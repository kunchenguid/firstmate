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

Every debug or fix report ends with exactly one nominal verdict:

| Verdict | Meaning |
|---|---|
| `verified` | the fix was exercised against the scenario that reproduced the bug, with cited evidence (command + raw output) |
| `partial` | the fix resolves part of the scenario; the residue is named and evidenced |
| `failed` | the fix does not resolve the bug, or the verification was not executed |

Fail-closed rule: missing verification means `failed`.
There is no "presumably fixed": a fix without recorded verification is reported as `failed`, never as a success.

Per-bug artifact format:

```markdown
### Bug: <short title>
- Symptom: <what broke, where>
- Hypothesis: <investigated root cause>
- Fix: <what changed, with file:line>
- Verification: <command executed + cited raw output>
- Verdict: `verified` | `partial` | `failed`
- Residue: <what stays open if partial or failed; `none` if verified>
```

## Measurement honesty

Any number cited to the fleet (percentage, count, tokens, latency, cost) references both:

1. the command that produced the number, and
2. the raw output, as a fenced block in the same document or a path to the recorded log.

Fail-closed: a number without its citation does not enter decisions, reports, or captain-facing summaries; a reader must be able to reproduce the number from the cited command.
"Should pass" is not a measurement; the honest phrasing names the verification that has not run yet.

A wrong number is retracted, never erased: the original stays in place annotated with a dated retraction, the corrected number arrives with its own command + raw output, and git history is never rewritten to hide a measurement.

## Companion tooling: lab config validator

Origin: pavani06/fleet-lab DEC-007, `experiments/config-validator/validate.py`, with schema and usage in that lab's `docs/conventions/config-key-validation.md`.
Given a YAML or JSON config, it rejects the load when a top-level key is outside its `KNOWN_KEYS` schema, naming the unknown field and, when one exists, the probable field by edit distance, and exits 1 with that name on stderr.
The schema it validates is the lab's experiment-config schema, not Firstmate's, so it is documented here as a port reference for fleet tooling and is not a dependency of any Firstmate path.
Porting or extending it is ordinary follow-up work; this graduation only records that the tool exists, what it does, and where it came from.
