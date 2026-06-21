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

# PREFERRED for long/multi-step prompts from Claude Code's Bash tool:
# write prompt to a temp file FIRST, then pass @<path> — avoids @- stdin issues
cat > /tmp/prompt-<name>.md << 'EOF'
<full task spec here>
EOF
spawn-claude <name> /c/Users/tajdi/myrepo @/tmp/prompt-<name>.md
```

**Passing long prompts from Claude Code's Bash tool:** `@-` (stdin piping) does NOT work from the Claude Code Bash tool environment — the pipe never delivers. The reliable pattern is:
1. Write the full prompt to `/tmp/prompt-<name>.md` using a heredoc
2. Pass `@/tmp/prompt-<name>.md` as the `<prompt...>` arg

spawn-claude reads the `@<file>` before launching, so the entire spec becomes Claude's first message with no race condition. Never pass `"Read PROMPT.md..."` as the launch prompt and write the file separately — there is a race between spawn and the file write.

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
- Only ever **creates** a tab. To tear down a session when done, use `zj-worktree-close.sh`.

## `zj-worktree-close.sh` — tear down a worktree session

```bash
bash ~/.claude/scripts/zj-worktree-close.sh [--force] [--no-tab] <tab-name> <repo-dir>
```

Closes the named zellij tab, removes the git worktree at `<repo>.wt/<name>`, and
deletes the local `wt/<name>` branch. Refuses to delete a branch with unmerged commits
unless `--force` is passed. `--no-tab` skips the zellij step (worktree + branch only).

```bash
# Normal teardown after the session merged its branch
bash ~/.claude/scripts/zj-worktree-close.sh projektor-access 'C:\Users\tajdi\projektor-workspace'

# Already merged / want to force-delete
bash ~/.claude/scripts/zj-worktree-close.sh --force projektor-access 'C:\Users\tajdi\projektor-workspace'
```

## Warm node_modules with `spawn-claude --warm-from`

A fresh worktree has no `node_modules`. The `--setup "pnpm install"` flag handles it
but takes time. `--warm-from <dir>` copies `node_modules` subtrees from an existing
install before running `--setup`, making the install near-instant:

```bash
spawn-claude \
  --warm-from 'C:\Users\tajdi\projektor-workspace' \
  --setup "pnpm install --frozen-lockfile --prefer-offline" \
  my-feature 'C:\Users\tajdi\projektor-workspace' "Implement X"
```

It copies `<warm-from>/node_modules` and `<warm-from>/*/node_modules` into the new
worktree. Pair always with `--prefer-offline` so pnpm reuses the local store.

## Prompt template rules (apply to both scripts)

Every session prompt — whether piped to `zj-claude.sh` or passed to `spawn-claude` — must include these lines in a **Finish line** section:

```
## Finish line
1. Run the project's pre-commit check (e.g. `mix precommit`) before committing.
2. Commit to the current worktree branch.
3. Push to `wt/<name>` — **do NOT push to main or any other branch**.
4. Update the task tracker when done.
```

**Why "do NOT push to main" must be explicit:** a session working in a worktree on `wt/<name>` can push to `origin/main` if prompted to "push to main" — it just runs `git push origin HEAD:main`. If the controller also cherry-picks the commit locally, you get two different SHAs for the same change and a non-fast-forward error requiring a rebase. Stating the branch explicitly in the prompt eliminates this.

For rovikore-host tasks a filled-in template lives at `.claude/templates/zj-session-prompt.md` in the repo.
