[CmdletBinding(DefaultParameterSetName='Gather')]
param(
    [Parameter(ParameterSetName='Resolve',   Mandatory)][string]$Resolve,
    [Parameter(ParameterSetName='ListBeads', Mandatory)][switch]$ListBeadsRepos,
    [Parameter(ParameterSetName='Gather',     Mandatory)][string]$RepoPath,
    [Parameter(ParameterSetName='Gather')][switch]$Lite,
    [string]$Root = $env:USERPROFILE,
    [int]$StaleDays = 30
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

# Repos to exclude from discovery/rollup by name (in addition to worktree dirs).
$script:ExcludeRepos = @('rovikore-demo')

function Get-RepoDirs([string]$root) {
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName '.git') } |
        Where-Object { $_.Name -notlike '*worktree*' -and $_.Name -notlike '*.wt' } |
        Where-Object { $script:ExcludeRepos -notcontains $_.Name }
}

function Invoke-Tool([scriptblock]$Block) {
    # Returns @{ available=<bool>; output=<string|null> }. Never throws.
    try {
        $out = & $Block 2>$null
        if ($LASTEXITCODE -ne 0) { return @{ available = $false; output = $null } }
        return @{ available = $true; output = (@($out) -join "`n") }
    } catch {
        return @{ available = $false; output = $null }
    }
}

function Git-Lines([string[]]$GitArgs) {
    # Run git, return stdout lines as an array. Never throws, even when git writes to
    # stderr (e.g. no upstream, no commits) — PS 5.1 turns native stderr into terminating
    # errors under $ErrorActionPreference='Stop', so swallow it here.
    try {
        $out = & git @GitArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        return @($out)
    } catch {
        return @()
    }
}

# --- Operation: Resolve ---
if ($PSCmdlet.ParameterSetName -eq 'Resolve') {
    $names = @(Get-RepoDirs $Root | ForEach-Object { $_.Name })
    $r = Resolve-RepoName -Name $Resolve -Candidates $names
    $path = $null
    if ($r.Resolved) { $path = (Join-Path $Root $r.Match) }
    [pscustomobject]@{
        resolved   = $r.Resolved
        match      = $r.Match
        path       = $path
        candidates = $r.Candidates
    } | ConvertTo-Json -Depth 8
    return
}

# --- Operation: ListBeadsRepos ---
if ($PSCmdlet.ParameterSetName -eq 'ListBeads') {
    $repos = @(Get-RepoDirs $Root |
        Where-Object { Test-Path (Join-Path $_.FullName '.beads') } |
        ForEach-Object { [pscustomobject]@{ name = $_.Name; path = $_.FullName } })
    # PS 5.1 ConvertTo-Json mangles a top-level collection into {value,Count}; serialize
    # each element and join so the output is always a plain JSON array (incl. 0/1 items).
    $items = @($repos | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress })
    '[' + ($items -join ',') + ']'
    return
}

# --- Operation: Gather ---
if (-not (Test-Path -LiteralPath $RepoPath)) {
    [pscustomobject]@{ error = "repo path not found: $RepoPath" } | ConvertTo-Json
    exit 1
}
$repoName    = Split-Path $RepoPath -Leaf
$hasBeads    = Test-Path (Join-Path $RepoPath '.beads')
$bvAvail     = [bool](Get-Command bv -ErrorAction SilentlyContinue) -and $hasBeads
$mkPath      = Join-Path $RepoPath 'docs\marketecture.md'
$mkExists    = Test-Path -LiteralPath $mkPath
$mkContent   = if ($mkExists) { Get-Content -LiteralPath $mkPath -Raw } else { '' }
$mkUpdated   = Get-MarketectureUpdated $mkContent
$mkStatus    = Get-DiagramStatus -Exists $mkExists -Updated $mkUpdated -ThresholdDays $StaleDays

Push-Location $RepoPath
try {
    $branch    = (Git-Lines @('rev-parse','--abbrev-ref','HEAD') | Select-Object -First 1)
    $remotes   = Git-Lines @('remote')
    $hasRemote = [bool]($remotes.Count)
    $dirty     = Git-Lines @('status','--porcelain')
    $stashes   = Git-Lines @('stash','list')
    $commits   = Git-Lines @('log','-5','--pretty=format:%h %s')

    $ahead = 0; $behind = 0
    $counts = (Git-Lines @('rev-list','--left-right','--count','@{u}...HEAD') | Select-Object -First 1)
    if ($counts) {
        $parts = $counts -split '\s+'
        if ($parts.Count -ge 2) { $behind = [int]$parts[0]; $ahead = [int]$parts[1] }
    }

    # beads
    $bdStatus = if ($hasBeads) { Invoke-Tool { bd status --json } } else { @{ available=$false; output=$null } }
    $bdInProg = if ($hasBeads) { Invoke-Tool { bd list --status=in_progress --json } } else { @{ available=$false; output=$null } }
    $bdReady  = if ($hasBeads) { Invoke-Tool { bd ready --json } } else { @{ available=$false; output=$null } }
    $bdBlock  = if ($hasBeads) { Invoke-Tool { bd blocked --json } } else { @{ available=$false; output=$null } }

    # bv
    $bvNext   = if ($bvAvail) { Invoke-Tool { bv --robot-next } } else { @{ available=$false; output=$null } }
    $bvTriage = if ($bvAvail -and -not $Lite) { Invoke-Tool { bv --robot-triage } } else { @{ available=$false; output=$null } }

    # gh
    $ghPrs    = if ($hasRemote) { Invoke-Tool { gh pr list --json number,title,state,updatedAt --limit 30 } } else { @{ available=$false; output=$null } }
    $ghIssues = if ($hasRemote -and -not $Lite) { Invoke-Tool { gh issue list --json number,title,state,updatedAt --limit 30 } } else { @{ available=$false; output=$null } }

    $env = [ordered]@{
        schema = 1
        lite   = [bool]$Lite
        repo   = [ordered]@{ name = $repoName; path = $RepoPath; has_beads = $hasBeads; has_remote = $hasRemote }
        git    = [ordered]@{
            branch         = $branch
            ahead          = $ahead
            behind         = $behind
            dirty_count    = $dirty.Count
            dirty_files    = if ($Lite) { @() } else { @($dirty) }
            stash_count    = $stashes.Count
            recent_commits = if ($Lite) { @() } else { @($commits) }
        }
        beads  = [ordered]@{
            available        = $hasBeads
            in_progress_count = Measure-BdJson $bdInProg.output
            ready_count       = Measure-BdJson $bdReady.output
            blocked_count     = Measure-BdJson $bdBlock.output
            status_raw        = if ($Lite) { $null } else { $bdStatus.output }
            in_progress_raw   = if ($Lite) { $null } else { $bdInProg.output }
            ready_raw         = if ($Lite) { $null } else { $bdReady.output }
            blocked_raw       = if ($Lite) { $null } else { $bdBlock.output }
        }
        bv     = [ordered]@{ available = $bvAvail; next_raw = $bvNext.output; triage_raw = $bvTriage.output }
        gh     = [ordered]@{
            available     = $hasRemote
            pr_count      = Measure-BdJson $ghPrs.output
            prs_raw       = if ($Lite) { $null } else { $ghPrs.output }
            issues_raw    = $ghIssues.output
        }
        marketecture = [ordered]@{
            exists  = $mkExists
            path    = 'docs/marketecture.md'
            updated = $mkUpdated
            status  = $mkStatus
            content = if ($Lite) { $null } else { $mkContent }
        }
    }
    $env | ConvertTo-Json -Depth 8
}
finally { Pop-Location }
