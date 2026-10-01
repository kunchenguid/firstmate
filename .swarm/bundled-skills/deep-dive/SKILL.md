---
name: deep-dive
audience: swarm-plugin
description: >
  Full execution protocol for MODE: DEEP_DIVE — read-only codebase audit with
  parallel explorer waves, 2 independent reviewers, and sequential critic
  challenge for HIGH/CRITICAL findings. Loaded on demand by the architect when
  the deep-dive command emits a [MODE: DEEP_DIVE ...] signal.
---

# Deep Dive Audit Protocol

Read-only deep audit of a specified codebase scope using parallel explorer waves, always 2 parallel reviewers, and sequential critic challenge. This mode does NOT mutate source code, does NOT delegate to coder, and does NOT call declare_scope.

## Graph-first evidence contract

Use `repo_map` `graph_health` and boundary discovery before a targeted source-bearing `context_pack`; existing `ask`, `key_files`, and `localization` remain discovery inputs, and `repo_map action="retrieve"` adds one bounded mixed pass routing across ask, symbols, callers, impact, routes, data, preflight, tests, diffs, and explanations — it does not replace explicit `key_files` or `localization` discovery. Graph evidence is advisory only. If freshness is stale or inconclusive, confidence is low, source is missing, the language is unsupported/dynamic, the graph is absent, or an action fails, inspect the direct source and searches before reporting a finding.

### MODE: DEEP_DIVE

## Step 0 — Parse Header

Parse the MODE: DEEP_DIVE header to extract:
- `scope`: the codebase area to audit (e.g., "auth", "payment flow", "src/hooks/")
- `profile`: one of standard | security | ux | architecture | full (default: standard)
- `max_explorers`: integer 1..8 — upper bound on explorer waves (default: 6, or 8 for full profile). This is a CAP, not a fixed count: scale the actual wave size to the resolved scope surface — a trivial scope needs 1–2 explorers, a typical scope 3–5, a large multi-module scope up to the cap — never fix the count in advance.
- `output`: markdown | json (default: markdown)
- `update_main`: boolean (default: true) — whether to fetch/ff-only main before starting
- `allow_dirty`: boolean (default: false) — whether to proceed with uncommitted changes

If the header is malformed or missing required fields, report the error and stop.

## Step 1 — Repo Readiness

1. Check git working tree status. If dirty and `allow_dirty` is false, warn the user and ask whether to proceed. Do NOT proceed automatically.
2. If `update_main` is true and tree is clean: check current branch. If not on `main`, report current branch to user and ASK FOR CONFIRMATION before switching. Only after explicit user approval: `git fetch origin main && git checkout main && git merge --ff-only origin/main`. If ff-only fails, warn the user and ask before proceeding.
3. Record the current HEAD commit hash for the report.

## Step 2 — Scope Resolution

Use the following tools to map the audit scope:
1. `repo_map` with action "graph_health" — only if the graph is missing or incomplete (stale beyond the refresh cap, extraction failures) run `repo_map` with action "build"; plugin init and the session-start probe keep the graph fresh otherwise
2. `repo_map` with action "ask" (the audit scope as the question) and action "key_files" to rank scope-relevant files and repo hubs before any manual symbol walk
3. `repo_map` with action "localization" for the scope target
4. `symbols` and `batch_symbols` on key files identified by ask or localization
5. `imports` to trace dependency boundaries
6. `doc_scan` if documentation coverage is relevant
7. `knowledge_recall` with query matching the scope domain

Produce a SCOPE MAP: list of files, modules, and interfaces within the audit boundary. Cap at 50 files total.

## Step 3 — Explorer Missions (Parallel Waves)

Dispatch explorer waves with `dispatch_lanes_async` when available. Each wave contains up to `max_explorers` missions. Before the first dispatch, verify from the session's actual tool list whether the controller's lane tools are present; when they are absent, use the native parallel subagent path from the start rather than discovering the gap on first failure.

**File caps per mission:**
- 8 files maximum per mission
- ~3500 total lines across all files in a mission
- Group files by import proximity (files that import each other go in the same mission)

**Partition is the contract:** missions own non-overlapping file sets — no file appears in two missions — and the union of all missions must cover every file in the Step 2 scope map. Any scope-map file not assigned to a mission is an explicit coverage gap, not an optional skip.

**Profile-based lane selection — each profile activates specific lanes:**

| Lane | Template | standard | security | ux | architecture | full |
|------|----------|----------|----------|----|-------------|------|
| SCOPE_MAP | Map structure, exports, boundaries | ✓ | ✓ | ✓ | ✓ | ✓ |
| WIRING_DATAFLOW | Trace data flow, API contracts, state propagation | ✓ | ✓ | | ✓ | ✓ |
| RUNTIME_BEHAVIOR | Error handling, edge cases, lifecycle, async patterns | ✓ | | | ✓ | ✓ |
| UX_FLOW | User-facing behavior, accessibility, responsiveness | | | ✓ | | ✓ |
| SECURITY_TRUST | Auth boundaries, input validation, trust transitions | | ✓ | | | ✓ |
| TEST_COVERAGE | Coverage gaps, flaky tests, missing assertions | ✓ | | | | ✓ |
| PERFORMANCE_RELIABILITY | Resource leaks, N+1 queries, race conditions | | | | ✓ | ✓ |
| DOCS_CONFIG_DEPLOYMENT | Config consistency, docs accuracy, deployment drift | | | | | ✓ |

Each explorer mission receives:
- Lane template name and description
- Assigned files (8 max, grouped by import proximity)
- The scope map context from Step 2
- Instruction: "You are performing a [LANE] audit. Report ALL findings as pipe-delimited [CANDIDATE] rows. Header row first, then one row per finding:

[CANDIDATE] | candidate_id | lane | severity | category | file:line | claim | evidence_summary | impact_context | confidence

- candidate_id: unique within this lane (e.g. C-001, C-002)
- severity: INFO | LOW | MEDIUM | HIGH | CRITICAL
- confidence: LOW | MEDIUM | HIGH
- If you find zero issues, emit the header row with no data rows.
- Do NOT emit findings as prose or free text — the downstream parser requires pipe-delimited rows."

Explorer missions are dispatched in parallel waves. Launch the wave promptly — do not accumulate extensive planning prose before the call, or output truncation may swallow the tool call itself. Launch the wave, record the returned `batch_id`, then continue deterministic architect work that does not depend on lane output: refine the scope map, build the candidate ledger shell, inspect local evidence with read-only tools, and prepare reviewer shard structure. Do not synthesize findings from running lanes. Keep each lane `prompt` compact: send shared context ONCE via the `common_prompt` field, or have lanes read it from a file by absolute path, instead of inlining the same large blob into every lane prompt — oversized inline prompts produce malformed or truncated tool-call JSON.

**Incremental collection pattern:** While lanes are running, use `collect_lane_results` without `wait` (or `wait: false`) to poll progress. Process any settled lanes immediately — extract candidates, check `output_ref`, update the candidate ledger — while continuing independent architect work (scope refinement, local evidence reads, reviewer preparation) between polls. This avoids idle waiting and lets you pipeline candidate normalization with lane completion. Only use `wait: true` at the Step 4 boundary if lanes are still pending and no more independent work remains.

At the Step 4 boundary, all lanes must be settled before proceeding. If non-blocking polls show lanes still running and you have exhausted independent work, call `collect_lane_results` with `wait: true` to block on the remaining lanes. **COVERAGE GATE:** Every lane must produce validated candidate output before proceeding. Missing, stale, cancelled, or failed lanes are coverage gaps that must be closed — not documented and skipped. If a lane fails: (1) retry max 2 times with materially different parameters; (2) if retries fail, deploy an equivalent alternative (same agent type, same prompt, same scope, same isolation — different dispatch mechanism acceptable when verified, including Task-tool dispatch as the final fallback when lane tools do not work); (3) if no equivalent exists, stop and surface the lane failure to the user as BLOCKED. Do not proceed past a required lane with unclosed coverage or produce a degraded review.

When a collected or blocking lane result includes `output_ref`, treat `output` as a preview and call `retrieve_lane_output` before extracting candidate findings or declaring a lane clean. If the result is `output_degraded`, `transcript_incomplete`, truncated without a usable ref, missing, stale, cancelled, or failed — or if the lane reports `status: completed` but `parse_lane_candidates` returns 0 candidates (Mode B: intermediate reasoning only) — apply the COVERAGE GATE: retry, deploy equivalent including Task-tool dispatch as the final fallback when lane tools do not work, or stop and surface the lane failure to the user as BLOCKED. Do not mark findings/coverage UNVERIFIED to proceed past the gap.

Explorers generate CANDIDATE FINDINGS only — they do NOT make verdicts. All findings are unverified until Step 5.

## Step 4 — Normalize Candidates

1. Collect all candidate findings from all explorer missions.
2. Deduplicate: merge findings that reference the same location and issue.
3. Assign DD-C001 through DD-CNNN identifiers to unique findings.
4. Sort candidates by severity (CRITICAL → HIGH → MEDIUM → LOW → INFO).
5. Shard into ≤10-candidate shards until all candidates are assigned to a shard.

## Step 5 — Always 2 Parallel Reviewers

Split the candidates into shards of ≤10 each and dispatch 2 parallel `the active swarm's reviewer agent` calls.

Each reviewer receives:
- Their shard of candidates (up to 10)
- The scope map context
- The original scope description
- Instruction: "Verify or reject each candidate finding. For each: verdict (VERIFIED / REJECTED / NEEDS_MORE_EVIDENCE), confidence (0-1), and brief reasoning."

Reviewers MUST NOT suggest fixes — they verify findings only.

## Step 5b — Reviewer Merge/Dedup

After both reviewers return, perform a lightweight sync pass:
1. Cross-reference findings between reviewers — flag correlations
2. Deduplicate any findings both reviewers verified independently
3. For NEEDS_MORE_EVIDENCE findings: if the other reviewer verified a related finding, merge
4. Produce a unified findings list with verified/rejected status

## Step 6 — Critic Challenge (HIGH/CRITICAL only)

For verified findings rated HIGH or CRITICAL, dispatch sequential critic passes:

**Pass 1 — False-positive / root-cause challenge:**
- `the active swarm's critic agent` receives each HIGH/CRITICAL finding
- Challenge: "Is this a false positive? Is the root cause correctly identified? Provide verdict: SURVIVES / DOWNGRADE / REJECT"
- Only findings that SURVIVE proceed to Pass 2

**Pass 2 — Impact / severity challenge:**
- `the active swarm's critic agent` receives surviving findings
- Challenge: "Is the severity correctly rated? Could this be lower impact than claimed? Provide verdict: SURVIVES / DOWNGRADE / REJECT"
- Final severity is the critic's assessed severity

CRITICAL: Do NOT challenge MEDIUM/LOW/INFO findings. Only HIGH and CRITICAL go through critic review.

## Step 7 — Final Report

Assemble and present the audit report:

1. **Wiring Map**: Visual summary of the scope's module structure and data flow
2. **Functionality Assessment**: High-level summary of what the scope does and how well
3. **Verified Findings Table**: DD-ID, severity, location, description, evidence
4. **Rejected Candidates**: Brief list with rejection reasons
5. **Enhancements**: Non-blocking improvement suggestions
6. **Recommended Implementation Phases**: If findings suggest follow-up work, outline phases
7. **JSON Block** (when output=json): Structured machine-readable findings

## Important Constraints

- Do NOT mutate source code under any circumstances
- Do NOT delegate to coder
- Do NOT call declare_scope
- Do NOT create or modify any files outside .swarm/
- No final finding may appear in the report without reviewer verification
- Explorers generate candidate findings only — reviewers verify or reject
- Critics challenge only HIGH/CRITICAL findings — do NOT waste cycles on lower severity
