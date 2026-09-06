---
name: captain-hold-lifecycle
description: >-
  Agent-only policy for completing investigations and visual reviews without losing unresolved captain calls, and for closing what the captain owns with his actual words.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a captain decision, when recording or routing the captain's answer, and on any RECORD DIVERGENCE line the wake drain prints.
user-invocable: false
metadata:
  internal: true
---

# Captain-hold lifecycle

A decision is not a separate thing: it is simply a task waiting on the captain.
The one primitive is an ordinary backlog task held for the captain through `bin/fm-captain-hold.sh hold`; its identity is the task id, and that wrapper owns the deterministic mechanics this policy relies on.
The agent performs the semantic inventory because scripts must not infer captain calls from report prose, visual-review artifacts, terminal output, or chat.

## Policy

Every unresolved question that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must be carried by a captain-held task in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
Prefer holding the work item the question gates over minting a new row; create a new task only when no work item exists to hold.
Put the question and its options in the hold reason, and keep one held task per genuine gate: a multi-question review is one held task pointing at its report, not a row per question. Represent that task with exactly one board card that consolidates its questions and options; never fan one task id into duplicate same-key cards.
Register or re-hold through `bin/fm-captain-hold.sh hold`, which is idempotent per task id.
After inventorying the whole report and review surface, run `bin/fm-captain-hold.sh complete` with every captain-held task id, or with `--none` only when the reviewed surface leaves nothing waiting on the captain.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; secondmate-owned work registers in that secondmate home's backlog, and a question already held anywhere is never re-registered as a second row.
Do not close a captain-held task merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
Holding the work item the question gates is safe for exactly that reason: cleanup keeps such a row open with the finished work's deliverable recorded and returns it to the queue, so it still reads as the captain's own call.
Only `answer` with the captain's words or an evidence-backed `reconcile close` may close it.

Never close anything the captain owns without recording what he actually said: `bin/fm-captain-hold.sh answer` writes his exact words into the task and closes it in the same act, with `--release` when the answer frees a captain-gated work item to proceed instead of completing a question.
When the answer changes what a task must build, follow `AGENTS.md` section 7's Validate contract to preserve the captain's words in the brief and steer the worker.
When the captain says "later", that is an answer too: re-hold with `bin/fm-captain-hold.sh hold <id> --reason "<reason>" --until <date>` so the item leaves the live Captain's Call and resurfaces on its date, instead of leaving a live-looking card or fabricating a closure.
"A keyed answer closes its matching captain-held task" is one capability with one owner, `bin/fm-captain-hold.sh answers`, and every channel that carries a captain answer feeds it the same task id and answer; a channel never maps keys to tasks, records a decision, or closes anything itself.
Chat already feeds it through `bin/fm-send.sh --resolve-key`, and a captured-answer source feeds it once bound with `bin/fm-captain-hold.sh bind <source-id>`; bind before arming the source, and key each structured question by the held task's id.
An unbound source and a key that names no captain-held task both simply feed nothing: the answer is still captured and firstmate is still woken, and closing falls back to the direct command above.
One answer value is reserved and closes nothing: `reconcile` means "go re-check reality", never "the captain answered", so the shared intake refuses it from every channel and creates nothing.
A bound captured source uses a separate seam: its adapter omits reconcile from keyed answers and emits the selected task id through `reconciles`, the generic runner feeds that into `reconcile-requests`, and the intake verifies the source binding and the local captain-held task before filing the durable board request.
A remote-secondmate card whose task is absent from the main backlog therefore remains announced but cannot create a main-home request; owner-aware request and mutation routing to the authoritative secondmate home is a separate follow-up.
That board-created request is yours to work off in the turn that receives it: `bin/fm-captain-hold.sh reconcile close <id> --evidence-file <path>` records the EVIDENCE and closes a moot call, while `reconcile note <id> --note-file <path>` annotates a genuinely active call and leaves it held.
Both outcomes refuse unless that task still has the pending request created by the captain's board selection, so neither is a standalone way to mutate a captain call.
A normal captain answer also retires any pending request because the call is settled, including close, release, and idempotent replay paths.
A retirement failure makes the command fail without reversing the already-durable answer, close, or note, and `reconcile list` keeps the surviving request visible for retry.
`reconcile list` names every request still outstanding.
Never use `answer` for an evidence-only moot call: `answer` records what the captain said, while `reconcile close` records verified evidence.
A captain-held task closed outside this owner leaves no durable answer, so the completion gate keeps failing until `answer` records the decision the captain actually gave.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create held tasks.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

A captain call can be written down twice - as the keyed status decision the fold reads, and as the backlog task held for the captain - and those two records can disagree without either surface saying so.
`bin/fm-captain-hold.sh diverged` reports that contradiction and the wake drain prints it as `RECORD DIVERGENCE`; it closes nothing, because a captain call closed wrongly leaves review entirely, which is worse than the noise.
Read such a line as "these two records disagree", never as "the captain ruled and someone forgot to file it": a call can dissolve because its premise was false, or turn out to have been a question of fact rather than the captain's to answer.
Reconcile it with what actually happened - `answer` when the captain's own words exist to record, and a fresh `needs-decision` line re-opening the status decision when that resolution was not the captain's word.
The absence of a routed work item is not a divergence and the guard never requires one: when the decision IS the deliverable there is nothing to route.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain, and find the task each one gates.
3. Hold that task - or create one captain-held task for the review's open questions - with a concise reason carrying the question and options.
4. Run `complete` with the full captain-held inventory for that review pass.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. Close each call only through `answer` (or a channel that feeds `answers`), close a board-requested moot call through evidence-backed `reconcile close`, record a still-active reconciliation through `reconcile note`, use `--until` when the captain defers it, or confirm a channel already closed it.
7. Confirm Bearings reflects the outcome: answered or reconciled-moot calls leave Captain's Call, released work resumes, active reconciliations remain held, and deferred calls sit in Charted Next with their date.

`bin/fm-captain-hold.sh --help` owns command syntax, close modes, legacy-identity compatibility, completion attestation, retry behavior, and close ordering.
`docs/captain-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
