#!/usr/bin/env bash
# fm-epic-status.sh - SHOW an epic's dispatch readiness at a glance, so the
# operator never hand-derives it after handoff (report G-dispatch/G-route: the
# pipeline STOPs at the sign gate and the operator had to work out by hand -
# signed? epic branch cut per repo? which stories dispatchable vs blocked? which
# home dispatches?). Its sibling bin/fm-epic-dispatch-plan.sh emits the commands.
#
# Read-only: it mutates nothing and dispatches nothing. It reads the epic dir
# under data/plans/, the backlog Done state, and (per involved repo) whether
# epic/<slug> is cut - via the same primitives the rest of the pipeline owns
# (bin/fm-epic-status-lib.sh reuses bin/fm-epic-branch.sh verify and the
# secondmate registry). Run WITH FM_HOME set to the home that owns the epic.
#
# For a given <slug> it prints:
#   - signed?           epic.md status + signed_off date
#   - epic branches     epic/<slug> present / MISSING per involved repo (N/M cut)
#   - stories           each story's state: DONE | dispatchable | blocked (by ...)
#                       | unseeded, with repo, base, and declared deps
#   - dispatch owner    this home, or a candidate secondmate to confirm by scope
#
# Usage:
#   fm-epic-status.sh <epic-slug>
#   fm-epic-status.sh -h | --help
#
# Overrides (mechanical/test seams, same style as bin/fm-epic-branch.sh):
#   FM_ROOT_OVERRIDE      firstmate code root (default: this script's ..).
#   FM_HOME               the home that owns the epic (default: FM_ROOT).
#   FM_DATA_OVERRIDE      data dir (default $FM_HOME/data); plans + backlog + registry.
#   FM_EPIC_BRANCH_BIN    epic-branch verifier (default $FM_ROOT/bin/fm-epic-branch.sh).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
EPIC_BRANCH_BIN="${FM_EPIC_BRANCH_BIN:-$FM_ROOT/bin/fm-epic-branch.sh}"
PLANS="$DATA/plans"
BACKLOG="$DATA/backlog.md"
SECONDMATES="$DATA/secondmates.md"

# shellcheck source=bin/fm-epic-status-lib.sh
. "$FM_ROOT/bin/fm-epic-status-lib.sh"

die() { echo "error: $*" >&2; exit 1; }

usage() {  # <exit-code> (default 2); code 0 prints to stdout for --help
  local code=${1:-2} out=/dev/stderr
  [ "$code" -eq 0 ] && out=/dev/stdout
  cat > "$out" <<'EOF'
usage:
  fm-epic-status.sh <epic-slug>   show an epic's dispatch readiness (read-only)
  fm-epic-status.sh -h | --help

Prints, for the epic whose epic.md carries `epic: <slug>` under data/plans/:
signed status, epic/<slug> present/MISSING per involved repo, each story's
dispatchable/blocked/done/unseeded state with its deps, and the dispatch-owning
home. Mutates nothing and dispatches nothing. Run WITH FM_HOME set to the epic's
home. Its sibling bin/fm-epic-dispatch-plan.sh emits the ordered dispatch commands.
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

# --- signed? ----------------------------------------------------------------
echo "epic $EPIC_SLUG - ${EPIC_TITLE:-(no title)}"
echo "  dir: $EPIC_DIR"
if [ -n "$EPIC_SIGNED_OFF" ] && [ "$EPIC_STATUS" = active ]; then
  echo "  signed: yes (signed_off $EPIC_SIGNED_OFF, status $EPIC_STATUS)"
elif [ -n "$EPIC_SIGNED_OFF" ]; then
  echo "  signed: signed_off $EPIC_SIGNED_OFF but status is \"${EPIC_STATUS:-unset}\" (expected active)"
else
  echo "  signed: NO (no signed_off; status \"${EPIC_STATUS:-unset}\") - not ready to dispatch"
fi

# --- epic branches the stories base on --------------------------------------
# The branch that gates a story's dispatch is its own pr_base, so the check keys
# off the epic/<slug> bases the stories actually declare (per repo), not a nominal
# epic/<epic-slug>. That is also what stays correct when a story's base branch name
# has drifted from the epic slug, which is surfaced as DRIFT rather than hidden.
epic_collect_bases
echo ""
cut=0
if [ "${#EB_SLUG[@]}" -eq 0 ]; then
  echo "epic branches: none - every story bases on its pr_base directly (no epic branch gates dispatch)"
else
  echo "epic branches (from story pr_base):"
  for j in "${!EB_SLUG[@]}"; do
    if epic_branch_present "$EPIC_BRANCH_BIN" "${EB_SLUG[$j]}" "${EB_REPO[$j]}"; then
      echo "  [x] epic/${EB_SLUG[$j]} in ${EB_REPO[$j]}"
      cut=$((cut + 1))
    else
      echo "  [ ] epic/${EB_SLUG[$j]} in ${EB_REPO[$j]}  - MISSING (cut with: fm-epic-branch.sh create ${EB_SLUG[$j]} ${EB_REPO[$j]})"
    fi
  done
  echo "  $cut/${#EB_SLUG[@]} cut"
  [ -z "$EB_DRIFT" ] || echo "  DRIFT: story base branch(es) differ from the epic slug \"$EPIC_SLUG\": $EB_DRIFT (epic authoring drift - fm-epic-lint territory)"
fi
branches_missing=$(( ${#EB_SLUG[@]} - cut ))

# --- stories ----------------------------------------------------------------
echo ""
echo "stories:"
dispatchable=0
for i in "${!ST_ID[@]}"; do
  meta="repo: ${ST_REPO[$i]:-?}, base: ${ST_PRBASE[$i]:-?}"
  [ -n "${ST_DEPENDS[$i]}" ] && meta="$meta, deps: ${ST_DEPENDS[$i]}"
  case "${ST_STATE[$i]}" in
    done)         echo "  [x] ${ST_ID[$i]}  DONE  ($meta)" ;;
    dispatchable) echo "  [>] ${ST_ID[$i]}  DISPATCHABLE  ($meta)"; dispatchable=$((dispatchable + 1)) ;;
    blocked)      echo "  [-] ${ST_ID[$i]}  blocked-by: ${ST_BLOCKEDBY[$i]}  ($meta)" ;;
    unseeded)     echo "  [?] ${ST_ID[$i]}  UNSEEDED (no backlog entry; promote first)  ($meta)" ;;
  esac
done
[ "${#ST_ID[@]}" -gt 0 ] || echo "  (no stories under $EPIC_DIR/stories/)"
echo "  $dispatchable dispatchable now"

# --- dispatch owner ---------------------------------------------------------
echo ""
echo "dispatch owner: $(epic_dispatch_owner "$SECONDMATES" ${EPIC_REPOS[@]+"${EPIC_REPOS[@]}"})"

if [ "$dispatchable" -gt 0 ] || [ "$branches_missing" -gt 0 ]; then
  echo ""
  echo "next: fm-epic-dispatch-plan.sh $EPIC_SLUG   (prints the ordered cut-branch + dispatch commands)"
fi
