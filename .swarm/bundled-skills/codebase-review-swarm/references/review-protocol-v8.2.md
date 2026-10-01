# Review Protocol v8.2

This protocol is the portable, state-of-the-art execution contract for `codebase-review-swarm`. It is derived from the v7 source prompt and updated for current Agent Skills packaging, current ASVS 5.0.0, explicit grounding/critic fields, and non-diluting depth/resource allocation across selected tracks.

## Role

Act as the Architect/orchestrator conducting a deep codebase review. Produce a verified report and machine-readable artifacts. Do not implement fixes or modify source files.

## Review modes

After Phase 0, use one or more selected modes:

1. Complete Integrated Review — all defect-focused tracks plus enhancement opportunities.
2. Defect-Focused Comprehensive QA — all defect tracks; no enhancement catalog.
3. Security and Supply Chain Focus — AppSec, LLM/MCP security, dependency integrity, CI provenance.
4. Functionality and Correctness Focus — claims-vs-shipped, wiring, edge cases, business logic.
5. Testing and Test Quality Focus — behavioral coverage, test drift, mutation resilience, property-based gaps.
6. UI/UX and Accessibility Focus — visual hierarchy, interaction design, WCAG 2.2 AA, typography, polish, design system, UI performance, evidence-backed AI-scaffold patterns.
7. Performance and Observability Focus — runtime performance, resource use, startup, telemetry, logs, metrics, traces.
8. AI Slop and Code Provenance Focus — hallucinated APIs, phantom dependencies, confident stubs, slopsquatting, context rot, stale API usage.
9. Enhancement Opportunities Only — architecture, quality, DX, resilience, observability, UI/UX, testing. Not a bug hunt.
10. Custom Combination — user-specified tracks or subsystem.

Selecting fewer tracks narrows domain only. It never reduces depth inside selected domains.

## Depth and resource allocation contract

This contract is mandatory for every run and overrides any implicit pressure to finish quickly.

### Core invariant

Selected tracks define *domain breadth*, not *review intensity*. A selected track must receive the same or greater depth whether it is run alone, with several tracks, or as part of a complete integrated review. The orchestrator must never trade depth inside a selected track for broader track coverage.

### Focused-track expansion

When the user selects one focused track or a narrow custom track set, convert the unused breadth into deeper analysis inside that domain:

- split coverage units more granularly than the minimum when a surface, boundary, component family, test cluster, or dependency family is complex;
- trace additional caller/callee, ingress/sink, schema, config, and test relationships relevant to that track;
- run every safe deterministic command relevant to that track rather than only the fastest one;
- perform additional disproof passes for high-impact candidates and repeated patterns;
- expand runtime validation attempts when runtime behavior is central and safe to exercise;
- use more reviewer batches with smaller local reasoning scopes;
- run targeted critic passes for systemic or high-value findings even below CRITICAL/HIGH when the track is the selected focus;
- produce fuller track-specific coverage notes, limitations, and remediation/enhancement sequencing.

A single-track review should feel like a specialist audit of that domain, not a filtered version of a complete review.

### Multi-track non-dilution

When the user selects multiple tracks or all tracks, treat the run as a composition of full-depth selected-track reviews plus cross-boundary synthesis. The orchestrator must add passes, waves, and artifacts instead of shrinking per-track effort.

Forbidden multi-track shortcuts:

- using larger file batches to fit all tracks into fewer contexts;
- sampling public surfaces, trust boundaries, test clusters, component families, or AI surfaces;
- reducing caller/callee tracing because another track also needs attention;
- skipping deterministic tools that would have run in a focused version of the track;
- omitting reviewer validation or critic challenge to conserve context;
- collapsing unrelated findings into vague systemic themes without preserving exact evidence;
- writing a final report that says selected tracks ran when any selected track did not reach its own full-depth closure gate.

If the selected scope is too large for one context window or one interactive session, split by track, subsystem, coverage unit, and validation lineage. Continue only from written artifacts. If splitting still leaves a selected unit unreviewed, mark it `BLOCKED` or `SKIPPED_WITH_REASON` with exact reason and exclude unsupported conclusions from the main findings.

### Review depth plan

After 0K and before Phase 1 candidate generation, create `ledgers/review-depth-plan.md`. The plan must list each selected track, its coverage-unit basis, minimum review passes, deterministic tools to attempt, validation routing, critic routing, and cross-track dependencies. The final critic must verify this plan against completed artifacts.

Minimum per-track depth plan fields:

```text
TRACK_DEPTH_PLAN
  track: <A|B|C|D|E|F|G|1X>
  mode: focused | multi_track | complete_integrated | custom
  coverage_unit_basis: <public_surface | trust_boundary | test_cluster | ui_component_family | hot_path | dependency_family | ai_surface | domain_component | cross_boundary_pair>
  expected_units: <count or unknown_until_inventory>
  granularity_rule: <how complex units are split>
  required_passes: <inventory excerpts, candidate pass, deterministic tool pass, caller/callee trace, tests/claims check, validation, critic>
  deterministic_tools_to_attempt: <commands/tools or N/A with reason>
  runtime_validation_policy: <when to run, when to mark UNVERIFIED>
  reviewer_batch_rule: <local reasoning unit definition>
  critic_rule: <inline/final/enhancement/systemic>
  non_dilution_check: <why this track is not shallower because of selected breadth>
END
```

### Coverage unit completion depth

`REVIEWED` means more than “looked at.” For every selected track, the coverage unit must record `passes_completed`, `evidence_refs`, `deterministic_checks`, `runtime_checks_or_reason`, `validation_refs`, and `remaining_uncertainty`. A unit may close as `REVIEWED` only after the selected track’s depth plan has been satisfied for that unit.

## Artifact root

Create one run directory before track execution:

```text
.swarm/review-v8/runs/<run_id>/
  metadata.json
  source-of-truth-packet.md
  repository-context-packet.md
  artifacts/
    claims.jsonl
    surfaces.jsonl
    boundaries.jsonl
    ai-surfaces.jsonl
    ui-inventory.jsonl
    test-inventory.jsonl
    coverage.jsonl
    candidates.jsonl
    validations.jsonl
    critic.jsonl
    disproven.jsonl
    commands.jsonl
  ledgers/
    inventory-summary.md
    candidate-summary.md
    validation-summary.md
    test-drift-review.md
    strengths-ledger.md
    review-depth-plan.md
    final-critic-check.md
  review-report.md
```

Before writing under `.swarm/`, verify `.swarm/` is ignored or locally excluded. If tracked `.swarm` files exist, warn and record the fact in `metadata.json`.

## Phase 0 safe ordering

1. Run 0A alone.
2. After 0A, run 0B and 0C through `dispatch_lanes_async` only if the repository is large enough to benefit. While those lanes run, the Architect continues deterministic inventory work that does not depend on their results.
3. After 0B, run 0D and 0E through `dispatch_lanes_async` only if 0E can leave `linked_claims` blank for Architect linking in 0J. Otherwise run 0D before 0E.
4. Preferred async batch order: batch 1 = 0F and 0G; batch 2 = 0H and 0I. Never exceed two Phase 0 agents — Phase 0 inventory units (0A→0J) form a largely sequential dependency chain, so concurrency is intentionally capped at 2 to respect that ordering rather than scaled toward the 8-lane dispatch limit.
5. Run 0F after 0E when possible.
6. Run 0G after 0B and 0C.
7. Run 0H and 0I after 0B and 0C.
8. Run 0J only after all applicable 0B-0I ledgers exist.
9. Run 0K after 0J. Stop for user track selection unless preselected.
10. Run 0L after track selection and before Phase 1 candidate generation. 0L is the last Phase 0 step before Phase 1.

Collect every async batch with `collect_lane_results` before consuming its ledger output or advancing to a dependent step. If `dispatch_lanes_async` or `collect_lane_results` is unavailable, fall back to blocking `dispatch_lanes`; if deterministic dispatch is unavailable, run isolated local passes and record that fallback. Do not run dependent inventory passes merely to keep agents busy. Missing dependency context is `unknown`, not guessed.

For every collected or blocking lane result, treat `output` as a preview when `output_ref` is present. Call `retrieve_lane_output` and use the full artifact before consuming inventory ledgers, linking claims, deciding that a unit produced no candidates, or advancing a dependent step. If a lane is degraded, incomplete, truncated without a usable ref, missing, stale, cancelled, or failed, record the affected coverage unit as a limitation and re-dispatch a narrower lane or mark it UNVERIFIED; do not infer absence from preview text.

## Phase 0 inventory

### 0A — Bootstrap and prior context

Architect reads directly. Capture current directory, git branch/head/status, prior reports (`qa-report.md`, `enhancement-report.md`, `.swarm/review-*`, `OPENCODE.md`, `CLAUDE.md`, `AGENTS.md`), package manager signals, language/workspace roots, and review type: fresh, continuation, or update.

### 0B — Directory and entry point map

Explorer maps top-level directories, source roots two levels deep, likely app/server/CLI/UI/worker/test/build entry points, generated/vendored/dependency/artifact paths, and approximate reviewable file counts. No architecture judgment.

### 0C — Manifest, dependency, tooling, and CI inventory

Explorer reads every manifest, lockfile, build script, package-manager metadata, CI workflow, Docker/container file, dependency update config, and release tool. Extract raw facts only: package manager, runtime constraints, scripts, direct dependencies, observed import/manifest mismatches, CI gates, lockfiles, provenance/attestation/signing signals. Do not judge dependency risk until Track B.

Run safe deterministic tools when available: package-manager list, lockfile integrity checks, typecheck/lint dry runs, dependency audit, OSV or equivalent, CodeQL/Semgrep if already configured, and MCP/tool scanners if AI surfaces exist. Record commands and outputs in `commands.jsonl`.

### 0D — Documentation, claims, and obligations ledger

Explorer reads README, docs, changelog, release notes, migration notes, examples, comments describing public behavior, supplied PR/issue text, and test names that claim behavior. Extract claims verbatim. Do not decide truth.

### 0E — Public surface inventory

Explorer identifies routes, controllers, commands, public exports, SDK APIs, event handlers, schemas, migrations, config keys, environment variables, jobs, queues, plugin hooks, extension points, and MCP tool/resource surfaces. Record input shapes, output shapes, auth/permission signals if locally visible, and wiring targets.

### 0F — Trust boundary and data flow inventory

Explorer maps ingress to sensitive sinks. Include HTTP, WebSocket, CLI args, environment variables, files/uploads, forms, IPC, queues, webhooks, plugins, browser storage, database reads, subprocess output, LLM prompts, retrieval context, tool schemas, MCP servers, and model outputs. Record guard/auth signals as `unknown` unless visible in the same local code region.

### 0G — Test, quality gate, and drift inventory

Test engineer, if available, inventories frameworks, commands, roots, fixtures, mocks, coverage, mutation/property/e2e/snapshot tools, CI gates, test names/comments that claim behavior, and obvious surface/test gaps.

### 0H — UI, UX, and design system inventory

Designer or Explorer determines whether UI exists and inventories UI type, framework, component/page roots, styling system, token/theme files, component library defaults, accessibility tooling, visual testing, Storybook/screenshots/design docs, and structural design signals. No critique yet.

### 0I — AI, agent, and model surface inventory

Run if 0B or 0C found AI-related names or packages (`ai`, `llm`, `prompt`, `agent`, `model`, `openai`, `anthropic`, `embedding`, `vector`, `rag`, `mcp`, `tool`, `eval`). Inventory model calls, prompts, tools, function schemas, MCP servers, autonomous loops, memory, retrieval, vector stores, evaluators, moderation, output parsers, user-controlled prompt/tool inputs, downstream sinks, limits, retries, budgets, and chain depth.

### 0J — Architect synthesis

Create `source-of-truth-packet.md`, `repository-context-packet.md`, and `ledgers/inventory-summary.md`. Do not add unquoted repo facts. Verify every required Phase 0 ledger exists and is non-empty or contains explicit `NOT_APPLICABLE` reason.

Minimum adequacy gate: if fewer than five non-`NOT_APPLICABLE`, non-empty structured blocks exist across applicable Phase 0 ledgers, or inventory is too sparse to support selected scope, stop and report limitation.

The source-of-truth packet must include repo identity, tech stack, commands, public surfaces, trust boundaries, MCP/agent surfaces, claims needing verification, test gates, UI applicability, AI applicability, recommended track, and prohibited assumptions.

The repository-context packet must be concise and global: architectural style, key modules and responsibilities, primary data flows, trust boundaries, notable tech decisions, and cross-cutting patterns visible from quoted Phase 0 inventory.

### 0J-bis - PR branch checkout pre-flight

If the review target is a PR branch or commit range, complete this before Phase 1
candidate-generation dispatch:

1. Verify the working tree is clean with `git status --porcelain`. If
   uncommitted changes exist, **you (the orchestrator)** must handle them
   before any explorer/candidate dispatch — use `prepare_pr_workflow_checkout`
   (the controller-owned path; it preserves every dirty path — including
   untracked files when called with no `paths` argument — and returns a recovery
   command), or a git worktree (see `running-tests` skill precedent). Note:
   `git branch tmp/save-<topic>` only moves the HEAD ref — it does not record or
   preserve uncommitted working-tree changes, so do not rely on it to save dirty
   work. **Never delegate `git stash`, `git reset`, `git checkout -- .`,
   or `git restore` to subagents** — these are worktree-global operations that
   destroy sibling agents' in-flight work under parallel execution.
2. Fetch and check out the PR head branch locally. Explorer agents read the
   working-tree filesystem (`Read`/`Glob`/`Grep`), not git history; without the
   checkout, they inspect the base branch and produce invalid candidates.
3. Record `base_ref..head_ref` in `source-of-truth-packet.md` and pass that
   commit range in every explorer/candidate-generation delegation so lanes can
   use `git show` for revision-specific inspection.

**Subagent prohibition — must reach every subagent prompt:**
Include this line verbatim in every explorer/candidate-generation
subagent dispatch prompt:
"You are a subagent sharing a worktree with sibling agents. You MUST
NOT run `git stash`, `git reset`, `git checkout -- .`, `git restore`,
or any other worktree-global destructive git command. These destroy
sibling agents' in-flight work without error."

### 0K — User review mode gate

Stop and present the ten review choices unless the user’s original request already selected tracks and explicitly authorized continuing. If the user selects a focused review, do not run unrelated tracks; record omitted tracks in coverage notes.

### 0L — Review depth plan

After track selection and before candidate generation, write `ledgers/review-depth-plan.md` using the `TRACK_DEPTH_PLAN` block. This is the binding execution plan for selected-track depth.

Rules:

- Focused mode must show how unused breadth becomes deeper pass structure for the selected track.
- Multi-track and complete-integrated modes must show that every selected track keeps the same closure gate it would have had as a focused review.
- If the plan cannot allocate a full-depth path for a selected track, stop before Phase 1 and report the blocker instead of running a diluted review.
- Phase 5 final critic must compare the completed run to this plan.

## Phase 1 — Candidate generation

Every dispatch includes selected track(s), exact file list or surface IDs, source-of-truth packet, repository-context packet, relevant ledgers, the applicable `TRACK_DEPTH_PLAN`, candidate format, `out_of_scope_note` rule, and anti-cursory/non-dilution reminder. Prefer `dispatch_lanes_async` for independent candidate-generation coverage units so the Architect can continue building the review ledger, coverage map, and validation routing while lanes inspect subsystems. Call `collect_lane_results` before Phase 2 reviewer validation; no candidate may be routed, counted, or synthesized until its async batch has settled or been explicitly marked blocked/skipped.

If candidate-generation lane results include `output_ref`, retrieve and parse the full artifact before candidate counting, deduplication, routing, or synthesis. Preview-only, degraded, or incomplete lane output is a coverage limitation, not negative evidence.

File-size rule: no more than 15 files per deep pass; no more than 8 dense files per deep pass. Dense = >300 logical lines, multiple unrelated responsibilities, or interleaved UI/state/network/security logic. No sampling inside assigned scope. Large selections require more deep passes, not larger batches or lower depth.

Candidate micro-loop:

```text
1. What exact line or config proves current state?
2. What claim, contract, boundary, or quality standard is it compared against?
3. What alternative interpretation would make the concern false?
4. Did I check that alternative interpretation?
5. Is there still at least MEDIUM confidence?
6. Grounding check: does the candidate align precisely with quoted context without overclaim, missing surrounding logic, or unsupported inference? Rate HIGH / MEDIUM / LOW.
7. If yes and grounding is not LOW, emit candidate. Otherwise record uncertainty only.
```

### Track A — Functionality, correctness, and claims-vs-shipped

Run for modes 1, 2, 4, or custom behavior review. Build one coverage unit for every public surface. A `REVIEWED` surface has entry point read, implementation traced, tests checked, claims compared, and evidence captured.

Check wiring/reachability, claims vs implementation, logic correctness, async correctness, persistence/data-model drift, feature flags/config drift, cross-platform assumptions, error handling, timeouts, and happy-path-only behavior.

### Track B — Security, privacy, LLM/MCP security, and supply chain

Run for modes 1, 2, 3, or custom security review. Build one coverage unit for every trust boundary and every AI surface. In focused Track B mode, split complex boundaries by ingress, guard, sink, privilege context, data sensitivity, deployment/runtime context, and dependency or CI provenance family. A `REVIEWED` boundary has source, guard, sink, impact, callers, authz, exploitability/disproof path, relevant tests, deterministic scanner/dependency checks, and safe runtime validation checked.

Apply OWASP ASVS 5.0.0 for web controls. Apply OWASP Top 10 for LLM Applications 2025 for LLM/agent/RAG/MCP surfaces: prompt injection, sensitive information disclosure, supply chain, data/model poisoning, improper output handling, excessive agency, system prompt leakage, vector/embedding weaknesses, misinformation, and unbounded consumption.

MCP-specific checks: tool description poisoning, hidden instructions in tool metadata, untrusted resource content, context exfiltration to tools/logs, server-chain lateral movement, missing allow-lists, missing per-session permissions, arbitrary server URLs, and anomalous request/response behavior.

Supply-chain checks: phantom imports, undeclared dependencies, non-existent packages, typosquatting/dependency confusion/slopsquatting, unbounded ranges, install scripts, binary downloads, native addons, pinned actions, token scopes, artifact signing, SLSA v1.2 provenance/attestation, dependency update tooling, and OpenSSF Scorecard-style hygiene.

### Track C — Testing and test quality

Run for modes 1, 2, 5, or custom testing review. Build coverage units for test clusters, fixture/helper clusters, and public surfaces with test implications. In focused Track C mode, split by behavior domain, fixture/helper family, mocking boundary, assertion style, and negative/edge-case family. Passing tests and coverage percentages are not proof. Test names are claims.

Check behavior vs implementation assertions, stale mocks/fixtures, weak assertions, snapshot masking, missing negative/edge cases, async test correctness, isolation leakage, mutation resilience, property-based opportunities, CI gates, and whether tests would fail for the claimed bug.

### Track D — UI/UX and accessibility

Run for modes 1, 2, 6, or custom UI review only if 0H found UI. Build coverage units for every component family. In focused Track D mode, split by page/route, interaction flow, component family, state variant, responsive breakpoint, accessibility mechanism, and design-token dependency. All UI passes must read component files, not infer from names.

Apply WCAG 2.2 AA. Check visual hierarchy, layout, primary actions, information architecture, interaction feedback, keyboard/focus/ARIA/contrast, typography, responsive behavior, loading/empty/error states, UI performance, consistency, design tokens, and evidence-backed unmodified AI-scaffold defaults. Never report vibe-based UI slop.

### Track E — Performance and observability

Run for modes 1, 2, 7, or custom performance/observability review. Build coverage units for hot paths, startup paths, I/O paths, resource-heavy jobs, and telemetry boundaries. In focused Track E mode, split by operation class, input cardinality, resource dimension, deployment lifecycle, and telemetry signal path; require measurement or conservative caveat for performance claims.

Check algorithmic complexity, synchronous/blocking work, memory growth, N+1 calls, caching, batching, retries/timeouts, startup cost, bundle size where applicable, logs, metrics, traces, context propagation, correlation IDs, error reporting, redaction, and production diagnosability.

### Track F — AI slop and code provenance

Run for modes 1, 2, 8, or custom AI/provenance review. Build coverage units for dependency families, recently added/generated-looking clusters only when evidence exists, repeated code patterns, public claims, tests, and AI/tool surfaces. In focused Track F mode, split by package ecosystem, API family, repeated abstraction pattern, generated-code signal with concrete evidence, claim family, mock-only test family, and AI/tool boundary.

Check phantom dependencies, hallucinated APIs, stale framework signatures, confident stubs, unsupported public claims, over-abstraction, duplicated semantic code, mock-only tests, context rot, security theater, slopsquatting, copy-paste drift, and UI scaffold defaults. Requires exact quote and concrete consequence.

### Track G — Enhancement opportunities only

Run for mode 1, 9, or custom enhancement review. Do not hunt defects. Build coverage units by architecture/domain/component family. In focused Track G mode, split by architecture domain, code-quality cluster, developer workflow, resilience/observability concern, test improvement family, and UI improvement family when UI exists. Current code must be framed as working unless evidence proves a defect.

Evaluate architecture, code quality, simplification, developer experience, performance headroom, resilience, observability, test robustness, and UI/UX improvements. Report only high/medium-value opportunities unless user requests exhaustive low-value cleanup. Every final enhancement requires critic validation.

### Phase 1X — Cross-boundary review

Run when two or more tracks ran and quoted cross-track evidence can be compared. For multi-track/all-track reviews, this pass is mandatory unless there is an explicit `NOT_APPLICABLE` reason proving no cross-track comparison is possible. Check caller/callee mismatches, UI/API/schema drift, docs/API/test drift, auth assumptions across middleware/handlers, config-name drift, shared-state assumptions, generated type/schema drift, package scripts calling missing files, and AI prompt/tool boundaries crossing security sinks.

## Phase 2 — Reviewer validation

Validate candidates in small local reasoning batches: same file, route chain, subsystem, dependency family, public claim, trust boundary, UI component family, or test fixture/helper. Do not validate dozens of unrelated candidates together.

Reviewer must re-open exact file and line, read raw file independently before explorer paraphrase, read enough surrounding context, check callers/callees/tests/manifests/configs/schemas/routes/generated files/docs, check mitigating controls, run safe minimal runtime validation where needed, recalibrate severity/value, record disproof reason, and mark `UNVERIFIED` when evidence is insufficient.

CRITICAL/HIGH confirmed or pre-existing findings route to inline critic. MEDIUM/LOW confirmed/pre-existing findings require reviewer finalization. Disproved and unverified items do not enter main findings.

## Phase 2C — Inline critic for CRITICAL/HIGH defects

Run immediately after each reviewer batch containing CRITICAL/HIGH confirmed/pre-existing findings. Critic checks whether the finding is real, severity justified, runtime validation sufficient, fix actionable, no mitigating control missed, no overclaim beyond evidence, and whether sibling coverage is required. Only `UPHELD`, `REFINED`, or `DOWNGRADED` items continue.

## Phase 2M — Reviewer finalization for MEDIUM/LOW defects

Reviewer confirms each item is not style preference, not severity-inflated, supported by evidence, actionable, and not mitigated. Only finalized/downgraded items continue.

## Phase 2E — Enhancement critic

Every report-eligible enhancement is challenged for evidence, value, concreteness, effort, complexity cost, style/intent fit, duplication, and merge/split/downgrade/reject decision. Only upheld/refined/merged/downgraded enhancements continue.

## Phase 3 — Test validation and drift review

Run if any selected track touches functionality, testing, security, public claims, CI, or behavior. If Track C did not run, limit to test drift arising from other findings. Confirm behavior assertions, fixture freshness, mock realism, snapshot quality, property-based opportunities, mutation resilience gaps, and focused commands run.

## Phase 4 — Architect synthesis

Synthesize only validated evidence. Drop disproved/overturned. Keep unverified only in coverage notes. Deduplicate same root cause. Merge repeated patterns only with evidence. Separate defects from enhancements, unsupported claims from code defects, and AI slop patterns from normal technical debt. Count rejected/unverified items. Create strengths ledger with quoted evidence only. Verify coverage closure. If any selected-track coverage unit is `UNASSIGNED` or `UNREVIEWED`, return to Phase 1. Verify completed artifacts against `ledgers/review-depth-plan.md`; if any selected track was diluted relative to its plan, return to the relevant phase or mark precise units blocked/skipped with reason.

## Phase 5 — Final whole-report critic

Before writing final report, run adversarial final critic against planned synthesis. It must check evidence, validation routing, critic routing, severity/value calibration, defect/enhancement separation, unverified exclusion, strengths evidence, UI concreteness, security exploitability, performance measurement caveats, AI-slop evidence, claim ledger support, honest coverage notes, counts consistency, zero unreviewed coverage, selected-track completeness, and compliance with `ledgers/review-depth-plan.md` including focused-track expansion and multi-track non-dilution.

If verdict is `REVISE`, revise synthesis and rerun final critic until `PASS`.

## Phase 6 — Final report

Write `review-report.md` in the run directory only after final critic PASS. Use `assets/review-report-template.md`. Final assistant response reports run path, selected tracks, coverage units closed, defect/enhancement counts, candidates filtered, final critic verdict, highest-risk confirmed findings, highest-value enhancements if applicable, coverage limitations, and “No source files were modified.”
