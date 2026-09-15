#!/usr/bin/env bash
# fm-refill.sh - durable desired-concurrency deficit detection.
#
# Usage:
#   fm-refill.sh set <count>
#   fm-refill.sh disable
#   fm-refill.sh status
#   fm-refill.sh check
#
# `set` stores one per-home desired productive-worker count in
# config/desired-concurrency. `check` is the watcher-facing, cadence-bounded
# detector. It compares current ordinary direct-report state with
# `tasks-axi ready`, publishes the latest bounded observation atomically, and
# prints one line only when a supervisor reconciliation is due.
#
# A reconciliation is due when terminal work still needs handling, or when the
# productive count is below the configured target and dispatchable work exists.
# Snapshots run at most once per FM_REFILL_CHECK_SECS (default 60) for an
# unchanged target, using the persisted observation as the cadence marker; a
# changed or newly set target is checked on the next poll.
# Identical observations are deduplicated until FM_REFILL_RESURFACE_SECS
# (default 900) so an unresolved capacity problem remains visible without
# spending a model turn on every watcher poll. Ambiguous, parked, paused, or
# blocked records are reported but do not count as productive and cannot hide a
# clean slot in another pool or project.
#
# In a secondmate home, an unacknowledged parent instruction preempts `check`:
# it stays silent without snapshotting or advancing the dedup record, so the
# parent inbox is handled before any refill wake and the deficit surfaces on
# the first poll after acknowledgement.
#
# This command never merges, tears down, spawns, edits the backlog, or guesses a
# task choice. The `refill-continuity` agent skill owns that guarded procedure.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TARGET_FILE="$CONFIG/desired-concurrency"
OBSERVATION="$STATE/refill-deficit"
LOCK="$STATE/.refill-deficit.lock"
CREW_STATE_BIN="${FM_REFILL_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
TASKS_AXI="${FM_REFILL_TASKS_AXI:-tasks-axi}"
NOW="${FM_REFILL_NOW:-$(date +%s)}"
RESURFACE="${FM_REFILL_RESURFACE_SECS:-900}"
CHECK_SECS="${FM_REFILL_CHECK_SECS:-60}"
STATE_TIMEOUT="${FM_REFILL_STATE_TIMEOUT:-10}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

valid_count() { case "$1" in ''|*[!0-9]*|0) return 1 ;; *) [ "$1" -le 64 ] ;; esac; }
valid_positive() { case "$1" in ''|*[!0-9]*|0) return 1 ;; *) return 0 ;; esac; }
valid_epoch() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

target_read() {
  TARGET=
  [ -f "$TARGET_FILE" ] && [ ! -L "$TARGET_FILE" ] || return 1
  IFS= read -r TARGET < "$TARGET_FILE" || return 1
  valid_count "$TARGET"
}

write_target() {
  local value=$1 pending
  mkdir -p "$CONFIG" || return 1
  pending=$(mktemp "$CONFIG/.desired-concurrency.pending.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$pending" || ! mv "$pending" "$TARGET_FILE"; then
    rm -f "$pending"
    return 1
  fi
}

record_get() { awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null; }

snapshot() {
  local meta id kind line state ready_out task_states='' ready_sig
  ACTIVE=0 TERMINAL=0 OTHER=0 TOTAL=0 READY=0 SNAPSHOT_ERROR=
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    kind=$(awk -F= '$1 == "kind" { print $2; exit }' "$meta" 2>/dev/null)
    [ "$kind" != secondmate ] || continue
    id=${meta##*/}; id=${id%.meta}
    TOTAL=$((TOTAL + 1))
    line=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      fm_run_timed "$STATE_TIMEOUT" "$CREW_STATE_BIN" "$id" 2>/dev/null) || line=
    state=$(printf '%s\n' "$line" | sed -n 's/^state: \([^ ]*\) .*/\1/p' | head -n 1)
    [ -n "$state" ] || state=unknown
    task_states="${task_states}${id}:${state};"
    case "$state" in
      working) ACTIVE=$((ACTIVE + 1)) ;;
      done|failed) TERMINAL=$((TERMINAL + 1)) ;;
      *) OTHER=$((OTHER + 1)) ;;
    esac
  done

  ready_out=$("$TASKS_AXI" ready --file "$DATA/backlog.md" 2>/dev/null) || {
    SNAPSHOT_ERROR='tasks-axi ready failed'
    return 1
  }
  READY=$(printf '%s\n' "$ready_out" | sed -n 's/^count: \([0-9][0-9]*\)$/\1/p' | head -n 1)
  case "$READY" in ''|*[!0-9]*) SNAPSHOT_ERROR='tasks-axi ready returned no count'; return 1 ;; esac
  ready_sig=$(printf '%s\n' "$ready_out" | cksum | awk '{print $1 ":" $2}')
  FINGERPRINT=$(printf '%s' "target=$TARGET|active=$ACTIVE|terminal=$TERMINAL|other=$OTHER|total=$TOTAL|ready=$READY|states=$task_states|ready_sig=$ready_sig" | cksum | awk '{print $1 ":" $2}')
  if [ "$TERMINAL" -gt 0 ] || { [ "$ACTIVE" -lt "$TARGET" ] && [ "$READY" -gt 0 ]; }; then
    PHASE=deficit
  else
    PHASE=satisfied
  fi
}

write_observation() {
  local emitted=$1 pending
  mkdir -p "$STATE" || return 1
  pending=$(mktemp "$STATE/.refill-deficit.pending.XXXXXX") || return 1
  cat > "$pending" <<EOF
schema=fm-refill-deficit.v1
phase=$PHASE
fingerprint=$FINGERPRINT
observed_epoch=$NOW
last_emitted_epoch=$emitted
desired=$TARGET
active=$ACTIVE
terminal=$TERMINAL
other=$OTHER
total=$TOTAL
ready=$READY
EOF
  mv "$pending" "$OBSERVATION" || { rm -f "$pending"; return 1; }
}

observation_fresh() {
  local observed desired
  [ -f "$OBSERVATION" ] && [ ! -L "$OBSERVATION" ] || return 1
  desired=$(record_get "$OBSERVATION" desired)
  [ "$desired" = "$TARGET" ] || return 1
  observed=$(record_get "$OBSERVATION" observed_epoch)
  valid_epoch "$observed" || return 1
  [ "$observed" -le "$NOW" ] && [ $((NOW - observed)) -lt "$CHECK_SECS" ]
}

disable_target() {
  local i=0
  mkdir -p "$STATE" || return 1
  until fm_lock_try_acquire "$LOCK"; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || { echo "fm-refill: another check holds $LOCK" >&2; return 1; }
    sleep 0.1
  done
  rm -f "$TARGET_FILE" "$OBSERVATION"
  fm_lock_release "$LOCK"
}

run_check() {
  local previous_fp previous_emit=0 emit=0 age
  target_read || return 0
  valid_epoch "$NOW" || { echo 'fm-refill: invalid clock' >&2; return 1; }
  valid_positive "$RESURFACE" || { echo 'fm-refill: invalid resurface interval' >&2; return 1; }
  valid_positive "$STATE_TIMEOUT" || { echo 'fm-refill: invalid state timeout' >&2; return 1; }
  valid_positive "$CHECK_SECS" || { echo 'fm-refill: invalid check interval' >&2; return 1; }
  fm_parent_channel_pending_instruction "$FM_HOME" >/dev/null && return 0
  observation_fresh && return 0
  mkdir -p "$STATE" || return 1
  # Watcher checks are opportunistic. If a direct status/check already owns the
  # observation lock, this poll stays silent and the next poll retries; it must
  # never block the watcher behind an informational snapshot.
  fm_lock_try_acquire "$LOCK" || return 0
  if observation_fresh; then
    fm_lock_release "$LOCK"
    return 0
  fi
  snapshot || { fm_lock_release "$LOCK"; return 1; }
  previous_fp=$(record_get "$OBSERVATION" fingerprint)
  previous_emit=$(record_get "$OBSERVATION" last_emitted_epoch)
  valid_epoch "$previous_emit" || previous_emit=0
  age=$((NOW - previous_emit)); [ "$age" -ge 0 ] || age=$RESURFACE
  if [ "$PHASE" = deficit ] && { [ "$FINGERPRINT" != "$previous_fp" ] || [ "$age" -ge "$RESURFACE" ]; }; then
    emit=$NOW
  else
    emit=$previous_emit
  fi
  write_observation "$emit" || { fm_lock_release "$LOCK"; return 1; }
  fm_lock_release "$LOCK"
  if [ "$emit" = "$NOW" ]; then
    printf 'refill-deficit: active=%s desired=%s ready=%s terminal=%s other=%s\n' \
      "$ACTIVE" "$TARGET" "$READY" "$TERMINAL" "$OTHER"
  fi
}

run_status() {
  if ! target_read; then
    printf 'desired-concurrency: disabled\n'
    return 0
  fi
  snapshot || { printf 'desired-concurrency: unavailable - %s\n' "$SNAPSHOT_ERROR"; return 1; }
  printf 'desired-concurrency: %s active=%s ready=%s terminal=%s other=%s total=%s phase=%s\n' \
    "$TARGET" "$ACTIVE" "$READY" "$TERMINAL" "$OTHER" "$TOTAL" "$PHASE"
}

case "${1:-}" in
  set)
    if [ "$#" -ne 2 ] || ! valid_count "$2"; then
      usage >&2
      exit 2
    fi
    write_target "$2" || exit 1
    printf 'desired-concurrency: %s\n' "$2"
    ;;
  disable)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    disable_target || exit 1
    printf 'desired-concurrency: disabled\n'
    ;;
  status) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; run_status ;;
  check) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; run_check ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
