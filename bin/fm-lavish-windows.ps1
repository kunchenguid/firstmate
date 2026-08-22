param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('open', 'poll', 'end', 'export', 'share', 'stop', 'doctor', 'setup')]
  [string]$Action,

  [Parameter(Position = 1)]
  [string]$Artifact
)

$ErrorActionPreference = 'Stop'
$ExtraArgs = @()
if ($env:FM_LAVISH_WINDOWS_ARGV_JSON) {
  $DecodedArgs = @(ConvertFrom-Json -InputObject $env:FM_LAVISH_WINDOWS_ARGV_JSON)
  foreach ($Arg in $DecodedArgs) {
    if ($Arg -isnot [string]) {
      throw 'Lavish forwarded argv must contain strings only'
    }
    $ExtraArgs += [string]$Arg
  }
}
$Port = 4388
$env:LAVISH_AXI_PORT = [string]$Port
$WorkDir = $env:USERPROFILE

function Get-LavishCommand {
  $Command = Get-Command 'lavish-axi.cmd' -ErrorAction SilentlyContinue
  if (-not $Command) {
    throw 'Windows lavish-axi is not installed. From Firstmate run: bin/fm-bootstrap.sh install lavish-axi'
  }
  return $Command.Source
}

function Invoke-LavishCommand([string]$Lavish, [string[]]$Arguments) {
  $Node = Get-Command 'node.exe' -ErrorAction SilentlyContinue
  if (-not $Node) {
    throw 'Windows node.exe is unavailable. Install Node.js for Windows, then rerun: bin/fm-bootstrap.sh install lavish-axi'
  }
  $env:FM_LAVISH_WINDOWS_COMMAND = $Lavish
  $env:FM_LAVISH_WINDOWS_NATIVE_ARGV_JSON = ConvertTo-Json -Compress -InputObject @($Arguments)
  $Launcher = @'
const fs = require('fs');
const path = require('path');
const childProcess = require('child_process');
const command = process.env.FM_LAVISH_WINDOWS_COMMAND;
const packagePath = path.join(path.dirname(command), 'node_modules', 'lavish-axi', 'package.json');
const packageData = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
const bin = typeof packageData.bin === 'string' ? packageData.bin : packageData.bin['lavish-axi'];
const result = childProcess.spawnSync(process.execPath, [path.resolve(path.dirname(packagePath), bin), ...JSON.parse(process.env.FM_LAVISH_WINDOWS_NATIVE_ARGV_JSON)], { encoding: 'utf8' });
if (result.stdout) process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);
if (result.error) throw result.error;
process.exit(result.status === null ? 1 : result.status);
'@
  & $Node.Source -e $Launcher
}

function Get-LavishVersion([string]$Lavish) {
  $Output = @(Invoke-LavishCommand $Lavish @('--version') 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw 'Windows lavish-axi did not report its version'
  }
  $Match = [regex]::Match(($Output -join "`n"), '(?i)v?(\d+)\.(\d+)\.(\d+)')
  if (-not $Match.Success) {
    throw "Cannot parse the Windows lavish-axi version: $($Output -join ' ')"
  }
  return [version]::new(
    [int]$Match.Groups[1].Value,
    [int]$Match.Groups[2].Value,
    [int]$Match.Groups[3].Value
  )
}

function Test-LavishPort {
  try {
    $Client = [System.Net.Sockets.TcpClient]::new()
    $Task = $Client.ConnectAsync('127.0.0.1', $Port)
    if (-not $Task.Wait(400)) {
      $Client.Dispose()
      return $false
    }
    $Client.Dispose()
    return $true
  } catch {
    return $false
  }
}

function Ensure-LavishServer([string]$Lavish) {
  if (Test-LavishPort) {
    return
  }

  $ServerArgs = @('server', '--port', [string]$Port)
  Start-Process -FilePath $Lavish -ArgumentList $ServerArgs -WorkingDirectory $WorkDir -WindowStyle Hidden | Out-Null
  foreach ($Attempt in 1..60) {
    Start-Sleep -Milliseconds 200
    if (Test-LavishPort) {
      return
    }
  }
  throw "Windows Lavish server did not start on 127.0.0.1:$Port"
}

Set-Location $WorkDir

if ($Action -eq 'setup') {
  $Npm = Get-Command 'npm.cmd' -ErrorAction SilentlyContinue
  if (-not $Npm) {
    throw 'Windows npm.cmd is unavailable. Install Node.js for Windows, then rerun: bin/fm-bootstrap.sh install lavish-axi'
  }
  & $Npm.Source install -g lavish-axi
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
  $Lavish = Get-LavishCommand
  Invoke-LavishCommand $Lavish @('setup', 'hooks')
  exit $LASTEXITCODE
}

$Lavish = Get-LavishCommand

if ($Action -eq 'doctor') {
  $Version = Get-LavishVersion $Lavish
  if ($Artifact) {
    $Minimum = [version]$Artifact
    if ($Version -lt $Minimum) {
      throw "Windows lavish-axi $Version is older than required $Minimum. Run: bin/fm-bootstrap.sh install lavish-axi"
    }
  }
  exit 0
}

if ($Action -eq 'stop') {
  Invoke-LavishCommand $Lavish (@('stop') + $ExtraArgs)
  exit $LASTEXITCODE
}

if (-not $Artifact) {
  throw "Artifact path is required for action '$Action'"
}

Ensure-LavishServer $Lavish

switch ($Action) {
  'open' {
    $env:LAVISH_AXI_NO_OPEN = '1'
    $Output = @(Invoke-LavishCommand $Lavish (@($Artifact) + $ExtraArgs) 2>&1)
    $ExitCode = $LASTEXITCODE
    $Output | ForEach-Object { Write-Output $_ }
    if ($ExitCode -ne 0) {
      exit $ExitCode
    }

    $Url = $null
    $Status = $null
    foreach ($Line in $Output) {
      if ([string]$Line -match '^\s*url:\s*"([^"]+)"\s*$') {
        $Url = $Matches[1]
      }
      if ([string]$Line -match '^\s*status:\s*"?([^"\s]+)"?\s*$') {
        $Status = $Matches[1]
      }
    }
    if (-not $Url) {
      throw 'Windows lavish-axi did not return a session URL'
    }
    if (($Status -ne 'user-ended') -and ($ExtraArgs -notcontains '--no-open')) {
      Start-Process $Url | Out-Null
    }
  }
  'poll' {
    Invoke-LavishCommand $Lavish (@('poll', $Artifact) + $ExtraArgs)
    exit $LASTEXITCODE
  }
  'end' {
    Invoke-LavishCommand $Lavish (@('end', $Artifact) + $ExtraArgs)
    exit $LASTEXITCODE
  }
  'export' {
    Invoke-LavishCommand $Lavish (@('export', $Artifact) + $ExtraArgs)
    exit $LASTEXITCODE
  }
  'share' {
    Invoke-LavishCommand $Lavish (@('share', $Artifact) + $ExtraArgs)
    exit $LASTEXITCODE
  }
}
