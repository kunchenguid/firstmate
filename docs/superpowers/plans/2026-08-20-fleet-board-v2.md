# Fleet Board v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing Bearings/Lavish board to `fm-bearings-board.v2` with quota usage, explicit Firstmate custody, and expandable Underway task detail while preserving the existing safe build and answer-routing path.

**Architecture:** Keep `fm-fleet-snapshot.sh` as the canonical state source and `fm-bearings-snapshot.sh` as its bounded projection. Add usage and supervisor data only to the board payload at compose time, with the existing board builder validating the full payload before injection and the existing template rendering the static page.

**Tech Stack:** Bash, jq, HTML/CSS/vanilla JavaScript, executable shell behavior tests, and the repository browser-test pattern.

**Spec:** `/Users/karanmanoharan/karan-agent-workspace/data/fleet-ui-usage-context/report.md`, sections 4 and 5 slices 1 and 2, plus `decision-context-window-investment.md`.

## Global Constraints

- Ship exactly report section 5 slices 1 and 2.
- Do not implement per-harness transcript or model context readers.
- Render `model window: not measured` for every Underway task detail.
- Preserve one Bearings/Lavish board, existing answer kinds, safe injection, answer bounds, build-before-bind, and bind-before-arm ordering.
- Accept only HTTPS PR URLs.
- Use empty strings for absent snapshot `model` and `effort` meta keys.
- Keep all UI copy concise and avoid redundant supporting copy.
- Use behavior tests through executable interfaces and never assert implementation source text.

### Task 1: Snapshot model and effort fields

**Files:**
- Modify: `bin/fm-fleet-snapshot.sh`
- Modify: `bin/fm-bearings-snapshot.sh`
- Test: `tests/fm-fleet-snapshot-view.test.sh`
- Test: `tests/fm-bearings-snapshot.test.sh`

**Interfaces:**
- `fm-fleet-snapshot.sh --json` emits each task's `model` and `effort` strings beside `harness`.
- `fm-bearings-snapshot.sh --json` and its default TOON output preserve those values on bounded `in_flight` rows.

- [x] **Step 1: Add failing snapshot assertions**

  Extend the existing fixture meta with `model=claude-fable-5-thinking-high` and `effort=default`, then assert the JSON task row exposes both values. Add a second fixture row without either key and assert both values are empty strings. Extend the Bearings fixture assertion to compare JSON and TOON values for the bounded `in_flight` row.

- [x] **Step 2: Run focused snapshot tests and confirm the new assertions fail**

  Run `tests/fm-fleet-snapshot-view.test.sh` and `tests/fm-bearings-snapshot.test.sh`. The new assertions must fail because the fields are not yet emitted.

- [x] **Step 3: Implement minimal field propagation**

  Read `model` and `effort` with `meta_value`, pass both through the task `jq -n` arguments, add them to the task object as strings, and project them into every bounded Bearings `in_flight` row. Do not assign defaults.

- [x] **Step 4: Run focused snapshot tests and verify JSON/TOON parity**

  Run `tests/fm-fleet-snapshot-view.test.sh` and `tests/fm-bearings-snapshot.test.sh` and confirm all pass.

### Task 2: Board v2 payload validation and rendering

**Files:**
- Modify: `bin/fm-bearings-board.sh`
- Modify: `.agents/skills/bearings/assets/board-template.html`
- Modify: `.agents/skills/bearings/SKILL.md`
- Test: `tests/fm-bearings-board.test.sh`

**Interfaces:**
- `fm-bearings-board.sh build payload.json` accepts only `fm-bearings-board.v2` payloads with valid `usage`, `supervisor`, and upgraded `underway` rows.
- The injected page renders Provisions, the supervisor strip, dense Underway rows, and read-only accessible detail expansion without changing answer routing.

- [x] **Step 1: Add failing builder contract tests**

  Update the valid fixture to schema v2 with `usage`, `supervisor`, and a complete Underway row. Add refusal cases for missing usage, available usage without providers, non-numeric provider headroom, missing Underway `owner`, missing Underway `next`, and non-HTTPS Underway `pr_url`. Add a dedicated existing-board preservation case. Add acceptance cases for unavailable usage with a bounded reason, provider headroom unknown, absent optional task fields, exhausted providers, and zero providers.

- [x] **Step 2: Run the board test and confirm the new contract tests fail**

  Run `tests/fm-bearings-board.test.sh`. It must fail on the old schema and missing v2 validation/rendering behavior.

- [x] **Step 3: Implement fail-closed v2 validation**

  Change the board schema constant to `fm-bearings-board.v2`. Require a `usage` object with `available` boolean and, when unavailable, a non-empty bounded `reason`; when available require a providers array and validate provider rows, allowing explicit unknown headroom without inventing a percentage. Require a `supervisor` object with identity and crew count plus optional model, effort, and startup-memory fields. Require Underway `owner`, `state_detail`, and `next`, preserve optional fields, and reuse HTTPS URL validation for `pr_url`.

- [x] **Step 4: Implement the static v2 board surfaces**

  Add the supervisor strip, Provisions section, provider empty/unavailable/attention states, source read time, provider runway and exhausted/tight/unknown badges, and the dense Herdr-style Underway row. Make each row keyboard accessible with button semantics and an expandable read-only detail containing custody, reconciled state, repo/worktree, harness/model/effort, recent status, blockers, PR/report links, `model window: not measured`, and required next action.

- [x] **Step 5: Update Bearings composition guidance**

  Document that the builder payload is v2, usage comes from fresh `quota-axi --json` data at compose time, unavailable usage is explicit, provider absence remains empty, supervisor data comes from compose-time Firstmate knowledge, and every Underway row receives a composed next action. Keep slice 3 excluded.

- [x] **Step 6: Run focused board tests and browser rendering checks**

  Run `tests/fm-bearings-board.test.sh` using the repository's existing headless browser pattern. Verify exhausted and unavailable usage states, zero-provider empty state, accessible detail expansion, custody text, `model window: not measured`, HTTPS link behavior, and injection round-trip preservation.

### Task 3: Full changed-scope verification and commit

**Files:**
- Review: all branch changes

- [x] **Step 1: Run changed selection and lint**

  Run the focused snapshot and board tests, the repository changed-test selection, `bin/fm-lint.sh`, and `bin/fm-doc-audience-check.sh`.

- [x] **Step 2: Review the complete diff**

  Confirm no slice 3 reader, daemon, wrapper, dashboard, duplicate state store, new answer kind, unsafe URL, guessed model/effort default, or altered build/bind/arm order appears in the diff.

- [x] **Step 3: Commit the implementation**

  Commit all normal project code, tests, the skill update, and the implementation plan with a concise message and no agent co-author.
