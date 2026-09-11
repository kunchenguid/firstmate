# Antigravity CLI

Antigravity CLI `agy` is a verified worker adapter for CREWMATE and SCOUT tasks only.
`bin/fm-spawn.sh` refuses `--secondmate` on `agy` because no primary supervision protocol is verified.

## Operating contract

- `agy` is resolved from `PATH` and refused when absent.
- The canonical launch, model and effort flags, private hook root, and brief submission are owned by `bin/fm-spawn.sh`.
- The adapter clears inherited Antigravity and foreign-harness markers before launching a worker.
- Child and tool processes export `ANTIGRAVITY_AGENT=1`, while exact `agy` ancestry identifies the launcher process.
- Firstmate-owned `PreInvocation` and `Stop` hooks provide the semantic busy source, while `PostToolUse` refreshes the shared progress marker; all are retired with the task.
- An agy Escape interruption has no verified cancellation acknowledgement, so control and data interruption paths preserve an unconfirmed semantic state.
- The shared composer classifier owns agy prompt recognition, draft preservation, multiline extraction, and cursor or cursorless capability handling.
- Raw agy launches remain unwired and classify as unknown.
- The exact current measurements and refresh commands are maintained in [`docs/verification/agy.md`](../../../../../docs/verification/agy.md).

## Boundaries

`references/common/primary-hooks.md` is intentionally out of scope for this worker-only adapter.
The adapter's executable mechanics are owned by the scripts named above and their help output.
