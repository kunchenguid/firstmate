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
After inventorying the whole report and review surface, run `bin/fm-decision-hold.sh complete` with every currently unresolved key, or with `--none` only when the reviewed surface contains no unresolved captain decision; a positional key requires an active hold on first completion, while `--resolved <key>` explicitly carries an older resolved key.
Completion provenance must preserve whether each key was verified as current or supplied as historical, so an exact retry may recognize a current key that has since resolved without letting older history substitute for a missing active generation; released-version inventories may be classified automatically only from source-verifiable active or retained Done records, while archive-only generations require explicit reclassification through `complete`.
Every currently unresolved key must still have its valid active captain-held record, but a historical key whose durable resolution later moved from the backlog's bounded Done window into its configured archive remains resolved and must not be restored merely to complete a later review pass.
Historical proof must remain in the originating home's effective backlog retention archive, retain that owner's provenance, and bind the exact origin, decision key, captain answer digest, and routed identities to their matching routed-work records; note snapshots and copied artifacts never qualify as Done retention.
Retention-affecting tasks-axi commands must cross the project-scoped `bin/tasks-axi` entrypoint, including terminal public-followup actions; the decision owner's `task-done` and `retention-prune` commands use that same transaction boundary, so the exact records archived by normal retention receive transition provenance.
Pre-boundary archive records remain fail-closed until an operator explicitly authorizes their exact backlog owner, archive owner, origin, key, and record digest through `migrate-retention`.
A released-version record that predates embedded origin and key fields remains compatible when its composed hold identity has exactly one valid origin/key decomposition or when an existing exact attestation matches the complete record.
An ambiguous unattested legacy identity fails closed until an operator explicitly migrates it with an independently authored identity mapping bound to the exact retained record; mutable claimant metadata and a replayed recorded decision cannot authorize that mapping.
A missing, malformed, mismatched, or merely presumed active decision record still stops completion, and neither titles, report prose, nor any other unstructured surface can substitute for its structured ownership.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; main-home work creates main-home holds, and secondmate-owned work creates holds in that secondmate home's backlog rather than copying them into the main backlog.
Do not close a hold merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
When the captain's answer authorizes follow-up work, the hold remains the authoritative Captain's Call item until that answer is durably recorded, dependent work is created in the same backlog and blocked by the hold, and `bin/fm-decision-hold.sh resolve` routes the answer by clearing those dependency edges before closing the hold.
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
2. Inventory only genuine unresolved choices that require the captain.
3. For each choice, choose a stable key and use the script's `hold` command with a concise title, reason, and repository.
4. Run the script's `complete` command with the full unresolved-key inventory for that review pass; use `--resolved <key>` to carry exact historical proof or to explicitly reclassify a historical key in surviving released-version metadata.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. If the captain authorizes dependent work, record it with normal tasks-axi commands and block it by the hold identity; run every command that may advance Done retention through `bin/tasks-axi` or the decision owner's equivalent `task-done` command.
7. Put the captain's exact durable decision in a file and close the hold with the script's `resolve` command and every routed task, its `answer` command when the captain answered a hold with no routed work behind it, its `decline` command when the answer routes no work at all, or its `repair` command when the hold was already closed outside the script.
   An ambiguous released-version resolution with no existing origin-bound attestation remains unresolved unless an operator supplies the independent identity mapping required by `migrate-legacy`; do not derive that mapping from surviving metadata or replayed answer text.
   A hold that a channel already closed by feeding its keyed answer needs none of these; confirm it in step 8 instead.
8. Confirm Bearings no longer shows the closed hold and that any routed work remains in structured backlog state.

`bin/fm-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
`docs/decision-hold-lifecycle.md` records integration context and regression evidence without restating this policy.
