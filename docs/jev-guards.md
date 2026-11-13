# Jev guard framework

A Jev guard is a bounded, read-only host diagnostic that turns one class of resource or state pressure into a machine-readable audit record and a one-line verdict.
Guards exist so a supervision loop can distinguish a genuinely wedged worker from a host condition that merely looks like one, without granting any guard the power to change the system it measures.
This document owns the framework contract every guard family follows; each family's own script header owns its measured signals and thresholds.

## Shape

Each family ships as a pair plus its tests.
`bin/fm-jev-<name>-guard.sh` is a thin wrapper that resolves its own directory and `exec`s the family engine with `python3`.
`bin/fm-jev-<name>-guard.py` is the engine: it measures, classifies, and prints.
`tests/fm-jev-<name>-guard.test.sh` drives the engine through its public CLI and asserts observable output, never engine source text.

## Engine contract

- Read-only diagnostics: a guard never writes to the system it measures and never mutates agent, session, or repository state.
- Fail-open: permission errors, missing pseudo-files, and virtualized-environment gaps degrade to a graceful `UNKNOWN` verdict with a reason, never a crash and never a false alarm.
- Bounded: one run finishes in well under a second on a healthy host; a guard that cannot answer in its budget reports `UNKNOWN` rather than blocking its caller.
- Structured output: `--json` prints one JSON object with `name`, `checked_at`, `status`, `recommendation`, and the family's own measured fields; human output is a short list of the same facts.
- Deterministic classification: `status` is one of `OK`, `WARNING`, `CRITICAL`, or `UNKNOWN` - the last only when fail-open withholds the verdict; thresholds live in the engine and are named in its header so a reader can audit the verdict.

## Verdict semantics

- `OK` means the measured condition is healthy and the caller should continue unchanged.
- `WARNING` means the condition is degraded but explained; the caller records it and continues.
- `CRITICAL` means the condition explains worker silence; the caller should not escalate a wedge while it holds, within whatever bound the caller puts on that deferral (see [Caller](#caller)).
- A guard never recommends a destructive action; `recommendation` is diagnostic text for the operator, not a command.

## Caller

The watcher's wedge timer is the one caller, and only in a home that lists guards in `config/wedge-evidence-guards`.
There a live pane about to wedge-escalate asks each listed guard, and a `CRITICAL` answer defers that escalation for a bounded run of windows instead of suppressing it.
[`configuration.md`](configuration.md#wedge-evidence-guards-configwedge-evidence-guards) owns that opt-in and its example operator family, and `bin/fm-watch.sh`'s `wedge_guard_evidence` owns the exact invocation and fail-open boundaries.

## Adding a family

Copy the smallest existing pair, keep the wrapper under ten lines, and keep every threshold in the engine with a comment naming the resource it bounds.
Add the family's behavioral test alongside it and run it through `bin/fm-test-run.sh`.
A family that needs a host-specific source (a fleet registry, a pool manager, a quota service, or a product's hook store) belongs to the operator's own layer, not this framework.
