# Crosscheck

Crosscheck is an exact-head PR reviewer that starts automatically when Firstmate registers a PR-ready task and remains available on demand.
It is independent of Firstmate task orchestration: any agent or operator that can run the supported wrapper and read the configured Firstmate home can use it.

Crosscheck does one job.
It reviews the current PR head, returns `CLEAR` or `BLOCKING`, and records cited findings and suspicions against that exact SHA.
It does not rerun CI, manufacture proof scripts, or launch verifier VMs.

## Run it

The normal Firstmate path is PR-ready registration:

```sh
FM_HOME=/Users/dongkeun/firstmate-home \
  bin/fm-pr-check.sh <task-id> \
  https://github.com/OWNER/REPO/pull/NUMBER
```

Registration records the live PR head, arms the merge poll, durably requests Crosscheck, starts one task-local coordinator, and returns without waiting for the review.
A matching active request is reused, and a matching exact-head and exact-claims `CLEAR` result is verified without another review.
Registering a new head replaces the queued request so the coordinator reviews that head next.
Registration holds the task metadata lock from head capture through poll emission and request publication, so an older capture cannot replace a newer registration.
A short task-local handoff lock couples request publication, status reconciliation, and coordinator retirement; it is never held during review execution.
A dead or failed coordinator releases its task-local lock and retries when the same registration command runs again.
The merge poll observes live GitHub merge state before reporting launcher failures, so manual completion and merge still trigger cleanup without granting merge authorization.
Unrelated task coordinators share no launcher lock, so the Azure lane-capacity and cost-admission controls remain the only review spending authority.

Before launching a review, the coordinator loads the authoritative operator-private fleet environment from `~/.fm-azure/fleet.env` by default.
`FM_CROSSCHECK_FLEET_ENV` may select another absolute file.
The launcher opens that file without following symlinks and requires a current-operator-owned regular file that is not group or world writable.
It sources the already-open file only inside the Crosscheck child, suppresses output from the source operation, and never copies environment values into argv, prompts, logs, repository files, or launcher records.

Missing, unsafe, or incomplete fleet configuration does not undo or fail PR registration.
The task remains honestly uncleared, the actionable failure is recorded in `state/<task-id>.crosscheck-autostart.json` and `state/<task-id>.crosscheck-autostart.log`, and the task check surfaces it for repair and retry.

For an explicit on-demand run, use a unique task ID and the full public GitHub PR URL:

```sh
set -a
. ~/.fm-azure/fleet.env
set +a
FM_HOME=/Users/dongkeun/firstmate-home \
  bin/fm-crosscheck.sh run <unique-task-id> \
  https://github.com/OWNER/REPO/pull/NUMBER
```

The fleet environment is operator-private Azure configuration.
Load it into the process environment; never paste its values into a prompt or command.

A new task ID needs no pre-created metadata file.
Existing state must match the same task and PR identity or the run fails closed.

The command exits zero only for a valid `CLEAR` verdict on the live head.
A finding, unresolved suspicion, stale head, provider failure, malformed verdict, or infrastructure failure exits nonzero and is never presented as clearance.

Results are written to:

```text
$FM_HOME/data/<task-id>/crosscheck.md
$FM_HOME/data/<task-id>/crosscheck-ledger.json
```

The Markdown report is the shareable result. It names the reviewed head, state,
summary, citations, active findings, and timing.

Useful read-only commands:

```sh
FM_HOME=/Users/dongkeun/firstmate-home bin/fm-crosscheck.sh status
FM_HOME=/Users/dongkeun/firstmate-home bin/fm-crosscheck.sh timings <task-id>
FM_HOME=/Users/dongkeun/firstmate-home bin/fm-crosscheck.sh economics <task-id>
```

`verify` prints the reviewed SHA only when the latest exact-head result remains
clear:

```sh
FM_HOME=/Users/dongkeun/firstmate-home \
  bin/fm-crosscheck.sh verify <task-id> <full-pr-url>
```

## Review contract

The trusted controller fetches `refs/pull/<number>/head`, checks it against the
live GitHub API head, resolves the merge base, and builds a bounded read-only
snapshot. The reviewer can search and read that snapshot but has no generic
shell, edit, GitHub, cloud, credential, MCP, or arbitrary network tool.

When the current directory or `$FM_HOME/projects/<repo>` is a matching GitHub
checkout, Crosscheck reuses its content-addressed Git objects. It still fetches
and verifies the live public PR ref; the local checkout is only a transfer cache.

The reviewer must:

- review the exact supplied head;
- cite a repository path and line for every finding or suspicion;
- update known finding lifecycles explicitly;
- call `finish_review` exactly once;
- return `BLOCKING` whenever a new finding, unresolved suspicion, or active
  earlier finding remains.

The controller independently replays the accepted structured tool log. A
missing, multiple, malformed, or contradictory final verdict gets one bounded
fresh repair attempt. A second protocol miss fails closed.

Findings remain in the task ledger across runs. A later exact-head semantic
review can keep one open, mark it claimed fixed, mark it verified fixed, or
close it as equivalent to a fixed finding. Moving the PR head requires a fresh
review; an old clear result never clears a new SHA.

## Reviewer harness

The primary reviewer is Pi running regular GLM 5.2 through the pinned
`fireworks-glm` provider lane. The supported selector is:

```text
accounts/fireworks/models/glm-5p2
```

The reviewer roster lives in the gitignored
`$FM_HOME/config/crosscheck-reviewer.json`:

```json
{
  "reviewers": [
    {
      "harness": "pi",
      "model": "accounts/fireworks/models/glm-5p2",
      "effort": "xhigh",
      "account_home": "/absolute/path/to/crosscheck-pi-home"
    },
    {
      "harness": "codex",
      "model": "gpt-5.6-sol",
      "effort": "xhigh",
      "account_home": "/absolute/path/to/independent-codex-home"
    }
  ]
}
```

The GLM Pi home contains only its pinned `models.json` provider credential.
Codex-family entries are fallback reviewers and are labeled degraded in the
result. Reviewer homes are inspected before dispatch and credentials are not
written into the repository or result.

Pi starts without repository context files or extension discovery. Crosscheck
loads only its tracked verdict extension, which exposes seven bounded tools:
snapshot search/read, finding/suspicion/update reporting, one optional lookup
request, and finalization.

## Ketch lookup

When public upstream context would materially resolve uncertainty, the first Pi
pass may request up to two bounded lookups. The controller runs the installed
Ketch binary against mechanically screened public code or web queries, then
gives the digest-bound result to one fresh final pass. Lookup failure becomes
limited untrusted context, not an infrastructure failure, and lookup can never
read private repository or credential material.

## Azure runtime

Azure uses one reusable reviewer host instead of provisioning a VM for every
review. Up to four local FIFO lanes dispatch independent managed run commands
onto that host. Each dispatch has a random nonce, a unique 24-character review
generation, unique blob names, and a private directory at:

```text
/var/lib/fm-crosscheck-model/<review-generation>
```

The guest removes that directory on exit. The controller removes the managed
run-command child and staged input, credential, snapshot, and output blobs. The
host remains warm for the next review. Concurrent generations never share a
working directory or credential file.

The first run after a clean deployment creates the host from the pinned model
image. Later runs only confirm the existing host identity and submit their
generation, so ordinary latency is snapshot transfer plus reviewer time rather
than VM provisioning and teardown.

The host image, SKU, deployment generation, reviewer account digest, request
digest, result digest, exact head, merge base, and claims digest remain recorded
in the durable identity. Historical disposable-compartment ledgers remain
readable.

Queue capacity is controlled with:

```text
FM_AZURE_CROSSCHECK_LANES=4
FM_AZURE_CROSSCHECK_QUEUE_WAIT_SECONDS=7200
```

`bin/fm-crosscheck-azure.py lanes` reports running and queued local lanes.

## Economics and reuse

Each run records available Pi tokens, declared model cost, reviewer latency,
outcome, finding disposition, lookup use, and phase timings. Provider-reported
cost remains separate from locally calculated cost.

An accepted clear review can be reused without another model request only when
the head SHA, reviewed merge base, stable claims digest, reviewer identity, and
review-contract digest are unchanged. Blocking, suspicious, failed, repaired
state with changed identity, or already reused runs are never used as a shortcut
to clear another head.
