#!/usr/bin/env bash
# Initial and successor startup allowance. Source after fm-wake-lib.sh.
# The enclosing host creates one exclusive empty journal in its home state dir
# before spawning, exporting its path, filename nonce, start and total cap.
# The acknowledged hand-back owner inherits that same allowance; its later
# cycles create their own. Only these enclosing owners read progress.
# Producers append one short `stage <n> <nonce>` line with a single printf and
# O_APPEND, after real operations: 1 arm admission, 2 watcher establishment,
# 3 recovery-generation inspection (including the arm's recovery lock).
# Records are nonce-scoped advisory hints, not producer or watcher identity
# proof. Readers ignore malformed records and records with another nonce.
# Only a new higher stage renews 25 seconds without observed progress. Repeated
# stages, file timestamps and live PIDs do not. The whole attempt is capped at
# 100 seconds. Explicit FM_SUPERVISION_HOST_READY_TIMEOUT is a pure total window
# without the no-progress rule; invalid values retain the 25-second fallback.
# The enclosing owner exports that explicit-window choice with the attempt.
# Progress never grants readiness. Wait still requires the arm's genuine
# started|attached line, and the acknowledged path's existing watcher-health
# check. Death, lost ownership or expiry retains the existing hand-to-main.
# Bounds are checked before and after readiness work, at scheduled checks.
# The host creates the first arm's journal before launch too. Standalone arms
# without a host context retain FM_ARM_CONFIRM_TIMEOUT's confirmation budget.
# Creating another attempt first clears the owner's previous journal, so a
# failed successor cannot leave it behind when acknowledged hand-back starts.
# FM_TEST_STARTUP_CLOCK may supply the clock only when FM_TEST_SEAM=1.
# shellcheck disable=SC2153 # STATE and SCRIPT_DIR are supplied by the caller.

fm_startup_progress_now() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_TEST_STARTUP_CLOCK:-}" ]; then
    IFS= read -r FM_STARTUP_PROGRESS_NOW < "$FM_TEST_STARTUP_CLOCK" || return 1
  else
    fm_epoch_seconds_to FM_STARTUP_PROGRESS_NOW
  fi
  case "$FM_STARTUP_PROGRESS_NOW" in ''|*[!0-9]*) return 1 ;; esac
}

fm_startup_progress_create() {
  fm_startup_progress_clear
  FM_STARTUP_PROGRESS_CAP=100
  FM_STARTUP_PROGRESS_EXPLICIT=0
  if [ -n "${FM_SUPERVISION_HOST_READY_TIMEOUT:-}" ]; then
    FM_STARTUP_PROGRESS_EXPLICIT=1
    FM_STARTUP_PROGRESS_CAP=$FM_SUPERVISION_HOST_READY_TIMEOUT
    case "$FM_STARTUP_PROGRESS_CAP" in 0*|*[!0-9]*) FM_STARTUP_PROGRESS_CAP=25 ;; esac
  fi
  fm_startup_progress_now || return 1
  FM_STARTUP_PROGRESS_BEGIN=$FM_STARTUP_PROGRESS_NOW
  FM_STARTUP_PROGRESS_JOURNAL=$(mktemp "$STATE/.watch-startup.XXXXXX") || return 1
  FM_STARTUP_PROGRESS_NONCE=${FM_STARTUP_PROGRESS_JOURNAL##*/}
  export FM_STARTUP_PROGRESS_JOURNAL FM_STARTUP_PROGRESS_NONCE
  export FM_STARTUP_PROGRESS_BEGIN FM_STARTUP_PROGRESS_CAP
  export FM_STARTUP_PROGRESS_EXPLICIT
}

fm_startup_progress_append() {  # <1|2|3>; advisory, never a readiness result
  [ -n "${FM_STARTUP_PROGRESS_JOURNAL:-}" ] || return 0
  case "$FM_STARTUP_PROGRESS_JOURNAL" in "$STATE"/.watch-startup.*) ;; *) return 0 ;; esac
  [ -f "$FM_STARTUP_PROGRESS_JOURNAL" ] && [ ! -L "$FM_STARTUP_PROGRESS_JOURNAL" ] || return 0
  printf '%s\n' "stage $1 $FM_STARTUP_PROGRESS_NONCE" >> "$FM_STARTUP_PROGRESS_JOURNAL" || true
}

fm_startup_progress_deadline() {  # <output-variable>; enclosing attempt when present
  [ -n "${FM_STARTUP_PROGRESS_JOURNAL:-}" ] || return 0
  printf -v "$1" '%s' "$((FM_STARTUP_PROGRESS_BEGIN + FM_STARTUP_PROGRESS_CAP))"
}

fm_startup_progress_check() {
  local highest
  highest=$(awk -v nonce="$FM_STARTUP_PROGRESS_NONCE" '
    NF == 3 && $1 == "stage" && $2 ~ /^[123]$/ && $3 == nonce && $2 > high { high = $2 }
    END { print high + 0 }
  ' "$FM_STARTUP_PROGRESS_JOURNAL" 2>/dev/null) || return 1
  fm_startup_progress_now || return 1
  if [ "$highest" -gt "$FM_STARTUP_PROGRESS_HIGHEST" ]; then
    FM_STARTUP_PROGRESS_HIGHEST=$highest
    FM_STARTUP_PROGRESS_LAST=$FM_STARTUP_PROGRESS_NOW
  fi
  [ "$FM_STARTUP_PROGRESS_NOW" -ge "$FM_STARTUP_PROGRESS_BEGIN" ] \
    && [ $((FM_STARTUP_PROGRESS_NOW - FM_STARTUP_PROGRESS_BEGIN)) -lt "$FM_STARTUP_PROGRESS_CAP" ] \
    && { [ "${FM_STARTUP_PROGRESS_EXPLICIT:-0}" = 1 ] \
      || [ $((FM_STARTUP_PROGRESS_NOW - FM_STARTUP_PROGRESS_LAST)) -lt 25 ]; }
}

fm_startup_progress_wait() {  # <spawned-pid> <arm-output> <check-health:0|1> [owner predicate]
  local pid=$1 out=$2 health=$3 owner=${4:-}
  FM_STARTUP_PROGRESS_HIGHEST=0
  FM_STARTUP_PROGRESS_LAST=$FM_STARTUP_PROGRESS_BEGIN
  while :; do
    [ -z "$owner" ] || "$owner" || return 1
    fm_pid_alive "$pid" && fm_startup_progress_check || return 1
    FM_STARTUP_PROGRESS_LINE=$(grep -E '^watcher: (started|attached) pid=[0-9]+' "$out" 2>/dev/null | head -n 1)
    if [ -n "$FM_STARTUP_PROGRESS_LINE" ] \
      && { [ "$health" = 0 ] || fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; }; then
      fm_startup_progress_check && fm_pid_alive "$pid"
      return $?
    fi
    sleep 0.2
  done
}

fm_startup_progress_clear() {
  case "${FM_STARTUP_PROGRESS_JOURNAL:-}" in "$STATE"/.watch-startup.*)
    rm -f -- "$FM_STARTUP_PROGRESS_JOURNAL" ;;
  esac
  fm_startup_progress_forget
}

fm_startup_progress_forget() {  # An arm must not reuse its completed startup.
  unset FM_STARTUP_PROGRESS_JOURNAL FM_STARTUP_PROGRESS_NONCE
  unset FM_STARTUP_PROGRESS_BEGIN FM_STARTUP_PROGRESS_CAP
  unset FM_STARTUP_PROGRESS_EXPLICIT
}
