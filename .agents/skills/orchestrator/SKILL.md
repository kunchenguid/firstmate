---
name: orchestrator
description: >-
  Open an orchestrator session: one long-running worker the captain talks to directly, which drives an authorized spec, ticket set, or issue set to completion through its own implementation workers.
  Use when the captain invokes /orchestrator, or asks to run or take over a programme whose implementation is already authorized.
user-invocable: true
metadata:
  internal: true
---

# orchestrator

An **orchestrator session** is one long-running worker the captain talks to directly.
Firstmate opens it, hands it a body of authorized work, and leaves the conversation.

Its input is a spec, a ticket set, or GitHub issues; the backlog stays firstmate's own queue.
It dispatches and supervises its own workers, and holds the one thing none of them can hold: the view across every ticket at once.

The session's own contract is [`CONTRACT.md`](CONTRACT.md), reached by the brief in step 5.
Firstmate opens the session and never runs it, so that file stays out of this one.

## 1. Take the intake inputs

Ask one concise question for whichever is missing, and open nothing until it is answered:

1. **The programme id** - one short slug, used for the home, the task, and the decision directory.
2. **The work** - the spec path, ticket set, or issue query, plus the captain's sentence that authorized implementing it.
3. **The projects** it lands in.

A spec, report, or recommendation is evidence that work is worth doing; the captain's word is what makes it startable.

**Done when:** all three are written in the captain's terms, and the authorization is a captain sentence you can quote.

## 2. Resolve the runtime

**Default: the claude runtime, model `claude-opus-5`, effort `xhigh`.**

An explicit per-task captain choice replaces it; a dispatch profile leaves it alone.
`data/captain-shared.md` still binds, so a model named by a programme record is a fallback order, not a pin.

**Done when:** the runtime, model, and effort are three concrete values ready for spawn validation.

## 3. Give it an isolated, unregistered home

The session gets its own `FM_HOME` - own `state/`, `data/`, `projects/`, own session lock - so it runs a live supervision cycle over its own workers without contending with firstmate's.

Registration in `data/secondmates.md` is what turns on liveness sweeps, auto-relaunch, the marked-request channel, and escalation relay.
A programme ends, so it takes the isolation and leaves the registry line out.

**Done when:** the home resolves to its own state directory, and `data/secondmates.md` is byte-identical to before.

## 4. Write the initialization packet

A fresh home carries no `data/learnings.md` - only `captain-shared.md` propagates - so the packet is where this session learns what the tooling does wrong today.

Write it under the programme's decision directory: each current defect of the spawn, base, teardown, and supervision tooling, with its workaround.

The packet is **tool state at open time**, not doctrine.
A fixed tool shortens the packet and leaves this skill untouched.

**Done when:** the file exists, every defect in it names a workaround, and it is written before step 6 spawns anything.

## 5. Scaffold the brief

Scaffold with `bin/fm-brief.sh <programme-id> <project> --scout`: the session ships no code itself, and its workers ship theirs under the project's ordinary delivery path.

Fill `{TASK}` with the work from step 1 and these three, every path absolute:

> Read and follow `<firstmate-home>/.agents/skills/orchestrator/CONTRACT.md` and `<firstmate-home>/.agents/skills/program-orchestration/SKILL.md`. They are your contract for this whole programme.
> Your decision records go in `<main-home>/data/<programme-id>/`, one file per decision.
> Your initialization packet is at `<absolute path>`.

The session reads its contract from the file, so this brief carries the pointer and none of the content.

**Done when:** no `{TASK}` or `{SCOPE}` placeholder remains, and all four paths above are absolute.

## 6. Open it, hand it over, step out

Spawn, confirm it is processing the brief, handle any trust dialog through `harness-adapters`, then tell the captain in one message where to talk to it.

That message is firstmate's last word on the subject until the session reports back.
Monitoring from here is lifecycle only: **alive, waiting, finished, or failed**.
The session's workers belong to the session, and its child tree is reconciled, recovered, and cleaned up from inside its own home.

A `needs-decision:` or `blocked:` escalation and the terminal report reach firstmate normally.

**Done when:** the session is processing its brief, and the captain has one message naming where to talk to it.

## 7. Take the return

On `done:`, read `data/<programme-id>/report.md`, relay the outcome and next actions to the captain, then follow the ordinary scout outcome path: the shared completion gate under `decision-hold-lifecycle`, then cleanup.

The decision records under `data/<programme-id>/` outlive the session; keep them.

**Done when:** the captain has the outcome and next actions, the completion gate has passed, and the decision records survive cleanup.
