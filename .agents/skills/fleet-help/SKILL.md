---
name: fleet-help
description: >-
  Explain what the firstmate fleet can do and recommend the next captain action from live read-only sources.
  Use when the captain invokes /fleet-help, asks what firstmate or the fleet can do, asks what is in flight, blocked, awaiting them, or asks what should happen next.
user-invocable: true
metadata:
  internal: true
---

# fleet-help

Guide the captain through firstmate's real capabilities and current fleet state.
This is a navigator, not a workflow runner.
It must preserve firstmate autonomy by guiding the captain in plain language without adding approval gates, personas, BMAD installs, or a second decision ceremony.

## Boundaries

- This skill is read-only over fleet state.
- Do not spawn workers, steer workers, dispatch queued work, merge PRs, update Linear, update the backlog, write reports, arm supervision, or mutate `state/` or `data/` as a side effect of help.
- If the best next step is actionable, say what the captain can ask for and stop.
- If the captain follows up with an implementation, merge, dispatch, project-management, secondmate, X-mode, or self-update request, leave this skill and use the normal owner for that request.
- Do not install BMAD, copy BMAD personas, or present named role menus.
- Apply `AGENTS.md` section 9 for captain-facing language and never relay raw command output as the answer.

## Sources to read

1. Read [`fleet-catalog.json`](fleet-catalog.json) from this skill directory.
   This catalog is the machine-readable inventory for user-invocable internal skills and script-owned lifecycle operations.
   Treat it as the source for capability mode instead of reconstructing a hardcoded capability list from memory.
2. Gather current fleet state with `bin/fm-bearings-snapshot.sh --json`.
   This is the preferred bounded local read because it already projects backlog, task state, secondmates, decision holds, landed work, report pointers, recorded PRs, and queue gates without writing a report.
   Add `--include-prs` only when the captain explicitly asks for live PR enrichment or asks what is awaiting review and local records are insufficient.
3. If `bin/fm-bearings-snapshot.sh` is unavailable, fall back to `bin/fm-fleet-snapshot.sh --json`.
   Do not parse `state/*.status` directly because those files are append-only event history, not current state.
4. If the snapshot reports unavailable or partial sources, disclose the consequence in plain language and avoid recommending actions that depend on the missing source.
5. If the captain asks a general capability question and no current-state answer is needed, the catalog alone is enough.

## Capability mode

Use this mode for questions like "what can the fleet do", "what can I ask firstmate for", or "how do I use the crew".

1. Read the catalog and group entries by the captain's likely intent, such as delivery, investigation, quality, fleet management, tracking, documentation, integration, and built-in slash skills.
2. Mention only capabilities that exist in the catalog or in the live snapshot.
3. For each relevant capability, give a short plain-English description and one sample captain prompt from the catalog.
4. Prefer a compact curated answer over dumping the whole catalog.
5. If the captain's question is broad, include a short "best next prompt" suggestion at the end.
6. Keep the handoff explicit: "If you want that, say ..." rather than starting it.

## Current-state and next-step mode

Use this mode for questions like "what is in flight", "what is blocked", "what is awaiting me", "what should happen next", or "where should I point the fleet".

1. Gather the snapshot before answering unless a fresh snapshot is already visible in the current conversation.
2. Classify the snapshot into captain-relevant buckets:
   - Needs the captain now: open decisions, merge-ready PRs, credential or login blockers, and blockers that only the captain can clear.
   - Underway: live work progressing on its own.
   - Blocked or gated: queued work whose blockers, dates, or integrity warnings are not captain actions yet.
   - Recently finished: landed work and completed scout reports that help choose follow-up work.
3. Recommend exactly one next action when the evidence supports it.
4. Prefer captain-held decisions and review-ready PRs over new work.
5. Prefer real blockers or failed work over routine queued work.
6. If nothing needs the captain, say that clearly and suggest the next sensible fleet request only when it would be useful.
7. Include exact phrasing the captain can use for the recommended follow-up.
8. Never present an action-free queued item as something the captain must decide.
9. Never infer current worker state from the last historical event line.

## Answer shape

For a broad `/fleet-help`, use this concise structure:

1. **What the fleet can do** - two to five grouped bullets from the catalog.
2. **What is live now** - the current state summary from the snapshot, or "I did not need a live snapshot for this question" when capability-only.
3. **Best next ask** - one recommended captain prompt, or "Nothing needs your action right now" when appropriate.

For a narrow question, answer only the requested part and keep the same boundaries.
Always include full PR URLs when mentioning PRs.
When the catalog and live state disagree, trust live state for current work and the catalog for capability names.

## Maintenance contract

The `generated_skills` section of `fleet-catalog.json` must match every internal user-invocable skill under `.agents/skills/`.
The test suite owns that sync check so `/fleet-help` does not advertise missing built-ins or omit installed ones.
The `lifecycle_operations` section is hand-authored because those capabilities are owned by scripts, skills, and fleet contracts rather than slash skills.
