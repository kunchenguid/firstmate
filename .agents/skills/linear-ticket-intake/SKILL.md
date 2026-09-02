---
name: linear-ticket-intake
description: >-
  Agent-only procedure for query-only Linear poll events and agent-owned ticket
  updates. Use before arming the Linear poller and on any
  `procevent linear <source-id> <sequence>` wake. Owns Linear re-fetch,
  duplicate prevention, one-writer assignment, Sol and Luna role separation,
  comment routing, writer transfer, and process-event acknowledgement.
user-invocable: false
metadata:
  internal: true
---

# Linear ticket intake

Use this procedure before arming `bin/fm-procevent-linear.sh` and whenever a `check:` wake carries `procevent linear <source-id> <sequence>`.
Load `process-event-sources` for the shared capture, read, and handled-acknowledgement contract.

The poller is a detector, never a Linear writer.
It may query mapped projects, compare its private observation snapshot, and emit immutable issue ids, identifiers, project names, event types, comment ids, and the API-provided canonical URL.
Never add a mutation to it, give it a ticket-writer lease, or use it as a fallback when an assigned worker cannot reach Linear MCP.

## Arm

Review the private config, then arm the source through its adapter:

```sh
bin/fm-procevent-linear.sh arm config/linear-poll.json
```

The registered command blocks outside the conversational turn and checks every 30 seconds.
An unchanged snapshot prints nothing, so the process-event runner has no result to capture and no wake or model call to create.

## Handle a detected Todo

Read the exact captured result through the adapter:

```sh
bin/fm-procevent-linear.sh read state/procevent-inbox/<source-id>.<sequence>.result
```

Re-fetch the issue through Linear MCP using its immutable id or identifier.
Treat Linear as the source of truth for current status, blockers, project mapping, and canonical URL; reject a mapping mismatch rather than guessing.
Check Firstmate's backlog, live task metadata, and `bin/fm-linear-ticket-writer.sh show <identifier>` before dispatch.
If the issue is blocked, no longer Todo, already leased, or already represented by a live or retained local task, do not create another task.

For a new eligible issue:

1. Create the normal Firstmate ship task and its local backlog record.
2. Choose one persistent Luna implementation worker as ticket owner and create its lease before spawn:

   ```sh
   bin/fm-linear-ticket-writer.sh assign <immutable-issue-id> <identifier> <canonical-url> <task-id> <luna-writer-id>
   bin/fm-linear-ticket-writer.sh owner-brief <identifier> <task-id> <luna-writer-id>
   ```

3. Create a separate Sol planning or review task when needed and apply its no-write brief before spawn:

   ```sh
   bin/fm-linear-ticket-writer.sh planner-brief <identifier> <sol-task-id>
   ```

4. Spawn through the normal Firstmate harness procedure.

The owner brief is the authority boundary.
Luna confirms the exact ticket, checks its lease before every Linear mutation, moves Todo to In Progress, creates or updates exactly one `## Firstmate Workpad`, and records the accepted plan, progress, blockers, PR URL, review results, fixes, and completion state.
Luna may change only its assigned ticket and must report a blocker when Linear MCP is unavailable.
Luna moves the ticket to Human Review only after the project delivery gates pass, and marks it Done only after independently verifying the PR merged.

Sol can plan and review but cannot mutate Linear.
Sol reports findings through Firstmate, and Firstmate steers those findings to Luna so the sole writer records them on the ticket.
Firstmate owns its local backlog and fleet records and must not ask Luna to edit them.

## Handle a detected comment

Re-fetch the comment and issue through Linear MCP.
If the issue has a current writer lease, steer the comment to that Luna task through the durable task inbox instead of creating another task or replying as Firstmate.
If no valid lease exists, reconcile the local task state before deciding whether this is missed intake or stale external activity.
The poll event itself never authorizes a Linear reply.

## Transfer a writer

Two live workers never share write authority.
Stop or revoke the old worker's Linear work first, then transfer explicitly:

```sh
bin/fm-linear-ticket-writer.sh transfer <identifier> <expected-old-writer-id> <replacement-writer-id>
```

The current lease generation and append-only transfer history are the durable authority.
Apply an owner brief for the replacement only after the transfer succeeds.
A stale worker fails `assert-writer` and `assert-target` after transfer.

## Reconcile and acknowledge

Firstmate may read Linear to reconcile status but does not duplicate Luna's comments, Workpad edits, status changes, or completion update.
After the Todo or comment event is fully routed, acknowledge that exact captured sequence:

```sh
bin/fm-procevent.sh handled <source-id> <sequence>
```

Repeated wakes for an already represented issue are a dedupe check, not permission to create another task, lease, or Workpad.
Never merge a project PR without the captain's explicit authority unless the project's separately configured standing merge posture already grants it.
