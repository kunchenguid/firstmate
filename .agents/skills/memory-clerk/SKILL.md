---
name: memory-clerk
description: >-
  Produce a bounded private curation proposal from explicitly allowlisted durable Firstmate records.
  Use when the captain invokes /memory-clerk, asks to review our memory, or says "curate what you know."
user-invocable: true
metadata:
  internal: true
---

# memory-clerk

Run an explicit, proposal-only review of durable Firstmate memory without observing transcripts or silently changing any authoritative record.
This workflow composes with `/stow` and the existing knowledge owners: it inventories and proposes, while those owners alone perform inspect-then-update.

## Safety boundary

Use `bin/fm-memory-clerk.sh` as the only input reader and proposal publisher for this workflow.
Its header and `--help` own the exact allowlist, path grammar, source and aggregate input limits, item and output limits, schema, digest validation, filesystem checks, and same-day replacement mechanics.
Do not supplement its inventory from conversation history, Pi session JSONL, transcripts, history files, terminal scrollback, tool arguments or results, browser profiles or state, SSH material, credential stores, environment files, hardware evidence, raw CSI, floor plans, arbitrary project files, or any other private record.
Do not inspect `state/`, `projects/`, or unallowlisted `data/` paths during this workflow.
Do not install a package, call a provider, start background work, schedule another pass, expose a recall tool, copy to a clipboard, write a debug transcript log, open a network endpoint, request a credential, or create a persistent second mate.

The automatic inventory is limited to the current home's captain memory, the primary home's shared captain memory, local learnings, structured backlog and decision records, completed-work and report pointers, and project-documentation pointers already present in those records.
A secondmate inventory never reads its inherited `data/captain-shared.md` because the primary owns that file.
A secondmate may only propose routing a shared preference to `primary data/captain-shared.md` through the main firstmate.
Project-documentation pointers are pointers only; never open the project document or any project file from this workflow.
A report body is eligible only when the current request explicitly names one unique `data/<id>/report.md` path or completed-report identity and that exact path is passed with `--report`.
Never discover report bodies by globbing, directory walking, searching `data/`, or expanding every pointer found in backlog records.

## Inventory

1. Run `bin/fm-memory-clerk.sh inventory`, adding `--report data/<id>/report.md` only for each explicitly targeted report from the current request.
2. Read only the returned JSON object.
3. Preserve every source status exactly.
   An absent file remains absent, an excluded primary-owned file remains unread, and an over-limit file is an explicit coverage exception rather than permission to sample it another way.
4. Treat returned source digests as provenance for this one pass.
   If a source changes before publication, let the write command refuse and rerun the inventory rather than weakening provenance.
5. Treat completed report and project-documentation paths found in automatic records only as pointers.
   Keep exact historical detail in the linked owner and recommend a targeted later read only when it could materially change curation.

## Curation analysis

Compare all included sources as one bounded set and classify each useful proposal as `new`, `duplicate`, `contradiction`, `supersession`, `stale`, or `no-change`.
Prefer a concise rewrite, merge, prune, or authoritative pointer over appending another statement.
Deduplicate both repeated facts and repeated recommendations.
When two sources disagree and their authority or date does not settle the conflict, classify the item as a contradiction with `review-required`; never guess which prose wins.
When a newer authoritative statement clearly replaces an older one, classify it as supersession and propose rewriting or pruning the old statement rather than preserving both.
Mark moving versions, paths, metrics, completed chronology, resolved alternatives, and time-sensitive operational claims as stale unless a current authoritative source proves they remain useful.
Keep exact report detail in the report and propose only the smallest durable pointer needed elsewhere.

Route every proposal to the owner named by `AGENTS.md` section 6 and the decision lifecycle:

- `data/captain.md` for home-domain captain preferences and working style.
- `primary data/captain-shared.md` for preferences shared across secondmate domains, owned and edited only by the primary home.
- `data/learnings.md` for recurring home-local operating facts with no stronger owner.
- `structured backlog` for task-scoped notes or undone work.
- `structured decision lifecycle` only for an already structured decision source, never for a choice inferred from prose.
- `project documentation via normal delivery` for project-intrinsic knowledge, without reading or editing the project here.
- `linked report` when exact evidence should remain only in the report.
- `no canonical change` when the current owners are already concise and consistent.

Canonical memory, structured backlog and decision records, project documentation, and linked reports remain authoritative.
Model-authored prose in the proposal is never a decision, approval, completion fact, authority grant, or source of current worker state.
Do not infer a new decision from memory prose, close an existing decision, report live work, or claim that a recommendation has been applied.

## Proposal publication

Build one JSON object with exactly `items` and `coverage_notes`, following the item fields and enums in `bin/fm-memory-clerk.sh --help` and using the inventory's proposal date, default review date, home scope, source pointers, and source digests verbatim.
Use `review-required` for unresolved contradictions and any recommendation that needs the captain's judgment.
Use `stow-candidate` only for a proposed captain-memory, shared-memory, or learning rewrite or prune that `/stow` can inspect and apply after review.
Use `route-candidate` for backlog, decision-lifecycle, project-documentation, or secondmate-to-primary routing.
Use `no-change` only with a `no-change` classification.

Prioritize contradictions, unsafe staleness, and high-value deduplication when more than 24 useful candidates exist.
Record the omitted count and reason in one bounded coverage note rather than expanding the artifact.
Do not copy report-sized evidence into a rationale or proposal.

Pipe the JSON object to `bin/fm-memory-clerk.sh write` with the same `--report` arguments used for inventory.
Do not write the Markdown artifact directly or bypass a refusal.
The command atomically publishes `data/memory-clerk/proposal-<date>.md` and replaces only that day's prior proposal.
It never edits canonical owners.

## Completion

Read the published proposal and report its private path, item count, contradiction count, excluded or over-limit inputs, and the next named owner action.
Say explicitly that canonical memory and operational records are unchanged.
For accepted memory-file recommendations, load `/stow` so its whole-file budget and inspect-then-update contract remains the sole write owner.
Route accepted backlog, decision, and project-documentation recommendations through their existing lifecycle rather than applying them from this skill.
If the proposal contains no items, report that the allowlisted records were reviewed and no canonical change was proposed, while preserving any coverage exceptions.
