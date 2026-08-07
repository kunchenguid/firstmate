---
name: loopspec
description: >-
  Agent-only procedure for firstmate's canonical LoopSpec primitive, the reusable answer to "under what conditions do we do this again, what may execute, how is progress verified, and when must it stop".
  Use before authoring or changing a LoopSpec, before selecting one for an event, before driving an iteration to a terminal state, and before describing any loop's status to the captain.
user-invocable: false
metadata:
  internal: true
---

# loopspec

`bin/fm-loopspec.sh` is the single owner of validation, deterministic selection and persistent loop state, and its header plus `--help` own every command, flag and refusal token.
`loopspecs/schema.json` owns the field contract, `loopspecs/triggers.json` owns the trigger register, and each `loopspecs/<id>.json` owns one loop.
This skill owns only what an agent must decide, and it never restates those files.

## Keep the primitive separate

A LoopSpec is temporal recurrence and nothing else.
It is not a ticket, a plan, a skill, an ExecutionUnit, a state machine, or a Fractal Node.
Decomposition is not looping: a node that produces three children has decomposed, and the schema recurring at another depth does not make that a loop.
Reach for a LoopSpec only when the real question is whether to do the same work again later.

## Do not build around it

The intended path reuses what already exists: an existing detector raises a durable wake, selection is deterministic, authorised skills do the work inside a model turn, a verifier declares progress, state persists, and the loop reaches a terminal state or a bounded next iteration.
Never add another watcher, scheduler, wake queue, supervision daemon, skill registry, evidence ledger or accounting source of truth to serve a loop.
Never write a private loop runner to bypass this substrate, and never schedule work from a detector: the detection plane may detect, classify, deduplicate, enqueue and write evidence, and everything beyond that belongs inside a model turn.

## Operating sequence

1. On a wake that might continue a loop, run `select` with the trigger the wake actually carries, never a trigger you infer.
2. Treat exactly one selection line as authority to proceed, and carry its reported version into `claim`.
3. Work only inside the selected spec's permitted skills and actions, and stop at its authority class.
4. Record the outcome with `finish`, naming the terminal the evidence supports.
5. Read the resulting terminal state, then follow the spec's escalation entry for it.

Terminal states are not a per-spec invention: `loopspecs/terminal-states.json` owns the unified terminal-state vocabulary and the total mapping onto it from every source vocabulary that names the same facts, and `fm-loopspec.sh terminal-map` reads it.
A state with no row there is refused rather than mapped to whatever looks closest, so add the row before adding the state.

## A refusal is a stop

Every refusal token is a fail-closed result, never an obstacle to route around.
Do not retry a refusal with different arguments to obtain a different answer, do not edit persistent state by hand, and do not hand-write a spec version to make a claim succeed.
An unavailable verifier can never become a pass; the only route out of one is the spec's failure terminal.
When a refusal names a real gap, fix the gap through the ordinary delivery path or escalate it, and leave the loop stopped meanwhile.
Missing capacity evidence is unknown capacity, not spare capacity, so supply the measured headroom or accept the refusal.

## Enabling a loop is a separate, evidenced decision

A spec may be enabled only when its trigger is implemented, verified and enabled in the register, its permitted skills are installed, and its authority class permits it.
The validator enforces all of that, so a spec that will not enable is telling you which of those is absent.
Marking a trigger `verified` requires witnessed end-to-end execution; a complete description is not an implementation, and neither is a passing description of one.

## Report loops honestly

Say what the loop actually reached, in the captain's nouns, and never announce that a loop is live on the strength of a validated spec.
A spec that validates and cannot be selected is ready and inactive, which is a real and reportable outcome.
Reserve any claim that a loop is running for production evidence that it ran.
