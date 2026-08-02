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
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create holds.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that pass `ask-user-authority`'s bar for asking; decide the rest yourself.
3. Read the open captain decisions the script prints, and for each surviving choice either `fold` it into the decision that already owns the question or register it with `hold` under a stable key, using `--distinct` only when it is genuinely a different question.
4. Run the script's `complete` command with the full unresolved-key inventory for that review pass, or `--folded` when every finding went into an existing decision.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. When the captain answers, run `resolve` in that same turn with `--decision` and either `--routed-to` for dependent work or `--no-routed-work` when none exists, creating and blocking dependent work first where it applies.
7. Confirm Bearings no longer shows the closed decision and that routed work remains in structured backlog state.

A decision the fleet view marks as ageing has already been asked.
Resurface it as still waiting since its date, never as a new question, and never register a second decision for it.

`bin/fm-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
`docs/decision-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
