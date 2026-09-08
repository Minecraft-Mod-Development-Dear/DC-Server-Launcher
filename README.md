Minecraft Forge 1.12.2で動くDimensional Container（DC）サーバーを起動し、
停止後のログを確認するWindows用デバッグツールです。GitHub連携を有効にすると、
検出結果をGitHub Issueへ記録できます。

このリポジトリに含まれるのはランチャーだけです。
サーバー、クライアント、DC本体、その他のMod、Javaは利用者が用意してください。

## 主な機能

- サーバー設定、必要ファイル、ポート、Mod構成を起動前に確認する
- 既存サーバーを使うNormal起動と、検証用環境を作るCreative起動を使い分ける
- 今回の起動で追加されたログとクラッシュレポートを停止後に確認する
- 検出結果をローカルへ保存し、GitHub連携が有効ならIssueへ送る

## 必要なもの

| 用意するもの | 用途 |
| --- | --- |
| Windows PowerShell 5.1またはPowerShell 7 |  |
| Java 8 | Forgeサーバー用 |
| Minecraft 1.12.2のForgeサーバー |  |
| DC本体と必要なMod |  |
| GitHub CLIまたはGitHub App | Issue連携を使う場合は必要 |

MinecraftまたはForgeのバージョンが異なる環境は対象外です。

## セットアップ

### 1. ランチャーを配置する

GitHubの `Code` → `Download ZIP` からダウンロードし、任意のフォルダへ
展開します。

展開後、次のファイルがあることを確認します。

```text
Start-Normal.cmd
Start-Debug-Creative.cmd
config\settings.json
config\settings.local.example.json
src\Invoke-Server.ps1
src\Launcher.Core.psm1
```

### 2. サーバー資材を用意する

初期設定では、展開先の `server` を使います。

```text
展開先\
├─ server\
│  ├─ forge-1.12.2-14.23.5.2864.jar
│  ├─ minecraft_server.1.12.2.jar
│  ├─ eula.txt
│  ├─ server.properties
│  ├─ libraries\
│  ├─ mods\
│  └─ config\
├─ Start-Normal.cmd
└─ Start-Debug-Creative.cmd
```

Forge JARの名前が例と異なる場合は、次の手順で `serverJar` を設定します。<br>
サーバーを別の場所に置く場合も、端末別設定で絶対パスを指定できます。

### 3. 端末別設定を作る

`config/settings.local.example.json` をコピーし、同じフォルダへ
`settings.local.json` という名前で保存します。

```powershell
Copy-Item config\settings.local.example.json config\settings.local.json
```

エクスプローラーを使う場合は、コピーしたファイル名から `.example` を
削除してください。<br>続けて、`C:\path\to\...` の例を実際のパスへ
置き換えます。

| 設定 | 内容 |
| --- | --- |
| `java.path` | Java 8の `java.exe`。空欄ならPATHなどから検索する |
| `client.logsDirectory` | Minecraftクライアントの `logs` フォルダ |
| `client.modsDirectory` | Minecraftクライアントの `mods` フォルダ |
| `profiles.Normal.serverDirectory` | Normalで使うサーバーフォルダ |
| `profiles.Normal.serverJar` | Normalで使うForge JARのファイル名 |
| `profiles.Creative.sourceServerDirectory` | Creativeへ同期する元のサーバーフォルダ |
| `profiles.Creative.serverJar` | Creativeで使うForge JARのファイル名 |
| `profiles.Creative.minecraftServerJar` | vanilla server JARのファイル名 |

DCのパッケージ名やロガー名を変更した環境では、`detection` も上書きします。
通常は初期値のままで構いません。

### 4. サーバー設定を確認する

Normalの初期値は次のとおりです。

| 項目 | 初期値 |
| --- | --- |
| ゲームモード | Survival（`gamemode=0`） |
| 強制ゲームモード | 無効（`force-gamemode=false`） |
| 接続先 | `127.0.0.1:25565` |
| ワールドタイプ | `DEFAULT` |

Normalでは `server.properties` を変更しません。実際の値が初期値と異なる場合は、
`settings.local.json` の `profiles.Normal.expectedProperties` で期待値を
上書きしてください。一致しないまま起動すると、サーバーを開始せずに終了します。

`eula.txt` も必要です。Minecraftの利用規約を確認し、同意する場合だけ
`eula=true` にしてください。

### 5. GitHub Issue連携を設定する

Issue連携を使わない場合、この手順は不要です。初期状態では
`github.enabled` が `false` になっています。

連携する場合は、`settings.local.json` の `github` を設定します。

| 設定 | 内容 |
| --- | --- |
| `github.enabled` | `true` にすると検出結果をIssueへ送る |
| `github.authMode` | `GitHubCli` または `GitHubApp` |
| `github.ghPath` | GitHub CLIのパス。PATHから見つかる場合は空欄でもよい |
| `github.owner` | Issueを作成するアカウントまたは組織 |
| `github.repository` | Issueを作成するリポジトリ |
| `github.logLabel` | ログIssueに付けるラベル |
| `github.externalLabel` | 外部ModのIssueに追加するラベル |

GitHub CLIを使う場合は、ランチャーを実行するWindowsユーザーで認証します。

```powershell
gh auth login
```

GitHub Appを使う場合は、`appId`、`installationId`、
`privateKeyPath` を設定します。<br>OpenSSLを自動検出できない場合は、
`openSslPath` も設定してください。

## 起動方法

| 起動方法 | 実行するファイル | 用途 |
| --- | --- | --- |
| Normal | `Start-Normal.cmd` | 既存のサーバーをそのまま起動する |
| Creative | `Start-Debug-Creative.cmd` | 検証用サーバーと新しいワールドを作って起動する |

### Normal

`Start-Normal.cmd` をダブルクリックします。初期設定の接続先は
`127.0.0.1:25565` です。

起動前チェックに失敗した場合は、表示された項目を直してから再実行します。
Normalは `server.properties` やワールドを変更しません。

### Creative

`Start-Debug-Creative.cmd` をダブルクリックします。初期設定の接続先は
`127.0.0.1:25566` です。

Creativeは、Normalのサーバーから次の資材を
`runtime\creative-server` へ同期します。

- `libraries`
- `mods`
- `config`
- Forge JAR
- vanilla server JAR
- `eula.txt`
- `server.properties`

同期後、Creative用の値を `server.properties` に設定します。
Creative用ワールドは起動前に削除し、毎回作り直します。
`profiles.Creative.serverDirectory` には、本番サーバーではなく
`runtime` 配下の専用フォルダを指定してください。

### 停止する

サーバーのコンソールで `/stop` を実行します。サーバー終了後、
ランチャーがログとクラッシュレポートを確認します。

コマンドラインから一時停止を省略する場合は、`-NoPause` を付けます。

```text
Start-Normal.cmd -NoPause
Start-Debug-Creative.cmd -NoPause
```

## ログとIssue

検出結果は、まず `state\outbox` に保存されます。GitHub連携が無効な場合は、
送信せずローカルに残します。

同じ内容のIssueがある場合は、フィンガープリントを使って再利用します。
`not_planned` または `duplicate` で閉じたIssueは再オープンしません。
それ以外の理由で閉じたIssueは再オープンし、再発内容をコメントします。
重複して作成されたIssueは1件を残し、他を `duplicate` で閉じます。

## 設定とログの扱い

次のファイルやフォルダには、ローカルパス、ログ、認証情報などが含まれる
場合があります。再配布時は注意してください。

- `config/settings.local.json`
- `config/redaction.local.json`
- `server/`
- `runtime/`
- `state/`
- GitHub Appの秘密鍵

追加で隠したい固定文字列がある場合は、`config/redaction.example.json` を
`config/redaction.local.json` へコピーします。<br>固定文字列は
`redactLiterals` に追加してください。<br>Issue連携の有効化前に、
`state\outbox` を開き、公開できない情報が残っていないか確認してください。

## 困ったとき

| 表示や症状 | 確認すること |
| --- | --- |
| Java 8が見つからない | `java.path` がJava 8の `java.exe` を指しているか |
| 必須ファイルが見つからない | サーバーパス、JAR名、`server.properties`、`eula.txt` |
| EULA未同意と表示される | `eula.txt` があり、同意後に `eula=true` と設定したか |
| `server.properties` が一致しない | `expectedProperties` と実際の値が一致しているか |
| ポートが使用中と表示される | 同じポートを使うサーバーやアプリが動いていないか |
| Mod構成が一致しない | サーバーとクライアントのMod、`mods` 内の専用Mod許可設定 |
| Creativeの同期に失敗する | 同期元に必要なフォルダ、JAR、設定ファイルがそろっているか |
| Issueが作成されない | GitHub連携、認証、連携先、ラベル、ネットワーク、API利用制限 |

起動前エラーではJavaを開始しません。表示されたエラーメッセージと
`[RESULT] toolExitCode` を確認してください。

## 質問・不具合報告

ランチャーの質問や不具合は、リポジトリの[Issues](../../issues)で報告できます。
次の情報を添えてください。

- NormalとCreativeのどちらで発生したか
- エラーメッセージと `[RESULT] toolExitCode`
- Minecraft、Forge、Javaのバージョン
- 再現手順

ログを添付する場合は、認証情報、個人情報、ローカルパスを削除してください。
`settings.local.json` と秘密鍵は添付しないでください。

## 開発者の方へ
PR本文に次の内容を記載してください。

- 変更内容と目的
- 変更に対して実施したテスト内容と結果（未実施の場合はその旨）
- 未確認の項目があれば、その内容
- 関連Issueがあれば、その番号やURL

設定や動作を変更する場合は、READMEまたは設定例も更新してください。
サーバー、Mod、ログ、端末別設定、秘密鍵はPRに含めないでください。

<br>
Built with GPT-5
