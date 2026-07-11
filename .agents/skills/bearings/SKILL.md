---
name: bearings
description: Generate a "pick up where I left off" status report from firstmate's live fleet state. Use when the captain invokes /bearings or asks for a bearings report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works". Reads bounded local fleet state cheaply, optionally checks open PRs when requested, composes a scannable dated report to data/status-report-<YYYY-MM-DD>.md, and surfaces a concise version in chat; it is read-mostly and must not tear down, merge, or mutate task state as a side effect of producing the brief.
user-invocable: true
metadata:
  internal: true
---

# bearings

Generate a "pick up where I left off" report from the fleet's live state, so the captain can resume in one read after a break, a night, or a context reset.
The deliverable is a dated markdown file plus a concise chat summary; this is the reusable version of the worked example at `data/status-report-2026-07-06.md` when that file is present in this home.
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
   A queued item under `gates` only becomes "next work" when its blocker is gone and its time/date gate has arrived; until then it stays queued with the reason.

2. **Compose the report with these sections, matching the worked example's structure, tone, and level of detail.**
   The gather step is deterministic; your judgment is scoped to the last mile only - ranking the command's facts by what matters right now and writing the scannable prose.
   The exemplar is `data/status-report-2026-07-06.md` in this home's `data/` when present; match its scannability, not a raw state dump.
   - **Title** - `# Bearings - <day> <YYYY-MM-DD>` (the exemplar used "Morning status" for a morning brief; use that phrasing when the captain specifically asks for a morning brief).
   - **TL;DR** - two or three sentences framing where things stand.
   - **Check first** - anything likely waiting on the captain: a PR to merge, a needed credential or login, or anything blocking pickup, each PR with the full `https://...` URL, never a bare `#number`.
   - **Landed** since the captain last worked - merged PRs, completed scouts, and finished local-only work, drawn from the Done section and recent merges.
   - **In flight** now - each live direct report with its current state in one line; if nothing is in flight, say so plainly rather than omitting the section.
   - **Plans / main pickup points** - pointers to the relevant `data/<id>/report.md` files and any Lavish boards (`.lavish/*.html`) the captain should reopen.
   - **Decisions pending** from the captain - relayed verbatim from needs-decision findings, with options where the crewmate offered them.
   - **Date-gated / queued** next work - queued items whose blocker is gone and whose gate has arrived, plus anything still blocked with the reason.

3. **Write the report to a dated file so it persists, and surface a concise version in chat.**
   - Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date.
     This is the required artifact; it lives in gitignored `data/` alongside the worked example.
     If today's file already exists, delete it first, then create a new file from scratch.
   - Surface a concise version to the captain in chat - the TL;DR plus the "Check first" list - and point to the file for the full picture.
   - For a richer review surface, optionally offer a Lavish board with `lavish-axi` when the report has enough structure to deserve one, but the markdown file is the required artifact and the chat summary is the required minimum.

## Tone and content rules

- This report is a private, captain-facing internal artifact that lives in gitignored `data/`, so unlike normal captain chat it MAY reference task ids, PR URLs, and repo names - the captain works with these directly and needs them to resume; keep it organized and scannable, not a raw dump.
- Every PR reference is a full `https://...` URL, never a bare `#number`; a shorthand `#number` is fine only as a back-reference after the full URL has already appeared in the same report.
- Never include PHI or secret values; the report is an operational artifact, but it is still subject to the same security and compliance rules that govern everything else in this fleet.

## Supervision discipline

This skill is read-mostly and changes no fleet state.
Do not tear down a task, merge a PR, dispatch queued work, or mutate any `state/` or `data/` file other than the single report file as a side effect of generating the brief.
If the state you read suggests an action - a PR ready to merge, a queued item whose gate has arrived, a needs-decision finding - name it in the report under "Check first" or "Date-gated / queued" and let the captain decide, rather than taking the action from inside this skill.
