# JSONL and Structured Block Schemas

Use these exact fields unless a field is not applicable, in which case write `N/A` or an explicit reason. Prefer one block per record in markdown ledgers and JSON object per line in `.jsonl` artifacts.

## Coverage unit

```json
{"unit_id":"COV-001","track":"security","unit_type":"trust_boundary","path_or_id":"BOUNDARY-001","status":"UNREVIEWED","depth_tier":"focused|multi_track|complete_integrated|custom","passes_required":["candidate","deterministic_tool","caller_callee_trace","test_or_guard_check","reviewer_validation","critic_if_required"],"passes_completed":[],"evidence_refs":[],"deterministic_checks":[],"runtime_checks_or_reason":"","validation_refs":[],"remaining_uncertainty":"","reason":"","updated_at":"<iso8601>"}
```

Terminal `status` values: `REVIEWED`, `NOT_APPLICABLE`, `SKIPPED_WITH_REASON`, `BLOCKED`. Final report is forbidden for selected tracks while any unit remains `UNASSIGNED` or `UNREVIEWED`. `REVIEWED` is valid only when `passes_completed` satisfies the selected track's `TRACK_DEPTH_PLAN`.

## Track depth plan

Write one block per selected track to `ledgers/review-depth-plan.md` after track selection and before Phase 1.

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

## Candidate finding

```text
CANDIDATE_FINDING
  id: <track>-<scope>-<sequence>
  track: functionality | security | supply_chain | testing | ui_ux | performance | observability | ai_slop | docs_claims | cross_platform | cross_boundary
  group: <short category>
  provisional_severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
  confidence: HIGH | MEDIUM
  grounding_assessment: HIGH | MEDIUM
  file: <relative path>
  line: <line or range>
  exact_quote: <verbatim evidence>
  title: <specific one-line title>
  problem: <factual description>
  impact: <why it matters>
  likely_fix: <concrete likely remediation>
  evidence_checked: <files, callers, configs, tests, docs, manifests, runtime paths checked>
  alternative_interpretation: <what could make this wrong>
  disproof_attempt: <required for CRITICAL/HIGH; recommended for all>
  linked_claims: <claim ids or N/A>
  linked_surfaces: <surface ids or N/A>
  linked_boundaries: <boundary ids or N/A>
  ai_pattern: <optional or N/A>
  needs_runtime_validation: yes | no
  size: S | M | L
END
```

## Enhancement candidate

```text
ENHANCEMENT_CANDIDATE
  id: ENH-<track>-<sequence>
  track: enhancement | architecture | code_quality | testing | ui_ux | performance | observability | resilience | developer_experience
  domain: <specific subsystem or component family>
  category: architecture | code_quality | simplification | developer_experience | performance | resilience | observability | ui_hierarchy | ui_interaction | ui_accessibility | ui_typography | ui_performance | ui_consistency | testing
  value_level: high | medium | low
  confidence: HIGH | MEDIUM
  grounding_assessment: HIGH | MEDIUM
  file: <relative path>
  line: <line or range>
  exact_quote: <verbatim current-state evidence>
  title: <specific one-line title>
  current_state: <what exists now, without calling it broken>
  confirms_current_code_is_working: yes | no
  enhancement: <specific implementable improvement>
  expected_impact: <what improves>
  effort: S | M | L
  dependencies: <other enhancement ids or N/A>
  alternative_interpretation: <why current design might be intentional>
  disproof_attempt: <required for high-value; recommended for all>
  rejection_risk: <what would make this a bad suggestion>
END
```

## Validated finding

```text
VALIDATED_FINDING
  candidate_id:
  status: CONFIRMED | DISPROVED | UNVERIFIED | PRE_EXISTING
  final_severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
  confidence: HIGH | MEDIUM
  grounding_assessment: HIGH | MEDIUM | LOW
  file:
  line:
  exact_quote:
  title:
  problem:
  impact:
  fix:
  validation_evidence:
  disproof_reason: <required if DISPROVED>
  verification_mode: STATIC | STATIC_PLUS_RUNTIME
  runtime_validation: <command or N/A>
  linked_claims:
  linked_surfaces:
  linked_boundaries:
  ai_pattern: <same value from candidate or N/A>
  inline_routing: CRITIC_REQUIRED | REVIEWER_FINALIZED | REVIEWER_DOWNGRADED
  finalization_status: FINALIZED | DOWNGRADED | N/A
  size: S | M | L
END
```

## Validated enhancement

```text
VALIDATED_ENHANCEMENT
  candidate_id:
  status: CONFIRMED_HIGH_VALUE | CONFIRMED_MEDIUM_VALUE | REJECTED | UNVERIFIED
  track:
  domain:
  category:
  confidence: HIGH | MEDIUM
  grounding_assessment: HIGH | MEDIUM | LOW
  file:
  line:
  exact_quote:
  title:
  current_state:
  confirms_current_code_is_working: yes | no
  enhancement:
  expected_impact:
  effort: S | M | L
  validation_evidence:
  dependency_map:
  rejection_reason: <required if REJECTED>
END
```

## Critic result

```text
CRITIC_RESULT
  finding_id:
  verdict: UPHELD | REFINED | DOWNGRADED | OVERTURNED
  original_severity: CRITICAL | HIGH
  final_severity:
  grounding_assessment: HIGH | MEDIUM | LOW
  file:
  line:
  exact_quote:
  title:
  final_problem:
  final_fix:
  ai_pattern: <same value from validated finding or N/A>
  verdict_reason:
  coverage_gap:
END
```

## Enhancement critic result

```text
ENHANCEMENT_CRITIC_RESULT
  enhancement_id:
  verdict: UPHELD_HIGH_VALUE | UPHELD_MEDIUM_VALUE | REFINED | MERGED | DOWNGRADED | REJECTED
  final_category:
  final_title:
  grounding_assessment: HIGH | MEDIUM | LOW
  file:
  line:
  exact_quote:
  final_enhancement:
  expected_impact:
  effort: S | M | L
  dependencies:
  verdict_reason:
END
```

## Test drift review

```text
TEST_DRIFT_REVIEW
  related_findings:
  commands_run:
  behavior_assertions_verified:
  stale_tests_found:
  weak_assertions_found:
  property_based_opportunities:
  mutation_resilience_gaps:
  remaining_uncertainty:
END
```

## Final critic check

```text
FINAL_CRITIC_CHECK
  verdict: PASS | REVISE
  required_revisions:
  severity_adjustments:
  findings_to_drop:
  findings_to_reclassify_as_enhancements:
  enhancements_to_reclassify_as_defects:
  unsupported_report_claims:
  missing_or_empty_ledgers:
  unsupported_strengths:
  coverage_note_fixes:
  count_mismatches:
  coverage_closure_failures:
  depth_plan_failures:
  selected_track_dilution_detected: yes | no
END
```

## Source-of-truth packet outline

```markdown
# Source of Truth Packet

## Repo Identity
## Tech Stack
## Commands
## Public Surfaces
## Trust Boundaries
## MCP and Agent Surfaces
## Claims Needing Verification
## Test and Quality Gates
## UI Applicability
## AI/Agent Applicability
## Review Track Recommendation
## Prohibited Assumptions
```
