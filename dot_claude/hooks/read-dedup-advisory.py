#!/usr/bin/env python3
"""Claude Code PreToolUse hook: warn when a file is Read again unchanged.

Advisory only - it never denies. Measured on projektor DEV-55: 155 (session,
file) pairs were re-read on 2026-09-05 and repeat calls are 27.9% of all tool
output corpus-wide. Denying is unsafe (acting on stale content), so this only
tells the model what it already has. Fails open on any error.
"""
import json
import os
import sys
import time
from pathlib import Path

STATE_DIR = Path(os.environ.get("TEMP", "/tmp")) / "claude-read-dedup"
MAX_AGE_S = 24 * 3600


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    if payload.get("tool_name") != "Read":
        return 0

    tool_input = payload.get("tool_input") or {}
    target = tool_input.get("file_path")
    session = payload.get("session_id")
    if not target or not session:
        return 0

    try:
        resolved = str(Path(target).resolve())
    except Exception:
        resolved = target

    try:
        mtime = os.path.getmtime(resolved)
    except OSError:
        return 0

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state_path = STATE_DIR / f"{session}.json"
    state = load(state_path)

    now = time.time()
    state = {k: v for k, v in state.items() if now - v.get("seen", 0) < MAX_AGE_S}

    prior = state.get(resolved)
    state[resolved] = {"seen": now, "mtime": mtime, "n": (prior or {}).get("n", 0) + 1}

    try:
        tmp = state_path.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(state, fh)
        os.replace(tmp, state_path)
    except Exception:
        pass

    if not prior or prior.get("mtime") != mtime:
        return 0

    n = prior.get("n", 1)
    ago = int(now - prior.get("seen", now))
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "additionalContext": (
                f"[read-dedup] You already read {Path(resolved).name} "
                f"{n}x this session (last {ago}s ago) and nothing has written to it since. "
                "Its contents are already in your context - re-reading costs tokens on every "
                "later turn. Proceeding anyway; re-read only if you genuinely need it again."
            ),
        }
    }))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
