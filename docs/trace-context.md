# Native W3C trace-context propagation

Firstmate can propagate a W3C [`traceparent`](https://www.w3.org/TR/trace-context/) to every agent it spawns so an external observer can identify each task as exactly one trace and correlate everything that task runs under that one identity.
The capability is default-off, source-owned, vendor-neutral, and deliberately narrow.
This document is the rationale and current-behavior guide; `docs/configuration.md` owns the configuration schema, `bin/fm-trace-context-lib.sh`'s header owns the exact mechanics, and [`verification/trace-context.md`](verification/trace-context.md) records the repeatable test evidence.

## Why this is a source change at all

Firstmate's durable operational artifacts already let a downstream observer derive logical task identity and lifecycle.
The source capability an observer cannot reconstruct after launch is a task-scoped trace id delivered in the agent's environment before launch and recorded under the same identity in task metadata.
This feature adds only that carrier seam.

## What it does

When enabled, for each spawn Firstmate resolves one W3C `traceparent` carrier for the task - minted as a fresh root on the task's first spawn and reused verbatim from the meta on relaunch - and:

- forms it as `00-<32 hex trace id>-<16 hex span id>-<2 hex flags>`, with random ids for a new root;
- injects it into the agent's pane shell as the `TRACEPARENT` environment variable immediately before launch, through the same `spawn_send_text_line` channel that already ships `GOTMPDIR`; and
- records the identical value as `traceparent=` in `state/<id>.meta`.

`TRACEPARENT` as an environment variable is a Firstmate convention carrying a W3C-formatted value: W3C Trace Context standardizes the `traceparent` HTTP header, not an env var, and OpenTelemetry SDKs do not read it from the environment automatically, so a downstream observer must explicitly read this env value or the `traceparent=` meta field.
This feature parents no SDK span by itself.

Because the injected carrier and the recorded carrier are the same string, an observer that reads the metadata reconstructs exactly the identity the child received.
This is the same coverage `GOTMPDIR` already has and requires no trace-specific `launch_template()` behavior.

## Root and recovery semantics

The point of these rules is one trace per task: never merge unrelated tasks, and never mint a second identity for the same task.

- **Root** - a spawn whose task meta holds no valid recorded carrier mints a fresh trace id, a fresh span id, and sampled flags (`01`).
  This begins a new trace, one per task.
- **Recovery** - a valid `traceparent=` already recorded in the task's meta is reused verbatim, so a relaunched or recovered task keeps one stable identity across restarts rather than starting a second trace.
  A corrupt recorded value is re-minted as a fresh root rather than propagated.

Disabling propagation is an intentional trace boundary: a disabled home injects no carrier into a newly launched or relaunched agent even when the task meta already contains a valid `traceparent=`.
An actual disabled relaunch regenerates the task meta without `traceparent=`, so a later enabled relaunch roots a new trace instead of resuming the identity from before the boundary; reusing an already-alive remote endpoint is not a relaunch and preserves the carrier that agent already holds.

### Enablement is home-session-scoped

Each locked `bin/fm-session-start.sh` run resolves that home's `config/trace-context` plus `FM_TRACE_CONTEXT` exactly once into session-scoped effective state.
The decision is atomically published through a same-directory temporary file and bound to the current session lock, so a failed publication cannot reactivate a stale `on` record from an earlier session.
Every spawn from that home reads only the frozen `on` or `off` decision.
Later config or environment edits are ignored until that home starts a new session.
Missing, stale, unreadable, invalid, or unsuccessfully published effective state defaults safely to `off`.

That flag is session-scoped enablement rather than durable configuration, so it is transferred at the launch convergence point - where the frozen decision is handed over with it - and left untouched by live convergence into an already-running home, on local and remote routes alike.
When enabled, a relaunch reuses the task's valid recorded carrier; a task without one roots a fresh trace.

Changing the setting across the whole fleet requires a manual full fleet restart so every home starts a new session and freezes the new decision.
Firstmate does not monitor setting drift, detect mismatches, refuse launches, or automatically stop or restart any home.

## Sampling

A new root sets the W3C trace flags to `01` (sampled).
This is a deliberate, source-owned choice:

- The capability is **opt-in** and default-off, so a home that enables it is asking for its spawns to be traced; an unsampled (`00`) root would produce a trace id that most downstream parent-based samplers drop, yielding nothing for the operator who opted in.
- **A recorded carrier keeps its flags verbatim.**
  Recovery reuses the task's recorded carrier byte-for-byte, flags included, so a task's sampling decision is stable across restarts.
  Firstmate chooses the flag only when it mints a *root*, which is the only way a new carrier is created.
- **Cost and privacy consequence.**
  `01` records a sampling *decision*, and a conforming downstream parent-based sampler will honor it - but it does not by itself guarantee that any collector stores a span, and Firstmate emits no spans of its own; it only sets the flag on the carrier.
  An operator who enables the capability and points sampling-respecting instrumentation at it should expect on the order of one trace per task to be recorded, at whatever cardinality and retention that instrumentation is configured for.
  An operator who wants unsampled roots or head-sampling owns that downstream or via a later, explicitly-scoped option; Firstmate does not embed a sampler.

## Safety

- **Default-off.**
  With no `config/trace-context` and no `FM_TRACE_CONTEXT`, a fresh spawn or actual relaunch injects nothing and writes no `traceparent=` line, so the generated meta and the launch environment are unchanged.
  Reusing an already-alive remote endpoint records any carrier that endpoint reports without injecting a new one.
  A locked session start makes the one config-file check, and each spawn sources one extra library and reads the frozen effective-state file, so the process is not literally byte-for-byte identical, but nothing an agent, an observer, or the task meta can see differs.
- **What is and is not exposed.**
  A Firstmate-*minted* root uses a random id and reads no prompt, path, task prose, credential, or arbitrary environment key, so Firstmate never *originates* sensitive data in the carrier.
  Every carrier Firstmate injects is either such a mint or the same task's previously recorded carrier reused verbatim; ambient `TRACEPARENT` is never read, so no caller-controlled bytes enter a new carrier.
  Exposure is bounded to that fixed-width carrier - it cannot carry a `tracestate`, an `OTEL_*` credential variable, or any arbitrary environment key, and there is no configurable or arbitrary command (only the fixed local `od`/`tr` for entropy).
- **Fail-independent.**
  Minting is a small local entropy pipeline: it reads a few bytes from `/dev/urandom` through the fixed local `od` and `tr` (resolved from PATH).
  There is no configured provider command, no network, and no watchdog.
  The normal cost is small, but `od`/`tr` are external processes, so there is no hard latency guarantee - this is not a guaranteed-negligible bound.
  Any entropy or self-validation failure that returns omits the carrier for that spawn without aborting source work; a corrupt recorded carrier is re-minted as a fresh root rather than propagated (it is not an omission).
  If the pre-launch carrier export fails, Firstmate omits the `traceparent=` metadata claim and still launches the task.
  If the backend reports that failed trace input could not be cleared, Firstmate refuses to append the launch command rather than risk launching with an unknown partial carrier.
  If recording the carrier fails after export, Firstmate unsets `TRACEPARENT` in the launch command and still launches the task, so the child never receives an identity absent from its metadata.
- **Metadata-only.**
  The value lives in the ephemeral pane shell and in `state/<id>.meta`; teardown removes state as before, so there is no new durable surface and no schema migration.

## Relationship to OpenTelemetry and later increments

Firstmate learns nothing about OpenTelemetry, any exporter, collector, storage, or UI.
It emits a standard W3C carrier and records the same identity; a downstream observer owns everything else and discovers active propagation from the home session's frozen decision or the `traceparent=` field.
Native lifecycle-event emission, extra stable IDs, intake metadata, and any embedded OTLP are deliberately deferred until a running observer demonstrates a concrete fidelity gap that the derived artifacts cannot cover.

## Verification

Repeatable test evidence - the unit and spawn-path suites with exact commands and output - lives in [`verification/trace-context.md`](verification/trace-context.md).
