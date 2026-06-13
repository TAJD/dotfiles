# update-toolchain — design

**Date:** 2026-05-20
**Status:** Design approved, pending implementation plan
**Owner:** tajdickson@protonmail.com

## Goal

A one-command update flow for the agentic toolchain on this Windows machine. Fast batch-and-report by default; opt-in deep mode for plugin/package ecosystems; minimal interactivity.

## Scope (v1)

In scope — the ten binaries verified on the machine 2026-05-20:

`nvim`, `zellij`, `bd`, `bv`, `cass`, `rtk`, `node`, `uv`, `gh`, `rustup`.

Explicitly excluded: `claude` (Claude Code) — Claude Code manages its own auto-update and is left out of this flow by design.

Explicitly out of scope for v1: git itself, OS-level winget upgrades, Neovim plugins (would live behind `-Deep` if added later), Python (`uv` manages it), pnpm (rarely needs updating; reconsider if it falls behind).

## Form factor

Two artifacts, with the script as source of truth:

- **`~/.claude/scripts/update-toolchain.ps1`** — the script. Invokable directly: `update-toolchain` or `update-toolchain -Deep`.
- **`~/.claude/skills/update-toolchain/SKILL.md`** — the skill. Invokable as `/update-toolchain`. Runs the script, parses the summary, handles failure follow-ups, optionally walks through `Manual` recipes interactively.

Direct script use is the fast path; the skill is for when something fails and you want help, or when you want the interactive walkthrough of manual-update tools.

## Public surface

```
update-toolchain.ps1 [-Deep] [-Strict] [-Only nvim,bd,...] [-Skip cass,rtk]
```

Flags compose freely. `-Only` and `-Skip` are mutually exclusive; passing both is a parse error.

- **`-Deep`** — adds `pnpm update -g` and `cargo install-update -a` (installing `cargo-update` first if missing). Reserved as the home for `:Lazy sync` and similar if added later.
- **`-Strict`** — fail-fast. Aborts on the first failure and rethrows. Default is continue-and-report.
- **`-Only <list>`** — run only these tools (comma-separated, lowercase names matching the dispatch table keys).
- **`-Skip <list>`** — run everything *except* these tools.

## Per-tool update commands

| Tool | Install method | Update command | Notes |
|---|---|---|---|
| `nvim` | winget (`Neovim.Neovim`) | `winget upgrade --id Neovim.Neovim --silent --accept-source-agreements` | |
| `zellij` | manual at `%LOCALAPPDATA%\Programs\zellij` | Download latest `zellij-x86_64-pc-windows-msvc.zip` from GitHub releases, extract over existing dir | Memory references an updater script "next to it" but the file is not present on 2026-05-20. Implementation must search the install dir first; if no script found, fall back to GitHub-release download. Re-verify and update memory after implementation. |
| `bd` | Go-installed (`~/go/bin`) | `bd upgrade` | Confirmed: subcommand exists. |
| `bv` | scoop | `scoop update bv` | |
| `cass` | manual (`~/.local/bin`) | Recipe: `& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.ps1"))) -EasyMode -Verify` | Returns `Manual` with this recipe in `Detail`. The installer is a download-and-replace; if you'd rather auto-run it, that's a one-line change to invoke `Invoke-Expression` instead. |
| `rtk` | manual (`~/.local/bin`) | Recipe: `cargo install --git https://github.com/rtk-ai/rtk --force` | Returns `Manual`. Auto-running it would rebuild from source on every invocation (slow); leaving manual keeps fast-path fast. |
| `node` | pnpm-managed | `pnpm env use --global lts` | |
| `uv` | manual (`~/.local/bin`) | `uv self update` | |
| `gh` | winget (`GitHub.cli`) | `winget upgrade --id GitHub.cli --silent --accept-source-agreements` | |
| `rustup` | winget (manages itself thereafter) | `rustup self update; rustup update` | |

## Per-tool function contract

Every updater function returns the same shape:

```powershell
[PSCustomObject]@{
    Tool   = 'nvim'           # lowercase, matches dispatch key
    Status = 'Updated'        # Updated | NoChange | Manual | Missing | Failed
    From   = 'v0.12.2'        # version string before update; null if Missing
    To     = 'v0.12.3'        # version string after update; null if Missing
    Detail = $null            # optional one-liner: error message, recipe, etc.
    LogPath = '...\nvim.log'  # path to per-tool captured output
}
```

Status semantics:
- **Updated** — version string changed.
- **NoChange** — already at latest.
- **Manual** — no automatic update path; `Detail` carries the recipe to run by hand. *Not* a failure.
- **Missing** — the binary is not on PATH; nothing to update. *Not* a failure.
- **Failed** — the update command errored. `Detail` carries the error summary; full output is in `LogPath`. In `-Strict` mode this rethrows.

## Logging and output

- Per-tool logs land in `~/.claude/scripts/.update-toolchain-logs/YYYY-MM-DD/<tool>.log` (overwritten if the same tool runs twice the same day). Combined stdout+stderr.
- Summary table prints at the end to stdout (see example below).
- Exit code: `0` if no `Failed`; `1` if any `Failed` (even outside `-Strict`).

```
Tool       Status     From → To
─────────────────────────────────────
nvim       NoChange   v0.12.2
zellij     Updated    v0.41.2 → v0.42.0
bd         NoChange   1.0.3
bv         Updated    0.8.1 → 0.8.3
cass       Manual     run: <recipe>
rtk        Manual     run: <recipe>
node       NoChange   22.20.0
uv         Updated    0.4.18 → 0.4.21
gh         Updated    2.82.0 → 2.92.0
rustup     NoChange   1.29.0
─────────────────────────────────────
Updated 4, NoChange 4, Manual 2, Failed 0  (11.8s)
```

## Skill behavior

`SKILL.md` is short and delegates almost everything to the script. Its job:

1. Run the script, capturing the result objects (not just stdout).
2. If any `Failed`, read the corresponding log files and propose a concrete fix per tool (e.g., "winget couldn't acquire the lock — close other installer windows and rerun with `-Only nvim`").
3. If any `Manual`, ask whether to walk through the recipes interactively, one at a time, confirming before each.
4. Otherwise print the summary and exit.

The skill does *not* re-implement the script's update logic.

## Failure handling

- Default: continue past failures, accumulate them, exit non-zero at the end. The next run is unaffected.
- `-Strict`: rethrow the first failure. Useful for debugging a single flaky tool with `-Only`.
- Network failures, lock contention, and admin-required upgrades all surface as `Failed` with their captured output in `LogPath`.

## Open TODOs (implementation phase, not design phase)

1. **Zellij updater script** — locate the script referenced in memory at `%LOCALAPPDATA%\Programs\zellij`, or commit to the GitHub-release fallback and update the memory entry.
2. **cass reinstall recipe** — confirm against the upstream install instructions.
3. **rtk reinstall recipe** — same.

These are placeholders in the dispatch table until confirmed; they return `Manual` with a `TODO: verify recipe` detail.

## Non-goals

- No config file. Per-tool overrides live in the script; if the install method for a tool changes, edit its function.
- No scheduling. If a recurring run is wanted later, that's `claude:schedule` or a Windows scheduled task wrapping the script — not part of this skill.
- No partial-update resumption. If a run is interrupted, just rerun it; the per-tool functions are idempotent.
