---
name: next
description: >-
  Choose the single highest-value use of the captain's attention, prepare it as far as Firstmate safely can, and hand off only the smallest action that still requires the captain.
  Use when the captain invokes /next, /next --why, /next --debug, or asks for the one most useful thing to do next.
user-invocable: true
metadata:
  internal: true
---

# next

`/next` is an attention-allocation interface, not a task status or workflow interface.
Its job is CHOOSE, PREPARE, then HAND OFF.
Optimize normal output for starting within five seconds.

## Parse the invocation

Accept no argument, `--why`, or `--debug`.
Reject every other argument concisely instead of guessing.
Neither diagnostic mode changes fleet or task state.

For `--debug`, run `bin/fm-next.sh --debug --json` once and return its structured output without re-ranking or translating it.
The command's diagnostics contain the deterministic candidate order and lifecycle evidence.

For normal mode, run `bin/fm-next.sh --json` once.
For `--why`, run `bin/fm-next.sh --why --json` once.
If collection fails, report the concrete failure instead of selecting from conversation memory or the latest visible event.
If `selection` is null, return the supplied `card` exactly.

## CHOOSE

`bin/fm-next.sh` is the sole selection owner.
Its choice covers all fleet tasks, dependencies, blockers, opportunities, open loops, autonomous-work exclusions, and closure fallback represented by the durable fleet sources.
Never re-rank, substitute a remembered task, or choose from its diagnostic alternatives.
Treat `selection.canonicalId`, `selection.kind`, and the command invocation as one immutable selection token for this preparation pass.

## PREPARE

Read `selection.preparation` before writing the answer.
It composes the selected task's durable intent, phase-specific plan, lifecycle evidence, artifacts, repository location and state, existing result, closure preflight, and explicit missing-evidence list.
Use those facts and read-only tools to do every bounded step that can reasonably be done without the captain.

Preparation may include:

- Reading a report, document, diff, implementation, test, or other existing result instead of asking the captain to open it.
- Inspecting the selected repository copy and the precise code or documentation relevant to the remaining uncertainty.
- Running an already-authorized focused check that does not edit project or fleet records.
- Opening or launching an existing review surface when that is safe, bounded, and already implied by the selected work.
- Reducing a decision to the smallest concrete choice and giving a recommendation supported by the gathered evidence.
- Preflighting closure retention and cleanup so only explicit closure authorization remains.

Do not mutate task or lifecycle state, edit code, merge, close, accept, deliver, start speculative work, disclose a secret, or perform a destructive, irreversible, or security-sensitive action merely because `/next` was invoked.
Do not broaden preparation into a general audit.
Stop when the remaining step genuinely requires captain judgment, presence, credentials, physical observation, or explicit authority.

Do not tell the captain to open a recorded result, inspect a candidate artifact, reconstruct intent, compare raw requirements, or determine whether work satisfies the task when the result and evidence are available for Firstmate to inspect.
Do not repeat the original specification when it can be translated into one concrete check.
When evidence is genuinely unavailable, ask only for the exact missing location, credential, observation, or choice.

If preparation proves that the selected captain action is no longer necessary, rerun the same deterministic selector once against fresh state.
Prepare the fresh selection if it changed.
Never run a third selection, loop, or hand off the obsolete action.
If the fresh selector still returns the same provably obsolete action, report that no reliable next action is available until the stale record is reconciled rather than inventing a replacement.

## HAND OFF

Normal output contains only these elements, omitting any empty one:

```text
<specific action title>
<ref> · <meaningful name>

<at most two short sentences of current context, including what preparation established>

<exact command, location, choice, or physical check>

<one simple response instruction or observable done condition>
```

Use the command's `presentation` and `card` only as deterministic seeds.
Replace vague seed language with what preparation actually established, while staying within the supplied intent and evidence.
Do not add headings merely to label the five elements.

A decision handoff gives Firstmate's recommendation and asks for the smallest concrete choice.
A visual handoff leaves the review surface running or names one exact access point and physical check.
A command handoff gives the exact command and working location.
A code or documentation handoff names only the precise uncertainty that remains after inspection.
A credential handoff names where to authenticate, never asks for the secret in chat, and asks for `ready` or the non-secret error.
A delivery handoff identifies the exact accepted result and asks only for the required approval.
A monitoring handoff names the exact observation, location, threshold, and window.
A closure handoff states that retention and cleanup were preflighted and asks only for explicit closure authorization.

Normal output never includes selection justification, rank or candidate counts, alternative tasks, lifecycle transition names, state-machine consequences, possible-outcome menus, raw requirements, raw revision hashes, delivery-mode labels, worker mechanics, `/task` detours, or internal diagnostics.

For `--why`, append one short `Why this` paragraph using only the command's `explanation.summary`.
You may include its supplied bounded alternatives after that paragraph, in order, without scores or new analysis.
Do not let the explanation displace or precede the prepared action.

Use `/tasks` for breadth, `/task` for depth, `/next` for prepared focus, `/close` for guarded archival, and `/history` for recall.
A `/next` invocation supplies no acceptance, delivery, closure, or follow-up authority by itself.
