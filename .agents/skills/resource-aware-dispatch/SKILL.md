---
name: resource-aware-dispatch
description: >-
  Agent-only procedure for measuring compute capacity, deriving worker slots,
  and routing host-bound work to a preferred or fallback SSH host.
  Load before dispatching additional independent crewmate or scout work, and
  before placing recompute-heavy or host-bound work.
user-invocable: false
metadata:
  internal: true
---

# resource-aware-dispatch

This skill is the single owner of the firstmate procedure for resource-aware parallel dispatch.
`bin/fm-capacity-lib.sh` owns the slot formula, the fresh-probe contract, host-scoped live-worker counting, same-task uniqueness, and the refuse-rather-than-kill spawn gate.
[`docs/configuration.md`](../../../docs/configuration.md) "Compute hosts and worker slots" owns optional `config/compute-hosts.json`.
`AGENTS.md` section 7 owns the always-loaded intake boundary and load trigger.
This is not model routing: do not edit `config/crew-dispatch.json` or standing harness pins from this skill.

## When to load

Load before spawning an additional independent ship or scout worker, and before placing recompute-heavy or host-bound work on a compute host.
A sequential replacement of a stuck or superseded worker uses `bin/fm-control.sh <id> relaunch` and does not take a second slot.
A persistent secondmate is not an independent worker slot.

## Fresh measurement, then assign

Run `bin/fm-capacity.sh probe` at the moment of assignment.
Do not reuse an earlier session's reachability, load, or slot count.
If captain preferences name a preferred SSH alias and a fallback SSH alias, pass them on that invocation (`--preferred` and `--fallback`) even when the config file is absent, so the executable sees this home's hosts without copying them into shared instructions.

Read the printed `slots`, `occupied`, `free`, `homes_scanned`, and `route` lines as the verdict.
`occupied` counts live workers across every local firstmate home on this host, including secondmate homes, so the budget protects the server rather than granting each home its own; `homes_scanned` says how many homes that count covers.
A task whose worker is confidently gone - a captain hold, a merge wait, an exited pane - keeps its record but releases its slot.
Whenever the endpoint state is neither a confident `alive` nor a confident gone - a backend with no recovery classifier, and equally an ambiguous or unreadable read on one that has it - that release follows the task's own last declaration instead: a declared `paused:` or `captain-held:` wait releases the slot, as does anything else the shared wake classifier reads as captain-relevant, while actively working or not-yet-declared work keeps it, so an unreadable endpoint can never oversubscribe the host.
A fresh ship or scout is refused when its id belongs to a record that is not an independent worker - a live secondmate's above all - for as long as that record exists, and when it belongs to a ship or scout whose worker is still live.
A ship or scout whose worker is positively gone keeps its record but releases the id, so a task whose pane died with its worktree intact is restarted by spawning it again rather than by deleting its metadata.
Each of `--preferred`, `--fallback`, `--preferred-kind`, and `--fallback-kind` overrides only its own field of the config file, so a preferred-only pin keeps the configured fallback; an unknown kind is refused rather than coerced.

## Independent workers

Dispatch isolated independent work in parallel up to `free` slots, not a fixed agent count.
When `free` is 0, keep the next independent item queued and leave every already-running worker running.
Never spawn a second worker for a task that already occupies a slot.
Never interrupt, exit, or abort another task's worker to free a slot.
`bin/fm-spawn.sh` enforces the same gate on a fresh ship or scout launch; treat a capacity refuse as "queue and wait", not as a reason to kill someone else.

## Host-bound and recompute-heavy work

Follow `route=` from a fresh `probe` or `route` run:

- `preferred` - place that work on `route_host`
- `fallback` - the preferred host was unreachable or unsuitable; use `route_host`
- `none` - do not pile that class of work onto the protected local supervisor

Worker panes still launch on this supervisor host through the ordinary spawn path.
The route is where the host-bound compute runs, not a second copy of the agent.

## Config

Optional local `config/compute-hosts.json` is gitignored and is not inherited by secondmate homes.
Copy the shape from [`docs/examples/compute-hosts.json`](../../../docs/examples/compute-hosts.json).
An absent file still protects the local supervisor through measured slots.
This file is not a harness or model profile.
