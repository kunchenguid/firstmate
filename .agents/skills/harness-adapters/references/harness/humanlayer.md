# HumanLayer CLI (codelayer)

The HumanLayer CLI's `codelayer` multi-provider coding agent TUI, verified end to end on 2026-09-15 with humanlayer 0.31.0 (`~/.local/bin/humanlayer`, config home `~/.humanlayer`) on macOS arm64 through the tmux backend, with the Codex provider (`--provider codex`, model default `gpt-6-astra`).
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no humanlayer wake protocol.
`../../../../../docs/verification/runtime-backends.md` ("HumanLayer") owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `humanlayer` from `PATH`, refused if absent; the installed launcher is a node shim (`~/.local/bin/humanlayer`) whose native child (`.../@humanlayer/cli-darwin-arm64/bin/humanlayer`) has `comm` exactly `humanlayer`. |
| Launch | `humanlayer codelayer --provider codex`, bare: there is no interactive launch flag that carries a prompt (`--prompt` runs non-interactively and exits at turn end), so the brief pointer is submitted through the composer after the readiness gate - the kimi/rovo launch-then-confirm shape. |
| Provider | `--provider codex` is the verified provider; codelayer's provider auto-runs tool calls with no approval prompt (verified live: bash commands and file writes landed ungated), which an unattended crewmate needs. |
| Busy state | See [busy-state arming and turn-end wiring](#busy-state-arming-and-turn-end-wiring-deliberate-gaps) for the classifier sources and supervision limits. |
| Idle anchor | `bin/fm-humanlayer-lib.sh` owns classification: the final non-blank row must be bare `>`, with no unresolved draft history; fresh-launch banners must be anchored at the top of the capture immediately before the composer, while retiring earlier prompt history requires a styled vendor completion row, whose provenance survives the usage footer. Draft continuation rows and truncated captures without positive provenance remain unknown; a plain completion marker cannot clear draft history. |
| Turn end | See [busy-state arming and turn-end wiring](#busy-state-arming-and-turn-end-wiring-deliberate-gaps). |
| Exit | Use the lifecycle control plane; [agent control](../../../../../docs/agent-control.md#verbs) owns its guarded key-exit contract. |
| Interrupt | Use the lifecycle control plane; [agent control](../../../../../docs/agent-control.md#verbs) owns the busy precondition and cancellation boundary. |
| Skill | No verified slash-skill form: typed `/...` renders literal composer text and reaches the model as chat. Use natural language. |
| Autonomy | No approval flag exists or is needed; the codex provider ran every tool call ungated. |
| Marker | None; tool children inherit the launching environment unchanged (verified live: a codelayer tool subprocess carried the launcher's `PI_CODING_AGENT` and `AI_AGENT` with no `HUMANLAYER_*` or `CODELAYER_*` variable added), so the spawn template clears foreign primary markers and detection is ancestry alone. |
| Resume | No verified pane-resume contract; use deterministic relaunch. |
| Model | `--model <id>`; the codex provider defaults to `gpt-6-astra`. No reachable model-listing command exists (`humanlayer agents auth` manages authentication only), so a requested id launches unvalidated. |
| Effort | `--thinking low|medium|high|xhigh` (verified low and xhigh live); `max` is known-bad - the provider rejects it with "OpenAI Responses does not support reasoning effort max" - so it stays in task metadata under the record-and-omit contract. |
| Composer | The generic shape classifier reads the borderless composer as `unknown`; HumanLayer submission requires the adapter-specific idle verdict at the shared backend boundary. Confirmation requires evidence from the current submission as described under [Steering precondition](#steering-precondition); a missing idle anchor alone is not delivery proof. |
| Multi-line | A multi-line steer typed with literal newlines lands in the composer without submitting and one `Enter` submits it as a single message (verified live). |

## Trust, approvals, and provider auth

A fresh task worktree showed no trust dialog of any kind (verified live across several fresh directories), so no trust pre-registration exists or is needed.
No approval prompt ever rendered: the codex provider ran `bash` commands and file writes without a gate, so there is no approval flow to map onto firstmate's decision plane.
`humanlayer api approvals resolve` exists in the cloud API surface for the HumanLayer app, not the local codelayer TUI, and is deliberately out of scope for this adapter.
The provider authenticated through the captain's own HumanLayer setup (`humanlayer agents auth codex` / AgentLayer file auth); any auth prompt or refusal is a credential blocker, not an adapter defect.

## Steering precondition

Check [harness support](../../../../../docs/configuration.md#harness-support) for backend eligibility before dispatch.

Text typed while a turn runs lands in a hidden input buffer and `Enter` does not queue it: the message was silently lost when the turn completed (verified live, humanlayer 0.31.0 - no echo row, no response, no error).
The shared backend submission boundary refuses injection unless the HumanLayer classifier proves idle, for direct sends and task-inbox doorbells alike.
On tmux, submission captures output with `pipe-pane` from before typing through the final confirmation decision, preserving the current prompt and provider-output evidence beyond scrollback loss; an existing pane pipe causes deferral.
Herdr compares subsequent captures against the pre-submission baseline, allowing overlapping captures after scrolling while requiring the current prompt and provider-output evidence to remain visible.
Historical responses cannot confirm a repeated instruction; ambiguous or lost evidence returns unknown.
A deferred durable inbox record remains available for the watcher's re-ring ladder; enqueue success is not delivery proof.
Never treat a busy humanlayer worker as safely steerable; wait for a verified idle verdict or use the control plane.

## Detection

Detected by ancestry alone: `../../../../../bin/fm-harness.sh` matches the anchored process name `humanlayer` (the native child) at comm strength, and the node shim through its script path in the interpreter-args arm.
No environment marker is promoted: codelayer adds no identity variable of its own and does not clear an inherited `CLAUDECODE` - but a structural humanlayer ancestor now outranks that retained marker.
The spawn template clears foreign primary markers at the launch boundary as defense in depth, the cursor/agy shape.
humanlayer is deliberately absent from the session-lock name vocabulary in `../../../../../bin/fm-session-lock-lib.sh`, where muse, gemini, and rovo are also absent: a crewmate-only adapter must never own a home session lock.

## Busy-state arming and turn-end wiring: deliberate gaps

`bin/fm-spawn.sh` does not arm or seed a HumanLayer busy-state record because no hook or plugin writer could clear it.
[`bin/fm-busy-lib.sh`](../../../../../bin/fm-busy-lib.sh) reports the screen classifier as `humanlayer-anchor`; tmux alone can prove tool-call activity from live tool descendants of an identified foreground HumanLayer process (`humanlayer-process`).
Herdr has no busy proof, and pure model thinking without a tool child stays unknown on tmux too.
[Runtime backend verification](../../../../../docs/verification/runtime-backends.md#humanlayer-humanlayer) owns the process observations and live evidence; `tests/fm-humanlayer-harness.test.sh` pins the portable classifier behavior.

No hook or poller touches `state/<id>.turn-ended` for this adapter.
Supervision therefore relies on the worker's status protocol for wake notifications, the classifier for available current-state evidence, and the watcher's stale detection for a wedged worker.
An unknown verdict is not proof that a turn has ended or that steering is safe.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no humanlayer protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.

## Non-interactive mode

`humanlayer codelayer --provider codex --prompt "<prompt>"` runs one turn to completion, exits 0, and prints the final assistant message between the machine-readable markers `__CODELAYER_FINAL_MESSAGE_START__` and `__CODELAYER_FINAL_MESSAGE_END__` followed by `[Done] complete`.
This mode is deliberately NOT the worker shape: a pane whose process exits at turn end cannot receive steers, so the interactive TUI is the verified executor and `--prompt` remains a diagnostic tool.
