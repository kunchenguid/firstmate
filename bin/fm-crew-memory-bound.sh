#!/usr/bin/env bash
# Establish an enforced memory bound around a crewmate's whole pane process tree.
# Usage:
#   fm-crew-memory-bound.sh read
#   fm-crew-memory-bound.sh preflight
#   fm-crew-memory-bound.sh check-launch <launch-command>
#   fm-crew-memory-bound.sh wrap <task-id> <launch-command>
#
# A crewmate pane is a plain shell that firstmate types a harness launch line
# into, and the crewmate then composes its own build commands inside that
# harness.  Wrapping one named command (a `cargo build`) is therefore worthless:
# the next command the crewmate types escapes it.  This script instead binds the
# launched harness and every descendant it will ever fork into one transient
# systemd scope, so a compiler the crewmate invents later is still inside the
# bound.
#
# `read` prints the validated effective bound.  `preflight` proves the mechanism
# actually enforces that bound on this host by creating a throwaway scope and
# reading back every one of its own cgroup limits, so a spawn never trusts a
# capability it has not observed.  `wrap` prints the launch line to type into the
# pane.  `check-launch` answers the one question `wrap` cannot answer late
# without orphaning state - whether a launch command can be bound at all - so a
# caller can refuse before it builds anything.
#
# Exit codes are shared by read, preflight, and wrap, and are the whole
# fail-closed contract:
#   0  a bound is configured and usable; `wrap` printed the bounded launch line
#   3  no bound is configured on this home; the caller proceeds unbounded
#   1  a bound is configured but could not be established; the caller must refuse
# `check-launch` is a bound-independent shape check and answers 0 (bindable) or
# 1 (not bindable) only.
#
# Configuration lives in config/crew-memory-bound (LOCAL, gitignored), one line:
#   <MemoryMax> [<MemoryHigh>]
# Each token is a positive integer with an optional K, M, G, or T suffix, and
# MemoryHigh, when given, must not exceed MemoryMax.  FM_CREW_MEMORY_BOUND
# overrides the file with the same syntax.
#
# The pane's own login shell stays outside the scope on purpose. Replacing it
# would mean the window dies with the harness, which would destroy the distinction
# recovery depends on between a dead pane and a live pane whose agent exited. The
# harness and everything it forks are inside, so every command a crewmate composes
# during its work is bounded; a command typed straight into the pane shell after
# the harness has exited is not, and re-launching a harness there goes back
# through fm-spawn.
#
# MemorySwapMax=0 is set unconditionally and is part of the guarantee, not a
# tunable: MemoryMax alone bounds only resident memory, so a runaway build left
# with swap would page the host into thrashing instead of dying.  memory.oom.group
# is deliberately left at its default so the kernel kills the one offending
# process - in practice the runaway compiler, by far the largest member - rather
# than the whole scope, leaving the harness alive to report the failure.
#
# A bound launch runs as `... -- <LAUNCH_SHELL> -c <launch>`, and that shell only
# replaces itself with the harness when <launch> is ONE SIMPLE COMMAND with no
# redirections.  For anything else it forks, remains the pane's foreground
# process-group leader, and tmux then reports `bash` as the pane command, which
# fm_backend_tmux_agent_state reads as `dead` - so recovery would relaunch a
# crewmate that is still working.  A launch that would land in that state is
# therefore refused rather than bound; see require_execable_launch.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_CREW_MEMORY_BOUND_FILE="crew-memory-bound"

# The interpreter the bounded launch line runs under. The preflight probe runs
# under the same one, so a host that can create the scope but lacks this shell
# fails the proof instead of failing later in the pane with no harness started.
LAUNCH_SHELL="/bin/bash"

# Set by read_bound on success.
BOUND_MAX=""
BOUND_HIGH=""
BOUND_MAX_BYTES=""
BOUND_HIGH_BYTES=""
BOUND_SOURCE=""

usage() {
  sed -n '2,7{s/^# \{0,1\}//;p;}' "$0"
}

print_error() {
  printf 'crew-memory-bound: %s\n' "$1" >&2
}

# Bytes for one size token, or empty for a token that is not a positive integer
# with an optional K/M/G/T suffix. Rejects 0 so a "bound" can never be a no-op.
size_to_bytes() {
  local token=$1 number suffix mult
  case "$token" in
    *[!0-9KMGT]*) return 1 ;;
    '') return 1 ;;
  esac
  number=${token%[KMGT]}
  suffix=${token#"$number"}
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$number" -gt 0 ] 2>/dev/null || return 1
  case "$suffix" in
    '') mult=1 ;;
    K) mult=1024 ;;
    M) mult=$((1024 * 1024)) ;;
    G) mult=$((1024 * 1024 * 1024)) ;;
    T) mult=$((1024 * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$((number * mult))"
}

# Read the configured bound into BOUND_*. Returns 0 configured, 3 unconfigured,
# 1 configured but invalid.
read_bound() {
  local raw="" path="$CONFIG/$FM_CREW_MEMORY_BOUND_FILE" lines max high max_bytes high_bytes=""

  BOUND_MAX=""
  BOUND_HIGH=""
  BOUND_MAX_BYTES=""
  BOUND_HIGH_BYTES=""
  BOUND_SOURCE=""

  if [ -n "${FM_CREW_MEMORY_BOUND:-}" ]; then
    raw=$FM_CREW_MEMORY_BOUND
    BOUND_SOURCE="FM_CREW_MEMORY_BOUND"
  else
    if [ -L "$path" ]; then
      print_error "config/$FM_CREW_MEMORY_BOUND_FILE is a symlink"
      return 1
    fi
    if [ ! -e "$path" ]; then
      return 3
    fi
    if [ ! -f "$path" ]; then
      print_error "config/$FM_CREW_MEMORY_BOUND_FILE is not a regular file"
      return 1
    fi
    lines=$(wc -l <"$path")
    if [ "$lines" -gt 1 ]; then
      print_error "config/$FM_CREW_MEMORY_BOUND_FILE must hold exactly one line"
      return 1
    fi
    raw=$(tr -d '\n' <"$path")
    BOUND_SOURCE="config/$FM_CREW_MEMORY_BOUND_FILE"
  fi

  # shellcheck disable=SC2086
  set -- $raw
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    print_error "$BOUND_SOURCE must hold '<MemoryMax> [<MemoryHigh>]' (got '$raw')"
    return 1
  fi
  max=$1
  high=${2:-}

  if ! max_bytes=$(size_to_bytes "$max"); then
    print_error "$BOUND_SOURCE MemoryMax '$max' is not a positive size such as 8G"
    return 1
  fi
  if [ -n "$high" ]; then
    if ! high_bytes=$(size_to_bytes "$high"); then
      print_error "$BOUND_SOURCE MemoryHigh '$high' is not a positive size such as 6G"
      return 1
    fi
    if [ "$high_bytes" -gt "$max_bytes" ]; then
      print_error "$BOUND_SOURCE MemoryHigh '$high' exceeds MemoryMax '$max'"
      return 1
    fi
  fi

  BOUND_MAX=$max
  BOUND_HIGH=$high
  BOUND_MAX_BYTES=$max_bytes
  BOUND_HIGH_BYTES=$high_bytes
  return 0
}

# A launch is bindable only when `<LAUNCH_SHELL> -c <launch>` will replace that
# shell with the launched harness, which it does for one simple command with no
# redirections and for nothing else. The six built-in launch templates are all
# simple commands; the raw-launch escape hatch is arbitrary shell text, so it is
# constrained here rather than merely documented - a live crewmate that reads as
# dead gets recovered on top of its own running task.
#
# The scan walks the string tracking quoting and command-substitution context and
# rejects a top-level (unquoted, unsubstituted) shell operator. Operators inside
# quotes or inside $(...)/`...` belong to another command and do not make the
# outer command non-simple.
launch_shape_refusal() {
  print_error "launch command cannot be bound: $1, so $LAUNCH_SHELL would fork instead of becoming the harness and the pane would report a shell - which supervision reads as a dead crewmate"
}

require_execable_launch() {
  local s=$1 n i ch nx stack='' top nl bs
  nl='
'
  bs=$'\\'
  n=${#s}
  i=0
  while [ "$i" -lt "$n" ]; do
    ch=${s:$i:1}
    if [ -n "$stack" ]; then top=${stack: -1}; else top=''; fi
    case "$top" in
      S)
        [ "$ch" != "'" ] || stack=${stack%?}
        i=$((i + 1))
        continue
        ;;
      B)
        case "$ch" in
          "$bs") i=$((i + 2)); continue ;;
          '`') stack=${stack%?} ;;
        esac
        i=$((i + 1))
        continue
        ;;
    esac
    nx=${s:$((i + 1)):1}
    case "$ch" in
      "$bs") i=$((i + 2)); continue ;;
      '`') stack="${stack}B" ;;
      '$')
        if [ "$nx" = '(' ]; then
          stack="${stack}U"
          i=$((i + 2))
          continue
        fi
        ;;
      '"')
        if [ "$top" = D ]; then stack=${stack%?}; else stack="${stack}D"; fi
        ;;
      "'")
        [ "$top" = D ] || stack="${stack}S"
        ;;
      '(')
        case "$top" in
          U | P) stack="${stack}P" ;;
          D) ;;
          *) launch_shape_refusal "'(' groups or subshells commands"; return 1 ;;
        esac
        ;;
      ')')
        case "$top" in
          U | P) stack=${stack%?} ;;
          D) ;;
          *) launch_shape_refusal "')' is unbalanced"; return 1 ;;
        esac
        ;;
      '|' | '&' | ';' | '<' | '>' | "$nl")
        if [ -z "$top" ]; then
          launch_shape_refusal "'$ch' makes it a pipeline, list, or redirection rather than one simple command"
          return 1
        fi
        ;;
    esac
    i=$((i + 1))
  done
  if [ -n "$stack" ]; then
    launch_shape_refusal "its quoting or command substitution is unbalanced"
    return 1
  fi
  return 0
}

# Single-quote one argument for safe reuse in a typed shell line. Arguments made
# only of characters no shell treats specially are left bare so the line the
# crewmate sees in its pane stays readable.
shell_quote() {
  case "$1" in
    '' | *[!A-Za-z0-9_./=:,+-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Unit names take a restricted alphabet; anything else becomes a dash so a task
# id can never produce an unusable or ambiguous unit.
sanitize_unit_atom() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9_.-' '-'
}

# The scope invocation shared by preflight's probe and the real launch, built
# once as an argv array so the probe can execute it directly and `wrap` can
# render the same flags into a typed shell line.
SCOPE_ARGS=()

build_scope_args() {
  local unit=$1
  SCOPE_ARGS=(
    systemd-run --user --scope --quiet --collect
    "--unit=$(sanitize_unit_atom "$unit").scope"
    "--description=firstmate crew memory bound $unit"
    -p "MemoryMax=$BOUND_MAX"
    -p MemorySwapMax=0
  )
  if [ -n "$BOUND_HIGH" ]; then
    SCOPE_ARGS+=(-p "MemoryHigh=$BOUND_HIGH")
  fi
}

# The probe body: report this process's own cgroup path and then EVERY limit the
# scope claims to set, so enforcement is read back from the kernel rather than
# assumed. A limit file that cannot be read reports `absent` rather than aborting
# the probe, so an unreadable limit fails the proof instead of being mistaken for
# a scope that could not be created.
# shellcheck disable=SC2016  # expands in the probe's own shell, not this one
PROBE_BODY='p=$(cut -d: -f3 /proc/self/cgroup); printf "%s\n" "$p"; for f in memory.max memory.high memory.swap.max; do cat "/sys/fs/cgroup$p/$f" 2>/dev/null || printf "absent\n"; done'

# Prove enforcement rather than infer it: run a throwaway scope that reports its
# own cgroup path and limits, then require that the path is not the root cgroup
# and that every limit the scope was asked for is the one the kernel holds.
# systemd starts a scope even when a property write to the kernel fails, so
# reading back only memory.max would call a scope proven while swap was left
# unbounded - the exact thing MemorySwapMax=0 exists to prevent.
prove_enforcement() {
  local unit out cg max_read high_read swap_read
  unit="fm-crew-memory-probe-$$-$(date +%s)"

  if ! command -v systemd-run >/dev/null 2>&1; then
    print_error "systemd-run is not available, so a configured bound cannot be enforced"
    return 1
  fi

  build_scope_args "$unit"
  if ! out=$("${SCOPE_ARGS[@]}" -- "$LAUNCH_SHELL" -c "$PROBE_BODY" 2>&1); then
    print_error "could not create a bounded scope: ${out:-systemd-run failed}"
    return 1
  fi

  cg=$(printf '%s\n' "$out" | sed -n '1p')
  max_read=$(printf '%s\n' "$out" | sed -n '2p')
  high_read=$(printf '%s\n' "$out" | sed -n '3p')
  swap_read=$(printf '%s\n' "$out" | sed -n '4p')

  if [ -z "$cg" ] || [ "$cg" = "/" ]; then
    print_error "a bounded scope left its processes in the root cgroup"
    return 1
  fi
  if [ "$max_read" != "$BOUND_MAX_BYTES" ]; then
    print_error "a bounded scope reported memory.max='$max_read', expected '$BOUND_MAX_BYTES'"
    return 1
  fi
  if [ -n "$BOUND_HIGH" ] && [ "$high_read" != "$BOUND_HIGH_BYTES" ]; then
    print_error "a bounded scope reported memory.high='$high_read', expected '$BOUND_HIGH_BYTES'"
    return 1
  fi
  if [ "$swap_read" != 0 ]; then
    print_error "a bounded scope reported memory.swap.max='$swap_read', expected '0'; without it a runaway build pages the host into thrashing instead of dying"
    return 1
  fi
  return 0
}

cmd_read() {
  local rc=0
  read_bound || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf 'max=%s\n' "$BOUND_MAX"
  [ -z "$BOUND_HIGH" ] || printf 'high=%s\n' "$BOUND_HIGH"
  printf 'source=%s\n' "$BOUND_SOURCE"
}

cmd_preflight() {
  local rc=0
  read_bound || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  prove_enforcement || return 1
  printf 'max=%s\n' "$BOUND_MAX"
  [ -z "$BOUND_HIGH" ] || printf 'high=%s\n' "$BOUND_HIGH"
  printf 'enforced=proven\n'
}

cmd_check_launch() {
  require_execable_launch "$1" || return 1
}

cmd_wrap() {
  local id=$1 launch=$2 rc=0 unit arg line
  read_bound || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  require_execable_launch "$launch" || return 1
  unit="fm-crew-$id-$(date +%s)"
  build_scope_args "$unit"
  line=""
  for arg in "${SCOPE_ARGS[@]}"; do
    line="$line$(shell_quote "$arg") "
  done
  printf '%s-- %s -c %s\n' "$line" "$(shell_quote "$LAUNCH_SHELL")" "$(shell_quote "$launch")"
}

case "${1:-}" in
  read)
    shift
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    cmd_read
    ;;
  preflight)
    shift
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    cmd_preflight
    ;;
  check-launch)
    shift
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    cmd_check_launch "$1"
    ;;
  wrap)
    shift
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    cmd_wrap "$1" "$2"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
