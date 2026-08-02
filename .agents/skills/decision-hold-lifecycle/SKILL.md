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
Apply `ask-user-authority`'s bar for asking to every candidate first; a question that fails that bar is Firstmate's to decide and must not be registered here at all.
Give each remaining distinct unresolved decision a stable privacy-safe key, register it through `bin/fm-decision-hold.sh hold`, and use the same key on retry so registration is idempotent while different decisions retain different durable identities.
Before a new identity is created the script puts the home's open captain decisions in front of you and refuses, because a second key covering an already-open question is how this queue compounds.
Read that listing and judge it semantically: an earlier review of the same pull request, subsystem, or policy question usually already owns the decision under a different key.
When it does, use `bin/fm-decision-hold.sh fold` to add this pass's finding to the existing decision instead of opening a second one, then complete against that fold.
Re-run with `--distinct` only when the question is genuinely different from every decision in that listing; the attestation is recorded in the new decision.
After inventorying the whole report and review surface, run `bin/fm-decision-hold.sh complete` with every unresolved key, or with `--none` only when the reviewed surface contains no unresolved captain decision.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; main-home work creates main-home holds, and secondmate-owned work creates holds in that secondmate home's backlog rather than copying them into the main backlog.
Do not close a hold merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
The hold remains the authoritative Captain's Call item until the captain's answer is durably recorded by `bin/fm-decision-hold.sh resolve`, which closes it.
Record the answer in the same turn it arrives.
An answer that lives only in a chat message is worse than no answer, because it acquires authority it cannot evidence: later work cites it as settled with nothing to point at, and the decision stays open and gets asked again.
Recording is deliberately cheap so nothing stands between hearing the answer and writing it down - pass the captain's words to `resolve` with `--decision`, and use `--no-routed-work` when the answer spawns no dependent task.
Two closures other than a fresh captain answer are equally first class: a question that turns out to be firstmate's own call under `ask-user-authority`'s bar closes with `--decided-by firstmate`, and one an earlier captain answer already settled closes with that answer and its source as the decision text.
Neither is a shortcut around the captain; each is the honest record of who actually decided.
A decision closed with a real record but not through this script still counts as durably resolved, so an earlier bulk close does not strand the investigation that found it.
Where dependent work genuinely exists, create it in the same backlog, block it by the hold identity, and route it with `--routed-to`; the script refuses `--no-routed-work` while any task is blocked by the hold, so that requirement cannot be skipped.
When the captain's answer routes no follow-up work at all, such as a declined proposal, `bin/fm-decision-hold.sh decline` records that answer and closes the hold; it never substitutes for routing work the captain did authorize.
When the captain simply answers a hold that has no follow-up work routed behind it yet, `bin/fm-decision-hold.sh answer` records that answer and closes the hold, so answering is closing rather than a separate later act that can be forgotten.
"A keyed answer closes its matching hold" is one capability with one owner, `bin/fm-decision-hold.sh answers`, and every channel that carries a captain answer feeds it the same `<decision-key>` and answer.
A channel never maps a key to a hold, records a decision, or closes anything itself, so no channel is special and a new one needs no new closing logic.
Chat already feeds it: `bin/fm-send.sh --resolve-key` answers a decision in whichever ledger still holds it open, including a decision already transferred to its durable hold.
A captured-answer source feeds it too once bound with `bin/fm-decision-hold.sh bind <source-id> <origin-id>`; bind before arming the source, and key each structured question by the hold's own decision key.
An unbound source and a question slug that is not a decision key both simply feed nothing: the answer is still captured and firstmate is still woken, and closing falls back to the commands above.
A hold closed outside this owner leaves no durable answer, so the completion gate keeps failing until `bin/fm-decision-hold.sh repair` records the decision the captain actually gave; neither unrouted path may stand in for an answer the captain has not given.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create holds.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that pass `ask-user-authority`'s bar for asking; decide the rest yourself.
3. Read the open captain decisions the script prints, and for each surviving choice either `fold` it into the decision that already owns the question or register it with `hold` under a stable key, using `--distinct` only when it is genuinely a different question.
4. Run the script's `complete` command with the full unresolved-key inventory for that review pass, or `--folded` when every finding went into an existing decision.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. When the captain authorizes dependent work, record it with normal tasks-axi commands and block it by the hold identity.
7. When the captain answers, run `resolve` in that same turn with `--decision` and either `--routed-to` for dependent work or `--no-routed-work` when none exists, creating and blocking dependent work first where it applies. When the answer routes no follow-up work at all, `decline` is the same one-turn recording without inventing a `--no-routed-work` resolve; `answer` records that same one-turn closure when the hold has no routed work behind it yet; when a hold was already closed outside this owner, `repair` records the decision it closed with.
   A hold that a channel already closed by feeding its keyed answer needs none of these; confirm it in step 8 instead.
8. Confirm Bearings no longer shows the closed hold and that any routed work remains in structured backlog state.

A decision the fleet view marks as ageing has already been asked.
Resurface it as still waiting since its date, never as a new question, and never register a second decision for it.

`bin/fm-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
`docs/decision-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
