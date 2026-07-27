---
name: status
description: Give a quick fresh read-only fleet update only when the captain explicitly invokes /status, without treating ordinary status wording, /bearings, morning briefs, full catch-up reports, or /ahoy recaps as triggers.
user-invocable: true
metadata:
  internal: true
---

# status

Give the captain a compact current update without producing the full Bearings report artifact.
Use this skill only for an explicit `/status` invocation.
Do not use it for ordinary uses of the word status, requests for `/bearings`, morning briefs, full catch-up reports, "where did I leave off" requests, "what's in the works" requests, or `/ahoy` session recaps.

## Gather

Run `bin/fm-bearings-snapshot.sh --json` at invocation time and use that fresh structured snapshot as the only fleet-state source.
The command's header and `--help` output own its invocation, fields, bounds, secondmate provenance, structured captain-held decisions, and output contract.
Do not create or consult a second fleet-state reader, parser contract, status-event-tail interpretation, visible-session recap, or ad-hoc project probe.
Do not infer current work from raw status-event tails or from the visible conversation history.
Keep the default local-only snapshot unless the captain explicitly asks for live PR discovery.
Registered secondmates and structured captain-held decisions use the authoritative provenance already defined by Bearings; point to Bearings as that owner rather than restating its procedure.

## Read-only boundary

Create no report file, data file, backlog update, state update, or other persisted artifact.
Do not dispatch work, steer a worker, merge a PR, clean up work, answer a queued decision, or change fleet state as a side effect of `/status`.
If the snapshot reveals an action that should happen, name the action in the chat update and leave the action to the normal lifecycle.

## Chat format

Render exactly these four short headings in this order, with no title, preamble, report link, table, or persisted artifact.
Include the required direct address to the captain inside one item or empty-state sentence, usually the first sentence under **Now**.
Keep the whole update compact and follow `AGENTS.md` section 9's captain-facing translation contract.
Do not expose internal task identifiers, raw labels, metadata paths, local-copy mechanics, worker-runtime terms, monitoring terms, raw tool output, or append-only status-event text.
Include a full `https://...` URL whenever a PR must be mentioned.

**Now**

List every live direct report that is currently progressing or waiting externally, one captain-facing outcome line each.
Do not hide active work behind a count.
If empty, write one sentence: "Captain, nothing is progressing or waiting externally right now."

**Needs you**

List decisions, review or merge approvals, credentials, and blockers that require the captain now.
If empty, write one sentence: "Nothing needs your action right now."

**Just finished**

List at most the two most recent completed outcomes from the bounded structured baseline.
If empty, write one sentence: "No recent completions are in the current baseline."

**Next**

List at most the three highest-priority queued or gated items, including the concrete blocker or date when present.
If empty, write one sentence: "Nothing is queued or gated."
