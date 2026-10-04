# Pi supervision branch

![Multi-brain agent architecture: one agent, two branches of attention, events are commits](pi-supervision-branch-poster.svg)

The poster is the visual of the idea.
This document stays the owner and the contract.

Fleet supervision on the Pi primary harness runs on a second conversation - the supervision branch - inside the same `pi` process as the captain's chat.
Supervision is default-on: once a Pi primary session owns this home's fleet lock, the branch handles eligible task-local rows from ordinary actionable wakes plus heartbeat scans that the cheap bash-level scan flags as possibly captain-relevant, then merges each outcome back into the captain conversation's transcript.
Ordinary main-only rows remain on main even when eligible task-local rows share their queue, except that a fully identity-bound task-scoped iDA process-result check is branch-owned and a decision-owned signal or stale trigger keeps its entire coalesced trigger batch on main.
A structurally valid signal or stale row whose task identity no longer resolves is retained as row-local main-only evidence: its own trigger stays on main, while unrelated resolvable rows remain branch-eligible.
Malformed or unreadable queue data still makes the scan unsafe and returns the whole wake to main, and every watcher-failure alarm also stays on main.
Captain-relevant branch outcomes persist as exact, sequence-keyed visible transcript entries and then open one sequence-keyed processing turn on main, which stays open until main acknowledges that sequence.
The design source is the captain-approved forked-supervision architecture board, a captain-private fleet record (a self-contained HTML explainer with the measured cache and judgment evidence); this document records the shape it landed as, and the delivering PR cites the board artifact itself.

The supervision branch itself is Pi-only by construction:

- The branch lives in `.pi/extensions/fm-branch-supervision.ts`, which only a Pi primary ever loads; no other harness gains branch supervision behavior.
- The bash-side additions (leases, the outcome store, session-start recovery) are inert in a home with no branch state: no lease files exist, no actor variable is set, every guard passes silently, and no new state appears (`tests/fm-branch-supervision.test.sh` holds this).
  A home on any harness that already has an outcome store still receives the shared drain compatibility recovery described in [Lost-wake outcome backstop](#lost-wake-outcome-backstop).
- It does not change which harness is primary and never moves a home to Pi.

## Activity in the Pi terminal

The primary TUI shows a compact `Branch` widget above the editor.
Run `/supervision-status` to toggle its detail lines and request a fresh read-only health observation.
This does not start or reset a branch, claim a wake, or acknowledge an outcome.

| State | Meaning |
| --- | --- |
| `disabled` | A fresh branch observation says reset or shutdown currently disables handling. |
| `idle` | The current process owns the lock and reports no pending work or latched fault; this is not proof of completed work. |
| `processing` | A live admission is pending; the item summary distinguishes accepted-before-prompt from model/tool execution. |
| `degraded` | A handling failure or unexpected MAIN fallback remains latched until a later durable branch result succeeds. |
| `error` | The branch reports a construction, reconciliation, or provider health fault. |
| `unknown` | Ownership or current evidence is missing, stale, inconsistent, or exceeds the bounded display capacity. |

Details show the current wake kind and bounded item/batch count, latest completed branch result time, latest MAIN fallback, and latest error category.
Only a branch settlement after a durable report counts as a completed result; acceptance, a loaded extension, mirrored conversation, a short-task outcome, and a quiet empty-queue return never count.
A MAIN-only check or decision is an expected fallback and does not imply branch failure.
The `ownership-lost` fallback category historically groups fleet-lock loss and wake rows already claimed by MAIN; the branch's `recheck: main-owned` or `grant: main-owned` observation distinguishes the latter without altering its safety guard.

The presentation owner is `.pi/extensions/fm-branch-status.ts`, with its bounded read model in `lib/fm-branch-activity.ts`.
It consumes branch/watcher observational events, reads at most the last 256 KiB and 200 routing records once on session start, and retains no message bodies or tool arguments.
Historical records can establish the last result or failure, but never current processing.
Refreshes coalesce over 100 ms, stream liveness pulses are limited to once per second, and a single two-minute expiry marks silent evidence unknown without polling or rescanning files.
Shutdown and reload dispose subscriptions and timers; noninteractive modes allocate no display observer.
Other primary harnesses and terminal backends gain no behavior or authority changes.
The portable checks are `tests/fm-pi-branch-status.test.sh`; `tests/fm-pi-branch-status-live.test.sh` refreshes real-Pi rendered evidence under the [harness verification policy](verification/runtime-backends.md).

## Live task continuation

Presentation acknowledgement does not establish task acceptance.
The canonical `data/<task>/task.json` record owns task identity, disposition and progress.
Its title is the task goal, and its progress fields store the acceptance method, current state, remaining gap and next step.
MAIN reads and materially updates those fields with the native tool's `read` and `update` actions.
The opaque read token binds one Branch admission to the exact projected goal, progress values, and current backlog disposition.
It rejects a continuation when that projection changes after admission, but it is not a MAIN update precondition or a persisted concurrency record.
Together with the exact current MAIN-authored `next_step`, it permits only idempotent same-worker inbox continuation; all other effects remain with their existing authority owners.
The branch can read only the exact token-bound compact admission while its original task remains unheld, unblocked and `in_flight`; it cannot write progress or make final semantic acceptance.

The Pi extension uses the existing heartbeat coordinator's tick and `progress-list` to inspect canonical task ids.
A healthy working executor, unchanged wait, task with no compact progress, or task with no remaining gap stays quiet.
An actionable gap without healthy execution is offered to the branch with the canonical task id, goal, acceptance method, current state, remaining gap and next step.
The branch inspects current artifacts and routes an already-authorized next step through its existing owner; failure or refusal falls back to MAIN.
Endpoint text is never substituted for task identity.
For a native-review checkpoint, the branch uses the inbox owner's idempotent continuation mode to instruct the same worker to run the exact-candidate review or apply an already-authorized correction; only that worker changes its branch.
A healthy unchanged executor or wait is settled quietly in the branch session.
Verified routine advancement is also settled quietly, and a changed executor observation admits the next bounded Branch turn without requiring MAIN to rewrite progress first.
Only goal-ready evidence, genuine blockers and authority decisions reach MAIN through the durable sequence-bound processing and acknowledgement path.
For one unchanged task-record token and executor observation, the extension emits at most two offers and one visible coordination escalation, then remains quiet until the record, executor, or disposition changes. This limits duplicate observation, not task attempts. The pacing entries are delivery receipts in the Pi session, bind the exact operational home as well as the session cwd, and survive session replacement only within that home; canonical task progress still comes only from the task record.
When existing supported actions are exhausted, MAIN's `hold` action records a named blocker or captain decision with a responsible party, required action, and clearing condition. The branch cannot write progress or create that disposition itself.

Neither monitoring nor branch admission grants authority or replaces an effect owner.
The branch may use that owner's existing interface for one in-scope routine step; MAIN owns progress writes, final artifact review, semantic acceptance, and genuine scope/product/architecture, destructive, security, merge or cleanup decisions.
A native-review finding delivered with its exact task-local snapshot stays on the branch only when the accepted brief makes the fix unambiguous and it adds no guarantee, subsystem, architecture choice, destructive effect, security-sensitive choice or risk acceptance.
Every other decision remains MAIN-owned.
Project-required routine confirmations use the same rule; every other decision is reported to MAIN.
Attempted or uncertain effects retain their existing readback and no-replay contracts.
A queued handoff, successful send, provider terminal state, report or pull request cannot independently establish acceptance.
An unreadable task record produces a scoped reconciliation request without inventing an executor or progress state.
If an admitted task becomes explicitly completed or archived before the branch reports, unchanged goal, progress, disposition safety, and non-record resume evidence produce one durable superseded settlement. Material nonterminal drift, pending decisions, identity mismatch, or uncertain effects still report through reconciliation.

Ordinary chat creates no progress record.
When requirements change, MAIN uses its ordinary file tools to keep the original brief's `## Captain's intent` as the consolidated processed requirement while preserving the rest of the task contract.
The canonical brief remains the only Intent record; there is no separate intent-update tool, source-message mapping, update receipt, or parallel history.
Discovery stays in the heartbeat owner's `progress-list` call; it does not add another history or progress source to MAIN's daily read/update schema.
The Branch registration exposes only `read` for the exact compact-progress task admitted through the ordinary task owner.
Historical rich-lifecycle records are neither admissions nor readable through this tool.
No continuation path creates a second scheduler, task store or lifecycle progress record.
[`tests/fm-task-progress.test.sh`](../tests/fm-task-progress.test.sh) and `tests/continuation-native.mjs` cover one-file task persistence, MAIN-only updates, restart recovery, quiet unchanged execution and compact native calls.

## Components and their owners

- Wake dispatch: `.pi/extensions/fm-primary-pi-watch.ts` stays the dispatcher; `.pi/extensions/lib/fm-branch-dispatch.ts` owns the offer handshake and row eligibility, while [`watcher-continuity.md`](watcher-continuity.md#per-actor-acknowledgement) owns the per-actor consume contract.
  A successful row grant transfers ownership of exactly the currently branch-eligible rows to the branch; a check-kind triggering close stays on main except for a task-scoped iDA process result whose queue key, payload, private captured result and adapter files, remote-agent metadata, durable iDA task state, session marker, and available provider identities all match exactly.
  Malformed, path-unsafe, unresolvable, mismatched-provider, mismatched-task, and mismatched-result iDA-looking rows keep the ordinary main path, as do merge-confirmation polls, credential/auth failures, and every other check class.
  No acceptor (extension absent or branch broken) keeps today's wake-to-main path for the close, and watcher-failure alarms always go to main because only main can repair the watcher cycle.
  A busy branch also declines a newly arrived iDA result unless its live grant already contains that exact row, so an unowned result falls back to main instead of waiting between actors.
  A decision-owned event surfaced by `bin/fm-watch.sh`'s signal path gets the identical treatment even though it keeps the ordinary `signal` kind.
  `signal_files_actionable` marks the queued payload `needs-decision:` for a newly surfaced `needs-decision` or a `captain-held` declaration surfaced through the no-verb fallback.
  Such rows stay MAIN-owned unless every open decision for their exact canonical task is a native-review finding with its exact regular task-local snapshot and the task currently has an in-flight compact progress record with an actionable gap; only then may the branch claim the row to apply the bounded routine-versus-genuine decision criteria above.
  For a stale row, `scopeForUnreadWake` folds the mapped task's status log and applies the same exact native-review snapshot qualification when a `needs-decision` remains open; a current `captain-held` declaration, another decision class, or an unreadable or symlinked record stays MAIN-owned.
  Task metadata contributes aliases only from one current-user-owned regular single-linked file with exactly one project field and at most one window field; task ids, status files, turn-ended files, and complete window values are opaque exact aliases.
  An alias claimed by more than one task remains unresolved and main-owned rather than inheriting filesystem iteration order.
  The dispatcher resolves trigger keys and every currently unread decision row to task identity before cross-referencing them.
  A decision without current compact qualification goes wholly to main, including a batch that also contains routine rows, and keeps later aliases for that same task on main until read.
  A qualified row carries the canonical identity into the branch prompt; endpoint labels never become task selectors.
  Other tasks remain independently eligible.
  The wake message itself retains its existing shape, so other harness-arm scripts remain unchanged.
  For an accepted iDA result the branch claims only the resolved task, repeats `fm-procevent-ida.sh handle` for the exact source sequence even when the runner already applied it, reads provider-aware task state and the task-bound report when present, and reports the result or incomplete blocker without treating provider text as authority.
  Compliance declarations, access grants, provider cancellation, new dispatch or scope, architecture choices, merge, destructive or security-sensitive action, and every other captain-owned decision remain main escalations.
  Heartbeat handling remains independent.
  A fleet-wide heartbeat keeps its own all-or-nothing rule (see "Heartbeat routing" below): it takes every branch-ownable unread row or none of them.
  A co-present main-owned check row no longer defers that review to main, because it is not fleet context the branch is missing and main is woken for it on its own triggering close.
- The branch itself: `.pi/extensions/fm-branch-supervision.ts` creates the branch session, serializes wakes, mirrors dialog, and merges outcomes.
  Each build reads global settings through Pi's `SettingsManager` with `projectTrusted: false`, then shares an in-memory snapshot between package resolution, the resource loader, and the session.
  Runtime settings such as transport, connection timeouts, retry policy, and proxy configuration survive; branch and plugin setters cannot write back to user settings, and model/effort selection retains the explicit precedence described below.
  The snapshot clears configured packages, extensions, skills, prompts, and themes because Pi resolves package sources before applying the loader's discovery flags.
  Unreadable or malformed global settings fail the build and return the wake to main instead of silently using defaults.
  Pi's CLI owns process-wide proxy environment and HTTP dispatcher initialization; the branch retains that process setup and does not reconfigure it.
  Before an `openai-codex` branch can prompt, it resolves the installed user package `npm:pi-openai-codex-compat` through Pi's package manager, validates package identity and the readable manifest, loads exactly its declared in-package extension entry from the installed user-package provenance, and binds the extension so its `session_start` provider override and native compaction hooks are active.
  The branch does not gate initialization on Pi or `pi-openai-codex-compat` version strings.
  Every other resource-discovery class remains disabled, and the post-start active-tool check must still equal `read`, guarded `bash`, `fm_task_continuation`, `fm_task_handoff`, and `fm_branch_report` in that order.
  If compatibility startup removes only `bash`, leaving exactly `read`, `fm_task_continuation`, `fm_task_handoff`, and `fm_branch_report`, the branch restores the registered guarded override and verifies the full active-tool set again.
  The runtime state check independently prevents a compatibility package from widening the branch tools.
  The plugin's native runtime dependencies must load on the host; an incompatible tree-sitter prebuild needs a local source build using the package's supported build tooling before activation.
  [Runtime verification](verification/runtime-backends.md) records the current installed-runtime checks and refresh commands.
  A missing, malformed, unresolved, unloadable, or startup-failing compatibility package makes that Codex branch fail closed before prompting and returns its accepted wake to main; non-Codex branches do not resolve or depend on the package.
  The branch conversation never spans main sessions: after every main session start - a cold start, `/new`, `/resume`, `/fork`, or a reload - the next eligible wake creates a NEW branch conversation, and a conversation recorded by an earlier session is never reopened as the live one.
  Installing or upgrading the package alone does not create `state/.branch-session`; ownership and durable-outcome reconciliation must succeed before the first eligible notification starts it.
  That keeps the branch reasoning from the current generated prompt and the current main dialog rather than from weeks of accumulated thread, where a superseded rule could still outweigh today's.
  A model or effort change inside one main session continues that session's own conversation, recorded by `state/.branch-session`; the explicit `/supervision-reset` path below retires it instead.
  Earlier conversations stay on disk under `state/branch-session/`, exactly as Pi keeps its own session files, and are never reopened as live branch context; the effort picker may only inspect the model named by the current pointer as the last-resort lookup documented in [configuration.md](configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort).
  Nothing captain-facing rides on that conversation: the durable outcome store and its processed marker are what carry unacknowledged outcomes across the boundary, and they re-present on the new main session exactly as they do after a crash.
  It checks the current extension generation and `state/.lock` ownership before each guarded branch side effect so replacement or lock loss cannot let an old continuation mutate the new session.
  Those checks and the store calls around them are awaited rather than synchronous, and an explicit queue inside the extension is what keeps them serialized (see "Off-thread delivery" below).
  Every accepted path that cannot reach a working branch rejects its settlement to the watcher, which retains delivery ownership and routes the wake to main as a follow-up that counts as delivered once Pi accepts it; a broken branch declines later offers so they take that path directly.
  Each watcher offer carries its exact eligible sequence-to-task snapshot.
  After asynchronous queueing and before publishing a grant, the branch rechecks the current extension generation, model/effort selection revision, fleet-lock ownership, trigger disposition, admitted sequences, and their resolved task identities.
  Retirement, endpoint reuse, a selection or generation change, or a competing main grant rejects settlement to watcher-owned fallback; an actually empty queue is the only already-consumed quiet no-op.
  After wake rows are claimed, a branch prompt counts as handled only when `fm_branch_report` appends a durable outcome before that prompt settles; a settled provider error or a settled prompt with no report releases the grant and rejects delivery ownership back to the watcher.
  While a task-scoped prompt is open, `fm_branch_report` accepts only the tasks that prompt's claimed rows resolve to (a signal row by its status-log key, a stale row through the task record naming that endpoint, or an iDA result through its identity-bound remote-task record); a report for any other task id, `fleet` included, is refused before the store is touched, so a task remembered from an earlier wake cannot become a delivered outcome, while a heartbeat review is not scoped by task.
  The branch's guarded commands never tell it to drain queued rows mid-handling: for that actor `bin/fm-guard.sh` keeps the queued-wakes warning silent, and an acknowledgement that consumed nothing reports that plainly with the exact command for the current wake (`docs/watcher-continuity.md` "Per-actor acknowledgement").
  Two consecutive settled provider errors latch the branch broken and surface a one-line health note only on that initial trip.
  Main keeps every wake during a five-minute cooldown, after which one wake may probe the branch while concurrent wakes still stay on main; each probe that settles with another provider error doubles the next cooldown up to one hour.
  A prompt from the current branch generation and model or effort selection that appends a durable `fm_branch_report` and then settles without a provider error clears both the latch and provider-error streak and surfaces a one-line recovery note; a provider error settled after that report wins instead, re-latches the branch, and extends the cooldown.
  A session replacement or branch model or effort change resets the recovery state immediately.
  Outcome-reconciliation failures are a separate health class from construction and provider failures.
  A one-shot read or presentation failure may probe again at the next ordinary offer, turn boundary, or outcome-ready event.
  After repeated failures, ordinary offers and turn boundaries use bounded exponential backoff without a new timer; an outcome-ready event still attempts reconciliation because it announces newly durable work.
  Only a successful authoritative reconciliation in the same extension generation and selection revision clears that class.
  Mirror success does not clear it, and the probe path never clears provider cooldown or permanent construction/configuration failures.
  Because durable outcomes precede presentation, recovery re-presents or reconciles them without replaying branch execution.
- Branch model and effort selection: the same extension registers `/supervision-model`, which picks the branch's model and then its reasoning effort, and applies both at the branch-session creation boundary; [configuration.md](configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort) owns the operator-facing schema and behavior.
- Branch conversation reset: `/supervision-reset` closes branch admission, aborts and waits for any active branch turn through Pi's session API, releases row grants and branch-held leases, archives the old JSONL, clears its pointer, and re-anchors mirroring at main's current tail.
  It does not replace the main session or any Feishu binding, and it does not eagerly create a branch: the next eligible wake creates the fresh persistent conversation.
- Branch system prompt: `bin/fm-branch-prompt.sh`; its header owns the byte-stable-prefix contract (no timestamps, no fleet snapshot, no per-wake content).
- Outcome store: `bin/fm-branch-outcome.sh`; its header owns the immutable sequence format, active/cold retention boundary, read cursor, and bounded per-task status-coverage indexes.
  Outcomes are written to the store before delivery to Pi.
  A captain row advances the cursor only after its matching visible session entry exists, while locked session-start replay stops before the first captain row so it cannot acknowledge that outcome through prose alone.
  A routine note has no such sequence-keyed record, so if its cursor write fails after the note was delivered the next reconciliation sends that note once more.
  That asymmetry is a known limitation of the routine delivery representation rather than of the ordering above, it predates delivery moving off Pi's render thread, and closing it means giving routine delivery a durable idempotent record - tracked as follow-up `fm-pi-routine-delivery-idempotency-followup-r1` and pinned meanwhile by `tests/fm-pi-branch-extension.test.sh`.
- Consistency: `bin/fm-lease-lib.sh` owns the per-task lease contract, the main-only role partition, and the deliberate CONFUSED-AGENT-GRADE threat model these guards target (captain-decided; adversarial-grade separation is out of scope and tracked as follow-up design work); `bin/fm-lease.sh` is the command surface.
  The guards are wired into `fm-send.sh`, `fm-control.sh`, and `fm-teardown.sh` (overlap, lease-checked, with claim serialization retained through the mutation) and `fm-pr-merge.sh`, `fm-merge-local.sh`, and `fm-spawn.sh` (main-owned, branch refused; a relaunch through `fm-control` stays branch-legal recovery).
  During compact continuation, the progress token and exact current MAIN-authored `next_step` permit idempotent same-worker inbox continuation; cross-task work uses the durable handoff owner, while attempted effects remain fenced by their existing operation, inbox, and receipt owners.
  A compact continuation is an authenticated admission from that owner, not a watcher wake: the branch does not drain or acknowledge wake rows and does not invent an eligible-row snapshot for it. Its task/progress/executor identity guard supplies the admission boundary, and any changed projection refuses the effect.
- Autonomy: supervision is default-on for every task once a Pi primary session owns the fleet lock (docs/configuration.md "Pi supervision branch"); no captain grant file is required.
  A fleet-wide heartbeat is separately eligible when its safe subset contains a heartbeat row, a resolvable task-local signal or stale row, or an identity-bound iDA result check (see "Heartbeat routing" below).
  Main-owned checks, decision-owned signal/stale rows, and structurally valid unresolved task rows are excluded and remain queued; malformed or unreadable queue data and every watcher-failure alarm keep the whole wake on main.
  The shared `scopeForUnreadWake` classifier also excludes the exact queued rows in `.main-eligible-rows` during admission and pre-prompt recheck.
  A trigger matching a claimed signal/stale task alias, exact check payload, or claimed heartbeat stays on MAIN; unrelated new rows can form their own grant.
  An absent MAIN record means no claim, while a malformed, unreadable, non-regular or changing record fails closed.
  The branch recomputes eligibility immediately before prompting the branch to drain and publishes the exact eligible row set to `state/.branch-eligible-rows` through `writeEligibleRowsSnapshot`.
  After an independently eligible wake has already been offered, an unrelated MAIN-owned row observed at that pre-drain recheck does not revoke the offer: it remains outside the admitted set.
  MAIN claiming an admitted row after admission rejects settlement; the final locked all-or-nothing grant check still arbitrates any later claim race.
  [`watcher-continuity.md`](watcher-continuity.md#per-actor-acknowledgement) owns the consume-side guarantee that neither actor can present or acknowledge the other's claim.
  Heartbeat keeps its own all-or-nothing recheck over the rows it can claim: it takes every branch-ownable unread row or none of them.
  A structurally valid unresolved task row is outside that claim and remains main-only; malformed or unreadable queue state still defers the whole review to main.
  A producer can still append a row in the instant between that final check and drain startup; this accepted residual follows the confused-agent-grade boundary above rather than claiming adversarial queue isolation.
  A broken branch between its bounded recovery probes keeps today's wake-to-main behavior. Preserved legacy mode records do not affect branch admission.

## Off-thread delivery

The supervision branch lives inside the captain's own Pi process, and Pi runs extensions, their tools, and their event handlers on the single JavaScript thread that also draws the TUI and reads the keyboard.
A synchronous subprocess in the delivery path therefore stops repaint and key echo for the child's whole lifetime, which the captain saw as a subsecond freeze every time a routine or captain-facing outcome arrived.
Subprocess work reached through Pi's asynchronous APIs is now awaited instead: `.pi/extensions/lib/fm-async-exec.ts` owns that awaited-spawn replacement and preserves the status, captured-output, and failure semantics its callers used from the synchronous form.

Awaiting yields the thread, so what the single thread used to guarantee for free is now an explicit queue in `.pi/extensions/fm-branch-supervision.ts`.
Every delivery, every acknowledgement, and every turn boundary's reconciliation runs as one unit of that queue, which is what preserves the durable append before anything visible, one delivery at a time in sequence order, the read cursor advanced before the next reader sees a row, and one ownership activation per generation.
Cancellation is preserved by the generation and lock-ownership rechecks the awaits are placed around: a session replaced mid-delivery fails the next recheck rather than acting into the session that replaced it.

Two reads stay synchronous because Pi's own API is synchronous there, not as an optimization.
Pi types its bash spawn hook as a plain function, so the guard on the branch's own shell commands cannot await; and the watcher reads `offer.accepted` the moment its dispatch event returns, so a session that does not own the fleet lock must still refuse a wake without waiting.
Both read the same uncached ownership authority: the lock's process ancestry is walked in full every time it is asked, never cached, because reparenting and pid reuse can invalidate a remembered chain and this answer decides ownership rather than hinting at it.

## Lost-wake outcome backstop

Every main-actor wake drain checks each task's newest non-blank status event against the latest supervision-branch outcome that causally covers that task's status log.
When that event is terminal or otherwise captain-facing and remains uncovered, the drain prints it once in `STATUS OUTCOME BACKSTOP`, even if the original queue row was already acknowledged; routine events stay silent, and valid open decisions remain owned by `OPEN DECISIONS`.
The one-shot backstop cursor is independent from signal annotation, so a delayed signal can still present its status context without repeating the recovered event.
The drain reads one fixed-size per-task outcome index instead of scanning append-only outcome history and inspects at most the final 64 KiB of each status log.
Status provenance added to new outcome rows distinguishes covered and genuinely later events even within one timestamp second.
Legacy outcomes predate that causal position, so equal-second migration cannot prove order and deliberately favors surfacing a plausibly later event; this can rarely duplicate an already handled legacy event.
A pathological latest status line that crosses the 64 KiB window is unclassifiable and remains silent rather than risking presentation of routine content; this is an accepted limit, not a status-line size contract.
A missing or invalid outcome-index ready marker is rebuilt from the authoritative outcome rows by `processed-init` under the outcome lock on the next main drain, on every harness.
Legacy outcome task labels such as endpoint identities remain valid delivery history; migration builds caches only for filename-safe task identities, without rewriting the store or advancing either delivery marker.
This same migration runs during Pi branch startup reconciliation, so a legacy label cannot prevent the first branch conversation from starting; malformed stores and invalid cursors still fail closed.
Only a genuine store fault keeps that backstop skipped.

## How the branch knows what the captain said

Main's captain and assistant text - never tool calls, tool results, operational injections, or the branch's own merged notes - is mirrored into the branch as read-only `fm-main-mirror` messages.
The idle path mirrors at main's turn end.
At `before_agent_start`, Pi's authoritative prompt is staged verbatim before SessionManager persists that user entry, so the complete current captain message precedes any branch wake accepted after that boundary; the later persisted copy is suppressed and older dialog entries remain bounded.
Native Feishu input uses Pi's custom-message queue instead of that prompt event, so its text is staged at `message_start` when Pi consumes it, including while main is streaming.
The native channel's `classifyFeishuMessage` remains the provenance owner: only a matching accepted delivery, binding generation, and immutable content digest qualifies as captain input; arbitrary custom messages and forged Feishu metadata do not.
Persisted Feishu entries use the same validation during history collection, preserving user/assistant order and cold-start continuity, and a staged delivery is suppressed once its persisted entry catches up.
The mirror cursor is durable (`state/.branch-mirror-cursor`), so within one main session only not-yet-mirrored dialog is replayed.
Every main session start re-anchors the mirror to the current main session's start, because that start also opens a new branch conversation: the cursor records what the PREVIOUS branch conversation received, so without the reset a `/resume` or reload, which keeps main's own session file, would leave the new branch blind to dialog main itself still has.
The reset is bounded by the current main session and costs only re-delivered read-only context, and the cursor keeps advancing incrementally from there.
The branch prompt frames mirrored text as context for judgment, never as instructions addressed to the branch; an authorization addressed to main (for example "you may merge when green") does not relax the branch's role limits.

## Two-stage noise filter

Stage one is unchanged: the bash watcher absorbs everything provably fine at zero token cost.
Stage two is the branch's verdict on each handled event, reported through its `fm_branch_report` tool: `routine` keeps the existing custom-message path without a follow-up turn, while `captain` appends a versioned `fm-branch-visible-outcome` custom session entry.
The captain entry contains the store sequence, task, verdict, exact summary, and silent flag, and its renderer presents the exact task and summary with an anchor prefix.
Pi custom session entries persist in the transcript but do not enter model context, so a stale compaction summary, an unrelated assistant response, prompt caching, or model instruction noncompliance cannot acknowledge or rewrite the outcome.
The store sequence is the idempotency key: reload after entry persistence but before cursor advancement finds the matching entry, avoids a duplicate, and advances the cursor; conflicting content for one sequence fails closed.
Reconciliation runs at session start when that generation already owns the fleet lock and at the first post-lock `turn_end`, so a cold start that acquires the lock through the startup digest still delivers stored captain outcomes without waiting for another wake.
Display is only half of a captain outcome; the other half is processing, because a blocker, a decision, or a ready PR needs main to act, not only the captain to see it.
After the visible entry exists and the read cursor has passed it, the extension hands every still-unprocessed captain row to main as one hidden, typed `fm-branch-process` request (kind `branch-outcome`) listing the exact sequence membership and task identities, and that request opens exactly one main turn.
Ordinary outcomes remain identity-only and require an exact `fm_branch_outcomes` read, while an inline-size successful ShortTask whose notification exactly matches its bound durable result is included directly and counted as loaded.
An oversized successful ShortTask carries only its independently authenticated bounded reference in the processing request and remains unloaded for acknowledgement until one `fm_short_task` result read supplies both its complete unchanged result and a matching loaded-evidence event; reading only the bounded outcome row does not satisfy that gate.
Missing or mismatched result bindings fall back to the ordinary exact outcome read.
Before acting on identity-only rows, main loads their exact sequences in one `fm_branch_outcomes` call. Each result carries the trusted outcome plus a derived current task projection, recorded and current executor generations with an explicit mismatch flag, applicable candidate identity, metadata digest, and runtime digest. Main closes the batch by calling `fm_branch_processed` with the complete comma-separated sequence membership from the request.
Acknowledgement is refused unless every named sequence was authenticated and handled and the durable outcome identity is unchanged. It does not recheck mutable task or executor projections after handling, because the acknowledgement closes presentation of the already-loaded outcome and grants neither effect authority nor semantic acceptance of current task state. A targeted read exposes recorded and current generations plus an explicit mismatch instead of throwing on a stale generation. Compaction preserves only current-request inline witnesses and clears earlier tool-read witnesses; session replacement clears both and re-presents durable identities. The legacy numeric `through` form remains a compatibility path for an active prefix, but new processing requests use exact membership.
Nothing else advances that marker: an unrelated reply, an empty reply, or a reply that paraphrases the outcome leaves the sequence unprocessed, and the extension presents the current unprocessed sequence set again at the next main run boundary and at every session start.
A presentation already pending its run boundary is not resent or widened; once that run settles, the extension presents the then-current sequence set.
The first two presentations of a given sequence set open a turn of their own; after that the request rides the captain's next prompt so an ignored request cannot become an unbounded loop of empty turns, while changed sequence membership and a session replacement each start that budget over.
Routine outcomes never enter this path and stay turn-free.
A later exact duplicate for the same proved task generation and stable material revision is delivered once while every row remains durable audit evidence. Missing or malformed generations are never replaced with a shared synthetic identity and therefore remain uncoalesced. Coalescing consults the retained active history plus every row that is currently unread or unprocessed: a verified terminal task disposition in that context suppresses repeated routine material first observed before the terminal transition, including a late retry of that old material, while a material revision first observed after the terminal remains deliverable once. If the required terminal evidence has already moved outside that active context, the branch conservatively delivers the new row instead of silently suppressing it. It never suppresses a new decision answer, one-off substantive note, uncertain effect, different identity, or new revision.
A home upgraded with outcomes already delivered treats those rows as processed once, at the first reconciliation that finds no processed marker, so its history is not re-presented.
The generated [Pi supervision protocol](supervision-protocols/pi.md) owns event ownership for merged outcomes and main's acknowledgement duty, while deterministic entry delivery owns captain visibility.
A no-change heartbeat outcome explicitly reported with `task=fleet` and `silent=true` is delivered silently with no rendered note.
A token-bound compact continuation may also request `routine` with `silent=true`; the receipt stays only in the branch session when the task-owned resumable state is unchanged.
A material task-owned resume-state change instead enters the existing outcome store and reaches MAIN so MAIN can update the canonical task record.
Every other `routine` outcome stays rendered with its sailboat prefix.
The branch prompt's "Verdict: routine or captain" section owns the verdict criteria, including how requested work's finished results and its mere progress updates are classified; unsolicited routine outcomes remain routine sailboat notes, unchanged fleet reviews remain silent, and doubt escalates.
Its "Goal-directed acceptance" section owns semantic review of material task returns: intermediate and provider-terminal results continue through existing authorized task and effect owners when acceptance is incomplete, satisfied acceptance becomes a candidate for MAIN retirement, explicit stops remain stopped, and delivery or merge authority never expands.
For an ordinary clean finish, the processing request acts as an authenticated completion capsule: MAIN makes one semantic/authority decision, then may grant one existing bounded operation chain for merge, sync, and cleanup. The chain returns combined receipts and never auto-accepts worker success, grants merge authority, activates a new extension, or replays an uncertain operation.
Its "PR identity: copy or abstain" section owns where a PR URL in a summary or tool argument may come from: the task's ready status or `pr=` metadata, verbatim, or else only the identifier the branch actually has.
Main can also read recent durable outcomes on demand through its `fm_branch_outcomes` tool outside the processing path.

## Active outcome retention and cold evidence

The outcome owner keeps the normal supervision path bounded without deleting recovery evidence. For example, if sequence 1000 is the confirmed processed frontier and the store ends at 1065, the active file keeps 937–1065: 64 processed rows including sequence 1000, followed by every newer row. Sequences 1–936 move byte-for-byte into the cold file. When the frontier later advances to 1066, the active processed window becomes 1003–1066. Sequence numbers never change.

`state/branch-outcomes.jsonl` is the active scan path, `state/branch-outcomes-cold.jsonl` is the preserved historical prefix, and `state/.branch-outcomes-base` records the first active sequence (`1` when absent). The base is the only new format fact needed to validate a suffix: active rows remain gap-free from that base, cold rows remain gap-free from sequence 1 through base minus one, and the cursor and processed marker may never fall behind the archived prefix.

`fm-branch-outcome.sh mark-processed` applies retention as part of the exact acknowledgement. `compact --dry-run` reports the boundary without changing it, while `compact --apply` performs the same owner operation explicitly. Compaction holds the existing outcome lock and publishes a prepared cold file, active file, base, and processed marker in that order under a recovery journal. Before the journal exists, a preparation failure leaves the acknowledgement unchanged; after it exists, every owner command completes the whole interrupted publication before proceeding. Appends therefore serialize with compaction, and a restart either finishes the exact prepared generation or refuses changed or missing evidence.

The active reduction is deliberately different from total disk retention. Moving processed rows removes them from ordinary capture and parsing, but the cold file still consumes their original bytes. `unread`, `unprocessed`, `list --recent`, cursor operations, ordinary append, active-row `list --seq`, reconciliation, and coalescing use only the active file; the extension asks for 64 recent active rows and explicitly merges every current unread or unprocessed row, so pending work is not limited to 64. Explicit `list --all`, a `list --seq` request below the active base, `append --once-task`, and a genuinely required outcome-index rebuild may scan cold evidence. Those cold paths remain linear in retained total history and are not part of ordinary delivery.

The number 64 is a retention count, not a byte limit. Active storage can exceed 64 rows because every row above the processed frontier remains active, and 64 unusually large rows can themselves exceed any subprocess output limit. No evidence row is truncated. A single oversized row therefore remains an explicit limitation rather than being silently shortened or deleted.

## Heartbeat routing

The cheap bash-level heartbeat scan absorbs a genuinely no-op pass before it reaches Pi, unchanged from before.
Only a scan already flagged as possibly captain-relevant emits the bare `heartbeat` wake; `.pi/extensions/fm-primary-pi-watch.ts` flags that offer `heartbeat: true`, and the branch accepts it without a project only when every branch-ownable row observed in the unread-queue eligibility check is either heartbeat-kind, a resolvable task-local signal or stale event, or an identity-bound iDA result check.

A heartbeat is never vetoed or ridden into main by a co-present main-owned check row or decision-owned signal/stale row.
Those rows are permanently main-owned in every mode, while a valid identity-bound iDA result remains branch-owned: main-owned rows are excluded from what the branch may claim and left queued for main, which is woken for each on its own watcher cycle, so nothing starves by being left behind.
Deferring the fleet review to main merely because some unrelated merge poll happened to be sitting unread put a routine review in the captain's chat for a reason that had nothing to do with the fleet, and that coupling is gone.
What all-or-nothing guarantees is that the branch takes every branch-ownable unread row or none of them.
A structurally valid unresolved task row is main-only and does not contaminate that safe subset; an unknown row kind or unreadable queue still defers the whole review to main.
The branch runs its normal operating procedure for the wake (`bin/fm-branch-prompt.sh` "Handling a wake") and performs the deeper fleet review that main previously performed.
A review that found literally nothing worth reporting uses verdict `routine`, `task=fleet`, and `silent=true` so it has no rendered note, while a fleet-wide routine action omits `silent` and keeps its rendered sailboat note.
Only a captain-worthy finding reports verdict `captain` and appends a visible captain outcome entry.
The unresolved row's own signal or stale trigger and every other fleet-wide wake with no safe subset keep today's wake-to-main path.
Watcher-failure alarms are never offered to the branch.

## Routing diagnostics

The watcher and branch append best-effort causal records to `state/.supervision-routing.jsonl`.
One bounded token connects classification, synchronous accept or decline, asynchronous recheck and grant, durable report or settlement, and watcher fallback or main delivery.
To explain a particular Main notification, find its time-adjacent `main-delivery` record and follow that token backward: `declined` names a synchronous refusal, `fallback` names a failure after acceptance, and `classify` records the trigger kind plus any excluded numeric row sequences.
Records contain only fixed reason categories, trigger kind, numeric queue sequences, generation/selection identity, and elapsed milliseconds; they never contain wake payloads, chat, model reasoning, credentials, arbitrary tool bodies, or provider payloads.

The file is capped at 200 JSONL records and 256 KiB, rewritten atomically with mode `0600`.
A diagnostic write failure is ignored by routing, and the file is never consulted as ownership or scheduling truth.

## Cost model and the byte-stable prefix

The captain accepted the normal provider prompt-caching strategy: a byte-identical branch prefix generated once per firstmate version, the same tool set in the same order on every request, and one shared `prompt_cache_key` per home for all branch sessions (set in a `before_provider_request` hook, and only for providers whose requests already carry that field); main keeps its own per-session key.
Budget roughly 60% cache hits on a new branch conversation's first call and 95% on later calls within that conversation; the shared per-home key is what carries the byte-identical prefix across the conversation each main session start opens, and reuse is best-effort, never guaranteed.
The branch can also run on a cheaper model and a shallower reasoning effort than main, both pinned with the Pi `/supervision-model` command; [configuration.md](configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort) owns those pins' operator-facing schema and unpinned behavior.
A provider an extension registered only into main's runtime, such as pi-devin-auth's `devin`, reaches the isolated branch runtime by copying its provider config from main's captured `ModelRegistry` into the branch `ModelRuntime` at model-resolution time and in the `/supervision-model` picker, so the provider's own `streamSimple` transport and OAuth wiring are reused by reference rather than reimplemented.
That carve-out is scoped to provider registration alone: the branch keeps its `noExtensions`, `noSkills`, and `noContextFiles` isolation, the copy is never persisted, a provider whose registration fails to compose is simply unavailable, and `tests/fm-pi-branch-extension.test.sh` pins the pin-and-fallthrough behavior.
No caching machinery beyond this exists, deliberately: any later dynamic content in the branch prefix silently removes most of the cache benefit, which is why `bin/fm-branch-prompt.sh`'s header is the contract's single owner and `tests/fm-branch-supervision.test.sh` pins the output to byte identity.

## Verification

Portable regressions: `tests/fm-pi-branch-extension.test.sh` covers dispatch; signal and stale report scoping with unscoped heartbeat reports; identity-bound iDA result row scoping; rejection of malformed or mismatched iDA notifications; busy-branch fallback for an unowned iDA row; the new branch conversation at every main session start with continuation inside one session; the mirror re-anchor that pairs with it; requested-versus-unsolicited delivery; exact visible entry content; no unkeyed model turn; the sequence-keyed processing request and its acknowledgement; authenticated inline ShortTask results; bounded oversized-result references, explicit full-result loading, and acknowledgement evidence across compaction and session replacement; re-presentation after an empty reply and after an unrelated prior answer; the triggered-then-next-turn pacing; session-start re-presentation; routine outcomes staying turn-free; the processed-marker migration; idle and busy main state; incident-shaped compaction and unrelated-assistant context; cold-start post-lock recovery; crash-before-cursor reload recovery; repeated-reload idempotency; mirroring; post-construction provider-error and no-report fallback; the consecutive-error latch; cooldown probe; exponential backoff; report-plus-settlement recovery; report-before-error re-latch; cache key; model and effort selection; and decision-owned signal and stale rows' exclusion from `eligibleSeqs`, their presence in `needsDecisionKeys`, task alias resolution, reserved-key configuration, status-log race and symlink refusal, non-vetoing behavior for unrelated eligible rows, and decision-only queues reading as ordinary main-only absence. When an installed SDK is available, the same suite invokes `tests/fm-pi-branch-retention-installed.mjs`: a real `DefaultResourceLoader` and `AgentSession` prove that greater-than-1-MiB history no longer blocks exact acknowledgement before and after compaction or later ordinary branch admission, with an in-process provider and zero network calls.
`tests/fm-branch-supervision.test.sh` covers prompt stability, active/cold retention at 0, below 64, exactly 64, and above 64 processed rows; the frontier boundary; pending-row preservation; immutable cold bytes and exact lookup; once-task and index-rebuild cold paths; concurrent append; acknowledgement and compaction interruption recovery; pre-journal failure atomicity; malformed, trailing-record, gap, and behind-base refusal; the captain cursor barrier; the processed marker's sequence bounds; leases; guards; and non-branch-home invariance.
`tests/fm-wake-drain-outcome-backstop.test.sh` covers keyless resurfacing, causal suppression, same-second ordering, one-shot presentation, first-drain index self-healing under the outcome lock, store-fault fail-closed behavior, bounded history cost and output, and the oversized-line limit.
`tests/fm-teardown.test.sh` covers removal of the retired task's outcome index and the append-side rule that a post-teardown report does not recreate it.
The branch-offer, heartbeat-offer, heartbeat-not-ridden-by-main-only-rows, main-only-check-class, identity-bound-iDA-result, captain-held-stale-stays-on-main, and mixed-signal-routing tests remain in `tests/fm-pi-watch-extension.test.sh` (the last two routing classes exercise `offerWakeToBranch`'s trigger-key cross-reference end to end), the recovery test remains in `tests/fm-session-start.test.sh`, and the per-actor consume regression remains in `tests/fm-wake-queue.test.sh`.
It also covers the off-thread delivery contract behaviorally: that a delivery leaves the event loop running rather than blocking it, that interleaved reports stay ordered and exactly once, that a session replaced mid-delivery neither loses nor duplicates an outcome, and that a failing store script surfaces without losing or doubling one.
`tests/fm-watch-triage.test.sh` covers `bin/fm-watch.sh`'s side of the contract end to end: needs-decision and no-verb captain-held signal rows are marked `needs-decision:`, while ordinary blocked or captain-relevant signals stay unmarked.
Live guards: `FM_PI_BRANCH_LIVE_E2E=1 tests/fm-pi-branch-live-e2e.test.sh` exercises the real installed Pi SDK's immediate active-transcript appendEntry rendering, persistence, custom-entry model exclusion, branch-session surfaces, and watcher-owned fallback after rejected branch settlement.
`FM_PI_BRANCH_RESPONSIVENESS_E2E=1 tests/fm-pi-branch-responsiveness-live-e2e.test.sh` answers the question only a real TUI can: it types into an isolated Pi pane while outcomes are delivered and fails if keystroke echo leaves the class of the same machine's extension-free floor.
Record dated current results in [docs/verification/runtime-backends.md](verification/runtime-backends.md).
The strict typecheck in `tests/fm-pi-primary-types.test.sh` pins the extension against the installed Pi package.

## Historical task records

The branch receives no lifecycle projection for ordinary task progress.
It can still process eligible wake rows and perform already-authorized operations through their existing owners, but it cannot write the compact task progress block or make final semantic acceptance.
Material branch results return through the ordinary outcome channel so MAIN can review the artifact, advance the next step, and update the original task row.

The branch does not read or continue historical lifecycle, policy or action records.
An existing operation owner may narrowly read an immutable historical terminal or merge fact when that is required to preserve an already attempted or uncertain effect; that compatibility never admits work to the branch or reactivates the removed engine.
