#!/usr/bin/env bash
# Wardroom: the council-at-intake stage between a filled brief and the spawn.
# Spec: docs/specs/2026-07-03-wardroom-intake.md.
#
# A ship brief may not spawn until the intake council has roasted it:
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
# Synthesis (fail closed): any thinker escalate OR missing PANEL line ->
# escalate, never proceed; any revise -> revise; both proceed -> proceed.
#
# Seams: FM_INTAKE_CMD  thinker command; prompt as $1, cwd=<project-dir>, stdout
#                       must end with "PANEL: proceed|revise|escalate - reason"
#                       (default: claude -p --permission-mode bypassPermissions)
#        FM_LENS_CMD    lens command (payload on stdin; see fm-lens-lib.sh)
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

MAXR=${FM_INTAKE_MAX_REVISES:-2}

# Already at the revise cap? Straight to the captain, no more panel spins.
if [ "$(fm_intake_revise_count "$STATE" "$ID")" -ge "$MAXR" ]; then
  fm_intake_append "$STATE" "$ID" escalate "revise cap reached ($MAXR revises); captain decision required"
  echo "escalate: task $ID at revise cap ($MAXR revises)" >&2
  exit 3
fi

# --- 1. foreign deep lens over the brief ---------------------------------------
LENS_REVIEW="$DATA/$ID/intake-lens-review.md"
LENS_PROMPT="You are a hostile planning reviewer. Roast this task brief before a worker is spawned on it: wrong seam, unprovable definition of done, missing constraints, hidden scope, YAGNI. Be specific. End with the changes that most deserve a revise, or say no blocking findings."
LENS=$(fm_lens_run "$BRIEF" "$LENS_REVIEW" "$LENS_PROMPT" fugu-ultra "$PROJ" "intake $ID")
fm_intake_append "$STATE" "$ID" panel "lens $LENS $(head -c 120 "$LENS_REVIEW" | tr '\n' ' ')"

# --- 2. thinker panel (sequential; parallel panels arrive with agent teams, P5) --
INTAKE_CMD=${FM_INTAKE_CMD:-claude -p --permission-mode bypassPermissions}

run_thinker() {  # <name> <charge> -> writes data/<id>/intake-<name>.md; prints last PANEL line
  local name=$1 charge=$2 out prompt
  out="$DATA/$ID/intake-$name.md"
  prompt=$(cat <<EOF
You are a Wardroom thinker on the intake council: the $name lens. A crewmate is
about to be spawned with the brief below. Roast the PLAN, not the author.
Your charge: $charge
Read the project around you for context. Be specific and concise.

# The brief
$(cat "$BRIEF")

# Foreign deep-lens review (lens=$LENS)
$(cat "$LENS_REVIEW")

Your reply MUST end with exactly one line, nothing after it:
PANEL: proceed - <one-line reason>
PANEL: revise - <the concrete change the brief needs>
PANEL: escalate - <why the captain must decide>
EOF
)
  : > "$out"
  if (cd "$PROJ" && sh -c "$INTAKE_CMD \"\$1\"" _ "$prompt") > "$out" 2>&1; then
    grep -E '^PANEL: (proceed|revise|escalate)' "$out" | tail -1 || true
  fi
}

L_ARCH=$(run_thinker architecture "Is this the right seam in the codebase? Is the definition of done machine-provable? Are the proposed gates the right gates?")
L_RISK=$(run_thinker risk "What is missing from the brief? What will bite the worker halfway through? What is speculative scope that should be cut?")

# --- 3. synthesize + decide (fail closed) ----------------------------------------
decision=proceed
reasons=""
for line in "$L_ARCH" "$L_RISK"; do
  case "$line" in
    PANEL:\ proceed*) : ;;
    PANEL:\ revise*)
      [ "$decision" = escalate ] || decision=revise
      reasons="$reasons${reasons:+; }${line#PANEL: }" ;;
    PANEL:\ escalate*)
      decision=escalate
      reasons="$reasons${reasons:+; }${line#PANEL: }" ;;
    *)
      decision=escalate
      reasons="$reasons${reasons:+; }thinker infrastructure failure (no PANEL line) - fail closed" ;;
  esac
done

REVIEW="$DATA/$ID/intake-review.md"
{
  echo "# Wardroom intake review: $ID"
  echo
  echo "Decision: $decision${reasons:+ - $reasons}"
  echo "Foreign lens: $LENS (intake-lens-review.md)"
  echo
  echo "## architecture thinker"
  cat "$DATA/$ID/intake-architecture.md" 2>/dev/null || echo "(missing)"
  echo
  echo "## risk thinker"
  cat "$DATA/$ID/intake-risk.md" 2>/dev/null || echo "(missing)"
} > "$REVIEW"

case "$decision" in
  proceed)
    fm_intake_append "$STATE" "$ID" proceed "panel proceed (lens=$LENS)"
    echo "proceed: task $ID vetted by the wardroom (lens=$LENS)"
    exit 0
    ;;
  revise)
    n=$(( $(fm_intake_revise_count "$STATE" "$ID") + 1 ))
    fm_intake_append "$STATE" "$ID" revise "(revise $n of $MAXR) ${reasons:-panel revise}"
    if [ "$n" -ge "$MAXR" ]; then
      fm_intake_append "$STATE" "$ID" escalate "revise cap reached ($n revises); captain decision required"
      echo "escalate: task $ID hit the revise cap ($n of $MAXR); see $REVIEW" >&2
      exit 3
    fi
    echo "revise: task $ID (revise $n of $MAXR) - amend the brief per $REVIEW and re-run fm-intake.sh" >&2
    exit 2
    ;;
  escalate)
    fm_intake_append "$STATE" "$ID" escalate "${reasons:-panel escalate}"
    echo "escalate: task $ID needs the captain (see $REVIEW)" >&2
    exit 3
    ;;
esac
