#!/usr/bin/env bash
# Firstmate T3 primary park: home-local continuity that injects captain follow-ups
# via t3cli send when the watcher closes with an actionable wake.
#
# Usage:
#   fm-t3-primary-park.sh ensure   # start run loop if not already alive; return
#   fm-t3-primary-park.sh run      # foreground park loop (ensure's child)
#   fm-t3-primary-park.sh status   # print running|stopped
#
# Requires an active state/.t3-primary-binding. AFK makes the park inert.
# Desktop Cursor stop-hook park stands down while binding is active.
# See docs/t3-primary-supervision.md and docs/watcher-continuity.md Option B.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-t3-primary-lib.sh
. "$SCRIPT_DIR/fm-t3-primary-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

CMD=${1:-ensure}
GRACE=${FM_GUARD_GRACE:-300}
POLL=${FM_T3_PARK_POLL:-2}
ARM_ATTEMPTS=${FM_T3_PARK_ATTEMPTS:-2}
READY_TIMEOUT=${FM_T3_READY_TIMEOUT:-90}
LOOP_CEILING=${FM_T3_TURNEND_LOOP_CEILING:-180}
BLOCK_BUDGET=${FM_T3_TURNEND_BLOCK_BUDGET:-3}
LOCK_ATTEMPTS=${FM_T3_LOCK_ATTEMPTS:-50}

case "$POLL" in ''|*[!0-9]*|0) POLL=2 ;; esac
case "$ARM_ATTEMPTS" in 1|2|3) : ;; *) ARM_ATTEMPTS=2 ;; esac
case "$READY_TIMEOUT" in ''|*[!0-9]*|0) READY_TIMEOUT=90 ;; esac
case "$LOOP_CEILING" in ''|*[!0-9]*|0) LOOP_CEILING=180 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac
case "$LOCK_ATTEMPTS" in ''|*[!0-9]*|0) LOCK_ATTEMPTS=50 ;; esac

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

lock_acquire_bounded() {
  local lock=$1 attempt=0
  while [ "$attempt" -lt "$LOCK_ATTEMPTS" ]; do
    fm_lock_try_acquire "$lock" && return 0
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$LOCK_ATTEMPTS" ] && sleep 0.1
  done
  return 1
}

claim_park() {
  local seq tmp
  lock_acquire_bounded "$FM_T3_PARK_OWNER_LOCK" || return 1
  seq=$(sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$FM_T3_PARK_OWNER" 2>/dev/null || true)
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  PARK_SEQ=$((seq + 1))
  tmp="$FM_T3_PARK_OWNER.tmp.${BASHPID:-$$}"
  if ! printf 'seq=%s pid=%s updated_at=%s\n' "$PARK_SEQ" "${BASHPID:-$$}" "$(date +%s)" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$FM_T3_PARK_OWNER" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$FM_T3_PARK_OWNER_LOCK"
    return 1
  fi
  fm_lock_release "$FM_T3_PARK_OWNER_LOCK"
  return 0
}

park_still_ours() {
  local seq
  seq=$(sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$FM_T3_PARK_OWNER" 2>/dev/null || true)
  [ "$seq" = "$PARK_SEQ" ]
}

current_session_still_ours() {
  local owner
  owner=$(cat "$FM_T3_STATE/.lock" 2>/dev/null) || return 1
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  fm_session_lock_owned_by_self "$FM_T3_STATE"
}

loop_count_read() {
  local count
  LOOP_COUNT=0
  [ -f "$FM_T3_LOOP_FILE" ] || return 0
  count=$(sed -n '1s/^count=//p' "$FM_T3_LOOP_FILE" 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  LOOP_COUNT=$count
}

loop_count_write() {
  local tmp="$FM_T3_LOOP_FILE.tmp.$$"
  printf 'count=%s\n' "$1" > "$tmp" 2>/dev/null && mv -f "$tmp" "$FM_T3_LOOP_FILE"
  rm -f "$tmp" 2>/dev/null || true
}

loop_count_reset() {
  rm -f "$FM_T3_LOOP_FILE" 2>/dev/null || true
}

budget_read() {
  BUDGET_COUNT=0
  [ -f "$FM_T3_BUDGET_FILE" ] || return 0
  BUDGET_COUNT=$(sed -n '1s/^count=//p' "$FM_T3_BUDGET_FILE" 2>/dev/null || true)
  case "$BUDGET_COUNT" in ''|*[!0-9]*) BUDGET_COUNT=0 ;; esac
}

budget_write() {
  local tmp="$FM_T3_BUDGET_FILE.tmp.$$"
  printf 'count=%s\n' "$1" > "$tmp" 2>/dev/null && mv -f "$tmp" "$FM_T3_BUDGET_FILE"
  rm -f "$tmp" 2>/dev/null || true
}

budget_reset() {
  rm -f "$FM_T3_BUDGET_FILE" 2>/dev/null || true
}

inject_followup() {  # <kind> <body>
  local kind=$1 body=$2 thread encoded status_rc
  park_still_ours || return 1
  [ -e "$FM_T3_STATE/.afk" ] && return 1
  thread=$(fm_t3_primary_binding_get thread_id) || return 1

  status_rc=0
  fm_t3_primary_wait_ready "$thread" "$READY_TIMEOUT" || status_rc=$?
  if [ "$status_rc" -eq 2 ]; then
    # Thread running (captain turn or other) - stand down; durable queue keeps wake.
    printf 't3-primary-park: stand down (thread running)\n'
    return 1
  fi
  if [ "$status_rc" -ne 0 ]; then
    printf 't3-primary-park: ready wait failed\n'
    return 1
  fi

  encoded=$(fm_t3_primary_encode_followup "$kind" "$body") || return 1
  if ! fm_t3_primary_send "$thread" "$encoded" >/dev/null 2>&1; then
    printf 't3-primary-park: send failed\n'
    return 1
  fi
  printf 't3-primary-park: injected kind=%s thread=%s\n' "$kind" "$thread"
  return 0
}

park_lock_held_by_live() {
  local lock=$FM_T3_PARK_LOCK owner pid identity
  [ -e "$lock" ] || [ -L "$lock" ] || return 1
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock" 2>/dev/null) || return 1
    case "$owner" in
      /*) ;;
      *) owner="$(dirname "$lock")/$owner" ;;
    esac
  else
    owner=$lock
  fi
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_pid_alive "$pid" || return 1
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$identity" ] || return 1
  fi
  return 0
}

ensure_park() {
  fm_t3_primary_paths
  mkdir -p "$FM_T3_STATE" || return 1
  if ! fm_t3_primary_binding_active; then
    printf 't3-primary-park: no active binding\n' >&2
    return 1
  fi
  if park_lock_held_by_live; then
    printf 't3-primary-park: already running\n'
    return 0
  fi
  # Blessed daemonization: ensure is the only entry that backgrounds run.
  # Callers must invoke ensure in the foreground (never shell & the arm itself).
  FM_HOME="$FM_T3_HOME" FM_STATE_OVERRIDE="$FM_T3_STATE" FM_CONFIG_OVERRIDE="$FM_T3_CONFIG" \
    nohup "$SCRIPT_DIR/fm-t3-primary-park.sh" run \
    >>"$FM_T3_STATE/.t3-primary-park.log" 2>&1 &
  disown $! 2>/dev/null || true
  sleep 0.5
  if park_lock_held_by_live; then
    printf 't3-primary-park: started\n'
    return 0
  fi
  printf 't3-primary-park: FAILED to start\n' >&2
  return 1
}

run_park_loop() {
  local thread attempt ARM_OUT ARM_PID ACTIONABLE HEALTHY STAND_DOWN WAKE SUCCESSOR_OUT
  local WATCH="$SCRIPT_DIR/fm-watch.sh"

  fm_t3_primary_paths
  mkdir -p "$FM_T3_STATE" || exit 1

  if ! fm_t3_primary_binding_active; then
    printf 't3-primary-park: no binding\n' >&2
    exit 1
  fi

  if ! fm_lock_try_acquire "$FM_T3_PARK_LOCK"; then
    if park_lock_held_by_live; then
      printf 't3-primary-park: singleton held\n'
      exit 0
    fi
    printf 't3-primary-park: could not acquire singleton\n' >&2
    exit 1
  fi

  trap 'fm_lock_release "$FM_T3_PARK_LOCK" 2>/dev/null; [ -n "${ARM_PID:-}" ] && kill "$ARM_PID" 2>/dev/null; [ -n "${ARM_OUT:-}" ] && rm -f "$ARM_OUT" 2>/dev/null; :' EXIT

  # shellcheck source=/dev/null
  [ -f "$FM_T3_CONFIG/x-mode.env" ] && . "$FM_T3_CONFIG/x-mode.env"

  while true; do
    [ -e "$FM_T3_STATE/.afk" ] && { printf 't3-primary-park: afk stand down\n'; exit 0; }
    if ! fm_t3_primary_binding_active; then
      printf 't3-primary-park: binding gone\n'
      exit 0
    fi
    if ! fm_supervision_needed "$FM_T3_STATE" "$GRACE"; then
      loop_count_reset
      budget_reset
      sleep "$POLL"
      continue
    fi

    if ! current_session_still_ours; then
      sleep "$POLL"
      continue
    fi

    PARK_SEQ=
    claim_park || { sleep "$POLL"; continue; }

    loop_count_read
    if [ "$LOOP_COUNT" -ge "$LOOP_CEILING" ]; then
      if [ "$LOOP_COUNT" -eq "$LOOP_CEILING" ]; then
        inject_followup turn-end-guard "FIRSTMATE T3 SUPERVISION FOLLOW-UP CEILING REACHED - this home has taken $LOOP_COUNT consecutive T3 park injects without a captain reset, so automatic wake delivery stops here to bound the loop. Queued wakes stay durable: run bin/fm-wake-drain.sh, handle them, and run its exact WAKE_ACK_REQUIRED command. Clear config or re-bind / session-start to resume, or send a captain message and reset state/.t3-primary-loop."
        loop_count_write $((LOOP_COUNT + 1))
      fi
      sleep 30
      continue
    fi

    ARM_OUT=
    ARM_PID=
    ACTIONABLE=0
    HEALTHY=0
    STAND_DOWN=0
    attempt=0
    while [ "$attempt" -lt "$ARM_ATTEMPTS" ]; do
      attempt=$((attempt + 1))
      ARM_OUT=$(mktemp "$FM_T3_STATE/.t3-park-output.XXXXXX") || ARM_OUT=
      if [ -n "$ARM_OUT" ]; then
        "$SCRIPT_DIR/fm-watch-arm.sh" >"$ARM_OUT" 2>&1 &
      else
        "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
      fi
      ARM_PID=$!
      while kill -0 "$ARM_PID" 2>/dev/null; do
        if ! park_still_ours || [ -e "$FM_T3_STATE/.afk" ]; then
          STAND_DOWN=1
          break
        fi
        # Captain typed: thread running while we hold no inject yet → stand down.
        thread=$(fm_t3_primary_binding_get thread_id 2>/dev/null || true)
        if [ -n "$thread" ]; then
          case "$(fm_t3_primary_thread_status "$thread" 2>/dev/null || true)" in
            running)
              STAND_DOWN=1
              break
              ;;
          esac
        fi
        sleep "$POLL"
      done
      if [ "$STAND_DOWN" -eq 1 ]; then
        kill "$ARM_PID" 2>/dev/null || true
        wait "$ARM_PID" 2>/dev/null || true
        ARM_PID=
        break
      fi
      wait "$ARM_PID" 2>/dev/null || true
      ARM_PID=

      [ -e "$FM_T3_STATE/.afk" ] && exit 0

      ACTIONABLE=0
      if [ -n "$ARM_OUT" ]; then
        grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$ARM_OUT" 2>/dev/null && ACTIONABLE=1
      fi
      [ "$ACTIONABLE" -eq 1 ] && break

      if fm_watcher_healthy "$FM_T3_STATE" "$WATCH" "$GRACE" "$FM_T3_HOME"; then
        HEALTHY=1
        break
      fi
      [ "$attempt" -lt "$ARM_ATTEMPTS" ] || break
      [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null
      ARM_OUT=
    done

    if [ "$STAND_DOWN" -eq 1 ]; then
      sleep "$POLL"
      continue
    fi

    if ! fm_supervision_needed "$FM_T3_STATE" "$GRACE"; then
      budget_reset
      loop_count_reset
      continue
    fi

    if [ "$ACTIONABLE" -eq 1 ]; then
      # Option B: start successor arm before delivering the inject.
      SUCCESSOR_OUT=$(mktemp "$FM_T3_STATE/.t3-park-successor.XXXXXX") || SUCCESSOR_OUT=
      if [ -n "$SUCCESSOR_OUT" ]; then
        "$SCRIPT_DIR/fm-watch-arm.sh" >"$SUCCESSOR_OUT" 2>&1 &
        # Do not wait - successor runs independently; readiness is best-effort.
        sleep 0.2
      fi

      WAKE=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$ARM_OUT" 2>/dev/null | head -8)
      if inject_followup watcher "firstmate watcher wake - one supervision event needs a handling turn now.
$WAKE

Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. The T3 primary park owns watcher continuity: do NOT run bin/fm-watch-arm.sh after an ordinary wake."; then
        loop_count_read
        loop_count_write $((LOOP_COUNT + 1))
        budget_reset
      fi
      [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null
      continue
    fi

    if [ "$HEALTHY" -eq 1 ]; then
      budget_reset
      [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null
      continue
    fi

    # Repair path
    budget_read
    if [ "$BUDGET_COUNT" -lt "$BLOCK_BUDGET" ]; then
      if inject_followup turn-end-guard "TURN WOULD END BLIND - T3 primary park could not establish a live watcher cycle after $attempt bounded attempts (nag $((BUDGET_COUNT + 1)) of $BLOCK_BUDGET). Repair missing watcher supervision according to the session-start operating block."; then
        budget_write $((BUDGET_COUNT + 1))
      fi
    fi
    [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null
    sleep "$POLL"
  done
}

case "$CMD" in
  -h|--help|help) usage; exit 0 ;;
  ensure) ensure_park; exit $? ;;
  run) run_park_loop; exit $? ;;
  status)
    fm_t3_primary_paths
    if park_lock_held_by_live; then
      printf 'running\n'
    else
      printf 'stopped\n'
    fi
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
