---
name: merge-dependabot
description: Automate merging Dependabot PRs - merges one at a time with CI verification, handles conflicts and recreates
---

# Merge Dependabot PRs

Automates the merge-rebase-wait-repeat cycle for Dependabot PRs on a GitHub repo.

## Usage

- `/merge-dependabot` — current repo (from `gh repo view`)
- `/merge-dependabot OWNER/REPO` — specific repo

## Workflow

### 1. Discover PRs

```bash
MSYS_NO_PATHCONV=1 gh pr list --repo REPO --author 'app/dependabot' --state open \
  --json number,title,statusCheckRollup \
  --jq '.[] | "#\(.number) \(.title) | CI: \(if (.statusCheckRollup | length) == 0 then "NO CHECKS" elif (.statusCheckRollup | all(.conclusion == "SUCCESS")) then "PASS" elif (.statusCheckRollup | any(.conclusion == "FAILURE")) then "FAIL" else "PENDING" end)"'
```

### 2. Prioritize

1. GitHub Actions version bumps (actions/checkout, actions/setup-node, etc.) — lowest risk
2. Single-package bumps with CI passing
3. Dependency group bumps with CI passing
4. PRs with no CI checks (trigger rebase first to get CI running)
5. PRs with CI failures — investigate last

### 3. Merge Loop

For each PR in priority order:

```
a. Check CI status: `MSYS_NO_PATHCONV=1 gh pr checks NUMBER --repo REPO`
b. Check mergeability: `MSYS_NO_PATHCONV=1 gh pr view NUMBER --repo REPO --json mergeable --jq '.mergeable'`
c. If PASS + MERGEABLE → merge: `MSYS_NO_PATHCONV=1 gh pr merge NUMBER --repo REPO --merge`
d. Trigger rebase on remaining PRs: comment `@dependabot rebase` on each
e. Wait ~90-120 seconds for rebase + CI
f. Move to next PR
```

### 4. Handle Failures

**Lockfile conflicts** (common after merging several PRs):
```bash
MSYS_NO_PATHCONV=1 gh pr close NUMBER --repo REPO --comment "@dependabot recreate"
```

**CI failures** — check if pre-existing or caused by the bump:
```bash
MSYS_NO_PATHCONV=1 gh run view RUN_ID --repo REPO --log-failed 2>&1 | tail -20
```

Known expected failures on Dependabot PRs:
- **Missing secrets** (CLOUDFLARE_API_TOKEN, etc.) — Dependabot PRs don't get repo secrets. Deploy/seed steps failing is OK.
- **Prettier on pnpm-lock.yaml** — add lockfile to `.prettierignore` if this blocks CI
- **Vercel preview deploy failures** — pre-existing, not related to the bump

Only block on failures in: lint, typecheck, unit tests, integration tests, build.

**Real build failures** — report to user, skip the PR.

### 5. Summary

After processing all PRs, output:

```
## Results for REPO
- Merged: #N (title), #N (title), ...
- Skipped (CI failure): #N (title) — reason
- Closed + recreating: #N (title) — lockfile conflict
- Still pending: #N (title) — awaiting CI
```

## Key Rules

- ALWAYS prefix `gh` commands with `MSYS_NO_PATHCONV=1` (Windows Git Bash path mangling)
- Use `rtk` prefix on commands per user conventions
- Never force-merge — always verify CI first
- Be patient with CI — wait for checks to complete rather than skipping
- E2E test failures with `continue-on-error: true` in CI config are acceptable
