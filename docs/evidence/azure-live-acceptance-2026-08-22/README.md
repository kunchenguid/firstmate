# Azure live acceptance evidence, 2026-08-22

[`evidence.json`](evidence.json) is the compact, secret-free record of the 2026-08-22 Azure worker acceptance used by `docs/azure-requirements.md` R2/R3, R5, and the corresponding partial R9 claims.
It is a whitelisted derivative of frozen manifest revision 12, whose SHA-256 is recorded at `frozen_manifest.sha256`.
It contains no subscription id, resource id, absolute machine path, credential, raw log, or internal worker hostname.

The raw outcome bundle is intentionally not tracked because its embedded commit metadata exposes an internal worker hostname.
The tracked origin proof is limited to the child ref, its exact tip, and digests of the frozen and live-ref lines.

## Claim map

| Requirement | Tracked field paths |
|---|---|
| R2/R3 parent and child assignments | `simultaneous_assignments[0]`, `simultaneous_assignments[1]` |
| R2/R3 durable child request | `child_request` |
| R2/R3 child execution and landing | `executions[0]`, `origin` |
| R2/R3 terminal parent monitor | `parent_monitor` |
| R2/R3 release and aftercare | `release_proofs[0]`, `release_proofs[1]`, `post_reset` |
| R5 simultaneous distinct-account placement | `simultaneous_assignments` |
| R5 ordinary read-only executions | `executions[1]`, `executions[2]` |
| R5 account authority at release | `release_proofs` |
| R9 proven subset | `origin`, `release_proofs`, `post_reset` |

This record does not prove R4, R6, C1, C2, or C3.
It exercised four simultaneous accounts, not all eight configured accounts.
The two ordinary executions were read-only inspections, and only the compartment child produced a commit.
The resource absence count covers the 60 enumerated acceptance resources, not shared foundation resources.
The observations are point-in-time, and the private child ref requires authenticated `Ruby-Labs` organization access.

## Verify the tracked record

From the repository root, run:

```sh
set -eu
evidence=docs/evidence/azure-live-acceptance-2026-08-22/evidence.json
jq -e '
  .schema == "fm.azure-live-acceptance-evidence/v1" and
  .frozen_manifest.revision == 12 and
  (.simultaneous_assignments | length) == 4 and
  ([.simultaneous_assignments[].slot] | unique | length) == 4 and
  ([.simultaneous_assignments[].account_binding] | unique | length) == 4 and
  all(.simultaneous_assignments[]; .state == "assigned") and
  (.executions | length) == 3 and
  all(.executions[]; .exit_code == 0 and .timed_out == false) and
  .executions[0].outcome_commits == 1 and
  .executions[1].outcome_commits == 0 and
  .executions[2].outcome_commits == 0 and
  .parent_monitor.status == "closed" and
  .parent_monitor.legs_completed == 1 and
  .parent_monitor.recorded_chain_tip.sequence == 7 and
  .parent_monitor.recorded_chain_tip == .parent_monitor.verified_tip and
  (.release_proofs | length) == 4 and
  all(.release_proofs[];
    (.authorities | keys) == ["account", "endpoint", "landing", "report", "worktree"] and
    ([.authorities[].verdict] | all(. == "proved"))
  ) and
  .post_reset.verified_absent_acceptance_resource_count == 60 and
  .post_reset.provider_worker_count == 0 and
  .post_reset.provider_active_specialized_reservation_count == 0 and
  .post_reset.vm_count == 0 and
  .post_reset.controller_worker_count == 0 and
  .post_reset.controller_assigned_queue_count == 0 and
  .post_reset.controller_live_capacity_reservation_count == 0 and
  .limitations.does_not_prove == ["R4", "R6", "C1", "C2", "C3"]
' "$evidence" >/dev/null
```

When the frozen evidence directory is available, reproduce every recorded source digest with:

```sh
set -eu
evidence=docs/evidence/azure-live-acceptance-2026-08-22/evidence.json
FROZEN_DIR=/path/to/live-acceptance-20260822T061300Z
test "$(shasum -a 256 "$FROZEN_DIR/run-manifest.json" | awk '{print $1}')" = \
  "$(jq -r '.frozen_manifest.sha256' "$evidence")"
jq -r '.source_artifacts[] | [.file, .sha256] | @tsv' "$evidence" |
while IFS="$(printf '\t')" read -r file expected; do
  actual=$(shasum -a 256 "$FROZEN_DIR/$file" | awk '{print $1}')
  test "$actual" = "$expected" || {
    printf 'digest mismatch: %s\n' "$file" >&2
    exit 1
  }
done
```

The controller counts are exact projections of the digest-bound post-reset controller source; no separate account-lease count is inferred.
Reproduce those projections with:

```sh
set -eu
evidence=docs/evidence/azure-live-acceptance-2026-08-22/evidence.json
FROZEN_DIR=/path/to/live-acceptance-20260822T061300Z
controller_file=$(jq -r '.source_artifacts.post_reset_controller.file' "$evidence")
expected=$(jq -c '.post_reset' "$evidence")
jq -e --argjson expected "$expected" '
  (.workers | length) == $expected.controller_worker_count and
  (.queue | length) == $expected.controller_queue_count and
  ([.queue[] | select(.status == "complete")] | length) ==
    $expected.controller_complete_queue_count and
  ([.queue[] | select(.status == "assigned")] | length) ==
    $expected.controller_assigned_queue_count and
  (.pending_actions | length) == $expected.controller_pending_action_count and
  ([.capacity_reservations[] | select(.status != "released")] | length) ==
    $expected.controller_live_capacity_reservation_count
' "$FROZEN_DIR/$controller_file" >/dev/null
```

## Verify the live private ref

The following command uses the existing Git credential helper for authenticated HTTPS access and fails without access instead of prompting:

```sh
set -eu
evidence=docs/evidence/azure-live-acceptance-2026-08-22/evidence.json
expected=$(jq -r '[.origin.tip, .origin.ref] | @tsv' "$evidence")
actual=$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads \
  "$(jq -r '.origin.url' "$evidence")" \
  "$(jq -r '.origin.ref' "$evidence")")
test "$actual" = "$expected"
test "$(printf '%s\n' "$actual" | shasum -a 256 | awk '{print $1}')" = \
  "$(jq -r '.origin.exact_ref_line_sha256' "$evidence")"
```

This authenticated check returned the recorded tip on 2026-08-22.
It proves the live ref at read time, not that a mutable branch can never move later.
