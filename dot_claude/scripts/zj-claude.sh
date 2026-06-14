#!/usr/bin/env bash
# zj-claude.sh — spawn an autonomous Claude Code session in a new, named zellij tab.
#
# Usage: zj-claude.sh <tab-name> <workdir> <prompt | @prompt-file>
#   <tab-name>   name for the new zellij tab
#   <workdir>    Windows path to start in, e.g. C:\Users\me\repo (or C:/Users/me/repo)
#   <prompt>     initial prompt text. AVOID embedded double-quotes (cmd.exe breaks on them).
#   @<file>      point Claude at an EXISTING file to read — expands to
#                "Read <file> in full, then carry out the work it describes."
#   @-           read the prompt from STDIN. The script writes it to a UNIQUE ephemeral
#                temp file under $TMPDIR/claude-spawn (pruned after a day) and points
#                Claude at that. PREFERRED for long/complex prompts: no fixed path to
#                clash on parallel spawns, nothing left behind in tracked dirs. e.g.
#                  printf '%s' "$long_prompt" | zj-claude.sh tab 'C:\dir' @-
#
# Why this exists / gotchas baked in (see memory: zellij-new-tabs-use-cmd):
#   - New zellij tabs run cmd.exe, NOT bash/pwsh — so we `cd /d "..."` and submit the
#     cd and the claude command as SEPARATE lines (cmd doesn't chain with `;`).
#   - We pass --dangerously-skip-permissions so the spawned session runs unattended
#     instead of stalling at the first permission prompt.
#   - We pass --model sonnet so spawned sessions default to Sonnet (cheaper for the
#     bounded, well-specified work these autonomous tabs usually do). Override per-call
#     with the MODEL env var (e.g. MODEL=opus zj-claude.sh ...) or /model in-session.
#   - READINESS RACE (see memory: zj-claude-settle-race): a fresh cmd.exe tab needs a
#     beat to draw its prompt before it can receive keystrokes. write-chars fired too
#     early drops/garbles characters; if the flag portion is clipped, claude launches
#     in NORMAL (prompting) mode and the session stalls waiting for a human. This bit
#     when spawning under heavy load (other sessions/builds running). We settle after
#     new-tab and after the cd. Bump the delays with ZJ_SETTLE if you still see it on a
#     loaded box. ALWAYS confirm the launched tab shows `--dangerously-skip-permissions`.
#
# No-op (exit 0) when not inside a zellij session.
set -euo pipefail

name="${1:?usage: zj-claude.sh <tab-name> <workdir> <prompt|@file>}"
workdir="${2:?usage: zj-claude.sh <tab-name> <workdir> <prompt|@file>}"
prompt_arg="${3:?usage: zj-claude.sh <tab-name> <workdir> <prompt|@file>}"
model="${MODEL:-sonnet}" # spawned sessions default to Sonnet; override with MODEL=...
settle="${ZJ_SETTLE:-1.5}" # seconds to let a fresh cmd.exe tab become ready; bump under load

if [[ "$prompt_arg" == "@-" ]]; then
  # Read the prompt from stdin into a UNIQUE ephemeral temp file, so parallel spawns
  # never clash and nothing is left behind in tracked dirs like ~/.claude.
  spawndir="${TMPDIR:-/tmp}/claude-spawn"
  mkdir -p "$spawndir"
  find "$spawndir" -type f -mtime +1 -delete 2>/dev/null || true   # prune yesterday's prompts
  tf="$(mktemp "$spawndir/${name}-XXXXXX.md")"
  cat > "$tf"
  file="$(cygpath -w "$tf" 2>/dev/null || echo "$tf")"   # claude runs in cmd.exe → needs a Windows path
  prompt="Read ${file} in full, then carry out the work it describes."
elif [[ "$prompt_arg" == @* ]]; then
  file="${prompt_arg:1}"
  prompt="Read ${file} in full, then carry out the work it describes."
else
  prompt="$prompt_arg"
fi

if [ -z "${ZELLIJ:-}" ]; then
  echo "zj-claude: not in a zellij session — skipping (would start claude in ${workdir})"
  exit 0
fi

zellij action new-tab --name "$name"
sleep "$settle"                                  # let the fresh cmd.exe tab draw its prompt
zellij action write-chars "cd /d \"${workdir}\"" # cmd.exe: /d handles drive changes
zellij action write 13                           # Enter
sleep 0.6                                         # let the cd land before the launch line
zellij action write-chars "claude --dangerously-skip-permissions --model ${model} \"${prompt}\""
zellij action write 13 # Enter
echo "zj-claude: opened tab '$name' in ${workdir} → claude --dangerously-skip-permissions --model ${model}"
