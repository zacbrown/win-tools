#Requires -Version 7.2
# Offline regression checks through the real DSC PowerShell adapter.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('wintools-dprint-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$oldFixtureBin = $env:WINTOOLS_TEST_BIN
$oldFixtureMode = $env:WINTOOLS_TEST_MODE

function Assert-Match([string]$Actual, [string]$Pattern) {
    if ($Actual -notmatch $Pattern) { throw "Expected pattern '$Pattern' in:`n$Actual" }
}

try {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'install.ps1') -Destination $scratch
    Copy-Item -LiteralPath (Join-Path $repoRoot 'modules') -Destination $scratch -Recurse
    $env:WINTOOLS_TEST_BIN = Join-Path $scratch 'bin'
    New-Item -ItemType Directory -Path $env:WINTOOLS_TEST_BIN | Out-Null
    # Use a native cmd fixture instead of the real dprint executable. Only the
    # temporary module copy changes the executable name and installation folder.
    $modulePath = Join-Path $scratch 'modules/WinTools/WinTools.psm1'
    $module = (Get-Content -LiteralPath $modulePath -Raw).Replace("'dprint.exe'", "'dprint.cmd'")
    Set-Content -LiteralPath $modulePath -Value $module
    Add-Content -LiteralPath $modulePath -Value @'

function Get-LocalBinDir { $env:WINTOOLS_TEST_BIN }
'@
    @'
@echo off
echo called>>"%WINTOOLS_TEST_BIN%\calls.txt"
if "%WINTOOLS_TEST_MODE%"=="failure" (
    echo Plugin download failed 1>&2
    exit /b 7
)
echo Compiling https://plugins.dprint.dev/markdown-0.22.0.wasm 1>&2
echo Added markdown plugin
echo { "plugins": ["npm:@dprint/markdown@0.26.0"] } > dprint.json
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $env:WINTOOLS_TEST_BIN 'dprint.cmd')

    $configPath = Join-Path $scratch 'config/dprint.json'
    @"
`$schema: https://aka.ms/dsc/schemas/v3/bundled/config/document.json
resources:
  - name: dprint-test
    type: Microsoft.DSC/PowerShell
    properties:
      resources:
        - name: markdown
          type: WinTools/DprintPlugin
          properties:
            Plugin: markdown
            ConfigPath: '$($configPath.Replace("'", "''"))'
"@ | Set-Content -LiteralPath (Join-Path $scratch 'tools.dsc.yaml')

    $env:WINTOOLS_TEST_MODE = 'success'
    $log = Join-Path $scratch 'success.log'
    $output = & pwsh -NoProfile -File (Join-Path $scratch 'install.ps1') -LogPath $log -OutputFormat json 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Successful native command was rejected by DSC: $output" }
    $null = $output | ConvertFrom-Json
    $text = Get-Content -LiteralPath $log -Raw
    Assert-Match $text 'Compiling https://plugins.dprint.dev/markdown-0.22.0.wasm'
    Assert-Match $text 'Added markdown plugin'
    Assert-Match $text 'END install Action=set ExitCode=0'
    Assert-Match $output '"Installed":\s*true'
    Write-Host 'PASS: stderr progress succeeds and diagnostics stay out of DSC JSON'

    # The npm entry installed above must prevent another invocation on reapply.
    $output = & pwsh -NoProfile -File (Join-Path $scratch 'install.ps1') -LogPath (Join-Path $scratch 'repeat.log') 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Repeated set failed: $output" }
    Assert-Match $output 'SUCCESS: DSC set completed'
    Assert-Match $output 'Final state: 1 OK, 0 need attention'
    if (@(Get-Content -LiteralPath (Join-Path $env:WINTOOLS_TEST_BIN 'calls.txt')).Count -ne 1) {
        throw 'The npm plugin was installed more than once'
    }
    Write-Host 'PASS: npm plugin is recognized on reapply'

    # A similarly named package is not the requested plugin.
    Set-Content -LiteralPath $configPath -Value '{ "plugins": ["npm:@dprint/markdown-extra@0.26.0"] }'
    $env:WINTOOLS_TEST_MODE = 'failure'
    $log = Join-Path $scratch 'failure.log'
    $output = & pwsh -NoProfile -File (Join-Path $scratch 'install.ps1') -LogPath $log 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { throw 'Native command failure was not propagated' }
    $text = Get-Content -LiteralPath $log -Raw
    Assert-Match $text 'Plugin download failed'
    Assert-Match $text "FAILED WinTools/DprintPlugin .*Stage='dprint config add markdown"
    Assert-Match $output 'failed \(exit 7\)'
    if ($text -match 'END WinTools/DprintPlugin .* Set') { throw 'Failed Set was logged as successful' }
    Write-Host 'PASS: nonzero exit fails with diagnostics and exact npm package matching'

    foreach ($plugin in 'https://plugins.dprint.dev/markdown-0.22.0.wasm', 'https://plugins.dprint.dev/markdown.wasm', 'https://plugins.dprint.dev/markdown.json') {
        @{ plugins = @($plugin) } | ConvertTo-Json | Set-Content -LiteralPath $configPath
        $output = & pwsh -NoProfile -File (Join-Path $scratch 'install.ps1') -LogPath (Join-Path $scratch 'legacy.log') -OutputFormat json 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Legacy plugin was not recognized: $plugin`n$output" }
        Assert-Match $output '"Installed":\s*true'
    }
    Write-Host 'PASS: legacy plugin URLs remain recognized'
} finally {
    $env:WINTOOLS_TEST_BIN = $oldFixtureBin
    $env:WINTOOLS_TEST_MODE = $oldFixtureMode
    $resolvedScratch = [System.IO.Path]::GetFullPath($scratch)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedScratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedScratch) -notlike 'wintools-dprint-test-*') {
        throw "Refusing to remove unexpected fixture path: $resolvedScratch"
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
