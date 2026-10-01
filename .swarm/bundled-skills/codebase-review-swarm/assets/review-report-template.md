# Codebase Review Report

Generated: [timestamp]
Repository: [name/path]
Git HEAD: [SHA]
Selected Review Tracks: [tracks]
Skipped Tracks: [tracks and why]
Review Mode: [complete integrated | defect-focused | focused | enhancement-only | custom]

## Executive Summary

[2-5 sentences. Strongest confirmed themes only. No unvalidated or unquoted claims.]

## Review Scope and Method

- Phase 0 inventory completed: yes
- User-selected tracks:
- Explorer candidates generated:
- Reviewer validation completed:
- Inline critic used for CRITICAL/HIGH:
- Reviewer finalization used for MEDIUM/LOW:
- Enhancement critic used:
- Final whole-report critic verdict:
- Coverage closure verified: yes (N units reviewed, 0 unreviewed)
- Runtime validation commands run:

## Findings Count

```text
Defect Findings by Track:
  functionality_correctness: C / H / M / L / I
  security_privacy:         C / H / M / L / I
  llm_ai_security:          C / H / M / L / I
  supply_chain:             C / H / M / L / I
  testing_quality:          C / H / M / L / I
  ui_ux_accessibility:      C / H / M / L / I
  performance:              C / H / M / L / I
  observability:            C / H / M / L / I
  ai_slop_provenance:       C / H / M / L / I
  docs_claims_drift:        C / H / M / L / I
  cross_platform:           C / H / M / L / I
  cross_boundary:           C / H / M / L / I
  total:                    C / H / M / L / I

Validation Outcomes:
  candidates_generated:
  confirmed:
  pre_existing:
  disproved:
  unverified:
  reviewer_downgraded:
  critic_upheld:
  critic_refined:
  critic_downgraded:
  critic_overturned:

Enhancement Outcomes:
  candidates_generated:
  upheld_high_value:
  upheld_medium_value:
  refined:
  merged:
  downgraded:
  rejected:
  unverified:

Claim Ledger:
  supported:
  partially_supported:
  unsupported:
  contradicted:
  stealth_change:
  unverified:

Coverage Closure:
  total_coverage_units:
  reviewed:
  not_applicable:
  skipped_with_reason:
  blocked:
  unreviewed: 0
```

## Critical and High Confirmed Defect Findings

[Full details. Do not include PRE_EXISTING here.]

## High-Severity Pre-Existing Findings

[Required if any CRITICAL/HIGH PRE_EXISTING findings exist.]

## Medium Defect Findings

[Full details or grouped details.]

## Low and Info Defect Findings

[Condensed but evidence-grounded.]

## Security, Privacy, LLM/MCP, and Supply Chain Notes

[Include only if selected or relevant.]

## Unsupported, Contradicted, or Partially Supported Claims

[Claim ledger outcomes.]

## AI Slop and Code Provenance Patterns

[Evidence-based patterns only. Never vibe-based.]

## Testing and Test Drift Findings

[Test-quality and drift results.]

## UI/UX and Accessibility Findings

[Include only if selected and UI exists.]

## Performance and Observability Findings

[Include only if selected.]

## Systemic Themes

[Themes synthesized from validated findings only.]

## Enhancement Opportunities

[Include only if selected.]

### Top 10 Highest-Impact Enhancements

[Top validated high-value opportunities, ranked by impact.]

### Full Enhancement Catalog

#### Architecture Enhancements (ARCH-*)
#### Code Quality Enhancements (QUAL-*)
#### Performance Enhancements (PERF-*)
#### Resilience and Observability Enhancements (RES-*)
#### Testing Enhancements (TEST-*)
#### UI/UX — Visual Hierarchy and Layout (UI-HIER-*)
#### UI/UX — Interaction Design and Feedback (UI-INT-*)
#### UI/UX — Accessibility and Inclusivity (UI-A11Y-*)
#### UI/UX — Typography and Visual Polish (UI-VIS-*)
#### UI/UX — Performance and Perceived Performance (UI-PERF-*)
#### UI/UX — Consistency and Design System Alignment (UI-CON-*)

### Implementation Roadmap

#### Phase 1 — Quick Wins

Low effort, high clarity. List by ID with one-line description.

#### Phase 2 — Meaningful Improvements

Medium effort, clear payoff. List by ID with dependencies noted.

#### Phase 3 — Architectural Investments

High effort, transformational impact. List by ID.

### Codebase Strengths

[Specific patterns worth preserving. Each strength must cite file and line range and include exact quote evidence.]

## Recommended Remediation Order

1. Security, supply-chain, data-loss, and broken shipped functionality.
2. Unsupported public claims and stealth behavior changes.
3. Trust-boundary and authorization defects.
4. Test gaps that allow confirmed defects to recur.
5. Performance and observability gaps affecting production diagnosis.
6. AI slop and provenance cleanup by repeated pattern.
7. Validated enhancement opportunities by dependency order.

## Coverage and Depth Notes

- Tracks not run:
- Areas inventoried but not deeply reviewed:
- Runtime validations not run and why:
- UNVERIFIED findings worth future attention:
- Files or generated artifacts intentionally excluded:

## Validation Notes

- candidates generated:
- reviewer confirmed:
- reviewer disproved:
- reviewer unverified:
- critic upheld/refined/downgraded/overturned:
- enhancements upheld/rejected:
- final critic verdict:
- coverage units: total / reviewed / not_applicable / skipped / blocked / unreviewed
- depth plan failures: none or list
- selected-track dilution detected: yes/no

## Per-Finding Format

### [SEVERITY] [Title]

Location: `path:line`
Track: [track]
Status: CONFIRMED | PRE_EXISTING
Confidence: HIGH | MEDIUM
Grounding: HIGH | MEDIUM

Evidence:
> [exact quote]

Problem:
[factual issue]

Impact:
[specific impact]

Validation:
[what reviewer checked, runtime command if any, critic outcome if high severity]

Recommended Fix:
[actionable remediation]

## Per-Enhancement Format

### [ENHANCEMENT-ID] [Title]

Location: `path:line`
Category: [category]
Value: High | Medium
Effort: S | M | L
Grounding: HIGH | MEDIUM

Current State:
> [exact quote]

Opportunity:
[specific improvement]

Expected Impact:
[what improves]

Validation:
[critic result and dependencies]
