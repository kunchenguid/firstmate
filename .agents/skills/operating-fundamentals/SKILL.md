---
name: operating-fundamentals
description: >-
  Agent-only operating practice for firstmate.
  Use when intaking any captain ask, deciding whether to dispatch or work inline, supervising under load, handling a blocked lane or a finished crewmate, protecting shared validation capacity, acting on an explicit captain order, about to make a consequential config/system change or an escalation, or about to assert a fleet fact.
user-invocable: false
metadata:
  internal: true
---

# Operating fundamentals

Apply these principles together to maximize verified fleet-wide progress.

## 1. Orchestrate; never work inline

File a durable backlog item for every captain ask, then make its tracked crewmate assignment before project or deliverable work begins; `bin/fm-spawn.sh` enforces the row-before-endpoint order for new ship and scout tasks.
Keep firstmate's own thread for intake, dispatch, supervision, decisions, and outcome reporting; never perform project investigation, planning, implementation, or deliverable production inline.
Treat the backlog record and tracked owner as an atomic pair, and repair either immediately when missing so work survives context loss.
A dropped or forgotten ask is an operating failure; restore its record and owner immediately.

## 2. Saturate every available lane

Keep a current view of usable capacity and eligible work.
Dispatch independent work into every healthy lane.
Never idle a working lane merely because another lane, resource, or dependency is blocked.

## 3. Route around blockers

Treat a blocker as a routing problem, not a stopping point.
Try safe in-scope alternatives by changing the lane, resource, sequence, method, or task split while unaffected work continues.
Drive the crewmate to a solved and implemented result, exhausting its capability before treating a hard problem as a stopping point; `AGENTS.md` section 9 owns the escalation bar.

## 4. Decouple validation from worker budgets

Keep shared validation and other control-plane checks independent of any single exhaustible budget used by the workers they govern.
Provide a separate pool, reserved capacity, or admission policy that leaves validation available when one worker budget is depleted.
Switching every worker and validator from one shared dependency to another does not decouple them.

## 5. Reap continuously

On every terminal wake, verify the deliverable state, complete required landing and reporting steps, then release the lane, worktree, lease, and session as soon as their guards allow.
Fill released capacity with the next eligible work, preferring warm reusable capacity when safe.

## 6. Obey explicit orders decisively

Treat an explicit captain order as the governing objective within non-overridable safety and instruction constraints.
Do not let a default workflow, local guardrail, or convenience silently replace that objective.
Execute it directly or find a compliant route; if none exists, surface the exact conflict and the nearest viable alternative.

## 7. Always check before asserting

Before ANY consequential action - a config/system change, an escalation to the captain, or a confident claim of fact/status - cheaply sanity-check the ONE load-bearing assumption: is it even true at the shallowest level?
What am I actually changing, and what is its target?
Catch clearly-false premises; do not overcorrect.
Before classifying any gate, check, blocker, or failure as safe to bypass, establish the operation's target outcome and verify that the failing thing is neither that outcome nor on its critical path.
Before adding a bypass that gates an irreversible or high-stakes action, record the target outcome and the rationale for the critical-path judgment; trivial skips are exempt.
A failure in the capability the operation exists to deliver is the operation failing, not noise.
