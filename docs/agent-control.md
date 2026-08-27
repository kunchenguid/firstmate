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

- The **verb allowlist**: `interrupt`, `exit`, `relaunch`.
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
| `relaunch` | Replace the running agent with a new one in the same worktree, normally reusing its endpoint and recreating it before launch only when a runtime that answered reports it missing, on the exact recorded adapter or an explicitly chosen harness, model, and effort. | The new agent is alive on the validated replacement endpoint, and the durable record names both that endpoint and the harness that is actually running. |

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

`relaunch` is the only verb that changes durable records, so it runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.

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
4. **Classify and stop the old agent.**
   An alive or agent-free endpoint follows the ordinary `exit` postcondition.
   A missing endpoint has no agent to stop, so the transaction records that fact and proceeds without sending lifecycle input - subject to the missing-endpoint decision below.
   Ambiguous, unreadable, and unverified states refuse before the progress note or durable record changes.
5. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`.
   The ordinary path adopts the recorded endpoint and worktree.
   Missing-endpoint recovery asks the launch owner to recheck that the endpoint is still missing, recreate only the shell endpoint in the recorded worktree, and publish the validated replacement identity.
   A `kind=secondmate` recovery keeps the home that `validate_firstmate_home_for_spawn` resolved rather than the raw recorded worktree, exactly as the endpoint-adopting path does.
   Both paths clear the previous harness's per-task wiring and arm a fresh busy generation.

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.

### The missing-endpoint decision

`missing` is not one observation. It is two, and only one of them proves that nothing can still be running at the recorded address.

| Verdict | What was observed | What relaunch does |
| --- | --- | --- |
| **strong missing** | A runtime **answered**: tmux read the session inventory and the recorded window is not in it, or tmux replied `can't find session` - which only a live server can say. Herdr's classifier reaches `missing` only from a successful pane read, so its missing is always strong. | Recreates the endpoint automatically in the recorded worktree. Nothing can be running at an address a reachable runtime says is empty. |
| **ambiguous missing** | Nothing positively accounted for the recorded window. The runtime itself could **not be reached** - tmux answered `no server running on <socket>` or `error connecting to <socket>` - or the grade's own read no longer showed the window absent. | Stops and asks. Nothing is created, stopped, or written. |
| **alive** | A verified harness agent is running. | Never recreates an endpoint. The ordinary relaunch replaces the agent in the endpoint it already has. |

An unreachable socket says only that *this process* cannot see a runtime there.
It cannot distinguish a wiped runtime from a server behind a different `TMUX_TMPDIR`, socket name, or user - and on the second reading, recreating the endpoint would start a second agent in a worktree the first one is still working in.
The liveness verdict and the grade are two separate reads of the runtime, so the grade is taken from what its own read saw rather than from the earlier `missing`: an inventory that now lists the window grades ambiguous rather than quoting tmux as authority for the absence of a window that is sitting right there.

So an ambiguous verdict is surfaced as a decision rather than a dead end - a wiped runtime is exactly the case that needs recovery, and a human can see what a socket probe cannot.
The refusal names the exact socket consulted and the backend's own response, states that the durable record, progress note, and worktree are untouched, and names the continuation: confirm no runtime anywhere holds that endpoint and no agent is still working in the worktree, then re-run with `--confirm-endpoint-gone`.

That confirmation grants no standing authority.
It is consumed by the one invocation that carries it, and only while the endpoint still classifies missing.
`fm-spawn --relaunch` re-reads the state under the lifecycle locks and refuses anything but `missing`, and the backend's create step classifies the address once more before creating anything, so a runtime that has come back - or an endpoint that reads alive - still refuses.
Passing `--confirm-endpoint-gone` at an alive or agent-free endpoint applies nothing: it is reported as not applied, and the relaunch proceeds as the ordinary in-place replacement.

### Failure and rollback

- A preflight refusal **before** the progress note is recorded leaves the durable record and the instructions byte-identical.
- A launch failure **after** the agent is stopped restores the prior durable record, keeps the progress note so a later recovery still has it, marks the journal `failed:launching`, and reports plainly that no agent is running and where the work is preserved.
- A missing-endpoint recreation failure before publication likewise keeps the prior durable record and progress note, with the existing worktree untouched.
  An endpoint the recovery already created is kept too, not cleaned up on the way out, because this plane closes no endpoint even one it opened moments earlier.
- If the launch owner already published the new record but no running agent can be confirmed, the new record is kept: the task is recorded on the new harness with no agent confirmed, which is exactly what recovery reconciles.
  Rewriting it back to the old harness would be a second, worse inaccuracy.

## Fail-closed boundaries

- Targeting is exact.
  Only a bare task id with a `state/<id>.meta` record in this home is accepted, and that record must pass the shared endpoint-identity validation.
  A legacy `fm-<id>` window label, an explicit `session:window` endpoint, and a record whose `endpoint_task_id` names another task are all refused.
- A remotely placed secondmate is refused by name.
  Its agent runs on another host, so none of the postconditions this plane verifies could be read for it here; local endpoint validation would refuse the record regardless, because `window=remote:<id>` can never match a local backend's required shape.
  Drive that lifecycle on its own host and reconcile it through the secondmate recovery path.
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
- Creating a replacement endpoint requires a `missing` verdict from a runtime that **answered**.
  An unreachable runtime cannot prove that no agent holds the worktree, so it becomes a human decision (`--confirm-endpoint-gone`) rather than an automatic recovery.
- `fm-spawn --relaunch` independently requires either a positively agent-free recorded endpoint or an explicit missing-endpoint recovery whose `missing` verdict it rechecks under the lifecycle locks.
  It verifies the adopted or recreated shell is sitting in the recorded worktree, so a replacement can never join a live agent or start outside the copy holding the work.

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
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, checkpoint refusals, rollback after a failed launch, and the missing-endpoint decision - strong recovery into the recorded worktree with its uncommitted work intact, the ambiguous decision that changes nothing before and after `--confirm-endpoint-gone`, a confirmation that still refuses a live endpoint, a secondmate recovering into its validated home, and repeat recovery that never creates a duplicate endpoint.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
- `tests/fm-backend-tmux-smoke.test.sh` - the missing grade and endpoint recreation against a real tmux server on a private socket, which is where the answers quoted in the decision table above come from.
