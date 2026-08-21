# fm-update.ps1 - run Firstmate's updater with Git Bash on Windows.
#
# Usage: fm-update.ps1 [--help]
# Resolves Git Bash from the Git for Windows installation instead of invoking
# the ambient `bash`, which may be the WSL launcher even when WSL is not set up.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$UpdaterArguments
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "fm-windows-git-bash.ps1")

$updaterPath = Join-Path $PSScriptRoot "fm-update.sh"
if (-not (Test-Path -LiteralPath $updaterPath -PathType Leaf)) {
    throw "Firstmate updater was not found at '$updaterPath'."
}

$gitBashPath = Resolve-FirstmateGitBash
& $gitBashPath $updaterPath @UpdaterArguments
exit $LASTEXITCODE
