# Write directly to a shared file: DSC resources run in adapter child processes,
# and their success stream must remain free of diagnostic text.
function Write-WinToolsLog {
    param(
        [Parameter(Mandatory)][string] $Message,
        [string] $Level = 'INFO'
    )
    if (-not $env:WINTOOLS_LOG_PATH) { return }
    $line = '{0} [{1}] [PID {2}] {3}{4}' -f [DateTimeOffset]::Now.ToString('o'), $Level, $PID, $Message, [Environment]::NewLine
    # A DSC trace and an adapter resource may append at the same time.
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($env:WINTOOLS_LOG_PATH, $line)
            return
        } catch [System.IO.IOException] {
            if ($attempt -lt 4) { Start-Sleep -Milliseconds 50; continue }
            [Console]::Error.WriteLine("Unable to append to WinTools log: $($_.Exception.Message)")
        } catch {
            [Console]::Error.WriteLine("Unable to append to WinTools log: $($_.Exception.Message)")
            return
        }
    }
}

function Get-WinToolsResourceContext {
    param([Parameter(Mandatory)] $Resource)
    $parts = @("WinTools/$($Resource.GetType().Name)")
    foreach ($property in 'Name', 'Plugin', 'Path', 'Version', 'Repo', 'Url', 'ScriptUrl', 'ConfigPath') {
        if ($Resource.PSObject.Properties[$property] -and "$($Resource.$property)") {
            $parts += "$property='$($Resource.$property)'"
        }
    }
    $parts -join ' '
}
