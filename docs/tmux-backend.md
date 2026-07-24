# tmux runtime backend

tmux is Firstmate's verified reference runtime backend and the fully supported baseline for secondmate homes.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Setup

Install tmux with `brew install tmux` or your platform package manager.
The universal harness and toolchain requirements are in [`configuration.md`](configuration.md#toolchain).

tmux is the hard default when no explicit setting or runtime auto-detection selects another backend.
Select it explicitly with local `config/backend` containing `tmux`, with `FM_BACKEND=tmux` for one launch, or by asking Firstmate to use tmux.
An explicit selection is also the opt-out from Herdr or cmux runtime auto-detection.

No provisioning is required before the first task.

## Watching the crew

For the best visible experience, launch the primary harness inside a tmux session:

```sh
tmux new -s firstmate
```

Crew tasks become windows in that session.
`tmux display-message -p '#S'` prints its name.
If the primary harness runs outside tmux, Firstmate creates or reuses a detached session named `firstmate`:

```sh
tmux attach -t firstmate
```

Each task window is named `fm-<id>`.

```sh
tmux list-windows -t <session-name>
tmux select-window -t <session-name>:fm-<id>
```

Typing into an attached task window is authoritative direct intervention.
Routine supervision does not require attachment: `bin/fm-peek.sh <id>` captures a bounded tail and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` steers the recorded endpoint.

Verify setup by spawning a small task and confirming its `fm-<id>` window appears in the selected session.

## Current behavior and safety

A target-existence check proves only that the pane exists.
The deeper tmux agent-liveness probe first verifies exact window membership, then reads `#{pane_current_command}` to distinguish a running harness process from a bare idle shell.
It classifies recognized Claude, Codex, OpenCode, and Grok process names as `alive`, common shells as `dead`, an authoritatively absent window as `missing`, unreadable state as `unreadable`, and every other process as `ambiguous`.
Only `dead` and `missing` authorize recovery because a false dead result could launch a duplicate agent.

Pi runs through a generic `node` process name and cannot be attributed confidently from the tmux foreground-process field.
An existing Pi pane is therefore reported as ambiguous rather than auto-healed, while an authoritatively missing Pi window can be relaunched safely.
This is the active tmux liveness limitation.

Agent liveness and composer safety are separate checks.
The shared classifier in `bin/fm-composer-lib.sh` accepts a shell glyph as an empty agent composer only inside a verified bordered composer.
A bare shell prompt is `unknown`, so away-mode escalation is never injected into a dead shell.

`bin/fm-tmux-lib.sh` owns exact type-and-submit mechanics.
It types a message once and retries Enter only until the composer clears.
A cleared composer is the positive delivery acknowledgement; text left in the composer remains `pending`, and `fm-send.sh` reports the failure instead of retyping.

OpenCode 1.18.4 has one busy-queue exception.
While OpenCode is mid-turn, Enter queues the message but leaves its text visible until the turn completes.
After the normal retry budget, a provably busy pane is accepted as queued, while an idle pane remains `pending` as a genuine swallowed Enter.
`tests/fm-tmux-submit-busy.test.sh` covers busy and idle panes with both pending and cleared composers.

## Limits and regression entry points

- tmux is the reference path and supports secondmate homes.
- Existing Pi agent-process liveness is inconclusive, while an authoritatively missing Pi window can trigger recovery.
- The OpenCode busy-queue exception is tmux-specific; Herdr retains its separately documented gap.

```sh
tests/fm-backend-tmux-smoke.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#tmux) records the active foreground-process and submit evidence.
