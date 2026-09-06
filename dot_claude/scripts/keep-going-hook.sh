#!/usr/bin/env bash
set -euo pipefail

project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
state_dir="$project_dir/.claude"
sentinel="$state_dir/goal-done"
abort="$state_dir/goal-stop"
counter_file="$state_dir/goal-tries"
max_file="$state_dir/keep-going-max"

cat >/dev/null || true

if [[ -f "$sentinel" ]]; then
  exit 0
fi

if [[ -f "$abort" ]]; then
  echo "keep-going-hook: $abort present, allowing stop without goal-done." >&2
  exit 0
fi

mkdir -p "$state_dir"

max=40
[[ -f "$max_file" ]] && max=$(cat "$max_file" 2>/dev/null || echo 40)

tries=0
[[ -f "$counter_file" ]] && tries=$(cat "$counter_file" 2>/dev/null || echo 0)
tries=$((tries + 1))
printf '%s' "$tries" > "$counter_file"

if (( tries > max )); then
  echo "keep-going-hook: hit max continuations ($max) without $sentinel, allowing stop." >&2
  exit 0
fi

reason="Standing goal not yet complete ($tries/$max continuations used). Keep working the goal from your original prompt. When it is FULLY met, create .claude/goal-done (e.g. touch .claude/goal-done) before your final message. If you are stuck, say so plainly instead of stopping silently."
printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$reason" | jq -Rs .)"
