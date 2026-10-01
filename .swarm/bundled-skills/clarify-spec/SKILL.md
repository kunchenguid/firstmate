---
name: clarify-spec
audience: swarm-plugin
description: >
  Full execution protocol for MODE: CLARIFY-SPEC -- resolving spec clarification markers and maintaining spec/planning alignment.
---

# Clarify Spec Protocol

This protocol is loaded on demand by the architect runtime. The architect prompt keeps only activation, action, and hard safety constraints; the full execution details live here.

### MODE: CLARIFY-SPEC
Activates when: `/swarm sdd status` reports a **single resolved EFFECTIVE spec** (non-null) AND it contains `[NEEDS CLARIFICATION]` markers; OR user says "clarify", "refine spec", "review spec", or "/swarm clarify" is invoked; OR architect transitions from MODE: SPECIFY or MODE: BRAINSTORM with open markers.

`/swarm sdd status` reflects `readEffectiveSpecSync`, which returns **null** (NO effective spec) for: no sources at all, multiple competing sources (e.g. `openspec/` AND `.specify/`), multi-feature Spec-Kit without a selected feature, or any other unresolvable state. CLARIFY-SPEC does NOT activate in these null cases — tell the user: "No resolved effective spec exists. Disambiguate with `/swarm sdd project --source <source>` or `--feature <feature>`, or run `/swarm specify` to generate one first." and stop.

CONSTRAINT: CLARIFY-SPEC must NEVER create a spec. Always consult `/swarm sdd status` to determine the effective spec source before proceeding.

1. Read the **effective spec** resolved by `/swarm sdd status` (native `.swarm/spec.md` OR OpenSpec `openspec/` OR Spec-Kit `.specify/` — read the resolved spec FIRST before making any changes).
2. Scan for ambiguities beyond explicit `[NEEDS CLARIFICATION]` markers:
   - Vague adjectives ("fast", "secure", "user-friendly") without measurable targets
   - Requirements that overlap or potentially conflict with each other
   - Edge cases implied but not explicitly addressed in the spec
   - Acceptance criteria (SC-###) that are not independently testable
3. Present all spec modifications using delta format with ## ADDED/MODIFIED/REMOVED Requirements sections:
   - ## ADDED Requirements: New requirements being added to the spec
   - ## MODIFIED Requirements: Existing requirements being revised (show old vs new)
   - ## REMOVED Requirements: Requirements being deleted (show what was removed)
4. Delegate to `the active swarm's sme agent` for domain research on ambiguous areas before presenting questions.
5. Present questions to the user ONE AT A TIME (max 8 per session):
   - Offer 2–4 multiple-choice options for each question
   - Mark the recommended option with reasoning (e.g., "Recommended: Option 2 because…")
   - Allow free-form input as an alternative to the options
6. After each accepted answer, write the resolution to the **resolved effective source** (source-aware write-back):
    - **NATIVE effective spec** (`.swarm/spec.md` exists): update `.swarm/spec.md` with the resolution directly.
    - **NON-NATIVE effective spec** (openspec/specify-only, NO native `.swarm/spec.md`): do NOT write `.swarm/spec.md` — this would silently shadow the non-native source. Instead:
      - (a) If the resolved source supports in-place edits (e.g., OpenSpec sections), update the source artifacts directly.
      - (b) If no in-place edit path exists, ask the user: "The effective spec lives in `<source>`. To persist this resolution as a native spec, run `/swarm sdd project` first to materialize one, or I can stop here. Proceed?" — if the user consents to project, materialize via `/swarm sdd project` then write `.swarm/spec.md`; otherwise stop.
      - (c) If neither (a) nor (b) applies, stop and tell the user the clarification cannot be auto-written to a non-native source without a projection step.
    - Replace the relevant `[NEEDS CLARIFICATION]` marker or vague language with the accepted answer.
    - If the answer invalidates an earlier requirement, update it to remove the contradiction.
7. Stop when: all critical ambiguities are resolved, user says "done" or "stop", or 8 questions have been asked.
8. Report a ## Clarification Summary: total questions asked, requirements added/modified/removed, remaining open ambiguities (if any), and suggest next step (`PLAN` if spec is clear, or continue clarifying).

CLARIFY-SPEC RULES:
- FR-ID increment rule: When adding new requirements, find the highest existing FR-ID and increment from there (FR-001 → FR-002). Never reuse or skip FR-IDs.
- One question at a time — never ask multiple questions in the same message.
- Do not modify any part of the spec that was not affected by the accepted answer.
- Always write the accepted answer back to the resolved effective source before presenting the next question. Never write `.swarm/spec.md` in a non-native (openspec/specify-only) repo — see step 5 source-aware write-back rule.
- Max 8 questions per session — if limit reached, report remaining ambiguities and stop.
- Do not create, overwrite, or shadow the spec file — only refine what exists. In non-native (openspec/specify-only) repos, never silently materialize a `.swarm/spec.md` that would shadow the effective source.

### Scoped Funnel Protocol (CLARIFY-SPEC only)

CLARIFY-SPEC handles **already-surfaced** `[NEEDS CLARIFICATION]` markers and spec ambiguities — it does not perform open-ended discovery of new uncertainties. The full four-stage clarification funnel (inventory, classify, consult critic, surface) described in the clarify skill applies to MODE: CLARIFY and MODE: PLAN, not here.

However, before surfacing each marker question to the user, CLARIFY-SPEC MUST:

1. **Consult `critic_sounding_board`** with the candidate marker question and surrounding spec context to check whether the question wording can be improved or the item can be resolved from existing context.
2. **Apply the Overconfidence guard:** If the critic supplies a `RESOLVE` verdict with a default answer, but that default is not directly supported by user request, spec, or recorded context, classify the item as `user_decision` rather than `self_resolved`.
3. **Apply always-surface protection:** If the marker belongs to an always-surface category (scope boundaries, destructive behavior, security/privacy, backward compatibility, breaking API changes, new dependencies, deprecations, cross-platform impact, cost/performance tradeoffs, user-visible UX, rollout strategy, QA gates), the item MUST NOT receive `UNNECESSARY`/`DROP` from the critic — override to `APPROVED`/`ASK_USER`.

Critic verdict mapping (`SoundingBoardVerdict`): `UNNECESSARY`→DROP, `RESOLVE`→RESOLVE, `REPHRASE`→REPHRASE, `APPROVED`→ASK_USER.

This scoped protocol is lighter than the full funnel because CLARIFY-SPEC starts from known markers rather than open uncertainty inventory, but it still protects against overconfident self-resolution and premature dropping of important questions.
