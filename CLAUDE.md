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
   - `GithubReleaseTool` — downloads a release asset from GitHub by regex pattern, extracts (`.zip` or `.tar.gz`), recursively locates each named binary inside, copies to `~/.local/bin`. **Idempotency**: `Test()` parses `<binary> --version` (regex defaults to `(\d+\.\d+\.\d+)`, overridable per resource) and compares against the resolved upstream tag (with leading `v` stripped). When `Version: latest`, both `Test()` and `Get()` hit the GitHub API — runs are network-bound.
   - `DirectBinary` — single-file download (used for `rustup-init.exe`). No version check; `Test()` is just "does the file exist."
   - `ScriptInstaller` — fetches a remote PowerShell install script and `Invoke-Expression`s it (used for `claude-code`, whose installer lives at `claude.ai/install.ps1`). Idempotency is "does `TestPath` exist."

The `DscResourcesToExport` list in `WinTools.psd1` is the contract with `dsc.exe`. New resources must be added there or DSC won't see them.

## Adding a tool

For a typical GitHub-released CLI: add a `WinTools/GithubReleaseTool` entry under the `install-tools` group in `tools.dsc.yaml`. The `AssetPattern` is a regex matched against asset filenames in the release JSON — prefer `x86_64-pc-windows-msvc` or `windows_amd64` variants, anchored with `$` to avoid matching `.sig`/`.sha256` siblings. `Binaries` is the list of executables to extract; the **first** is used for version detection.

For tools whose `--version` output doesn't match `\d+\.\d+\.\d+`, set `VersionRegex` on the resource. For tools whose release tag doesn't trivially correspond to `--version` output, expect `Test()` to always return false and `Set()` to re-run on every apply — there's no per-tool override for that mismatch today.

## Conventions

- Install target is hardcoded to `~/.local/bin` (`Get-LocalBinDir` in the module). Don't introduce per-tool install paths.
- DSC classes use `Set-StrictMode -Version 3.0` and `$ErrorActionPreference = 'Stop'` at module scope — preserve both when editing.
- `NotConfigurable` properties on the classes (`InstalledVersion`, `TargetVersion`, `Exists`, `InPath`) exist for `Get()` output only; do not set them from YAML.
