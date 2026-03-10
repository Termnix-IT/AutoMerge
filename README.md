# AutoMerge_Readme

## 使い方
1.AutoMerge.txt を Compare-ShowLogs_ByIP.ps1 として保存
2.ログを デスクトップ\ログ保管 に配置 （命名規則：YYMMDD_HHMMSS_IP_from_ユーザー.log）
3.PowerShell でスクリプトのあるフォルダに移動して実行


# もっとも新しい同一IPの最新ログを起点に比較
.\Compare-ShowLogs_ByIP.ps1

## オプション例
・特定のファイルを起点にする
.\Compare-ShowLogs_ByIP.ps1 -CurrentFile "$env:USERPROFILE\Desktop\ログ保管\260212_083000_10.51.192.216_from_i-taga3e-v.log"

・IPを指定してそのIPの最新ログを起点にする
.\Compare-ShowLogs_ByIP.ps1 -TargetIP "10.51.192.216"

・許容誤差を変更
# 1日前は ±24h、1週間前は ±72h で探す
.\Compare-ShowLogs_ByIP.ps1 -OneDayToleranceHours 24 -OneWeekToleranceHours 72

