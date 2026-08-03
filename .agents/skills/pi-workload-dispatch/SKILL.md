---
name: pi-workload-dispatch
description: Agent-only intake procedure for selecting live Pi workloads after captain and configured dispatch profiles have had precedence.
user-invocable: false
metadata:
  internal: true
---

# pi-workload-dispatch

Load this skill before every crewmate or scout intake unless the captain has concretely overridden the harness, model, or effort for that task.
Load it again whenever selecting from the live Pi workload source.
This skill owns the intake precedence and selection procedure, while [`docs/configuration.md`](../../../docs/configuration.md#live-pi-workload-source) owns source resolution, schema, helper output, spawn flags, and recorded metadata.

## Intake precedence

Apply these steps in order and stop at the first governing source.

1. Any concrete per-task captain override on harness, model, or effort wins and bypasses both `config/crew-dispatch.json` profile selection and the live Pi workload source for that dispatch.
   Preserve every explicitly supplied axis exactly.
   Resolve unspecified harness, model, or effort axes through the existing static harness path and `harness-adapters` generic fallback as applicable, rather than composing the override with a potentially incompatible dispatch profile tuple.
2. The best-fit rule in `config/crew-dispatch.json` wins, with any profile array resolved exactly through `quota-array-dispatch`.
3. The dispatch file's `default` wins, with the same object-or-array behavior.
4. Otherwise, when the live source is available and `harness-adapters` can verify the effective chosen runtime as `pi` or `pi-signed`, select a live workload by the procedure below.
5. When the live source is absent, preserve its observable `SOURCE_ABSENT` result and continue through the legacy `config/crew-harness` resolution path.

A malformed live source blocks only a dispatch that reached the live-source step, and that dispatch must not fall back to static configuration or another workload.
A selected workload whose model is absent from the selected Pi-family executable's authoritative catalog is blocked, and no alternate workload or model may be substituted silently.
An unavailable discovery surface establishes uncertainty rather than support, so report the uncertainty instead of inventing catalog or provider facts.

## Selecting a live workload

Run `bin/fm-subagent-dispatch.sh list` at intake and judge fit from the current workload descriptions.
Use the balanced tier's `w1` workload only as a recommendation for unmatched ordinary work, never as a hard-coded model choice and never in place of a better description match.
The live workload description decides task fit.
Quota evidence does not rank live workloads and may resolve only genuinely comparable candidates already offered together by a matched `config/crew-dispatch.json` profile array.
The array path still takes exactly one `quota-axi --json` snapshot for the intake, accounts for every candidate, and never uses array order or ranking.

After choosing a tier and opaque workload key, run `bin/fm-subagent-dispatch.sh resolve <tier> <workload-key>` immediately before launch.
Use `harness-adapters` to establish current model support, provider identity, authentication source, and accepted effort for the selected `pi` or `pi-signed` executable.
Do not infer any of those facts from the workload key, tier, model spelling, source path, or another harness's catalog.
Spawn with an explicit Pi-family harness, the freshly resolved model and effort, and the same source tier and workload flags so `fm-spawn.sh` can re-resolve and reject stale input before mutation.
The exact commands and fields are documented in [`docs/configuration.md`](../../../docs/configuration.md#live-pi-workload-source).
