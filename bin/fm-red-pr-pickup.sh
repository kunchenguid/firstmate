#!/usr/bin/env bash
# fm-red-pr-pickup.sh - write and read the pickup record for a red pull request.
#
# A red PR may never sit waiting (docs/configuration.md "Red-PR pickup SLA"):
# within five minutes of a red check the owning supervisor - this home for its
# own tasks, the secondmate for its workers, in the mate's own home - must have
# named an owner, a next step and an eta. This CLI is how that record is
# written; bin/fm-watch.sh's red_pr_pickup_tick is the ladder that demands it,
# and bin/fm-classify-lib.sh owns the record format, the freshness rule and the
# one writer (fm_red_pr_record_write), so the tick and this CLI can never drift
# apart on what a record is.
#
# Usage:
#   fm-red-pr-pickup.sh record <pr-url> owner=<owner> step='<next step>' eta='<eta>'
#       Write (or refresh) this home's pickup record for the PR. One line each:
#       owner is the named owner (a task id, `firstmate`, or a named human), step
#       the concrete next step that is moving, eta when the step lands - free
#       text, or a UTC ISO 8601 timestamp (`2026-11-20T14:00Z`) which also holds
#       freshness to that deadline. Rewriting refreshes updated=; the write is
#       atomic. The record is the ONLY ownership: an incomplete or stale record
#       reads as none, and the ladder treats the PR as unpicked.
#   fm-red-pr-pickup.sh show [<pr-url>]
#       Print this home's records (or one PR's record) with their freshness
#       verdicts, as the supervisor's read-back.
#   fm-red-pr-pickup.sh path <pr-url>
#       Print the record file's path for this home (FM_HOME/FM_STATE_OVERRIDE
#       resolve it), so a wake's exact command can name where it lands.
#
# Never a merge gate: this record licenses nothing about merging. It only
# prevents a red PR from being unowned; landing the PR stays with
# bin/fm-pr-merge.sh and the captain's merge authority.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  sed -n 's/^# \{0,1\}//p' "$0" | sed -n '/^Usage:/,/^$/p'
}

cmd=${1:-}
case "$cmd" in
  record)
    [ $# -ge 2 ] || { echo 'fm-red-pr-pickup.sh: record needs a pr-url' >&2; exit 2; }
    pr=$2 owner='' step='' eta=''
    shift 2
    for arg in "$@"; do
      case "$arg" in
        owner=*) owner=${arg#owner=} ;;
        step=*) step=${arg#step=} ;;
        eta=*) eta=${arg#eta=} ;;
        *) echo "fm-red-pr-pickup.sh: unknown argument: $arg" >&2; exit 2 ;;
      esac
    done
    if ! fm_red_pr_record_write "$STATE" "$pr" "$owner" "$step" "$eta"; then
      echo 'fm-red-pr-pickup.sh: record needs owner=, step= and eta= (each one line, no tabs)' >&2
      exit 1
    fi
    key=$(fm_red_pr_key "$pr")
    echo "red-pr pickup recorded: $STATE/.red-pr-pickup/$key"
    ;;
  show)
    now=$(date +%s)
    if [ $# -ge 2 ]; then
      if fm_red_pr_record_show "$STATE" "$2"; then
        if fm_red_pr_record_fresh "$STATE" "$2" "$now"; then
          echo "fresh (stale after $(fm_red_pr_record_stale_secs)s without refresh or a future eta)"
        else
          echo "STALE (no refresh within $(fm_red_pr_record_stale_secs)s and no future UTC eta; the red-pr ladder treats this PR as unpicked - rewrite the record)"
        fi
      else
        echo "no pickup record for $2 in this home" >&2
        exit 1
      fi
    else
      found=0
      for f in "$STATE"/.red-pr-pickup/*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        found=1
        cat "$f"
        url=$(_fm_red_pr_field "$f" pr)
        if [ -n "$url" ] && fm_red_pr_record_fresh "$STATE" "$url" "$now"; then
          echo "fresh (stale after $(fm_red_pr_record_stale_secs)s without refresh or a future eta)"
        else
          echo "STALE (no refresh within $(fm_red_pr_record_stale_secs)s and no future UTC eta; the red-pr ladder treats this PR as unpicked - rewrite the record)"
        fi
      done
      [ "$found" -eq 1 ] || echo "no pickup records in this home"
    fi
    ;;
  path)
    [ $# -eq 2 ] || { echo 'fm-red-pr-pickup.sh: path needs a pr-url' >&2; exit 2; }
    key=$(fm_red_pr_key "$2") || { echo "fm-red-pr-pickup.sh: bad pr-url" >&2; exit 2; }
    echo "$STATE/.red-pr-pickup/$key"
    ;;
  ''|-h|--help)
    usage
    [ "$cmd" = '' ] && exit 2
    exit 0
    ;;
  *)
    echo "fm-red-pr-pickup.sh: unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
