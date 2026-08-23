# Azure R4 live acceptance evidence, 2026-08-23

[`evidence.json`](evidence.json) is the compact, secret-free record of the live validation-cell acceptance for R4 and the final dependency of R9.
It projects the exact collected result, protected owner-decision history, four behavior shard results, lint shard result, merged pull request, and post-close cleanup state.
It contains no subscription id, Azure resource id, VM instance id, credential, absolute machine path, raw log, or internal hostname.

The accepted cell used the Claude provider runtime and no-mistakes protected owner decisions.
It reached `checks-passed`, collected the exact submitted head, and closed after pull request 319 merged with all 13 checks green.
The worktree disk, private cell container, direct cell role assignments, and every Azure resource tagged to the cell were absent after close.
The controller retained only released historical reservation rows for the cell's five-constituent shape.

## Claim map

| Claim | Tracked field paths |
|---|---|
| Exact cell, request, source, and terminal result | `cell` |
| Claude runtime and protected no-mistakes build | `runtime` |
| Signed owner decision | `owner_decision` |
| Four successful behavior shards | `behavior_shards` |
| Successful lint shard | `lint_shard` |
| Exact merged PR and green CI | `pull_request` |
| Worktree release and scale-to-zero | `cleanup` |
| Frozen local source digests | `source_artifacts` |

This record proves the amended R4 acceptance: one validation cell reached `close` with its worktree disk released.
Together with the already tracked evidence for R1-R3 and R5-R8, it closes R9's only remaining dependency.
It does not promote C1, C2, or C3, and the runner-offload optimisation still has no live acceptance record because it is not an R4 acceptance leg.

## Verify the tracked record

From the repository root, run:

```sh
set -eu
evidence=docs/evidence/azure-r4-live-acceptance-2026-08-23/evidence.json
jq -e '
  .schema == "fm.azure-r4-live-acceptance-evidence/v1" and
  .acceptance_date == "2026-08-23" and
  .cell.id == "azv-c1bb1c5ff906" and
  .cell.phase == "closed" and
  .cell.outcome == "checks-passed" and
  .cell.checks_green == true and
  .cell.attempt == 1 and
  .cell.submitted_head == .cell.current_head and
  .cell.current_head == .cell.remote_head and
  .runtime.provider == "claude" and
  .runtime.bundle_sha256 == "e1d5de518f4dcca9572a471a35c9b42261b9739ee4f244d7138ecaf3c24d2742" and
  .runtime.provider_binary_sha256 == "55d281096f57d411ebbdd94dbf5e9ff3accb7c05713e37348c2c11d4b83bf9d9" and
  .owner_decision.protected == true and
  .owner_decision.protocol == "fm.azure-validation-owner-decision/v1" and
  (.behavior_shards | length) == 4 and
  ([.behavior_shards[].shard] | sort) == [1, 2, 3, 4] and
  ([.behavior_shards[].invocation] | unique | length) == 4 and
  ([.behavior_shards[].round] | unique | length) == 1 and
  all(.behavior_shards[]; .shard_count == 4 and .exit_code == 0) and
  .lint_shard.exit_code == 0 and
  .pull_request.number == 319 and
  .pull_request.head == .cell.current_head and
  .pull_request.checks_total == 13 and
  .pull_request.checks_passed == 13 and
  .pull_request.checks_failed == 0 and
  .cleanup.worktree_disk_absent == true and
  .cleanup.cell_container_absent == true and
  .cleanup.cell_role_assignments_absent == true and
  .cleanup.exact_cell_tagged_resource_count == 0 and
  .cleanup.controller_worker_count == 0 and
  .cleanup.controller_noncomplete_queue_count == 0 and
  .cleanup.controller_pending_action_count == 0 and
  .cleanup.controller_live_capacity_reservation_count == 0 and
  .cleanup.provider_active_specialized_reservation_count == 0 and
  .cleanup.released_shape_reservation_count == 5 and
  .limitations.does_not_prove == ["C1", "C2", "C3"]
' "$evidence" >/dev/null
```

When the operator-local sources are available, verify their exact bytes before comparing projections:

```sh
set -eu
evidence=docs/evidence/azure-r4-live-acceptance-2026-08-23/evidence.json
CELL_STATE=/path/to/azv-c1bb1c5ff906.json
RESULT_JSON=/path/to/attempt-1/extracted/result.json
BEHAVIOR_JSON=/path/to/attempt-1/extracted/evidence/behavior-shards.json
METRICS_JSON=/path/to/attempt-1/extracted/evidence/cell-metrics.json
RESULT_ARCHIVE=/path/to/attempt-1/result.tar.gz
REQUEST_JSON=/path/to/payloads/azv-c1bb1c5ff906/request.json
CONTROLLER_JSON=/path/to/azure-workers/controller.json
for pair in \
  "$CELL_STATE closed_cell_state_sha256" \
  "$RESULT_JSON collected_result_json_sha256" \
  "$BEHAVIOR_JSON behavior_shards_json_sha256" \
  "$METRICS_JSON cell_metrics_json_sha256" \
  "$RESULT_ARCHIVE result_archive_sha256" \
  "$REQUEST_JSON sealed_request_json_sha256" \
  "$CONTROLLER_JSON post_close_controller_sha256"
do
  set -- $pair
  test "$(shasum -a 256 "$1" | awk '{print $1}')" = \
    "$(jq -r --arg key "$2" '.source_artifacts[$key]' "$evidence")"
done
```

The source hashes bind the private raw evidence without publishing its infrastructure identities.
The live GitHub fact can be rechecked with `gh pr view 319 -R ruby-dlee/firstmate`, and the validated head must remain an ancestor of the live default branch.
