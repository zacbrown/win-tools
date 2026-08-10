#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Bumps GitHub-pinned tools in tools.dsc.yaml to their latest upstream release.

.DESCRIPTION
    install.ps1 -Action test only checks whether an installed binary matches the
    Version pinned in tools.dsc.yaml -- it never asks upstream "is there something
    newer?" (that is by design: DirectArchive/DirectBinary make no GitHub API calls
    at apply time). This script answers that separate question AND applies the fix.

    For every github.com release-download URL in tools.dsc.yaml it extracts the tag
    currently pinned, compares it against the repo's latest published release
    (GET /repos/<owner>/<repo>/releases/latest), and -- when a newer release exists --
    rewrites the file in place: it swaps the tag inside the Url (and any version
    embedded in the asset filename) and bumps the matching Version: field. That is
    exactly the two coordinated edits (Url + Version) that make the next ./install.ps1
    re-install the tool, since Test() then sees the pinned Version no longer matches
    the installed binary.

    Non-GitHub sources (e.g. rustup-init from static.rust-lang.org) and the
    claude-code ScriptInstaller have no such URL and are left untouched. Resources
    with no Version: field (e.g. the fff DirectBinary assets) still get their Url tag
    bumped.

    To raise the API rate limit (60/hr unauth -> 5000/hr auth) the script uses, in
    order: $env:GITHUB_TOKEN, then the token from an authenticated `gh` CLI
    (`gh auth token`), then falls back to unauthenticated requests.

.PARAMETER ConfigPath
    Path to the DSC config. Defaults to tools.dsc.yaml next to this script.

.PARAMETER DryRun
    Report available updates but do NOT modify the file.

.EXAMPLE
    ./check-updates.ps1            # find updates and edit tools.dsc.yaml

.EXAMPLE
    ./check-updates.ps1 -DryRun    # just report; change nothing
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'tools.dsc.yaml'),
    [switch]$DryRun
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

# Strip a release tag down to the value that appears in a Version: field / asset
# filename: drop a leading 'v' (v1.2.3 -> 1.2.3) or 'jq-' (jq-1.8.2 -> 1.8.2).
function Get-BareVersion([string]$tag) {
    ($tag -replace '^v', '') -replace '^jq-', ''
}

$raw     = [System.IO.File]::ReadAllText((Resolve-Path $ConfigPath))
$newline = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
$lines   = $raw -split "`r`n|`n"

# One entry per Url line that points at a GitHub release download.
$urlPattern = 'https://github\.com/(?<owner>[^/\s]+)/(?<repo>[^/\s]+)/releases/download/(?<tag>[^/\s]+)/(?<asset>[^\s''"]+)'
$urlLines = for ($i = 0; $i -lt $lines.Count; $i++) {
    $m = [regex]::Match($lines[$i], $urlPattern)
    if ($m.Success) {
        [pscustomobject]@{
            Index  = $i
            Owner  = $m.Groups['owner'].Value
            Repo   = $m.Groups['repo'].Value
            Tag    = $m.Groups['tag'].Value
            Url    = $m.Value
            RepoId = "$($m.Groups['owner'].Value)/$($m.Groups['repo'].Value)"
        }
    }
}

if (-not $urlLines) {
    Write-Warning "No github.com release-download URLs found in $ConfigPath"
    return
}

# Resolve an API token: prefer $env:GITHUB_TOKEN, then an authenticated gh CLI.
function Resolve-GitHubToken {
    if ($env:GITHUB_TOKEN) {
        return [pscustomobject]@{ Token = $env:GITHUB_TOKEN; Source = 'GITHUB_TOKEN env var' }
    }
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        # gh prints the token to stdout and any "not logged in" message to stderr.
        # Capture stdout fully (don't pipe Select-Object onto the native call, or the
        # pipeline can short-circuit before $LASTEXITCODE is set), then check the code.
        $out  = & gh auth token 2>$null
        $code = $LASTEXITCODE
        $token = ($out | Select-Object -First 1)
        if ($code -eq 0 -and $token) {
            return [pscustomobject]@{ Token = "$token".Trim(); Source = 'gh auth token' }
        }
    }
    return [pscustomobject]@{ Token = $null; Source = $null }
}

$auth = Resolve-GitHubToken
$headers = @{
    'Accept'               = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'win-tools-check-updates'
}
if ($auth.Token) {
    $headers['Authorization'] = "Bearer $($auth.Token)"
    Write-Host "Authenticated via $($auth.Source)." -ForegroundColor DarkGray
} else {
    Write-Warning 'No token from GITHUB_TOKEN or gh CLI -- using unauthenticated API (60 requests/hr).'
}

# Query each distinct repo's latest release exactly once.
$latestCache = @{}
function Get-LatestTag([string]$repoId) {
    if ($latestCache.ContainsKey($repoId)) { return $latestCache[$repoId] }
    try {
        $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoId/releases/latest" -Headers $script:headers
        $latestCache[$repoId] = [pscustomobject]@{ Tag = $resp.tag_name; Error = $null }
    } catch {
        $latestCache[$repoId] = [pscustomobject]@{ Tag = $null; Error = $_.Exception.Message }
    }
    $latestCache[$repoId]
}

# Rewrite lines[$urlIdx]'s Url tag/version, then bump the Version: field in the same
# resource block. Mutates the script-scope $lines array. Returns $true if it changed
# anything.
function Update-Entry($entry, [string]$newTag) {
    $oldTag = $entry.Tag
    $oldVer = Get-BareVersion $oldTag
    $newVer = Get-BareVersion $newTag

    # Swap the tag first (it may contain the bare version as a substring), then swap
    # any bare version embedded in the asset filename. Scoped to this one URL string.
    $newUrl = $entry.Url.Replace($oldTag, $newTag)
    if ($oldVer -and $oldVer -ne $oldTag) {
        $newUrl = $newUrl.Replace($oldVer, $newVer)
    }
    $script:lines[$entry.Index] = $script:lines[$entry.Index].Replace($entry.Url, $newUrl)

    # Bump the Version: field within the same resource entry (search forward until the
    # next "- name:" list item). Only touch it if it matches the version we replaced,
    # so an unrelated tool sharing a number is never disturbed.
    for ($j = $entry.Index + 1; $j -lt $script:lines.Count; $j++) {
        if ($script:lines[$j] -match '^\s*-\s+name:') { break }
        if ($script:lines[$j] -match "^(?<indent>\s*)Version:\s*[''""]?$([regex]::Escape($oldVer))[''""]?\s*$") {
            $script:lines[$j] = "$($Matches['indent'])Version: $newVer"
            break
        }
    }
    return $true
}

# Evaluate every repo, collect one report row per distinct repo, and apply edits.
$seenRepo = @{}
$results  = @()
$changed  = $false

foreach ($entry in $urlLines) {
    $latest = Get-LatestTag $entry.RepoId
    $status = $null

    if ($latest.Error) {
        $status = 'error'
        $latestDisplay = "($($latest.Error))"
    } elseif ($latest.Tag -eq $entry.Tag) {
        $status = 'up to date'
        $latestDisplay = $latest.Tag
    } else {
        $status = if ($DryRun) { 'UPDATE (dry-run)' } else { 'UPDATED' }
        $latestDisplay = $latest.Tag
        if (-not $DryRun) {
            if (Update-Entry $entry $latest.Tag) { $changed = $true }
        }
    }

    # One row per repo (fff backs several Url lines; report it once).
    if (-not $seenRepo.ContainsKey($entry.RepoId)) {
        $seenRepo[$entry.RepoId] = $true
        $results += [pscustomobject]@{
            Repo   = $entry.RepoId
            Pinned = $entry.Tag
            Latest = $latestDisplay
            Status = $status
        }
    }
}

if ($changed) {
    [System.IO.File]::WriteAllText((Resolve-Path $ConfigPath), ($lines -join $newline))
}

# Colorized table
$w0 = ($results.Repo   | Measure-Object -Property Length -Maximum).Maximum
$w1 = (($results.Pinned | ForEach-Object Length) + 6 | Measure-Object -Maximum).Maximum
$w2 = (($results.Latest | ForEach-Object Length) + 6 | Measure-Object -Maximum).Maximum

Write-Host ''
Write-Host ("{0,-$w0}  {1,-$w1}  {2,-$w2}  {3}" -f 'REPO', 'PINNED', 'LATEST', 'STATUS')
Write-Host ("{0,-$w0}  {1,-$w1}  {2,-$w2}  {3}" -f ('-' * 4), ('-' * 6), ('-' * 6), ('-' * 6))

foreach ($r in $results) {
    $color = switch -Wildcard ($r.Status) {
        'UPDATE*'    { 'Yellow' }
        'up to date' { 'Green' }
        default      { 'Red' }
    }
    Write-Host ("{0,-$w0}  {1,-$w1}  {2,-$w2}  " -f $r.Repo, $r.Pinned, $r.Latest) -NoNewline
    Write-Host $r.Status -ForegroundColor $color
}

$updates = @($results | Where-Object { $_.Status -like 'UPDATE*' -or $_.Status -eq 'UPDATED' })
Write-Host ''
if ($DryRun) {
    Write-Host ("{0} repo(s) checked, {1} update(s) available (dry-run -- no changes written)." -f $results.Count, $updates.Count)
} elseif ($changed) {
    Write-Host ("{0} repo(s) checked, {1} update(s) written to {2}." -f $results.Count, $updates.Count, (Split-Path -Leaf $ConfigPath))
    Write-Host "Run ./install.ps1 to install the bumped versions." -ForegroundColor Cyan
} else {
    Write-Host ("{0} repo(s) checked, everything up to date." -f $results.Count)
}

if ($updates.Count -gt 0) { exit 1 }
