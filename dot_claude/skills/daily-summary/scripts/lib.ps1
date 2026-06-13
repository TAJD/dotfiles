# Pure helpers for daily-summary. No external tool calls, no console output.

function Get-MarketectureUpdated {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    if ([string]::IsNullOrEmpty($Content)) { return $null }
    $m = [regex]::Match($Content, '<!--\s*marketecture:updated:\s*(\d{4}-\d{2}-\d{2})\s*-->')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-DiagramStatus {
    [CmdletBinding()]
    param(
        [bool]$Exists,
        [string]$Updated,
        [int]$ThresholdDays = 30,
        [datetime]$Now = (Get-Date)
    )
    if (-not $Exists) { return 'missing' }
    if ([string]::IsNullOrEmpty($Updated)) { return 'stale' }
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact(
        $Updated, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
    if (-not $ok) { return 'stale' }
    if (($Now.Date - $parsed.Date).Days -gt $ThresholdDays) { return 'stale' }
    return 'ok'
}

function Resolve-RepoName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Candidates
    )
    $exact = @($Candidates | Where-Object { $_ -ceq $Name })
    if ($exact.Count -eq 1) { return [pscustomobject]@{ Resolved = $true; Match = $exact[0]; Candidates = @() } }
    $ci = @($Candidates | Where-Object { $_ -ieq $Name })
    if ($ci.Count -eq 1) { return [pscustomobject]@{ Resolved = $true; Match = $ci[0]; Candidates = @() } }
    $sub = @($Candidates | Where-Object { $_ -like "*$Name*" })
    if ($sub.Count -eq 1) { return [pscustomobject]@{ Resolved = $true; Match = $sub[0]; Candidates = @() } }
    return [pscustomobject]@{ Resolved = $false; Match = $null; Candidates = $sub }
}

function Measure-BdJson {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return 0 }
    try { $o = $Json | ConvertFrom-Json } catch { return 0 }
    if ($null -eq $o) { return 0 }
    if ($o -is [System.Array]) { return $o.Count }
    foreach ($k in 'issues','beads','items','results','data','prs','pullRequests') {
        if (($o.PSObject.Properties.Name -contains $k) -and ($o.$k -is [System.Array])) { return $o.$k.Count }
    }
    foreach ($k in 'count','total') {
        if ($o.PSObject.Properties.Name -contains $k) { return [int]$o.$k }
    }
    return 1
}
