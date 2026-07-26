#!/usr/bin/env bash
# Acquire, inspect, or atomically reclaim the per-home firstmate session lock.
# A normal session owner is the harness (agent) process PID found by walking
# the shell's ancestry, which lives as long as the firstmate session - unlike
# the transient subshell PID of any one tool call.
# When that process tree cannot be inspected, Codex may instead use its stable
# CODEX_THREAD_ID as codex-thread:<id>.
#
# Machine-readable acquisition outcomes are printed as LOCK_RESULT=<result>:
#   OWNED               exit 0  - this session owns the lock
#   LIVE_OTHER          exit 10 - a different live harness is proven
#   STALE_RECLAIMABLE   exit 11 - the recorded numeric owner is proven stale
#   IDENTITY_UNAVAILABLE exit 12 - ownership or liveness cannot be proven
#   RECLAIM_BUSY        exit 13 - the reclaim mutex is temporarily held; retry
#
# Every reclaim path emits LOCK_RESULT= before exiting, including refused
# --expected mismatches and mid-mutex rechecks that reclassify the new state.
#
# Mutating commands additionally serialize on state/.lock.acquire so
# concurrent acquisitions admit exactly one winner, probe state/ writability
# before taking any lock, refuse a lock that is not a regular file, and verify
# the published owner by reading the lock back after every write.
#
# Short internal mutexes (state/.lock.acquire and state/.lock-reclaim):
#   Preferred form is a kernel flock(2) on a regular file, taken through a
#   small perl helper: macOS has flock(2) but ships no flock(1) CLI, and perl
#   is already a soft dependency of bin/fm-wake-lib.sh. The kernel releases
#   the lock automatically when the holding process dies, so a crashed holder
#   can never leave an orphaned mutex; a leftover mutex file is unlocked and
#   harmless. FM_LOCK_NO_FLOCK=1 forces the fallback below.
#   Fallback (helper unavailable, or a legacy directory-form mutex already
#   occupies the path): the original mkdir/symlink locks. state/.lock.acquire
#   uses the fm-wake-lib lock; state/.lock-reclaim uses a mkdir mutex with
#   owner PID and start timestamp written after create. Only a provably
#   abandoned fallback mutex may be removed and retaken: the recorded owner
#   PID is dead, or (legacy/no-pid) the directory age meets the mid-acquire
#   threshold. A live owner is never overridden.
#   Emergency removal of a fallback (directory-form) reclaim mutex, only when
#   the owner is proven dead or missing after age:
#     pid=$(cat state/.lock-reclaim/pid 2>/dev/null)
#     if ! kill -0 "$pid" 2>/dev/null; then rm -rf state/.lock-reclaim; fi
#   Prefer re-running fm-lock.sh so the same proof runs automatically.
#
# The main session lock state/.lock deliberately stays a durable on-disk
# identity, never flock-based: it must outlive the individual commands that
# read and write it, which an fd-held kernel lock cannot do.
#
# Usage: fm-lock.sh
#          Acquire a free lock or atomically reclaim a proven-stale lock.
#        fm-lock.sh status
#          Print the current typed state without mutating the lock; always exit 0.
#        fm-lock.sh reclaim --expected <owner> [--confirmed-closed]
#          Compare and replace exactly <owner> under the reclaim mutex.
#          --confirmed-closed is accepted only for a codex-thread owner and only
#          after the captain explicitly confirms that its old window is closed.
# There is deliberately no unconditional clear command.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
RECLAIM_LOCK="$STATE/.lock-reclaim"
CLAIM_LOCK="$STATE/.lock.acquire"
# Seconds a no-pid or mid-write reclaim mutex must age before it is treated as
# abandoned (same mid-acquire idea as bin/fm-wake-lib.sh's FM_LOCK_STALE_AFTER).
RECLAIM_MUTEX_STALE_AFTER="${FM_RECLAIM_MUTEX_STALE_AFTER:-2}"
# Short busy-mutex retries for free-claim and stale reclaim (not live takeover).
RECLAIM_BUSY_RETRIES="${FM_RECLAIM_BUSY_RETRIES:-4}"
RECLAIM_BUSY_SLEEP_SECS="${FM_RECLAIM_BUSY_SLEEP_SECS:-0.05}"

EXIT_LIVE_OTHER=10
EXIT_STALE_RECLAIMABLE=11
EXIT_IDENTITY_UNAVAILABLE=12
EXIT_RECLAIM_BUSY=13

mkdir -p "$STATE" 2>/dev/null || {
  printf 'LOCK_RESULT=IDENTITY_UNAVAILABLE\n'
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit "$EXIT_IDENTITY_UNAVAILABLE"
}

# Harness identity (FM_HARNESS_RE, holder liveness, self-ownership) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract. The typed walker below reuses FM_HARNESS_RE but also
# distinguishes an unreadable process tree from a genuinely absent harness,
# which the Codex thread-identity fallback needs.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

CURRENT_OWNER=
PROCESS_TREE_UNAVAILABLE=0
LOCK_OWNER=
LOCK_FILE_INVALID=0
HOLDER_RESULT=
HOLDER_PROOF=
HOLDER_DETAIL=
PID_IDENTITY=
PID_IDENTITY_DETAIL=
RECLAIM_HELD=0
RECLAIM_LOCK_MODE=
CLAIM_LOCK_HELD=0
CLAIM_LOCK_MODE=

# flock(2) helper for the two short internal mutexes: bash keeps the mutex
# file open on a dedicated fd (8 = claim, 9 = reclaim) so the kernel holds the
# lock exactly as long as this process lives; the perl child only performs the
# flock(2) call on the inherited fd. After acquiring, the helper rechecks that
# the fd still names the on-disk path (same inode, regular non-symlink file)
# so an unlink-and-recreate race cannot let two holders share the mutex.
# Exit: 0 acquired, 1 busy, 2 path identity changed, 3 fd unusable.
# shellcheck disable=SC2016 # perl source; the $-expressions are perl's own.
FLOCK_PERL='
use Fcntl qw(:flock);
my ($fd, $path) = @ARGV;
open(my $fh, "+<&=", $fd + 0) or exit 3;
flock($fh, LOCK_EX | LOCK_NB) or exit 1;
my @held = stat($fh) or exit 2;
my @disk = lstat($path) or exit 2;
exit 2 unless -f _;
exit 2 unless $held[0] == $disk[0] && $held[1] == $disk[1];
exit 0;
'

flock_open_fd() {
  case "$1" in
    8) exec 8<> "$2" ;;
    9) exec 9<> "$2" ;;
    *) return 1 ;;
  esac
} 2>/dev/null

flock_close_fd() {
  case "$1" in
    8) exec 8>&- ;;
    9) exec 9>&- ;;
  esac
} 2>/dev/null

# 0 = the perl flock(2) helper provably works here; 1 = use the mkdir
# fallbacks. Probed once per invocation against a scratch file in state/.
FLOCK_USABLE=
flock_available() {
  local probe
  if [ -n "$FLOCK_USABLE" ]; then
    return "$FLOCK_USABLE"
  fi
  FLOCK_USABLE=1
  if [ "${FM_LOCK_NO_FLOCK:-0}" != 1 ] && command -v perl >/dev/null 2>&1; then
    probe=$(mktemp "$STATE/.lock-flock-probe.XXXXXX" 2>/dev/null) || probe=
    if [ -n "$probe" ]; then
      if (flock_open_fd 8 "$probe" && perl -e "$FLOCK_PERL" 8 "$probe") 2>/dev/null; then
        FLOCK_USABLE=0
      fi
      rm -f "$probe" 2>/dev/null || true
    fi
  fi
  return "$FLOCK_USABLE"
}

# Try the flock(2) mutex at $1 on fd $2.
# 0 = held; 1 = busy or lost a recreate race (retry); 2 = the path holds a
# legacy directory-form mutex or cannot be opened (use the mkdir path).
flock_try() {
  local path=$1 fd=$2 rc=0
  if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
    return 2
  fi
  flock_open_fd "$fd" "$path" || return 2
  perl -e "$FLOCK_PERL" "$fd" "$path" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  flock_close_fd "$fd"
  if [ "$rc" -eq 3 ]; then
    return 2
  fi
  return 1
}

# Unlink while still holding the lock, then close: a rival that already opened
# the removed inode fails its post-flock identity recheck instead of sharing
# the mutex with the next holder's fresh file.
flock_release() {
  local path=$1 fd=$2
  rm -f "$path" 2>/dev/null || true
  flock_close_fd "$fd"
}

usage() {
  cat <<'EOF'
Usage: fm-lock.sh
         Acquire a free lock or atomically reclaim a proven-stale lock.
       fm-lock.sh status
         Print the current typed state without mutating the lock; always exit 0.
       fm-lock.sh reclaim --expected <owner> [--confirmed-closed]
         Compare and replace exactly <owner> under the reclaim mutex.
         --confirmed-closed is accepted only for a codex-thread owner and only
         after the captain explicitly confirms that its old window is closed.
There is deliberately no unconditional clear command.
EOF
}

valid_codex_thread_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

process_owner() {
  local pid=$$ comm base args parent
  CURRENT_OWNER=
  PROCESS_TREE_UNAVAILABLE=0

  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || {
      PROCESS_TREE_UNAVAILABLE=1
      return 1
    }
    base=$(basename "$comm")
    if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
      CURRENT_OWNER=$pid
      return 0
    fi
    case "$comm" in
      *node*|*python*)
        args=$(ps -o args= -p "$pid" 2>/dev/null) || {
          PROCESS_TREE_UNAVAILABLE=1
          return 1
        }
        if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
          CURRENT_OWNER=$pid
          return 0
        fi
        ;;
    esac
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || {
      PROCESS_TREE_UNAVAILABLE=1
      return 1
    }
    case "$parent" in
      ''|*[!0-9]*|0|1) return 1 ;;
      *) pid=$parent ;;
    esac
  done
  return 1
}

current_owner() {
  CURRENT_OWNER=
  if process_owner; then
    return 0
  fi
  if [ "$PROCESS_TREE_UNAVAILABLE" -eq 1 ] \
    && valid_codex_thread_id "${CODEX_THREAD_ID:-}"; then
    CURRENT_OWNER="codex-thread:$CODEX_THREAD_ID"
    return 0
  fi
  return 1
}

read_lock() {
  LOCK_OWNER=
  LOCK_FILE_INVALID=0
  if [ -L "$LOCK" ] || { [ -e "$LOCK" ] && [ ! -f "$LOCK" ]; }; then
    LOCK_FILE_INVALID=1
    return 0
  fi
  [ -f "$LOCK" ] || return 1
  IFS= read -r LOCK_OWNER < "$LOCK" || true
  return 0
}

inspect_pid_identity() {
  local owner=$1 comm base args
  PID_IDENTITY=
  PID_IDENTITY_DETAIL=

  comm=$(ps -o comm= -p "$owner" 2>/dev/null) || {
    PID_IDENTITY=UNAVAILABLE
    PID_IDENTITY_DETAIL="pid $owner is alive but its process identity cannot be read"
    return 0
  }
  base=$(basename "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    PID_IDENTITY=HARNESS
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$owner" 2>/dev/null) || {
        PID_IDENTITY=UNAVAILABLE
        PID_IDENTITY_DETAIL="pid $owner is alive but its process arguments cannot be read"
        return 0
      }
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        PID_IDENTITY=HARNESS
        return 0
      fi
      ;;
  esac
  PID_IDENTITY=NOT_HARNESS
}

classify_live_harness_pid() {
  local owner=$1
  if current_owner && [ "$CURRENT_OWNER" = "$owner" ]; then
    HOLDER_RESULT=OWNED
    HOLDER_PROOF='current-harness-pid'
    HOLDER_DETAIL="current harness pid $owner"
  elif [ -n "$CURRENT_OWNER" ] && printf '%s' "$CURRENT_OWNER" | grep -qE '^[0-9]+$'; then
    HOLDER_RESULT=LIVE_OTHER
    HOLDER_PROOF='live-harness-pid'
    HOLDER_DETAIL="another live harness pid $owner"
  else
    HOLDER_RESULT=IDENTITY_UNAVAILABLE
    HOLDER_PROOF='current-identity-unavailable'
    HOLDER_DETAIL="pid $owner is a live harness but this session identity cannot be compared safely"
  fi
}

classify_owner() {
  local owner=$1
  HOLDER_RESULT=
  HOLDER_PROOF=
  HOLDER_DETAIL=

  case "$owner" in
    codex-thread:*)
      if [ "$owner" = "codex-thread:${CODEX_THREAD_ID:-}" ] \
        && valid_codex_thread_id "${CODEX_THREAD_ID:-}"; then
        HOLDER_RESULT=OWNED
        HOLDER_PROOF='current-codex-thread'
        HOLDER_DETAIL="current Codex thread"
      else
        HOLDER_RESULT=IDENTITY_UNAVAILABLE
        HOLDER_PROOF='foreign-codex-thread-unverifiable'
        HOLDER_DETAIL="Codex thread $owner has no verifiable lifecycle signal"
      fi
      return 0
      ;;
    ''|*[!0-9]*)
      HOLDER_RESULT=IDENTITY_UNAVAILABLE
      HOLDER_PROOF='invalid-owner'
      HOLDER_DETAIL="lock owner '$owner' is not a supported identity"
      return 0
      ;;
  esac

  if ! kill -0 "$owner" 2>/dev/null; then
    HOLDER_RESULT=STALE_RECLAIMABLE
    HOLDER_PROOF='pid-dead'
    HOLDER_DETAIL="pid $owner is not alive"
    return 0
  fi

  inspect_pid_identity "$owner"
  case "$PID_IDENTITY" in
    HARNESS)
      classify_live_harness_pid "$owner"
      ;;
    UNAVAILABLE)
      HOLDER_RESULT=IDENTITY_UNAVAILABLE
      HOLDER_PROOF='pid-identity-unreadable'
      HOLDER_DETAIL=$PID_IDENTITY_DETAIL
      ;;
    *)
      HOLDER_RESULT=STALE_RECLAIMABLE
      HOLDER_PROOF='pid-not-harness'
      HOLDER_DETAIL="pid $owner is alive but is not a harness process"
      ;;
  esac
}

# Classify the on-disk lock read by read_lock, refusing a lock that is not a
# regular readable file instead of interpreting its owner.
classify_lock_owner() {
  if [ "$LOCK_FILE_INVALID" -eq 1 ]; then
    HOLDER_RESULT=IDENTITY_UNAVAILABLE
    HOLDER_PROOF='lock-not-regular-file'
    HOLDER_DETAIL='session lock is not a regular file; operate read-only until resolved'
    return 0
  fi
  classify_owner "$LOCK_OWNER"
}

emit_result() {
  local result=$1 detail=$2
  printf 'LOCK_RESULT=%s\n' "$result"
  case "$result" in
    OWNED)
      case "$CURRENT_OWNER" in
        codex-thread:*) printf 'lock acquired: Codex thread %s\n' "${CURRENT_OWNER#codex-thread:}" ;;
        *) printf 'lock acquired: harness pid %s\n' "$CURRENT_OWNER" ;;
      esac
      ;;
    LIVE_OTHER)
      printf 'error: another live firstmate session holds the lock (%s); operate read-only until resolved\n' "$detail" >&2
      ;;
    STALE_RECLAIMABLE)
      printf 'lock: stale and reclaimable (%s)\n' "$detail"
      ;;
    IDENTITY_UNAVAILABLE)
      printf 'error: lock identity unavailable (%s); no live rival or stale owner has been proven\n' "$detail" >&2
      ;;
    RECLAIM_BUSY)
      printf 'error: reclaim mutex busy (%s); retry briefly and re-check bin/fm-lock.sh status\n' "$detail" >&2
      ;;
  esac
}

result_exit_code() {
  case "$1" in
    OWNED) return 0 ;;
    LIVE_OTHER) return "$EXIT_LIVE_OTHER" ;;
    STALE_RECLAIMABLE) return "$EXIT_STALE_RECLAIMABLE" ;;
    IDENTITY_UNAVAILABLE) return "$EXIT_IDENTITY_UNAVAILABLE" ;;
    RECLAIM_BUSY) return "$EXIT_RECLAIM_BUSY" ;;
    *) return "$EXIT_IDENTITY_UNAVAILABLE" ;;
  esac
}

emit_classified_lock() {
  local detail_prefix=$1
  if ! read_lock; then
    emit_result IDENTITY_UNAVAILABLE "${detail_prefix}: lock is free"
    return "$EXIT_IDENTITY_UNAVAILABLE"
  fi
  classify_lock_owner
  if [ "$HOLDER_RESULT" = OWNED ]; then
    current_owner || CURRENT_OWNER=$LOCK_OWNER
  fi
  emit_result "$HOLDER_RESULT" "${detail_prefix}: $HOLDER_DETAIL"
  result_exit_code "$HOLDER_RESULT"
  return $?
}

reclaim_mutex_age() {
  local m now
  if [ "$(uname)" = Darwin ]; then
    m=$(stat -f %m "$RECLAIM_LOCK" 2>/dev/null) || return 1
  else
    m=$(stat -c %Y "$RECLAIM_LOCK" 2>/dev/null) || return 1
  fi
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((now - m))"
}

# Provably abandoned: live owner PID is never overridden. Missing/invalid PID is
# treated like wake-lib mid-acquire: only after RECLAIM_MUTEX_STALE_AFTER seconds.
reclaim_mutex_is_provably_abandoned() {
  local pid age min_age
  [ -d "$RECLAIM_LOCK" ] || [ -L "$RECLAIM_LOCK" ] || return 1
  pid=$(cat "$RECLAIM_LOCK/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*)
      min_age=$RECLAIM_MUTEX_STALE_AFTER
      case "$min_age" in ''|*[!0-9]*) min_age=2 ;; esac
      [ "$min_age" -lt 2 ] && min_age=2
      # Allow test overrides that deliberately set 0 to force no-pid recovery.
      if [ "${FM_RECLAIM_MUTEX_STALE_AFTER:-}" = 0 ]; then
        min_age=0
      fi
      if ! age=$(reclaim_mutex_age); then
        return 1
      fi
      [ "$age" -ge "$min_age" ]
      return $?
      ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  return 0
}

remove_reclaim_mutex() {
  rm -f "$RECLAIM_LOCK/pid" "$RECLAIM_LOCK/started" 2>/dev/null || true
  rmdir "$RECLAIM_LOCK" 2>/dev/null || true
  # Legacy/malformed leftover: directory with unexpected files.
  if [ -d "$RECLAIM_LOCK" ] || [ -L "$RECLAIM_LOCK" ]; then
    rm -rf "$RECLAIM_LOCK" 2>/dev/null || true
  fi
}

write_reclaim_owner() {
  local mypid=${BASHPID:-$$} back
  if ! printf '%s\n' "$mypid" > "$RECLAIM_LOCK/pid"; then
    return 1
  fi
  date +%s > "$RECLAIM_LOCK/started" 2>/dev/null || true
  back=$(cat "$RECLAIM_LOCK/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

release_reclaim_lock() {
  local recorded mypid=${BASHPID:-$$}
  if [ "$RECLAIM_HELD" -ne 1 ]; then
    return 0
  fi
  if [ "$RECLAIM_LOCK_MODE" = flock ]; then
    flock_release "$RECLAIM_LOCK" 9
  else
    recorded=$(cat "$RECLAIM_LOCK/pid" 2>/dev/null || true)
    if [ "$recorded" = "$mypid" ]; then
      remove_reclaim_mutex
    fi
  fi
  RECLAIM_HELD=0
  RECLAIM_LOCK_MODE=
}

# Returns 0 held, 1 busy (live or mid-acquire), after one abandon-and-retry.
# The flock(2) form is preferred; the mkdir form remains for a missing helper
# and as the recovery path for a legacy directory-form mutex already on disk.
acquire_reclaim_lock() {
  local attempt=0 flock_rc
  RECLAIM_LOCK_MODE=
  while [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))
    if flock_available; then
      flock_rc=0
      flock_try "$RECLAIM_LOCK" 9 || flock_rc=$?
      if [ "$flock_rc" -eq 0 ]; then
        RECLAIM_HELD=1
        RECLAIM_LOCK_MODE=flock
        return 0
      fi
      if [ "$flock_rc" -eq 1 ]; then
        return 1
      fi
      # Legacy directory-form mutex on disk: recover it through the same
      # abandoned-owner proof as the fallback, then retry the flock form.
      if reclaim_mutex_is_provably_abandoned; then
        remove_reclaim_mutex
        continue
      fi
      return 1
    fi
    if mkdir "$RECLAIM_LOCK" 2>/dev/null; then
      if write_reclaim_owner; then
        RECLAIM_HELD=1
        RECLAIM_LOCK_MODE='mkdir'
        return 0
      fi
      remove_reclaim_mutex
      return 1
    fi
    if reclaim_mutex_is_provably_abandoned; then
      remove_reclaim_mutex
      continue
    fi
    return 1
  done
  return 1
}

acquire_reclaim_lock_with_busy_retry() {
  local attempt=0 max=$RECLAIM_BUSY_RETRIES
  case "$max" in ''|*[!0-9]*) max=4 ;; esac
  while [ "$attempt" -le "$max" ]; do
    if acquire_reclaim_lock; then
      return 0
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -le "$max" ] || break
    sleep "$RECLAIM_BUSY_SLEEP_SECS" 2>/dev/null || sleep 1
  done
  return 1
}

# Publish $1 as the lock owner atomically, then verify the publication by
# reading the lock back; a symlinked, missing, or mismatched lock fails.
write_owner() {
  local owner=$1 tmp="$STATE/.lock.tmp.$$" back
  if ! { printf '%s\n' "$owner" > "$tmp"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  if ! mv -f "$tmp" "$LOCK" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  [ -f "$LOCK" ] && [ ! -L "$LOCK" ] || return 1
  back=$(cat "$LOCK" 2>/dev/null) || return 1
  [ "$back" = "$owner" ]
}

release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    if [ "$CLAIM_LOCK_MODE" = flock ]; then
      flock_release "$CLAIM_LOCK" 8
    else
      fm_lock_release "$CLAIM_LOCK"
    fi
    CLAIM_LOCK_HELD=0
    CLAIM_LOCK_MODE=
  fi
}

# Try the acquisition mutex once: preferred flock(2) form, with the
# fm-wake-lib lock as fallback and as the recovery path for a legacy
# mkdir/symlink-form lock already occupying the path.
# 0 = held, 1 = busy (retry), 2 = flock-form mutex file present but the
# helper is unavailable, so waiting can never resolve it.
claim_lock_try() {
  local flock_rc
  CLAIM_LOCK_MODE=
  if flock_available; then
    flock_rc=0
    flock_try "$CLAIM_LOCK" 8 || flock_rc=$?
    if [ "$flock_rc" -eq 0 ]; then
      CLAIM_LOCK_MODE=flock
      return 0
    fi
    if [ "$flock_rc" -eq 1 ]; then
      return 1
    fi
  fi
  if fm_lock_try_acquire "$CLAIM_LOCK"; then
    CLAIM_LOCK_MODE='mkdir'
    return 0
  fi
  if ! flock_available && [ ! -L "$CLAIM_LOCK" ] && [ -f "$CLAIM_LOCK" ]; then
    return 2
  fi
  return 1
}

# Gate every mutating command: prove state/ is writable before taking any lock,
# then serialize the whole classify-and-write flow on the acquisition lock so
# concurrent sessions admit exactly one winner.
prepare_mutation() {
  local probe claim_rc
  probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
    emit_result IDENTITY_UNAVAILABLE "cannot write session lock; operate read-only until resolved"
    exit "$EXIT_IDENTITY_UNAVAILABLE"
  }
  rm -f "$probe" 2>/dev/null || {
    emit_result IDENTITY_UNAVAILABLE "cannot clean session-lock publication probe; operate read-only until resolved"
    exit "$EXIT_IDENTITY_UNAVAILABLE"
  }
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  while :; do
    claim_rc=0
    claim_lock_try || claim_rc=$?
    if [ "$claim_rc" -eq 0 ]; then
      break
    fi
    if [ "$claim_rc" -eq 2 ]; then
      emit_result IDENTITY_UNAVAILABLE "state/.lock.acquire is a flock-form mutex file but the flock(2) helper is unavailable; operate read-only until resolved"
      exit "$EXIT_IDENTITY_UNAVAILABLE"
    fi
    sleep 0.1
  done
  CLAIM_LOCK_HELD=1
}

# claim_free: 0 success, 2 lock appeared, 3 reclaim mutex busy, 1 other failure.
claim_free() {
  if ! acquire_reclaim_lock_with_busy_retry; then
    return 3
  fi
  if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
    release_reclaim_lock
    return 2
  fi
  if ! write_owner "$CURRENT_OWNER"; then
    release_reclaim_lock
    return 1
  fi
  release_reclaim_lock
  return 0
}

reclaim_expected() {
  local expected=$1 confirmed_closed=$2 initial_proof current

  if ! read_lock; then
    emit_result IDENTITY_UNAVAILABLE "reclaim refused; expected owner $expected but the lock is free"
    return "$EXIT_IDENTITY_UNAVAILABLE"
  fi
  if [ "$LOCK_FILE_INVALID" -eq 1 ] || [ "$LOCK_OWNER" != "$expected" ]; then
    classify_lock_owner
    if [ "$HOLDER_RESULT" = OWNED ]; then
      current_owner || CURRENT_OWNER=$LOCK_OWNER
    fi
    emit_result "$HOLDER_RESULT" "reclaim refused; expected owner $expected but found $LOCK_OWNER ($HOLDER_DETAIL)"
    result_exit_code "$HOLDER_RESULT"
    return $?
  fi

  classify_owner "$expected"
  if [ "$HOLDER_RESULT" = OWNED ]; then
    current_owner || CURRENT_OWNER=$expected
    emit_result OWNED "$HOLDER_DETAIL"
    return 0
  fi
  if [ "$HOLDER_RESULT" = STALE_RECLAIMABLE ]; then
    initial_proof=$HOLDER_PROOF
  elif [ "$HOLDER_RESULT" = IDENTITY_UNAVAILABLE ] \
    && [ "$confirmed_closed" -eq 1 ] \
    && [ "${expected#codex-thread:}" != "$expected" ]; then
    initial_proof=confirmed-closed-codex-thread
  else
    emit_result "$HOLDER_RESULT" "$HOLDER_DETAIL"
    result_exit_code "$HOLDER_RESULT"
    return $?
  fi

  if ! current_owner; then
    emit_result IDENTITY_UNAVAILABLE "cannot identify this session through readable process ancestry or CODEX_THREAD_ID"
    return "$EXIT_IDENTITY_UNAVAILABLE"
  fi
  current=$CURRENT_OWNER

  if ! acquire_reclaim_lock_with_busy_retry; then
    emit_result RECLAIM_BUSY "another reclaim operation holds state/.lock-reclaim"
    return "$EXIT_RECLAIM_BUSY"
  fi
  if ! read_lock || [ "$LOCK_FILE_INVALID" -eq 1 ] || [ "$LOCK_OWNER" != "$expected" ]; then
    release_reclaim_lock
    emit_classified_lock "reclaim refused; owner changed while waiting for the reclaim mutex"
    return $?
  fi

  classify_owner "$expected"
  if [ "$initial_proof" = confirmed-closed-codex-thread ]; then
    if [ "$HOLDER_RESULT" != IDENTITY_UNAVAILABLE ] \
      || [ "$HOLDER_PROOF" != foreign-codex-thread-unverifiable ]; then
      release_reclaim_lock
      emit_result "$HOLDER_RESULT" "reclaim refused; the confirmed Codex owner state changed during verification ($HOLDER_DETAIL)"
      result_exit_code "$HOLDER_RESULT"
      return $?
    fi
  elif [ "$HOLDER_RESULT" != STALE_RECLAIMABLE ] \
    || [ "$HOLDER_PROOF" != "$initial_proof" ]; then
    release_reclaim_lock
    emit_result "$HOLDER_RESULT" "reclaim refused; the stale-owner proof changed during verification ($HOLDER_DETAIL)"
    result_exit_code "$HOLDER_RESULT"
    return $?
  fi

  CURRENT_OWNER=$current
  if ! write_owner "$CURRENT_OWNER"; then
    release_reclaim_lock
    emit_result IDENTITY_UNAVAILABLE "failed to write the new lock owner"
    return "$EXIT_IDENTITY_UNAVAILABLE"
  fi
  release_reclaim_lock
  emit_result OWNED "reclaimed from $expected"
  return 0
}

status_lock() {
  if ! read_lock; then
    printf 'lock: free\n'
    return 0
  fi
  classify_lock_owner
  if [ "$HOLDER_RESULT" = OWNED ]; then
    current_owner || CURRENT_OWNER=$LOCK_OWNER
  fi
  printf 'LOCK_RESULT=%s\n' "$HOLDER_RESULT"
  case "$HOLDER_RESULT" in
    OWNED) printf 'lock: owned by this session (%s)\n' "$HOLDER_DETAIL" ;;
    LIVE_OTHER) printf 'lock: held by live harness pid %s (%s)\n' "$LOCK_OWNER" "$HOLDER_DETAIL" ;;
    STALE_RECLAIMABLE) printf 'lock: stale and reclaimable (%s)\n' "$HOLDER_DETAIL" ;;
    IDENTITY_UNAVAILABLE) printf 'lock: identity unavailable (%s)\n' "$HOLDER_DETAIL" ;;
  esac
}

acquire_default() {
  local attempt=0 claim_rc
  while [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))
    if ! read_lock; then
      if ! current_owner; then
        emit_result IDENTITY_UNAVAILABLE "cannot identify this session through readable process ancestry or CODEX_THREAD_ID"
        return "$EXIT_IDENTITY_UNAVAILABLE"
      fi
      claim_rc=0
      claim_free || claim_rc=$?
      case "$claim_rc" in
        0)
          emit_result OWNED "new lock"
          return 0
          ;;
        2)
          continue
          ;;
        3)
          emit_result RECLAIM_BUSY "cannot acquire the reclaim mutex for a free lock"
          return "$EXIT_RECLAIM_BUSY"
          ;;
        *)
          emit_result IDENTITY_UNAVAILABLE "failed to write a free lock owner"
          return "$EXIT_IDENTITY_UNAVAILABLE"
          ;;
      esac
    fi

    classify_lock_owner
    case "$HOLDER_RESULT" in
      OWNED)
        current_owner || CURRENT_OWNER=$LOCK_OWNER
        emit_result OWNED "$HOLDER_DETAIL"
        return 0
        ;;
      LIVE_OTHER|IDENTITY_UNAVAILABLE)
        emit_result "$HOLDER_RESULT" "$HOLDER_DETAIL"
        result_exit_code "$HOLDER_RESULT"
        return $?
        ;;
      STALE_RECLAIMABLE)
        reclaim_expected "$LOCK_OWNER" 0
        return $?
        ;;
    esac
  done

  emit_result IDENTITY_UNAVAILABLE "lock ownership changed repeatedly during acquisition"
  return "$EXIT_IDENTITY_UNAVAILABLE"
}

trap 'release_reclaim_lock; release_claim_lock' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

case "${1:-}" in
  '')
    prepare_mutation
    acquire_default
    ;;
  status)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    status_lock
    ;;
  reclaim)
    shift
    expected=
    confirmed_closed=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --expected)
          [ "$#" -gt 1 ] || { echo "error: --expected requires an owner" >&2; exit 2; }
          expected=$2
          shift 2
          ;;
        --confirmed-closed)
          confirmed_closed=1
          shift
          ;;
        *)
          echo "error: unknown reclaim argument: $1" >&2
          usage >&2
          exit 2
          ;;
      esac
    done
    [ -n "$expected" ] || { echo "error: reclaim requires --expected <owner>" >&2; exit 2; }
    if [ "$confirmed_closed" -eq 1 ] && [ "${expected#codex-thread:}" = "$expected" ]; then
      echo "error: --confirmed-closed is valid only for a codex-thread owner" >&2
      exit 2
    fi
    prepare_mutation
    reclaim_expected "$expected" "$confirmed_closed"
    ;;
  clear)
    echo "error: unconditional clear is not supported; use reclaim --expected <owner>" >&2
    exit 2
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "error: unknown command: $1" >&2
    usage >&2
    exit 2
    ;;
esac
