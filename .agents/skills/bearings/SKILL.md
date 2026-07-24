---
name: bearings
description: Generate a "pick up where I left off" status report from firstmate's live fleet state. Use when the captain invokes /bearings or asks for a bearings report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works". Reads bounded local fleet state cheaply, optionally checks open PRs when requested, composes a scannable dated report to data/status-report-<YYYY-MM-DD>.md, and surfaces a concise version in chat; it is read-mostly and must not tear down, merge, or mutate task state as a side effect of producing the brief.
user-invocable: true
metadata:
  internal: true
---

# bearings

Generate a complete standalone snapshot from the fleet's current state, so the captain can resume in one read after a break, a night, or a context reset.
The deliverable is a dated markdown file plus a concise chat summary that each stand on the current snapshot rather than an earlier report.
This skill is read-mostly.
It reads fleet state and writes exactly one report file.
It never tears down a task, merges a PR, dispatches new work, or mutates any task state as a side effect of producing the brief - those belong to the captain's explicit word and the normal task lifecycle.

## What it does

1. **Gather live fleet state with one deterministic command.**
   Run `bin/fm-bearings-snapshot.sh` and read its compact output.
   It is the single bounded, deterministic source for this report and renders TOON by default.
   Do not hand-probe the snapshot schema and do not make ad-hoc `gh-axi`/`gh` calls to assemble fleet facts; this command already assembles them.
   The command's header and `--help` output own its exact fields, bounds, opt-ins, and output contract.
   When the captain asks to include PRs, use the command's live-PR opt-in; otherwise keep the default local-only read.
   If the command is unavailable, fall back to `bin/fm-fleet-snapshot.sh --json` and `bin/fm-crew-state.sh <id>`; never infer current state from a raw `tail` of `state/<id>.status`, which is append-only wake-event history whose last line goes stale.
   For registered secondmates, use the snapshot's structured-home classification and provenance; a parent event or bounded terminal contradiction is fallback evidence, never authority over readable structured home state.
   Structured captain-held decisions come from `decision-hold-lifecycle` and appear under `decisions_open`; do not scrape reports or visual-review artifacts to supplement them.
   A queued item under `gates` only becomes "next work" when its blocker is gone and its time/date gate has arrived; until then it stays queued with the reason.
   The `(main-inventory)` gate is an action-free integrity warning rather than queued work: render it under Charted Next with the related `omitted` disclosure, never invent an Underway row from backlog-only state, and never move it into Captain's Call.

2. **Compose the detailed report file around the four-section spine, adding the richer detail the chat leaves out.**
   The gather step is deterministic; your judgment is scoped to the last mile only - ranking the command's facts by what matters right now and writing the scannable prose.
   Never read an earlier `data/status-report-*.md` to decide what to omit, include, describe as changed, or call current.
   The report uses the same four complete sections as the chat (see the chat-response contract below), in the same order, each always present, and adds the detail the chat omits:
   - **Title** - `# Bearings - <day> <YYYY-MM-DD>` (use "Morning status" only when the captain specifically asks for a morning brief), followed by two or three sentences framing where things stand.
   - **Captain's Call** - every open decision summarized with its options from the structured decision record, plus each PR ready to merge and each needed credential or login, every PR with the full `https://...` URL, never a bare `#number`.
   - **Recently Landed** - the bounded current recent-completions baseline from structured state across the main fleet and every registered secondmate home, rendered in full on every run.
   - **Underway** - each live direct report making progress, with its current state, and the plans / main pickup pointers worth reopening (`data/<id>/report.md` files, `.lavish/*.html` boards).
   - **Charted Next** - queued or gated work, including any main-inventory integrity warning, with each item's blocker, date, or integrity reason.

3. **Write the dated report file so it persists, then surface the mandatory four-section digest in chat.**
   - Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date.
     This is the required artifact; it lives in gitignored `data/`.
     If today's file already exists, delete it first, then create a new file from scratch.
   - The chat response is the concise four-section digest defined by the contract below: materially shorter than the report file, complete as a current snapshot, internally consistent with the file, and linked to that file for the full picture.
   - For a richer review surface, optionally offer a Lavish board with `lavish-axi` when the report has enough structure to deserve one, but the markdown file is the required artifact and the four-section chat digest is the required minimum.

## Chat-response contract

This skill is the one owner of the `/bearings` chat-response format; the snapshot and classifier own the data that feeds it, and no other file restates this contract.
Every `/bearings` chat response renders EXACTLY these four sections, in THIS order, and nothing else structural (there is no At Anchor section):

1. **Captain's Call** - ONLY items that need the captain's own action now: a decision to make, a PR to approve or merge, a credential or login to provide, or a blocker only the captain can clear.
   Empty-state: "Nothing needs your action right now."
2. **Recently Landed** - the bounded current recent-completions baseline: merged PRs, completed scouts, and finished local-only merges across the main fleet and every registered secondmate home.
   Empty-state: "No recent completions are in the current baseline."
3. **Underway** - live work progressing on its own, one line of current state per direct report.
   Empty-state: "Nothing is underway."
4. **Charted Next** - queued or gated work waiting on the fleet or a date, plus action-free fleet-integrity warnings, never on the captain.
   Empty-state: "Nothing is queued."

Rules that keep the contract unambiguous:

- Every section ALWAYS renders, even when empty, with its short empty-state sentence; never omit a section.
- Every report and chat digest is a complete current snapshot, never a delta against a prior report.
- Recently Landed always renders the bounded current baseline, even when the same completions appeared in an earlier report.
- The four buckets are mutually exclusive, so every item is forced into exactly one: needs-your-action is Captain's Call, done is Recently Landed, self-progressing is Underway, and not-yet-started work or an action-free fleet-integrity warning is Charted Next.
- The strict boundary keeps action-free items OUT of Captain's Call: a working or validating task, a queued item blocked on another task or a date, landed work, a completed scout's report pointer, a declared `paused:` external wait, and a bare recorded PR with no merge-ready signal each belong to one of the other three sections, never Captain's Call.
- A secondmate's own row appears Underway only for `active_child_work`; `externally_held` belongs in Charted Next, and `unknown` belongs there as an unavailable-state gate unless its reason requires the captain's action.
- Do not suppress separately projected decisions, landed records, or gates from a `partial-structured` home merely because that secondmate's own row is `unknown`.
- The chat follows `AGENTS.md` section 9 and carries one scannable line per item, each PR as the full `https://...` URL; detailed decisions, plans, full gate reasons, and evidence live only in the report file, which the chat links to, so the chat stays materially shorter than that file.

## Tone and content rules

- This report is a private, captain-facing internal artifact that lives in gitignored `data/`, so unlike normal captain chat it MAY reference task ids, PR URLs, and repo names - the captain works with these directly and needs them to resume; keep it organized and scannable, not a raw dump.
- Every PR reference is a full `https://...` URL, never a bare `#number`; a shorthand `#number` is fine only as a back-reference after the full URL has already appeared in the same report.
- Never include PHI or secret values; the report is an operational artifact, but it is still subject to the same security and compliance rules that govern everything else in this fleet.

## Supervision discipline

This skill is read-mostly and changes no fleet state.
Do not tear down a task, merge a PR, dispatch queued work, or mutate any `state/` or `data/` file other than the single report file as a side effect of generating the brief.
If the state you read suggests an action - a PR ready to merge, a queued item whose gate has arrived, or a needs-decision finding - name it in its section and leave the action to the normal lifecycle and configured authority rather than taking it from inside this skill.
