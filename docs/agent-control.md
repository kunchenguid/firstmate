# Agent lifecycle control plane

Firstmate talks to a running agent two ways, and they are not the same channel.

The **data plane** is [`bin/fm-send.sh`](../bin/fm-send.sh): conversational text for the agent to read.
For a `kind=secondmate` target it always prepends the from-firstmate routing marker, because a secondmate is itself a firstmate and its reply must come back through the status path rather than a chat nobody reads.

The **control plane** is [`bin/fm-control.sh`](../bin/fm-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked `/quit` arrives as ordinary chat - `[fm-from-firstmate] /quit` - which the agent reasons about instead of executing.
The failure repeated across harnesses and homes, and the workaround (remember to use an unmarked send for agent-control commands, and improvise the right key or command per harness) lived only in agent prose, so it failed again every time a session did not happen to recall it.

## What the control plane owns

`bin/fm-control-lib.sh` is the single executable owner of three capability tables, with no side effects, so it can be read as a contract:

- The **verb allowlist**: `interrupt`, `exit`, `relaunch`, `recover-missing`.
  There is no arbitrary-text and no generic raw-key entry point.
  A caller either names an allowlisted verb or is refused.
- **Per-harness mechanics**: the key that cancels a running turn, how many times it must be delivered, whether the composer needs clearing afterwards, the command that exits the agent, and which task kinds the adapter is verified to run.
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's per-adapter tables, which now point here.
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
| `recover-missing` | With `--captain-authorized`, create one fresh Herdr endpoint for an ordinary ship/scout task whose recorded Herdr endpoint is authoritatively missing, then launch the existing brief in the exact recorded local copy. | The new Herdr endpoint is alive, the task identity and recorded copy are unchanged, and the replacement record is atomically published only after that proof. |

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
It is not deterministic across the verified adapters: codex and grok resume only from a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, and kimi have no verified pane-resume contract.
`relaunch` covers the same need on every adapter, because the brief on disk - not a harness-private session - is the durable instruction.

## Transactional relaunch

`relaunch` and `recover-missing` are the verbs that change durable records, so each runs as a transaction with its own journal, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, or `--effort` wins.
   Otherwise a `kind=secondmate` task re-resolves its durable `config/secondmate-harness` pin, including that file's optional model and effort tokens, exactly as every other respawn does - so setting the pin and relaunching is the ordinary way to move a secondmate's runtime.
   A ship or scout keeps the harness already recorded for it, because that harness comes from firstmate's dispatch-profile judgment at intake and must not be silently re-read from configuration.
   A recorded raw-command basename that differs from its resolved adapter cannot reproduce the command actually running, so relaunch refuses before the checkpoint unless the caller passes an explicit `--harness` to choose the replacement runtime deliberately.
   A harness change resets model and effort unless they are named too, because a model chosen for one adapter does not transfer to another.
2. **Safe checkpoint.**
   The recorded worktree must exist and be a worktree root; its head and dirty state are recorded.
   For a `kind=secondmate` task, the home's identity marker must match and its child records must be readable, so a relaunch can never strand child work behind an unreadable home.
   A secondmate's own crewmates run in their own endpoints and outlive its relaunch; the relaunched secondmate reconciles them from its home's durable records at startup.
3. **Record the note.**
   A ship or scout relaunch requires `--note`, because the replacement inherits the local copy but none of the conversation; the note is appended to the instructions it reads.
   A secondmate relaunch does not require one and never rewrites its standing charter.
4. **Stop the old agent** through the `exit` verb, with its postcondition.
5. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`, which adopts the recorded endpoint and worktree instead of creating either, clears the previous harness's per-task wiring, and arms a fresh busy generation.

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.

## Explicit missing-endpoint recovery

The exact command is `bin/fm-control.sh <task-id> recover-missing --captain-authorized --note "<what the replacement must know>"`.
The `--captain-authorized` flag is required on every invocation, so this path is never inferred from a dead pane, a standing autonomy posture, or an automatic recovery sweep.
The note is required for both ship and scout tasks because the replacement reads the durable brief rather than the vanished conversation.

Before this operation existed, the ordinary `fm-spawn.sh <task-id> --relaunch` path refused a recorded Herdr endpoint classified as `missing`, because that path is reserved for a positively agent-free endpoint and does not allocate a new one.
This operation is eligible only when the exact task record in this home is valid, local, `kind=ship` or `kind=scout`, `backend=herdr`, and points at an existing Git worktree root and project.
That recorded copy must also share its Git object store with the recorded project, and no other task record in this home may name the same copy.
A remote route, secondmate, malformed record, missing worktree, missing brief, non-Herdr backend, a copy belonging to a different repository, or a copy a second task record also claims is refused.
The recorded endpoint must classify as `missing`, which means Herdr positively says the recorded pane is absent.
A present pane with no registered agent classifies as `dead` and remains the ordinary `relaunch` case, while a live, ambiguous, or unreadable result refuses this operation.

Those two record-level proofs matter because this operation allocates a NEW endpoint: a foreign checkout would strand the replacement outside the work it must continue, and a copy two records claim would put two tasks in one set of files.

A missing pane is not ownership proof by itself.
Before creating anything, the control plane scans every running Herdr session, task-labeled tab, and foreground process path for a live registered agent carrying the exact task label or the recorded worktree.
A live match or any incomplete or contradictory inventory read refuses the operation.
A pane with no native registration is considered clear only when Herdr's strict process inventory proves it is one idle bare shell; an unregistered non-shell or unreadable process shape remains ambiguous.
The launch owner repeats the ownership proof immediately before allocating the fresh endpoint, then creates exactly one new tab in the recorded Herdr session and workspace.
It moves that new pane into the exact recorded worktree without invoking a fresh worktree provider or creating a second project copy.

The durable transaction is recorded at `state/<id>.control-recover-missing` and the launch attempt keeps exact new endpoint evidence at `state/<id>.recover-missing.<transaction>.attempt`.
The prior metadata remains authoritative while the new pane is created, moved into the existing copy, wired to the recorded harness, and positively classified as alive.
Only then does the launch owner atomically publish a replacement metadata file carrying the same task id, project, worktree, kind, and a fresh Herdr endpoint.
A launch or publication failure never claims recovery, keeps the prior record when it was not published, and retains the attempt evidence for reconciliation.
Starting the operation again while a prior recovery journal exists is refused unless that journal is conclusively `complete` for this exact task and published endpoint, in which case it is retired automatically and a new transaction is permitted; unresolved or malformed prior evidence still blocks a new attempt.
An ordinary `relaunch` preserves the completed transaction's binding in the task's metadata so this reconciliation still works after a later harness switch.
When a launch failure retires the fresh replacement wiring before publication, the rollback also restores the saved brief from its preserved copy and records in the transaction journal whether that restoration succeeded, so the prior record is never left pointing at a brief still carrying the failed replacement's appended recovery instructions.
A replacement record that was published before a later failure is kept rather than rewritten to the disappeared endpoint.

The `fm-spawn.sh --recover-missing` half is internal and accepts only the live parent transaction owned by `fm-control.sh`; direct invocation is refused before endpoint allocation.
This operation does not alter normal `relaunch`, automatic recovery, watcher behavior, secondmate recovery, teardown, or discard semantics.
It is not a force, discard, endpoint-search, fresh-task, or generic bypass mechanism.

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
- `recover-missing` requires the exact task id and the explicit `--captain-authorized` flag.
  It refuses secondmates, remote routes, malformed records, missing copies, and every backend other than a recorded Herdr endpoint.
- A present but agent-free Herdr pane is `dead`, not `missing`, so ordinary `relaunch` remains the only recovery path for that case.
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
- `fm-spawn --relaunch` independently refuses unless the recorded endpoint is positively agent-free and its shell is sitting in the recorded worktree, so a replacement can never join a live agent or start outside the copy holding the work.

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
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction (identity preservation, harness switching, the progress note, checkpoint refusals, rollback after a failed launch) and the explicit missing-Herdr recovery path (ownership proof, endpoint replacement, copy and instructions preservation, rollback, refusal boundaries, and relaunch/secondmate non-regressions).
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
- `tests/fm-backend-herdr.test.sh` - Herdr's missing, dead, live, and ambiguous pane-state classifier.
- The real lifecycle opt-in for this recovery path must use `bin/fm-herdr-lab.sh` with a generated non-default session and verify the default-session tripwire after teardown.
