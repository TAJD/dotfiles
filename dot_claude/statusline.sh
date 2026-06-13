#!/usr/bin/env bash
# Claude Code statusline: [model] repo (branch) · ctx N%
# Receives JSON on stdin from Claude Code.
input=$(cat)

MODEL=$(printf '%s' "$input" | jq -r '.model.display_name // "claude"')
DIR=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // "."')
CTX=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')

REPO=$(basename "$DIR")
BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null)

# ANSI: dim grey separators, cyan repo, yellow branch, magenta model, red/green sync
DIM=$'\033[2m'; RESET=$'\033[0m'
CYAN=$'\033[36m'; YELLOW=$'\033[33m'; MAGENTA=$'\033[35m'
RED=$'\033[31m'; GREEN=$'\033[32m'

# Sync indicators (only if in a git repo)
SYNC=""
if [ -n "$BRANCH" ]; then
  # vs upstream (origin/<branch>): ↑ahead ↓behind
  if upstream=$(git -C "$DIR" rev-list --left-right --count "@{u}...HEAD" 2>/dev/null); then
    behind=${upstream%%	*}; ahead=${upstream##*	}
    [ "$ahead"  != "0" ] && SYNC="${SYNC} ${GREEN}↑${ahead}${RESET}"
    [ "$behind" != "0" ] && SYNC="${SYNC} ${RED}↓${behind}${RESET}"
  else
    SYNC="${SYNC} ${DIM}(no upstream)${RESET}"
  fi
  # vs main: Δ commits diverged (only when not on main itself)
  main=$(git -C "$DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  main=${main:-main}
  if [ "$BRANCH" != "$main" ] && diff=$(git -C "$DIR" rev-list --left-right --count "origin/${main}...HEAD" 2>/dev/null); then
    mb=${diff%%	*}; ma=${diff##*	}
    [ "$ma" != "0" ] || [ "$mb" != "0" ] && SYNC="${SYNC} ${DIM}Δ${main}${RESET} ${YELLOW}+${ma}${RESET}/${RED}-${mb}${RESET}"
  fi
fi

out="${MAGENTA}${MODEL}${RESET} ${DIM}|${RESET} ${CYAN}${REPO}${RESET}"
[ -n "$BRANCH" ] && out="${out} ${DIM}(${RESET}${YELLOW}${BRANCH}${DIM})${RESET}"
[ -n "$SYNC" ]   && out="${out}${SYNC}"
[ -n "$CTX" ]    && out="${out} ${DIM}·${RESET} ctx ${CTX}%"

printf '%s' "$out"
