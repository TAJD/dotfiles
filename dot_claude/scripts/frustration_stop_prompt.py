#!/usr/bin/env python3
"""
Stop hook: prompt agent to self-assess frustrations before ending a session.

If recent auto-detected failures exist in the state file that haven't been
addressed by a manual log, outputs a brief prompt and exits 2 (which blocks
the stop in Claude Code and feeds the text back to the agent).

Exits 0 silently if nothing worth flagging.
"""

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

STATE_FILE = Path.home() / ".claude" / "frustration_state.jsonl"
COOLDOWN_FILE = Path.home() / ".claude" / "frustration_cooldown.json"

# Only prompt if there are this many failures and no auto-log already fired
MIN_FAILURES = 2
LOOKBACK_MINUTES = 60


def load_recent_failures() -> list[dict]:
    if not STATE_FILE.exists():
        return []
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=LOOKBACK_MINUTES)
    entries = []
    for line in STATE_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
            if datetime.fromisoformat(e["ts"]) > cutoff:
                entries.append(e)
        except Exception:
            pass
    return entries


def auto_log_already_fired() -> bool:
    """Return True if the auto-log already ran recently (cooldown set)."""
    if not COOLDOWN_FILE.exists():
        return False
    try:
        data = json.loads(COOLDOWN_FILE.read_text(encoding="utf-8"))
        cutoff = datetime.now(timezone.utc) - timedelta(minutes=LOOKBACK_MINUTES)
        for ts_str in data.values():
            if datetime.fromisoformat(ts_str) > cutoff:
                return True
    except Exception:
        pass
    return False


def main() -> None:
    failures = load_recent_failures()

    if len(failures) < MIN_FAILURES:
        sys.exit(0)

    if auto_log_already_fired():
        # Hook already caught a loop and auto-logged it; agent saw the threshold.
        # Only prompt if there are substantially more failures than the threshold.
        if len(failures) < 6:
            sys.exit(0)

    tools = list(dict.fromkeys(e["tool"] for e in failures))
    errors = [e["error"] for e in failures[-2:]]

    print(
        f"\n[frustration-check] {len(failures)} tool failure(s) detected in this session "
        f"(tools: {', '.join(tools)}).\n"
        f"Recent: {' | '.join(e[:80] for e in errors)}\n\n"
        f"Before finishing: did you encounter a wrong assumption, workaround, or "
        f"blocking issue worth logging? If yes, run:\n\n"
        f"  uv run python \"$HOME/.claude/scripts/record_frustration.py\" "
        f"--message \"...\" --category blocked|workaround --severity N\n\n"
        f"If nothing worth logging, just continue."
    )
    sys.exit(2)


if __name__ == "__main__":
    main()
