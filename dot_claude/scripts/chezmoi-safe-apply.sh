#!/usr/bin/env bash
set -euo pipefail

status=$(chezmoi status "$@" 2>&1)
mm=$(printf '%s\n' "$status" | grep -E '^MM ' || true)

if [[ -n "$mm" ]]; then
  echo "chezmoi-safe-apply: refusing to apply, both source and target have diverged for:" >&2
  printf '%s\n' "$mm" >&2
  echo "" >&2
  echo "Applying now would overwrite target-only edits. Reconcile each file first:" >&2
  echo "  chezmoi diff -- <target-path>   # see both sides" >&2
  echo "  chezmoi re-add -- <target-path> # pull target's live edits into source, then re-apply" >&2
  echo "or pass --force to apply anyway (this WILL discard the target-only edits)." >&2
  if [[ " $* " != *" --force "* ]]; then
    exit 1
  fi
  echo "chezmoi-safe-apply: --force given, applying despite the MM files above." >&2
fi

args=()
for a in "$@"; do
  [[ "$a" == "--force" ]] && continue
  args+=("$a")
done

exec chezmoi apply "${args[@]}"
