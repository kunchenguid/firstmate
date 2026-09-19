# Build an isolated test assembly and home; never install the native provider.
# Usage: powershell -NoProfile -File tests/fixtures/native-owner/Build.ps1
# Requires native Git symlinks and the pre-existing Docker validation image.
$ErrorActionPreference = 'Stop'
$env:MSYS = 'winsymlinks:nativestrict'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$root = Join-Path ([IO.Path]::GetTempPath()) ('fm-native-candidate-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
$copy = Join-Path $root 'firstmate'
& git -c core.symlinks=true clone --quiet --no-local --single-branch $repo $copy
if ($LASTEXITCODE -ne 0) { throw 'Disposable clone failed' }
Copy-Item -Path (Join-Path $repo 'bin/*') -Destination (Join-Path $copy 'bin') -Recurse -Force
Copy-Item -Path (Join-Path $repo 'tests/fixtures/native-owner/*') -Destination (Join-Path $copy 'tests/fixtures/native-owner') -Recurse -Force
$binary = Join-Path $copy 'bin/SessionProbe.exe'
$sources = @((Join-Path $repo 'bin/native-owner/NativeOwner.cs'), (Join-Path $repo 'bin/native-owner/NativeHomeLease.cs'), (Join-Path $PSScriptRoot 'NativeDriver.cs'), (Join-Path $repo 'bin/native-owner/NativeReceiptJournal.cs'), (Join-Path $PSScriptRoot 'ReceiptTests.cs'))
$sources += @((Join-Path $repo 'bin/native-owner/NativeOperations.cs'), (Join-Path $repo 'bin/native-owner/NativeAcknowledgementEvidence.cs'), (Join-Path $repo 'bin/native-owner/NativeOperationLifetime.cs'), (Join-Path $PSScriptRoot 'OperationLifetimeTests.cs'))
Add-Type -Path $sources -OutputAssembly $binary -OutputType ConsoleApplication -ReferencedAssemblies System.dll,System.Core.dll,System.Web.Extensions.dll
& $binary operation-lifetime-contention
if ($LASTEXITCODE -ne 0) { throw 'Operation marker publication tests failed' }
& $binary receipt-tests
$receiptExit = $LASTEXITCODE
if ($receiptExit -ne 0) { throw 'Durable receipt lifecycle tests failed' }
& $binary environment-tests
if ($LASTEXITCODE -ne 0) { throw 'Native environment filtering tests failed' }
$invalidState = Join-Path $root 'missing-state'
$savedErrorPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $invalidOwner = @(& $binary owner alive $invalidState 'native:00000000000000000000000000000000' trailing 2>&1)
    if ($LASTEXITCODE -ne 2 -or ($invalidOwner -join "`n") -notmatch 'usage: NativeOwner') { throw 'Owner CLI accepted a trailing argument' }
    $invalidOwner = @(& $binary owner harness $invalidState trailing 2>&1)
    if ($LASTEXITCODE -ne 2 -or ($invalidOwner -join "`n") -notmatch 'usage: NativeOwner') { throw 'Owner CLI accepted an ID for a fixed-shape verb' }
} finally {
    $ErrorActionPreference = $savedErrorPreference
}
# Exercise the real opt-in consumers, including local changes before commit.
foreach ($name in @('exercise.sh','notification-check.sh','notification-ack.sh')) { Copy-Item (Join-Path $PSScriptRoot $name) (Join-Path $copy $name) }
Copy-Item (Join-Path $PSScriptRoot 'AppHost.mjs') (Join-Path $copy 'AppHost.mjs')
foreach ($module in @('codex-tool-gate.mjs','host-lifecycle.mjs','app-server-policy.mjs')) { Copy-Item (Join-Path $repo ('bin/native-owner/' + $module)) (Join-Path $copy $module) }
Copy-Item $binary (Join-Path $copy 'bin/fm-native-owner.exe')
New-Item -ItemType Directory (Join-Path $root 'tools') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'jq') (Join-Path $root 'tools/jq')
$state = Join-Path $repo 'data/native-candidate-validation'
New-Item -ItemType Directory -Force $state | Out-Null
@{ root=$root; code=$copy; binary=$binary; repo=$repo; hashes=@($sources | ForEach-Object { @{ file=$_; hash=(Get-FileHash $_).Hash } }) } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $state 'build.json')
Write-Output $binary
