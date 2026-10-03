---
name: bearings
description: >-
  Generate a "pick up where I left off" fleet digest from firstmate's live fleet state.
  Use when the captain invokes /bearings or asks for a bearings report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works".
  Plain /bearings is chat-only by default, /bearings file explicitly writes the dated data/status-report-<YYYY-MM-DD>.md artifact, and live PR enrichment remains opt-in and composes with either mode.
user-invocable: true
metadata:
  internal: true
---

# bearings

Generate a complete current snapshot from the fleet's current state, so the captain can resume in one read after a break, a night, or a context reset.
Plain `/bearings` returns only the concise four-section chat digest.
Only `/bearings file` writes the dated markdown report artifact and then returns the concise four-section chat digest linked to that report.
A digest invocation is operationally read-only apart from observational remote-ledger cache refreshes, durable per-target reconcile-notify requests when the captured state needs them, and the dated report in file mode.
During that invocation it never tears down a task, merges a PR, dispatches new work, steers a worker, answers a decision, cleans up work, or mutates backlog or task state.

## Invocation modes

- Plain `/bearings` gathers a fresh bounded snapshot and renders the four-section chat digest without creating, deleting, reading, or replacing `data/status-report-<YYYY-MM-DD>.md`.
- `/bearings file` gathers a fresh bounded snapshot, replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch, and renders the four-section chat digest with a link or path to that report.
- Treat `file` only as an explicit invocation option in the slash command.
- Do not treat natural-language requests such as "write a report", "save this", or "persist it" as file mode unless the invocation explicitly includes the standalone option.
- When the captain asks to include PRs, pass the snapshot command's live-PR opt-in.
- `/bearings include PRs` remains chat-only and makes the live-PR opt-in.
- `/bearings file include PRs` composes the same way.

## What it does

1. **Gather live fleet state with one deterministic command.**
   Run `snapshot=$(bin/fm-bearings-snapshot.sh --json)` at invocation time and read that compact output.
   It is the single bounded, deterministic fleet-state source for Bearings.
   Do not create or consult a second fleet-state reader, parser contract, status-event-tail interpretation, visible-session recap, ad-hoc project probe, or ad-hoc `gh-axi`/`gh` query.
   The command's header and `--help` output own its exact fields, bounds, opt-ins, and output contract.
   Only pass `--include-prs` when the captain asks for live GitHub PR enrichment.
   A parent event or bounded terminal contradiction is fallback evidence, never authority over readable structured home state.
   A decision is simply a task held for the captain (`captain-hold-lifecycle`), whatever its kind.
   The canonical snapshot assigns every captain hold exactly one bucket from structured fields only: `blocked` when any blocker is unresolved, else `dated` while `hold_until` is in the future, else `aged` when an undated hold has reached the configured age threshold, else `live`.
   Never use hold-reason or body prose to classify or place a decision.
   Treat `retained_record_count` as the default historical-preservation signal and keep `retained_records` out of routine prose; use `--all-retained` only when cleanup or recovery actually needs those identities.
   Retained records remain preserved execution evidence, never Underway; any unresolved captain action remains independently represented by the snapshot's structured decision surfaces.
   A `live` hold appears in Captain's Call; `blocked`, `dated`, and `aged` holds appear as disclosed Charted Next gates stating their structured reason.
   Use `--all-decisions` to reveal every captain hold available within the bounded snapshot and remove each revealed gate from Charted Next so the buckets remain exclusive.
   A compact decision row carries its exact `--task <task-id>` retrieval command.
   Use that targeted read whenever the summary does not contain the concrete request, options, credential requirement, remaining issue, or authority and evidence pointers needed to act; never compensate with `--fields bodies` or an unbounded whole-fleet dump.
   Aging is only a presentation safety net, and re-holding with `--until` remains the durable deferral.
   Do not scrape reports, visual-review artifacts, raw status-event tails, or visible conversation history to supplement current state.
   A queued item under `gates` only becomes "next work" when its blocker is gone and its time/date gate has arrived.
   Until then it stays queued with the reason.
   The `(main-inventory)` gate is an action-free integrity warning rather than queued work.
   Render it under Charted Next with the related `omitted` disclosure, never invent an Underway row from backlog-only state, and never move it into Captain's Call.
2. **Compose the four-section chat digest from the fresh snapshot.**
   The gather step is deterministic; your judgment is scoped to ranking the command's facts by what matters right now and writing scannable captain-facing prose.
   The chat response uses the four complete sections in the chat-response contract below, in the same order, each always present.
   Plain mode stops here and writes no report artifact.

3. **In explicit file mode only, compose and replace the detailed report file.**
   The report uses the same four complete sections as the chat, in the same order, and adds the detail the chat omits.
   Never read an earlier `data/status-report-*.md` to decide what to omit, include, describe as changed, or call current.
   Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date.
   If today's file already exists, delete it first, then create a new file from scratch.
   This is the only file-mode write allowed by the skill.
   The detailed report includes:
   - **Title** - `# Bearings - <day> <YYYY-MM-DD>` (use "Morning status" only when the captain specifically asks for a morning brief), followed by two or three sentences framing where things stand.
   - **Captain's Call** - every unsuppressed open decision summarized with its options from the structured decision record, plus each PR ready to merge and each needed credential or login, every PR with the full `https://...` URL, never a bare `#number`.
   - **Recently Landed** - the bounded current recent-completions baseline from structured state, rendered in full on every run.
   - **Underway** - each live direct report making progress, with its current state, and the plans or main pickup pointers worth reopening (`data/<id>/report.md` files).
   - **Charted Next** - queued or gated work, including deferred or aged captain-hold safety gates and any main-inventory integrity warning, with each item's blocker, date, age, or integrity reason.
   After writing the file, return the concise four-section chat digest and include the report path or link without adding a fifth section.

## Chat-response contract

This skill is the one owner of the `/bearings` chat-response format; the snapshot and classifier own the data that feeds it, and no other file restates this contract.
Every `/bearings` chat response renders EXACTLY these four sections, in THIS order, and nothing else structural (there is no At Anchor section):

1. **Captain's Call** - ONLY unsuppressed items that need the captain's own action now: a decision to make, a PR to approve or merge, a credential or login to provide, or a blocker only the captain can clear.
   Deferred or aged holds follow the presentation safety rule above instead.
   Empty-state: "Nothing needs your action right now."
2. **Recently Landed** - the bounded current recent-completions baseline: merged PRs, completed scouts, and finished local-only merges across the main fleet.
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
- The strict boundary keeps action-free items OUT of Captain's Call: a working or validating task, a queued item blocked on another task or a date, landed work, a completed scout's report pointer, a declared `paused:` external wait, and a bare recorded PR with no merge-ready signal each belong to one of the other three sections, never Captain's Call.
- Include the required direct address to the captain inside one item or empty-state sentence.
- Every PR appears as the full `https://...` URL; a shorthand `#number` is fine only as a back-reference after the full URL has already appeared in the same digest.
- The chat follows `AGENTS.md` section 9 and carries one scannable line per item.
- Detailed decisions, plans, full gate reasons, and evidence stay out of chat; file mode puts them in the report.
- In file mode, include the report path or link inside the four-section digest without adding another heading.

## Tone and content rules

- The optional file-mode report is a private, captain-facing internal artifact that lives in gitignored `data/`, so unlike normal captain chat it MAY reference task ids, PR URLs, and repo names.
- The captain works with those directly and needs them to resume; keep the report organized and scannable, not a raw dump.
- Every PR reference is a full `https://...` URL, never a bare `#number`.
- Never include PHI or secret values; the report is an operational artifact, but it is still subject to the same security and compliance rules that govern everything else in this fleet.

## Supervision discipline

During a digest invocation, this skill changes no fleet state beyond observational remote-ledger cache refreshes, durable local per-target reconcile-notify requests, and the explicit report artifact.
Do not tear down a task, merge a PR, dispatch queued work, steer a worker, answer a queued decision, clean up work, or mutate any other `state/` or `data/` file during that invocation.
If the state gathered for the digest suggests an action, name it in its section and leave it to the normal lifecycle and configured authority.
