---
name: pi-supervised-question
description: >-
  Agent-only procedure for a Pi crew question wake whose status names state/questions/<task-id>/<call-id>.request.json or key=ask-<call-id>, including a repeated or stale question after recovery.
user-invocable: false
metadata:
  internal: true
---

# Pi supervised question

Use this only for a Pi crew's versioned supervised-question request.
Ordinary `needs-decision` events continue to follow the existing task and validation lifecycle.

## Handle the request

1. Drain the durable wake queue before reading the request, as required for every wake-handling turn.
2. Derive the task ID and call ID only from the validated relative path in the status event, then read `state/questions/<task-id>/<call-id>.request.json` under the active `FM_HOME`.
3. Confirm that `state/<task-id>.meta` still records `harness=pi` and that the request's `taskId`, `callId`, `protocolVersion`, and deadline match the event and current task.
4. Treat the request questions as the pending decision artifact, not as permission to answer them.
   Existing authority still applies, so escalate captain-owned, destructive, irreversible, or security-sensitive choices and wait for the answer.
5. Build one `answers` entry per question in request order using the exact selected option label.
6. Publish through the guarded helper with answer JSON on standard input:

   ```sh
   printf '%s\n' '<answer-json>' | FM_HOME=<active-home> bin/fm-pi-answer.sh <task-id> <call-id>
   ```

7. Never use `fm-send`, chat injection, direct response-file writes, or an answer to a previous call ID.
   The agent is blocked inside the same tool call, so only the bridge response can resume it safely.
8. Verify that the status log appended `resolved: Pi question answered [key=ask-<call-id>]`, then reconcile the crew's current state and resume the normal supervision cycle.

## Stale or recovered calls

If the guarded helper reports that the owner, bridge, deadline, or resolution is stale, do not retry that call ID.
Run `FM_HOME=<active-home> bin/fm-pi-question-recover.sh <task-id>`, confirm the old request is terminal, and wait for the resumed Pi agent to reissue the question with a new call ID.
An already recorded answer may be summarized through the resumed agent's normal context, but it is never copied into a new response without applying current authority and validating the new options.

Completion requires either a matching keyed `resolved` event followed by continued crew execution, or a concrete captain escalation that preserves the still-pending call without chat injection.
