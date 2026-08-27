# Azure C3 cost-guard acceptance evidence, 2026-08-24

[`evidence.json`](evidence.json) is the compact, secret-free record of the two live legs required by `docs/azure-requirements.md` C3.
It contains no subscription id, Azure resource id, account identity, credential, absolute machine path, or raw log.

The 600-second idle-deallocation subject remained assigned without release proof until ordinary authority-backed cleanup.
Positive recorded spend 2.983466 USD crossed a controlled 1 USD bound and refused new compute with `override=none`, after which the default 100 USD/no-override zero state was re-proved.

Azure Cost Management actuals lag by hours.
The daily bound is therefore a backstop on recorded spend rather than a real-time meter; per-mutation cumulative admission and idle deallocation remain the same-day protections ahead of it.

## Claim map

| C3 clause | Tracked field paths |
|---|---|
| Assigned worker deallocated unattended at the minimum supported threshold | `idle_deallocation` |
| No release proof was minted before the evidence capture | `idle_deallocation.queue_status_after_deallocation`, `idle_deallocation.release_proof_after_deallocation` |
| Positive recorded spend crossed the controlled bound with no override | `daily_bound` |
| Default policy and zero fleet state were restored | `default_state_reproof` |
| Cost Management lag remains explicit | `telemetry_caveat`, `limitations.cost_management_is_not_real_time` |
| Private source records are byte-bound without publishing infrastructure identity | `source_artifacts` |

This record proves C3 only.
It does not prove C1 or C2, and it makes no Crosscheck acceptance claim.

## Verify the tracked record

From the repository root, run:

```sh
set -eu
evidence=docs/evidence/azure-c3-cost-guard-2026-08-24/evidence.json
jq -e '
  .schema == "fm.azure-c3-cost-guard-evidence/v1" and
  .acceptance_date == "2026-08-24" and
  .requirement == "C3" and
  .idle_deallocation.threshold_seconds == 600 and
  .idle_deallocation.unattended_deallocation_observed == true and
  .idle_deallocation.provider_power_state == "deallocated" and
  .idle_deallocation.queue_status_after_deallocation == "assigned" and
  .idle_deallocation.release_proof_after_deallocation == false and
  .idle_deallocation.ordinary_authority_backed_cleanup_after_capture == true and
  .daily_bound.recorded_spend_usd == 2.983466 and
  .daily_bound.controlled_bound_usd == 1 and
  .daily_bound.override == "none" and
  .daily_bound.new_compute_refused == true and
  .daily_bound.request_assigned == false and
  .daily_bound.wind_down_available == true and
  .default_state_reproof.daily_bound_usd == 100 and
  .default_state_reproof.override == "none" and
  .default_state_reproof.tripped == false and
  .default_state_reproof.queue_depth == 0 and
  .default_state_reproof.desired_workers == 0 and
  .default_state_reproof.active_workers == 0 and
  .default_state_reproof.assignment_count == 0 and
  .default_state_reproof.used_vcpus == 0 and
  .default_state_reproof.committed_vcpus == 0 and
  .limitations.cost_management_is_not_real_time == true and
  .limitations.does_not_prove == ["C1", "C2"]
' "$evidence" >/dev/null
```

When the operator-local sources are available, verify their exact bytes before comparing projections:

```sh
set -eu
evidence=docs/evidence/azure-c3-cost-guard-2026-08-24/evidence.json
IDLE_REPORT=/path/to/idle-subject-report.md
BOUND_REPORT=/path/to/daily-bound-report.md
COMPLETION=/path/to/zero-to-zero-completion.md
test "$(shasum -a 256 "$IDLE_REPORT" | awk '{print $1}')" = \
  "$(jq -r '.source_artifacts.idle_subject_report_sha256' "$evidence")"
test "$(shasum -a 256 "$BOUND_REPORT" | awk '{print $1}')" = \
  "$(jq -r '.source_artifacts.daily_bound_report_sha256' "$evidence")"
test "$(shasum -a 256 "$COMPLETION" | awk '{print $1}')" = \
  "$(jq -r '.source_artifacts.zero_to_zero_completion_sha256' "$evidence")"
```

The hashes bind the private source reports without publishing their infrastructure identities.
