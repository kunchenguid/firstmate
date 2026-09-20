# Explicit experimental launcher; does not install hooks or change user settings.
# -BuildOnly compiles the code-owned provider after all its sessions have stopped.
# Launch requires an empty-fleet temporary home and a local Docker image with jq.
<#
.SYNOPSIS
Build or explicitly launch the experimental native Windows Codex host.
.DESCRIPTION
Builds the native provider or launches it with explicit experimental opt-in.
See docs/native-windows-codex.md for setup, safety boundaries, and supported limits.
.PARAMETER Experimental
Required consent to launch this temporary-home-only candidate.
.PARAMETER BuildOnly
Compile the local provider and source stamp without launching a session.
.PARAMETER VerifyOnly
Connect startup and app-server without starting any model turns.
.PARAMETER OperationalHome
The Windows path to the temporary operational home.
.PARAMETER JqImage
An existing local Docker image containing jq and GNU timeout. No image is pulled.
Read-only helper containers self-expire even if their native client is stopped.
#>
[CmdletBinding(PositionalBinding=$false)]
param([switch]$Experimental,[switch]$BuildOnly,[switch]$VerifyOnly,[string]$OperationalHome,[string]$JqImage)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$names=@('NativeOwner','NativeHomeLease','NativeReceiptJournal','NativeAcknowledgementEvidence','NativeOperationLifetime','NativeOperations','NativeLauncher')
$sources=@($names | ForEach-Object { Join-Path $PSScriptRoot ('native-owner/'+$_+'.cs') })
$fingerprint=($sources | ForEach-Object {(Get-FileHash $_ -Algorithm SHA256).Hash}) -join ':'
$binary=Join-Path $PSScriptRoot 'fm-native-owner.exe'
$stamp=Join-Path $PSScriptRoot 'fm-native-owner.build'
if ($BuildOnly) {
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('fm-native-build-'+[guid]::NewGuid().ToString('N')+'.exe')
    Add-Type -Path $sources -OutputAssembly $temporary -OutputType ConsoleApplication -ReferencedAssemblies System.dll,System.Core.dll,System.Web.Extensions.dll
    # Windows refuses replacement of a running image; never bypass that refusal.
    if (Test-Path $binary) { [IO.File]::Delete($binary) }
    [IO.File]::Move($temporary,$binary)
    [IO.File]::WriteAllText($stamp,$fingerprint)
    Write-Output 'Native candidate compiled; no session started.'
    exit 0
}
if (!$Experimental) { throw 'Explicit -Experimental opt-in is required; production use remains disabled.' }
if (!$OperationalHome) { throw '-OperationalHome must name a temporary empty-fleet home.' }
if (!$JqImage -or $JqImage -notmatch '^[A-Za-z0-9][A-Za-z0-9./:_@-]+$') { throw '-JqImage must name an existing local Docker image containing jq.' }
if (!(Test-Path $binary) -or !(Test-Path $stamp) -or [IO.File]::ReadAllText($stamp) -ne $fingerprint) { throw 'Provider missing or out of date; run -BuildOnly after stopping native sessions.' }
& docker image inspect $JqImage *> $null
if ($LASTEXITCODE -ne 0) { throw 'The selected Docker jq image is not available locally; no image was pulled.' }
$previous=$env:FM_NATIVE_JQ_IMAGE
$previousVerify=$env:FM_NATIVE_VERIFY_ONLY
try {
    $env:FM_NATIVE_JQ_IMAGE=$JqImage
    $env:FM_NATIVE_VERIFY_ONLY=if ($VerifyOnly) { '1' } else { '' }
    # Direct inherited handles preserve interactive input; PowerShell's native
    # pipeline adapter can buffer piped input until EOF instead of forwarding it.
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$binary
    $info.Arguments='launch --experimental "'+[IO.Path]::GetFullPath($OperationalHome).TrimEnd('\')+'"'
    $info.UseShellExecute=$false
    $process=[Diagnostics.Process]::Start($info)
    try { $process.WaitForExit(); $result=$process.ExitCode } finally { $process.Dispose() }
    exit $result
} finally { $env:FM_NATIVE_JQ_IMAGE=$previous; $env:FM_NATIVE_VERIFY_ONLY=$previousVerify }
