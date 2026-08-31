# The bin/ toolbelt

Each script header owns its exact flags, inputs, and mechanics.

Use this inventory to find the current owner, then read that header before running a script.

## Session and fleet

| Script | Purpose |
| --- | --- |
| `fm-session-start.sh` | Compose the locked local session-start digest. |
| `fm-bootstrap.sh` | Detect local toolchain and fleet problems and install approved tools. |
| `fm-startup-network.sh` | Publish bounded deferred session-start network results. |
| `fm-fleet-sync.sh` | Refresh local project clones through guarded fast-forwards. |
| `fm-fleet-snapshot.sh` | Print the read-only fleet snapshot JSON. |
| `fm-fleet-view.sh` | Render the fleet snapshot as Markdown. |
| `fm-guard.sh` | Warn about primary-checkout tangles, queued wakes, and unhealthy supervision. |
| `fm-lock.sh` | Own the per-home Firstmate session lock. |

## Work and secondmates

| Script | Purpose |
| --- | --- |
| `fm-spawn.sh` | Spawn local crewmates, scouts, and local secondmates in tmux. |
| `fm-home-seed.sh` | Provision a local secondmate home and maintain `data/secondmates.md`. |
| `fm-backlog-handoff.sh` | Validate and delegate a backlog item to a local secondmate home. |
| `fm-brief.sh` | Scaffold ship, scout, and secondmate-charter briefs. |
| `fm-send.sh` | Send a verified literal line or supported key through the recorded tmux endpoint. |
| `fm-peek.sh` | Print a bounded tail of a crewmate endpoint. |
| `fm-control.sh` | Control one task's allowlisted lifecycle action. |
| `fm-crew-state.sh` | Print one deterministic current-state line for a crew member. |
| `fm-teardown.sh` | Fail closed while returning landed worktrees and retiring local secondmate homes. |
| `fm-promote.sh` | Promote a scout task in place to a protected ship task. |

## Watcher and durable state

| Script | Purpose |
| --- | --- |
| `fm-watch.sh` | Run the singleton local watcher and queue actionable wakes. |
| `fm-watch-arm.sh` | Arm the home-scoped watcher. |
| `fm-watch-checkpoint.sh` | Run one bounded foreground watcher checkpoint. |
| `fm-wake-drain.sh` | Present and acknowledge durable wakes and open decisions. |
| `fm-check-register.sh` | Bind one intentional custom watcher check to its current bytes. |
| `fm-pr-check.sh` | Record validated pull request metadata and arm a static merge poll. |
| `fm-pr-merge.sh` | Record pull request metadata and merge only with explicit approval. |
| `fm-procevent.sh` | Register, capture, and retire process-to-event sources. |
| `fm-procevent-when.sh` | Fire a trusted deterministic action once when its condition holds. |
| `fm-decision-hold.sh` | Own durable captain-held decision records. |

## Shared libraries

`*-lib.sh` files are sourced helpers.

`fm-backend.sh` and `backends/tmux.sh` own the only supported runtime adapter.

`fm-tmux-lib.sh`, `fm-composer-lib.sh`, and `fm-busy-lib.sh` own tmux delivery and current-state primitives.

`fm-wake-lib.sh` and `fm-classify-lib.sh` own durable wake queue mechanics and classification vocabulary.

`fm-config-inherit-lib.sh` owns material inherited from the primary home into local secondmate homes.
