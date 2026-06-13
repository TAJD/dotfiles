---
name: toolchain-changelog
description: Compile a consolidated "what changed per version" report across the agentic toolchain (neovim, zellij, bd, bv, cass, rtk, uv, gh, rustup, node). Use when the user says "what changed in my tools", "compile a list of updates", "changelog for my toolchain", or after /update-toolchain to see the deltas being applied. Read-only research — it does NOT update anything.
---

# toolchain-changelog

Companion to `update-toolchain`. That skill *applies* updates; this one *explains* them —
it gathers the release notes between each tool's installed version and the latest, and
compiles one consolidated report. Read-only: never installs or upgrades anything here.

The same tool set as `update-toolchain` (`~/.claude/scripts/update-toolchain.ps1` is the
source of truth for which tools exist and how their installed versions are read).

## Steps

1. **Scope.** Default to all tools. Honor "only X" / "just X" → restrict; "skip X" → exclude.
   If the user just ran `/update-toolchain`, you may already know which tools have a delta —
   only research those.

2. **Read installed versions.** Run the version commands below (cheap, do them in one
   PowerShell call). Tools at their latest need no research — skip them in step 3.

3. **Dispatch parallel research agents — one per tool that has (or might have) a delta.**
   This protects main context from raw changelog dumps. Use `general-purpose` agents
   (model `sonnet`), all in a single message. Give each agent: the tool name, its installed
   version, and its source repo from the table below. Instruct each to return ONLY:
   - the latest stable version, then
   - concise bullets of notable changes between installed (exclusive) and latest (inclusive),
     **grouped by version**, covering: new features, important bug fixes, breaking changes,
     security fixes. If installed == latest, return "already at latest".

   Agent prompt skeleton:
   > Research release notes for `<tool>`. Installed: `<version>`. Source: `<repo url>`.
   > Determine the latest stable version. List notable changes between installed (exclusive)
   > and latest (inclusive), grouped by version: features, important fixes, breaking changes,
   > security. Use WebFetch on the releases page / CHANGELOG. Return ONLY the latest-version
   > line then the grouped bullets (or "already at latest"). No preamble.

4. **Compile the report.** A status table (installed → latest, current/behind), then
   per-tool grouped notes for tools that are behind. **Explicitly surface**:
   - **Windows-relevant** fixes (this is a Windows machine) — call them out.
   - **Breaking changes** and **security fixes** — flag, don't bury.
   - Platform-specific notes that *don't* apply here (e.g. macOS-only fixes) — say so briefly
     so the user knows you checked.

5. **Offer the handoff.** If anything is behind, point at `/update-toolchain` (or the specific
   `-Only <tool>` invocation) to actually apply it. Don't apply updates from this skill.

## Tool → source map

| Tool | Installed-version command | Changelog source |
|------|---------------------------|------------------|
| nvim | `nvim --version` (first line) | https://github.com/neovim/neovim/releases (stable only) |
| gh | `gh --version` (first line) | https://github.com/cli/cli/releases |
| rustup | `rustup --version` / `rustc --version` | https://github.com/rust-lang/rustup (self) + https://github.com/rust-lang/rust/blob/master/RELEASES.md (toolchain) |
| bd | `bd --version` | https://github.com/steveyegge/beads/releases |
| bv | `bv --version` | run `scoop info bv` to find the homepage/manifest, then its releases |
| uv | `uv --version` | https://github.com/astral-sh/uv/blob/main/CHANGELOG.md |
| node | `node --version` | https://github.com/nodejs/node/releases (track the active LTS line) |
| zellij | `& "$env:LOCALAPPDATA\Programs\zellij\zellij.exe" --version` | https://github.com/zellij-org/zellij/blob/main/CHANGELOG.md |
| cass | `cass --version` | https://github.com/Dicklesworthstone/coding_agent_session_search (releases + tags + CHANGELOG) |
| rtk | `rtk --version` | https://github.com/rtk-ai/rtk (releases + tags; fall back to Cargo.toml on main) |

## Constraints

- Read-only. This skill never runs an installer, `cargo install`, `winget upgrade`, etc.
  Applying updates is `update-toolchain`'s job.
- Always dispatch the changelog fetches as parallel subagents — never fetch 5+ changelogs
  inline; the raw notes will flood the conversation.
- Don't pin specific version numbers into agent docs as a side effect — describe capabilities,
  not versions (standing user preference).
- Some repos (cass, rtk) may have releases without formal changelog entries; have the agent
  say so rather than inventing notes.

## Notes for the assistant

- `bv` and `node` upstreams aren't GitHub-release-driven the same way; let the agent discover
  the right source (`scoop info bv`; the Node LTS schedule) rather than forcing a repo.
- macOS/Linux-only fixes still belong in the report but tagged as not-applicable-here.
