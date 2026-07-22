# results-first-delivery

Agent-only skill: implements and supervises the Firstmate results-first
delivery lifecycle.

## When to load

Load this skill before:
- Authoring or reviewing `bin/fm-delivery-*.sh`, `bin/fm-evidence-run.sh`,
  `bin/fm-lane-reserve.sh`, `bin/fm-rollout-embargo.sh`, or delivery tests.
- Changing `bin/fm-project-mode.sh`, `bin/fm-brief.sh`, `bin/fm-teardown.sh`,
  or `bin/fm-crew-state.sh` to integrate results-first behavior.
- Deciding whether a ship task has completed under the results-first path.
- Updating `docs/delivery-lifecycle.md` or `AGENTS.md` delivery trigger text.

## Core rules

1. A ship task is complete only when `data/<id>/delivery-receipt.json` exists and
   passes `bin/fm-delivery-receipt.sh validate <id> receipt`.
2. Phases advance monotonically through `bin/fm-delivery-phase.sh`. A blocked
   phase records a reason and a later `resume` clears it.
3. Evidence is write-once and hashed via `bin/fm-evidence-run.sh`. Never re-run
   an evidence step that already produced a manifest hash; reference the
   existing manifest instead.
4. Receipts and in-flight records are redacted for volatile provider fields
   before validation or hashing.
5. `bin/fm-teardown.sh` refuses to tear down a results-first task without a
   finalized receipt, unless `--force` is explicitly authorized.
6. Crew state for delivery tasks is authoritative from
   `state/<id>.delivery.json`; do not infer state from pane liveness or the
   last status line alone.

## Delivery modes

- `direct-PR +yolo` (default for newly registered projects): the worker pushes a
  branch, opens a PR, then runs deterministic validation/release/deploy/smoke
  from the landed source and finalizes a receipt.
- `local-only`: same as direct-PR but no remote/PR; the ready branch is merged
  locally by the configured merge authority through the guarded fast-forward
  path.
- `no-mistakes`: legacy opt-in only. Run the one bounded legacy `no-mistakes`
  pipeline, then continue the results-first path to finalize a receipt. Do not
  use no-mistakes for new projects.

## Lane and embargo

- Only one `primary` lane lease per firstmate home. A `support` lease must link
  to an existing primary.
- A rollout embargo generation is write-once. It lists `permitted` and
  `forbidden` task ids. Use it to prevent resumption of parked GLX initiatives
  during a cutover.

## Failover checkpoint

The provider-failover checkpoint SHA
`6815f216a8d24bce20a2c2fe6245fe3d270c64da` is preserved in
`bin/fm-dispatch-select.sh`. It gates TTL expiry, launch-pressure refusal, and
paused-worker stale suppression.

## Test contract

Every change to a delivery tool must have a deterministic test in `tests/`
using only `bash`, `python3`, and temporary directories. Do not add `jq` or
other JSON dependencies. Run `bash -n` on every modified script and the full
`tests/*.test.sh` suite before committing.
