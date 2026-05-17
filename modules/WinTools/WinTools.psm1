Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

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

    [DscProperty(NotConfigurable)] [string] $InstalledVersion
    [DscProperty(NotConfigurable)] [string] $TargetVersion

    [GithubReleaseTool] Get() {
        $binDir = Get-LocalBinDir
        $primary = Join-Path $binDir $this.Binaries[0]

        $result = [GithubReleaseTool]::new()
        $result.Name             = $this.Name
        $result.Repo             = $this.Repo
        $result.Version          = $this.Version
        $result.AssetPattern     = $this.AssetPattern
        $result.Binaries         = $this.Binaries
        $result.VersionRegex     = $this.VersionRegex
        $result.InstalledVersion = $this.GetInstalledVersion($primary)
        $result.TargetVersion    = $this.ResolveTargetVersion()
        return $result
    }

    [bool] Test() {
        $binDir = Get-LocalBinDir
        foreach ($b in $this.Binaries) {
            if (-not (Test-Path (Join-Path $binDir $b))) { return $false }
        }
        $current = $this.GetInstalledVersion((Join-Path $binDir $this.Binaries[0]))
        if (-not $current) { return $false }
        return ($current -eq $this.ResolveTargetVersion())
    }

    [void] Set() {
        $binDir = Get-LocalBinDir
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null

        $tag = if ($this.Version -eq 'latest') {
            Get-LatestReleaseTag -Repo $this.Repo
        } else {
            $this.Version
        }
        $asset = Get-ReleaseAsset -Repo $this.Repo -Tag $tag -Pattern $this.AssetPattern

        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wintools-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $archive = Join-Path $tmp $asset.name
            Write-Verbose "Downloading $($asset.browser_download_url)"
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive -UseBasicParsing

            $extract = Join-Path $tmp 'extract'
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
            Expand-ReleaseArchive -ArchivePath $archive -DestinationDir $extract

            foreach ($bin in $this.Binaries) {
                $found = Get-ChildItem -Path $extract -Recurse -File -Filter $bin -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if (-not $found) { throw "Binary '$bin' not found inside $($asset.name)" }
                Copy-Item -Path $found.FullName -Destination (Join-Path $binDir $bin) -Force
            }
        } finally {
            Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    hidden [string] GetInstalledVersion([string]$BinaryPath) {
        if (-not (Test-Path $BinaryPath)) { return '' }
        try {
            $out = & $BinaryPath --version 2>&1 | Out-String
            if ($out -match $this.VersionRegex) { return $matches[1] }
        } catch {
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
class DirectBinary {
    [DscProperty(Key)]       [string] $Name
    [DscProperty(Mandatory)] [string] $Url

    [DscProperty(NotConfigurable)] [bool] $Exists

    [DirectBinary] Get() {
        $r = [DirectBinary]::new()
        $r.Name   = $this.Name
        $r.Url    = $this.Url
        $r.Exists = Test-Path (Join-Path (Get-LocalBinDir) $this.Name)
        return $r
    }

    [bool] Test() {
        return Test-Path (Join-Path (Get-LocalBinDir) $this.Name)
    }

    [void] Set() {
        $binDir = Get-LocalBinDir
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        $dest = Join-Path $binDir $this.Name
        Write-Verbose "Downloading $($this.Url) -> $dest"
        Invoke-WebRequest -Uri $this.Url -OutFile $dest -UseBasicParsing
    }
}

[DscResource()]
class ScriptInstaller {
    [DscProperty(Key)]       [string] $Name
    [DscProperty(Mandatory)] [string] $ScriptUrl
    [DscProperty(Mandatory)] [string] $TestPath

    [DscProperty(NotConfigurable)] [bool] $Exists

    [ScriptInstaller] Get() {
        $r = [ScriptInstaller]::new()
        $r.Name      = $this.Name
        $r.ScriptUrl = $this.ScriptUrl
        $r.TestPath  = $this.TestPath
        $r.Exists    = Test-Path ([Environment]::ExpandEnvironmentVariables($this.TestPath))
        return $r
    }

    [bool] Test() {
        return Test-Path ([Environment]::ExpandEnvironmentVariables($this.TestPath))
    }

    [void] Set() {
        Write-Verbose "Fetching $($this.ScriptUrl)"
        $script = Invoke-RestMethod -Uri $this.ScriptUrl -UseBasicParsing
        Invoke-Expression $script
    }
}

[DscResource()]
class LocalBinPath {
    [DscProperty(Key)] [string] $Path = "$env:USERPROFILE\.local\bin"

    [DscProperty(NotConfigurable)] [bool] $Exists
    [DscProperty(NotConfigurable)] [bool] $InPath

    [LocalBinPath] Get() {
        $result = [LocalBinPath]::new()
        $result.Path   = $this.Path
        $result.Exists = Test-Path $this.ResolvedPath()
        $result.InPath = $this.IsInUserPath()
        return $result
    }

    [bool] Test() {
        return (Test-Path $this.ResolvedPath()) -and $this.IsInUserPath()
    }

    [void] Set() {
        $resolved = $this.ResolvedPath()
        if (-not (Test-Path $resolved)) {
            New-Item -ItemType Directory -Path $resolved -Force | Out-Null
        }
        if (-not $this.IsInUserPath()) {
            $current = [Environment]::GetEnvironmentVariable('Path', 'User')
            $entry = $this.Path
            $new = if ([string]::IsNullOrEmpty($current)) { $entry } else { "$entry;$current" }
            [Environment]::SetEnvironmentVariable('Path', $new, 'User')
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
