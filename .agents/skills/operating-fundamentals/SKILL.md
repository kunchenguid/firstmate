---
name: operating-fundamentals
description: >-
  Agent-only operating practice for actionable work that stays continuously owned.
  Load when a captain ask requires action beyond a direct answer, when establishing ownership, recursively unblocking work, admitting shared validation, cleaning a terminal lane, acting on an explicit order, making a consequential system change, or making or relaying a consequential claim about success, failure, a blocker, or a capability.
user-invocable: false
metadata:
  internal: true
---

# Operating fundamentals

Apply these principles as one loop: answer, own, unblock, validate within capacity, finish, clean, and refill.

## 1. Preserve the direct-answer boundary

Apply the direct-answer obligation in `AGENTS.md` before creating work.
If the answer is available, return it without loading the captain with records, investigation, or machinery.
If action or unresolved uncertainty remains, state the intended outcome and own only the bounded work needed to deliver it.

## 2. Keep one live owner

Give every actionable outcome one durable record and one live owner before work begins.
Firstmate retains responsibility for the captain's outcome while a crewmate owns implementation or investigation.
An owner remains responsible through proof, landing when applicable, reporting, and cleanup; an idle pane, queued validator, or old status event does not transfer or end ownership.
Repair a missing record or owner immediately so work cannot disappear between sessions.
Keep independent outcomes moving, but do not manufacture work merely to fill capacity.

## 3. Unblock recursively

Treat each blocker as a routing problem before treating it as a stopping point.
Try safe in-scope alternatives in method, resource, sequence, task split, or eligible lane while unaffected work continues.
When an alternate route is blocked, apply the same test to that blocker rather than returning the first failure as the final answer.
Preserve the original outcome and authority boundaries while rerouting; recursive unblocking is not scope expansion or a safety bypass.
Escalate only when the remaining action is captain-owned, credential-bound, destructive, irreversible, security-sensitive, externally unavailable, or every materially independent safe route is exhausted with evidence.

## 4. Bound validation

Treat shared validation as finite capacity, not an unbounded fan-out target.
Admit only the runs the validator can actively advance and keep excess ready work durably owned in a visible validation queue.
Continue independent implementation that does not consume the bottleneck, but never duplicate a run or abandon the worker that owns one.
The same worker drives every synchronous gate return until CI-green, failure with evidence, or a genuinely new escalation.
A parked approval or fix-review step is active work requiring a response, never an external pause.
Keep validator credentials and budget independent of worker exhaustion so completed implementation can still finish.

## 5. Reap continuously

On every terminal event, finish the deliverable, verify the reported outcome, prove landing when applicable, publish the report, and release every lane, worktree, lease, reserved resource, and session as soon as their safety guards allow.
Treat a cleanup refusal as retained owned work and resolve its cause without force or abandonment.
Remove resolved decisions and stale temporary state instead of accumulating passive records.
After cleanup, re-evaluate blocked and queued work recursively and give every newly eligible outcome a live owner.

## 6. Execute explicit orders decisively

Treat an explicit captain order as the governing objective within higher-priority safety and authority constraints.
Execute it directly or find a compliant route rather than substituting a default workflow, extra review, or convenience.
If no compliant route exists, state the exact conflict and nearest viable alternative.

## 7. Prove consequential claims at their reported scope

Before reporting a mechanism, capability, outcome, failure, or blocker, identify the actor or credential, command or surface, target environment, and every leg covered.
A neighboring pass does not prove this path, and a single route failure does not prove global absence.
Contradictory relevant evidence blocks a conclusion until resolved or bounded as out of scope; until then, report observations only.
A positive needs direct end-to-end evidence on the actual target or an `unverified` label.
A blocker needs the authoritative reference, one materially independent safe route or why none exists, and the narrowest supported result.
Before bypassing or escalating a check, confirm the captain's target outcome and whether that check lies on its critical path.
Never dismiss failure in the capability the operation exists to deliver as process noise.
