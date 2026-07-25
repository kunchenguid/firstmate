---
name: captain-communication
description: >-
  Agent-only procedure for captain-facing escalations and outcome reports.
  Load before sending a decision request, investigation result, failure, credential request, review-ready report, or other non-routine outcome to the captain, and whenever translating internal evidence for captain chat.
user-invocable: false
metadata:
  internal: true
---

# captain-communication

Use this skill after the always-loaded address, plain-language, and immediate-escalation boundaries in `AGENTS.md` section 9 decide that a captain-facing message is required.
It owns the translation vocabulary, evidence-first shape, and routine-update suppression details.

## Translate evidence into outcomes

Describe the investigation, scout, fix, PR, review, decision, blocker, credential, local copy, worker, or project rather than the orchestration mechanism.
`Scout` and `second mate` are accepted Firstmate vocabulary when they naturally identify that work or role.
Never paste a worker report, status line, tool output, validation label, or decision record into captain chat.
Read exact internal evidence privately, then report its project consequence in plain English.
Private reports may retain precise identifiers, paths, event labels, and runtime terms when useful, but the captain-facing summary that links them still follows this rule.

Translate internal vocabulary as follows when it would otherwise leak into chat:

- Worktree, checkout, primary checkout, or local-main becomes local copy, isolated copy, or local branch only when location matters.
- Teardown becomes cleanup.
- Wake, watcher, heartbeat, stale, signal, or check becomes notification, monitoring, waiting too long, or stopped responding.
- Hold, gate, ask-user, needs-decision, blocked, or paused becomes the concrete decision, wait, approval, blocker, or external delay.
- Done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state becomes the concrete result, review finding, passing checks, failed check, or stopped validation.
- Brief becomes instructions.
- Crewmate becomes worker only when the helper matters.
- Harness, backend, runtime, or adapter becomes worker runtime or tool only when that choice blocks work.
- Status file, metadata, state, task id, or raw state path becomes durable record, local record, or nothing unless the captain needs the path to act.
- Fail-closed, fails closed, fail loudly, or close variants become stops safely when something goes wrong, refuses rather than proceeding, or the concrete missing requirement.
- Fail-open, fails open, passive fail-open, or degraded-open becomes steps aside when the optional check cannot complete, or continues without that optional protection.

## Shape decisions and escalations

Make every escalation self-contained and concise.
Lead with concrete evidence, state the consequence, give bounded options when useful, and recommend one.
Use the same evidence-first shape for objections and clarifying challenges rather than unsupported deference.
Use plain chat for a focused yes-or-no decision and `lavish-axi` only when several options or a structured report materially benefits from a visual surface.
Whenever a PR is mentioned, put its full `https://...` URL before any shorthand.
Mention unusually high work cost as a courtesy without making it a blocker.

## Suppress non-events

Do not surface automatic fixes, routine retries, routine progress, elapsed waiting time, or internal supervision mechanics.
Batch non-urgent updates into the next natural reply.
When one routine operational event requires no action but a response is mandatory, reply exactly `Captain, shipshape.` without implying that unrelated visible-session decisions are resolved.
