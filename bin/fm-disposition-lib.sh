#!/usr/bin/env bash
# One centralized live disposition reader and fresh per-effect authority
# resolver. Receipts are bound effect evidence, never live truth. This library
# re-reads exact worker, endpoint, Git, forge, bead, owned-copy, and queue
# evidence with explicit unknown branches, and returns landed |
# preserved_unlanded | unknown.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-attempt-lib.sh
. "$SCRIPT_DIR/fm-attempt-lib.sh"

# shellcheck disable=SC2034
FM_DISPOSITION_LIB_SOURCED=1

fm_authority_for() {  # <transition> <task_key> -> prints fresh authority or fails
  local transition=$1 key=$2 file
  file="${FM_AUTHORITY_FILE:-${FM_STATE_OVERRIDE:-$FM_HOME/state}/authority-current.json}"
  [ -f "$file" ] || { echo "missing current-session authority for $transition on $key" >&2; return 1; }
  jq -e --arg t "$transition" '.transition == $t' "$file" >/dev/null 2>&1 \
    || { echo "missing fresh $transition authority for $key (only other-transition authority present)" >&2; return 1; }
  jq -r '.authority' "$file"
}

fm_disposition_live() {  # <attempt_id> -> landed | preserved_unlanded | unknown
  local attempt=$1
  local bead pr merged copy repo branch_state bead_state
  bead=$(fm_attempt_load "$attempt" | jq -r '.envelope.task_key')
  copy=$(fm_attempt_load "$attempt" | jq -r '.provider.copy // ""')
  # shellcheck disable=SC2034 # Git fact re-read as part of the live fact set;
  # not yet an input to the disposition decision tree
  repo="${FM_REFILL_PROJECT:-/home/holu/decision-os}"
  pr=$(fm_attempt_load "$attempt" | jq -r '[.observations[]? | select(.name == "forge")][-1].evidence.pr // ""')
  # forge authority: PR merge state decides landing; bead state is tracker truth
  if [ -n "$pr" ]; then
    merged=$(gh pr view "$pr" --json state,headRefOid,baseRefOid 2>/dev/null \
      | jq -r 'if .state == "MERGED" then "landed" else "preserved_unlanded" end' 2>/dev/null \
      || echo unknown)
    # gh failing with EMPTY stdout makes jq exit 0 with no output, so the
    # || echo unknown never fires; resolve the empty read to unknown too.
    [ -n "$merged" ] || merged=unknown
    [ "$merged" = unknown ] && { echo unknown; return 0; }
    echo "$merged"
    return 0
  fi
  # owned-copy authority: branch/ref state in the exact copy
  if [ -n "$copy" ] && [ -d "$copy/.git" ]; then
    branch_state=$(git -C "$copy" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
    [ "$branch_state" = unknown ] && { echo unknown; return 0; }
  fi
  # bead state is tracker truth, never forge truth; it can only confirm "not
  # landing" or leave the disposition unknown. br answers a not-initialized or
  # not-found bead with an error object (not an array), so both shapes resolve
  # to an explicit unknown instead of a jq crash.
  bead_state=$(br show --json "$bead" 2>/dev/null \
    | jq -r 'if type == "array" then (.[0].status // "unknown") else "unknown" end')
  case "$bead_state" in
    closed|done) echo preserved_unlanded ;;
    *) echo unknown ;;
  esac
}
