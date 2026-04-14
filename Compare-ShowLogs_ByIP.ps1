<#
.SYNOPSIS
  Compare Cisco show-command logs for the same IP and export human-readable diffs.

.DESCRIPTION
  This script scans a log directory for files that match the naming pattern
  YYMMDD_HHMMSS_IP_from_USER.log, selects the latest log for a target IP, and compares it
  with the closest log captured roughly 1 day and 1 week earlier.

  The diff engine uses an LCS-based comparison so inserted or deleted lines do not cause the
  rest of the file to appear changed. Noise lines can be excluded while keeping original line
  numbers in the report.

  Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER LogDirectory
  Directory containing the log files. Defaults to "$HOME\Desktop\ログ保管".

.PARAMETER OutputDirectory
  Directory where reports are written. Defaults to "<LogDirectory>\出力".

.PARAMETER CurrentFile
  Explicit current log file to use as the comparison baseline.

.PARAMETER TargetIP
  Select the latest log for this IP as the comparison baseline.

.PARAMETER OneDayToleranceHours
  Maximum allowed distance, in hours, from the target timestamp of 1 day earlier.

.PARAMETER OneWeekToleranceHours
  Maximum allowed distance, in hours, from the target timestamp of 1 week earlier.

.PARAMETER IgnorePattern
  Regex patterns for lines to exclude before comparison. Original line numbers are preserved.

.PARAMETER Recurse
  Search for log files recursively under LogDirectory.

.EXAMPLE
  .\Compare-ShowLogs_ByIP.ps1

.EXAMPLE
  .\Compare-ShowLogs_ByIP.ps1 -TargetIP 10.0.0.1

.EXAMPLE
  .\Compare-ShowLogs_ByIP.ps1 -CurrentFile "$env:USERPROFILE\Desktop\ログ保管\260212_083000_10.0.0.1_from_admin.log"

.EXAMPLE
  .\Compare-ShowLogs_ByIP.ps1 -IgnorePattern '^\s*$', 'uptime', 'Last input'
#>

[CmdletBinding(DefaultParameterSetName = 'Auto')]
param(
  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string]$LogDirectory,

  [Parameter()]
  [string]$OutputDirectory,

  [Parameter(ParameterSetName = 'ByFile', Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$CurrentFile,

  [Parameter(ParameterSetName = 'ByIP', Mandatory = $true)]
  [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}$')]
  [string]$TargetIP,

  [Parameter()]
  [ValidateRange(1, 24 * 14)]
  [int]$OneDayToleranceHours = 36,

  [Parameter()]
  [ValidateRange(1, 24 * 30)]
  [int]$OneWeekToleranceHours = 96,

  [Parameter()]
  [string[]]$IgnorePattern = @(),

  [Parameter()]
  [switch]$Recurse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogNameRegex = '^(?<yy>\d{2})(?<mo>\d{2})(?<dd>\d{2})_(?<HH>\d{2})(?<MM>\d{2})(?<SS>\d{2})_(?<ip>\d{1,3}(?:\.\d{1,3}){3})_from_(?<user>.+?)\.log$'

function Resolve-DefaultPaths {
  $desktop = [Environment]::GetFolderPath('Desktop')

  if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $script:LogDirectory = Join-Path $desktop 'ログ保管'
  }

  if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $script:OutputDirectory = Join-Path $script:LogDirectory '出力'
  }
}

function Ensure-Directory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Parse-LogName {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.FileInfo]$File
  )

  $match = [regex]::Match($File.Name, $script:LogNameRegex)
  if (-not $match.Success) {
    return $null
  }

  $year = 2000 + [int]$match.Groups['yy'].Value
  $month = [int]$match.Groups['mo'].Value
  $day = [int]$match.Groups['dd'].Value
  $hour = [int]$match.Groups['HH'].Value
  $minute = [int]$match.Groups['MM'].Value
  $second = [int]$match.Groups['SS'].Value

  try {
    $timestamp = [datetime]::new($year, $month, $day, $hour, $minute, $second)
  } catch {
    Write-Warning ("Skipping '{0}' because the timestamp in the file name is invalid." -f $File.Name)
    return $null
  }

  [pscustomobject]@{
    File = $File
    IP = $match.Groups['ip'].Value
    User = $match.Groups['user'].Value
    LogTime = $timestamp
  }
}

function Get-LogFiles {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Directory,

    [Parameter(Mandatory = $true)]
    [string]$ExcludedDirectory,

    [Parameter()]
    [switch]$Recursive
  )

  if (-not (Test-Path -LiteralPath $Directory)) {
    throw "Log directory was not found: $Directory"
  }

  $params = @{
    LiteralPath = $Directory
    File = $true
    Filter = '*.log'
    ErrorAction = 'Stop'
  }

  if ($Recursive) {
    $params['Recurse'] = $true
  }

  $files = Get-ChildItem @params | Where-Object {
    $_.DirectoryName -ne $ExcludedDirectory
  }

  if (-not $files) {
    throw "No log files (*.log) were found in '$Directory'."
  }

  return ,$files
}

function Build-Index {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.FileInfo[]]$Files
  )

  $parsed = New-Object System.Collections.Generic.List[object]
  $skipped = New-Object System.Collections.Generic.List[string]

  foreach ($file in $Files) {
    $entry = Parse-LogName -File $file
    if ($null -eq $entry) {
      $skipped.Add($file.Name)
      continue
    }

    $parsed.Add($entry)
  }

  if ($skipped.Count -gt 0) {
    Write-Warning ("Skipped {0} file(s) that did not match the naming convention." -f $skipped.Count)
    foreach ($name in $skipped) {
      Write-Verbose ("Skipped: {0}" -f $name)
    }
  }

  if ($parsed.Count -eq 0) {
    throw 'No files matched the required naming pattern: YYMMDD_HHMMSS_IP_from_USER.log'
  }

  return $parsed.ToArray()
}

function Select-CurrentLog {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Index,

    [Parameter()]
    [string]$ExplicitFile,

    [Parameter()]
    [string]$IP
  )

  if ($PSBoundParameters.ContainsKey('ExplicitFile') -and -not [string]::IsNullOrWhiteSpace($ExplicitFile)) {
    if (-not (Test-Path -LiteralPath $ExplicitFile)) {
      throw "CurrentFile was not found: $ExplicitFile"
    }

    $file = Get-Item -LiteralPath $ExplicitFile -ErrorAction Stop
    $parsed = Parse-LogName -File $file
    if ($null -eq $parsed) {
      throw "CurrentFile does not match the required naming pattern: $($file.Name)"
    }

    return $parsed
  }

  $candidates = $Index
  if (-not [string]::IsNullOrWhiteSpace($IP)) {
    $candidates = $candidates | Where-Object { $_.IP -eq $IP }
  }

  if (-not $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($IP)) {
      throw "No logs were found for IP '$IP'."
    }

    throw 'No candidate logs were found.'
  }

  return $candidates | Sort-Object LogTime -Descending | Select-Object -First 1
}

function Get-ClosestByTime {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Candidates,

    [Parameter(Mandatory = $true)]
    [datetime]$TargetTime,

    [Parameter(Mandatory = $true)]
    [timespan]$Tolerance,

    [Parameter(Mandatory = $true)]
    [object]$Exclude
  )

  $filtered = $Candidates | Where-Object { $_.File.FullName -ne $Exclude.File.FullName }
  if (-not $filtered) {
    return $null
  }

  $selected = $filtered |
    Sort-Object @{ Expression = { [math]::Abs(($_.LogTime - $TargetTime).TotalSeconds) }; Ascending = $true } |
    Select-Object -First 1

  if ($null -eq $selected) {
    return $null
  }

  $distance = [timespan]::FromSeconds([math]::Abs(($selected.LogTime - $TargetTime).TotalSeconds))
  if ($distance -le $Tolerance) {
    return $selected
  }

  Write-Verbose (
    "Closest candidate '{0}' was outside tolerance. Target={1}, Candidate={2}, DistanceHours={3:N2}, AllowedHours={4:N2}" -f
    $selected.File.Name,
    $TargetTime.ToString('yyyy-MM-dd HH:mm:ss'),
    $selected.LogTime.ToString('yyyy-MM-dd HH:mm:ss'),
    $distance.TotalHours,
    $Tolerance.TotalHours
  )

  return $null
}

function Get-IndexedLines {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter()]
    [string[]]$Patterns = @()
  )

  $rawLines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)
  $indexed = New-Object System.Collections.Generic.List[object]

  for ($i = 0; $i -lt $rawLines.Count; $i++) {
    $lineText = [string]$rawLines[$i]
    $ignore = $false

    foreach ($pattern in $Patterns) {
      if ($lineText -match $pattern) {
        $ignore = $true
        break
      }
    }

    if ($ignore) {
      continue
    }

    $indexed.Add([pscustomobject]@{
      Number = $i + 1
      Text = $lineText
    })
  }

  return $indexed.ToArray()
}

function Format-LineNumber {
  param(
    [AllowNull()]
    [object]$Number
  )

  if ($null -eq $Number) {
    return '-'
  }

  return [string]$Number
}

function Format-LineText {
  param(
    [AllowNull()]
    [object]$Text
  )

  if ($null -eq $Text) {
    return '(no line)'
  }

  if ([string]$Text -eq '') {
    return '(empty line)'
  }

  return [string]$Text
}

function Get-LcsDiff {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$CurrentLines,

    [Parameter(Mandatory = $true)]
    [object[]]$PastLines
  )

  $currentCount = $CurrentLines.Count
  $pastCount = $PastLines.Count
  $prefixLength = 0

  while (
    $prefixLength -lt $currentCount -and
    $prefixLength -lt $pastCount -and
    $CurrentLines[$prefixLength].Text -ceq $PastLines[$prefixLength].Text
  ) {
    $prefixLength++
  }

  $suffixLength = 0
  while (
    $suffixLength -lt ($currentCount - $prefixLength) -and
    $suffixLength -lt ($pastCount - $prefixLength) -and
    $CurrentLines[$currentCount - 1 - $suffixLength].Text -ceq $PastLines[$pastCount - 1 - $suffixLength].Text
  ) {
    $suffixLength++
  }

  $currentCoreLength = $currentCount - $prefixLength - $suffixLength
  $pastCoreLength = $pastCount - $prefixLength - $suffixLength

  if ($currentCoreLength -gt 0) {
    $currentCore = @($CurrentLines[$prefixLength..($prefixLength + $currentCoreLength - 1)])
  } else {
    $currentCore = @()
  }

  if ($pastCoreLength -gt 0) {
    $pastCore = @($PastLines[$prefixLength..($prefixLength + $pastCoreLength - 1)])
  } else {
    $pastCore = @()
  }

  $rows = $currentCore.Count
  $cols = $pastCore.Count
  $matrix = New-Object 'int[,]' ($rows + 1), ($cols + 1)

  for ($i = $rows - 1; $i -ge 0; $i--) {
    for ($j = $cols - 1; $j -ge 0; $j--) {
      if ($currentCore[$i].Text -ceq $pastCore[$j].Text) {
        $matrix[$i, $j] = $matrix[($i + 1), ($j + 1)] + 1
      } else {
        $matrix[$i, $j] = [math]::Max($matrix[($i + 1), $j], $matrix[$i, ($j + 1)])
      }
    }
  }

  $diffs = New-Object System.Collections.Generic.List[object]
  $currentIndex = 0
  $pastIndex = 0

  while ($currentIndex -lt $rows -or $pastIndex -lt $cols) {
    if ($currentIndex -lt $rows -and $pastIndex -lt $cols -and $currentCore[$currentIndex].Text -ceq $pastCore[$pastIndex].Text) {
      $currentIndex++
      $pastIndex++
      continue
    }

    if ($currentIndex -lt $rows -and ($pastIndex -ge $cols -or $matrix[($currentIndex + 1), $pastIndex] -ge $matrix[$currentIndex, ($pastIndex + 1)])) {
      $diffs.Add([pscustomobject]@{
        Type = '追加'
        CurrentNumber = $currentCore[$currentIndex].Number
        CurrentText = $currentCore[$currentIndex].Text
        PastNumber = $null
        PastText = $null
      })
      $currentIndex++
      continue
    }

    if ($pastIndex -lt $cols) {
      $diffs.Add([pscustomobject]@{
        Type = '削除'
        CurrentNumber = $null
        CurrentText = $null
        PastNumber = $pastCore[$pastIndex].Number
        PastText = $pastCore[$pastIndex].Text
      })
      $pastIndex++
    }
  }

  return $diffs.ToArray()
}

function Write-DiffReport {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CurrentPath,

    [Parameter(Mandatory = $true)]
    [string]$PastPath,

    [Parameter(Mandatory = $true)]
    [string]$LabelPast,

    [Parameter(Mandatory = $true)]
    [datetime]$CurrentLogTime,

    [Parameter(Mandatory = $true)]
    [datetime]$PastLogTime,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter()]
    [string[]]$Patterns = @()
  )

  $currentLines = Get-IndexedLines -Path $CurrentPath -Patterns $Patterns
  $pastLines = Get-IndexedLines -Path $PastPath -Patterns $Patterns
  $diffs = Get-LcsDiff -CurrentLines $currentLines -PastLines $pastLines

  $header = @(
    '=== 差分レポート（同一IP） ==='
    ("生成日時           : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    ("現在ファイル       : {0}" -f $CurrentPath)
    ("現在ログ日時       : {0}" -f $CurrentLogTime.ToString('yyyy-MM-dd HH:mm:ss'))
    ("比較ラベル         : {0}" -f $LabelPast)
    ("比較先ファイル     : {0}" -f $PastPath)
    ("比較先ログ日時     : {0}" -f $PastLogTime.ToString('yyyy-MM-dd HH:mm:ss'))
    ("除外パターン       : {0}" -f $(if ($Patterns.Count -gt 0) { $Patterns -join '; ' } else { 'なし' }))
    '----------------------------------------'
  )

  $report = New-Object System.Text.StringBuilder
  [void]$report.AppendLine(($header -join [Environment]::NewLine))

  if ($diffs.Count -eq 0) {
    [void]$report.AppendLine('差分はありません。')
  } else {
    foreach ($diff in $diffs) {
      [void]$report.AppendLine(("変更種別           : {0}" -f $diff.Type))
      [void]$report.AppendLine(("現在行番号         : {0}" -f (Format-LineNumber -Number $diff.CurrentNumber)))
      [void]$report.AppendLine(("現在行テキスト     : {0}" -f (Format-LineText -Text $diff.CurrentText)))
      [void]$report.AppendLine(("比較先行番号       : {0}" -f (Format-LineNumber -Number $diff.PastNumber)))
      [void]$report.AppendLine(("比較先行テキスト   : {0}" -f (Format-LineText -Text $diff.PastText)))
      [void]$report.AppendLine('----------------------------------------')
    }

    [void]$report.AppendLine(("変更件数合計       : {0}" -f $diffs.Count))
  }

  $report.ToString() | Out-File -LiteralPath $OutputPath -Encoding UTF8 -Force

  [pscustomobject]@{
    OutputPath = $OutputPath
    ChangeCount = $diffs.Count
  }
}

Resolve-DefaultPaths
Ensure-Directory -Path $OutputDirectory

$logFiles = Get-LogFiles -Directory $LogDirectory -ExcludedDirectory $OutputDirectory -Recursive:$Recurse
$index = Build-Index -Files $logFiles

$current = Select-CurrentLog -Index $index -ExplicitFile $CurrentFile -IP $TargetIP
$ipCandidates = $index | Where-Object { $_.IP -eq $current.IP }

$oneDayTarget = $current.LogTime.AddDays(-1)
$oneWeekTarget = $current.LogTime.AddDays(-7)

$oneDayFile = Get-ClosestByTime -Candidates $ipCandidates -TargetTime $oneDayTarget -Tolerance ([TimeSpan]::FromHours($OneDayToleranceHours)) -Exclude $current
$oneWeekFile = Get-ClosestByTime -Candidates $ipCandidates -TargetTime $oneWeekTarget -Tolerance ([TimeSpan]::FromHours($OneWeekToleranceHours)) -Exclude $current

if ($null -eq $oneDayFile) {
  Write-Warning ("No same-IP log was found near 1 day earlier for IP '{0}' within +/-{1} hours." -f $current.IP, $OneDayToleranceHours)
}

if ($null -eq $oneWeekFile) {
  Write-Warning ("No same-IP log was found near 1 week earlier for IP '{0}' within +/-{1} hours." -f $current.IP, $OneWeekToleranceHours)
}

$baseName = [System.IO.Path]::GetFileNameWithoutExtension($current.File.Name)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$results = New-Object System.Collections.Generic.List[object]

if ($null -ne $oneDayFile) {
  $oneDayOutput = Join-Path $OutputDirectory ("diff_1day_{0}_{1}.txt" -f $baseName, $stamp)
  $result = Write-DiffReport `
    -CurrentPath $current.File.FullName `
    -PastPath $oneDayFile.File.FullName `
    -LabelPast '1day-ago' `
    -CurrentLogTime $current.LogTime `
    -PastLogTime $oneDayFile.LogTime `
    -OutputPath $oneDayOutput `
    -Patterns $IgnorePattern
  $results.Add($result)
}

if ($null -ne $oneWeekFile) {
  $oneWeekOutput = Join-Path $OutputDirectory ("diff_1week_{0}_{1}.txt" -f $baseName, $stamp)
  $result = Write-DiffReport `
    -CurrentPath $current.File.FullName `
    -PastPath $oneWeekFile.File.FullName `
    -LabelPast '1week-ago' `
    -CurrentLogTime $current.LogTime `
    -PastLogTime $oneWeekFile.LogTime `
    -OutputPath $oneWeekOutput `
    -Patterns $IgnorePattern
  $results.Add($result)
}

if ($results.Count -eq 0) {
  Write-Warning 'No reports were generated.'
  return
}

$results
