#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' ERR

input=$(cat)
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

[[ -z "$path" ]] && exit 0

norm=$(printf '%s' "$path" | tr '\\' '/')
if [[ "$norm" != *"/.claude/projects/"* ]]; then
  exit 0
fi

[[ -e "$path" ]] && exit 0

remainder=$(printf '%s' "$norm" | sed -E 's#^.*/\.claude/projects/[^/]+/##')

if [[ -z "$remainder" || "$remainder" == "$norm" || -z "$cwd" ]]; then
  echo "Path '$path' runs through ~/.claude/projects/<key>/, which is the transcript store, not a repo. Use a path relative to your actual working directory instead." >&2
  exit 2
fi

suggestion="${cwd%/}/$remainder"
echo "Path '$path' resolves inside ~/.claude/projects/<key>/, which is the transcript store, not your repo root. Your working directory is '$cwd' — you likely meant '$suggestion'. Retry with that path." >&2
exit 2
