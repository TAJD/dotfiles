#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/keep-going-hook.sh"
fail=0

run() {
  local desc="$1"; shift
  local tmp out rc
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.claude"
  "$@" "$tmp"
  out=$(CLAUDE_PROJECT_DIR="$tmp" bash "$hook" <<<'{}') && rc=0 || rc=$?
  if [[ "$rc" != 0 ]]; then
    echo "FAIL ($desc): hook exited $rc, expected 0"; fail=1
  fi
  rm -rf "$tmp"
  printf '%s' "$out"
}

setup_none() { :; }
setup_done() { touch "$1/.claude/goal-done"; }
setup_stop() { touch "$1/.claude/goal-stop"; }
setup_maxed() { echo 2 > "$1/.claude/keep-going-max"; echo 5 > "$1/.claude/goal-tries"; }

out=$(run "no sentinel" setup_none)
[[ "$out" == *'"decision":"block"'* ]] || { echo "FAIL: expected block when no sentinel, got: $out"; fail=1; }

out=$(run "goal-done present" setup_done)
[[ -z "$out" ]] || { echo "FAIL: expected empty stdout with goal-done, got: $out"; fail=1; }

out=$(run "goal-stop present" setup_stop)
[[ -z "$out" ]] || { echo "FAIL: expected empty stdout with goal-stop, got: $out"; fail=1; }

out=$(run "max continuations exhausted" setup_maxed)
[[ -z "$out" ]] || { echo "FAIL: expected empty stdout past max, got: $out"; fail=1; }

if [[ $fail -eq 0 ]]; then
  echo "keep-going-hook.test.sh: all cases passed"
else
  exit 1
fi
