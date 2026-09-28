---
name: profile-array-dispatch
description: >-
  Agent-only decision procedure for resolving a matched crew-dispatch profile
  array by task fit and configured order after verifying model support,
  authentication, and runtime compatibility.
  Load when a dispatch rule or default resolves to more than one profile candidate.
user-invocable: false
metadata:
  internal: true
---

# profile-array-dispatch

This skill is the single owner of profile-array selection.
`AGENTS.md` section 4 owns routing precedence, the load trigger, malformed-config refusal, and Firstmate-only final choice.
`harness-adapters` owns harness verification, model and provider discovery, authentication evidence, and effort fallback.

Do not add a quota service, scheduler, opaque score, hard-coded model ranking, or provider fallback.
Do not invent capacity from missing telemetry.
The profile array is ordered configuration: after the gates below, select the first eligible profile in its written order.
That order is the captain's only preference among otherwise eligible profiles.

## Resolve task fit first

Determine the task's required capabilities and reasoning class before inspecting candidate order.
Keep only profiles that meet those requirements.
Never let array order silently downgrade a required capability or reasoning class.
If no profile meets the task, report the unmet requirement and every candidate considered.

## Verify candidates in order

Inspect task-fit candidates in configured order.
For each candidate, establish these facts from the selected harness's authoritative surfaces described by `harness-adapters`:

- the harness is supported by Firstmate;
- the configured model is listed for the current account when a model is explicit;
- the model's provider relationship and selected authentication surface are known;
- that selected authentication surface is usable;
- the configured effort is compatible with the harness and model; and
- the resolved runtime backend can launch the harness.

An account-reaching model listing that omits the configured model is concrete unsupported evidence.
An authoritative authentication check that rejects the selected credential is concrete unavailable-authentication evidence and excludes that candidate before selection.
An unreachable discovery or authentication surface establishes uncertainty, not support.
If required support or authentication cannot be established, stop and report the exact missing evidence instead of guessing or skipping an unresolved earlier candidate.
Malformed configuration is an actionable error, never a candidate to select around.
Duplicate concrete profiles are a configuration error.

## Select and launch

Select the first candidate in configured order that passes task fit and all verification gates; later candidates need no speculative probe.
Account for earlier candidates explicitly, naming the task-fit or concrete support reason that excluded each one.
Pass only the selected concrete `harness`, `model`, and `effort` axes to the spawn owner.

If the provider refuses the selected candidate during launch or work, report that refusal honestly.
Do not silently retry the next array member or switch models.
A different candidate requires a new explicit Firstmate selection using current evidence.
