---
name: docs-sync
description: Run a bounded, tracked tending pass that keeps a project's documentation true to the code and to Asana - no half-implemented leftovers, no stale claims. Use when the user invokes /docs-sync (e.g. "/docs-sync acme") or asks to reconcile, clean up, or update a project's docs against what actually shipped. Selects the next doc slice with the review ledger, ships a direct-fix crew that reconciles docs against code/PRs/commits, then firstmate reconciles Asana with every write captain-confirmed.
user-invocable: true
metadata:
  internal: true
---

# docs-sync

A tending pass keeps documentation honest a bounded slice at a time: docs that match what the code actually does, with no work-in-progress leftovers and no claims the code has since moved past.
Documentation files are this pass's territory; comments inside the code belong to the `/code-shape` pass, so the two tending passes never edit the same lines.
The scoping, tracking, and prioritization are the review ledger's job on its `docs` track (`bin/fm-review-ledger.sh`, narrated in `docs/review-ledger.md`); this skill turns the chosen slice into one direct-fix ship for the docs, then reconciles Asana separately because writing to Asana is outward-facing.
It is captain-invoked only; it never runs on a schedule.

The work splits by who can see what.
The crew reconciles docs against code, PRs, and commit history, all readable from the repo it already has.
Firstmate reconciles docs and code against Asana: it holds the Asana connector a spawned crew may not, and every Asana write needs the captain's word.

## Running a pass

1. **Resolve the project and read its direction.**
   Resolve the project from the invocation exactly as intake does (`AGENTS.md` section 6) and state it back.
   Read `data/directions/<project>.md`; a doc that documents the project against its stated direction is worth more than one that just matches today's code.

2. **Ask the ledger for the next doc slice.**
   Run `bin/fm-review-ledger.sh select <project> docs` and read the chosen unit(s), the reason, and the head sha; `NOTHING_TO_REVIEW` means the docs are covered and quiet, so say so and stop.
   Run `bin/fm-review-ledger.sh select <project> docs --paths` to get the exact paths to scope the crew to.
   A docs-centralized project should point its `docs` track at the documentation tree with a `data/reviews/<project>/docs.units` override (see `docs/review-ledger.md`), so the slice is doc-shaped rather than source-shaped.

3. **Dispatch one direct-fix ship crew scoped to the doc slice.**
   Scaffold a ship brief (`bin/fm-brief.sh <id> <project>`), then replace `{TASK}` with a docs-reconciliation task:
   - **Cross-Reference Codebase Diffs.** Scan the codebase diffs (commits and merged PRs) since the last docs pass. Identify which codebase features changed and search for their corresponding documentation. If a codebase change has no corresponding doc update, flag it as a missed file.
   - **Reconcile.** For every work-in-progress and implementation doc in the slice, check each claim against the merged PRs, the commit history, and the actual code, and classify it: implemented (the code matches), partial leftover (a described step was never finished), stale (the code has moved past the doc), orphaned (it references things that no longer exist), or intended (it describes direction the code has not reached yet, which is a standing intent to keep as intent, not a false claim to delete).
   - **Hunt for Orphaned Files.** Check the doc slice against the codebase graph (`codebase-memory-mcp`). If a doc references an entity (function, route, module) that no longer exists in the codebase graph, the doc is an orphaned "missed file" and should be deleted or marked obsolete.
   - **Find Missing Related Docs.** If the slice consists mostly of source code directories rather than explicit documentation files, proactively find and review the docs *related* to that source code rather than reporting the slice as "clean".
   - **Fix.** Update, merge, or delete docs so no leftover or stale claim survives, and the surviving docs are clean and organized - the docs are used every day for implementation, so a wrong doc is worse than a missing one.
   - **When code and doc disagree, do not assume the doc is wrong.** A mismatch can be a code regression rather than a stale doc, so surface it as a finding instead of rewriting the doc to match broken code; delete a doc only when the evidence shows a false claim of done or a reference to something gone, never merely because it describes intended-but-unbuilt direction; and never invent documentation for undocumented behavior outside the slice.
   - **Leave firstmate the Asana evidence.** In the PR description, list each doc or feature touched with its implementation status and the evidence (the commits, PRs, or code that prove it), so firstmate can reconcile Asana from fact rather than guesswork.
   - **A clean slice is a valid outcome.** If the docs in the slice are already true and no codebase updates were missed, report it clean and open no PR.
   Then spawn and supervise as any ship task (`AGENTS.md` sections 6 and 7); review the docs diff against the direction before it lands, and merge on the captain's word.

4. **Reconcile Asana - firstmate's leg, every write captain-confirmed.**
   This runs whether the docs pass produced a PR or came back clean; a clean docs pass still yields implementation evidence to check Asana against.
   - **Resolve the Asana project** for this repo by searching Asana by name; if it is ambiguous or unmapped, ask the captain once and record the mapping with `capture-decision` so the next pass does not re-ask.
   - **Compute the change-set** by cross-referencing the crew's implementation evidence against the Asana task states: a task the code proves done but Asana still shows open is a proposed close; a task Asana shows done but the code or docs show unfinished is a proposed reopen or flag; a doc describing work with no Asana task, or an Asana task with no trace in code or docs, is a mismatch to surface.
   - **Relay the proposed change-set to the captain** and apply nothing first - use `lavish-axi` for the structured, multi-item review (`AGENTS.md` section 8).
   - **Apply only confirmed writes** through the Asana connector, annotating each state change with the evidence that justified it (the commit or PR that proves the task done or unfinished) so the change is auditable later; a write the captain did not confirm does not happen, and a destructive Asana change (deleting a task) always escalates rather than being applied on a routine confirmation.
   - If the Asana connector is not available in this session, do the docs reconciliation anyway and report the Asana leg as pending a connector, rather than silently skipping it.

5. **Record the slice on the ledger when the pass ends.**
   Record each doc unit from step 2 at the landed commit (sync the clone first, `AGENTS.md` section 7):
   `bin/fm-review-ledger.sh record <project> docs <unit> --sha <merged-sha> --verdict <full-PR-url>`.
   For a slice the crew reported clean, record each unit at the current clone head with `--verdict clean`.
   The Asana leg is not part of the ledger row; the ledger tracks doc-review coverage, and Asana is reconciled fresh from evidence each pass.
