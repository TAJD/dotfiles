---
name: update-toolchain
description: Run the agentic-toolchain updater script and handle failures or manual-update recipes interactively. Use when the user says "update my tools", "/update-toolchain", or asks about updating neovim/zellij/bd/bv/cass/rtk/uv/gh/rustup/node.
---

# update-toolchain

Wraps `~/.claude/scripts/update-toolchain.ps1`. The script is the source of truth for what gets updated and how; this skill handles the human-in-the-loop bits.

## Steps

1. Decide flags from the user's phrasing:
   - "deep update", "full update", "everything" → `-Deep`
   - "just check" / "preview" / "dry run" → `-DryRun`
   - "only X" / "just X" → `-Only X`
   - "skip X" / "everything except X" → `-Skip X`
   - "fail fast" / "stop on error" → `-Strict`
2. Confirm with the user if `-Deep` is selected: `-Deep` also runs `pnpm update -g` (touches Claude Code) and `cargo install-update -a` (touches all cargo binaries). Make sure that's what they want.
3. Run the script with the resolved flags:
   ```powershell
   $results = & "$env:USERPROFILE\.claude\scripts\update-toolchain.ps1" <flags>
   ```
   The script also writes its summary to stdout — that's the user-facing report.
4. **If any row has Status = `Failed`:** read its `LogPath` (or surface the `Detail` for synthetic/early failures), summarize the cause in one line, and propose a concrete next step. Do not auto-retry — the user decides.
5. **If any row has Status = `Manual`:** ask the user if they want to walk through the recipes one at a time. For each, show the recipe from the `Detail` field, ask to confirm, then execute after explicit yes.
6. **Otherwise:** print the summary and stop.

## Constraints

- Never silently re-run a `Failed` update.
- Never run a `Manual` recipe without per-recipe confirmation.
- Do not edit the script from inside the skill — if a recipe is wrong, surface that and ask whether to fix the script.
- `cass` and `rtk` are intentionally `Manual` even when their recipes are automatable. Don't "improve" this without asking — the design call was to keep the fast path fast (rtk's `cargo install --git --force` rebuilds from source).

## Notes for the assistant

- The script returns `PSCustomObject` rows from the dispatch loop (and `-Deep` block when set). You can inspect `$results.Status`, `$results.Detail`, etc. directly when needed.
- Log dir: `~/.claude/scripts/.update-toolchain-logs/<YYYY-MM-DD>/<tool>.log`.
- Exit code is `1` if any `Failed`, `0` otherwise. `Manual` and `Missing` are not failures.
