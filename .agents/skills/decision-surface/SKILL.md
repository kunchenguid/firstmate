---
name: decision-surface
description: >-
  Agent-only procedure for consuming the resolved operational decision surface instead of reconstructing operational truth.
  Use before asserting any capacity, dependency, decision-status, in-flight, verifier, or landing fact, before dispatching work that may already exist, and whenever a decision-surface check returns contradicted or unevaluable.
user-invocable: false
metadata:
  internal: true
---

# decision-surface

Firstmate reasons about meaning.
CODE resolves operational fact.
This skill owns what firstmate does with the resolved surface; `bin/fm-decision-surface.sh`'s header owns the command contract, its schema, and its exit statuses.

The failure this exists to prevent is not a wrong answer, it is a confident one.
Reconstructing operational truth conversationally produces prose that reads as authoritative and drifts from the records silently.
The incident that motivated the surface was a report that queued work would dispatch "as capacity frees" while nothing in the fleet was capacity-bound at all.
Every fact needed to refute that sentence was already recorded; nothing made it get read, and nothing refused the sentence.

## The rule

Consume the surface before reasoning about work.
Interpret it, explain it, and reason about what it means, but never re-derive what it already states.
No firstmate prose may contradict its capacity, dependency, decision-status, in-flight, verifier, or landing fields.

Run `bin/fm-decision-surface.sh` for the fleet, or with a task id for one task.
It is read-only: no lock, no wake drain, no mutation.

## The three checks

Each answers one question - does structured state contradict the claim - and nothing else.

| Check | The claim it tests |
|---|---|
| `check capacity-blocked` | "this is waiting on capacity" / "it will dispatch as capacity frees" |
| `check decision-pending <decision-id>` | "that decision is still with the captain" |
| `check duplicate-dispatch <task-id>` | "dispatch this work" when the identity may already be live |

Build the decision id with `bin/fm-decision-hold.sh id <origin-id> <decision-key>`.

Read the verdict, not the exit status alone:

- **not-contradicted** - no landed owner refutes the claim.
  This is not a warrant that the claim is true, only that nothing deterministic denies it.
  Say it if your own reasoning supports it.
- **contradicted** - the claim is forbidden.
  Do not soften it, hedge it, or repeat it with a qualifier.
  The evidence line names the reading that refutes it; act on that reading instead.
  A contradicted capacity claim usually means the real blocker is semantic and still unnamed - name it or dispatch.
- **unevaluable** - no landed owner could answer.
  The fact may not be asserted at all.
  Unevaluable is never a quiet pass: an unreadable census, an invalid admission policy, or an absent decision record each mean firstmate does not know, and saying so plainly is the correct captain-facing outcome.

## What is still firstmate's

`bin/fm-decision-surface.sh owners` prints the durable ledger of deterministic work, each row either owned by a landed command or marked pending with the capability that must land first.
A pending row means the compensating instruction in `AGENTS.md` is retained deliberately, and these are the current pairings:

| Pending row | The instruction it keeps alive |
|---|---|
| `attempt_and_retry_counting` | firstmate still judges when a repeated failure has become a real blocker |
| `verifier_verdict_vocabulary` | firstmate still reads each verifier in that verifier's own terms |
| `invoking_known_next_stage` | firstmate still triggers validation on the worker rather than calling the pipeline |
| `deadline_and_time_gate_elapsed` | firstmate still re-reads queued time gates at teardown and heartbeat |
| `transition_legality`, `why_not_now`, `path_health`, `deterministic_progression` | firstmate still derives the lawful next action from the lifecycle contract |

Retiring a compensating instruction without flipping its row, or flipping a row without retiring the instruction, leaves exactly the silent gap this ledger exists to prevent.
Change both in the same edit.

## The platform seam

The deterministic platform publishes a richer projection - `why_not_now`, allowed and forbidden transitions, path health, authority, and whether reasoning is required at all.
`bin/fm-decision-surface.sh platform-seam` prints that contract and its wiring state; `--probe-platform` measures it rather than assuming it.

It is marked not-wired until the platform projection resolves this home's fleet task ids.
A reachable platform command that names none of this fleet's work is a projection of other identities, not live wiring, and consuming it as though it described fleet work would reintroduce exactly the contradiction this skill forbids.
When it wires, the platform projection becomes authoritative for the fields it owns, the fleet composer defers to it, and the four transition-related pending rows retire together.

## Reporting it to the captain

The surface is evidence, not a message.
Translate it under `AGENTS.md` section 9 before it reaches the captain: say what is blocking the work and what decision it needs, never the check name, verdict token, or exit status.
A contradicted claim that was already sent is a correction worth making plainly and once, because the captain may have planned around it.
