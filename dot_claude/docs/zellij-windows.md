# Zellij on Windows

Quick reference for the manual zellij install on this machine.

## Why manual?

The official `irm https://zellij.dev/launch.ps1 | iex` is a **bootstrap launcher**, not an installer:
it drops `zellij.exe` into `%TEMP%\zellij\bootstrap\` and execs it. `%TEMP%` is volatile and
not on `PATH`, so `zellij` never becomes a permanent command.

Zellij has no winget/scoop package on Windows yet, so we install by hand.

## Install layout

| What | Path |
|------|------|
| Binary | `%LOCALAPPDATA%\Programs\zellij\zellij.exe` |
| Updater | `%LOCALAPPDATA%\Programs\zellij\update.ps1` |
| PATH | User-scoped, points at `%LOCALAPPDATA%\Programs\zellij` |

The PATH entry is set via `[Environment]::SetEnvironmentVariable('Path', ..., 'User')`,
so it persists and shows up in any new shell (PowerShell, Git Bash, cmd).

## Updating

```powershell
& "$env:LOCALAPPDATA\Programs\zellij\update.ps1"
```

The updater downloads the latest release zip directly from
`github.com/zellij-org/zellij/releases/latest` (arch auto-detected: `x86_64` or `aarch64`),
extracts it to a temp dir, and swaps the fresh `zellij.exe` into the install dir.
Prints old version → new version on success; no-ops if already current.

**Why not the running binary directly?** Windows write-locks a running `.exe`, so the new
binary can't overwrite `zellij.exe` while any session is open — but a running exe *can* be
renamed. The updater moves the current binary to `zellij.exe.old` and copies the new one in.
The open session keeps using the renamed image; the **next** `zellij` launch picks up the new
version. So after updating, fully restart zellij:

```powershell
zellij kill-all-sessions   # or: zellij delete-session <name>
zellij                     # fresh session on the new version
```

> **Don't use `launch.ps1` to update.** That bootstrap is a *launcher* — it execs zellij with
> forwarded args. The old updater tried `powershell -Command "irm …/launch.ps1 | iex" --version`
> to "just download", but `--version` binds to `iex` (not zellij) under Windows PowerShell, so
> the download never ran. The updater now pulls the release zip itself and avoids the wrapper.

## Reinstalling from scratch

If the install gets corrupted or you want to start over:

```powershell
# Remove install dir
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Programs\zellij"

# Clear PATH entry (reopen shell after)
$p = [Environment]::GetEnvironmentVariable('Path','User') -split ';' |
     Where-Object { $_ -ne "$env:LOCALAPPDATA\Programs\zellij" -and $_ -ne '' }
[Environment]::SetEnvironmentVariable('Path', ($p -join ';'), 'User')

# Re-run bootstrap, then copy binary into place
irm https://zellij.dev/launch.ps1 | iex   # populates %TEMP%\zellij\bootstrap\zellij.exe
$dest = "$env:LOCALAPPDATA\Programs\zellij"
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item "$env:TEMP\zellij\bootstrap\zellij.exe" "$dest\zellij.exe" -Force

# Re-add to PATH
$p = [Environment]::GetEnvironmentVariable('Path','User')
[Environment]::SetEnvironmentVariable('Path', "$p;$dest", 'User')
```

Open a new shell so the updated PATH takes effect.

## Caveats

- **Native Windows zellij is relatively new (0.44.x+).** Prior to that it was WSL-only.
  If something behaves oddly, the WSL build is more battle-tested.
- **PATH changes don't apply to existing shells** — always reopen the terminal after install.
- The bootstrap launcher will keep working even after a manual install; running
  `irm https://zellij.dev/launch.ps1 | iex` just executes whatever `zellij.exe` is cached
  in `%TEMP%`, independent of your installed copy.
