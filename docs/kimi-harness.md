# Kimi Code CLI harness verification

This record covers the Kimi crew-harness integration verified on 2026-07-23 with Kimi Code CLI 0.29.0.
The probes ran in an isolated firstmate task worktree and in a dedicated temporary tmux server.
No real crewmate task was dispatched.
No Kimi authentication or configuration state was changed.

## CLI, model, and launch axes

Command:

```text
kimi --version
```

Exact output:

```text
0.29.0
```

Command:

```text
kimi provider list --json
```

Exact K3 object from the output:

```json
"kimi-code/k3": {
  "provider": "managed:kimi-code",
  "model": "k3",
  "maxContextSize": 1048576,
  "capabilities": [
    "thinking",
    "always_thinking",
    "image_in",
    "video_in",
    "tool_use"
  ],
  "displayName": "K3",
  "supportEfforts": [
    "low",
    "high",
    "max"
  ],
  "defaultEffort": "high"
}
```

Command:

```text
kimi --effort high
```

Exact output:

```text
error: unknown option '--effort'
```

Command:

```text
kimi -p 'Reply with exactly: OK' -m k3:max
```

Exact output:

```text
error: failed to run prompt: config.invalid: Model "k3:max" is not configured in config.toml. Add a [models."k3:max"] entry with max_context_size.
See log: /Users/raphaelthiel/.kimi-code/logs/kimi-code.log
```

Command:

```text
kimi --auto 'Reply exactly OK'
```

Exact output:

```text
unknown command 'Reply exactly OK'. See 'kimi --help'.
```

The interactive launch shape is therefore `kimi --auto -m kimi-code/k3` with no positional prompt and no effort flag.
The CLI help describes `--auto` exactly as `Start in auto permission mode: fully autonomous, the agent will not ask questions.`
The authoritative live probe also verified a file write without a permission question and no first-run trust dialog.

## TUI, busy states, and commands

Command:

```text
kimi --auto -m kimi-code/k3
```

Exact startup lines:

```text
Session:   session_1bbff60b-3c48-4c37-985a-900f031367b2
Model:     K3
Version:   0.29.0
│ >                                                                          │
auto  K3 thinking: high  …/firstmate-7bab20/1/firstmate  fm/kimi-integrate
                                                             context: 0% (0/1M)
```

The first cheap prompt was:

```text
Use the shell tool to run printf KIMI_TOOL_PROBE, then reply exactly DONE.
```

Exact observed busy and tool-state lines:

```text
⠋ thinking...
● Running a command
$ printf KIMI_TOOL
● Ran a command
$ printf KIMI_TOOL_PROBE
KIMI_TOOL_PROBE
⠋ working...
```

During model waits between those verb states, the active spinner rendered moon phases followed by `· Tip: /init: generate AGENTS.md`.
The default busy regex covers the active verb states `thinking...`, `working...`, and `Running a command` without depending on a particular spinner glyph or matching the non-state `Tip:` text.

The verified interrupt is one Escape, which produced:

```text
Interrupted by user
```

Typing `/quit` and submitting it produced:

```text
Bye!

To resume this session: kimi -r session_1bbff60b-3c48-4c37-985a-900f031367b2
```

`kimi --help` also advertised these exact resume options:

```text
-S, --session [id]            Resume a session. With ID: resume that session. Without ID:
                              interactively pick.
-c, --continue                Continue the previous session for the working directory. (default:
                              false)
```

## Process ancestry

The live Kimi pane process was inspected with:

```text
ps -o pid=,ppid=,comm=,args= -p "$KIMI_PANE_PID"
```

Exact output:

```text
31743 31742 kimi-code kimi-code
```

The authoritative in-agent environment probe found no Kimi-specific child environment marker.
`fm-harness.sh` therefore detects the `kimi` or `kimi-code` command in process ancestry and also recognizes a `kimi-code` script path under a generic interpreter.

## Slash autocomplete and `fm-send`

A temporary task meta record with `harness=kimi` targeted a dedicated tmux Kimi pane.
The command was:

```text
FM_HOME="$VERIFY_HOME" FM_SEND_SETTLE=0 bin/fm-send.sh verify '/check-kimi-code-docs Reply exactly POPUP_OK without tools.'
```

Exact relevant pane output:

```text
▶ Activated skill: check-kimi-code-docs
  Reply exactly POPUP_OK without tools.
● POPUP_OK
```

In the same tmux setup, typing `/quit` displayed this popup:

```text
│ > /quit                                                                    │
│   → exit (quit, q)  Exit the application                                   │
```

The first tmux Enter selected the popup item and cleared the visible composer without exiting.
The second Enter exited the TUI.
`fm-send` therefore enforces a minimum of two Enter attempts for slash-prefixed Kimi messages while still typing the text only once.
The post-fix live `/quit` probe printed:

```text
KIMI_QUIT_VERIFY=PASS_SESSION_EXITED
```

## Composer classification

Kimi's idle input row is:

```text
│ >                                                                          │
```

The `>` glyph is shell-like only when bare.
Inside matching side borders it is Kimi's agent composer prompt and must classify as `empty`.
A bordered row such as `│ > /quit │` must classify as `pending`.
The shared `fm_composer_classify_bordered_row` function owns this distinction, and both tmux and Herdr delegate the Kimi-shaped row to it.

## Turn-end hook gap

Kimi 0.29.0 supports global `[[hooks]]` configuration in `~/.kimi-code/config.toml`, including the `Stop` event.
That file is shared Kimi state and may already contain unrelated user or Orca entries.
This integration does not rewrite it because a safe, idempotent, ownership-preserving TOML merge has not been live-verified.
Kimi crew tasks rely on busy-state and stale-pane detection until that guarded installer exists.
