#!/usr/bin/env bash
# fm-home-summary-refresh.sh - publish this home's structured summary ledger.
#
# Usage: fm-home-summary-refresh.sh [--best-effort]
#
# The published state/home-summary.json is the exact
# `fm-fleet-snapshot.sh --secondmate-home-summary` document for this FM_HOME.
# Its schema remains `fm-secondmate-home-summary.v1` and includes both the
# existing generated timestamp and generated_epoch for freshness arithmetic.
#
# Publication is atomic: the producer writes and validates a unique mode-0600
# temporary file on the state directory's filesystem, then renames it over the
# ledger. A failed, interrupted, or killed producer therefore leaves the prior
# complete ledger in place and never exposes partial JSON at the ledger path.
# A home-local refresh lock serializes concurrent triggers so an older in-flight
# summary cannot overwrite one computed after a later status change. The shared
# timeout owner bounds lock acquisition and production together with
# FM_HOME_SUMMARY_TIMEOUT (default 60 seconds). No reader can observe temporary
# output through the ledger path.
#
# With --best-effort, any failure is appended to the bounded home-local
# state/.home-summary-refresh.log and the command exits zero. Session start,
# watcher, spawn, and teardown use that mode so this side-band publication can
# never change their result. Without it, failures are printed and returned to
# the direct caller for tests and diagnostics.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
LEDGER="$STATE/home-summary.json"
ERROR_LOG="$STATE/.home-summary-refresh.log"
REFRESH_LOCK="$STATE/.home-summary-refresh.lock"
ERROR_LOG_MAX_BYTES=${FM_HOME_SUMMARY_ERROR_LOG_MAX_BYTES:-65536}
HOME_SUMMARY_TIMEOUT=${FM_HOME_SUMMARY_TIMEOUT:-60}
BEST_EFFORT=0
HOME_SUMMARY_ERROR=
HOME_SUMMARY_TMP=
HOME_SUMMARY_ERR_TMP=
HOME_SUMMARY_LOCK_HELD=0

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  '') ;;
  --best-effort) BEST_EFFORT=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
case "$ERROR_LOG_MAX_BYTES" in
  ''|*[!0-9]*|0) ERROR_LOG_MAX_BYTES=65536 ;;
esac
case "$HOME_SUMMARY_TIMEOUT" in
  ''|*[!0-9]*|0) HOME_SUMMARY_TIMEOUT=60 ;;
esac

# shellcheck disable=SC2329 # Invoked by the signal and EXIT traps below.
home_summary_cleanup() {
  [ -z "$HOME_SUMMARY_TMP" ] || rm -f -- "$HOME_SUMMARY_TMP" 2>/dev/null || true
  [ -z "$HOME_SUMMARY_ERR_TMP" ] || rm -f -- "$HOME_SUMMARY_ERR_TMP" 2>/dev/null || true
  if [ "$HOME_SUMMARY_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$REFRESH_LOCK" || true
    HOME_SUMMARY_LOCK_HELD=0
  fi
}

home_summary_fail() {
  HOME_SUMMARY_ERROR=$1
  return 1
}

home_summary_refresh_once() {
  local producer_rc producer_error started_epoch deadline_epoch remaining
  started_epoch=$(date +%s)
  deadline_epoch=$((started_epoch + HOME_SUMMARY_TIMEOUT))
  if ! mkdir -p "$STATE" 2>/dev/null; then
    home_summary_fail "state directory is unavailable: $STATE"
    return 1
  fi
  trap home_summary_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while ! fm_lock_try_acquire "$REFRESH_LOCK"; do
    if [ "$(date +%s)" -ge "$deadline_epoch" ]; then
      home_summary_fail "refresh timed out waiting for its publication lock"
      return 1
    fi
    sleep 0.1
  done
  HOME_SUMMARY_LOCK_HELD=1
  HOME_SUMMARY_TMP=$(umask 077; mktemp "$STATE/.home-summary.json.XXXXXX") || {
    home_summary_fail "could not create an atomic publication file in $STATE"
    return 1
  }
  HOME_SUMMARY_ERR_TMP=$(umask 077; mktemp "$STATE/.home-summary-error.XXXXXX") || {
    home_summary_fail "could not create a producer diagnostic file in $STATE"
    return 1
  }

  remaining=$((deadline_epoch - $(date +%s)))
  if [ "$remaining" -le 0 ]; then
    home_summary_fail "refresh timed out before summary production"
    return 1
  fi
  if fm_run_timed "$remaining" env \
    FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$PROJECTS" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary \
      > "$HOME_SUMMARY_TMP" 2> "$HOME_SUMMARY_ERR_TMP"; then
    producer_rc=0
  else
    producer_rc=$?
  fi
  if [ "$producer_rc" -ne 0 ]; then
    producer_error=$(tail -n 1 "$HOME_SUMMARY_ERR_TMP" 2>/dev/null \
      | tr '\t\r\n' '   ' | cut -c1-500)
    if [ -n "$producer_error" ]; then
      home_summary_fail "summary producer failed with exit $producer_rc: $producer_error"
    else
      home_summary_fail "summary producer failed with exit $producer_rc"
    fi
    return 1
  fi
  rm -f -- "$HOME_SUMMARY_ERR_TMP"
  HOME_SUMMARY_ERR_TMP=
  if ! jq -e --arg home "$FM_HOME" '
    .schema == "fm-secondmate-home-summary.v1"
    and .home == $home
    and (.generated | type) == "string"
    and (.generated | length) > 0
    and (.generated_epoch | type) == "number"
    and .generated_epoch >= 0
    and (.generated_epoch | floor) == .generated_epoch
    and (.valid | type) == "boolean"
    and (.state | type) == "string"
    and (.invalidity | type) == "object"
    and (.active_children | type) == "array"
    and (.decisions_open | type) == "array"
    and (.holds | type) == "array"
    and (.queued | type) == "array"
    and (.landed | type) == "array"
    and (.endpoints | type) == "array"
    and (.counts | type) == "object"
    and (.omitted | type) == "array"
  ' "$HOME_SUMMARY_TMP" >/dev/null 2>&1; then
    home_summary_fail "summary producer returned a malformed ledger document"
    return 1
  fi
  if ! chmod 600 "$HOME_SUMMARY_TMP" 2>/dev/null; then
    home_summary_fail "could not set the publication file mode"
    return 1
  fi
  if ! mv -f -- "$HOME_SUMMARY_TMP" "$LEDGER" 2>/dev/null; then
    home_summary_fail "atomic ledger replacement failed: $LEDGER"
    return 1
  fi
  HOME_SUMMARY_TMP=
  fm_lock_release "$REFRESH_LOCK"
  HOME_SUMMARY_LOCK_HELD=0
  trap - EXIT HUP INT TERM
  return 0
}

home_summary_log_failure() {
  local size tmp
  if ! printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HOME_SUMMARY_ERROR" >> "$ERROR_LOG" 2>/dev/null; then
    printf 'fm-home-summary-refresh: %s\n' "$HOME_SUMMARY_ERROR" >&2
    return 0
  fi
  size=$(wc -c < "$ERROR_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$size" -ge "$ERROR_LOG_MAX_BYTES" ]; then
    tmp="$ERROR_LOG.tmp.${BASHPID:-$$}"
    tail -n 200 "$ERROR_LOG" > "$tmp" 2>/dev/null \
      && mv -f -- "$tmp" "$ERROR_LOG" 2>/dev/null
    rm -f -- "$tmp" 2>/dev/null || true
  fi
}

if home_summary_refresh_once; then
  exit 0
else
  refresh_rc=$?
fi
if [ "$BEST_EFFORT" -eq 1 ]; then
  home_summary_log_failure
  exit 0
fi
printf 'fm-home-summary-refresh: %s\n' "$HOME_SUMMARY_ERROR" >&2
exit "$refresh_rc"
