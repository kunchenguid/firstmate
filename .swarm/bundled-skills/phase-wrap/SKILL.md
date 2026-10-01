---
name: phase-wrap
audience: swarm-plugin
description: >
  Full execution protocol for MODE: PHASE-WRAP -- phase boundary evidence, drift and hallucination gates, retrospectives, phase completion, and final council.
---

# Phase Wrap Protocol

This protocol is loaded on demand by the architect runtime. The architect prompt keeps only activation, action, and hard safety constraints; the full execution details live here.

## Graph-first evidence contract

Before final phase judgment, use `repo_map` `diff_context`, `impact_cone`, and `test_pack` to audit the changed surface and likely tests. Graph evidence is advisory only. If freshness is stale or inconclusive, confidence is low, source is missing, the language is unsupported/dynamic, the graph is absent, or an action fails, inspect the direct source, Git diff, and executable test evidence.

## ⛔ RETROSPECTIVE GATE

**MANDATORY before calling phase_complete.** You MUST write a retrospective evidence bundle BEFORE calling \`phase_complete\`. The tool will return \`{status: 'blocked', reason: 'RETROSPECTIVE_MISSING'}\` if you skip this step.

**How to write the retrospective:**

Call the \`write_retro\` tool with the required fields:
- \`phase\`: The phase number being completed (e.g., 1, 2, 3)
- \`verdict\`: Explicit phase outcome, either \`pass\` or \`fail\`
- \`summary\`: Human-readable summary of the phase
- \`task_count\`: Count of tasks completed in this phase
- \`task_complexity\`: One of \`trivial\` | \`simple\` | \`moderate\` | \`complex\`
- \`total_tool_calls\`: Total number of tool calls in this phase
- \`coder_revisions\`: Number of coder revisions made
- \`reviewer_rejections\`: Number of reviewer rejections received
- \`test_failures\`: Number of test failures encountered
- \`security_findings\`: Number of security findings
- \`integration_issues\`: Number of integration issues
- \`lessons_learned\` ("lessons_learned"): (optional) Key lessons learned from this phase (max 5)
- \`top_rejection_reasons\`: (optional) Top reasons for reviewer rejections
- \`metadata\`: (optional) Additional metadata, e.g., \`{ "plan_id": "<current plan title from .swarm/plan.json>" }\`

The tool will automatically write the retrospective to \`.swarm/evidence/retro-{phase}/evidence.json\` with the correct schema wrapper. The resulting JSON entry will include: \`"type": "retrospective"\`, \`"phase_number"\` (matching the phase argument), and the exact caller-supplied \`"verdict"\`.

**Required field rules:**
- \`verdict\` must be explicit on every write. Use \`"pass"\` only when the phase genuinely passed; use \`"fail"\` when the retrospective is truthfully recording an unresolved or forced-close outcome.
- \`phase\` MUST match the phase number you are completing
- \`lessons_learned\` should be 3-5 concrete, actionable items from this phase
- Write the bundle as task_id \`retro-{N}\` (e.g., \`retro-1\` for Phase 1, \`retro-2\` for Phase 2)
- \`metadata.plan_id\` should be set to the current project's plan title (from \`.swarm/plan.json\` header). This enables cross-project filtering in the retrospective injection system.

### Additional retrospective fields (capture when applicable):
- \`user_directives\`: Any corrections or preferences the user expressed during this phase
  - \`directive\`: what the user said (non-empty string)
  - \`category\`: \`tooling\` | \`code_style\` | \`architecture\` | \`process\` | \`other\`
  - \`scope\`: \`session\` (one-time, do not carry forward) | \`project\` (persist to context.md) | \`global\` (user preference)
- \`approaches_tried\`: Approaches attempted during this phase (max 10)
  - \`approach\`: what was tried (non-empty string)
  - \`result\`: \`success\` | \`failure\` | \`partial\`
  - \`abandoned_reason\`: why it was abandoned (required when result is \`failure\` or \`partial\`)

**⚠️ WARNING:** Calling \`phase_complete(N)\` without a valid \`retro-N\` bundle will be BLOCKED. The error response will be:
\`{ "status": "blocked", "reason": "RETROSPECTIVE_MISSING" }\`

### MODE: PHASE-WRAP
1. the active swarm's explorer agent - Rescan
2. the active swarm's docs agent (the standard `docs` agent — NOT `docs_design`) - Update documentation for all changes in this phase. Provide:
   - Complete list of files changed during this phase
   - Summary of what was added/modified/removed
   - List of doc files that may need updating (README.md, CONTRIBUTING.md, docs/)
   Do NOT dispatch `docs_design` here. The structured design docs are synced separately and conditionally in step 5.58.
3. Update context.md
4. Write retrospective evidence: use the evidence manager (write_retro) to record phase, total_tool_calls, coder_revisions, reviewer_rejections, test_failures, security_findings, integration_issues, task_count, task_complexity, top_rejection_reasons, lessons_learned to .swarm/evidence/. Reset Phase Metrics in context.md to 0.
4.5. Run `evidence_check` to verify all completed tasks have required evidence (review + test). If gaps found, note in retrospective lessons_learned. Optionally run `pkg_audit` if dependencies were modified during this phase. Optionally run `schema_drift` if API routes were modified during this phase.
5. Run `sbom_generate` with scope='changed' to capture post-implementation dependency snapshot (saved to `.swarm/evidence/sbom/`). This is a non-blocking step - always proceeds to summary.
5.5. **Drift verification**: Conditional on an EFFECTIVE spec existing (determined via `/swarm sdd status` or `readEffectiveSpecSync` — native `.swarm/spec.md`, OpenSpec `openspec/`, or Spec-Kit `.specify/`). If NO effective spec exists at all, skip silently. If an effective spec exists (even openspec-only or specify-only), delegate to the active swarm's critic_drift_verifier agent with DRIFT-CHECK context:
   - Provide: phase number being completed, completed task IDs and their descriptions
   - Include evidence path (.swarm/evidence/) for the critic to read implementation artifacts
   The critic reads every target file, verifies described changes exist against the spec, and returns per-task verdicts: ALIGNED, MINOR_DRIFT, MAJOR_DRIFT, or OFF_SPEC.
   If the critic returns anything other than ALIGNED on any task, surface the drift results as a warning to the user before proceeding.
   After the delegation returns, YOU (the architect) call the `write_drift_evidence` tool to write the drift evidence artifact (phase, verdict from critic, summary). The critic does NOT write files — it is read-only. Only then proceed to step 5.55. phase_complete will also run its own deterministic pre-check (completion-verify) and block if tasks are obviously incomplete.
   ⚠️ **GOTCHA**: The drift evidence `summary` field is scanned by gates for verdict keywords. NEVER include the string "NEEDS_REVISION" or any other verdict word in the summary text — the gate will match it and falsely reject the evidence even when the verdict is APPROVED. Use neutral language like "drift verification completed" or "all tasks aligned with spec".
5.55. **Hallucination verification (conditional on QA gate)**: Check whether `hallucination_guard` is enabled in the effective QA gate profile for this plan (visible via `get_qa_gate_profile`). If disabled, skip silently and proceed to step 5.6.
   If `hallucination_guard` is enabled, delegate to the active swarm's critic_hallucination_verifier agent with HALLUCINATION-CHECK context:
   - Provide: phase number being completed, completed task IDs, every file touched this phase
   - Include evidence path (.swarm/evidence/) so the verifier can read implementation artifacts
   The verifier reads every changed file cold, cross-references every named API against its real source or package manifest, and returns per-artifact verdicts across four axes: API existence, signature accuracy, doc/spec claim support, citation integrity.
   If the verifier returns NEEDS_REVISION: STOP — do NOT call phase_complete.
   Fix the hallucinations (remove fabricated APIs, correct signatures, repair broken citations), then re-delegate until APPROVED.
   After the delegation returns APPROVED, YOU (the architect) call the `write_hallucination_evidence` tool to write the evidence artifact (phase, verdict, summary). The critic does NOT write files — it is read-only.
   NOTE: This step is enforced by the plugin. If `hallucination_guard` is enabled and `.swarm/evidence/{phase}/hallucination-guard.json` is missing or has a non-APPROVED verdict, phase_complete will be BLOCKED.
   PROFILE LOCK NOTE: If the QA gate profile is already locked (drift verification has approved the plan) and `hallucination_guard` was not elected during the initial QA GATE SELECTION, this step is skipped — report the skip to the user. A new plan cycle is required to enable the gate.
5.56. **Mutation gate (conditional on QA gate)**: Check whether `mutation_test` is enabled in the effective QA gate profile for this plan (visible via `get_qa_gate_profile`). If disabled or turbo mode is active, skip silently and proceed to step 5.6.
   If `mutation_test` is enabled:
   1. Call `generate_mutants` with the list of source files touched this phase to produce mutation patches.
   2. If `generate_mutants` returns a SKIP verdict (LLM unavailable), call `write_mutation_evidence` with verdict SKIP and proceed — SKIP does not block.
   3. Otherwise, call `mutation_test` with the generated patches, the source files, and the test command for this project.
   4. Call `write_mutation_evidence` with the phase number, verdict (PASS/WARN/FAIL), killRate, adjustedKillRate, and summary from the mutation_test result.
   5. If verdict is FAIL: STOP — do NOT call phase_complete. Provide the testImprovementPrompt from mutation_test to the coder to improve test coverage, then re-run from step 1.
   6. If verdict is WARN: non-blocking — proceed to step 5.6 with a warning to the user.
   7. If verdict is PASS: proceed to step 5.6.
   NOTE: This step is enforced by the plugin. If `mutation_test` is enabled and `.swarm/evidence/{phase}/mutation-gate.json` is missing or has a 'fail' verdict, phase_complete will be BLOCKED.
5.58. **Design-doc sync (conditional on `design_docs.enabled` — issue #1080)**: If `design_docs.enabled` is not true, skip silently. Otherwise: `phase_complete` runs a deterministic, non-blocking design-doc drift check and writes `.swarm/doc-drift-phase-{phase}.json`. If its verdict is `DOC_STALE`, enter MODE: DESIGN_DOCS in sync mode for the stale sections only — delegate to the active swarm's `docs_design` agent (NOT the standard `docs` agent) with the changed files + the stale section IDs, and have it update the affected docs and append a `design-changelog.md` entry. This is advisory and NON-BLOCKING — never hold up phase_complete on design-doc lag, and never write `.swarm/spec.md`, `CHANGELOG.md`, or `docs/releases/pending/*` here.
5.59. **Required agent dispatch for phase_complete**: Before calling `phase_complete`, the architect MUST have dispatched each of the active swarm's standard agents at least once during this phase. By default, `phase_complete` requires these agents:

| Agent | When required | Where dispatched during normal task execution |
|---|---|---|
| `coder` | Always | Task implementation (coder) |
| `reviewer` | Always | Task review (reviewer) |
| `test_engineer` | When phase modifies source code/tests (unless explicitly waived) | Test verification (test_engineer) |
| `docs` | When `phase_complete.require_docs: true` in plugin configuration | Documentation updates |

If any required agent is missing, `phase_complete` returns `{ success: false, status: 'incomplete', message: 'Phase N incomplete: missing required agents: <list>', agentsMissing: [...] }` and the phase is not closed. Dispatch each agent during normal task execution (not only inside optional Phase/Final Councils in steps 5.65/5.7) so the closeout gate is satisfied.

The `docs` agent requirement is controlled by `phase_complete.require_docs` in plugin configuration, not by the QA gate profile returned by `get_qa_gate_profile`. It defaults to `true`. Set it to `false` only when the phase genuinely has no documentation obligation. A successful docs completion is persisted as plan- and phase-bound participation proof so `phase_complete` can recover it after a session restart; unrelated task-gate evidence does not count as docs participation.

Docs-attestation integrity (issue #1994 P2): when the docs agent concludes that a phase — especially a doc-only phase — needs no further documentation edits, that attestation is valid ONLY if the docs agent actually inspected the phase's changed files and recorded what it checked (files read, per-file verdict) in its completion report. A mechanical "no edits needed" reply dispatched only to satisfy `agentsDispatched` — without inspecting the phase's changes — is a process violation: the gate exists to catch documentation drift, not to be acknowledged past.

The `coder` and `test_engineer` agents are required because every phase that modifies source code or tests must have at least one implementation and one test-verification delegation. For pure documentation or retrospective phases, these may be waived by the user explicitly.

This is a hard enforcement mechanism, not a suggestion. `phase_complete` will not return `status: success` if any required agent is missing from `agentsDispatched`.

CATASTROPHIC VIOLATION CHECK — ask yourself at EVERY phase boundary (MODE: PHASE-WRAP):
"Have I delegated to each of the active swarm's required agents (coder, reviewer, test_engineer, plus docs if required) at least once this phase?"
If the answer is NO for any of them: you have a catastrophic process violation.
STOP. Do not proceed to the next phase. Inform the user:
"⛔ PROCESS VIOLATION: Phase [N] completed with missing required-agent delegations in the active swarm: [list missing agents].
All code changes in this phase are unreviewed/untested/undocumented. Recommend retrospective review before proceeding."
This is not optional. Missing required-agent calls in a phase is always a violation.
There is no project where code ships without review, tests, and required documentation.

5.6. **Mandatory gate evidence**: Before calling phase_complete, ensure:
   - `.swarm/evidence/{phase}/completion-verify.json` exists (written automatically by the completion-verify gate)
    - `.swarm/evidence/{phase}/drift-verifier.json` exists with verdict 'approved' (written by YOU via the `write_drift_evidence` tool after the critic_drift_verifier returns its verdict in step 5.5) — required when an effective spec exists
   - `.swarm/evidence/{phase}/hallucination-guard.json` exists with verdict 'approved' (written by YOU via the `write_hallucination_evidence` tool after the critic_hallucination_verifier returns its verdict in step 5.55) — ONLY required when `hallucination_guard` is enabled in the QA gate profile
   - `.swarm/evidence/{phase}/mutation-gate.json` exists with verdict 'pass' or 'warn' (written by YOU via the `write_mutation_evidence` tool after step 5.56) — ONLY required when `mutation_test` is enabled in the QA gate profile
   - `.swarm/evidence/{phase}/phase-council.json` exists with the collected council member verdicts (written by YOU via the `submit_phase_council_verdicts` tool after the phase council in step 5.65 returns its verdicts) — ONLY required when `phase_council` is enabled in the QA gate profile
    - regression-test falsification evidence exists for at least one regression
      test added or modified in this phase: fix removed/bypassed -> test fails
      for the expected reason -> fix restored -> test passes. If the phase
      changed no regression tests, record `not applicable` with the changed-file
      evidence.
    If any required file is missing, run the missing gate first. Turbo mode skips all gates automatically.
   NOTE: Steps 5.5, 5.55, and 5.56 are enforced by runtime hooks. If `hallucination_guard` is enabled and you skip the critic_hallucination_verifier delegation (or fail to call `write_hallucination_evidence`), phase_complete will be BLOCKED by the plugin. Similarly, if `mutation_test` is enabled and you skip step 5.56 (or fail to call `write_mutation_evidence`), phase_complete will be BLOCKED. These are not suggestions — they are hard enforcement mechanisms.
5.65. **Phase Council (conditional on QA gate — `phase_council`)**: Check whether `phase_council` is enabled in the effective QA gate profile (visible via `get_qa_gate_profile`). If disabled, skip silently and proceed to step 5.7.
   This gate is triggered by the `phase_council` QA gate, NOT by `council_mode`. (`council_mode` controls per-task Stage B replacement in MODE: EXECUTE; `phase_council` controls holistic phase-level review here in MODE: PHASE-WRAP.)
   If `phase_council` is enabled:
   1. Build a PHASE DOSSIER from all completed tasks in this phase, their evidence artifacts, changed-file summaries, and any drift/hallucination/mutation evidence.
   2. Dispatch the full 5-member council (`the active swarm's critic agent`, `the active swarm's reviewer agent`, `the active swarm's sme agent`, `the active swarm's test_engineer agent`, and `the active swarm's explorer agent`) in PARALLEL with phase-scoped context. Each member reviews the entire phase's work holistically and returns a `CouncilMemberVerdict` JSON object.
      → REQUIRED: The reviewer council member Task dispatch MUST contain a literal `ACCEPTANCE:` line — resolve per ACCEPTANCE FIELD RESOLUTION in your system prompt (phase-scoped: concatenate the verbatim FR/SC text for every task in this phase when fr_refs is non-empty — the delegation gate does NOT auto-inject for multi-task phase/council dispatches, so paste the bodies yourself — otherwise a one-line phase-derived DONE restatement). A missing line is BLOCKED by ACCEPTANCE_FIELD_REQUIRED. The other four members are not gated by this rule.
   3. Collect all 5 verdict objects. Do NOT fabricate or substitute verdicts.
   4. Act on the verdict: APPROVE → proceed. CONCERNS with `success: false` + `reason: 'blocking_concerns_unresolved'` → HIGH/CRITICAL findings are blocking, no evidence written, must resolve requiredFixes and re-council. CONCERNS with `success: true` → only MEDIUM/LOW advisory findings, phase may proceed per `phaseConcernsAllowComplete` flag. REJECT → surface required fixes to the user before proceeding.
   5. YOU (the architect) call the `submit_phase_council_verdicts` tool with the phase number and the collected council verdicts to persist the phase-council evidence. The council members do NOT write files — they are read-only. Only the `submit_phase_council_verdicts` tool writes `.swarm/evidence/{phase}/phase-council.json` (with plan binding, member verdicts, and quorum metadata). Do this BEFORE calling `phase_complete`.
   Requires council.enabled: true in config.

5.7. **Final Council (conditional on QA gate - last phase only)**: Check whether `final_council` is enabled in the effective QA gate profile (visible via `get_qa_gate_profile`). If disabled, skip silently and proceed to step 6.
   If enabled AND this is the LAST phase in the plan (all other phases have status 'complete' and no more phases remain):
   1. Build a PROJECT DOSSIER from the completed plan, all phase summaries, changed-file summaries, and all relevant evidence artifacts. This is the full 5-member council (NOT the General Council) running a completed-project review.
   2. Dispatch the full 5-member council (`the active swarm's critic agent`, `the active swarm's reviewer agent`, `the active swarm's sme agent`, `the active swarm's test_engineer agent`, and `the active swarm's explorer agent`) in PARALLEL with project-scoped context. Each member must review the entire completed body of work and return a `CouncilMemberVerdict` JSON object using `agent`, `verdict` (APPROVE|CONCERNS|REJECT), `confidence`, `findings[]`, `criteriaAssessed[]`, `criteriaUnmet[]`, and `durationMs`.
      → REQUIRED: The reviewer council member Task dispatch MUST contain a literal `ACCEPTANCE:` line — resolve per ACCEPTANCE FIELD RESOLUTION in your system prompt (project-scoped: concatenate the verbatim FR/SC text across all phases — the delegation gate does NOT auto-inject for multi-task dispatches, so paste the bodies yourself — otherwise a one-line project-derived DONE restatement). A missing line is BLOCKED by ACCEPTANCE_FIELD_REQUIRED. The other four members are not gated by this rule.
   3. Collect the five returned verdict objects. Do NOT fabricate, infer, or substitute verdicts. If a member does not return valid JSON, re-dispatch that member.
   4. Call `write_final_council_evidence` with `phase`, `projectSummary`, `roundNumber`, and the collected `verdicts` array. This writes `.swarm/evidence/final-council.json` with plan binding, member verdicts, and quorum metadata.
   ⚠️ **GOTCHA**: `write_final_council_evidence` normalizes a CONCERNS verdict based on whether there are required fixes. CONCERNS with `requiredFixes > 0` → the tool writes NO evidence file (early-return `blocking_concerns_unresolved`) and `phase_complete` then blocks on the MISSING `final-council.json`. CONCERNS with zero required fixes → the tool writes a `concerns` verdict which is NON-blocking (advisory warning only). So: you MUST address required fixes from a CONCERNS verdict and re-council, or you will block on a missing evidence file. (Note: the **phase-level** council's `phaseConcernsAllowComplete` flag makes CONCERNS advisory at phase scope; the final council does not have that flag.)
   5. Do NOT call `convene_general_council`, do NOT dispatch `council_generalist`, `council_skeptic`, or `council_domain_expert`, and do NOT require `council.general.enabled` for this gate. `final_council` is the full 5-member council (NOT the General Council) rerun at project scope.
   6. Do NOT call `phase_complete` or `/swarm close` until `.swarm/evidence/final-council.json` exists with an approved, plan-bound, quorumed final-council verdict. When `final_council` is enabled, `phase_complete` will block until that evidence exists.
   If enabled but NOT the last phase, skip silently - final council only runs once, after all phases.
6. Summarize to user
7. Check the AUTO_PROCEED STATUS banner (injected into your context by the system-enhancer). The banner shows:
   - `auto-proceed: <on|off>` — the current effective value
   - `source: <session|plan-or-default>` — which side it came from
   - `nudge: <true|false>` — whether the FR-004 first-boundary nudge has already been done
   Then branch:
   - If `auto-proceed: on`: call `phase_complete`, then advance to the first task of the next phase. Do NOT ask the user.
   - If `auto-proceed: off` AND `nudge: false`: after the user confirms the phase transition, suggest enabling auto-proceed. Use the swarm_command tool to record the user's answer: `swarm_command({ command: "auto-proceed", args: ["on"] })` for yes, `swarm_command({ command: "auto-proceed", args: ["off"] })` for no. Either call sets nudge to true and prevents re-nudging.
   - If `auto-proceed: off` AND `nudge: true`: Ask "Ready for Phase [N+1]?" and wait for user confirmation before proceeding.

### Blockers
Mark the task [BLOCKED] via `update_task_status` (do not hand-edit plan.md — it is a derived projection), skip to next unblocked task, inform user.
