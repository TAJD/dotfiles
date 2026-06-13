#!/usr/bin/env bash
# dependabot-setup.sh — Audit Dependabot configuration coverage across GitHub repos
# Usage: dependabot-setup.sh [--repo OWNER/REPO] [--since DAYS]
#   --since DAYS  Skip repos with no pushes in the last N days (default 365). Ignored with --repo.
set -euo pipefail

SINGLE_REPO=""
SINCE_DAYS=365
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  SINGLE_REPO="$2"; shift 2 ;;
    --since) SINCE_DAYS="$2";  shift 2 ;;
    *) echo "Usage: dependabot-setup.sh [--repo OWNER/REPO] [--since DAYS]"; exit 1 ;;
  esac
done

USER=$(MSYS_NO_PATHCONV=1 gh api /user --jq '.login' 2>/dev/null)
DATE=$(date +%Y-%m-%d)
CUTOFF=$(date -u -d "$SINCE_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)

echo "=== DEPENDABOT CONFIGURATION AUDIT ==="
echo "Date: $DATE"
echo "User: $USER"
[[ -z "$SINGLE_REPO" ]] && echo "Filter: pushed since $CUTOFF (last $SINCE_DAYS days)"
echo ""

# Collect repos
if [[ -n "$SINGLE_REPO" ]]; then
  REPOS=("$SINGLE_REPO")
else
  mapfile -t REPOS < <(MSYS_NO_PATHCONV=1 gh api '/user/repos?per_page=100&type=owner' \
    --jq ".[] | select(.archived == false and .fork == false and .pushed_at > \"$CUTOFF\") | .full_name")
fi

ALERTS_OFF=0; SECFIX_OFF=0; MISSING_YML=0; COVERAGE_GAPS=0; TOTAL_OPEN_PRS=0

printf "%-40s %-7s %-10s %-22s %-22s %-9s\n" \
  "REPO" "ALERTS" "SEC-FIXES" "DEPENDABOT.YML" "ECOSYSTEMS-DETECTED" "OPEN-PRS"
printf '%s\n' "$(printf '%-120s' '' | tr ' ' '-')"

for REPO in "${REPOS[@]}"; do
  # Check vulnerability alerts
  if MSYS_NO_PATHCONV=1 gh api "/repos/$REPO/vulnerability-alerts" --silent 2>/dev/null; then
    ALERTS_STATUS="ON"
  else
    ALERTS_STATUS="OFF"
    ALERTS_OFF=$((ALERTS_OFF + 1))
  fi

  # Check automated security fixes
  if MSYS_NO_PATHCONV=1 gh api "/repos/$REPO/automated-security-fixes" --silent 2>/dev/null; then
    SECFIX_STATUS="ON"
  else
    SECFIX_STATUS="OFF"
    SECFIX_OFF=$((SECFIX_OFF + 1))
  fi

  # Detect ecosystems from file tree
  TREE=$(MSYS_NO_PATHCONV=1 gh api "/repos/$REPO/git/trees/HEAD?recursive=1" \
    --jq '.tree[].path' 2>/dev/null) || TREE=""

  DETECTED_ECOS=()
  if echo "$TREE" | grep -q 'package\.json$'; then DETECTED_ECOS+=("npm"); fi
  if echo "$TREE" | grep -q 'mix\.exs$'; then DETECTED_ECOS+=("mix"); fi
  if echo "$TREE" | grep -q 'Cargo\.toml$'; then DETECTED_ECOS+=("cargo"); fi
  if echo "$TREE" | grep -qE '(pyproject\.toml|requirements[^/]*\.txt|Pipfile|setup\.py)$'; then DETECTED_ECOS+=("pip"); fi
  if echo "$TREE" | grep -q 'go\.mod$'; then DETECTED_ECOS+=("gomod"); fi
  if echo "$TREE" | grep -q 'Gemfile$'; then DETECTED_ECOS+=("bundler"); fi
  if echo "$TREE" | grep -q 'composer\.json$'; then DETECTED_ECOS+=("composer"); fi
  if echo "$TREE" | grep -qE '\.github/workflows/[^/]+\.ya?ml$'; then DETECTED_ECOS+=("github-actions"); fi
  if echo "$TREE" | grep -q 'Dockerfile'; then DETECTED_ECOS+=("docker"); fi

  if [[ ${#DETECTED_ECOS[@]} -gt 0 ]]; then
    DETECTED_STR=$(IFS=','; echo "${DETECTED_ECOS[*]}")
  else
    DETECTED_STR="none"
  fi

  # Check existing dependabot.yml
  YML_STATUS="✗"
  YML_ECOS=()
  for YML_PATH in ".github/dependabot.yml" ".github/dependabot.yaml"; do
    YML_CONTENT=$(MSYS_NO_PATHCONV=1 gh api "/repos/$REPO/contents/$YML_PATH" \
      --jq '.content' 2>/dev/null | base64 -d 2>/dev/null) || YML_CONTENT=""
    if [[ -n "$YML_CONTENT" ]]; then
      mapfile -t YML_ECOS < <(echo "$YML_CONTENT" | \
        grep -E '^\s*-?\s*package-ecosystem:' | \
        sed 's/.*package-ecosystem:\s*//; s/["\x27 ]//g')
      if [[ ${#YML_ECOS[@]} -gt 0 ]]; then
        ECO_LIST=$(IFS=','; echo "${YML_ECOS[*]}")
        YML_STATUS="✓ ($ECO_LIST)"
      else
        YML_STATUS="✓ (no-ecos)"
      fi
      break
    fi
  done

  if [[ "$YML_STATUS" == "✗" ]]; then
    if [[ "$DETECTED_STR" != "none" ]]; then
      MISSING_YML=$((MISSING_YML + 1))
    fi
  else
    # Check coverage gaps: detected ecos not in yml
    GAP=false
    for eco in "${DETECTED_ECOS[@]}"; do
      if ! printf '%s\n' "${YML_ECOS[@]}" | grep -qx "$eco"; then
        GAP=true; break
      fi
    done
    if [[ "$GAP" == "true" ]]; then
      COVERAGE_GAPS=$((COVERAGE_GAPS + 1))
    fi
  fi

  # Count open Dependabot PRs
  OPEN_PRS=$(MSYS_NO_PATHCONV=1 gh pr list --repo "$REPO" --author 'app/dependabot' \
    --state open --json number --jq 'length' 2>/dev/null) || OPEN_PRS=0
  TOTAL_OPEN_PRS=$((TOTAL_OPEN_PRS + OPEN_PRS))

  printf "%-40s %-7s %-10s %-22s %-22s %-9s\n" \
    "$REPO" "$ALERTS_STATUS" "$SECFIX_STATUS" "$YML_STATUS" "$DETECTED_STR" "$OPEN_PRS"
done

echo ""
echo "--- SUMMARY ---"
echo "Repos scanned: ${#REPOS[@]}"
echo "Repos with alerts OFF: $ALERTS_OFF"
echo "Repos with security-fixes OFF: $SECFIX_OFF"
echo "Repos missing dependabot.yml (with detected ecosystems): $MISSING_YML"
echo "Repos with dependabot.yml coverage gaps: $COVERAGE_GAPS"
echo "Open Dependabot PRs across all repos: $TOTAL_OPEN_PRS"
