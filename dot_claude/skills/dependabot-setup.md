---
name: dependabot-setup
description: Audit Dependabot configuration coverage across GitHub repos and remediate gaps — enable vulnerability alerts, enable automated security fixes, open PR with .github/dependabot.yml for detected ecosystems
---

# Dependabot Setup

Sibling context: `/vuln-audit` lists open alerts + matching PRs. `/merge-dependabot` merges them. This skill closes configuration gaps so Dependabot is actually doing its job — alerts enabled, security fixes enabled, and a `dependabot.yml` covering detected ecosystems.

## Phase 1: Audit

```bash
bash ~/.claude/scripts/dependabot-setup.sh
```

Or for a single repo: `bash ~/.claude/scripts/dependabot-setup.sh --repo OWNER/REPO`

Default skips repos with no pushes in the last 365 days. Override with `--since DAYS` (e.g. `--since 90`).

Present the table. Summarize: N repos with alerts OFF, N with security-fixes OFF, N missing yml, N with coverage gaps.

## Phase 2: Remediate

### Part A — Toggles (apply immediately, no per-repo prompt)

For each repo with ALERTS=OFF:
```bash
MSYS_NO_PATHCONV=1 gh api -X PUT "/repos/OWNER/REPO/vulnerability-alerts"
```

For each repo with SEC-FIXES=OFF:
```bash
MSYS_NO_PATHCONV=1 gh api -X PUT "/repos/OWNER/REPO/automated-security-fixes"
```

Report summary at end: "Enabled alerts on N repos, security-fixes on N repos."

### Part B — dependabot.yml PR (per-repo y/n)

Only for repos where `DEPENDABOT.YML = ✗` AND at least one ecosystem was detected. Never overwrite an existing yml.

Generate and show the proposed yaml, then ask y/n:

```yaml
version: 2
updates:
  - package-ecosystem: "ECOSYSTEM"
    directory: "/"
    schedule:
      interval: "weekly"
    groups:
      minor-and-patch:
        applies-to: version-updates
        update-types: ["minor", "patch"]
      security-updates:
        applies-to: security-updates
        patterns: ["*"]
```

One block per detected ecosystem. Both groups are required: without `applies-to: security-updates`, vulnerability fixes arrive as one PR per CVE instead of one grouped PR. `applies-to` must be explicit on the version-updates group too — otherwise the second group block is silently ignored. On y, create the branch and open a PR:

```bash
BRANCH=$(MSYS_NO_PATHCONV=1 gh repo view OWNER/REPO --json defaultBranchRef --jq '.defaultBranchRef.name')
SHA=$(MSYS_NO_PATHCONV=1 gh api "/repos/OWNER/REPO/git/refs/heads/$BRANCH" --jq '.object.sha')
MSYS_NO_PATHCONV=1 gh api -X POST "/repos/OWNER/REPO/git/refs" \
  -f ref="refs/heads/chore/dependabot-config" -f sha="$SHA"
B64=$(base64 -w0 < /tmp/dependabot.yml)
MSYS_NO_PATHCONV=1 gh api -X PUT "/repos/OWNER/REPO/contents/.github/dependabot.yml" \
  -f message="Configure Dependabot version updates" \
  -f content="$B64" \
  -f branch="chore/dependabot-config"
MSYS_NO_PATHCONV=1 gh pr create --repo OWNER/REPO --base "$BRANCH" \
  --head chore/dependabot-config \
  --title "Configure Dependabot version updates" \
  --body "Adds .github/dependabot.yml covering detected ecosystems: ECOSYSTEMS."
```

Write the yaml to `/tmp/dependabot.yml` before running the block.

### Part C — Coverage gaps (report only)

For repos where yml exists but is missing one or more detected ecosystems: list which ecosystems are absent and let the user decide. Do not auto-PR.

## Phase 3: Summary

```
Toggles: enabled alerts on N repos, security-fixes on N repos
PRs opened: <list URLs>
Skipped: <list with reason>
```

If any repos have open Dependabot PRs waiting to merge, point user at `/merge-dependabot OWNER/REPO`.

## Key Rules

- Always `MSYS_NO_PATHCONV=1` on every `gh` command
- Never overwrite existing `.github/dependabot.yml`
- Owned non-fork non-archived repos only (script default)
