# Agent lifecycle control plane

Firstmate talks to a running agent two ways, and they are not the same channel.

The **data plane** is [`bin/fm-send.sh`](../bin/fm-send.sh): conversational text for the agent to read.
For a `kind=secondmate` target it always prepends the from-firstmate routing marker, because a secondmate is itself a firstmate and its reply must come back through the status path rather than a chat nobody reads.

The **control plane** is [`bin/fm-control.sh`](../bin/fm-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked `/quit` arrives as ordinary chat - `[fm-from-firstmate] /quit` - which the agent reasons about instead of executing.
The failure repeated across harnesses and homes, and the workaround (remember to use an unmarked send for agent-control commands, and improvise the right key or command per harness) lived only in agent prose, so it failed again every time a session did not happen to recall it.

## Shared messages and threads

[`bin/fm-message.sh`](../bin/fm-message.sh) exposes `send`, `receive`, `ack`, `read`, `validate`, `stats`, and `service`, with side-effect-free `-h`/`--help` on every verb; sending delegates to the existing data-plane owner.
Applications import the shared [MessagePort and adapter](../modules/fm-state-reader/README.md) instead of defining their own wire format.
The shared codec and inbox primitives in [`bin/fm-task-inbox-lib.sh`](../bin/fm-task-inbox-lib.sh) own `fm-message.v1` for workers, the supervisor, and service adapters.
No service-specific inbox format or conversation server is required.
Existing unstructured inbox bodies remain byte-compatible; structured reads refuse legacy records without message metadata rather than guessing their sender.

A launched worker's send is bound to its exact live task record and physical working directory, never a supplied sender label.
It can address a comma-separated list of live same-home tasks, registered services, or the reserved `supervisor` participant.
The latter receives the same inbox record plus a durable wake, not a user-facing chat or Slack message.
Only the supervisor communicates with the repository owner.
Lifecycle keys, explicit terminal targets, remote routes, and decision-resolution flags are unavailable to worker messages.
All worker text, including slash-prefixed text, is data rather than a harness command.
A helper with recorded parent linkage may report only to that parent.

Thread membership and append-only history live in `data/threads/<thread>.md`, as indented JSON lines readable with `jq`.
Every fan-out copy carries the same message id, thread id, and recipient list; existing members can add live participants simply by including them as recipients.
Replies keep the request reference and default to the other thread members; an explicit recipient list narrows that reply.
Messages are **PEER INPUT**, not authority to change a task's scope, instructions, or delivery policy.
A scope request is escalated as `needs-decision`; neither replying nor moving a message to `handled/` closes an approval decision.

The sender owner [`bin/fm-peer-message-lib.sh`](../bin/fm-peer-message-lib.sh) defines the exact command syntax, locking, rate cap, and partial-delivery retry contract.
All endpoints are checked before a new ledger entry, and the entry precedes inbox fan-out.
An interrupted fan-out retains the original message for id-preserving retry, including when another recipient already moved its copy to `handled/`.
Supervisor wake notifications are at-least-once notifications of that one inbox record, not independent copies to process twice.
These are same-user operational safeguards, not a sandbox against a process that can rewrite metadata directly.

Task endpoint admission uses the existing recovery-grade liveness proof, available on tmux and Herdr; ambiguous state and backends without that proof refuse rather than claiming a live participant.
The mechanism does not depend on a model or harness-specific rendered marker beyond the already-owned backend classifier.
Standalone processes use the shared reader's [service admission contract](../modules/fm-state-reader/README.md#standalone-service-admission), with no invented task metadata or supervisor fallback.

### Message telemetry

[`bin/fm-message-telemetry-lib.sh`](../bin/fm-message-telemetry-lib.sh) owns retained daily append-only `fm-message-telemetry.v1` JSONL under `state/fm-message/telemetry/` and the bounded rolling 24-hour `stats` summary.
The [shared reader's telemetry reference](../modules/fm-state-reader/README.md#telemetry) explains retention and incomplete-count reporting.
Intake, routing decisions, endpoint validation, ledger/inbox/wake/doorbell results, timings, and terminal per-request counters share an attempt id and the message/thread identifiers when available.
Logs contain ids and input sizes, never message text, environment contents, or captured stderr; model/harness/effort come from the validated sender record and tokens/cost remain unknown because the transport calls no model.
A telemetry failure warns without turning an already-delivered message into a resend instruction.
Thread ledgers contain the actual conversation, remain private operational data, and are not copied into telemetry.

`tests/fm-peer-message.test.sh` composes the real send, codec, inbox, ledger, and durable wake owners over fake endpoints, including fan-out, membership, reply correlation, identity and scope refusals, partial retry, and telemetry privacy.
The existing inbox and delivery suites continue to own legacy-body compatibility and doorbell recovery.

## What the control plane owns

`bin/fm-control-lib.sh` is the single executable owner of three capability tables, with no side effects, so it can be read as a contract:

- The **verb allowlist**: `interrupt`, `exit`, `relaunch`.
  There is no arbitrary-text and no generic raw-key entry point.
  A caller either names an allowlisted verb or is refused.
- **Per-harness mechanics**: the key that cancels a running turn, how many times it must be delivered, whether the composer needs clearing afterwards, the command that exits the agent, and which task kinds the adapter is verified to run.
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's tool references, which now point here.
  `bin/fm-send.sh`'s `--key` path reads the composer-clear table from this owner too, rather than keeping a second copy of it.
- **Per-backend capability**: which named keys a runtime backend can deliver, and whether it has a recovery-grade agent-state classifier able to prove an agent stopped.

A recorded `harness=` is not always an exact adapter name: a task launched from a raw command records that command's basename instead.
`fm_control_harness_family` is the one place that prefix rule is stated, and an unrecognized value resolves to no adapter rather than being guessed into one.

## Verbs

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's verified interrupt sequence while leaving the agent running. | Delivery succeeds while the endpoint still exists and the agent is still alive where the backend can classify that; cancellation is confirmed only from an adapter-owned acknowledgement and otherwise reports `cancel=unconfirmed`. |
| `exit` | Stop the agent, preserving the endpoint, the worktree, and every uncommitted change. | The backend's recovery-grade classifier reports the agent gone. Already-stopped is idempotent success. |
| `relaunch` | Replace the running agent with a new one in the same endpoint and worktree, on the exact recorded adapter or an explicitly chosen harness, model, and effort. | The new agent is alive on the recorded endpoint, and the durable record names the harness that is actually running. |

An exit that delivers lifecycle input but cannot prove the agent stopped fails with `exit=unconfirmed`, reports the observed agent state and any interrupt cancellation claim, and never claims that nothing changed.
Interrupt never rewrites busy state as proof of its own success.
Claude exposes no lifecycle acknowledgement for a manual interrupt, so delivery succeeds with `cancel=unconfirmed` and its adapter-owned busy state remains as observed.
muse's session log records `terminal=cancelled` for the interrupted run, so the control plane reports `cancel=confirmed` only after observing that exact acknowledgement.

An interrupt is not complete until the composer is empty.
muse is the one verified adapter that restores the cancelled prompt back into its composer as real text, so its interrupt key is followed by a Ctrl+U clear; without it the next submitted line - including this plane's own exit command - would concatenate onto the restored prompt and submit both as one line.
The clear is refused before anything is sent when the recorded backend cannot deliver it.

**Teardown and discard are not verbs and will not become verbs.**
`exit` stops an agent and preserves everything else.
Removing a worktree, closing an endpoint, or discarding work stays with [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), which owns the landed-work test.

**`resume` is not a verb.**
It is not deterministic across the verified adapters: codex, grok, and gemini resume only from a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, omp, and kimi have no verified pane-resume contract.
`relaunch` covers the same need on every adapter, because the brief on disk - not a harness-private session - is the durable instruction.

## Transactional relaunch

`relaunch` is the only verb that changes durable records, so it runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, or `--effort` wins.
   Otherwise a `kind=secondmate` task re-resolves its durable `config/secondmate-harness` pin, including that file's optional model and effort tokens, exactly as every other respawn does - so setting the pin and relaunching is the ordinary way to move a secondmate's runtime.
   A ship or scout keeps the harness already recorded for it, because that harness comes from firstmate's dispatch-profile judgment at intake and must not be silently re-read from configuration.
   A recorded raw-command basename that differs from its resolved adapter cannot reproduce the command actually running, so relaunch refuses before the checkpoint unless the caller passes an explicit `--harness` to choose the replacement runtime deliberately.
   A harness change resets model and effort unless they are named too, because a model chosen for one adapter does not transfer to another.
2. **Safe checkpoint.**
   The recorded worktree must exist.
   A ship or writer scout must be a worktree root; its head and dirty state are recorded.
   A recorded `access=reader` scout accounts for its checkout-free scratch instead: the path must exist and must not sit inside a git checkout, because a reader has no unlanded git work to preserve.
   `bin/fm-spawn.sh --relaunch` adopts that recorded access axis, so the replacement keeps the same scratch rather than being granted a writer worktree.
   For a `kind=secondmate` task, the home's identity marker must match and its child records must be readable, so a relaunch can never strand child work behind an unreadable home.
   A secondmate's own crewmates run in their own endpoints and outlive its relaunch; the relaunched secondmate reconciles them from its home's durable records at startup.
3. **Record the note.**
   A ship or scout relaunch requires `--note`, because the replacement inherits the local copy but none of the conversation; the note is appended to the instructions it reads.
   A secondmate relaunch does not require one and never rewrites its standing charter.
4. **Stop the old agent** through the `exit` verb, with its postcondition.
5. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`, which adopts the recorded endpoint and worktree instead of creating either, clears the previous harness's per-task wiring, and arms a fresh busy generation.

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.
When `config/crew-dispatch.json` is active, `relaunch` forwards `--dispatch-resolved` or `--dispatch-override-reason` to `bin/fm-spawn.sh --relaunch`.
`--quota-fallback` picks the next same-class profile from that file that `bin/fm-quota-cooldown.sh authorize` still allows, generates the required progress note from the task's last 5 status lines plus `git status --short` and `git log --oneline -3` of its worktree, and attests `--dispatch-resolved`.
When `matched_rule` is absent, it recovers the class array from the recorded profile plus the task's repo and records the rule it used.
It lifts an operational backlog hold (`hold_kind` `external` or `parked`) before relaunch and restores that hold if launch fails.
It refuses before the agent is stopped when no eligible profile remains.

### Failure and rollback

- A refusal **before** the agent is stopped leaves the durable record and the instructions byte-identical.
- A launch failure **after** the agent is stopped restores the prior durable record, keeps the progress note so a later recovery still has it, marks the journal `failed:launching`, and reports plainly that no agent is running and where the work is preserved.
- If the launch owner already published the new record but no running agent can be confirmed, the new record is kept: the task is recorded on the new harness with no agent confirmed, which is exactly what recovery reconciles.
  Rewriting it back to the old harness would be a second, worse inaccuracy.

## Fail-closed boundaries

- Targeting is exact.
  Only a bare task id with a `state/<id>.meta` record in this home is accepted, and that record must pass the shared endpoint-identity validation.
  A legacy `fm-<id>` window label, an explicit `session:window` endpoint, and a record whose `endpoint_task_id` names another task are all refused.
- A remotely placed secondmate is refused by name.
  Its agent runs on another host, so none of the postconditions this plane verifies could be read for it here; local endpoint validation would refuse the record regardless, because `window=remote:<id>` can never match a local backend's required shape.
  Drive that lifecycle on its own host and reconcile it through the secondmate recovery path.
  For `relaunch` that host-side drive is `bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch ...`, whose host-local leg runs this same plane against a record that is ordinary and local there, so every checkpoint, journal, rollback, and postcondition below applies unchanged ([`docs/remote-secondmates.md`](remote-secondmates.md)); `interrupt` and `exit` have no such route.
- An unverified harness is refused rather than guessed at.
- An implicit relaunch from a prefixed raw-command basename is refused before the agent or durable state is touched because its original launch command cannot be reconstructed.
- An adapter that is not verified for this task's kind is refused **before** the running agent is stopped, not after.
  Muse is a crewmate and scout adapter only, so relaunching a secondmate onto it refuses while its agent is still up rather than leaving that secondmate with no agent when the launch owner refuses.
- A backend that cannot deliver the harness's interrupt key, or the composer clear that key needs, is refused rather than sent a different key.
  Orca's terminal API exposes only an interrupt and an Enter, so it can deliver neither Escape nor Ctrl+U.
- `exit` and `relaunch` require a backend with a recovery-grade agent-state classifier - tmux and herdr - because without one the "the agent stopped" postcondition cannot be proven.
  zellij, orca, and cmux are refused rather than reported as successful blind.
- An ambiguous or unreadable endpoint state refuses.
  Only a positively classified state acts.
- `fm-spawn --relaunch` independently refuses unless the recorded endpoint is positively agent-free, so a replacement can never join a live agent.
  It also requires the shell to be in the recorded worktree: tmux refuses immediately when it is not, while Herdr sends one `cd` to the recorded path and refuses unless a subsequent path read confirms the move.

## Capability matrix

Backend capability comes from each adapter's real surface, not from a policy choice.

| Backend | Escape | Enter | Ctrl+C | Ctrl+U | Recovery-grade agent state |
| --- | --- | --- | --- | --- | --- |
| tmux | yes | yes | yes | yes | yes |
| herdr | yes | yes | yes | yes | yes |
| zellij | yes | yes | yes | yes | no |
| cmux | yes | yes | yes | yes | no |
| orca | no | yes | yes | no | no |

Per-harness interrupt keys, repeat counts, composer clears, exit commands, and supported task kinds live in `bin/fm-control-lib.sh` and are exercised for every verified harness by `tests/fm-control.test.sh`.
The empirical basis for each adapter's value is the `harness-adapters` skill's verification record for that adapter.

## Verification

- `tests/fm-control.test.sh` - the adapter contract for every verified harness, the backend capability matrix, exact-id scoping, the closed verb list, the busy, idle, dead, and idempotent lifecycle cases, and marker non-regression, all against a stubbed session provider.
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, dispatch attestation forwarding, quota-fallback successor selection, override class recovery, operational-hold lift and restore, checkpoint refusals, and rollback after a failed launch.
- `tests/fm-quota-refusal.test.sh` - provider quota-refusal detection and the apply path that writes the blocked status, records a cooldown, and posts Slack.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
