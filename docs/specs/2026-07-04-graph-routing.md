# Graph Unification + Routing Manifest — Design Spec (Agent OS Phase 4)

Date: 2026-07-04
Status: approved
Parent: docs/specs/2026-07-01-agent-os-council.md (Phase 4 outline)
Prereq: Phases 1–3 shipped (firstmate ledger green:19).

## Problem

The operating model is split-brain: the discipline graph (stone-skills) has no
node for the council the OS now enforces, agent↔skill bindings are prose-only
(the tend-the-graph TARGET), and claude-pm-system's routing schema is
aspirational scaffolding — no `routing.json` instance exists and its
`delivery_mode` vocabulary (`async|sync|batch`) never matched firstmate's real
modes (`no-mistakes|direct-PR|local-only`).

## The change (two repos, each verified by its OWN native gate)

### stone-skills (~/stone-skills — gate: `node bin/check.mjs` + `npm test`)

1. **New leaf `skills/orchestration/council/SKILL.md`** — the two-ended
   council doctrine: roles (coordinator=firstmate, thinkers=read-only
   specialist panel, worker=crewmate sole writer, verifier=Quarterdeck),
   Wardroom at intake / Quarterdeck at delivery, fail-closed stop conditions,
   bounded retries. `## Related`: decide-or-delegate,
   gate-driven-development, parallel-orchestration, fleet-comms,
   context-discipline.
2. **Related-edge additions** (additive lines only — these are LIVE always
   skills): decide-or-delegate, gate-driven-development,
   parallel-orchestration each gain `- council`.
3. **`agents.json` manifest** (repo root) — the tend-the-graph TARGET: binds
   each specialist agent name to its definition path (relative to $HOME) and
   the skills that dispatch to it. Roster: eng-architecture,
   eng-code-reviewer, eng-debugger, eng-evaluator, eng-gate-verifier,
   eng-researcher, eng-security (~/.claude/agents/specialists/),
   loop-verifier (~/firstmate/.claude/agents/).
4. **check.mjs extension** — two new finding codes, observed FAIL before the
   manifest exists (red-first in this repo's idiom):
   - `agent-missing`: a manifest agent whose definition file does not exist.
   - `agent-unbound`: an `eng-*` or `loop-verifier` name mentioned in any
     SKILL.md body that is absent from the manifest.
   Plus unit tests in tests/skills.test.mjs and a regenerated INDEX.md.

### claude-pm-system (~/claude-pm-system — gate: `node bin/validate-routing.mjs` + `npm test`)

5. **Vocabulary reconciliation**: `schemas/routing.schema.json` and
   `bin/validate-routing.mjs` replace `async|sync|batch` with the real
   `no-mistakes|direct-PR|local-only` (the scaffolding was aspirational; the
   code adopts reality, not the reverse).
6. **`routing.json` instance** (repo root) — the real topology from
   firstmate's registries: 7 projects with their live modes; secondmates
   `main` (the primary firstmate home; owns every project not routed to a
   domain secondmate), `cellarsky-sm` (cellarandsky), `hermes-jarvis-sm`
   (hermes-jarvis); specialists = the 8 manifest agents with their tool
   allowlists (read-only rosters; eng-researcher adds WebFetch/WebSearch).
7. **`bin/check-routing-sync.mjs <routing.json> <projects.md>`** — thin drift
   check: every `- name [mode]` line in firstmate's data/projects.md must
   appear in routing.json with the same mode (and vice versa for routed
   projects). data/*.md stays the operational source of truth; routing.json
   is the formal graph.

## Deliberate decisions

- **No cross-repo frozen-gate ledger.** Each repo's native check is its gate;
  the firstmate ledger does not reach into sibling repos. This spec records
  the honesty boundary.
- routing.json is hand-authored + drift-checked, not generated — parsing the
  prose-heavy secondmates.md is brittle; the sync checker covers the part
  that drifts (projects/modes).
- Council skill is a **leaf** (loaded on demand); the always-tier
  decide-or-delegate keeps carrying the dispatch tripwire and now points at
  council for the full doctrine.

## Non-goals

Generating routing.json; binding non-eng agents (brand-designer etc. — not
part of the dev council); P5 thinker-teams; migrating external runtime skills
(orchestrator/model-chat/team-24-7) into stone-skills — the council leaf
references them as external tools instead.
