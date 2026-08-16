# Process-to-event runner verification

Audience: maintainer verification.

This record holds reusable evidence for the generic runner's active guarantees.
`docs/configuration.md` owns the operating contract, each script's header and `--help` own its mechanics, and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

Verified on 2026-08-13 on the current supported development platform.
The generic cases use inert fixture adapter names, while supported adapter behavior is covered by the remote-reply and condition->action suites.
No external poll service is required.

## What the runner proves

The generic cases are exercised by `tests/fm-procevent.test.sh` against fake blocking processes whose completion is a process event, not a timer.
Watcher delivery is exercised by `tests/fm-watch-triage.test.sh` over a real capture.
Adapter-owned application is exercised end to end by `tests/fm-remote-reply.test.sh`.

| Guarantee | Evidence |
| --- | --- |
| capture before publication | the captured result exists at `0600` and its event names its committed sequence only afterward |
| proactive delivery | a real capture queues a `check` record, and a healthy watcher reports it through the existing actionable wake path |
| bounded re-announcement until handled | an unhandled result is re-announced with the same source and sequence across reconcile calls and replacement sessions |
| handled acknowledgement | `fm-procevent.sh handled` is private, generation-keyed, idempotent, and the only operation that stops re-announcement |
| adapter-owned terminal verdict | fixture adapters prove that terminal retirement is adapter-owned and that an adapter without terminal knowledge stays armed |
| adapter-owned application | the remote-reply adapter updates its local status mirror, settles its pending reply, re-arms its cursor, and acknowledges idempotently |
| condition->action trust and single-fire | `tests/fm-procevent-when.test.sh` proves stable true fires once and mutated specs or action executables are refused before execution |
| result identity and ordering | wakes name the committed sequence, and pending sequences `1`, `2`, and `10` publish in numeric order |
| one owner per canonical source | a second home cannot start an already-owned source |
| isolated process ownership | direct start establishes a runner-owned process group before claiming a source |
| stale reclaim without displacement | contenders replace stale claims only after the old generation is stopped and released |
| uncertain identity safety | an uncertain live owner keeps its registration and claim for retry rather than being signalled |
| bounded home sweep | teardown preflights and retires only registrations and claims physically owned by the target home |
| argv integrity | spaces and shell metacharacters remain literal arguments, and unrepresentable newlines are rejected |
| bounded output | output over `FM_PROCEVENT_MAX_OUTPUT_BYTES` is drained while staged output remains bounded |
| terminal failure recovery | a failed terminal removal stays terminal, does not restart polling, and completes idempotently when removal recovers |
| silent failure handling | a nonzero source with no output publishes nothing and remains registered for retry |
| inertness | a home with no registered source starts no process and generates no process-event state |

The runner proves only its own durability boundary.
It never claims at-least-once, no-loss, lossless, or generic exactly-once delivery or effects.
Source-side replay and durability limits remain adapter-specific and are documented by the adapter that owns them.

## Runner lifetime and cleanup

A runner is its own process-group leader and outlives the shell that started it by design.
`retire` and `reconcile` verify the runner-owned group, stop it, and refuse to release ownership until the group is gone.
A leader that died while its owned group survived is reclaimed only after that group is stopped.
PID reuse and uncertain identity never authorize signalling.

The suite covers orphan cleanup and leaves zero fixture runners, children, and stray claims after repeated runs.

## Portability and scope

The runner uses the platform launcher selected by its existing implementation to establish a private process group and verifies the expected group leader before recording a claim.
The runner is domain-neutral and creates no endpoint, task metadata, or backlog item.
All supported primary harnesses and runtime backends consume process-event wakes through the existing watcher path, so this contract adds no harness or backend-specific control plane.
The `when` adapter uses the same locked registration publisher and trust boundary as the generic runner.
