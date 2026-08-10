# Native-Windows behavior tests for the public Codex hook adapter.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Hook = Join-Path $Root 'bin/fm-codex-hook.mjs'

function Invoke-Hook {
    param([string]$Mode, [string]$Payload)
    $output = $Payload | & node $Hook $Mode 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

function Assert-Exit {
    param($Result, [int]$Expected, [string]$Label)
    if ($Result.ExitCode -ne $Expected) {
        throw "$Label expected exit $Expected, got $($Result.ExitCode): $($Result.Output)"
    }
}

if ($env:OS -ne 'Windows_NT') {
    Write-Output 'skip - native Windows only'
    exit 0
}

$hooks = Get-Content -Raw (Join-Path $Root '.codex/hooks.json') | ConvertFrom-Json
$commands = @($hooks.hooks.SessionStart.hooks.command) + @($hooks.hooks.PreToolUse.hooks.command) + @($hooks.hooks.Stop.hooks.command)
if ($commands.Count -ne 4 -or @($commands | Where-Object { $_ -match '^node bin/fm-codex-hook\.mjs (session-start|arm|cd|stop)$' }).Count -ne 4) {
    throw '.codex/hooks.json must route SessionStart, both PreToolUse hooks, and Stop through the native adapter'
}

$start = Invoke-Hook session-start '{"source":"startup"}'
Assert-Exit $start 0 'session start'
if ($start.Output -notmatch '^NATIVE_WINDOWS_RUNTIME:') { throw 'session start hid the POSIX fleet-runtime limitation' }

Assert-Exit (Invoke-Hook arm '{"tool_input":{"command":"Get-Location"}}') 0 'unrelated command'
$arm = Invoke-Hook arm '{"tool_input":{"command":"bin/fm-watch-arm.sh &"}}'
Assert-Exit $arm 2 'backgrounded watcher arm'
if ($arm.Output -notmatch '\[watcher-background\]') { throw 'arm deny omitted its stable reason code' }

$cd = Invoke-Hook cd '{"tool_input":{"command":"cd projects/foo"}}'
Assert-Exit $cd 2 'persistent cd'
if ($cd.Output -notmatch '\[persistent-cd\]') { throw 'cd deny omitted its stable reason code' }

Assert-Exit (Invoke-Hook arm '{not-json') 0 'malformed payload'
Assert-Exit (Invoke-Hook stop '{"stop_hook_active":true}') 0 'loop-guarded stop'

$scratch = Join-Path $Root '.no-mistakes/codex-hook-windows-test'
$state = Join-Path $scratch 'state'
try {
    New-Item -ItemType Directory -Force $state | Out-Null
    New-Item -ItemType File -Force (Join-Path $state 'task.meta') | Out-Null
    $previous = $env:FM_STATE_OVERRIDE
    $env:FM_STATE_OVERRIDE = $state
    $stop = Invoke-Hook stop '{"stop_hook_active":false}'
    Assert-Exit $stop 2 'blind stop'
    if ($stop.Output -notmatch '\[turn-would-end-blind\]') { throw 'Stop deny omitted its stable reason code' }
} finally {
    $env:FM_STATE_OVERRIDE = $previous
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'ok - native Codex Stop and PreToolUse hooks'
