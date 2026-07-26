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
It classifies recognized Claude, Codex, OpenCode, Grok, and Kimi process names as `alive`, a `node` pane whose foreground argv[0] basename is exactly `cursor-agent` as `alive`, common shells as `dead`, an authoritatively absent window as `missing`, unreadable state as `unreadable`, and every other process as `ambiguous`.
Only `dead` and `missing` authorize recovery because a false dead result could launch a duplicate agent.

Pi runs through a generic `node` process name and cannot be attributed confidently from the tmux foreground-process field.
An existing Pi pane is therefore reported as ambiguous rather than auto-healed, while an authoritatively missing Pi window can be relaunched safely.
This is the active tmux liveness limitation.

Agent liveness and composer safety are separate checks.
For a bordered composer, the tmux reader locates the complete box structurally and classifies every content row through the shared ANSI and ghost handling in `bin/fm-composer-lib.sh`.
Real text on any content row is pending, while only an unambiguous box with every row empty is proven empty.
Unreadable, incomplete, or structurally ambiguous boxes fail closed, and panes without a bordered composer retain the compatible cursor-row classification.
The shared classifier accepts a shell glyph as an empty agent composer only inside a verified bordered composer.
A bare shell prompt is `unknown`, so away-mode escalation is never injected into a dead shell.

Rendered busy detection is also harness-scoped.
Task metadata selects only that harness's verified signature, so output from one harness cannot make another harness appear busy.
The exact selection contract and safety rationale live in [architecture](architecture.md#runtime-session-backends), while the signatures live in [the harness-adapters skill](../.agents/skills/harness-adapters/SKILL.md).

`bin/fm-tmux-lib.sh` owns exact type-and-submit mechanics.
It types a message once and retries Enter only until the composer clears.
Only a proven empty composer is a positive delivery acknowledgement.
Text left in established structure remains `pending`, text in ambiguous structure remains unproven, and unreadable or unsafe state remains unknown.
`fm-send.sh` reports every unconfirmed verdict as a failure instead of retyping or assuming delivery.

OpenCode 1.18.4 has one busy-queue exception.
While OpenCode is mid-turn, Enter queues the message but leaves its text visible until the turn completes.
After the normal retry budget, only structurally proven pending text in a provably busy pane is accepted as queued, while an idle pane remains `pending` as a genuine swallowed Enter.
Ambiguous pending text never receives the busy-queue conversion.
`tests/fm-tmux-submit-busy.test.sh` covers busy and idle panes with proven, ambiguous, and cleared composers.

## Limits and regression entry points

- tmux is the reference path and supports secondmate homes.
- Existing Pi agent-process liveness is inconclusive, while an authoritatively missing Pi window can trigger recovery.
- The OpenCode busy-queue exception is tmux-specific; Herdr retains its separately documented gap.

```sh
tests/fm-backend-tmux-smoke.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-cursor-harness.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-bootstrap.test.sh
```

### Cursor Agent verification, 2026-07-14

Version: `2026.07.09-a3815c0`.
Launch command: `cursor-agent --force --model gpt-5.6-sol-high`.
Command run while the interactive TUI was live: `tmux display-message -p -t fm-cursor-verify '#{pane_current_command}'`.
Exact output: `node`.
Commands then read the same pane's `#{pane_pid}` and ran `ps -o pid=,ppid=,pgid=,comm=,args= -g <foreground-pgid>`.
The single foreground row's arguments began with `$HOME/.local/bin/cursor-agent --use-system-ca .../cursor-agent/versions/2026.07.09-a3815c0/index.js`.
This is why the liveness classifier inspects only a `node` pane's own pid and requires argv[0]'s basename to equal `cursor-agent`; unrelated Node programs remain `ambiguous`/`unknown`.

The busy TUI was captured while the agent ran `sleep 30`.
Its status line was `⠘⠆ Running  50 tokens`, while the idle TUI had no `Running ... tokens` line.
The shared busy regex therefore matches a leading spinner token followed by `Running`, a numeric token count, and `tokens`, without depending on one animated braille glyph.

### Cursor Agent reverification, 2026-07-18

Version: `2026.07.16-899851b`.
Launch command in a scratch tmux session: `cursor-agent --force --model auto`.
`tmux list-panes -F '#{pane_pid} #{pane_current_command}'` reported `node`; `ps -o tpgid= -p <pane_pid>` named the pane pid itself, and a sole-column `ps -o comm= -p <tpgid>` printed the full argv[0] `$HOME/.local/bin/cursor-agent`, with `ps -o args=` beginning `$HOME/.local/bin/cursor-agent --use-system-ca .../versions/2026.07.16-899851b/index.js`.
Both liveness paths therefore hold on this build: macOS `comm` resolves to the exact `cursor-agent` basename directly, and the `node` route still requires the `cursor-agent` argv[0] basename.

The busy signature changed on this build.
While a turn ran (`sleep 20` through the Shell tool), the composer footer row read `→ Add a follow-up                       ctrl+c to stop` and a transient `1 task` line appeared; the `Running  <N> tokens` status line of 2026.07.09 never appeared.
At idle the footer showed only `→ Add a follow-up` with no `ctrl+c to stop`.
The shared busy regex therefore matches an end-anchored `ctrl+c to stop` (the anchor keeps mid-transcript prose from matching) and retains the older `Running  <N> tokens` pattern for pre-2026.07.16 builds.
Piping the interactive launch through `tee` broke the TTY and made `cursor-agent` fail with `Error: No prompt provided for print mode`, so liveness probes must never wrap the launch in a pipe.

[`verification/runtime-backends.md`](verification/runtime-backends.md#tmux) records the active foreground-process and submit evidence.
