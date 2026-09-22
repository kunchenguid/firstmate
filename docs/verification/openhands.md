# Verification: the openhands crewmate/scout adapter

Audience: maintainer verification.

Active empirical facts for firstmate's openhands adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/openhands.md`](../../.agents/skills/harness-adapters/references/harness/openhands.md); this record owns how they were established and what is still unproven.

| Field | Value |
|---|---|
| Date | 2026-09-22 |
| Version | OpenHands CLI 1.16.0 / SDK v1.21.0 |
| Binary | worktree-local `uv tool install openhands --python 3.12`; `ps -o comm=` reports `openhands` |
| Backend | tmux, in an isolated private socket; the live default session was unchanged |
| Model | `fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash` via `LLM_MODEL` and `--override-with-envs` |

## Detection

```sh
$ ps -o comm=,args= -p <openhands-pid>
openhands    /.../python /.../openhands --override-with-envs --always-approve --exit-without-confirmation
```

A live TUI carries `GROK_AGENT=1` when launched from a Grok pane and no `OPENHANDS_*` identity variable of its own.
`bin/fm-harness.sh` therefore matches the anchored process name `openhands` alone, with a Python-interpreter args fallback whose last path component is exactly `openhands`, and the spawn clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `FM_PI_HARNESS`, `GEMINI_CLI`, `CURSOR_AGENT`, and `CURSOR_INVOKED_AS` at the launch boundary.
`tests/fm-openhands-harness.test.sh` pins the anchored match, the rejection of unrelated names containing the fragment, and that an inherited `CLAUDECODE` never outranks a real `openhands` ancestor.

## Launch and credentials

```sh
HOME=<throwaway> OPENHANDS_SUPPRESS_BANNER=1 OPENHANDS_PERSISTENCE_DIR=<throwaway>/.openhands \
  OPENHANDS_WORK_DIR=<worktree> \
  openhands --override-with-envs --always-approve --exit-without-confirmation
```

`-f` and `-t` are documented as seeding the composer (`openhands --help` on CLI 1.16.0).
On an isolated tmux PTY they can also post a queued SendMessage and start a turn without Enter.
Spawn does not rely on that: it launches the TUI without `-f`, `--task`, or `--headless`, waits for `Type your message, @mention a file, or / for commands`, then types `Read the brief at <launch-brief> and follow it exactly.` and Enter.
That submit started a Fireworks DeepSeek 4.1 Flash turn, matched `ESC: pause`, answered `80235`, and a pointer-driven brief appended `done: openhands live ok` through a shell tool.
`--always-approve` ran that shell action without a confirmation modal.

`--headless` with `-f`/`-t` does process a file unattended.
That path is unused: it has no TUI for `ESC: pause` busy detection, steering, Escape interrupt, or `/exit`, and it exits when the first turn ends.

The same launch with the operator `HOME` and a root-owned `~/.openhands` crashed:

```text
PermissionError: [Errno 13] Permission denied: '/home/azureuser/.openhands/profiles'
```

`OPENHANDS_PERSISTENCE_DIR` does not move that profile store; `Path.home() / ".openhands" / "profiles"` is hardcoded.
The spawn therefore always uses a per-task `HOME`.

`--override-with-envs` is required so `LLM_MODEL` / `LLM_API_KEY` create the agent without the first-run settings wizard.
There is no `--model` or `--effort` flag on this CLI.

## Busy, interrupt, and exit

A turn in flight rendered:

```text
⠋ Working (0s • ESC: pause)
```

Idle replaced that row with a blank status line above the bordered composer whose placeholder is `Type your message, @mention a file, or / for commands`.
`fm_busy_openhands_tail_busy` matches `ESC: pause` only.

A single Escape printed `Pausing conversation` / `Pausing conversation, this make take a few seconds...` and left the placeholder composer with no restored prompt.
The process stayed alive.

`/exit` is the documented command; `--exit-without-confirmation` makes `_command_exit` call `app.exit()` instead of the "Terminate session?" modal.
A first Enter after typing `/exit` can leave the text in the composer (slash-command completion), matching the control plane's existing Enter-retry for exit commands.
Ctrl+C under `--exit-without-confirmation` exited the process (verified live).

## Refresh

Run the portable suite and the live guard after any openhands upgrade, because the process name, rendered busy/interrupt text, and profile-store path are vendor-controlled surfaces:

```sh
bin/fm-test-run.sh tests/fm-openhands-harness.test.sh
FM_OPENHANDS_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-openhands-signals-live-e2e.test.sh
```
