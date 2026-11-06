# bearings: gather, notify, compose, and file-mode report

For a contribution wake or linked-issue filing, go directly to Contribution follow-up; the digest procedure below applies to Bearings invocations.

1. **Gather live fleet state with one deterministic command.**
   Run `snapshot=$(bin/fm-bearings-snapshot.sh --json)` at invocation time and read that compact output.
   It is the single bounded, deterministic fleet-state source for Bearings.
   Do not create or consult a second fleet-state reader, parser contract, status-event-tail interpretation, visible-session recap, ad-hoc project probe, or ad-hoc `gh-axi`/`gh` query.
   The command's header and `--help` output own its exact fields, bounds, opt-ins, and output contract.
   The default performs bounded concurrent remote-ledger reads for registered remote homes under one shared snapshot budget and may refresh the parent-side cache.
   Only pass `--include-prs` when the captain asks for repository-wide live GitHub PR enrichment.
   Registered owned contributions use the cached `contributions` projection independently of that opt-in; no invocation-time forge discovery is needed to read it.
   For registered secondmates, use the snapshot's structured-home classification and provenance.
   A parent event or bounded terminal contradiction is fallback evidence, never authority over readable structured home state.
   A decision is simply a task held for the captain (`captain-hold-lifecycle`), whatever its kind.
   The canonical snapshot assigns every captain hold exactly one bucket from structured fields only: `blocked` when any blocker is unresolved, else `dated` while `hold_until` is in the future, else `aged` when an undated hold has reached the configured age threshold, else `live`.
   Never use hold-reason or body prose to classify or place a decision.
   A `live` hold appears in Captain's Call; `blocked`, `dated`, and `aged` holds appear as disclosed Charted Next gates stating their structured reason.
   Use `--all-decisions` to reveal every captain hold available within the bounded snapshot and remove each revealed gate from Charted Next so the buckets remain exclusive.
   Aging is only a presentation safety net, and re-holding with `--until` remains the durable deferral.
   Do not scrape reports, visual-review artifacts, raw status-event tails, or visible conversation history to supplement current state.
   A queued item under `gates` only becomes "next work" when its blocker is gone and its time/date gate has arrived.
   Until then it stays queued with the reason.
   The `(main-inventory)` gate is an action-free integrity warning rather than queued work.
   Render it under Charted Next with the related `omitted` disclosure, never invent an Underway row from backlog-only state, and never move it into Captain's Call.
   The same holds for a secondmate home whose current state is unavailable, and for a readable home whose `invalidity` reports a backlog-vs-metadata mismatch: the mismatch is a repair notice about that home's own books, not a reason to drop its separately projected decisions, queued, landed, or live work.
   The `(return-catchup)` gate is the same shape: an action-free notice that an away-return catch-up is still open, naming the blockers left to clear or the reason the catch-up was retained.
   Render it under Charted Next like any other warning row: reporting is not ordinary work, while acting on the fleet still waits for `bin/fm-afk-return.sh check` (`/afk`).

2. **Record a later reconcile notification for any home whose own books disagree.**
   When the snapshot reports a secondmate home whose `invalidity` is `orphan_in_flight`, `unowned_current`, or `terminal_in_flight`, that home's backlog and its own task metadata disagree and only that home may fix it.
   Run `printf '%s\n' "$snapshot" | bin/fm-secondmate-reconcile.sh request --snapshot -` immediately after gathering the snapshot.
   This atomically records one local one-shot request per mismatched target and returns without sending, taking a mate lifecycle lock, or waiting behind a local or remote delivery queue.
   The supervision loop later claims the requests and runs the cooldown-limited fire-and-forget deliveries; the script header owns per-target coalescing, request durability, retries, cooldown, identity checks, and retirement.
   Continue composing the digest from the captured snapshot as soon as the local requests are recorded.
   If local request publication fails, continue composing, report that durability blocker, and never fall back to an inline send.
   A home is still asked at most once per four-hour window, while a skipped or failed later delivery leaves the request durable for another supervision pass.
   Never edit another home's backlog or metadata from here, and never expect or wait on a reply.

3. **Compose the four-section chat digest from the fresh snapshot.**
   The gather step is deterministic; your judgment is scoped to ranking the command's facts by what matters right now and writing scannable captain-facing prose.
   The chat response uses the four complete sections in the chat-response contract below, in the same order, each always present.
   Plain mode stops here and writes no report artifact.

4. **In explicit file mode only, compose and replace the detailed report file.**
   The report uses the same four complete sections as the chat, in the same order, and adds the detail the chat omits.
   Never read an earlier `data/status-report-*.md` to decide what to omit, include, describe as changed, or call current.
   Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date.
   If today's file already exists, delete it first, then create a new file from scratch.
   This is the only file-mode write allowed by the skill.
   The detailed report includes:
   - **Title** - `# Bearings - <day> <YYYY-MM-DD>` (use "Morning status" only when the captain specifically asks for a morning brief), followed by two or three sentences framing where things stand.
   - **Captain's Call** - every unsuppressed open decision summarized with its options from the structured decision record, plus each PR ready to merge and each needed credential or login, every PR with the full `https://...` URL, never a bare `#number`.
   - **Recently Landed** - the bounded current recent-completions baseline from structured state across the main fleet and every registered secondmate home, rendered in full on every run.
   - **Underway** - each live direct report making progress, with its current state, and the plans or main pickup pointers worth reopening (`data/<id>/report.md` files, `.lavish/*.html` boards).
   - **Charted Next** - queued or gated work, including deferred or aged captain-hold safety gates and any main-inventory integrity warning, with each item's blocker, date, age, or integrity reason.
   After writing the file, return the concise four-section chat digest and include the report path or link without adding a fifth section.
   For a richer review surface, offer `/bearings lavish` when the report has enough structure to deserve one, but only after the required digest is ready.
