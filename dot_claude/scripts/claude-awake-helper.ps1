param([Parameter(Mandatory)][int]$WatchPid)

# One helper per session, keyed by the watched PID. The SessionStart hook fires on
# startup/resume/clear/compact, so duplicate launches happen — only one may hold the lock.
$lock = Join-Path $env:TEMP "claude-awake-$WatchPid.lock"
try {
  # Atomic claim: New-Item without -Force fails if the lock already exists (no TOCTOU race).
  New-Item $lock -ItemType File -ErrorAction Stop | Out-Null
}
catch {
  # Lock exists. Stand down if a LIVE helper owns it; otherwise it's stale (a previous
  # helper was hard-killed before its finally ran) — clear it and claim it once.
  $owner = [int](Get-Content $lock -Raw -ErrorAction SilentlyContinue)
  if ($owner -and (Get-Process -Id $owner -ErrorAction SilentlyContinue)) { exit }
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
  try { New-Item $lock -ItemType File -ErrorAction Stop | Out-Null } catch { exit }
}
Set-Content -Path $lock -Value $PID -ErrorAction SilentlyContinue   # record owner for stale-detection

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Sleep { [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f); }
'@

# ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x1)
# Add -bor 0x2 (ES_DISPLAY_REQUIRED) if you also want the screen kept on.
[Sleep]::SetThreadExecutionState(0x80000000 -bor 0x1)
try {
  # Blocks until the watched claude session exits (clean exit OR crash/kill).
  Wait-Process -Id $WatchPid -ErrorAction SilentlyContinue
}
finally {
  # Release THIS session's lock. Windows keeps the machine awake until the LAST
  # surviving helper releases, so no manual ref-counting is needed.
  [Sleep]::SetThreadExecutionState(0x80000000)   # ES_CONTINUOUS alone = back to normal
  Remove-Item $lock -ErrorAction SilentlyContinue
}
