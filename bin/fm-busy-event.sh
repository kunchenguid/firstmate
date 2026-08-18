#!/usr/bin/env bash
# fm-busy-event.sh - the ONLY writer of the semantic busy-state contract
# owned by bin/fm-busy-lib.sh (record format, gen binding, and classification
# live there; this script owns mutation mechanics only).
#
# Subcommands:
#
#   arm <state-dir> <id> [--state busy|idle|unknown] [--source S] [--event E]
#       Mint a fresh incarnation gen token, write the gen sidecar, and seed
#       the record at seq=1 (default: busy, source fm-spawn, event
#       launch-brief - the launch prompt IS a submitted turn). Prints the
#       minted gen on stdout so the caller can embed it into adapter wiring.
#       Arming again replaces the previous incarnation: late events carrying
#       the old gen are rejected as stale from then on.
#
#   apply <state-dir> <id> <busy|idle|unknown> (--gen G | --current-gen)
#         --source S --event E
#       Append one lifecycle event: validate the gen against the armed
#       sidecar, advance seq under the lock, atomically replace the record.
#       Adapter wiring passes the exact --gen embedded at arm time, so a
#       hook that outlives its incarnation fails closed here. The legacy
#       Claude fm-send --key Escape path (fm-interrupt) and firstmate recovery
#       paths (fm-recovery) may pass --current-gen to bind to the incarnation
#       armed right now.
#
#   retire <state-dir> <id> (--gen G | --current-gen)
#       Remove one incarnation's sidecar and record while holding the same
#       writer lock used by arm and apply. An exact gen prevents teardown for
#       an old task from retiring a newly armed incarnation. A missing sidecar
#       is already retired, so any orphan record is removed idempotently.
#
# Exit codes: 0 applied; 1 refused (stale gen, unarmed task, lock timeout,
# invalid input); 2 usage. Adapter hook command lines append `|| true` so a
# refusal never breaks the harness's own lifecycle.
set -u

usage() {
  cat >&2 <<'EOF'
usage:
  fm-busy-event.sh arm <state-dir> <id> [--state busy|idle|unknown] [--source S] [--event E]
  fm-busy-event.sh apply <state-dir> <id> <busy|idle|unknown> (--gen G | --current-gen) --source S --event E
  fm-busy-event.sh retire <state-dir> <id> (--gen G | --current-gen)
See the header comment for the full contract.
EOF
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

CMD=${1:-}
case "$CMD" in
  arm|apply|retire) shift ;;
  *) usage ;;
esac

STATE=${1:-}
ID=${2:-}
[ -n "$STATE" ] && [ -n "$ID" ] || usage
shift 2
case "$ID" in *[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }

NEW_STATE=
GEN=
USE_CURRENT_GEN=0
SOURCE=
EVENT=
if [ "$CMD" = apply ]; then
  NEW_STATE=${1:-}
  case "$NEW_STATE" in busy|idle|unknown) shift ;; *) usage ;; esac
elif [ "$CMD" = arm ]; then
  NEW_STATE=busy
  SOURCE=fm-spawn
  EVENT=launch-brief
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --state) NEW_STATE=${2:-}; shift 2 || usage ;;
    --gen) GEN=${2:-}; shift 2 || usage ;;
    --current-gen) USE_CURRENT_GEN=1; shift ;;
    --source) SOURCE=${2:-}; shift 2 || usage ;;
    --event) EVENT=${2:-}; shift 2 || usage ;;
    *) usage ;;
  esac
done
if [ "$CMD" != retire ]; then
  case "$NEW_STATE" in busy|idle|unknown) : ;; *) usage ;; esac
  fm_busy_token_valid "$SOURCE" || { echo "error: invalid --source" >&2; exit 1; }
  fm_busy_token_valid "$EVENT" || { echo "error: invalid --event" >&2; exit 1; }
fi

REC=$(fm_busy_record_path "$STATE" "$ID")
GEN_FILE=$(fm_busy_gen_path "$STATE" "$ID")
JOURNAL="$REC.transition"
LOCK="$REC.lock"

# Serialize writers. The lock protects seq advancement and the sidecar/record
# pair; a holder that died mid-write is broken after FM_BUSY_LOCK_STALE_SECS.
lock_acquire() {
  local tries=0 now mtime age
  while ! mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 40 ]; then
      now=$(date +%s)
      mtime=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo "$now")
      age=$((now - mtime))
      if [ "$age" -ge "${FM_BUSY_LOCK_STALE_SECS:-5}" ]; then
        rmdir "$LOCK" 2>/dev/null || rm -rf "$LOCK" 2>/dev/null || true
        mkdir "$LOCK" 2>/dev/null && break
      fi
      echo "error: busy-state lock timeout for $ID" >&2
      return 1
    fi
    sleep 0.05
  done
  return 0
}
lock_release() { rmdir "$LOCK" 2>/dev/null || true; }

write_busy_record() {  # <gen> <seq> <state> <source> <event> <timestamp>
  local tmp
  tmp="$REC.tmp.$$"
  printf 'v1 gen=%s seq=%s state=%s source=%s event=%s ts=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" > "$tmp" || return 1
  mv -f "$tmp" "$REC"
}

dashboard_state_for() {  # <busy-state>
  case "$1" in
    busy) dashboard_state=working ;;
    idle) dashboard_state=parked ;;
    unknown) dashboard_state=unknown ;;
  esac
}

write_pending() {  # <gen> <seq> <state> <source> <event> <timestamp>
  local tmp
  tmp="$JOURNAL.tmp.$$"
  printf 'v1 gen=%s seq=%s state=%s source=%s event=%s ts=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" > "$tmp" || return 1
  mv -f "$tmp" "$JOURNAL"
}

read_pending() {
  local line extra field
  local -a fields
  PENDING_GEN=
  PENDING_SEQ=
  PENDING_STATE=
  PENDING_SOURCE=
  PENDING_EVENT=
  PENDING_AT=
  [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || return 1
  # shellcheck disable=SC2034 # extra exists only to prove the record is one line
  { IFS= read -r line && ! IFS= read -r extra; } < "$JOURNAL" 2>/dev/null || return 1
  IFS=' ' read -r -a fields <<< "$line"
  [ "${#fields[@]}" -eq 7 ] && [ "${fields[0]}" = "$FM_BUSY_LIB_VERSION" ] || return 1
  for field in "${fields[@]:1}"; do
    case "$field" in
      gen=*) PENDING_GEN=${field#gen=} ;;
      seq=*) PENDING_SEQ=${field#seq=} ;;
      state=*) PENDING_STATE=${field#state=} ;;
      source=*) PENDING_SOURCE=${field#source=} ;;
      event=*) PENDING_EVENT=${field#event=} ;;
      ts=*) PENDING_AT=${field#ts=} ;;
      *) return 1 ;;
    esac
  done
  fm_busy_token_valid "$PENDING_GEN" && fm_busy_token_valid "$PENDING_SOURCE" \
    && fm_busy_token_valid "$PENDING_EVENT" || return 1
  case "$PENDING_SEQ" in ''|*[!0-9]*) return 1 ;; esac
  case "$PENDING_AT" in ''|*[!0-9]*) return 1 ;; esac
  case "$PENDING_STATE" in busy|idle|unknown) ;; *) return 1 ;; esac
}

replay_pending() {  # <current-gen>
  [ -e "$JOURNAL" ] || return 0
  read_pending || return 1
  if [ "$PENDING_GEN" != "$1" ]; then
    rm -f -- "$JOURNAL"
    return 0
  fi
  dashboard_state_for "$PENDING_STATE"
  if [ "${FM_DASHBOARD_TRANSITION_DEFER:-0}" != 1 ]; then
    "$SCRIPT_DIR/fm-dashboard-transition.sh" record "$STATE" "$ID" "$dashboard_state" "$PENDING_AT" || return 1
  fi
  if [ "${FM_BUSY_EVENT_TESTING:-0}" = 1 ] && [ "${FM_BUSY_EVENT_TEST_INTERRUPT_AFTER_TRANSITION:-0}" = 1 ]; then
    return 1
  fi
  write_busy_record "$PENDING_GEN" "$PENDING_SEQ" "$PENDING_STATE" "$PENDING_SOURCE" "$PENDING_EVENT" "$PENDING_AT" || return 1
  rm -f -- "$JOURNAL"
}

commit_event() {  # <gen> <seq> <state> <source> <event> <timestamp>
  write_pending "$@" && replay_pending "$1"
}

old_umask=$(umask)
umask 077

if [ "$CMD" = arm ]; then
  timestamp=$(date +%s)
  GEN="g${timestamp}.$$.${RANDOM}"
  lock_acquire || exit 1
  {
    rm -f -- "$JOURNAL" \
      && printf '%s\n' "$GEN" > "$GEN_FILE.tmp.$$" && mv -f "$GEN_FILE.tmp.$$" "$GEN_FILE" \
      && commit_event "$GEN" 1 "$NEW_STATE" "$SOURCE" "$EVENT" "$timestamp"
  } || { lock_release; umask "$old_umask"; echo "error: arm failed for $ID" >&2; exit 1; }
  lock_release
  umask "$old_umask"
  printf '%s\n' "$GEN"
  exit 0
fi

# apply / retire
if [ "$USE_CURRENT_GEN" = 1 ] && [ "$CMD" != retire ]; then
  GEN=$(fm_busy_current_gen "$STATE" "$ID") || {
    umask "$old_umask"
    echo "error: no armed busy-state gen for $ID" >&2
    exit 1
  }
fi
if [ "$USE_CURRENT_GEN" != 1 ] || [ "$CMD" != retire ]; then
  fm_busy_token_valid "$GEN" || { umask "$old_umask"; echo "error: invalid --gen" >&2; exit 1; }
fi

lock_acquire || { umask "$old_umask"; exit 1; }
CURRENT=$(fm_busy_current_gen "$STATE" "$ID") || {
  if [ "$CMD" = retire ] && [ ! -e "$GEN_FILE" ] && [ ! -L "$GEN_FILE" ]; then
    rm -f "$REC" "$JOURNAL" || {
      lock_release
      umask "$old_umask"
      echo "error: busy-state retirement failed for $ID" >&2
      exit 1
    }
    lock_release
    umask "$old_umask"
    exit 0
  fi
  lock_release
  umask "$old_umask"
  echo "error: no armed busy-state gen for $ID" >&2
  exit 1
}
if [ "$CMD" = retire ] && [ "$USE_CURRENT_GEN" = 1 ]; then
  GEN=$CURRENT
fi
if [ "$GEN" != "$CURRENT" ]; then
  lock_release
  umask "$old_umask"
  echo "error: stale busy-state gen for $ID (event rejected)" >&2
  exit 1
fi
if [ "$CMD" = retire ]; then
  rm -f "$GEN_FILE" "$REC" "$JOURNAL" || {
    lock_release
    umask "$old_umask"
    echo "error: busy-state retirement failed for $ID" >&2
    exit 1
  }
  lock_release
  umask "$old_umask"
  exit 0
fi
replay_pending "$CURRENT" || {
  lock_release
  umask "$old_umask"
  echo "error: pending busy-state transition could not be replayed for $ID" >&2
  exit 1
}
OLD_SEQ=0
if [ -f "$REC" ]; then
  old_line=$(head -n 1 "$REC" 2>/dev/null || true)
  case "$old_line" in
    *" gen=$GEN "*)
      old_seq_field=${old_line##* seq=}
      old_seq_field=${old_seq_field%% *}
      case "$old_seq_field" in
        ''|*[!0-9]*) OLD_SEQ=0 ;;
        *) OLD_SEQ=$old_seq_field ;;
      esac
      ;;
  esac
fi
timestamp=$(date +%s)
commit_event "$GEN" $((OLD_SEQ + 1)) "$NEW_STATE" "$SOURCE" "$EVENT" "$timestamp" || {
  lock_release
  umask "$old_umask"
  echo "error: record write failed for $ID" >&2
  exit 1
}
lock_release
umask "$old_umask"
exit 0
