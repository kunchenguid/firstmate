---
name: specify
audience: swarm-plugin
description: >
  Full execution protocol for MODE: SPECIFY -- spec creation, codebase reality checks, SME input, QA gate persistence, and optional council spec review.
---

# Specify Protocol

This protocol is loaded on demand by the architect runtime. The architect prompt keeps only activation, action, and hard safety constraints; the full execution details live here.

### MODE: SPECIFY
Activates when: user asks to "specify", "define requirements", "write a spec", or "define a feature"; OR `/swarm specify` is invoked; OR no EFFECTIVE spec exists and no `.swarm/plan.md` exists (use `/swarm sdd status` to determine effective-spec existence — native `.swarm/spec.md`, OpenSpec `openspec/`, or Spec-Kit `.specify/`).

   1. Run `/swarm sdd status` to determine whether an effective spec exists and, if so, how it should be handled. An effective spec exists iff `/swarm sdd status` reports a resolved spec. `/swarm sdd status` reflects `readEffectiveSpecSync`, which returns null (NO effective spec) for: no sources, multiple competing sources (openspec+speckit), multi-feature Spec-Kit without a selected feature, or any unresolvable state. When `/swarm sdd status` reports a resolved spec, classify it as NATIVE (native `.swarm/spec.md`) vs NON-NATIVE (projected). When it reports NO resolved spec, do NOT treat any source as an effective spec. Based on this classification, branch to the appropriate sub-step:
     - **NATIVE**: proceed to step 1a (overwrite/refine/archive).
     - **NON-NATIVE**: proceed to step 1b (non-shadowing choice).
     - **NO effective spec** (ambiguous or no sources): if multiple SDD sources are present, proceed to step 1c (disambiguation); otherwise proceed to step 1d (native authoring).
     - If this is called from the stale spec archival path (MODE: PLAN option 1) — archival was already completed; skip all branches and proceed directly to generation (step 2).
1a. **NATIVE SPEC — overwrite/refine/archive.** Ask the user "A spec already exists. Do you want to overwrite it or refine it?"
      - Overwrite → ARCHIVE FIRST: read the existing spec, extract version (priority order): (1) from spec heading, look for patterns like "v{semver}" or "Version {semver}" in the first H1/H2; (2) from package.json version field in project root; create `.swarm/spec-archive/` directory if it does not exist; copy existing spec.md to `.swarm/spec-archive/spec-v{version}.md`; if version cannot be determined, use date-based fallback: `.swarm/spec-archive/spec-{YYYY-MM-DD}.md`; log the archive location to the user ("Archived existing spec to .swarm/spec-archive/spec-v{version}.md"); then proceed to generation (step 2)
      - Refine → delegate to MODE: CLARIFY-SPEC
1b. **NON-NATIVE SPEC — non-shadowing check (FR-002).** The effective spec comes from `openspec/` or `.specify/` sources with no native `.swarm/spec.md`. Do NOT silently author a competing native spec. Instead OFFER the user a choice:
      - **(a) Project/ingest** the existing SDD sources into `.swarm/spec.md` via the agent-invocable `/swarm sdd project` command. Obtain EXPLICIT user consent before proceeding. (Do not pass `--overwrite` in this branch — no native spec exists yet.)
      - **(b) Proceed with native authoring** (`/swarm specify`) if the user explicitly chooses to ignore the SDD sources and write a new spec from scratch.
      - **(c) Cancel** — abort SPECIFY; the existing SDD sources remain the effective spec.
     - If the user chooses option (a) and `/swarm sdd project` completes successfully: the projected spec is now materialized as `.swarm/spec.md` (NATIVE). Do NOT proceed to generation (step 2) — that would overwrite the just-projected spec. Instead route to step 1a (overwrite/refine/archive) so the user can refine, overwrite, or archive the projected spec.
     - If the user chooses option (b): proceed directly to generation (step 2) with a note that existing SDD sources were bypassed per user decision.
     - If the user chooses option (a) and `/swarm sdd project` fails: report the failure and re-offer the choices.
1c. **AMBIGUOUS — multiple SDD sources detected.** Both `openspec/` AND `.specify/` exist with no native `.swarm/spec.md`. Per `readEffectiveSpecSync` semantics this is NOT an effective spec (the function returns null). Do NOT treat this as a single-source NON-NATIVE choice. Instead:
        - Inform the user: "Multiple SDD sources detected (openspec AND speckit) but no native spec exists. This is ambiguous — there is no single effective spec. You must choose which source to project, or disambiguate via `/swarm sdd status --source`."
       - Offer the user a choice:
         - **(a) Project from openspec** — run `/swarm sdd project --source openspec` (after consent) to project the openspec source into `.swarm/spec.md`.
          - **(b) Project from speckit** — run `/swarm sdd project --source speckit` (after consent) to project the speckit source into `.swarm/spec.md`.
         - **(c) Cancel** — abort SPECIFY; the ambiguous sources remain as-is.
       - After a successful projection (a or b): the spec is now NATIVE → route to step 1a (overwrite/refine/archive).
       - After a failed projection: report the failure and re-offer the choices.
1d. **NO EFFECTIVE SPEC.** Proceed directly to generation (step 2).
1e. Run CODEBASE REALITY CHECK for any codebase references mentioned by the user or implied by the feature. Skip if work is purely greenfield (no existing codebase to check). Report discrepancies before proceeding to explorer.
2. Delegate to `the active swarm's explorer agent` to scan the codebase for relevant context (existing patterns, related code, affected areas).
3. Delegate to `the active swarm's sme agent` for domain research on the feature area to surface known constraints, best practices, and integration concerns.
4. Generate `.swarm/spec.md` capturing:
   - First line must be: `# Specification: <feature-name>`
   - Feature description: WHAT users need and WHY — never HOW to implement
   - User scenarios with acceptance criteria (Given/When/Then format)
   - Functional requirements numbered FR-001, FR-002… using MUST/SHOULD language
   - Success criteria numbered SC-001, SC-002… — measurable and technology-agnostic
   - Key entities if data is involved (no schema or field definitions — entity names only)
   - Edge cases and known failure modes
    - `[NEEDS CLARIFICATION]` markers for items where uncertainty could change scope, security, or core behavior, BUT ONLY after running the clarification funnel: (1) inventory all material uncertainties without numeric cap, (2) classify each as self_resolved/critic_resolved/research_needed/user_decision/deferred_nonblocking — **Overconfidence guard:** if the default is not directly supported by user request, spec, or recorded context, classify as `user_decision` rather than `self_resolved`, (3) consult critic_sounding_board with candidate items — critic responds per SoundingBoardVerdict: UNNECESSARY→DROP, RESOLVE→RESOLVE, REPHRASE→REPHRASE, APPROVED→ASK_USER — **always-surface protection:** always-surface categories must not receive UNNECESSARY/DROP; override to APPROVED/ASK_USER, (4) record all resolved items as explicit assumptions in the spec, (5) use markers only for items that survive the funnel (ASK_USER or unresolved after critic consultation). Decision packet format: grouped by category, recommended defaults, blocking vs optional markers, impact of accepting default. Prefer informed defaults over asking
     - **Important:** If research is ongoing, apply a fixed 5-minute protocol budget to `research_needed`. If research does not complete before the budget expires, automatically reclassify the item to `user_decision` with a note that research was incomplete, then surface it to the user. This prevents the clarification funnel from stalling while waiting for external research.
 5. Write the spec to `.swarm/spec.md`.
5b. **DEFER QA AND EXECUTION PROFILE SELECTION.**
SPECIFY does not collect, infer, or stage QA gates, parallel coder count, commit frequency, or `auto_proceed`. Those choices depend on the drafted task graph and its exact plan identity. MODE: PLAN freezes the exact `swarm_id` and plan title, presents the unified four-choice dialogue, persists the gate profile, and saves the execution profile. Do not write execution choices to `.swarm/context.md`.

General Council advisory input is offered as an early workflow option in MODE: BRAINSTORM (Phase 1b) and MODE: PLAN before `save_plan`, not as a SPECIFY step. If the user wants council input during SPECIFY, they can use `/swarm council <question>` manually.

7. Report a summary to the user (MUST count, SHALL count, scenario count, clarification markers) and suggest the next step: `CLARIFY-SPEC` (if markers exist) or `PLAN`.

SPEC CONTENT RULES — the spec MUST NOT contain:
- Technology stack, framework choices, library names
- File paths, API endpoint designs, database schema, code structure
- Implementation details or "how to build" language
- Any reference to specific tools, languages, or platforms

Each functional requirement MUST be independently testable.
Focus on WHAT users need and WHY — never HOW to implement.
No technology stack, APIs, or code structure in the spec.
Each requirement must be independently testable.
Prefer informed defaults over asking the user — use `[NEEDS CLARIFICATION]` only when uncertainty could change scope, security, or core behavior.

EXTERNAL PLAN IMPORT PATH — when the user provides an existing implementation plan (markdown content, pasted text, or a reference to a file):
1. Run CODEBASE REALITY CHECK scoped to every file, function, API, and behavioral assumption in the provided plan. Report discrepancies to user before proceeding.
2. Read and parse the provided plan content.
3. Reverse-engineer `.swarm/spec.md` from the plan:
   - Derive FR-### functional requirements from task descriptions
   - Derive SC-### success criteria from acceptance criteria in tasks
   - Identify user scenarios from the plan's phase/feature groupings
   - Surface implicit assumptions as `[NEEDS CLARIFICATION]` markers
4. Validate the provided plan against swarm task format requirements:
   - Every task should have FILE, TASK, CONSTRAINT, and ACCEPTANCE fields
   - No task should touch more than 2 files
   - No compound verbs in TASK lines ("implement X and add Y" = 2 tasks)
   - Dependencies should be declared explicitly
   - Phase structure should match `.swarm/plan.md` format
5. Report gaps, format issues, and improvement suggestions to the user.
6. Ask: "Should I also flesh out any areas that seem underspecified?"
   - If yes: delegate to `the active swarm's sme agent` for targeted research on weak areas, then propose specific improvements.
7. Output: both a `.swarm/spec.md` (extracted from the plan) and a validated version of the user's plan.

EXTERNAL PLAN RULES:
- Surface ALL changes as suggestions — do not silently rewrite the user's plan.
- The user's plan is the starting point, not a draft to replace.
- Validation findings are advisory; the user may accept or reject each suggestion.
