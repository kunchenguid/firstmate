# Crosscheck

Crosscheck is an on-demand, exact-head PR reviewer. It is independent of
Firstmate task orchestration: any agent or operator that can run the supported
wrapper and read the configured Firstmate home can use it.

Crosscheck does one job. It reviews the current PR head, returns `CLEAR` or
`BLOCKING`, and records cited findings and suspicions against that exact SHA.
It does not rerun CI, manufacture proof scripts, or launch verifier VMs.

## Run it

Use a unique task ID and the full public GitHub PR URL:

```sh
FM_HOME=/Users/dongkeun/firstmate-home \
  bin/fm-crosscheck.sh run <unique-task-id> \
  https://github.com/OWNER/REPO/pull/NUMBER
```

A new task ID needs no pre-created metadata file. Existing state must match the
same task and PR identity or the run fails closed.

The command exits zero only for a valid `CLEAR` verdict on the live head. A
finding, unresolved suspicion, stale head, provider failure, malformed verdict,
or infrastructure failure exits nonzero and is never presented as clearance.

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
