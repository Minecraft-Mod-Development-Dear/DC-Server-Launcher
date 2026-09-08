[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Normal', 'Creative')]
    [string]$Mode,
    [switch]$NoPause,
    [string]$SettingsPath = '',
    [string]$LocalSettingsPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $PSScriptRoot 'Launcher.Core.psm1') -Force

function Save-Session {
    param([pscustomobject]$Session)
    Write-AtomicJson $Session.path $Session.value
}

function Get-PrimaryDetectionSettings {
    param([hashtable]$Settings)
    $detection = $Settings.detection
    $packagePrefixes = if ($detection.ContainsKey('primaryPackagePrefixes')) { @($detection.primaryPackagePrefixes) } else { @() }
    $loggers = if ($detection.ContainsKey('primaryLoggers')) { @($detection.primaryLoggers) } else { @() }
    $owner = if ($detection.ContainsKey('primaryOwner') -and -not [string]::IsNullOrWhiteSpace([string]$detection.primaryOwner)) {
        [string]$detection.primaryOwner
    } else { 'DC' }
    return [pscustomobject]@{ packagePrefixes = $packagePrefixes; loggers = $loggers; owner = $owner }
}

function Get-IssueLabelSettings {
    param([hashtable]$Settings)
    $github = $Settings.github
    $logLabel = if ($github.ContainsKey('logLabel') -and -not [string]::IsNullOrWhiteSpace([string]$github.logLabel)) { [string]$github.logLabel } else { 'Log' }
    $externalLabel = if ($github.ContainsKey('externalLabel') -and -not [string]::IsNullOrWhiteSpace([string]$github.externalLabel)) { [string]$github.externalLabel } else { 'External' }
    return [pscustomobject]@{ log = $logLabel; external = $externalLabel }
}

function Set-ServerProperties {
    param([string]$Path, [hashtable]$Expected)
    $lines = if (Test-Path -LiteralPath $Path -PathType Leaf) { @(Get-Content -Encoding UTF8 -LiteralPath $Path) } else { @() }
    $seen = @{}
    $updated = foreach ($line in $lines) {
        $separator = ([string]$line).IndexOf('=')
        if ($separator -lt 0 -or ([string]$line).TrimStart().StartsWith('#')) { $line; continue }
        $key = ([string]$line).Substring(0, $separator).Trim()
        if ($Expected.ContainsKey($key)) {
            $seen[$key] = $true
            "$key=$($Expected[$key])"
        } else { $line }
    }
    foreach ($key in $Expected.Keys | Sort-Object) {
        if (-not $seen.ContainsKey($key)) { $updated += "$key=$($Expected[$key])" }
    }
    $updated | Set-Content -Encoding UTF8 -LiteralPath $Path
}

function Test-RecordedProcessRunning {
    param([hashtable]$SessionValue)
    if ($null -eq $SessionValue -or $null -eq $SessionValue.processId -or [string]::IsNullOrWhiteSpace([string]$SessionValue.processStartedAt)) { return $false }
    $process = Get-Process -Id ([int]$SessionValue.processId) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        $expected = [DateTimeOffset]::Parse([string]$SessionValue.processStartedAt).UtcDateTime
        return [Math]::Abs(($process.StartTime.ToUniversalTime() - $expected).TotalSeconds) -lt 2
    } catch { return $false }
}

function Add-FindingsToOutbox {
    param([pscustomobject]$Session, [hashtable]$Settings, [hashtable]$Ignore, [hashtable]$Redaction)
    $created = 0
    $manual = 0
    $dedupe = @{}
    $detection = Get-PrimaryDetectionSettings $Settings
    $labels = Get-IssueLabelSettings $Settings
    $checkpoints = @($Session.value.logs)
    $knownCrashReports = @($Session.value.initialCrashReports | ForEach-Object { ([IO.Path]::GetFullPath([string]$_)).ToLowerInvariant() })
    $crashRoots = @((Join-Path ([string]$Session.value.serverDirectory) 'crash-reports'))
    if (-not [string]::IsNullOrWhiteSpace([string]$Session.value.clientLogDirectory)) {
        $crashRoots += Join-Path (Split-Path -Parent ([string]$Session.value.clientLogDirectory)) 'crash-reports'
    }
    $sessionStarted = [DateTimeOffset]::Parse([string]$Session.value.startedAt).UtcDateTime
    foreach ($crashRoot in $crashRoots) {
        if (-not (Test-Path -LiteralPath $crashRoot -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -File -LiteralPath $crashRoot -Filter '*.txt') {
            if ($file.FullName.ToLowerInvariant() -in $knownCrashReports -or $file.LastWriteTimeUtc -lt $sessionStarted) { continue }
            $checkpoints += [ordered]@{ path = $file.FullName; exists = $false; fileId = ''; offset = 0; lastWriteUtc = $null }
        }
    }
    foreach ($checkpoint in $checkpoints) {
        $segment = Read-LogSegment $checkpoint
        foreach ($finding in @(Get-LogFindings $segment ([string]$checkpoint.path) @($Ignore.ignoreContains))) {
            $ownership = Get-FindingOwnership @($finding.lines) @($detection.packagePrefixes) @($detection.loggers) $detection.owner
            $fingerprint = Get-FindingFingerprint $finding.text $ownership.owner
            if ($dedupe.ContainsKey($fingerprint)) { continue }
            $dedupe[$fingerprint] = $true
            $protected = Protect-LogText $finding.text @($Redaction.redactLiterals) @{
                '<SERVER_DIR>' = [string]$Session.value.serverDirectory
                '<CLIENT_LOG_DIR>' = [string]$Session.value.clientLogDirectory
                '<LAUNCHER_DIR>' = $projectRoot
            }
            if (-not $protected.safe -or [Text.Encoding]::UTF8.GetByteCount($protected.text) -gt [int]$Settings.posting.maxItemBytes) {
                $reasons = @($protected.reasons)
                if ([Text.Encoding]::UTF8.GetByteCount($protected.text) -gt [int]$Settings.posting.maxItemBytes) { $reasons += 'posting-size-limit' }
                [void](Protect-QuarantineData $projectRoot $Session.value.sessionId $finding.text $reasons)
                $manual++
                continue
            }
            [void](New-OutboxItem $projectRoot $Session.value.sessionId $finding $ownership.owner $fingerprint $protected.text $Session.value.serverExitCode $labels.log $labels.external)
            $created++
        }
    }
    return [pscustomobject]@{ created = $created; manual = $manual }
}

function Send-PendingOutbox {
    param([hashtable]$Settings)
    $pending = @(Get-PendingOutboxItems $projectRoot)
    if ($pending.Count -eq 0) { return [pscustomobject]@{ sent = 0; failed = 0; remaining = 0 } }
    if (-not [bool]$Settings.github.enabled) { return [pscustomobject]@{ sent = 0; failed = 0; remaining = $pending.Count } }

    $github = $Settings.github.Clone()
    $labels = Get-IssueLabelSettings $Settings
    $github.privateKeyPath = Resolve-LauncherPath ([string]$github.privateKeyPath) $projectRoot
    $github.openSslPath = Resolve-LauncherPath ([string]$github.openSslPath) $projectRoot
    $authMode = [string]$github.authMode
    if ([string]::IsNullOrWhiteSpace($authMode)) { $authMode = 'GitHubApp' }
    $ghPath = if ($authMode -eq 'GitHubCli') { Get-GitHubCliPath ([string]$github.ghPath) } else { '' }
    $throttle = @{ lastMutationUtc = [DateTime]::MinValue; mutationCount = 0; maxMutations = [int]$Settings.posting.maxMutations }
    $apiInvoker = {
        param($method, $uri, $headers, $body)
        $isIssueMutation = $method -in @('POST', 'PATCH', 'DELETE') -and $uri -notmatch '/access_tokens$'
        if ($isIssueMutation) {
            if ([int]$throttle.mutationCount -ge [int]$throttle.maxMutations) { throw 'GitHub mutation limit reached for this run.' }
            $elapsed = ([DateTime]::UtcNow - [DateTime]$throttle.lastMutationUtc).TotalMilliseconds
            if ($elapsed -lt 1000) { Start-Sleep -Milliseconds ([int][Math]::Ceiling(1000 - $elapsed)) }
            $throttle.lastMutationUtc = [DateTime]::UtcNow
            $throttle.mutationCount = [int]$throttle.mutationCount + 1
        }
        if ($authMode -eq 'GitHubCli') { return Invoke-GitHubCliRequest -GhPath $ghPath -Method $method -Uri $uri -Headers $headers -Body $body }
        return Invoke-DefaultGitHubRequest $method $uri $headers $body
    }.GetNewClosure()
    $token = if ($authMode -eq 'GitHubCli') { 'gh-cli' } else { Get-GitHubAccessToken -GitHub $github -RequestInvoker $apiInvoker }
    $sent = 0
    $failed = 0
    $postedBytes = 0
    foreach ($entry in $pending) {
        if ([int]$throttle.mutationCount -ge [int]$Settings.posting.maxMutations) { break }
        $itemBytes = [Text.Encoding]::UTF8.GetByteCount([string]$entry.value.body)
        if ($postedBytes + $itemBytes -gt [int]$Settings.posting.maxRunBytes) { break }
        $entry.value.status = 'sending'
        $entry.value.attempts = [int]$entry.value.attempts + 1
        Write-AtomicJson $entry.path $entry.value
        try {
            $result = Sync-LogIssue -ApiBase ([string]$github.apiBase) -Owner ([string]$github.owner) -Repository ([string]$github.repository) `
                -Token $token -Fingerprint ([string]$entry.value.fingerprint) -Title ([string]$entry.value.title) `
                -Body ([string]$entry.value.body) -FindingOwner ([string]$entry.value.owner) `
                -LogLabel $labels.log -ExternalLabel $labels.external -RequestInvoker $apiInvoker
            $entry.value.status = 'sent'
            $entry.value.issueNumber = $result.issue.number
            $entry.value.issueUrl = $result.issue.html_url
            $entry.value.sentAt = (Get-Date).ToUniversalTime().ToString('o')
            $entry.value.action = $result.action
            $sent++
            $postedBytes += $itemBytes
            Write-Host "[ISSUE] action=$($result.action) url=$($result.issue.html_url)"
        } catch {
            $entry.value.status = 'pending'
            $entry.value.lastError = $_.Exception.Message
            $retrySeconds = 300
            try {
                $retryHeader = $_.Exception.Response.Headers['Retry-After']
                if ($null -ne $retryHeader -and [int]::TryParse([string]$retryHeader, [ref]$retrySeconds)) { $retrySeconds = [Math]::Max(1, $retrySeconds) }
            } catch {}
            $entry.value.nextAttemptAt = (Get-Date).ToUniversalTime().AddSeconds($retrySeconds).ToString('o')
            $failed++
            Write-Warning "GitHub posting failed for $($entry.value.fingerprint): $($_.Exception.Message)"
        }
        Write-AtomicJson $entry.path $entry.value
    }
    $remaining = @(Get-PendingOutboxItems $projectRoot).Count
    return [pscustomobject]@{ sent = $sent; failed = $failed; remaining = $remaining }
}

function Complete-Session {
    param([pscustomobject]$Session, [hashtable]$Settings, [hashtable]$Ignore, [hashtable]$Redaction, [object]$ServerExitCode)
    $Session.value.status = 'finalizing'
    $Session.value.serverExitCode = $ServerExitCode
    Save-Session $Session
    $queue = Add-FindingsToOutbox $Session $Settings $Ignore $Redaction
    $posting = Send-PendingOutbox $Settings
    $Session.value.status = if ($posting.remaining -gt 0) { 'pending' } else { 'completed' }
    $Session.value.completedAt = (Get-Date).ToUniversalTime().ToString('o')
    $Session.value.findings = [ordered]@{ queued = $queue.created; manual = $queue.manual; sent = $posting.sent; failed = $posting.failed; pending = $posting.remaining }
    Save-Session $Session
    $toolExitCode = Get-ToolExitCode $ServerExitCode ($(if ($posting.failed -gt 0) { 41 } else { 0 })) -Pending:($posting.remaining -gt 0)
    $result = [ordered]@{
        sessionId = $Session.value.sessionId; mode = $Session.value.mode; serverExitCode = $ServerExitCode
        toolExitCode = $toolExitCode; queued = $queue.created; manual = $queue.manual; sent = $posting.sent
        failed = $posting.failed; pending = $posting.remaining; completedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-AtomicJson (Join-Path $projectRoot "state\results\$($Session.value.sessionId).json") $result
    return [pscustomobject]$result
}

function Recover-UnfinishedSessions {
    param([hashtable]$Settings, [hashtable]$Ignore, [hashtable]$Redaction)
    foreach ($unfinished in @(Get-UnfinishedSessions $projectRoot)) {
        if ($null -eq $unfinished.value) { throw "Unreadable session file: $($unfinished.path)" }
        if (Test-RecordedProcessRunning $unfinished.value) { throw "A recorded server process is still running: PID $($unfinished.value.processId)" }
        Write-Host "[RECOVERY] session=$($unfinished.value.sessionId)"
        if ([string]$unfinished.value.status -eq 'pending') {
            $posting = Send-PendingOutbox $Settings
            if ($posting.remaining -eq 0) {
                $unfinished.value.status = 'completed'
                $unfinished.value.completedAt = (Get-Date).ToUniversalTime().ToString('o')
                Save-Session $unfinished
            }
        } else {
            [void](Complete-Session $unfinished $Settings $Ignore $Redaction 'unknown')
        }
    }
}

function Prepare-CreativeProfile {
    param([hashtable]$Profile)
    $serverDirectory = Resolve-LauncherPath ([string]$Profile.serverDirectory) $projectRoot
    $runtimeRoot = Resolve-LauncherPath 'runtime' $projectRoot
    if (-not (Test-ChildPath $runtimeRoot $serverDirectory)) { throw "Creative server directory must be under runtime: $serverDirectory" }
    $sourceDirectory = Resolve-LauncherPath ([string]$Profile.sourceServerDirectory) $projectRoot
    if (-not (Test-Path -LiteralPath $serverDirectory -PathType Container)) { New-Item -ItemType Directory -Force -Path $serverDirectory | Out-Null }
    foreach ($directoryName in @('libraries', 'mods', 'config')) {
        Sync-DirectoryMirror (Join-Path $sourceDirectory $directoryName) (Join-Path $serverDirectory $directoryName) $runtimeRoot
    }
    $minecraftServerJar = if ($Profile.ContainsKey('minecraftServerJar') -and -not [string]::IsNullOrWhiteSpace([string]$Profile.minecraftServerJar)) {
        [string]$Profile.minecraftServerJar
    } else { 'minecraft_server.1.12.2.jar' }
    foreach ($fileName in @([string]$Profile.serverJar, $minecraftServerJar, 'eula.txt', 'server.properties')) {
        $source = Join-Path $sourceDirectory $fileName
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Creative source file not found: $source" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $serverDirectory $fileName) -Force
    }
    Set-ServerProperties (Join-Path $serverDirectory 'server.properties') $Profile.expectedProperties
    $worldPath = Join-Path $serverDirectory ([string]$Profile.worldName)
    if (-not (Test-DirectChildPath $serverDirectory $worldPath)) { throw "Creative world must be a direct child of its server directory: $worldPath" }
    if (Test-Path -LiteralPath $worldPath -PathType Container) { Remove-Item -LiteralPath $worldPath -Recurse -Force }
    return $serverDirectory
}

$toolExitCode = 50
$serverExitCode = 'unknown'
$failureExitCode = 10
$process = $null
try {
    $settings = Get-LauncherSettings $projectRoot $SettingsPath $LocalSettingsPath
    $ignore = Read-JsonHashtable (Join-Path $projectRoot 'config\ignore.json')
    $redaction = Read-JsonHashtable (Join-Path $projectRoot 'config\redaction.local.json') -Optional
    if (-not $redaction.ContainsKey('redactLiterals') -or $null -eq $redaction.redactLiterals) { $redaction['redactLiterals'] = @() }
    Recover-UnfinishedSessions $settings $ignore $redaction

    if (-not $settings.profiles.ContainsKey($Mode)) { throw "Profile not found: $Mode" }
    $profile = $settings.profiles[$Mode]
    $serverDirectory = if ($Mode -eq 'Creative') { Prepare-CreativeProfile $profile } else { Resolve-LauncherPath ([string]$profile.serverDirectory) $projectRoot }
    $propertiesPath = Join-Path $serverDirectory 'server.properties'
    $jarPath = Join-Path $serverDirectory ([string]$profile.serverJar)
    foreach ($required in @($propertiesPath, $jarPath, (Join-Path $serverDirectory 'eula.txt'))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required server file not found: $required" }
    }
    [void](Test-ServerClassPath $jarPath)
    $properties = Read-ServerProperties $propertiesPath
    $propertyErrors = @(Test-ExpectedProperties $properties $profile.expectedProperties)
    if ($propertyErrors.Count -gt 0) { throw ($propertyErrors -join [Environment]::NewLine) }
    $eulaPath = Join-Path $serverDirectory 'eula.txt'
    $eula = Get-Content -Raw -Encoding UTF8 -LiteralPath $eulaPath
    if ($eula -notmatch '(?m)^\s*eula\s*=\s*true\s*$') { throw "Minecraft EULA has not been accepted: $eulaPath" }
    $port = [int]$profile.expectedProperties['server-port']
    $address = [string]$profile.expectedProperties['server-ip']
    if (-not (Test-PortAvailable $port $address)) { throw "Server port is already in use: $address`:$port" }

    $javaPath = Resolve-Java8 (Resolve-LauncherPath ([string]$settings.java.path) $projectRoot)
    if ([string]::IsNullOrWhiteSpace($javaPath)) { throw 'Java 8 could not be found. Set java.path in config/settings.local.json.' }
    if ($settings.java.arguments -isnot [array]) { throw 'java.arguments must be a JSON array of strings.' }
    $arguments = @($settings.java.arguments) + @('-jar', $jarPath, 'nogui')
    [void](ConvertTo-NativeArgumentLine -Arguments $arguments)
    if ([bool]$settings.github.enabled) {
        $githubPreflight = $settings.github.Clone()
        foreach ($key in @('owner', 'repository')) {
            if ([string]::IsNullOrWhiteSpace([string]$githubPreflight[$key])) { throw "GitHub setting is empty: github.$key" }
        }
        $issueLabels = Get-IssueLabelSettings $settings
        foreach ($label in @($issueLabels.log, $issueLabels.external)) {
            if ([string]::IsNullOrWhiteSpace([string]$label)) { throw 'GitHub issue labels must not be empty.' }
        }
        $authMode = [string]$githubPreflight.authMode
        if ([string]::IsNullOrWhiteSpace($authMode)) { $authMode = 'GitHubApp' }
        if ($authMode -eq 'GitHubApp') {
            foreach ($key in @('appId', 'installationId', 'privateKeyPath')) {
                if ([string]::IsNullOrWhiteSpace([string]$githubPreflight[$key])) { throw "GitHub App setting is empty: github.$key" }
            }
            $githubPreflight.privateKeyPath = Resolve-LauncherPath ([string]$githubPreflight.privateKeyPath) $projectRoot
            $githubPreflight.openSslPath = Resolve-LauncherPath ([string]$githubPreflight.openSslPath) $projectRoot
            if (-not (Test-Path -LiteralPath $githubPreflight.privateKeyPath -PathType Leaf)) { throw "GitHub App private key was not found: $($githubPreflight.privateKeyPath)" }
        } elseif ($authMode -ne 'GitHubCli') {
            throw "Unsupported GitHub authentication mode: $authMode"
        }
        $preflightInvoker = if ($authMode -eq 'GitHubCli') {
            [void]($preflightGhPath = Get-GitHubCliPath ([string]$githubPreflight.ghPath))
            { param($method,$uri,$headers,$body) Invoke-GitHubCliRequest -GhPath $preflightGhPath -Method $method -Uri $uri -Headers $headers -Body $body }.GetNewClosure()
        } else { ${function:Invoke-DefaultGitHubRequest} }
        $preflightToken = if ($authMode -eq 'GitHubCli') { 'gh-cli' } else { Get-GitHubAccessToken -GitHub $githubPreflight }
        [void](Test-GitHubRepositoryLabels ([string]$githubPreflight.apiBase) ([string]$githubPreflight.owner) ([string]$githubPreflight.repository) $preflightToken @($issueLabels.log, $issueLabels.external) $preflightInvoker)
    }
    if ([bool]$settings.mods.validate) {
        $serverInventory = @(Get-ModJarInventory (Join-Path $serverDirectory 'mods'))
        $clientMods = Resolve-LauncherPath ([string]$settings.client.modsDirectory) $projectRoot
        $clientInventory = @(Get-ModJarInventory $clientMods)
        $modErrors = @(Test-ModInventoryMatch $serverInventory $clientInventory @($settings.mods.serverOnlyModIds) @($settings.mods.clientOnlyModIds) @($settings.mods.serverOnlyJarHashes) @($settings.mods.clientOnlyJarHashes))
        if ($modErrors.Count -gt 0) { throw ($modErrors -join [Environment]::NewLine) }
    }

    $clientLogDirectory = Resolve-LauncherPath ([string]$settings.client.logsDirectory) $projectRoot
    $worldName = if ($Mode -eq 'Creative') { [string]$profile.worldName } else { [string]$properties['level-name'] }
    Write-Host "[SERVER] mode=$Mode"
    Write-Host "[SERVER] connect=$address`:$port"
    Write-Host "[SERVER] world=$worldName"
    Write-Host "[SERVER] console=this window"

    $session = New-LauncherSession $projectRoot $Mode $serverDirectory $clientLogDirectory
    $failureExitCode = 20
    $process = Start-LauncherProcess -FilePath $javaPath -Arguments $arguments -WorkingDirectory $serverDirectory
    $session.value.status = 'running'
    $session.value.processId = $process.Id
    $session.value.processStartedAt = $process.StartTime.ToUniversalTime().ToString('o')
    Save-Session $session
    $process.WaitForExit()
    $serverExitCode = [int]$process.ExitCode
    $failureExitCode = 30
    $result = Complete-Session $session $settings $ignore $redaction $serverExitCode
    $toolExitCode = [int]$result.toolExitCode
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    if ($toolExitCode -eq 50) { $toolExitCode = $failureExitCode }
} finally {
    if ($null -ne $process) { $process.Dispose() }
    Write-Host "[RESULT] serverExitCode=$serverExitCode"
    Write-Host "[RESULT] toolExitCode=$toolExitCode"
    if (-not $NoPause -and [Environment]::UserInteractive) { [void](Read-Host 'Press Enter to close') }
}

exit $toolExitCode
