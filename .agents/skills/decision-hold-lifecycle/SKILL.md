---
name: decision-hold-lifecycle
description: >-
  Agent-only policy for filing every captain decision to one bar and for completing investigations and visual reviews without losing unresolved decisions.
  Load before filing any captain-held decision whatever produced it, before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a decision, and when recording or routing the captain's answer.
user-invocable: false
metadata:
  internal: true
---

# Durable captain-decision lifecycle

This skill is the single policy owner for captain decisions, and it owns two distinct contracts.

The **filing bar** applies to EVERY captain-held decision regardless of what produced it: an investigation, a visual review, a routine observation, or a captain-gated thread filed straight into the backlog.
The **completion gate** applies to investigations and visual reviews, which must inventory their unresolved decisions before they may be treated as complete.
A decision filed outside an investigation still meets the filing bar; it simply has no inventory to complete.

## The filing bar

Every captain decision must be self-contained and readable cold, because the captain may return days later having forgotten what produced it.
`data/captain-shared.md`'s decision-presentation section is the authoritative statement of that bar and of the due-diligence checklist a decision must clear before it is presented as ready; read it rather than working from memory of it.

`bin/fm-decision-hold.sh` makes the bar structural by requiring each dimension as its own field rather than as prose inside one reason, and by forcing an explicit choice about the built surface instead of letting an optional flag be forgotten.
What the script cannot judge is whether the prose is genuinely clear, jargon-free, and decidable without re-reading the investigation, or whether the options are really built and viewable.
When the captain's useful answers are a clean small pick, record two to four short explicit labels through the supported filing command; otherwise leave options absent and preserve the free-text decision rather than forcing nuance into misleading buttons.
When the decision asks the captain to supply a specific fact or classification rather than choose a course, mark it `fact` and give the expected-answer shape with it, which the script now requires together.
The marker changes only how the existing free-text Answer control is framed; never use it to imply that a richer data-entry surface exists.
When two or more distinct decisions genuinely come from the same investigation or report, assign the same privacy-safe group slug to each so Mission Control can contain them visually without merging their identities or answer paths.
Never group decisions merely because their subjects are similar, and never derive a group key, options, a fact marker, or an expected-answer hint from prose.
That judgement is yours on every filing, and passing the script is not evidence you met it.

The script also refuses a filing that fails one structural readiness checklist, and `bin/fm-decision-hold.sh doctor` sweeps the same checklist across open decisions; [`docs/decision-hold-lifecycle.md`](../../../docs/decision-hold-lifecycle.md) states it.
Passing it means only that each dimension is present and well-shaped, never that the decision is worth the captain's time.

Use `hold` when an investigation or visual review discovered the decision, so it gets its own durable decision identity under that origin.
Use `hold-item` when the decision gates a backlog item that already exists, whatever kind that item carries.
Never file a captain decision with a bare `tasks-axi hold <id> --kind captain`; that path skips the bar, which is exactly how thin decisions reached the captain before.
Setting a decision aside and bringing it back are the two exceptions, because they restore existing text rather than file a decision; `bin/fm-mission-control.sh` owns both.

## Inventory policy

Every unresolved decision that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must become a structured captain-held work item in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
The agent performs the semantic inventory because scripts must not infer decisions from report prose, visual-review artifacts, terminal output, or chat.
Give each distinct unresolved decision a stable privacy-safe key, register it through `bin/fm-decision-hold.sh hold`, and use the same key on retry so registration is idempotent while different decisions retain different durable identities.
After inventorying the whole report and review surface, run `bin/fm-decision-hold.sh complete` with every unresolved key, or with `--none` only when the reviewed surface contains no unresolved captain decision.
When a later pass establishes that a key duplicates a question already inventoried under a different key, retract it through `bin/fm-decision-hold.sh retract` naming the surviving key, which keeps the question gated under one identity; removing the duplicate from the backlog without retracting it leaves the inventory pointing at an identity that no longer exists.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; main-home work creates main-home holds, and secondmate-owned work creates holds in that secondmate home's backlog rather than copying them into the main backlog.
Do not close a hold merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
The hold remains the authoritative Captain's Call item until the captain's answer is durably recorded, dependent work is created in the same backlog and blocked by that hold, and `bin/fm-decision-hold.sh resolve` routes the answer by clearing those dependency edges before closing the hold.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create holds.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain.
3. For each decision, choose a stable key and use the script's `hold` command with a concise title, reason, and repository, plus every context dimension the filing bar above requires, explicit option labels only when the choice is genuinely a clean small pick, fact-intake framing only when the captain must supply a fact or classification, and one shared group slug only for distinct decisions from the same origin.
   Read `data/captain-shared.md`'s decision-presentation section and judge the prose against it before filing; the script enforces that each dimension is present, never that it is clear.
   Where a built surface exists, link it; where the decision needs one that does not exist yet, build it before presenting the decision as ready rather than filing the acknowledgment that none applies.
4. Run the script's `complete` command with the full unresolved-key inventory for that review pass.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
   Bearings surfaces the one-line reason, so relay the filed context with it rather than assuming the captain has already read the board, which is where the labelled sections appear.
6. After the captain decides, record dependent work with normal tasks-axi commands and block it by the hold identity.
7. Put the captain's exact durable decision in a file and use the script's `resolve` command with every routed task.
8. Confirm Bearings no longer shows the closed hold and that routed work remains in structured backlog state.

`bin/fm-decision-hold.sh --help` owns command syntax, exact context flags, identity construction, completion attestation, retry behavior, and close ordering.
`docs/decision-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
`docs/mission-control.md` records how the filed context reaches the captain on the board.
