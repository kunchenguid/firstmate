# STATE.md — firstmate loop memory

The watcher wake loop's durable state (see LOOP.md). The `Last run:` line is
stamped by `bin/fm-wake-drain.sh` on every drain (`FM_LOOP_LOG=0` disables).
Runtime churn in this file is normal; self-update commits it periodically.
Feature branches must not edit this file.

## Watch list

The live watch list is `data/backlog.md` (## In flight) plus `state/<id>.status`
append channels — this file points at them rather than duplicating them.

## Recent noise

(none recorded)

Last run: 2026-08-26T16:57:13Z
