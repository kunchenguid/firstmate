---
name: brainstorm
audience: swarm-plugin
description: >
  Full execution protocol for MODE: BRAINSTORM -- structured discovery dialogue, approach selection, spec drafting, QA gate selection, and transition handling.
---

# Brainstorm Protocol

This protocol is loaded on demand by the architect runtime. The architect prompt keeps only activation, action, and hard safety constraints; the full execution details live here.

### MODE: BRAINSTORM
Activates when: user invokes `/swarm brainstorm`; OR uses phrases like "brainstorm", "let's think through", "think this through with me", "workshop this idea"; OR the problem is fuzzy/exploratory and the user has not yet written (or does not want to directly dictate) a spec.

Use BRAINSTORM when requirements need to be drawn out through structured dialogue before committing to a spec. Use SPECIFY when the user has already articulated clear requirements.

MODE: BRAINSTORM runs seven phases in strict order. Do not skip phases. Do not collapse phases. Each phase has a clear entry signal and a clear exit signal.

**Phase 1: CONTEXT SCAN (architect + explorer, parallel).**
- Delegate to `the active swarm's explorer agent` to map the relevant portion of the codebase. Scope the explorer to the area most likely affected by the topic.
- In parallel, read any existing `.swarm/spec.md`, `.swarm/plan.md`, and `.swarm/knowledge.jsonl` entries that are relevant.
- Run CODEBASE REALITY CHECK on any claims the user made in their topic statement. Surface discrepancies before moving forward.
- Exit when you have a confident map of: (a) existing code and patterns, (b) relevant prior decisions, (c) what is actually unknown.

**Phase 1b: GENERAL COUNCIL ADVISORY (optional, architect).**
If `council.general.enabled` is true in the resolved opencode-swarm config AND a search API key is configured:
- Ask the user: "Enable General Council advisory input? The 3-agent council (generalist, skeptic, domain expert) will research the problem domain and provide diverse perspectives to inform the specification and plan. (default: no)"
- If the user declines or config is not enabled, skip to Phase 2.
- If the user accepts:
  1. Run the Research Phase: formulate 1-3 targeted `web_search` queries grounded in the topic.
  2. Dispatch `the active swarm's council_generalist agent`, `the active swarm's council_skeptic agent`, and `the active swarm's council_domain_expert agent` in PARALLEL with the RESEARCH CONTEXT.
  3. Collect responses, call `convene_general_council` with mode `general`.
  4. Carry the council's consensus and disagreements forward as context for subsequent phases.
- Exit with council input noted (or skipped).

**Phase 2: DIALOGUE (architect ↔ user).**
- Ask EXACTLY ONE focused question per message. Wait for the user's answer before asking the next.
- Prioritize questions that materially change scope, risk, or architecture. Skip questions whose answers can be responsibly defaulted — use informed defaults and say so.
- Hard cap: no more than SIX questions total in this phase. Stop sooner if uncertainty has collapsed.
- Each question must include: (a) why it matters, (b) the default you will use if the user doesn't answer, (c) the concrete options you're weighing.
- Exit when: remaining ambiguity can be defaulted safely, or the user explicitly says "good, move on" or equivalent.

**Phase 3: APPROACHES (architect, optionally with SME).**
- Produce 2-4 distinct candidate approaches. Each approach must have: name, one-paragraph summary, primary tradeoff it optimizes for, primary risk it accepts, rough integration surface.
- For high-risk domains (auth, payments, data mutation, public API, schema, concurrency, security-sensitive parsing), delegate to `the active swarm's sme agent` for domain research first.
- Present the approaches to the user and recommend one with explicit reasoning. The user can pick, modify, or reject.
- Exit when the user has chosen (or agreed to your recommended) approach.

**Phase 4: DESIGN SECTIONS (architect).**
- Draft the structural design of the chosen approach. Include: data model / entities, major components / modules, integration points, invariants, failure modes, rollout considerations.
- Keep design technology-aware (this is NOT the spec — BRAINSTORM design notes can reference frameworks and patterns).
- Name the design sections explicitly so you can reference them in the spec without duplicating.
- Exit with a design outline the user can skim in under two minutes.

**Phase 5: SPEC WRITE + SELF-REVIEW (architect + reviewer).**
    - Generate `.swarm/spec.md` following the same SPEC CONTENT RULES that MODE: SPECIFY uses: WHAT/WHY only, no tech stack, no implementation details, FR-### / SC-### numbering, Given/When/Then scenarios, `[NEEDS CLARIFICATION]` markers only for items that survive the clarification funnel: inventory all material uncertainties without numeric cap → classify each (self_resolved/critic_resolved/research_needed/user_decision/deferred_nonblocking) — **Overconfidence guard:** if the default is not directly supported by user request, spec, or recorded context, classify as `user_decision` rather than `self_resolved` → consult critic_sounding_board — critic responds per SoundingBoardVerdict: UNNECESSARY→DROP, RESOLVE→RESOLVE, REPHRASE→REPHRASE, APPROVED→ASK_USER — **always-surface protection:** always-surface categories must not receive UNNECESSARY/DROP; override to APPROVED/ASK_USER → record resolved items as assumptions → surface only survivors as markers with decision packet format (grouped by category, recommended defaults, blocking vs optional markers).
    - **Important:** If research is ongoing, apply a fixed 5-minute protocol budget to `research_needed`. If research does not complete before the budget expires, automatically reclassify the item to `user_decision` with a note that research was incomplete, then surface it to the user. This prevents the clarification funnel from stalling while waiting for external research.
- Cross-reference design sections by name where relevant context helps (but keep HOW out of the spec).
- Delegate to `the active swarm's reviewer agent` for an independent review of the draft spec. Reviewer must flag: requirements that encode HOW, untestable requirements, missing edge cases, silent assumptions.
    → REQUIRED: The reviewer Task dispatch MUST contain a literal `ACCEPTANCE:` line. This is a pre-plan spec review (no fr_refs yet), so resolve per ACCEPTANCE FIELD RESOLUTION in your system prompt using a one-line task-derived DONE restatement, e.g. "DONE = reviewer flags HOW-encoded requirements, untestable requirements, missing edge cases, and silent assumptions in the draft spec." A missing line is BLOCKED by ACCEPTANCE_FIELD_REQUIRED.
- Apply reviewer feedback. If reviewer rejects, iterate once and re-review. After two rounds, surface remaining disagreements to the user.
- Before writing `.swarm/spec.md`, apply the FR-002 non-shadowing check: if a non-native spec already exists, do not shadow it (see MODE: SPECIFY step 1b).
- Resolve the effective spec first via `/swarm sdd status` (issue #2131 finding 9): write `.swarm/spec.md` ONLY when no non-native effective spec (openspec / speckit projection) is active — those sources are read-only inputs (see the status output's `allowed mutations` line); refine them in their own tool instead of shadowing them.
- Exit when reviewer signs off (or user explicitly accepts remaining disagreements).

**Phase 6: DEFER QA AND EXECUTION PROFILE SELECTION.**
- BRAINSTORM does not collect, infer, or stage QA gates, parallel coder count, commit frequency, or `auto_proceed`.
- MODE: PLAN owns the unified four-choice dialogue after it has drafted task scopes and frozen the exact plan identity (`swarm_id` plus title). MODE: LOOP with `autonomy=auto` also applies its balanced-speed defaults there without pausing.
- Do not write execution choices to `.swarm/context.md`.

**Phase 7: TRANSITION.**
- Summarize: (a) chosen approach, (b) design sections produced, (c) spec written, and (d) remaining `[NEEDS CLARIFICATION]` markers.
- Offer the user two next steps: `PLAN` (go to MODE: PLAN and persist the plan via the authoritative ledger-backed `save_plan` tool; never write `.swarm/plan.md` directly) or `CLARIFY-SPEC` (resolve remaining markers first).
- Do NOT proceed to PLAN or CLARIFY-SPEC automatically — wait for user direction.

BRAINSTORM RULES:
- No skipping phases. Each phase's exit condition must be met before moving on.
- One question per message in DIALOGUE — never batch. MODE: PLAN owns the later unified QA and execution-profile exchange.
- Always offer an informed default for every question.
- The spec produced in Phase 5 must still satisfy the SPEC CONTENT RULES (no tech stack, no implementation details).
- QA gates are first selected and persisted during MODE: PLAN against the exact plan identity; they are ratchet-tighter from that point.
