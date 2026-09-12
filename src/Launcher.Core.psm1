Set-StrictMode -Version 2.0

function ConvertTo-HashtableDeep {
    param([object]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) { $table[[string]$key] = ConvertTo-HashtableDeep $InputObject[$key] }
        return $table
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $InputObject) { [void]$items.Add((ConvertTo-HashtableDeep $item)) }
        return ,($items.ToArray())
    }
    # The [pscustomobject] accelerator also matches PSObject-wrapped strings in
    # Windows PowerShell. Only actual JSON objects should become dictionaries.
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-HashtableDeep $property.Value
        }
        return $table
    }
    return $InputObject
}

function Merge-HashtableDeep {
    param([hashtable]$Base, [hashtable]$Override)
    $result = @{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    foreach ($key in $Override.Keys) {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $result[$key] = Merge-HashtableDeep $result[$key] $Override[$key]
        } else {
            $result[$key] = $Override[$key]
        }
    }
    return $result
}

function Read-JsonHashtable {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Optional)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($Optional) { return @{} }
        throw "JSON file was not found: $Path"
    }
    $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "JSON file is empty: $Path" }
    return ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)
}

function Write-AtomicJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $temporary = Join-Path $parent ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($fullPath)), [Guid]::NewGuid().ToString('N'))
    try {
        $Value | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 -LiteralPath $temporary
        Move-Item -LiteralPath $temporary -Destination $fullPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Resolve-LauncherPath {
    param([string]$Value, [string]$ProjectRoot)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    if (-not [IO.Path]::IsPathRooted($expanded)) { $expanded = Join-Path $ProjectRoot $expanded }
    return [IO.Path]::GetFullPath($expanded)
}

function Get-LauncherSettings {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$SettingsPath = '',
        [string]$LocalSettingsPath = ''
    )
    if ([string]::IsNullOrWhiteSpace($SettingsPath)) { $SettingsPath = Join-Path $ProjectRoot 'config\settings.json' }
    if ([string]::IsNullOrWhiteSpace($LocalSettingsPath)) { $LocalSettingsPath = Join-Path $ProjectRoot 'config\settings.local.json' }
    $settings = Read-JsonHashtable -Path $SettingsPath
    $local = Read-JsonHashtable -Path $LocalSettingsPath -Optional
    $merged = Merge-HashtableDeep $settings $local
    $merged['_projectRoot'] = [IO.Path]::GetFullPath($ProjectRoot)
    return $merged
}

function Read-ServerProperties {
    param([Parameter(Mandatory = $true)][string]$Path)
    $properties = @{}
    foreach ($line in Get-Content -Encoding UTF8 -LiteralPath $Path) {
        $text = [string]$line
        if ([string]::IsNullOrWhiteSpace($text) -or $text.TrimStart().StartsWith('#')) { continue }
        $separator = $text.IndexOf('=')
        if ($separator -lt 0) { continue }
        $properties[$text.Substring(0, $separator).Trim()] = $text.Substring($separator + 1).Trim()
    }
    return $properties
}

function Test-ExpectedProperties {
    param([hashtable]$Actual, [hashtable]$Expected)
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Expected.Keys) {
        $actualValue = if ($Actual.ContainsKey($key)) { [string]$Actual[$key] } else { '<missing>' }
        if ($actualValue -cne [string]$Expected[$key]) {
            [void]$errors.Add("server.properties mismatch: $key actual=$actualValue expected=$($Expected[$key])")
        }
    }
    return $errors.ToArray()
}

function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Get-FilePrefixHash {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$Length)
    if ($Length -le 0) { return '' }
    $stream = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    } catch [IO.IOException] {
        return ''
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $buffer = New-Object byte[] $Length
        $read = $stream.Read($buffer, 0, $Length)
        if ($read -ne $Length) { return '' }
        return ([BitConverter]::ToString($sha.ComputeHash($buffer))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose(); $stream.Dispose() }
}

function Get-FileCheckpoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return [ordered]@{ path = $fullPath; exists = $false; fileId = ''; offset = 0; prefixLength = 0; prefixHash = ''; lastWriteUtc = $null }
    }
    $file = Get-Item -LiteralPath $fullPath
    $identity = Get-Sha256Text ("{0}|{1}" -f $file.FullName.ToLowerInvariant(), $file.CreationTimeUtc.Ticks)
    $prefixLength = [Math]::Min([int64]4096, [int64]$file.Length)
    return [ordered]@{
        path = $file.FullName
        exists = $true
        fileId = $identity
        offset = [long]$file.Length
        prefixLength = [int]$prefixLength
        prefixHash = Get-FilePrefixHash $file.FullName ([int]$prefixLength)
        lastWriteUtc = $file.LastWriteTimeUtc.ToString('o')
    }
}

function Read-LogSegment {
    param([Parameter(Mandatory = $true)][hashtable]$Checkpoint)
    $path = [string]$Checkpoint.path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $file = Get-Item -LiteralPath $path
    $offset = [long]$Checkpoint.offset
    $currentCheckpoint = Get-FileCheckpoint $path
    if (-not [bool]$Checkpoint.exists -or [string]$currentCheckpoint.fileId -cne [string]$Checkpoint.fileId) { $offset = 0 }
    if ($Checkpoint.ContainsKey('prefixLength') -and [int]$Checkpoint.prefixLength -gt 0) {
        $currentPrefix = Get-FilePrefixHash $path ([int]$Checkpoint.prefixLength)
        if ([string]$currentPrefix -cne [string]$Checkpoint.prefixHash) { $offset = 0 }
    }
    if ($offset -lt 0 -or $offset -gt $file.Length) { $offset = 0 }
    $stream = $null
    try {
        try {
            # Minecraft/Log4j may keep the client log open while the server
            # finalizes. Share the file with the running client where possible.
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        } catch [IO.IOException] {
            # A locked client log must not turn an otherwise clean server exit
            # into a launcher failure. It will be picked up on a later run.
            return ''
        }
        [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
        $remaining = [int64]$stream.Length - $offset
        if ($remaining -le 0) { return '' }
        if ($remaining -gt [int32]::MaxValue) { throw "Log segment is too large to read: $path" }
        $bytes = New-Object byte[] ([int]$remaining)
        $read = 0
        while ($read -lt $bytes.Length) {
            $count = $stream.Read($bytes, $read, $bytes.Length - $read)
            if ($count -le 0) { break }
            $read += $count
        }
        if ($read -le 0) { return '' }
        try {
            return (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes, 0, $read)
        } catch {
            return [Text.Encoding]::GetEncoding(932).GetString($bytes, 0, $read)
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function New-LauncherSession {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ServerDirectory,
        [string]$ClientLogDirectory = ''
    )
    $id = [Guid]::NewGuid().ToString('N')
    $logs = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('latest.log', 'debug.log')) {
        [void]$logs.Add((Get-FileCheckpoint (Join-Path $ServerDirectory "logs\$name")))
        if (-not [string]::IsNullOrWhiteSpace($ClientLogDirectory)) {
            [void]$logs.Add((Get-FileCheckpoint (Join-Path $ClientLogDirectory $name)))
        }
    }
    $crashFiles = @()
    $crashRoots = @($ServerDirectory)
    if (-not [string]::IsNullOrWhiteSpace($ClientLogDirectory)) { $crashRoots += Split-Path -Parent $ClientLogDirectory }
    foreach ($root in $crashRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $crashDir = Join-Path $root 'crash-reports'
        if (Test-Path -LiteralPath $crashDir -PathType Container) {
            $crashFiles += @(Get-ChildItem -File -LiteralPath $crashDir | ForEach-Object { $_.FullName })
        }
    }
    $session = [ordered]@{
        schemaVersion = 1; sessionId = $id; mode = $Mode; status = 'prepared'
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
        serverDirectory = [IO.Path]::GetFullPath($ServerDirectory)
        clientLogDirectory = $ClientLogDirectory
        processId = $null; processStartedAt = $null; serverExitCode = $null
        # Windows PowerShell 5.1 can fail to enumerate a typed generic List
        # inside an array subexpression. Materialize it before serializing.
        logs = @($logs.ToArray()); initialCrashReports = @($crashFiles); findings = @()
    }
    $path = Join-Path $ProjectRoot "state\sessions\$id.json"
    Write-AtomicJson $path $session
    return [pscustomobject]@{ path = $path; value = $session }
}

function Get-UnfinishedSessions {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $directory = Join-Path $ProjectRoot 'state\sessions'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return @() }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($file in Get-ChildItem -File -LiteralPath $directory -Filter '*.json') {
        try {
            $value = Read-JsonHashtable $file.FullName
            if ([string]$value.status -notin @('completed')) { [void]$items.Add([pscustomobject]@{ path = $file.FullName; value = $value }) }
        } catch { [void]$items.Add([pscustomobject]@{ path = $file.FullName; value = $null; error = $_.Exception.Message }) }
    }
    return $items.ToArray()
}

function Test-OrdinalContains {
    param([string]$Text, [string]$Value)
    return $Text.IndexOf($Value, [StringComparison]::Ordinal) -ge 0
}

function Test-FindingIgnored {
    param([string[]]$Lines, [string[]]$IgnoreContains)
    foreach ($pattern in @($IgnoreContains)) {
        if ([string]::IsNullOrEmpty($pattern)) { continue }
        foreach ($line in @($Lines)) { if (Test-OrdinalContains $line $pattern) { return $true } }
    }
    return $false
}

function Get-LogFindings {
    param([string]$Text, [string]$SourcePath = '', [string[]]$IgnoreContains = @())
    $lines = @($Text -split "`r?`n")
    $results = New-Object System.Collections.Generic.List[object]
    $startPattern = '(?i)(?:\bERROR\b|\bFATAL\b|\bSEVERE\b|\bWARN(?:ING)?\b|\bException\b|\bError\b|Caused by:|Crash report)'
    $continuationPattern = '^\s*(?:at\s+|Caused by:|Suppressed:|\.\.\.\s+\d+\s+more|$)'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch $startPattern) { continue }
        $group = New-Object System.Collections.Generic.List[string]
        [void]$group.Add([string]$lines[$i])
        $j = $i + 1
        while ($j -lt $lines.Count -and $lines[$j] -match $continuationPattern) {
            [void]$group.Add([string]$lines[$j]); $j++
        }
        $i = [Math]::Max($i, $j - 1)
        if (Test-FindingIgnored @($group) $IgnoreContains) { continue }
        $joined = @($group) -join "`n"
        $severity = if ($joined -match '(?i)\b(?:ERROR|FATAL|SEVERE|Exception|Error|Caused by:)\b') { 'error' } else { 'warn' }
        [void]$results.Add([pscustomobject]@{ severity = $severity; sourcePath = $SourcePath; startLine = $i - $group.Count + 2; lines = @($group); text = $joined })
    }
    return $results.ToArray()
}

function Get-FindingOwnership {
    param(
        [Parameter(Mandatory = $true)][string[]]$Lines,
        [string[]]$PrimaryPackagePrefixes = @('com.minecraftmoddevelopmentdear.dimensionalcontainer'),
        [string[]]$PrimaryLoggers = @('dimensionalcontainer', 'DimensionalContainerCore'),
        [string]$PrimaryOwner = 'DC'
    )
    if ([string]::IsNullOrWhiteSpace($PrimaryOwner)) { $PrimaryOwner = 'DC' }
    $generic = @('java.', 'javax.', 'sun.', 'com.sun.', 'net.minecraft.', 'net.minecraftforge.', 'org.spongepowered.')
    $causeIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match 'Caused by:') { $causeIndex = $i } }
    $start = if ($causeIndex -ge 0) { $causeIndex + 1 } else { 0 }
    for ($i = $start; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^\s*at\s+(?<class>[A-Za-z0-9_.$]+)') { continue }
        $className = [string]$Matches['class']
        if (@($generic | Where-Object { $className.StartsWith($_, [StringComparison]::Ordinal) }).Count -gt 0) { continue }
        if (@($PrimaryPackagePrefixes | Where-Object { $className.StartsWith($_, [StringComparison]::Ordinal) }).Count -gt 0) {
            return [pscustomobject]@{ owner = $PrimaryOwner; evidence = "throwing-frame:$className" }
        }
        return [pscustomobject]@{ owner = 'External'; evidence = "throwing-frame:$className" }
    }
    foreach ($line in $Lines) {
        if ($line -match '\[[^\]]+/(?:WARN|ERROR|FATAL)\]\s+\[(?<logger>[^\]]+)\]') {
            $logger = [string]$Matches['logger']
            if (@($PrimaryLoggers | Where-Object { $logger.Equals($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
                return [pscustomobject]@{ owner = $PrimaryOwner; evidence = "logger:$logger" }
            }
            if ($logger -notin @('FML', 'minecraft', 'Forge')) { return [pscustomobject]@{ owner = 'External'; evidence = "logger:$logger" } }
        }
    }
    return [pscustomobject]@{ owner = $PrimaryOwner; evidence = 'fallback:unresolved' }
}

function Get-FindingFingerprint {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Owner)
    $normalized = $Text
    $normalized = [regex]::Replace($normalized, '(?m)^\[[0-9:.-]+\]\s*', '')
    $normalized = [regex]::Replace($normalized, '(?i)\b0x[0-9a-f]+\b', '<hex>')
    $normalized = [regex]::Replace($normalized, '(?m)(\.java):\d+', '$1:<line>')
    $normalized = [regex]::Replace($normalized, '(?i)\b[0-9a-f]{8}-[0-9a-f-]{27,}\b', '<uuid>')
    $normalized = [regex]::Replace($normalized, '(?m)(?:[A-Za-z]:\\|/)[^\s)]+', '<path>')
    return Get-Sha256Text ($Owner + "`n" + $normalized.Trim())
}

function Invoke-RegexReplace {
    param([string]$Text, [string]$Pattern, [object]$Replacement, [Text.RegularExpressions.RegexOptions]$Options = [Text.RegularExpressions.RegexOptions]::None)
    $regex = New-Object Text.RegularExpressions.Regex($Pattern, $Options, ([TimeSpan]::FromSeconds(2)))
    if ($Replacement -is [scriptblock]) { return $regex.Replace($Text, [Text.RegularExpressions.MatchEvaluator]$Replacement) }
    return $regex.Replace($Text, [string]$Replacement)
}

function Protect-LogText {
    param([Parameter(Mandatory = $true)][string]$Text, [string[]]$RedactLiterals = @(), [hashtable]$PathMap = @{})
    $value = $Text
    $reasons = New-Object System.Collections.Generic.List[string]
    foreach ($literal in @($RedactLiterals | Sort-Object Length -Descending -Unique)) {
        if ([string]::IsNullOrEmpty($literal)) { return [pscustomobject]@{ safe = $false; text = ''; reasons = @('empty-redact-literal') } }
        $value = $value.Replace($literal, '[REDACTED_CUSTOM]')
    }
    try {
        $value = Invoke-RegexReplace $value '-----BEGIN(?: RSA)? PRIVATE KEY-----[\s\S]*?-----END(?: RSA)? PRIVATE KEY-----' '[REDACTED_CREDENTIAL]' ([Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $value = Invoke-RegexReplace $value '\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b' '[REDACTED_CREDENTIAL]'
        $value = Invoke-RegexReplace $value '(?im)(Authorization\s*:\s*)(?:Bearer|Basic)\s+[^\s]+' '$1[REDACTED_CREDENTIAL]'
        $value = Invoke-RegexReplace $value '(?i)(https?://)[^/\s:@]+:[^@\s/]+@' '$1[REDACTED_URL_SECRET]@'
        $value = Invoke-RegexReplace $value '(?i)([?&](?:token|access_token|auth|api_key|password|secret|signature)=)[^&#\s]+' '$1[REDACTED_URL_SECRET]'
        $value = Invoke-RegexReplace $value '\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b' '[REDACTED_EMAIL]' ([Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $value = Invoke-RegexReplace $value '\b(?:\d{1,3}\.){3}\d{1,3}\b' { param($match) if ($match.Value -eq '127.0.0.1') { $match.Value } else { '[REDACTED_IP]' } }
        $value = Invoke-RegexReplace $value '(?m)(<)[^>\r\n]+(>\s*).+$' '$1[PLAYER]$2[REDACTED_CHAT]'
        foreach ($key in @($PathMap.Keys | Sort-Object { ([string]$PathMap[$_]).Length } -Descending)) {
            $path = [string]$PathMap[$key]
            if (-not [string]::IsNullOrWhiteSpace($path)) { $value = $value.Replace($path.TrimEnd('\'), [string]$key) }
        }
        $value = Invoke-RegexReplace $value '(?i)\b[A-Z]:\\(?:[^\s<>:"|?*]+\\)*[^\s<>:"|?*]*' '<LOCAL_PATH>'
    } catch {
        [void]$reasons.Add('redaction-error:' + $_.Exception.GetType().Name)
    }
    $credentialPattern = '(?i)(?:-----BEGIN(?: RSA)? PRIVATE KEY-----|\bgh[pousr]_[A-Za-z0-9_]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b|Authorization\s*:\s*(?:Bearer|Basic)\s+(?!\[REDACTED))'
    try { if ([regex]::IsMatch($value, $credentialPattern)) { [void]$reasons.Add('credential-pattern-remains') } }
    catch { [void]$reasons.Add('redaction-rescan-error') }
    return [pscustomobject]@{ safe = ($reasons.Count -eq 0); text = $value; reasons = @($reasons) }
}

function Get-IssueLabels {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [string]$LogLabel = 'Log',
        [string]$ExternalLabel = 'External'
    )
    if ([string]::IsNullOrWhiteSpace($LogLabel)) { $LogLabel = 'Log' }
    if ([string]::IsNullOrWhiteSpace($ExternalLabel)) { $ExternalLabel = 'External' }
    if ($Owner -eq 'External') { return @($LogLabel, $ExternalLabel) }
    return @($LogLabel)
}

function Test-GitHubRepositoryLabels {
    param(
        [string]$ApiBase = 'https://api.github.com', [string]$Owner, [string]$Repository,
        [string]$Token, [string[]]$RequiredLabels = @('Log', 'External'),
        [scriptblock]$RequestInvoker = ${function:Invoke-DefaultGitHubRequest}
    )
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    foreach ($label in $RequiredLabels) {
        $encoded = [Uri]::EscapeDataString($label)
        try { [void](& $RequestInvoker 'GET' "$ApiBase/repos/$Owner/$Repository/labels/$encoded" $headers $null) }
        catch { throw "Required GitHub label was not found or could not be read: $label. $($_.Exception.Message)" }
    }
    return $true
}

function Get-ToolExitCode {
    param([object]$ServerExitCode, [int]$ToolFailureCode = 0, [switch]$Pending)
    if ($ToolFailureCode -ne 0) { return $ToolFailureCode }
    $parsedExitCode = 0
    if (-not [int]::TryParse([string]$ServerExitCode, [ref]$parsedExitCode) -or $parsedExitCode -ne 0) { return 21 }
    if ($Pending) { return 42 }
    return 0
}

function Invoke-DefaultGitHubRequest {
    param([string]$Method, [string]$Uri, [hashtable]$Headers, [object]$Body)
    $parameters = @{ Method = $Method; Uri = $Uri; Headers = $Headers; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $parameters['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress); $parameters['ContentType'] = 'application/json' }
    return Invoke-RestMethod @parameters
}

function Find-GitHubIssuesByFingerprint {
    param(
        [string]$ApiBase = 'https://api.github.com', [string]$Owner, [string]$Repository,
        [string]$Fingerprint, [string]$Token, [scriptblock]$RequestInvoker = ${function:Invoke-DefaultGitHubRequest}
    )
    $marker = "<!-- log-fingerprint: $Fingerprint -->"
    $query = [Uri]::EscapeDataString("repo:$Owner/$Repository is:issue in:body `"$Fingerprint`"")
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $page = 1; $matches = New-Object System.Collections.Generic.List[object]
    do {
        $uri = "$ApiBase/search/issues?q=$query&per_page=100&page=$page"
        $response = & $RequestInvoker 'GET' $uri $headers $null
        if ($response.PSObject.Properties.Name -contains 'incomplete_results' -and $response.incomplete_results) { throw 'GitHub issue search returned incomplete results.' }
        $items = @($response.items)
        foreach ($issue in $items) {
            $markerLines = @([string]$issue.body -split "`r?`n" | Where-Object { $_ -ceq $marker })
            if ($markerLines.Count -gt 0) { [void]$matches.Add($issue) }
        }
        $page++
    } while ($items.Count -eq 100)
    return $matches.ToArray()
}

function Set-IssueLabels {
    param([object]$Issue, [string[]]$RequiredLabels, [string]$ApiBase, [string]$Owner, [string]$Repository, [string]$Token, [scriptblock]$RequestInvoker)
    $existing = @($Issue.labels | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } })
    $labels = @($existing + $RequiredLabels | Sort-Object -Unique)
    if (@($RequiredLabels | Where-Object { $_ -notin $existing }).Count -eq 0) { return $Issue }
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    return & $RequestInvoker 'PATCH' "$ApiBase/repos/$Owner/$Repository/issues/$($Issue.number)" $headers @{ labels = $labels }
}

function Split-Utf8Text {
    param([Parameter(Mandatory = $true)][string]$Text, [int]$MaxBytes = 50000)
    if ($MaxBytes -lt 4) { throw 'MaxBytes must be at least 4.' }
    if ([Text.Encoding]::UTF8.GetByteCount($Text) -le $MaxBytes) { return @($Text) }
    $parts = New-Object System.Collections.Generic.List[string]
    $builder = New-Object Text.StringBuilder
    $bytes = 0
    foreach ($character in $Text.ToCharArray()) {
        $characterBytes = [Text.Encoding]::UTF8.GetByteCount([string]$character)
        if ($builder.Length -gt 0 -and $bytes + $characterBytes -gt $MaxBytes) {
            [void]$parts.Add($builder.ToString())
            [void]$builder.Clear()
            $bytes = 0
        }
        [void]$builder.Append($character)
        $bytes += $characterBytes
    }
    if ($builder.Length -gt 0) { [void]$parts.Add($builder.ToString()) }
    return $parts.ToArray()
}

function Get-GitHubIssueStateReason {
    param(
        [object]$Issue, [string]$ApiBase, [string]$Owner, [string]$Repository,
        [string]$Token, [scriptblock]$RequestInvoker
    )
    $stateReasonProperty = $Issue.PSObject.Properties['state_reason']
    if ($null -eq $stateReasonProperty) {
        $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
        $details = & $RequestInvoker 'GET' "$ApiBase/repos/$Owner/$Repository/issues/$($Issue.number)" $headers $null
        $stateReasonProperty = $details.PSObject.Properties['state_reason']
        if ($null -eq $stateReasonProperty) {
            throw "Closed GitHub issue #$($Issue.number) did not include state_reason."
        }
    }
    if ($null -eq $stateReasonProperty.Value) { return $null }
    return [string]$stateReasonProperty.Value
}

function Add-LogIssueReoccurrenceComments {
    param(
        [object]$Issue, [string]$Fingerprint, [object[]]$BodyChunks, [string]$ApiBase,
        [string]$Owner, [string]$Repository, [string]$Token, [scriptblock]$RequestInvoker
    )
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    for ($chunkIndex = 0; $chunkIndex -lt $BodyChunks.Count; $chunkIndex++) {
        $chunkHash = Get-Sha256Text $BodyChunks[$chunkIndex]
        $commentBody = "<!-- log-chunk: $Fingerprint-$chunkIndex-$chunkHash -->`n$($BodyChunks[$chunkIndex])"
        [void](& $RequestInvoker 'POST' "$ApiBase/repos/$Owner/$Repository/issues/$($Issue.number)/comments" $headers @{ body = $commentBody })
    }
}

function Resolve-ClosedLogIssue {
    param(
        [object]$Issue, [string]$Fingerprint, [object[]]$BodyChunks, [string]$ApiBase,
        [string]$Owner, [string]$Repository, [string]$Token, [scriptblock]$RequestInvoker
    )
    $stateReason = Get-GitHubIssueStateReason $Issue $ApiBase $Owner $Repository $Token $RequestInvoker
    if ($stateReason -in @('not_planned', 'duplicate')) {
        return [pscustomobject]@{ action = 'existing-closed-suppressed'; issue = $Issue; commented = $false }
    }

    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $labels = @($Issue.labels | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } })
    $updated = & $RequestInvoker 'PATCH' "$ApiBase/repos/$Owner/$Repository/issues/$($Issue.number)" $headers @{ state = 'open'; labels = $labels }
    Add-LogIssueReoccurrenceComments $updated $Fingerprint $BodyChunks $ApiBase $Owner $Repository $Token $RequestInvoker
    return [pscustomobject]@{ action = 'reopened'; issue = $updated; commented = $true }
}

function Close-DuplicateLogIssues {
    param(
        [object]$Canonical, [object[]]$Duplicates, [string]$ApiBase, [string]$Owner,
        [string]$Repository, [string]$Token, [string[]]$RequiredLabels, [scriptblock]$RequestInvoker
    )
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    foreach ($duplicate in @($Duplicates)) {
        $duplicate = Set-IssueLabels $duplicate $RequiredLabels $ApiBase $Owner $Repository $Token $RequestInvoker
        if ([string]$duplicate.state -eq 'closed') { continue }
        $message = "Duplicate log issue. The canonical issue is #$($Canonical.number)."
        [void](& $RequestInvoker 'POST' "$ApiBase/repos/$Owner/$Repository/issues/$($duplicate.number)/comments" $headers @{ body = $message })
        [void](& $RequestInvoker 'PATCH' "$ApiBase/repos/$Owner/$Repository/issues/$($duplicate.number)" $headers @{ state = 'closed'; state_reason = 'duplicate' })
    }
}

function Sync-LogIssue {
    param(
        [string]$ApiBase = 'https://api.github.com', [string]$Owner, [string]$Repository, [string]$Token,
        [string]$Fingerprint, [string]$Title, [string]$Body, [string]$FindingOwner,
        [string]$LogLabel = 'Log', [string]$ExternalLabel = 'External',
        [scriptblock]$RequestInvoker = ${function:Invoke-DefaultGitHubRequest}
    )
    # Keep a one-label result as an array in the GitHub request JSON.
    $requiredLabels = @(Get-IssueLabels $FindingOwner $LogLabel $ExternalLabel)
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $bodyChunks = @(Split-Utf8Text $Body 50000)
    $matches = @(Find-GitHubIssuesByFingerprint $ApiBase $Owner $Repository $Fingerprint $Token $RequestInvoker | Sort-Object number)
    if ($matches.Count -eq 0) {
        $created = & $RequestInvoker 'POST' "$ApiBase/repos/$Owner/$Repository/issues" $headers @{ title = $Title; body = $bodyChunks[0]; labels = $requiredLabels }
        for ($chunkIndex = 1; $chunkIndex -lt $bodyChunks.Count; $chunkIndex++) {
            $chunkHash = Get-Sha256Text $bodyChunks[$chunkIndex]
            $commentBody = "<!-- log-chunk: $Fingerprint-$chunkIndex-$chunkHash -->`n$($bodyChunks[$chunkIndex])"
            [void](& $RequestInvoker 'POST' "$ApiBase/repos/$Owner/$Repository/issues/$($created.number)/comments" $headers @{ body = $commentBody })
        }
        $afterCreate = @(Find-GitHubIssuesByFingerprint $ApiBase $Owner $Repository $Fingerprint $Token $RequestInvoker | Sort-Object number)
        if ($afterCreate.Count -gt 0) {
            $canonicalAfterCreate = Set-IssueLabels $afterCreate[0] $requiredLabels $ApiBase $Owner $Repository $Token $RequestInvoker
            if ($afterCreate.Count -gt 1) { Close-DuplicateLogIssues $canonicalAfterCreate @($afterCreate | Select-Object -Skip 1) $ApiBase $Owner $Repository $Token $requiredLabels $RequestInvoker }
            $action = if ([int]$canonicalAfterCreate.number -eq [int]$created.number) { 'created' } else { 'created-conflict-recovered' }
            return [pscustomobject]@{ action = $action; issue = $canonicalAfterCreate; commented = ($bodyChunks.Count -gt 1) }
        }
        return [pscustomobject]@{ action = 'created'; issue = $created; commented = ($bodyChunks.Count -gt 1) }
    }
    $canonical = $matches[0]
    if ($matches.Count -gt 1) { Close-DuplicateLogIssues $canonical @($matches | Select-Object -Skip 1) $ApiBase $Owner $Repository $Token $requiredLabels $RequestInvoker }
    $canonical = Set-IssueLabels $canonical $requiredLabels $ApiBase $Owner $Repository $Token $RequestInvoker
    if ([string]$canonical.state -eq 'closed') {
        return Resolve-ClosedLogIssue $canonical $Fingerprint $bodyChunks $ApiBase $Owner $Repository $Token $RequestInvoker
    }
    return [pscustomobject]@{ action = 'existing-open'; issue = $canonical; commented = $false }
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-GitHubAppJwt {
    param([string]$AppId, [string]$PrivateKeyPath, [string]$OpenSslPath = '')
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
    $payloadJson = @{ iat = $now - 60; exp = $now + 540; iss = [string]$AppId } | ConvertTo-Json -Compress
    $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payloadJson))
    $unsigned = "$header.$payload"
    if ([string]::IsNullOrWhiteSpace($OpenSslPath)) {
        $command = Get-Command openssl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { $OpenSslPath = $command.Source }
        if ([string]::IsNullOrWhiteSpace($OpenSslPath)) {
            $candidate = 'C:\Program Files\Git\usr\bin\openssl.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $OpenSslPath = $candidate }
        }
    }
    if ([string]::IsNullOrWhiteSpace($OpenSslPath) -or -not (Test-Path -LiteralPath $OpenSslPath -PathType Leaf)) {
        throw 'OpenSSL was not found. Configure github.openSslPath.'
    }
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('mc-launcher-jwt-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    $inputPath = Join-Path $temporaryDirectory 'jwt.txt'; $signaturePath = Join-Path $temporaryDirectory 'jwt.sig'
    try {
        [IO.File]::WriteAllBytes($inputPath, [Text.Encoding]::ASCII.GetBytes($unsigned))
        & $OpenSslPath dgst -sha256 -sign $PrivateKeyPath -out $signaturePath $inputPath | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $signaturePath -PathType Leaf)) { throw 'OpenSSL could not sign the GitHub App JWT.' }
        return "$unsigned.$(ConvertTo-Base64Url ([IO.File]::ReadAllBytes($signaturePath)))"
    } finally {
        if (Test-Path -LiteralPath $temporaryDirectory) { Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force }
    }
}

function Get-GitHubInstallationToken {
    param([hashtable]$GitHub, [scriptblock]$RequestInvoker = ${function:Invoke-DefaultGitHubRequest})
    $jwt = New-GitHubAppJwt ([string]$GitHub.appId) ([string]$GitHub.privateKeyPath) ([string]$GitHub.openSslPath)
    $headers = @{ Authorization = "Bearer $jwt"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $response = & $RequestInvoker 'POST' "$($GitHub.apiBase)/app/installations/$($GitHub.installationId)/access_tokens" $headers @{}
    return [string]$response.token
}

function Get-GitHubCliPath {
    param([string]$GhPath = '')
    if ([string]::IsNullOrWhiteSpace($GhPath)) {
        $command = Get-Command gh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) { $command = Get-Command gh -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if ($null -ne $command) { $GhPath = [string]$command.Source }
    }
    if ([string]::IsNullOrWhiteSpace($GhPath) -or -not (Test-Path -LiteralPath $GhPath -PathType Leaf)) { throw 'GitHub CLI was not found. Install gh or configure github.ghPath.' }
    return [IO.Path]::GetFullPath($GhPath)
}

function Get-GitHubCliToken {
    param([string]$GhPath = '')
    $GhPath = Get-GitHubCliPath $GhPath
    $output = @(& $GhPath auth token 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { throw 'GitHub CLI is not authenticated. Run gh auth login for this Windows user.' }
    $token = ([string]$output[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'GitHub CLI returned an empty token.' }
    return $token
}

function Invoke-GitHubCliRequest {
    param(
        [Parameter(Mandatory = $true)][string]$GhPath,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers,
        [object]$Body
    )
    $GhPath = Get-GitHubCliPath $GhPath
    $uriObject = [Uri]$Uri
    $endpoint = $uriObject.PathAndQuery
    $cliArguments = @('api', $endpoint, '--method', $Method.ToUpperInvariant(), '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2022-11-28')
    $temporaryPath = ''
    try {
        if ($null -ne $Body) {
            $temporaryPath = Join-Path ([IO.Path]::GetTempPath()) ('mc-launcher-gh-' + [Guid]::NewGuid().ToString('N') + '.json')
            [IO.File]::WriteAllText($temporaryPath, ($Body | ConvertTo-Json -Depth 20 -Compress), (New-Object Text.UTF8Encoding($false)))
            $cliArguments += @('--input', $temporaryPath)
        }
        $output = @(& $GhPath @cliArguments 2>&1 | ForEach-Object { $_.ToString() })
        if ($LASTEXITCODE -ne 0) { throw (($output -join [Environment]::NewLine).Trim()) }
        if ($output.Count -eq 0 -or [string]::IsNullOrWhiteSpace(($output -join ''))) { return $null }
        return ($output -join [Environment]::NewLine) | ConvertFrom-Json
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($temporaryPath) -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

function Get-GitHubAccessToken {
    param(
        [Parameter(Mandatory = $true)][hashtable]$GitHub,
        [scriptblock]$RequestInvoker = ${function:Invoke-DefaultGitHubRequest},
        [scriptblock]$CliTokenProvider = ${function:Get-GitHubCliToken},
        [scriptblock]$AppTokenProvider = ${function:Get-GitHubInstallationToken}
    )
    $mode = [string]$GitHub.authMode
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'GitHubApp' }
    switch ($mode) {
        'GitHubCli' { return (& $CliTokenProvider ([string]$GitHub.ghPath)) }
        'GitHubApp' { return (& $AppTokenProvider $GitHub $RequestInvoker) }
        default { throw "Unsupported GitHub authentication mode: $mode" }
    }
}

function Test-ChildPath {
    param([string]$Parent, [string]$Child)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [IO.Path]::GetFullPath($Child)
    return $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)
}

function Test-DirectChildPath {
    param([string]$Parent, [string]$Child)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $childFull = [IO.Path]::GetFullPath($Child).TrimEnd('\')
    return (Split-Path -Parent $childFull).Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)
}

function Sync-DirectoryMirror {
    param([string]$Source, [string]$Destination, [string]$AllowedRoot)
    if (-not (Test-ChildPath $AllowedRoot $Destination)) { throw "Unsafe mirror destination: $Destination" }
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Mirror source not found: $Source" }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
    $sourceRoot = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $sourceRelative = @{}
    foreach ($file in Get-ChildItem -File -Recurse -LiteralPath $sourceRoot) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $sourceRelative[$relative] = $file
        $target = Join-Path $destinationRoot $relative
        $targetParent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) { New-Item -ItemType Directory -Force -Path $targetParent | Out-Null }
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileSha256 $file.FullName) -cne (Get-FileSha256 $target)) {
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        }
    }
    foreach ($file in Get-ChildItem -File -Recurse -LiteralPath $destinationRoot) {
        $relative = $file.FullName.Substring($destinationRoot.Length).TrimStart('\')
        if (-not $sourceRelative.ContainsKey($relative)) { Remove-Item -LiteralPath $file.FullName -Force }
    }
}

function Resolve-Java8 {
    param([string]$ConfiguredPath = '')
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) { [void]$candidates.Add($ConfiguredPath) }
    foreach ($variableName in @('JAVA8_HOME', 'JAVA_HOME')) {
        $home = [Environment]::GetEnvironmentVariable($variableName)
        if (-not [string]::IsNullOrWhiteSpace($home)) { [void]$candidates.Add((Join-Path $home 'bin\java.exe')) }
    }
    foreach ($command in @(Get-Command java.exe -All -ErrorAction SilentlyContinue)) { [void]$candidates.Add([string]$command.Source) }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        $path = $candidate
        if (Test-Path -LiteralPath $candidate -PathType Container) { $path = Join-Path $candidate 'bin\java.exe' }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $processInfo = New-Object Diagnostics.ProcessStartInfo
        $processInfo.FileName = [IO.Path]::GetFullPath($path)
        $processInfo.Arguments = '-version'
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $processInfo
        try {
            [void]$process.Start()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $lines = @($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($process.ExitCode -eq 0 -and ($lines -join "`n") -match 'version\s+"1\.8\.') { return [IO.Path]::GetFullPath($path) }
        } catch {} finally { $process.Dispose() }
    }
    return ''
}

function ConvertTo-NativeArgumentLine {
    param([AllowEmptyCollection()][object[]]$Arguments = @())
    $quoted = New-Object 'System.Collections.Generic.List[string]'
    foreach ($argument in $Arguments) {
        if ($argument -isnot [string]) { throw 'Each process argument must be a string. Check java.arguments in settings.' }
        if ($argument.Length -gt 0 -and $argument -notmatch '[\s"]') {
            [void]$quoted.Add($argument)
            continue
        }
        # Double backslashes before a quote or the closing quote, using the
        # Windows native argument rules. Do not invoke a shell.
        $escaped = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        [void]$quoted.Add('"' + $escaped + '"')
    }
    return $quoted.ToArray() -join ' '
}

function Start-LauncherProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyCollection()][object[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [switch]$RedirectStandardStreams
    )
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = ConvertTo-NativeArgumentLine -Arguments $Arguments
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = [bool]$RedirectStandardStreams
    $info.RedirectStandardInput = [bool]$RedirectStandardStreams
    $info.RedirectStandardOutput = [bool]$RedirectStandardStreams
    $info.RedirectStandardError = [bool]$RedirectStandardStreams
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "Could not start process: $FilePath" }
        [void]$process.Handle
        return $process
    } catch {
        $process.Dispose()
        throw
    }
}

function Test-ServerClassPath {
    param([Parameter(Mandatory = $true)][string]$JarPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        $entry = $zip.GetEntry('META-INF/MANIFEST.MF')
        if ($null -eq $entry) { throw "Server JAR manifest is missing: $JarPath" }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { $manifest = $reader.ReadToEnd() -replace '\r?\n ', '' } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    if ($manifest -match '(?m)^Class-Path:\s*([^\r\n]+)') {
        $jarDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($JarPath))
        foreach ($relative in ($Matches[1].Trim() -split '\s+')) {
            $dependency = Join-Path $jarDirectory ([Uri]::UnescapeDataString($relative))
            if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) { [void]$missing.Add($dependency) }
        }
    }
    if ($missing.Count -gt 0) { throw ('Server Class-Path dependency missing: ' + ($missing.ToArray() -join ', ')) }
    return $true
}

function Test-PortAvailable {
    param([int]$Port, [string]$Address = '127.0.0.1')
    $listener = $null
    try {
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse($Address), $Port)
        $listener.Start()
        return $true
    } catch { return $false }
    finally { if ($null -ne $listener) { try { $listener.Stop() } catch {} } }
}

function Get-ModJarInventory {
    param([Parameter(Mandatory = $true)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return @() }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $inventory = New-Object System.Collections.Generic.List[object]
    foreach ($file in Get-ChildItem -File -LiteralPath $Directory -Filter '*.jar') {
        $modIds = New-Object System.Collections.Generic.List[string]
        $versions = New-Object System.Collections.Generic.List[string]
        try {
            $zip = [IO.Compression.ZipFile]::OpenRead($file.FullName)
            try {
                $entry = $zip.GetEntry('mcmod.info')
                if ($null -ne $entry) {
                    $reader = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
                    try { $metadata = ConvertTo-HashtableDeep (($reader.ReadToEnd()) | ConvertFrom-Json) } finally { $reader.Dispose() }
                    $records = if ($metadata -is [hashtable] -and $metadata.ContainsKey('modList')) { @($metadata.modList) } else { @($metadata) }
                    foreach ($record in $records) {
                        if ($record -is [hashtable] -and $record.ContainsKey('modid')) { [void]$modIds.Add([string]$record.modid) }
                        if ($record -is [hashtable] -and $record.ContainsKey('version')) { [void]$versions.Add([string]$record.version) }
                    }
                }
                if ($modIds.Count -eq 0) {
                    $manifest = $zip.GetEntry('META-INF/MANIFEST.MF')
                    if ($null -ne $manifest) {
                        $reader = New-Object IO.StreamReader($manifest.Open(), [Text.Encoding]::UTF8)
                        try { $manifestText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                        if ($manifestText -match '(?m)^Implementation-Title:\s*(?<id>.+)$') { [void]$modIds.Add($Matches['id'].Trim()) }
                        if ($manifestText -match '(?m)^Implementation-Version:\s*(?<version>.+)$') { [void]$versions.Add($Matches['version'].Trim()) }
                    }
                }
            } finally { $zip.Dispose() }
        } catch {}
        [void]$inventory.Add([pscustomobject]@{
            path = $file.FullName; name = $file.Name
            sha256 = Get-FileSha256 $file.FullName
            modIds = @($modIds | Sort-Object -Unique); versions = @($versions | Sort-Object -Unique)
        })
    }
    return $inventory.ToArray()
}

function Test-ModInventoryMatch {
    param(
        [object[]]$ServerInventory, [object[]]$ClientInventory,
        [string[]]$ServerOnlyModIds = @(), [string[]]$ClientOnlyModIds = @(),
        [string[]]$ServerOnlyJarHashes = @(), [string[]]$ClientOnlyJarHashes = @()
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $clientHashes = @($ClientInventory | ForEach-Object { $_.sha256 })
    $serverHashes = @($ServerInventory | ForEach-Object { $_.sha256 })
    foreach ($jar in $ServerInventory) {
        $allowed = $jar.sha256 -in $ServerOnlyJarHashes -or @($jar.modIds | Where-Object { $_ -in $ServerOnlyModIds }).Count -gt 0
        if (-not $allowed -and $jar.sha256 -notin $clientHashes) { [void]$errors.Add("server jar is not shared or server-only: $($jar.name)") }
    }
    foreach ($jar in $ClientInventory) {
        $allowed = $jar.sha256 -in $ClientOnlyJarHashes -or @($jar.modIds | Where-Object { $_ -in $ClientOnlyModIds }).Count -gt 0
        if (-not $allowed -and $jar.sha256 -notin $serverHashes) { [void]$errors.Add("client jar is not shared or client-only: $($jar.name)") }
    }
    return $errors.ToArray()
}

function New-OutboxItem {
    param(
        [string]$ProjectRoot, [string]$SessionId, [object]$Finding, [string]$Owner,
        [string]$Fingerprint, [string]$SafeText, [object]$ServerExitCode = 'unknown',
        [string]$LogLabel = 'Log', [string]$ExternalLabel = 'External'
    )
    $id = [Guid]::NewGuid().ToString('N')
    $marker = "<!-- log-fingerprint: $Fingerprint -->"
    $titleText = ($SafeText -split "`r?`n" | Select-Object -First 1)
    if ($titleText.Length -gt 100) { $titleText = $titleText.Substring(0, 100) }
    $labels = @(Get-IssueLabels $Owner $LogLabel $ExternalLabel)
    $safeSource = if ([string]::IsNullOrWhiteSpace([string]$Finding.sourcePath)) { '<unknown>' } else { [IO.Path]::GetFileName([string]$Finding.sourcePath) }
    $body = @(
        $marker
        ''
        '## Automated log inspection'
        ''
        "- Session: ``$SessionId``"
        "- Severity: ``$($Finding.severity)``"
        "- Owner: ``$Owner``"
        "- Source: ``$safeSource``"
        "- Server exit code: ``$ServerExitCode``"
        ''
        '```text'
        $SafeText
        '```'
    ) -join "`n"
    $item = [ordered]@{
        schemaVersion = 1; queueId = $id; status = 'pending'; createdAt = (Get-Date).ToUniversalTime().ToString('o')
        sessionId = $SessionId; fingerprint = $Fingerprint; owner = $Owner; labels = $labels
        title = "[Automated Log][$($Finding.severity.ToUpperInvariant())] $titleText"; body = $body; attempts = 0; nextAttemptAt = $null
    }
    $path = Join-Path $ProjectRoot "state\outbox\$id.json"
    Write-AtomicJson $path $item
    return [pscustomobject]@{ path = $path; value = $item }
}

function Protect-QuarantineData {
    param([string]$ProjectRoot, [string]$SessionId, [string]$Text, [string[]]$Reasons)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $encrypted = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $path = Join-Path $ProjectRoot ("state\quarantine\{0}-{1}.bin" -f $SessionId, [Guid]::NewGuid().ToString('N'))
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllBytes($path, $encrypted)
    Write-AtomicJson ($path + '.json') ([ordered]@{ sessionId = $SessionId; status = 'manual-required'; reasons = @($Reasons); createdAt = (Get-Date).ToUniversalTime().ToString('o') })
    return $path
}

function Get-PendingOutboxItems {
    param([string]$ProjectRoot)
    $directory = Join-Path $ProjectRoot 'state\outbox'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return @() }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($file in Get-ChildItem -File -LiteralPath $directory -Filter '*.json') {
        $value = Read-JsonHashtable $file.FullName
        if ([string]$value.status -notin @('pending', 'sending')) { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$value.nextAttemptAt)) {
            try { if ([DateTimeOffset]::Parse([string]$value.nextAttemptAt) -gt [DateTimeOffset]::UtcNow) { continue } } catch {}
        }
        [void]$items.Add([pscustomobject]@{ path = $file.FullName; value = $value })
    }
    return $items.ToArray()
}

Export-ModuleMember -Function *
