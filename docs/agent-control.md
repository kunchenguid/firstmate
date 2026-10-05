# Agent lifecycle control plane

Firstmate talks to a running agent two ways, and they are not the same channel.

The **data plane** is [`bin/fm-send.sh`](../bin/fm-send.sh): conversational text for the agent to read.
For a `kind=secondmate` target it always prepends the from-firstmate routing marker, because a secondmate is itself a firstmate and its reply must come back through the status path rather than a chat nobody reads.

The **control plane** is [`bin/fm-control.sh`](../bin/fm-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked `/quit` arrives as ordinary chat - `[fm-from-firstmate] /quit` - which the agent reasons about instead of executing.
The failure repeated across harnesses and homes, and the workaround (remember to use an unmarked send for agent-control commands, and improvise the right key or command per harness) lived only in agent prose, so it failed again every time a session did not happen to recall it.

## What the control plane owns

`bin/fm-control-lib.sh` is the single executable owner of three capability tables, which have no side effects, so they can be read as a contract:

- The **verb allowlist**: `interrupt`, `exit`, `relaunch`.
  There is no arbitrary-text and no generic raw-key entry point.
  A caller either names an allowlisted verb or is refused.
- **Per-harness mechanics**: the key that cancels a running turn, how many times it must be delivered, whether the composer needs clearing afterwards, the command that exits the agent, and which task kinds the adapter is verified to run.
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's tool references, which now point here.
  `bin/fm-send.sh`'s `--key` path reads the composer-clear table from this owner too, rather than keeping a second copy of it.
- **Per-backend capability**: which named keys a runtime backend can deliver, and whether it has a recovery-grade agent-state classifier able to prove an agent stopped.

The [endpoint-absence proof](#reclaiming-a-task-whose-endpoint-is-gone) below is the only function here that runs backend reads; sourcing the file is still free.

A recorded `harness=` is not always an exact adapter name: a task launched from a raw command records that command's basename instead.
`fm_control_harness_family` is the one place that prefix rule is stated, and an unrecognized value resolves to no adapter rather than being guessed into one.

## Verbs

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's verified interrupt sequence while leaving the agent running. | Delivery succeeds while the endpoint still exists and the agent is still alive where the backend can classify that; cancellation is confirmed only from an adapter-owned acknowledgement and otherwise reports `cancel=unconfirmed`. |
| `exit` | Stop the agent, preserving the endpoint, the worktree, and every uncommitted change. | The backend's recovery-grade classifier reports the agent gone. Already-stopped is idempotent success. An endpoint reading `missing` goes through the same [absence proof](#reclaiming-a-task-whose-endpoint-is-gone) the reclaim uses before anything is claimed about it: proven gone reports `endpoint-gone` (the agent went with it, and the endpoint this verb normally preserves did not survive), a Herdr pane that turns out to be there and idle is the ordinary `already-stopped`, one whose agent is back takes the ordinary interrupt-then-exit path. A tmux `missing` that its record cannot prove - a record without endpoint identity, or a recorded server that is unreachable or still holding the window - refuses rather than claim a stop it cannot see. |
| `relaunch` | Replace the running agent with a new one in the same worktree - and the same endpoint whenever that endpoint still exists - on the exact recorded adapter or an explicitly chosen harness, model, and effort. | The new agent is alive on the endpoint the task's record now names, and that record names the harness that is actually running. |

An exit that delivers lifecycle input but cannot prove the agent stopped fails with `exit=unconfirmed`, reports the observed agent state and any interrupt cancellation claim, and never claims that nothing changed.
Interrupt never rewrites busy state as proof of its own success.
Claude exposes no lifecycle acknowledgement for a manual interrupt, so delivery succeeds with `cancel=unconfirmed` and its adapter-owned busy state remains as observed.
Devin emits no lifecycle hook for cancellation either, so after an armed interrupt the control plane invalidates the interrupted turn's busy record to `unknown` with `cancel=unconfirmed`; that invalidation is a conservative loss of knowledge, never a fabricated idle.
Devin's double Escape also opens its `/revert` picker on an idle agent, where Enter reverts file changes, so its second press is sent only after the first renders a running turn's armed hint and never sooner than the adapter's press gap.
An interrupt whose first press shows no running turn stops there and reports `cancel=not-running`, leaving busy state untouched; a picker a mistimed press opened is closed with one Escape and reported as `revert-picker=dismissed`, and `exit` refuses to type into an open picker.
[`bin/fm-control-lib.sh`](../bin/fm-control-lib.sh) owns the arm signal, press gap, and picker signal.
muse's session log records `terminal=cancelled` for the interrupted run, so the control plane reports `cancel=confirmed` only after observing that exact acknowledgement.

An interrupt is not complete until the composer is empty.
muse is the one verified adapter that restores the cancelled prompt back into its composer as real text, so its interrupt key is followed by a Ctrl+U clear; without it the next submitted line - including this plane's own exit command - would concatenate onto the restored prompt and submit both as one line.
The clear is refused before anything is sent when the recorded backend cannot deliver it.

`exit` reads the composer's state before typing the exit command and requires the exact `empty` verdict; a `pending` verdict refuses by naming the pending text, and any other verdict (`unknown`, `pending-unproven`, or an unreadable read) refuses as not proven empty, matching the fail-safe contract every other consumer that can overwrite composer input follows.

**Teardown and discard are not verbs and will not become verbs.**
`exit` stops an agent and preserves everything else.
Removing a worktree, closing an endpoint, or discarding work stays with [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), which owns the landed-work test.

**`resume` is not a verb.**
It is not deterministic across the verified adapters: codex, grok, gemini, and devin resume only from a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, omp, kimi, and agy have no verified general pane-resume contract.
`relaunch` uses the brief on disk - not a harness-private session - as the durable instruction when the backend can prove the old agent stopped and the composer is empty; Devin on Herdr currently fails that composer check and refuses.
A relaunch does take one session reference when the endpoint's own runtime recorded it - see [the relaunch transaction](#transactional-relaunch) - but that is a relaunch input, not a caller-facing verb.

## Transactional relaunch

`relaunch` is the only verb that changes durable records, so it runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, or `--effort` wins.
   Otherwise a `kind=secondmate` task re-resolves its durable `config/secondmate-harness` pin, including that file's optional model and effort tokens, exactly as every other respawn does - so setting the pin and relaunching is the ordinary way to move a secondmate's runtime.
   A ship or scout keeps the harness already recorded for it, because that harness comes from firstmate's dispatch-profile judgment at intake and must not be silently re-read from configuration.
   A recorded raw-command basename that differs from its resolved adapter cannot reproduce the command actually running, so relaunch refuses before the checkpoint unless the caller passes an explicit `--harness` to choose the replacement runtime deliberately.
   A harness change resets model and effort unless they are named too, because a model chosen for one adapter does not transfer to another.
   A Claude or Pi replacement must also pass the home's [worker account pin](configuration.md#worker-account-pin-configclaude-account-configpi-account), so a pin that no longer resolves or is signed out refuses before the old agent stops.
2. **Safe checkpoint.**
   The recorded worktree must exist and be a worktree root; its head and dirty state are recorded.
   For a `kind=secondmate` task, the home's identity marker must match and its child records must be readable, so a relaunch can never strand child work behind an unreadable home.
   A secondmate's own crewmates run in their own endpoints and outlive its relaunch; the relaunched secondmate reconciles them from its home's durable records at startup.
3. **Record the note.**
   A ship or scout relaunch requires `--note`, because the replacement inherits the local copy but none of the conversation; the note is appended to the instructions it reads.
   A secondmate relaunch does not require one and never rewrites its standing charter.
4. **Stop the old agent** through the `exit` verb, with its postcondition.
5. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`, which reuses the recorded worktree instead of creating one, adopts the recorded endpoint when it still exists, clears the previous harness's per-task wiring, and arms a fresh busy generation.
   When the recorded endpoint is proven gone rather than merely idle or unreachable - which Herdr establishes from the recorded session and tmux from the endpoint identity its record carries - the launch owner creates one fresh endpoint in that same worktree and the republished record rebinds the task to it - see [Reclaiming a task whose endpoint is gone](#reclaiming-a-task-whose-endpoint-is-gone).
6. **Preserve runtime-bound status authority where supported.**
   The endpoint's runtime may bind pane status to one session identity; the launch owner preserves it only when that runtime records a reference the replacement adapter can consume, and otherwise launches the ordinary fresh session.
   This reference is a launch input, never authority to send, close, or act on the pane.
   [`docs/herdr-backend.md`](herdr-backend.md#agent-status-authority-and-relaunch) owns the mechanism and measured behavior.

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.

### Reclaiming a task whose endpoint is gone

A Herdr pane or workspace can be destroyed out from under a live task by churn or a session restart, and a tmux server can be lost with every window on it by a crash or a restart that wipes `/tmp`.
The task's worktree, branch, commits, and uncommitted changes all survive that; only its terminal does not.

Two endpoint verdicts are agent-free, and both license a relaunch:

- `dead` - the endpoint exists and confidently holds no agent. It is **adopted**, so the task keeps its exact recorded address.
- gone, **proven** - there is no endpoint and therefore no agent, and it cannot be adopted, so the launch owner **creates one fresh endpoint in the recorded worktree** and the republished record rebinds the task to it.

That proof is its own step, because the classifier's `missing` is not one state: it conflates *the endpoint was destroyed* with *the endpoint is unreachable from here right now*.
An unreachable endpoint can still hold the live agent a rebind would duplicate, so absence is proven and never inferred from a failed read.
How it is proven is a property of the backend, and `fm_control_endpoint_absence_verdict` in `bin/fm-control-lib.sh` is the one owner of the dispatch, so `exit` and `relaunch` cannot reach two different answers about one endpoint:

- **Herdr proves it from the recorded session.** Every read goes through the adapter's `--session <session>` CLI, so the recheck starts and reads the session the *record* names, through that session's own socket.
  It starts that server (only the server: no workspace and no tab are created) and **re-reads the recorded pane**.
  `dead` means the pane survived the restart and is adopted after all, with no second tab; `alive` means the agent came back and refuses; only a second `missing` proves the pane itself did not survive ([`docs/herdr-backend.md`](herdr-backend.md) "Restart and liveness behavior").
  That server start is a real side effect, and the parenthetical above does not cover it: when the recorded session's server no longer exists at all, the probe stands a fresh empty one up in order to ask, and nothing afterwards uses it.
  So in that state `exit` - which otherwise reads as a read-only inspection - leaves an idle herdr server behind.
- **tmux proves it from the identity its record carries.** `list-windows -a` describes only the tmux server the *current process* addresses (its `TMUX_TMPDIR`/socket), so a server-wide read cannot tell a destroyed window from one on a server this process cannot address, and it is never the proof.
  Every tmux record written by `bin/fm-spawn.sh` therefore names the server instance that hosted its window: `tmux_socket`, `tmux_server_pid` and `tmux_server_start` (together one server *instance*, which a reused pid or a reused socket path cannot impersonate), `tmux_window_id` (which survives a rename or a move between sessions), `endpoint_host`, and `endpoint_boot`.
  [`bin/fm-endpoint-proof-lib.sh`](../bin/fm-endpoint-proof-lib.sh) owns the fields and the proof, which rests on exactly one of three facts: the host rebooted since the record was written (same host identity, different boot id, so nothing of that boot is running), the recorded server instance is gone (its socket refuses or no longer exists and no tmux process holds the pid, or the socket is now served by a different instance), or the live recorded server no longer has the recorded window id.
  After any of them the worktree is still checked for live processes: a same-user non-shell process working in it, or carrying `FM_TASK_ID=<id>`, vetoes the proof, because an agent that outlived its server is exactly the duplicate this guards against.
  Everything else is `unproven` and refuses as before: a failed or timed-out read (every read is bounded, and captured through a file because a tmux client hands its stdout to the server, so a stopped server would otherwise hold a pipe capture open past the bound), a permission error, a record written on another host, a live recorded server that still has the window - alive, renamed, or moved - and a record whose identity is incomplete or invalid.
  A tmux record written before the identity existed is [legacy](#legacy-tmux-records-and-the-explicit-consent).

Every transient or self-contradicting read stays `unreadable` or `ambiguous` and still refuses, so a momentary backend failure can never be mistaken for absence.

`exit` reports what the proof established and nothing more - see its row in the verb table above.

What a reclaim is not:

- It is **not a teardown**. The worktree is reused exactly as the previous agent left it; nothing unlanded is ever discarded, and the ordinary `--note` requirement still applies.
- It does **not** change the task's identity. The task id, its armed poll and registration, and its status log are untouched; only the endpoint binding in the record moves.
  Its instructions are the one exception, and only in the way an ordinary relaunch already changes them: a ship or scout reclaim appends the required `--note` under a `## Progress note (<timestamp>)` heading in `data/<id>/brief.md`, so re-read that brief rather than assuming it is byte-identical - a reclaim that failed and was retried leaves one block per attempt.
  A secondmate's standing charter is never rewritten.
- It is **not** a peer seat's operation. `fm-control` resolves an exact task id against **this** home's `state/`, so only the home that owns the task can reclaim it.
- It does **not** cover a secondmate. A secondmate whose endpoint is gone already has one recovery path - `bin/fm-spawn.sh <id> --secondmate`, driven by the session-start sweep or the watcher's liveness tick - so control-plane reclaim refuses and names it rather than becoming a second path to the same outcome.

The re-created tab is opened in the herdr session the record names, never in whichever session the recovering seat happens to sit in - relocating a task onto another herdr server would be an identity change published as a self-consistent but wrong record.
A seat that *claims* a herdr launcher pane belonging to a different session is refused rather than allowed to place the endpoint somewhere else, so reclaim such a task from a seat in the recorded session.
A seat with no herdr launcher pane at all - a plain ssh or cron shell, which is the ordinary way an operator reclaims - is not refused: placement falls back to the recorded session's labeled container, so the tab still lands in the session the record names.
The reclaim pins the recorded **session** but not the **workspace**: the container follows the reclaiming seat, so a reclaim run from a seat inside the recorded session places the new tab in *that seat's* workspace rather than the recorded `herdr_workspace_id`, even when the recorded workspace still exists and only the pane was destroyed.
The record is republished consistently and no work is lost, but the task's `herdr_workspace_id` moves with it.
The pane id necessarily changes (the pane did not survive), and the record follows it.
A Herdr reclaim deliberately uses the flat container shape rather than presentation projection: projection is a presentation-only layout that is never endpoint or ownership authority, and flat is already the documented fallback for every recovery it cannot bind exactly ([`docs/herdr-backend.md`](herdr-backend.md)).

**Known limitation - a refusal before the record is republished leaves a stray husk pane** (follow-up bead `fm-herdr-rebind-leak-20260913`).
The rebind registers no abort cleanup, so a refusal in the window between the new tab being created and the record being republished leaves that pane behind while the record still names the old, gone one.
The stray pane holds a bare shell - the harness is not delivered until after publication - so the next reclaim cleans up after it: the re-created tab carries the same `fm-<id>` label, `tab create` finds it, classifies it a husk, and closes and replaces it.
That self-heals only when the retry resolves the *same* workspace, which the placement rule above does not guarantee.
The worktree and the task's records are unaffected either way.

A tmux rebind opens its fresh window directly in the recorded worktree, on the tmux server the recovering seat addresses: in the seat's own session when it runs inside tmux, otherwise in the detached `firstmate` session.
The recorded server is proven gone, so there is no other server to keep the task on, and the record is republished with the new window's label and identity.
The window is closed again, by its exact id, if the spawn aborts before any launch text reached it, so a refused attempt leaves nothing for a retry to trip over; once the record is republished the window is the task's endpoint and is never closed by the abort path.
A relaunch that adopts a live tmux window refreshes the record's identity from that window, so a record written before the identity existed gains it at its next relaunch.

### Legacy tmux records and the explicit consent

A tmux record spawned before the identity existed carries nothing a proof can start from, and nothing is claimed for it: `exit` and `relaunch` refuse its `missing` endpoint exactly as they always did.
The one way through is an explicit, specific, recorded consent, and it exists for the situation this plane was blind to - the tmux server that hosted the task is gone, the worktree and its work are intact, and the operator is certain the old agent died with it.

1. `FM_HOME=<home> bin/fm-endpoint-proof.sh <id>` prints the evidence that can still be read and changes nothing: host and boot identity, whether the record predates this boot, the server this seat addresses (where a replacement would open), every reachable tmux server of this user and whether any holds a window for the task, the servers it could not read, and the worktree's live processes.
   It ends with a `consent-digest` over exactly the decision-relevant evidence.
   While the evidence names a live window or process there is no digest and the report says `consent: not possible`; no consent ever overrides a live agent.
   A tmux server of this user that the report could not match to a scanned socket (one started with its own `TMUX_TMPDIR`, say) is listed as a warning and is not part of the digest, so confirm none of them hosts the task before asking.
2. On the captain's explicit word for that task, `bin/fm-control.sh <id> relaunch --note <text> --legacy-endpoint-consent <digest>` passes the digest back.
   It verifies only while the evidence is byte-identical, so a restarted server or a process that appeared since the review voids it, and the refusal prints the current digest.
   It is refused while the away-posture record exists, because nobody who could speak for the captain is watching, and it is never accepted for a record that carries identity - a complete record is decided by its proof alone, so an unreachable or live recorded server is never overridden.
3. Before anything is stopped, the consent is appended to `state/<id>.endpoint-consent` with the evidence it rested on, and the journal names the digest; `bin/fm-endpoint-proof.sh consents <id>` re-digests each recorded block, so a consent can be audited, and an altered one stops matching.
   The relaunch then rebinds the task like any proven reclaim, and the record it publishes carries identity, so a repeated recovery of the same task needs no second consent: after the first relaunch the window is adopted, never duplicated.

The consent is the operator's decision about a fact the machine could not establish, with the evidence it was made on kept beside it; it is not a proof and is never reused as one.
The evidence is shown, not trusted: a record-versus-boot comparison rests on the wall clock, which is why it informs the operator and never carries a verdict.

`bin/fm-endpoint-proof.sh backfill <id|--all>` gives a *live* legacy tmux record the identity it lacks, by reading the window through its exact label on the server this seat addresses and appending the lines under the task's meta lock by atomic replace.
Run it while tmux is healthy, once after updating firstmate, so the next loss of a server is provable instead of needing a consent.
It is a no-op for a record that already carries identity, a missing endpoint, or any other backend.

Known limits, stated rather than hidden:

- The proof compares host and boot identity but not pid or mount namespaces, so a record written inside a container that shares the host's machine id and boot id cannot be told apart from one on the host.
- A process that is not visible to this user (another account's) cannot veto.
- On a platform without `/proc` the process check reads `lsof` and cannot see the `FM_TASK_ID` marker.
- The identity is consulted only when the server this seat addresses reads the endpoint `missing`. A same-named, agent-free window already present on this seat's server is still adopted by its name, as before, without checking whether the recorded identity names a different server that is alive: the recovery that creates such a window refuses unless the recorded server is proven gone, but a window put there by other means is trusted.
- A tmux server of this user outside the scanned socket directories cannot be matched to a socket, so the legacy evidence lists it as a warning outside the digest, and confirming it does not host the task stays with the operator.

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
  For `relaunch`, drive the host through [`bin/fm-remote-secondmate-relaunch.sh`](../bin/fm-remote-secondmate-relaunch.sh), which runs `bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch ...` and then republishes this home's route record from the identity the host confirmed; the host-local leg runs this same plane against a record that is ordinary and local there, so every checkpoint, journal, rollback, and postcondition below applies unchanged ([`docs/remote-secondmates.md`](remote-secondmates.md)); `interrupt` and `exit` have no such route.
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
- `exit`'s composer-empty check, above, is itself a fail-closed boundary that `relaunch` inherits by stopping the old agent through `exit`.
- `fm-spawn --relaunch` independently refuses unless the endpoint is positively agent-free - either a `dead` endpoint that survives, or a Herdr endpoint proven gone by the absence proof above - so a replacement can never join a live agent.
  An `alive`, `ambiguous`, or `unreadable` verdict all refuse, and so does any endpoint whose absence is not provable, which on tmux is a `missing` whose record carries no identity (without a reviewed consent) or whose recorded server is unreachable or still holds the window; absence is claimed only from positive evidence of it.
  It also requires the shell to be in the recorded worktree: every backend but Orca (which owns its own task worktree with no current-path probe) gets one explicit `cd` to the recorded path, then a pre-launch path read that refuses before any harness starts unless it confirms the endpoint is sitting in the recorded copy.

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
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, checkpoint refusals, rollback after a failed launch, and the endpoint-absence proof both verbs share - the Herdr reclaim of a destroyed endpoint, the tmux reclaim from a record's identity, the legacy consent (wrong digest, live process, away posture, accepted digest), repeated recovery, and tmux refusing every endpoint it cannot prove absent.
- `tests/fm-endpoint-proof.test.sh` - the tmux identity and proof against real tmux servers on private sockets: a server that is gone or replaced, a window gone from a live server, an endpoint alive elsewhere (renamed or moved), a stopped or unreadable server (bounded), a reboot and another host, a live process in the worktree, legacy evidence and its digest, the consent record, dirty work left untouched, and the idempotent backfill.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
