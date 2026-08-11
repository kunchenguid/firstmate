#!/usr/bin/env bash
# Probe one Firstmate watcher's liveness from an installed launchd copy.
#
# The monitored FM_HOME is read-only probe input. All deadman configuration and
# state live beside this installed script. Normal healthy and unhealthy probe
# paths return 0, including failed notification attempts. Invalid configuration
# or corrupt deadman-owned state returns 2 so launchd logs a self-fault.
#
# Usage: fm-deadman.sh [--canary|--help]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR=${FM_DEADMAN_INSTALL_DIR:-$SCRIPT_DIR}
CONFIG_FILE="$INSTALL_DIR/deadman.env"
CHANNEL_FILE="$INSTALL_DIR/deadman.conf"
JOURNAL="$INSTALL_DIR/deadman.journal"
LOCK_DIR="$INSTALL_DIR/.probe.lock"

STALE_AFTER_SECS=600
SAMPLE_GAP_SECS=60
SAMPLE_MAX_GAP_SECS=120
FIRST_ARM_GRACE_SECS=660
WAKE_GRACE_SECS=300
SLEEP_GAP_DETECT_SECS=180
COOLDOWN_SECS=1800
FM_HOME=

usage() {
  printf 'usage: fm-deadman.sh [--canary|--help]\n' >&2
}

rotate_log() {
  local path=$1 size tmp
  [ -f "$path" ] || return 0
  size=$(wc -c < "$path" 2>/dev/null) || return 0
  [ "$size" -le 131072 ] && return 0
  tmp="$path.tmp.$$"
  tail -n 500 "$path" > "$tmp" 2>/dev/null && mv -f "$tmp" "$path"
  rm -f "$tmp" 2>/dev/null || true
}

journal() {
  local line=$1 size tmp
  printf '%s\t%s\n' "${NOW:-$(date +%s)}" "$line" >> "$JOURNAL" 2>/dev/null || return 0
  size=$(wc -c < "$JOURNAL" 2>/dev/null) || return 0
  [ "$size" -le 131072 ] && return 0
  tmp="$JOURNAL.tmp.$$"
  tail -n 500 "$JOURNAL" > "$tmp" 2>/dev/null && mv -f "$tmp" "$JOURNAL"
  rm -f "$tmp" 2>/dev/null || true
}

self_fault() {
  journal "self-fault: $1"
  printf 'fm-deadman: %s\n' "$1" >&2
  exit 2
}

atomic_write() {
  local path=$1 value=$2 tmp="$1.tmp.$$"
  (umask 077 && printf '%s\n' "$value" > "$tmp") || return 1
  mv -f "$tmp" "$path"
}

valid_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

read_config() {
  local line key value
  [ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ] || self_fault "missing or unreadable config: $CONFIG_FILE"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) self_fault "invalid config line" ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      FM_HOME) FM_HOME=$value ;;
      STALE_AFTER_SECS) STALE_AFTER_SECS=$value ;;
      SAMPLE_GAP_SECS) SAMPLE_GAP_SECS=$value ;;
      SAMPLE_MAX_GAP_SECS) SAMPLE_MAX_GAP_SECS=$value ;;
      FIRST_ARM_GRACE_SECS) FIRST_ARM_GRACE_SECS=$value ;;
      WAKE_GRACE_SECS) WAKE_GRACE_SECS=$value ;;
      SLEEP_GAP_DETECT_SECS) SLEEP_GAP_DETECT_SECS=$value ;;
      COOLDOWN_SECS) COOLDOWN_SECS=$value ;;
      *) self_fault "unknown config key: $key" ;;
    esac
  done < "$CONFIG_FILE"
  case "$FM_HOME" in /*) ;; *) self_fault "FM_HOME must be an absolute path" ;; esac
  valid_uint "$STALE_AFTER_SECS" || self_fault "STALE_AFTER_SECS must be an unsigned integer"
  valid_uint "$SAMPLE_GAP_SECS" || self_fault "SAMPLE_GAP_SECS must be an unsigned integer"
  valid_uint "$SAMPLE_MAX_GAP_SECS" || self_fault "SAMPLE_MAX_GAP_SECS must be an unsigned integer"
  valid_uint "$FIRST_ARM_GRACE_SECS" || self_fault "FIRST_ARM_GRACE_SECS must be an unsigned integer"
  valid_uint "$WAKE_GRACE_SECS" || self_fault "WAKE_GRACE_SECS must be an unsigned integer"
  valid_uint "$SLEEP_GAP_DETECT_SECS" || self_fault "SLEEP_GAP_DETECT_SECS must be an unsigned integer"
  valid_uint "$COOLDOWN_SECS" || self_fault "COOLDOWN_SECS must be an unsigned integer"
  [ "$STALE_AFTER_SECS" -gt 0 ] || self_fault "STALE_AFTER_SECS must be positive"
  [ "$SAMPLE_GAP_SECS" -ge 60 ] && [ "$SAMPLE_GAP_SECS" -le 120 ] || self_fault "SAMPLE_GAP_SECS must be 60-120"
  [ "$SAMPLE_MAX_GAP_SECS" -ge "$SAMPLE_GAP_SECS" ] && [ "$SAMPLE_MAX_GAP_SECS" -le 120 ] || self_fault "SAMPLE_MAX_GAP_SECS must be SAMPLE_GAP_SECS-120"
  [ "$SLEEP_GAP_DETECT_SECS" -gt 0 ] || self_fault "SLEEP_GAP_DETECT_SECS must be positive"
}

read_timestamp() {
  local path=$1 value
  TIMESTAMP=
  [ -e "$path" ] || return 1
  IFS= read -r value < "$path" || self_fault "cannot read deadman state: $path"
  valid_uint "$value" || self_fault "invalid deadman timestamp: $path"
  TIMESTAMP=$value
  return 0
}

beacon_mtime() {
  local path=$1 value
  value=$(stat -f %m "$path" 2>/dev/null) || value=$(stat -c %Y "$path" 2>/dev/null) || return 1
  valid_uint "$value" || return 1
  printf '%s\n' "$value"
}

probe_status() {
  local beat="$FM_HOME/state/.last-watcher-beat" mtime age
  if [ ! -d "$FM_HOME" ] || [ ! -r "$FM_HOME" ] || [ ! -x "$FM_HOME" ]; then
    PROBE_CLASS=home-unavailable
    PROBE_DETAIL="FM_HOME missing or unreadable: $FM_HOME"
    return 1
  fi
  if [ ! -f "$beat" ] || [ ! -r "$beat" ]; then
    PROBE_CLASS=beacon-unavailable
    PROBE_DETAIL="watcher beacon missing or unreadable: $beat"
    return 1
  fi
  if ! mtime=$(beacon_mtime "$beat"); then
    PROBE_CLASS=beacon-unreadable
    PROBE_DETAIL="watcher beacon mtime unreadable: $beat"
    return 1
  fi
  age=$((NOW - mtime))
  if [ "$age" -lt 0 ]; then
    PROBE_CLASS=beacon-future
    PROBE_DETAIL="watcher beacon has future mtime by $((-age))s: $beat"
    return 1
  fi
  if [ "$age" -gt "$STALE_AFTER_SECS" ]; then
    PROBE_CLASS=beacon-stale
    PROBE_DETAIL="watcher beacon stale for ${age}s: $beat"
    return 1
  fi
  PROBE_CLASS=healthy
  PROBE_DETAIL="watcher beacon age ${age}s"
  return 0
}

arm_if_ready() {
  local installed_at
  [ -e "$INSTALL_DIR/armed" ] && return 0
  if probe_status; then
    atomic_write "$INSTALL_DIR/armed" "$NOW" || self_fault "cannot arm deadman"
    rm -f "$INSTALL_DIR/first-stale"
    journal "armed after healthy beacon"
    return 0
  fi
  if ! read_timestamp "$INSTALL_DIR/installed-at"; then
    atomic_write "$INSTALL_DIR/installed-at" "$NOW" || self_fault "cannot create first-arm timestamp"
    journal "first-arm grace started"
    return 1
  fi
  installed_at=$TIMESTAMP
  if [ "$NOW" -lt "$installed_at" ] || [ $((NOW - installed_at)) -lt "$FIRST_ARM_GRACE_SECS" ]; then
    journal "first-arm grace: $PROBE_CLASS"
    return 1
  fi
  atomic_write "$INSTALL_DIR/armed" "$NOW" || self_fault "cannot arm deadman after grace"
  journal "armed after first-arm grace"
  return 0
}

apply_sleep_wake_grace() {
  local last_run grace_until delta
  if read_timestamp "$INSTALL_DIR/last-run-at"; then
    last_run=$TIMESTAMP
    delta=$((NOW - last_run))
    if [ "$delta" -lt 0 ] || [ "$delta" -gt "$SLEEP_GAP_DETECT_SECS" ]; then
      grace_until=$((NOW + WAKE_GRACE_SECS))
      atomic_write "$INSTALL_DIR/wake-grace-until" "$grace_until" || self_fault "cannot record wake grace"
      rm -f "$INSTALL_DIR/first-stale"
      journal "sleep/wake grace started after run gap ${delta}s"
    fi
  fi
  atomic_write "$INSTALL_DIR/last-run-at" "$NOW" || self_fault "cannot record probe time"
  if read_timestamp "$INSTALL_DIR/wake-grace-until"; then
    grace_until=$TIMESTAMP
    if [ "$NOW" -lt "$grace_until" ]; then
      journal "sleep/wake grace active"
      return 1
    fi
    rm -f "$INSTALL_DIR/wake-grace-until"
  fi
  return 0
}

notify() {
  local summary=$1
  local FM_NOTIFY_CONFIG_FILE=$CHANNEL_FILE
  local FM_NOTIFY_CHANNEL=${FM_DEADMAN_CHANNEL:-}
  local FM_NOTIFY_EXEC=${FM_DEADMAN_NOTIFY_EXEC:-}
  local FM_NOTIFY_TIMEOUT_SECS=${FM_DEADMAN_NOTIFY_TIMEOUT_SECS:-10}
  local FM_NOTIFY_TITLE="firstmate deadman"
  fm_notify "$summary" "journal $JOURNAL"
}

acquire_lock() {
  local mtime age
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  mtime=$(beacon_mtime "$LOCK_DIR") || return 1
  age=$((NOW - mtime))
  [ "$age" -gt 300 ] || return 1
  rmdir "$LOCK_DIR" 2>/dev/null || return 1
  mkdir "$LOCK_DIR" 2>/dev/null
}

# shellcheck disable=SC2329 # invoked by EXIT trap after probe lock acquisition
release_probe() {
  if [ "${DEADMAN_CLEANUP_DONE:-}" = 1 ]; then
    return 0
  fi
  DEADMAN_CLEANUP_DONE=1
  trap - EXIT INT TERM
  if declare -F fm_notify_stop_active >/dev/null 2>&1; then
    fm_notify_stop_active
  fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

# shellcheck disable=SC2329 # invoked by INT/TERM traps after probe lock acquisition
handle_probe_signal() {
  release_probe
  exit 1
}

main() {
  local mode=${1:-} first_sample sample_time sample_class delta last_success summary
  case "$mode" in
    ''|--canary) ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  [ "$#" -le 1 ] || { usage; exit 2; }
  [ -d "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ] || self_fault "install directory missing or unwritable: $INSTALL_DIR"
  rotate_log "$INSTALL_DIR/deadman.stdout.log"
  rotate_log "$INSTALL_DIR/deadman.stderr.log"
  read_config
  [ -r "$SCRIPT_DIR/fm-notify-lib.sh" ] || self_fault "notification library missing"
  # shellcheck source=bin/fm-notify-lib.sh
  . "$SCRIPT_DIR/fm-notify-lib.sh"
  NOW=${FM_DEADMAN_NOW:-$(date +%s)}
  valid_uint "$NOW" || self_fault "current time must be an unsigned integer"
  if ! acquire_lock; then
    if [ "$mode" = --canary ]; then
      journal "canary failed: another invocation holds the lock"
      exit 1
    fi
    journal "probe skipped: another invocation holds the lock"
    exit 0
  fi
  DEADMAN_CLEANUP_DONE=
  trap release_probe EXIT
  trap handle_probe_signal INT TERM

  if [ "$mode" = --canary ]; then
    summary="FIRSTMATE DEADMAN CANARY - notification path is working for $FM_HOME"
    if notify "$summary"; then
      journal "canary notification succeeded"
      exit 0
    fi
    journal "canary notification failed"
    exit 1
  fi

  apply_sleep_wake_grace || exit 0
  arm_if_ready || exit 0
  if probe_status; then
    rm -f "$INSTALL_DIR/first-stale"
    exit 0
  fi

  first_sample="$INSTALL_DIR/first-stale"
  if [ ! -e "$first_sample" ]; then
    atomic_write "$first_sample" "$NOW|$PROBE_CLASS" || self_fault "cannot record first stale sample"
    journal "first unhealthy sample: $PROBE_CLASS"
    exit 0
  fi
  IFS='|' read -r sample_time sample_class < "$first_sample" || self_fault "cannot read first stale sample"
  valid_uint "$sample_time" || self_fault "invalid first stale sample"
  delta=$((NOW - sample_time))
  if [ "$sample_class" != "$PROBE_CLASS" ] || [ "$delta" -lt "$SAMPLE_GAP_SECS" ] || [ "$delta" -gt "$SAMPLE_MAX_GAP_SECS" ]; then
    if [ "$delta" -ge "$SAMPLE_GAP_SECS" ] && [ "$delta" -le "$SAMPLE_MAX_GAP_SECS" ] && [ "$sample_class" != "$PROBE_CLASS" ]; then
      journal "unhealthy class changed: $sample_class -> $PROBE_CLASS"
    fi
    [ "$delta" -lt "$SAMPLE_GAP_SECS" ] || atomic_write "$first_sample" "$NOW|$PROBE_CLASS" || self_fault "cannot refresh first stale sample"
    exit 0
  fi

  if read_timestamp "$INSTALL_DIR/last-success-at"; then
    last_success=$TIMESTAMP
    [ "$NOW" -ge "$last_success" ] || self_fault "successful-page timestamp is in the future"
    if [ $((NOW - last_success)) -lt "$COOLDOWN_SECS" ]; then
      journal "unhealthy but successful-page cooldown active: $PROBE_CLASS"
      exit 0
    fi
  fi

  summary="FIRSTMATE DEADMAN: $PROBE_DETAIL; scheduling path may be stopped"
  if notify "$summary"; then
    atomic_write "$INSTALL_DIR/last-success-at" "$NOW" || self_fault "cannot record successful page"
    journal "page succeeded: $PROBE_CLASS"
  else
    journal "page failed: $PROBE_CLASS"
  fi
  atomic_write "$first_sample" "$NOW|$PROBE_CLASS" || self_fault "cannot refresh stale sample after page attempt"
  exit 0
}

main "$@"
