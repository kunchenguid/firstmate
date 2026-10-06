#!/usr/bin/env bash
# fm-mem-box.sh - run a command inside a bounded cgroup v2 memory box.
#
# Every worker and test a firstmate home launches runs under a per-lane
# memory cap, so a runaway leak dies inside its own box instead of taking the
# whole host to the edge of swap. bin/fm-spawn.sh re-execs each worker's pane
# shell through `exec`, so the agent and everything it spawns share one box, and
# bin/fm-test-run.sh boxes each behavior-test script the same way. The box is a
# systemd user scope:
#
#   systemd-run --user --scope -p MemoryMax=<cap> -p MemorySwapMax=0 -- <cmd...>
#
# MemorySwapMax=0 is deliberate: a boxed process never grows into swap, so an
# over-limit allocation is killed by the kernel at the box boundary rather than
# thrashing the host. The default cap is 8 GiB and per-lane overrides are
# configured in `config/memory-box`.
#
# Usage:
#   fm-mem-box.sh check
#   fm-mem-box.sh cap <lane>
#   fm-mem-box.sh exec <lane> [--unit <name>] -- <command> [args...]
#
# `check`   reports the effective cgroup v2 delegation facts and every lane cap.
# `cap`     prints the effective byte cap for <lane>.
# `exec`    runs the command inside the box (foreground; the box lifetime is the
#           command's lifetime). The command's own exit status is returned.
#
# Configuration (all optional, all in this home's gitignored config/):
#   config/memory-box            one `key=value` per line; `default=<size>` sets
#                                the fallback cap and `<lane>=<size>` overrides a
#                                lane. <size> is a positive decimal byte count
#                                with an optional K/M/G/T suffix (1024-based).
#
# Environment:
#   FM_MEM_BOX_CAP        one-invocation size override; wins over configured caps.
#   FM_CONFIG_OVERRIDE    config directory override (as elsewhere in bin/).
#   FM_MEM_BOX_LANES      space-separated lane names for `check` (optional).
#
# A host that cannot delegate a cgroup v2 memory scope refuses execution.
# A lane named `heavy` additionally consults bin/fm-heavy-guard.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_MEM_BOX_CONFIG_FILE="memory-box"
FM_MEM_BOX_DEFAULT_CAP=8589934592 # 8 GiB
FM_MEM_BOX_LANE_RE='^[A-Za-z0-9_.-]+$'
FM_MEM_BOX_CAP_SOURCE=""
FM_MEM_BOX_CAP_VALUE=""
FM_MEM_BOX_CAP_ERROR=""

usage() {
  sed -n '2,/^set -u/{ /^set -u/d;s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'fm-mem-box: %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------- size parsing

# fm_mem_box_parse_size <size>
# Prints the byte count for a validated size. Accepts a positive decimal number
# with an optional single K/M/G/T suffix interpreted as 1024^n.
fm_mem_box_parse_size() {
  local size=$1 num='' mult=''
  case "$size" in
    *[Kk]) num=${size%?}; mult=1024 ;;
    *[Mm]) num=${size%?}; mult=1048576 ;;
    *[Gg]) num=${size%?}; mult=1073741824 ;;
    *[Tt]) num=${size%?}; mult=1099511627776 ;;
    *[0-9]) num=$size; mult=1 ;;
    *) return 1 ;;
  esac
  case "$num" in
    ''|0|0*|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$((num * mult))"
}

fm_mem_box_cap_error() {
  FM_MEM_BOX_CAP_ERROR=$1
  return 1
}

# fm_mem_box_cap <lane>
# Prints the effective byte cap for <lane> and records its source in
# FM_MEM_BOX_CAP_SOURCE. A malformed configured value is a hard error rather
# than an inferred default.
fm_mem_box_cap() {
  local lane=$1 path line key value seen_default=0 lane_cap='' plain='' bytes=''
  FM_MEM_BOX_CAP_SOURCE=""
  FM_MEM_BOX_CAP_VALUE=""
  FM_MEM_BOX_CAP_ERROR=""
  [ -n "$lane" ] || return 1

  if [ -n "${FM_MEM_BOX_CAP:-}" ]; then
    bytes=$(fm_mem_box_parse_size "$FM_MEM_BOX_CAP") \
      || fm_mem_box_cap_error "FM_MEM_BOX_CAP is not a valid size: $FM_MEM_BOX_CAP" || return 1
    FM_MEM_BOX_CAP_SOURCE='env'
    FM_MEM_BOX_CAP_VALUE=$bytes
    printf '%s\n' "$bytes"
    return 0
  fi

  path="$CONFIG/$FM_MEM_BOX_CONFIG_FILE"
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ -L "$path" ] || [ ! -f "$path" ]; then
      fm_mem_box_cap_error "config/$FM_MEM_BOX_CONFIG_FILE is not an ordinary regular file" || return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=${line#"${line%%[![:space:]]*}"}
      line=${line%"${line##*[![:space:]]}"}
      [ -n "$line" ] || continue
      case "$line" in
        *=*) ;;
        *) fm_mem_box_cap_error "config/$FM_MEM_BOX_CONFIG_FILE line is not key=value: $line" || return 1 ;;
      esac
      key=${line%%=*}
      value=${line#*=}
      case "$key" in
        default) seen_default=1 ;;
        *) [[ "$key" =~ $FM_MEM_BOX_LANE_RE ]] \
          || fm_mem_box_cap_error "config/$FM_MEM_BOX_CONFIG_FILE has an invalid lane key: $key" || return 1 ;;
      esac
      bytes=$(fm_mem_box_parse_size "$value") \
        || fm_mem_box_cap_error "config/$FM_MEM_BOX_CONFIG_FILE has an invalid size for '$key': $value" || return 1
      if [ "$key" = default ]; then
        plain=$bytes
      elif [ "$key" = "$lane" ]; then
        lane_cap=$bytes
      fi
    done < "$path"
  fi

  if [ -n "$lane_cap" ]; then
    FM_MEM_BOX_CAP_SOURCE=lane
    FM_MEM_BOX_CAP_VALUE=$lane_cap
    printf '%s\n' "$lane_cap"
    return 0
  fi
  if [ "$seen_default" = 1 ]; then
    FM_MEM_BOX_CAP_SOURCE=default
    FM_MEM_BOX_CAP_VALUE=$plain
    printf '%s\n' "$plain"
    return 0
  fi
  FM_MEM_BOX_CAP_SOURCE=builtin
  FM_MEM_BOX_CAP_VALUE=$FM_MEM_BOX_DEFAULT_CAP
  printf '%s\n' "$FM_MEM_BOX_DEFAULT_CAP"
  return 0
}

# ------------------------------------------------------------- host capability

# fm_mem_box_supported
# True when this host can delegate a cgroup v2 user memory scope.
fm_mem_box_supported() {
  command -v systemd-run >/dev/null 2>&1 || return 1
  [ -f /sys/fs/cgroup/cgroup.controllers ] || return 1
  fm_mem_box_prepare_env
  systemd-run --user --scope --quiet -p MemoryMax=67108864 -p MemorySwapMax=0 -- true >/dev/null 2>&1
}

fm_mem_box_prepare_env() {
  if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
  fi
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] \
    && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  fi
}

fm_mem_box_unsupported_reason() {
  if ! command -v systemd-run >/dev/null 2>&1; then
    printf 'systemd-run is not installed (systemd user manager required)'
  elif [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
    printf 'cgroup v2 is not mounted'
  else
    printf 'cgroup v2 delegation / systemd user manager cannot create a memory scope'
  fi
}

# ------------------------------------------------------------------ subcommands

cmd_check() {
  local lanes lane supported=no
  printf 'script=%s\n' "$FM_ROOT/bin/fm-mem-box.sh"
  if command -v systemd-run >/dev/null 2>&1; then
    printf 'systemd-run=%s\n' "$(command -v systemd-run)"
  else
    printf 'systemd-run=absent\n'
  fi
  if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    printf 'cgroup2=yes\n'
  else
    printf 'cgroup2=no\n'
  fi
  if fm_mem_box_supported; then
    supported=yes
  fi
  printf 'supported=%s\n' "$supported"
  [ "$supported" = yes ] || printf 'unsupported-reason=%s\n' "$(fm_mem_box_unsupported_reason)"
  printf 'default-cap-bytes=%s\n' "$FM_MEM_BOX_DEFAULT_CAP"
  lanes="${FM_MEM_BOX_LANES:-worker test heavy}"
  for lane in $lanes; do
    if ! fm_mem_box_cap "$lane" >/dev/null; then
      printf 'lane=%s error=%s\n' "$lane" "$FM_MEM_BOX_CAP_ERROR"
      continue
    fi
    printf 'lane=%s cap=%s source=%s\n' "$lane" "$FM_MEM_BOX_CAP_VALUE" "$FM_MEM_BOX_CAP_SOURCE"
  done
}

cmd_cap() {
  [ "$#" -eq 1 ] || die "cap requires exactly one lane"
  # Call in the current shell so FM_MEM_BOX_CAP_ERROR survives; a command
  # substitution would set it in a subshell and lose the message.
  if ! fm_mem_box_cap "$1" >/dev/null; then
    die "$FM_MEM_BOX_CAP_ERROR"
  fi
  printf '%s\n' "$FM_MEM_BOX_CAP_VALUE"
}

# Refuse a heavy lane on a host whose config routes heavy work to the campaign VM.
fm_mem_box_guard_heavy() {
  local lane=$1 guard="$FM_ROOT/bin/fm-heavy-guard.sh"
  [ "$lane" = heavy ] || return 0
  [ -f "$guard" ] || return 0
  bash "$guard" check --lane heavy
}

cmd_exec() {
  [ "$#" -ge 3 ] || die "exec requires: <lane> -- <command> [args...]"
  local lane=$1
  shift
  local -a unit_args=()
  if [ "${1:-}" = --unit ]; then
    [ "$#" -ge 4 ] && [ -n "$2" ] || die "--unit requires a name and command"
    unit_args=("--unit=$2")
    shift 2
  fi
  [ "$1" = -- ] || die "exec requires -- before the command"
  shift
  [ "$#" -ge 1 ] || die "exec requires a command after --"
  fm_mem_box_guard_heavy "$lane" || exit $?

  local cap
  if ! fm_mem_box_cap "$lane" >/dev/null; then
    die "$FM_MEM_BOX_CAP_ERROR"
  fi
  cap=$FM_MEM_BOX_CAP_VALUE

  if ! fm_mem_box_supported; then
    die "memory box unavailable ($(fm_mem_box_unsupported_reason)); refusing to run lane '$lane' unboxed"
  fi

  unset FM_MEM_BOX_CAP
  exec systemd-run --user --scope --quiet --collect "${unit_args[@]}" \
    -p "MemoryMax=$cap" -p MemorySwapMax=0 -- "$@"
}

main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  local sub=$1
  shift
  case "$sub" in
    check) cmd_check "$@" ;;
    cap) cmd_cap "$@" ;;
    exec) cmd_exec "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
