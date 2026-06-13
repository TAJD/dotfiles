# update-toolchain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a PowerShell script + Claude Code skill that updates the ten agentic-toolchain binaries with one command, returning a structured summary.

**Architecture:** Script is source of truth — one PowerShell function per tool returning a uniform `PSCustomObject`. Dispatch table drives execution. Skill wraps the script and handles failure/manual-recipe follow-ups.

**Tech Stack:** PowerShell 5.1 (Windows PowerShell), pnpm, winget, scoop, cargo, GitHub releases API for zellij.

**Spec:** [`DESIGN.md`](./DESIGN.md)

---

## Testing approach

This is a thin orchestration script over external CLIs. A dedicated test framework (Pester) is not in this repo and pulling it in just for this would be YAGNI. Verification is **manual run-and-observe** using the `-Only` flag to scope each task to its tool. The dispatch + summary logic is pure data manipulation and verified with a `-DryRun` flag added in Task 1.

## File structure

- Create: `~/.claude/scripts/update-toolchain.ps1` — the script (single file, ~300 LOC target)
- Create: `~/.claude/skills/update-toolchain/SKILL.md` — the skill wrapper
- Logs at runtime: `~/.claude/scripts/.update-toolchain-logs/YYYY-MM-DD/<tool>.log`

The script is one file by design — eleven small functions plus a dispatch table is easier to read in one place than across nine files.

---

## Task 1: Scaffolding — script skeleton with dispatch, dry-run, summary printer

**Files:**
- Create: `~/.claude/scripts/update-toolchain.ps1`

- [ ] **Step 1: Write the script scaffold**

```powershell
[CmdletBinding()]
param(
    [switch]$Deep,
    [switch]$Strict,
    [switch]$DryRun,
    [string[]]$Only,
    [string[]]$Skip
)

$ErrorActionPreference = 'Stop'
$script:LogDir = Join-Path $env:USERPROFILE ".claude\scripts\.update-toolchain-logs\$(Get-Date -Format 'yyyy-MM-dd')"
$null = New-Item -ItemType Directory -Force -Path $script:LogDir

function New-Result {
    param($Tool, $Status, $From, $To, $Detail, $LogPath)
    [PSCustomObject]@{ Tool=$Tool; Status=$Status; From=$From; To=$To; Detail=$Detail; LogPath=$LogPath }
}

function Invoke-Tool {
    param([string]$Name, [scriptblock]$Updater)
    $log = Join-Path $script:LogDir "$Name.log"
    if ($DryRun) { return New-Result $Name 'NoChange' 'dry-run' 'dry-run' $null $log }
    try {
        & $Updater $log
    } catch {
        if ($Strict) { throw }
        New-Result $Name 'Failed' $null $null $_.Exception.Message $log
    }
}

# Dispatch table — one entry per tool. Updater scriptblocks added in later tasks.
$script:Dispatch = [ordered]@{
    nvim   = { param($log) New-Result 'nvim'   'NoChange' 'stub' 'stub' $null $log }
    zellij = { param($log) New-Result 'zellij' 'NoChange' 'stub' 'stub' $null $log }
    bd     = { param($log) New-Result 'bd'     'NoChange' 'stub' 'stub' $null $log }
    bv     = { param($log) New-Result 'bv'     'NoChange' 'stub' 'stub' $null $log }
    cass   = { param($log) New-Result 'cass'   'NoChange' 'stub' 'stub' $null $log }
    rtk    = { param($log) New-Result 'rtk'    'NoChange' 'stub' 'stub' $null $log }
    node   = { param($log) New-Result 'node'   'NoChange' 'stub' 'stub' $null $log }
    uv     = { param($log) New-Result 'uv'     'NoChange' 'stub' 'stub' $null $log }
    gh     = { param($log) New-Result 'gh'     'NoChange' 'stub' 'stub' $null $log }
    rustup = { param($log) New-Result 'rustup' 'NoChange' 'stub' 'stub' $null $log }
}

# Filter via -Only / -Skip
if ($Only -and $Skip) { throw "-Only and -Skip are mutually exclusive" }
$tools = $script:Dispatch.Keys | Where-Object {
    (-not $Only -or $_ -in $Only) -and (-not $Skip -or $_ -notin $Skip)
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$results = foreach ($t in $tools) { Invoke-Tool -Name $t -Updater $script:Dispatch[$t] }
$sw.Stop()

# Summary table
"`nTool       Status     From → To"
"─" * 45
foreach ($r in $results) {
    $arrow = if ($r.From -ne $r.To -and $r.To) { "$($r.From) → $($r.To)" } else { $r.From }
    "{0,-10} {1,-10} {2}" -f $r.Tool, $r.Status, ($arrow ?? '')
}
"─" * 45
$counts = $results | Group-Object Status | ForEach-Object { "$($_.Name) $($_.Count)" }
"{0}  ({1:N1}s)" -f ($counts -join ', '), $sw.Elapsed.TotalSeconds

# Exit code: 1 if any Failed
if ($results.Status -contains 'Failed') { exit 1 } else { exit 0 }
```

Note: Windows PowerShell 5.1 lacks the `??` operator — replace the `($arrow ?? '')` line with `if ($arrow) { $arrow } else { '' }`.

- [ ] **Step 2: Verify dry-run end-to-end**

Run: `powershell -File "$env:USERPROFILE\.claude\scripts\update-toolchain.ps1" -DryRun`

Expected output:
```
Tool       Status     From → To
─────────────────────────────────────────────
nvim       NoChange   dry-run
zellij     NoChange   dry-run
... (8 more rows)
─────────────────────────────────────────────
NoChange 10  (0.1s)
```

- [ ] **Step 3: Verify -Only filtering**

Run: `... -DryRun -Only nvim,gh`

Expected: only `nvim` and `gh` rows.

- [ ] **Step 4: Verify -Only/-Skip mutual exclusion**

Run: `... -DryRun -Only nvim -Skip gh`

Expected: throws "-Only and -Skip are mutually exclusive".

---

## Task 2: Resolve open TODOs (cass/rtk install recipes)

The spec leaves cass and rtk install recipes as TODO. Resolve these before writing the dispatch entries so the `Manual` recipe strings are accurate.

- [ ] **Step 1: Find cass install instructions**

Check the cass binary for hints: `cass --help | Select-String -Pattern 'install|update'`.
Also: from the global `CLAUDE.md`, cass v0.3.4+ lives at `~/.local/bin/cass`. Check the repo it came from — likely GitHub. Search recent shell history or `cass robot-docs guide` for install hints.

If a one-liner install script exists (e.g. `irm https://.../install.ps1 | iex`), record it. Otherwise the recipe is "download latest release from <repo>/releases and replace `~/.local/bin/cass.exe`".

- [ ] **Step 2: Find rtk install instructions**

Same approach. `rtk --version` shows 0.37.2; binary is at `~/.local/bin/rtk.exe`. Look for install docs.

- [ ] **Step 3: Update DESIGN.md with verified recipes**

Replace the "TODO at implementation time" notes for cass and rtk with the actual recipes found. Keep the `Manual` status — these still don't auto-update — but the `Detail` field now carries a real command.

---

## Task 3: nvim and gh updaters (winget)

**Files:**
- Modify: `~/.claude/scripts/update-toolchain.ps1` (replace nvim and gh entries in `$script:Dispatch`)

- [ ] **Step 1: Add a winget helper and two updaters**

```powershell
function Update-WingetTool {
    param([string]$Name, [string]$WingetId, [string]$VersionCommand, [string]$LogPath)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        return New-Result $Name 'Missing' $null $null $null $LogPath
    }
    $before = & ([scriptblock]::Create($VersionCommand)) 2>&1 | Select-Object -First 1
    winget upgrade --id $WingetId --silent --accept-source-agreements --accept-package-agreements *>&1 |
        Tee-Object -FilePath $LogPath | Out-Null
    $after = & ([scriptblock]::Create($VersionCommand)) 2>&1 | Select-Object -First 1
    $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
    New-Result $Name $status $before $after $null $LogPath
}
```

Replace the nvim and gh entries:

```powershell
nvim = { param($log) Update-WingetTool -Name 'nvim' -WingetId 'Neovim.Neovim'  -VersionCommand 'nvim --version | Select-Object -First 1' -LogPath $log }
gh   = { param($log) Update-WingetTool -Name 'gh'   -WingetId 'GitHub.cli'     -VersionCommand 'gh --version | Select-Object -First 1' -LogPath $log }
```

- [ ] **Step 2: Verify nvim**

Run: `... -Only nvim`

Expected: `nvim NoChange v0.12.2` (or `Updated` if a newer release is out). Check `.update-toolchain-logs/YYYY-MM-DD/nvim.log` exists.

- [ ] **Step 3: Verify gh** (this one has a pending upgrade 2.82 → 2.92)

Run: `... -Only gh`

Expected: `gh Updated 2.82.0 → 2.92.0`. Verify with `gh --version`.

---

## Task 4: rustup updater

**Files:**
- Modify: `~/.claude/scripts/update-toolchain.ps1` (replace rustup dispatch entry)

- [ ] **Step 1: Add the rustup updater**

```powershell
rustup = {
    param($log)
    if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) { return New-Result 'rustup' 'Missing' $null $null $null $log }
    $before = (rustup --version) -join ' '
    rustup self update *>&1 | Tee-Object -FilePath $log | Out-Null
    rustup update          *>&1 | Tee-Object -FilePath $log -Append | Out-Null
    $after = (rustup --version) -join ' '
    $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
    New-Result 'rustup' $status $before $after $null $log
}
```

- [ ] **Step 2: Verify**

Run: `... -Only rustup`. Expected: `NoChange` or `Updated`; log shows both `rustup self update` and `rustup update` output.

---

## Task 5: bd updater

**Files:**
- Modify: `~/.claude/scripts/update-toolchain.ps1`

- [ ] **Step 1: Add the bd updater**

```powershell
bd = {
    param($log)
    if (-not (Get-Command bd -ErrorAction SilentlyContinue)) { return New-Result 'bd' 'Missing' $null $null $null $log }
    $before = (bd --version 2>&1) -join ' '
    bd upgrade *>&1 | Tee-Object -FilePath $log | Out-Null
    $after = (bd --version 2>&1) -join ' '
    $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
    New-Result 'bd' $status $before $after $null $log
}
```

- [ ] **Step 2: Verify**

Run: `... -Only bd`. Expected: a result row; log shows `bd upgrade` output.

---

## Task 6: bv updater (scoop)

**Files:**
- Modify: `~/.claude/scripts/update-toolchain.ps1`

- [ ] **Step 1: Add the bv updater**

```powershell
bv = {
    param($log)
    if (-not (Get-Command bv -ErrorAction SilentlyContinue)) { return New-Result 'bv' 'Missing' $null $null $null $log }
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        return New-Result 'bv' 'Failed' $null $null 'scoop not on PATH' $log
    }
    $before = (bv --version 2>&1) -join ' '
    scoop update bv *>&1 | Tee-Object -FilePath $log | Out-Null
    $after = (bv --version 2>&1) -join ' '
    $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
    New-Result 'bv' $status $before $after $null $log
}
```

- [ ] **Step 2: Verify**

Run: `... -Only bv`. Expected: result row; log shows `scoop update bv` output.

---

## Task 7: uv updater

**Files:**
- Modify: `~/.claude/scripts/update-toolchain.ps1`

- [ ] **Step 1: Add the uv updater**

```powershell
uv = {
    param($log)
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { return New-Result 'uv' 'Missing' $null $null $null $log }
    $before = (uv --version 2>&1) -join ' '
    uv self update *>&1 | Tee-Object -FilePath $log | Out-Null
    $after = (uv --version 2>&1) -join ' '
    $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
    New-Result 'uv' $status $before $after $null $log
}
```

- [ ] **Step 2: Verify**

Run: `... -Only uv`. Expected: result row; log shows `uv self update` output.

---

## Task 8: node updater (pnpm-managed)

**Files:**
- Modify: `~/.claude/scripts/update-toolchain.ps1`

- [ ] **Step 1: Add the node updater**

```powershell
node = {
    param($log)
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return New-Result 'node' 'Missing' $null $null $null $log }
    if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
        return New-Result 'node' 'Manual' $null $null 'pnpm not on PATH; install pnpm or update node manually' $log
    }
    $before = (node --version 2>&1) -join ' '
    pnpm env use --global lts *>&1 | Tee-Object -FilePath $log | Out-Null
    $after = (node --version 2>&1) -join ' '
    $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
    New-Result 'node' $status $before $after $null $log
}
```

- [ ] **Step 2: Verify**

Run: `... -Only node`. Expected: result row; log shows pnpm env output. Note: this currently uses LTS — if you'd rather track latest, swap `lts` for `latest`.

---

## Task 9: zellij updater (GitHub release fallback)

**Files:**
- Modify: `~/.claude/scripts/update-toolchain.ps1`

The spec's first preference was a local updater script, but on 2026-05-20 that script was not present. This task implements the GitHub-release fallback. If a local updater is rediscovered later, that's a one-line change to call it.

- [ ] **Step 1: Add the zellij updater**

```powershell
zellij = {
    param($log)
    $installDir = "$env:LOCALAPPDATA\Programs\zellij"
    $exe = Join-Path $installDir 'zellij.exe'
    if (-not (Test-Path $exe)) { return New-Result 'zellij' 'Missing' $null $null $null $log }

    $before = (& $exe --version 2>&1) -join ' '

    # GitHub releases API
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/zellij-org/zellij/releases/latest' -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -like '*x86_64-pc-windows-msvc*.zip' } | Select-Object -First 1
    if (-not $asset) {
        return New-Result 'zellij' 'Failed' $before $null 'no x86_64-pc-windows-msvc asset in latest release' $log
    }

    "Latest release: $($release.tag_name)" | Tee-Object -FilePath $log | Out-Null
    "Downloading: $($asset.browser_download_url)" | Tee-Object -FilePath $log -Append | Out-Null

    $tmp = New-TemporaryFile
    $zip = "$($tmp.FullName).zip"
    Move-Item $tmp.FullName $zip -Force
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $installDir -Force
    Remove-Item $zip -Force

    $after = (& $exe --version 2>&1) -join ' '
    $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
    New-Result 'zellij' $status $before $after $null $log
}
```

- [ ] **Step 2: Verify**

Close any running zellij instances first (file in use will fail the extract).

Run: `... -Only zellij`. Expected: result row; log lists release tag and download URL. If `Updated`, run `zellij --version` to confirm.

- [ ] **Step 3: Update the memory entry**

Memory `zellij_install.md` says an updater script lives next to the install. Either:
- (a) it's been removed — update the memory to reflect the new GitHub-release approach, or
- (b) you find it — update this dispatch entry to call it instead.

Pick one and update the memory file accordingly.

---

## Task 10: cass and rtk Manual stubs

**Files:**
- Modify: `~/.claude/scripts/update-toolchain.ps1`

These tools have no self-update. They return `Manual` with the verified recipe from Task 2.

- [ ] **Step 1: Add cass and rtk Manual stubs**

```powershell
cass = {
    param($log)
    if (-not (Get-Command cass -ErrorAction SilentlyContinue)) { return New-Result 'cass' 'Missing' $null $null $null $log }
    $version = (cass --version 2>&1) -join ' '
    # Replace <RECIPE> with the verified recipe from Task 2.
    New-Result 'cass' 'Manual' $version $version '<RECIPE>' $log
}

rtk = {
    param($log)
    if (-not (Get-Command rtk -ErrorAction SilentlyContinue)) { return New-Result 'rtk' 'Missing' $null $null $null $log }
    $version = (rtk --version 2>&1) -join ' '
    # Replace <RECIPE> with the verified recipe from Task 2.
    New-Result 'rtk' 'Manual' $version $version '<RECIPE>' $log
}
```

- [ ] **Step 2: Verify**

Run: `... -Only cass,rtk`. Expected: both report `Manual` with the recipe in the `Detail` column.

---

## Task 11: -Deep mode

**Files:**
- Modify: `~/.claude/scripts/update-toolchain.ps1`

Adds two extra steps that run *after* the dispatch loop when `-Deep` is set: `pnpm update -g` and `cargo install-update -a` (installing `cargo-update` first if missing).

- [ ] **Step 1: Add the deep block**

After the dispatch foreach but before the summary table:

```powershell
if ($Deep) {
    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
        $log = Join-Path $script:LogDir 'deep-pnpm.log'
        pnpm update -g *>&1 | Tee-Object -FilePath $log | Out-Null
        $results += New-Result 'pnpm-globals' 'Updated' $null $null 'pnpm update -g' $log
    }
    if (Get-Command cargo -ErrorAction SilentlyContinue) {
        $log = Join-Path $script:LogDir 'deep-cargo.log'
        if (-not (cargo install --list | Select-String -Pattern '^cargo-update v')) {
            cargo install cargo-update *>&1 | Tee-Object -FilePath $log | Out-Null
        }
        cargo install-update -a *>&1 | Tee-Object -FilePath $log -Append | Out-Null
        $results += New-Result 'cargo-binaries' 'Updated' $null $null 'cargo install-update -a' $log
    }
}
```

Note: `$results` was assigned by a `foreach` expression. Make sure it's an array — wrap the assignment as `$results = @(foreach ...)` so `+=` works for any count.

- [ ] **Step 2: Verify**

Run: `... -Deep -Only nvim` (limits the dispatch to one fast tool while still exercising deep mode).

Expected: nvim row plus `pnpm-globals` and `cargo-binaries` rows. Logs `deep-pnpm.log` and `deep-cargo.log` exist.

---

## Task 12: -Strict fail-fast

`-Strict` is already wired in `Invoke-Tool` (Task 1 rethrows when set). Confirm the behavior end-to-end.

- [ ] **Step 1: Verify -Strict aborts on first failure**

Temporarily edit one updater (e.g. `bd`) to `throw "synthetic failure"`.

Run: `... -Strict -Only nvim,bd,gh`

Expected: nvim runs, bd throws, script terminates with the error before gh runs. No summary table.

Then run the same without `-Strict`:

Expected: full summary table, bd shows `Failed` with detail "synthetic failure", exit code 1.

Revert the synthetic failure.

---

## Task 13: SKILL.md — Claude Code wrapper

**Files:**
- Create: `~/.claude/skills/update-toolchain/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

```markdown
---
name: update-toolchain
description: Run the agentic-toolchain updater script and handle failures or manual-update recipes interactively. Use when the user says "update my tools", "/update-toolchain", or asks about updating neovim/zellij/bd/bv/cass/rtk/uv/gh/rustup/node.
---

# update-toolchain

Wraps `~/.claude/scripts/update-toolchain.ps1`. The script is the source of truth for what gets updated and how; this skill handles the human-in-the-loop bits.

## Steps

1. Decide flags from the user's phrasing:
   - "deep update", "full update", "everything" → `-Deep`
   - "just check" / "preview" → `-DryRun`
   - "only X" / "just X" → `-Only X`
   - "skip X" / "everything except X" → `-Skip X`
2. Run the script, capturing structured results:
   ```powershell
   $results = & "$env:USERPROFILE\.claude\scripts\update-toolchain.ps1" <flags>
   ```
3. Print the summary the script emitted.
4. **If any `Failed`:** read each failure's `LogPath`, summarize what went wrong, and propose a concrete fix (e.g., "winget couldn't acquire the installer lock — close any open installer windows and run `update-toolchain.ps1 -Only nvim` to retry"). Do not auto-retry.
5. **If any `Manual`:** ask the user if they want to walk through the recipes one at a time. For each, show the recipe, ask to confirm, then run it after explicit yes.
6. **Otherwise:** report success and stop.

## Constraints

- Never silently re-run failed updates. The user decides whether to retry.
- Never run a `Manual` recipe without explicit per-recipe confirmation.
- Do not modify the script from inside the skill. If a recipe is wrong, surface that and ask whether to edit the script.
```

- [ ] **Step 2: Verify the skill is registered**

Run a quick Claude Code session and check `/update-toolchain` appears in the skill list. If not, check the frontmatter and file location.

---

## Task 14: End-to-end smoke test

- [ ] **Step 1: Run the full thing**

Close any running instances of the binaries being updated (especially zellij and nvim).

Run: `powershell -File "$env:USERPROFILE\.claude\scripts\update-toolchain.ps1"`

Expected:
- Ten rows in the summary.
- No `Failed` (or, if any, the `LogPath` actually contains the failure output).
- Today's log dir exists with one `.log` file per tool.
- `gh --version` reports 2.92.x (the pending upgrade from the install matrix is consumed).
- Exit code 0.

- [ ] **Step 2: Run with -Deep**

Run: `... -Deep`

Expected: ten tool rows plus `pnpm-globals` and `cargo-binaries`. `deep-pnpm.log` and `deep-cargo.log` exist.

- [ ] **Step 3: Optional — note any regressions**

If any tool changed its update mechanism between design and now, update DESIGN.md and the dispatch entry. Otherwise, done.

---

## Execution tracking

This repo (`~/.claude/`) is not a git repo and tasks are tracked via beads (`bd`) globally. When starting execution:

1. Create one bd issue per task above (`bd create --title="update-toolchain Task N: <name>" --type=task --priority=2`).
2. Mark `in_progress` when starting, close when done.
3. Use `bd dep add` so Task 3+ depend on Task 1, Task 11 depends on all tool tasks, etc.

Or, if running via `superpowers:subagent-driven-development`, the subagents handle their own tracking and the bd issues are optional bookkeeping.
