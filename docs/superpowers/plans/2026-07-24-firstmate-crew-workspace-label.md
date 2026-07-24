# FirstMate Crew Workspace Label Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ambiguous primary Herdr worker-container label `firstmate` with `FirstMate Crew` without orphaning existing workspaces.

**Architecture:** Keep `fm_backend_herdr_workspace_label` as the single label owner. New primary workspaces use `FirstMate Crew`; secondmate labels remain unchanged. Read-only workspace discovery prefers the new label and falls back to the legacy `firstmate` label so upgrades reuse existing containers until an operator renames them.

**Tech Stack:** Bash, jq, Herdr CLI, shell regression tests.

## Global Constraints

- Do not rename or alter secondmate workspace labels.
- Never create a duplicate primary workspace merely because an installation still uses the legacy label.
- Preserve the presentation-ordering compatibility for legacy `firstmate/...` child labels.
- Deliver through the repository's no-mistakes PR workflow; do not merge without captain approval.

---

### Task 1: Primary workspace label and compatibility

**Files:**
- Modify: `tests/fm-backend-herdr.test.sh`
- Modify: `bin/backends/herdr.sh`

**Interfaces:**
- Consumes: `FM_HOME`, `.fm-secondmate-home`, and `herdr workspace list` JSON.
- Produces: `fm_backend_herdr_workspace_label` returning `FirstMate Crew` for a primary home; `fm_backend_herdr_workspace_find` preferring that label and falling back to legacy `firstmate`.

- [x] **Step 1: Change the focused tests to expect `FirstMate Crew` and add a legacy-discovery regression**

Update the primary-label, empty-marker, create, reuse, and no-focus fixtures. Add a test whose workspace list contains only `firstmate` and assert that `fm_backend_herdr_workspace_find` returns its id without creating another workspace.

- [x] **Step 2: Run the focused suite and verify it fails for the missing behavior**

Run: `tests/fm-backend-herdr.test.sh`

Expected: FAIL because the implementation still returns and creates `firstmate`.

- [x] **Step 3: Implement the new label and legacy fallback**

Add explicit primary and legacy-primary label constants. Return `FirstMate Crew` for unmarked and empty-marker homes. In workspace discovery, select the new exact label first and fall back to `firstmate` only for a primary home. Update presentation ordering to recognize the new parent while retaining legacy child-prefix compatibility.

- [x] **Step 4: Run the focused suite and repair only directly affected fixtures**

Run: `tests/fm-backend-herdr.test.sh`

Expected: PASS with no failures.

### Task 2: Documentation and broader verification

**Files:**
- Modify: `docs/configuration.md`
- Modify: `docs/herdr-backend.md`
- Modify: any Herdr-specific test fixture that fails solely because it models the primary workspace label.

**Interfaces:**
- Consumes: the label and compatibility behavior from Task 1.
- Produces: upgrade documentation and cross-suite regression coverage.

- [x] **Step 1: Document the visible label and upgrade behavior**

State that new primary homes use `FirstMate Crew`, secondmates retain `2ndmate-<id>`, and discovery continues to adopt an existing legacy `firstmate` workspace until it is renamed with `herdr workspace rename <workspace-id> 'FirstMate Crew'`.

- [x] **Step 2: Run Herdr-related tests**

Run:

```bash
tests/fm-backend-herdr.test.sh
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
tests/fm-backend-herdr-presentation-e2e.test.sh
```

Expected: all tests PASS.

- [x] **Step 3: Run the repository test family selected for the touched backend**

Run: `bin/fm-test-run.sh --help`

Use its documented Herdr/backend family command and expect zero failures.

- [ ] **Step 4: Commit and validate through no-mistakes**

Commit the scoped implementation and documentation, then run:

```bash
no-mistakes axi run --intent "Rename the ambiguous Herdr worker workspace shown beneath FirstMate HQ to FirstMate Crew for clarity. Preserve existing installations by finding the legacy lowercase firstmate workspace rather than creating a duplicate; leave secondmate labels unchanged; update tests and documentation; deliver through a PR without merging."
```

Drive every returned gate to `checks-passed` or a user-owned decision.
