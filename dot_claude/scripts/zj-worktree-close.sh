#!/usr/bin/env bash
# zj-worktree-close.sh — tear down a named worktree Claude session
#
# Usage: zj-worktree-close.sh [options] <tab-name> <repo-dir>
#
# Options:
#   --force    delete branch even if it has unmerged commits (use after manual merge)
#   --no-tab   skip the zellij tab-close step (worktree + branch cleanup only)
#
# What it does:
#   1. Closes the named zellij tab (go-to + close-tab, then returns focus)
#   2. git worktree remove <repo>.wt/<slug>
#   3. git branch -d wt/<slug>  (or -D with --force)
#
# No-op outside a zellij session (exit 0).
set -euo pipefail

force=0; no_tab=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --force)   force=1; shift;;
    --no-tab)  no_tab=1; shift;;
    --)        shift; break;;
    *)         echo "zj-worktree-close: unknown option $1" >&2; exit 2;;
  esac
done

name="${1:?usage: zj-worktree-close.sh [--force] [--no-tab] <tab-name> <repo-dir>}"
repo="${2:?usage: zj-worktree-close.sh [--force] [--no-tab] <tab-name> <repo-dir>}"

slug=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')
[[ -n "$slug" ]] || slug="claude"

repo_abs=$(cd "$repo" && pwd)
parent=$(dirname "$repo_abs"); bn=$(basename "$repo_abs")
wt_dir="$parent/$bn.wt/$slug"
branch="wt/$slug"

# ── Guard ────────────────────────────────────────────────────────────────────
if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "zj-worktree-close: $repo is not a git repo" >&2; exit 1
fi

# ── Warn on unmerged commits ─────────────────────────────────────────────────
if git -C "$repo" show-ref -q --verify "refs/heads/$branch"; then
  base_branch="main"; git -C "$repo" show-ref -q --verify refs/heads/main || base_branch="master"
  unmerged=$(git -C "$repo" log --oneline "$base_branch..$branch" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$unmerged" -gt 0 && $force -eq 0 ]]; then
    echo "zj-worktree-close: $branch has $unmerged commit(s) not merged into $base_branch:" >&2
    git -C "$repo" log --oneline "$base_branch..$branch" >&2
    echo "" >&2
    echo "  Merge/PR first, then re-run with --force to delete." >&2
    exit 1
  fi
fi

# ── Close zellij tab (kills the pane process) ────────────────────────────────
if [[ $no_tab -eq 0 && -n "${ZELLIJ:-}" ]]; then
  if zellij action go-to-tab-name "$name" 2>/dev/null; then
    zellij action close-tab 2>/dev/null || true
    echo "zj-worktree-close: closed tab '$name'"
    sleep 1  # give the process time to exit before we try to remove its CWD
  else
    echo "zj-worktree-close: tab '$name' not found (already closed?)" >&2
  fi
fi

# ── Kill any process still using the worktree dir (handles --no-tab case) ────
# On Windows/MSYS, rm -rf fails with "Device or resource busy" when a process
# has the worktree as its CWD. Find and kill those processes first.
if [[ -e "$wt_dir" ]]; then
  wt_native=$(command -v cygpath >/dev/null && cygpath -w "$wt_dir" || printf '%s' "$wt_dir")
  # PowerShell: find processes whose working directory is inside the worktree
  kill_count=$(powershell.exe -NoProfile -Command "
    \$wt = '$wt_native'.Replace('\\\\', '\\')
    \$procs = Get-WmiObject Win32_Process | Where-Object {
      try { \$_.ExecutablePath -and (Get-Process -Id \$_.ProcessId -ErrorAction SilentlyContinue).Path } catch { \$false }
    }
    \$killed = 0
    Get-WmiObject Win32_Process | ForEach-Object {
      try {
        \$exe = \$_.Name
        \$cmd = \$_.CommandLine
        if (\$cmd -and \$cmd.Contains(\$wt)) {
          Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue
          \$killed++
        }
      } catch {}
    }
    \$killed
  " 2>/dev/null | tr -d '\r' || echo "0")
  if [[ "$kill_count" -gt 0 ]]; then
    echo "zj-worktree-close: killed $kill_count process(es) using the worktree" >&2
    sleep 0.5
  fi
fi

# ── Remove worktree ───────────────────────────────────────────────────────────
if [[ -e "$wt_dir" ]]; then
  git -C "$repo" worktree remove "$wt_dir" --force 2>/dev/null \
    || { echo "zj-worktree-close: worktree remove failed, trying rm -rf" >&2; rm -rf "$wt_dir" 2>/dev/null; }
  git -C "$repo" worktree prune 2>/dev/null || true
  echo "zj-worktree-close: removed worktree $wt_dir"
else
  echo "zj-worktree-close: worktree dir not found ($wt_dir) — skipping" >&2
fi

# ── Delete branch ─────────────────────────────────────────────────────────────
if git -C "$repo" show-ref -q --verify "refs/heads/$branch"; then
  flag="-d"; [[ $force -eq 1 ]] && flag="-D"
  git -C "$repo" branch "$flag" "$branch"
  echo "zj-worktree-close: deleted branch $branch"
else
  echo "zj-worktree-close: branch $branch not found — skipping" >&2
fi

echo "zj-worktree-close: done"
