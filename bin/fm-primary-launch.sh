#!/usr/bin/env bash
# Launch or attach the one tmux-backed primary Firstmate session for this home.
# This file owns selector parsing, harness argv, compatibility checks, and exact
# Linux-side launch mechanics for the Windows wrapper in windows/firstmate.*.
#
# Usage:
#   fm-primary-launch.sh
#   fm-primary-launch.sh --codex|--pi|--grok|--claude|--opencode
#                        [--model <model>] [--effort <level>]
#
# Bare launch selects Codex with its backwards-compatible unrestricted posture.
# A selector changes only the primary harness; model and effort are optional
# independent axes. Raw harness arguments and positional prompts are rejected.
# Existing same-home sessions may be attached only when their harness is
# compatible. state/.lock remains authoritative; tmux user options are routing
# metadata. Stale locks are never removed here.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_ROOT=/home/firstmate/firstmate
PRODUCTION_HOME=/home/firstmate/firstmate
PRODUCTION_USER=firstmate
SESSION=firstmate
GROK_INSTRUCTION='Run bin/fm-session-start.sh exactly once before doing anything else.'

TEST_MODE=0
if [ "${FM_PRIMARY_LAUNCH_TESTING:-}" = 1 ] && [ "$SCRIPT_DIR" != "$PRODUCTION_ROOT/bin" ]; then
  TEST_MODE=1
  FM_ROOT=${FM_PRIMARY_ROOT_OVERRIDE:-$PRODUCTION_ROOT}
  FM_HOME_FIXED=${FM_PRIMARY_HOME_OVERRIDE:-$PRODUCTION_HOME}
  REQUIRED_USER=${FM_PRIMARY_USER_OVERRIDE:-$PRODUCTION_USER}
  SESSION=${FM_PRIMARY_SESSION_OVERRIDE:-$SESSION}
else
  FM_ROOT=$PRODUCTION_ROOT
  FM_HOME_FIXED=$PRODUCTION_HOME
  REQUIRED_USER=$PRODUCTION_USER
fi

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

harness_label() {
  case "$1" in
    codex) printf 'Codex' ;;
    pi) printf 'Pi' ;;
    grok) printf 'Grok' ;;
    claude) printf 'Claude' ;;
    opencode) printf 'OpenCode' ;;
    *) printf '%s' "$1" ;;
  esac
}

tmux_cmd() {
  if [ "$TEST_MODE" = 1 ] && [ -n "${FM_PRIMARY_TMUX_SOCKET:-}" ]; then
    tmux -L "$FM_PRIMARY_TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

session_option() {
  tmux_cmd show-options -qv -t "$SESSION" "$1" 2>/dev/null || true
}

live_lock_pid() {
  FM_HOME="$FM_HOME_FIXED" FM_ROOT_OVERRIDE="$FM_ROOT" "$FM_ROOT/bin/fm-lock.sh" live-pid 2>/dev/null
}

ensure_daemon() {
  command -v no-mistakes >/dev/null 2>&1 || fail 'no-mistakes is required'
  if ! no-mistakes daemon status 2>&1 | grep -q 'daemon running'; then
    no-mistakes daemon start || fail 'could not start the no-mistakes daemon'
  fi
}

pid_harness() {
  local root_pid=$1 pid ppid comm args candidates
  local -i depth=0
  candidates=$root_pid
  while [ "$depth" -lt 8 ]; do
    depth=$((depth + 1))
    for pid in $candidates; do
      comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
      args=$(ps -o args= -p "$pid" 2>/dev/null || true)
      case "$(basename "$comm") $args" in
        *opencode*) printf 'opencode\n'; return 0 ;;
        *claude*) printf 'claude\n'; return 0 ;;
        *codex*) printf 'codex\n'; return 0 ;;
        *grok*) printf 'grok\n'; return 0 ;;
        *'/pi '*|*' pi '*|pi\ *) printf 'pi\n'; return 0 ;;
      esac
    done
    candidates=
    while read -r pid ppid; do
      case " $root_pid " in
        *" $ppid "*) candidates="$candidates $pid" ;;
      esac
    done < <(ps -eo pid=,ppid= 2>/dev/null)
    [ -n "$candidates" ] || break
    root_pid="$root_pid $candidates"
  done
  return 1
}

session_pane_pid() {
  local pane_pid
  pane_pid=$(tmux_cmd display-message -p -t "$SESSION":0.0 '#{pane_pid}' 2>/dev/null || true)
  case "$pane_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pane_pid"
}

pid_belongs_to_pane() {
  local pid=$1 pane_pid=$2 ppid
  while [ "$pid" -gt 1 ]; do
    [ "$pid" = "$pane_pid" ] && return 0
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
    case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
    pid=$ppid
  done
  return 1
}

verify_session() {
  local recorded_home recorded_harness lock_pid pane_pid live lock_harness
  recorded_home=$(session_option '@firstmate_home')
  [ "$recorded_home" = "$FM_HOME_FIXED" ] || fail "tmux session '$SESSION' is not verified for $FM_HOME_FIXED; no state was changed"
  recorded_harness=$(session_option '@firstmate_harness')
  case "$recorded_harness" in codex|pi|grok|claude|opencode) ;; *) fail "tmux session '$SESSION' has no verified harness routing metadata; no state was changed" ;; esac
  [ "$recorded_harness" = "$HARNESS" ] || refuse_running "$recorded_harness" "$HARNESS"
  lock_pid=$(live_lock_pid || true)
  [ -n "$lock_pid" ] || fail "tmux session '$SESSION' has no authoritative live lock for $FM_HOME_FIXED; no state was changed"
  pane_pid=$(session_pane_pid || true)
  [ -n "$pane_pid" ] || fail "cannot verify the live harness in tmux session '$SESSION'; no state was changed"
  live=$(pid_harness "$pane_pid" || true)
  [ -n "$live" ] || fail "cannot verify the live harness in tmux session '$SESSION'; no state was changed"
  [ "$live" = "$HARNESS" ] || refuse_running "$live" "$HARNESS"
  pid_belongs_to_pane "$lock_pid" "$pane_pid" || fail "tmux session '$SESSION' does not own the authoritative live lock for $FM_HOME_FIXED; no state was changed"
  lock_harness=$(pid_harness "$lock_pid" || true)
  [ "$lock_harness" = "$HARNESS" ] || fail "the authoritative live lock does not match $(harness_label "$HARNESS"); no state was changed"
}

wait_for_session_lock() {
  local -i attempt=0
  while [ "$attempt" -lt 250 ]; do
    live_lock_pid >/dev/null && return 0
    attempt=$((attempt + 1))
    sleep 0.02
  done
  return 1
}

refuse_running() {
  local live=$1 requested=$2
  printf 'Firstmate is already running on %s for %s.\n' "$(harness_label "$live")" "$FM_HOME_FIXED" >&2
  printf 'Exit that primary session before starting %s; no state was changed.\n' "$(harness_label "$requested")" >&2
  exit 1
}

attach_session() {
  if [ "$TEST_MODE" = 1 ] && [ "${FM_PRIMARY_NO_ATTACH:-}" = 1 ]; then
    printf 'attached: session=%s home=%s harness=%s\n' "$SESSION" "$FM_HOME_FIXED" "$HARNESS"
    return 0
  fi
  if [ -n "${FM_PRIMARY_TMUX_SOCKET:-}" ]; then
    exec tmux -L "$FM_PRIMARY_TMUX_SOCKET" attach-session -t "$SESSION"
  fi
  exec tmux attach-session -t "$SESSION"
}

require_native_harness() {
  local executable
  executable=$(command -v "$HARNESS" 2>/dev/null || true)
  [ -n "$executable" ] || fail "native WSL/Linux harness '$HARNESS' is not installed"
  case "$executable" in
    /mnt/[a-zA-Z]/*|*.exe) fail "'$HARNESS' resolves to a Windows executable ($executable); install a native WSL/Linux build" ;;
  esac
}

run_harness() {
  local executable=$HARNESS
  local -a argv
  argv=()
  require_native_harness
  case "$HARNESS" in
    codex)
      argv+=(--dangerously-bypass-approvals-and-sandbox)
      [ -z "$MODEL" ] || argv+=(--model "$MODEL")
      [ -z "$EFFORT" ] || argv+=(-c "model_reasoning_effort=\"$EFFORT\"")
      ;;
    pi)
      [ -z "$MODEL" ] || argv+=(--model "$MODEL")
      [ -z "$EFFORT" ] || argv+=(--thinking "$EFFORT")
      ;;
    grok)
      argv+=(--trust)
      [ -z "$MODEL" ] || argv+=(--model "$MODEL")
      [ -z "$EFFORT" ] || argv+=(--reasoning-effort "$EFFORT")
      argv+=("$GROK_INSTRUCTION")
      ;;
    claude)
      [ -z "$MODEL" ] || argv+=(--model "$MODEL")
      [ -z "$EFFORT" ] || argv+=(--effort "$EFFORT")
      ;;
    opencode)
      [ -z "$MODEL" ] || argv+=(--model "$MODEL")
      ;;
    *) fail "internal unsupported harness '$HARNESS'" ;;
  esac
  export FM_HOME=$FM_HOME_FIXED
  cd "$FM_ROOT"
  exec "$executable" "${argv[@]}"
}

if [ "${1:-}" = __run ] && [ "${FM_PRIMARY_LAUNCH_INTERNAL:-}" = 1 ]; then
  HARNESS=${FM_PRIMARY_HARNESS:-}
  MODEL=${FM_PRIMARY_MODEL:-}
  EFFORT=${FM_PRIMARY_EFFORT:-}
  case "$HARNESS" in codex|pi|grok|claude|opencode) ;; *) fail 'invalid internal harness' ;; esac
  case "$EFFORT" in ''|low|medium|high|xhigh|max) ;; *) fail 'invalid internal effort' ;; esac
  case "$HARNESS:$EFFORT" in codex:max|grok:xhigh|grok:max|opencode:?*) fail 'unsupported internal effort' ;; esac
  [ "$(id -un)" = "$REQUIRED_USER" ] || fail "run this launcher as Linux user $REQUIRED_USER"
  if [ "$TEST_MODE" != 1 ] && [ "${WSL_DISTRO_NAME:-}" != Ubuntu ]; then
    fail 'run this launcher in WSL distribution Ubuntu'
  fi
  run_harness
fi

HARNESS=codex
MODEL=
EFFORT=
EXPLICIT=0
MODEL_SET=0
EFFORT_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --codex|--pi|--grok|--claude|--opencode)
      [ "$EXPLICIT" -eq 0 ] || fail 'pass exactly one harness selector'
      HARNESS=${1#--}
      EXPLICIT=1
      shift
      ;;
    --model|--effort)
      option=$1
      [ "$#" -gt 1 ] || fail "$option requires a value"
      case "$2" in --*) fail "$option requires a value" ;; esac
      [ -n "$2" ] || fail "$option requires a non-empty value"
      if [ "$option" = --model ]; then
        [ "$MODEL_SET" -eq 0 ] || fail '--model may be passed only once'
        MODEL=$2
        MODEL_SET=1
      else
        [ "$EFFORT_SET" -eq 0 ] || fail '--effort may be passed only once'
        EFFORT=$2
        EFFORT_SET=1
      fi
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    --*) fail "unknown option $1" ;;
    *) fail 'positional prompts and raw harness arguments are not supported' ;;
  esac
done

if [ "$MODEL_SET" -eq 1 ] || [ "$EFFORT_SET" -eq 1 ]; then
  [ "$EXPLICIT" -eq 1 ] || fail '--model and --effort require an explicit harness selector'
fi
case "$EFFORT" in ''|low|medium|high|xhigh|max) ;; *) fail '--effort must be one of low, medium, high, xhigh, max' ;; esac
case "$HARNESS:$EFFORT" in
  codex:max) fail 'Codex does not support effort max; use low, medium, high, or xhigh' ;;
  grok:xhigh|grok:max) fail 'Grok supports effort low, medium, or high' ;;
  opencode:?*) fail 'OpenCode interactive-primary effort selection is not verified' ;;
esac

[ "$(id -un)" = "$REQUIRED_USER" ] || fail "run this launcher as Linux user $REQUIRED_USER"
[ -d "$FM_ROOT" ] || fail "Firstmate repository root is missing: $FM_ROOT"
if [ "$TEST_MODE" != 1 ] && [ "${WSL_DISTRO_NAME:-}" != Ubuntu ]; then
  fail 'run this launcher in WSL distribution Ubuntu'
fi
command -v tmux >/dev/null 2>&1 || fail 'tmux is required'
command -v flock >/dev/null 2>&1 || fail 'flock is required'

lock_key=$(printf '%s' "$FM_HOME_FIXED" | cksum | awk '{print $1}')
launch_lock="${XDG_RUNTIME_DIR:-/tmp}/firstmate-primary-launch-$UID-$lock_key.lock"
exec 9>"$launch_lock"
flock 9

if tmux_cmd has-session -t "$SESSION" 2>/dev/null; then
  verify_session
  ensure_daemon
  flock -u 9
  attach_session
  exit 0
fi

if lock_pid=$(live_lock_pid); then
  lock_harness=$(pid_harness "$lock_pid" || true)
  if [ -n "$lock_harness" ]; then
    printf 'Firstmate has a live %s session lock for %s, but no compatible tmux session exists.\n' "$(harness_label "$lock_harness")" "$FM_HOME_FIXED" >&2
  else
    printf 'Firstmate has a live session lock for %s (pid %s), but no compatible tmux session exists.\n' "$FM_HOME_FIXED" "$lock_pid" >&2
  fi
  printf 'Exit the live primary session before launching another; the lock was not changed.\n' >&2
  exit 1
fi

require_native_harness
ensure_daemon

TMUX_ENV=(
  -e "FM_HOME=$FM_HOME_FIXED"
  -e "FM_PRIMARY_LAUNCH_INTERNAL=1"
  -e "FM_PRIMARY_HARNESS=$HARNESS"
  -e "FM_PRIMARY_MODEL=$MODEL"
  -e "FM_PRIMARY_EFFORT=$EFFORT"
)
if [ "$TEST_MODE" = 1 ]; then
  TMUX_ENV+=(
    -e 'FM_PRIMARY_LAUNCH_TESTING=1'
    -e "FM_PRIMARY_ROOT_OVERRIDE=$FM_ROOT"
    -e "FM_PRIMARY_HOME_OVERRIDE=$FM_HOME_FIXED"
    -e "FM_PRIMARY_USER_OVERRIDE=$REQUIRED_USER"
  )
fi

tmux_cmd new-session -d -s "$SESSION" -c "$FM_ROOT" "${TMUX_ENV[@]}" "exec '$FM_ROOT/bin/fm-primary-launch.sh' __run"
tmux_cmd set-option -q -t "$SESSION" @firstmate_home "$FM_HOME_FIXED"
tmux_cmd set-option -q -t "$SESSION" @firstmate_harness "$HARNESS"
if ! wait_for_session_lock; then
  tmux_cmd kill-session -t "$SESSION" 2>/dev/null || true
  fail "new '$SESSION' session did not acquire the authoritative live lock"
fi
verify_session
flock -u 9
attach_session
