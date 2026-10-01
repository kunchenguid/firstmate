---
name: loop
audience: swarm-plugin
description: >
  Full execution protocol for MODE: LOOP — the compound-engineering loop:
  brainstorm → plan → build → review → improve, iterating under
  defense-in-depth stop conditions with generator/critic separation,
  durable resumable state, and mandatory compounding learning capture.
  Loaded on demand by the architect when the loop command emits a
  [MODE: LOOP ...] signal.
---

# Compound-Engineering Loop Protocol

MODE: LOOP runs an objective end to end as a series of gated phases, then
loops to compound improvements until the objective is met or a stop condition
fires. Each cycle reuses the existing mode skills (`brainstorm`, `plan`,
`critic-gate`, `execute`, `phase-wrap`) and ends with a learning-capture step
so the next cycle is cheaper — that is what makes the loop *compounding* rather
than merely repeating.

This is a real implementation workflow: it delegates to the coder, declares
scope, and mutates source code through the normal EXECUTE path. It is distinct
from full-auto (a critic gate via the `critic_oversight` agent that
intercepts phase completions and high-risk actions for review — full-auto
never plans, delegates, or executes; the architect retains ALL delegation
duty) and turbo (parallel lanes within a single phase). LOOP is a
user-initiated, gated, sequential, compounding workflow.

The two design rules that everything below serves:

1. **Separate the generator from the verifier.** The context that writes a
   change must never be the only context that approves it. Implementation,
   independent review, and critic challenge live in separate delegated
   contexts. Review is report-only; a distinct fix step applies changes.
2. **Stop on positive evidence or a budget — never on vibes.** Every phase has
   an entry gate and an exit gate backed by concrete evidence, and the loop has
   layered stop conditions so it can never run away.

---

## Step 0 — Parse Header

Parse the `[MODE: LOOP ...]` header to extract:

- `objective`: the goal text after the header (the WHAT to achieve). Empty only
  when `resume=true`.
- `max_cycles`: integer 1..5 (default 3) — hard cap on outer improvement cycles.
- `autonomy`: `auto` (default) or `checkpoint`.
  - `auto`: proceed across gates without prompting, but still enforce every
    hard stop condition and the mandatory review/critic gates.
  - `checkpoint`: pause at each phase gate and wait for explicit user approval
    before continuing.
- `depth`: `standard` (default) or `exhaustive` (wider exploration in
  BRAINSTORM and PLAN: more candidate approaches, deeper localization).
- `resume`: `true` | `false`. When true, resume the existing run from durable
  state instead of starting a new objective.

If the header is malformed or required fields are missing, report the error and
stop.

---

## Step 1 — Preconditions & Durable State

1. **Working tree.** Check `git status`. If the tree is dirty, surface the
   uncommitted changes and ask whether to proceed (checkpoint) or proceed only
   if the changes are clearly part of this objective (auto). Do not silently
   build on an unknown working state.
2. **Run state directory.** Loop state lives under `.swarm/loop/<run-id>/`
   (containment invariant — never write loop state outside `.swarm/`).
   - New run (`resume=false`): allocate a `run-id` (short slug + timestamp),
     create `.swarm/loop/<run-id>/state.json`, and record the baseline:
     objective, parsed parameters, start HEAD commit, `cycle: 0`,
     `phase: brainstorm`, empty `improvements` and `learnings` lists.
   - Resume (`resume=true`): locate the most recent `.swarm/loop/<run-id>/`
     with an unfinished state, read it, **validate required fields** (`run_id`,
     `cycle`, `phase`, `done` must all be present and have the correct types;
     if any are missing or malformed, report the corruption clearly and stop
     rather than continuing with undefined values), print a short progress
     summary (cycle N of max_cycles, current phase, last gate result), and
     continue from the recorded phase. If no resumable run exists, say so and
     stop.
   - **Retention:** On both new-run and resume entry, prune completed runs
     (`.done === true`) that exceed 10 in count — keep the 10 most recent by
     timestamp, remove the rest. This prevents unbounded state accumulation
     under `.swarm/loop/`.
3. **State is derived, not authoritative for code.** The durable state file
   tracks *loop control* (cycle counter, phase, gate outcomes, captured
   learnings, stop reason). Actual implementation progress is derived from git
   and the plan ledger (`.swarm/plan-ledger.jsonl`), never from conversation
   memory — so a killed/resumed session never loses or re-does work.

Write the state file after every gate transition. The on-disk state is the
single source of truth for resumability.

---

## Step 2 — The Cycle

One cycle is five phases run in order: **BRAINSTORM → PLAN → BUILD → REVIEW →
IMPROVE**. Do not skip or collapse phases. Each phase has an entry gate
(precondition) and an exit gate (positive evidence required before the next
phase begins). In `checkpoint` autonomy, pause at each gate for user approval.

When `autonomy=auto`, use the balanced-speed defaults instead of asking the user
for execution preferences: reviewer ON, test_engineer ON, sme_enabled ON,
critic_pre_plan ON, sast_enabled ON, drift_check ON, and council_mode,
hallucination_guard, mutation_test, phase_council, final_council OFF. Keep
commit frequency at phase-level only. During PLAN, choose the largest safe
parallel coder count from dependency-ready, file-disjoint task groups, clamped to
the configured limit (currently 6); if scopes overlap or are unknown, use 1.
This does not weaken QA; it removes only the preference prompt.

On cycle 2+, BRAINSTORM is replaced by a lightweight **refinement** step: feed
the prior cycle's captured improvements and residual findings into PLAN
directly (skip full discovery dialogue) — the objective is already framed.

### Phase 1 — BRAINSTORM (cycle 1 only)

- **Entry gate:** objective is non-empty; no approved plan already covers it.
- **Action:** Load `file:.swarm/bundled-skills/brainstorm/SKILL.md` and run it to
  produce `.swarm/spec.md` and a QA gate profile. With `depth=exhaustive`,
  require at least one non-obvious candidate approach.
- **Exit gate:** `spec.md` exists with explicit, testable success criteria and
  scope boundaries. Record the success criteria into loop state — they are the
  objective-met test used by the stop conditions. Checkpoint: confirm the spec
  with the user.

### Phase 2 — PLAN

- **Entry gate:** a spec (or, on cycle 2+, the improvement directives) exists.
- **Action:**
  1. Load `file:.swarm/bundled-skills/pre-phase-briefing/SKILL.md` (required before
     planning, especially on cycle 2+: it reads the prior retrospective and
     verifies codebase reality so the new plan reflects what actually changed).
  2. Load `file:.swarm/bundled-skills/swarm-plan/SKILL.md` to decompose the work into
     tasks and call `save_plan`. With `depth=exhaustive`, prefer finer task
     granularity and deeper localization.
  3. Load `file:.swarm/bundled-skills/critic-gate/SKILL.md` to put the plan through
     an independent critic.
- **Exit gate:** critic verdict is APPROVED (NEEDS_REVISION → revise and
  re-submit, max 2 cycles per the critic-gate skill; REJECTED → stop and report
  to the user). Record the verdict in loop state.

### Phase 3 — BUILD

- **Entry gate:** a critic-approved plan exists.
- **Action:** Load `file:.swarm/bundled-skills/execute/SKILL.md` and run the plan
  phase by phase. The coder implements each task; per-task QA gates (tests,
  lint, security, etc.) run as defined by the selected QA profile. The coder
  context is the **generator** — it does not get to declare its own work
  correct.
- **Exit gate:** all planned tasks for the cycle are implemented and their
  per-task QA gates pass with recorded evidence. NEVER weaken, mock, skip, or
  delete a failing test/assertion to make a gate pass — fix the root cause or
  stop and report.

### Phase 4 — REVIEW (report-only) + FIX

This phase is the heart of the generator/verifier separation. It runs on the
**actual current diff**, in contexts independent of the coder.

- **Entry gate:** BUILD exit gate passed; capture the current diff
  (`git diff` against the cycle's start commit).
- **Action:**
  1. **Independent reviewer.** Delegate the real diff and the QA evidence to a
     fresh reviewer context. It defaults to disbelief, looks for correctness
     bugs, regressions, security issues, missing edge cases, and
     claimed-vs-actual mismatches, and classifies each finding. The reviewer
     does not edit code — it reports.
  2. **Critic challenge.** Delegate the reviewer-approved diff and any
     HIGH/CRITICAL findings to a separate critic context that challenges weak
     evidence, overclaimed severity, and missing sibling-file checks. The
     critic may overturn the reviewer.
  3. **Fix step.** For every `NEEDS_REVISION` / `REJECTED` / `BLOCKED` item,
     return to the coder (generator) to fix it with code, tests, or evidence,
     then re-run the affected reviewer/critic gate. Any edit after approval
     invalidates that approval — re-review.
- **Exit gate:** reviewer approval AND critic approval on the latest diff, with
  the latest edit older than both approvals. Record the reviewer/critic verdicts
  durably alongside the phase evidence (the phase-wrap evidence manager writes
  retrospective and gate artifacts under `.swarm/evidence/` — keep the
  review/critic outcomes with that phase's evidence so `phase_complete` and any
  later audit can read them). This satisfies the mandatory implementation
  closeout gate.

### Phase 5 — IMPROVE (phase-wrap + compounding capture)

This is what makes the loop compound. Do not declare completion without it.

- **Entry gate:** REVIEW exit gate passed.
- **Action:**
  1. Load `file:.swarm/bundled-skills/phase-wrap/SKILL.md` and write the mandatory
     retrospective (the `phase_complete` gate blocks without a valid `retro-N`
     bundle). Rescan the codebase and update documentation exactly as the
     phase-wrap skill directs — that is, scoped to its authorized set
     (README.md / CONTRIBUTING.md / docs/ via the `docs` agent). Do NOT edit the
     governance contract files (AGENTS.md / CLAUDE.md); they constrain the loop
     and are out of scope for autonomous edits.
  2. **Capture learnings durably.** Distill what this cycle taught — recurring
     bug classes, surprising couplings, tooling gotchas, convention decisions —
     into the knowledge base (the `knowledge_add` tool / the memory tools when
     enabled) and/or a categorized note under `.swarm/loop/<run-id>/learnings/`.
  3. **Make learnings discoverable.** Ensure the next loop will actually read
     them: persist via `knowledge_add` (which `knowledge_recall` surfaces in
     later phases) rather than a write-only note nobody reads — capturing
     learnings nothing retrieves does not compound.
  4. **Feed findings forward.** Record any review/critic finding that recurred
     so it becomes an explicit check in the next cycle's reviewer prompt.
- **Exit gate:** retrospective written and accepted by `phase_complete`;
  learnings persisted; the cycle's improvements and residual findings recorded
  in loop state.

---

## Step 3 — Loop Decision (Stop Conditions)

After IMPROVE, evaluate the stop conditions **in order**. Use defense in depth:
several overlapping conditions, not one. Record the chosen `stop_reason` in
loop state.

1. **Objective met (primary).** The success criteria captured in Phase 1 are
   all satisfied AND the full validation suite / required QA gates are green.
   → STOP (success).
2. **Cycle budget exhausted.** `cycle >= max_cycles`. → STOP. Never exceed
   `max_cycles`.
3. **No-progress / plateau.** The just-finished cycle produced no qualifying
   improvement toward the objective (no new passing criteria, no accepted
   review fix that advanced the goal). → STOP and report the plateau; looping
   again would burn budget without progress.
4. **Oscillation.** The cycle reintroduced or reverted a change made in a prior
   cycle (the diff fingerprint repeats). → STOP and report; the loop is
   thrashing.
5. **Unrecoverable error.** A gate cannot pass for a reason outside this
   objective's scope (e.g., REJECTED plan, environment failure, a required
   external dependency is unavailable). → STOP and report.
6. **Explicit user stop.** The user asked to stop. → STOP immediately.

If none fire and budget remains: increment `cycle`, set the next cycle's input
to the recorded improvement directives + residual findings, and return to
**Phase 2 (PLAN)** (cycle 2+ skips full BRAINSTORM). In `checkpoint` autonomy,
confirm "continue for another cycle?" with the user before looping.

---

## Step 4 — Completion

When a stop condition fires:

1. Mark loop state `done` with the `stop_reason` and final HEAD commit.
2. Present a human-readable summary:
   - Objective and whether it was met.
   - Baseline → final state (what changed, key files/tasks).
   - Cycles run (and why it stopped).
   - Tasks completed vs deferred; residual review findings and where they are
     recorded.
   - Learnings captured this run and where they live.
   - Suggested next steps (e.g., open a PR via `/swarm pr-review` or the
     commit-pr flow — do NOT open a PR unless the user asks).
3. Emit a completion marker on its own line to summarize terminal state for human readers:

   `<loop-complete reason="objective-met|budget-exhausted|plateau|oscillation|unrecoverable-error|user-stop" cycles="N"/>`

---

## Durable State Schema (`.swarm/loop/<run-id>/state.json`)

A minimal, append-friendly shape — extend as needed but keep these fields:

```json
{
  "run_id": "rate-limit-20260618T0712Z",
  "objective": "add rate limiting to the public API",
  "params": { "max_cycles": 3, "autonomy": "checkpoint", "depth": "standard" },
  "start_commit": "<sha>",
  "cycle": 1,
  "phase": "review",
  "success_criteria": ["...", "..."],
  "gates": [
    { "cycle": 1, "phase": "plan", "result": "approved", "at": "<iso>" }
  ],
  "improvements": [],
  "learnings": [],
  "done": false,
  "stop_reason": null,
  "final_commit": null
}
```

---

## Autonomy Quick Reference

| Behavior | `auto` (default) | `checkpoint` |
| --- | --- | --- |
| Pause at phase gates | No | Yes — wait for user approval |
| Confirm before next cycle | No | Yes |
| Mandatory review + critic gates | Enforced | Enforced |
| Hard stop conditions (budget, plateau, oscillation, errors) | Enforced | Enforced |
| Weaken/mock/skip a failing test | Never | Never |

`auto` reduces prompts; it never reduces verification.

---

## Anti-Patterns (do not do these)

- Letting the coder context approve its own diff. Review and critic must be
  independent contexts.
- Treating passing tests, explorer output, or self-review as the implementation
  closeout gate. They are not.
- Editing code after reviewer/critic approval and then declaring done without
  re-review. Any post-approval edit invalidates the approval.
- Looping "one more time" past `max_cycles` or after a plateau because it feels
  close. Stop and report.
- Skipping the IMPROVE/compound capture step to finish faster. The compounding
  step is the point of the loop.
- Storing loop progress only in conversation context. Persist to
  `.swarm/loop/<run-id>/` so the loop survives interruption.
- Weakening, mocking, skipping, or deleting a failing assertion to turn a gate
  green. Fix the root cause or stop.
