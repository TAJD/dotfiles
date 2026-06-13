[CmdletBinding()]
param(
    [switch]$Deep,
    [switch]$Strict,
    [switch]$DryRun,
    [string[]]$Only,
    [string[]]$Skip
)

$ErrorActionPreference = 'Stop'
$script:LogDir = Join-Path $env:USERPROFILE ".claude\scripts\.update-toolchain-logs\$(Get-Date -Format 'yyyy-MM-dd')"
$null = New-Item -ItemType Directory -Force -Path $script:LogDir

function New-Result {
    param($Tool, $Status, $From, $To, $Detail, $LogPath)
    [PSCustomObject]@{ Tool=$Tool; Status=$Status; From=$From; To=$To; Detail=$Detail; LogPath=$LogPath }
}

function Invoke-Tool {
    param([string]$Name, [scriptblock]$Updater)
    $log = Join-Path $script:LogDir "$Name.log"
    if ($DryRun) { return New-Result $Name 'NoChange' 'dry-run' 'dry-run' $null $log }
    # PS 5.1 wraps native-command stderr as NativeCommandError when stream-redirected.
    # Suppressing that here means real `throw`s still bubble (Strict mode works), but
    # tools that write info to stderr (uv, scoop, etc.) don't get false-positive Failed.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Updater $log
    } catch {
        if ($Strict) { throw }
        New-Result $Name 'Failed' $null $null $_.Exception.Message $log
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-WingetTool {
    param([string]$Name, [string]$WingetId, [scriptblock]$VersionCmd, [string]$LogPath, [int]$TimeoutSec = 300)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        return New-Result $Name 'Missing' $null $null $null $LogPath
    }
    $before = (& $VersionCmd) -join ' '

    # System-scope MSIs (Program Files) need admin to install. Without elevation winget
    # downloads but stalls on install with no way to surface the UAC prompt.
    if (-not (Test-IsAdmin)) {
        $recipe = "Run from an elevated PowerShell: winget upgrade --id $WingetId"
        return New-Result $Name 'Manual' $before $before $recipe $LogPath
    }

    $errFile = "$LogPath.err"
    $proc = Start-Process -FilePath 'winget' `
        -ArgumentList @('upgrade', '--id', $WingetId, '--silent',
                        '--accept-source-agreements', '--accept-package-agreements',
                        '--disable-interactivity') `
        -PassThru -NoNewWindow `
        -RedirectStandardOutput $LogPath `
        -RedirectStandardError $errFile

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch {}
        $proc.WaitForExit(5000) | Out-Null
        if (Test-Path $errFile) {
            Get-Content $errFile -ErrorAction SilentlyContinue | Add-Content $LogPath -ErrorAction SilentlyContinue
            Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        }
        return New-Result $Name 'Failed' $before $null "winget timed out after ${TimeoutSec}s" $LogPath
    }

    if (Test-Path $errFile) {
        Get-Content $errFile -ErrorAction SilentlyContinue | Add-Content $LogPath -ErrorAction SilentlyContinue
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }

    $after = (& $VersionCmd) -join ' '
    $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
    New-Result $Name $status $before $after $null $LogPath
}

# Recipes for tools with no automatic update path.
$script:CassRecipe = '& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.ps1"))) -EasyMode -Verify'
$script:RtkRecipe  = 'cargo install --git https://github.com/rtk-ai/rtk --force'

# Dispatch table - one entry per tool.
$script:Dispatch = [ordered]@{
    nvim = { param($log) Update-WingetTool -Name 'nvim' -WingetId 'Neovim.Neovim' -VersionCmd { nvim --version | Select-Object -First 1 } -LogPath $log }

    gh = { param($log) Update-WingetTool -Name 'gh' -WingetId 'GitHub.cli' -VersionCmd { gh --version | Select-Object -First 1 } -LogPath $log }

    rustup = {
        param($log)
        if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) { return New-Result 'rustup' 'Missing' $null $null $null $log }
        $before = (rustup --version 2>$null) -join ' '
        rustup self update *>&1 | Tee-Object -FilePath $log | Out-Null
        rustup update          *>&1 | Tee-Object -FilePath $log -Append | Out-Null
        $after = (rustup --version 2>$null) -join ' '
        $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
        New-Result 'rustup' $status $before $after $null $log
    }

    bd = {
        param($log)
        if (-not (Get-Command bd -ErrorAction SilentlyContinue)) { return New-Result 'bd' 'Missing' $null $null $null $log }
        if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
            return New-Result 'bd' 'Failed' $null $null 'go toolchain not on PATH (bd was go-installed)' $log
        }
        $before = (bd --version 2>&1) -join ' '
        # `bd upgrade` is a status checker, not an updater. Real update is go install from source.
        go install github.com/steveyegge/beads/cmd/bd@latest *>&1 | Tee-Object -FilePath $log | Out-Null
        $after = (bd --version 2>&1) -join ' '
        $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
        New-Result 'bd' $status $before $after $null $log
    }

    bv = {
        param($log)
        if (-not (Get-Command bv -ErrorAction SilentlyContinue)) { return New-Result 'bv' 'Missing' $null $null $null $log }
        if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
            return New-Result 'bv' 'Failed' $null $null 'scoop not on PATH' $log
        }
        $before = (bv --version 2>&1) -join ' '
        scoop update bv *>&1 | Tee-Object -FilePath $log | Out-Null
        $after = (bv --version 2>&1) -join ' '
        $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
        New-Result 'bv' $status $before $after $null $log
    }

    uv = {
        param($log)
        if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { return New-Result 'uv' 'Missing' $null $null $null $log }
        $before = (uv --version 2>&1) -join ' '
        uv self update *>&1 | Tee-Object -FilePath $log | Out-Null
        $after = (uv --version 2>&1) -join ' '
        $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
        New-Result 'uv' $status $before $after $null $log
    }

    node = {
        param($log)
        if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return New-Result 'node' 'Missing' $null $null $null $log }
        if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
            return New-Result 'node' 'Manual' $null $null 'pnpm not on PATH; install pnpm or update node manually' $log
        }
        $before = (node --version 2>&1) -join ' '
        pnpm env use --global lts *>&1 | Tee-Object -FilePath $log | Out-Null
        $after = (node --version 2>&1) -join ' '
        $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
        New-Result 'node' $status $before $after $null $log
    }

    zellij = {
        param($log)
        $installDir = "$env:LOCALAPPDATA\Programs\zellij"
        $exe = Join-Path $installDir 'zellij.exe'
        if (-not (Test-Path $exe)) { return New-Result 'zellij' 'Missing' $null $null $null $log }
        $before = (& $exe --version 2>&1) -join ' '
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/zellij-org/zellij/releases/latest' -UseBasicParsing
        "Latest release: $($release.tag_name)" | Tee-Object -FilePath $log | Out-Null

        # Skip download/extract if already at the latest tag.
        $currentVer = ($before -replace '^zellij\s+', '').Trim()
        $latestVer = $release.tag_name -replace '^v', ''
        if ($currentVer -eq $latestVer) {
            "Already at latest" | Tee-Object -FilePath $log -Append | Out-Null
            return New-Result 'zellij' 'NoChange' $before $before $null $log
        }

        $asset = $release.assets | Where-Object { $_.name -like '*x86_64-pc-windows-msvc*.zip' } | Select-Object -First 1
        if (-not $asset) {
            return New-Result 'zellij' 'Failed' $before $null 'no x86_64-pc-windows-msvc asset in latest release' $log
        }
        "Downloading: $($asset.browser_download_url)" | Tee-Object -FilePath $log -Append | Out-Null
        $tmp = New-TemporaryFile
        $zip = "$($tmp.FullName).zip"
        Move-Item $tmp.FullName $zip -Force
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
        try {
            Expand-Archive -Path $zip -DestinationPath $installDir -Force -ErrorAction Stop
        } catch {
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            return New-Result 'zellij' 'Failed' $before $null "extract failed (zellij.exe may be in use): $($_.Exception.Message)" $log
        }
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        $after = (& $exe --version 2>&1) -join ' '
        $status = if ($before -eq $after) { 'NoChange' } else { 'Updated' }
        New-Result 'zellij' $status $before $after $null $log
    }

    cass = {
        param($log)
        if (-not (Get-Command cass -ErrorAction SilentlyContinue)) { return New-Result 'cass' 'Missing' $null $null $null $log }
        $version = (cass --version 2>&1) -join ' '
        New-Result 'cass' 'Manual' $version $version $script:CassRecipe $log
    }

    rtk = {
        param($log)
        if (-not (Get-Command rtk -ErrorAction SilentlyContinue)) { return New-Result 'rtk' 'Missing' $null $null $null $log }
        $version = (rtk --version 2>&1) -join ' '
        New-Result 'rtk' 'Manual' $version $version $script:RtkRecipe $log
    }
}

# Filter via -Only / -Skip. Normalize comma-strings (powershell -File arg binding doesn't split).
function Split-CommaList($list) {
    if (-not $list) { return $list }
    @($list | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
}
$Only = Split-CommaList $Only
$Skip = Split-CommaList $Skip

if ($Only -and $Skip) { throw "-Only and -Skip are mutually exclusive" }
$tools = $script:Dispatch.Keys | Where-Object {
    (-not $Only -or $_ -in $Only) -and (-not $Skip -or $_ -notin $Skip)
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$results = @(foreach ($t in $tools) { Invoke-Tool -Name $t -Updater $script:Dispatch[$t] })

if ($Deep -and -not $DryRun) {
    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
        $log = Join-Path $script:LogDir 'deep-pnpm.log'
        try {
            pnpm update -g *>&1 | Tee-Object -FilePath $log | Out-Null
            $results += New-Result 'pnpm-globals' 'Updated' $null $null 'pnpm update -g' $log
        } catch {
            if ($Strict) { throw }
            $results += New-Result 'pnpm-globals' 'Failed' $null $null $_.Exception.Message $log
        }
    }
    if (Get-Command cargo -ErrorAction SilentlyContinue) {
        $log = Join-Path $script:LogDir 'deep-cargo.log'
        try {
            if (-not (cargo install --list | Select-String -Pattern '^cargo-update v')) {
                cargo install cargo-update *>&1 | Tee-Object -FilePath $log | Out-Null
            }
            cargo install-update -a *>&1 | Tee-Object -FilePath $log -Append | Out-Null
            $results += New-Result 'cargo-binaries' 'Updated' $null $null 'cargo install-update -a' $log
        } catch {
            if ($Strict) { throw }
            $results += New-Result 'cargo-binaries' 'Failed' $null $null $_.Exception.Message $log
        }
    }
}

$sw.Stop()

# Summary table
""
"Tool       Status     From -> To"
"-" * 45
foreach ($r in $results) {
    $arrow = if ($r.From -ne $r.To -and $r.To) { "$($r.From) -> $($r.To)" } elseif ($r.From) { $r.From } else { '' }
    "{0,-10} {1,-10} {2}" -f $r.Tool, $r.Status, $arrow
}
"-" * 45
$counts = $results | Group-Object Status | ForEach-Object { "$($_.Name) $($_.Count)" }
"{0}  ({1:N1}s)" -f ($counts -join ', '), $sw.Elapsed.TotalSeconds

# Exit code: 1 if any Failed
if ($results.Status -contains 'Failed') { exit 1 } else { exit 0 }
