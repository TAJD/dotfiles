# dotfiles

Personal development-environment configuration, managed with [chezmoi](https://www.chezmoi.io).

Tracks:

- **Zellij** — `AppData/Roaming/zellij/config/` (`config.kdl`, layouts, plugins)
- **Claude Code harness** — `~/.claude/`: `CLAUDE.md`, `RTK.md`, `settings.json`,
  `statusline.sh`, `.mcp.json`, and the `skills/`, `agents/`, `scripts/`, `docs/` trees
- **Shell helpers** — `~/.local/bin/` text scripts (`spawn-claude`, `agent-mail`)

## Setup on a new machine

```sh
# install chezmoi (Windows)
winget install twpayne.chezmoi

# clone + apply
chezmoi init --apply https://github.com/<user>/dotfiles.git
```

`chezmoi init` regenerates `~/.config/chezmoi/chezmoi.toml` from
[`.chezmoi.toml.tmpl`](./.chezmoi.toml.tmpl), which enables the **secret gate**:
`chezmoi add` hard-fails if a file contains a detected secret.

## Daily workflow

```sh
chezmoi add <path>     # start tracking a file (blocked if it contains secrets)
chezmoi diff           # preview what apply would change
chezmoi apply          # apply source -> live
chezmoi cd             # drop into the source repo to commit/push
```

## What is NOT tracked

Secrets and runtime state are excluded via [`.chezmoiignore`](./.chezmoiignore):
credentials, history, caches, sessions, databases, logs, backups, installed
plugins/binaries, and machine-local overrides (`settings.local.json`). Live API
keys are never committed — `settings.json` is sanitised and a gitleaks
pre-commit hook guards every commit.

## Portability

Machine-specific paths use templates, e.g.
`{{ .chezmoi.homeDir }}`, so the same source applies across machines.
