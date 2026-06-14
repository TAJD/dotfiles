## Model delegation (read first)

**Opus plans. Sonnet builds. Haiku looks up.** Opus costs ~5× Haiku per token — reach for it
only when reasoning quality changes the outcome.

- **Plan mode (`Shift+Tab` → `/model opusplan`)** for multi-file refactors, architecture, hard
  debugging. Opus reasons, then auto-demotes to Sonnet for execution.
- **Sonnet** is the default for implementation. Don't escalate to Opus unless Sonnet is
  visibly struggling with the *reasoning*, not just typing.
- **Delegate read-only / mechanical work to Haiku** via the Task tool with `model: "haiku"`:
  codebase search, log scans, test runs, doc lookups, formatting checks.
- **Delegate bounded implementation work to Sonnet** via the Task tool with
  `model: "sonnet"` (or a `model: sonnet` agent like `sonnet-builder`). Trigger when ALL of
  these hold: spec is unambiguous, scope is ~1–2 files / ~50–300 lines, no design choices
  remain, verification is mechanical (build/test/lint). Concrete examples: implementing a
  fully-specified check from a ticket, adding a formatter from a schema, porting a
  function between two known signatures, generating a fixture suite. **Anti-trigger**:
  anything that needs back-and-forth with me about design, anything where the failure mode
  is "wrong abstraction" rather than "wrong syntax."
- **Spawn subagents to protect main context**, not just for parallelism. If output would
  flood my conversation with stuff I won't reuse (long build logs, exhaustive file walks,
  whole-file rewrites I won't re-read), delegate it.
- **Parallelize independent tasks in a single message.** Never parallelize work with shared
  state or sequential dependencies. On Windows, treat `isolation: "worktree"` as unreliable
  — use sibling git worktrees for parallel fan-out (see `~/.claude/docs/spawning-sessions.md`), or run sequentially.
- **Don't spawn subagents for** single file reads, one-liner edits, or work needing
  back-and-forth iteration. The setup tax exceeds the savings below ~30 lines of output.

Full playbook (cost table, frontmatter syntax, worked examples) before nontrivial planning:
`~/.claude/docs/model-delegation.md`.

## Reviewing files (zellij auto-open)

When you ask me to review a local file — a spec, design doc, generated artifact,
or anything you want me to read in my editor — **open it for me in the same turn**
by running, via the Bash tool:

```bash
bash ~/.claude/scripts/zj-review.sh "<abs-path>" ["tab-name"]
```

It opens the file in a new named zellij tab with `$EDITOR` (nvim) and **no-ops
cleanly when I'm not in a zellij session** (plain terminal, IDE, CI), so it's
always safe to call. Don't wait to be asked — opening the file is part of asking
for the review. Multiple files → call it once per file.

**Spawning a Claude session in a new zellij tab** (e.g. to hand off follow-up
work): use the companion helper

```bash
printf '%s' "$continuation_prompt" | \
  bash ~/.claude/scripts/zj-claude.sh "<tab-name>" "<workdir-windows-path>" @-
```

It opens a cmd.exe tab, `cd /d`s into the dir, and launches
`claude --dangerously-skip-permissions --model sonnet` (spawned sessions default
to Sonnet; override with `MODEL=opus bash ~/.claude/scripts/zj-claude.sh ...`).
For anything non-trivial, **pipe the prompt in via `@-`** — the script writes it to a
unique ephemeral temp file under `$TMPDIR/claude-spawn`, so parallel spawns never clash
and nothing is left behind. Do NOT hand-write prompt files into `~/.claude` or other
tracked dirs. (`@<abs-path>` still works for a file you already have.) New zellij tabs
are **cmd.exe**, not bash/pwsh — never chain with `;` there.

**When spawning a session for a known task in the repo's project management tool:**
post the full continuation prompt as a **comment on that task** rather than writing
it to a local file. Pass the session the ticket URL as its entry point. This keeps
the prompt reviewable alongside the work, avoids accidental commits of prompt files,
and lets any agent or human resume from the ticket. The repo's CLAUDE.md identifies
which PM tool is in use and how to add comments.

**Spawning parallel workers, each in its own git worktree** (independent tasks that
would otherwise fight over the working tree): use `spawn-claude` (`~/.local/bin/`)

```bash
spawn-claude [--model <ref>] [--here] [--base <ref>] [--setup <cmd>] <name> <repo-dir> <prompt...>
```

It creates a worktree at `<repo>.wt/<name>` on branch `wt/<name>` (outside the repo
tree), then launches a worker there in a new tab. Parallel `spawn-claude`s are safe
because each gets its own worktree + branch. Defaults to `--model sonnet` (override
`--model opus`); `--here` runs in the repo with no worktree; `--setup "<cmd>"` runs
before claude (e.g. `pnpm install` for a fresh worktree). Full reference for all three
zellij helpers: `~/.claude/docs/spawning-sessions.md`.

## Conversation History Search (cass)

`cass` (at `~/.local/bin/cass`) is a unified search across coding-agent transcripts (Claude Code, Codex, Gemini, etc.) on this machine. Use it whenever the user references prior work you don't remember ("what was I doing yesterday?", "what changes were you validating?", "find the session where we fixed X").

**Always use `--robot` / `--json` for machine-readable output.** Pipe through `rtk` for token savings.

### Quick recipes

```bash
# Find sessions for the current workspace
cass sessions --current --json --limit 5

# Search across all transcripts (last 7 days, JSON)
cass search "playwright" --week --robot --limit 10

# Filter by agent or workspace
cass search "auth refactor" --agent "claude-code" --robot
cass search "bug" --workspace /c/Users/<you>/<project> --robot

# Aggregate (massive token savings for overview queries)
cass search "*" --json --aggregate agent --week
cass search "error" --json --aggregate date --days 30

# Drill into a hit
cass view <source_path> -n <line> -C 10        # 10 lines of context
cass expand <source_path> --line <line>        # surrounding messages
cass export <source_path> --format markdown    # full session as markdown

# Token-budgeted pagination (for huge results)
cass search "X" --robot --max-tokens 200 --request-id run-1 --limit 2 --robot-meta
cass search "X" --robot --cursor <_meta.next_cursor> --request-id run-1b
```

### When to reach for cass

- User references something from a prior session you have no record of.
- Debugging a recurring issue — check whether it was solved before.
- "What did we decide about X?" — search for the decision in transcripts.
- Onboarding into a worktree with no clear in-flight state — `cass sessions --current` finds the last session in this directory.

### Notes

- Index lives in the platform data dir; if `cass status --json` reports stale or missing, run `cass index --full` once.
- `cass robot-docs <topic>` — topics: `commands | examples | guide | schemas | exit-codes | env | paths`.
- Exit codes: 0 ok, 2 usage error, 3 missing index, 9 unknown.
- Prefer `--robot-format compact` or `toon` over default JSON when piping into the conversation to save tokens.

## Issue Tracking (Beads / bv)

Some projects still use **bd** (beads). If a `.beads/` directory exists, run `bd prime`
for full workflow context (`bd ready` / `bd show <id>` / `bd close <id>` /
`bd worktree create <name>`). **rovikore-host and paca have moved to Paca — beads is
read-only there; check the repo's own CLAUDE.md for which tracker is live.**

**bv** is the TUI viewer / agent companion for beads repos. For agent use, prefer
`--robot-*` subcommands paired with `--format toon` and piped through `rtk`. Start with
`bv --robot-triage`; `--robot-next` (top pick), `--robot-blocker-chain <id>` (why stuck),
`--robot-alerts` (drift), `--agent-brief <dir>` (brief a fresh agent). `bv --robot-docs guide`
is the full reference.

## Project-specific context

A local `PROJECTS.md` (kept out of this public repo) is a lookup index mapping each
project name to where its repo lives on this machine. When I name a project, `cd` to
its path and read that repo's own CLAUDE.md / README for detail — keep specifics
there, not in this file, so the core rules stay generic and portable.

@PROJECTS.md

@RTK.md
