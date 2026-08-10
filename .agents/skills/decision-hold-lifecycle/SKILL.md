---
name: decision-hold-lifecycle
description: >-
  Agent-only policy for completing investigations and visual reviews without losing unresolved captain decisions or unscheduled product ideas.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a decision, and when recording or routing the captain's answer.
user-invocable: false
metadata:
  internal: true
---

# Durable unresolved-decision and product-idea lifecycle

This skill is the single policy owner for unresolved captain decisions and unscheduled product ideas discovered by an investigation or visual review.

## Policy

Every unresolved decision that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must become a structured captain-held work item in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
Every product idea, feature proposal, or strategic suggestion not yet scheduled as work must also become a row in that originating home's product-idea ledger with its report section as the source.
The agent performs both semantic inventories because scripts must not infer decisions or ideas from report prose, visual-review artifacts, terminal output, or chat.
Give each distinct unresolved decision a stable privacy-safe key, register it through `bin/fm-decision-hold.sh hold`, and use the same key on retry so registration is idempotent while different decisions retain different durable identities.
After inventorying the whole report and review surface, append every discovered idea row and run `bin/fm-decision-hold.sh complete` with the decision inventory plus the idea inventory attestation.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; main-home work creates main-home holds, and secondmate-owned work creates holds in that secondmate home's backlog rather than copying them into the main backlog.
Do not close a hold merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
The hold remains the authoritative Captain's Call item until the captain's answer is durably recorded, dependent work is created in the same backlog and blocked by that hold, and `bin/fm-decision-hold.sh resolve` routes the answer by clearing those dependency edges before closing the hold.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create holds.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory genuine unresolved choices that require the captain and unscheduled product ideas that need durable discovery.
3. For each choice, choose a stable key and use the script's `hold` command with a concise title, reason, and repository.
4. Append each unscheduled idea to the originating home's `data/product-ideas.md` as a well-formed `PI-NNN` row whose Source is `data/<origin-id>/report.md#<section-heading>`, never a line number.
5. Run the script's `complete` command with the decision inventory (`--none` or every unresolved key) and the idea inventory (`--ideas <PI-id>...` or `--no-ideas`) for that review pass.
6. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
7. After the captain decides, record dependent work with normal tasks-axi commands and block it by the hold identity.
8. Put the captain's exact durable decision in a file and use the script's `resolve` command with every routed task.
9. Confirm Bearings no longer shows the closed hold and that routed work remains in structured backlog state.

`bin/fm-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
`docs/decision-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
