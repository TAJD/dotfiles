$ErrorActionPreference = 'Stop'
$gather = Join-Path $PSScriptRoot '..\scripts\gather.ps1'
$fail = 0
function Check($cond, $msg) { if ($cond) { Write-Host "ok: $msg" } else { Write-Host "FAIL: $msg"; $script:fail++ } }

# Resolve
$r = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gather -Resolve 'cofferdam' | ConvertFrom-Json
Check ($r.resolved -eq $true) 'resolve cofferdam -> resolved'
Check ($r.path -like '*cofferdam') 'resolve returns a path'

# ListBeadsRepos must emit a plain JSON ARRAY of {name,path} (not a {value,Count} wrapper).
# Assert against the raw output text: it's what the skill actually consumes, and it sidesteps
# PS 5.1's ConvertFrom-Json array-enumeration quirks.
$reposRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gather -ListBeadsRepos
Check ($reposRaw.TrimStart()[0] -eq '[')        'list beads repos is a JSON array (starts with [)'
$null = $reposRaw | ConvertFrom-Json            # throws (and fails the run) if invalid JSON
Check ($reposRaw -match '"name":')              'array elements have a name field'
Check ($reposRaw -match '"path":')              'array elements have a path field'
Check ($reposRaw -match '"name":"cofferdam"')   'list includes cofferdam'
Check ((([regex]::Matches($reposRaw,'"name":')).Count) -ge 5) 'list finds multiple beads repos'

# Gather full envelope
$envJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gather -RepoPath $r.path
$envObj = $envJson | ConvertFrom-Json
Check ($envObj.schema -eq 1) 'envelope has schema=1'
Check ($null -ne $envObj.git.branch) 'envelope has a branch'
Check ($envObj.repo.has_beads -eq $true) 'cofferdam has beads'
Check ($envObj.marketecture.status -in @('ok','stale','missing')) 'marketecture status is valid token'

# Lite envelope omits heavy fields
$liteObj = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gather -RepoPath $r.path -Lite) | ConvertFrom-Json
Check ($liteObj.lite -eq $true) 'lite flag set'
Check ($null -eq $liteObj.marketecture.content) 'lite omits marketecture content'

# Regression: a repo whose current branch has NO upstream must not blank out the
# envelope. (`git rev-list @{u}...HEAD` errors on no-upstream branches; that must not
# abort the gather.) Also covers a fresh repo with a single commit and no remote.
$tmp = Join-Path $env:TEMP ("ds-noupstream-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $tmp | Out-Null
$savedEap = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
Push-Location $tmp
& git init -q | Out-Null
& git -c user.email=t@t.dev -c user.name=tester commit --allow-empty -q -m "init" | Out-Null
Pop-Location
$ErrorActionPreference = $savedEap

$envJson2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gather -RepoPath $tmp
$o2 = $envJson2 | ConvertFrom-Json
Check ($o2.schema -eq 1)                                  'no-upstream repo: valid envelope'
Check (-not $o2.error)                                    'no-upstream repo: no error key'
Check ($null -ne $o2.git.branch -and $o2.git.branch -ne '') 'no-upstream repo: branch populated'
Check ($o2.git.ahead -eq 0 -and $o2.git.behind -eq 0)     'no-upstream repo: ahead/behind default to 0'
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

if ($fail -gt 0) { Write-Host "`n$fail failure(s)"; exit 1 }
Write-Host "`nSmoke OK"; exit 0
