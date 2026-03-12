<#
.SYNOPSIS
  命名規則（YYMMDD_HHMMSS_IP_from_ユーザー.log）に基づき、
  同一IPの最新ログと 1日前／1週間前のログを比較し、差分を出力します。

.DESCRIPTION
  - ログフォルダ既定: デスクトップ\ログ保管
  - 出力フォルダ既定: ログ保管\出力
  - 「現在ログ」は同フォルダ内の最も新しい（ファイル名に含まれる日時が最大の）ファイル。
  - 比較相手は「同一IP」かつ 指定目標時刻（現在ログの採取時刻から 1日前/1週間前）に最も近いファイルを、許容誤差の範囲で選定。
  - 差分は行番号付きでテキスト出力します。
  - Windows PowerShell 5.1 互換（'??' などの演算子は未使用）。

.PARAMETER LogDirectory
  ログ保管フォルダ。既定: デスクトップ\ログ保管

.PARAMETER OutputDirectory
  出力フォルダ。既定: LogDirectory\出力

.PARAMETER CurrentFile
  現在ログを明示指定する場合に使用（そのファイルのIPを基準に比較）

.PARAMETER OneDayToleranceHours
  1日前検索の許容誤差（時間）。既定: 36

.PARAMETER OneWeekToleranceHours
  1週間前検索の許容誤差（時間）。既定: 96

.PARAMETER TargetIP
  IPを明示指定して、そのIPの最新ログを基準に比較する場合に使用
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

# ====== Utility ======

function Resolve-DefaultPaths {
  $desktop = [Environment]::GetFolderPath('Desktop')
  if (-not $LogDirectory -or [string]::IsNullOrWhiteSpace($LogDirectory)) {
    $script:LogDirectory = Join-Path $desktop 'ログ保管'
  }
  if (-not $OutputDirectory -or [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $script:OutputDirectory = Join-Path $LogDirectory '出力'
  }
}

function Ensure-OutputDir {
  if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
  }
}

## ここまで実施

# 例: 260113_141553_10.51.192.216_from_i-taga3e-v.log
#      YYMMDD_HHMMSS_IP_from_USER.log
$NameRegex = '^(?<yy>\d{2})(?<mo>\d{2})(?<dd>\d{2})_(?<HH>\d{2})(?<MM>\d{2})(?<SS>\d{2})_(?<ip>\d{1,3}(?:\.\d{1,3}){3})_from_(?<user>.+?)\.log$'

function Parse-LogName {
  param([System.IO.FileInfo]$File)
  $m = [regex]::Match($File.Name, $NameRegex)
  if (-not $m.Success) { return $null }

  $year  = 2000 + [int]$m.Groups['yy'].Value
  $month = [int]$m.Groups['mo'].Value
  $day   = [int]$m.Groups['dd'].Value
  $hour  = [int]$m.Groups['HH'].Value
  $min   = [int]$m.Groups['MM'].Value
  $sec   = [int]$m.Groups['SS'].Value

  try {
    $dt = [datetime]::new($year,$month,$day,$hour,$min,$sec)
  } catch {
    return $null
  }

  [pscustomobject]@{
    File    = $File
    IP      = $m.Groups['ip'].Value
    User    = $m.Groups['user'].Value
    LogTime = $dt
  }
}

function Get-LogFiles {
  param([string]$Dir)
  $files = Get-ChildItem -Path $Dir -File -Filter *.log -ErrorAction Stop
  if (-not $files) { throw "ログファイル（*.log）が見つかりません: $Dir" }
  # 出力フォルダ配下を除外
  $files = $files | Where-Object { $_.DirectoryName -ne $OutputDirectory }
  return $files
}

function Build-Index {
  param([System.IO.FileInfo[]]$Files)
  $list = foreach ($f in $Files) {
    $p = Parse-LogName -File $f
    if ($p) { $p }
  }
  if (-not $list) { throw "命名規則に合致するログが見つかりません（YYMMDD_HHMMSS_IP_from_USER.log）。" }
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
    return $candidates | Sort-Object LogTime -Descending | Select-Object -First 1
  }
}

function Get-ClosestByTime {
  param(
    [object[]]$Candidates,
    [datetime]$TargetTime,
    [timespan]$Tolerance,
    [object]$Exclude
  )
  $cands = $Candidates | Where-Object { $_.File.FullName -ne $Exclude.File.FullName }
  if (-not $cands) { return $null }

  $sel = $cands |
    Sort-Object @{Expression = { [math]::Abs(($_.LogTime - $TargetTime).TotalSeconds) } ; Ascending = $true } |
    Select-Object -First 1

  if ($sel -and [math]::Abs(($sel.LogTime - $TargetTime).TotalHours) -le $Tolerance.TotalHours) {
    return $sel
  }
  return $null
}

# 今後のノイズ除外（現状は素通し）
function Filter-NoiseLines {
  param([string[]]$Lines)
  # 例: return $Lines | Where-Object { $_ -notmatch 'uptime|Time since last|^\s*$' }
  return $Lines
}

function Format-Line {
  param([string]$Text)
  if ($null -eq $Text) { return '(no line)' }
  return $Text
}

function Compare-FilesWithLineNumbers {
  param(
    [string]$CurrentPath,
    [string]$PastPath,
    [string]$LabelPast,
    [datetime]$CurrentLogTime,
    [datetime]$PastLogTime,
    [string]$OutputPath
  )

  $currentLines = Get-Content -LiteralPath $CurrentPath -ErrorAction Stop
  $pastLines    = Get-Content -LiteralPath $PastPath   -ErrorAction Stop

  $currentLines = Filter-NoiseLines -Lines $currentLines
  $pastLines    = Filter-NoiseLines -Lines $pastLines

  $max = [math]::Max($currentLines.Count, $pastLines.Count)

  $header = @()
  $header += "=== Diff Report (same IP) ==="
  $header += "Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  $header += "Current   : $CurrentPath"
  $header += "LogTime   : $($CurrentLogTime.ToString('yyyy-MM-dd HH:mm:ss'))"
  $header += "${LabelPast}: $PastPath"
  $header += "${LabelPast} LogTime : $($PastLogTime.ToString('yyyy-MM-dd HH:mm:ss'))"
  $header += "----------------------------------------"
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
      [void]$sb.AppendLine(("Line {0}" -f $lineNum))
      [void]$sb.AppendLine(("  Current : {0}" -f (Format-Line $cur)))
      [void]$sb.AppendLine(("  Past    : {0}" -f (Format-Line $pst)))
      [void]$sb.AppendLine("  -----------------------------")
    }
  }

  if ($diffCount -eq 0) {
    [void]$sb.AppendLine("No differences.")
  } else {
    [void]$sb.AppendLine(("Diff lines: {0}" -f $diffCount))
  }

  $sb.ToString() | Out-File -LiteralPath $OutputPath -Encoding UTF8 -Force
  return $diffCount
}

# ====== Main ======
Resolve-DefaultPaths
Ensure-OutputDir

$files = Get-LogFiles -Dir $LogDirectory
$index = Build-Index -Files $files

# 現在ログ（CurrentFile 優先、次いで TargetIP で絞り、最後は全体から最新を選択）
$current = Select-CurrentLog -Index $index -ExplicitFile $CurrentFile -IP $TargetIP

# 同一IPの候補に絞る
$ip = $current.IP
$ipCandidates = $index | Where-Object { $_.IP -eq $ip }

# 基準は「現在ログの採取時刻（ファイル名から解析した時刻）」
$baseTime = $current.LogTime
$oneDayTarget  = $baseTime.AddDays(-1)
$oneWeekTarget = $baseTime.AddDays(-7)

$oneDayFile  = Get-ClosestByTime -Candidates $ipCandidates -TargetTime $oneDayTarget  -Tolerance ([TimeSpan]::FromHours($OneDayToleranceHours))  -Exclude $current
$oneWeekFile = Get-ClosestByTime -Candidates $ipCandidates -TargetTime $oneWeekTarget -Tolerance ([TimeSpan]::FromHours($OneWeekToleranceHours)) -Exclude $current

if (-not $oneDayFile)  { Write-Warning "1日前（±$OneDayToleranceHours h）に近い同一IP($ip)ログが見つかりません。" }
if (-not $oneWeekFile) { Write-Warning "1週間前（±$OneWeekToleranceHours h）に近い同一IP($ip)ログが見つかりません。" }

# 出力ファイル名（現在ログベース）
$base = [IO.Path]::GetFileNameWithoutExtension($current.File.Name)
$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')

if ($oneDayFile) {
  $out1 = Join-Path $OutputDirectory ("diff_1day_{0}_{1}.txt" -f $base, $stamp)
  $c1 = Compare-FilesWithLineNumbers `
          -CurrentPath $current.File.FullName `
          -PastPath    $oneDayFile.File.FullName `
          -LabelPast   '1day-ago' `
          -CurrentLogTime $current.LogTime `
          -PastLogTime    $oneDayFile.LogTime `
          -OutputPath  $out1
  Write-Host ("[IP {0}] 1day diff: {1} lines -> {2}" -f $ip, $c1, $out1)
}

if ($oneWeekFile) {
  $out7 = Join-Path $OutputDirectory ("diff_1week_{0}_{1}.txt" -f $base, $stamp)
  $c7 = Compare-FilesWithLineNumbers `
          -CurrentPath $current.File.FullName `
          -PastPath    $oneWeekFile.File.FullName `
          -LabelPast   '1week-ago' `
          -CurrentLogTime $current.LogTime `
          -PastLogTime    $oneWeekFile.LogTime `
          -OutputPath  $out7
  Write-Host ("[IP {0}] 1week diff: {1} lines -> {2}" -f $ip, $c7, $out7)
}