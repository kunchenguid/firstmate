#!/usr/bin/env bash
# Report bounded host pressure for optional capacity-failover backpressure.
# Usage:
#   fm-host-pressure.sh check [--config <path>] [--home <path>] [--state <path>]
#   fm-host-pressure.sh gate --kind <spawn|test> [--config <path>] [--home <path>] [--state <path>]
#   fm-host-pressure.sh periodic-alert [--config <path>] [--home <path>] [--state <path>]
#   fm-host-pressure.sh classify-shed --command <command-line>
#
# The check/gate commands print key=value evidence lines.
# Exit code 0 means the launch may continue.
# Exit code 1 means a critical threshold was crossed and a caller should apply
# backpressure by refusing a new heavy launch.
# Exit code 2 means usage or config error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pressure-lib.sh
. "$SCRIPT_DIR/fm-pressure-lib.sh"

usage() {
  sed -n '2,11p' "$0" >&2
}

need_value() {
  [ "$#" -gt 1 ] || { echo "error: $1 requires a value" >&2; exit 2; }
}

cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 2; }
shift || true

CFG="$CONFIG/capacity-failover"
HOME_PATH="$FM_HOME"
STATE_PATH="$STATE"
GATE_KIND=
COMMAND_LINE=
CONFIG_ALERT_COOLDOWN_SECS=3600

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) need_value "$@"; CFG=$2; shift 2 ;;
    --config=*) CFG=${1#--config=}; shift ;;
    --home) need_value "$@"; HOME_PATH=$2; shift 2 ;;
    --home=*) HOME_PATH=${1#--home=}; shift ;;
    --state) need_value "$@"; STATE_PATH=$2; shift 2 ;;
    --state=*) STATE_PATH=${1#--state=}; shift ;;
    --kind) need_value "$@"; GATE_KIND=$2; shift 2 ;;
    --kind=*) GATE_KIND=${1#--kind=}; shift ;;
    --command) need_value "$@"; COMMAND_LINE=$2; shift 2 ;;
    --command=*) COMMAND_LINE=${1#--command=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; usage; exit 2 ;;
  esac
done

append_reason() {
  if [ -z "$REASONS" ]; then
    REASONS=$1
  else
    REASONS="$REASONS,$1"
  fi
}

mark_warn() {
  [ "$STATE_VALUE" = critical ] || STATE_VALUE=warn
  append_reason "$1"
}

mark_critical() {
  STATE_VALUE=critical
  append_reason "$1"
}

disk_hysteresis_state() {  # <available> <floor> <clear>
  local available=$1 floor=$2 clear=$3 marker active
  marker="$STATE_PATH/.host-pressure-disk-floor"
  [ "$available" != unknown ] || { printf 'unknown\n'; return 0; }
  [ -n "$floor" ] || { rm -f "$marker"; printf 'inactive\n'; return 0; }
  active=0
  [ -f "$marker" ] && active=1
  if [ "$available" -lt "$floor" ]; then
    mkdir -p "$STATE_PATH"
    {
      printf 'state=critical\n'
      printf 'entered_epoch=%s\n' "$(fm_pressure_now_epoch)"
      printf 'disk_available_mb=%s\n' "$available"
      printf 'disk_floor_mb=%s\n' "$floor"
      printf 'disk_clear_mb=%s\n' "$clear"
    } > "$marker"
    printf 'entered\n'
    return 0
  fi
  if [ "$active" -eq 1 ] && [ -n "$clear" ] && [ "$available" -lt "$clear" ]; then
    printf 'held\n'
    return 0
  fi
  rm -f "$marker"
  printf 'inactive\n'
}

emit_check() {
  local disk_hysteresis disk_floor disk_clear disk_default_clear
  if ! fm_pressure_enabled "$CFG"; then
    printf 'state=off\n'
    printf 'reason=host_pressure_not_enabled\n'
    return 0
  fi

  MIN_MEM=$(fm_pressure_config_value "$CFG" min_memory_available_mb 2048)
  WARN_MEM=$(fm_pressure_config_value "$CFG" warn_memory_available_mb 4096)
  MIN_DISK=$(fm_pressure_config_value "$CFG" min_disk_available_mb 10240)
  WARN_DISK=$(fm_pressure_config_value "$CFG" warn_disk_available_mb 20480)
  disk_floor=$(fm_pressure_config_value "$CFG" disk_floor_mb "$MIN_DISK")
  MAX_RUNNING=$(fm_pressure_config_value "$CFG" max_running_tasks 30)

  fm_pressure_numeric_or_empty "$MIN_MEM" min_memory_available_mb || return 2
  fm_pressure_numeric_or_empty "$WARN_MEM" warn_memory_available_mb || return 2
  fm_pressure_numeric_or_empty "$MIN_DISK" min_disk_available_mb || return 2
  fm_pressure_numeric_or_empty "$WARN_DISK" warn_disk_available_mb || return 2
  fm_pressure_numeric_or_empty "$disk_floor" disk_floor_mb || return 2
  fm_pressure_numeric_or_empty "$MAX_RUNNING" max_running_tasks || return 2

  disk_default_clear=$WARN_DISK
  if [ -n "$disk_floor" ] && [ -n "$disk_default_clear" ] && [ "$disk_default_clear" -lt "$disk_floor" ]; then
    disk_default_clear=$disk_floor
  fi
  disk_clear=$(fm_pressure_config_value "$CFG" disk_clear_mb "$disk_default_clear")
  fm_pressure_numeric_or_empty "$disk_clear" disk_clear_mb || return 2

  MEM_AVAILABLE=$(fm_pressure_memory_available_mb)
  DISK_AVAILABLE=$(fm_pressure_disk_available_mb "$HOME_PATH")
  RUNNING=$(fm_pressure_running_tasks "$STATE_PATH")

  STATE_VALUE=ok
  REASONS=

  if [ "$MEM_AVAILABLE" != unknown ]; then
    fm_pressure_numeric_or_empty "$MEM_AVAILABLE" memory_available_mb || return 2
    if [ -n "$MIN_MEM" ] && [ "$MEM_AVAILABLE" -lt "$MIN_MEM" ]; then
      mark_critical memory_available_below_min
    elif [ -n "$WARN_MEM" ] && [ "$MEM_AVAILABLE" -lt "$WARN_MEM" ]; then
      mark_warn memory_available_below_warn
    fi
  else
    mark_warn memory_available_unknown
  fi

  if [ "$DISK_AVAILABLE" != unknown ]; then
    fm_pressure_numeric_or_empty "$DISK_AVAILABLE" disk_available_mb || return 2
    disk_hysteresis=$(disk_hysteresis_state "$DISK_AVAILABLE" "$disk_floor" "$disk_clear")
    case "$disk_hysteresis" in
      entered) mark_critical disk_floor_below_min ;;
      held) mark_critical disk_floor_hysteresis_active ;;
      inactive)
        if [ -n "$WARN_DISK" ] && [ "$DISK_AVAILABLE" -lt "$WARN_DISK" ]; then
          mark_warn disk_available_below_warn
        fi
        ;;
    esac
  else
    disk_hysteresis=unknown
    mark_warn disk_available_unknown
  fi

  fm_pressure_numeric_or_empty "$RUNNING" running_tasks || return 2
  if [ -n "$MAX_RUNNING" ] && [ "$RUNNING" -ge "$MAX_RUNNING" ]; then
    mark_critical running_tasks_at_or_above_max
  fi

  printf 'state=%s\n' "$STATE_VALUE"
  printf 'reason=%s\n' "${REASONS:-none}"
  [ -z "$GATE_KIND" ] || printf 'gate_kind=%s\n' "$GATE_KIND"
  printf 'memory_available_mb=%s\n' "$MEM_AVAILABLE"
  printf 'min_memory_available_mb=%s\n' "$MIN_MEM"
  printf 'warn_memory_available_mb=%s\n' "$WARN_MEM"
  printf 'disk_available_mb=%s\n' "$DISK_AVAILABLE"
  printf 'disk_floor_mb=%s\n' "$disk_floor"
  printf 'disk_clear_mb=%s\n' "$disk_clear"
  printf 'disk_hysteresis=%s\n' "$disk_hysteresis"
  printf 'min_disk_available_mb=%s\n' "$MIN_DISK"
  printf 'warn_disk_available_mb=%s\n' "$WARN_DISK"
  printf 'running_tasks=%s\n' "$RUNNING"
  printf 'max_running_tasks=%s\n' "$MAX_RUNNING"

  if [ "$STATE_VALUE" = critical ]; then
    fm_pressure_safe_transient_candidates "$HOME_PATH"
    return 1
  fi
  return 0
}

periodic_alert() {
  local out status state reason available floor clear cooldown marker now last detail errfile last_detail
  # emit_check rewrites the disk-hysteresis marker, so it is evaluated exactly
  # once and its stderr is captured alongside its stdout instead of being
  # recovered by a second run.
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-host-pressure.XXXXXXXX")
  if out=$(emit_check 2>"$errfile"); then
    status=0
  else
    status=$?
  fi
  # A malformed config/capacity-failover makes emit_check exit 2 with its
  # message on stderr and nothing on stdout. The watcher reads this command's
  # stdout and discards its stderr, so surface the refusal as an alert record
  # rather than letting a broken threshold read as "nothing to alert".
  # A broken threshold is only fixed by a human editing the file, so the alert
  # is bounded by its own marker with a fixed cooldown - the configured cooldown
  # cannot be trusted while the config is refused - and re-alerts immediately
  # when the refusal message itself changes.
  if [ "$status" -eq 2 ]; then
    detail=$(tail -1 "$errfile")
    rm -f "$errfile"
    detail=${detail:-invalid capacity-failover configuration}
    marker="$STATE_PATH/.host-pressure-config-alert"
    now=$(fm_pressure_now_epoch)
    last=$(sed -n 's/^last_alert_epoch=//p' "$marker" 2>/dev/null | tail -1)
    last_detail=$(sed -n 's/^reason=//p' "$marker" 2>/dev/null | tail -1)
    if [ -n "$last" ] && [ "$last_detail" = "$detail" ] &&
      [ "$((now - last))" -lt "$CONFIG_ALERT_COOLDOWN_SECS" ] 2>/dev/null; then
      return 0
    fi
    mkdir -p "$STATE_PATH"
    {
      printf 'last_alert_epoch=%s\n' "$now"
      printf 'reason=%s\n' "$detail"
    } > "$marker"
    printf 'alert=host_pressure_config_invalid\n'
    printf 'state=error\n'
    printf 'reason=%s\n' "$detail"
    printf 'cooldown_secs=%s\n' "$CONFIG_ALERT_COOLDOWN_SECS"
    return 2
  fi
  rm -f "$STATE_PATH/.host-pressure-config-alert"
  cat "$errfile" >&2
  rm -f "$errfile"
  state=$(printf '%s\n' "$out" | sed -n 's/^state=//p' | tail -1)
  case "$state" in
    critical) ;;
    *) return 0 ;;
  esac
  reason=$(printf '%s\n' "$out" | sed -n 's/^reason=//p' | tail -1)
  case "$reason" in
    *disk_floor*) ;;
    *) return "$status" ;;
  esac
  cooldown=$(fm_pressure_config_value "$CFG" disk_alert_cooldown_secs 900)
  fm_pressure_numeric_or_empty "$cooldown" disk_alert_cooldown_secs || return 2
  marker="$STATE_PATH/.host-pressure-disk-alert"
  now=$(fm_pressure_now_epoch)
  last=$(sed -n 's/^last_alert_epoch=//p' "$marker" 2>/dev/null | tail -1)
  if [ -n "$last" ] && [ "$((now - last))" -lt "$cooldown" ] 2>/dev/null; then
    return 0
  fi
  mkdir -p "$STATE_PATH"
  printf 'last_alert_epoch=%s\n' "$now" > "$marker"
  available=$(printf '%s\n' "$out" | sed -n 's/^disk_available_mb=//p' | tail -1)
  floor=$(printf '%s\n' "$out" | sed -n 's/^disk_floor_mb=//p' | tail -1)
  clear=$(printf '%s\n' "$out" | sed -n 's/^disk_clear_mb=//p' | tail -1)
  printf 'alert=disk_pressure\n'
  printf 'state=critical\n'
  printf 'reason=%s\n' "$reason"
  printf 'disk_available_mb=%s\n' "$available"
  printf 'disk_floor_mb=%s\n' "$floor"
  printf 'disk_clear_mb=%s\n' "$clear"
  printf 'cooldown_secs=%s\n' "$cooldown"
  return 0
}

case "$cmd" in
  check)
    emit_check
    exit "$?"
    ;;
  gate)
    case "$GATE_KIND" in
      spawn|test) ;;
      *) echo "error: gate requires --kind spawn|test" >&2; exit 2 ;;
    esac
    emit_check
    exit "$?"
    ;;
  periodic-alert)
    periodic_alert
    exit "$?"
    ;;
  classify-shed)
    [ -n "$COMMAND_LINE" ] || { echo "error: classify-shed requires --command" >&2; exit 2; }
    fm_pressure_shed_classify_command "$COMMAND_LINE"
    ;;
  *)
    echo "error: unknown command '$cmd'" >&2
    usage
    exit 2
    ;;
esac
