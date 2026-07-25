# Harness adapter verification

This file owns active, version-scoped empirical evidence for ordinary worker harness guarantees that do not belong to a session-provider backend or primary-supervision adapter.

## Cursor Agent CLI

Verified on 2026-07-25 with Cursor Agent CLI `2026.07.23-e383d2b` on Linux x64 under tmux.
The launcher initially reported `2026.05.28-a70ca7c`, then updated before final verification, so only the later version supports the maintained evidence below.

### Identity, authentication, and live model IDs

```sh
cursor-agent --version
cursor-agent status
cursor-agent models | grep -E '^(composer-2\.5|cursor-grok-4\.5-low) - '
```

```text
2026.07.23-e383d2b
✓ Logged in as <redacted>
composer-2.5 - Composer 2.5 (current)
cursor-grok-4.5-low - Cursor Grok 4.5 Low
```

The account model catalog is intentionally not copied into Firstmate.
Operators run `cursor-agent models` and preserve the selected ID exactly.

### Direct model selection

Both probes used a task-owned scratch directory and read-only ask mode.

```sh
cursor-agent --workspace "$SCRATCH" --print --trust --mode ask \
  --model composer-2.5 --output-format stream-json \
  'Reply with exactly COMPOSER_OK and do not use tools.' \
  | jq -c 'select(.type=="system" or .type=="result") \
    | if .type=="system" then {type,model,apiKeySource,permissionMode} \
      else {type,subtype,is_error,result} end'
```

```json
{"type":"system","model":"Composer 2.5","apiKeySource":"login","permissionMode":"default"}
{"type":"result","subtype":"success","is_error":false,"result":"COMPOSER_OK"}
```

```sh
cursor-agent --workspace "$SCRATCH" --print --trust --mode ask \
  --model cursor-grok-4.5-low --output-format stream-json \
  'Reply with exactly CURSOR_GROK_OK and do not use tools.' \
  | jq -c 'select(.type=="system" or .type=="result") \
    | if .type=="system" then {type,model,apiKeySource,permissionMode} \
      else {type,subtype,is_error,result} end'
```

```json
{"type":"system","model":"Cursor Grok 4.5 Low","apiKeySource":"login","permissionMode":"default"}
{"type":"result","subtype":"success","is_error":false,"result":"CURSOR_GROK_OK"}
```

### Supervised interactive lifecycle

The first supervised smoke used `fm-spawn.sh`'s raw-launch escape hatch in a disposable Firstmate task copy.
The final current-version smoke used the same positional prompt shape as the adapter:

```sh
cursor-agent --force --trust --model composer-2.5 \
  'Reply with exactly INTERACTIVE_OK and do not use tools.'
```

The TUI showed all of the following without a workspace-trust dialog:

```text
Cursor Agent
v2026.07.23-e383d2b
Composer 2.5                                      Run Everything
```

The supervised task separately proved the canonical positional launch brief reached the model, a normal `fm-send` steer returned `PATCHED_STEER_OK`, and `/no-mistakes` appeared in slash autocomplete.
During a bounded `sleep 30` tool call, the busy footer showed `ctrl+c to stop`.
One `Ctrl+C` stopped the turn and restored its prompt into the composer with `Press Ctrl+C again to exit`; one `Ctrl+U` cleared it safely for a replacement steer.
`/exit` returned to the shell and printed this resume form:

```text
To resume this session: agent --resume=<chat-id>
```

The following command restored the same transcript and retained Composer 2.5:

```sh
cursor-agent --force --trust --resume=<chat-id>
```

The live tmux process name while running was `cursor-agent`, and it returned to `bash` after `/exit`.
Cursor placed its `→ Add a follow-up` composer several rows above tmux's reported blank cursor row.
The current shared classifier returned `empty` for that idle placeholder, `pending` for real text after `→`, and `unknown` after the process returned to the shell.

### Supported boundary

The verified launch is an ordinary worker/scout adapter on tmux, Zellij, Orca, and cmux.
Cursor is not a verified primary harness or persistent secondmate and is deliberately absent from primary detection, session-lock matching, turn-end guards, and rendered supervision protocols.
Herdr is also excluded because its native agent registration is required for safe liveness and recovery and was not verified for Cursor.
Cursor exposes no verified per-turn hook, so task status writes and session-provider pane polling remain the completion path.
`fm-spawn` checks `cursor-agent` availability and authenticated status before endpoint creation.
The launch uses `--force` for unattended built-in tools and commands, but deliberately omits `--approve-mcps` because MCP server approval is a separate trust boundary.
Cursor exposes no separate effort flag; exact model IDs and parameterized model strings carry model-specific effort.
