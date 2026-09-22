# Synthetic competition-scientist lab

This example is an inert pilot for testing competition-research control loops.
It is not part of Firstmate's task, spawn, supervision, validation, or submission lifecycle.
Nothing runs unless an operator explicitly calls `bin/fm-competition-scientist-lab.sh`.
The lab never invokes a model, reaches a competition service, modifies a project, or submits an entry.

## Purpose

The pilot compares a minimal linear autoresearch controller with a bounded proposed controller.
It tests control safety and evidence quality rather than claiming a model-performance result.
A full model-backed A/B is a separately dispatched experiment after this implementation lands.

The three deterministic synthetic tasks expose different research failures:

- `grouped-classification` includes a feature whose relationship flips in stress and sealed groups.
- `nonlinear-regression` has individually weak linear, quadratic, and periodic components whose combinations can improve prediction.
- `noisy-classification` makes small threshold changes fall below the evaluator's declared resolution.

## Safety contract

The only scientific surface is the generated workspace file `candidate.py`.
The lab accepts typed proposals and materializes one literal assignment per attempt.
It parses the candidate with Python's AST and never executes candidate code.
Imports, calls, extra assignments, missing assignments, symlinks, and undeclared workspace files are rejected.
This also prevents a proposal from opening a network connection or launching a subprocess.

The evaluator, synthetic data, development split, falsification split, sealed-data generator, Python environment record, baseline template, and empty dependency set are frozen and SHA-256 verified before every evaluation.
The sealed rows are generated into a temporary harness-owned file only during finalization and are removed after that single evaluation.
The evaluator runs in a subprocess with a kernel CPU limit and a parent-enforced wall limit.
Linux uses a kernel address-space limit for memory, while macOS uses parent-side resident-memory sampling because macOS rejects a lowered `RLIMIT_AS` for the Python process image.
The default experiment cap is 30 seconds of CPU, 30 seconds of wall time, and 1 GiB of resident memory per evaluator call.
Every successful candidate is evaluated twice before selection, and disagreement is classified as `nondeterministic-replay`.

The threat model is an accidental or confused proposal, not a malicious local account with permission to chmod and rewrite the workspace.
The single-surface check, read-only files, hashes, AST policy, subprocess limits, and replay ledger make mistakes visible and stop ordinary evaluator tampering.
They are not an OS security boundary against the same Unix user deliberately replacing the harness or debugger-attaching to it.
A model-backed experiment that needs hostile-code isolation must add a container or dedicated unprivileged account before accepting arbitrary candidate code.

## Controllers

The `linear` controller always derives one one-lever proposal from the current main incumbent.
A strictly passing candidate is kept, and every other candidate is reverted while its content-addressed evidence remains reachable.

The `proposed` controller uses the same linear behavior for the first four measured attempts, including the baseline.
After at least two consecutive scored experiment rejections, it may create at most two named branches.
Policy violations and infrastructure failures do not manufacture a plateau.
Execution and planning tokens share the total token budget and the per-attempt token cap.
Planning tokens may not exceed the smaller declared planning cap.
The default per-attempt cap is 8,000 tokens, and the default planning cap is 9,600 of 48,000 total tokens, or 20 percent.
Before final promotion, the proposed controller runs one deterministic counterfactual falsification evaluation.
The final sealed audit runs once after search completion and never changes an earlier attempt verdict.

A typed proposal may choose a change, name one bounded falsifier, and request a branch, but it cannot provide a score, acceptance verdict, evaluator edit, budget override, or hidden result.
The selected proposal's falsifier is recorded with the one frozen counterfactual suite rather than executed as arbitrary plan-authored code.
Any model integration must pass measured token use into the proposal record rather than trusting an estimate written by the model.

## Selection rule

Correctness, frozen hashes, the declared surface, deterministic replay, and resource bounds are hard gates.
The quality comparison is lexicographic in this order:

1. worst-group score;
2. grouped mean score;
3. stress-group score;
4. calibration or normalized error;
5. lower candidate complexity when the quality dimensions are equivalent within resolution.

A task-specific evaluator-noise floor is frozen from 64 deterministic within-group bootstrap resamples of the baseline and capped to the interval `[0.005, 0.03]`.
The same floor applies to each normalized quality dimension.
A change below that floor does not promote unless it is a verified simplification.
Any group regression beyond the frozen tolerance rejects the candidate before the lexicographic comparison.
The noisy-classification fixture demonstrates the below-resolution outcome.

## Commands

Create a workspace and record only its baseline:

```sh
bin/fm-competition-scientist-lab.sh init \
  --workspace /tmp/fm-competition-pilot \
  --task grouped-classification \
  --controller proposed
```

Apply one external proposal:

```sh
cat > /tmp/proposal.json <<'JSON'
{
  "id": "drop-spurious",
  "hypothesis": "The development-correlated feature reverses in stress groups.",
  "falsifier": "Reject if any protected group falls beyond tolerance.",
  "changes": {"GROUPED_SPURIOUS_WEIGHT": 0.0},
  "branch": "main",
  "token_cost": 8000,
  "planning_tokens": 0
}
JSON
bin/fm-competition-scientist-lab.sh attempt \
  /tmp/fm-competition-pilot \
  --proposal /tmp/proposal.json
```

Finish the search and call the sealed audit:

```sh
bin/fm-competition-scientist-lab.sh finish /tmp/fm-competition-pilot
```

Re-run every visible scored candidate without calling the sealed audit again:

```sh
bin/fm-competition-scientist-lab.sh replay /tmp/fm-competition-pilot
```

Run one complete search from a JSONL proposal list:

```sh
bin/fm-competition-scientist-lab.sh run \
  --workspace /tmp/fm-competition-run \
  --task nonlinear-regression \
  --controller linear \
  --proposals /tmp/proposals.jsonl
```

Run the zero-token deterministic smoke for all three tasks and both controllers:

```sh
bin/fm-competition-scientist-lab.sh smoke \
  --output /tmp/fm-competition-smoke
```

The command's `--help` output owns the current flags and defaults.
A command refuses to adopt or overwrite an existing workspace.
There is intentionally no cleanup command.

## Proposal schema

Each line of a proposal JSONL file is one object:

```json
{
  "id": "unique-slug",
  "hypothesis": "One testable mechanism.",
  "falsifier": "One bounded disconfirming observation.",
  "changes": {"ONE_ALLOWED_ASSIGNMENT": "new literal value"},
  "branch": "main",
  "token_cost": 8000,
  "planning_tokens": 0
}
```

`changes` must contain exactly one task-allowed assignment.
`token_cost` records execution tokens and `planning_tokens` records planning tokens, and their sum must fit the frozen per-attempt cap.
Hypotheses and resulting candidate hashes must be unique inside one search.
The controller rejects duplicate hypotheses, duplicate candidates, multiple changes, irrelevant levers, early branches, excess branches, and token overruns before they can affect an incumbent.

## Evidence schema

`.run/ledger.jsonl` is the authoritative attempt ledger.
Every row carries:

- schema, sequence, kind, task, controller, branch, parent, and candidate hashes;
- hypothesis, falsifier, and the exact one-assignment delta;
- complete development metrics and prediction hash when execution succeeded;
- verdict, decision reason, failure class, repeat count, wall time, and resource charges;
- frozen data and evaluator hashes plus the recorded environment;
- replay command, previous-record hash, and current-record hash.

`.run/results.tsv` is a compact human view, not a second contract owner.
`artifacts/<candidate-sha256>/` retains each materialized candidate, predictions, and result, including rejected and failed attempts.
`artifacts/proposal-<sha256>/` retains proposals rejected before candidate execution.
`.run/final.json` alone contains the post-search sealed score.
No sealed dataset file exists in the proposer-visible workspace before finalization.

Failure classes include immutable or undeclared-surface refusal, duplicate or confounded proposal, budget refusal, syntax, timeout, OOM, network denial, runtime failure, and nondeterministic replay.
A failure restores the branch incumbent and leaves its evidence reachable.

## Full A/B budget

The planned full A/B shape is three tasks, two controllers, and three controller seeds.
That is 18 complete searches and 108 measured attempts when each search includes its baseline and five proposals.
Two deterministic evaluations per successful attempt produce at most 216 development evaluator calls.
At the hard 30-second evaluator cap, the maximum development CPU exposure is 108 CPU-minutes.
The nine proposed-mode falsification requests use at most 18 additional evaluator calls, and the 18 sealed audits add 18 more, so the total evaluator ceiling is 126 CPU-minutes.
At 8,000 combined execution and planning tokens per measured attempt, the aggregate search ceiling is 864,000 tokens.
The proposed controller's planning allowance is included in that ceiling rather than added to it.
The sealed evaluator runs once after each complete search.

The built-in fixture and smoke modes spend zero model tokens.
They validate mechanics and record a deterministic transcript, but they do not count as the full A/B and do not establish a performance claim.

## Verification

The dated [fixture smoke transcript](../../verification/competition-scientist-lab.md) records the current hashes, command, and exact output.
Run the focused behavior suite with `bin/fm-test-run.sh tests/fm-competition-scientist-lab.test.sh`.
Run `bin/fm-doc-audience-check.sh` after changing this guide or its verification record.

## Model-backed boundary

A model-backed pilot must be separately dispatched after this implementation is reviewed and lands.
It must preserve the same evaluator ownership, one-surface restriction, grouped/OOD gates, resource accounting, and sealed-result timing.
It must also add measured model-token accounting and an isolation boundary suitable for any executable code it accepts.
Competition access, project changes, model/data acquisition, and every upload remain outside this lab and retain their existing approval paths.
