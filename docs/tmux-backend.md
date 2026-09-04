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

### Agent liveness probe

A target-existence check proves only that the pane exists.
The deeper tmux agent-liveness probe first verifies exact window membership, then reads process names to distinguish a running harness from a bare idle shell.
It classifies recognized Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, Cursor, and Muse process identities as `alive`, common shells as `dead`, an authoritatively absent window as `missing`, unreadable state as `unreadable`, and every other process as `ambiguous`.
Only `dead` and `missing` authorize recovery because a false dead result could launch a duplicate agent.

For positive attribution, the probe combines two independent name sources rather than making either one load-bearing.
`#{pane_current_command}` and the pane tty foreground process group's kernel `comm` values expose different name fields, and which one retains executable identity is platform-dependent.
The foreground probe also reads argv[0] so an exact harness install-path component can carry the verdict when the other fields expose a rewritten process name.
Either source naming a verified harness is enough for `alive`, because a false `dead` is the one verdict that can start a duplicate agent on a live worktree, while a readable foreground process group settles the negative verdicts.

Scoping the second source to the foreground process group rather than to the pane's descendants is deliberate: a harness-named process left running in the background of an otherwise idle pane must not read as an agent.
The same scoping covers multi-process launchers without a special case, so the Pi Launcher path is attributed through its `pi-signed` wrapper and `pi` engine even though its title is the exact foreground command `pi-launcher`.
Direct executable identities `pi`, `pi-signed`, and `Pi` remain accepted exactly, and similar or prefixed process names are not accepted through those exact Pi-family entries.
Muse is likewise anchored to the exact `muse` launcher identity or the installed `muse-bin-<version>` prefix, so unrelated names such as `musescore` and `amuse` remain ambiguous.
Cursor is identified from its exact `cursor-agent` identity or versioned install tree in the foreground process path or structured argv[0]; a bare `node` or unrelated `agent` remains ambiguous.

The CI-enforced portable regression and opt-in real-harness drift guard follow the split owned by `.agents/skills/firstmate-coding-guidelines/SKILL.md`.
Run the real-harness guard after any harness upgrade and before trusting refreshed evidence.

### Composer, busy state, and delivery

Agent liveness and composer safety are separate checks.
The tmux reader is a thin adapter over the fleet-wide classifier in `bin/fm-composer-lib.sh`: it contributes one styled full-pane capture, the `#{cursor_y}` cursor row, and foreground-process identity probes, and the shape containing the cursor - a complete bordered box (titled bottom borders tolerated), a bare agent-glyph row with its wrapped input, opencode's left bar, or Pi's identity-corroborated separator pair - normally decides the verdict.
Real text in an identified shape is pending, while only positively proven emptiness reads empty.
A blank or otherwise unidentified cursor row is `unknown` and every consumer defers, except that a foreground process proven to be Cursor is re-read cursorlessly because Cursor parks its terminal cursor below its footer.
That identity-gated exception preserves the strict container-proof rule for every other pane, so a modal dialog, a dead shell between stale rules, or a mid-redraw pane is never an injection target.
The shared classifier accepts a shell glyph as an empty agent composer only inside a bordered container.
A bare shell prompt is `unknown`, so away-mode escalation is never injected into a dead shell.

Busy state is not read from rendered text on this backend.
A task's busy, idle, unknown, or dead verdict comes from the semantic busy-state contract owned by `bin/fm-busy-lib.sh`; [architecture](architecture.md#busy-state-is-semantic-per-adapter) owns its boundaries.
The one remaining rendered-tail reader is Grok's isolated fallback inside that contract, which can only classify a Grok task.
The submit acknowledgement and away-mode supervisor-pane busy guard below still consult rendered output, but only to decide whether input can be delivered, never to decide recorded task state.
The supervisor guard selects only the detected primary harness's signature rather than a global union of vendor patterns.

`bin/fm-tmux-lib.sh` owns exact type-and-submit mechanics.
It types a message once and retries Enter only until the composer clears.
Only a proven empty composer is a positive delivery acknowledgement.
Text left in established structure remains `pending`, text in ambiguous structure remains unproven, and unreadable or unsafe state remains unknown.
An ordinary local `fm-send.sh` text steer and every remote text steer no longer ride this verified submit at all: they become durable steering-inbox records plus best-effort constant doorbell lines (`bin/fm-task-inbox-lib.sh`).
The verdicts above are delivery-critical only for the local typed plane - harness-native invocations and explicit backend targets - where `fm-send.sh` still never retypes or assumes a confirmed submit for an unconfirmed verdict; its header owns the distinct delivered-unconfirmed exit status and operator response.
The `--key` path is separate from that typed plane, and the adapter constrains nothing on it: `fm_backend_tmux_send_key` passes the name straight to `tmux send-keys`, so the limit is tmux's own key table rather than the `fm-send.sh` path, which normalizes only the Escape spellings.
Arrows, such as the ones needed to move a selection inside a harness confirmation dialog, therefore reach the pane exactly as written; Enter, Escape, and Ctrl-C are the only names this repository's own evidence exercises, and any other name is accepted or rejected by tmux itself.

OpenCode 1.18.4 has one busy-queue exception.
While OpenCode is mid-turn, Enter queues the message but leaves its text visible until the turn completes.
After the normal retry budget, only structurally proven pending text in a provably busy pane is accepted as queued, while an idle pane remains `pending` as a genuine swallowed Enter.
Ambiguous pending text never receives the busy-queue conversion.
A second, baseline-gated conversion covers harnesses whose mid-turn screen the classifier cannot identify (Pi replaces its separated composer while working): when and only when the pane was idle before the text was typed, an idle-to-busy transition across the submit's own Enter confirms delivery, the same turn-started signal Herdr reads natively.
Without that baseline, an `unknown` verdict is preserved untouched, so a busy-looking pane can never convert an unread composer into a confirmation.
`tests/fm-tmux-submit-busy.test.sh` covers busy and idle panes with proven, ambiguous, and cleared composers.

## Limits and regression entry points

- tmux is the reference path and supports secondmate homes.

```sh
tests/fm-backend-tmux-smoke.test.sh
tests/fm-tmux-agent-liveness.test.sh
tests/fm-harness-liveness-drift-live-e2e.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-cursor-harness.test.sh
tests/fm-muse-harness.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#tmux) records the active foreground-process and submit evidence.
