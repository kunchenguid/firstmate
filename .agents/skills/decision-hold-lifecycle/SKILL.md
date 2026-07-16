---
name: decision-hold-lifecycle
description: >-
  Agent-only policy for safe rich-review surfaces and for completing investigations and visual reviews without losing unresolved captain decisions.
  Load before creating, presenting, or ending a structured or Lavish review, before treating an investigation or scout report as complete, and when recording or routing the captain's answer.
user-invocable: false
metadata:
  internal: true
---

# Rich review and durable decision lifecycle

This skill is the single policy owner for Firstmate-generated rich-review surfaces and for unresolved captain decisions discovered by an investigation or visual review.

## Rich-review and decision-input contract

Rich-review surfaces are optional companions for rich reports, visual comparisons, annotated sources, structured evidence, or multi-finding review.
Keep the primary chat path available, and use it alone for simple decisions.
Primary chat is the only approval channel unless the integration has both a durable return path into Firstmate's authoritative workflow and verified submission idempotence with acknowledgement.
For Lavish 0.1.40, a browser `waiting` or `listening` state proves only the absence or presence of an active poll, `queueKey` replaces only unsent browser entries and is not server idempotence, polling can remove feedback before agent acknowledgement, and the verified SDK cannot prove `sent`, `delivered`, or `acknowledged` state.
None of those signals satisfies the approval-channel guarantees, and any different behavior after an upstream change must be revalidated before it can be relied upon.

Every rich-review surface must expose at least one authoritative source path, the exact commit or snapshot, a raw-file option, and the artifact type and fidelity.
Provide both absolute and repository-relative paths when both exist, and omit only a path form that is inapplicable.
When a review rendering could be mistaken for product direction, state explicitly whether it is a product mockup.
Evidence-bearing decision reports must include citations or line references, severity rationale, alternatives, disconfirming evidence, consequences, and reversibility in proportion to the decision's impact.

Inputs are inactive by default and must be omitted or visibly disabled whenever no durable return path is armed.
Until both approval-channel guarantees are verified, direct the captain to decide in primary chat instead of submitting through the rich surface.
Artifact code must not claim `sent`, `delivered`, or `acknowledged` without specific evidence for the claimed state.
If an exceptional interactive surface meets both guarantees, disable repeated submission on first activation, prevent the same logical submission from being sent again, and show only truthful locally observed states.
Never preselect a choice that grants authority, changes security, or permits private access.

## Unresolved-decision lifecycle

Every unresolved decision that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must become a structured captain-held work item in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
The agent performs the semantic inventory because scripts must not infer decisions from report prose, visual-review artifacts, terminal output, or chat.
Give each distinct unresolved decision a stable privacy-safe key, register it through `bin/fm-decision-hold.sh hold`, and use the same key on retry so registration is idempotent while different decisions retain different durable identities.
After inventorying the whole report and review surface, run `bin/fm-decision-hold.sh complete` with every unresolved key, or with `--none` only when the reviewed surface contains no unresolved captain decision.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; main-home work creates main-home holds, and secondmate-owned work creates holds in that secondmate home's backlog rather than copying them into the main backlog.
Do not close a hold merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
The hold remains the authoritative Captain's Call item until the captain's answer is durably recorded, dependent work is created in the same backlog and blocked by that hold, and `bin/fm-decision-hold.sh resolve` routes the answer by clearing those dependency edges before closing the hold.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create holds.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain.
3. For each choice, choose a stable key and use the script's `hold` command with a concise title, reason, and repository.
4. Run the script's `complete` command with the full unresolved-key inventory for that review pass.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. After the captain decides, record dependent work with normal tasks-axi commands and block it by the hold identity.
7. Put the captain's exact durable decision in a file and use the script's `resolve` command with every routed task.
8. Confirm Bearings no longer shows the closed hold and that routed work remains in structured backlog state.

`bin/fm-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
`docs/decision-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
