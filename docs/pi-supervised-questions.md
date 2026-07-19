# Pi supervised questions

This document is the single owner of Firstmate's Pi supervised-question protocol version 1.
The generic Pi capability package owns the matching model-facing `ask_user_question` schema and bridge client.
Firstmate owns only the launch envelope, private state, answer publication, wake lifecycle, recovery, and cancellation described here.

## Launch envelope

`bin/fm-spawn.sh` adds the following variables to every Pi ship and scout launch:

```text
FM_INTERACTION_MODE=supervised
FM_HOME=/absolute/path/to/operational/home
FM_TASK_ID=<task-id>
FM_ASK_BRIDGE=/absolute/path/to/firstmate/bin/fm-pi-ask-bridge.sh
```

Supervised mode is explicit and is never inferred from an interactive terminal.
Pi secondmates retain their existing primary-shaped launch because attended-primary behavior belongs to the separately sequenced primary experiment.
Pi ship and scout spawn refuses before worktree creation when `jq` is unavailable because the Firstmate-owned protocol validator depends on it.

The generic extension spawns `FM_ASK_BRIDGE`, writes one request object to its standard input, propagates its abort signal to the bridge process, and waits for one response object on standard output.
The bridge reserves standard output for the exact tool return and writes bounded errors to standard error with a stable `ASK_USER_*` code.

## Identifier and text bounds

Task, call, and question IDs contain 1 to 64 ASCII letters, digits, dots, underscores, or dashes, and the first character is not a dot or dash.
Each call contains 1 to 4 questions.
Each question contains 2 to 4 options and has a unique question ID within the call.
Each question header is 1 to 40 UTF-8 bytes.
Each question body is 1 to 500 UTF-8 bytes.
Each option label is 1 to 100 UTF-8 bytes and is unique within its question.
Each option description is 0 to 500 UTF-8 bytes.

## Request schema

Requests use this exact version 1 shape with no additional fields:

```json
{
  "protocolVersion": 1,
  "taskId": "task-r1",
  "callId": "call-a1",
  "createdAt": "2026-07-19T12:00:00Z",
  "deadline": "2026-07-19T12:30:00Z",
  "questions": [
    {
      "id": "delivery",
      "header": "Delivery",
      "question": "Which delivery path should continue?",
      "options": [
        {"label": "Direct PR", "description": "Open a PR without the full validation pipeline."},
        {"label": "No mistakes", "description": "Run the full validation pipeline before review."}
      ]
    }
  ]
}
```

`createdAt` and `deadline` are UTC RFC 3339 second timestamps.
The deadline must follow creation, must still be in the future at publication, and must not exceed the bridge's bounded wait limit.
`FM_PI_ASK_MAX_WAIT_SECS` defaults to 86400 seconds and exists for controlled tests and deployments that need a shorter envelope.

## Response schema

Firstmate writes this exact version 1 response shape with no additional fields:

```json
{
  "protocolVersion": 1,
  "taskId": "task-r1",
  "callId": "call-a1",
  "answeredAt": "2026-07-19T12:05:00Z",
  "answers": [
    {"questionId": "delivery", "selectedLabel": "No mistakes"}
  ]
}
```

There is exactly one answer for each question in request order.
Each question ID must match its request entry and each selected label must exactly match one listed option label.
The bridge emits only `{"answers":[...]}` so the blocked Pi tool call receives the model-facing result without protocol metadata.

## Private state paths

For task `<task-id>` and call `<call-id>`, Firstmate uses:

```text
state/questions/<task-id>/<call-id>.request.json
state/questions/<task-id>/<call-id>.response.json
state/questions/<task-id>/<call-id>.owner.json
state/questions/<task-id>/<call-id>.resolution.json
state/questions/<task-id>/<call-id>.lock
```

The `questions` root and task directory are mode `0700`.
JSON files are mode `0600`.
Request and response publication uses a same-directory temporary file followed by an atomic rename.
The mode-`0600` lock file serializes answer publication against timeout, cancellation, and recovery.
It is published with a same-directory hard link only after its process ID and process start identity are complete, so a dead lock can be reclaimed without trusting PID reuse or exposing an ownerless-lock crash window.

The private owner object binds the request to both the Pi process that owns the in-memory tool call and the bridge process waiting for the answer.
It is versioned and contains `protocolVersion`, `taskId`, `callId`, `ownerPid`, `ownerStart`, `bridgePid`, and `bridgeStart`.

The private resolution object contains `protocolVersion`, `taskId`, `callId`, `status`, `resolvedAt`, and bounded `detail`.
Terminal statuses are `answered`, `cancelled`, `timed-out`, `abandoned`, `invalid-request`, and `invalid-response`.
Once a resolution exists, the guarded answer helper refuses every later answer for that call ID.

## Lifecycle

After publishing the owner and request atomically, the bridge appends:

```text
needs-decision: Pi question request state/questions/<task-id>/<call-id>.request.json [key=ask-<call-id>]
```

Status text contains only validated IDs and a relative private path.
The question body stays in the mode-`0600` request file.

Firstmate reads the request and publishes an answer only through:

```sh
printf '%s\n' '{"answers":[{"questionId":"delivery","selectedLabel":"No mistakes"}]}' \
  | FM_HOME=/absolute/home bin/fm-pi-answer.sh task-r1 call-a1
```

The helper requires an explicit `FM_HOME` and validates task ownership, Pi harness ownership, request and call identity, protocol version, freshness, owner liveness, bridge liveness, answer order, and option labels.
It refuses malformed, duplicate, expired, resolved, abandoned, or otherwise stale answers.
It never injects chat into the blocked agent turn.

The bridge waits on a filesystem event when `fswatch` or `inotifywait` is available and always retains a bounded poll fallback.
`FM_PI_ASK_POLL_SECONDS` defaults to one second and exists for tests.
Before every poll it checks cancellation, response publication, owning Pi process identity, and deadline.

After a valid response, the bridge atomically writes `status=answered`, appends the matching status event, and emits the exact tool result:

```text
resolved: Pi question answered [key=ask-<call-id>]
```

An abort signal writes `status=cancelled` and appends a matching keyed `resolved` event.
A passed deadline writes `status=timed-out` and appends a matching keyed `resolved` event.
A dead owning Pi process or dead bridge is not resumable because the original tool call lived only in that process.
Recovery writes `status=abandoned`, refuses late answers for the old call ID, and requires a resumed agent to reissue the question with a new call ID.
Reusing any prior call ID is always rejected, even when the prior request was byte-identical.

`bin/fm-bootstrap.sh` runs idempotent recovery only in the lock-owning mutating startup path.
Detect-only startup never changes question state.
`bin/fm-teardown.sh` cancels pending questions before killing an endpoint and removes that task's private question directory only after normal teardown safety checks pass.

## Verification evidence

On 2026-07-19, the implementation was verified against Pi 0.80.7 and jq 1.7.1 on macOS.
The exact commands were:

```sh
pi --version
jq --version
bash tests/fm-pi-supervised-question.test.sh
bin/fm-lint.sh
```

The version output was:

```text
0.80.7
jq-1.7.1-apple
```

The behavior test covers a published crew question, wake status, guarded Firstmate answer, exact tool return, matching resolution, process death with a pending request, stale-answer refusal, reissue under a new call ID, malformed answers, timeout, cancellation, startup recovery, and launch-envelope wiring.
The recorded behavior-test output was:

```text
ok - Pi bridge publishes a crew question, accepts one guarded answer, returns exact tool JSON, and resolves once
ok - guarded and direct malformed answers fail without leaving the tool call polling
ok - process death abandons the old call, rejects late answers, and permits only a new-call reissue
ok - owner death, timeout, and cancellation all terminate with durable resolution
ok - startup recovery abandons dead Pi calls only in the mutating lock-owning path
ok - Pi launch, startup, and teardown wiring preserve the supervised-question lifecycle
```

The recorded lint output was:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```
