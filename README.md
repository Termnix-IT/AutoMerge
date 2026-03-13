# AutoMerge

Cisco の `show` コマンドで取得したログを、同一 IP 単位で比較する PowerShell スクリプトです。

ログファイルは次の命名規則を前提としています。

```text
YYMMDD_HHMMSS_IP_from_USER.log
```

このスクリプトは、対象 IP の最新ログを基準にして、おおむね 1 日前と 1 週間前のログを自動選定し、差分レポートを出力します。

## 主な機能

- Windows PowerShell 5.1 / PowerShell 7+ に対応
- ファイル名に含まれる日時を使って比較対象を自動選定
- LCS ベースの差分比較により、途中の行追加・削除でも差分が崩れにくい
- ノイズ行を除外しても元の行番号を保持
- `-CurrentFile` または `-TargetIP` で比較起点を明示可能
- UTF-8 のテキストレポートを出力

## 動作要件

- Windows PowerShell 5.1 以上、または PowerShell 7 以上
- ログファイルが UTF-8 で保存されていること

## 使い方

既定値で実行する場合:

```powershell
.\Compare-ShowLogs_ByIP.ps1
```

特定 IP の最新ログを基準にする場合:

```powershell
.\Compare-ShowLogs_ByIP.ps1 -TargetIP "10.51.192.216"
```

特定ファイルを基準にする場合:

```powershell
.\Compare-ShowLogs_ByIP.ps1 -CurrentFile "$env:USERPROFILE\Desktop\ログ保管\260212_083000_10.51.192.216_from_admin.log"
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

## 注意事項

- 命名規則に一致しないファイルはスキップされます。
- 許容誤差内に比較対象が見つからない場合、そのレポートは生成されません。
- 現在は UTF-8 でログを読み込みます。別の文字コードを使う環境では、スクリプト内の `Get-Content` の指定を調整してください。

## ライセンス

MIT License
