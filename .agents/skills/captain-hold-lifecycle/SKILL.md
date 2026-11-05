---
name: captain-hold-lifecycle
description: >-
  Load before treating an investigation, Investigator report, structured review, or Lavish review as complete, before ending a visual review that exposed a user decision, when recording or routing the user's answer, and on any RECORD DIVERGENCE line the wake drain prints.
user-invocable: false
metadata:
  internal: true
---

# user-hold lifecycle

A decision is not a separate thing: it is simply a task waiting on the user.
The one primitive is an ordinary backlog task held for the user through `bin/fm-captain-hold.sh hold`; its identity is the task id, and that wrapper owns the deterministic mechanics this policy relies on.
The agent performs the semantic inventory because scripts must not infer user calls from report prose, visual-review artifacts, terminal output, or chat.

## Policy

Every unresolved question that belongs to the user and is discovered while producing, reading, presenting, or ending an investigation or visual review must be carried by a user-held task in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
For a Lavish board-backed handoff, pass the reply through `bin/fm-procevent-lavish.sh arm --agent-reply-file` before appending the status; the adapter owns version-specific acceptance ordering.
Prefer holding the work item the question gates over minting a new row; create a new task only when no work item exists to hold.
The originating investigation or review is never its own inventory entry, so hold a separate task for the call and pass `--origin <origin-id>` so `complete` can check it.
Put the question and its options in the hold reason, and keep one held task per genuine gate: a multi-question review is one held task pointing at its report, not a row per question. Represent that task with exactly one board card that consolidates its questions and options; never fan one task id into duplicate same-key cards.
Register or re-hold through `bin/fm-captain-hold.sh hold`, which is idempotent per task id.
After inventorying the whole report and review surface, the Director runs `bin/fm-captain-hold.sh complete` with every user-held task id, or with `--none` when nothing waits on the user.
An Investigator may attest its own empty inventory only through the narrow command exception in its generated brief's Definition of done.
For a non-empty inventory or a refused command, the Investigator reports to the Director rather than writing metadata or backlog records.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; Project-Director-owned work registers in that Project Director home's backlog, and a question already held anywhere is never re-registered as a second row.
Do not close a user-held task merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
Holding the work item the question gates is safe for exactly that reason: cleanup keeps such a row open with the finished work's deliverable recorded and returns it to the queue, so it still reads as the user's own call.
Only `answer` with the user's words or an evidence-backed `reconcile close` may resolve it.

Never close anything the user owns without recording what he actually said: `bin/fm-captain-hold.sh answer` writes his exact words into the task and closes a question-shaped call, while `--release` frees a user-gated work item to proceed.
A merge approval uses that existing release path because approval permits the merge to proceed; cleanup closes the work only after it lands and records what shipped.
Closing a held row at merge approval instead records completion before landing, so the backlog claims completion before the work actually ships.
When the answer changes what a task must build, follow `AGENTS.md` section 7's mid-task ask rule to preserve the user's words in the brief and steer the worker.
When the user says "later", that is an answer too: re-hold with `bin/fm-captain-hold.sh hold <id> --reason "<reason>" --until <date>` so the item leaves the live user's Call and resurfaces on its date, instead of leaving a live-looking card or fabricating a closure.
"A keyed answer resolves its matching user-held task" is one capability with one owner, `bin/fm-captain-hold.sh answers`, and every channel that carries a user answer feeds it the same task id and answer; a channel never maps keys to tasks, records a decision, or resolves anything itself.
Chat already feeds it through `bin/fm-send.sh --resolve-key`, and a captured-answer source feeds it once bound with `bin/fm-captain-hold.sh bind <source-id>`; bind before arming the source, and key each structured question by the held task's id.
An unbound source and a key that names no user-held task both simply feed nothing: the answer is still captured and the Director is still woken, and closing falls back to the direct command above.
One answer value is reserved and closes nothing: `reconcile` means "go re-check reality", never "the user answered", so the shared intake refuses it from every channel and creates nothing.
A bound captured source uses a separate seam: its adapter omits reconcile from keyed answers and emits the selected task id through `reconciles`, the generic runner feeds that into `reconcile-requests`, and the intake verifies the source binding and the local user-held task before filing the durable board request.
A remote Project Director card whose task is absent from the main backlog therefore remains announced but cannot create a main-home request; owner-aware request and mutation routing to the authoritative Project Director home is a separate follow-up.
That board-created request is yours to work off in the turn that receives it: `bin/fm-captain-hold.sh reconcile close <id> --evidence-file <path>` records the EVIDENCE and closes a moot call, while `reconcile note <id> --note-file <path>` annotates a genuinely active call and leaves it held.
Both outcomes refuse unless that task still has the pending request created by the user's board selection, so neither is a standalone way to mutate a user call.
A normal user answer also retires any pending request because the call is settled, including close, release, and idempotent replay paths.
A retirement failure makes the command fail without reversing the already-durable answer, close, or note, and `reconcile list` keeps the surviving request visible for retry.
`reconcile list` names every request still outstanding.
Never use `answer` for an evidence-only moot call: `answer` records what the user said, while `reconcile close` records verified evidence.
A user-held task closed outside this owner leaves no durable answer, so the completion gate keeps failing until `answer` records the decision the user actually gave.
Resolved findings, recommendations that need no user choice, and prose that merely sounds decision-like do not create held tasks.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

A user call can be written down twice - as the keyed status decision the fold reads, and as the backlog task held for the user - and those two records can disagree without either surface saying so.
`bin/fm-captain-hold.sh diverged` reports that contradiction and the wake drain prints it as `RECORD DIVERGENCE`; it closes nothing, because a user call closed wrongly leaves review entirely, which is worse than the noise.
Read such a line as "these two records disagree", never as "the user ruled and someone forgot to file it": a call can dissolve because its premise was false, or turn out to have been a question of fact rather than the user's to answer.
Reconcile it with what actually happened - `answer` when the user's own words exist to record, and a fresh `needs-decision` line re-opening the status decision when that resolution was not the user's word.
The absence of a routed work item is not a divergence and the guard never requires one: when the decision IS the deliverable there is nothing to route.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the user, and find the task each one gates.
3. The Director holds that task - or creates one user-held task for the review's open questions - with a concise reason carrying the question and options.
4. Attest the full inventory for that review pass under the caller authority in Policy above.
5. Relay the choices to the user as decisions from Bearings' user's Call section under `AGENTS.md` section 9; do not use the word hold in user chat.
6. Close each call only through `answer` (or a channel that feeds `answers`), close a board-requested moot call through evidence-backed `reconcile close`, record a still-active reconciliation through `reconcile note`, use `--until` when the user defers it, or confirm a channel already closed it.
7. Confirm Bearings reflects the outcome: answered or reconciled-moot calls leave user's Call, released work resumes, active reconciliations remain held, and deferred calls sit in Next with their date.

`bin/fm-captain-hold.sh --help` owns command syntax, close modes, legacy-identity compatibility, completion attestation, retry behavior, and close ordering.
`docs/captain-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
