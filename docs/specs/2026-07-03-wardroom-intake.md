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
   *(Superseded by the 2026-08-29 amendment below: a fourth verdict,
   `proceed-with-notes`, and a defined severity bar for `revise`.)*
3. Synthesis (fail closed): any escalate or missing PANEL line → escalate;
   any revise → revise; both proceed → proceed.
   *(Amended 2026-08-29: a malformed, hedged, or template-echoed PANEL line
   escalates as well, and "both proceed" widens to "both non-blocking" — either
   `proceed` or `proceed-with-notes`, whose findings ride along on the
   decision.)*
   Written to
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

## Amendment, 2026-08-29: the severity bar (gates t1)

### What went wrong

The council shipped able to block and unable to pass. Across its whole history:
**0 proceeds, 59 revises, 37 escalations** — every brief that ever entered
intake left by captain escalation or a bypass. On 2026-08-28/29 six briefs
jammed at once; raising `FM_INTAKE_MAX_REVISES` to 3 and then 4 on one of them
bought three more rounds of findings and still no proceed. The cap was never the
constraint. The missing **exit condition** was.

Three causes compounded, all in `bin/fm-intake.sh`:

1. **The reviewers were told to attack.** The lens was "a hostile planning
   reviewer. Roast this task brief"; both thinkers were told to "Roast the PLAN".
   A reviewer asked to roast will always produce findings. That is its job.
2. **No severity threshold.** The thinkers got `proceed | revise | escalate`
   with no definition of when a finding is severe enough to block, so any
   imperfection mapped to `revise`. The asymmetry was visible in the prompts: the
   lens was offered "or say no blocking findings"; the thinkers had no escape.
3. **Synthesis required unanimity** — correct, but combined with (1) and (2) it
   meant a single tidiness clause from either lens vetoed the spawn.

The corpus shows the mechanism precisely: `revise:` lines are **compound**, one
genuine blocker concatenated with four to eight nitpick clauses. One nitpick
spends a revise; two spend the cap. Reading the corpus, the two classes separate
by grammar, not topic. A blocker asserts **premise then consequence** and cites
the artifact that proves it — *"the worktree cannot see `.notfair/` at all, so
the backfill half is unrunnable"*, *"the spec forbids any boot-time refusal
string"*. A note is a **bare imperative** with no consequence and no citation —
*drop*, *cut*, *strip*, *rename*, *fix the count*, *name the new file*.

### The change

**A severity bar, stated in the charge, with a verdict word to carry what does
not meet it.** The thinker grammar gains a fourth verdict:

```
PANEL: proceed             - nothing to say
PANEL: proceed-with-notes  - real findings that do not block
PANEL: revise              - a BLOCKING defect
PANEL: escalate            - only the captain may decide
```

Blocking is now defined, not left to taste. A finding blocks only if, running
the brief as written, the crewmate would **FAIL** (cannot carry out an
instruction, or cannot prove it is done), **DO HARM** (a destructive,
irreversible or shared-state action whose blast radius the brief has not
bounded), or **BUILD THE WRONG THING** (contradicts a tracked spec or contract,
solves a different problem, or generalises a rule that misfires on the ordinary
case). The charge carries the two corpus-derived tests: state it as premise then
consequence, and cite the artifact that proves it — otherwise it is a note. And
it says explicitly that one blocker plus six notes is *one* blocker: the six go
in the prose, never in the verdict line.

The five verdicts that were correctly blocking, and which the bar is calibrated
to keep blocking, are the classes above: a `sweep --apply` safe-set that would
close panes holding live work (HARM); a design contradicting
`2026-08-27-n-concurrent-firstmates.md` §4 (WRONG THING); a test command that
leases from the live treehouse pool (HARM); a classifier that would escalate on
every non-firstmate project (WRONG THING — a rule misfiring on the ordinary
case); a brief asking a worker to move a gitignored file it cannot see (FAIL).

**Notes are recorded, they do not veto.** Non-blocking findings are collected
into the `proceed:` line and into a *Notes on the brief (non-blocking)* section
of `data/<id>/intake-review.md`, so the council's findings are not lost just
because they did not block. Delivery is firstmate's: nothing downstream of
`fm-intake.sh` reads them, so firstmate folds what is worth folding into the
brief before spawning. Wiring them into the launch prompt is queued work.

**Unanimity is unchanged, deliberately.** A single `revise` from either lens
still blocks; a single `escalate` still escalates. Relaxing synthesis to majority
would have been the wrong fix — one reviewer spotting real harm *should* stop the
spawn. The defect was that everything counted as a blocker, not that unanimity
was wrong.

**Fail-closed is unchanged and slightly tightened.** Verdict parsing moves into
`fm_intake_verdict` in `fm-intake-lib.sh`, which recognises exactly the four
words and returns `invalid` for anything else; synthesis maps `invalid` to
escalate. The previous prefix match would have accepted `PANEL: proceeds` as a
proceed. The verdict word must be the whole word: only an empty tail or the
` - reason` the grammar asks for may follow it, so a thinker that could not
choose (`PANEL: proceed/revise - unsure`), got the grammar wrong
(`PANEL: proceed_with_notes`) or is guessing (`PANEL: proceed?`) escalates rather
than being truncated into a clean proceed. A trailing space or CR is transport
noise and is stripped, not treated as a malformed verdict. A missing PANEL line,
a dead thinker, and an unreadable review all still escalate. Because the prompt
itself lists all four `PANEL:` lines as a template, a thinker may emit several of
them, and each template line parses as a valid verdict it never reached — so
selection first discards the noise. A line whose reason is a placeholder token
rather than prose (`PANEL: escalate - <why the captain, not the crewmate, must
decide>`) is a template echo, matched by shape via `fm_intake_is_placeholder`, and
a `PANEL: ` line that parses to no valid verdict is a footnote; neither may
decide. Among what survives, the *last* line wins, because the prompt requires
the reply to end with exactly one verdict line. A trailing template echo can then
neither downgrade a real blocker into a proceed nor turn a sound verdict into a
spurious escalate, and no valid verdict at all remains the fail-closed escalate.
`FM_INTAKE_OVERRIDE` semantics and the cap values are untouched.

### The regression that was missing

Nothing watched the one number that would have said the council was broken, and
so nothing did, for 96 verdicts. **A gate that can never pass is
indistinguishable from a gate that is broken.** `fm_intake_health` reads the
most recent decisions in the `state/*.intake` corpus and returns non-zero when
the proceed rate is *structurally zero*: enough decisions to be meaningful
(`FM_INTAKE_HEALTH_MIN`, default 10) and not one proceed among them.
`fm-intake.sh` calls it on every decision it records — including the at-cap
escalate, which was 30 of the 37 escalations — and prints the rate plus a plain
warning that the bar, not the briefs, is the likely fault. Below the sample floor
it stays quiet; a detector that cried wolf on the first three decisions would be
muted.

**The judgement is a rolling window, and that is load-bearing.** Read
cumulatively this detector would be a one-shot: nothing prunes `.intake` files,
so the first proceed ever recorded would disarm it for the life of the corpus,
and the prompt-level regression it exists to catch could only ever be caught
once — historically, never again. It therefore judges the last
`FM_INTAKE_HEALTH_WINDOW` decisions (default 20), ordered by `.intake` file
modification time and then by append order within a file. If a later prompt
change drives the proceed rate back to zero, it fires again.

Panel *quality* remains outside the gates — the same honesty boundary the
original spec draws. The proceed rate is the instrument that catches a
prompt-level regression that no unit test can see.

### Seams added

`FM_INTAKE_HEALTH_MIN` (10) — decisions required before a 0% proceed rate counts
as a structural fault.

`FM_INTAKE_HEALTH_WINDOW` (20) — how many of the most recent decisions that rate
is read over, so the detector stays live instead of disarming on the first
proceed.

Both bounds are validated before use: an empty, non-numeric, zero, or negative
value falls back to its default rather than being honoured. A bound that
switches the detector off is the silently-unwatched watchdog the detector
exists to prevent, so neither seam may be the thing that mutes it.

### Gates (t1)

- `gate-t1-severity-proceeds` — stubbed thinkers drive synthesis directly, so
  the gate tests the logic and not a model's mood: two non-blocking findings →
  **proceed** with the notes carried (the case that had never happened); one
  genuine blocker from either lens → **still revise**; any escalate → **still
  escalate**; a missing or malformed PANEL line → **still escalate**.
  Plus `fm_intake_verdict` directly: the four words and nothing else, with a
  hedged or garbled verdict (`proceed/revise`, `proceed?`, `proceed_with_notes`)
  invalid rather than truncated into a proceed; `fm_intake_is_placeholder`
  recognising every line of the prompt's own grammar template by shape and no
  real verdict; and, when a thinker emits several `PANEL: ` lines, the template
  echoes and non-verdict footnotes discarded and the LAST real verdict deciding
  — so a trailing echo can neither downgrade a revise into a proceed nor invent
  a blocker after a sound verdict, and output whose only `PANEL: ` lines are
  invalid or templates still escalates.
- `gate-t1-proceed-rate-nonzero` — the detector: a 12-decision zero-proceed
  corpus is flagged, one proceed clears it, a 3-decision corpus and an empty one
  stay quiet, the same 3-decision corpus is flagged with the floor at 3, a
  proceed older than the window does not disarm it, neither bound can mute the
  detector with an empty, non-numeric, zero, or negative value, and a live
  `fm-intake` run over a zero-proceed state dir emits the warning.

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
