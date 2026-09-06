#!/usr/bin/env bash
set -uo pipefail

PROJ_DIR="${ZJ_FLEET_PROJECTS_DIR:-$HOME/.claude/projects}"
STALL_SECS="${ZJ_FLEET_STALL_SECS:-1200}"
PR_CACHE="${TMPDIR:-/tmp}/zj-fleet-status-pr-cache.json"
PR_CACHE_TTL="${ZJ_FLEET_PR_CACHE_TTL:-30}"
now=$(date -u +%s)

if [ ! -d "$PROJ_DIR" ]; then
  echo "No transcript store at $PROJ_DIR (no sessions recorded)."
  exit 0
fi

pr_state_for() {
  local wt="$1"
  local branch cache_ts cached state base ts
  [ -d "$wt" ] || { printf 'n/a'; return; }
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  [ -z "$branch" ] && { printf 'n/a'; return; }
  ts=$(date +%s)
  if [ -f "$PR_CACHE" ]; then
    cache_ts=$(jq -r '._fetched_at // 0' "$PR_CACHE" 2>/dev/null || echo 0)
    if [ $((ts - cache_ts)) -lt "$PR_CACHE_TTL" ]; then
      cached=$(jq -r --arg b "$branch" '.[$b] // empty' "$PR_CACHE" 2>/dev/null || echo "")
      [ -n "$cached" ] && { printf '%s' "$cached"; return; }
    fi
  fi
  if ! command -v gh >/dev/null 2>&1; then
    printf 'n/a'
    return
  fi
  state=$( (cd "$wt" && gh pr list --head "$branch" --json state --jq '.[0].state // "none"' 2>/dev/null) || echo "none")
  base="{}"
  [ -f "$PR_CACHE" ] && base=$(cat "$PR_CACHE" 2>/dev/null || echo "{}")
  printf '%s' "$base" | jq --arg b "$branch" --arg s "$state" --argjson ts "$ts" \
    '.[$b] = $s | ._fetched_at = $ts' > "$PR_CACHE.tmp" 2>/dev/null && mv "$PR_CACHE.tmp" "$PR_CACHE"
  printf '%s' "$state"
}

printf '%-28s %8s  %-9s %-20s %s\n' "PROJECT" "IDLE(s)" "STATE" "PENDING-TOOL" "PR"

for dir in "$PROJ_DIR"/*/; do
  [ -d "$dir" ] || continue
  f=$(ls -t "$dir"*.jsonl 2>/dev/null | head -1)
  [ -z "$f" ] && continue

  maxts=$(jq -r 'select(.timestamp)|.timestamp' "$f" 2>/dev/null | sort | tail -1)
  [ -z "$maxts" ] && continue
  ts=$(date -u -d "$maxts" +%s 2>/dev/null || echo "$now")
  idle=$(( now - ts ))

  cwd=$(jq -r 'select(.cwd)|.cwd' "$f" 2>/dev/null | tail -1 | tr '\\' '/')
  label=$(basename "$dir")
  [ -n "$cwd" ] && label=$(basename "$cwd")

  tail_rec=$(jq -r 'select(.timestamp)|select(.type=="assistant" or .type=="user")|"\(.timestamp)|\(.type)|\([.message.content[]?|.type//empty]|join(","))"' "$f" 2>/dev/null | sort | tail -1)
  rtype=$(printf '%s' "$tail_rec" | cut -d'|' -f2)
  ctypes=$(printf '%s' "$tail_rec" | cut -d'|' -f3)

  pending="-"
  state="?"
  case "$ctypes:$rtype" in
    *tool_use*:assistant)
      state="WORKING"
      pending=$(jq -r 'select(.type=="assistant")|select(.message.content[]?.type=="tool_use")|"\(.timestamp)|\(.message.content[]|select(.type=="tool_use")|.name)"' "$f" 2>/dev/null | sort | tail -1 | cut -d'|' -f2)
      ;;
    *:assistant) state="PARKED" ;;
    *:user)      state="IDLE-OK" ;;
  esac
  [ "$idle" -gt "$STALL_SECS" ] && state="STALL"

  pr="n/a"
  [ -n "$cwd" ] && pr=$(pr_state_for "$cwd")

  printf '%-28s %8s  %-9s %-20s %s\n' "${label:0:28}" "$idle" "$state" "${pending:0:20}" "$pr"
done
