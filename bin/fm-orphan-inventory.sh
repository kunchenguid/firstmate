#!/usr/bin/env bash
# fm-orphan-inventory.sh - report-only inventory of Treehouse slots, and the
# processes running inside them, that no current task record names.
#
# WHY. Teardown reaps a task's processes, and every other cleanup path starts
# from a task record, so nothing ever looks at work whose record is gone - most
# visibly after a firstmate home is lost, when its slots and agents keep
# running with no record left to tear them down. This script names them so the
# captain can decide; it never signals, returns, or deletes anything.
#
# ATTRIBUTION, no process environment needed (macOS does not expose another
# process's environment):
#   1. Every Firstmate owner claim <pool>/<slot>/.fm-slot-owner under the
#      Treehouse root whose pool carries a treehouse-state.json. bin/fm-wake-lib.sh owns the claim format and parser.
#   2. The claim's home= is canonicalized with pwd -P, as is this home, so two
#      spellings of one directory compare equal.
#   3. A claim is orphaned when it names this home and state/<task>.meta is
#      absent, or names a home directory that no longer exists. A claim naming
#      another existing home is that home's business and is skipped, as is an
#      unreadable, relative, or oddly named claim. A claim younger than
#      FM_ORPHAN_CLAIM_MIN_AGE_MIN minutes is skipped too: a spawn writes it
#      before publishing the task's record.
#   4. One bounded system-wide `lsof -a -d cwd` scan attributes a process to an
#      orphaned slot when its working directory is inside the slot's copy.
#
# OUTPUT, one line per finding, silent when there is none:
#   ORPHAN_PROCESS: pid=<pid> command=<name> age=<etime> rss_kb=<kb> slot=<copy>
#     task=<task> home=<home> reason=<no-record|home-gone>; <stop command>
#   ORPHAN_SLOT: slot=<copy> task=<task> home=<home> reason=<...>
#     processes=<none|unknown>; <preview cleanup command>
# ORPHAN_SLOT is printed for an orphaned slot with no process inside, or for
# every orphaned slot when the process scan could not run (processes=unknown).
# The printed commands are for the captain's decision: a process may be a live
# agent, and `treehouse destroy` is a dry run that skips unlanded work.
#
# Usage: fm-orphan-inventory.sh
#   Run by the locked deferred startup stage (bin/fm-startup-network.sh).
# Environment:
#   FM_ORPHAN_POOL_ROOT            Treehouse root to scan (default TREEHOUSE_ROOT,
#                                  else ~/.treehouse); tests/lib.sh points it at
#                                  an absent path so no suite reads host pools
#   FM_ORPHAN_CLAIM_MIN_AGE_MIN=5  claim age floor in minutes
#   FM_ORPHAN_SCAN_TIMEOUT=20      seconds bounding the lsof scan
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

POOL_ROOT="${FM_ORPHAN_POOL_ROOT:-${TREEHOUSE_ROOT:-$HOME/.treehouse}}"
MIN_AGE_MIN="${FM_ORPHAN_CLAIM_MIN_AGE_MIN:-5}"
SCAN_TIMEOUT="${FM_ORPHAN_SCAN_TIMEOUT:-20}"
ORPHANS=()   # "<copy><TAB><task><TAB><home><TAB><reason>"
CWDS=''      # "<pid><TAB><cwd>" lines from the one scan

canon_dir() {  # <dir>
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

claim_markers() {
  find "$POOL_ROOT" -mindepth 3 -maxdepth 3 -name .fm-slot-owner -type f \
    -mmin "+$MIN_AGE_MIN" 2>/dev/null
}

slot_copy() {  # <slot-dir>: the slot's single repo copy, canonical
  local d
  for d in "$1"/*/; do
    [ -d "$d" ] && canon_dir "$d" && return 0
  done
  return 1
}

orphan_reason() {  # <claimed-home> <task> <this-home>
  local home
  case "$1" in /*) ;; *) return 1 ;; esac
  if ! home=$(canon_dir "$1"); then
    [ -e "$1" ] || { printf 'home-gone\n'; return 0; }
    return 1
  fi
  [ "$home" = "$3" ] && [ ! -e "$STATE/$2.meta" ] || return 1
  printf 'no-record\n'
}

consider_claim() {  # <marker> <this-home>
  local slot copy reason
  slot=$(dirname "$1")
  [ -f "$(dirname "$slot")/treehouse-state.json" ] || return 0
  copy=$(slot_copy "$slot") || return 0
  fm_treehouse_slot_owner_state "$copy" ''
  case "$FM_TREEHOUSE_SLOT_OWNER_ID" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  reason=$(orphan_reason "$FM_TREEHOUSE_SLOT_OWNER_HOME" "$FM_TREEHOUSE_SLOT_OWNER_ID" "$2") || return 0
  ORPHANS+=("$copy"$'\t'"$FM_TREEHOUSE_SLOT_OWNER_ID"$'\t'"$FM_TREEHOUSE_SLOT_OWNER_HOME"$'\t'"$reason")
}

scan_cwds() {  # sets CWDS; fails when the scan cannot establish a result
  local listing
  command -v lsof >/dev/null 2>&1 || return 1
  listing=$(fm_run_timed "$SCAN_TIMEOUT" lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  CWDS=$(printf '%s\n' "$listing" | awk '/^p/ { pid = substr($0, 2) } /^n/ { print pid "\t" substr($0, 2) }')
}

pids_in() {  # <copy>
  printf '%s\n' "$CWDS" | awk -F '\t' -v dir="$1" -v self="$$" \
    '$1 != self && ($2 == dir || index($2, dir "/") == 1) { print $1 }'
}

report_process() {  # <pid> <orphan-record>
  local copy task home reason info etime rss comm
  IFS=$'\t' read -r copy task home reason <<< "$2"
  info=$(ps -o etime=,rss=,comm= -p "$1" 2>/dev/null) || return 0
  read -r etime rss comm <<< "$info"
  printf 'ORPHAN_PROCESS: pid=%s command=%q age=%s rss_kb=%s slot=%q task=%s home=%q reason=%s; stop it only on the captain'"'"'s word: kill %s\n' \
    "$1" "${comm##*/}" "$etime" "$rss" "$copy" "$task" "$home" "$reason" "$1"
}

report_slot() {  # <orphan-record> <processes>
  local copy task home reason
  IFS=$'\t' read -r copy task home reason <<< "$1"
  printf 'ORPHAN_SLOT: slot=%q task=%s home=%q reason=%s processes=%s; preview its cleanup with: treehouse destroy %q (a dry run; add --yes only after its preview shows no unlanded work)\n' \
    "$copy" "$task" "$home" "$reason" "$2" "$copy"
}

report_orphan() {  # <orphan-record> <scan-ok>
  local pids pid
  [ "$2" = 1 ] || { report_slot "$1" unknown; return 0; }
  pids=$(pids_in "${1%%$'\t'*}")
  [ -n "$pids" ] || { report_slot "$1" none; return 0; }
  for pid in $pids; do report_process "$pid" "$1"; done
}

main() {
  local this_home marker record scan_ok=1
  this_home=$(canon_dir "$FM_HOME") && [ -d "$POOL_ROOT" ] || return 0
  while IFS= read -r marker; do
    consider_claim "$marker" "$this_home"
  done < <(claim_markers)
  [ "${#ORPHANS[@]}" -gt 0 ] || return 0
  scan_cwds || scan_ok=0
  for record in "${ORPHANS[@]}"; do report_orphan "$record" "$scan_ok"; done
}

main
