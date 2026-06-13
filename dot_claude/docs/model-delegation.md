# Model delegation playbook

How to choose between Opus, Sonnet, and Haiku — for the main session and for spawned subagents.
The headline rule lives in `~/.claude/CLAUDE.md`; this file is the depth.

## TL;DR

**Opus plans. Sonnet builds. Haiku looks up.** Opus costs ~5× Haiku per token, so reach for it
only when reasoning quality changes the outcome.

## Cost shape (per million tokens, in / out)

| Model      | Input    | Output   | Use it for                                              |
|------------|----------|----------|---------------------------------------------------------|
| Opus 4.7   | $5       | $25      | Planning, architecture, hard debugging, frontier reasoning |
| Sonnet 4.6 | $3       | $15      | Default workhorse — implementation, refactors, reviews  |
| Haiku 4.5  | $1       | $5       | Lookups, search, log scans, formatting, test running    |

Sources: [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing),
[Models overview](https://platform.claude.com/docs/en/docs/about-claude/models/latest).

## Choosing the main session's model

- **Plan mode (`Shift+Tab` then `/model opusplan`)** for: multi-file refactors, architecture
  decisions, hard debugging, anything where a wrong plan costs many downstream tokens.
  Opus reasons through the plan, then auto-demotes to Sonnet for execution.
- **Sonnet** is the default for implementation, feature work, routine refactors. Don't
  escalate to Opus unless Sonnet is visibly struggling with the *reasoning*, not just the
  typing.
- **Haiku** for sessions that are pure lookup or log triage.

## Choosing a subagent's model

When spawning via the Task tool, set `model:` explicitly. Defaults follow the parent.

- **Haiku** — read-only research, codebase search, grep/glob sweeps, doc lookups, log scans,
  test running. Anything where the output is "here's what I found." Claude Code's built-in
  `Explore` agent uses Haiku — follow that pattern.
- **Sonnet** — implementation subagents, code review, anything that writes code or makes
  judgment calls. Default workhorse.
- **Opus** — only for subagents doing genuine architecture/design work mid-execution. Rare.

## When to spawn a subagent at all

- **Spawn one** when the work would otherwise flood the main context with output I won't
  reuse (search results, file dumps, long logs). Context hygiene > parallelism — this is
  the *primary* reason subagents exist.
- **Spawn one** when there are ≥2 independent tasks. Dispatch them in a single message so
  they run in parallel.
- **Never parallelize** tasks with shared state or sequential dependencies.
- **Don't spawn** for: a single file read, a one-liner edit, anything needing iterative
  back-and-forth, or work where I need the raw output (not a summary).

## Mechanics

**Per-subagent model in frontmatter:**

```yaml
---
name: codebase-researcher
description: Search and analyze codebase structure
model: haiku            # or: sonnet, opus, inherit, claude-opus-4-7
tools: Read, Glob, Grep
---
```

**Per-invocation override** (Task tool): pass `model: "haiku"` in the call.

**Resolution order** (highest priority first):
1. `CLAUDE_CODE_SUBAGENT_MODEL` env var
2. Task-tool `model` parameter
3. Subagent frontmatter `model:` field
4. Main session's current model

**Slash commands:**
- `/model opus` · `/model sonnet` · `/model haiku` — switch the main session
- `/model opusplan` — Opus plans, Sonnet executes
- `/effort xhigh` — adaptive reasoning on Opus 4.7

Sources: [Subagents](https://code.claude.com/docs/en/sub-agents),
[Model config](https://code.claude.com/docs/en/model-config).

## Anti-patterns

- Running tests or grepping the codebase on Opus. Delegate to a Haiku Task instead.
- Spawning a subagent to read one file. Just use Read.
- Using Opus for implementation after planning is done — let it demote to Sonnet.
- Parallelizing tasks that share files or have sequential dependencies.
- Treating subagents as "for parallelism" — their main job is protecting the orchestrator's
  context.

## Worked examples

**"Refactor the auth flow across three files."**
→ Plan mode + Opus to design the change. Sonnet (main session) executes. No subagents needed
unless the output exploration would balloon context.

**"Find every place that calls `oldFunction` and report what they pass."**
→ Spawn one Haiku subagent with Grep + Read. Returns a summary; raw matches stay out of main
context.

**"Build this feature in parallel with running the existing test suite."**
→ Single message: Sonnet Task subagent for the implementation, Haiku Task subagent for `rtk
vitest run`. Independent, no shared state — fine to parallelize.

**"Why is this test failing?"**
→ Stay in main session (Sonnet) for the back-and-forth. Don't subagent the debugger.
