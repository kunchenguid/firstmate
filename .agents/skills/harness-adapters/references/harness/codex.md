# Codex

Verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a Firstmate-launched worker. |
| Exit command | `/quit`; its slash popup needs about one second between text and Enter, which the shared submit path used by the control plane handles. |
| Interrupt | Single Escape. |
| Skill invocation | `$<skill>`, for example `$no-mistakes`; `/<skill>` is Claude-only and Codex rejects it as "Unrecognized command". |
| Resume | `codex resume <session-id>`, using the id printed on quit. |
| Model flag | `--model <model>`. |
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'`, verified on codex-cli 0.142.1 whose installed schema contains `model_reasoning_effort`, active config uses it, and bundled catalog advertises only these four values while omitting `max`. |
| Model discovery | Open the current interactive session's `/model` picker. |

Because busy state is unknown, `../../../bin/fm-crew-state.sh` reports a Codex worker as `unknown` and names the adapter, for example `harness state unavailable (unknown codex-unverified)`.
That is the recorded contract rather than a fault to investigate, and it is not evidence the worker is wedged.
Supervision still surfaces a wedged Codex worker, because the watcher's stale path reads pane output churn rather than harness semantic state.
What is lost is the distinction: Firstmate cannot separate a Codex worker that is thinking from one that is stuck, so it cannot absorb a benign stale for a provably-working Codex agent and cannot attribute a validation run's step state for one.
Expect periodic stale escalations on a healthy Codex worker and reconcile them by inspection.

## Launch gates

Gate sequence, selection defaults, and option text verified on 2026-09-09 with codex-cli 0.153.4.

A first run for a repository root can present two gates in sequence, and the launch is not underway until both are cleared.
Clearing only the first leaves the agent parked with its launch brief unread.

The first is the directory trust dialog: "Do you trust the contents of this directory?"
For a non-secondmate Firstmate spawn, `../../../bin/fm-codex-trust.sh` records this worktree as trusted in Codex's user config before launch and reads the setting back, so the worker does not meet the dialog.
The helper preserves every unrelated config byte and refuses a path it cannot establish as a linked worktree of the supplied project.
A Codex secondmate is deliberately excluded from pre-registration because its home is persistent rather than a fresh per-task worktree.

The second appears when that root's `.codex/hooks.json` is new or changed: "Hooks need review", offering `1. Review hooks`, `2. Trust all and continue`, and `3. Continue without trusting (hooks won't run)`.
Its selection starts on `1. Review hooks`, so Enter alone opens the review rather than accepting, and accepting requires moving the selection first.
Firstmate's own key plane carries no selection movement - `../../../bin/fm-control-lib.sh` accepts only Enter, Escape, C-c, and C-u - so it cannot answer this gate; move the selection through the backend's own key facility, or hand the gate to the operator.

Read the hooks before choosing rather than trusting blind.
For a Firstmate-launched worker or secondmate these are Firstmate's own tracked hooks - session start, the Bash pre-tool checks, and the turn-end guard - each anchored to a Firstmate-shaped root and written to exit 0 when anything is missing.
Codex's own option text declares that declining leaves hooks unrun, and the turn-end guard is one of the hooks that gate registers, so `3. Continue without trusting` launches a worker whose turn-end backstop is not installed.
That consequence follows from the option's declared behavior and the registered hook set; it has not been separately exercised, and nothing in the pane announces it after the choice is made.

## Skill popup

A `$<skill>` invocation opens a `$` autocomplete popup.
Submitting too fast lets the popup swallow Enter, so the invocation never lands.
`../../../bin/fm-send.sh` gives a leading `$` a 1.2-second settle before the first Enter only when the exact task metadata records `harness=codex`, with the target backend's submit retry as the safety net.
That scope is load-bearing because a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`.
An explicit `session:window` target has no metadata, so its harness is unknown and uses the non-Codex fast path.
This is why `$no-mistakes` reaches a Codex worker instead of being consumed by the popup.

## Primary integration

The primary integration was verified on 2026-07-08 with codex-cli 0.142.1.
The firstmate primary's `.codex/hooks.json` registers a Stop hook that pipes Codex's payload to `../../../bin/fm-turnend-guard.sh`.
Codex Stop hooks preserve exit status 2 and stderr to block, and expose `stop_hook_active` for the same one-block loop safety used by the guard's default mode.

The Stop payload includes `cwd`, but the tracked hook does not use it to choose the guard executable.
Codex runs the Stop command with process PWD set to the hook-loaded project root, while no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is Firstmate-shaped and hook-bearing, and then invokes the guard with the original payload.

Codex's primary watcher protocol is `../../../bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `../../../bin/fm-watch-arm.sh`.
Codex cannot reason while a foreground tool call is running, so the checkpoint is deliberately foreground and bounded to return control regularly for user messages and queued notifications.
Codex's PreToolUse watcher-arm seatbelt blocks directly through its project hook.
