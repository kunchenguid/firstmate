---
name: decision-hold-lifecycle
description: >-
  Agent-only policy for completing investigations and visual reviews without losing unresolved captain decisions.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a decision, and when recording or routing the captain's answer.
user-invocable: false
metadata:
  internal: true
---

# Durable unresolved-decision lifecycle

This skill is the single policy owner for unresolved captain decisions discovered by an investigation or visual review.

## Policy

Every unresolved decision that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must become a structured captain-held work item in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
The agent performs the semantic inventory because scripts must not infer decisions from report prose, visual-review artifacts, terminal output, or chat.
Give each distinct unresolved decision a stable privacy-safe key, register it through `bin/fm-decision-hold.sh hold`, and use the same key on retry so registration is idempotent while different decisions retain different durable identities.
After inventorying the whole report and review surface, run `bin/fm-decision-hold.sh complete` with every unresolved key, or with `--none` only when the reviewed surface contains no unresolved captain decision.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; main-home work creates main-home holds, and secondmate-owned work creates holds in that secondmate home's backlog rather than copying them into the main backlog.
Do not close a hold merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
When the captain's answer authorizes follow-up work, the hold remains the authoritative Captain's Call item until that answer is durably recorded, dependent work is created in the same backlog and blocked by the hold, and `bin/fm-decision-hold.sh resolve` routes the answer by clearing those dependency edges before closing the hold.
When the captain's answer routes no follow-up work at all, such as a declined proposal, `bin/fm-decision-hold.sh decline` records that answer and closes the hold; it never substitutes for routing work the captain did authorize.
When the captain simply answers a hold that has no follow-up work routed behind it yet, `bin/fm-decision-hold.sh answer` records that answer and closes the hold, so answering is closing rather than a separate later act that can be forgotten.
"A keyed answer closes its matching hold" is one capability with one owner, `bin/fm-decision-hold.sh answers`, and every channel that carries a captain answer feeds it the same `<decision-key>` and answer.
The exact answer `__drop__` is the reserved close/drop encoding owned by that script's header: the intake declines the hold with a dropped-by-captain record rather than recording a substantive answer, and closes only that hold while existing dependents remain independent queued work.
A channel never maps a key to a hold, records a decision, or closes anything itself, so no channel is special and a new one needs no new closing logic.
Chat already feeds it: `bin/fm-send.sh --resolve-key` answers a decision in whichever ledger still holds it open, including a decision already transferred to its durable hold.
A captured-answer source feeds it too once bound with `bin/fm-decision-hold.sh bind <source-id> <origin-id>`, or with `--any-origin` for a source that carries answers across origins, such as the bearings board; bind before arming the source, and key each structured question by the hold's own decision key, or by its full hold identity under an any-origin binding.
An unbound source and a question slug that is not a decision key both simply feed nothing: the answer is still captured and firstmate is still woken, and closing falls back to the commands above.
A hold closed outside this owner leaves no durable answer, so the completion gate keeps failing until `bin/fm-decision-hold.sh repair` records the decision the captain actually gave; neither unrouted path may stand in for an answer the captain has not given.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create holds.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain.
3. For each choice, choose a stable key and use the script's `hold` command with a concise title, reason, and repository.
4. Run the script's `complete` command with the full unresolved-key inventory for that review pass.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. If the captain authorizes dependent work, record it with normal tasks-axi commands and block it by the hold identity.
7. Put the captain's exact durable decision in a file and close the hold with the script's `resolve` command and every routed task, its `answer` command when the captain answered a hold with no routed work behind it, its `decline` command when the answer routes no work at all, or its `repair` command when the hold was already closed outside the script.
   A hold that a channel already closed by feeding its keyed answer needs none of these; confirm it in step 8 instead.
8. Confirm Bearings no longer shows the closed hold and that any routed work remains in structured backlog state.

`bin/fm-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
`docs/decision-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
