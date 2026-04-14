# AutoMerge

Cisco の `show` コマンドで取得したログを、同一 IP 単位で比較する PowerShell スクリプトです。

もともとは、Tera Term マクロで取得した日課点検ログの確認を想定して作成しています。特に [Termnix-IT/Teratarm_macro](https://github.com/Termnix-IT/Teratarm_macro) のような、Cisco 系機器へ接続して複数の `show` コマンドを自動実行するマクロから取得したログの比較を主な用途としています。

ログファイルは次の命名規則を前提としています。

```text
YYMMDD_HHMMSS_IP_from_USER.log
```

このスクリプトは、対象 IP の最新ログを基準にして、おおむね 1 日前と 1 週間前のログを自動選定し、差分レポートを出力します。

## 主な機能

- Windows PowerShell 5.1 / PowerShell 7+ に対応
- Tera Term マクロで取得した日課点検ログの比較を想定
- ファイル名に含まれる日時を使って比較対象を自動選定
- LCS ベースの差分比較により、途中の行追加・削除でも差分が崩れにくい
- 比較前に共通の先頭・末尾ブロックを除外し、大きなログでも差分計算を軽量化
- ノイズ行を除外しても元の行番号を保持
- 1 行ログや空に近いログでも安定して処理可能
- `-CurrentFile` または `-TargetIP` で比較起点を明示可能
- UTF-8 のテキストレポートを出力

## 動作要件

- Windows PowerShell 5.1 以上、または PowerShell 7 以上
- ログファイルが UTF-8 で保存されていること
- 必要に応じて、Tera Term マクロなどで対象機器から `show` コマンドのログを事前取得していること

## 想定しているログ取得元

このスクリプトは、手動取得したログだけでなく、Tera Term マクロで日常的に採取したログを比較する用途を想定しています。

想定例:

- [Termnix-IT/Teratarm_macro](https://github.com/Termnix-IT/Teratarm_macro)

上記リポジトリの README では、Cisco 系機器へログイン後に `enable` 実行済みの状態で、複数の `show` コマンドを自動取得する簡易マクロであることが説明されています。そこから保存したログを、本スクリプトで日次・週次比較する運用を想定しています。

## 使い方

詳細な手順は [使い方.md](C:\Users\lugep\デスクトップ\Google Drive\ProjectFolder\AutoMerge\使い方.md) を参照してください。

既定値で実行する場合:

```powershell
.\Compare-ShowLogs_ByIP.ps1
```

特定 IP の最新ログを基準にする場合:

```powershell
.\Compare-ShowLogs_ByIP.ps1 -TargetIP "10.0.0.1"
```

特定ファイルを基準にする場合:

```powershell
.\Compare-ShowLogs_ByIP.ps1 -CurrentFile "$env:USERPROFILE\Desktop\ログ保管\260212_083000_10.0.0.1_from_admin.log"
```

差分対象からノイズ行を除外する場合:

```powershell
.\Compare-ShowLogs_ByIP.ps1 -IgnorePattern '^\s*$', 'uptime', 'Last input'
```

サブディレクトリも再帰的に検索する場合:

```powershell
.\Compare-ShowLogs_ByIP.ps1 -Recurse
```

比較対象の許容誤差を変更する場合:

```powershell
.\Compare-ShowLogs_ByIP.ps1 -OneDayToleranceHours 24 -OneWeekToleranceHours 72
```

## 既定パス

- ログ格納先: `$HOME\Desktop\ログ保管`
- 出力先: `<LogDirectory>\出力`

## 出力

出力先フォルダには、条件に応じて次のレポートが生成されます。

- `diff_1day_<base>_<timestamp>.txt`
- `diff_1week_<base>_<timestamp>.txt`

また、スクリプトはパイプラインへ次の情報を返します。

```text
OutputPath
ChangeCount
```

レポート本文の見出しは日本語で出力されます。主な表記は次の通りです。

- `変更種別`
- `現在行番号`
- `現在行テキスト`
- `比較先行番号`
- `比較先行テキスト`
- `変更件数合計`

## 注意事項

- 命名規則に一致しないファイルはスキップされます。
- 許容誤差内に比較対象が見つからない場合、そのレポートは生成されません。
- 現在は UTF-8 でログを読み込みます。別の文字コードを使う環境では、スクリプト内の `Get-Content` の指定を調整してください。
- 差分アルゴリズムは LCS ベースです。共通の先頭・末尾を事前に除外して計算量を抑えていますが、極端に巨大なログ同士では実行時間が長くなる場合があります。

## 検証

ローカルでは次の確認を推奨します。

```powershell
# 構文チェック
[System.Management.Automation.Language.Parser]::ParseFile(".\Compare-ShowLogs_ByIP.ps1", [ref]$null, [ref]$null)

# サンプル比較の実行
.\Compare-ShowLogs_ByIP.ps1 -LogDirectory ".\tmp\logs" -OutputDirectory ".\tmp\out" -TargetIP "10.0.0.1"
```

GitHub Actions では [`.github/workflows/powershell.yml`](C:\Users\lugep\デスクトップ\Google Drive\ProjectFolder\AutoMerge\.github\workflows\powershell.yml) で構文チェックと回帰テストを実行します。

## ライセンス

MIT License
