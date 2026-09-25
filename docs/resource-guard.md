# Per-task resource guard

Firstmate's resource guard keeps expensive work inside a declared task budget without turning one provider's telemetry into a fleet-wide assumption.
It is local, provider-neutral, task-bound, and conservative when measurements are unavailable or shared.

## Architecture

`bin/fm-resource-guard.sh` is the single numeric policy evaluator and record owner.
It consumes quota-axi's normalized JSON, selects an explicit provider/account/model scope, resolves every concrete window named by that scope, and evaluates those windows independently.
It does not infer provider identity from a worker runtime or model name.

`bin/fm-procevent-resource.sh` is deliberately thin.
It lets the generic process-event runner execute the central monitor and classify a terminal pause/error result; it contains no thresholds or provider logic.
A resource process-event wakes supervision, not the worker directly.
This preserves the existing one-owner model: Firstmate steers the worker through its durable inbox, and the worker stops cooperatively at a safe ownership boundary.

`bin/fm-spawn.sh` adds the central guard's fixed worker overlay when `state/<task>.resource-budget.json` already exists.
The same overlay reaches every supported worker runtime.
A corrupt or unsafe budget blocks spawn rather than silently dropping enforcement.
`bin/fm-teardown.sh` retires the task's monitor and emits its terminal event before live task state is removed.

The guard complements the planned operation-capability evaluator rather than replacing it.
A future operation evaluator can ask whether the task resource record is active as one precondition for a costly operation.
Resource policy remains in this script, while operation authorization remains in the operation evaluator; neither should copy the other's rules or create a second runtime control plane.

The operator procedure is in [the internal resource-guard skill](../.agents/skills/resource-guard/SKILL.md).
The script header owns the complete CLI, exact arithmetic, schemas, and failure behavior.

## Policy

Every guarded task starts from a minimized quota snapshot and declares a bounded next tranche.
The evaluator applies these rules:

- preserve 30 quota points by default;
- inside six hours of a window reset, permit a 15-point floor only when every applicable scope reports runway through reset and the measured remaining points cover the bounded tranche without crossing 15;
- inside two hours, permit a 5-point floor under the same proof;
- pause after 15 measured task quota points by default;
- treat equality as safe, so a tranche ending exactly at a floor does not cross it;
- apply the strictest result across all account-wide, provider-wide, product, and model windows;
- pause conservatively when attribution is shared or unknown and the shared delta reaches the task limit;
- treat a changed reset identity as discontinuous evidence rather than silently rebasing an exact task burn;
- treat missing, ambiguous, malformed, stale, or unknown telemetry as unavailable, never zero or an invented percentage.

A window's burn is measured against its task-start baseline only while its reset identity is continuous.
A provider replenishment cannot produce a negative burn.
When a reset changes between checks, the guard records an unavailable measurement and asks for review because work between the reset and the first observed post-reset sample cannot be attributed exactly.
The baseline reset identity is kept, so later checks stay discontinuous rather than silently healing.
Only an exact captain answer can resume such a pause, and it does so by starting a fresh versioned baseline from current valid telemetry; it refuses when the current snapshot cannot establish one.

Near-reset relaxation is intentionally narrower than ordinary recovery.
Only the proven 15/5 floor rule can reopen an ordinary reserve pause automatically.
A new session, an updated percentage, a reset, or elapsed time alone does not reopen a lane.
Every other resume needs an exact captain-held decision lifecycle and matching decision digest, or a recorded redesign/re-scope for the bounded-review circuit breaker.
A revised budget changes the task burn allowance and optional tranche; it cannot lower reserve floors.

## Safe pause semantics

A monitor never interrupts or exits a worker.
It also never stashes, resets, checks out another branch, cleans files, aborts a validation run, or starts a competing run.
It records `pause_pending` and wakes Firstmate.
A failed or malformed quota read during monitoring is recorded the same way, as `telemetry_unavailable` with reason `telemetry_read_failed` over the last known baseline, so the monitor never retires while the budget stays active.
Every authorized return to active re-arms the task's single monitor registration, and a finalized reserve pause keeps it armed so the near-reset proof can reopen the lane and report `resumed`.
If reset discontinuity or another telemetry, burn, or attribution reason ends that possibility, the pause escalates to that reason and the monitor reports `awaiting-authority` instead of polling silently.
Local errors such as lock contention retry with bounded backoff and then report a non-terminal `error`, so the source stays registered.

Firstmate asks the worker to stop at its next safe boundary.
For ordinary work, that means the current atomic write/test action is complete and all branches/files remain preserved.
For branch-owning validation, that means the current supported action has reached a gate or the validation owner has returned branch custody through its own protocol.
The worker appends its normal `paused` task event only after reaching that point.
The guard's `pause` command verifies that latest worker event, and that its `[at=<epoch>]` stamp is no older than the pause request, before finalizing `paused`.
`fm-spawn` refuses to launch a task whose budget is not active.
Every budget starts in the durable `pre_dispatch` lifecycle; a guarded `fm-spawn` records the one `dispatched` transition before launch delivery and rolls it back if the spawn aborts before the worker command is delivered.
While the budget is still `pre_dispatch`, no worker exists to stop, so `pause --pre-dispatch` finalizes any pending pause without a worker event, whether `start`, a check, a milestone, or the monitor raised it; once dispatched, worker safe-boundary evidence is mandatory.

This cooperative boundary is portable across worker runtimes and does not weaken the existing validation custody rules.

## Bounded review protocol

The budget record includes an `fm.bounded-review.v1` ledger.
It records only exact heads, privacy-safe actor/session ids, provider ids, model-family ids, reason slugs, and timestamps.
It enforces:

1. one creator pass;
2. one full independent critic pass on the frozen creator head;
3. one accepted correction pass owned by the creator;
4. one focused independent delta review of the corrected head;
5. a complete independent review of the exact final head.

Critic, delta, and final sessions must differ from the creator session.
A different provider/model family is the default when feasible.
Using the same provider and family requires an explicit privacy-safe reason slug in the record.

A first review failure opens the one correction opportunity.
A second consecutive failure under the same theme opens `pause_pending` with reason `repeated_review_theme`.
Any other failure after the accepted correction opens `pause_pending` with reason `review_loop_exhausted`, so alternating themes cannot loop.
Further review is refused until a materially new redesign/re-scope is recorded or the captain authorizes a revised budget.
This bounds review spend without treating a focused delta review as a substitute for the required final full review.

## Local records and trust boundaries

All records are local to the Firstmate home:

| Record | Purpose |
|---|---|
| `state/<task>.resource-budget.json` | Versioned current budget, minimized window snapshots, attribution, and review ledger |
| `state/<task>.resource-pause.json` | Pause trigger, safe boundary, and exact resume authority |
| `data/burn-evaluations/<task>-<id>.json` | Immutable trigger evaluation with measured delta and concurrent-task context |
| `data/resource-events/YYYY-MM.jsonl` | Finalized versioned baseline, snapshot-transition, milestone, review, pause, resume, and retirement events |

Directories are mode `0700` and files are mode `0600`.
Symlinked or unowned record paths are refused.
Per-task locks serialize one budget, and a separate home-wide lock serializes the shared event journal across concurrent tasks.
Event ids are deterministic SHA-256 digests of canonical event content.
An exact retry is idempotent.
Before each append, every retained line is schema-checked and its digest is recomputed; malformed, forged, oversized, or hostile input blocks publication and is never evaluated as shell.

Finalized events are append-only inside their retention horizon.
Publication applies a rolling 90-day private retention policy and removes expired entries.
Burn evaluations remain immutable task evidence until ordinary private-data maintenance removes them under the home's policy.
Live budget and pause records are removed only through landed-task cleanup.

The guard stores no prompts, completions, token streams, diffs, source paths, file contents, usernames, credentials, provider payloads, captain decision text, or model billing estimates.
Provider percentages are normalized quota points, not token counts or money.
The decision record stores only a SHA-256 digest proving that the supplied answer is the captain answer already recorded by `fm-captain-hold.sh`.

## Schemas

The current local schema ids are:

- `fm.task-resource-budget.v1`
- `fm.resource-pause.v1`
- `fm.burn-evaluation.v1`
- `fm.resource-event.v1`
- `fm.bounded-review.v1`

A minimized event has this shape:

```json
{
  "schema": "fm.resource-event.v1",
  "event_id": "<sha256>",
  "ts": "2027-01-15T08:00:00Z",
  "kind": "window_snapshot",
  "task_id": "example-task",
  "budget_id": "<sha256>",
  "budget_revision": 1,
  "provider": "codex",
  "account_key": "work",
  "model": "fable",
  "source": "quota-axi",
  "attribution_confidence": "shared",
  "concurrent_tasks": ["example-sibling"],
  "windows": [
    {
      "id": "weekly",
      "baseline_remaining_points": 80,
      "current_remaining_points": 65,
      "burn_points": 15,
      "reserve_floor_points": 30,
      "reset_continuity": true,
      "telemetry_known": true
    }
  ],
  "decision": {
    "state": "pause_pending",
    "reason": "attribution_uncertain",
    "resume_required": "captain_decision_or_redesign"
  },
  "milestone": null
}
```

Fields can be added compatibly within a version, but changing meaning, privacy, authority, or required fields needs a new schema id and migration tests.
Consumers must reject unknown major schema ids instead of guessing.

## Private Wednesday review

The JSONL feed is the source for a private weekly operational review.
A reviewer can aggregate the retained files locally without contacting a provider:

```bash
jq -s '
  group_by(.task_id) |
  map({
    task_id: .[0].task_id,
    providers: (map(.provider) | unique),
    pauses: (map(select(.decision.state == "pause_pending" or .decision.state == "paused")) | length),
    resumes: (map(select(.kind == "resume")) | length),
    max_window_burn: ([.[].windows[]?.burn_points // 0] | max),
    attribution: (map(.attribution_confidence) | unique),
    review_events: (map(select(.kind == "review_policy")) | length)
  })
' data/resource-events/*.jsonl
```

Interpret a shared or unknown delta as a window observation, not a task invoice.
Review repeated pause reasons, attribution quality, same-family review exceptions, and redesign frequency.
Do not rank people, reconstruct prompts, or convert quota points into cost without a separate authoritative price source.

## Verification

Focused coverage lives in `tests/fm-resource-guard.test.sh`.
It exercises threshold equality, exact six-hour/two-hour boundaries, runway proof, overlapping windows, schema-6 account ambiguity, multiple providers, 15-point burn, shared attribution, unavailable/malformed/reset-discontinuous telemetry, safe pause, automatic and captain-authorized resume, bounded review, cross-family review records, concurrent event appends, idempotence, hostile input, privacy minimization, and 90-day retention.

Related integration suites cover process-event lifecycle, captain-held answer recording, spawn overlays, cleanup, and quota schema validation.
A live token-free smoke check may pass a current `quota-axi --json` snapshot into `start --snapshot`; it must use a disposable private home and `--no-monitor`, and must not print or commit the raw payload.
