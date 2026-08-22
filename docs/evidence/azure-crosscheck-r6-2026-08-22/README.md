# Azure Crosscheck R6 evidence, 2026-08-22

[`evidence.json`](evidence.json) is the compact, secret-free record of the second review required by the evidenceable R6 amendment in `docs/azure-requirements.md`.
It projects the exact task declaration and accepted ledger run without carrying subscription ids, resource ids, credentials, absolute machine paths, raw logs, or internal hostnames.

The task declared `harness=claude` and `model=claude-opus-5`.
The accepted run used Pi with `gpt-5.6-sol`, recorded `review_family_mode: codex-fallback`, and omitted the `model_independence: same-model` marker.
The declared author family and reviewer family were therefore different, so the same-model relaxation was not required.
This proves the declaration-based acceptance that the system can evidence; it does not prove who authored the change.

The verdict was `blocking`, which is a completed review rather than a tool failure or merge approval.
It cited three locations, executed its reproduction and verifier successfully in isolated Azure attempts, and recorded complete model, tool, verifier, and staging cleanup.
The finding identified the missing tracked acceptance bundle in PR #300.
Commit `49f858713d78fea3a3da0f2445dc4cf8c92d592a`, which is an ancestor of this record, adds that compact tracked evidence.

The first screened reviewer in the run was the GLM primary and did not complete an accepted verdict.
R6 does not require that failed attempt to be rewritten as a success: the accepted screened fallback remains outside the non-Codex declaration's family and records its fallback family mode explicitly.

## Claim map

| R6 clause | Tracked field paths |
|---|---|
| Non-Codex model declaration | `author_declaration` |
| Completed cross-family review | `accepted_run.state`, `accepted_run.reviewer` |
| Same-model relaxation not required | `accepted_run.reviewer.model_independence`, `accepted_run.reviewer.same_model_relaxation_required` |
| Exact PR head and base | `accepted_run.head_sha`, `accepted_run.base_sha`, `accepted_run.base_branch_sha` |
| Azure execution and cleanup | `accepted_run.azure_execution` |
| Executed reproduction | `accepted_run.execution_proof` |
| Review finding absorbed by tracked evidence | `accepted_run.active_blockers`, `finding.resolved_by_tracked_evidence_commit` |

## Verify the tracked record

From the repository root, run:

```sh
set -eu
evidence=docs/evidence/azure-crosscheck-r6-2026-08-22/evidence.json
jq -e '
  .schema == "fm.azure-crosscheck-r6-evidence/v1" and
  .task_id == "azure-r6-claude-acceptance" and
  .author_declaration.harness == "claude" and
  .author_declaration.model == "claude-opus-5" and
  .accepted_run.state == "blocking" and
  .accepted_run.head_sha == "e2fa194e3f2581897fcf2d33d70b9acff23e63a3" and
  .accepted_run.reviewer.harness == "pi" and
  .accepted_run.reviewer.model == "gpt-5.6-sol" and
  .accepted_run.reviewer.review_family_mode == "codex-fallback" and
  .accepted_run.reviewer.model_independence == null and
  .accepted_run.reviewer.same_model_relaxation_required == false and
  .accepted_run.reviewer.execution_mode == "azure-compartment-v1" and
  .accepted_run.azure_execution.model_cleanup_phase == "complete" and
  .accepted_run.azure_execution.staging_cleanup_phase == "complete" and
  (.accepted_run.azure_execution.evidence_attempts | length) == 2 and
  all(.accepted_run.azure_execution.evidence_attempts[];
    .result_exit_code == 0 and
    .result_timed_out == false and
    .tool_cleanup_phase == "complete" and
    .tool_credential_present == false and
    .tool_network_bytes == 0 and
    .verifier_cleanup_phase == "complete" and
    .verifier_credential_present == false and
    .verifier_network_bytes == 0
  ) and
  .accepted_run.execution_proof.actual_exit == 0 and
  .accepted_run.execution_proof.expected_exit == 0 and
  (.accepted_run.citations | length) == 3 and
  .accepted_run.active_blockers == ["cc-ceeaedcd090c"] and
  .finding.resolved_by_tracked_evidence_commit == "49f858713d78fea3a3da0f2445dc4cf8c92d592a" and
  .limitations.author_identity_is_a_declaration == true and
  .limitations.glm_primary_completed == false and
  .limitations.does_not_prove == ["R4", "C1", "C2", "C3"]
' "$evidence" >/dev/null
```

When the frozen sources are available, verify their exact bytes before comparing projections:

```sh
set -eu
evidence=docs/evidence/azure-crosscheck-r6-2026-08-22/evidence.json
META=/path/to/azure-r6-claude-acceptance.meta
LEDGER=/path/to/azure-r6-claude-acceptance/crosscheck-ledger.json
test "$(shasum -a 256 "$META" | awk '{print $1}')" = \
  "$(jq -r '.source_artifacts.task_meta.sha256' "$evidence")"
test "$(shasum -a 256 "$LEDGER" | awk '{print $1}')" = \
  "$(jq -r '.source_artifacts.crosscheck_ledger.sha256' "$evidence")"
test "$(awk -F= '$1 == "harness" {print $2}' "$META")" = \
  "$(jq -r '.author_declaration.harness' "$evidence")"
test "$(awk -F= '$1 == "model" {print $2}' "$META")" = \
  "$(jq -r '.author_declaration.model' "$evidence")"
test "$(jq -r '.runs[-1].state' "$LEDGER")" = \
  "$(jq -r '.accepted_run.state' "$evidence")"
test "$(jq -r '.runs[-1].reviewer.model' "$LEDGER")" = \
  "$(jq -r '.accepted_run.reviewer.model' "$evidence")"
test "$(jq -r '.runs[-1].reviewer.review_family_mode' "$LEDGER")" = \
  "$(jq -r '.accepted_run.reviewer.review_family_mode' "$evidence")"
test "$(jq -r '.runs[-1].reviewer.model_independence // ""' "$LEDGER")" = ""
```

The source ledger remains the authority for the complete verdict history.
This tracked projection proves the R6 acceptance fields and preserves the review finding without publishing infrastructure identity or credential metadata.
