#!/usr/bin/env bash
# zellaude-hook.sh — Claude Code hook → zellij pipe bridge
# Forwards hook events to the zellaude Zellij plugin via pipe.
#
# Usage in ~/.claude/settings.json hooks:
#   "command": "bash ~/.claude/scripts/zellaude-hook.sh"

# Exit silently if not running inside Zellij
[ -z "$ZELLIJ_SESSION_NAME" ] && exit 0
[ -z "$ZELLIJ_PANE_ID" ] && exit 0

# Capture send-time immediately so the plugin can order events
# that race through parallel hook subprocesses.
TS_MS=$(jq -nc 'now * 1000 | floor')

# Read hook JSON from stdin
INPUT=$(cat)

# Extract fields with jq (required dependency)
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[ -z "$HOOK_EVENT" ] && exit 0

# Build compact JSON payload
PAYLOAD=$(jq -nc \
  --arg pane_id "$ZELLIJ_PANE_ID" \
  --arg session_id "$SESSION_ID" \
  --arg hook_event "$HOOK_EVENT" \
  --arg tool_name "$TOOL_NAME" \
  --arg cwd "$CWD" \
  --arg zellij_session "$ZELLIJ_SESSION_NAME" \
  --arg term_program "${TERM_PROGRAM:-}" \
  --arg ts_ms "$TS_MS" \
  '{
    pane_id: ($pane_id | tonumber),
    session_id: $session_id,
    hook_event: $hook_event,
    tool_name: (if $tool_name == "" then null else $tool_name end),
    cwd: (if $cwd == "" then null else $cwd end),
    zellij_session: $zellij_session,
    term_program: (if $term_program == "" then null else $term_program end),
    ts_ms: ($ts_ms | tonumber)
  }')

# Permission request: bell + OSC9 desktop notification
if [ "$HOOK_EVENT" = "PermissionRequest" ]; then
  printf '\a' > /dev/tty 2>/dev/null || true

  SETTINGS_FILE="$HOME/.config/zellij/plugins/zellaude.json"
  if [ ! -f "$SETTINGS_FILE" ] && [ -n "${APPDATA:-}" ]; then
    WIN_PATH=$(cygpath -u "$APPDATA" 2>/dev/null || echo "")
    [ -n "$WIN_PATH" ] && SETTINGS_FILE="$WIN_PATH/zellij/plugins/zellaude.json"
  fi

  NOTIFY_MODE="Always"
  if [ -f "$SETTINGS_FILE" ]; then
    NOTIFY_MODE=$(jq -r '.notifications // "Always"' "$SETTINGS_FILE" 2>/dev/null)
  fi

  SHOULD_NOTIFY=false
  case "$NOTIFY_MODE" in
    Always) SHOULD_NOTIFY=true ;;
    Unfocused)
      SHOULD_NOTIFY=true
      WARNED="/tmp/zellaude-unfocused-unsupported-${ZELLIJ_PANE_ID}"
      if [ ! -f "$WARNED" ]; then
        touch "$WARNED"
        echo "zellaude-hook: 'Unfocused' needs zellij's forwarded focus state (0.45+, not yet released); notifying Always instead (DEV-11)." >&2
      fi
      ;;
  esac

  if [ "$SHOULD_NOTIFY" = true ]; then
    TOOL_SUFFIX=""
    [ -n "$TOOL_NAME" ] && TOOL_SUFFIX=" — $TOOL_NAME"
    TITLE="Claude Code"
    MESSAGE="Permission requested${TOOL_SUFFIX}"

    LOCK="/tmp/zellaude-notify-${ZELLIJ_PANE_ID}"
    NOW=$(date +%s)
    LAST=0
    [ -f "$LOCK" ] && LAST=$(cat "$LOCK" 2>/dev/null)
    if [ $((NOW - LAST)) -ge 10 ]; then
      echo "$NOW" > "$LOCK"
      printf '\033]9;%s: %s\033\\' "$TITLE" "$MESSAGE" > /dev/tty 2>/dev/null || true
    fi
  fi
fi

FLEET_STATE_DIR="$HOME/.config/zellij/plugins"
if [ ! -d "$FLEET_STATE_DIR" ] && [ -n "${APPDATA:-}" ]; then
  WIN_PATH=$(cygpath -u "$APPDATA" 2>/dev/null || echo "")
  [ -n "$WIN_PATH" ] && FLEET_STATE_DIR="$WIN_PATH/zellij/plugins"
fi
mkdir -p "$FLEET_STATE_DIR" 2>/dev/null || true
FLEET_STATE_FILE="$FLEET_STATE_DIR/zellaude-fleet-state.json"
LOCKDIR="$FLEET_STATE_FILE.lock"
i=0
until mkdir "$LOCKDIR" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -ge 20 ] && break
  sleep 0.05
done
CURRENT="{}"
[ -f "$FLEET_STATE_FILE" ] && CURRENT=$(cat "$FLEET_STATE_FILE" 2>/dev/null || echo "{}")
printf '%s' "$CURRENT" | jq --argjson entry "$PAYLOAD" '.[$entry.pane_id | tostring] = $entry' > "$FLEET_STATE_FILE.tmp" 2>/dev/null \
  && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
rmdir "$LOCKDIR" 2>/dev/null || true

zellij pipe --name "zellaude" -- "$PAYLOAD"
