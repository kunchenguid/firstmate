# Orca managed WSL CLI PowerShell bridge
# firstmate-orca-wsl-bridge-patch-v1
# Work around stablyai/orca#12231: Windows PowerShell 5.1 destroys ASCII "
# in CLI arguments when forwarding via `& $OrcaLauncher @ForwardArgs`.
# - PowerShell 7+: use Standard native argument passing (no pre-escape).
# - Windows PowerShell 5.1: pre-escape ASCII " before the native splat.
# Stock Orca 1.4.179 still ships the unfixed bridge; re-apply after Orca
# reinstalls overwrite ~/.local/share/orca/orca-wsl-bridge.ps1.
[CmdletBinding(PositionalBinding=$false)]
param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$OrcaLauncher,

  [string]$WslCwd,

  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$ForwardArgs
)

$exitCode = 0
try {
  if ([string]::IsNullOrEmpty($WslCwd)) {
    Remove-Item Env:ORCA_CLI_CWD -ErrorAction SilentlyContinue
  } else {
    $env:ORCA_CLI_CWD = $WslCwd
  }

  $argsToSend = $ForwardArgs
  if ($PSVersionTable.PSVersion.Major -ge 7) {
    # PS7 can pass argv losslessly when Standard mode is on.
    $PSNativeCommandArgumentPassing = 'Standard'
  } else {
    # PS 5.1 strips unescaped ASCII double quotes on native calls (#12231).
    $escaped = New-Object System.Collections.Generic.List[string]
    foreach ($arg in $ForwardArgs) {
      if ($null -eq $arg) {
        [void]$escaped.Add($arg)
        continue
      }
      [void]$escaped.Add([regex]::Replace([string]$arg, '(\\*)"', '$1$1\"'))
    }
    $argsToSend = $escaped.ToArray()
  }

  Push-Location -LiteralPath (Split-Path -Parent $OrcaLauncher)
  & $OrcaLauncher @argsToSend
  if ($null -eq $LASTEXITCODE) {
    if (-not $?) {
      $exitCode = 1
    } else {
      $exitCode = 0
    }
  } else {
    $exitCode = $LASTEXITCODE
  }
} catch {
  Write-Error $_
  $exitCode = 1
}
exit $exitCode
