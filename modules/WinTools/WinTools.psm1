Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Logging.ps1')

function Get-LocalBinDir {
    Join-Path $env:USERPROFILE '.local\bin'
}

function Get-GitHubHeaders {
    $h = @{ 'User-Agent' = 'win-tools-dsc'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $h['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $h
}

function Get-LatestReleaseTag {
    param([Parameter(Mandatory)][string]$Repo)
    $url = "https://api.github.com/repos/$Repo/releases/latest"
    (Invoke-RestMethod -Uri $url -Headers (Get-GitHubHeaders)).tag_name
}

function Get-ReleaseAsset {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Pattern
    )
    $url = "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    $release = Invoke-RestMethod -Uri $url -Headers (Get-GitHubHeaders)
    $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $asset) {
        $names = ($release.assets | ForEach-Object name) -join ', '
        throw "No asset in $Repo@$Tag matched /$Pattern/. Assets: $names"
    }
    $asset
}

function Expand-ReleaseArchive {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestinationDir
    )
    if ($ArchivePath -match '\.zip$') {
        Expand-Archive -Path $ArchivePath -DestinationPath $DestinationDir -Force
    } elseif ($ArchivePath -match '\.tar\.gz$|\.tgz$') {
        & tar -xzf $ArchivePath -C $DestinationDir
        if ($LASTEXITCODE -ne 0) { throw "tar extraction failed for $ArchivePath" }
    } else {
        throw "Unsupported archive type: $ArchivePath"
    }
}

[DscResource()]
class GithubReleaseTool {
    [DscProperty(Key)]       [string]   $Name
    [DscProperty(Mandatory)] [string]   $Repo
    [DscProperty()]          [string]   $Version = 'latest'
    [DscProperty(Mandatory)] [string]   $AssetPattern
    [DscProperty(Mandatory)] [string[]] $Binaries
    [DscProperty()]          [string]   $VersionRegex = '(\d+\.\d+\.\d+)'
    [DscProperty()]          [bool]     $ForceUpdateCheck = $false

    [DscProperty(NotConfigurable)] [string] $InstalledVersion
    [DscProperty(NotConfigurable)] [string] $TargetVersion

    [GithubReleaseTool] Get() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Get'
        $failed = $false
        Write-WinToolsLog "START $context Get"
        try {
            $binDir = Get-LocalBinDir
            $primary = Join-Path $binDir $this.Binaries[0]

            $result = [GithubReleaseTool]::new()
            $result.Name             = $this.Name
            $result.Repo             = $this.Repo
            $result.Version          = $this.Version
            $result.AssetPattern     = $this.AssetPattern
            $result.Binaries         = $this.Binaries
            $result.VersionRegex     = $this.VersionRegex
            $result.ForceUpdateCheck = $this.ForceUpdateCheck
            $result.InstalledVersion = $this.GetInstalledVersion($primary)
            # Mirror Test()'s short-circuit: don't hit the API just to populate TargetVersion
            # when Version is 'latest' — DSC v3 calls Get() during 'set', so this would burn
            # the rate limit even when nothing needs installing.
            $result.TargetVersion    = if ($this.Version -eq 'latest' -and -not $this.ForceUpdateCheck) {
                'latest'
            } else {
                $this.ResolveTargetVersion()
            }
            return $result
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Get Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Get Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Get" }
        }
    }

    [bool] Test() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Test'
        $failed = $false
        Write-WinToolsLog "START $context Test"
        try {
            $binDir = Get-LocalBinDir
            foreach ($b in $this.Binaries) {
                if (-not (Test-Path (Join-Path $binDir $b))) { return $false }
            }
            # Short-circuit for 'latest' to avoid hammering the GitHub API on every run.
            # Set ForceUpdateCheck: true on a resource to re-enable the upstream compare.
            if ($this.Version -eq 'latest' -and -not $this.ForceUpdateCheck) { return $true }
            $current = $this.GetInstalledVersion((Join-Path $binDir $this.Binaries[0]))
            if (-not $current) { return $false }
            return ($current -eq $this.ResolveTargetVersion())
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Test Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Test Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Test" }
        }
    }

    [void] Set() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Set'
        $failed = $false
        Write-WinToolsLog "START $context Set"
        try {
            $binDir = Get-LocalBinDir
            New-Item -ItemType Directory -Path $binDir -Force | Out-Null

            $stage = 'resolve release tag'
            Write-WinToolsLog "$context $stage"
            $tag = if ($this.Version -eq 'latest') {
                Get-LatestReleaseTag -Repo $this.Repo
            } else {
                $this.Version
            }
            $stage = 'resolve release asset'
            Write-WinToolsLog "$context $stage Tag='$tag' Pattern='$($this.AssetPattern)'"
            $asset = Get-ReleaseAsset -Repo $this.Repo -Tag $tag -Pattern $this.AssetPattern

            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wintools-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $archive = Join-Path $tmp $asset.name
                $stage = "download $($asset.browser_download_url)"
                Write-WinToolsLog "$context $stage"
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive -UseBasicParsing

                $extract = Join-Path $tmp 'extract'
                New-Item -ItemType Directory -Path $extract -Force | Out-Null
                $stage = "extract $archive"
                Write-WinToolsLog "$context $stage"
                Expand-ReleaseArchive -ArchivePath $archive -DestinationDir $extract

                foreach ($bin in $this.Binaries) {
                    $stage = "locate/copy $bin to $binDir"
                    Write-WinToolsLog "$context $stage"
                    $found = Get-ChildItem -Path $extract -Recurse -File -Filter $bin -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                    if (-not $found) { throw "Binary '$bin' not found inside $($asset.name)" }
                    Copy-Item -Path $found.FullName -Destination (Join-Path $binDir $bin) -Force
                }
            } finally {
                Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Set Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Set Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Set" }
        }
    }

    hidden [string] GetInstalledVersion([string]$BinaryPath) {
        if (-not (Test-Path $BinaryPath)) { return '' }
        $versionContext = Get-WinToolsResourceContext $this
        Write-WinToolsLog "$versionContext check installed version: $BinaryPath --version"
        try {
            # Run from the binary's own directory: some tools (e.g. hypa) walk
            # up from the process CWD doing project-root detection and crash
            # when dsc's CWD is an unreadable path like C:\Program Files\WindowsApps.
            $out = ''
            Push-Location (Split-Path -Parent $BinaryPath)
            try {
                $out = & $BinaryPath --version 2>&1 | Out-String
            } finally {
                Pop-Location
            }
            if ($out -match $this.VersionRegex) {
                Write-WinToolsLog "$versionContext InstalledVersion='$($matches[1])'"
                return $matches[1]
            }
            Write-WinToolsLog "$versionContext version output did not match '$($this.VersionRegex)': $out" 'WARN'
        } catch {
            Write-WinToolsLog "$versionContext version check failed: $($_.Exception.Message)" 'WARN'
            return ''
        }
        return ''
    }

    hidden [string] ResolveTargetVersion() {
        $tag = if ($this.Version -eq 'latest') {
            Get-LatestReleaseTag -Repo $this.Repo
        } else {
            $this.Version
        }
        return $tag.TrimStart('v')
    }
}

[DscResource()]
class DirectArchive {
    [DscProperty(Key)]       [string]   $Name
    [DscProperty(Mandatory)] [string]   $Url
    [DscProperty(Mandatory)] [string[]] $Binaries
    [DscProperty()]          [string]   $Version
    [DscProperty()]          [string]   $VersionRegex = '(\d+\.\d+\.\d+)'

    [DscProperty(NotConfigurable)] [bool]   $Exists
    [DscProperty(NotConfigurable)] [string] $InstalledVersion

    [DirectArchive] Get() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Get'
        $failed = $false
        Write-WinToolsLog "START $context Get"
        try {
            $binDir = Get-LocalBinDir
            $primary = Join-Path $binDir $this.Binaries[0]
            $r = [DirectArchive]::new()
            $r.Name             = $this.Name
            $r.Url              = $this.Url
            $r.Binaries         = $this.Binaries
            $r.Version          = $this.Version
            $r.VersionRegex     = $this.VersionRegex
            $r.Exists           = $this.AllBinariesPresent()
            $r.InstalledVersion = $this.GetInstalledVersion($primary)
            return $r
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Get Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Get Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Get" }
        }
    }

    [bool] Test() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Test'
        $failed = $false
        Write-WinToolsLog "START $context Test"
        try {
            if (-not $this.AllBinariesPresent()) { return $false }
            if ([string]::IsNullOrEmpty($this.Version)) { return $true }
            $primary = Join-Path (Get-LocalBinDir) $this.Binaries[0]
            $current = $this.GetInstalledVersion($primary)
            if (-not $current) { return $false }
            return ($current -eq $this.Version.TrimStart('v'))
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Test Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Test Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Test" }
        }
    }

    [void] Set() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Set'
        $failed = $false
        Write-WinToolsLog "START $context Set"
        try {
            $binDir = Get-LocalBinDir
            New-Item -ItemType Directory -Path $binDir -Force | Out-Null

            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wintools-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $archive = Join-Path $tmp ([System.IO.Path]::GetFileName($this.Url))
                $stage = "download $($this.Url)"
                Write-WinToolsLog "$context $stage"
                Invoke-WebRequest -Uri $this.Url -OutFile $archive -UseBasicParsing

                $extract = Join-Path $tmp 'extract'
                New-Item -ItemType Directory -Path $extract -Force | Out-Null
                $stage = "extract $archive"
                Write-WinToolsLog "$context $stage"
                Expand-ReleaseArchive -ArchivePath $archive -DestinationDir $extract

                foreach ($bin in $this.Binaries) {
                    $stage = "locate/copy $bin to $binDir"
                    Write-WinToolsLog "$context $stage"
                    $found = Get-ChildItem -Path $extract -Recurse -File -Filter $bin -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                    if (-not $found) { throw "Binary '$bin' not found inside $archive" }
                    Copy-Item -Path $found.FullName -Destination (Join-Path $binDir $bin) -Force
                }
            } finally {
                Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Set Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Set Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Set" }
        }
    }

    hidden [bool] AllBinariesPresent() {
        $binDir = Get-LocalBinDir
        foreach ($b in $this.Binaries) {
            if (-not (Test-Path (Join-Path $binDir $b))) { return $false }
        }
        return $true
    }

    hidden [string] GetInstalledVersion([string]$BinaryPath) {
        if (-not (Test-Path $BinaryPath)) { return '' }
        $versionContext = Get-WinToolsResourceContext $this
        Write-WinToolsLog "$versionContext check installed version: $BinaryPath --version"
        try {
            # Run from the binary's own directory: some tools (e.g. hypa) walk
            # up from the process CWD doing project-root detection and crash
            # when dsc's CWD is an unreadable path like C:\Program Files\WindowsApps.
            $out = ''
            Push-Location (Split-Path -Parent $BinaryPath)
            try {
                $out = & $BinaryPath --version 2>&1 | Out-String
            } finally {
                Pop-Location
            }
            if ($out -match $this.VersionRegex) {
                Write-WinToolsLog "$versionContext InstalledVersion='$($matches[1])'"
                return $matches[1]
            }
            Write-WinToolsLog "$versionContext version output did not match '$($this.VersionRegex)': $out" 'WARN'
        } catch {
            Write-WinToolsLog "$versionContext version check failed: $($_.Exception.Message)" 'WARN'
            return ''
        }
        return ''
    }
}

[DscResource()]
class DirectBinary {
    [DscProperty(Key)]       [string] $Name
    [DscProperty(Mandatory)] [string] $Url

    [DscProperty(NotConfigurable)] [bool] $Exists

    [DirectBinary] Get() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Get'
        $failed = $false
        Write-WinToolsLog "START $context Get"
        try {
            $r = [DirectBinary]::new()
            $r.Name   = $this.Name
            $r.Url    = $this.Url
            $r.Exists = Test-Path (Join-Path (Get-LocalBinDir) $this.Name)
            return $r
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Get Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Get Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Get" }
        }
    }

    [bool] Test() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Test'
        $failed = $false
        Write-WinToolsLog "START $context Test"
        try {
            return Test-Path (Join-Path (Get-LocalBinDir) $this.Name)
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Test Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Test Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Test" }
        }
    }

    [void] Set() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Set'
        $failed = $false
        Write-WinToolsLog "START $context Set"
        try {
            $binDir = Get-LocalBinDir
            New-Item -ItemType Directory -Path $binDir -Force | Out-Null
            $dest = Join-Path $binDir $this.Name
            $stage = "download $($this.Url) to $dest"
            Write-WinToolsLog "$context $stage"
            Invoke-WebRequest -Uri $this.Url -OutFile $dest -UseBasicParsing
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Set Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Set Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Set" }
        }
    }
}

[DscResource()]
class ScriptInstaller {
    [DscProperty(Key)]       [string] $Name
    [DscProperty(Mandatory)] [string] $ScriptUrl
    [DscProperty(Mandatory)] [string] $TestPath

    [DscProperty(NotConfigurable)] [bool] $Exists

    [ScriptInstaller] Get() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Get'
        $failed = $false
        Write-WinToolsLog "START $context Get"
        try {
            $r = [ScriptInstaller]::new()
            $r.Name      = $this.Name
            $r.ScriptUrl = $this.ScriptUrl
            $r.TestPath  = $this.TestPath
            $r.Exists    = Test-Path ([Environment]::ExpandEnvironmentVariables($this.TestPath))
            return $r
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Get Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Get Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Get" }
        }
    }

    [bool] Test() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Test'
        $failed = $false
        Write-WinToolsLog "START $context Test"
        try {
            return Test-Path ([Environment]::ExpandEnvironmentVariables($this.TestPath))
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Test Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Test Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Test" }
        }
    }

    [void] Set() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Set'
        $failed = $false
        Write-WinToolsLog "START $context Set"
        try {
            $stage = "download installer $($this.ScriptUrl)"
            Write-WinToolsLog "$context $stage"
            $script = Invoke-RestMethod -Uri $this.ScriptUrl -UseBasicParsing
            $stage = 'execute installer'
            Write-WinToolsLog "$context $stage"
            Invoke-Expression $script
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Set Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Set Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Set" }
        }
    }
}

[DscResource()]
class DprintPlugin {
    [DscProperty(Key)] [string] $Plugin
    [DscProperty()]    [string] $ConfigPath = "$env:USERPROFILE\.config\dprint\dprint.json"

    [DscProperty(NotConfigurable)] [bool] $Installed

    [DprintPlugin] Get() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Get'
        $failed = $false
        Write-WinToolsLog "START $context Get"
        try {
            $r = [DprintPlugin]::new()
            $r.Plugin     = $this.Plugin
            $r.ConfigPath = $this.ConfigPath
            $r.Installed  = $this.HasPlugin()
            return $r
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Get Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Get Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Get" }
        }
    }

    [bool] Test() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Test'
        $failed = $false
        Write-WinToolsLog "START $context Test"
        try {
            return $this.HasPlugin()
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Test Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Test Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Test" }
        }
    }

    [void] Set() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Set'
        $failed = $false
        Write-WinToolsLog "START $context Set"
        try {
            $resolved = [Environment]::ExpandEnvironmentVariables($this.ConfigPath)
            $dir = Split-Path -Parent $resolved
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            if (-not (Test-Path $resolved)) {
                Set-Content -Path $resolved -Value '{ "plugins": [] }' -Encoding utf8
            }
            $dprint = Join-Path (Get-LocalBinDir) 'dprint.exe'
            if (-not (Test-Path $dprint)) {
                throw "dprint.exe not found at $dprint; ensure the 'dprint' resource has run."
            }
            Push-Location $dir
            try {
                $stage = "dprint config add $($this.Plugin) in $dir"
                Write-WinToolsLog "$context $stage"
                & $dprint config add $this.Plugin
                if ($LASTEXITCODE -ne 0) {
                    throw "dprint config add $($this.Plugin) failed (exit $LASTEXITCODE)"
                }
            } finally {
                Pop-Location
            }
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Set Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Set Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Set" }
        }
    }

    hidden [bool] HasPlugin() {
        $resolved = [Environment]::ExpandEnvironmentVariables($this.ConfigPath)
        if (-not (Test-Path $resolved)) { return $false }
        try {
            $cfg = Get-Content -Raw -Path $resolved | ConvertFrom-Json
            if (-not $cfg.PSObject.Properties['plugins']) { return $false }
            $needle = [regex]::Escape($this.Plugin)
            foreach ($p in $cfg.plugins) {
                if ("$p" -match "/$needle-\d|/$needle\.wasm|/$needle\.json") { return $true }
            }
        } catch {
            return $false
        }
        return $false
    }
}

[DscResource()]
class LocalBinPath {
    [DscProperty(Key)] [string] $Path = "$env:USERPROFILE\.local\bin"

    [DscProperty(NotConfigurable)] [bool] $Exists
    [DscProperty(NotConfigurable)] [bool] $InPath

    [LocalBinPath] Get() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Get'
        $failed = $false
        Write-WinToolsLog "START $context Get"
        try {
            $result = [LocalBinPath]::new()
            $result.Path   = $this.Path
            $result.Exists = Test-Path $this.ResolvedPath()
            $result.InPath = $this.IsInUserPath()
            return $result
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Get Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Get Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Get" }
        }
    }

    [bool] Test() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Test'
        $failed = $false
        Write-WinToolsLog "START $context Test"
        try {
            return (Test-Path $this.ResolvedPath()) -and $this.IsInUserPath()
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Test Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Test Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Test" }
        }
    }

    [void] Set() {
        $context = Get-WinToolsResourceContext $this
        $stage = 'Set'
        $failed = $false
        Write-WinToolsLog "START $context Set"
        try {
            $resolved = $this.ResolvedPath()
            if (-not (Test-Path $resolved)) {
                New-Item -ItemType Directory -Path $resolved -Force | Out-Null
            }
            if (-not $this.IsInUserPath()) {
                $current = [Environment]::GetEnvironmentVariable('Path', 'User')
                $entry = $this.Path
                $new = if ([string]::IsNullOrEmpty($current)) { $entry } else { "$entry;$current" }
                $stage = 'update user PATH'
                Write-WinToolsLog "$context $stage Entry='$entry'"
                [Environment]::SetEnvironmentVariable('Path', $new, 'User')
            }
        } catch {
            $failed = $true
            Write-WinToolsLog "FAILED $context Set Stage='$stage': $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
            throw [System.InvalidOperationException]::new("$context Set Stage='$stage' failed: $($_.Exception.Message)", $_.Exception)
        } finally {
            if (-not $failed) { Write-WinToolsLog "END $context Set" }
        }
    }

    hidden [string] ResolvedPath() {
        return [Environment]::ExpandEnvironmentVariables($this.Path)
    }

    hidden [bool] IsInUserPath() {
        $current = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ([string]::IsNullOrEmpty($current)) { return $false }
        $target = $this.ResolvedPath().TrimEnd('\')
        foreach ($entry in $current.Split(';')) {
            if (-not $entry) { continue }
            $expanded = [Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\')
            if ($expanded -ieq $target) { return $true }
        }
        return $false
    }
}
