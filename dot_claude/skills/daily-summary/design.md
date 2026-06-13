# Design: `daily-summary` skill

**Date:** 2026-05-24
**Status:** Approved (brainstorming), pre-implementation
**Home:** `~/.claude/skills/daily-summary/` (`SKILL.md` + `scripts/gather.ps1`)

## Purpose

A personal slash-command skill that summarizes the state of a repository (or rolls
up across all beads-tracked repos): a maintained ASCII "marketecture" diagram,
in-flight work, open PRs/issues, and next steps per `bv`. Produces a terminal
summary and a dated markdown trail.

Diagram **generation** is a deliberate, separate `--prep` stage. The daily summary
modes are read-only with respect to project files.

## Build approach

**Thin gather script + LLM synthesis.**

- A PowerShell script (`scripts/gather.ps1`) deterministically collects raw data
  for one repo and emits a single JSON envelope: git state, beads JSON, `bv` robot
  output, `gh` JSON (when a remote exists), and the contents + `updated` date of the
  repo's `docs/marketecture.md` (if present).
- Claude consumes that envelope and does the model-dependent work. In `--prep`,
  that's **inferring / refreshing the marketecture diagram**; in daily modes, it's
  **writing the narrative** from already-cached data.

Rejected alternatives:
- *Prompt-only* (Claude runs every command itself): simple but slow and noisy at
  ~10 commands × N repos in roll-up mode.
- *Fully scripted report*: deterministic but cannot do diagram inference well.

## Invocation (three modes)

- `/daily-summary --prep <repo>` — generate/refresh one repo's marketecture diagram.
- `/daily-summary --prep --all` — generate/refresh diagrams across all beads repos.
- `/daily-summary <repo>` — **deep-dive** daily summary on one named repo (read-only).
- `/daily-summary --all` — **roll-up** across every `~` dir with a `.beads/` (read-only).

`<repo>` is resolved against directories under `~`. If no unambiguous match, print
the candidate list and stop.

## Prep stage (`--prep`)

The only stage that infers diagrams or writes to project files. Per repo:

1. Read existing `docs/marketecture.md` (if any) from the gather envelope.
2. Infer a fresh ASCII boxes-and-arrows diagram from repo content (top-level
   structure, key modules, CLAUDE.md prose) + beads (epics/components reflected in
   issues).
3. Diff fresh vs existing. If they differ (or no file exists), **show the proposed
   `docs/marketecture.md` content and wait for approval**. Write only on confirm.
4. Ensure `CLAUDE.md` contains a one-time reference to the diagram (see below). If
   absent, **propose adding it** and write on confirm.

In `--prep --all`, iterate beads repos, proposing each repo's changes in turn.
Writes are left **uncommitted** for the user to review and commit.

## Marketecture file + reference

**Diagram file:** `docs/marketecture.md` in each repo. ASCII diagram plus a trailing
update marker that drives staleness detection:

```
## Marketecture

<ascii boxes-and-arrows diagram>

<!-- marketecture:updated: 2026-05-24 -->
```

**Reference in `CLAUDE.md`:** a one-time `@import` line under a heading, so Claude
Code auto-loads the diagram into context when working in that repo — referenced,
not duplicated:

```
## Marketecture

@docs/marketecture.md
```

The skill never embeds the diagram body in `CLAUDE.md`; it only ensures this
reference exists.

## Single-repo report (read-only)

Order of sections in both terminal and file:

1. **Header** — repo name, current branch, ahead/behind vs upstream (if any),
   timestamp.
2. **Marketecture** — the ASCII diagram read from `docs/marketecture.md`. No
   inference. If the file is missing: "no diagram yet; run `--prep <repo>` to
   create one."
3. **In-flight work** — `in_progress` beads + uncommitted changes (file count +
   names) + recent commits (last ~5) + stashes.
4. **Open PRs** — `gh pr list`. Omitted silently if the repo has no remote.
5. **Open issues** — open beads + `gh issue list` (gh part omitted if no remote).
6. **Next steps** — `bv --robot-next` / `bv --robot-triage`. Falls back to
   `bd ready` if `bv` is absent.
7. **Beads health** — open / ready / blocked / closed counts (`bd stats`).

## Roll-up report (read-only)

A compact one-line-per-repo table. Columns:

```
repo | branch | dirty? | in-progress | ready | blocked | open PRs | bv top pick | diagram
```

- `diagram` is `✓` (file present + `updated` within threshold), `stale` (present but
  `updated` older than 30 days), or `missing`.
- Reads only `docs/marketecture.md` presence + `updated` date; never infers.
- After the table, list repos whose diagram is `missing`/`stale`, suggesting
  `/daily-summary --prep <repo>`.

## File locations (daily output)

Central history, ASCII everywhere:

- Single-repo: `C:\Users\tajdi\notes\daily\YYYY-MM-DD-<repo>.md`
- Roll-up: `C:\Users\tajdi\notes\daily\YYYY-MM-DD.md`

Both also printed to the terminal. Re-running the same target on the same day
overwrites that day's file for that target.

## Data sources & commands

Prefer robot/JSON output and `rtk`-prefixed git/gh per the user's conventions.

- **git**: branch, `git status` (dirty files), `git log -5`, `git stash list`,
  ahead/behind (`git rev-list --count`). Remote presence via `git remote`.
- **beads**: `bd stats`, `bd list --status=in_progress`, `bd ready`, `bd blocked`
  (JSON where supported).
- **bv**: `bv --robot-next --format toon`, `bv --robot-triage --format toon`.
  Guarded by `bv` on PATH **and** a `.beads/` dir.
- **gh**: `gh pr list`, `gh issue list` (JSON). Guarded by remote presence.
- **docs/marketecture.md**: file contents + `updated` date (gather reads it; only
  `--prep` writes it).

The gather script emits one JSON envelope keyed by section, with explicit
`available: true/false` flags so the synthesizer knows what to omit.

## Graceful degradation

| Condition | Behavior |
|-----------|----------|
| `bv` not on PATH | Fall back to `bd ready` for next steps |
| No `.beads/` dir | Beads/bv sections show "no beads tracking" |
| No git remote | Omit Open PRs + gh issues silently |
| No `docs/marketecture.md` | Daily: "no diagram yet; run `--prep <repo>`". Roll-up: `missing` |
| Repo name not found | Print candidate dirs under `~`, stop |
| `gather.ps1` partial failure | Report that section unavailable; never abort the whole run |

## Testing

- Smoke-run `--prep cofferdam` (has `.beads/` + CLAUDE.md): verify it proposes a
  `docs/marketecture.md` and a `@docs/marketecture.md` reference, writing only on
  confirm, and that the CLAUDE.md prose is otherwise untouched.
- Smoke-run single-repo daily against `cofferdam` and a repo without a remote;
  verify graceful degradation and that no inference/writes occur.
- Verify `gather.ps1` emits valid JSON with `available` flags for present/absent
  tools (test with `bv`/`gh` reachable and a `.beads`-less dir).
- Verify roll-up reads only the diagram file's presence + `updated` date and
  computes `✓/stale/missing` correctly.

## Out of scope (YAGNI)

- The repo-sweep / cofferdam-CI skill (separate spec, separate cycle).
- Auto-committing diagram/CLAUDE.md changes (left uncommitted for user review).
- Any inference outside `--prep`.
- Non-Windows paths (this is a personal skill on a Windows machine).
