#!/usr/bin/env bash
# vuln-audit.sh — Scan GitHub repos for vulnerability alerts and Dependabot PRs
# Usage: vuln-audit.sh [--repo OWNER/REPO]
set -euo pipefail

SINGLE_REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) SINGLE_REPO="$2"; shift 2 ;;
    *) echo "Usage: vuln-audit.sh [--repo OWNER/REPO]"; exit 1 ;;
  esac
done

USER=$(MSYS_NO_PATHCONV=1 gh api /user --jq '.login' 2>/dev/null)
DATE=$(date +%Y-%m-%d)

echo "=== VULNERABILITY AUDIT ==="
echo "Date: $DATE"
echo "User: $USER"
echo ""

# Collect repos
if [[ -n "$SINGLE_REPO" ]]; then
  REPOS=("$SINGLE_REPO")
else
  mapfile -t REPOS < <(MSYS_NO_PATHCONV=1 gh api '/user/repos?per_page=100&type=owner' \
    --jq '.[] | select(.archived == false and .fork == false) | .full_name')
fi

declare -a HIGH_ALERTS=() MEDIUM_ALERTS=() LOW_ALERTS=() NO_ALERTS=()
TOTAL_ALERTS=0; HIGH_COUNT=0; MEDIUM_COUNT=0; LOW_COUNT=0
REPOS_WITH_ALERTS=0; PR_PASSING=0; PR_FAILING=0; PR_PENDING=0; PR_NOCHECKS=0

for REPO in "${REPOS[@]}"; do
  # Get alerts
  ALERTS=$(MSYS_NO_PATHCONV=1 gh api "/repos/$REPO/dependabot/alerts?state=open&per_page=100" \
    --jq '.[] | "\(.security_advisory.severity)|\(.dependency.package.name)|\(.security_advisory.summary)"' 2>/dev/null) || ALERTS="DISABLED"

  if [[ "$ALERTS" == "DISABLED" || -z "$ALERTS" ]]; then
    if [[ "$ALERTS" != "DISABLED" ]]; then
      NO_ALERTS+=("$REPO")
    else
      NO_ALERTS+=("$REPO (alerts disabled)")
    fi
    continue
  fi

  REPOS_WITH_ALERTS=$((REPOS_WITH_ALERTS + 1))

  # Get Dependabot PRs for this repo
  PR_INFO=$(MSYS_NO_PATHCONV=1 gh pr list --repo "$REPO" --author 'app/dependabot' --state open \
    --json number,title,statusCheckRollup \
    --jq '.[] | "\(.number)|\(.title)|\(
      if (.statusCheckRollup | length) == 0 then "NO CHECKS"
      elif (.statusCheckRollup | all(.conclusion == "SUCCESS")) then "PASS"
      elif (.statusCheckRollup | any(.conclusion == "FAILURE")) then "FAIL"
      elif (.statusCheckRollup | any(.status == "IN_PROGRESS" or .status == "QUEUED")) then "PENDING"
      else "UNKNOWN" end)"' 2>/dev/null) || PR_INFO=""

  # Count PR statuses
  while IFS= read -r pr_line; do
    [[ -z "$pr_line" ]] && continue
    ci=$(echo "$pr_line" | cut -d'|' -f3)
    case "$ci" in
      PASS) PR_PASSING=$((PR_PASSING + 1)) ;;
      FAIL) PR_FAILING=$((PR_FAILING + 1)) ;;
      PENDING) PR_PENDING=$((PR_PENDING + 1)) ;;
      "NO CHECKS") PR_NOCHECKS=$((PR_NOCHECKS + 1)) ;;
    esac
  done <<< "$PR_INFO"

  # Process alerts by severity
  while IFS= read -r alert; do
    [[ -z "$alert" ]] && continue
    sev=$(echo "$alert" | cut -d'|' -f1)
    pkg=$(echo "$alert" | cut -d'|' -f2)
    summary=$(echo "$alert" | cut -d'|' -f3)
    TOTAL_ALERTS=$((TOTAL_ALERTS + 1))

    entry="[$REPO] $pkg: $summary ($sev)"

    # Find matching PRs for this package
    pr_matches=""
    while IFS= read -r pr_line; do
      [[ -z "$pr_line" ]] && continue
      pr_num=$(echo "$pr_line" | cut -d'|' -f1)
      pr_title=$(echo "$pr_line" | cut -d'|' -f2)
      pr_ci=$(echo "$pr_line" | cut -d'|' -f3)
      if echo "$pr_title" | grep -qi "$pkg"; then
        pr_matches="${pr_matches}\n  PR #${pr_num}: ${pr_title} [CI: ${pr_ci}]"
      fi
    done <<< "$PR_INFO"

    case "$sev" in
      critical|high)
        HIGH_COUNT=$((HIGH_COUNT + 1))
        HIGH_ALERTS+=("${entry}${pr_matches}") ;;
      medium)
        MEDIUM_COUNT=$((MEDIUM_COUNT + 1))
        MEDIUM_ALERTS+=("${entry}${pr_matches}") ;;
      low)
        LOW_COUNT=$((LOW_COUNT + 1))
        LOW_ALERTS+=("${entry}${pr_matches}") ;;
    esac
  done <<< "$ALERTS"

  # Show any PRs not matched to alerts
  while IFS= read -r pr_line; do
    [[ -z "$pr_line" ]] && continue
    pr_num=$(echo "$pr_line" | cut -d'|' -f1)
    pr_title=$(echo "$pr_line" | cut -d'|' -f2)
    pr_ci=$(echo "$pr_line" | cut -d'|' -f3)
    matched=false
    while IFS= read -r alert; do
      [[ -z "$alert" ]] && continue
      pkg=$(echo "$alert" | cut -d'|' -f2)
      if echo "$pr_title" | grep -qi "$pkg"; then matched=true; break; fi
    done <<< "$ALERTS"
    if [[ "$matched" == "false" ]]; then
      entry="[$REPO] Unmatched PR #${pr_num}: ${pr_title} [CI: ${pr_ci}]"
      MEDIUM_ALERTS+=("$entry")
    fi
  done <<< "$PR_INFO"
done

# Output
if [[ ${#HIGH_ALERTS[@]} -gt 0 ]]; then
  echo "--- CRITICAL/HIGH ---"
  for a in "${HIGH_ALERTS[@]}"; do echo -e "$a"; done
  echo ""
fi

if [[ ${#MEDIUM_ALERTS[@]} -gt 0 ]]; then
  echo "--- MEDIUM ---"
  for a in "${MEDIUM_ALERTS[@]}"; do echo -e "$a"; done
  echo ""
fi

if [[ ${#LOW_ALERTS[@]} -gt 0 ]]; then
  echo "--- LOW ---"
  for a in "${LOW_ALERTS[@]}"; do echo -e "$a"; done
  echo ""
fi

if [[ ${#NO_ALERTS[@]} -gt 0 ]]; then
  echo "--- REPOS WITH NO ALERTS ---"
  echo "${NO_ALERTS[*]}" | tr ' ' '\n' | paste -sd', ' -
  echo ""
fi

echo "--- SUMMARY ---"
echo "Repos scanned: ${#REPOS[@]}"
echo "Repos with alerts: $REPOS_WITH_ALERTS"
echo "Total alerts: $TOTAL_ALERTS ($HIGH_COUNT high, $MEDIUM_COUNT medium, $LOW_COUNT low)"
echo "PRs ready to merge (CI passing): $PR_PASSING"
echo "PRs needing attention (CI failing): $PR_FAILING"
echo "PRs pending CI: $PR_PENDING"
echo "PRs with no CI checks: $PR_NOCHECKS"
