---
name: swarm-plan
audience: swarm-plugin
description: >
  Full execution protocol for MODE: PLAN -- plan creation, external plan ingestion, QA gate persistence, task granularity, and traceability checks.
---

# Plan Protocol

This protocol is loaded on demand by the architect runtime. The architect prompt keeps only activation, action, and hard safety constraints; the full execution details live here.

## Graph-first evidence contract

Before planning, call `repo_map` with `graph_health`, then `package_boundaries` and `key_files`, followed by a targeted source-bearing `context_pack`; a `preflight_packet` (bounded ontology of roles, routes, data, and security findings) frames planning risk, and per-file `ontology` facts sharpen it. Graph evidence is advisory only. If freshness is stale or inconclusive, confidence is low, source is missing, the language is unsupported/dynamic, the graph is absent, or an action fails, inspect the direct source and searches before committing the plan.

### MODE: PLAN

PLANNING PROFILE (authoritative): obey the runtime-injected `[PLANNING PROFILE
— AUTHORITATIVE]` directive, which is produced by the same resolver used by
`save_plan`. Select exactly one path:

- `balanced`: use durable QA/execution defaults and do not pause for the full
  questionnaire, spec ceremony, or complete clarification funnel. Ask only for
  unresolved material ambiguity, destructive/high-risk authorization, or a
  decision only the user can make. `save_plan` exact-binds the default QA
  profile. Persist `planning_profile: "balanced"`.
- `strict` (including locked legacy profiles with no stored field): require an
  effective spec, run the complete clarification funnel, present the unified
  QA/execution questionnaire, and wait for the user's answers before saving.
  Persist `planning_profile: "strict"` only when the field is already explicit
  or this is a new/unlocked plan; do not materialize it into a locked legacy
  profile.

A locked profile may ratchet `balanced` to `strict`; it never moves `strict` to
`balanced`.

SPEC POLICY (profile-dependent — check before planning):

An effective spec exists iff `/swarm sdd status` reports a resolved spec (it reflects `readEffectiveSpecSync`, which returns null for no sources, multiple competing sources, multi-feature Spec-Kit without a selected feature, or any unresolvable state). Do NOT enumerate these cases — defer to `/swarm sdd status`.

- If NO effective spec exists (confirmed via `/swarm sdd status`):
  - `strict`: stop and enter MODE: SPECIFY (or materialize a selected SDD source
    with explicit consent). Strict planning cannot save without an effective
    spec.
  - `balanced`: a spec is optional. Offer the choices below only when a spec
    would materially resolve ambiguity; otherwise proceed directly.
  - The remaining no-spec choices in this section apply only to `balanced`.
  - PLAN INGESTION DETECTION: Check if the user is providing an external plan (indicators: markdown content with Phase/Task structure, or phrases like "ingest this plan", "implement this plan", "prepare for implementation", "here is a plan", "here's the plan"):
    - If plan ingestion is detected AND no effective spec exists: offer this choice FIRST before any planning:
      1. "Generate spec from this plan first" → enter EXTERNAL PLAN IMPORT PATH in MODE: SPECIFY to reverse-engineer a spec.md from the provided plan, then return to planning
      2. "Skip spec and proceed with the provided plan" → proceed directly to plan ingestion and planning without creating a spec
    - In `balanced`, this is a SOFT gate — option 2 lets the user proceed without a spec.
  - If no plan ingestion detected: Warn: "No effective spec found. A spec helps ensure the plan covers all requirements and gives the critic something to verify against. Would you like to create one first?"
    - Offer two options:
      1. "Create a spec first" → transition to MODE: SPECIFY
      2. "Skip and plan directly" → continue with the steps below unchanged
- If an effective spec EXISTS:
  - NOTE: Stale detection is intentionally heuristic (compare headings) — false positives are acceptable because this is a SOFT gate. When in doubt, ask the user.
  - Read the spec (using the effective spec path reported by `/swarm sdd status`) and compare its first heading (or feature description) against the current planning context (the user's request and any existing plan.md title/phase names)
  - STALE SPEC DETECTION: If the spec heading or feature description does NOT match the current work being planned (e.g., spec describes "user authentication" but user is asking to plan "payment integration"), treat the spec as potentially stale. In `strict`, offer options 1 and 2 only. In `balanced`, offer all three options:
    1. **Archive and create new spec** → attempt to rename .swarm/spec.md to .swarm/spec-archive/spec-{YYYY-MM-DD}.md (create the directory if needed); if archival succeeds: enter MODE: SPECIFY and skip the "spec already exists" prompt; if archival fails: inform user of the failure and offer: retry archival, or proceed with option 2, or proceed with option 3
    2. **Keep existing spec** → use the effective spec as-is and proceed with planning below
    3. **Skip spec entirely** (`balanced` only) → proceed to planning below ignoring the existing spec
  - If the spec appears current (heading matches the work being planned) OR user chose option 2 above, proceed with spec:
    - Read it and use it as the primary input for planning
    - Cross-reference requirements (FR-###) when decomposing tasks
    - Ensure every FR-### maps to at least one task
    - If a task has no corresponding FR-###, flag it as a potential gold-plating risk
  - If a `balanced` user chose option 3 above, proceed without spec: skip all spec-based steps and proceed directly to planning

This is a soft gate only in `balanced`. In `strict`, a missing effective spec is
a hard prerequisite and `save_plan` will return `SPEC_REQUIRED`.

**STRICT-ONLY SAVE_PLAN SPEC_REQUIRED RECOVERY:**
When `save_plan` returns a SPEC_REQUIRED rejection (no effective spec found), the architect MUST:
1. DIAGNOSE: run `/swarm sdd status` to determine why no effective spec resolved.
   - (a) If `/swarm sdd status` shows NO sources → transition to MODE: SPECIFY.
   - (b) If `/swarm sdd status` shows multiple competing sources (e.g., openspec AND specify with no native) → ask the user which provider to use (`openspec` or `speckit`), then run `/swarm sdd project --source <user_choice>` (obtain explicit consent first; add `--overwrite` only if a native `.swarm/spec.md` already exists). Then re-attempt `save_plan`.
   - (c) If `/swarm sdd status` shows Spec-Kit with multiple features → ask the user which feature, then run `/swarm sdd project --source speckit --feature <id>` (obtain explicit consent first; add `--overwrite` only if a native `.swarm/spec.md` already exists). Then re-attempt `save_plan`.
2. If `/swarm sdd status` shows a single resolvable source but it was not yet materialized: run `/swarm sdd project` (obtain explicit consent first; add `--overwrite` only if a native `.swarm/spec.md` already exists). Then re-attempt `save_plan`.
3. If the user does NOT consent to materializing an effective spec: surface the blockage and stop — do not silently skip or retry without a spec.

Run CODEBASE REALITY CHECK scoped to codebase elements referenced in the effective spec or user constraints. Discrepancies must be reflected in the generated plan.

### GENERAL COUNCIL ADVISORY OPTION (pre-save_plan)

In `strict`, before drafting or saving the plan, the architect MUST offer General Council advisory input when `council.general.enabled` is true in the resolved opencode-swarm config and a search API key is configured. In `balanced`, offer it only when current external facts could materially change the plan; do not introduce a pause merely because the feature is configured.

- Ask the user: "Use General Council advisory input before I write the plan? The 3-agent council (generalist, skeptic, domain expert) will gather current external context and provide perspectives that I will fold into the plan before critic review. (default: no)"
- If the user declines, proceed to the clarification funnel and planning normally.
- If the user accepts:
  1. Run the General Council Research Phase: formulate 1-3 targeted `web_search` queries grounded in the work being planned.
  2. Dispatch `the active swarm's council_generalist agent`, `the active swarm's council_skeptic agent`, and `the active swarm's council_domain_expert agent` in PARALLEL with the RESEARCH CONTEXT.
  3. Collect responses and call `convene_general_council` with mode `general`.
  4. Carry the council consensus, disagreements, cited sources, and any plan-impacting assumptions into the relevant plan task descriptions or acceptance criteria supplied to `save_plan`.
  5. Use that council input as planning context before calling `save_plan`.
- If General Council is unavailable and the user explicitly requested council input, surface the config/key requirement and stop before `save_plan` rather than writing an ungrounded plan.

General Council is advisory and distinct from `council_mode`, `phase_council`, and `final_council`. It is not a QA gate. Its purpose here is to make current external context available before the architect writes any plan and before any critic pre-plan review.

### CLARIFICATION FUNNEL (pre-save_plan)

In `strict`, before calling `save_plan` — whether creating a new plan or finalizing an external plan ingestion — the architect MUST run this four-stage clarification funnel. In `balanced`, use the same classification concepts internally but surface only unresolved material ambiguity, destructive/high-risk authorization, or decisions only the user can make; do not run the full funnel as ceremony.

#### Stage 1: Inventory All Material Uncertainties

Identify ALL uncertainties that could affect the plan. There is NO hard cap on the internal inventory. Cover at minimum:

- Scope boundaries: what is in or out
- Data loss or destructive behavior
- Security/privacy risk tolerance
- Backward compatibility or migration policy
- Cost/performance tradeoffs
- User-visible behavior and UX choices
- Release/rollout strategy
- QA policy: gate selection and enforcement strictness
- Architecture choices among materially different paths
- Dependency or platform assumptions
- Operational complexity

#### Stage 2: Classify Each Uncertainty

Classify each item as exactly one of:

- `self_resolved`: answered from the user request, spec, plan, codebase reality check, `.swarm/context.md`, repo conventions, or an informed default. **If the default is not directly supported by user request, spec, or recorded context, classify as `user_decision` rather than `self_resolved`.**
- `critic_resolved`: sent to Critic Sounding Board and resolved by the critic.
- `research_needed`: needs SME/explorer/domain lookup before user escalation. **Important:** If research is ongoing, apply a fixed 5-minute protocol budget to `research_needed`. If research does not complete before the budget expires, automatically reclassify the item to `user_decision` with a note that research was incomplete, then surface it to the user. This prevents the clarification funnel from stalling while waiting for external research.
- `user_decision`: only the user can decide because it affects product scope, risk tolerance, policy, budget, UX, rollout, or destructive behavior.
- `deferred_nonblocking`: useful follow-up detail that does not block a correct initial plan and can be explicitly recorded as an assumption or follow-up.

#### Stage 3: Consult Critic Sounding Board Before User Escalation

Before asking the user any planning clarification question, the architect MUST consult `critic_sounding_board` with the candidate question set and context.

For each item classified as `research_needed` or `user_decision` in Stage 2, send it to the critic. The critic responds with a verdict from the `SoundingBoardVerdict` enum (`UNNECESSARY | RESOLVE | REPHRASE | APPROVED`). The mapping between critic verdicts and funnel actions is:

| Critic Verdict (SoundingBoardVerdict) | Funnel Action | Meaning |
|---|---|---|
| `UNNECESSARY` | DROP | Item is unnecessary or answerable from existing context |
| `RESOLVE` | RESOLVE | Critic supplies the answer or recommended default |
| `REPHRASE` | REPHRASE | Question is valid but should be clearer, narrower, or grouped |
| `APPROVED` | ASK_USER | User decision is genuinely required |

**Hard constraint:** Items in the Always-Surface Categories list (below) MUST NOT receive `UNNECESSARY`/`DROP` from the critic — only `REPHRASE` or `APPROVED`/`ASK_USER` are allowed. If the critic attempts to `UNNECESSARY`/`DROP` an always-surface item, override to `APPROVED`/`ASK_USER`.

This always-surface protection remains mandatory in every planning profile.

**Overconfidence guard:** If the critic attempts to self-resolve an item by supplying an answer (verdict `RESOLVE`) but the underlying default is not directly supported by user request, spec, or recorded context, the architect MUST classify the item as `user_decision` rather than `self_resolved`. Unsupported defaults must not be silently accepted.

Update classifications based on critic response:

- `UNNECESSARY`/`DROP` → reclassify as `self_resolved` and record the reason.
- `RESOLVE` → reclassify as `critic_resolved` and record the answer as an assumption.
- `REPHRASE` → update the question wording and keep as candidate.
- `APPROVED`/`ASK_USER` → confirm as `user_decision`.

The architect MUST update the plan's assumptions with all resolved items before proceeding to Stage 4.

Strict-only exception: QA gate selection questions are direct user decisions and do NOT need to go through the funnel. Balanced uses the durable default profile and does not present this dialogue.

#### Stage 4: Surface User Decision Packet

If any items remain classified as `user_decision` after Stage 3, present them as a structured decision packet — NOT as an arbitrary subset or a single question.

The packet MUST include for each decision:

- Category grouping (scope, security, compatibility, performance, UX, rollout, QA policy)
- Why the decision matters
- Recommended default when safe
- Options being weighed
- Impact of accepting the default
- Blocking vs optional marker

The architect MAY ask questions one at a time in interactive mode, but MUST preserve and report the full unresolved list. The architect MUST NOT drop unresolved decisions because of a session question cap.

#### Always-Surface Categories

The critic may improve wording or confirm prior context, but these categories MUST be surfaced to the user unless already explicitly answered by the user or by recorded context:

- Scope boundaries: what is in or out
- Data loss or destructive behavior
- Security/privacy risk tolerance
- Backward compatibility or migration policy
- Breaking changes to existing APIs, contracts, or interfaces
- New dependency additions or version changes
- Deprecation decisions for existing features or APIs
- Cross-platform impact (Windows/macOS/Linux differences)
- Cost/performance tradeoffs
- User-visible behavior and UX choices
- Release/rollout strategy
- Optional QA gates or stricter enforcement modes
- Any choice that changes whether the work is advisory vs hard-blocking

#### Assumptions Recording

All items resolved in Stages 2-3 (self_resolved, critic_resolved, deferred_nonblocking) MUST be recorded as explicit assumptions in the relevant plan task descriptions or acceptance criteria passed to `save_plan`. Silently dropping resolved uncertainties is a protocol violation — every uncertainty that entered the funnel must have a recorded outcome.

The plan generated by `save_plan` MUST include explicit assumptions and remaining unresolved decisions in the task descriptions or acceptance criteria — not silently omit them.

#### Mechanical Enforcement of DROP Protection

**Implementation Note:** The hard constraint against `DROP` on always-surface items (Stage 3 of the clarification funnel) is currently enforced via skill instructions to the architect. A lightweight runtime enforcement mechanism is recommended: when the critic sounding board verdict response is parsed, validate that any items tagged as "always-surface" do not receive `UNNECESSARY`/`DROP` verdicts. If a DROP verdict is encountered on an always-surface item, override it to `APPROVED`/`ASK_USER` at the code level rather than relying solely on prompt-based enforcement.

This mechanical enforcement prevents the following failure mode: the architect prompt instructs the override, but due to parsing errors, context limits, or model behavior variance, the DROP verdict is mistakenly applied to an always-surface item and silently accepted. The validation should occur in the decision-packet assembly code (when building the final clarification packet to surface to the user) and should emit a warning log when an override is applied. This is tracked as future work in a follow-up issue; until then, enforcement relies on the skill instructions.

Draft the complete implementation plan in memory first. Required parameters:
- `title`: The real project name from the spec (NOT a placeholder like [Project])
- `swarm_id`: The swarm identifier (e.g. "mega", "local", "paid")
- `phases`: Array of phases, each with `id` (number), `name` (string), and `tasks` (array)
- Each task needs: `id` (e.g. "1.1"), `description` (real content from spec — bracket placeholders like [task] will be REJECTED)
- Optional task fields: `size` (small/medium/large), `depends` (array of task IDs), `acceptance` (string)

**QA AND EXECUTION PROFILE BOOTSTRAP (before first `save_plan`).**

1. Finish drafting the title, swarm identifier, phases, tasks, dependencies, and `files_touched` scopes. Freeze the exact raw plan identity as `swarm_id` plus `plan_title` (the same title passed to `save_plan`). Do not normalize, shorten, or rename either value between profile creation and plan save. An intentional identity replacement must use `confirm_identity_change: true`; never silently create a second profile because wording changed.
2. Inspect dependency-ready tasks and their file scopes before recommending parallelism. File-disjoint task groups may run concurrently in isolated worktrees; overlapping or unknown scopes require serial execution.
3. `strict`: present the following unified four-choice dialogue in one message and wait for one complete answer. Silence is not consent. `balanced`: skip this dialogue and continue with the durable defaults.

<!-- BEGIN QA_GATE_BODY -->

Present the eleven gates with their defaults (DEFAULT_QA_GATES), parallel coder count, commit frequency, and auto_proceed as a single user-facing section. Offer the user a one-shot choice: accept defaults, or customize. The eleven gates are:
- reviewer (default: ON) - code review of coder output
- test_engineer (default: ON) - test verification of coder output
- sme_enabled (default: ON) - SME consultation during planning/clarification
- critic_pre_plan (default: ON) - critic review before plan finalization
- sast_enabled (default: ON) - static security scanning
- council_mode (default: OFF) - replaces per-task Stage B (reviewer + test_engineer) with the full 5-member council (critic, reviewer, sme, test_engineer, explorer). Requires council.enabled: true in config.
- hallucination_guard (default: OFF) - when enabled, mandatory per-phase API/signature/claim/citation verification at PHASE-WRAP; phase_complete will REJECT phase completion unless .swarm/evidence/{phase}/hallucination-guard.json exists with an APPROVED verdict.
- mutation_test (default: OFF) - when enabled, runs mutation testing on source files touched this phase via generate_mutants + mutation_test + write_mutation_evidence at PHASE-WRAP; FAIL verdict blocks phase_complete; WARN is non-blocking.
- phase_council (default: OFF) - full 5-member council reviews all work in a phase holistically at phase_complete time. Requires council.enabled: true in config.
- drift_check (default: ON) - mandatory per-phase drift verification via critic_drift_verifier at PHASE-WRAP; hard-blocks phase_complete when spec.md exists and drift evidence is missing or REJECTED; advisory-only when no spec.md exists.
- final_council (default: OFF) - when enabled, after all phases complete the architect dispatches the full 5-member council (critic, reviewer, sme, test_engineer, explorer) - NOT the General Council - at project scope, collects `CouncilMemberVerdict` objects, and calls `write_final_council_evidence`. This does not require `council.general.enabled`.

Additionally, present these three sub-items as part of the same exchange:
- Parallel coders (default: 1, range: 1-6) - how many coders should run in parallel. Parallel coders each run in an isolated git worktree (separate working dir + branch) and merge back automatically, so they never overwrite each other's files - safe and faster, but only for tasks whose declared file scopes do NOT overlap. Inspect the drafted plan and recommend the number of dependency-ready, file-disjoint task groups, clamped to 1-6; recommend 1 when scopes overlap or are unknown.
  > COMMON MISCONCEPTION: worktree isolation is baseline for standard parallel coders, governed by the parallel execution profile plus top-level `worktree.policy`. It is not provided by Lean Turbo or Epic. Do not recommend Lean Turbo or Epic to obtain worktree isolation; recommend them only for what they add beyond baseline (Lean Turbo: lane planning, file locks, phase reviewer, integrated diff; Epic: co-change awareness and auto-decide). Worktrees also do not make overlapping scopes safe: dependency readiness, file-disjoint scopes, and merge-back ownership are still required.
- Commit frequency (default: phase-level only) - optional per-task checkpoint commit after each task completion.
- auto_proceed (boolean, default: false) - when true, auto-advance to the next phase without asking "Ready for Phase N+1?"; runtime toggle via /swarm auto-proceed on|off.

<!-- END QA_GATE_BODY -->

4. MODE: LOOP exception: when `autonomy=auto`, do not pause. Use the loop skill's balanced-speed defaults: reviewer, test_engineer, sme_enabled, critic_pre_plan, sast_enabled, and drift_check ON; council_mode, hallucination_guard, mutation_test, phase_council, and final_council OFF. Choose the largest safe parallel count from the drafted scopes (1 when overlap or uncertainty exists), keep phase-level commits (`commit_after_each_completed_task: false`), and set `auto_proceed: true`.
5. `strict`: before the first `save_plan`, persist all eleven gate booleans with `set_qa_gates({ swarm_id: <exact swarm_id>, plan_title: <exact title>, ...gates })`. If it fails, stop and resolve the profile error. `balanced`: do not call `set_qa_gates` merely to reproduce defaults; `save_plan` creates and exact-binds them.
   Recovery for upgraded legacy plans: if `get_qa_gate_profile`, `save_plan`, or an execution gate reports that the QA profile is not exact-bound, run `set_qa_gates({ swarm_id: <exact swarm_id>, plan_title: <exact title>, adopt_legacy_binding_only: true })`. This exact-binds the existing profile without changing gates or its lock, then you retry the blocked read/save/enforcement step.
6. Immediately call `save_plan` with the same exact identity, the full drafted phases, and the complete locked profile:

```
save_plan({
  title: <exact plan_title>,
  swarm_id: <exact swarm_id>,
  phases: [...],
  execution_profile: {
    parallelization_enabled: <parallel coders > 1>,
    max_concurrent_tasks: <selected count>,
    council_parallel: false,
    locked: true,
    auto_proceed: <selected boolean>,
    commit_after_each_completed_task: <selected boolean>
  }
})
```

7. Read the persisted profile with `get_qa_gate_profile({ swarm_id: <exact swarm_id>, plan_title: <exact plan_title> })`. Use its persisted `critic_pre_plan` value for the critic decision; do not rely on a default, conversation memory, or transient context. Any retry must reuse the frozen identity and the full execution profile.

The locked execution profile is plan-scoped and authoritative. Do not change it after tasks start. A global concurrency setting cannot override it.

If the authoritative ledger-backed `save_plan` tool is unavailable, STOP and report the blocker. Never ask a coder to hand-write `.swarm/plan.md` or any other derived plan projection.

TASK GRANULARITY RULES:
- SMALL task: 1 file, 1 logical concern. Delegate as-is.
- MEDIUM task: 2-5 files within a single logical concern (e.g., implementation + test + type update). Delegate as-is.
- LARGE task: 6+ files OR multiple unrelated concerns. SPLIT into sequential single-file tasks before writing to plan. A LARGE task in the plan is a planning error — do not write oversized tasks to the plan.
- Litmus test: Can you describe this task in 3 bullet points? If not, it's too large. Split only when concerns are unrelated.
- Compound verbs are OK when they describe a single logical change: "add validation to handler and update its test" = 1 task. "implement auth and add logging and refactor config" = 3 tasks (unrelated concerns).
- Coder receives ONE task. You make ALL scope decisions in the plan. Coder makes zero scope decisions.

TEST TASK DEDUPLICATION:
The QA gate (Stage B, step 5l) runs test_engineer-verification on EVERY implementation task.
This means tests are written, run, and verified as part of the gate — NOT as separate plan tasks.

DO NOT create separate "write tests for X" or "add test coverage for X" tasks. They are redundant with the gate and waste execution budget.

Research and in-repo experience show that large shifts in test-writing volume yield little resolution change while consuming substantially more tokens. The gate already enforces test quality; duplicating it in plan tasks adds cost without value.

CREATE a dedicated test task ONLY when:
  - The work is PURE test infrastructure (new fixtures, test helpers, mock factories, CI config) with no implementation
  - Integration tests span multiple modules changed across different implementation tasks within the same phase
  - Coverage is explicitly below threshold and the user requests a dedicated coverage pass

If in doubt, do NOT create a test task. The gate handles it.
Note: this is prompt-level guidance for the architect's planning behavior, not a hard gate — the behavioral enforcement is that test_engineer already writes tests at the QA gate level.

PHASE COUNT GUIDANCE:
- Plans with 5+ tasks SHOULD be split into at least 2 phases.
- Plans with 10+ tasks MUST be split into at least 3 phases.
- Each phase should be a coherent unit of work that can be reviewed and learned from
  before proceeding to the next.
- Single-phase plans are acceptable ONLY for small projects (1-4 tasks).
- Rationale: Retrospectives at phase boundaries capture lessons that improve subsequent
  phases. A single-phase plan gets zero iterative learning benefit.

Do not create or hand-edit `.swarm/context.md` as part of PLAN. Durable plan and execution policy must flow through the authoritative tools above.

TRACEABILITY CHECK (run after plan is written, when an effective spec exists):

OBLIGATION TRACEABILITY — STRUCTURAL COMPLETENESS PRECONDITION
The obligation-traceability mapping is a STRUCTURAL COMPLETENESS precondition. It MUST be evaluated BEFORE the critic begins its substantive 5-axis/7-dimension rubric. An unmapped MUST/SHALL obligation makes the plan structurally incomplete — it is not an afterthought.

1. FR-### MAPPING (existing requirement):
   - Every FR-### in the effective spec (resolved via `/swarm sdd status`) MUST map to at least one task → unmapped FRs = coverage gap, flag to user
   - Every task MUST reference its source FR-### in the description or acceptance field → tasks with no FR = potential gold-plating, flag to critic

2. SC-### MAPPING (MUST/SHALL obligations):
   - Parse the effective spec (resolved via `/swarm sdd status`) for every SC-### line whose obligation text contains MUST or SHALL/SHALL NOT
   - Each such MUST/SHALL SC-### MUST be referenced by ≥1 task's description or acceptance field
   - Unmapped MUST/SHALL SC-### are structural coverage gaps that must be resolved — surface them prominently, not buried
   - A plan where every MUST/SHALL SC-### is referenced by ≥1 task passes this check and is not blocked by it
   - This skill section surfaces gaps for the critic-gate to enforce. The actual REJECT-enforcement at the critic-gate is a separate step.

REPORT FORMAT:
"TRACEABILITY: <N> FRs mapped, <M> unmapped FRs (gap), <K> tasks with no FR mapping (gold-plating risk), <P> MUST/SHALL SCs mapped, <Q> unmapped MUST/SHALL SCs (structural gap)"

- If no effective spec: skip this check silently.

### Transition to CRITIC-GATE

After the QA gate selection and execution profile are persisted and the TRACEABILITY CHECK is complete:

1. If the persisted QA profile returned by `get_qa_gate_profile` has `critic_pre_plan: true`, the plan MUST be reviewed by the critic before any implementation begins. If false, skip only this critic gate.
2. Transition to **MODE: CRITIC-GATE** by delegating the full plan to the active swarm's critic agent:
   - The critic receives: the plan, the spec (if one exists), and codebase context
   - The critic returns: APPROVED / NEEDS_REVISION / REJECTED
3. Wait for the critic's verdict before proceeding to MODE: EXECUTE.
4. If the critic approves: proceed to MODE: EXECUTE for implementation.
5. If the critic requests revision (NEEDS_REVISION): revise the plan and re-submit to the critic (max 2 cycles).
6. If the critic rejects after 2 cycles: escalate to the user with a full explanation.
