# cass — conversation history search

`cass` (v0.3.4+, at `~/.local/bin/cass`) is a unified search across coding-agent transcripts
(Claude Code, Codex, Gemini, etc.) on this machine. Use it whenever the user references prior
work I don't remember ("what was I doing yesterday?", "what changes were you validating?",
"find the session where we fixed X").

**Always use `--robot` / `--json` for machine-readable output.** Pipe through `rtk` for token
savings.

## Quick recipes

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

## When to reach for cass

- User references something from a prior session I have no record of.
- Debugging a recurring issue — check whether it was solved before.
- "What did we decide about X?" — search for the decision in transcripts.
- Onboarding into a worktree with no clear in-flight state — `cass sessions --current` finds
  the last session in this directory.

## Notes

- Index lives in the platform data dir; if `cass status --json` reports stale or missing,
  run `cass index --full` once.
- `cass robot-docs <topic>` — topics: `commands | examples | guide | schemas | exit-codes |
  env | paths`.
- Exit codes: 0 ok, 2 usage error, 3 missing index, 9 unknown.
- Prefer `--robot-format compact` or `toon` over default JSON when piping into the
  conversation to save tokens.
