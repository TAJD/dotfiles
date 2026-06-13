#!/usr/bin/env python3
"""
PostToolUse hook: detect repeated tool failures and auto-log to frustration DB.

Reads hook JSON from stdin, updates a rolling state file, fires
record_frustration.py when 3 failures occur within 5 minutes for the same
session. A 10-minute cooldown prevents spam once triggered.
"""

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

THRESHOLD = 3
WINDOW_MINUTES = 5
COOLDOWN_MINUTES = 10

STATE_FILE = Path.home() / ".claude" / "frustration_state.jsonl"
COOLDOWN_FILE = Path.home() / ".claude" / "frustration_cooldown.json"
RECORD_SCRIPT = Path.home() / ".claude" / "scripts" / "record_frustration.py"

# Error patterns for non-Bash tools
ERROR_PATTERNS = [
    "error:", "not found", "failed", "cannot", "no such file",
    "permission denied", "does not exist", "invalid", "unexpected",
]


def is_failure(data: dict) -> tuple[bool, str]:
    tool = data.get("tool_name", "")
    response = data.get("tool_response", {})

    if isinstance(response, str):
        output = response
    elif isinstance(response, dict):
        output = (
            response.get("output", "")
            or response.get("error", "")
            or str(response)
        )
    else:
        output = str(response)

    if tool == "Bash":
        m = re.search(r"Exit code:\s*(\d+)", output)
        if m and m.group(1) != "0":
            return True, f"Bash exit {m.group(1)}: {output[:120].strip()}"
        lower = output.lower()
        if any(p in lower for p in ERROR_PATTERNS):
            return True, output[:120].strip()
        return False, ""

    # All other tools: look for error signals in output
    lower = output.lower()
    if any(p in lower for p in ERROR_PATTERNS):
        return True, f"{tool}: {output[:120].strip()}"

    return False, ""


def get_cwd(data: dict) -> str:
    inp = data.get("tool_input", {})
    if isinstance(inp, dict) and "cwd" in inp:
        return inp["cwd"]
    return os.getcwd()


def load_state() -> list[dict]:
    if not STATE_FILE.exists():
        return []
    entries = []
    for line in STATE_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return entries


def save_state(entries: list[dict]) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with STATE_FILE.open("w", encoding="utf-8") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")


def is_in_cooldown(session_id: str) -> bool:
    if not COOLDOWN_FILE.exists():
        return False
    try:
        data = json.loads(COOLDOWN_FILE.read_text(encoding="utf-8"))
        last_str = data.get(session_id)
        if last_str:
            last = datetime.fromisoformat(last_str)
            if datetime.now(timezone.utc) - last < timedelta(minutes=COOLDOWN_MINUTES):
                return True
    except Exception:
        pass
    return False


def set_cooldown(session_id: str) -> None:
    data: dict = {}
    if COOLDOWN_FILE.exists():
        try:
            data = json.loads(COOLDOWN_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    data[session_id] = datetime.now(timezone.utc).isoformat()
    COOLDOWN_FILE.write_text(json.dumps(data), encoding="utf-8")


def main() -> None:
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            return
        data = json.loads(raw)
    except Exception:
        return

    failed, error_summary = is_failure(data)
    if not failed:
        return

    session_id = data.get("session_id", "unknown")
    cwd = get_cwd(data)
    tool = data.get("tool_name", "unknown")
    now = datetime.now(timezone.utc)

    # Load state, prune to window
    entries = load_state()
    cutoff = now - timedelta(minutes=WINDOW_MINUTES)
    entries = [
        e for e in entries
        if datetime.fromisoformat(e["ts"]) > cutoff
    ]

    entries.append({
        "ts": now.isoformat(),
        "session_id": session_id,
        "tool": tool,
        "cwd": cwd,
        "error": error_summary[:200],
    })
    save_state(entries)

    session_failures = [e for e in entries if e["session_id"] == session_id]
    if len(session_failures) < THRESHOLD:
        return

    if is_in_cooldown(session_id):
        return

    # Build a descriptive message from recent failures
    tools_seen = list(dict.fromkeys(e["tool"] for e in session_failures))
    recent_errors = [e["error"] for e in session_failures[-3:]]
    message = (
        f"Auto-detected: {len(session_failures)} failures in {WINDOW_MINUTES}min "
        f"(tools: {', '.join(tools_seen)}). "
        f"Errors: {' | '.join(recent_errors)}"
    )

    try:
        subprocess.run(
            [
                "uv", "run", "python", str(RECORD_SCRIPT),
                "--message", message[:500],
                "--category", "repeated_failure",
                "--severity", "4",
                "--cwd", cwd,
                "--session", session_id,
                "--context", json.dumps({
                    "auto_detected": True,
                    "tools": tools_seen,
                    "failure_count": len(session_failures),
                    "window_minutes": WINDOW_MINUTES,
                }),
            ],
            capture_output=True,
            timeout=15,
        )
        set_cooldown(session_id)
    except Exception:
        pass


if __name__ == "__main__":
    main()
