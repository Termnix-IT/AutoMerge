<#
.SYNOPSIS
  ファイル名の日時(YYMMDD_HHMMSS)を用いて、最新ログと 1日前 / 1週間前のログを比較し、差分を出力します。

.FILENAME FORMAT
  YYMMDD_HHMMSS_<IP>_from_<USER>.log
  例: 260113_141553_10.51.192.216_from_i-taga3e-v.log

.PARAMETER LogDirectory
  既定: デスクトップ\ログ保管

.PARAMETER OutputDirectory
  既定: LogDirectory\出力

.PARAMETER OneDayToleranceMinutes
  1日前ファイルを探す際の許容誤差（分）。既定: 24*60 (= 1440分)

.PARAMETER OneWeekToleranceMinutes
  1週間前ファイルを探す際の許容誤差（分）。既定: 2*24*60 (= 2880分) ※週次採取でズレを考慮
#>

param(
  [string]$LogDirectory,
  [string]$OutputDirectory,
  [int]$OneDayToleranceMinutes = 24*60,
  [int]$OneWeekToleranceMinutes = 2*24*60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-DefaultPaths {
  $desktop = [Environment]::GetFolderPath('Desktop')
  if (-not $LogDirectory) {
    $script:LogDirectory = Join-Path $desktop 'ログ保管'
  }
  if (-not $OutputDirectory) {
    $script:OutputDirectory = Join-Path $LogDirectory '出力'
  }
}

function Ensure-OutputDir {
  if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
  }
}

# 命名規則のパース: YYMMDD_HHMMSS_IP_from_USER.log
function Parse-LogName {
  param([System.IO.FileInfo]$File)

  $name = $File.Name
  # 正規表現: 先頭に YYMMDD_HHMMSS、続いて IP、"from"、ユーザー
  $re = '^(?<YY>\d{2})(?<MM>\d{2})(?<DD>\d{2})_(?<hh>\d{2})(?<mm>\d{2})(?<ss>\d{2})_(?<IP>[^_]+)_from_(?<USER>.+?)\.log$'
  $m = [regex]::Match($name, $re)
  if (-not $m.Success) { return $null }

  # 年は20xx前提（26 -> 2026）
  $year = 2000 + [int]$m.Groups['YY'].Value
  $month = [int]$m.Groups['MM'].Value
  $day   = [int]$m.Groups['DD'].Value
  $hour  = [int]$m.Groups['hh'].Value
  $min   = [int]$m.Groups['mm'].Value
  $sec   = [int]$m.Groups['ss'].Value

  try {
    $dt = [datetime]::New($year,$month,$day,$hour,$min,$sec)
  } catch {
    return $null
  }

  # 抽出メタ
  [pscustomobject]@{
    File     = $File
    DateTime = $dt
    IP       = $m.Groups['IP'].Value
    User     = $m.Groups['USER'].Value
    BaseName = [IO.Path]::GetFileNameWithoutExtension($name)
  }
}

function Load-LogIndex {
  param([string]$Dir)
  $files = Get-ChildItem -Path $Dir -File -Filter '*.log' -ErrorAction Stop
  if (-not $files) { throw "ログファイル（*.log）が見つかりません: $Dir" }

  $parsed = foreach ($f in $files) {
    $p = Parse-LogName -File $f
    if ($p) { $p }
  }

  if (-not $parsed) {
    throw "命名規則に一致するファイルがありません。規則: YYMMDD_HHMMSS_IP_from_USER.log"
  }

  # 出力フォルダ内のファイルは除外
  $parsed = $parsed | Where-Object { $_.File.DirectoryName -ne $OutputDirectory }

  return $parsed
}

function Select-LatestByName {
  param([object[]]$Index)
  # DateTime が最大のもの
  $Index | Sort-Object DateTime -Descending | Select-Object -First 1
}

function Get-ClosestByTargetTime {
  param(
    [object[]]$Index,
    [datetime]$Target,
    [object]$Exclude,
    [timespan]$Tolerance
  )
  $cands = $Index | Where-Object { $_.File.FullName -ne $Exclude.File.FullName }
  if (-not $cands) { return $null }

  $sel = $cands |
    Sort-Object @{Expression = { [math]::Abs(($_.DateTime - $Target).TotalSeconds) } ; Ascending = $true } |
    Select-Object -First 1

  if ($sel -and [math]::Abs(($sel.DateTime - $Target).TotalMinutes) -le $Tolerance.TotalMinutes) {
    return $sel
  } else {
    return $null
  }
}

function Compare-FilesWithLineNumbers {
  param(
    [string]$CurrentPath,
    [string]$PastPath,
    [string]$LabelPast,
    [string]$OutputPath
  )

  $currentLines = Get-Content -LiteralPath $CurrentPath -ErrorAction Stop
  $pastLines    = Get-Content -LiteralPath $PastPath -ErrorAction Stop

  # === 無視ルールフック ===
  # 今後のカスタマイズ用：ここに Where-Object で除外条件を入れると差分ノイズを減らせます。
  # 例（コメントアウトのまま運用可）:
  # $currentLines = $currentLines | Where-Object { $_ -notmatch 'uptime|Time since last|^\s*$' }
  # $pastLines    = $pastLines    | Where-Object { $_ -notmatch 'uptime|Time since last|^\s*$' }

  $max = [math]::Max($currentLines.Count, $pastLines.Count)

  $header = @()
  $header += "=== 差分レポート ==="
  $header += "比較日時 : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  $header += "現在     : $CurrentPath"
  $header += "$LabelPast: $PastPath"
  $header += "-----------------------------"
  $headerText = ($header -join [Environment]::NewLine) + [Environment]::NewLine

  $diffCount = 0
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($headerText)

  for ($i = 0; $i -lt $max; $i++) {
    $cur = if ($i -lt $currentLines.Count) { $currentLines[$i] } else { $null }
    $pst = if ($i -lt $pastLines.Count)    { $pastLines[$i]    } else { $null }
    if ($cur -ne $pst) {
      $diffCount++
      $lineNum = $i + 1
      [void]$sb.AppendLine("行 $lineNum")
      [void]$sb.AppendLine(("  現在    : {0}" -f ($cur ?? '(行なし)')))
      [void]$sb.AppendLine(("  過去    : {0}" -f ($pst ?? '(行なし)')))
      [void]$sb.AppendLine("  -----------------------------")
    }
  }

  if ($diffCount -eq 0) {
    [void]$sb.AppendLine("差分はありませんでした。")
  } else {
    [void]$sb.AppendLine("差分行数: $diffCount")
  }

  $sb.ToString() | Out-File -LiteralPath $OutputPath -Encoding UTF8 -Force
  return $diffCount
}

# ===== メイン =====
Resolve-DefaultPaths
Ensure-OutputDir

$index = Loadありがとうございます！命名規則（`YYMMDD_HHMMSS_対象IP_from_ユーザー名.log`）に合わせて、**同一IPのログ同士**を「最新 → 1日前／1週間前」に自動マッチングして差分を出すようにスクリプトを最適化しました。  
（※無視したい行のルールは今後対応予定とのことなので、差分は素直に全行比較にしています。フィルタ条件は後から簡単に組み込めるよう関数分離しています。）

---

## できること

- `デスクトップ\ログ保管` 内のログから、**最新のファイル**（＝現在のログ）を選ぶ  
- **同一IP**の中で、**1日前**／**1週間前**に**最も近い**ログを自動選択（許容誤差つき）  
- 差分（異なる行）を **行番号つき**で `デスクトップ\ログ保管\出力\` に `diff_1day_*.txt` / `diff_1week_*.txt` として出力  
- ファイル名は `YYMMDD_HHMMSS_IP_from_ユーザー.log` をパース（IP単位の比較）

---

## スクリプト（`Compare-ShowLogs_ByIP.ps1`）

```powershell
<# 
.SYNOPSIS
  命名規則（YYMMDD_HHMMSS_IP_from_ユーザー.log）に基づき、同一IPの最新ログと
  1日前／1週間前のログを比較して差分を出力します。

.DESCRIPTION
  - ログフォルダ既定: デスクトップ\ログ保管
  - 出力フォルダ既定: ログ保管\出力
  - 「現在のログ」は同フォルダ内の最終更新が最も新しいファイル。
  - 1日前／1週間前のログは「同一IP」かつ指定時刻に最も近いファイルを選択（許容誤差あり）。
  - 差分は行番号付きでテキスト出力します。

.PARAMETER LogDirectory
  ログ保管フォルダ。既定: デスクトップ\ログ保管

.PARAMETER OutputDirectory
  出力フォルダ。既定: LogDirectory\出力

.PARAMETER CurrentFile
  現在のログを明示指定する場合に使用。
  指定した場合はそのファイル名からIPを抽出し、同一IPだけを比較対象に絞ります。

.PARAMETER OneDayToleranceHours
  1日前検索の許容誤差（時間）。既定: 36

.PARAMETER OneWeekToleranceHours
  1週間前検索の許容誤差（時間）。既定: 96

.PARAMETER TargetIP
  IPを明示的に指定して比較対象を絞る場合に使用（CurrentFile未指定時など）。

.EXAMPLE
  .\Compare-ShowLogs_ByIP.ps1

.EXAMPLE
  .\Compare-ShowLogs_ByIP.ps1 -CurrentFile "$env:USERPROFILE\Desktop\ログ保管\260212_083000_10.51.192.216_from_i-taga3e-v.log"

.EXAMPLE
  .\Compare-ShowLogs_ByIP.ps1 -TargetIP "10.51.192.216"

.NOTES
  - 無視行ルールは今後カスタマイズ予定のため、関数 Filter-NoiseLines を用意だけしています（現状は素通し）。
#>

param(
  [string]$LogDirectory,
  [string]$OutputDirectory,
  [string]$CurrentFile,
  [int]$OneDayToleranceHours = 36,
  [int]$OneWeekToleranceHours = 96,
  [string]$TargetIP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ===== ユーティリティ =====
function Resolve-DefaultPaths {
  $desktop = [Environment]::GetFolderPath('Desktop')
  $defaultLogDir = Join-Path $desktop 'ログ保管'
  $defaultOutDir = Join-Path $defaultLogDir '出力'
  if (-not $LogDirectory -or [string]::IsNullOrWhiteSpace($LogDirectory)) {
    $script:LogDirectory = $defaultLogDir
  }
  if (-not $OutputDirectory -or [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $script:OutputDirectory = $defaultOutDir
  }
}

function Ensure-OutputDir {
  if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
  }
}

# 例: 260113_141553_10.51.192.216_from_i-taga3e-v.log
#     ^^^^^^ ^^^^^^  ^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^^^^
#      YYMMDD HHMMSS       IP             USER
$NameRegex = '^(?<yy>\d{2})(?<mm>\d{2})(?<dd>\d{2})_(?<HH>\d{2})(?<MM>\d{2})(?<SS>\d{2})_(?<ip>\d{1,3}(?:\.\d{1,3}){3})_from_(?<user>.+?)\.log$'

function Parse-LogName {
  param([System.IO.FileInfo]$File)
  $m = [regex]::Match($File.Name, $NameRegex)
  if (-not $m.Success) { return $null }

  # YYMMDD HHMMSS → DateTime（世紀は曖昧だが、現実運用上 2000年以降と仮定）
  $yy = [int]$m.Groups['yy'].Value
  $century = 2000
  $year = $century + $yy
  $month = [int]$m.Groups['mm'].Value
  $day = [int]$m.Groups['dd'].Value
  $hour = [int]$m.Groups['HH'].Value
  $min  = [int]$m.Groups['MM'].Value
  $sec  = [int]$m.Groups['SS'].Value
  $dt = Get-Date -Year $year -Month $month -Day $day -Hour $hour -Minute $min -Second $sec

  [pscustomobject]@{
    File = $File
    IP   = $m.Groups['ip'].Value
    User = $m.Groups['user'].Value
    LogTime = $dt
  }
}

function Get-LogFiles {
  param([string]$Dir)
  $files = Get-ChildItem -Path $Dir -File -Filter *.log -ErrorAction Stop
  if (-not $files) { throw "ログファイル（*.log）が見つかりませんでした。パス: $Dir" }
  # 出力フォルダ配下は除外
  $files = $files | Where-Object { $_.DirectoryName -ne $OutputDirectory }
  return $files
}

function Build-Index {
  param([System.IO.FileInfo[]]$Files)
  $list = foreach ($f in $Files) {
    $p = Parse-LogName -File $f
    if ($p) { $p }
  }
  if (-not $list) { throw "命名規則に合致するログが見つかりませんでした（$NameRegex）。" }
  return ,$list
}

function Select-CurrentLog {
  param(
    [object[]]$Index,
    [string]$ExplicitFile,
    [string]$IP
  )
  if ($ExplicitFile) {
    if (-not (Test-Path -LiteralPath $ExplicitFile)) {
      throw "CurrentFile が見つかりません: $ExplicitFile"
    }
    $f = Get-Item -LiteralPath $ExplicitFile
    $p = Parse-LogName -File $f
    if (-not $p) { throw "CurrentFile が命名規則に一致しません: $($f.Name)" }
    return $p
  } else {
    $candidates = $Index
    if ($IP) { $candidates = $candidates | Where-Object { $_.IP -eq $IP } }
    if (-not $candidates) {
      if ($IP) { throw "指定IPのログが見つかりません: $IP" }
      throw "比較対象のログが見つかりません。"
    }
    # 最新（LogTime 最大）を現在ログとする
    return $candidates | Sort-Object LogTime -Descending | Select-Object -First 1
  }
}

function Get-ClosestByTime {
  param(
    [object[]]$Candidates,     # 同一IPの候補
    [datetime]$TargetTime,
    [timespan]$Tolerance,
    [object]$Exclude            # 現在ログ
  )
  $cands = $Candidates | Where-Object { $_.File.FullName -ne $Exclude.File.FullName }
  if (-not $cands) { return $null }

  $sel = $cands |
    Sort-Object @{Expression = { [math]::Abs(($_.LogTime - $TargetTime).TotalSeconds) }; Ascending = $true } |
    Select-Object -First 1

  if ($sel -and [math]::Abs(($sel.LogTime - $TargetTime).TotalHours) -le $Tolerance.TotalHours) {
    return $sel
  }
  return $null
}

# 今後のノイズ除外（現状は素通し）
function Filter-NoiseLines {
  param([string[]]$Lines)
  # ここに除外正規表現を追加予定
  return $Lines
}

function Compare-FilesWithLineNumbers {
  param(
    [string]$CurrentPath,
    [string]$PastPath,
    [string]$LabelPast,
    [string]$OutputPath
  )

  $nowInfo  = Get-Item -LiteralPath $CurrentPath
  $pastInfo = Get-Item -LiteralPath $PastPath

  $currentLines = Get-Content -LiteralPath $CurrentPath -ErrorAction Stop
  $pastLines    = Get-Content -LiteralPath $PastPath -ErrorAction Stop

  $currentLines = Filter-NoiseLines -Lines $currentLines
  $pastLines    = Filter-NoiseLines -Lines $pastLines

  $max = [math]::Max($currentLines.Count, $pastLines.Count)

  $header = @()
  $header += "=== 差分レポート（同一IP） ==="
  $header += "比較日時 : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  $header += "現在     : $($nowInfo.FullName)"
  $header += "採取時刻 : $((Get-Date $nowInfo.LastWriteTime).ToString('yyyy-MM-dd HH:mm:ss'))"
  $header += "$LabelPast: $($pastInfo.FullName)"
  $header += "採取時刻 : $((Get-Date $pastInfo.LastWriteTime).ToString('yyyy-MM-dd HH:mm:ss'))"
  $header += "-----------------------------"
  $headerText = ($header -join [Environment]::NewLine) + [Environment]::NewLine

  $diffCount = 0
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($headerText)

  for ($i = 0; $i -lt $max; $i++) {
    $cur = if ($i -lt $currentLines.Count) { $currentLines[$i] } else { $null }
    $pst = if ($i -lt $pastLines.Count)    { $pastLines[$i]    } else { $null }

    if ($cur -ne $pst) {
      $diffCount++
      $lineNum = $i + 1
      [void]$sb.AppendLine("行 $lineNum")
      [void]$sb.AppendLine(("  現在    : {0}" -f ($cur ?? '(行なし)')))
      [void]$sb.AppendLine(("  過去    : {0}" -f ($pst ?? '(行なし)')))
      [void]$sb.AppendLine("  -----------------------------")
    }
  }

  if ($diffCount -eq 0) {
    [void]$sb.AppendLine("差分はありませんでした。")
  } else {
    [void]$sb.AppendLine("差分行数: $diffCount")
  }

  $sb.ToString() | Out-File -LiteralPath $OutputPath -Encoding UTF8 -Force
  return $diffCount
}

# ===== メイン処理 =====
Resolve-DefaultPaths
Ensure-OutputDir

$files = Get-LogFiles -Dir $LogDirectory
$index = Build-Index -Files $files

# 現在ログの決定（CurrentFile 優先、なければ TargetIP で絞って最新）
$current = Select-CurrentLog -Index $index -ExplicitFile $CurrentFile -IP $TargetIP

# 同一IPのみを候補に
$ip = $current.IP
$ipCandidates = $index | Where-Object { $_.IP -eq $ip }

# 目標時刻（現在ログの採取時刻基準ではなく「現在日時」基準にしています）
$now = Get-Date
$oneDayTarget  = $now.AddDays(-1)
$oneWeekTarget = $now.AddDays(-7)

$oneDayFile  = Get-ClosestByTime -Candidates $ipCandidates -TargetTime $oneDayTarget  -Tolerance ([TimeSpan]::FromHours($OneDayToleranceHours))  -Exclude $current
$oneWeekFile = Get-ClosestByTime -Candidates $ipCandidates -TargetTime $oneWeekTarget -Tolerance ([TimeSpan]::FromHours($OneWeekToleranceHours)) -Exclude $current

if (-not $oneDayFile)  { Write-Warning "1日前（±$OneDayToleranceHours 時間）に近い同一IP($ip)ログが見つかりません。" }
if (-not $oneWeekFile) { Write-Warning "1週間前（±$OneWeekToleranceHours 時間）に近い同一IP($ip)ログが見つかりません。" }

# 出力ファイル名（現在ログのメタから生成）
$base = [IO.Path]::GetFileNameWithoutExtension($current.File.Name)
$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')

if ($oneDayFile) {
  $out1 = Join-Path $OutputDirectory ("diff_1day_{0}_{1}.txt" -f $base, $stamp)
  $c1 = Compare-FilesWithLineNumbers -CurrentPath $current.File.FullName -PastPath $oneDayFile.File.FullName -LabelPast '1日前' -OutputPath $out1
  Write-Host ("[IP {0}] 1日前との差分: {1} 行 -> {2}" -f $ip, $c1, $out1)
}

if ($oneWeekFile) {
  $out7 = Join-Path $OutputDirectory ("diff_1week_{0}_{1}.txt" -f $base, $stamp)
  $c7 = Compare-FilesWithLineNumbers -CurrentPath $current.File.FullName -PastPath $oneWeekFile.File.FullName -LabelPast '1週間前' -OutputPath $out7
  Write-Host ("[IP {0}] 1週間前との差分: {1} 行 -> {2}" -f $ip, $c7, $out7)
}