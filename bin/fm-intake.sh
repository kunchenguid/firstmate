#!/usr/bin/env bash
# Wardroom: the council-at-intake stage between a filled brief and the spawn.
# Spec: docs/specs/2026-07-03-wardroom-intake.md.
#
# A ship brief may not spawn until the intake council has vetted it:
#   1. foreign deep lens over the brief (shared chain, model fugu-ultra)
#                                          -> data/<id>/intake-lens-review.md
#   2. thinker panel: two read-only lenses run sequentially (architecture, risk)
#                                          -> data/<id>/intake-architecture.md,
#                                             data/<id>/intake-risk.md
#   3. fail-closed synthesis               -> data/<id>/intake-review.md and a
#      decision line in state/<id>.intake (fm-intake-lib grammar); fm-spawn
#      refuses a ship task without a trailing proceed.
#   4. on revise: firstmate amends the brief per the findings and re-runs;
#      after FM_INTAKE_MAX_REVISES (default 2) revises, escalates.
#
# The severity bar: only a BLOCKING defect may hold a spawn - the crewmate would
# FAIL, DO HARM, or BUILD THE WRONG THING. Everything else is a NOTE and rides
# along with the proceed (verdict `proceed-with-notes`). Unanimity on blockers
# is kept: one lens seeing real harm still stops the spawn.
#
# Synthesis (fail closed): any thinker escalate OR missing/malformed PANEL line
# -> escalate, never proceed; any revise -> revise; all non-blocking -> proceed.
#
# Seams: FM_INTAKE_CMD  thinker command; prompt as $1, cwd=<project-dir>, stdout
#                       must end with
#                       "PANEL: proceed|proceed-with-notes|revise|escalate - reason"
#                       (default: claude -p --permission-mode bypassPermissions)
#        FM_LENS_CMD    lens command (payload on stdin; see fm-lens-lib.sh)
#        FM_INTAKE_HEALTH_MIN  decisions before a 0% proceed rate is a fault (10)
#        FM_INTAKE_HEALTH_WINDOW  how many of the most recent decisions that
#                       rate is read over (20); a rolling window, so the first
#                       proceed cannot disarm the detector for good
# Exit: 0 proceed, 2 revise, 3 escalate, 1 usage/operational error.
# Usage: fm-intake.sh <task-id> <project-dir>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-intake-lib.sh
. "$SCRIPT_DIR/fm-intake-lib.sh"
# shellcheck source=bin/fm-lens-lib.sh
. "$SCRIPT_DIR/fm-lens-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

ID=${1:?usage: fm-intake.sh <task-id> <project-dir>}
PROJ=${2:?usage: fm-intake.sh <task-id> <project-dir>}
BRIEF="$DATA/$ID/brief.md"
[ -f "$BRIEF" ] || { echo "error: no brief for task $ID at $BRIEF" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project dir $PROJ missing" >&2; exit 1; }
if grep -q '{TASK}' "$BRIEF"; then
  echo "error: brief for $ID still carries the {TASK} placeholder - fill it before intake" >&2
  exit 1
fi

# Every decision this council records is followed by an honest read of its own
# record. A council with a structurally zero proceed rate is not strict, it is
# broken - and it went 96 verdicts before anyone noticed, because nothing said so.
finish() {  # <exit-code>
  local health
  if ! health=$(fm_intake_health "$STATE"); then
    {
      echo "warning: $health"
      echo "warning: the intake council has never once proceeded over that sample -"
      echo "         suspect the severity bar, not the briefs. See the bar in this"
      echo "         script and docs/specs/2026-07-03-wardroom-intake.md."
    } >&2
  fi
  exit "$1"
}

MAXR=${FM_INTAKE_MAX_REVISES:-2}

# Already at the revise cap? Straight to the captain, no more panel spins.
if [ "$(fm_intake_revise_count "$STATE" "$ID")" -ge "$MAXR" ]; then
  fm_intake_append "$STATE" "$ID" escalate "revise cap reached ($MAXR revises); captain decision required"
  echo "escalate: task $ID at revise cap ($MAXR revises)" >&2
  finish 3
fi

# --- 1. foreign deep lens over the brief ---------------------------------------
LENS_REVIEW="$DATA/$ID/intake-lens-review.md"
LENS_PROMPT="You are a deep planning reviewer. Read this task brief hard before a worker is spawned on it: wrong seam, unprovable definition of done, missing constraints, hidden scope, YAGNI. Be specific, and cite the file, line, or spec section that proves each point. Separate your findings into two lists: BLOCKING - if the worker ran this brief as written it would be unable to do or prove the work, would take a destructive or shared-state action the brief has not bounded, or would build the wrong thing; and NOTES - everything else worth saying, which is real but does not justify holding the spawn. A brief does not have to be excellent to proceed; it has to be safe, provable, and aimed at the right target. End with the blocking findings, or say no blocking findings."
LENS=$(fm_lens_run "$BRIEF" "$LENS_REVIEW" "$LENS_PROMPT" fugu-ultra "$PROJ" "intake $ID")
fm_intake_append "$STATE" "$ID" panel "lens $LENS $(head -c 120 "$LENS_REVIEW" | tr '\n' ' ')"

# --- 2. thinker panel (sequential; parallel panels arrive with agent teams, P5) --
INTAKE_CMD=${FM_INTAKE_CMD:-claude -p --permission-mode bypassPermissions}

# The prompt below lists all four PANEL lines as a template, so a thinker that
# echoes the menu, restates an option, or adds a footnote emits more than one
# line starting "PANEL: ". Two of those lines are noise and must not decide the
# verdict: a template echo (which parses as a valid verdict the thinker never
# reached - the escalate template would stop every spawn on its own) and a
# non-verdict footnote (which would fail closed into a spurious escalate). Both
# are dropped, and among what remains the LAST line wins, because the prompt
# tells the thinker its reply must END with exactly one verdict line. No valid
# line at all still yields nothing, which the caller maps to escalate.
pick_panel() {  # <thinker-output-file> -> the last real PANEL verdict line
  local line best=""
  while IFS= read -r line; do
    [ "$(fm_intake_verdict "$line")" != invalid ] || continue
    if fm_intake_is_placeholder "$line"; then continue; fi
    best=$line
  done < <(grep '^PANEL: ' "$1" || true)
  [ -n "$best" ] && printf '%s\n' "$best"
  return 0
}

run_thinker() {  # <name> <charge> -> writes data/<id>/intake-<name>.md; prints its PANEL verdict line
  local name=$1 charge=$2 out prompt
  out="$DATA/$ID/intake-$name.md"
  prompt=$(cat <<EOF
You are a Wardroom thinker on the intake council: the $name lens. A crewmate is
about to be spawned with the brief below. Review the PLAN, not the author.
Your charge: $charge
Read the project around you for context. Be specific and concise.

# The bar
You are not scoring this brief. You are answering one question: is it safe to
spawn a worker on it as written? A brief does not have to be excellent to
proceed. It has to be safe, provable, and aimed at the right target.

A finding is BLOCKING only if, running this brief as written, the crewmate would:
  - FAIL - be unable to carry out an instruction, or unable to prove it is done:
    an unprovable definition of done, a command that cannot run here, a file it
    cannot see, a dependency that does not exist;
  - DO HARM - take a destructive, irreversible, or shared-state action whose
    blast radius the brief has not bounded: touching live or production state,
    an over-broad "safe set", a test that leases or mutates a real resource;
  - BUILD THE WRONG THING - contradict a tracked spec or an established
    contract, solve a different problem than the one asked, or generalise a rule
    so that it misfires on the ordinary case.

Everything else is a NOTE: a cleaner seam, a better name, an extra test, scope
you would have trimmed, a doc step, a count or a wording to fix, a risk worth
mentioning. Notes are valuable and you should still write them: they are recorded
on the proceed line in state/<id>.intake and in data/<id>/intake-review.md, where
firstmate reads them and folds what is worth folding into the brief before the
crewmate is spawned. What a note does not do is veto the spawn. Preference is not
a defect.

Two tests before you call something blocking:
  - Can you state it as premise then consequence - "X is true, SO the worker
    cannot Y"? A bare instruction to drop, cut, rename, or tidy something, with
    no consequence, is a note.
  - Can you cite the artifact that proves it - a path, a line, a spec section, a
    command that fails? If not, it is a note.
If you have one blocking finding and six notes, the verdict is revise and you
name the ONE blocker; the six go in your prose above the verdict line, not in it.
If you have no blocking finding, the verdict is proceed-with-notes, however much
you would have written differently.

# The brief
$(cat "$BRIEF")

# Foreign deep-lens review (lens=$LENS)
$(cat "$LENS_REVIEW")

Your reply MUST end with exactly one line, nothing after it:
PANEL: proceed - <one-line reason>
PANEL: proceed-with-notes - <the non-blocking findings, in one line>
PANEL: revise - <the single BLOCKING defect, and the concrete change it needs>
PANEL: escalate - <why the captain, not the crewmate, must decide>
EOF
)
  : > "$out"
  if (cd "$PROJ" && sh -c "$INTAKE_CMD \"\$1\"" _ "$prompt") > "$out" 2>&1; then
    pick_panel "$out"
  fi
}

L_ARCH=$(run_thinker architecture "Is this the right seam in the codebase? Is the definition of done machine-provable? Are the proposed gates the right gates? A seam you would have drawn differently is a note; a seam that cannot carry the change is a blocker.")
L_RISK=$(run_thinker risk "What is missing that the worker cannot proceed without? What will bite it halfway through? What could it break outside its own worktree? Speculative scope is a note unless building it would do harm.")

# --- 3. synthesize + decide (fail closed) ----------------------------------------
#
# Blocking verdicts (revise, escalate) collect into $reasons and decide the
# panel. Non-blocking findings collect into $notes and ride along with the
# proceed; they are recorded, not obeyed. Unanimity is unchanged - one revise
# still blocks - because the fix here is WHAT counts as a blocker, not who has
# to agree. An unrecognised verdict is an infrastructure failure, never a pass.
decision=proceed
reasons=""
notes=""
# Each finding is attributed to the lens that raised it: both lists join on
# "; ", so without a name a reader cannot tell two lenses apart from one lens
# making a two-part point. Lens names contain no "=", so the split is exact.
for pair in "architecture=$L_ARCH" "risk=$L_RISK"; do
  lens_name=${pair%%=*}
  line=${pair#*=}
  case "$(fm_intake_verdict "$line")" in
    proceed) : ;;
    proceed-with-notes)
      note=${line#PANEL: }
      note=${note#proceed-with-notes}
      note=${note# - }
      # A verdict word with no reason after it is still non-blocking; it just
      # has nothing to add. Appending it would leave a dangling separator.
      [ -n "$note" ] && notes="$notes${notes:+; }$lens_name: $note"
      : ;;
    revise)
      [ "$decision" = escalate ] || decision=revise
      reasons="$reasons${reasons:+; }$lens_name: ${line#PANEL: }" ;;
    escalate)
      decision=escalate
      reasons="$reasons${reasons:+; }$lens_name: ${line#PANEL: }" ;;
    *)
      decision=escalate
      reasons="$reasons${reasons:+; }$lens_name: thinker infrastructure failure (no valid PANEL line) - fail closed" ;;
  esac
done

REVIEW="$DATA/$ID/intake-review.md"
{
  echo "# Wardroom intake review: $ID"
  echo
  echo "Decision: $decision${reasons:+ - $reasons}"
  echo "Foreign lens: $LENS (intake-lens-review.md)"
  echo
  if [ -n "$notes" ]; then
    echo "## Notes on the brief (non-blocking)"
    echo
    echo "The panel raised these and did not consider them worth holding the"
    echo "spawn for. Fold in what is worth folding in; none of it is a veto."
    echo
    echo "- $notes"
    echo
  fi
  echo "## architecture thinker"
  cat "$DATA/$ID/intake-architecture.md" 2>/dev/null || echo "(missing)"
  echo
  echo "## risk thinker"
  cat "$DATA/$ID/intake-risk.md" 2>/dev/null || echo "(missing)"
} > "$REVIEW"

case "$decision" in
  proceed)
    fm_intake_append "$STATE" "$ID" proceed "panel proceed (lens=$LENS)${notes:+ - notes: $notes}"
    echo "proceed: task $ID vetted by the wardroom (lens=$LENS)"
    [ -n "$notes" ] && echo "notes on the brief (non-blocking, see $REVIEW): $notes"
    finish 0
    ;;
  revise)
    n=$(( $(fm_intake_revise_count "$STATE" "$ID") + 1 ))
    fm_intake_append "$STATE" "$ID" revise "(revise $n of $MAXR) ${reasons:-panel revise}"
    if [ "$n" -ge "$MAXR" ]; then
      fm_intake_append "$STATE" "$ID" escalate "revise cap reached ($n revises); captain decision required"
      echo "escalate: task $ID hit the revise cap ($n of $MAXR); see $REVIEW" >&2
      finish 3
    fi
    echo "revise: task $ID (revise $n of $MAXR) - amend the brief per $REVIEW and re-run fm-intake.sh" >&2
    finish 2
    ;;
  escalate)
    fm_intake_append "$STATE" "$ID" escalate "${reasons:-panel escalate}"
    echo "escalate: task $ID needs the captain (see $REVIEW)" >&2
    finish 3
    ;;
esac
