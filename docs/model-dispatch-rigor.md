# Model dispatch rigor

Different harness/model combinations hold judgment and long-context discipline
to different degrees. This doc codifies how to compensate: push what's
mechanically checkable into script gates that run the same way regardless of
model, and scale brief narrowness to match what judgment remains uncovered.
(Captain, 2026-10-04.)

## The lever, not a menu

There is exactly one lever here, applied at two different strengths:

**Narrow the brief to cut how much judgment the dispatched model needs to
exercise.** A brief that pre-resolves the ambiguous calls itself ("do X, not
the adjacent Y you might be tempted to also fix") produces the same outcome
from a weaker model that a looser brief only produces from a strong one. The
cost moves to whoever writes the brief — more upfront investigation for the
supervisor, less judgment risk from the worker. This is a real tradeoff, not
a free win: spend it where the task's ambiguity is actually high, not on
every brief by default.

Everything mechanically verifiable should already be a script gate
regardless of which model ran the work — this is not new policy, it's what
`fm-pr-merge.sh` (merge-on-green only) and `no-mistakes`'s own gates already
do. A gate that only fires for some harnesses is a gap to close, not a
tiering decision — route it to the pipeline, not to a doc.

## Tiering by model, not by harness

Harness is not a reliability signal. Model is. The same harness can carry a
strong pinned model (dispatch narrows little) or a weekly-rotating free model
(dispatch narrows a lot). Two tiers:

- **Known-strong** (a pinned model with an established track record — e.g. the
  models `config/crew-harness`/`config/secondmate-harness` name explicitly):
  ordinary brief per `AGENTS.md` section 11. No extra narrowing.
- **Rotating/unvetted** (anything selected fresh each cycle with no track
  record yet — today this means opencode's free-tier models): narrow the brief
  further than you would for a known-strong model doing the same task, and
  prefer it for mechanically-checkable work (a scoped fix, a test suite run, a
  read-only scout) over open-ended design judgment. This is the same lever,
  just pulled harder because there's no track record to offset it.

## Rotating free-model fitness: read before you narrow

For opencode's free tier specifically, don't guess which model is current or
how much to narrow for it — the weekly scanner already answers this.
`AutomationSync/opencode_free_model_scanner.py` (IMAC, weekly cron) writes
`AutomationSync/knowledge/opencode-free-models.json`: every free model,
classified into `coding_large` / `deep_debug` / `scout_tool`, each carrying
`is_preview`, `is_expiring_soon`, and `early_termination_detected`.

Before dispatching an opencode free-model candidate:

1. Read that knowledge file. Match the candidate's domain classification to
   the task shape — don't hand `scout_tool` a coding_large-sized change.
2. `early_termination_detected: true` or `is_expiring_soon: true` on the
   candidate demotes it: narrow the brief further than the rotating-tier
   default, or prefer the domain's `recommended_defaults` entry instead.
3. If `scanned_at` is older than ~10 days (past the weekly cadence plus
   slack), treat the data as stale — fall back to the most conservative
   narrowing for that domain rather than trusting a classification that may
   no longer hold. A stale scan is a reason to narrow more, never a reason to
   skip the check.

This is a reference lookup before dispatch, not a standing daemon — it
doesn't change what `quota-array-dispatch` already owns (economics,
eligibility, `spendPriority`) and isn't wired into it. If this needs to
become an automatic gate inside that skill's candidate ranking rather than a
manual pre-dispatch check, that's a separate, explicitly-scoped follow-up —
don't fold it into that skill as a side effect of reading this doc.
