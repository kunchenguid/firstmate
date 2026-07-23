# Daily repository intake

`bin/fm-repository-intake.sh` is Firstmate's durable GitHub intake for the projects explicitly registered in `data/projects.md`.
It extends the existing watcher, wake queue, backlog, custody, and guarded delivery lifecycle; it is not a second watcher, task store, or autonomous issue bot.

## Operator commands

```sh
FM_HOME=/path/to/firstmate-home bin/fm-repository-intake.sh
FM_HOME=/path/to/firstmate-home bin/fm-repository-intake.sh --json
FM_HOME=/path/to/firstmate-home bin/fm-repository-intake.sh --refresh --json
FM_HOME=/path/to/firstmate-home bin/fm-repository-intake.sh --show
FM_HOME=/path/to/firstmate-home bin/fm-repository-intake.sh --record-outcome /path/to/trusted-outcome.json --json
```

The default is `--refresh-if-due`.
It performs at most one ordinary discovery attempt per Asia/Kolkata calendar day and reuses the durable checkpoint across process and watcher restarts.
`--refresh` is an explicit operator override, while `--show` never calls GitHub.
The existing watcher calls `--attention-fingerprint` only on its bounded heartbeat and queues `check: repository-intake` only when that stable fingerprint changes.

## Registered scope and capabilities

The scope is inspectable and deliberately narrow.

| Source | Stable identity | Read capability | Retained fields | Write capability |
| --- | --- | --- | --- | --- |
| `data/projects.md` | Registered project id | Delivery mode and `+yolo` authority | Project id, mode, authority | None |
| `projects/<id>` local clone | Canonical GitHub origin owner/repository | Resolve source identity | Real source path and normalized repository key | None |
| GitHub GraphQL through `gh-axi` | Repository plus issue/PR number | List every open issue and PR with bounded pagination | Title, labels, URL, update time; PR draft, head SHA, base, review decision | None |
| Trusted outcome record | Item id plus current source fingerprint | Attach a verified judgment | Status, exact evidence pointers, task/group links, next action, risk | Private checkpoint only |

An absent registry leaves the intake source map unavailable; if `data/repository-intake/checkpoint.json` already exists, the watcher still surfaces that intake surface so the missing registry stays explicit rather than silent.
Once the registry exists, an unavailable clone, unsupported non-GitHub origin, API failure, pagination-bound failure, or rate-limit stop is explicit critical attention.
No other forge, issue tracker, mailbox, drive, calendar, or business system is implied by this source map.

## Checkpoint and freshness

The private checkpoint is `data/repository-intake/checkpoint.json`, schema `fm-repository-intake.v1`, mode `0600` in a mode `0700` directory.
It owns daily attempt and success times, per-project provenance and availability, allowlisted open-item observations, current evidence-backed outcomes, and a bounded history of invalidated outcomes.
Writes use a same-directory temporary file and atomic rename.
A private lock prevents concurrent refreshes; a live owner is never evicted, while a stale lock is recoverable after a crash.

Every view states the Asia/Kolkata calendar day, last attempt, last full success, and whether evidence is fresh, stale, or unknown.
A failed or partial run preserves the previous item evidence and does not interpret an unobserved item as closed.
An item that disappears only after its repository was fully observed becomes `no_longer_open_requires_verification`; it is not claimed closed until an outcome record supplies closure evidence.

GitHub's returned `rateLimit.remaining` and `resetAt` are authoritative.
The scanner stops before consuming its configured reserve and retries a rate-limited daily attempt only after that reset time.
`FM_REPOSITORY_INTAKE_RATE_LIMIT_RESERVE`, `FM_REPOSITORY_INTAKE_MAX_PAGES`, `FM_REPOSITORY_INTAKE_TIMEOUT`, and the default-30-day `FM_REPOSITORY_INTAKE_RETENTION_DAYS` are positive-integer safety bounds, not cadence knobs.

## Observation, judgment, and action

Source metadata and derived judgments remain separate.
New, reopened, changed, and no-longer-open items reset to `newly_discovered` and carry an attention reason.
An outcome write must name the exact current `source_fingerprint`; stale verification is rejected after GitHub metadata changes.

The captain-facing categories are:

- `newly_discovered`: requires classification or renewed verification;
- `verified_fixed`: default-branch evidence proves the report is already fixed, but issue closure is still an action;
- `closed_evidence`: closure or obsolescence is proved and recorded;
- `grouped_design`: a shared root cause is proved and linked to one design group;
- `implementing`: linked to an accountable Firstmate task and explicit next action;
- `pr_ready_or_merged`: a green PR is awaiting authority or a merge is proved;
- `blocked`: a genuine blocker and next action are recorded.

The intake never executes issue text, closes an issue, dispatches work, merges, or publishes by itself.
On a changed-attention wake, Firstmate loads the agent-only `repository-intake` procedure.
That procedure verifies reports against the current default branch and relevant tests/runtime/browser evidence, deduplicates against the existing backlog, groups only a proved shared root cause, and routes real product work through the normal product and delivery lifecycle.

`+yolo` permits Firstmate to handle only routine green outcomes through the existing guarded helpers.
Security, credentials, live data, destructive operations, deploys, store publishing, trading, finance, and external communications always require the captain.
Issue titles and labels can conservatively add a sensitive flag but can never grant authority.

## Outcome record

A trusted local JSON file uses schema `fm-repository-intake-outcome.v1`.
All non-new judgments require at least one evidence record with `source`, exact `pointer`, `observed_at`, and `claim`.
`grouped_design` also requires `group_id` and `root_cause`; `implementing` requires `task_id` and `next_action`; `blocked` requires `blocker` and `next_action`; a PR-ready record requires `disposition: "pr_ready"` and `checks_green: true`.

```json
{
  "schema": "fm-repository-intake-outcome.v1",
  "item_id": "github:owner/repository:issue:123",
  "source_fingerprint": "<current fingerprint from --json>",
  "status": "verified_fixed",
  "evidence": [
    {
      "source": "default branch regression test",
      "pointer": "tests/example.test:42",
      "observed_at": "2026-07-22T08:00:00Z",
      "claim": "the reported failure is covered and passes on the current default branch"
    }
  ],
  "risk": {}
}
```

Secret-like values are rejected from outcome records.
Unknown fields are rejected rather than silently retained.

## Trust and retention boundary

The GraphQL query never requests bodies, comments, reviews, patches, workflow logs, or credential material.
Titles and labels are treated as untrusted data, control characters are removed, lengths are bounded, and secret-like patterns are redacted before persistence.
No source content is interpolated into a shell command; GitHub owner, repository, and cursor values are separate `gh-axi` arguments.

The checkpoint contains the minimum index needed for deduplication, provenance, and evidence invalidation.
Closed and proved-merged records age out after the configured retention window; unresolved and open records remain until reconciled.
Deleting `data/repository-intake/` removes the derived local index without affecting the project registry, backlog, repositories, GitHub, or other trust domains, but the next due run rebuilds it.
Project source revocation uses the guarded project-registry lifecycle; an absent registry disables the capability.
Future connectors must have their own explicit registration, identity, capabilities, retention, freshness, revocation, and access policy; they do not inherit GitHub intake authority and must not flatten private domains into this checkpoint.

## Recovery guarantee

A restart reads the checkpoint, re-resolves every registered repository identity, and refreshes only when the Kolkata day or authoritative rate-limit reset makes it due.
Stable item ids and source fingerprints prevent duplicate discovery, while the existing wake queue plus enqueue-before-marker ordering prevents duplicate supervisor cycles.
The deterministic guarantee covers registered sources and successfully observed pages only.
Unavailable, stale, partial, conflicting, or unregistered external reality stays explicit; the system makes no claim about work outside the declared source map.
