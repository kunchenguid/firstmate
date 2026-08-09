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

## Let code execute the transitions it already determines

`bin/fm-loop-actuate.sh` is the wake-to-action table, and its header plus `table` subcommand own the mapping.
Run it rather than performing a transition by hand: when exactly one lawful transition follows from the recorded state, spending a coordinator turn to carry it out is the cost this substrate exists to remove.
Agents reason inside bounded work; they are not the state machine.

Two places genuinely need a turn, and only these two.
The first is choosing between candidate specs when the deterministic filter leaves two or three, which stays a decision rather than a function; answer it over the typed applicability headers from `candidates`, never by reading spec bodies into context, and hand the answer back as `run --spec <id>`.
The second is the work inside a claimed iteration, done under the spec's permitted skills and actions.

## Operating sequence

1. On a wake that might continue a loop, actuate with the trigger the wake actually carries, never a trigger you infer.
2. If the candidate set needs the judgment call, make it over the headers alone and return it as `--spec`; a set of four or more is a filtering defect to fix, not a harder choice to make.
3. Work only inside the selected spec's permitted skills and actions, and stop at its authority class.
4. Let the bound verifier produce the verdict. Never report one yourself: a success terminal requires a recorded run bound to that iteration, and the party doing the work never certifies the work.
5. Read the resulting terminal state, then follow the spec's escalation entry for it.

## A refusal is a stop

Every refusal token is a fail-closed result, never an obstacle to route around.
Do not retry a refusal with different arguments to obtain a different answer, do not edit persistent state by hand, and do not hand-write a spec version to make a claim succeed.
An unavailable verifier can never become a pass; the only route out of one is the spec's failure terminal.
When a refusal names a real gap, fix the gap through the ordinary delivery path or escalate it, and leave the loop stopped meanwhile.
Missing capacity evidence is unknown capacity, not spare capacity, so supply the measured headroom or accept the refusal.

## Enabling a loop is a separate, evidenced decision

A spec may be enabled only when its trigger is implemented, verified and enabled in the register, its permitted skills are installed, its authority class permits it, and its `verifier_command` resolves inside the repository and can run.
The validator enforces all of that, so a spec that will not enable is telling you which of those is absent.
Marking a trigger `verified` requires witnessed end-to-end execution; a complete description is not an implementation, and neither is a passing description of one.

Bind the verifier before anything else, because the binding is what makes the work loopable at all.
Work is genuinely loopable only when a named verifier can produce different evidence after an iteration because of the action that iteration took; repetition being possible is not sufficient.
A verifier that is named but unreachable is worse than none, since it looks bound and verifies nothing, so name the executable rather than a concept.
Prefer a deterministic verifier over a judgment-based one: it needs no independent maker and checker, so it is unaffected when vendor diversity is degraded.

## Report loops honestly

Say what the loop actually reached, in the captain's nouns, and never announce that a loop is live on the strength of a validated spec.
A spec that validates and cannot be selected is ready and inactive, which is a real and reportable outcome.
Reserve any claim that a loop is running for production evidence that it ran.
