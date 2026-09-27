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

- The **verb allowlist**: `interrupt`, `exit`, `relaunch`, plus the secondmate park pair `suspend` and `resume`.
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
| `suspend` | Park a persistent secondmate: stop its agent on a positively classified endpoint and write a durable suspension record at `state/<id>.suspended`. The home is preserved byte-for-byte. Manual trigger only; there is no automatic suspension. | The agent is gone per the backend's recovery-grade classifier, the record proves the parked state (task, endpoint, worktree, head, dirty), and the status file carries a `suspended:` event. |
| `resume` | Restore a parked secondmate: requires the durable suspension record it countermands, proves the recorded home is intact, relaunches through `bin/fm-spawn.sh <id> --secondmate` when the recorded endpoint is gone, and removes the record once the agent is confirmed alive. | The secondmate's agent is alive and the suspension record is gone. A task with no record is refused. |

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

**`resume` is not a pane-session verb.**
Restoring a pane-session is not deterministic across the verified adapters: codex and grok resume only from a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, and kimi have no verified pane-resume contract.
`relaunch` covers that need on every adapter, because the brief on disk - not a harness-private session - is the durable instruction.
The `resume` verb exists only as the deterministic countermand of a durable suspension record for a persistent secondmate, described below.

## Secondmate suspend and resume

A persistent secondmate is provisioned to run until retired, and the session liveness sweep revives one whenever its endpoint proves dead or missing.
When the captain wants a secondmate's home parked - proven, preserved, and exempt from that revival - the control plane offers an explicit park pair rather than a pile of lifetime workarounds:

- **`suspend <task-id>`** is manual and secondmate-only (`kind=secondmate`).
  Before stopping anything it proves the recorded home still exists, is a git worktree root, is marked `.fm-secondmate-home = <id>`, and has a readable HEAD and status, so a parked home is one a later resume can actually restore.
  The agent is then stopped through the verified `exit` path (interrupting a busy turn first), and a durable record at `state/<id>.suspended` captures task, timestamp, backend, endpoint, worktree, kind, head, and dirty state.
  An already-gone endpoint parks with `agent=no-agent` rather than being revived.
  The status file carries a `suspended:` event.
- While the record exists, the home is exempt from recovery: `fm-bootstrap.sh`'s session-start liveness sweep skips it, `fm-watch.sh` never probes or reclaims its pane, and `fm-supervise-daemon.sh` classifies its idle pane as `self` - parked by durable record, not a wedge.
  The session-start fleet digest prints `endpoint: suspended` for it.
- **`resume <task-id>`** is the only verb that countermands the record.
  It refuses a task with no record, and refuses one that reads alive despite a record, because a live agent under a park record means something revived the home while parked and the contradiction must be resolved explicitly, not overridden.
  With the recorded endpoint dead (cleared first, mirroring the liveness sweep's discipline) or missing, it relaunches through `bin/fm-spawn.sh <id> --secondmate`, re-resolves the exact endpoint from the published record, waits for a positively alive agent, then removes the suspension record and writes a `resumed:` event.
  A failed relaunch retains the record so a later resume can try again.

A suspended secondmate's retirement is ordinary retirement: `bin/fm-teardown.sh` removes the suspension record as part of the task's record cleanup.

### Non-goals

- Suspend is never automatic; there is no policy that parks a secondmate without an explicit `suspend`.
- Suspend is not a crewmate verb: it is restricted to `kind=secondmate`.
- Remote secondmates are refused by the control plane's target validation exactly as every other verb refuses them; a remotely placed home's park/resume belongs to the lifecycle tooling on its own host.
- `resume` does not recreate a harness-private session; it relaunches the home the way every other respawn does.

## Transactional relaunch

`relaunch` is the only *transactional* verb, so it runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.
`suspend` and `resume` are not transactions: each writes or removes its single park record, and both refuse rather than mutate a half-state.

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
- An unverified harness is refused rather than guessed at.
- An implicit relaunch from a prefixed raw-command basename is refused before the agent or durable state is touched because its original launch command cannot be reconstructed.
- An adapter that is not verified for this task's kind is refused **before** the running agent is stopped, not after.
  muse is a crewmate and scout adapter only, so relaunching a secondmate onto it refuses while its agent is still up rather than leaving that secondmate with no agent when the launch owner refuses.
- A backend that cannot deliver the harness's interrupt key, or the composer clear that key needs, is refused rather than sent a different key.
  Orca's terminal API exposes only an interrupt and an Enter, so it can deliver neither Escape nor Ctrl+U.
- `exit` and `relaunch` require a backend with a recovery-grade agent-state classifier - tmux and herdr - because without one the "the agent stopped" postcondition cannot be proven.
  zellij, orca, and cmux are refused rather than reported as successful blind.
- `suspend` is restricted to a persistent secondmate (`kind=secondmate`).
- `resume` acts only on a durable suspension record: a task with no record is refused, and one that reads alive despite a record is a contradiction the operator must resolve, not a resume target.
- An ambiguous or unreadable endpoint state refuses.
  Only a positively classified state acts.
  On Herdr, a stale registered agent is cleared only after repeated structured reads prove the exact pane contains one recognized bare foreground shell in the recorded worktree - the pane's own shell or a persistent nested task shell, which carry the same proof; a live agent is never cleared, and a mismatched process is never sent exit text.
  Herdr applies an accepted clear asynchronously, so the repair waits a bounded time for the registry to report agent-free before it counts as repaired.
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
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, checkpoint refusals, and rollback after a failed launch.
- `tests/fm-control-suspend.test.sh` - the secondmate park pair: byte-identical suspend/resume round-trip of home, branch, worktree, record, and uncommitted changes, manual-only and secondmate-only enforcement, the liveness-sweep and watcher exemption, resume's relaunch fallback on a gone endpoint, and the record's removal at retirement.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
- `tests/fm-pi-herdr-luna-live-e2e.test.sh` - the opt-in real Pi/Luna launch proof against a named Herdr lab.
