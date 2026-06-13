#!/usr/bin/env bash
# zj-review.sh — open a file for review in a new, named zellij tab.
#
# Usage: zj-review.sh <file> [tab-name] [editor]
#   <file>      path to open (Windows C:\... or POSIX /... both fine)
#   [tab-name]  zellij tab name        (default: "review:<filename>")
#   [editor]    editor command         (default: $EDITOR, else nvim)
#
# No-op (exit 0) when not inside a zellij session — safe to call from a plain
# terminal, an IDE, or CI without erroring.
set -euo pipefail

file="${1:?usage: zj-review.sh <file> [tab-name] [editor]}"
base="${file##*[\\/]}" # filename only; handles both \ and / separators
name="${2:-review:${base}}"
editor="${3:-${EDITOR:-nvim}}"

if [ -z "${ZELLIJ:-}" ]; then
  echo "zj-review: not in a zellij session — skipping ($file)"
  exit 0
fi

zellij action new-tab --name "$name"
zellij action write-chars "${editor} \"${file}\""
zellij action write 13 # 13 = Enter (CR) to submit the command
echo "zj-review: opened tab '$name' → ${editor} \"${file}\""
