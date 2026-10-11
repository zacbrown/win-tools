#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('set', 'test', 'get')]
    [string] $Action = 'set',
    [string] $LogPath,
    [ValidateSet('error', 'warn', 'info', 'debug', 'trace')]
    [string] $TraceLevel = 'info',
    [ValidateSet('summary', 'json')]
    [string] $OutputFormat = 'summary'
)

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulesDir = Join-Path $repoRoot 'modules'
$configPath = Join-Path $repoRoot 'tools.dsc.yaml'

. (Join-Path $modulesDir 'WinTools/Logging.ps1')
. (Join-Path $modulesDir 'WinTools/Output.ps1')
if (-not $LogPath) {
    $LogPath = Join-Path $repoRoot ("logs/install-{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), [Guid]::NewGuid().ToString('N').Substring(0, 8))
}
$LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
# Check writability before starting DSC. A supplied path is appended to.
[System.IO.File]::AppendAllText($LogPath, '')
if ($OutputFormat -eq 'summary') {
    Write-Host "Running DSC $Action..."
    Write-Host "WinTools log: $LogPath"
}
$logStart = (Get-Item -LiteralPath $LogPath).Length

$previousLogPath = $env:WINTOOLS_LOG_PATH
$previousModulePath = $env:PSModulePath
$exitCode = 1
$result = $null
$stdout = [System.Collections.Generic.List[string]]::new()
$stderr = [System.Collections.Generic.List[string]]::new()
# Handle DSC's exit status ourselves, including when the caller enables this preference.
$PSNativeCommandUseErrorActionPreference = $false
try {
    $env:WINTOOLS_LOG_PATH = $LogPath
    $env:PSModulePath = "$modulesDir;$previousModulePath"
    Write-WinToolsLog "START install Action=$Action Config='$configPath' TraceLevel=$TraceLevel PowerShell=$($PSVersionTable.PSVersion)"
    if (-not (Get-Command dsc -ErrorAction SilentlyContinue)) {
        throw "The 'dsc' CLI (DSC v3) is not installed. Grab a release from https://github.com/PowerShell/DSC/releases and put dsc.exe on PATH."
    }

    & dsc --trace-level $TraceLevel --trace-format plaintext config $Action --file $configPath 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            Write-WinToolsLog "DSC stderr: $_" 'DSC'
            $stderr.Add("$_")
            Write-Verbose "$_"
        } else {
            Write-WinToolsLog "DSC stdout: $_" 'DSC'
            $stdout.Add("$_")
        }
    }
    $exitCode = $LASTEXITCODE
    Write-WinToolsLog "END install Action=$Action ExitCode=$exitCode"
    if ($stdout.Count -gt 0) {
        try { $result = ($stdout -join "`n") | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch {
            if ($exitCode -eq 0) { throw "DSC returned invalid result JSON: $($_.Exception.Message)" }
        }
    }
    if ($exitCode -eq 0 -and $null -eq $result) { throw 'DSC returned no result JSON.' }
    if ($exitCode -eq 0 -and $result.hadErrors) { $exitCode = 1 }
    if ($OutputFormat -eq 'json') { $stdout | Write-Output }
} catch {
    Write-WinToolsLog "FAILED install: $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
    $exitCode = 1
    Write-Host $_.Exception.Message -ForegroundColor Red
} finally {
    $env:WINTOOLS_LOG_PATH = $previousLogPath
    $env:PSModulePath = $previousModulePath
    if ($OutputFormat -eq 'summary') {
        Write-WinToolsSummary -Action $Action -ExitCode $exitCode -Result $result -LogPath $LogPath
    }
    if ($exitCode -ne 0) {
        # Read only this run so an appended log cannot surface an old failure.
        $stream = [System.IO.File]::OpenRead($LogPath)
        try {
            $null = $stream.Seek($logStart, [System.IO.SeekOrigin]::Begin)
            $reader = [System.IO.StreamReader]::new($stream)
            try { $runLog = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
        $failure = $runLog -split '\r?\n' | Where-Object { $_ -match '\[ERROR\].*FAILED WinTools/' } | Select-Object -Last 1
        if ($failure) { Write-Host ($failure -replace '^.*?FAILED (?=WinTools/)', '') -ForegroundColor Red }
        elseif ($stderr.Count -gt 0) { Write-Host $stderr[$stderr.Count - 1] -ForegroundColor Red }
    }
}
exit $exitCode
