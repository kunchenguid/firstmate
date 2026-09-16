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
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's tool references, which now point here.
  `bin/fm-send.sh`'s `--key` path reads the composer-clear table from this owner too, rather than keeping a second copy of it.
- **Per-backend capability**: which named keys a runtime backend can deliver, and whether it has a recovery-grade agent-state classifier able to prove an agent stopped or its endpoint gone.

A recorded `harness=` is not always an exact adapter name: a task launched from a raw command records that command's basename instead.
`fm_control_harness_family` is the one place that prefix rule is stated, and an unrecognized value resolves to no adapter rather than being guessed into one.

## Verbs

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's verified interrupt sequence while leaving the agent running. | Delivery succeeds while the endpoint still exists and the agent is still alive where the backend can classify that; cancellation is confirmed only from an adapter-owned acknowledgement and otherwise reports `cancel=unconfirmed`. |
| `exit` | Stop the agent, preserving the endpoint, the worktree, and every uncommitted change. | The backend's recovery-grade classifier reports the agent gone. Already-stopped is idempotent success. |
| `relaunch` | Replace the running agent with a new one in the same endpoint and worktree, on the exact recorded adapter or an explicitly chosen harness, model, effort, and account slot. | The new agent is alive on the recorded endpoint, and the durable record names the harness that is actually running. |
| `recover-missing` | Recreate the exact recorded terminal for a task whose tmux endpoint is missing - the window alone, or the whole session it lived in - then hand the launch to the existing owner (`fm-spawn.sh --relaunch`) on the recorded harness, model, effort, and account slot. | The backend's recovery-grade classifier proves the agent was missing, unavailable/dirty worktrees refuse rather than repairing, and the new agent is alive on the exact recreated terminal. |

An exit that delivers lifecycle input but cannot prove the agent stopped fails with `exit=unconfirmed`, reports the observed agent state and any interrupt cancellation claim, and never claims that nothing changed.
Interrupt never rewrites busy state as proof of its own success.
Claude exposes no lifecycle acknowledgement for a manual interrupt, so delivery succeeds with `cancel=unconfirmed` and its adapter-owned busy state remains as observed.
muse's session log records `terminal=cancelled` for the interrupted run, so the control plane reports `cancel=confirmed` only after observing that exact acknowledgement.

An interrupt is not complete until the composer is empty.
muse is the one verified adapter that restores the cancelled prompt back into its composer as real text, so its interrupt key is followed by a Ctrl+U clear; without it the next submitted line - including this plane's own exit command - would concatenate onto the restored prompt and submit both as one line.
The clear is refused before anything is sent when the recorded backend cannot deliver it.

`exit` reads the composer's state before typing the exit command and requires the exact `empty` verdict; a `pending` verdict refuses by naming the pending text, and any other verdict (`unknown`, `pending-unproven`, or an unreadable read) refuses as not proven empty, matching the fail-safe contract every other consumer that can overwrite composer input follows.

**Teardown and discard are not verbs and will not become verbs.**
`exit` stops an agent and preserves everything else.
Removing a worktree, closing an endpoint, or discarding work stays with [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), which owns the landed-work test.

**`resume` is not a verb.**
It is not deterministic across the verified adapters: codex, grok, and gemini resume only from a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, omp, kimi, and agy have no verified pane-resume contract.
`relaunch` covers the same need on every adapter, because the brief on disk - not a harness-private session - is the durable instruction.

## Transactional relaunch

`relaunch` and `recover-missing` are the only verbs that change durable records, so each runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, `--effort`, or `--account-slot` wins.
   Otherwise a `kind=secondmate` task re-resolves its durable `config/secondmate-harness` pin, including that file's optional model and effort tokens, exactly as every other respawn does - so setting the pin and relaunching is the ordinary way to move a secondmate's runtime.
   A ship or scout keeps the harness already recorded for it, because that harness comes from firstmate's dispatch-profile judgment at intake and must not be silently re-read from configuration.
   A recorded raw-command basename that differs from its resolved adapter cannot reproduce the command actually running, so relaunch refuses before the checkpoint unless the caller passes an explicit `--harness` to choose the replacement runtime deliberately.
   A harness change resets model, effort, and any recorded account slot unless they are named too, because neither a model nor a subscription profile chosen for one adapter transfers to another.
   `--account-slot` applies to ship and scout workers only, and it re-resolves against the home-local registry owned by [configuration.md](configuration.md#account-slots-configaccount-slotsjson) here, before anything is stopped.
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

### Recovering a missing terminal

`recover-missing` runs the same transaction for a task whose terminal is gone rather than agent-free, which is the one state `relaunch` cannot act on: it refuses a missing endpoint, and `fm-spawn.sh --relaunch` adopts only a surviving endpoint.
It differs from the steps above in exactly three places.

- No profile flags. `--harness`, `--model`, `--effort`, and `--account-slot` are refused; a recovery continues the same run, and choosing a different runtime or account is what `relaunch` is for.
  Only `--note`/`--note-file` apply, and a ship or scout still requires one for the same reason a relaunch does.
  Nothing is re-resolved from configuration either: every identity axis comes from the task's own durable record, so a secondmate whose `config/secondmate-harness` pin has since changed is recovered on the harness, model, and effort it actually recorded.
  Picking the changed pin up is a `relaunch`, which is the verb that deliberately re-resolves it.
- Two extra preconditions around the checkpoint: the endpoint must read the positively `missing` state, and the recorded local copy must be present, free of uncommitted changes beyond the spawn's own untracked leftovers, and - for a Treehouse pool slot - still claimed by this task.
  Each of those refuses rather than cleaning, reallocating, or repairing anything; no worktree and no pool slot is ever created here.
- No stop step. Nothing is running, so step 4 is replaced by recreating the window under the recorded `fm-<id>` name in the recorded session and worktree, then waiting on a bounded budget for the new terminal to hold an agent-free state before step 5 hands it to the same launch owner.
  A login shell that is still running its rc files reads `ambiguous` while each of them owns the pane, and the launch owner takes one un-retried state read that must be `dead`, so the state has to hold rather than merely be observed once.

#### A signed-out account slot with a missing terminal

One combination cannot be brought back through either verb.
It happens when a worker was launched on an account slot, that slot's store no longer holds a usable credential - for example after signing out of that account under the store - and then the worker's terminal or its whole session is gone.

- `recover-missing` refuses while resolving the recorded slot, before it reads the endpoint, reporting that the slot's store holds no vendor-managed credential.
- `relaunch` refuses the same way without flags. With `--account-slot default` it gets past the slot and then refuses because the terminal is gone and there is no agent to stop.

These refusals are intended, not a bug.
The worker's local copy and its uncommitted work are untouched, and each verb stops rather than guessing which account a rescued worker should spend.
There are two ways out:

1. Sign in again under that slot's store, so the recorded slot resolves, then run `recover-missing`.
2. Remove the `account_slot=` line from the task's `state/<id>.meta` record by hand, then run `recover-missing`. The worker comes back on the harness's normal credentials instead of a slot.

### Failure and rollback

- A refusal **before** the agent is stopped leaves the durable record and the instructions byte-identical.
- A launch failure **after** the agent is stopped restores the prior durable record, keeps the progress note so a later recovery still has it, marks the journal `failed:launching`, and reports plainly that no agent is running and where the work is preserved.
- If the launch owner already published the new record but no running agent can be confirmed, the new record is kept: the task is recorded on the new harness with no agent confirmed, which is exactly what recovery reconciles.
  Rewriting it back to the old harness would be a second, worse inaccuracy.
- A `recover-missing` failure while the terminal is being recreated restores the prior record and the prior instructions byte-exact, because no agent was ever touched in that phase.
- A `recover-missing` failure once the terminal is back - the new shell never settling to agent-free, or the launch itself failing - never claims an agent was stopped, and names the state the operator is now in: the recreated terminal holds a bare shell, so the endpoint reads `dead` rather than `missing` and the verb that retries it is `relaunch`.

## Fail-closed boundaries

- Targeting is exact.
  Only a bare task id with a `state/<id>.meta` record in this home is accepted, and that record must pass the shared endpoint-identity validation.
  A legacy `fm-<id>` window label, an explicit `session:window` endpoint, and a record whose `endpoint_task_id` names another task are all refused.
- A remotely placed secondmate is refused by name.
  Its agent runs on another host, so none of the postconditions this plane verifies could be read for it here; local endpoint validation would refuse the record regardless, because `window=remote:<id>` can never match a local backend's required shape.
  Drive that lifecycle on its own host and reconcile it through the secondmate recovery path.
  For `relaunch` that host-side drive is `bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch ...`, whose host-local leg runs this same plane against a record that is ordinary and local there, so every checkpoint, journal, rollback, and postcondition below applies unchanged ([`docs/remote-secondmates.md`](remote-secondmates.md)); `interrupt`, `exit`, and `recover-missing` have no such route.
- An unverified harness is refused rather than guessed at.
- An implicit relaunch from a prefixed raw-command basename is refused before the agent or durable state is touched because its original launch command cannot be reconstructed.
  `recover-missing` refuses such a record outright rather than pointing at `--harness`, because it takes no profile flags: bringing the terminal back on a different runtime than the record names is not a recovery.
- An adapter that is not verified for this task's kind is refused **before** the running agent is stopped, not after.
  Muse is a crewmate and scout adapter only, so relaunching a secondmate onto it refuses while its agent is still up rather than leaving that secondmate with no agent when the launch owner refuses.
  The same table refuses a `recover-missing` before the terminal is recreated, where there is no running agent to stop and nothing has been touched at all.
- A backend that cannot deliver the harness's interrupt key, or the composer clear that key needs, is refused rather than sent a different key.
  Orca's terminal API exposes only an interrupt and an Enter, so it can deliver neither Escape nor Ctrl+U.
- `exit`, `relaunch`, and `recover-missing` require a backend with a recovery-grade agent-state classifier - tmux and herdr - because without one the "the agent stopped" or "the endpoint is missing" postcondition cannot be proven.
  zellij, orca, and cmux are refused rather than reported as successful blind.
- `recover-missing` additionally requires a backend that can recreate a terminal under the recorded endpoint handle, which today is tmux only: its window keeps the recorded `fm-<id>` name, so recovery rewrites no durable record.
  Herdr mints a fresh pane id for every new tab, so recreating there would have to republish the task's endpoint; that is refused rather than shipped without regression coverage.
- On tmux, two different losses read as a missing endpoint and both are recovered: the task's window is gone from a session that is still alive, or the whole session - or the whole tmux server - is gone.
  The second is recreated session first, under the exact recorded session name, and then the window inside it; a session that still exists is left exactly as it is.
  A session that cannot be recreated refuses before the window, the record, or the instructions are touched.
- An ambiguous or unreadable endpoint state refuses.
  Only a positively classified state acts.
- `exit`'s composer-empty check, above, is itself a fail-closed boundary that `relaunch` inherits by stopping the old agent through `exit`.
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

Per-harness interrupt keys, repeat counts, composer clears, exit commands, and supported task kinds live in `bin/fm-control-lib.sh` and are exercised for every verified harness by `tests/fm-control.test.sh`, with adapters outside its lane pinning their control mechanics in their own harness suites.
The empirical basis for each adapter's value is the `harness-adapters` skill's verification record for that adapter.

## Verification

- `tests/fm-control.test.sh` - the adapter contract for its verified-harness lane (adapters outside the lane pin their control mechanics in their own harness suites), the backend capability matrix, exact-id scoping, the closed verb list, the busy, idle, dead, and idempotent lifecycle cases, and marker non-regression, all against a stubbed session provider.
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, checkpoint refusals, rollback after a failed launch, and an already-armed merge poll still authenticating after the record rewrite.
- `tests/fm-control-recover-missing.test.sh` - the missing-terminal recovery: the success path under the recorded handle for both losses (a missing window in a live session, and a whole gone session recreated before it), the live, ambiguous, absent-copy, dirty-copy, and pool-slot-ownership refusals leaving the record and instructions byte-identical, the refusal when the session cannot be recreated, the recorded profile surviving a differing configured secondmate pin, the spawn-leftover dirt exemption against real untracked work, the refused profile flags, the basename-harness and unsupported-backend refusals, a still-starting shell being waited out rather than handed over and the refusal when it never settles, and the message after a failed launch handoff.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
