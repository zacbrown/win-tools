#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('set', 'test', 'get')]
    [string] $Action = 'set',
    [string] $LogPath,
    [ValidateSet('error', 'warn', 'info', 'debug', 'trace')]
    [string] $TraceLevel = 'info'
)

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulesDir = Join-Path $repoRoot 'modules'
$configPath = Join-Path $repoRoot 'tools.dsc.yaml'

. (Join-Path $modulesDir 'WinTools/Logging.ps1')
if (-not $LogPath) {
    $LogPath = Join-Path $repoRoot ("logs/install-{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), [Guid]::NewGuid().ToString('N').Substring(0, 8))
}
$LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
# Check writability before starting DSC. A supplied path is appended to.
[System.IO.File]::AppendAllText($LogPath, '')
Write-Host "WinTools log: $LogPath"

$previousLogPath = $env:WINTOOLS_LOG_PATH
$previousModulePath = $env:PSModulePath
$exitCode = 1
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
            Write-Host "$_"
        } else {
            Write-WinToolsLog "DSC stdout: $_" 'DSC'
            Write-Output $_
        }
    }
    $exitCode = $LASTEXITCODE
    Write-WinToolsLog "END install Action=$Action ExitCode=$exitCode"
    if ($exitCode -ne 0) {
        Write-Host "DSC $Action failed (exit $exitCode). Details: $LogPath" -ForegroundColor Red
        # Surface the resource context after DSC's often lengthy adapter stack trace.
        Get-Content -LiteralPath $LogPath -Tail 200 | Where-Object { $_ -match '\[ERROR\].*FAILED ' } | Select-Object -Last 1 | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    }
} catch {
    Write-WinToolsLog "FAILED install: $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
    Write-Host "Install failed. Details: $LogPath" -ForegroundColor Red
    throw
} finally {
    $env:WINTOOLS_LOG_PATH = $previousLogPath
    $env:PSModulePath = $previousModulePath
}
exit $exitCode
