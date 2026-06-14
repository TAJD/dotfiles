# Zellij session & worker spawning

Three helper scripts drive a zellij-based, multi-tab agent workflow on Windows.
All are **no-ops outside a zellij session**, so they're safe to call from a plain
terminal, an IDE, or CI.

| Script | Location | Purpose | Default model |
|--------|----------|---------|---------------|
| `zj-review.sh` | `~/.claude/scripts/` | Open a file in a new tab for review (in `$EDITOR`) | n/a |
| `zj-claude.sh` | `~/.claude/scripts/` | Spawn one autonomous Claude session in a new cmd.exe tab | **sonnet** |
| `spawn-claude` | `~/.local/bin/`     | Spawn a worktree-isolated Claude worker (parallel-safe) | **sonnet** |

Spawned workers default to **Sonnet** — these tabs do bounded, well-specified work
where Sonnet is the right tool ("Opus plans, Sonnet builds"). Override per-call
with `--model opus` (or `MODEL=opus`), or `/model` inside the session.

## `zj-review.sh` — open a file to read

```bash
bash ~/.claude/scripts/zj-review.sh "<abs-path>" ["tab-name"] ["editor"]
```

Opens `<file>` in a new named tab with `$EDITOR` (nvim by default). Use it to put a
spec/design/artifact in front of yourself without leaving the current pane.

## `zj-claude.sh` — one autonomous session

```bash
bash ~/.claude/scripts/zj-claude.sh "<tab>" "<dir>" "<prompt>"                  # inline text
printf '%s' "$prompt" | bash ~/.claude/scripts/zj-claude.sh "<tab>" "<dir>" @-  # via stdin (preferred)
bash ~/.claude/scripts/zj-claude.sh "<tab>" "<dir>" "@C:/path/to/prompt.md"     # existing file
```

Launches `claude --dangerously-skip-permissions --model sonnet` in a fresh tab,
`cd`'d into `<workdir>`. Runs in `<workdir>` directly — no worktree — so use it for
read-only or single-stream work.

**Long/complex prompts → pipe via `@-`.** The script reads stdin into a *unique
ephemeral* temp file under `$TMPDIR/claude-spawn` (auto-pruned after a day) and points
Claude at it. This avoids cmd.exe quoting issues AND the old foot-gun of hand-writing a
prompt to a fixed path like `~/.claude/foo-prompt.md` — those collide when spawns run in
parallel and litter tracked dirs. `@<file>` still works for a file you already have.

### Windows gotchas baked in
- **New zellij tabs are cmd.exe**, not bash/pwsh — the script `cd /d`s and submits
  the `cd` and the `claude` line separately (cmd has no `;` chaining).
- **Readiness race:** a fresh cmd.exe tab needs a beat to draw its prompt before it
  can receive keystrokes. The script settles after new-tab and after the `cd`; bump
  `ZJ_SETTLE` (default 1.5s) on a loaded box. Always confirm the launched tab shows
  `--dangerously-skip-permissions` — if the flags get clipped, the session stalls
  waiting for a human.

## `spawn-claude` — parallel worktree-isolated workers

```bash
spawn-claude [--here] [--base <ref>] [--setup <cmd>] [--model <ref>] <name> <repo-dir> <prompt...>
```

The workhorse for **parallel** agents. By default it creates a git worktree at
`<repo>.wt/<name>` on a new branch `wt/<name>` **outside** the repo tree, then runs
a Sonnet worker there in a new tab. Because each worker gets its own worktree and
branch, parallel `spawn-claude`s never fight over the working tree.

```bash
# three workers on isolated worktrees, each on Sonnet
spawn-claude api    /c/Users/tajdi/myrepo "Implement the REST endpoints from docs/api.md"
spawn-claude tests  /c/Users/tajdi/myrepo "Write tests for the auth module"
spawn-claude --model opus design /c/Users/tajdi/myrepo "Refactor the storage layer"

# run in the repo itself (no worktree), install deps first
spawn-claude --here --setup "pnpm install" ui /c/Users/tajdi/myrepo "Build the settings page"
```

Options: `--here` (run in the repo, no worktree) · `--base <ref>` (branch off a ref;
default origin/main → main/master → HEAD) · `--setup <cmd>` (run before claude, e.g.
`pnpm install` for a fresh worktree) · `--model <ref>` (default sonnet) ·
`--dry-run` (print the worktree + layout commands without executing).

### Notes
- Pins this shell's Git-bash absolute path (native zellij would otherwise exec the
  WSL `bash.exe` off the Windows PATH). Paths are `cygpath -m`'d; the prompt rides in
  a temp file so no shell/KDL quoting can mangle it.
- The generated layout includes the tab-bar + status-bar plugin panes, matching
  zellij's default `new_tab_template` — a bare `layout { pane }` would drop the tab
  strip from view.
- Only ever **creates** a tab, never closes one. Clean up worktrees with
  `git worktree remove <repo>.wt/<name>` when done.
