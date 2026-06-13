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
  remain, verification is mechanical (build/test/lint). Concrete examples: writing a new
  cofferdam check from a fully-specified bead, adding a formatter from a schema, porting a
  function between two known signatures, generating a fixture suite. **Anti-trigger**:
  anything that needs back-and-forth with me about design, anything where the failure mode
  is "wrong abstraction" rather than "wrong syntax."
- **Spawn subagents to protect main context**, not just for parallelism. If output would
  flood my conversation with stuff I won't reuse (long build logs, exhaustive file walks,
  whole-file rewrites I won't re-read), delegate it.
- **Parallelize independent tasks in a single message.** Never parallelize work with shared
  state or sequential dependencies. On Windows, treat `isolation: "worktree"` as unreliable
  — use real `bd worktree create` directories for parallel fan-out, or run sequentially.
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
bash ~/.claude/scripts/zj-claude.sh "<tab-name>" "<workdir-windows-path>" "@<abs-prompt-file>"
```

It opens a cmd.exe tab, `cd /d`s into the dir, and launches
`claude --dangerously-skip-permissions --model sonnet` (spawned sessions default
to Sonnet; override with `MODEL=opus bash ~/.claude/scripts/zj-claude.sh ...`).
For anything non-trivial, write the
continuation prompt to a file and pass `@<abs-path>` (avoids cmd quoting issues).
New zellij tabs are **cmd.exe**, not bash/pwsh — never chain with `;` there.

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
cass search "hyrox" --agent "claude-code" --robot
cass search "bug" --workspace /c/Users/tajdi/bestefforttools --robot

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

## Issue Tracking (Beads)

Projects may use **bd** (beads) for issue tracking. Look for a `.beads/` directory.
Run `bd prime` for workflow context, or `bd onboard` for setup instructions.

Quick reference:
- `bd ready` — find unblocked work
- `bd list` — list open issues
- `bd create "Title"` — create issue
- `bd close <id>` — complete work
- `bd worktree create <name>` — create worktree with beads redirect
- `bd prime` — full workflow context

## Beads Viewer (bv)

`bv` is a TUI viewer and AI-agent companion for beads issue trackers. Run `bv` (no args) inside a beads-enabled repo to launch the TUI; for agent work, prefer the `--robot-*` subcommands which emit JSON/TOON.

**Always pair robot output with `--format toon`** (or `BV_OUTPUT_FORMAT=toon`) for token savings, and pipe through `rtk` like any other command.

### Agent-friendly commands

```bash
bv --robot-triage --format toon            # unified triage mega-command (start here)
bv --robot-next --format toon              # single top-pick recommendation
bv --robot-priority --format toon          # ranked priority recommendations
bv --robot-plan --format toon              # dependency-respecting execution plan
bv --robot-insights --format toon          # graph analysis + insights
bv --robot-alerts --format toon            # drift + proactive alerts
bv --robot-related <id> --format toon      # beads related to an ID
bv --robot-blocker-chain <id> --format toon  # full blocker chain for an ID
bv --robot-search --search "<query>" --format toon  # semantic search
bv --agent-brief ./brief                   # export triage/insights/brief bundle to dir
bv --robot-docs commands                   # machine-readable command reference
bv --robot-schema                          # JSON Schema for all robot commands
```

### Recipes & filtering

- `bv -r triage` (or `--recipe`) — apply a named recipe (`triage`, `actionable`, `high-impact`).
- `--label <name>` scopes analysis to a label's subgraph; `--robot-by-label` / `--robot-by-assignee` filter outputs.
- `--as-of <ref>` / `--diff-since <ref>` — view state at a point in time or diff against history.

### When to reach for bv

- Picking the next issue to work on → `--robot-next` or `--robot-triage`.
- Understanding why an issue is stuck → `--robot-blocker-chain <id>`.
- Sprint planning / capacity → `--robot-plan`, `--robot-capacity`, `--robot-forecast`.
- Spotting drift, stale issues, or orphan commits → `--robot-alerts`, `--robot-orphans`.
- Briefing a fresh agent on the project → `--agent-brief <dir>`.

### Notes

- `bv --robot-help` lists every robot command; `bv --robot-docs guide` is the full agent guide.
- For one-off scripted recommendations: `bv --emit-script --script-limit 5` outputs a shell script for the top picks.

@RTK.md
