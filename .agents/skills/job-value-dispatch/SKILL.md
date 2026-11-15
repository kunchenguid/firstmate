---
name: job-value-dispatch
description: >-
  Load at every crewmate or scout dispatch intake to classify job value,
  apply same-job evidence, shadow local routes, and verify local Pi endpoints.
user-invocable: false
metadata:
  internal: true
---

# Job-value dispatch

This skill adds the job-value decision to the existing `config/crew-dispatch.json` intake.
The configuration schema is owned by `docs/configuration.md`; `fm-dispatch-resolve.sh` remains the optional typed rule matcher.
This skill does not select inside a profile array: `quota-array-dispatch` owns that decision.

## Decision at the written brief

1. Resolve the project's delivery mode, yolo posture, privacy boundary, and authority before choosing a model.
   An external, irreversible, destructive, or security-sensitive action keeps its existing captain gate regardless of model.
   A task whose code or prompt must stay local has no cloud fallback.
2. Ask whether a wrong result will multiply through later work.
   Architecture, migration, authorization, trust, policy, and ambiguous cross-system design require the strongest suitable reasoning class from the existing specific rules.
   Do not downgrade that class to save quota or to increase local use.
3. Ask whether the work is bounded, independently inspectable, and cheap to rerun.
   Clear bug fixes, implementation of approved plans, test fixes, boilerplate, and bounded UI work can enter a measured local class.
   A model's public benchmark, parameter count, or advertised context is only a prior.
4. Match the existing specific dispatch rule before a generic local rule.
   The explicit captain override remains highest priority.
   If typed resolution is off, ambiguous, escalated, or erroneous, Firstmate makes the same documented judgment; those outcomes never authorize a lower tier by default.
5. Admit a recurring local class only after repeated same-job evidence.
   A screening minimum is three fresh attempts on each of two representative tasks, at least five accepted results in six, no unexplained provider switch or structural tool failure, and independently verified output.
   Keep a new model trial-only when those observations are absent.
   A high-impact class remains on its existing strong profile even if a local model meets the bounded-work screen.

## Shadow and readiness evidence

For a proposed local rule, append one `shadow` row with `bin/fm-dispatch-evidence.sh` before spawn.
Record the proposed model, actual selected model, task class, reason, and confidence when available.
The [operator reference](../../../docs/configuration.md#local-pi-readiness-and-task-outcome-evidence) owns readiness requirements, evidence storage, fields, and content restrictions.
An unmeasured local route may shadow while the current specific rule or Codex default still executes.

Before an actual local Pi spawn, run the script's `check-local` canary against the expected endpoint using the worker account's Pi catalog.
Save its JSON result beside the task's outcome evidence.
Also record the server's checkpoint and runtime revision from the deployment manifest or image digest; an endpoint that does not advertise those revisions cannot prove them by `/v1/models` alone.
If any check fails, leave the local route unselected and state the failure; never silently forward the same request to a cloud endpoint.
Do not perform a model swap or restart a shared server merely to make the check pass.

After a task is verified, append an `outcome` row with the model identity, accepted result, wall time, interventions, rework, and the verifier/evidence reference.
Capture Pi session provider/model and matching server request evidence; an exact landed head proves output, not model provenance.
Classify failures as timeout, structural protocol or format error, capacity or context cap, task-quality failure, or infrastructure failure.
Re-screen a class after a checkpoint, quantization, serving runtime, chat template, reasoning setting, or verifier changes.
Rollback means restore the prior dispatch rule and Pi catalog entry and prove the previous endpoint still answers.

`bin/fm-dispatch-evidence.sh` owns the exact check and log command syntax.
`docs/configuration.md` owns the operator description and JSONL fields.
