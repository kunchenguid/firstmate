$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$wrapperText = Get-Content -Raw -LiteralPath (Join-Path $root "windows\firstmate.ps1")
$cmdText = Get-Content -Raw -LiteralPath (Join-Path $root "windows\firstmate.cmd")

$prefix = [regex]::Match($wrapperText, '(?s)\$wslArgs\s*=\s*@\((.*?)\)\s*\+\s*\$args').Groups[1].Value
if (-not $prefix) { throw "PowerShell wrapper no longer appends the original argument array" }
if ($wrapperText -notmatch '&\s+wsl\.exe\s+@wslArgs') { throw "PowerShell wrapper no longer splats the WSL argument array" }
if ($wrapperText -match 'Invoke-Expression|Start-Process|ArgumentList|-Command') { throw "PowerShell wrapper introduced string-based argument reparsing" }
foreach ($value in @('"-d", "Ubuntu"', '"-u", "firstmate"', '"--cd", "/home/firstmate/firstmate"', '"-e", "/home/firstmate/firstmate/bin/fm-primary-launch.sh"')) {
    if ($prefix -notmatch [regex]::Escape($value)) { throw "PowerShell wrapper changed fixed routing: $value" }
}
$hostile = @("percent%NAME%", 'embedded"quote', "space value", "separator;&|<>()", '$(hostile) ` literal')
$forwarded = @($hostile)
for ($i = 0; $i -lt $hostile.Count; $i++) {
    if ($forwarded[$i] -cne $hostile[$i]) { throw "PowerShell array forwarding changed hostile argument $i" }
}
if ($cmdText -match '%\*') { throw "CMD wrapper still reparses percent-star arguments" }
foreach ($token in @("--codex", "--pi", "--grok", "--claude", "--opencode")) {
    if ($cmdText -notmatch [regex]::Escape($token)) { throw "CMD wrapper omitted $token compatibility" }
}
if ($cmdText -notmatch 'accepts only one harness selector') { throw "CMD wrapper does not reject value passthrough" }
Write-Output "ok - Windows wrappers use opaque arrays and narrow CMD passthrough"
