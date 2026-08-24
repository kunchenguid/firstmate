# Windows transport for GitHub Copilot CLI repository hooks.
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $HookArguments
)

. (Join-Path $PSScriptRoot "fm-windows-git-bash.ps1")

try {
    $bash = Resolve-FirstmateGitBash
}
catch {
    exit 0
}

$payload = [Console]::In.ReadToEnd()
$script = Join-Path $PSScriptRoot "fm-ghcp-hook.sh"
if ($payload) {
    $payload | & $bash $script @HookArguments
}
else {
    & $bash $script @HookArguments
}
exit $LASTEXITCODE
