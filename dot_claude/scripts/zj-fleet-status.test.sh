#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

pass=0
fail=0
check() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $desc"
    echo "  want: $want"
    echo "  got:  $got"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

run_hook() {
  ZELLIJ_SESSION_NAME=test-session ZELLIJ_PANE_ID="$1" bash -c "echo '$2' | env -u APPDATA bash zellaude-hook.sh" 2>/dev/null || true
}

run_hook 1 '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","cwd":"/c/repo.wt/DEV-1"}' >/dev/null
run_hook 2 '{"hook_event_name":"PreToolUse","session_id":"s2","tool_name":"Edit","cwd":"/c/repo.wt/DEV-2"}' >/dev/null

STATE_FILE="$HOME/.config/zellij/plugins/zellaude-fleet-state.json"
check "state file created" "$([ -f "$STATE_FILE" ] && echo yes || echo no)" "yes"
check "pane 1 tracked" "$(jq -r '."1".cwd' "$STATE_FILE")" "C:/repo.wt/DEV-1"
check "pane 2 tracked" "$(jq -r '."2".hook_event' "$STATE_FILE")" "PreToolUse"

run_hook 1 '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash","cwd":"/c/repo.wt/DEV-1"}' >/dev/null
check "pane 1 overwritten by later event" "$(jq -r '."1".hook_event' "$STATE_FILE")" "PostToolUse"
check "pane 1 cwd unchanged by overwrite" "$(jq -r '."1".cwd' "$STATE_FILE")" "C:/repo.wt/DEV-1"
check "pane count stable after overwrite" "$(jq 'length' "$STATE_FILE")" "2"

OUT=$(HOME="$HOME" APPDATA= env -u GH_TOKEN bash zj-fleet-status.sh 2>&1)
check "render includes pane 1 ticket slug" "$(printf '%s' "$OUT" | grep -c 'DEV-1')" "1"
check "render includes pane 2 ticket slug" "$(printf '%s' "$OUT" | grep -c 'DEV-2')" "1"

EMPTY_HOME="$TMP/empty-home"
mkdir -p "$EMPTY_HOME"
OUT2=$(HOME="$EMPTY_HOME" APPDATA= bash zj-fleet-status.sh; echo "exit:$?")
check "no state file yields friendly message and exit 0" "$(printf '%s' "$OUT2" | tail -1)" "exit:0"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
