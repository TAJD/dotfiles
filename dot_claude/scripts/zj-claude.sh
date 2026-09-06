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
#   Workspace trust is pre-accepted for the launch dir (see below) — without it
#   the trust dialog swallows the prompt's auto-submit and the session hangs.
#   After the tab opens, the script waits for a session transcript to prove the
#   brief was actually submitted (ZJ_VERIFY=0 skips, ZJ_VERIFY_TIMEOUT tunes).
#   Exit 3 means the tab opened but the session never started.
#
# No-op (exit 0) when not inside a zellij session.
set -euo pipefail

here=0; base=""; setup=""; keep_going=0; force_shared=0
keep_going_max="${KEEP_GOING_MAX:-40}"
model="${MODEL:-sonnet}"
settle="${ZJ_SETTLE:-1.5}"  # seconds for a new tab's chrome to settle before layout loads

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --here)          here=1; shift;;
    --base)          base="${2:?--base needs a ref}"; shift 2;;
    --setup)         setup="${2:?--setup needs a command}"; shift 2;;
    --model)         model="${2:?--model needs a ref}"; shift 2;;
    --keep-going)    keep_going=1; shift;;
    --force-shared)  force_shared=1; shift;;
    --)              shift; break;;
    *)               echo "zj-claude: unknown option $1" >&2; exit 2;;
  esac
done

name="${1:?usage: zj-claude.sh [--here] [--base <ref>] [--setup <cmd>] <tab-name> <workdir> <prompt|@file|@->}"
workdir="${2:?usage: zj-claude.sh <tab-name> <workdir> <prompt|@file|@->}"
prompt_arg="${3:?usage: zj-claude.sh <tab-name> <workdir> <prompt|@file|@->}"

# ── Resolve prompt ──────────────────────────────────────────────────────────
spawndir="${TMPDIR:-/tmp}/claude-spawn"
mkdir -p "$spawndir"
find "$spawndir" -type f -mtime +1 -delete 2>/dev/null || true  # prune old files

# Always assemble into a fresh temp file. @file used to be passed through by
# reference, so the closing instruction below was appended to the CALLER'S file
# — mutating it, and stacking another copy on every re-spawn from the same file.
promptfile="$(mktemp "$spawndir/${name}-XXXXXX.md")"
if [[ "$prompt_arg" == "@-" ]]; then
  cat > "$promptfile"
elif [[ "$prompt_arg" == @* ]]; then
  src="${prompt_arg:1}"
  [[ -r "$src" ]] || { echo "zj-claude: prompt file not readable: $src" >&2; exit 1; }
  cat "$src" > "$promptfile"
else
  printf '%s' "$prompt_arg" > "$promptfile"
fi

# ── Append standard worker closing instruction ───────────────────────────────
closing='When you have finished all the work and it passes CI: commit your changes with a descriptive message, push the branch, and open a PR.'
grep -qF "$closing" "$promptfile" || printf '\n\n%s' "$closing" >> "$promptfile"

if [[ $keep_going -eq 1 ]]; then
  {
    printf '\n\n## Standing-goal loop\n'
    printf 'A Stop hook will block you from ending this session until the goal above is met, up to %s continuations.\n' "$keep_going_max"
    printf 'When the goal is FULLY met, create .claude/goal-done (e.g. `touch .claude/goal-done`) before your final message.\n'
    printf 'If a human needs to abort the loop early, they create .claude/goal-stop in this worktree.\n'
  } >> "$promptfile"
fi

# ── Worktree creation ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
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

if [[ $keep_going -eq 1 ]]; then
  abs_launch=$(cd "$launch_dir" 2>/dev/null && pwd || printf '%s' "$launch_dir")
  home_abs=$(cd "$HOME" && pwd)
  shared=0
  if [[ $here -eq 1 ]]; then
    case "$abs_launch" in
      "$home_abs"|"$home_abs"/.claude|"$home_abs"/.claude/*) shared=1;;
      *.wt/*) ;;
      *) shared=1;;
    esac
  fi
  if [[ $shared -eq 1 && $force_shared -eq 0 ]]; then
    echo "zj-claude: refusing --keep-going --here into shared directory: $abs_launch" >&2
    echo "zj-claude: this is not a dedicated worktree — a Stop hook here would block every session run from this directory, not just this one." >&2
    echo "zj-claude: safe alternative: drop --here so a dedicated worktree is created, or pass --force-shared if this directory truly is dedicated to this one standing-goal session." >&2
    exit 1
  fi
  [[ $shared -eq 1 ]] && echo "zj-claude: WARNING — installing standing-goal Stop hook into shared directory $abs_launch (--force-shared)." >&2

  mkdir -p "$launch_dir/.claude"
  printf '%s' "$keep_going_max" > "$launch_dir/.claude/keep-going-max"
  settings_file="$launch_dir/.claude/settings.local.json"
  hook_entry='{"matcher":"","hooks":[{"type":"command","command":"bash ~/.claude/scripts/keep-going-hook.sh"}]}'
  if [[ -f "$settings_file" ]] && command -v jq >/dev/null 2>&1; then
    cp "$settings_file" "$settings_file.bak"
    if jq --argjson entry "$hook_entry" '.hooks.Stop = ((.hooks.Stop // []) + [$entry])' "$settings_file" > "$settings_file.tmp" \
       && jq -e . "$settings_file.tmp" >/dev/null 2>&1; then
      mv "$settings_file.tmp" "$settings_file"
    else
      echo "zj-claude: --keep-going: merge into $settings_file produced invalid JSON — left original untouched, backup at $settings_file.bak" >&2
      rm -f "$settings_file.tmp"
    fi
  elif [[ -f "$settings_file" ]]; then
    echo "zj-claude: --keep-going: $settings_file already exists and jq is unavailable to merge, skipping hook install" >&2
  else
    printf '{"hooks":{"Stop":[%s]}}' "$hook_entry" | jq . > "$settings_file"
  fi
fi

# ── Path conversion (Windows/MSYS) ──────────────────────────────────────────
to_native() { command -v cygpath >/dev/null && cygpath -m "$1" || printf '%s' "$1"; }
bash_native=$(to_native "$(command -v bash)")
launch_dir_native=$(to_native "$launch_dir")
pf_native=$(to_native "$promptfile")

# ── Pre-accept workspace trust ──────────────────────────────────────────────
# A worktree is always a brand-new directory, so Claude Code opens on "Is this a
# project you created or one you trust?" and waits. --dangerously-skip-permissions
# does NOT bypass it. That dialog eats the auto-submit of the positional prompt:
# the session comes up with the brief sitting unsent in the composer, looking
# alive (process up, tab open) while doing nothing — and it stays stuck, because
# the stranded draft blocks auto-submit on every relaunch too. Trust is implied
# by the invocation: the caller is deliberately starting a skip-permissions agent
# in this directory, and by default we created it ourselves from their own repo.
#
# Written via a lock + atomic rename so parallel spawns can't shred the file.
trust_lock="${TMPDIR:-/tmp}/zj-trust-lock"
trust_wait=0
until mkdir "$trust_lock" 2>/dev/null; do
  sleep 0.2
  trust_wait=$((trust_wait + 1))
  [[ $trust_wait -gt 50 ]] && break
done
node -e '
  const fs = require("fs"), os = require("os"), path = require("path");
  const p = path.join(os.homedir(), ".claude.json");
  const key = process.argv[1];
  let j = {};
  try { j = JSON.parse(fs.readFileSync(p, "utf8")); } catch { process.exit(0); }
  j.projects = j.projects || {};
  j.projects[key] = Object.assign({}, j.projects[key], { hasTrustDialogAccepted: true });
  const tmp = p + ".zjtmp" + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(j, null, 2));
  fs.renameSync(tmp, p);
' "$launch_dir_native" 2>/dev/null || echo "zj-claude: could not pre-accept trust for $launch_dir_native — the session may stall on the trust prompt" >&2
rmdir "$trust_lock" 2>/dev/null || true

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

manifest_file="${CLAUDE_FLEET_MANIFEST:-$HOME/.claude/fleet/manifest.json}"
mkdir -p "$(dirname "$manifest_file")"
[[ -f "$manifest_file" ]] || printf '[]' > "$manifest_file"
manifest_slug=$(printf '%s' "$launch_dir_native" | sed 's|[:/.]|-|g')
kg_max_json="null"
[[ $keep_going -eq 1 ]] && kg_max_json="$keep_going_max"
manifest_record=$(jq -n \
  --arg tab "$name" \
  --arg worktree "$launch_dir" \
  --arg repo_root "$workdir" \
  --arg branch "${branch:-}" \
  --arg model "$model" \
  --arg brief "$promptfile" \
  --arg spawn_ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg slug "$manifest_slug" \
  --argjson keep_going_max "$kg_max_json" \
  '{tab:$tab, worktree:$worktree, repo_root:$repo_root, branch:(if ($branch|length)>0 then $branch else null end), model:$model, brief:$brief, spawn_ts:$spawn_ts, transcript_slug:$slug, keep_going_max:$keep_going_max}')
manifest_lock="${TMPDIR:-/tmp}/zj-manifest-lock-$(printf '%s' "$manifest_file" | tr -c 'A-Za-z0-9' '-')"
manifest_wait=0
until mkdir "$manifest_lock" 2>/dev/null; do
  sleep 0.2
  manifest_wait=$((manifest_wait + 1))
  [[ $manifest_wait -gt 50 ]] && break
done
manifest_tmp="$manifest_file.tmp$$"
if jq --argjson rec "$manifest_record" '. + [$rec]' "$manifest_file" > "$manifest_tmp" 2>/dev/null && jq -e . "$manifest_tmp" >/dev/null 2>&1; then
  mv "$manifest_tmp" "$manifest_file"
else
  rm -f "$manifest_tmp"
  echo "zj-claude: failed to append fleet manifest entry to $manifest_file" >&2
fi
rmdir "$manifest_lock" 2>/dev/null || true

# ── Verify the session actually started ─────────────────────────────────────
# "Tab opened" is not "session running": the process can come up and sit on a
# prompt with the brief unsent, which looks identical from the outside. Claude
# Code writes a transcript under ~/.claude/projects/<slug>/ as soon as a turn
# begins, so its appearance is proof the brief was submitted, not just typed.
# Set ZJ_VERIFY=0 to skip the wait.
if [[ "${ZJ_VERIFY:-1}" != "0" ]]; then
  slug_dir=$(printf '%s' "$launch_dir_native" | sed 's|[:/.]|-|g')
  proj_dir="$HOME/.claude/projects/$slug_dir"
  waited=0
  until [[ -n "$(find "$proj_dir" -name '*.jsonl' -newermt '-5 minutes' 2>/dev/null | head -1)" ]]; do
    sleep 2
    waited=$((waited + 2))
    # A --setup hook (pnpm install, mix deps.get) runs BEFORE claude, so the
    # transcript is legitimately minutes away. Allow for it rather than crying
    # wolf on a session that is just still installing.
    if [[ $waited -ge ${ZJ_VERIFY_TIMEOUT:-$([[ -n "$setup" ]] && echo 900 || echo 60)} ]]; then
      echo "zj-claude: WARNING — tab '$name' opened but no session transcript appeared in ${waited}s." >&2
      echo "zj-claude: the brief may be sitting unsent in the composer. Switch to the tab and check." >&2
      exit 3
    fi
  done
  echo "zj-claude: session confirmed running (transcript in $proj_dir)"
fi
