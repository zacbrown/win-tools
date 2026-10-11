# Presentation belongs in the wrapper, never in the adapter's resource streams.
function Get-WinToolsStateResource {
    param($State)
    if ($State -is [System.Collections.IDictionary]) {
        if ($State.Contains('name') -and $State.Contains('type') -and $State.Contains('properties')) {
            $State
        } else {
            # The PowerShell adapter uses resources before a set and result after
            # it. Only descend into current/final state, never beforeState.
            foreach ($key in 'results', 'result', 'resources', 'afterState', 'actualState') {
                if ($State.Contains($key)) { Get-WinToolsStateResource $State[$key] }
            }
        }
    } elseif ($State -is [System.Collections.IEnumerable] -and $State -isnot [string]) {
        foreach ($item in $State) { Get-WinToolsStateResource $item }
    }
}

function Get-WinToolsStateRow {
    param([Parameter(Mandatory)] $Resource)
    $properties = $Resource.properties
    $status = 'OK'
    $details = [System.Collections.Generic.List[string]]::new()
    $installed = '-'
    $desired = '-'
    # Test() returns a boolean rather than the Get() property bag.
    if ($properties.Contains('InDesiredState')) {
        if ($properties.InDesiredState) { $details.Add('matches desired state') }
        else { $status = 'MISMATCH'; $details.Add('does not match desired state') }
    }
    if ($properties.Contains('Exists')) {
        if ($properties.Exists) { $details.Add('present') } else { $status = 'MISSING'; $details.Add('missing') }
    }
    if ($properties.Contains('Installed')) {
        if ($properties.Installed) { $details.Add("$($properties.Plugin) plugin installed") } else { $status = 'MISSING'; $details.Add("$($properties.Plugin) plugin missing") }
    }
    if ($properties.Contains('InPath')) {
        if ($properties.InPath) { $details.Add('on user PATH') } else { $status = 'NEEDS PATH'; $details.Add('missing from user PATH') }
    }
    if ($properties.InstalledVersion) { $installed = $properties.InstalledVersion }
    # GithubReleaseTool exposes InstalledVersion without an Exists property.
    if ($properties.Contains('InstalledVersion') -and -not $properties.Contains('Exists')) {
        if ($installed -ne '-') { $details.Add('installed') }
        else { $status = 'UNKNOWN'; $details.Add('installed version unavailable') }
    }
    if ($properties.TargetVersion) { $desired = $properties.TargetVersion } elseif ($properties.Version) { $desired = $properties.Version }
    if ($desired -ne '-' -and $desired -ne 'latest' -and $status -eq 'OK') {
        if ($installed -eq '-') { $status = 'UNKNOWN'; $details.Add('version could not be read') }
        elseif ($installed.TrimStart('v') -ne $desired.TrimStart('v')) { $status = 'MISMATCH'; $details.Add('version differs from desired') }
    }
    foreach ($key in 'Path', 'ConfigPath', 'TestPath') {
        if ($properties[$key]) { $details.Add([Environment]::ExpandEnvironmentVariables($properties[$key])) }
    }
    if ($properties.Binaries) { $details.Add(($properties.Binaries -join ', ')) }
    if ($details.Count -eq 0) { $status = 'UNKNOWN'; $details.Add('state unavailable') }
    [pscustomobject]@{
        Resource = $Resource.name
        Status = $status
        Installed = $installed
        Desired = $desired
        State = $details -join '; '
    }
}

function Write-WinToolsSummary {
    param(
        [Parameter(Mandatory)][string] $Action,
        [Parameter(Mandatory)][int] $ExitCode,
        $Result,
        [Parameter(Mandatory)][string] $LogPath
    )
    Write-Host ''
    if ($ExitCode -eq 0) {
        Write-Host "SUCCESS: DSC $Action completed (exit 0)." -ForegroundColor Green
    } else {
        Write-Host "FAIL: DSC $Action failed (exit $ExitCode)." -ForegroundColor Red
    }
    $rows = @(Get-WinToolsStateResource $Result | ForEach-Object { Get-WinToolsStateRow $_ })
    if ($rows.Count -gt 0) {
        $needsAttention = @($rows | Where-Object Status -ne 'OK').Count
        $label = if ($ExitCode -eq 0) { 'Final state' } else { 'Reported final state (partial)' }
        $color = if ($needsAttention -eq 0) { 'Green' } else { 'Yellow' }
        Write-Host ("{0}: {1} OK, {2} need attention." -f $label, ($rows.Count - $needsAttention), $needsAttention) -ForegroundColor $color
        # Format-Table keeps names/versions aligned while allowing long paths to wrap.
        $columns = if ($Action -eq 'test') { 'Resource', 'Status', 'State' } else { 'Resource', 'Status', 'Installed', 'Desired', 'State' }
        $rows | Format-Table -Property $columns -AutoSize -Wrap | Out-String -Width 160 | ForEach-Object { Write-Host $_.TrimEnd() }
    } else {
        Write-Host 'Final state unavailable. See the log for details.' -ForegroundColor Yellow
    }
    if ($ExitCode -ne 0 -and $rows.Count -gt 0) {
        Write-Host 'State for failed or unreported resources is unavailable.' -ForegroundColor Yellow
    }
    Write-Host "Details: $LogPath"
}
