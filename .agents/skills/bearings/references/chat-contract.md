# bearings: chat-response contract and tone rules

This skill is the one owner of the `/bearings` chat-response format; the snapshot and classifier own the data that feeds it, and no other file restates this contract.
Every `/bearings` chat response renders EXACTLY these four sections, in THIS order, and nothing else structural (there is no At Anchor section):

1. **Captain's Call** - ONLY unsuppressed items that need the captain's own action now: a decision to make, a PR to approve or merge, a credential or login to provide, or a blocker only the captain can clear.
   Deferred or aged holds follow the presentation safety rule above instead.
   Include `contributions.captain` rows in this section, deduplicating any row already represented by its live captain hold or merge call.
   Show the other contribution actors only as counts beside the checked/known coverage, and disclose `captain_omitted`, `unmeasured_homes`, stale verdicts and checks with no verdict when nonzero.
   Empty-state: "Nothing needs your action right now" is allowed only when `contributions.proven_clear` is true and the existing decision set is empty.
   When the section is empty but coverage is incomplete, say that no decision is recorded and give the checked/known count; a missing coverage field is also unverified.
2. **Recently Landed** - the bounded current recent-completions baseline: merged PRs, completed scouts, and finished local-only merges across the main fleet and every registered secondmate home.
   Empty-state: "No recent completions are in the current baseline."
3. **Underway** - live work progressing on its own, one line of current state per direct report.
   Empty-state: "Nothing is underway."
4. **Charted Next** - queued or gated work waiting on the fleet or a date, deferred or aged captain-hold safety gates, plus action-free fleet-integrity warnings.
   Empty-state: "Nothing is queued."

Rules that keep the contract unambiguous:

- Every section ALWAYS renders, even when empty, with its short empty-state sentence; never omit a section.
- Every chat digest and file-mode report is a complete current snapshot, never a delta against a prior report.
- Recently Landed always renders the bounded current baseline, even when the same completions appeared in an earlier report.
- A captain hold appears in exactly one decision bucket: an unsuppressed live hold is in Captain's Call, while a blocked, dated, or aged hold is in Charted Next; `--all-decisions` moves the latter into Captain's Call and removes its gate.
- Underway independently reports active work, so an actively worked captain-held task may appear there plus its one decision bucket.
- A secondmate home can contribute to more than one section at once. Each active child is an Underway row regardless of the home-level `bearings_state`, while that same home's live captain hold is Captain's Call and its queued or external holds stay Charted Next. Do not hide active children because the home also has an open captain hold.
- The strict boundary keeps action-free items OUT of Captain's Call: a working or validating task, a queued item blocked on another task or a date, landed work, a completed scout's report pointer, a declared `paused:` external wait, and a bare recorded PR with no merge-ready signal each belong to one of the other three sections, never Captain's Call.
- A secondmate's own home-level row is not an Underway unit: `externally_held` belongs in Charted Next, and `unknown` belongs there as an unavailable-state gate unless its reason requires the captain's action.
- Do not suppress separately projected decisions, landed records, or gates from a `partial-structured` home merely because that secondmate's own row is `unknown` or its `invalidity` reports an inventory mismatch.
- Include the required direct address to the captain inside one item or empty-state sentence.
- Every PR appears as the full `https://...` URL; a shorthand `#number` is fine only as a back-reference after the full URL has already appeared in the same digest.
- The chat follows `AGENTS.md` section 9 and carries one scannable line per item.
- Detailed decisions, plans, full gate reasons, and evidence stay out of chat; file mode puts them in the report, while lavish mode puts only its payload-backed interactive detail on the board.
- In file mode, include the report path or link inside the four-section digest without adding another heading.
- In lavish mode, include the board URL inside the four-section digest the same way.

## Tone and content rules

- The optional file-mode report is a private, captain-facing internal artifact that lives in gitignored `data/`, so unlike normal captain chat it MAY reference task ids, PR URLs, and repo names.
- The captain works with those directly and needs them to resume; keep the report organized and scannable, not a raw dump.
- Every PR reference is a full `https://...` URL, never a bare `#number`.
- Never include PHI or secret values; the report is an operational artifact, but it is still subject to the same security and compliance rules that govern everything else in this fleet.
