# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Declarative installer for a fixed set of Windows CLI tools (ripgrep, fd, fzf, just, uv, gh, rustup-init, claude-code). Drops binaries into `%USERPROFILE%\.local\bin` and ensures that directory is on the user `Path`. Built on **DSC v3** (PowerShell Desired State Configuration, the standalone `dsc.exe` rewrite — not the legacy Windows PowerShell DSC).

## Common commands

```powershell
# Apply desired state (install/update everything)
./install.ps1                # default action = set
./install.ps1 -Action set

# Check whether current state matches desired state (no changes)
./install.ps1 -Action test

# Read current state of each resource
./install.ps1 -Action get
```

Prereqs: PowerShell 7.2+ and `dsc.exe` (DSC v3) on `PATH`. `install.ps1` throws a helpful error pointing at https://github.com/PowerShell/DSC/releases if `dsc` is missing.

Set `$env:GITHUB_TOKEN` before running to avoid GitHub API rate limits (60/hr unauth → 5000/hr auth). `WinTools.psm1::Get-GitHubHeaders` picks it up automatically.

## Architecture

Three layers, top-down:

1. **`tools.dsc.yaml`** — declarative inventory. Each entry under `resources:` is a `Microsoft.DSC/PowerShell` group that hosts one or more class-based DSC resources from the local `WinTools` module. Groups have `dependsOn` edges (e.g. `install-tools` runs after `ensure-local-bin`).

2. **`install.ps1`** — thin wrapper that prepends `./modules` to `$env:PSModulePath` so the PowerShell DSC adapter can discover `WinTools`, then shells out to `dsc config <action> --file tools.dsc.yaml`. The PSModulePath injection is load-bearing: without it, `dsc` cannot locate the resource classes.

3. **`modules/WinTools/WinTools.psm1`** — four class-based DSC resources (each implements `Get()` / `Test()` / `Set()`):
   - `LocalBinPath` — creates a directory and ensures it's in the user `Path` env var.
   - `GithubReleaseTool` — downloads a release asset from GitHub by regex pattern, extracts (`.zip` or `.tar.gz`), recursively locates each named binary inside, copies to `~/.local/bin`. **Idempotency**: when `Version` is pinned (e.g. `1.2.3`), `Test()` parses `<binary> --version` (regex defaults to `(\d+\.\d+\.\d+)`, overridable per resource) and compares against the pinned tag — no API call. When `Version: latest`, both `Test()` and `Get()` short-circuit so repeated runs don't burn through the GitHub rate limit — `Test()` returns true on binary existence and `Get()` reports `TargetVersion = 'latest'` without resolving the upstream tag. Set `ForceUpdateCheck: true` on a resource to re-enable the upstream lookup in both methods (DSC v3 calls `Get()` as part of `set`, so a single un-guarded `Get()` is enough to drain the unauthenticated 60/hr budget in ~7 runs).
   - `DirectArchive` — downloads a zip/tar.gz from a known literal URL (no GitHub API call), extracts, copies named binaries to `~/.local/bin`. Use this for tools where you can pin to a direct release-download URL — the asset URL (`github.com/<repo>/releases/download/...`) is served from the CDN and **does not count against the API rate limit**. `Test()` is just "do all binaries exist."
   - `DirectBinary` — single-file download (used for `rustup-init.exe`). No version check; `Test()` is just "does the file exist."
   - `ScriptInstaller` — fetches a remote PowerShell install script and `Invoke-Expression`s it (used for `claude-code`, whose installer lives at `claude.ai/install.ps1`). Idempotency is "does `TestPath` exist."

The `DscResourcesToExport` list in `WinTools.psd1` is the contract with `dsc.exe`. New resources must be added there or DSC won't see them.

## Adding a tool

Default to `WinTools/DirectArchive` for a typical GitHub-released CLI. Resolve the current release tag once (e.g. `gh release view --repo <owner>/<repo>` or the releases API), then add an entry under the `install-tools` group with a literal `Url` of the form `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>`. `Binaries` is the list of executables to extract from the archive. Version bumps are explicit edits to the URL; the release-download CDN doesn't count against the GitHub API rate limit.

Reach for `WinTools/GithubReleaseTool` only when the user explicitly asks for upstream tracking (`Version: latest`) on a specific tool. In that case, `AssetPattern` is a regex matched against asset filenames in the release JSON — prefer `x86_64-pc-windows-msvc` or `windows_amd64` variants, anchored with `$` to avoid matching `.sig`/`.sha256` siblings. The **first** binary listed is used for version detection; override `VersionRegex` if `--version` output doesn't match `\d+\.\d+\.\d+`. If a tool's release tag doesn't trivially correspond to its `--version` output, expect `Test()` to always return false and `Set()` to re-run on every apply.

## Conventions

- Install target is hardcoded to `~/.local/bin` (`Get-LocalBinDir` in the module). Don't introduce per-tool install paths.
- DSC classes use `Set-StrictMode -Version 3.0` and `$ErrorActionPreference = 'Stop'` at module scope — preserve both when editing.
- `NotConfigurable` properties on the classes (`InstalledVersion`, `TargetVersion`, `Exists`, `InPath`) exist for `Get()` output only; do not set them from YAML.
