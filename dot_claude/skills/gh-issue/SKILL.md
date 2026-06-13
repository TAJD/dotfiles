---
name: gh-issue
description: Create a GitHub issue and add it to TAJD's project board (project 6). Use when the user asks to raise, create, or file a GitHub issue. Detects the current repo automatically; falls back to TAJD/planning if no GitHub remote is found or the user doesn't specify.
---

# gh-issue

Create a GitHub issue and add it to the TAJD project board (project 6, view 3).

## Steps

1. **Determine the target repo:**
   - Run `gh repo view --json nameWithOwner --jq '.nameWithOwner'` in the current directory.
   - If it returns a valid `owner/repo`, use that.
   - If it errors (not a git repo, no remote, not a GitHub remote) or the user explicitly said "planning", use `TAJD/planning`.

2. **Create the issue:**
   ```bash
   gh issue create --repo <repo> --title "<title>" --body "<description>"
   ```
   - Title comes from the user's invocation args.
   - If no description was provided, use an empty string for `--body` (omit the flag).
   - Capture the returned issue URL.

3. **Add to project board:**
   ```bash
   gh project item-add 6 --owner TAJD --url <issue-url>
   ```

4. **Report back:** Output the issue URL so the user can navigate to it.

## Notes

- If the user provides both a title and a description, pass both. If only a title, skip `--body`.
- Do not ask clarifying questions before running — act on what the user provided.
- If `gh` is not authenticated, surface the error directly; do not attempt a workaround.
