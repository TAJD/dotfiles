---
name: daily-summary
description: Summarize a repo's state — marketecture diagram, in-flight work, open PRs/issues, and bv next steps — or roll up across all beads-tracked repos. Use when the user runs /daily-summary, asks for a daily or standup summary of a repo, wants a repo status overview, or asks to generate/refresh a repo's marketecture diagram (--prep).
---

# daily-summary

Summarize a repository (or roll up across all beads-tracked repos) and write a dated
markdown trail. A `--prep` stage generates and maintains each repo's marketecture diagram.

## Paths
- Gather script: `$env:USERPROFILE\.claude\skills\daily-summary\scripts\gather.ps1`
- Daily output dir: `$env:USERPROFILE\notes\daily\` (create if missing)
- Invoke the gather script with: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <gather.ps1> <args>`

## Parse the invocation

Read `$ARGUMENTS`. Determine the mode:

| Args | Mode |
|------|------|
| `--prep --all` | PREP-ALL |
| `--prep <repo>` | PREP-ONE |
| `--all` | ROLLUP |
| `<repo>` | SINGLE |
| (empty) | Ask the user: which repo, or `--all`? Then re-dispatch. |

To resolve `<repo>` to a path, run `gather.ps1 -Resolve <repo>`. If `resolved` is
false, print the `candidates` (or, if empty, run `gather.ps1 -ListBeadsRepos` and show
those names) and stop.

Today's date for filenames and the `updated:` marker: get it from the environment
(the date is provided in your context); format `YYYY-MM-DD`.

## PREP-ONE (`--prep <repo>`)

1. Resolve `<repo>` → path. Run `gather.ps1 -RepoPath <path>` and read the envelope.
2. **Infer** an ASCII boxes-and-arrows marketecture diagram for the repo from:
   - the repo's top-level structure and key modules (read what you need),
   - the repo's existing `CLAUDE.md` prose if present,
   - the beads picture (`marketecture` is *not* in the envelope yet for new repos;
     use `beads.*_raw` and, if useful, epics/labels) to label major components.
   Keep it conceptual (components + flow), not a folder tree. Mirror the ASCII style
   already used in the user's CLAUDE.md architecture blocks.
3. Build the proposed `docs/marketecture.md` content exactly in this shape:

   ```
   ## Marketecture

   <ascii diagram>

   <!-- marketecture:updated: YYYY-MM-DD -->
   ```

4. If `marketecture.exists` was true, show a diff vs the existing `content`; otherwise
   show the full proposed file. **Ask the user to approve** before writing. Do not write
   on decline.
5. On approval:
   - Write `docs/marketecture.md` (create `docs/` if needed).
   - Ensure `CLAUDE.md` references it. If `CLAUDE.md` does not already contain
     `@docs/marketecture.md`, append:

     ```
     ## Marketecture

     @docs/marketecture.md
     ```

     Create `CLAUDE.md` if absent. Never embed the diagram body in `CLAUDE.md`.
   - Leave both files **uncommitted**. Tell the user what changed.

## PREP-ALL (`--prep --all`)

Run `gather.ps1 -ListBeadsRepos`. For each repo, run the PREP-ONE flow (steps 1–5),
proposing and confirming per repo. Summarize at the end which repos were updated,
skipped, or declined.

## SINGLE (`<repo>`) — read-only

1. Resolve `<repo>` → path. Run `gather.ps1 -RepoPath <path>`; read the envelope.
2. Render this report (ASCII only), in this section order, to the terminal AND to
   `$env:USERPROFILE\notes\daily\<YYYY-MM-DD>-<repo>.md` (overwrite if it exists):

   1. **Header** — repo name, `git.branch`, ahead/behind (omit if both 0), timestamp.
   2. **Marketecture** — print `marketecture.content` verbatim. If
      `marketecture.exists` is false: "_No diagram yet — run `/daily-summary --prep
      <repo>` to create one._". Do **not** infer here.
   3. **In-flight work** — `in_progress` beads (from `beads.in_progress_raw`),
      `git.dirty_count` + `git.dirty_files`, `git.recent_commits`, `git.stash_count`.
   4. **Open PRs** — from `gh.prs_raw`. If `gh.available` is false, omit this section
      silently.
   5. **Open issues** — open beads + (if `gh.available`) `gh.issues_raw`.
   6. **Next steps** — from `bv.next_raw` / `bv.triage_raw`. If `bv.available` is
      false, fall back to `beads.ready_raw` (or note "no beads tracking" if
      `beads.available` is false too).
   7. **Beads health** — counts from `beads.status_raw` (open/ready/blocked/closed).
      If `beads.available` is false: "_No beads tracking in this repo._".
3. Tell the user the file path you wrote.

## ROLLUP (`--all`) — read-only

1. Run `gather.ps1 -ListBeadsRepos` to get the repo set.
2. For each repo, run `gather.ps1 -RepoPath <path> -Lite`.
3. Render one compact table (ASCII) to the terminal AND to
   `$env:USERPROFILE\notes\daily\<YYYY-MM-DD>.md` (overwrite if it exists):

   ```
   repo | branch | dirty | in-prog | ready | blocked | PRs | bv top pick | diagram
   ```

   - `dirty` = `git.dirty_count` (or `-` if 0).
   - counts from `beads.*_count`, `gh.pr_count`.
   - `bv top pick` = the single recommendation extracted from `bv.next_raw` (or `-`).
   - `diagram` = `marketecture.status` mapped: `ok`→`✓`, `stale`→`stale`, `missing`→`missing`.
4. Below the table, list repos whose `diagram` is `stale` or `missing`, each with the
   suggestion `/daily-summary --prep <repo>`.
5. Never infer diagrams in this mode.

## Graceful degradation (all modes)

| Condition (from envelope) | Behavior |
|---------------------------|----------|
| `bv.available` false | Next steps fall back to `beads.ready_raw` |
| `beads.available` false | Beads/bv sections say "no beads tracking" |
| `gh.available` false | Omit Open PRs + gh issues silently |
| `marketecture.exists` false | SINGLE: prompt to run `--prep`. ROLLUP: `missing` |
| repo name unresolved | Print candidates (or `-ListBeadsRepos` names) and stop |
| envelope has `error` key | Report it; do not proceed for that repo |
