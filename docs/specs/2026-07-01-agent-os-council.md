# Agent OS: the Council — Design Spec

Date: 2026-07-01
Status: approved-pending-review
Scope: the whole operating model (firstmate + claude-pm-system + stone-skills)
Build order: Phase 1 detailed here; Phases 2–5 outlined, each gets its own spec.

## Problem

The operating model already has council-shaped parts — specialist read-only
agents, a sole-writer crewmate, a false-green gate ledger — but verification
between "crewmate says done" and "captain accepts done" is **disciplinary, not
structural**. `done:` in `state/<id>.status` is self-reported; `eng-gate-verifier`
exists but nothing forces it to run. This is loop-engineering's anti-pattern #1
(the maker grading its own homework) and the most common failure mode of agent
pipelines (the verifier gets skipped).

Secondary problems, deferred to later phases: no thinker panel at intake, zero
loop-engineering conformance (no LOOP.md / budget / run-log / constraints /
loop-audit score), and a split-brain skill graph (discipline skills in
stone-skills, council/runtime skills unlinked in ~/.claude/skills).

## Decisions (captured with the design)

- **Council mix:** Claude-first. Claude does thinker + worker. The verifier
  stage adds a *foreign lens* for blind-spot coverage: **Fugu → codex → none**,
  in that order, degrading loudly, never silently.
- **Native primitives:** GA core only for the spine (subagents, hooks, ledger).
  Experimental agent teams reserved for Phase 5 thinker panels, easy to disable.
- **loop-engineering (cobusgreyling) is the bible:** adopt the discipline
  (maker/checker, default-REJECT verifier, attempt caps, L0→L3 ladder, state
  files) in Phase 1, and the actual tools (`loop-audit` as a CI gate,
  `loop-cost`, `loop-sync`) in Phase 3.
- **Role bindings** (TRINITY vocabulary → ours):
  - Coordinator → **firstmate** (routes, never does the work; `decide-or-delegate` is its brain)
  - Thinker → parallel read-only specialist panel (`eng-architecture`, `eng-security`, `eng-researcher`, Explore) — formalized Phase 2
  - Worker → **crewmate** (sole writer, worktree, brief contract) — unchanged
  - Verifier → **`eng-gate-verifier`** fresh-context default-REJECT + foreign lens — Phase 1
- **Stop condition:** verifier APPROVE over a green ledger. Never the worker's claim.

## Phase 1 — the Quarterdeck (structural verifier stage)

`done:` becomes **a claim, not an acceptance**.

### Flow

1. Crewmate appends `done: <line>` to `state/<id>.status` (unchanged).
2. Watcher wakes firstmate (unchanged). Firstmate's first act on a `done:` for a
   **ship** task is now `bin/fm-verify.sh <id>` — never direct acceptance.
3. `fm-verify.sh`:
   a. Runs the **foreign lens** on the crewmate's diff: Fugu (`fugu` model,
      OpenAI-compatible `https://api.sakana.ai/v1`, key `FUGU_API_KEY`) with
      fallback to `codex exec` (subscription-authed CLI), producing
      `data/<id>/lens-review.md`. If neither is available: log
      `lens: none (degraded)` and continue. Every hop is logged; no silent skip.
   b. Spawns **`eng-gate-verifier`** in a fresh context against the crewmate's
      worktree, with `data/<id>/brief.md` + the lens review as evidence.
      Verifier re-runs `gates/verify.sh` (when the repo has gates), re-executes
      the DoD claims itself, and never trusts the crewmate's report.
      Default stance: REJECT.
4. Verdict is appended to **`state/<id>.verdict`** — same append-only grammar
   as `.status`, one line per event:
   - `approve: <one line>`
   - `reject: <reason>` (attempt N of 3)
   - `escalate: <reason>`
   - `lens: fugu|codex|none <one line>`
5. **Hard gates:** `fm-merge-local.sh` and `fm-pr-check.sh` refuse to proceed
   unless the last verdict line for `<id>` is `approve:`. The backlog item may
   not move to `## Done` without it. Structural — scripts enforce it, not prose.
6. **On reject:** findings relayed to the crewmate via `fm-send.sh`; status
   returns to `working:`. **Attempt cap = 3** total verify attempts, then
   `escalate:` to the captain (loop-engineering: hard cap → human gate).

### Contract updates

- `fm-brief.sh` DoD gains the verify clause: "`done:` is a claim; an independent
  verifier will re-prove it against your worktree. Expect a reject round-trip
  if any claim doesn't reproduce."
- `AGENTS.md` §7 (lifecycle) + §8 (supervision) document the verify stage and
  the verdict file.

### Seams and scope guards

- `FM_LENS_CMD` (foreign lens) and `FM_VERIFY_CMD` (verifier spawn) are
  injectable env seams — same stub pattern as `JARVIS_WORKER_CMD` — so the
  entire loop is testable offline with echo stubs.
- **Ship tasks only.** Scouts (report-only) keep the current path in Phase 1.
- Verify stage is bounded: read-only verifier, one lens call, no writer spawns.

### Error handling

- Lens API failure (401/timeout/no credits) → log, fall through the chain.
- Verifier spawn failure → `escalate:` (never auto-approve on infrastructure
  failure — fail closed).
- Malformed/missing verdict file at merge time → merge scripts refuse (fail
  closed) with a bordered guard banner, matching `fm-guard.sh` conventions.

### Testing / gates (gate-driven, in firstmate's own ledger)

New gates in `~/firstmate/gates/ledger.json`, each observed red before green,
bash tests in `tests/` matching the existing suite style:

1. `gate-q1-verdict-grammar` — verdict file accepts only the four line forms.
2. `gate-q2-merge-refuses-unverified` — `fm-merge-local.sh` exits non-zero
   without a trailing `approve:` line.
3. `gate-q3-prcheck-refuses-unverified` — same for `fm-pr-check.sh`.
4. `gate-q4-reject-roundtrip` — reject relays findings and flips status to
   `working:` (stubbed lens + verifier).
5. `gate-q5-attempt-cap` — third reject produces `escalate:`, not a fourth loop.
6. `gate-q6-lens-degrade` — missing Fugu key + missing codex → `lens: none`
   logged, verify still runs (no silent skip, no crash).
7. `gate-q7-fail-closed` — verifier spawn failure yields `escalate:`, never
   `approve:`.

## Phases 2–5 (outline)

- **P2 — Council at intake:** thinker panel (parallel read-only specialists +
  Fugu-ultra deep roast) reviews brief/plan pre-spawn; grill-me interview
  upstream for new captain-initiated work. Council then runs at both ends.
- **P3 — loop-engineering conformance:** `LOOP.md`, `loop-budget.md`,
  `loop-run-log.md`, `loop-constraints.md` in firstmate;
  `npx @cobusgreyling/loop-audit` wired into `gates/verify.sh`; honest L2 first
  (its `loopActivity` signal demands proven runs — same ethos as
  `first_observed_red`), L3 only with budget + run-log + human gates.
- **P4 — Graph unification + routing manifest:** council/runtime skills become
  stone-skills nodes with `## Related` edges; instantiate `routing.json`
  against claude-pm-system's existing `routing.schema.json` (reconciling its
  `async|sync|batch` vocabulary with `no-mistakes|direct-PR|local-only`);
  agent↔skill manifest gated by `check.mjs` (the tend-the-graph TARGET).
- **P5 — Agent teams for thinker panels:** `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`,
  named parallel reviewers only — **never parallel writers**.

## Credentials (already in place, ~/.env chmod 600)

- `FUGU_API_KEY` — valid; account needs prepaid credits before the Fugu hop
  goes live (chain runs codex-only until then).
- codex CLI v0.142.1 — subscription-authed, works today.
- `OPENAI_API_KEY_LENS` — valid secondary; primary `OPENAI_API_KEY` untouched
  (realtime voice sidecar depends on it).

## Non-goals

- No Anthropic API / Agent SDK for the voice path (jarvis-talk hard constraint
  stands; this spec touches firstmate, not talkd).
- No proxying Claude through another model — the foreign lens *reviews*, it
  never sits between the captain and Claude.
- No new repo; no migration of working spawn/watch/supervise machinery.
