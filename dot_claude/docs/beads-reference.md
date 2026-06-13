# Beads (bd) and Beads Viewer (bv) — issue tracking

Projects may use **bd** (beads) for issue tracking. Look for a `.beads/` directory at the repo
root. Run `bd prime` for full workflow context, or `bd onboard` for setup instructions.

## bd — quick reference

```bash
bd ready                    # find unblocked work
bd list                     # list open issues
bd show <id>                # show issue details
bd create "Title"           # create issue
bd close <id>               # complete work
bd search "query"           # search issues
bd status                   # database overview
bd prime                    # full workflow context
bd onboard                  # setup instructions
```

## Worktrees (use bd, not raw git)

`bd worktree` sets up a redirect so all worktrees share the same `.beads/` database.

```bash
bd worktree create feature-name            # create worktree with beads redirect
bd worktree create fix --branch fix-123    # create with specific branch
bd worktree list                           # list all worktrees
bd worktree remove feature-name            # remove with safety checks
bd worktree info                           # show current worktree info
```

All worktrees auto-discover the shared database via the main repo root. Concurrent reads are
safe; writes use file locking. For heavy worktree usage, set `BEADS_DIR` env var to point all
worktrees at a shared `.beads/` directory.

## bv — Beads Viewer (TUI + agent companion)

Run `bv` (no args) inside a beads-enabled repo to launch the TUI. For agent work, prefer the
`--robot-*` subcommands which emit JSON/TOON.

**Always pair robot output with `--format toon`** (or `BV_OUTPUT_FORMAT=toon`) for token
savings, and pipe through `rtk` like any other command.

### Agent-friendly commands

```bash
bv --robot-triage --format toon              # unified triage mega-command (start here)
bv --robot-next --format toon                # single top-pick recommendation
bv --robot-priority --format toon            # ranked priority recommendations
bv --robot-plan --format toon                # dependency-respecting execution plan
bv --robot-insights --format toon            # graph analysis + insights
bv --robot-alerts --format toon              # drift + proactive alerts
bv --robot-related <id> --format toon        # beads related to an ID
bv --robot-blocker-chain <id> --format toon  # full blocker chain for an ID
bv --robot-search --search "<query>" --format toon  # semantic search
bv --agent-brief ./brief                     # export triage/insights/brief bundle to dir
bv --robot-docs commands                     # machine-readable command reference
bv --robot-schema                            # JSON Schema for all robot commands
```

### Recipes & filtering

- `bv -r triage` (or `--recipe`) — apply a named recipe (`triage`, `actionable`,
  `high-impact`).
- `--label <name>` scopes analysis to a label's subgraph; `--robot-by-label` /
  `--robot-by-assignee` filter outputs.
- `--as-of <ref>` / `--diff-since <ref>` — view state at a point in time or diff against
  history.

### When to reach for bv

- Picking the next issue to work on → `--robot-next` or `--robot-triage`.
- Understanding why an issue is stuck → `--robot-blocker-chain <id>`.
- Sprint planning / capacity → `--robot-plan`, `--robot-capacity`, `--robot-forecast`.
- Spotting drift, stale issues, or orphan commits → `--robot-alerts`, `--robot-orphans`.
- Briefing a fresh agent on the project → `--agent-brief <dir>`.

### Notes

- `bv --robot-help` lists every robot command; `bv --robot-docs guide` is the full agent guide.
- For one-off scripted recommendations: `bv --emit-script --script-limit 5` outputs a shell
  script for the top picks.
