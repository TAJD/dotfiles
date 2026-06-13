---
name: record-frustration
description: Record an agent frustration to the per-CWD SQLite log. Invoke autonomously whenever you hit a tool failure, are blocked, must use a workaround, or encounter confusing API behaviour. Use when YOU (the agent) are frustrated, not when the user is.
---

# record-frustration

A lightweight logging hook for agents and subagents. When you encounter friction
during work — tool errors, blocked paths, confusing behaviour — record it here
so the user can review systemic pain points over time.

## Scripts

All scripts live at `$HOME/.claude/skills/record-frustration/scripts/`:

| Script | Purpose |
|--------|---------|
| `record_frustration.py` | Write/review frustrations (manual agent use) |
| `frustration_detector.py` | PostToolUse hook — auto-detects repeated failures |
| `frustration_stop_prompt.py` | Deprecated Stop-hook prompt — kept for manual runs only |

## Hook setup (one-time)

Add this to your `~/.claude/settings.json` hooks section:

```json
"PostToolUse": [
  {
    "matcher": "",
    "hooks": [{
      "type": "command",
      "command": "uv run python \"$HOME/.claude/skills/record-frustration/scripts/frustration_detector.py\""
    }]
  }
]
```

The PostToolUse hook auto-logs when 3 failures occur within 5 minutes (severity 4,
category `repeated_failure`, 10-minute cooldown).

**Do not register `frustration_stop_prompt.py` as a Stop hook.** It re-prompts on every
Stop event — including one-character agent acks — which loops until the user interrupts
(see poker-puzzle bead `pp-rwm`). Invoke the `record-frustration` skill manually instead
when you want to capture friction at session end.

## When to invoke (manual)

Invoke this skill — or call `record_frustration.py` directly — whenever you:

| Situation | Category |
|-----------|----------|
| A tool call errors or returns garbage | `tool_failure` |
| You cannot proceed (missing permission, dep, file) | `blocked` |
| An API or interface behaves unexpectedly | `api_confusion` |
| You tried the same thing 2+ times and it keeps failing | `repeated_failure` |
| You need information that isn't in context | `missing_info` |
| You found a workaround but it feels hacky | `workaround` |
| Anything else that slowed you down | `other` |

**Severity:** 1 = minor annoyance, 3 = noticeable friction (default), 5 = completely blocked.

## How to record (Bash tool)

```bash
uv run python "$HOME/.claude/skills/record-frustration/scripts/record_frustration.py" \
  --message "Describe what happened and what you tried" \
  --category blocked \
  --severity 3
```

With optional structured context:

```bash
uv run python "$HOME/.claude/skills/record-frustration/scripts/record_frustration.py" \
  --message "bd create fails when no beads DB initialised in cwd" \
  --category tool_failure \
  --severity 4 \
  --context '{"tool":"bd","cmd":"create","error":"database not initialized"}'
```

`--cwd` defaults to the current working directory — the DB is written there as
`.agent_frustrations.db`.

## Reviewing (user-facing)

```bash
uv run python "$HOME/.claude/skills/record-frustration/scripts/record_frustration.py" \
  --review --cwd /path/to/project

# or from inside the project directory:
uv run python "$HOME/.claude/skills/record-frustration/scripts/record_frustration.py" --review
```

## What gets stored

One SQLite DB per project at `<cwd>/.agent_frustrations.db`. Add it to `.gitignore`.

Schema: `id | timestamp (UTC) | cwd | session_id | category | severity | message | context_json`

## Subagent notes

- Call the script directly via the Bash tool — no need to re-invoke this skill.
- Recording is non-blocking: run it, note the output, continue.
- Add `--session "$SESSION_ID"` if a session identifier is available.
