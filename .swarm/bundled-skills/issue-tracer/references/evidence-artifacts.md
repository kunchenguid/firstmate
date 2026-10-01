# Evidence Artifacts

Use these templates to keep the investigation auditable and resumable. In compact mode each template may be a clearly-headed in-thread block with the identical required content - the storage changes, the required content does not. Every heading shown here is what `trace-check.sh` looks for; do not rename or drop one.

## `state.md`

Seeded by `trace-init.sh`, updated by the agent at phase boundaries, validated (never mutated) by `trace-check.sh`. Thirteen fixed `key: value` lines in this exact order, then a `## Gates` table:

```markdown
# Trace State: <slug>
protocol: 3.0.0
phase: <0|1|2|2.5|3|4|4.2|4.5|4.6|5|5.1|closed>
tier: <S|M|L|unset>
classification: <unset|VALID|AMBIGUOUS|ALREADY_FIXED|NOT_A_BUG|FEATURE>
base-ref: <origin/main or other upstream ref, or unset>
base-sha: <40-hex or unset>
freshness: <synced|behind:<n>|fetch-failed:<reason>|user-override:"<quoted user text>"|unset>
phase0-tree-id: <40-hex or unset>
checkpoint-tree-id: <40-hex or unset>
handshake: <MATCH|SHIM|STALE:<path>|ABSENT|unset>
tools: <comma list, e.g. graphify,zvec_grep,gh,subagents,claude-cli,codex-cli or none>
merge: <AWAITING_USER_APPROVAL|APPROVED:<pr-head-sha>|MERGED|not-applicable>
next-action: <free text, one line>

## Gates
| gate | verdict | reviewed-commit | tree-id | artifact |
|---|---|---|---|---|
```

Gate rows (`plan-critic`, `implementation-review`, `final-critic`, `merge-approval`) are appended, never edited.

## `01-issue-summary.md`

```markdown
# Issue Summary

## Source
- Issue: [URL or user-provided text]
- Repo: [owner/repo or local path]
- Labels: [labels]
- State: [open/closed/unknown]

## Observed Behavior
[What actually happens. Include exact errors and stack traces.]

## Expected Behavior
[What should happen.]

## Reproduction Steps
1. [Step]
2. [Step]

## Environment
- Runtime:
- OS/platform:
- Browser/device:
- Feature flags/config:
- External services:

## Acceptance Criteria
- [ ] AC1: [Measurable behavior]
- [ ] AC2: [Measurable behavior]

## Classification
[One of VALID, AMBIGUOUS, ALREADY_FIXED, NOT_A_BUG, FEATURE, with evidence. Must match state.md's `classification:` field.]

## Related Issues
- [Sibling issue/PR - title terms, error strings, or touched paths that connect it]

## Ambiguities
- [Question or missing input]
```

## `02-reproduction.md`

```markdown
# Reproduction Evidence

## Commands Tried

### Attempt 1
- Command:
- Exit code: [N]
- Result: CONFIRMED / NOT REPRODUCED / BLOCKED

```text
[Exact output]
```

## Minimal Reproduction
- Test/script/checklist:
- Why it matches the reported issue:

## Reproduction Verdict
[Confirmed, blocked, or non-reproducible with reason.]

## Fixing Change
[ALREADY_FIXED classification only: the specific commit/PR that fixed it, identified via the timeline API, `git log -S`/`-G`, or `git bisect`.]

## Acceptance checks

(Appended at Phase 2.5, after localization.)

| AC | class | check | argv | expect | pre-fix | post-fix | notes |
|---|---|---|---|---|---|---|---|
| AC1 | DISCRIMINATING / PRESERVING / NEW-SURFACE / NON-EXECUTABLE | C1 or DOCS_ONLY/HOST_ONLY/PRODUCT_DECISION/EXTERNAL_SERVICE_UNAVAILABLE | `<command>` or `-` | `<regex>` or `-` | RED / GREEN / ERROR / `-` | GREEN or `pending` | [substitute evidence path or free text] |

The table splits each row on `|`, so the `argv` cell must never contain a literal `|` (for example a shell pipeline). If a check needs a pipeline, write it as a small script under `repro/` and put the script's path/invocation in `argv` instead of the raw pipeline. Rows must have exactly ten pipe-separated fields, including the leading and trailing delimiters; missing a final delimiter is malformed just like an extra delimiter. The parser accepts LF and CRLF line endings by stripping only each record's terminal CR, while embedded C0/DEL control bytes in any cell are rejected before diagnostics. `trace-check.sh` reports the row shape/control failure without interpolating the untrusted cell.

## Red checkpoint
manifest: repro/checkpoint.manifest
checkpoint-tree-id: <40-hex>
```

## External checkpoint anchor

After the final Phase-2.5 checkpoint and before production edits, the implementation owner runs `repro-check.sh anchor --slug <slug>` and publishes the exact one-line receipt in an external, reviewer-visible issue or PR conversation. This publication and its timing are a human-enforced gate; the local validator cannot attest to either. The receipt has no secrets or source content:

```text
issue-tracer-checkpoint-v1 slug=<slug> manifest=<40-hex manifest blob> semantics=<40-hex acceptance-table digest> tree=<40-hex checkpoint-tree-id>
```

Record the publication URL or conversation identifier and a verbatim discovery copy in the trace, but never treat that local copy as authority. The owner must not regenerate the receipt after implementation begins. Independent reviewers verify the externally copied literal with `repro-check.sh verify-anchor --slug <slug> --receipt '<literal>'`; verification uses the no-filter manifest digest, the ordered acceptance-table semantic digest, and the `checkpoint-tree-id` recorded in `state.md`, not the live working-tree tree. Any malformed, stale, in-place-edited, semantic-table-edited, or delete-and-refrozen manifest fails closed. A byte-identical refreeze is intentionally accepted.

Receipts emitted before the `semantics=` field was introduced are not
compatible with this schema and are rejected as malformed. No migration is
provided: an old receipt cannot prove that the acceptance table was frozen,
so a pre-implementation trace must be rechecked and re-anchored, while a
trace already under implementation must not silently regenerate its anchor.

## `03-localization-log.md`

```markdown
# Localization Log

## Active Hypotheses

### H1: [Hypothesis]
- Status: active / confirmed / ruled_out / inconclusive
- Suspected file/symbol:
- Evidence for:
- Evidence against:
- Commands/tests:
- Verdict:

## Files Read
- `path/file.ext:lines` - [why read] - [what was learned]

## Searches Run
- `<search pattern>` - [result]

## Tests/Commands Run
- `command` - PASS/FAIL/BLOCKED - [meaning]

## Ruled-Out Paths
- [Path] - [why ruled out]
```

## `04-root-cause.md`

```markdown
# Root Cause

## Summary
[What failed, where, and why.]

## Exact Location
- File:
- Symbol:
- Lines:

## Broken Contract
[Invariant or behavioral contract violated.]

## Triggering Conditions
[Inputs/state/environment required.]

## Evidence Chain
1. [Symptom]
2. [Code evidence]
3. [Command/test evidence]
4. [Ruled-out alternatives]

## Confidence
[0-100% with reason. Below 90%, return to localization with a NAMED missing-evidence target instead of guessing. If two hypotheses remain equally supported after a second pass, escalate to the user.]
```

## `05-fix-plan.md`

```markdown
# Fix Plan

## Issue
[Short summary.]

## Root Cause
[From 04-root-cause.md.]

## Candidate Fixes
| Candidate | Approach | Files | Pros | Cons | Verdict |
|---|---|---|---|---|---|
| A | [Minimal guard/logic/config/state/API fix] | [files] | [pros] | [cons] | selected/rejected |

## Selected Fix
[Exact behavioral change and why it is necessary and sufficient.]

## Files Expected to Change
- `path/file.ext` - [exact reason]

## Impact Analysis
- Callers/importers:
- Tests/fixtures:
- Config/docs:
- API/UI/CLI:
- Persistence/migrations:
- Security/privacy:
- Concurrency/idempotency:

## Anticipated Defect-Class Sweep (Phase 4.2)
- Pattern statement (draft):
- Search predicates (draft):
- Guardrail rung intended:

## Edge Cases
- [edge] - covered by [test/check]

## Test Plan
1. [Failing regression test]
2. [Impacted suite]
3. [Lint/type/build/security checks]

## Unwired Functionality Checklist
- [ ] Entry point reaches new/changed logic.
- [ ] All callers use the updated contract correctly.
- [ ] Error path is observable and handled.
- [ ] No new branch lacks tests or manual verification.
- [ ] Documentation/comments match actual behavior.

## Risk and Rollback
- Risk:
- Rollback:

## Critic Status
- Critic verdict:
- Required revisions:
```

## `06-critic-review.md`

Use `references/critic-gate.md` (Plan Critic section). The `## Reviewed SHA / diff hash` section records exactly two lines - `reviewed-commit: <40-hex>` and `tree-id: <40-hex>` - and `trace-check.sh` requires both to equal the `plan-critic` row's `reviewed-commit`/`tree-id` cells in `## Gates`. The artifact also records a verdict, `## Round N` per revision cycle, and `## Check replay`. Optional `06b-critic-recheck.md` records a later recheck round in the same shape when the plan changes after initial approval.

## `07-approved-plan.md`

```markdown
# Reviewed Plan Awaiting Approval

[Copy final 05-fix-plan.md here.]

## User Approval
- [ ] User explicitly approved implementation on [date/time/session note]
```

## `08-test-results.md`

```markdown
# Test Results

## Regression Test
- Command:
- Before fix: FAIL / not run with reason
- After fix: PASS / FAIL

## Acceptance check results

(One `### Check <id>` block per executable row in the Acceptance checks table, from `repro-check.sh run` output.)

### Check C1 (DISCRIMINATING)
- base: <sha> exit=<n> result=RED log=repro/C1.base.log
- head: <reviewed-commit or tree-id> exit=<n> result=GREEN log=repro/C1.head.log
- argv: <argv>
- expect: <regex>
- verdict: PASS

## Quality Checks
- Lint:
- Typecheck:
- Build:
- Format:
- Security/static checks:

## Deferred-Work Scan
- Command: `.opencode/skills/issue-tracer/scripts/scan-deferred.sh`
- Result: [clean, or each hit + disposition]

## Verification Reasoning
[Why the fix is correct beyond merely making tests pass.]

## Checkpoint verification
- Command: `repro-check.sh verify-checkpoint --slug <slug>`
- Result: [OK for every path, or CHANGED entries reconciled via a manifest amendment]

## Test Drift Review
[Any stale tests found and how they were handled.]
```

## `08a-recurrence-sweep.md`

Full-sweep variant (default; required whenever the change corrects any incorrect behavior, data, or docs):

```markdown
# Recurrence Sweep and Guardrail

## Defect Class
[One-sentence pattern statement: the shape of the mistake - API misused, guard omitted, contract assumed, encoding confused - not the site of it.]

## Predicates and Results
- Predicate 1: `<rg/AST/type query>`

```text
[Full result set. An empty result is evidence only if the predicate is shown.]
```

## Dispositions
| Hit (file:line) | Disposition | Justification |
|---|---|---|
| path:line | FIX / FALSE_POSITIVE / OUT_OF_CLASS / DEFERRED_WITH_USER_APPROVAL | [why; for DEFERRED: tracked issue link + quoted user acknowledgment] |

## Guardrail
- Rung chosen: [lint/static rule > type constraint > runtime/trust-boundary assertion > CI check > documented invariant + regression family]
- Infeasibility reasons (required if landing on either of the two weakest rungs): [why each stronger rung is infeasible for this class - "faster" is not a reason]
- Demonstration: [revert-check / mutation / synthetic instance] - captured output showing it FAILS on the original defect and PASSES on the fixed code.
```

Fast path (only when the change corrects zero incorrect behavior/data/docs - pure style/naming): mark the artifact with the exact line `no-defect-class: true` and fill in `## Justification`. `trace-check.sh phase 4.2` looks for that marker line anywhere in the file; when present it requires `## Justification` to hold real (non-bracketed) text and skips the full-sweep headings entirely.

```markdown
# Recurrence Sweep and Guardrail

no-defect-class: true

## Justification
[Reason this change has zero behavioral surface - one line.]
```

## `08b-implementation-review.md`

Use `references/critic-gate.md` (Implementation Review section). The `## Reviewed SHA / diff hash` section records exactly two lines - `reviewed-commit: <40-hex>` and `tree-id: <40-hex>` - and `trace-check.sh` requires both to equal the `implementation-review` row's `reviewed-commit`/`tree-id` cells in `## Gates`. The artifact also records a verdict, `## Independently re-run`, `## Check integrity`, and the `## Deferred / Scoped-Out / Unwired` finding.

## `09-final-critic.md`

Use `references/critic-gate.md` (Final Critic section). The `## Reviewed SHA / diff hash` section records exactly two lines - `reviewed-commit: <40-hex>` and `tree-id: <40-hex>` - confirmed equal to shipped HEAD, and `trace-check.sh` requires both to equal the `final-critic` row's `reviewed-commit`/`tree-id` cells in `## Gates`. The artifact also records a verdict, `## Acceptance criteria evidence`, and the `## Deferred / Scoped-Out / Unwired` finding. Optional `09b-final-critic-delta.md` records a later delta review in the same shape after a post-approval edit.

## `10-pr-body.md`

Use `assets/pr-template.md`, including the `## Acceptance Criteria -> Evidence` map, the `## Waivers (or none)` section, and the `## Merge status` section with its `PR head: <40-hex>` line. `trace-check.sh phase 5` requires all three exact headings/lines plus a `state.md` `merge:` value of `AWAITING_USER_APPROVAL`, `APPROVED:<sha>`, or `MERGED`.

## `10-ci-feedback.md`

Written when CI rounds occur after publication: one entry per round with the failing check name, the exact failure output, the diagnosis, and the fix commit. Absent when no CI round required a response.

## `10b-merge-approval.md`

```markdown
# Merge Approval

## User approval (verbatim)
[The interactive user's exact approval text, quoted.]

## PR head SHA
[40-hex]

## Final critic reviewed-commit
[40-hex - must equal PR head SHA]
```

`trace-check.sh merge` checks presence and that the two SHAs are equal 40-hex, and prints "NOTE: human-enforced gate; this validator checks presence and binding only" - it can never certify that a real interactive approval occurred, only that one is recorded and bound to the right commit.

## `repro/` layout

Lives inside the trace directory (git-excluded, never committed): `checkpoint.manifest` (rows are appended, never edited - a frozen `(path, check-id)` pair is superseded only by a recorded `AMEND` row, while distinct check ids may share a path only when they capture identical current bytes; divergent effective blobs for one path fail closed, and both the header's recorded row count and `seq` continuity are validated on every read and write; header `# issue-tracer checkpoint manifest v1 rows=<N>`, restamped with the row and seeded by `trace-init.sh` as `rows=0`, and see `references/acceptance-checks.md` for what that does and does not guarantee) plus `<check-id>.base.log` and `<check-id>.head.log` per executable check, written by `repro-check.sh run`.

## OBE subset

`ALREADY_FIXED` classification runs Phases 0-2 only. `trace-check.sh phase 2.5` through `phase 5` accept the subset and report `OK obe-subset` once `02-reproduction.md` contains the `## Fixing Change` heading.

## Test Validation and Drift Review

See `references/full-resolution-contract.md` for this section - kept there as the single copy; this reference only points to it so the requirement is not duplicated and cannot drift.
