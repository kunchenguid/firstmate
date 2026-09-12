# Antigravity CLI

Antigravity CLI `agy` is a verified worker adapter for CREWMATE and SCOUT tasks only.
`bin/fm-spawn.sh` refuses `--secondmate` on `agy` because no primary supervision protocol is verified.

## Operating contract

- `agy` is resolved from `PATH` and refused when absent.
- The canonical launch, model and effort flags, private hook root, and brief submission are owned by `bin/fm-spawn.sh`.
- AGY dispatch profiles accept low, medium, high, and xhigh effort; xhigh maps to high and max is rejected by crew-dispatch validation.
- The adapter clears inherited Antigravity and foreign-harness markers before launching a worker.
- AGY identity is marker-only (`ANTIGRAVITY_AGENT=1`); generic liveness may still accept an exact `agy` foreground process in the recorded pane, but that process name never establishes harness identity.
- Firstmate-owned `PreInvocation` and `Stop` hooks provide the semantic busy source, while `PostToolUse` refreshes the shared progress marker; all are retired with the task.
- An agy Escape interruption has no verified cancellation acknowledgement, so control and data interruption paths preserve an unconfirmed semantic state.
- The shared composer classifier owns agy prompt recognition, draft preservation, multiline extraction, and cursor or cursorless capability handling.
- Non-tmux composer reads use a bounded 200-row tail for agy so both measured boundaries survive long drafts; other harnesses retain the normal 20-row tail.
- The inbox doorbell defers both pending and unknown agy composer verdicts and rings only after a proven empty result; the watcher records the deferral and retries.
- Typed AGY steering compares the extracted composer with the literal text before Enter; a mismatch withholds Enter, records the steer in the inbox, and reports that stray text may remain unsent in the pane.
- AGY exit records a pending composer in the line-oriented status log by doubling literal backslashes and replacing newlines with the two-character sequence `\n`.
- AGY exit records any pending composer text, clears it with the measured C-u key, requires a proven empty composer, and then submits `/quit`; unknown or uncleared input remains a loud refusal.
- The remaining sub-second race between preflight and literal typing is shared with every typed harness path; no exclusive input reservation is provided, a human typing in this window can leave firstmate's text unsent alongside their draft, Enter is never pressed on a mismatch, and the durable inbox record is the recovery copy.
- Assignment forms of `ANTIGRAVITY_AGENT` (`ANTIGRAVITY_AGENT=`, `export`, `declare`, or `typeset`) are refused in raw launch commands, a bare marker name used as an argument value is allowed, and the launch boundary scrubs the variable firstmate provides.
- Raw commands whose basename is `agy` are recorded as `raw-agy`, remain unwired, and classify as unknown.
- The exact current measurements and refresh commands are maintained in [`docs/verification/agy.md`](../../../../../docs/verification/agy.md).

## Boundaries

`references/common/primary-hooks.md` is intentionally out of scope for this worker-only adapter.
The adapter's executable mechanics are owned by the scripts named above and their help output.
