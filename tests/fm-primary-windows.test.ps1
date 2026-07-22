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
if ($cmdText -match '%\*|%~[0-9]') { throw "CMD refusal shim expands untrusted arguments" }
if ($cmdText -notmatch 'run firstmate from PowerShell') { throw "CMD refusal does not name the safe entrypoint" }
if ($cmdText -match '^\s*(powershell(?:\.exe)?|wsl\.exe)\b') { throw "CMD refusal shim unexpectedly delegates arguments" }
Write-Output "ok - PowerShell preserves opaque argv and CMD refuses without parsing it"
