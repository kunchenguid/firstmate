# Codex

**A worker without functioning supervision hooks can still work, produce, and finish while nothing ever wakes firstmate: it is silently invisible to supervision.**
Treat missing hook permission as a threat to that supervision path, even when launch and instruction processing succeed.

Operating facts below were verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

## Trust gates and launch verification

### Directory trust

A directory trust dialog appears on the first run for a repository root: "Do you trust the contents of this directory?"
Accept it with Enter and verify the instructions begin processing.
The decision persists for the repository, so later worktrees of the same project skip it.
That Enter recipe applies only to this directory dialog.

### New or changed hooks

The hook-review dialog observed on 2026-09-08 appeared before instructions were processed: four hooks were new or changed, with an offer to let them run outside the sandbox.
It presented three choices with the cursor on review, not either trust choice.
Firstmate's key plane can confirm, escape, or interrupt but cannot move the selection.
**Escape is the only safe key for this dialog through that plane**, because it offers going back without granting anything.
Confirm opens a review flow the plane cannot navigate; declining disables precisely the hooks supervision depends on.
Do not automate an answer or guess a selection.
The dialog can swallow the ordinary stop command: successful delivery does not prove the worker stopped, so clear the dialog with Escape before recovery.

Escape allowed the observed workers to proceed, but the dialog recurred on a later launch.
**Trusted versus merely dismissed remains unresolved**, including why turn-end notifications worked; neither dismissal nor those notifications establish that all four hooks ran or were approved.
Do not infer a trust guarantee for future launches or versions from those observations.

### Required after every launch

Before treating any Codex worker as supervised, verify that its actual turn-end signal was freshly written after this launch and that supervision received the corresponding wake.
For a crewmate or scout, inspect the active home's task-specific `state/<id>.turn-ended` evidence against the launch time, accounting for an older marker on a relaunch, and correlate it with the supervisor's received event.
A successful launch, instruction processing, completed work, or installed hook configuration is insufficient; keep supervision unverified while that evidence is absent.
`../../../bin/fm-spawn.sh` owns signal wiring; its Codex crewmate and scout launches use `notify` for the turn-end marker, independently of the dialog-listed lifecycle hooks.
For a secondmate's own supervision path, use `references/common/primary-hooks.md` and the Primary integration section below rather than expecting a parent-facing worker marker.

### Operator acceptance persistence

**Hook acceptance is not a once-per-machine approval: trust is recorded for each reviewed definition's content hash, and new or changed definitions require renewed review.**
The [official hook trust documentation](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks), checked on 2026-09-08, owns this persistence rule and states that untrusted non-managed hooks are skipped.
Any tool changing hook definitions in the shared `~/.codex/hooks.json` can therefore reopen review, including tools unrelated to Firstmate.
This rule does not establish the approval state of the observed workers; that requires confirmed operator acceptance and matching recorded trust for the current definitions.
Do not automate an answer, substitute another resolution path, or trigger trust experiments on live workers or their validation pipelines.

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
