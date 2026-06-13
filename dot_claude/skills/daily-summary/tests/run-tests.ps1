$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\lib.ps1')

$script:fail = 0
function Assert-Equal($actual, $expected, $msg) {
    if ("$actual" -ne "$expected") {
        Write-Host ("FAIL: {0}`n  expected: [{1}]`n  actual:   [{2}]" -f $msg, $expected, $actual)
        $script:fail++
    } else {
        Write-Host "ok: $msg"
    }
}

# --- Get-MarketectureUpdated ---
Assert-Equal (Get-MarketectureUpdated '<!-- marketecture:updated: 2026-05-24 -->') '2026-05-24' 'parses updated date'
Assert-Equal (Get-MarketectureUpdated 'no marker here')                            ''           'returns null when no marker'
Assert-Equal (Get-MarketectureUpdated '')                                          ''           'returns null on empty'

# --- Measure-BdJson ---
Assert-Equal (Measure-BdJson '[{"id":1},{"id":2},{"id":3}]')        3 'counts bare array'
Assert-Equal (Measure-BdJson '{"issues":[{"id":1},{"id":2}]}')      2 'counts object.issues array'
Assert-Equal (Measure-BdJson '{"count":7}')                         7 'reads count field'
Assert-Equal (Measure-BdJson '')                                    0 'empty -> 0'
Assert-Equal (Measure-BdJson 'not json')                            0 'invalid json -> 0'
Assert-Equal (Measure-BdJson '[]')                                  0 'empty array -> 0'

# --- Resolve-RepoName ---
$cands = @('cofferdam','calendaring','beads_viewer','rovikore-host','rovikore-demo','rovikore-landing-page')
Assert-Equal (Resolve-RepoName -Name 'cofferdam' -Candidates $cands).Match  'cofferdam'   'exact match'
Assert-Equal (Resolve-RepoName -Name 'COFFERDAM' -Candidates $cands).Match  'cofferdam'   'case-insensitive match'
Assert-Equal (Resolve-RepoName -Name 'calend'    -Candidates $cands).Match  'calendaring' 'single substring match'
Assert-Equal (Resolve-RepoName -Name 'zzz'       -Candidates $cands).Resolved $false      'no match -> unresolved'
$amb = Resolve-RepoName -Name 'rovikore' -Candidates $cands
Assert-Equal $amb.Resolved        $false 'ambiguous -> unresolved'
Assert-Equal $amb.Candidates.Count 3     'ambiguous -> returns all candidates'

# --- Get-DiagramStatus ---
$now = [datetime]'2026-05-24'
Assert-Equal (Get-DiagramStatus -Exists $false -Now $now)                          'missing' 'missing when file absent'
Assert-Equal (Get-DiagramStatus -Exists $true -Updated '2026-05-20' -Now $now)     'ok'      'ok when recent'
Assert-Equal (Get-DiagramStatus -Exists $true -Updated '2026-01-01' -Now $now)     'stale'   'stale when older than threshold'
Assert-Equal (Get-DiagramStatus -Exists $true -Updated '' -Now $now)               'stale'   'stale when present but no date'
Assert-Equal (Get-DiagramStatus -Exists $true -Updated 'garbage' -Now $now)        'stale'   'stale when date unparseable'

if ($script:fail -gt 0) { Write-Host "`n$script:fail failure(s)"; exit 1 }
Write-Host "`nAll tests passed"; exit 0
