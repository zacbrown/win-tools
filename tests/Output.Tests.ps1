#Requires -Version 7.2
# Exercise wrapper outcomes without changing the machine or using the network.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('wintools-output-test-' + [Guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH
$oldResult = $env:WINTOOLS_OUTPUT_RESULT
$oldExit = $env:WINTOOLS_OUTPUT_EXIT
New-Item -ItemType Directory -Path $scratch | Out-Null

function Assert-Match([string]$Actual, [string]$Pattern) {
    if ($Actual -notmatch $Pattern) { throw "Expected '$Pattern' in:`n$Actual" }
}

function Invoke-Fixture([string]$Json, [int]$Code = 0, [string]$Format = 'summary', [string]$Action = 'set') {
    Set-Content -LiteralPath $env:WINTOOLS_OUTPUT_RESULT -Value $Json
    $env:WINTOOLS_OUTPUT_EXIT = "$Code"
    $output = & pwsh -NoProfile -File (Join-Path $scratch 'install.ps1') -Action $Action -LogPath (Join-Path $scratch 'run.log') -OutputFormat $Format 2>&1 | Out-String
    @{ Output = $output; Code = $LASTEXITCODE }
}

try {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'install.ps1') -Destination $scratch
    Copy-Item -LiteralPath (Join-Path $repoRoot 'modules') -Destination $scratch -Recurse
    # The native fixture writes separate stdout/stderr, like DSC itself.
    @'
@echo off
echo fixture diagnostic 1>&2
type "%WINTOOLS_OUTPUT_RESULT%"
exit /b %WINTOOLS_OUTPUT_EXIT%
'@ | Set-Content -LiteralPath (Join-Path $scratch 'dsc.cmd')
    $env:PATH = "$scratch;$oldPath"
    $env:WINTOOLS_OUTPUT_RESULT = Join-Path $scratch 'result.json'
    $healthy = '{"name":"tool","type":"WinTools/DirectArchive","properties":{"Exists":true,"InstalledVersion":"2.0.0","Version":"2.0.0","Binaries":["tool.exe"]}}'
    $missing = $healthy.Replace('"Exists":true', '"Exists":false')
    $json = '{"hadErrors":false,"results":[{"result":{"beforeState":{"resources":[' + $missing + ']},"afterState":{"result":[' + $healthy + ']}}}]}'
    $run = Invoke-Fixture $json
    if ($run.Code -ne 0) { throw "Successful fixture failed: $($run.Output)" }
    Assert-Match $run.Output 'SUCCESS: DSC set completed'
    Assert-Match $run.Output 'Final state: 1 OK, 0 need attention'
    Assert-Match $run.Output 'tool\s+OK\s+2.0.0\s+2.0.0'
    if ($run.Output -match 'fixture diagnostic|beforeState|MISSING') { throw 'Trace or old state leaked into summary' }
    Assert-Match (Get-Content -LiteralPath (Join-Path $scratch 'run.log') -Raw) 'fixture diagnostic'
    Write-Host 'PASS: final state replaces before state; trace stays in the log'

    $run = Invoke-Fixture $json -Format json
    if ($run.Code -ne 0) { throw 'JSON fixture failed' }
    $null = $run.Output | ConvertFrom-Json
    if ($run.Output.Trim() -cne $json) { throw 'Machine output changed' }
    Write-Host 'PASS: explicit JSON output has no summary or traces'

    $mismatch = $healthy.Replace('"InstalledVersion":"2.0.0"', '"InstalledVersion":"1.0.0"')
    $unknown = $healthy.Replace('"InstalledVersion":"2.0.0"', '"InstalledVersion":""')
    $path = '{"name":"bin","type":"WinTools/LocalBinPath","properties":{"Exists":true,"InPath":false,"Path":"%USERPROFILE%\\.local\\bin"}}'
    $plugin = '{"name":"markdown","type":"WinTools/DprintPlugin","properties":{"Installed":false,"Plugin":"markdown"}}'
    $run = Invoke-Fixture ('{"results":[{"result":{"afterState":{"resources":[' + ($healthy, $missing, $mismatch, $unknown, $path, $plugin -join ',') + ']}}}]}')
    Assert-Match $run.Output 'Final state: 1 OK, 5 need attention'
    foreach ($status in 'MISSING', 'MISMATCH', 'UNKNOWN', 'NEEDS PATH', 'markdown plugin missing') { Assert-Match $run.Output $status }
    Write-Host 'PASS: missing files/plugins, version drift, unreadable versions and PATH drift'

    $github = '{"name":"upstream","type":"WinTools/GithubReleaseTool","properties":{"InstalledVersion":"","TargetVersion":"latest","Version":"latest","Binaries":["upstream.exe"]}}'
    $run = Invoke-Fixture ('{"results":[{"result":{"afterState":{"result":[' + $github + ']}}}]}')
    Assert-Match $run.Output 'Final state: 0 OK, 1 need attention'
    Assert-Match $run.Output 'upstream\s+UNKNOWN'
    Write-Host 'PASS: upstream tracking cannot claim success without observed installation state'

    $run = Invoke-Fixture '{"results":[{"result":{"actualState":{"result":[{"name":"present","type":"WinTools/DirectArchive","properties":{"InDesiredState":true}},{"name":"drift","type":"WinTools/DirectArchive","properties":{"InDesiredState":false}}]}}}]}' -Action test
    if ($run.Code -ne 0) { throw 'Test drift changed the DSC execution exit code' }
    Assert-Match $run.Output 'SUCCESS: DSC test completed'
    Assert-Match $run.Output 'Final state: 1 OK, 1 need attention'
    Assert-Match $run.Output 'drift\s+MISMATCH\s+does not match desired state'
    Write-Host 'PASS: boolean adapter test state and drift with exit zero'

    # An appended log must never attribute a previous run's failure to this run.
    Add-Content -LiteralPath (Join-Path $scratch 'run.log') -Value '[ERROR] FAILED WinTools/DirectArchive previous-failure'
    $run = Invoke-Fixture $json -Code 42
    if ($run.Code -ne 42) { throw 'DSC exit code was not preserved' }
    Assert-Match $run.Output 'FAIL: DSC set failed \(exit 42\)'
    Assert-Match $run.Output 'Reported final state \(partial\)'
    Assert-Match $run.Output 'fixture diagnostic'
    if ($run.Output -match 'previous-failure') { throw 'Old failure surfaced from appended log' }
    Write-Host 'PASS: nonzero exit, partial state and current-run diagnostics'

    $run = Invoke-Fixture ($json.Replace('"hadErrors":false', '"hadErrors":true'))
    if ($run.Code -ne 1) { throw 'hadErrors with exit zero was accepted' }
    Assert-Match $run.Output 'FAIL: DSC set failed'
    foreach ($invalid in '', 'not json') {
        $run = Invoke-Fixture $invalid
        if ($run.Code -ne 1) { throw 'Missing or malformed results were accepted' }
        Assert-Match $run.Output 'FAIL: DSC set failed'
        Assert-Match $run.Output 'Final state unavailable'
    }
    Write-Host 'PASS: errors and absent/malformed JSON cannot report success'
} finally {
    $env:PATH = $oldPath
    $env:WINTOOLS_OUTPUT_RESULT = $oldResult
    $env:WINTOOLS_OUTPUT_EXIT = $oldExit
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedScratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedScratch) -notlike 'wintools-output-test-*') {
        throw "Refusing to remove unexpected fixture path: $resolvedScratch"
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
