# Retirement and teardown

A secondmate is persistent by default.
An empty queue is healthy and does not trigger teardown.
Run `bin/fm-teardown.sh <id>` for `kind=secondmate` only when the captain or main firstmate explicitly decides to retire that persistent second mate.

The safety check is the secondmate's own home.
Teardown refuses while its `state/*.meta` contains in-flight work.
Non-forced retirement also refuses while any parent pending-reply for that id is still unresolved.
A remote route delegates the in-flight guard to its configured host and additionally refuses while the primary has a pending handoff outbox.
SSH exit 255 preserves the route and local records because remote completion is unknown.
When retirement proceeds, teardown kills the direct endpoint, removes every parent pending-reply record for that id including resolved leftovers and its delivery confirmation, removes the `data/secondmates.md` route, clears the main home metadata, and removes the retired secondmate home.
An endpoint close that could not be made stops the retirement before any record naming that endpoint is removed, so a cleanup never reports success for an agent that may still be live with nothing left on disk naming it.
[`bin/fm-teardown.sh`](../../../../bin/fm-teardown.sh)'s `endpoint_close_refusal` contract owns backend-specific `--force` limits; [endpoint-close verification](../../../../docs/verification/runtime-backends.md#endpoint-close) records what each backend can prove.
Removing a leased home releases its durable treehouse lease via `treehouse return`, so the pool slot is freed for reuse rather than left leased forever.
A plain-clone home with no pool slot is simply removed.
If `treehouse return` fails for a leased home, teardown stops with state intact rather than raw-removing the directory and hiding a held lease.
Before either return or direct removal, teardown asks the target home's process-event runner to retire its registrations and physically owned machine-wide claims through the safe generation-bound path.
It refuses retirement while that cleanup is uncertain or unavailable, preserving the home and retirement records for a later retry.
Raw deletion is unsupported because a blocking process-event child can outlive its home.

With `--force`, teardown is the explicit discard path.
The worktree-slot ownership contract in `bin/fm-teardown.sh` still applies: `--force` never authorizes returning a descendant pool slot that another task may own.
It kills child windows, discards child work and state inside the secondmate home, removes the route, releases the lease, and removes the retired secondmate home.
If forced teardown contends with a fresh task publication in any affected home, one command refuses without publishing or removing task state; treat that refusal as terminal and inspect the other operation before retrying.
`fm-spawn.sh --relaunch` and non-forced teardown remain outside that task-set serialization; [`fm-secondmate-liveness-lib.sh`'s header](../../../../bin/fm-secondmate-liveness-lib.sh) owns automatic recovery serialization.
Never use `--force` unless the captain explicitly said to discard the work.
