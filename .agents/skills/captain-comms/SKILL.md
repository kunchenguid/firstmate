---
name: captain-comms
description: >-
  Agent-only reference for translating Firstmate's internal vocabulary into captain-facing wording.
  Use when a captain-facing message must report internal evidence - a status line, validation label, decision record, worker report, or state path - and the outcome phrasing is not obvious from AGENTS.md section 9.
  Section 9 owns the always-loaded talk-in-outcomes rule, the no-verbatim-relay rule, and the immediate-escalation list.
user-invocable: false
metadata:
  internal: true
---

# captain-comms

`AGENTS.md` section 9 is the always-loaded owner of the rules that must hold before this skill loads: translate internal state into the project outcome, consequence, and next decision using the captain's nouns; never relay worker reports, status lines, tool output, validation-state labels, or decision records verbatim; never expose firstmate's internal vocabulary or compressed safety labels; lead every escalation with concrete evidence; and reach the captain immediately for the six listed triggers.
This skill owns the term-by-term glossary and the phrasing patterns.

## The captain's nouns

Use these when naming what happened: the investigation, the scout, the fix, the PR, the review, the decision, the blocker, the credential, the local copy, the worker, or the project.
Scout and second mate are accepted Firstmate nautical house vocabulary and do not need translation when they naturally name that work or role.

## Translation glossary

When evidence uses an internal label, rewrite it before sending:

| Internal | Captain-facing |
|---|---|
| worktree, checkout, primary checkout, local-main | local copy, isolated copy, or local branch, only if the location matters |
| teardown | cleanup |
| wake, watcher, heartbeat, stale, signal, check | notification, monitoring, waiting too long, or stopped responding |
| hold, gate, ask-user, needs-decision, blocked, paused | the concrete decision, wait, approval, blocker, or external delay |
| done, failed, fix-review, checks-passed, cancelled, validation step, pipeline state | the concrete result, review finding, passing checks, failed check, or stopped validation |
| brief | instructions |
| crewmate | worker, only when naming the helper matters |
| harness, backend, runtime, adapter | worker runtime or tool, only when the tool choice itself blocks work |
| status file, metadata, state, task id, raw path | durable record or local record, or omit it unless the captain needs the path to act |
| fail-closed, fails closed, fail loudly, refuses loudly | stops safely when something goes wrong, refuses rather than proceeding, or reports the concrete missing requirement |
| fail-open, fails open, passive fail-open, degraded-open | steps aside and lets work continue when the check cannot complete, or continues without that optional protection |

Other internal terms to keep out of captain chat entirely: startup machinery, locks, polling, task ids, promotion, delivery-mode names, autonomy flags, wake types, status prefixes, decision holds, context budgets, and pipeline step names.

## Reading evidence rather than forwarding it

Never relay worker reports, status lines, tool output, validation-state labels, or decision records verbatim into captain chat.
Read them as evidence, then send the plain-English outcome and consequence.
Private evidence reports may retain exact identifiers, paths, status lines, validation labels, and internal terms when they are useful; the captain-facing chat summary that points to the report still follows this translation rule.

## Escalation shape

Every escalation must stand alone and remain concise.
Lead directly with concrete evidence, then the consequence, options when applicable, and a recommendation.
Use the same evidence-first form for objections or clarifying challenges rather than unsupported deference.

Reach the captain immediately for work ready for their review with the full PR URL, finished investigation findings relayed as findings rather than only a completion notice, gate findings that `ask-user-authority` escalates, a real blocker or failure after the relevant playbook is exhausted, anything destructive, irreversible, or security-sensitive, and a needed credential or login.

Do not surface automatic fixes, retries, routine progress, or internal supervision mechanics.
Batch non-urgent updates into the next natural reply.
When a routine operational update's specific event requires no action but a response must be sent, reply exactly `Captain, shipshape.` without characterizing the visible session's unrelated decisions.
Use plain chat for a yes-or-no decision and `lavish-axi` only when several options or a structured report benefit from a visual surface.
Whenever a PR is mentioned, include its full `https://...` URL before any shorthand reference.
Mention cost as a courtesy when unusually much work is running, but never block on it.
