#Requires -Version 7.2
# Offline end-to-end checks using mocked GitHub release responses.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('wintools-updates-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-Asset([string]$Name) {
    @{ name = $Name; browser_download_url = "https://github.com/example/tool/releases/download/v1.0.10/$Name" }
}

function Invoke-Check($Release, [string]$Config, [switch]$DryRun) {
    $configPath = Join-Path $scratch 'config.yaml'
    [IO.File]::WriteAllText($configPath, $Config)
    $Release | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $scratch 'release.json')
    $arguments = @('-NoProfile', '-File', (Join-Path $scratch 'runner.ps1'), '-Checker', (Join-Path $repoRoot 'check-updates.ps1'), '-Config', $configPath)
    if ($DryRun) { $arguments += '-DryRun' }
    $output = & pwsh @arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    [pscustomobject]@{ Output = $output; Code = $code; Config = [IO.File]::ReadAllText($configPath) }
}

try {
    @'
param($Checker, $Config, [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$env:GITHUB_TOKEN = 'offline-fixture-token'
$global:releaseFixture = Get-Content (Join-Path $PSScriptRoot 'release.json') -Raw | ConvertFrom-Json
function Invoke-RestMethod {
    param($Uri, $Headers)
    if ($global:releaseFixture.PSObject.Properties['fixtureError']) { throw $global:releaseFixture.fixtureError }
    $global:releaseFixture
}
& $Checker -ConfigPath $Config -DryRun:$DryRun
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath (Join-Path $scratch 'runner.ps1')

    $config = @'
resources:
  - name: tool
    properties:
      Url: https://github.com/example/tool/releases/download/v1.0.1/tool-v1.0.1-win-x64.zip
      Version: 1.0.1
'@
    # New version contains the old version as a prefix (1.0.1 -> 1.0.10).
    $release = @{ tag_name = 'v1.0.10'; assets = @((New-Asset 'tool-v1.0.10-win-x64.zip')) }
    $result = Invoke-Check $release $config
    Assert-True ($result.Code -eq 1) "Update exit code: $($result.Output)"
    Assert-True ($result.Config.Contains('/v1.0.10/tool-v1.0.10-win-x64.zip')) 'Incorrect asset URL/version replacement'
    Assert-True ($result.Config.Contains('Version: 1.0.10')) 'Version pin not updated'
    Write-Host 'PASS: verified asset URL and coordinated version bump'

    $result = Invoke-Check $release $config -DryRun
    Assert-True ($result.Code -eq 1 -and $result.Config -ceq $config) 'Dry run changed the config or lost update status'
    Write-Host 'PASS: dry run leaves config byte-for-byte unchanged'

    $missingRelease = @{ tag_name = 'v1.0.10'; assets = @((New-Asset 'tool-linux-x64.tar.gz')) }
    foreach ($dry in $false, $true) {
        $result = Invoke-Check $missingRelease $config -DryRun:$dry
        Assert-True ($result.Code -eq 2 -and $result.Config -ceq $config) 'Missing Windows asset must block updates'
        Assert-True ($result.Output -match 'BLOCKED.*tool-v1.0.10-win-x64.zip') 'Missing-asset report lacked expected filename'
        Assert-True ($result.Output -notmatch 'everything up to date') 'Blocked release incorrectly reported as up to date'
    }
    Write-Host 'PASS: missing Windows asset blocks normal and dry-run updates'

    $multiAsset = $config + "`n  - name: library`n    properties:`n      Url: https://github.com/example/tool/releases/download/v1.0.1/library.dll`n"
    $result = Invoke-Check $release $multiAsset
    Assert-True ($result.Code -eq 2 -and $result.Config -ceq $multiAsset) 'A missing sibling asset must prevent partial repository updates'
    Write-Host 'PASS: all assets for a repository validated before any edits'

    $sameTag = @{ tag_name = 'v1.0.1'; assets = @() }
    $result = Invoke-Check $sameTag $config
    Assert-True ($result.Code -eq 2 -and $result.Output -match 'BLOCKED') 'An already-invalid pin must not be reported up to date'
    Write-Host 'PASS: existing invalid pin detected even when tag matches'

    $result = Invoke-Check @{ fixtureError = 'fixture GitHub API failure' } $config
    Assert-True ($result.Code -eq 2 -and $result.Config -ceq $config) 'API failures must preserve pins and return a failure status'
    Assert-True ($result.Output -notmatch 'everything up to date') 'API failure incorrectly reported as up to date'
    Write-Host 'PASS: API failure reporting and exit status'

    $sameTag.assets = @(@{ name = 'tool-v1.0.1-win-x64.zip'; browser_download_url = 'https://github.com/example/tool/releases/download/v1.0.1/tool-v1.0.1-win-x64.zip' })
    $result = Invoke-Check $sameTag $config
    Assert-True ($result.Code -eq 0 -and $result.Config -ceq $config -and $result.Output -match 'everything up to date') 'Valid current pins should be unchanged'
    Write-Host 'PASS: valid up-to-date pins'
} finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedScratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedScratch) -notlike 'wintools-updates-test-*') {
        throw "Refusing to remove unexpected fixture path: $resolvedScratch"
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
