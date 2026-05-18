# win-tools

Declarative installer for a fixed set of Windows CLI tools, built on [DSC v3](https://github.com/PowerShell/DSC). Drops binaries into `%USERPROFILE%\.local\bin` and ensures that directory is on the user `Path`.

## Tools installed

- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`)
- [fd](https://github.com/sharkdp/fd)
- [fzf](https://github.com/junegunn/fzf)
- [just](https://github.com/casey/just)
- [uv](https://github.com/astral-sh/uv) (`uv`, `uvx`)
- [gh](https://github.com/cli/cli) — GitHub CLI
- [rustup-init](https://rustup.rs/)
- [dprint](https://github.com/dprint/dprint) (+ markdown plugin)
- [beads](https://github.com/gastownhall/beads) (`bd`)
- [claude-code](https://claude.ai/install.ps1)

## Prerequisites

- PowerShell 7.2+
- `dsc.exe` (DSC v3) on `PATH` — grab a release from [PowerShell/DSC](https://github.com/PowerShell/DSC/releases)

Optionally set `$env:GITHUB_TOKEN` before running to bump the GitHub API rate limit from 60/hr to 5000/hr. With the current config (all tools use direct release-download URLs), this is rarely needed.

## Usage

```powershell
# Install / update everything to the pinned versions
./install.ps1                # default action = set
./install.ps1 -Action set

# Check current state vs desired state (no changes)
./install.ps1 -Action test

# Read current state of each resource
./install.ps1 -Action get
```

## Adding or updating a tool

Tools are pinned to specific release-download URLs in [`tools.dsc.yaml`](tools.dsc.yaml). To bump a version, edit both `Url` and `Version` on the resource — the next `set` will re-install because `Test()` compares the pinned `Version` against `<binary> --version`.

See [CLAUDE.md](CLAUDE.md) for architecture details and the full set of resource types available in the `WinTools` module.
