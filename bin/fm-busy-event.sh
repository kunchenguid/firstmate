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
#         --source S --event E [--run-token T]
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
  fm-busy-event.sh apply <state-dir> <id> <busy|idle|unknown> (--gen G | --current-gen) --source S --event E [--run-token T]
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
RUN_TOKEN=
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
    --run-token) RUN_TOKEN=${2:-}; shift 2 || usage ;;
    *) usage ;;
  esac
done
if [ "$CMD" != retire ]; then
  case "$NEW_STATE" in busy|idle|unknown) : ;; *) usage ;; esac
  fm_busy_token_valid "$SOURCE" || { echo "error: invalid --source" >&2; exit 1; }
  fm_busy_token_valid "$EVENT" || { echo "error: invalid --event" >&2; exit 1; }
  if [ -n "$RUN_TOKEN" ]; then
    fm_busy_token_valid "$RUN_TOKEN" || { echo "error: invalid --run-token" >&2; exit 1; }
  fi
fi

REC=$(fm_busy_record_path "$STATE" "$ID")
GEN_FILE=$(fm_busy_gen_path "$STATE" "$ID")
LOCK="$REC.lock"
LOCK_OWNER="$LOCK/owner"
FS_HELPER="$SCRIPT_DIR/fm-omp-fs.py"
LOCK_TOKEN=
LOCK_OWNER_PID=
LOCK_STATE_IDENTITY=
LOCK_IDENTITY=
LOCK_OWNER_IDENTITY=

busy_lock_snapshot() {
  command -v python3 >/dev/null 2>&1 || return 1
  [ -r "$FS_HELPER" ] || return 1
  python3 "$FS_HELPER" snapshot-lock "$STATE" "${LOCK##*/}" ""
}

busy_lock_remove_snapshot() {
  local snapshot=$1 state_identity lock_identity owner_identity owner_pid owner_token extra expected_owner
  read -r state_identity lock_identity owner_identity owner_pid owner_token extra <<< "$snapshot"
  [ -n "$state_identity" ] && [ -n "$lock_identity" ] && [ -n "$owner_identity" ] \
    && [ -n "$owner_pid" ] && [ -n "$owner_token" ] && [ -z "$extra" ] || return 1
  expected_owner=
  [ "$owner_identity" = orphan ] || expected_owner=$owner_identity
  python3 "$FS_HELPER" remove-lock "$STATE" "${LOCK##*/}" \
    "$state_identity" "$lock_identity" \
    "$expected_owner" \
    "$owner_pid" "$owner_token"
}

lock_owner_write() {
  LOCK_OWNER_PID=${BASHPID:-$$}
  LOCK_TOKEN="$LOCK_OWNER_PID.$RANDOM.$(date +%s)"
  ( umask 077; set -C; printf '%s %s\n' "$LOCK_OWNER_PID" "$LOCK_TOKEN" > "$LOCK_OWNER" )
}

lock_owner_status() {
  local snapshot state_identity lock_identity owner_identity owner_pid owner_token extra
  snapshot=$(busy_lock_snapshot) || { printf 'invalid\n'; return 0; }
  read -r state_identity lock_identity owner_identity owner_pid owner_token extra <<< "$snapshot"
  if [ -z "$state_identity" ] || [ -z "$lock_identity" ] || [ -z "$owner_identity" ] \
    || [ -z "$owner_pid" ] || [ -z "$owner_token" ] || [ -n "$extra" ]; then
    printf 'invalid\n'
    return 0
  fi
  if [ "$owner_identity" = orphan ]; then
    printf 'orphan\n'
    return 0
  fi
  case "$owner_pid" in *[!0-9]*) printf 'invalid\n'; return 0 ;; esac
  if [ "$owner_pid" -le 0 ] 2>/dev/null; then
    printf 'invalid\n'
    return 0
  fi
  if kill -0 "$owner_pid" 2>/dev/null; then printf 'live\n'; else printf 'dead\n'; fi
}

# Serialize writers. The lock protects seq advancement and the sidecar/record
# pair; a holder that died mid-write is broken after FM_BUSY_LOCK_STALE_SECS.
lock_acquire() {
  local tries=0 now mtime age owner_status snapshot state_identity lock_identity owner_identity owner_pid owner_token extra
  while true; do
    if mkdir "$LOCK" 2>/dev/null; then
      if lock_owner_write && snapshot=$(busy_lock_snapshot); then
        read -r state_identity lock_identity owner_identity owner_pid owner_token extra <<< "$snapshot"
        if [ -n "$state_identity" ] && [ -n "$lock_identity" ] && [ "$owner_identity" != orphan ] \
          && [ -n "$owner_pid" ] && [ -n "$owner_token" ] && [ -z "$extra" ]; then
          LOCK_STATE_IDENTITY=$state_identity
          LOCK_IDENTITY=$lock_identity
          LOCK_OWNER_IDENTITY=$owner_identity
          LOCK_OWNER_PID=$owner_pid
          LOCK_TOKEN=$owner_token
        else
          busy_lock_remove_snapshot "$snapshot" >/dev/null 2>&1 || true
          return 1
        fi
        if [ -n "${FM_BUSY_TEST_LOCK_ACQUIRED_GATE:-}" ]; then
          : > "$FM_BUSY_TEST_LOCK_ACQUIRED_GATE.ready" || return 1
          while [ ! -e "$FM_BUSY_TEST_LOCK_ACQUIRED_GATE.release" ]; do sleep 0.01; done
        fi
        return 0
      fi
      snapshot=$(busy_lock_snapshot 2>/dev/null || true)
      [ -z "$snapshot" ] || busy_lock_remove_snapshot "$snapshot" >/dev/null 2>&1 || true
      return 1
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 40 ]; then
      [ -d "$LOCK" ] && [ ! -L "$LOCK" ] || return 1
      now=$(date +%s)
      mtime=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo "$now")
      age=$((now - mtime))
      owner_status=$(lock_owner_status)
      if [ "$age" -ge "${FM_BUSY_LOCK_STALE_SECS:-5}" ] \
        && { [ "$owner_status" = dead ] || [ "$owner_status" = orphan ]; }; then
        snapshot=$(busy_lock_snapshot) || return 1
        busy_lock_remove_snapshot "$snapshot" || return 1
        tries=0
        continue
      fi
      echo "error: busy-state lock timeout for $ID" >&2
      return 1
    fi
    sleep 0.05
  done
  return 0
}

lock_release() {
  local snapshot state_identity lock_identity owner_identity owner_pid owner_token extra
  [ -n "$LOCK_STATE_IDENTITY" ] && [ -n "$LOCK_IDENTITY" ] && [ -n "$LOCK_OWNER_IDENTITY" ] || return 0
  snapshot=$(busy_lock_snapshot 2>/dev/null) || return 0
  read -r state_identity lock_identity owner_identity owner_pid owner_token extra <<< "$snapshot"
  [ "$state_identity" = "$LOCK_STATE_IDENTITY" ] \
    && [ "$lock_identity" = "$LOCK_IDENTITY" ] \
    && [ "$owner_identity" = "$LOCK_OWNER_IDENTITY" ] \
    && [ "$owner_pid" = "$LOCK_OWNER_PID" ] \
    && [ "$owner_token" = "$LOCK_TOKEN" ] \
    && [ -z "$extra" ] || return 0
  busy_lock_remove_snapshot "$snapshot" || return 1
  LOCK_STATE_IDENTITY=
  LOCK_IDENTITY=
  LOCK_OWNER_IDENTITY=
}

write_record() {  # <gen> <seq>
  local tmp
  tmp="$REC.tmp.$$"
  printf 'v1 gen=%s seq=%s state=%s source=%s event=%s ts=%s\n' \
    "$1" "$2" "$NEW_STATE" "$SOURCE" "$EVENT" "$(date +%s)" > "$tmp" || return 1
  mv -f "$tmp" "$REC"
}

old_umask=$(umask)
umask 077

if [ "$CMD" = arm ]; then
  GEN="g$(date +%s).$$.$RANDOM"
  lock_acquire || exit 1
  {
    printf '%s\n' "$GEN" > "$GEN_FILE.tmp.$$" && mv -f "$GEN_FILE.tmp.$$" "$GEN_FILE" \
      && write_record "$GEN" 1
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
    rm -f "$REC" || {
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
  rm -f "$GEN_FILE" "$REC" || {
    lock_release
    umask "$old_umask"
    echo "error: busy-state retirement failed for $ID" >&2
    exit 1
  }
  lock_release
  umask "$old_umask"
  exit 0
fi
if [ -n "$RUN_TOKEN" ]; then
  CURRENT_RUN=$(fm_busy_current_run_token "$STATE" "$ID") || {
    lock_release
    umask "$old_umask"
    echo "error: no current OMP run token for $ID" >&2
    exit 1
  }
  if [ "$RUN_TOKEN" != "$CURRENT_RUN" ]; then
    lock_release
    umask "$old_umask"
    echo "error: stale OMP run token for $ID (event rejected)" >&2
    exit 1
  fi
fi
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
write_record "$GEN" $((OLD_SEQ + 1)) || {
  lock_release
  umask "$old_umask"
  echo "error: record write failed for $ID" >&2
  exit 1
}
lock_release
umask "$old_umask"
exit 0
