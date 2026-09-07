---
name: debrief
description: >-
  Generate a five-section session debrief in chat, written in ASD-STE100 Simplified Technical English.
  Use when the captain invokes /debrief, or asks what the workers have done, what happened this session, for a recap, a session report, or a summary of what was sent or done.
user-invocable: true
metadata:
  internal: true
---

# debrief

Give the captain the report he asks for by hand almost every session, in one command.
The report goes to chat only.
Do not write a report file: `bearings` already owns the dated `data/status-report-<YYYY-MM-DD>.md` artifact, and the captain did not ask for a file here.

## What it does

1. **Gather durable fleet facts with the existing bounded tools.**
   Run `snapshot=$(bin/fm-bearings-snapshot.sh --json)` for fleet facts, open decisions, landed work, gates, and recorded PRs.
   Its header and `--help` output own the exact field list and every opt-in flag; read them rather than guessing the schema.
   Do not hand-probe its schema, write a second gathering script, or make an ad-hoc `gh-axi`/`gh` call to assemble fleet facts.
   Use `bin/fm-crew-state.sh <id>` when the current state of one specific worker matters.
   Read `data/<id>/report.md` for a completed investigation, and report what it found, not that it finished.
   Treat `state/<id>.status` as append-only wake-event history only; its last line goes stale and is never current state.

2. **Add what this session itself did.**
   The snapshot shows fleet state, not this conversation's activity, so it cannot alone answer "what happened this session".
   Combine the snapshot's facts with what this session actually did: what was spawned, steered, reviewed, decided, or delivered in the visible conversation.
   When the session began mid-way through existing work, or after a reset that lost earlier turns, say plainly which part of the report comes from the durable snapshot and which part comes from this session's own visible history.

3. **Compose the five-section chat report, always all five, always in this order.**
   1. **What the workers did this session** - concrete actions this session drove or observed, not a restated task list.
   2. **What was fixed, and what was found** - two separate lists.
      A fault that was found and not fixed belongs only in "found", never in "fixed".
   3. **The effect on the project** - what is better, worse, or at risk now, as a consequence, not a second activity list.
   4. **Open action items** - two separate lists: what firstmate will do next, and what only the captain can do.
   5. **Decisions required** - one entry per decision, each stating the choice, the options, what each option costs, and firstmate's recommendation, with enough context that the captain can answer without opening anything else.
   Render every section even when it is empty, with a short plain sentence saying so.
   Do not report an unchanged fleet as progress: when nothing moved since the last debrief, say that directly instead of padding a section with old facts.

## Language rule

Write the entire report in ASD-STE100 Simplified Technical English.
This replaces the light nautical wording `AGENTS.md` otherwise allows; the mandatory direct address to the captain still applies.

- One idea in one sentence.
- Keep sentences short: about 20 words for an instruction, about 25 for a description.
- Use the active voice and name who does the thing.
- Use the simple present or the simple past tense; avoid a perfect tense where a simple tense works.
- Give one word one meaning; do not use the same word as both a noun and a verb.
- Use no idioms, no metaphors, and no other figures of speech.
- Do not drop articles, auxiliaries, or relative pronouns to save words.
- Write numbers as numerals.
- Use a table instead of a paragraph when the content is a list of facts.

## Rules this skill must never break

- This skill is read-mostly.
  It must never tear down a task, merge a request, dispatch new work, or otherwise change any task state as a side effect of producing the report.
- Report the finding, not the activity.
  "The investigation finished" is not a report; what it found is.
- `AGENTS.md` section 9 owns the captain-facing translation contract that rewrites internal terms before they reach the captain; follow it, and do not restate it here.
- Every request appears as its full `https://...` address, never as a bare number.
