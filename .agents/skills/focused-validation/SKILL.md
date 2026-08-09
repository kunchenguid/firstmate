---
name: focused-validation
description: >-
  Agent-only procedure for the feature-first validation operating model: the mapped focused validation slice that is the default preflight for every ship task, the stop rule that proves a changed surface isolated and proven, the file-to-test-family map, the internal-only fast-path boundary, and isolation-preserving test optimizations that keep per-run isolation. Load before classifying a ship task's surface at intake, before writing or adjusting a ship brief's focused-validation clause, and before running a ship task's focused preflight.
user-invocable: false
metadata:
  internal: true
---

# focused-validation

This skill is the single policy owner for the feature-first validation operating model's procedure.
`AGENTS.md` section 7 owns the always-loaded contract: the preflight requirement, the stop rule, the fast-path boundary, the full-review retention, and the daemon-window scheduling rule.
`bin/fm-brief.sh` generates the worker-facing focused-validation section in every ship brief and points here for the detail.
This skill never duplicates those owners; it states the procedure they reference.

## Load triggers

Load before classifying a ship task's surface at intake, before writing or adjusting a ship brief's focused-validation clause, and before running a ship task's focused preflight.
A worker running a ship brief that carries the focused-validation section loads this skill through the brief's `$FM_ROOT` pointer when it needs the ladder, the isolation proof, or the map.

## The mapped focused validation slice

Every ship task runs a mapped focused validation slice before the full review starts or before a direct-PR opens, and records the slice's timing.
The slice is the cheapest test selection that can observe the change's contract, mapped from the touched files.

- For firstmate-repo tasks, the map is `bin/fm-test-run.sh --changed` (the changed-file to family map owned by that script's header) or the touched `tests/<family>.test.sh` scripts directly.
- For other projects, use the focused test families the project's committed `AGENTS.md` names.
- When a project has no such pointer, choose the minimal test file or runner selection that asserts the contract, and record the choice with the timing.

The preflight's purpose is that a trivial break fails in seconds here instead of after the full review.

## The stop rule: isolated and proven

A changed surface is isolated and proven when all four conditions hold:

1. **File-to-surface map** - the touched files resolve to exactly one module and one test family, with no shared middleware, config, deploy, or edge file in the diff.
2. **Contract expressibility** - the acceptance condition is writable as a pure function or a single API-level assertion, with no browser, scheduler, or external service required.
3. **No external mutation** - the diff writes no database schema shared with other features, no deploy workflow, no secret, and no edge config.
4. **Existing focused coverage** - the module's focused tests exist and pass on the base.

Only an isolated and proven surface earns fast-path eligibility, and only inside the internal-only boundary: direct-PR with focused validation is limited to internal tooling, automation, scripts, and operator process.
Product-facing, mixed, security-sensitive, edge, deployment, and uncertain work climbs to the full `no-mistakes` review regardless of focused-slice results.

## Isolation-preserving optimizations

Per-run test isolation is retained indefinitely; there is no shared warm test stack.
Optimize startup inside isolated runs with deterministic fixtures, immutable dependency or image caches, focused health checks, and unique writable test artifacts such as per-worker database names and ephemeral ports.
A shared warm stack is not part of this model, and no change here reintroduces it.

## Scheduling around the gate daemon

The full `no-mistakes` review stays the production correctness gate.
Never schedule a no-mistakes run that would span a no-mistakes daemon-update window, because a daemon restart kills in-flight runs.
Only firstmate manages the daemon.

## Focused validation is not visual review

The focused slice never substitutes for the separate vision-capable visual-review worker that `AGENTS.md` section 7 assigns to every UI-touching ship.
