#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('set', 'test', 'get')]
    [string] $Action = 'set'
)

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulesDir = Join-Path $repoRoot 'modules'
$configPath = Join-Path $repoRoot 'tools.dsc.yaml'

$env:PSModulePath = "$modulesDir;$env:PSModulePath"

if (-not (Get-Command dsc -ErrorAction SilentlyContinue)) {
    throw "The 'dsc' CLI (DSC v3) is not installed. Grab a release from https://github.com/PowerShell/DSC/releases and put dsc.exe on PATH."
}

dsc config $Action --file $configPath
