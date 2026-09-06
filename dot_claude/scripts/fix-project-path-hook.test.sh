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

check "misresolved Glob path (path field, nonexistent)" \
  '{"cwd":"C:/Users/tajdi/bestefforttools","tool_input":{"path":"C:/Users/tajdi/.claude/projects/C--Users-tajdi-bestefforttools/does-not-exist-dir"}}' \
  2

check "existing transcript project dir passes (deliberate transcript search)" \
  '{"cwd":"C:/Users/tajdi/bestefforttools","tool_input":{"path":"C:/Users/tajdi/.claude/projects/C--Users-tajdi-bestefforttools"}}' \
  0

check "Bash tool with no path field passes" \
  '{"cwd":"C:/Users/tajdi/bestefforttools","tool_input":{"command":"ls"}}' \
  0

check "Windows backslash path" \
  '{"cwd": "C:\\Users\\tajdi\\bestefforttools", "tool_input": {"file_path": "C:\\Users\\tajdi\\.claude\\projects\\C--Users-tajdi-bestefforttools\\lib\\seo.ts"}}' \
  2 "transcript store"

real_transcript=$(find "$HOME/.claude/projects" -maxdepth 2 -name '*.jsonl' 2>/dev/null | head -1)
if [[ -n "$real_transcript" ]]; then
  check "existing transcript file passes" \
    "$(jq -nc --arg p "$real_transcript" '{cwd:"C:/Users/tajdi", tool_input:{file_path:$p}}')" \
    0
else
  echo "SKIP (existing transcript file passes): no .jsonl found under ~/.claude/projects"
fi

if [[ $fail -eq 0 ]]; then
  echo "fix-project-path-hook.test.sh: all cases passed"
else
  exit 1
fi
