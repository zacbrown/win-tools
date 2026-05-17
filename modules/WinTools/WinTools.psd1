@{
    RootModule           = 'WinTools.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'c7a6b5d4-3e2f-4a1b-9c8d-7e6f5a4b3c2d'
    Author               = 'Zac Brown'
    Description          = 'DSC v3 resources for installing CLI tools from GitHub releases into ~/.local/bin.'
    PowerShellVersion    = '7.2'
    DscResourcesToExport = @('GithubReleaseTool', 'DirectArchive', 'DirectBinary', 'LocalBinPath', 'ScriptInstaller')
    FunctionsToExport    = @()
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('DSC', 'Windows', 'GitHub')
        }
    }
}
