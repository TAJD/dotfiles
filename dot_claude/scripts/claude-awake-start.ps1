# SessionStart hook: launch one detached keep-awake helper bound to THIS claude
# session's lifetime. Windows aggregates ES_SYSTEM_REQUIRED across all processes, so
# the system stays awake until the last session's helper exits.

$ErrorActionPreference = 'SilentlyContinue'

# Walk up from this hook process to the long-lived claude/node session process,
# skipping any transient shell (bash/cmd/powershell) that launched the hook. Guard
# against a runaway walk: stop at the root (parent 0 / missing / self-parent).
$proc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
while ($proc -and $proc.Name -notmatch '^(claude|node)') {
  $parentId = $proc.ParentProcessId
  if (-not $parentId -or $parentId -eq 0 -or $parentId -eq $proc.ProcessId) { $proc = $null; break }
  $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$parentId"
}
if (-not $proc) { exit }   # no claude/node ancestor found — do nothing
$claudePid = $proc.ProcessId

Start-Process powershell -WindowStyle Hidden -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass',
  '-File', "$HOME\.claude\scripts\claude-awake-helper.ps1",
  '-WatchPid', $claudePid
)
