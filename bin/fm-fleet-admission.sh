#!/usr/bin/env bash
# Inspect and reconcile the fleet-wide worker admission ledger.
# bin/fm-wake-lib.sh's fleet worker admission section owns the ceiling, the
# ledger, and the claim lifecycle that bin/fm-spawn.sh and bin/fm-teardown.sh
# drive; this is the operator surface over it. Run it from any local home: every home resolves the
# same root anchor.
#
# Usage:
#   fm-fleet-admission.sh status
#     Prints the ceiling (or `off`), the number of held claims, and one line
#     per claim: <verdict> <kind> <task> <home>. The verdict is live, spawning,
#     or orphaned. Read-only. Exits 0 when nothing is orphaned, 2 when an
#     orphaned claim needs an explicit decision, and 1 when the ledger cannot
#     be read. A replacement primary session runs this to reconcile the
#     capacity its predecessor left: the ledger is durable and never reset.
#   fm-fleet-admission.sh adopt
#     Claims every ship and scout task record already present in THIS home
#     (FM_HOME) that holds no claim yet, marking each active. Existing work is
#     never refused, so adoption may leave the fleet above its ceiling; new
#     spawns then wait until enough workers finish. Idempotent. Run it once in
#     every local home when first enabling the ceiling.
#   fm-fleet-admission.sh release <task-id> [--home <home>]
#     Explicitly frees one claim (default home: FM_HOME). Refuses while the
#     task record still exists or while the claim's own spawn is still running,
#     so it can free only an orphaned claim. Nothing else ever frees an
#     orphaned claim.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '8,26p' "$0" | sed 's/^# \{0,1\}//'
}

cmd_status() {
  local claim verdict orphaned=0 count
  fm_fleet_admission_resolve "$FM_HOME" || {
    echo "error: $FM_FLEET_ADMISSION_ERROR" >&2
    return 1
  }
  count=0
  [ ! -d "$(fm_fleet_admission_dir)" ] || count=$(fm_fleet_admission_count)
  if [ "$FM_FLEET_ADMISSION_ENABLED" = 1 ]; then
    printf 'fleet worker ceiling: %s (root %s)\n' "$FM_FLEET_ADMISSION_LIMIT" "$FM_FLEET_ADMISSION_ROOT"
  else
    printf 'fleet worker ceiling: off (root %s)\n' "$FM_FLEET_ADMISSION_ROOT"
  fi
  printf 'held: %s\n' "$count"
  for claim in "$(fm_fleet_admission_dir)"/*.claim; do
    [ -e "$claim" ] || [ -L "$claim" ] || continue
    verdict=$(fm_fleet_admission_verdict "$claim")
    [ "$verdict" != orphaned ] || orphaned=$((orphaned + 1))
    printf '%s %s %s %s\n' "$verdict" \
      "$(fm_fleet_admission_field "$claim" kind)" \
      "$(fm_fleet_admission_field "$claim" task)" \
      "$(fm_fleet_admission_field "$claim" home)"
  done
  if [ "$orphaned" -gt 0 ]; then
    echo "orphaned claims keep their slots until released explicitly: confirm no worker for the task is still running, then run fm-fleet-admission.sh release <task-id> --home <home>" >&2
    return 2
  fi
}

cmd_adopt() {
  local meta id kind rc adopted=0
  fm_fleet_admission_resolve "$FM_HOME" || {
    echo "error: $FM_FLEET_ADMISSION_ERROR" >&2
    return 1
  }
  if [ "$FM_FLEET_ADMISSION_ENABLED" != 1 ]; then
    echo "error: no fleet worker ceiling is configured at $FM_FLEET_ADMISSION_ROOT/config/fleet-crew-limit; nothing to adopt into" >&2
    return 1
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    kind=$(sed -n 's/^kind=//p' "$meta" | tail -n 1)
    case "$kind" in ship|scout) ;; *) continue ;; esac
    # Existing work is adopted even above the ceiling: admit first, and fall
    # back to writing the claim directly only when the ceiling refused it.
    fm_fleet_admission_admit "$FM_HOME" "$STATE" "$id" "$kind" active
    rc=$?
    if [ "$rc" -eq 3 ]; then
      _fm_fleet_admission_lock || { echo "error: $FM_FLEET_ADMISSION_ERROR" >&2; return 1; }
      _fm_fleet_admission_write \
        "$(fm_fleet_admission_claim_path "$(fm_fleet_admission_canonical_home "$FM_HOME")" "$id")" \
        "$(fm_fleet_admission_canonical_home "$FM_HOME")" "$STATE" "$id" "$kind" active ""
      rc=$?
      _fm_fleet_admission_unlock
    fi
    if [ "$rc" -ne 0 ]; then
      echo "error: could not adopt task $id: $FM_FLEET_ADMISSION_ERROR" >&2
      return 1
    fi
    adopted=$((adopted + 1))
  done
  printf 'adopted: %s task(s) from %s\n' "$adopted" "$FM_HOME"
  printf 'held: %s of %s\n' "$(fm_fleet_admission_count)" "$FM_FLEET_ADMISSION_LIMIT"
}

cmd_release() {
  local id=${1:-} home=$FM_HOME rc
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || { usage >&2; return 2; }; home=$2; shift 2 ;;
      *) usage >&2; return 2 ;;
    esac
  done
  case "$id" in ''|*[!A-Za-z0-9._-]*) usage >&2; return 2 ;; esac
  fm_fleet_admission_release_orphan "$FM_HOME" "$home" "$id"
  rc=$?
  case "$rc" in
    0) echo "released $id in $home (if it held a claim)" ;;
    4) echo "error: refusing to release: $FM_FLEET_ADMISSION_ERROR (tear the task down instead, or wait for its spawn to finish)" >&2; return 1 ;;
    *) echo "error: ${FM_FLEET_ADMISSION_ERROR:-could not release $id}" >&2; return 1 ;;
  esac
}

case "${1:-}" in
  status) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_status ;;
  adopt) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_adopt ;;
  release) shift; cmd_release "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
