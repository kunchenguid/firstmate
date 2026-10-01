# Dry-Run: Parser-Based Candidate Extraction

This section demonstrates the Profile A (structured controller) extraction
path end-to-end using synthetic data. It is concrete enough to implement the
same pattern in another skill. On Profiles B/C the `[CANDIDATE]` row format in
the lane reports is the extraction contract itself; this parser flow does not
apply.

### Scenario

A PR review has dispatched six base explorer lanes via `dispatch_lanes_async`.
The batch completed and `collect_lane_results` returned:

```json
{
  "batch_id": "batch-a1b2c3",
  "lane_results": [
    {
      "lane_id": "pr_review_lane1_correctness",
      "status": "completed",
      "output_ref": "L1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "output_degraded": false
    },
    {
      "lane_id": "pr_review_lane2_security",
      "status": "completed",
      "output_ref": "L1:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "output_degraded": false
    }
  ]
}
```

### Step 1 — Call the parser

The orchestrator calls `parse_lane_candidates` for each `output_ref`:

```json
{
  "tool": "parse_lane_candidates",
  "arguments": {
    "output_ref": "L1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "producer": "swarm-pr-review",
    "expected_family": "base_explorer"
  }
}
```

### Step 2 — Structured response

The parser returns a `ParseResultWithSidecar`. On success, `error` and `error_code` are absent.

A successful receipt may additionally carry **salvage disclosure** fields, which
report that the artifact was accepted only after a narrow, auditable repair —
never that it was pristine (issue #2279):

- `repair_kinds` — structural repairs applied before the strict parse, e.g.
  `["duplicate-header-row-dropped"]` when a canonical header was re-emitted as a
  data row, or `["synthesized-header"]`, `["summary-row-dropped"]`.
- `clean_attestation_salvaged: true` plus `clean_attestation_salvage_reason` — a
  `[CLEAN]` attestation conflicted with a same-lane `[CANDIDATE]` row, so the
  attestation was discredited while the candidate rows were retained. The parse
  SUCCEEDS. Do **not** read this as coverage: `clean_attestation` is absent
  whenever it is set, so a lane with no candidate rows still fails coverage.
  A `[CLEAN]` that failed for any other reason (degraded or partial source,
  duplicate attestation, lane mismatch) still hard-errors and never reports a
  salvage.

Example success receipt:

```json
{
  "candidates": [
    {
      "record_type": "candidate",
      "row_format_family": "base_explorer",
      "row_format_version": 1,
      "record_version": { "major": 1, "minor": 1 },
      "source_output_ref": "L1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "source_batch_id": "B-2025-06-22-001",
      "source_lane_id": "explorer-1",
      "source_agent": "paid_explorer",
      "source_digest": "sha256:abc123def456...",
      "extracted_from_partial_source": false,
      "sessionId": "ses_01HXYZ...",
      "parentSessionId": "ses_01HABC...",
      "producer": "swarm-pr-review",
      "candidate_id": "C-001",
      "lane": "Lane 1: Correctness and edge cases",
      "micro_lane": null,
      "severity": "HIGH",
      "category": "null-safety",
      "file_line": "src/utils/cache.ts:142",
      "claim": "Uncached getter may return undefined on cold start",
      "evidence_summary": "The `getCached` function returns `cache[key]` without a fallback when the cache is empty.",
      "impact_context": "Downstream callers in `src/handlers/*.ts` expect a defined value and call `.toString()` directly.",
      "invariant_violated": null,
      "confidence": "HIGH"
    },
    {
      "record_type": "candidate",
      "row_format_family": "base_explorer",
      "row_format_version": 1,
      "record_version": { "major": 1, "minor": 1 },
      "source_output_ref": "L1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "source_batch_id": "B-2025-06-22-001",
      "source_lane_id": "explorer-1",
      "source_agent": "paid_explorer",
      "source_digest": "sha256:abc123def456...",
      "extracted_from_partial_source": false,
      "sessionId": "ses_01HXYZ...",
      "parentSessionId": "ses_01HABC...",
      "producer": "swarm-pr-review",
      "candidate_id": "C-002",
      "lane": "Lane 1: Correctness and edge cases",
      "micro_lane": null,
      "severity": "MEDIUM",
      "category": "async-ordering",
      "file_line": "src/services/queue.ts:88",
      "claim": "Race between `drain` and `processNext` may drop items",
      "evidence_summary": "`drain` sets `active = false` before awaiting `processNext`, which also checks `active`.",
      "impact_context": "Items submitted during the drain window are silently dropped.",
      "invariant_violated": null,
      "confidence": "MEDIUM"
    }
  ],
  "invocation_envelope": {
    "record_type": "invocation",
    "source_output_ref": "L1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "source_batch_id": "B-2025-06-22-001",
    "source_lane_id": "explorer-1",
    "source_agent": "paid_explorer",
    "source_digest": "sha256:abc123def456...",
    "row_format_version": 1,
    "record_version": { "major": 1, "minor": 1 },
    "sessionId": "ses_01HXYZ...",
    "parentSessionId": "ses_01HABC...",
    "producer": "swarm-pr-review",
    "produced_at": "2025-06-22T14:30:00.000Z",
     "format_families_detected": ["base_explorer"],
     "candidate_count": 2,
     "parse_errors": 0,
     "malformed_rows": 0,
     "clean_attestation_count": 0
  },
  "diagnostics": {
    "candidate_count": 2,
    "parse_errors": 0,
    "parse_error_details": [],
    "malformed_rows": 0,
    "duplicate_id_count": 0,
    "duplicate_id_warnings": [],
    "degraded_source_count": 0,
    "incomplete_source_count": 0,
     "format_families_detected": ["base_explorer"],
     "clean_attestation_count": 0
   }
}
```
> **Note**: callers pass `expected_family` for each dispatch batch. A recognizable
> conflicting header fails closed with `expected-family-mismatch`; when the flag
> is absent, the recognized header controls the mapping and positional detection
> is only a legacy unknown-header fallback. Marker-prefixed data rows remain
> accepted for compatibility. Valid canonical rows produce `parse_errors: 0`.

On refusal (e.g. `output_ref` does not exist), `error` and `error_code` are present; `candidates` is `[]`; `invocation_envelope` and `diagnostics` are populated with empty fields for traceability:

```json
{
  "error": "Artifact reference not found in store",
  "error_code": "ref-not-found",
  "candidates": [],
  "invocation_envelope": {
    "record_type": "invocation",
    "source_output_ref": "L1:1111111111111111111111111111111111111111111111111111111111111111:2222222222222222222222222222222222222222222222222222222222222222:3333333333333333333333333333333333333333333333333333333333333333",
    "source_batch_id": "",
    "source_lane_id": "",
    "source_agent": "",
    "source_digest": "",
    "row_format_version": 1,
    "record_version": { "major": 1, "minor": 1 },
    "produced_at": "2025-06-22T14:30:00.000Z",
    "format_families_detected": [],
    "candidate_count": 0,
    "parse_errors": 0,
    "malformed_rows": 0,
    "clean_attestation_count": 0
  },
  "diagnostics": {
    "candidate_count": 0,
    "parse_errors": 0,
    "parse_error_details": [],
    "malformed_rows": 0,
    "duplicate_id_count": 0,
    "duplicate_id_warnings": [],
    "degraded_source_count": 0,
    "incomplete_source_count": 0,
    "format_families_detected": [],
    "clean_attestation_count": 0
   }
}
```

### Step 3 — Filter and group

The orchestrator filters the returned `candidates[]` array by `producer: "swarm-pr-review"` and the exact allowed `source_batch_id` / `source_lane_id` tuples, then groups
the candidates. In this synthetic example, the two candidates above are grouped
by file area:

- **Chunk A — `src/utils/`** (1 candidate): C-001
- **Chunk B — `src/services/`** (1 candidate): C-002

If there were more candidates, the orchestrator would also group by category
(e.g., `null-safety`, `async-ordering`) and cap each chunk at 50 candidates.

### Step 4 — Dispatch reviewer lanes

The orchestrator dispatches one reviewer lane per chunk:

```text
You are the independent reviewer. Validate only the candidates assigned below.
Do not search for new issues except where needed to validate reachability or
mitigation. Do not trust explorer severity.

Context pack summary:
- scope: ...
- obligations: ...
- impact cone: ...
- deterministic signals: ...
- relevant Swarm artifacts / knowledge: ...
- base_ref: <commit SHA of base branch>
- head_ref: <commit SHA of PR head branch>

Candidates (Chunk A — src/utils/):
- C-001 | HIGH | null-safety | src/utils/cache.ts:142 | Uncached getter may return undefined on cold start

For each candidate, return:
[REVIEWED] | item_id | classification | evidence_type | severity | introduced_by_pr | file:line | rationale | probe | reviewer_notes | risk_impact | risk_tags

You must check caller context, reachability, schema/middleware/framework mitigations, state-machine constraints, test coverage, PR-introducedness, and severity.

IMPORTANT: If a finding claims behavior is "new" or "introduced by the PR", you MUST read the equivalent code on the base branch (git show <base_ref>:<file>) to verify it was not present before. A reviewer claim of "this is new" is invalid without base-branch evidence. Do not compare the new code to an idealized baseline — compare it to what actually existed on the base branch at the time of the PR.
```

### Key invariants

- The parser reads the **full artifact**, not a preview. Truncation in the
  `dispatch_lanes` preview does not affect candidate extraction.
- The orchestrator never classifies candidates — it only filters, groups, and
  routes them.
- Each reviewer receives a bounded chunk. A chunk with more than 50 candidates
  is split before dispatch.
- The `invocation_envelope` in the parser response provides audit provenance
  for every extracted candidate.
