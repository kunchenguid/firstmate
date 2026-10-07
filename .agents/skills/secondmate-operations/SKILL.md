---
name: secondmate-operations
description: >-
  Secondmate-only supervisor rules. Load at session start when this home runs under a secondmate charter or the digest lists a registered secondmate, and before routing to, steering, or recovering one.
user-invocable: false
metadata:
  internal: true
---

# Secondmate operations

These are the `AGENTS.md` supervisor rules that apply only while secondmates are in play.
With no registered secondmate and no secondmate charter, none of them apply.
`secondmate-provisioning` still owns creating, seeding, handing off to, syncing, and retiring secondmate homes.

## Routing and home boundaries

- Load `secondmate-provisioning` before managing secondmate homes, charters, handoffs, inherited material, or `data/secondmates.md`.
- Route by registered scope, not clone membership; keep `local-only` work in the main home and never supervise a secondmate's children from there.
- Route in-scope work to the registered secondmate unless blocked or explicitly redirected; `AGENTS.md` section 6 owns home boundaries.
- `secondmate-provisioning` owns secondmate harness pins and inherited local material, while `harness-adapters` owns the harness consequences.

## Steering and replies

- A remote secondmate steer rides the same durable-inbox model through the remote transport; after an unconfirmed delivery, only the exact `FM_PENDING_REPLY_EXISTING_CORR=<id>` resend command printed by `fm-send` is safe because it preserves the request body for remote enqueue deduplication (`bin/fm-send.sh` header).
- A secondmate's routed reply returns through status or a document pointer, not by firstmate peeking into its chat.
- For the parent-owned correlation, recovery, and escalation contract on marked secondmate requests, see `bin/fm-pending-reply-lib.sh`.

## Recovery and supervision

- For a dead secondmate direct report, load `secondmate-provisioning` and reconcile only that secondmate, never its whole child tree from the main home.
- Each secondmate reconciles work already in its own home and then idles; recovery never authorizes it to invent work.
- A `check: secondmate <id> auto-relaunched` wake records a recovery that already completed - reconcile the mate's current state rather than relaunching again, and treat a repeat or a paused-bound wake as the signal to investigate why the mate keeps exiting.
- A secondmate's idle endpoint is healthy, and parent supervision relies on its routed status rather than treating a quiet pane as stale.

## Backlog and briefs

- A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item.
- Work routed to a secondmate is recorded in that secondmate home's own backlog, not the main backlog.
- `secondmate-provisioning` and `bin/fm-backlog-handoff.sh` own cross-home handoff safety.
- Load `secondmate-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-return-channel contracts.
