$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here "claude-hang-capture.ps1"
$fail = 0

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$proj = Join-Path $tmp "projects/stale-worker"
New-Item -ItemType Directory -Force -Path $proj | Out-Null
$staleTs = [DateTimeOffset]::UtcNow.AddHours(-2).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
Set-Content -Path (Join-Path $proj "s1.jsonl") -Value "{`"type`":`"user`",`"timestamp`":`"$staleTs`"}"

$out = & $script -ProjectsDir (Join-Path $tmp "projects") -StallSeconds 60 -DryRun 2>&1 | Out-String
if ($out -notmatch "stale-worker") {
  Write-Output "FAIL: expected stale-worker in dry-run output"
  Write-Output $out
  $fail = 1
} else {
  Write-Output "PASS: stale transcript detected in dry-run"
}

$emptyOut = & $script -ProjectsDir (Join-Path $tmp "no-such-dir") 2>&1 | Out-String
if ($emptyOut -notmatch "no transcript store") {
  Write-Output "FAIL: expected friendly message for missing projects dir"
  Write-Output $emptyOut
  $fail = 1
} else {
  Write-Output "PASS: missing projects dir handled"
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

if ($fail -eq 0) {
  Write-Output "claude-hang-capture.test.ps1: all cases passed"
  exit 0
} else {
  exit 1
}
