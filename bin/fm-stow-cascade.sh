#!/usr/bin/env bash
# Enumerate this home's registered secondmates for an internal /stow cascade.
# Usage: fm-stow-cascade.sh [--help]
#        fm-stow-cascade.sh --reach <memory-file> <survivor>...
#
# The internal /stow skill owns curation judgement; this command owns only the
# mechanical inputs a cascade needs: which homes exist, what each home's own
# startup-memory accounting says right now, and how the sweep can reach it.
#
# Enumeration comes from data/secondmates.md, the registry that already refuses
# a duplicate id, a duplicate home, and an overlapping home, so each registered
# secondmate is emitted exactly once and no home is accounted twice. A home's
# budget is that home's alone: this command never sums a fleet total, because
# config/startup-memory-budget is a per-home allowance.
#
# Each home is reported as one blank-line-separated key=value stanza:
#   secondmate=<id>
#   placement=local|remote            (host=<alias> on a remote route)
#   home=<path>
#   budget_report=ok|error|timeout    (report lines follow on ok)
#   transport=agent|direct|deferred|unavailable
#   reason=<one line>                 (whenever a step did not complete)
#
# transport says how the sweep reaches that home:
#   agent     - a live secondmate agent owns the home; steer it with
#               bin/fm-send.sh so it sweeps its own uncaptured session
#               knowledge and replies through its marked return channel.
#   direct    - a local home with no live agent; curate its editable memory
#               files in place.
#   deferred  - a remote home with no live agent. There is deliberately no
#               generic remote write path (bin/fm-remote-file.sh put reaches
#               only the handoff outbox), so that home is accounted read-only
#               and curated by its next cascade once its agent is back.
#   unavailable - the home's own accounting did not complete, so no transport
#               conclusion is safe.
#
# Every step that crosses a host, plus each home's own accounting, runs under
# one hard bound (FM_STOW_CASCADE_TIMEOUT seconds, default 60), so a slow or
# unreachable home reports an exception and the sweep continues instead of
# blocking the primary's own /stow. A local endpoint probe reads this host's
# recorded backend in process, like every other caller of that contract.
#
# A secondmate home never cascades: secondmates do not own secondmates, so this
# command reports the empty cascade there rather than reaching for a registry.
#
# --reach answers, per fact, whether every home that reads a fact in
# <memory-file> (data/captain.md, data/captain-shared.md, or data/learnings.md)
# today can still read that fact after stow moves or drops an entry. Each
# <survivor> is a place the fact will still be afterwards: a relocation's
# destination, the surviving copy a dropped duplicate leaves, or the archive a
# retirement writes. A reader still reads the fact when any survivor is
# reachable from it; one that reaches none loses the fact, which is a deletion
# for that reader. This home reads all three files; in a primary home every
# registered secondmate also reads its inherited copy of
# data/captain-shared.md. A survivor is reachable from a reader when it lies
# inside that reader's home, or, for a secondmate reading the shared file, when
# it is this home's data/captain-shared.md itself, the shared surface every
# inheriting home (local or remote) loads as its copy. A local home that fails
# validation never counts as reaching anything. It prints source=, one
# survives= line per survivor, one
# "reader=<id> placement=<p> home=<path> reachable=yes|no" line per reader, and
# reach=reversible or reach=removal. In a secondmate home
# data/captain-shared.md is primary-owned, so --reach refuses it there.
#
# Exit status: 0 every home reported cleanly (or there were none), or --reach
# found every reader still able to read the fact; 3 at least one home reported
# an exception and every home was still reported; 4 --reach found a reader
# that would lose the fact; 1 the cascade input itself is unusable; 2 invalid
# use.
set -u

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

MODE=cascade
case "${1:-}" in
  -h|--help) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; usage; exit 0 ;;
  --reach) [ "$#" -ge 3 ] || { usage >&2; exit 2; }; MODE=reach ;;
  "") [ "$#" -eq 0 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REGISTRY="$DATA/secondmates.md"
BUDGET_CMD=fm-startup-memory-budget.sh
SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

BOUND=${FM_STOW_CASCADE_TIMEOUT:-60}
case "$BOUND" in
  ''|*[!0-9]*) printf 'error: FM_STOW_CASCADE_TIMEOUT must be a positive integer: %s\n' "$BOUND" >&2; exit 2 ;;
esac
[ "$BOUND" -gt 0 ] \
  || { printf 'error: FM_STOW_CASCADE_TIMEOUT must be a positive integer: %s\n' "$BOUND" >&2; exit 2; }

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
emit() { printf '%s\n' "$1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-stow-cascade.XXXXXX") || exit 1
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap.
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
STEP_OUT="$TMP/step.out"

# Run one bounded external step, capturing its stdout for the caller.
# Returns the step's own status, or 124 when the bound was hit.
run_step() {
  local rc=0
  fm_run_timed "$BOUND" "$@" < /dev/null > "$STEP_OUT" 2>/dev/null || rc=$?
  return "$rc"
}

# This home's recorded secondmate endpoint for <id>, if it has one.
meta_for() { # <id>
  local meta="$STATE/$1.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  grep -q '^kind=secondmate$' "$meta" 2>/dev/null || return 1
  printf '%s\n' "$meta"
}

TRANSPORT=
TRANSPORT_REASON=
set_transport() { TRANSPORT=$1; TRANSPORT_REASON=${2:-}; }

# A local home is curated in place when no live agent owns it.
resolve_local_transport() { # <id> <resolved-home>
  local id=$1 home=$2 meta backend target meta_home
  if ! meta=$(meta_for "$id"); then
    set_transport direct 'no recorded endpoint for this home'
    return 0
  fi
  meta_home=$(fm_meta_get "$meta" home)
  if [ -n "$meta_home" ] \
    && [ "$(secondmate_registry_path_key "$meta_home" 2>/dev/null || true)" != "$home" ]; then
    set_transport direct 'recorded endpoint belongs to another home'
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  if [ -z "$target" ]; then
    set_transport direct 'recorded endpoint has no target'
    return 0
  fi
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')" in
    alive) set_transport agent ;;
    *) set_transport direct 'no live agent on the recorded endpoint' ;;
  esac
}

# A remote home with no live agent is deferred, never direct: this repo has no
# generic remote write path for a home's own memory files.
resolve_remote_transport() { # <id>
  local id=$1 rc=0
  if ! meta_for "$id" >/dev/null; then
    set_transport deferred 'no recorded endpoint and no remote memory write path'
    return 0
  fi
  run_step "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" || rc=$?
  if [ "$rc" -eq 124 ]; then
    set_transport deferred "remote endpoint probe exceeded the ${BOUND}s bound"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    set_transport deferred 'remote endpoint probe failed'
    return 0
  fi
  case "$(tail -1 "$STEP_OUT")" in
    alive) set_transport agent ;;
    *) set_transport deferred 'no live agent and no remote memory write path' ;;
  esac
}

# <path> made absolute against this home, with its existing part resolved.
reach_path() { # <path>
  local path=$1 rest=
  case "$path" in /*) ;; *) path="$FM_HOME/$path" ;; esac
  while [ "$path" != / ] && [ "${path%/}" != "$path" ]; do path=${path%/}; done
  while [ ! -d "$path" ]; do
    rest="/${path##*/}$rest"
    path=${path%/*}
    [ -n "$path" ] || path=/
  done
  path=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || return 1
  printf '%s%s\n' "${path%/}" "$rest"
}

REACH_UNREACHABLE=0
REACH_SURVIVORS=()
reach_reader() { # <reader> <placement> <home> <shared-surface-or-empty> <usable:0|1>
  local reachable=no survivor
  if [ "$5" = 1 ]; then
    for survivor in "${REACH_SURVIVORS[@]}"; do
      case "$survivor/" in "${3%/}"/*) reachable=yes ;; esac
      [ -z "$4" ] || [ "$survivor" != "$4" ] || reachable=yes
    done
  fi
  emit "reader=$1 placement=$2 home=$3 reachable=$reachable"
  [ "$reachable" = yes ] || REACH_UNREACHABLE=$((REACH_UNREACHABLE + 1))
}

reach_main() { # <memory-file> <survivor>...
  local source=${1##*/} survivor resolved self shared line
  shift
  case "$source" in captain.md|captain-shared.md|learnings.md) ;; *) usage >&2; exit 2 ;; esac
  for survivor in "$@"; do
    case "/$survivor/" in
      */../*|*/./*) printf 'error: a survivor must not contain . or .. segments: %s\n' "$survivor" >&2; exit 2 ;;
    esac
    resolved=$(reach_path "$survivor") || die "survivor cannot be resolved: $survivor"
    REACH_SURVIVORS+=("$resolved")
  done
  self=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "home cannot be resolved: $FM_HOME"
  if [ "$source" = captain-shared.md ] \
    && { [ -e "$FM_HOME/$SUB_HOME_MARKER" ] || [ -L "$FM_HOME/$SUB_HOME_MARKER" ]; }; then
    die "data/captain-shared.md is primary-owned in a secondmate home; route its relocation to the primary owner"
  fi
  emit "source=data/$source"
  for survivor in "${REACH_SURVIVORS[@]}"; do emit "survives=$survivor"; done
  reach_reader this-home local "$self" '' 1
  if [ "$source" = captain-shared.md ] && { [ -e "$REGISTRY" ] || [ -L "$REGISTRY" ]; }; then
    shared=$(reach_path "$DATA/captain-shared.md") || die "shared memory file cannot be resolved: $DATA/captain-shared.md"
    secondmate_registry_validate_bindings "$REGISTRY" secondmate_registry_path_key \
      || die "$SECONDMATE_REGISTRY_ERROR"
    grep '^- ' "$REGISTRY" > "$TMP/records" 2>/dev/null || : > "$TMP/records"
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      secondmate_registry_parse_line "$line" || die "malformed secondmate registry entry: $line"
      if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
        reach_reader "$SECONDMATE_REGISTRY_ID" remote "$SECONDMATE_REGISTRY_HOST:$SECONDMATE_REGISTRY_HOME" "$shared" 1
      elif validate_secondmate_home "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME"; then
        reach_reader "$SECONDMATE_REGISTRY_ID" local "$VALIDATED_HOME" "$shared" 1
      else
        reach_reader "$SECONDMATE_REGISTRY_ID" local "$SECONDMATE_REGISTRY_HOME" '' 0
      fi
    done < "$TMP/records"
  fi
  if [ "$REACH_UNREACHABLE" -eq 0 ]; then
    emit 'reach=reversible'
    exit 0
  fi
  emit 'reach=removal'
  exit 4
}

[ "$MODE" != reach ] || { shift; reach_main "$@"; }

if [ -e "$FM_HOME/$SUB_HOME_MARKER" ] || [ -L "$FM_HOME/$SUB_HOME_MARKER" ]; then
  emit 'role=secondmate'
  emit 'secondmates=0'
  emit 'reason=a secondmate home stows its own memory only and never cascades'
  exit 0
fi
emit 'role=primary'

if [ ! -e "$REGISTRY" ] && [ ! -L "$REGISTRY" ]; then
  emit 'secondmates=0'
  emit 'exceptions=0'
  emit 'reason=no secondmate registry in this home'
  exit 0
fi
if ! secondmate_registry_validate_bindings "$REGISTRY" secondmate_registry_path_key; then
  die "$SECONDMATE_REGISTRY_ERROR"
fi

grep '^- ' "$REGISTRY" > "$TMP/records" 2>/dev/null || : > "$TMP/records"
total=0
exceptions=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  secondmate_registry_parse_line "$line" || die "malformed secondmate registry entry: $line"
  id=$SECONDMATE_REGISTRY_ID
  home=$SECONDMATE_REGISTRY_HOME
  remote=$SECONDMATE_REGISTRY_REMOTE
  host=$SECONDMATE_REGISTRY_HOST
  total=$((total + 1))
  rc=0
  printf '\n'
  emit "secondmate=$id"
  if [ "$remote" -eq 1 ]; then
    emit 'placement=remote'
    emit "host=$host"
    emit "home=$home"
    run_step "$SCRIPT_DIR/fm-on.sh" "$id" "$BUDGET_CMD" report || rc=$?
  else
    emit 'placement=local'
    if ! validate_secondmate_home "$id" "$home"; then
      emit "home=$home"
      emit 'budget_report=error'
      emit 'transport=unavailable'
      emit "reason=$VALIDATION_ERROR"
      exceptions=$((exceptions + 1))
      continue
    fi
    resolved=$VALIDATED_HOME
    emit "home=$resolved"
    # Every FM_*_OVERRIDE is restated so a caller's own override cannot leak
    # this home's memory files into the accounting of another home.
    run_step env \
      FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$resolved" \
      FM_STATE_OVERRIDE="$resolved/state" \
      FM_DATA_OVERRIDE="$resolved/data" \
      FM_CONFIG_OVERRIDE="$resolved/config" \
      "$SCRIPT_DIR/$BUDGET_CMD" report || rc=$?
  fi
  if [ "$rc" -eq 124 ]; then
    emit 'budget_report=timeout'
    emit 'transport=unavailable'
    emit "reason=this home's own accounting exceeded the ${BOUND}s bound"
    exceptions=$((exceptions + 1))
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    emit 'budget_report=error'
    emit 'transport=unavailable'
    emit "reason=this home's own accounting failed"
    exceptions=$((exceptions + 1))
    continue
  fi
  emit 'budget_report=ok'
  cat "$STEP_OUT"
  if [ "$remote" -eq 1 ]; then
    resolve_remote_transport "$id"
  else
    resolve_local_transport "$id" "$resolved"
  fi
  emit "transport=$TRANSPORT"
  [ -z "$TRANSPORT_REASON" ] || emit "reason=$TRANSPORT_REASON"
  case "$TRANSPORT" in agent|direct) ;; *) exceptions=$((exceptions + 1)) ;; esac
done < "$TMP/records"

printf '\n'
emit "secondmates=$total"
emit "exceptions=$exceptions"
[ "$exceptions" -eq 0 ] || exit 3
exit 0
