# The Wardroom: Council at Intake — Design Spec (Agent OS Phase 2)

Date: 2026-07-03
Status: approved
Parent: docs/specs/2026-07-01-agent-os-council.md (Phase 2 outline)
Prereq: Phase 1 (the Quarterdeck) shipped — gates q1–q7 green.

## Problem

Briefs go straight to spawn. Nothing roasts the *plan* before a crewmate burns
hours building the wrong thing. The council runs at delivery (Quarterdeck) but
not at intake — the article's "run the council at the start and the finish" is
half-implemented.

## The change

**A ship brief may not spawn until the intake council has proceeded.**

### Flow

1. After firstmate fills `{TASK}` in a ship brief, it runs
   **`bin/fm-intake.sh <id> <project-dir>`** before spawning.
2. fm-intake runs the **foreign deep lens** over the brief — shared chain
   `FM_LENS_CMD > Fugu (fugu-ultra) > codex > none`, loud degrade — then a
   **thinker panel**: two read-only lenses run sequentially (architecture: right
   seam / provable DoD / right gates; risk: what is missing / what bites / what
   is YAGNI), each ending in `PANEL: proceed|revise|escalate - reason`.
3. Synthesis (fail closed): any escalate or missing PANEL line → escalate;
   any revise → revise; both proceed → proceed. Written to
   `data/<id>/intake-review.md`; the decision appends to the new append-only
   **`state/<id>.intake`** (`proceed:` / `revise:` / `escalate:` decisions,
   `panel:` evidence — a separate channel; the verdict grammar stays as q1 pins it).
4. **Hard gate:** `fm-spawn.sh` refuses a **ship** spawn without a trailing
   `proceed:` — inserted AFTER the existing missing-brief fail-fast, so all
   existing missing-brief tests keep their error. Scouts/secondmates exempt.
   `FM_INTAKE_OVERRIDE=1` = loud captain bypass.
5. **revise:** firstmate amends the brief per the findings and re-runs intake;
   `FM_INTAKE_MAX_REVISES` (default 2) revises → escalate to the captain.
6. **Shared lens extraction:** the Fugu/codex/none chain moves out of
   fm-verify.sh into **`bin/fm-lens-lib.sh`**, consumed by both council ends;
   existing gates q4/q6 guard the refactor.
7. grill-me upstream interview for captain-initiated work: AGENTS.md prose only.

### Deliberate decisions

- **fm-intake-lib.sh mirrors fm-verdict-lib.sh rather than sharing a generic
  channel core.** Two ~50-line bash libs with different grammars and banners;
  a parameterized abstraction costs more than the duplication. Third channel =
  build the abstraction.
- Thinkers run **sequentially** (parallel panels arrive with agent teams, P5).
- Panel *quality* is not machine-checkable; the gates prove intake **happened,
  in order, fail-closed** — same honesty boundary as the Quarterdeck.
- Intake runs pre-spawn, so no `state/<id>.meta` exists yet — fm-intake takes
  the project dir as argv, not from meta.

### Seams

`FM_INTAKE_CMD` (thinker; prompt as $1, cwd=project dir, stdout ends with a
PANEL line; default `claude -p --permission-mode bypassPermissions`),
`FM_LENS_CMD` (shared lens chain), `FM_INTAKE_MAX_REVISES` (2),
`FM_INTAKE_OVERRIDE=1` (loud bypass). Exit: 0 proceed, 2 revise, 3 escalate,
1 usage error.

### Gates (red-first + LEDGER_MUTATE=1 mutation, as q1–q7)

- `gate-i1-intake-grammar` — intake channel grammar; last-decision ignores
  `panel:` lines and returns 1 on no-file/no-decision (q1 lessons baked in).
- `gate-i2-spawn-refuses-unvetted` — fm-spawn refuses ship w/o trailing
  proceed (WARDROOM banner); scout exempt; override loud; sits after the
  brief check (no side effects, no stubs needed).
- `gate-i3-panel-roundtrip` — stubbed panel: both-proceed → `proceed:` exit 0
  + synthesis file; one-revise → `revise: (revise 1 of 2)` exit 2.
- `gate-i4-revise-cap-fail-closed` — at-cap escalates without running the
  panel; a thinker with no PANEL line escalates, never proceeds.
- `gate-i5-intake-lens-degrade` — env -i, no codex → `panel: lens none` line +
  loud warning, intake still completes (q4/q6 keep guarding fm-verify parity).

### Non-goals

Panel quality judgment; parallel thinkers (P5); Fugu credits (chain degrades
until topped up); re-verify-at-PR-time (separate open follow-up from P1).

Known boundary (found in W5-W7 review): fm-promote.sh flips a scout to
ship in place without fm-spawn, bypassing the intake gate - the scout report
stands in for the vetted plan. Structural intake for promotions = queued
follow-up.
