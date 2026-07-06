---
name: morning-brief
description: Generate a "pick up where I left off" morning status report from firstmate's live fleet state. Use when the captain asks for a morning brief, status report, catch-up, "where did I leave off", or "what's in the works". Reads the live backlog, each direct report's current state, open PRs via gh-axi, scout reports, and pending decisions, then writes a dated report to data/ and surfaces a concise summary in chat. Read-mostly - it never tears down, merges, or mutates task state as a side effect.
user-invocable: true
metadata:
  internal: true
---

# morning-brief

A reusable "pick up where I left off" report, composed fresh from firstmate's live fleet state each time the captain asks for it.
It is the standing version of the worked example at `data/status-report-2026-07-06.md` in the primary home: if that file exists, read it first, because it is the calibration target for the exact structure, tone, and level of detail the captain wants.
The brief is a private, captain-facing internal artifact (it lives in gitignored `data/`), so unlike normal captain chat it may reference task ids, PR URLs, and repo names directly - the captain works with these to resume.

## What it does

1. **Read live fleet state, cheaply and in this order.**
   Do not re-run `bin/fm-session-start.sh` or bulk-read its inputs; the brief composes from the same sources but reads only what it needs, mid-session.
   - `data/backlog.md` - the In flight, Queued, and Done sections are the backbone of the report.
   - Each `state/<id>.meta` for the current direct-report set, then each task's live state via `bin/fm-crew-state.sh <id>`.
     Never `tail` a `state/<id>.status` log to infer current state: that log is an append-only wake-event history, and its last line goes stale the moment a resolved gate lets a run resume (AGENTS.md section 8).
     `fm-crew-state.sh` reconciles the authoritative run-step over the possibly-stale log line, which is why it is the read used here.
   - Open PRs awaiting the captain's merge, via `gh-axi`, for every repo touched by an in-flight or recently landed task.
     Run `gh-axi pr list --state open` per repo (and `gh-axi pr list --state merged --limit <n>` for recently landed ones); the captain needs the full `https://github.com/<owner>/<repo>/pull/<n>` URL for each, never a bare `#number`.
   - Recent scout and report deliverables under `data/<id>/report.md`, plus any planning docs and Lavish boards (`.lavish/*.html`) the captain has open as pickup points.
   - Pending human decisions (needs-decision findings and open ask-user gates), needed credentials or logins, and date-gated queued items.
     Dispatch nothing: a date-gated item stays queued until its gate has arrived, and even then the brief only surfaces it for the captain's awareness.

2. **Compose the report with these sections, matching the exemplar.**
   - **TL;DR** - two or three sentences framing where the captain left off and what moved since.
   - **Check first** - anything waiting on the captain's merge or decision, each with the full `https://...` PR URL and a one-line "why it needs you".
   - **Landed** since the captain last worked - from the backlog Done section and recently merged PRs, one bullet per landed change with its PR URL or local-merge note.
   - **In flight** now - each live direct report and what it is doing, from `fm-crew-state.sh`, one bullet per task.
   - **Plans / main pickup points** - pointers to the relevant `data/<id>/report.md` files and any Lavish boards, with a one-line context each so the captain knows which to reopen.
   - **Decisions pending** from the captain - verbatim option summaries for each open needs-decision, kept tight.
   - **Date-gated / queued** next work - queued items, noting any date gate and any credential or login the brief itself cannot satisfy.

   Add a deeper sub-section only when a workstream genuinely deserves its own snapshot (the exemplar carries a "Bugbot review" and an "NW Urology migration snapshot"); otherwise keep to the seven sections above so the report stays scannable.

3. **Write the report to a dated file AND surface a concise version in chat.**
   Persist the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date, so it survives a session reset and stays comparable day to day.
   Then surface a concise version to the captain in chat: the TL;DR plus the Check first items with their full PR URLs, and a pointer to the persisted file for the rest.
   For a richer review surface, optionally offer a Lavish board via `lavish-axi` (a plan or table playbook fits a multi-workstream brief); the markdown file is the required artifact and the Lavish board is optional.

4. **Respect firstmate's supervision discipline.**
   This skill is read-mostly: it reads state and writes exactly one report file under `data/`.
   It must not tear down a task (`fm-teardown`), merge a PR (`fm-pr-merge` or `fm-merge-local`), open or steer work (`fm-spawn` or `fm-send`), or mutate any task state as a side effect of generating the brief.
   If something the brief surfaces needs an action, name it in the report and let the captain say the word - do not take the action from inside the brief.

## Tone and content rules

- The report lives in gitignored `data/`, so it may name task ids, PR URLs, and repo names directly; the captain works with these to resume.
  Keep it organized and scannable, not a raw dump - the exemplar is the calibration target.
- Every PR reference is a full `https://...` URL, never a bare `#number`.
  A shorthand `#number` is fine only as a back-reference after the full URL has already appeared in the same report.
- Never include PHI or secret values (API keys, tokens, passwords, connection strings).
  Reference a needed credential only by the name of the login or grant the captain must perform, e.g. "needs AWS SSO (ih-prod)".
- One full sentence per line in the persisted markdown, per repo style; plain dash, never an em dash.
