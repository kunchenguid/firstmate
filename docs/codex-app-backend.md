# Codex Desktop host lifecycle

Codex Desktop can run Firstmate-managed ship and scout tasks natively when the primary is itself a Desktop task and uses the app host tools for task lifecycle.
This is recorded as `backend=codex-app-host` in task metadata.

`codex-app-host` is deliberately not a value for `FM_BACKEND`, `config/backend`, or `fm-spawn.sh --backend`.
The Desktop host creates, sends, reads, waits for, and archives the visible task; Firstmate's shell helpers own the durable identity and reconciled state.
The unsupported value `codex-app` continues to be refused by the normal spawn dispatcher.

## Ownership split

The Desktop host owns:

1. It creates a task in an exact saved project and isolated Desktop worktree.
2. It returns the task's durable `threadId`, `hostId`, and worktree path.
3. It sends initial and follow-up turns.
4. It reads bounded transcript/state and waits for attention or completion.
5. It archives the exact task only after Firstmate's archive preflight succeeds.

Firstmate owns:

1. Firstmate owns the task id and exact task/worktree metadata binding.
2. Firstmate owns `state/<id>.status` as the append-only return/wake event log.
3. Firstmate owns `state/<id>.codex-app-current` as the current-state record.
4. Firstmate translates host observations into lifecycle events.
5. Firstmate refuses mutations outside the live session lock.

The event log and current state are intentionally separate.
A last status line can remain historical after a task resumes; `fm-crew-state.sh` reads the exact current-state record for `codex-app-host` and never infers current state from the log tail.

## Cross-project permission boundary

Codex Desktop derives a repository task's writable filesystem scope from the saved project that created the task.
Discovering a global skill through a readable symlink does not add the skill's source repository as another writable project.
An external repository task that starts the installed `bin/fm-session-start.sh` directly therefore reaches the Firstmate lock path in a read-only permission context, even when Unix mode bits show that the account owns the directory.

`bin/fm-desktop-entry.sh` is the read-only routing boundary.
It compares Git common-directory identity and reports `mode=direct` only for a task already running in the Firstmate repository or one of its worktrees.
Every other repository gets `mode=coordinator`: the source task creates one visible Desktop-owned Firstmate worktree, passes the complete request and exact source project to it, then waits for and relays that coordinator's result.
The coordinator uses its own writable top level as `FM_HOME`, starts the session exactly once, and owns every target ship or scout through the host lifecycle below.
The source task never substitutes ordinary subagents or project work of its own.

## Desktop workflow

Preflight must prove that the current primary is Codex Desktop and the task host tools are exposed.
If an exact known local checkout is absent from Desktop's project list, the primary opens that path with Codex Desktop and refreshes the list; project registration is not a routine captain step.
Start the Firstmate session in a tracked PTY so the thread-bound lease remains live.

For each task:

1. Create the visible task with the Desktop host tool in an isolated worktree.
2. Record the exactly five routing factors with `bin/fm-task-model-route.sh` and select a `small`, `normal`, or `research` envelope.
3. Read the returned task identity and actual worktree path.
4. While holding the Firstmate session lock, register that exact identity:

   ```sh
   bin/fm-codex-app-task.sh register <id> \
     --thread <thread-id> --host <host-id> \
     --project <saved-project-checkout> --worktree <desktop-worktree> \
     --kind <ship-or-scout> --model <model> --effort <effort> \
     --route-record <absolute-routing-record> \
     --session-envelope <small|normal|research> \
     --mode <direct-PR|local-only> --yolo <on|off>
   ```

5. Verify `state/<id>.meta`, the writable status file, and `bin/fm-crew-state.sh <id>` before treating the task as supervised.
6. Use the Desktop wait/read tools for host truth.
   Reconcile every meaningful state transition and optionally append its verified lifecycle event:

   ```sh
   bin/fm-codex-app-task.sh reconcile <id> \
     --thread <observed-thread-id> --host <observed-host-id> \
     --generation <observed-generation> --epoch <observed-observation-epoch> \
     --state <working-or-terminal-state> --detail '<bounded evidence>' \
     --event '<working|needs-decision|blocked|paused|done|failed>: <detail>'
   ```

   Pass the thread, host, generation, and observation epoch attached to the observed result so a delayed result from a stopped or superseded endpoint cannot mutate the current task.
7. Use the Desktop send tool for follow-ups.
   Never imitate a send by editing a transcript or local ledger.
8. Reconcile the final state, then run `bin/fm-codex-app-task.sh archive-preflight <id> --report <absolute-firstmate-home>/data/<id>/report.md`.
   Desktop archive removes its app-owned worktree.
   The preflight allows a completed scout only when its non-empty canonical task report is retained at `data/<id>/report.md` outside that worktree, and refuses ship tasks until their implementation is independently landed or explicit discard is authorized.
   Call the Desktop archive tool only after a successful preflight.
   Generic `fm-teardown.sh` still refuses host-owned tasks and preserves their Firstmate records.

Worker-written status lines are valid when Desktop permissions allow the exact Firstmate state path.
When they do not, the primary records only transitions it has actually observed through the host wait/read tools.
It must never invent a worker event from an old status tail.

## Durable metadata

A registered host task carries the normal task fields plus:

```text
backend=codex-app-host
endpoint_task_id=<firstmate-task-id>
window=<desktop-thread-id>
codex_app_thread_id=<desktop-thread-id>
codex_app_host_id=<desktop-host-id>
worktree=<actual-desktop-worktree>
git_common_dir=<registered-project-git-common-directory>
mode=<direct-PR-or-local-only>
yolo=<on-or-off>
model_route_record=<absolute-routing-record>
model_route_sha256=<routing-record-digest>
session_envelope=<small-or-normal-or-research>
session_generation=<positive-integer>
observation_epoch=<positive-integer>
session_cost_telemetry=unsupported
session_context_telemetry=unsupported
session_compaction_telemetry=unsupported
session_output_telemetry=unsupported
```

Endpoint validation requires one exact value for every binding and refuses a mismatched task id, thread id, host id, project, worktree, or Git common-directory identity before mutation.
Registration refuses to overwrite pre-existing task records, accepts only `direct-PR` or `local-only` with an explicit `on` or `off` project `yolo` posture, and refuses a worktree that resolves to the saved project checkout.
The shared routing parser requires the ordered five factors and their evidence, recomputes the score, floor, override, and deterministic selection, and rejects missing, duplicate, extra, or inconsistent rows.
Each configured quota profile records its model, effort, truthful quota eligibility, rejection reason, and candidate-specific evidence independently of the routing floor or explicit captain override.
The floor and explicit override constrain only selection of the resolved profile, so an otherwise quota-eligible candidate remains eligible when it is unselected by either constraint.
The selected eligible profile is separate from both the deterministic result and any explicit captain override.
Registration binds the exact routing record digest and every later host mutation refuses changed routing evidence.
Every Desktop task operation passes one process-identity-bound mutation owner whose initialization is serialized before concurrent admission and that blocks sibling operations while registration, resume, or hard-stop recovery is incomplete.
Registration, resume, and hard stop publish through preimage-bound journals, so an exact retry cannot overwrite newer task state or status events after interruption.
Registration establishes a durable observation epoch, and hard stop plus resume each advance it before results from the prior endpoint may be reconciled.

## Session envelope boundary

Codex Desktop does not currently expose reliable exact per-task cost, remaining-context, compaction-count, or output-token metrics to Firstmate.
The envelope classes therefore provide qualitative soft boundaries and never claim exact enforcement or savings from those signals.
At an explicit hard boundary, the worker stages intended changes and `fm-codex-app-task.sh hard-stop` creates a staged-only checkpoint commit plus a structured handoff outside the app-owned worktree.
The hard-stop recovery journal binds the pre-checkpoint commit, staged tree, requested handoff, endpoint generation and observation epoch, task preimages, checkpoint, and staged publication digests, so an interrupted publication retries from that exact checkpoint without overwriting later task records.
The primary creates a fresh Desktop task for the retained worktree, then `fm-codex-app-task.sh resume` verifies the exact checkpoint and handoff before replacing endpoint identity and advancing both `session_generation` and `observation_epoch`.
Each completed resume publishes a durable receipt binding the previous and fresh thread identifiers and generations, and only that exact receipt makes a retry idempotent.
Unstaged and untracked artifacts remain preserved throughout this transition.
Reconciled `working` state is authoritative only for a bounded age, after which crew-state reports it as stale instead of suppressing later supervision signals.

## Standalone shell boundary

The documented Codex App Server exposes thread and turn lifecycle methods, but Firstmate does not yet ship a standalone `bin/backends/codex-app.sh` client.
A primary outside Codex Desktop therefore cannot select this host lifecycle, and `fm-spawn.sh --backend codex-app` remains blocked.
Implementing that later requires one maintained App Server process plus proven create/resume/read/wait/archive semantics; it must not be approximated with raw Desktop sockets.

## Rollout limits

Ship and scout tasks are supported through a live Desktop primary.
Secondmate support remains out of scope until its home provisioning, nested ownership, and recovery semantics are designed for the host lifecycle.

[`verification/runtime-backends.md`](verification/runtime-backends.md#codex-app-host-tools) owns the active host-tool evidence.
The `firstmate-codexapp` skill owns the operator sequence.
