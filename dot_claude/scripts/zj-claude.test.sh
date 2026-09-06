#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/zj-claude.sh"
fail=0

export ZJ_VERIFY=0
export ZELLIJ=

run() {
  local fake_home="$1"; shift
  HOME="$fake_home" bash "$script" "$@" 2>&1
}

assert_refuses() {
  local desc="$1" fake_home="$2" workdir="$3"
  local out rc
  out=$(run "$fake_home" --keep-going --here t "$workdir" 'x') && rc=0 || rc=$?
  if [[ "$rc" == 0 ]]; then
    echo "FAIL ($desc): expected non-zero exit, got 0. output: $out"; fail=1
  fi
  if [[ "$out" != *"refusing"* ]]; then
    echo "FAIL ($desc): expected a refusal message, got: $out"; fail=1
  fi
  if [[ -f "$workdir/.claude/keep-going-max" ]]; then
    echo "FAIL ($desc): keep-going-max was written despite refusal"; fail=1
  fi
}

fake_home=$(mktemp -d)
mkdir -p "$fake_home/.claude"

assert_refuses "\$HOME" "$fake_home" "$fake_home"
assert_refuses "\$HOME/.claude" "$fake_home" "$fake_home/.claude"

plainshared=$(mktemp -d)
assert_refuses "non-worktree shared dir" "$fake_home" "$plainshared"

wt="$plainshared.wt/worker1"
mkdir -p "$wt"
out=$(run "$fake_home" --keep-going --here t "$wt" 'x') && rc=0 || rc=$?
if [[ "$rc" != 0 ]]; then
  echo "FAIL (dedicated worktree layout): expected exit 0, got $rc. output: $out"; fail=1
fi
if [[ ! -f "$wt/.claude/keep-going-max" ]]; then
  echo "FAIL (dedicated worktree layout): keep-going-max was not written"; fail=1
fi

out=$(run "$fake_home" --keep-going --force-shared --here t "$fake_home/.claude" 'x') && rc=0 || rc=$?
if [[ "$rc" != 0 ]]; then
  echo "FAIL (force-shared): expected exit 0, got $rc. output: $out"; fail=1
fi
if [[ "$out" != *"WARNING"* ]]; then
  echo "FAIL (force-shared): expected a loud warning, got: $out"; fail=1
fi
if [[ ! -f "$fake_home/.claude/.claude/keep-going-max" ]]; then
  echo "FAIL (force-shared): keep-going-max was not written under the forced dir"; fail=1
fi

rm -rf "$fake_home" "$plainshared" "$plainshared.wt"

if [[ $fail -eq 0 ]]; then
  echo "zj-claude.test.sh: all cases passed"
else
  exit 1
fi
