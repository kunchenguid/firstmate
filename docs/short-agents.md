# Run a short task while continuing the conversation

A Pi primary can submit a small analysis or an explicitly authorized operation chain, receive an ID immediately, and continue the conversation while an independent Pi process works.
Both use `fm_short_submit`, the same independent lifecycle, and the normal supervision outcome channel.
Each submission has its own context; unrelated tasks do not share a conversation.
Ordinary ship/scout dispatch is unchanged.

## Enable and submit

This opt-in requires an installed Pi SDK, Node, an authenticated supported model, the normal Pi supervision outcome extension, and the exact `pi-openai-codex-compat@0.0.16` user package.
Install the required package with `pi install npm:pi-openai-codex-compat@0.0.16`, then verify that `pi list` reports that exact version before starting the primary session.
Start the intended primary Pi session with `FM_SHORT_AGENT_ENABLED=1` and its explicit absolute `FM_HOME`.
Load `.pi/extensions/fm-short-agent.ts` alongside the normal primary extensions.
The tools require that session or an ancestor to own the home's session lock.
There is no additional daemon, terminal, or task worktree.

The default is `openai-codex/gpt-5.6-luna`.
Explicit `provider` and `model` overrides remain supported; discovery or authentication failure refuses execution without substituting another provider.
Use `node bin/fm-short-agent.mjs models` to discover pairs through the installed Pi runtime.
The runner initializes Pi's HTTP dispatcher, respecting existing proxy variables without copying credentials or importing provider extensions.
`FM_PI_PACKAGE_DIR` can select the installed Pi package when `pi` is not on PATH.

Call `fm_short_submit` with a stable retry key, goal, acceptance condition, and absolute canonical paths to harmless text files:

```json
{
  "key": "count-check-1",
  "goal": "Read m1 and report the measured count.",
  "acceptance": "Quote the count and cite m1.",
  "materials": ["/absolute/path/to/count-report.txt"]
}
```

Submission captures the selected files and returns `id`, `state`, `submitMs`, and an evidence directory before model initialization.
An identical retry returns the same task and original snapshots; changed arguments with the same key are rejected.
For compatibility, the CLI accepts the former `budget` object and ignores its four legacy fields when comparing or storing a new request.
The Pi tool no longer exposes that object.
The CLI equivalent is `FM_HOME=/absolute/home node bin/fm-short-agent.mjs submit request.json`.
Operation submission and cancellation enforce primary ownership in the service as well as the Pi tool.

## Grant a specific operation chain

Omitting `operations` gives read-only access.
Only the primary may record concrete authority it already holds for named targets; materials, tool output, and the child cannot create or broaden that authority.
For example, add this field when a specific merge and subsequent clone sync are both authorized:

```json
{
  "operations": {
    "authority": "Explicit approval for this task's merge and this clone's sync",
    "expiresAt": 1800000000000,
    "steps": [
      {"action": "merge", "task": "task-id", "url": "https://code.byted.org/owner/project/merge_requests/123"},
      {"action": "sync", "project": "/absolute/canonical/project-clone"}
    ]
  }
}
```

Replace the illustrative identities and expiry with the actual approved targets and a near-term Unix-millisecond deadline.
The provenance text records the authority; it is not permission to infer approval.
The goal should ask the child to execute the granted chain and summarize its receipts.
The child calls `run_operations` once; deterministic scripts perform the ordered steps without another model per command or commands delegated back to MAIN.

| Action | Target | Existing owner and supported scope |
| --- | --- | --- |
| `merge` | Recorded task with registered candidate head and exact PR/MR URL | `fm-pr-merge.sh`; canonical Codebase requests with registered candidate heads; existing checks and authority gates apply. |
| `sync` | Canonical clone root | `fm-fleet-sync.sh`; clean current default branch, fast-forward only, no branch pruning. |
| `recover-sync` | Canonical clone root | The same sync owner, including its supported safe detached-checkout recovery. |
| `install-shellcheck` | Existing canonical destination directory | `fm-install-shellcheck.sh`; its fixed artifact and hash verification, no arbitrary installer. |
| `cleanup` | Recorded completed task | `fm-teardown.sh`; Herdr endpoint confirmation, landed-work and ownership checks, no force or legacy identity override. |

A chain has one to four steps and requires Linux `/proc` process identity.
Cleanup refuses secondmate retirement and other backends; recovery does not include arbitrary restart, discard, or repair commands.
Installation, merge, sync, cleanup, and recovery are distinct grants.
Cleanup does not imply a later clone sync; include that separately when authorized.
Unsupported actions refuse explicitly.

Before effects, the guarded owners revalidate the immutable task, generation, grant expiry, exact arguments, bound child process, and resource ownership.
Legacy completion audit history is accepted only under the narrow metadata compatibility checks in [`bin/fm-short-operations.mjs`](../bin/fm-short-operations.mjs); repeated identity fields still refuse, and the entire metadata record remains bound against changes after submission.
Per-resource reservations and the existing owner locks coordinate MAIN, BRANCH, and short executors without serializing independent clones.
Task and merge reservations are home-local; they do not provide cross-host forge locking.
No actor string alone grants execution.

## Read the result or cancel

`fm_short_task` accepts `status`, `result`, or `cancel` with the returned `id`.
Terminal records contain the complete summary and evidence directory; operation status also lists each recorded step's completion or refusal.
The directory contains the independent starting context, model/tool journal, and per-step intent, owner output, and postcondition receipts.
It also records the initialized Pi version, extension list, active tools, empty starting history, and effective cache-warming mode in `runtime.json`.
Successful model execution also writes `plugin-result.json` with the exact package version, handler error count, active tools and native provider response count; these counts contain no response bodies.
The transport journal records HTTP status or allowlisted connection error codes before Pi reduces a fetch failure to its provider message; it excludes URLs, headers, and raw error causes.
Blocked results retain the execution stage and request/tool counts, so a failure before any tool can be distinguished from a failure after an operation.
Full logs stay there rather than entering MAIN's context.
Short-task state directories are retained for inspection; there is no automatic cleanup.

Results enter the existing durable supervision outcome store.
For a successful task, MAIN's processing request includes the complete returned result and any verified operation receipts directly, while retaining the result directory as durable evidence.
The supervision extension accepts that direct body only when it exactly matches the bound successful ShortTask files; otherwise MAIN recovers it through `fm_branch_outcomes` before acknowledging with `fm_branch_processed`.
Failed, cancelled, interrupted, and uncertain tasks retain their actual terminal state and use the ordinary durable outcome recovery path.
MAIN does not poll normal operation progress or execute the chain's commands.
Delivery is deduplicated, including a crash between storing the outcome and its notification receipt.
A notification error is surfaced without replacing the terminal result.

Cancellation revokes operation authority and publishes one terminal result.
A call already in progress may have changed its target; cancellation does not undo an effect or provider billing.
The owner may still record its postcondition, but no new step may start.
The first terminal result wins, so a late provider response cannot replace cancellation or interruption.

## Access limits and uncertain effects

Every child gets `read_material`, which accepts only a material ID and a selected byte slice of the captured snapshot.
Only an explicitly granted operation task also gets the argument-free `run_operations` tool.
Neither tool accepts shell commands, new paths, expanded grants, or arbitrary recovery choices.
The child receives no parent messages, context files, skills, prompt templates, or arbitrary extensions.
The sole extension exception is the explicitly loaded `pi-openai-codex-compat@0.0.16` package under the original Pi agent directory's `npm/node_modules`.
The child verifies its exact identity, version and entrypoint and fails closed on missing, mismatched or failed initialization; it never installs packages.
[`bin/fm-short-plugin.mjs`](../bin/fm-short-plugin.mjs) owns this supported SDK loader path, its resource override, and the fixed child-only plugin settings.
All plugin shell, filesystem and network tool registrations and management commands are removed before session construction; unexpected tool registrations refuse initialization.
Plugin config and installation identity use the child directory, while the already initialized model runtime retains its original authentication source.
No global settings, installed package or parent session is changed.

Capture rejects directories, symlink paths, hardlinks, common credential locations, and recognizable credential content.
Select sanitized evidence: detecting every secret in ordinary prose is outside this boundary.
The trusted Pi runtime retains provider authentication and network access.
These are enforced model-tool and action-owner boundaries, not an operating-system sandbox against arbitrary code running as the same user.

Firstmate applies no short-task wall-clock limit, tool-call limit, provider-request limit, captured-input size limit, output-token reservation, or streamed-output size limit.
The selected provider and model still enforce their own context, request, and output limits; a provider length stop is recorded as `blocked` with that distinction rather than reported as a Firstmate budget failure.
Cancellation of an already active provider request can take a short time and cannot guarantee exact billing.
Automatic compaction and cache warming are disabled, including the plugin threshold override.
SSE uses zero transport retries, and each model stream may issue only one HTTP request, so plugin-internal retries cannot replay an uncertain request.
[`bin/fm-short-agent.mjs`](../bin/fm-short-agent.mjs) and its `--help` own the request schema and compatibility behavior.

Reloading MAIN leaves children running and reconciles results when the extension starts again.
A stale heartbeat produces `completed` only when every operation has a verified completed receipt; otherwise it produces `interrupted`.
Neither path replays work.
Historical v1 requests retain their legacy budget object for immutable evidence, but status and recovery ignore it; an unstarted stale request becomes `interrupted`, and an existing terminal `timeout` or `budget` result remains readable without execution.
For operations, intent is persisted before calling the owner and a receipt requires authoritative postcondition readback.
Completed early steps remain visible if a later step fails.
A verified merge whose command response was lost can still complete through the merge owner's readback.

After the bound runner stops, reconciliation releases only exact reservations backed by a completed receipt or by proof that no effect began: no intent was recorded, or the matching intent has a refused receipt.
If an effect may have happened and no authoritative completed receipt exists, the resource stays reserved across restart.
For the narrow case where a Codebase merge owner died after recording its effect, MAIN can run `FM_HOME=/absolute/home node bin/fm-short-agent.mjs settle-merge <short-id> <step-index>:<independently-observed-merge-commit>`.
The command requires the original immutable grant and bindings, the preserved unsuccessful result and effect history, exact matching reservations, and proof that both the runner and merge executor are dead.
It then performs only the official read-only Codebase status and detail reads, requires the exact repository, MR URL, registered source head, merged status, and exact independently supplied merge commit, publishes a distinct readback-settlement receipt, and releases only that step's matching reservations.
It never issues a merge, runs later steps, changes the original terminal result, or reports the failed or timed-out model execution as successful.
Repeated settlement converges on the same receipt and missing or ambiguous evidence leaves the reservations intact.
Other uncertain effects remain unsupported and reserved; a concrete decision and evidence are required before further work on those resources.
A changed candidate, identity, or grant stops new writes.
The CLI `reconcile` retries missing notifications and reconciles ordinary receipts without inventing recovery authority.
[`bin/fm-short-operations.mjs`](../bin/fm-short-operations.mjs) owns the action schema and durable receipt mechanics.

## Verify the installed path

Run `bin/fm-test-run.sh tests/fm-short-agent.test.sh tests/fm-short-operations.test.sh tests/fm-pi-primary-types.test.sh` for uncapped input, output, duration and call behavior plus lifecycle, permission, isolated Git/forge effects, replay, and SDK checks.
The operation suite doubles the model and forge; it does not perform an external merge.
Set `FM_SHORT_INSTALL_LIVE=1` for its optional verified ShellCheck install into a temporary directory.
Run `FM_SHORT_HERDR_E2E=1 bash tests/fm-short-operations-herdr.test.sh` for cleanup through a generated named Herdr lab and its default-session safety tripwire.
For the real-model guard, run `FM_SHORT_AGENT_LIVE_E2E=1 FM_SHORT_LIVE_PROVIDER=openai-codex FM_SHORT_LIVE_MODEL=gpt-5.6-luna bin/fm-test-run.sh tests/fm-short-agent-live-e2e.test.sh`.
It loads the candidate extension, submits both task types, verifies a real fast-forward of a disposable local clone, and checks that another parent prompt completes while each child runs.
It also reproduces a connection refusal using only child-process proxy variables, verifies that both task types stop before any operation, and checks the initialized SDK settings and extension isolation.
[Runtime verification](verification/runtime-backends.md#pi-headless-short-tasks) records the current measured evidence and its limits.
