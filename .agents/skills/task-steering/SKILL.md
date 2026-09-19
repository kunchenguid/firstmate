---
name: task-steering
description: >- Agent-only reference for steering a live worker and driving its lifecycle. Load before sending ordinary text to a worker, resending after an unconfirmed remote delivery, closing an open keyed decision with an answer, or interrupting, exiting, or relaunching a worker.
user-invocable: false
metadata:
  internal: true
---

# task-steering

This skill is the single owner of the full steering and lifecycle-control
mechanics, including the remote-secondmate transport and pending-reply
correlation contract.
`AGENTS.md` section 7 owns only the always-loaded command names and the
never-mix-planes boundary.

Steer a worker with ordinary text through fail-closed `fm-send`: the message becomes a durable record in the task's steering inbox (multi-line text is legal, local and remote alike) and the worker's terminal receives only a constant doorbell line, with the watcher re-ringing an unacknowledged local message and escalating a stuck one (`../../../bin/fm-task-inbox-lib.sh`; `../../../bin/fm-send.sh` owns the typed-plane carve-outs).
A remote secondmate steer rides the same durable-inbox model through the remote transport; after an unconfirmed delivery, only the exact `FM_PENDING_REPLY_EXISTING_CORR=<id>` resend command printed by `fm-send` is safe because it preserves the request body for remote enqueue deduplication (`fm-send.sh` header).
When a steer answers an open keyed decision or blocker, pass `fm-send`'s `--resolve-key` so the answer itself closes that decision record at answer time, identically for local and remote workers (contract: `fm-send.sh` header).
`fm-send` is the data plane for text the worker should read; never use its key or text paths for interrupt, exit, or other lifecycle control, because routing-marked lifecycle text becomes chat the worker reasons about instead of executing.
Drive a worker's lifecycle through `../../../bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which owns the per-runtime mechanics, verifies each action, and never tears down or discards anything (`../../../docs/agent-control.md`).
A secondmate's routed reply returns through status or a document pointer, not by firstmate peeking into its chat.
For the parent-owned correlation, recovery, and escalation contract on marked secondmate requests, see `../../../bin/fm-pending-reply-lib.sh`.
