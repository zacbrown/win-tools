#Requires -Version 7.2
# Offline integration checks through the real DSC PowerShell adapter.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('wintools-logging-test-' + [Guid]::NewGuid().ToString('N'))
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
    # Override network/extraction only in the temporary module copy loaded by DSC.
    Add-Content -LiteralPath (Join-Path $scratch 'modules/WinTools/WinTools.psm1') -Value @'

function Get-LocalBinDir { $env:WINTOOLS_TEST_BIN }
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    if ($env:WINTOOLS_TEST_MODE -eq 'download') {
        throw 'Response status code does not indicate success: 404 (Not Found).'
    }
    Set-Content -LiteralPath $OutFile -Value 'fixture archive'
}
function Expand-ReleaseArchive {
    param($ArchivePath, $DestinationDir)
    if ($env:WINTOOLS_TEST_MODE -eq 'extract') { throw 'Invalid archive fixture' }
    if ($env:WINTOOLS_TEST_MODE -ne 'copy') {
        Set-Content -LiteralPath (Join-Path $DestinationDir 'fixture.txt') -Value 'fixture payload'
    }
}
'@
    @'
$schema: https://aka.ms/dsc/schemas/v3/bundled/config/document.json
resources:
  - name: logging-test
    type: Microsoft.DSC/PowerShell
    properties:
      resources:
        - name: fixture
          type: WinTools/DirectArchive
          properties:
            Name: logging-fixture
            Url: https://example.invalid/fixture.zip
            Binaries: [fixture.txt]
'@ | Set-Content -LiteralPath (Join-Path $scratch 'tools.dsc.yaml')

    foreach ($mode in 'download', 'extract', 'copy', 'success') {
        $env:WINTOOLS_TEST_MODE = $mode
        $log = Join-Path $scratch "$mode.log"
        $output = & pwsh -NoProfile -File (Join-Path $scratch 'install.ps1') -LogPath $log -TraceLevel debug 2>&1 | Out-String
        $code = $LASTEXITCODE
        $text = Get-Content -LiteralPath $log -Raw
        Assert-Match $text "START WinTools/DirectArchive Name='logging-fixture'"
        Assert-Match $text 'DSC stderr:'
        if ($mode -eq 'success') {
            if ($code -ne 0) { throw "Expected success, got ${code}: $output" }
            Assert-Match $text "END WinTools/DirectArchive .* Set"
            Assert-Match $text 'END install Action=set ExitCode=0'
            if (-not (Test-Path (Join-Path $env:WINTOOLS_TEST_BIN 'fixture.txt'))) { throw 'Fixture was not installed' }
        } else {
            if ($code -eq 0) { throw "Failure was not propagated for $mode" }
            $stage = if ($mode -eq 'copy') { 'locate/copy' } else { $mode }
            Assert-Match $text "FAILED WinTools/DirectArchive .*Stage='$stage"
            Assert-Match $output "logging-fixture.*Stage='$stage"
            Assert-Match $text 'https://example.invalid/fixture.zip'
            if ($mode -eq 'download') { Assert-Match $text '404 \(Not Found\)' }
            if ($text -match 'END WinTools/DirectArchive .* Set') { throw 'Failed Set was logged as successful' }
        }
        Write-Host "PASS: $mode stage and exit status"
    }

    # Get/Test must still emit parseable DSC JSON; logging cannot enter stdout.
    @'
param($Installer, $Action)
& $Installer -Action $Action 6>$null
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath (Join-Path $scratch 'read-state.ps1')
    foreach ($action in 'get', 'test') {
        $output = & pwsh -NoProfile -File (Join-Path $scratch 'read-state.ps1') -Installer (Join-Path $scratch 'install.ps1') -Action $action | Out-String
        if ($LASTEXITCODE -ne 0) { throw "$action failed: $output" }
        $null = $output | ConvertFrom-Json
        Write-Host "PASS: $action JSON output"
    }
    $defaultLogs = @(Get-ChildItem -LiteralPath (Join-Path $scratch 'logs') -Filter '*.log')
    if ($defaultLogs.Count -ne 2) { throw 'Expected unique default logs for get and test' }
    Write-Host 'PASS: default per-run log paths'
} finally {
    $env:WINTOOLS_TEST_BIN = $oldFixtureBin
    $env:WINTOOLS_TEST_MODE = $oldFixtureMode
    # Only remove the uniquely named directory created by this test.
    $resolvedScratch = [System.IO.Path]::GetFullPath($scratch)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedScratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedScratch) -notlike 'wintools-logging-test-*') {
        throw "Refusing to remove unexpected fixture path: $resolvedScratch"
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
