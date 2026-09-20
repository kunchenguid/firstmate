---
name: evidence-conventions
description: >-
  Agent-only reference for the fleet's evidence conventions, graduated from pavani06/fleet-lab DEC-004..007.
  Single owner of the evidence-state vocabulary (reported done / verified / not run), the bug-verdict taxonomy (verified / partial / failed), and the measurement-honesty rule (every number cites its command and raw output).
  Load before writing or reading worker status lines, reports, or PR descriptions that claim completion, verification, bug verdicts, or measurements.
user-invocable: false
metadata:
  internal: true
---

# evidence-conventions

Authority: these conventions were approved in the pavani06/fleet-lab lab (decisions DEC-004, DEC-005, and DEC-006, plus validator decision DEC-007, 2026-09-20) and graduated to fleet-wide operating norms by the captain.
This skill is the single owner of their substance; briefs, status scaffolds, and `AGENTS.md` carry only trigger pointers back here.
The conventions govern claims, not mechanisms: they grade what an agent asserts, and no parser or state machine changes because of them.

## Evidence states

Every claim that work is complete, in a status line, report, PR description, or agent handoff, carries exactly one of these labels:

| Label | Meaning | Who writes it |
|---|---|---|
| `reported done` | the agent says it did the work; nobody has verified it | any agent |
| `verified` | the verification was executed and its raw output is recorded (see measurement honesty below) | whoever holds the evidence |
| `not run` | the verification was not executed | any agent |

Rules:

- Fail-closed: a completion claim without a label is treated as `not run`.
- `verified` without cited evidence is label abuse; the honest label is `reported done`.
- The labels are literal lowercase, with a space inside `reported done` and `not run`, so they stay greppable.

In a Firstmate status line the label lives in the free-text part after the state verb, and the state verb itself (`working`, `done`, `blocked`, and the rest) stays exactly as `bin/fm-classify-lib.sh` defines it.
A brief scaffold's `done [at=<epoch>]: PR {url} checks green` gate is a `verified`-class claim: the pipeline's green CI is the cited evidence.

## Bug verdicts

Every debug or fix report ends with exactly one nominal verdict: `verified`, `partial`, or `failed`.
The token `verified` belongs to the evidence states above; the bug verdicts are derived from them, never redefined:

- `verified` - the fix was exercised against the scenario that reproduced the bug, and its verification evidence carries the evidence state `verified` (command + raw output recorded).
- `partial` - the fix resolves part of the scenario; the residue is named and its evidence cited.
- `failed` - the fix does not resolve the bug, or its verification is missing or `not run`.

Fail-closed rule, coherent with the evidence states: missing or `not run` verification means `failed`.
There is no "presumably fixed": a fix without recorded verification is reported as `failed`, never as a success.
`diagnostic-reasoning` owns the structure of a diagnostic report; this verdict labeling applies on top of that structure.

## Measurement honesty

Any number cited to the fleet (percentage, count, tokens, latency, cost) references both:

1. the command that produced the number, and
2. the raw output, as a fenced block in the same document or a path to the recorded log.

Fail-closed: a number without its citation does not enter decisions, reports, or captain-facing summaries; a reader must be able to reproduce the number from the cited command.
"Should pass" is not a measurement; the honest phrasing names the verification that has not run yet.

A wrong number is retracted, never erased: the original stays in place annotated with a dated retraction, the corrected number arrives with its own command + raw output, and git history is never rewritten to hide a measurement.

Lab config validator reference: pavani06/fleet-lab DEC-007 ships `experiments/config-validator/validate.py`, which rejects a YAML or JSON config on an unknown top-level key, naming the field and its probable match; schema and usage live in that lab's `docs/conventions/config-key-validation.md`, and the tool validates the lab's schema only, so it is not a dependency of any Firstmate path.
