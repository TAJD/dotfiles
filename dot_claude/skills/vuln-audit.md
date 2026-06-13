---
name: vuln-audit
description: Scan GitHub repos for vulnerability alerts and Dependabot PRs, output prioritized action plan
---

# Vulnerability Audit

Run the vuln-audit script and act on findings.

## Steps

1. **Run the audit**:
   ```bash
   bash ~/.claude/scripts/vuln-audit.sh
   ```
   Or for a single repo: `bash ~/.claude/scripts/vuln-audit.sh --repo OWNER/REPO`

2. **Parse and present** the output to the user as a structured summary.

3. **Offer next actions** based on findings:
   - "Want me to merge the N passing PRs?" → invoke `/merge-dependabot OWNER/REPO`
   - "Want me to investigate the failing CI on repo X?" → check logs with `gh run view --log-failed`
   - "Want me to enable Dependabot alerts on repos where they're disabled?" → `MSYS_NO_PATHCONV=1 gh api -X PUT /repos/OWNER/REPO/vulnerability-alerts`

4. **Important reminders**:
   - Always use `MSYS_NO_PATHCONV=1` on `gh` commands (Windows Git Bash)
   - Dependabot PRs lack repo secrets — deploy step failures are expected
   - After merging several PRs, lockfile conflicts are common — close + `@dependabot recreate`
