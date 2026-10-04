#!/usr/bin/env bash
# fm-mem-alert.sh - alert firstmate when host memory crosses the alert threshold.
#
# A one-minute check (installed as a systemd user timer by
# bin/fm-mem-protection-install.sh) samples /proc/meminfo and, when used memory
# passes the threshold, queues ONE firstmate note naming the top memory consumer
# by RSS. The note is the alert: it carries a durable record and a check wake.
#
# Usage:
#   fm-mem-alert.sh check [--meminfo <file>] [--procfs <dir>] [--state <file>]
#                         [--now <epoch>] [--emit <command>] [--print]
#   fm-mem-alert.sh status
#
# `check`   samples memory, updates the armed/fired state, and emits one alert on
#           a crossing. `--print` prints the alert body and the emit command
#           without changing state or emitting, for inspection on a quiet host.
# `status`  prints the fixed threshold, state, and current sample.
#
# Environment:
#   FM_HOME, FM_STATE_OVERRIDE   as elsewhere in bin/.
#   FM_MEM_ALERT_STATE    state file (default $state/mem-alert.state)
#   FM_MEM_ALERT_MEMINFO  meminfo source (default /proc/meminfo)
#   FM_MEM_ALERT_PROCFS   proc mount point (default /proc)
#   FM_MEM_ALERT_EMIT     command invoked as `<command> <body>` instead of the
#                         default `bin/fm-inbox.sh note`
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_MEM_ALERT_THRESHOLD=85
FM_MEM_ALERT_MEMINFO=${FM_MEM_ALERT_MEMINFO:-/proc/meminfo}
FM_MEM_ALERT_PROCFS=${FM_MEM_ALERT_PROCFS:-/proc}
FM_MEM_ALERT_STATE=${FM_MEM_ALERT_STATE:-$STATE/mem-alert.state}

usage() {
  sed -n '2,/^set -u/{ /^set -u/d;s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'fm-mem-alert: %s\n' "$*" >&2
  exit 2
}

# fm_mem_alert_used_percent <meminfo>
fm_mem_alert_used_percent() {
  local file=$1 total='' available='' key value
  [ -r "$file" ] || die "cannot read meminfo source: $file"
  while read -r key value _; do
    case "$key" in
      MemTotal:) total=$value ;;
      MemAvailable:) available=$value ;;
    esac
    [ -n "$total" ] && [ -n "$available" ] && break
  done < "$file"
  case "$total" in
    ''|*[!0-9]*) die "meminfo source has no MemTotal: $file" ;;
  esac
  case "$available" in
    ''|*[!0-9]*) die "meminfo source has no MemAvailable: $file" ;;
  esac
  [ "$total" -gt 0 ] || die "meminfo source reports zero MemTotal: $file"
  printf '%s\n' "$(((total - available) * 100 / total))"
}

# fm_mem_alert_top_process <procfs>
# Prints "<pid> <rss-kb> <name>" for the largest-RSS process, or nothing.
fm_mem_alert_top_process() {
  local procfs=$1 status pid rss best_rss=-1 best_pid='' comm
  for status in "$procfs"/[0-9]*/status; do
    [ -r "$status" ] || continue
    pid=${status#"$procfs"/}
    pid=${pid%/status}
    rss=$(awk '$1=="VmRSS:"{print $2}' "$status" 2>/dev/null)
    [ -n "$rss" ] || continue
    case "$rss" in *[!0-9]*) continue ;; esac
    if [ "$rss" -gt "$best_rss" ]; then
      best_rss=$rss
      best_pid=$pid
    fi
  done
  [ -n "$best_pid" ] || return 0
  comm=$(tr -d '\n' < "$procfs/$best_pid/comm" 2>/dev/null) || comm=unknown
  [ -n "$comm" ] || comm=unknown
  printf '%s %s %s\n' "$best_pid" "$best_rss" "$comm"
}

# fm_mem_alert_body <used> <threshold> <top>
fm_mem_alert_body() {
  local used=$1 threshold=$2 top=$3 pid rss name mb
  printf 'memory alert: host memory at %s%% used (alert threshold %s%%)' "$used" "$threshold"
  if [ -n "$top" ]; then
    read -r pid rss name <<<"$top"
    mb=$((rss / 1024))
    printf '; top process %s pid=%s rss=%sMiB' "$name" "$pid" "$mb"
  fi
}

# fm_mem_alert_emit <body>
fm_mem_alert_emit() {
  local body=$1 now=${FM_MEM_ALERT_NOW:-$(date +%s)}
  if [ -n "${FM_MEM_ALERT_EMIT:-}" ]; then
    bash -c "$FM_MEM_ALERT_EMIT" fm-mem-alert "$body"
    return $?
  fi
  "$FM_ROOT/bin/fm-inbox.sh" note --request-id "mem-alert-$now" -- "$body"
}

fm_mem_alert_state_read() {
  [ -r "$FM_MEM_ALERT_STATE" ] || { printf 'armed\n'; return 0; }
  local line
  line=$(head -n 1 "$FM_MEM_ALERT_STATE" 2>/dev/null) || line=
  case "$line" in
    fired) printf 'fired\n' ;;
    *) printf 'armed\n' ;;
  esac
}

fm_mem_alert_state_write() {
  local value=$1 dir
  dir=${FM_MEM_ALERT_STATE%/*}
  [ -n "$dir" ] && [ ! -d "$dir" ] && mkdir -p "$dir" 2>/dev/null
  (umask 077; printf '%s\n' "$value" > "$FM_MEM_ALERT_STATE") 2>/dev/null || true
}

cmd_status() {
  local threshold=$FM_MEM_ALERT_THRESHOLD used state
  used=$(fm_mem_alert_used_percent "$FM_MEM_ALERT_MEMINFO") || exit $?
  state=$(fm_mem_alert_state_read)
  printf 'meminfo=%s\n' "$FM_MEM_ALERT_MEMINFO"
  printf 'threshold-percent=%s\n' "$threshold"
  printf 'used-percent=%s\n' "$used"
  printf 'state=%s\n' "$state"
  printf 'state-file=%s\n' "$FM_MEM_ALERT_STATE"
}

cmd_check() {
  local meminfo=$FM_MEM_ALERT_MEMINFO procfs=$FM_MEM_ALERT_PROCFS state=$FM_MEM_ALERT_STATE
  local now='' print_only=0 emit=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --meminfo) [ "$#" -gt 1 ] || die "--meminfo requires a path"; meminfo=$2; shift 2 ;;
      --meminfo=*) meminfo=${1#--meminfo=}; shift ;;
      --procfs) [ "$#" -gt 1 ] || die "--procfs requires a path"; procfs=$2; shift 2 ;;
      --procfs=*) procfs=${1#--procfs=}; shift ;;
      --state) [ "$#" -gt 1 ] || die "--state requires a path"; state=$2; shift 2 ;;
      --state=*) state=${1#--state=}; shift ;;
      --now) [ "$#" -gt 1 ] || die "--now requires an epoch"; now=$2; shift 2 ;;
      --now=*) now=${1#--now=}; shift ;;
      --emit) [ "$#" -gt 1 ] || die "--emit requires a command"; emit=$2; shift 2 ;;
      --emit=*) emit=${1#--emit=}; shift ;;
      --print) print_only=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown check argument: $1" ;;
    esac
  done

  FM_MEM_ALERT_MEMINFO=$meminfo
  FM_MEM_ALERT_PROCFS=$procfs
  FM_MEM_ALERT_STATE=$state
  [ -n "$now" ] && FM_MEM_ALERT_NOW=$now
  [ -n "$emit" ] && FM_MEM_ALERT_EMIT=$emit

  local threshold=$FM_MEM_ALERT_THRESHOLD used prev top body
  used=$(fm_mem_alert_used_percent "$meminfo") || exit $?
  prev=$(fm_mem_alert_state_read)

  if [ "$print_only" = 1 ]; then
    top=$(fm_mem_alert_top_process "$procfs")
    body=$(fm_mem_alert_body "$used" "$threshold" "$top")
    printf '%s\n' "$body"
    return 0
  fi

  if [ "$used" -lt "$threshold" ]; then
    # Below the alert level: re-arm so the next crossing alerts again.
    if [ "$prev" != armed ]; then
      fm_mem_alert_state_write armed
    fi
    return 0
  fi

  if [ "$prev" = fired ]; then
    return 0
  fi

  top=$(fm_mem_alert_top_process "$procfs")
  body=$(fm_mem_alert_body "$used" "$threshold" "$top")
  if fm_mem_alert_emit "$body"; then
    fm_mem_alert_state_write fired
  else
    printf 'fm-mem-alert: alert emission failed\n' >&2
    return 1
  fi
  return 0
}

main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  local sub=$1
  shift
  case "$sub" in
    check) cmd_check "$@" ;;
    status) cmd_status "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
