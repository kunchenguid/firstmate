---
name: pr-description
description: >-
  Agent-only contract for writing a human-readable GitHub PR body or Codebase MR description.
  Load immediately before preparing or revising any PR/MR description, including daily sync MRs.
user-invocable: false
metadata:
  internal: true
---

# PR and MR descriptions

This skill is the single owner of Firstmate's PR/MR description structure, abstraction level, visual-selection rule, platform-rendering profile, and daily-sync variant.
The description is a decision surface for a reviewer first and an audit record second.
Its first screen must let someone who did not participate answer what changes after merge, whether they need to act or worry, and whether merging has any special requirement.

## Required reading order

Use these layers in order.

### 1. What changes after merge

Write for the captain, reviewer, operator, or user who wants the outcome without reconstructing the implementation.
Use two to four plain-language sentences at product, workflow, or operational-behavior level.
State what becomes possible, stops happening, or behaves differently after merge, then state any reader action and special merge requirement.
Say explicitly when there is no required action, no expected behavior change, or no special merge requirement.

Do not call this section "What we did."
That heading invites a list of files, functions, commands, and internal names instead of the result a person will experience.

The first screen must not contain commit SHAs, check IDs, task IDs, internal test filenames, pipeline step or job names, parent hashes, exhaustive file lists, or long commands.
Do not lead with branch names, function names, internal component names, implementation chronology, or phrases such as "refactored X" when they do not explain the observable result.
Retain useful machine-facing identifiers in a lower layer or folded block.

### 2. Why and impact

Write for the reviewer deciding whether the change is necessary and appropriately scoped.
Explain the problem or opportunity, who or what is affected, important non-effects, compatibility boundaries, risks, and rollback implications.
Stay at behavior and system-boundary level.
Name an internal subsystem only when the reader needs it to understand the impact.

### 3. Validation, gaps, and follow-up

Write for the reviewer deciding whether the evidence is adequate and whether anything remains to do.
Summarize outcomes instead of narrating the test machinery.
Separate what passed, what was not verified, known risk, and any owner-visible follow-up.
A compact checklist is appropriate when the states themselves matter.
Move check IDs, job names, full commands, logs, transient failures, and internal test filenames into the implementation-and-traceability layer.

### 4. Implementation and traceability

Write for maintainers investigating the implementation, reproducing evidence, or auditing history later.
Put exact commands, commit and parent hashes, check IDs, task IDs, pipeline jobs, internal test filenames, logs, exhaustive file tables, and detailed conflict chronology here.
Use one or more collapsed details blocks for long or machine-oriented material so it remains available without dominating the human reading path.
Keep a short implementation note outside the fold only when it changes how the reviewer should reason about safety or compatibility.

## Smallest useful visual

The first screen must include one visual when a single diagram, table, tree, pseudocode block, or focused diff makes the outcome or impact understandable at a glance.
Choose the smallest view that carries the point:

- Use pseudocode for a decision rule or algorithm.
- Use a call tree for runtime control flow.
- Use a file or component tree for ownership, layout, or a broad refactor.
- Use a Mermaid diagram only on a platform that renders it.
- Use a focused diff when the changed shape is the point.
- Use a table for exact mappings, comparisons, states, or repeated fields.

Keep only the labels and relationships needed for the reader's decision.
Place the visual next to the two-to-four-sentence outcome it supports.
Do not add a visual to a typo correction, one-line fix, dependency pin, or similarly trivial change when prose is already faster to understand.
The rule is comprehension, not decoration.

## Platform rendering profile

The 2026-08-19 observations below come from browser reads of the same probe body on this change's real GitHub PR and Codebase MR, not from platform documentation or Markdown-library assumptions.

| Feature | GitHub PR body | Codebase MR description | Required fallback |
| --- | --- | --- | --- |
| Mermaid fenced block | Live result recorded after probe | Live result recorded after probe | Use an ASCII tree, focused diff, or table where Mermaid does not render. |
| Details block | Live result recorded after probe | Live result recorded after probe | Use a short `Implementation and traceability` section with compact bullets where it does not collapse. |
| Markdown table | Live result recorded after probe | Live result recorded after probe | Use short labeled bullets where it does not render as a table. |
| Task list | Live result recorded after probe | Live result recorded after probe | Use `Done`, `Pending`, and `Not verified` labeled bullets where interactive task boxes do not render. |
| Markdown image | Live result recorded after probe | Live result recorded after probe | Use a descriptive link and equivalent alt text where the image does not render inline. |

## General description shape

Use the headings that best fit the change, while preserving the four-layer order.

```markdown
## What changes after merge

Two to four plain-language sentences covering the outcome, reader action, and any special merge requirement.

The smallest useful visual, when it materially improves comprehension.

## Why and impact

The problem, affected scope, important non-effects, and material risk.

## Validation, gaps, and follow-up

- Passed: outcome-level evidence.
- Not verified: explicit gap, or "None beyond the platform checks above."
- Follow-up: owner and action, or "No follow-up required."

<details>
<summary>Implementation and traceability</summary>

Exact commands, identifiers, filenames, job details, logs, hashes, or exhaustive file lists.

</details>
```

## Daily sync variant

A daily sync reviewer cares what came in, whether any behavior change deserves attention, whether they must act, and whether the merge method has a special requirement.
They do not need merge-parent hashes or conflict chronology on the first screen.

```markdown
## What this sync brings in

Two to four plain-language sentences naming the meaningful incoming behavior, whether the fork's local behavior remains intact, any reader action, and any special merge requirement.

Use a compact incoming-versus-preserved table or tree when several streams would otherwise be hard to scan.

## Why and impact

State why the sync is needed, who is affected, preserved local behavior, and noteworthy risk or compatibility limits.

## Validation, gaps, and follow-up

- Passed: outcome-level evidence.
- Not verified: explicit gaps.
- Reader action: required action or "None."
- Merge requirement: special method or "None."

<details>
<summary>Sync implementation and traceability</summary>

Pinned upstream commit, merge commit and parents, conflict chronology, exact commands, check IDs, internal test filenames, and job-level evidence.

</details>
```

## MR 74 before and after

The existing MR 74 description is the negative example.
Its first screen begins with pinned and merge commit hashes, both parent hashes, fixup commit hashes, internal test filenames, and check IDs before a reader can determine the human outcome.
Do not reproduce those machine identifiers here because this example is about the abstraction boundary, not a second audit record.

The same change written for a person begins as follows.

```markdown
## What this sync brings in

This sync brings in more reliable remote-secondmate status and delivery reporting, clearer Lavish scout guidance, and stronger workflow linting.
The fork's Relay and Codebase-specific behavior remains intact, and reviewers do not need to take any migration or setup action.
All Codebase checks pass; merge this as a merge commit rather than squash or rebase so the upstream sync boundary stays intact.

| Incoming behavior | What the reviewer should know |
| --- | --- |
| Remote secondmates | Status reads and uncertain-delivery reporting are more reliable. |
| Scout guidance | Lavish investigations receive clearer prompts. |
| Workflow validation | Codebase jobs use the required workflow linter consistently. |
| Fork-specific behavior | Relay and Codebase customizations are preserved. |

## Why and impact

The fork was behind six upstream changes from 2026-08-18.
The sync affects remote secondmate supervision, scout guidance, and CI validation without changing the captain's normal workflow or requiring local reconfiguration.

## Validation, gaps, and follow-up

- Passed: all 14 Codebase checks, including the previously failing lint and behavior groups.
- Not verified: the full changed suite and environment-gated Herdr, Pi, TypeScript, and C-compiler cases.
- Reader action: none beyond review.
- Merge requirement: preserve the merge commit; do not squash or rebase.

<details>
<summary>Sync implementation and traceability</summary>

Place the pinned upstream commit, merge commit and both parents, fixup commits, check IDs, exact commands, internal test filenames, rerun history, and unresolved suite details here.

</details>
```

The rewritten first screen answers what came in, whether the reader must act, and how the MR must merge before exposing any machine-only identifier.

## Final read-through

Before publishing, read only the title and first screen as if you had not participated in the work.
Revise until that view answers what changes after merge, who is affected, whether the reader must do anything or worry, and whether merging has a special requirement.
Then verify that every machine-facing detail needed for traceability still exists in a lower layer or folded block.
