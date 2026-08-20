#!/usr/bin/env bash
# fm-epic-dispatch-plan.sh - EMIT the ordered, copy-pasteable commands to move a
# signed epic from "branches cut" to "stories dispatched", so the operator runs a
# sequence instead of hand-deriving it (report G-dispatch/G-route). Its sibling
# bin/fm-epic-status.sh SHOWs readiness; this one hands you the commands.
#
# It PRINTS ONLY. It never cuts a branch, never spawns, never mutates anything -
# dispatch stays firstmate judgment (a story a human decides not to start yet is
# simply not run). The output is two ordered blocks:
#   1. fm-epic-branch.sh create <slug> <repo>   for every involved repo whose
#      epic/<slug> is not yet cut (a story cannot branch from an absent base).
#   2. for each currently DISPATCHABLE story (its deps merged, not itself done),
#      the fm-brief.sh + fm-spawn.sh pair, with the resolved PR base (the story's
#      pr_base) and the resolved delivery mode.
#
# Delivery mode resolution (G-mode): a story's optional `delivery:` frontmatter
# key wins when present (epflow-07); otherwise the project's REGISTERED posture
# (bin/fm-project-mode.sh --raw) is used, since that is the captain's standing
# posture (AGENTS.md section 7). A `no-mistakes-prod-only` posture is a per-task
# surface classification only firstmate can make, so the plan surfaces BOTH
# candidate modes for that story rather than guessing - it keeps the decision.
#
# Run WITH FM_HOME set to the home that owns the epic.
#
# Usage:
#   fm-epic-dispatch-plan.sh <epic-slug>
#   fm-epic-dispatch-plan.sh -h | --help
#
# Overrides (mechanical/test seams, same style as bin/fm-epic-status.sh):
#   FM_ROOT_OVERRIDE      firstmate code root (default: this script's ..).
#   FM_HOME               the home that owns the epic (default: FM_ROOT).
#   FM_DATA_OVERRIDE      data dir (default $FM_HOME/data); plans + backlog.
#   FM_EPIC_BRANCH_BIN    epic-branch verifier (default $FM_ROOT/bin/fm-epic-branch.sh).
#   FM_PROJECT_MODE_BIN   registered-mode accessor (default $FM_ROOT/bin/fm-project-mode.sh).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
EPIC_BRANCH_BIN="${FM_EPIC_BRANCH_BIN:-$FM_ROOT/bin/fm-epic-branch.sh}"
PROJECT_MODE_BIN="${FM_PROJECT_MODE_BIN:-$FM_ROOT/bin/fm-project-mode.sh}"
PLANS="$DATA/plans"
BACKLOG="$DATA/backlog.md"

# shellcheck source=bin/fm-epic-status-lib.sh
. "$FM_ROOT/bin/fm-epic-status-lib.sh"

die() { echo "error: $*" >&2; exit 1; }

usage() {  # <exit-code> (default 2); code 0 prints to stdout for --help
  local code=${1:-2} out=/dev/stderr
  [ "$code" -eq 0 ] && out=/dev/stdout
  cat > "$out" <<'EOF'
usage:
  fm-epic-dispatch-plan.sh <epic-slug>   print the ordered cut-branch + dispatch commands
  fm-epic-dispatch-plan.sh -h | --help

Prints ONLY (never cuts a branch, never spawns): first fm-epic-branch.sh create
for every involved repo whose epic/<slug> is missing, then the fm-brief.sh +
fm-spawn.sh pair for each currently dispatchable story, with the resolved PR base
and delivery mode. Dispatch stays firstmate judgment. Run WITH FM_HOME set to the
epic's home. Its sibling bin/fm-epic-status.sh shows the same readiness as a table.
EOF
  exit "$code"
}

SLUG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage 0 ;;
    -*) die "unknown option: $1" ;;
    *) if [ -z "$SLUG" ]; then SLUG=$1; else usage; fi ;;
  esac
  shift
done
[ -n "$SLUG" ] || usage
case "$SLUG" in *[!A-Za-z0-9._/-]*|-*) die "invalid epic slug: $SLUG" ;; esac

EPIC_DIR="$(epic_status_find_dir "$PLANS" "$SLUG")" \
  || die "no epic with slug \"$SLUG\" under $PLANS (epic.md must carry \`epic: $SLUG\`)"
epic_status_load "$EPIC_DIR" "$BACKLOG" || die "epic dir $EPIC_DIR is incomplete (needs epic.md + stories/)"

# resolve_mode <story-index>: the delivery mode for a story - its `delivery:` key
# when set, else the repo's REGISTERED posture. Prints the mode; a prod-only
# posture prints the sentinel "PROD-ONLY" so the caller can surface both legs.
resolve_mode() {
  local i=$1 repo="${ST_REPO[$1]}"
  if [ -n "${ST_DELIVERY[$i]}" ]; then
    printf '%s\n' "${ST_DELIVERY[$i]}"
    return 0
  fi
  [ -n "$repo" ] || { printf 'no-mistakes\n'; return 0; }
  # --raw prints "<mode> <yolo>"; take the mode word only.
  case "$("$PROJECT_MODE_BIN" --raw "$repo" 2>/dev/null | awk '{print $1}')" in
    no-mistakes-prod-only) printf 'PROD-ONLY\n' ;;
    direct-PR)             printf 'direct-PR\n' ;;
    local-only)            printf 'local-only\n' ;;
    *)                     printf 'no-mistakes\n' ;;
  esac
}

# resolve_yolo <repo>: the repo's REGISTERED yolo posture (fm-project-mode default
# prints "<mode> <yolo>"). yolo is firstmate judgment (AGENTS.md section 7); the
# registry value is the standing default the emitted command carries so it is
# runnable, and firstmate overrides it deliberately.
resolve_yolo() {
  local repo=$1 yolo
  [ -n "$repo" ] || { printf 'off\n'; return 0; }
  yolo="$("$PROJECT_MODE_BIN" "$repo" 2>/dev/null | awk '{print $2}')"
  case "$yolo" in on|off) printf '%s\n' "$yolo" ;; *) printf 'off\n' ;; esac
}

echo "# dispatch plan for epic $EPIC_SLUG ($EPIC_DIR)"
if [ -z "$EPIC_SIGNED_OFF" ] || [ "$EPIC_STATUS" != active ]; then
  echo "# WARNING: epic is not signed (signed_off \"${EPIC_SIGNED_OFF:-unset}\", status \"${EPIC_STATUS:-unset}\") - do not dispatch until signed."
fi
echo "# PRINTS ONLY - nothing below is executed. Run the lines you decide to dispatch."

# --- step 1: cut the epic branches the stories actually base on --------------
# The branch that gates a story is its own pr_base. So the cut set is exactly the
# distinct epic/<slug> bases the stories declare, per repo (epic_collect_bases),
# not a nominal epic/<epic-slug>. An epic whose stories base on main (a local-only
# fork that lands FF on main) references no epic branch, so nothing is emitted -
# the plan never invents a branch a story will not use.
epic_collect_bases
echo ""
echo "## 1. cut epic branches (the distinct epic/<slug> bases the stories declare)"
[ -z "$EB_DRIFT" ] || echo "# DRIFT: story base branch(es) differ from the epic slug \"$EPIC_SLUG\": $EB_DRIFT (author drift - the create below cuts the branch the story actually names)"
missing=0
for j in "${!EB_SLUG[@]}"; do
  if epic_branch_present "$EPIC_BRANCH_BIN" "${EB_SLUG[$j]}" "${EB_REPO[$j]}"; then
    echo "# epic/${EB_SLUG[$j]} already cut in ${EB_REPO[$j]}"
  else
    echo "bin/fm-epic-branch.sh create ${EB_SLUG[$j]} ${EB_REPO[$j]}"
    missing=$((missing + 1))
  fi
done
if [ "${#EB_SLUG[@]}" -eq 0 ]; then
  echo "# no story bases on an epic/<slug> branch (stories land on their pr_base directly) - no epic branch needed"
elif [ "$missing" -eq 0 ]; then
  echo "# all needed epic branches already cut"
fi

# --- step 2: dispatch each currently dispatchable story ---------------------
echo ""
echo "## 2. dispatch the currently dispatchable stories"
dispatchable=0
for i in "${!ST_ID[@]}"; do
  [ "${ST_STATE[$i]}" = dispatchable ] || continue
  dispatchable=$((dispatchable + 1))
  id="${ST_ID[$i]}"
  repo="${ST_REPO[$i]:-<repo>}"
  base="${ST_PRBASE[$i]:-<base>}"

  # A scout story delivers a report, not a merge: it dispatches with --scout and
  # carries no delivery mode or base (fm-brief/fm-spawn refuse --mode/--base on a
  # scout). Only ship stories get the mode+base pair.
  if [ "${ST_KIND[$i]}" = scout ]; then
    echo ""
    echo "# --- $id  (repo: $repo, SCOUT - report, no merge) ---"
    echo "bin/fm-brief.sh $id $repo --scout"
    echo "# fill the {TASK} placeholder in data/$id/brief.md, then:"
    echo "bin/fm-spawn.sh $id $repo --scout"
    continue
  fi

  mode="$(resolve_mode "$i")"
  yolo="$(resolve_yolo "${ST_REPO[$i]}")"
  echo ""
  echo "# --- $id  (repo: $repo, base: $base) ---"
  if [ "$mode" = PROD-ONLY ]; then
    echo "# delivery mode NEEDS firstmate surface classification (repo posture is no-mistakes-prod-only):"
    echo "#   internal-only tooling/process -> direct-PR ; product-facing/mixed/uncertain -> no-mistakes"
    echo "# then run the pair below with your chosen --mode:"
    mode="<no-mistakes|direct-PR>"
  fi
  echo "bin/fm-brief.sh $id $repo --mode $mode --base $base"
  echo "# fill the {TASK} placeholder in data/$id/brief.md, then (yolo is firstmate's call; $yolo is the registered default):"
  echo "bin/fm-spawn.sh $id $repo --mode $mode --yolo $yolo --base $base"
done
[ "$dispatchable" -gt 0 ] || echo "# no stories are dispatchable now (all done, blocked, or unseeded - see fm-epic-status.sh $EPIC_SLUG)"
