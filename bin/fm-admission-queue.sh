#!/usr/bin/env bash
# fm-admission-queue.sh - the durable deferred-start queue behind spawn admission.
#
# A fresh ship or scout start that bin/fm-spawn.sh holds (exit 75: the lane
# cap, the host's load, memory or disk, the fleet-wide worker count, the
# project's GitHub queue, its project capacity, or the load guard) is recorded
# here before the spawn exits, with the exact arguments and directory it was
# given, so a held start survives the exit and is never forgotten. The watcher
# runs `retry` detached on its poll (bin/fm-watch.sh), so a held start is
# offered again at every wake and heartbeat without a new daemon, and the wake
# drain prints `section` so Firstmate sees what is held (bin/fm-wake-drain.sh).
#
# Usage:
#   fm-admission-queue.sh add <task-id> [--reason TEXT] -- <fm-spawn.sh args...>
#                                 record or refresh a held start (idempotent:
#                                 the first queued time and the order survive)
#   fm-admission-queue.sh submit <task-id> -- <fm-dispatch.sh args...>
#                                 queue a fresh routed start without waiting;
#                                 duplicates keep the original request
#   fm-admission-queue.sh list    one line per entry, reserved reviews first,
#                                 then oldest first:
#                                 <id> <held|failed> queued <age> tries <n> <reason> allowance=<ordinary|reserved-review>
#   fm-admission-queue.sh section the ADMISSION block the drain prints, or
#                                 nothing when the queue is empty
#   fm-admission-queue.sh retry [--max-starts N]
#                                 offer held reviews first, then ordinary starts,
#                                 oldest first within each allowance, by
#                                 running fm-spawn.sh with the saved arguments
#   fm-admission-queue.sh drop <task-id>
#                                 forget an entry (a failed one Firstmate gave up on)
#
# retry starts at most N tasks per run (default 1), so a recovered host takes
# starts one tick at a time instead of all at once: that pacing is the
# hysteresis, because every start raises the load the next verdict reads. It
# tries at most FM_ADMISSION_RETRY_ATTEMPTS held entries per run (default 4),
# reserved reviews first then oldest first, because a project-specific hold must not block the entries
# behind it. A start that exits 0 is removed and announced to Firstmate with one
# durable `check:` wake row; an entry whose task already has a record is
# removed; a start that fails for any reason other than a hold stays as `failed`
# (never retried again until dropped) and is announced the same way, so a start
# that cannot run is surfaced instead of retried forever.
#
# State: state/admission-queue/<task-id>.start, one `key=value` record per file
# (mode 0600, written atomically) with queued_epoch, last_epoch, attempts,
# state (held|failed), reason, cwd, command (spawn|dispatch; absent is spawn),
# and one `arg=` line per argument.
# retry serializes on state/.admission-queue.lock and exits 0 when another run
# holds it. Arguments and directories containing a newline are refused.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE resolve the home like the other bin/
# scripts; FM_ADMISSION_SPAWN and FM_ADMISSION_DISPATCH replace replay commands
# (tests only). FM_ADMISSION_RESOLVER_RETRY_SECS (default 900) paces weekly holds.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
QUEUE="$STATE/admission-queue"
SPAWN="${FM_ADMISSION_SPAWN:-$SCRIPT_DIR/fm-spawn.sh}"
DISPATCH="${FM_ADMISSION_DISPATCH:-$SCRIPT_DIR/fm-dispatch.sh}"
HELD_EXIT=75

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { echo "fm-admission-queue: $*" >&2; exit 1; }

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

id_valid() {
  case "$1" in ''|*[!A-Za-z0-9._-]*|.*|-*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

one_line() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-300; }

# Fields of one entry file, set by read_entry; ENTRY_ARGS is an array.
read_entry() {  # <file>
  local line
  ENTRY_QUEUED=0 ENTRY_LAST=0 ENTRY_ATTEMPTS=0 ENTRY_STATE=held ENTRY_REASON='' ENTRY_CWD=''
  ENTRY_ARGS=()
  ENTRY_COMMAND=spawn
  ENTRY_ALLOWANCE=ordinary
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      queued_epoch=*) ENTRY_QUEUED=${line#*=} ;;
      last_epoch=*) ENTRY_LAST=${line#*=} ;;
      attempts=*) ENTRY_ATTEMPTS=${line#*=} ;;
      state=*) ENTRY_STATE=${line#*=} ;;
      reason=*) ENTRY_REASON=${line#*=} ;;
      cwd=*) ENTRY_CWD=${line#*=} ;;
      command=*) ENTRY_COMMAND=${line#*=} ;;
      arg=*)
        ENTRY_ARGS+=("${line#arg=}")
        [ "$line" != arg=--merge-review ] || ENTRY_ALLOWANCE=reserved-review
        ;;
    esac
  done < "$1"
  is_uint "$ENTRY_QUEUED" || ENTRY_QUEUED=0
  is_uint "$ENTRY_LAST" || ENTRY_LAST=0
  is_uint "$ENTRY_ATTEMPTS" || ENTRY_ATTEMPTS=0
  [ "$ENTRY_STATE" = failed ] || ENTRY_STATE=held
}

write_entry() {  # <id> <queued> <attempts> <state> <reason> <cwd> <arg>...
  local id=$1 queued=$2 attempts=$3 state=$4 reason=$5 cwd=$6 tmp arg
  shift 6
  mkdir -p "$QUEUE" || die "cannot create $QUEUE"
  chmod 700 "$QUEUE" 2>/dev/null || true
  [ ! -L "$QUEUE/$id.start" ] || die "$QUEUE/$id.start is a symlink"
  tmp=$(umask 077; mktemp "$QUEUE/.$id.XXXXXX") || die "cannot write the queue entry for $id"
  {
    printf 'queued_epoch=%s\n' "$queued"
    printf 'last_epoch=%s\n' "$(date +%s)"
    printf 'attempts=%s\n' "$attempts"
    printf 'state=%s\n' "$state"
    printf 'reason=%s\n' "$reason"
    printf 'cwd=%s\n' "$cwd"
    printf 'command=%s\n' "${WRITE_COMMAND:-spawn}"
    for arg in "$@"; do printf 'arg=%s\n' "$arg"; done
  } > "$tmp" || { rm -f -- "$tmp"; die "cannot write the queue entry for $id"; }
  mv -f -- "$tmp" "$QUEUE/$id.start" || { rm -f -- "$tmp"; die "cannot publish the queue entry for $id"; }
}

# Reserved reviews first, then oldest queued first (ties by name).
entries_sorted() {
  local f priority
  for f in "$QUEUE"/*.start; do
    [ -f "$f" ] || continue
    read_entry "$f"
    priority=1
    [ "$ENTRY_ALLOWANCE" != reserved-review ] || priority=0
    printf '%s\t%s\t%s\n' "$priority" "$ENTRY_QUEUED" "$f"
  done | sort -n -k1,1 -k2,2 -k3,3 | cut -f3
}

age_text() {  # <seconds>
  local s=$1
  if [ "$s" -lt 120 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 7200 ]; then printf '%sm' $((s / 60))
  else printf '%sh' $((s / 3600)); fi
}

cmd_add() {
  local id cwd arg queued old='' attempts=0 reason=''
  [ "$#" -ge 1 ] || die "add needs a task id"
  id=$1; shift
  id_valid "$id" || die "invalid task id '$id'"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || die "--reason needs a value"; reason=$(one_line "$2"); shift 2 ;;
      --) shift; break ;;
      *) die "unknown add argument '$1'" ;;
    esac
  done
  [ "$#" -ge 1 ] || die "add needs the spawn arguments after --"
  for arg in "$@"; do
    case "$arg" in *$'\n'*) die "a spawn argument holding a newline cannot be queued" ;; esac
  done
  cwd=$(pwd -P) || die "cannot resolve the working directory"
  case "$cwd" in *$'\n'*) die "a working directory holding a newline cannot be queued" ;; esac
  queued=$(date +%s)
  if [ -f "$QUEUE/$id.start" ]; then
    old=$QUEUE/$id.start
    read_entry "$old"
    queued=$ENTRY_QUEUED
    attempts=$ENTRY_ATTEMPTS
    [ "$queued" -gt 0 ] || queued=$(date +%s)
  fi
  attempts=$((attempts + 1))
  write_entry "$id" "$queued" "$attempts" held "$reason" "$cwd" "$@"
}

cmd_submit() {
  local id=${1:-} lock
  id_valid "$id" || die 'submit needs a valid task id'
  # Serialize same-id submissions, not the replay: a slow launch must never
  # prevent a different request from being durably accepted. Existing entries
  # remain immutable here; spawn holds may refresh them through add.
  mkdir -p "$STATE" || die 'cannot create state'
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" || die 'cannot load lock library'
  lock="$STATE/.admission-submit-$id.lock"
  fm_lock_try_acquire "$lock" || die 'same task submission busy; retry submission'
  if [ ! -e "$STATE/$id.meta" ] && [ ! -e "$QUEUE/$id.start" ]; then
    WRITE_COMMAND=dispatch cmd_add "$id" --reason 'pending routed start' "${@:2}"
  fi
  fm_lock_release "$lock"
  printf 'queued: %s (admission retry owns completion; not yet started)\n' "$id"
}

cmd_list() {
  local f id now
  now=$(date +%s)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    id=$(basename "$f" .start)
    read_entry "$f"
    printf '%s %s queued %s tries %s %s allowance=%s\n' "$id" "$ENTRY_STATE" \
      "$(age_text $((now > ENTRY_QUEUED ? now - ENTRY_QUEUED : 0)))" "$ENTRY_ATTEMPTS" "$ENTRY_REASON" "$ENTRY_ALLOWANCE"
  done < <(entries_sorted)
}

cmd_section() {
  local rows
  rows=$(cmd_list)
  [ -n "$rows" ] || return 0
  printf 'ADMISSION: %s start(s) held, retried by the watcher on its poll (bin/fm-admission-queue.sh list; drop <id> forgets one):\n' \
    "$(printf '%s\n' "$rows" | grep -c .)"
  if printf '%s\n' "$rows" | grep -q ' allowance=reserved-review$'; then
    printf '  RESERVED REVIEWS:\n'
    printf '%s\n' "$rows" | grep ' allowance=reserved-review$' | sed 's/^/    /'
  fi
  if printf '%s\n' "$rows" | grep -q ' allowance=ordinary$'; then
    printf '  ORDINARY:\n'
    printf '%s\n' "$rows" | grep ' allowance=ordinary$' | sed 's/^/    /'
  fi
}

announce() {  # <key> <text>
  [ -n "${_FM_WAKE_LIB_LOADED:-}" ] || {
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh" 2>/dev/null || return 0
    _FM_WAKE_LIB_LOADED=1
  }
  fm_wake_append check "$1" "check: $2" >/dev/null 2>&1 || true
}

cmd_retry() {
  local max=1 attempts_cap f id out rc reason started=0 tried=0 lock command resolver_retry
  resolver_retry=${FM_ADMISSION_RESOLVER_RETRY_SECS:-900}
  is_uint "$resolver_retry" || resolver_retry=900
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max-starts)
        if [ "$#" -lt 2 ] || ! is_uint "$2"; then die "--max-starts needs a number"; fi
        max=$2; shift 2 ;;
      *) die "unknown retry argument '$1'" ;;
    esac
  done
  attempts_cap=${FM_ADMISSION_RETRY_ATTEMPTS:-4}
  is_uint "$attempts_cap" && [ "$attempts_cap" -gt 0 ] || attempts_cap=4
  [ -d "$QUEUE" ] || return 0
  [ -n "$(entries_sorted)" ] || return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" || die "cannot load fm-wake-lib.sh"
  _FM_WAKE_LIB_LOADED=1
  lock="$STATE/.admission-queue.lock"
  fm_lock_try_acquire "$lock" || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$started" -lt "$max" ] && [ "$tried" -lt "$attempts_cap" ] || break
    id=$(basename "$f" .start)
    read_entry "$f"
    [ "$ENTRY_STATE" = held ] || continue
    if [ "$ENTRY_COMMAND" = dispatch ] && [ "$ENTRY_REASON" = resolver-held ] &&
       [ "$(( $(date +%s) - ENTRY_LAST ))" -lt "$resolver_retry" ]; then
      continue
    fi
    if [ -e "$STATE/$id.meta" ]; then
      rm -f -- "$f"
      echo "admission: $id already has a task record; dropped from the queue"
      continue
    fi
    [ -n "$ENTRY_CWD" ] && [ -d "$ENTRY_CWD" ] && [ "${#ENTRY_ARGS[@]}" -gt 0 ] || {
      write_entry "$id" "$ENTRY_QUEUED" "$ENTRY_ATTEMPTS" failed "the saved start is unusable (directory or arguments missing)" "$ENTRY_CWD" ${ENTRY_ARGS[@]+"${ENTRY_ARGS[@]}"}
      announce "admission-failed:$id" "held start $id cannot be retried: the saved start is unusable; bin/fm-admission-queue.sh drop $id and dispatch it again"
      echo "admission: $id failed: the saved start is unusable"
      continue
    }
    tried=$((tried + 1))
    rc=0
    case "$ENTRY_COMMAND" in
      spawn) command=$SPAWN ;;
      dispatch) command=$DISPATCH ;;
      *) command= ;;
    esac
    if [ -n "$command" ]; then
      out=$(cd "$ENTRY_CWD" && "$command" "${ENTRY_ARGS[@]}" 2>&1) || rc=$?
    else
      out='invalid saved command'; rc=2
    fi
    if [ "$rc" -eq 0 ]; then
      rm -f -- "$f"
      started=$((started + 1))
      echo "admission: started $id"
      announce "admission-started:$id" "held start $id was admitted and started"
    elif [ "$rc" -eq 3 ] && [ "$ENTRY_COMMAND" = dispatch ] && printf '%s\n' "$out" | grep -q '^[[:space:]]*status: held'; then
      WRITE_COMMAND=dispatch write_entry "$id" "$ENTRY_QUEUED" "$((ENTRY_ATTEMPTS + 1))" held resolver-held "$ENTRY_CWD" "${ENTRY_ARGS[@]}"
      echo "admission: $id resolver held"
    elif [ "$rc" -eq "$HELD_EXIT" ]; then
      echo "admission: $id still held: $(one_line "$(printf '%s\n' "$out" | grep -m1 '^deferred:' || true)")"
    else
      reason="exit $rc: $(one_line "$(printf '%s\n' "$out" | tail -n 1)")"
      WRITE_COMMAND=$ENTRY_COMMAND write_entry "$id" "$ENTRY_QUEUED" "$((ENTRY_ATTEMPTS + 1))" failed "$reason" "$ENTRY_CWD" ${ENTRY_ARGS[@]+"${ENTRY_ARGS[@]}"}
      announce "admission-failed:$id" "held start $id failed on retry ($reason); bin/fm-admission-queue.sh drop $id and dispatch it again"
      echo "admission: $id failed: $reason"
    fi
  done < <(entries_sorted)
  fm_lock_release "$lock"
}

cmd_drop() {
  [ "$#" -eq 1 ] || die "drop needs one task id"
  id_valid "$1" || die "invalid task id '$1'"
  rm -f -- "$QUEUE/$1.start"
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  submit) shift; cmd_submit "$@" ;;
  list) cmd_list ;;
  section) cmd_section ;;
  retry) shift; cmd_retry "$@" ;;
  drop) shift; cmd_drop "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
