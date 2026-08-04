# Fleet data contracts

Firstmate's durable records are produced by one script each and consumed by many.
This page owns the field-ownership map across those producers and consumers.
Exact flags, exact commands, and exact paths stay in each script's header and `--help`; the schemas themselves live in [`bin/fm-outcome-lib.sh`](../bin/fm-outcome-lib.sh), which is the single owner of every wire shape described here.

Three artifacts carry the contract.

| Artifact | Schema | Producer | Lifetime |
| --- | --- | --- | --- |
| `data/<id>/outcome.json` | `fm-outcome-manifest.v1` | [`bin/fm-outcome-manifest.sh`](../bin/fm-outcome-manifest.sh) | durable, survives teardown |
| `data/<id>/work-items.json` | `fm-work-items.v1` | [`bin/fm-work-item.sh`](../bin/fm-work-item.sh) | durable, survives teardown |
| `state/<id>.pr-status` | `fm-pr-status.v1` | [`bin/fm-pr-status.sh`](../bin/fm-pr-status.sh) | volatile, removed by teardown |

[`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh) is the read-only projection that exposes all three, plus live task state, as schema `fm-fleet-snapshot.v1`.

## Why a manifest exists

`state/<id>.meta` is the only structured record of a task's dispatch, and teardown removes it.
The backlog's Done section is pruned to a configured recent window.
Before this contract, a task that finished and was cleaned up left nothing structured behind except a scout report, so nothing could attribute its usage, ingest its outcome, or show it in history.

The manifest closes that gap: teardown publishes it atomically before removing the volatile records it is composed from.
A task that cannot be archived is not erased - [`bin/fm-teardown.sh`](../bin/fm-teardown.sh) refuses the cleanup and keeps every record for a retry, because the manifest is the only thing that survives.

## Manifest field ownership

Every field is composed from a record that already exists at completion time.
The manifest never contacts a forge and never reads a brief, a prompt, a tool argument, or a credential-bearing artifact.

| Field | Source of truth | Notes |
| --- | --- | --- |
| `schema`, `task_id`, `home`, `recorded_at` | the writer | identity and provenance of the record itself |
| `title` | the task's structured backlog row | metadata, URLs, and report pointers stripped; null for secondmates because they are not backlog items |
| `project`, `kind`, `mode`, `yolo` | `state/<id>.meta` | the delivery contract the task shipped under |
| `harness`, `model`, `effort` | `state/<id>.meta` | the dispatch decision, retained for usage attribution |
| `timestamps.*` | see below | each value's provenance is named in `timestamp_sources` |
| `outcome.state` | the last terminal status event, the task kind, or the teardown mode | `done`, `failed`, `discarded`, `retired`, or `unknown` |
| `outcome.detail` | that event's note | single-line, control characters stripped, length capped |
| `outcome.forced` | the teardown invocation | true when cleanup discarded work under explicit authority |
| `pr.url`, `pr.provider`, `pr.host`, `pr.path`, `pr.number` | `state/<id>.meta`, parsed by `bin/fm-pr-lib.sh` | forge-agnostic identity, GitLab paths may nest |
| `pr.head` | `state/<id>.meta`'s recorded `pr_head` | validated as a SHA or dropped |
| `pr.status.*` | the cached observation, see [Normalized PR state](#normalized-pr-state) | never refreshed at write time |
| `report.path`, `report.present` | `data/<id>/report.md` | the scout deliverable pointer |
| `attribution.*` | `state/<id>.meta` | the references a later usage read needs, see below |
| `work_items` | `data/<id>/work-items.json` | embedded so the manifest is self-contained |
| `gbrain` | `state/<id>.gbrain`, an optional provider | `status` is `absent` when no provider wrote one |

### Timestamps and their provenance

The records firstmate keeps do not all carry an explicit stamp, so the manifest names where each value came from instead of implying a precision it does not have.

- `created` comes from the brief's mtime (`brief_mtime`), falling back to the backlog row's `since` date at UTC midnight (`backlog_since`).
- `started` comes from the task metadata's mtime (`meta_mtime`), which spawn writes.
- `completed` is the write time (`manifest_write`) unless the caller pins one (`explicit`).

A future explicit recorded stamp can supersede any of these without a schema change: only the `timestamp_sources` value moves.

### Attribution after teardown

`attribution` retains what a delayed usage read needs once the task's runtime is gone: the backend, the endpoint target and its task id, the worktree, the per-task temp root, the trace context when trace propagation is enabled, and the secondmate home for a retired secondmate.
The project it ran against is the top-level `project` field, recorded once so the two can never disagree.
Together with `harness`, `model`, and `effort` these are enough to attribute a session's token usage to a task that no longer exists.

## Work-item references

Most tasks trace back to an issue in the **managed project's** tracker, not in this repository, so the reference is forge- and host-agnostic.
A task may carry several references or none.

Each reference stores the canonical URL plus the parsed `forge`, `host`, project `path`, `owner`, `repo`, `number`, and item `kind`.
`owner` is everything before the last path segment, so a nested GitLab group round-trips as faithfully as a two-segment GitHub path.
An unrecognized host stores `forge: "unknown"` rather than being rejected or guessed at, and an explicit forge override is available for a self-hosted instance.

`origin` marks each reference as `intake` (declared by the captain or the brief) or `pr-linked` (derived later from a PR's linked-issue metadata).

`enrichment` carries `title`, `state`, `observed_at`, and `source`, all nullable.
**Consumers must render a reference that has never been enriched.**
A forge that cannot be reached is a missing title, never a rendering failure.

The shared reader accepts only the exact reference shape produced by this contract.
URLs are capped at 512 characters, hosts at 253, project paths at 480, owners at 400, repositories at 200, forge tokens at 32, enrichment titles at 240, and enrichment sources at 40.
Parsed identity fields must reconstruct the canonical URL, numbers must be positive integers or null, origins and kinds must use their documented tokens, enrichment state must be `open`, `closed`, `merged`, `unknown`, or null, and enrichment timestamps must be ISO-8601 UTC or null.
Read-only projections replace an absent or invalid store with the documented empty reference list, while `add`, `remove`, and `clear` refuse to overwrite a present invalid store.

`bin/fm-work-item.sh` owns storage and transport only.
Deciding which work item a task references, resolving it against a project's registry, and refreshing per-forge enrichment belong to the project-issue-linkage owner, which calls `add` here rather than introducing a second schema.
The legacy `issue=<number>` field in task metadata records a same-repository GitHub issue and is not migrated into this store by this contract; that migration belongs to the same linkage owner.

## Normalized PR state

A recorded PR URL does not say whether work is waiting on review, waiting on checks, conflicting, or already merged.
`bin/fm-pr-status.sh` is the one place that asks a forge and the one place that maps each forge's vocabulary onto these enumerations.

| Field | Values |
| --- | --- |
| `state` | `open`, `draft`, `closed`, `merged`, `unknown` |
| `review` | `approved`, `changes_requested`, `review_required`, `none`, `unknown` |
| `checks` | `passing`, `failing`, `pending`, `none`, `unknown` |
| `mergeable` | `mergeable`, `conflicting`, `blocked`, `unknown` |

The observation is cached at `state/<id>.pr-status` with an `observed_at` stamp, and the snapshot reports `status_age_seconds` as the age of that cached record.
Read-only consumers report the cached value with its age and never call a forge themselves, so the fleet snapshot stays offline and fast.
`bin/fm-pr-check.sh` seeds the cache when it arms a merge watch and `bin/fm-pr-merge.sh` refreshes it after a merge; both are best effort, and a failed refresh leaves the previous observation in place rather than overwriting a good reading with `unknown`.
Every cache read validates the canonical PR identity, the normalized enumerations, the draft type, the head SHA, the ISO-8601 UTC observation stamp, and the provider source before exposing it.
A cache whose URL does not match the task's current canonical PR URL projects the documented unknown observation, while a failed refresh for the same URL retains the previous valid observation.
GitLab review state combines the merge request approvals endpoint's current `approved`, `approvals_required`, `approvals_left`, and `approved_by` values to distinguish `none`, `review_required`, and `approved`, and ambiguous or unavailable results degrade to `unknown`.

## Snapshot projection

`fm-fleet-snapshot.v1` grows additively.
Every field below is new; a v1 consumer that reads only the fields it already knows keeps working unchanged, so no renderer migration is required.

Per task: `model`, `effort`, `paths.status_log.last_event_at` and `last_event_age_seconds`, the parsed PR identity with `head`, `status`, `status_age_seconds`, and `status_freshness`, the `work_items` list, and the computed `card`.

Top level: `card_precedence`, `supervision` (watcher beacon age against the shared grace window from `bin/fm-supervision-lib.sh`, plus away-mode state and age), and `history`.

`history` is schema `fm-outcome-history.v1`, built from every `data/<id>/outcome.json` in the home, newest completion first and bounded by `FM_SNAPSHOT_HISTORY`.
A manifest that no longer parses, is not a plain file, or exceeds the read bound is disclosed in `history.malformed` with its reason rather than dropped, so a consumer can distinguish "nothing completed" from "one record is unreadable".
History orders readable same-schema candidates before applying full value conformance, then validates only enough newest candidates to fill the requested bound.

### Card precedence

Signals overlap constantly: a task can have an open decision, an open PR, and a `done` event at the same time.
Exactly one column wins per task, resolved against this ladder in order, and `card.rank` is its 1-based position.
`card.signals` records the inputs that produced the verdict, so a surprising column is inspectable rather than opaque.

| Rank | Column | Action | Wins when |
| --- | --- | --- | --- |
| 1 | `needs_decision` | `decide` | a keyed decision is still open |
| 2 | `blocked` | `unblock` | a keyed blocker is still open |
| 3 | `parked` | `respond_to_gate` | validation is parked at a gate |
| 4 | `failed` | `investigate` | the task reported a failure |
| 5 | `review` | `review_pr` | a PR is recorded and not confirmed merged |
| 6 | `done` | `close_out` | the task reported completion with nothing left open |
| 7 | `waiting` | `recheck` | a declared external wait |
| 8 | `active` | `supervise` | the worker is working |
| 9 | `secondmate` | `route_work` | a persistent secondmate with an empty queue |
| 10 | `idle` | `inspect` | no current signal |

The ordering encodes four judgements worth stating.
An open decision outranks everything because it is unanswered work for firstmate or the captain even when a PR is already open.
A blocker outranks a failure because the worker is still there and asking.
A failure outranks an open PR because the PR is not the live problem.
An open PR outranks `done` because a task that reported "PR checks green" has not landed until that PR is merged.

## Secret safety

Manifests and snapshots carry no credentials, no raw prompts, no tool arguments, and no captured payloads.

That is enforced, not just documented.
Shared work-item and PR-status readers validate every stored value against its wire type, enumeration, canonical shape, and documented length cap before exposing it to a manifest or snapshot.
`fm_outcome_manifest_keys_valid` also checks a composed manifest against a fixed recursive key allowlist, and the writer refuses to publish a document carrying any path the allowlist does not name.
Adding a field is therefore a deliberate act in one place.
Every producer-owned free-text value passes through `fm_outcome_text`, which strips control characters, collapses the value to a single line, and caps its length, while stored free text is rejected when it exceeds the same boundary.
The PR observation stores only the enumerated tokens above and a head SHA; no API response body reaches disk.

`tests/fm-outcome-manifest.test.sh` plants sentinel secrets in private runtime records and in non-conforming allowlisted values inside present work-item and PR-status stores, then asserts none of it appears in a manifest or a snapshot.
The crew's own status line is deliberately outside that set: it is a single-line supervisor-facing field firstmate designed and has always surfaced, not a store of credentials or captured payloads.

## Verification

```
$ bash tests/fm-outcome-manifest.test.sh
$ bash tests/fm-fleet-snapshot-view.test.sh
$ bash tests/fm-teardown.test.sh
```
