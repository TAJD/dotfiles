param(
  [string]$ProjectsDir = (Join-Path $HOME ".claude/projects"),
  [string]$OutDir = (Join-Path $HOME ".claude/hang-captures"),
  [int]$StallSeconds = 1200,
  [switch]$DryRun
)

if (-not (Test-Path $ProjectsDir)) {
  Write-Output "claude-hang-capture: no transcript store at $ProjectsDir"
  exit 0
}

$claudeProcs = @(Get-Process -Name claude -ErrorAction SilentlyContinue)
$nodeClaudeProcs = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'cli\.js' } |
  ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
$allProcs = @($claudeProcs + $nodeClaudeProcs) | Sort-Object Id -Unique

if (-not $allProcs) {
  Write-Output "claude-hang-capture: no claude processes running (checked claude.exe and node.exe cli.js)"
  exit 0
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$now = [DateTimeOffset]::UtcNow

function Get-Records($jsonlPath) {
  Get-Content -LiteralPath $jsonlPath -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { $null }
  } | Where-Object { $_ }
}

$stalled = @()
$latestByProject = @()
Get-ChildItem -Directory $ProjectsDir | ForEach-Object {
  $dir = $_.FullName
  $f = Get-ChildItem -File -Filter "*.jsonl" $dir -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $f) { return }
  $records = @(Get-Records $f.FullName)
  $withTs = $records | Where-Object { $_.timestamp }
  if (-not $withTs) { return }
  $maxTs = ($withTs | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp
  $ts = [DateTimeOffset]::Parse($maxTs)
  $idle = ($now - $ts).TotalSeconds

  $tail = $withTs | Sort-Object timestamp | Select-Object -Last 6
  $lastType = ($tail | Select-Object -Last 1).type
  $continuedAway = $records | Where-Object { $_.type -eq 'continued-in' }

  $latestByProject += [PSCustomObject]@{ Project = $_.Name; Ts = $ts }

  if ($continuedAway) { return }
  if ($idle -ge $StallSeconds) {
    $stalled += [PSCustomObject]@{
      Project      = $_.Name
      Transcript   = $f.FullName
      IdleSeconds  = [int]$idle
      LastType     = $lastType
      Tail         = $tail
    }
  }
}

if (-not $stalled) {
  Write-Output "claude-hang-capture: no transcript stalled >= ${StallSeconds}s"
  exit 0
}

$ts = $now.ToString("yyyyMMdd-HHmmss")
$reportPath = Join-Path $OutDir "hang-$ts.txt"
$lines = @()
$lines += "claude-hang-capture: $($now.ToString('o'))"

$mem = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($mem) {
  $lines += "FreePhysicalMemory(KB)=$($mem.FreePhysicalMemory) TotalVisibleMemorySize(KB)=$($mem.TotalVisibleMemorySize)"
}

$coOccurring = $latestByProject | Group-Object { $_.Ts.ToString("yyyy-MM-ddTHH:mm") } | Where-Object { $_.Count -gt 1 }
if ($coOccurring) {
  $lines += "Multiple sessions quiesced in the same minute (possible machine/multiplexer failure, not a single-session hang):"
  $coOccurring | ForEach-Object {
    $lines += "  $($_.Name): $(($_.Group | ForEach-Object { $_.Project }) -join ', ')"
  }
}

$lines += ""
$lines += "Stalled transcripts (idle >= ${StallSeconds}s) with a live claude process present:"
$stalled | ForEach-Object {
  $s = $_
  $lines += "  $($s.Project): idle $($s.IdleSeconds)s -- $($s.Transcript)"
  $lines += "    last record type: $($s.LastType)"
  $s.Tail | ForEach-Object {
    $ctypes = @($_.message.content | Where-Object { $_ } | ForEach-Object { $_.type }) -join ","
    $lines += "    $($_.timestamp) | $($_.type) | $ctypes"
    $toolUse = $_.message.content | Where-Object { $_.type -eq 'tool_use' }
    if ($toolUse) {
      foreach ($t in $toolUse) {
        $inputStr = ($t.input | ConvertTo-Json -Compress -Depth 3 -ErrorAction SilentlyContinue)
        $lines += "      tool_use: $($t.name) input=$inputStr"
      }
    }
  }
}

$lines += ""
$lines += "Live claude processes (claude.exe and node.exe running cli.js):"
$allProcs | ForEach-Object {
  $lines += "  pid=$($_.Id) name=$($_.ProcessName) path=$($_.Path) start=$($_.StartTime) cpu=$($_.CPU) threads=$($_.Threads.Count) responding=$($_.Responding)"
}

$zellijTabs = & zellij action query-tab-names 2>$null
if ($LASTEXITCODE -eq 0 -and $zellijTabs) {
  $lines += ""
  $lines += "Zellij tabs:"
  $zellijTabs | ForEach-Object { $lines += "  $_" }
}

$zellijLogDir = Join-Path $env:LOCALAPPDATA "Temp\zellij\zellij-log"
if (Test-Path $zellijLogDir) {
  $logCopyDir = Join-Path $OutDir "zellij-log-$ts"
  Copy-Item -Recurse -Force $zellijLogDir $logCopyDir -ErrorAction SilentlyContinue
  $lines += ""
  $lines += "Zellij log copied to: $logCopyDir"
}

if ($DryRun) {
  $lines | ForEach-Object { Write-Output $_ }
  exit 0
}

$lines | Set-Content -Path $reportPath -Encoding utf8

$procdump = Get-Command procdump.exe -ErrorAction SilentlyContinue
if ($procdump) {
  foreach ($p in $allProcs) {
    $lockFile = Join-Path $OutDir "dump-lock-$($p.Id).flag"
    if (Test-Path $lockFile) {
      $age = ($now - [DateTimeOffset](Get-Item $lockFile).LastWriteTimeUtc).TotalMinutes
      if ($age -lt 60) { continue }
    }
    $dumpPath = Join-Path $OutDir "claude-$($p.Id)-$ts.dmp"
    & $procdump.Source -ma $p.Id $dumpPath 2>&1 | Out-Null
    New-Item -ItemType File -Force -Path $lockFile | Out-Null
  }
} else {
  Add-Content -Path $reportPath -Value "`nprocdump.exe not found on PATH -- no minidump captured, report only."
}

Write-Output "claude-hang-capture: wrote $reportPath"
