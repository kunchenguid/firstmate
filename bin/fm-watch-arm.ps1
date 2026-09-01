# Windows entry point for a Copilot CLI tracked asynchronous watcher task.
#
# Run this script as the sole PowerShell command with the tool's native async
# mode.
# It resolves Git for Windows Bash structurally and preserves the shell
# watcher's output and exit status for Copilot's completion notification.
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $WatchArguments
)

. (Join-Path $PSScriptRoot "fm-windows-git-bash.ps1")

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

try {
    $gitBashPath = Resolve-FirstmateGitBash
}
catch {
    Write-Error $_
    exit 1
}

$watchScript = Join-Path $PSScriptRoot "fm-watch-arm.sh"
& $gitBashPath $watchScript @WatchArguments
exit $LASTEXITCODE
