# Windows WSL launcher

The repository-root `firstmate.bat` opens Firstmate's Herdr-backed harness menu from Windows.
Double-click the file in Explorer, or run it from Command Prompt or PowerShell.

## Prerequisites

- Install WSL with `wsl --install` and finish the distribution's first-run setup.
- Install Firstmate's Linux-side prerequisites, Herdr, and the harnesses you want to use inside that WSL distribution.
- Keep the Firstmate repository somewhere the distribution can read.
  Windows drive paths, including paths containing spaces, are supported through WSL's `--cd` mapping.

The bridge uses the current default WSL distribution.
If more than one distribution is installed, select the one that contains Firstmate's dependencies before launching:

```powershell
wsl --list --verbose
wsl --set-default Ubuntu
```

## Launch

Double-click `firstmate.bat` at the repository root.
The window opens the existing harness menu, and the selected session follows the same Herdr launch and attach flow as `bin/fm-launch.sh`.
If startup fails, the window prints the underlying error, reports the exit status, gives the WSL installation repair when relevant, and stays open for acknowledgment.

The batch entry accepts the launcher's existing arguments and returns its exit status:

```bat
firstmate.bat --print-menu
firstmate.bat --verbose
firstmate.bat --help
```

The bridge starts one WSL process, sets its working directory to the batch file's repository, selects `/bin/bash` directly, and enters through `bin/fm-wsl-entry.sh`.
The WSL helper resolves the repository from its own location and replaces itself with `bin/fm-launch.sh`, so the current Windows directory and shell profiles cannot redirect the launch.

## Troubleshooting

If Windows says WSL is missing, run `wsl --install`, restart Windows if prompted, finish the distribution setup, and retry.
If the helper reports that `bin/fm-launch.sh` is absent, update the repository before retrying.
If the menu reports a Herdr or harness problem, install or configure that dependency inside the default WSL distribution rather than only on Windows.

## Maintaining this file

This file is the operator-facing owner of the Windows-to-WSL launcher bridge.
Keep menu behavior and Herdr lifecycle details with their existing script owners, and keep exact bridge mechanics in `firstmate.bat` and `bin/fm-wsl-entry.sh`.
