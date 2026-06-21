#!/usr/bin/env bash
# zj-claude.sh — spawn an autonomous Claude Code session in a new, named zellij tab,
# in its OWN git worktree by default so parallel sessions never fight over the working tree.
#
# Usage: zj-claude.sh [options] <tab-name> <workdir> <prompt | @prompt-file | @->
#
# Options (must precede positional args):
#   --here          run in <workdir> itself, no worktree created
#   --base <ref>    branch worktree off <ref> (default: main, master, or HEAD)
#   --setup <cmd>   run <cmd> in the pane before claude (e.g. "mix deps.get")
#
#   <tab-name>   name for the new zellij tab
#   <workdir>    Windows path to the repo root (e.g. C:\Users\me\repo)
#   <prompt>     initial prompt text
#   @<file>      point Claude at an EXISTING file — expands to
#                "Read <file> in full, then carry out the work it describes."
#   @-           read the prompt from STDIN (written to a unique temp file so
#                parallel spawns never clash). e.g.
#                  printf '%s' "$long_prompt" | zj-claude.sh tab 'C:\dir' @-
#
# Worktree default:
#   Creates <repo-parent>/<repo-name>.wt/<name> on branch wt/<name>, outside the
#   repo tree so whole-tree commands don't walk it. Pass --here to run directly
#   in <workdir> without creating a worktree (research/exploration use cases).
#
# Prompt delivery:
#   Uses a KDL layout that starts a bash pane directly — no write-chars timing
#   race. The prompt is read from a temp file via `cat`, so quoting and length
#   are irrelevant. Claude's session is fully autonomous (--dangerously-skip-permissions).
#
# No-op (exit 0) when not inside a zellij session.
set -euo pipefail

here=0; base=""; setup=""
model="${MODEL:-sonnet}"
settle="${ZJ_SETTLE:-1.5}"  # seconds for a new tab's chrome to settle before layout loads

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --here)        here=1; shift;;
    --base)        base="${2:?--base needs a ref}"; shift 2;;
    --setup)       setup="${2:?--setup needs a command}"; shift 2;;
    --model)       model="${2:?--model needs a ref}"; shift 2;;
    --)            shift; break;;
    *)             echo "zj-claude: unknown option $1" >&2; exit 2;;
  esac
done

name="${1:?usage: zj-claude.sh [--here] [--base <ref>] [--setup <cmd>] <tab-name> <workdir> <prompt|@file|@->}"
workdir="${2:?usage: zj-claude.sh <tab-name> <workdir> <prompt|@file|@->}"
prompt_arg="${3:?usage: zj-claude.sh <tab-name> <workdir> <prompt|@file|@->}"

# ── Resolve prompt ──────────────────────────────────────────────────────────
spawndir="${TMPDIR:-/tmp}/claude-spawn"
mkdir -p "$spawndir"
find "$spawndir" -type f -mtime +1 -delete 2>/dev/null || true  # prune old files

if [[ "$prompt_arg" == "@-" ]]; then
  tf="$(mktemp "$spawndir/${name}-XXXXXX.md")"
  cat > "$tf"
  promptfile="$tf"
elif [[ "$prompt_arg" == @* ]]; then
  promptfile="${prompt_arg:1}"
else
  tf="$(mktemp "$spawndir/${name}-XXXXXX.md")"
  printf '%s' "$prompt_arg" > "$tf"
  promptfile="$tf"
fi

# ── Worktree creation ────────────────────────────────────────────────────────
if [[ $here -eq 1 ]]; then
  launch_dir="$workdir"
else
  git -C "$workdir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "zj-claude: $workdir is not a git repo — use --here to run there directly" >&2; exit 1; }

  if [[ -z "$base" ]]; then
    if   git -C "$workdir" show-ref -q --verify refs/heads/main;   then base=main
    elif git -C "$workdir" show-ref -q --verify refs/heads/master; then base=master
    else base=$(git -C "$workdir" rev-parse --abbrev-ref HEAD); fi
  fi
  git -C "$workdir" fetch -q origin "$base" 2>/dev/null || true
  start="$base"
  git -C "$workdir" show-ref -q --verify "refs/remotes/origin/$base" && start="origin/$base"

  slug=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')
  [[ -n "$slug" ]] || slug="claude"

  repo_abs=$(cd "$workdir" && pwd)
  parent=$(dirname "$repo_abs"); bn=$(basename "$repo_abs")
  branch="wt/$slug"; launch_dir="$parent/$bn.wt/$slug"

  if git -C "$workdir" show-ref -q --verify "refs/heads/$branch" || [[ -e "$launch_dir" ]]; then
    sfx=$(date +%H%M%S); branch="wt/$slug-$sfx"; launch_dir="$parent/$bn.wt/$slug-$sfx"
  fi

  echo "zj-claude: creating worktree $launch_dir on $branch (from $start)" >&2
  git -C "$workdir" worktree add -b "$branch" "$launch_dir" "$start" >&2
fi

# ── Path conversion (Windows/MSYS) ──────────────────────────────────────────
to_native() { command -v cygpath >/dev/null && cygpath -m "$1" || printf '%s' "$1"; }
bash_native=$(to_native "$(command -v bash)")
launch_dir_native=$(to_native "$launch_dir")
pf_native=$(to_native "$promptfile")

# ── Guard: must be inside zellij ────────────────────────────────────────────
if [ -z "${ZELLIJ:-}" ]; then
  echo "zj-claude: not in a zellij session — skipping (would start claude in ${launch_dir})"
  exit 0
fi

# ── KDL layout ──────────────────────────────────────────────────────────────
# Starts a bash pane directly — no write-chars timing race. Prompt delivered
# via `cat promptfile` so length and quoting are irrelevant.
# Chrome panes (zellaude top + zjstatus bottom) must match the user's
# default_tab_template so the tab bar is visible. Mirrors spawn-claude exactly.
pre=""; [[ -n "$setup" ]] && pre="$setup; "

layout=$(mktemp --suffix=.kdl)
cat > "$layout" <<KDL
layout {
    pane size=1 borderless=true {
        plugin location="https://github.com/ishefi/zellaude/releases/latest/download/zellaude.wasm"
    }
    pane command="$bash_native" cwd="$launch_dir_native" {
        args "-lc" "${pre}claude --dangerously-skip-permissions --model $model \"\$(cat '$pf_native')\"; exec \"$bash_native\" -i"
    }
    pane size=1 borderless=true {
        plugin location="file:C:/Users/tajdi/AppData/Roaming/zellij/config/plugins/zjstatus.wasm" {
            format_left   ""
            format_center ""
            format_right  "{datetime}"
            format_space  ""
            mode_normal        "#[bg=#89B4FA,fg=#1E1E2E,bold] NORMAL "
            mode_locked        "#[bg=#F38BA8,fg=#1E1E2E,bold] LOCKED "
            mode_pane          "#[bg=#A6E3A1,fg=#1E1E2E,bold] PANE "
            mode_tab           "#[bg=#A6E3A1,fg=#1E1E2E,bold] TAB "
            mode_scroll        "#[bg=#F9E2AF,fg=#1E1E2E,bold] SCROLL "
            mode_resize        "#[bg=#FAB387,fg=#1E1E2E,bold] RESIZE "
            mode_move          "#[bg=#CBA6F7,fg=#1E1E2E,bold] MOVE "
            mode_search        "#[bg=#F9E2AF,fg=#1E1E2E,bold] SEARCH "
            mode_session       "#[bg=#CBA6F7,fg=#1E1E2E,bold] SESSION "
            mode_tmux          "#[bg=#F5C2E7,fg=#1E1E2E,bold] TMUX "
            mode_renametab     "#[bg=#A6E3A1,fg=#1E1E2E,bold] RENAME TAB "
            mode_renamepane    "#[bg=#A6E3A1,fg=#1E1E2E,bold] RENAME PANE "
            datetime          "#[fg=#6C7086,bold] {format} "
            datetime_format   "%d %b %Y  %H:%M"
            datetime_timezone "Europe/London"
        }
    }
}
KDL

# ── Serialised tab creation ──────────────────────────────────────────────────
# Concurrent `zellij action new-tab` calls race and silently drop tabs.
# A lock directory (atomic mkdir) serialises the actual tab-open step while
# still letting worktree creation above run in parallel.
lock_dir="${TMPDIR:-/tmp}/zj-tab-lock"
lock_wait=0
until mkdir "$lock_dir" 2>/dev/null; do
  sleep 0.3
  lock_wait=$((lock_wait + 1))
  [[ $lock_wait -gt 100 ]] && { echo "zj-claude: tab lock timeout after 30s" >&2; rm -f "$layout"; exit 1; }
done
trap 'rm -rf "$lock_dir"; rm -f "$layout"' EXIT

zellij action new-tab --name "$name" --layout "$(to_native "$layout")"
sleep 0.5  # brief settle so the next concurrent caller doesn't race the compositor

rm -rf "$lock_dir"
trap - EXIT
rm -f "$layout"

echo "zj-claude: opened tab '$name' → claude --model $model in $launch_dir"
