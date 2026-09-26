# Run a read-only short task without holding the main conversation

A Pi primary session can explicitly submit a small analysis, receive an ID immediately, and continue the conversation while a separate Pi process reads selected evidence.
For example, submit one text report and ask for its measured count; the child reads a captured copy and returns a short answer with an evidence pointer.
Full logs stay in the task directory rather than entering MAIN's context.
Ordinary ship/scout dispatch is unchanged.

## Enable and submit

This opt-in requires an installed Pi SDK, Node, a supported authenticated model, and the normal Pi supervision outcome extension for delivery into MAIN.
Start the intended primary Pi session with `FM_SHORT_AGENT_ENABLED=1` and its explicit absolute `FM_HOME`.
Load the tracked `.pi/extensions/fm-short-agent.ts` alongside the normal primary extensions.
The submit and control tools require that session or an ancestor to own the home's session lock.
The feature adds no daemon and does not change existing fleet routing.

Use `node bin/fm-short-agent.mjs models` to discover provider/model pairs through the installed Pi authentication runtime.
The runner uses Pi's declared SDK entry and initializes Pi's HTTP dispatcher in its own process, respecting existing proxy environment variables.
It does not copy credentials or load provider extensions.
If a provider requires a custom extension, this first version refuses unavailable discovery/auth rather than importing the parent's extensions.
`FM_PI_PACKAGE_DIR` can explicitly select the installed Pi package when `pi` is not on PATH.

Call `fm_short_submit` with a stable retry key, goal, acceptance condition, explicit provider/model, and absolute canonical paths to up to four harmless text files.
For an illustrative count check, the arguments are:

```json
{
  "key": "count-check-1",
  "goal": "Read m1 and report the measured count.",
  "acceptance": "Quote the count and cite m1.",
  "provider": "<provider from models>",
  "model": "<model from models>",
  "materials": ["/absolute/path/to/count-report.txt"],
  "budget": {"timeMs": 120000, "tools": 8, "outputTokens": 2048, "requests": 4}
}
```

Submission persists acceptance and returns `id`, `state`, `submitMs`, and an evidence directory before model initialization.
A repeated key with identical arguments returns the same task; changed arguments with the same key are rejected.
The original file snapshots remain authoritative on a retry.
The command-line equivalent is `FM_HOME=/absolute/home node bin/fm-short-agent.mjs submit request.json`.
The CLI is a task-local operator interface; the Pi tool supplies the primary-session ownership check.

## Read the answer or cancel

Call `fm_short_task` with the returned `id` and `action` set to `status`, `result`, or `cancel`.
Status and result return the same bounded current record; terminal results include the summary and evidence directory.
Detailed reads and model messages are in that directory's `journal.jsonl`; `context.json` records the exact independent starting context.
The child receives no parent messages, context files, skills, prompt templates, or arbitrary extensions.

Completion and failures enter the existing durable supervision outcome store.
MAIN reads and acknowledges them through the normal `fm_branch_outcomes` / `fm_branch_processed` flow.
The notification's task identity is deduplicated, including retries after a crash between storing the outcome and storing its receipt.
The existing outcome store remains authoritative for delivery and acknowledgement.

Cancellation publishes a terminal result that the child observes before further tool/model calls and on its next timer tick.
An already active provider request can take a short time to stop; cancellation does not undo provider billing.
The first terminal result wins, so a late success cannot replace cancellation, timeout, or interruption.

## Access limits and recovery

The model has exactly one executable tool: `read_material` reads a bounded byte slice from an immutable selected-file snapshot by material ID.
It cannot supply filesystem paths, execute commands, edit files, call network tools, load extensions, or spawn another agent.
Capture rejects directories, large files, symlink paths, hardlinks, common credential locations, and recognizable credential content.
Select sanitized evidence: detecting every secret embedded in an otherwise ordinary text document is outside this boundary.
The trusted Pi runtime retains provider authentication and network access; this is a model-tool capability boundary, not an operating-system sandbox against a compromised SDK or another process running as the same user.

Wall time, tool calls, provider requests, and reserved output tokens are bounded.
Output reservations are conservative: each request reserves up to 1024 tokens, and unused allowance is not refunded.
Some transports ignore the upstream output limit, so the runner also stops when streamed text, reasoning, and tool-argument bytes exceed the output allowance; this deliberately conservative byte guard can stop before that many tokens.
An abort cannot guarantee a precise upstream billing cap.
Input is bounded by goal/material/read byte limits; the output allowance is not a total billed-token cap.
The runner disables automatic provider retries, compaction, and cache warming.
Exact request limits and persisted lifecycle mechanics are owned by [`bin/fm-short-agent.mjs`](../bin/fm-short-agent.mjs) and its `--help`.

Reloading MAIN leaves children running and reconciles their durable results when the opt-in extension starts again.
An expired child heartbeat becomes `interrupted`; an expired wall deadline becomes `timeout`.
Neither path replays uncertain model work or signals an unverified process ID.
After a stopped primary returns, its extension retries missing notifications; the operator equivalent is the CLI `reconcile` command.
A notification error is surfaced without replacing the terminal result.

This first version creates a small state directory per task and retains it for inspection; it has no automatic cleanup or general scheduling service.
Submission still validates and snapshots bounded materials in MAIN, and MAIN still reviews the result.
It therefore reduces execution work without claiming to offload all coordination or context cost.

## Verify the installed path

Run `bin/fm-test-run.sh tests/fm-short-agent.test.sh tests/fm-pi-primary-types.test.sh` for portable lifecycle, permission, replay, and API checks.
For the real-model guard, choose a discovered pair and set `FM_SHORT_AGENT_LIVE_E2E=1`, `FM_SHORT_LIVE_PROVIDER`, and `FM_SHORT_LIVE_MODEL`, then run `bin/fm-test-run.sh tests/fm-short-agent-live-e2e.test.sh`.
It uses an isolated temporary home and harmless fixture, submits through the loaded Pi tool, runs a second parent prompt while the child is active, and checks the child's real read and exclusion of a parent-only sentinel.
It uses no Herdr session or live fleet records.
