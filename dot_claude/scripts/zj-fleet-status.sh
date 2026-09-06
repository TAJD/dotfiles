#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="$HOME/.config/zellij/plugins"
if [ ! -d "$STATE_DIR" ] && [ -n "${APPDATA:-}" ]; then
  WIN_PATH=$(cygpath -u "$APPDATA" 2>/dev/null || echo "")
  [ -n "$WIN_PATH" ] && STATE_DIR="$WIN_PATH/zellij/plugins"
fi
STATE_FILE="$STATE_DIR/zellaude-fleet-state.json"
PR_CACHE="${TMPDIR:-/tmp}/zj-fleet-status-pr-cache.json"
PR_CACHE_TTL="${ZJ_FLEET_PR_CACHE_TTL:-30}"

if [ ! -f "$STATE_FILE" ]; then
  echo "No fleet state yet at $STATE_FILE (no hook events recorded)."
  exit 0
fi

now_ms=$(jq -nc 'now * 1000 | floor')

pr_state_for() {
  local branch="$1"
  local now cache_ts cached
  now=$(date +%s)
  if [ -f "$PR_CACHE" ]; then
    cache_ts=$(jq -r '._fetched_at // 0' "$PR_CACHE" 2>/dev/null || echo 0)
    if [ $((now - cache_ts)) -lt "$PR_CACHE_TTL" ]; then
      cached=$(jq -r --arg b "$branch" '.[$b] // empty' "$PR_CACHE" 2>/dev/null || echo "")
      [ -n "$cached" ] && { printf '%s' "$cached"; return; }
    fi
  fi
  if ! command -v gh >/dev/null 2>&1; then
    printf 'n/a'
    return
  fi
  local state
  state=$(gh pr list --head "$branch" --json state --jq '.[0].state // "none"' 2>/dev/null || echo "none")
  local base="{}"
  [ -f "$PR_CACHE" ] && base=$(cat "$PR_CACHE" 2>/dev/null || echo "{}")
  printf '%s' "$base" | jq --arg b "$branch" --arg s "$state" --argjson ts "$now" \
    '.[$b] = $s | ._fetched_at = $ts' > "$PR_CACHE.tmp" 2>/dev/null && mv "$PR_CACHE.tmp" "$PR_CACHE"
  printf '%s' "$state"
}

printf '%-14s %-20s %-12s %8s  %s\n' "PANE" "TICKET" "EVENT" "IDLE(s)" "PR"

jq -r 'to_entries[] | [.value.pane_id, .value.cwd // "", .value.hook_event, .value.tool_name // "", .value.ts_ms] | @tsv' "$STATE_FILE" | tr -d '\r' |
while IFS=$'\t' read -r pane_id cwd hook_event tool_name ts_ms; do
  slug=$(basename "$cwd" 2>/dev/null || echo "?")
  idle=$(( (now_ms - ts_ms) / 1000 ))
  event_label="$hook_event"
  [ -n "$tool_name" ] && event_label="$hook_event:$tool_name"
  branch="wt/$slug"
  pr=$(pr_state_for "$branch")
  printf '%-14s %-20s %-12s %8s  %s\n' "$pane_id" "$slug" "$event_label" "$idle" "$pr"
done
