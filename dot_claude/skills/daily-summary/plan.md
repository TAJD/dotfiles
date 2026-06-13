# daily-summary Skill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a personal `/daily-summary` Claude Code skill that summarizes one repo (marketecture diagram, in-flight work, open PRs/issues, bv next steps) or rolls up across all beads-tracked repos, writing a dated markdown trail; a `--prep` stage generates/maintains each repo's marketecture diagram.

**Architecture:** A PowerShell gather script (`scripts/gather.ps1`) deterministically collects raw per-repo data into one JSON envelope; pure helpers live in `scripts/lib.ps1` and are unit-tested with a framework-free runner. `SKILL.md` orchestrates: it parses args, invokes the gather script, and does the model-dependent work (diagram inference in `--prep`; narrative synthesis in daily modes). Diagrams live in each repo's `docs/marketecture.md`, referenced from `CLAUDE.md` via a `@docs/marketecture.md` import. Daily modes are read-only; only `--prep` writes project files, propose-and-confirm.

**Tech Stack:** Windows PowerShell 5.1, `bd`/`bv` (beads), `gh` (GitHub CLI), `git`. Tests are a framework-free `.ps1` assert runner (Pester 3.4 is too old to rely on).

**Spec:** `~/.claude/skills/daily-summary/design.md`

---

## File Structure

```
~/.claude/skills/daily-summary/
  design.md            # spec (exists)
  plan.md              # this plan (exists)
  SKILL.md             # skill instructions (Tasks 6-9)
  scripts/
    lib.ps1            # pure helpers, no I/O (Tasks 1-4)
    gather.ps1         # per-repo data collection -> JSON envelope (Task 5)
  tests/
    run-tests.ps1      # framework-free unit tests for lib.ps1 (Tasks 1-4)
    smoke-gather.ps1   # integration smoke test for gather.ps1 (Task 5)
```

- `lib.ps1` holds only pure functions (no external commands, no console writes) so they are trivially testable.
- `gather.ps1` does all I/O (runs git/bd/bv/gh, reads files) and emits JSON.
- `SKILL.md` holds all model-dependent behavior and prose.

**Conventions for all PowerShell here:**
- Run scripts with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <path> [args]`.
- `ConvertTo-Json` MUST pass `-Depth 8` (5.1 defaults to depth 2 and silently truncates).
- Native tool output is captured as raw strings in the envelope (no JSON-in-JSON re-serialization) to avoid 5.1 escaping/depth pitfalls.

---

## Task 0: Scaffold + version control

**Files:**
- Create dirs: `scripts/`, `tests/` under `~/.claude/skills/daily-summary/`
- Create: `.gitignore`

- [ ] **Step 1: Create directories**

```powershell
$base = Join-Path $env:USERPROFILE '.claude\skills\daily-summary'
New-Item -ItemType Directory -Force (Join-Path $base 'scripts') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $base 'tests')   | Out-Null
```

- [ ] **Step 2: Initialize a self-contained git repo for the skill**

Rationale: `~/.claude` is not a git repo; a local repo at the skill dir lets us commit per task without entangling the rest of `~/.claude`. It can be relocated later.

```powershell
cd (Join-Path $env:USERPROFILE '.claude\skills\daily-summary')
git init
"" | Out-File -Encoding utf8 .gitignore   # placeholder; nothing to ignore yet
git add design.md plan.md .gitignore
git commit -m "chore: scaffold daily-summary skill (spec + plan)"
```

Expected: a repo with one commit containing `design.md`, `plan.md`.

---

## Task 1: `Get-MarketectureUpdated` (parse updated date)

Parses `<!-- marketecture:updated: YYYY-MM-DD -->` out of a diagram file's text. Returns the date string or `$null`.

**Files:**
- Create: `scripts/lib.ps1`
- Create: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing test** (`tests/run-tests.ps1`)

```powershell
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

if ($script:fail -gt 0) { Write-Host "`n$script:fail failure(s)"; exit 1 }
Write-Host "`nAll tests passed"; exit 0
```

(`$null` stringifies to `''`, so the `Assert-Equal` comparisons above hold.)

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1`
Expected: FAIL — `lib.ps1` does not exist / `Get-MarketectureUpdated` not defined.

- [ ] **Step 3: Write minimal implementation** (`scripts/lib.ps1`)

```powershell
# Pure helpers for daily-summary. No external tool calls, no console output.

function Get-MarketectureUpdated {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    if ([string]::IsNullOrEmpty($Content)) { return $null }
    $m = [regex]::Match($Content, '<!--\s*marketecture:updated:\s*(\d{4}-\d{2}-\d{2})\s*-->')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1`
Expected: PASS — all three assertions ok.

- [ ] **Step 5: Commit**

```powershell
git add scripts/lib.ps1 tests/run-tests.ps1
git commit -m "feat: Get-MarketectureUpdated parses diagram updated date"
```

---

## Task 2: `Get-DiagramStatus` (ok / stale / missing)

Given existence + updated date + threshold, returns `'ok'`, `'stale'`, or `'missing'`. `'ok'` renders as ✓ later.

**Files:**
- Modify: `scripts/lib.ps1` (append function)
- Modify: `tests/run-tests.ps1` (append assertions before the final tally block)

- [ ] **Step 1: Write the failing assertions** — insert into `run-tests.ps1` just before the `if ($script:fail ...)` tally:

```powershell
# --- Get-DiagramStatus ---
$now = [datetime]'2026-05-24'
Assert-Equal (Get-DiagramStatus -Exists $false -Now $now)                          'missing' 'missing when file absent'
Assert-Equal (Get-DiagramStatus -Exists $true -Updated '2026-05-20' -Now $now)     'ok'      'ok when recent'
Assert-Equal (Get-DiagramStatus -Exists $true -Updated '2026-01-01' -Now $now)     'stale'   'stale when older than threshold'
Assert-Equal (Get-DiagramStatus -Exists $true -Updated '' -Now $now)               'stale'   'stale when present but no date'
Assert-Equal (Get-DiagramStatus -Exists $true -Updated 'garbage' -Now $now)        'stale'   'stale when date unparseable'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1`
Expected: FAIL — `Get-DiagramStatus` not defined.

- [ ] **Step 3: Write minimal implementation** — append to `scripts/lib.ps1`:

```powershell
function Get-DiagramStatus {
    [CmdletBinding()]
    param(
        [bool]$Exists,
        [string]$Updated,
        [int]$ThresholdDays = 30,
        [datetime]$Now = (Get-Date)
    )
    if (-not $Exists) { return 'missing' }
    if ([string]::IsNullOrEmpty($Updated)) { return 'stale' }
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact(
        $Updated, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
    if (-not $ok) { return 'stale' }
    if (($Now.Date - $parsed.Date).Days -gt $ThresholdDays) { return 'stale' }
    return 'ok'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add scripts/lib.ps1 tests/run-tests.ps1
git commit -m "feat: Get-DiagramStatus classifies diagram freshness"
```

---

## Task 3: `Resolve-RepoName` (name -> repo, with candidates)

Given a name and a list of candidate repo names, resolves to one match or returns candidates for an ambiguous/no match.

**Files:**
- Modify: `scripts/lib.ps1`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing assertions** — insert before the tally:

```powershell
# --- Resolve-RepoName ---
$cands = @('cofferdam','calendaring','beads_viewer','rovikore-host','rovikore-demo','rovikore-landing-page')
Assert-Equal (Resolve-RepoName -Name 'cofferdam' -Candidates $cands).Match  'cofferdam'   'exact match'
Assert-Equal (Resolve-RepoName -Name 'COFFERDAM' -Candidates $cands).Match  'cofferdam'   'case-insensitive match'
Assert-Equal (Resolve-RepoName -Name 'calend'    -Candidates $cands).Match  'calendaring' 'single substring match'
Assert-Equal (Resolve-RepoName -Name 'zzz'       -Candidates $cands).Resolved $false      'no match -> unresolved'
$amb = Resolve-RepoName -Name 'rovikore' -Candidates $cands
Assert-Equal $amb.Resolved        $false 'ambiguous -> unresolved'
Assert-Equal $amb.Candidates.Count 3     'ambiguous -> returns all candidates'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1`
Expected: FAIL — `Resolve-RepoName` not defined.

- [ ] **Step 3: Write minimal implementation** — append to `scripts/lib.ps1`:

```powershell
function Resolve-RepoName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Candidates
    )
    $exact = @($Candidates | Where-Object { $_ -ceq $Name })
    if ($exact.Count -eq 1) { return [pscustomobject]@{ Resolved = $true; Match = $exact[0]; Candidates = @() } }
    $ci = @($Candidates | Where-Object { $_ -ieq $Name })
    if ($ci.Count -eq 1) { return [pscustomobject]@{ Resolved = $true; Match = $ci[0]; Candidates = @() } }
    $sub = @($Candidates | Where-Object { $_ -like "*$Name*" })
    if ($sub.Count -eq 1) { return [pscustomobject]@{ Resolved = $true; Match = $sub[0]; Candidates = @() } }
    return [pscustomobject]@{ Resolved = $false; Match = $null; Candidates = $sub }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add scripts/lib.ps1 tests/run-tests.ps1
git commit -m "feat: Resolve-RepoName resolves repo names with candidate fallback"
```

---

## Task 4: `Measure-BdJson` (defensive count of beads JSON)

Counts items in JSON output from `bd`/`gh`, tolerating array, object-with-array-field, or count-field shapes (their exact shape is not relied upon).

**Files:**
- Modify: `scripts/lib.ps1`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Write the failing assertions** — insert before the tally:

```powershell
# --- Measure-BdJson ---
Assert-Equal (Measure-BdJson '[{"id":1},{"id":2},{"id":3}]')        3 'counts bare array'
Assert-Equal (Measure-BdJson '{"issues":[{"id":1},{"id":2}]}')      2 'counts object.issues array'
Assert-Equal (Measure-BdJson '{"count":7}')                         7 'reads count field'
Assert-Equal (Measure-BdJson '')                                    0 'empty -> 0'
Assert-Equal (Measure-BdJson 'not json')                            0 'invalid json -> 0'
Assert-Equal (Measure-BdJson '[]')                                  0 'empty array -> 0'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1`
Expected: FAIL — `Measure-BdJson` not defined.

- [ ] **Step 3: Write minimal implementation** — append to `scripts/lib.ps1`:

```powershell
function Measure-BdJson {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return 0 }
    try { $o = $Json | ConvertFrom-Json } catch { return 0 }
    if ($null -eq $o) { return 0 }
    if ($o -is [System.Array]) { return $o.Count }
    foreach ($k in 'issues','beads','items','results','data','prs','pullRequests') {
        if (($o.PSObject.Properties.Name -contains $k) -and ($o.$k -is [System.Array])) { return $o.$k.Count }
    }
    foreach ($k in 'count','total') {
        if ($o.PSObject.Properties.Name -contains $k) { return [int]$o.$k }
    }
    return 1
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1`
Expected: PASS — all assertions across Tasks 1-4 ok.

- [ ] **Step 5: Commit**

```powershell
git add scripts/lib.ps1 tests/run-tests.ps1
git commit -m "feat: Measure-BdJson defensively counts tool JSON output"
```

---

## Task 5: `gather.ps1` — per-repo data collection

Three operations, selected by parameter set:
- `-Resolve <name>` → `{ resolved, match, path, candidates }`
- `-ListBeadsRepos` → `[ { name, path }, ... ]` for `~` dirs containing `.beads`
- `-RepoPath <path> [-Lite]` → the full envelope

**Files:**
- Create: `scripts/gather.ps1`
- Create: `tests/smoke-gather.ps1`

- [ ] **Step 1: Write `scripts/gather.ps1`**

```powershell
[CmdletBinding(DefaultParameterSetName='Gather')]
param(
    [Parameter(ParameterSetName='Resolve',   Mandatory)][string]$Resolve,
    [Parameter(ParameterSetName='ListBeads', Mandatory)][switch]$ListBeadsRepos,
    [Parameter(ParameterSetName='Gather',     Mandatory)][string]$RepoPath,
    [Parameter(ParameterSetName='Gather')][switch]$Lite,
    [string]$Root = $env:USERPROFILE,
    [int]$StaleDays = 30
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

function Get-RepoDirs([string]$root) {
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName '.git') } |
        Where-Object { $_.Name -notlike '*worktree*' -and $_.Name -notlike '*.wt' }
}

function Invoke-Tool([scriptblock]$Block) {
    # Returns @{ available=<bool>; output=<string|null> }. Never throws.
    try {
        $out = & $Block 2>$null
        if ($LASTEXITCODE -ne 0) { return @{ available = $false; output = $null } }
        return @{ available = $true; output = (@($out) -join "`n") }
    } catch {
        return @{ available = $false; output = $null }
    }
}

# --- Operation: Resolve ---
if ($PSCmdlet.ParameterSetName -eq 'Resolve') {
    $names = @(Get-RepoDirs $Root | ForEach-Object { $_.Name })
    $r = Resolve-RepoName -Name $Resolve -Candidates $names
    $path = $null
    if ($r.Resolved) { $path = (Join-Path $Root $r.Match) }
    [pscustomobject]@{
        resolved   = $r.Resolved
        match      = $r.Match
        path       = $path
        candidates = $r.Candidates
    } | ConvertTo-Json -Depth 8
    return
}

# --- Operation: ListBeadsRepos ---
if ($PSCmdlet.ParameterSetName -eq 'ListBeads') {
    $repos = @(Get-RepoDirs $Root |
        Where-Object { Test-Path (Join-Path $_.FullName '.beads') } |
        ForEach-Object { [pscustomobject]@{ name = $_.Name; path = $_.FullName } })
    ,$repos | ConvertTo-Json -Depth 8   # leading comma forces array even for 0/1 items
    return
}

# --- Operation: Gather ---
if (-not (Test-Path -LiteralPath $RepoPath)) {
    [pscustomobject]@{ error = "repo path not found: $RepoPath" } | ConvertTo-Json
    exit 1
}
$repoName    = Split-Path $RepoPath -Leaf
$hasBeads    = Test-Path (Join-Path $RepoPath '.beads')
$bvAvail     = [bool](Get-Command bv -ErrorAction SilentlyContinue) -and $hasBeads
$mkPath      = Join-Path $RepoPath 'docs\marketecture.md'
$mkExists    = Test-Path -LiteralPath $mkPath
$mkContent   = if ($mkExists) { Get-Content -LiteralPath $mkPath -Raw } else { '' }
$mkUpdated   = Get-MarketectureUpdated $mkContent
$mkStatus    = Get-DiagramStatus -Exists $mkExists -Updated $mkUpdated -ThresholdDays $StaleDays

Push-Location $RepoPath
try {
    $branch    = (& git rev-parse --abbrev-ref HEAD 2>$null)
    $remotes   = @(& git remote 2>$null)
    $hasRemote = [bool]($remotes.Count)
    $dirty     = @(& git status --porcelain 2>$null)
    $stashes   = @(& git stash list 2>$null)
    $commits   = @(& git log -5 --pretty=format:'%h %s' 2>$null)

    $ahead = 0; $behind = 0
    $counts = (& git rev-list --left-right --count '@{u}...HEAD' 2>$null)
    if ($LASTEXITCODE -eq 0 -and $counts) {
        $parts = $counts -split '\s+'
        if ($parts.Count -ge 2) { $behind = [int]$parts[0]; $ahead = [int]$parts[1] }
    }

    # beads
    $bdStatus = if ($hasBeads) { Invoke-Tool { bd status --json } } else { @{ available=$false; output=$null } }
    $bdInProg = if ($hasBeads) { Invoke-Tool { bd list --status=in_progress --json } } else { @{ available=$false; output=$null } }
    $bdReady  = if ($hasBeads) { Invoke-Tool { bd ready --json } } else { @{ available=$false; output=$null } }
    $bdBlock  = if ($hasBeads) { Invoke-Tool { bd blocked --json } } else { @{ available=$false; output=$null } }

    # bv
    $bvNext   = if ($bvAvail) { Invoke-Tool { bv --robot-next } } else { @{ available=$false; output=$null } }
    $bvTriage = if ($bvAvail -and -not $Lite) { Invoke-Tool { bv --robot-triage } } else { @{ available=$false; output=$null } }

    # gh
    $ghPrs    = if ($hasRemote) { Invoke-Tool { gh pr list --json number,title,state,updatedAt --limit 30 } } else { @{ available=$false; output=$null } }
    $ghIssues = if ($hasRemote -and -not $Lite) { Invoke-Tool { gh issue list --json number,title,state,updatedAt --limit 30 } } else { @{ available=$false; output=$null } }

    $env = [ordered]@{
        schema = 1
        lite   = [bool]$Lite
        repo   = [ordered]@{ name = $repoName; path = $RepoPath; has_beads = $hasBeads; has_remote = $hasRemote }
        git    = [ordered]@{
            branch         = $branch
            ahead          = $ahead
            behind         = $behind
            dirty_count    = $dirty.Count
            dirty_files    = if ($Lite) { @() } else { @($dirty) }
            stash_count    = $stashes.Count
            recent_commits = if ($Lite) { @() } else { @($commits) }
        }
        beads  = [ordered]@{
            available        = $hasBeads
            in_progress_count = Measure-BdJson $bdInProg.output
            ready_count       = Measure-BdJson $bdReady.output
            blocked_count     = Measure-BdJson $bdBlock.output
            status_raw        = if ($Lite) { $null } else { $bdStatus.output }
            in_progress_raw   = if ($Lite) { $null } else { $bdInProg.output }
            ready_raw         = if ($Lite) { $null } else { $bdReady.output }
            blocked_raw       = if ($Lite) { $null } else { $bdBlock.output }
        }
        bv     = [ordered]@{ available = $bvAvail; next_raw = $bvNext.output; triage_raw = $bvTriage.output }
        gh     = [ordered]@{
            available     = $hasRemote
            pr_count      = Measure-BdJson $ghPrs.output
            prs_raw       = if ($Lite) { $null } else { $ghPrs.output }
            issues_raw    = $ghIssues.output
        }
        marketecture = [ordered]@{
            exists  = $mkExists
            path    = 'docs/marketecture.md'
            updated = $mkUpdated
            status  = $mkStatus
            content = if ($Lite) { $null } else { $mkContent }
        }
    }
    $env | ConvertTo-Json -Depth 8
}
finally { Pop-Location }
```

- [ ] **Step 2: Write `tests/smoke-gather.ps1`** (integration; uses real `cofferdam`)

```powershell
$ErrorActionPreference = 'Stop'
$gather = Join-Path $PSScriptRoot '..\scripts\gather.ps1'
$fail = 0
function Check($cond, $msg) { if ($cond) { Write-Host "ok: $msg" } else { Write-Host "FAIL: $msg"; $script:fail++ } }

# Resolve
$r = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gather -Resolve 'cofferdam' | ConvertFrom-Json
Check ($r.resolved -eq $true) 'resolve cofferdam -> resolved'
Check ($r.path -like '*cofferdam') 'resolve returns a path'

# ListBeadsRepos returns valid JSON array
$repos = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gather -ListBeadsRepos | ConvertFrom-Json
Check ($null -ne $repos) 'list beads repos returns json'

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

if ($fail -gt 0) { Write-Host "`n$fail failure(s)"; exit 1 }
Write-Host "`nSmoke OK"; exit 0
```

- [ ] **Step 3: Run unit tests then smoke test**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1`
Expected: PASS (unchanged).
Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\smoke-gather.ps1`
Expected: `Smoke OK`. If a `Measure-BdJson` count looks wrong, inspect real shape with `bd ready --json` in `cofferdam` and extend the key list in `Measure-BdJson` (Task 4), re-run both tests.

- [ ] **Step 4: Commit**

```powershell
git add scripts/gather.ps1 tests/smoke-gather.ps1
git commit -m "feat: gather.ps1 collects per-repo envelope (resolve/list/gather)"
```

---

## Task 6: `SKILL.md` — frontmatter, arg parsing, mode dispatch

**Files:**
- Create: `SKILL.md`

- [ ] **Step 1: Write `SKILL.md` head + dispatch section**

Write the file beginning with this exact frontmatter and dispatch logic:

````markdown
---
name: daily-summary
description: Summarize a repo's state — marketecture diagram, in-flight work, open PRs/issues, and bv next steps — or roll up across all beads-tracked repos. Use when the user runs /daily-summary, asks for a daily or standup summary of a repo, wants a repo status overview, or asks to generate/refresh a repo's marketecture diagram (--prep).
---

# daily-summary

Summarize a repository (or roll up across all beads-tracked repos) and write a dated
markdown trail. A `--prep` stage generates and maintains each repo's marketecture diagram.

## Paths
- Gather script: `$env:USERPROFILE\.claude\skills\daily-summary\scripts\gather.ps1`
- Daily output dir: `$env:USERPROFILE\notes\daily\` (create if missing)
- Invoke the gather script with: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <gather.ps1> <args>`

## Parse the invocation

Read `$ARGUMENTS`. Determine the mode:

| Args | Mode |
|------|------|
| `--prep --all` | PREP-ALL |
| `--prep <repo>` | PREP-ONE |
| `--all` | ROLLUP |
| `<repo>` | SINGLE |
| (empty) | Ask the user: which repo, or `--all`? Then re-dispatch. |

To resolve `<repo>` to a path, run `gather.ps1 -Resolve <repo>`. If `resolved` is
false, print the `candidates` (or, if empty, run `gather.ps1 -ListBeadsRepos` and show
those names) and stop.

Today's date for filenames and the `updated:` marker: get it from the environment
(the date is provided in your context); format `YYYY-MM-DD`.
````

- [ ] **Step 2: Sanity check the frontmatter**

Run: `powershell.exe -NoProfile -Command "Get-Content '$env:USERPROFILE\.claude\skills\daily-summary\SKILL.md' -TotalCount 5"`
Expected: shows the `---` / `name:` / `description:` lines (valid frontmatter).

- [ ] **Step 3: Commit**

```powershell
git add SKILL.md
git commit -m "feat: SKILL.md frontmatter and mode dispatch"
```

---

## Task 7: `SKILL.md` — PREP stage

**Files:**
- Modify: `SKILL.md` (append)

- [ ] **Step 1: Append the PREP section**

````markdown
## PREP-ONE (`--prep <repo>`)

1. Resolve `<repo>` → path. Run `gather.ps1 -RepoPath <path>` and read the envelope.
2. **Infer** an ASCII boxes-and-arrows marketecture diagram for the repo from:
   - the repo's top-level structure and key modules (read what you need),
   - the repo's existing `CLAUDE.md` prose if present,
   - the beads picture (`marketecture` is *not* in the envelope yet for new repos;
     use `beads.*_raw` and, if useful, epics/labels) to label major components.
   Keep it conceptual (components + flow), not a folder tree. Mirror the ASCII style
   already used in the user's CLAUDE.md architecture blocks.
3. Build the proposed `docs/marketecture.md` content exactly in this shape:

   ```
   ## Marketecture

   <ascii diagram>

   <!-- marketecture:updated: YYYY-MM-DD -->
   ```

4. If `marketecture.exists` was true, show a diff vs the existing `content`; otherwise
   show the full proposed file. **Ask the user to approve** before writing. Do not write
   on decline.
5. On approval:
   - Write `docs/marketecture.md` (create `docs/` if needed).
   - Ensure `CLAUDE.md` references it. If `CLAUDE.md` does not already contain
     `@docs/marketecture.md`, append:

     ```
     ## Marketecture

     @docs/marketecture.md
     ```

     Create `CLAUDE.md` if absent. Never embed the diagram body in `CLAUDE.md`.
   - Leave both files **uncommitted**. Tell the user what changed.

## PREP-ALL (`--prep --all`)

Run `gather.ps1 -ListBeadsRepos`. For each repo, run the PREP-ONE flow (steps 1–5),
proposing and confirming per repo. Summarize at the end which repos were updated,
skipped, or declined.
````

- [ ] **Step 2: Verify the section is present**

Run: `powershell.exe -NoProfile -Command "Select-String -Path '$env:USERPROFILE\.claude\skills\daily-summary\SKILL.md' -Pattern 'PREP-ONE','PREP-ALL' | ForEach-Object Line"`
Expected: both headings found.

- [ ] **Step 3: Commit**

```powershell
git add SKILL.md
git commit -m "feat: SKILL.md prep stage (diagram inference + propose-confirm writes)"
```

---

## Task 8: `SKILL.md` — SINGLE report

**Files:**
- Modify: `SKILL.md` (append)

- [ ] **Step 1: Append the SINGLE section**

````markdown
## SINGLE (`<repo>`) — read-only

1. Resolve `<repo>` → path. Run `gather.ps1 -RepoPath <path>`; read the envelope.
2. Render this report (ASCII only), in this section order, to the terminal AND to
   `$env:USERPROFILE\notes\daily\<YYYY-MM-DD>-<repo>.md` (overwrite if it exists):

   1. **Header** — repo name, `git.branch`, ahead/behind (omit if both 0), timestamp.
   2. **Marketecture** — print `marketecture.content` verbatim. If
      `marketecture.exists` is false: "_No diagram yet — run `/daily-summary --prep
      <repo>` to create one._". Do **not** infer here.
   3. **In-flight work** — `in_progress` beads (from `beads.in_progress_raw`),
      `git.dirty_count` + `git.dirty_files`, `git.recent_commits`, `git.stash_count`.
   4. **Open PRs** — from `gh.prs_raw`. If `gh.available` is false, omit this section
      silently.
   5. **Open issues** — open beads + (if `gh.available`) `gh.issues_raw`.
   6. **Next steps** — from `bv.next_raw` / `bv.triage_raw`. If `bv.available` is
      false, fall back to `beads.ready_raw` (or note "no beads tracking" if
      `beads.available` is false too).
   7. **Beads health** — counts from `beads.status_raw` (open/ready/blocked/closed).
      If `beads.available` is false: "_No beads tracking in this repo._".
3. Tell the user the file path you wrote.
````

- [ ] **Step 2: Verify the section is present**

Run: `powershell.exe -NoProfile -Command "Select-String -Path '$env:USERPROFILE\.claude\skills\daily-summary\SKILL.md' -Pattern 'SINGLE .*read-only' | ForEach-Object Line"`
Expected: the SINGLE heading found.

- [ ] **Step 3: Commit**

```powershell
git add SKILL.md
git commit -m "feat: SKILL.md single-repo report"
```

---

## Task 9: `SKILL.md` — ROLLUP report + degradation reference

**Files:**
- Modify: `SKILL.md` (append)

- [ ] **Step 1: Append the ROLLUP + degradation section**

````markdown
## ROLLUP (`--all`) — read-only

1. Run `gather.ps1 -ListBeadsRepos` to get the repo set.
2. For each repo, run `gather.ps1 -RepoPath <path> -Lite`.
3. Render one compact table (ASCII) to the terminal AND to
   `$env:USERPROFILE\notes\daily\<YYYY-MM-DD>.md` (overwrite if it exists):

   ```
   repo | branch | dirty | in-prog | ready | blocked | PRs | bv top pick | diagram
   ```

   - `dirty` = `git.dirty_count` (or `-` if 0).
   - counts from `beads.*_count`, `gh.pr_count`.
   - `bv top pick` = the single recommendation extracted from `bv.next_raw` (or `-`).
   - `diagram` = `marketecture.status` mapped: `ok`→`✓`, `stale`→`stale`, `missing`→`missing`.
4. Below the table, list repos whose `diagram` is `stale` or `missing`, each with the
   suggestion `/daily-summary --prep <repo>`.
5. Never infer diagrams in this mode.

## Graceful degradation (all modes)

| Condition (from envelope) | Behavior |
|---------------------------|----------|
| `bv.available` false | Next steps fall back to `beads.ready_raw` |
| `beads.available` false | Beads/bv sections say "no beads tracking" |
| `gh.available` false | Omit Open PRs + gh issues silently |
| `marketecture.exists` false | SINGLE: prompt to run `--prep`. ROLLUP: `missing` |
| repo name unresolved | Print candidates (or `-ListBeadsRepos` names) and stop |
| envelope has `error` key | Report it; do not proceed for that repo |
````

- [ ] **Step 2: Verify the section is present**

Run: `powershell.exe -NoProfile -Command "Select-String -Path '$env:USERPROFILE\.claude\skills\daily-summary\SKILL.md' -Pattern 'ROLLUP','Graceful degradation' | ForEach-Object Line"`
Expected: both found.

- [ ] **Step 3: Commit**

```powershell
git add SKILL.md
git commit -m "feat: SKILL.md rollup report and degradation reference"
```

---

## Task 10: End-to-end acceptance

**Files:** none (verification only)

- [ ] **Step 1: Re-run all automated tests**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1`
Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\smoke-gather.ps1`
Expected: both green.

- [ ] **Step 2: Manual skill acceptance (run the skill itself)**

Invoke each mode and eyeball output:
- `/daily-summary cofferdam` — full report renders; marketecture section behaves (shows the prompt to prep if no `docs/marketecture.md` yet); a file appears at `notes\daily\<date>-cofferdam.md`.
- `/daily-summary --all` — table lists beads repos with valid `diagram` tokens; `notes\daily\<date>.md` written.
- `/daily-summary --prep cofferdam` — proposes a `docs/marketecture.md` + a `@docs/marketecture.md` CLAUDE.md reference, writes only on approval, leaves them uncommitted, and does not disturb existing CLAUDE.md prose.

Expected: all three behave per spec; degradation is graceful on a repo with no remote.

- [ ] **Step 3: Final commit**

```powershell
git add -A
git commit -m "test: end-to-end acceptance for daily-summary skill"
```

---

## Self-review notes (done by planner)

- **Spec coverage:** prep stage (Task 7), single report w/ 7 sections (Task 8), rollup table + staleness (Task 9), docs/marketecture.md + @import (Task 7), central output paths (Tasks 8–9), gh-skip-when-no-remote (gather + Tasks 8–9), bv→bd fallback (gather + degradation table), propose-and-confirm writes (Task 7). Covered.
- **Type consistency:** envelope field names used in SKILL.md (`beads.in_progress_raw`, `gh.prs_raw`, `marketecture.status`/`content`/`exists`, `git.dirty_files`, `bv.next_raw`) match `gather.ps1`'s `[ordered]` envelope keys exactly. Helper names (`Get-MarketectureUpdated`, `Get-DiagramStatus`, `Resolve-RepoName`, `Measure-BdJson`) are consistent across lib/tests/gather.
- **No placeholders:** all steps contain runnable code/commands and expected output.
