#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/fix-project-path-hook.sh"
fail=0

check() {
  local desc="$1" json="$2" want_rc="$3" want_grep="${4:-}"
  local out rc
  out=$(printf '%s' "$json" | bash "$hook" 2>&1) && rc=0 || rc=$?
  if [[ "$rc" != "$want_rc" ]]; then
    echo "FAIL ($desc): exit $rc, expected $want_rc. Output: $out"; fail=1
  fi
  if [[ -n "$want_grep" && "$out" != *"$want_grep"* ]]; then
    echo "FAIL ($desc): output missing '$want_grep'. Output: $out"; fail=1
  fi
}

check "misresolved Read path" \
  '{"cwd":"C:/Users/tajdi/bestefforttools","tool_input":{"file_path":"C:/Users/tajdi/.claude/projects/C--Users-tajdi-bestefforttools/lib/seo.ts"}}' \
  2 "C:/Users/tajdi/bestefforttools/lib/seo.ts"

check "normal repo path passes" \
  '{"cwd":"C:/Users/tajdi/bestefforttools","tool_input":{"file_path":"C:/Users/tajdi/bestefforttools/lib/seo.ts"}}' \
  0

check "misresolved Glob path (path field)" \
  '{"cwd":"C:/Users/tajdi/bestefforttools","tool_input":{"path":"C:/Users/tajdi/.claude/projects/C--Users-tajdi-bestefforttools"}}' \
  2

check "Bash tool with no path field passes" \
  '{"cwd":"C:/Users/tajdi/bestefforttools","tool_input":{"command":"ls"}}' \
  0

check "Windows backslash path" \
  '{"cwd": "C:\\Users\\tajdi\\bestefforttools", "tool_input": {"file_path": "C:\\Users\\tajdi\\.claude\\projects\\C--Users-tajdi-bestefforttools\\lib\\seo.ts"}}' \
  2 "transcript store"

if [[ $fail -eq 0 ]]; then
  echo "fix-project-path-hook.test.sh: all cases passed"
else
  exit 1
fi
