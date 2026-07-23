# Cursor Agent crewmate harness

Cursor Agent is a verified Firstmate runtime for ordinary crewmates and scouts.
It is not a verified primary firstmate or persistent secondmate harness.
The launch, profile, and task-local trust mechanics live in `bin/fm-spawn.sh`.
The operational recovery facts live in `.agents/skills/harness-adapters/SKILL.md`.

## Supported launch

Firstmate invokes the explicit `agent` entry point and launches an interactive session with this shape:

```sh
agent --force --trust --workspace "<isolated-task-directory>" --model "<mapped-model-id>" "<launch-brief>"
```

`--force` is the captain-approved unattended command posture for Firstmate-launched Cursor workers.
`--trust` is scoped by the accompanying `--workspace` argument to the isolated task directory.
The adapter never edits `~/.cursor/cli-config.json` or any other global Cursor setting.
A positional prompt starts the first turn and the TUI stays open for follow-ups.

Cursor has no standalone effort flag.
When no explicit model is supplied, Firstmate maps its effort axis to the empirically listed Cursor Grok 4.5 models:

| Firstmate effort | Cursor model id |
|---|---|
| `low` | `cursor-grok-4.5-low` |
| `medium` | `cursor-grok-4.5-medium` |
| `high` | `cursor-grok-4.5-high` |
| `xhigh` | `cursor-grok-4.5-high` |
| `max` | `cursor-grok-4.5-high` |

The Cursor Grok 4.5 catalog has no `xhigh` or `max` entry, so those values cap at its highest listed model instead of becoming an invented flag or model id.
Any explicitly requested model — inside or outside the Cursor Grok 4.5 family — always wins unchanged; effort never remaps it.

## Supervision signals

The busy-only ASCII hint is `ctrl+c to stop`.
The TUI also renders `Working` and `Thinking N tokens`, but those words are less specific in captured transcript text.
The idle composer uses the agent-only `→` glyph with `Add a follow-up` after a completed turn and `Plan, search, build anything` before the first turn.
The shared composer classifier recognizes that glyph and both placeholders without weakening the rule that a bare shell prompt is never safe for injection.

No Cursor per-turn hook is verified.
Cursor workers therefore use Firstmate's ordinary pane hashing, busy hint, and stable-idle monitoring path.

## Interrupt, exit, and resume

Cursor advertises `Ctrl+C` as the active-turn interrupt.
An automated PTY probe sent one `Ctrl+C` while token counts were increasing, but generation continued to completion.
Recovery must therefore send at most one interrupt, re-read the pane, and let the turn settle before redirecting if it remains busy.
Blindly repeating `Ctrl+C` is unsafe because an idle first press changes the TUI into the `Press Ctrl+C again to exit` state.

A clean idle exit is a verified two-step sequence:

1. Send `Ctrl+C` once.
2. Verify `Press Ctrl+C again to exit` is visible.
3. Send `Ctrl+C` once more.

The clean-exit banner prints `agent --resume=<chat-id>`.
Recovery resumes in the preserved isolated task directory with `agent --force --trust --workspace <path> --resume=<chat-id>`.
`agent --continue` is the documented fallback for the most recent workspace session.

## Runtime backend review

All supported runtime backend integration surfaces were reviewed before enabling the adapter.

- tmux uses the shared busy regex and cursor-row composer classifier.
  Cursor's foreground command is the generic `node`, so process-level liveness remains conservatively `unknown`; `docs/tmux-backend.md` records the empirical process evidence.
- Herdr prefers native registered-agent state when available and falls back to the shared busy regex and structural composer classifier when it is not.
  Its bare composer set now includes `→` and the two Cursor placeholders.
- Orca has no native semantic busy state and uses capture plus the shared regex.
  Its structural composer classifier now accepts Cursor's bare `→` composer row specifically, short-circuits Cursor's on-row `ctrl+c to stop` busy hint to `empty` (a landed submit, no duplicate Enter), and retains bare-shell refusal - the generic `❯`/`›` glyphs are not accepted bare, so a `❯`-prompt dead shell stays `unknown`.
- cmux has the same capture and structural-classifier posture as Orca and recognizes the Cursor composer shape under the same Cursor-only bare-glyph and busy-hint rules.
- zellij has no separate composer-state API and retains its existing type-once, Enter-retry, screen-delta submit verification.
  Cursor uses that generic path without changing zellij lifecycle behavior.

Cursor is refused for secondmate launches.
This avoids claiming primary session-start, turn-end, watcher, and process-liveness guarantees that have not been empirically verified.
The existing five primary harness integrations in `docs/sessionstart-nudge.md`, `docs/turnend-guard.md`, `docs/arm-pretool-check.md`, and `docs/supervision-protocols/` remain unchanged.

## Empirical verification

Verification date: 2026-07-23.
Cursor Agent version: `2026.07.20-8cc9c0b`.
Host: macOS arm64.
The observations below incorporate the completed private verification report and the follow-up tmux integration probes run from this implementation branch.

### Version, authentication, and invocation

Commands:

```sh
which agent cursor
agent --version
cursor agent --version
agent status
agent about
```

Observed results, with the absolute home prefix normalized to `$HOME`:

```text
$HOME/.local/bin/agent
$HOME/.local/bin/cursor
2026.07.20-8cc9c0b
2026.07.20-8cc9c0b
✓ Logged in as <redacted account>
CLI Version         2026.07.20-8cc9c0b
Model               Cursor Grok 4.5 High
Subscription Tier   Team
```

One-shot prompt command:

```sh
agent --print --mode ask --model cursor-grok-4.5-low --trust --workspace "$(pwd)" \
  "Reply with exactly the four characters PONG and nothing else."
```

Observed stdout was exactly `PONG` with exit status 0.
The equivalent `cursor agent --print ...` probe returned exactly `CURSOR_AGENT_OK` with exit status 0.

### Model catalog

Commands:

```sh
agent --help
agent models
```

`agent --help` advertised `--model <model>` and no separate `--effort` option.
The 2026-07-23 catalog output included these exact entries:

```text
cursor-grok-4.5-low - Cursor Grok 4.5 Low
cursor-grok-4.5-medium - Cursor Grok 4.5 Medium
cursor-grok-4.5-high - Cursor Grok 4.5
```

The catalog also included model families whose effort is encoded in ids such as `-xhigh` and `-max`, plus parameterized model bracket overrides.
Firstmate uses only the concrete Cursor Grok entries above for its default mapping.

### Interactive tmux supervision

Command typed into a scratch tmux window:

```sh
agent --force --trust --workspace "$PWD" --mode ask \
  --model cursor-grok-4.5-low 'Reply with exactly PONG.'
```

Observed busy capture:

```text
⠀⠞ Working
→ Add a follow-up                                             ctrl+c to stop
Cursor Grok 4.5 Low                                           Run Everything
```

Observed idle capture:

```text
PONG
→ Add a follow-up
Ask (shift+tab to cycle)
Cursor Grok 4.5 Low · 15.8%                                   Run Everything
```

The shared tmux composer classifier returned `empty` for that idle pane.
The first idle `Ctrl+C` produced exactly `Press Ctrl+C again to exit`.
The second `Ctrl+C` returned the pane to `zsh`.

### tmux process identity

Commands:

```sh
tmux display-message -p -t "$session:cursor" '#{pane_current_command}'
tmux display-message -p -t "$session:cursor" '#{pane_tty}'
ps -t "${tty#/dev/}" -o pid=,ppid=,pgid=,comm=,args=
```

The exact current-command output was `node`.
The foreground argv began with:

```text
$HOME/.local/bin/agent --use-system-ca $HOME/.local/share/cursor-agent/versions/2026.07.20-8cc9c0b/index.js --force --trust --workspace ...
```

That path-shaped argv is not stable enough to become process-liveness authority.
The adapter preserves the existing conservative rule that a generic interpreter is `unknown`, never confidently dead.

### Workspace trust and permissions

Without `--trust`, a fresh workspace displayed this blocking modal:

```text
⚠ Workspace Trust Required
Cursor Agent can execute code and access files in this directory.
Do you trust the contents of this directory?
▶ [a] Trust this workspace
  [q] Quit
```

`q` exited cleanly.
`agent --help` documented `--force` and its `--yolo` alias as force-allowing commands unless denied.
The shipped adapter uses `--force` explicitly and does not alter global approval configuration.
