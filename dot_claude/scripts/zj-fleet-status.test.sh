#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

pass=0
fail=0
check() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $desc"
    echo "  want: $want"
    echo "  got:  $got"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/projects"
mkdir -p "$PROJ/proj-a" "$PROJ/proj-b" "$PROJ/repo.wt~DEV-1"
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
NOW1=$(date -u -d '+1 second' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -v+1S +%Y-%m-%dT%H:%M:%S.000Z)
STALE=$(date -u -d '@0' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -r 0 +%Y-%m-%dT%H:%M:%S.000Z)

cat > "$PROJ/proj-a/s1.jsonl" <<JSONL
{"type":"user","timestamp":"$NOW","cwd":"/c/repo/proj-a","message":{"role":"user","content":"go"}}
{"type":"assistant","timestamp":"$NOW1","cwd":"/c/repo/proj-a","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}
JSONL

cat > "$PROJ/proj-b/s2.jsonl" <<JSONL
{"type":"user","timestamp":"$STALE","cwd":"/c/repo/proj-b","message":{"role":"user","content":"hi"}}
{"type":"assistant","timestamp":"$STALE","cwd":"/c/repo/proj-b","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
{"type":"mode","mode":"normal"}
JSONL

OUT=$(ZJ_FLEET_PROJECTS_DIR="$PROJ" GH_TOKEN= bash zj-fleet-status.sh 2>&1)
check "proj-a rendered" "$(printf '%s' "$OUT" | grep -c 'proj-a')" "1"
check "proj-a is WORKING" "$(printf '%s' "$OUT" | awk '/proj-a/{print $3}')" "WORKING"
check "proj-a pending tool is Bash" "$(printf '%s' "$OUT" | awk '/proj-a/{print $4}')" "Bash"
check "proj-b is STALL (old timestamp)" "$(printf '%s' "$OUT" | awk '/proj-b/{print $3}')" "STALL"

EMPTY="$TMP/empty-projects"
OUT2=$(ZJ_FLEET_PROJECTS_DIR="$EMPTY" bash zj-fleet-status.sh; echo "exit:$?")
check "missing projects dir yields friendly message and exit 0" "$(printf '%s' "$OUT2" | tail -1)" "exit:0"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
