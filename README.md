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
- [RTK](https://github.com/rtk-ai/rtk#installation) (`rtk`) — reduces CLI output for AI agents
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

Every run prints `SUCCESS` or `FAIL`, its log location, and a final-state table. `set` and `get` show each resource's status, installed and desired versions, and file/plugin/PATH state; `test` shows whether each resource matches its desired state. Missing files, version mismatches, and unreadable versions are called out separately from whether DSC completed successfully. Failed runs show any reported final state as partial; unreported state is unavailable. DSC's trace output and full result JSON are saved in a timestamped log under `logs/` (ignored by Git).

The log records each resource's `Get`, `Test`, and `Set` calls, the tool name and pinned version/URL, installation stages, errors with PowerShell stack traces, DSC output, and DSC's exit code. Resource logging works inside the PowerShell adapter's child processes.

```powershell
# More detailed DSC tracing, with a chosen log path (appends if it exists)
./install.ps1 -TraceLevel debug -LogPath ./logs/debug.log

# Stream DSC diagnostics to the terminal as well
./install.ps1 -TraceLevel debug -Verbose

# Return DSC JSON for scripts, without the terminal summary
./install.ps1 -Action get -OutputFormat json | ConvertFrom-Json

# Find the resource and stage that failed in the latest default log
$log = Get-ChildItem ./logs/install-*.log | Sort-Object LastWriteTime | Select-Object -Last 1
Select-String -LiteralPath $log.FullName -Pattern 'FAILED|download|extract|locate/copy'
```

Failures include the resource name and stage in the terminal, for example `WinTools/DirectArchive Name='fzf' ... Set Stage='download https://...' failed: ... 404 (Not Found)`. The wrapper preserves DSC's nonzero exit code. A successful `test` command can still report resources that need attention; its exit code describes DSC execution, while the table describes the resource state. Invalid/missing result JSON or a result with `hadErrors: true` is treated as a failure even if DSC exits zero. `-TraceLevel trace` enables the most detailed DSC diagnostics in the log. Logs remain on disk until you remove them.

Offline logging integration checks (requires DSC and PowerShell 7.2+): `pwsh -NoProfile -File ./tests/Logging.Tests.ps1`. These use a temporary module copy with simulated downloads; they do not install real tools.

Offline output checks: `pwsh -NoProfile -File ./tests/Output.Tests.ps1`. These cover final-state summaries, version/PATH drift, clean JSON output, failure exit codes, and appended logs using a native DSC command fixture.

Offline dprint regression checks: `pwsh -NoProfile -File ./tests/DprintPlugin.Tests.ps1`. These verify native stderr handling, exit codes, and recognition of npm and legacy plugin entries through the DSC adapter with a temporary command fixture.

## Adding or updating a tool

Run `./check-updates.ps1 -DryRun` to check GitHub releases without changing the playbook. Run `./check-updates.ps1` to update pins, review `git diff -- tools.dsc.yaml`, then run `./install.ps1` to install them. The checker verifies that every expected asset for a repository exists in its latest release before changing that repository's pins. Missing or renamed assets are reported as `BLOCKED` and require review; it never guesses a replacement platform or asset. This also detects missing assets when the pinned tag already matches the latest release.

The checker's exit codes are `0` for up to date, `1` for updates available/applied, and `2` for blocked assets or API errors. Other repositories with valid assets can still be updated when one is blocked. Non-GitHub sources are skipped. Offline regression checks: `pwsh -NoProfile -File ./tests/CheckUpdates.Tests.ps1`.

Tools are pinned to specific release-download URLs in [`tools.dsc.yaml`](tools.dsc.yaml). To bump a version, edit both `Url` and `Version` on the resource — the next `set` will re-install because `Test()` compares the pinned `Version` against `<binary> --version`.

See [CLAUDE.md](CLAUDE.md) for architecture details and the full set of resource types available in the `WinTools` module.
