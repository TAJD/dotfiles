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

manifest_home=$(mktemp -d)
mkdir -p "$manifest_home/.claude"
stub=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/zellij"
chmod +x "$stub/zellij"
manifest="$manifest_home/manifest.json"

single_wt="$manifest_home-repo.wt/single"
mkdir -p "$single_wt"
PATH="$stub:$PATH" HOME="$manifest_home" ZELLIJ=fake CLAUDE_FLEET_MANIFEST="$manifest" \
  bash "$script" --here single "$single_wt" 'x' >/dev/null 2>&1
if ! jq -e '.[0] | has("tab") and has("worktree") and has("brief") and has("spawn_ts") and has("transcript_slug") and has("keep_going_max")' "$manifest" >/dev/null 2>&1; then
  echo "FAIL (manifest fields): expected record with tab/worktree/brief/spawn_ts/transcript_slug/keep_going_max, got: $(cat "$manifest")"; fail=1
fi

pids=()
for i in 1 2 3 4; do
  cwt="$manifest_home-repo.wt/concurrent$i"
  mkdir -p "$cwt"
  ( PATH="$stub:$PATH" HOME="$manifest_home" ZELLIJ=fake CLAUDE_FLEET_MANIFEST="$manifest" \
    bash "$script" --keep-going --here "concurrent$i" "$cwt" 'x' >/dev/null 2>&1 ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

if ! jq -e . "$manifest" >/dev/null 2>&1; then
  echo "FAIL (manifest concurrency): manifest is not valid JSON after concurrent spawns"; fail=1
fi
count=$(jq 'length' "$manifest")
if [[ "$count" != 5 ]]; then
  echo "FAIL (manifest concurrency): expected 5 records (1 + 4 concurrent), got $count"; fail=1
fi
if [[ "$(jq '[.[] | select(.tab | startswith("concurrent"))] | length' "$manifest")" != 4 ]]; then
  echo "FAIL (manifest concurrency): missing a concurrent spawn record"; fail=1
fi
if [[ "$(jq -r '.[] | select(.tab=="concurrent1") | .keep_going_max' "$manifest")" != "40" ]]; then
  echo "FAIL (manifest keep_going_max): expected 40 for a --keep-going spawn"; fail=1
fi

rm -rf "$manifest_home" "$stub" "$manifest_home-repo.wt"

if [[ $fail -eq 0 ]]; then
  echo "zj-claude.test.sh: all cases passed"
else
  exit 1
fi
