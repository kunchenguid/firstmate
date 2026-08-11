#!/usr/bin/env bash
# Provision and operate an isolated Herdr lab session without risking the live
# default session.
#
# Usage:
#   fm-herdr-lab.sh name <label>
#   fm-herdr-lab.sh prepare <session>
#   fm-herdr-lab.sh provision <session>
#   fm-herdr-lab.sh run <session> <herdr arguments...>
#   fm-herdr-lab.sh run-argv <session> agent start <flags...> -- <agent argv...>
#   fm-herdr-lab.sh stop <session>
#   fm-herdr-lab.sh teardown <session>
#
# Session names must begin with "fm-lab-" and can never be "default".
# Every ordinary Herdr call made here carries a trailing --session <session>.
# The agent-start exception inserts the selector immediately before its argv
# separator, where Herdr consumes it instead of forwarding it to the agent.
# The run command rejects caller-supplied --session flags, any leading option
# before the subcommand, all session lifecycle operations, and every server
# operation.
# Session stop is available only through guarded stop or teardown, and session
# delete is available only through teardown.
# Both paths perform a fresh refuse-default check immediately before each
# destructive call.
# Provisioning and every destructive boundary (the lab server launch, guarded
# stop and delete, and forwarded run commands other than plain status/list
# reads) also first re-prove that the default session is running, refusing
# loudly on a stopped or unreadable default.
# Provision records the running default session, its workspace/tab/pane
# topology, and its agent identities as a fleet-state tripwire. Teardown
# requires that record to be identical afterward.
# FM_HERDR_LAB_PROVISION_TIMEOUT_SECONDS is a whole number from 1 through 600.
# It defaults to 120 so a loaded fleet gets a fair but bounded startup window.
set -u

fm_herdr_lab_error() {
  echo "fm-herdr-lab: $*" >&2
}

fm_herdr_lab_validate_name() { # <session>
  local name=${1:-}
  [[ "$name" =~ ^fm-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && return 0
  case "$name" in
    default) fm_herdr_lab_error "refusing session name 'default'" ;;
    '') fm_herdr_lab_error "refusing an empty session name" ;;
    *) fm_herdr_lab_error "session name must start with 'fm-lab-' and contain only letters, digits, underscores, or dashes: $name" ;;
  esac
  return 1
}

fm_herdr_lab_state_dir() {
  printf '%s' "${FM_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/fm-herdr-lab-${UID}}"
}

fm_herdr_lab_tripwire_path() { # <session>
  printf '%s/%s.fleet-state.json' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_raw() { # <session> <herdr arguments...>
  local name=$1
  shift
  HERDR_SESSION="$name" herdr "$@" --session "$name"
}

fm_herdr_lab_raw_argv() { # <session> agent start <flags...> -- <agent argv...>
  local name=$1 arg seen_sep=0
  local -a pre=() post=()
  shift
  for arg in "$@"; do
    if [ "$seen_sep" = 0 ] && [ "$arg" = -- ]; then
      seen_sep=1
      continue
    fi
    if [ "$seen_sep" = 1 ]; then post+=("$arg"); else pre+=("$arg"); fi
  done
  [ "$seen_sep" = 1 ] && [ "${#post[@]}" -gt 0 ] || return 1
  HERDR_SESSION="$name" herdr "${pre[@]}" --session "$name" -- "${post[@]}"
}

fm_herdr_lab_session_list() { # <session>
  fm_herdr_lab_raw "$1" session list --json
}

fm_herdr_lab_default_read() { # <herdr arguments...>
  HERDR_SESSION=default herdr "$@" --session default
}

fm_herdr_lab_fleet_state() { # <session>
  local name=$1 sessions workspaces tabs panes agents snapshot
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot read Herdr sessions for the fleet-state tripwire"
    return 1
  }
  snapshot=$(printf '%s' "$sessions" | jq -c '
    [.sessions[]? | select(.default == true)]
    | if length == 1 and .[0].name == "default"
      then .[0] | {name, default, running, socket_path}
      else empty
      end
  ' 2>/dev/null)
  [ -n "$snapshot" ] || {
    fm_herdr_lab_error "fleet-state tripwire requires exactly one named default session"
    return 1
  }
  workspaces=$(fm_herdr_lab_default_read workspace list 2>/dev/null) || {
    fm_herdr_lab_error "cannot read default workspaces for the fleet-state tripwire"
    return 1
  }
  tabs=$(fm_herdr_lab_default_read tab list 2>/dev/null) || {
    fm_herdr_lab_error "cannot read default tabs for the fleet-state tripwire"
    return 1
  }
  panes=$(fm_herdr_lab_default_read pane list 2>/dev/null) || {
    fm_herdr_lab_error "cannot read default panes for the fleet-state tripwire"
    return 1
  }
  agents=$(fm_herdr_lab_default_read agent list 2>/dev/null) || {
    fm_herdr_lab_error "cannot read default agents for the fleet-state tripwire"
    return 1
  }
  jq -cn --argjson session "$snapshot" \
    --argjson workspaces "$workspaces" --argjson tabs "$tabs" \
    --argjson panes "$panes" --argjson agents "$agents" '
    def stable:
      walk(if type == "object" then
        del(.agent_status, .status, .state, .activity, .last_activity,
            .last_activity_at, .updated_at, .focused, .is_focused,
            .active, .selected, .revision, .scroll)
      else . end);
    def required_array($payload; $key):
      if ($payload.result[$key] | type) == "array"
      then ($payload.result[$key] | stable | sort_by(tojson))
      else error("missing " + $key + " array")
      end;
    {session: $session,
     workspaces: required_array($workspaces; "workspaces"),
     tabs: required_array($tabs; "tabs"),
     panes: required_array($panes; "panes"),
     agents: required_array($agents; "agents")}' 2>/dev/null || {
      fm_herdr_lab_error "default fleet topology or agent identity response was malformed"
      return 1
    }
}

fm_herdr_lab_prepare() { # <session>
  local name=$1 sessions state_dir tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_error "session '$name' already exists; refusing to adopt or overwrite it"
    return 1
  fi
  fm_herdr_lab_require_default_running "$name" prepare || return 1

  state_dir=$(fm_herdr_lab_state_dir)
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  mkdir -p "$state_dir" || return 1
  [ ! -e "$tripwire" ] || {
    fm_herdr_lab_error "tripwire already exists for '$name'; refusing ambiguous ownership"
    return 1
  }
  fm_herdr_lab_fleet_state "$name" > "$tripwire" || {
    rm -f "$tripwire"
    return 1
  }
}

fm_herdr_lab_refuse_if_default() { # <session>
  local name=$1 info flag
  fm_herdr_lab_validate_name "$name" || return 1
  info=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "refusing destructive call because session list failed"
    return 1
  }
  flag=$(printf '%s' "$info" | jq -r --arg name "$name" \
    '.sessions[]? | select(.name == $name) | .default' 2>/dev/null)
  [ "$flag" = false ] && return 0
  fm_herdr_lab_error "refusing destructive call for '$name': session is absent or default (default=${flag:-<not found>})"
  return 1
}

fm_herdr_lab_require_default_running() { # <session> <operation>
  local name=$1 operation=$2 sessions running
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "refusing $operation for '$name': cannot read Herdr sessions to prove the default session is running"
    return 1
  }
  running=$(printf '%s' "$sessions" | jq -r '
    if (.sessions | type) == "array" then
      [.sessions[] | select(type == "object" and .default == true)]
      | if length == 1 and .[0].name == "default" and .[0].running == true
        then "true"
        else empty
        end
    else
      empty
    end
  ' 2>/dev/null)
  [ "$running" = true ] && return 0
  fm_herdr_lab_error "refusing $operation for '$name': the default Herdr session is not proven running (running=${running:-<not found>}); start the default session and retry once 'herdr session list --json' reports it running"
  return 1
}

fm_herdr_lab_cli() { # <session> <herdr arguments...>
  local name=$1 arg
  shift
  fm_herdr_lab_validate_name "$name" || return 1
  [ "$#" -gt 0 ] || { fm_herdr_lab_error "run requires Herdr arguments"; return 1; }
  case "$1" in
    -*)
      fm_herdr_lab_error "run forbids a leading option before the Herdr subcommand; it could shift a server or session lifecycle operation past the guard or subvert session isolation"
      return 1
      ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      --session|--session=*)
        fm_herdr_lab_error "run forbids caller-supplied --session; the helper appends the lab session"
        return 1
        ;;
    esac
  done
  case "$1 ${2:-}" in
    "server "*)
      fm_herdr_lab_error "run forbids server operations; use provision for the named lab server"
      return 1
      ;;
    "session list") ;;
    "session "*)
      fm_herdr_lab_error "run forbids session lifecycle operations; use guarded teardown"
      return 1
      ;;
  esac
  case "$1 ${2:-}" in
    "status "*|*" list") ;;
    *)
      # Plain status/list reads stay available for diagnosis; any other
      # forwarded command may mutate lab state, so re-prove the running
      # default session first.
      fm_herdr_lab_require_default_running "$name" run || return 1
      ;;
  esac
  fm_herdr_lab_raw "$name" "$@"
}

fm_herdr_lab_cli_argv() { # <session> agent start <flags...> -- <agent argv...>
  local name=$1 arg seen_sep=0 post_count=0
  shift
  fm_herdr_lab_validate_name "$name" || return 1
  [ "${1:-} ${2:-}" = "agent start" ] || {
    fm_herdr_lab_error "run-argv permits only agent start"
    return 1
  }
  for arg in "$@"; do
    if [ "$seen_sep" = 1 ]; then
      post_count=$((post_count + 1))
    elif [ "$arg" = -- ]; then
      seen_sep=1
    else
      case "$arg" in
        --session|--session=*)
          fm_herdr_lab_error "run-argv forbids caller-supplied --session; the helper inserts the lab session before the argv separator"
          return 1
          ;;
      esac
    fi
  done
  [ "$seen_sep" = 1 ] && [ "$post_count" -gt 0 ] || {
    fm_herdr_lab_error "run-argv requires a literal -- followed by the agent argv"
    return 1
  }
  fm_herdr_lab_require_default_running "$name" run-argv || return 1
  fm_herdr_lab_raw_argv "$name" "$@"
}

fm_herdr_lab_descendants() { # <root-pid>; deepest descendants first
  ps -axo pid=,ppid= 2>/dev/null | awk -v root="$1" '
    { parent[$1] = $2; count += 1 }
    END {
      for (pid in parent) {
        current = pid
        for (step = 0; step <= count; step += 1) {
          if (!(current in parent) || parent[current] == current) break
          if (parent[current] == root) { print step + 1, pid; break }
          current = parent[current]
        }
      }
    }
  ' | sort -rn -k1,1 | awk '{ print $2 }'
}

fm_herdr_lab_pid_live() { # <pid>
  local state
  state=$(ps -o state= -p "$1" 2>/dev/null | tr -d '[:space:]') || return 1
  [ -n "$state" ] && [[ "$state" != Z* ]]
}

fm_herdr_lab_provision_timeout() {
  local timeout=${FM_HERDR_LAB_PROVISION_TIMEOUT_SECONDS:-120}
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] && [ "$timeout" -le 600 ] || {
    fm_herdr_lab_error "FM_HERDR_LAB_PROVISION_TIMEOUT_SECONDS must be a whole number from 1 through 600 (got '${timeout:-<empty>}')"
    return 1
  }
  printf '%s\n' "$timeout"
}

fm_herdr_lab_launch_server() { # <session>
  HERDR_SESSION="$1" python3 - "$1" <<'PY'
import os
import subprocess
import sys

process = subprocess.Popen(
    ["herdr", "server", "--session", sys.argv[1]],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    env=os.environ.copy(),
    start_new_session=True,
)
print(process.pid)
PY
}

fm_herdr_lab_cancel_provision() { # <pid>
  local pid=$1 attempt=0 descendants targets target any_live
  descendants=$(fm_herdr_lab_descendants "$pid") || descendants=
  targets="$descendants $pid"
  for target in $targets; do
    fm_herdr_lab_pid_live "$target" && kill -TERM "$target" 2>/dev/null || true
  done
  while [ "$attempt" -lt 10 ]; do
    any_live=0
    for target in $targets; do
      fm_herdr_lab_pid_live "$target" && any_live=1
    done
    [ "$any_live" = 1 ] || break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  for target in $targets; do
    fm_herdr_lab_pid_live "$target" && kill -KILL "$target" 2>/dev/null || true
  done
  wait "$pid" 2>/dev/null || true
}

fm_herdr_lab_provision() { # <session>
  local name=$1 sessions tripwire running attempt server_pid timeout max_attempts
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    tripwire=$(fm_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] || {
      fm_herdr_lab_error "missing fleet-state tripwire for existing session '$name'; refusing to adopt it"
      return 1
    }
    fm_herdr_lab_refuse_if_default "$name" || return 1
    running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
      '.sessions[]? | select(.name == $name) | .running' 2>/dev/null)
    [ "$running" = false ] || {
      fm_herdr_lab_error "session '$name' is not stopped; refusing to re-provision it"
      return 1
    }
    fm_herdr_lab_check_tripwire "$name" || return 1
  else
    fm_herdr_lab_prepare "$name" || return 1
  fi
  fm_herdr_lab_require_default_running "$name" provision || return 1
  timeout=$(fm_herdr_lab_provision_timeout) || return 1
  max_attempts=$((timeout * 5))
  server_pid=$(fm_herdr_lab_launch_server "$name") || return 1
  [[ "$server_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    running=$(fm_herdr_lab_cli "$name" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null) || running=false
    if [ "$running" = true ]; then
      fm_herdr_lab_refuse_if_default "$name" || {
        fm_herdr_lab_cancel_provision "$server_pid"
        return 1
      }
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_cancel_provision "$server_pid"
  fm_herdr_lab_error "lab session '$name' did not report running within $timeout seconds"
  return 1
}

fm_herdr_lab_check_tripwire() { # <session>
  local name=$1 tripwire before after
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing unverified teardown"
    return 1
  }
  before=$(cat "$tripwire")
  after=$(fm_herdr_lab_fleet_state "$name") || return 1
  [ "$before" = "$after" ] || {
    fm_herdr_lab_error "FLEET-STATE TRIPWIRE FAILED: default session changed during lab work"
    fm_herdr_lab_error "before: $before"
    fm_herdr_lab_error "after:  $after"
    return 1
  }
}

fm_herdr_lab_verify_tripwire() { # <session>
  local name=$1 tripwire
  fm_herdr_lab_check_tripwire "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  rm -f "$tripwire"
}

fm_herdr_lab_stop() { # <session>
  local name=$1 tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing stop"
    return 1
  }
  fm_herdr_lab_refuse_if_default "$name" || return 1
  fm_herdr_lab_require_default_running "$name" stop || return 1
  fm_herdr_lab_raw "$name" session stop "$name" --json
}

fm_herdr_lab_wait_stopped() { # <session>
  local name=$1 sessions state attempt=0
  while [ "$attempt" -lt 100 ]; do
    sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
      fm_herdr_lab_error "cannot list Herdr sessions while waiting for '$name' to stop"
      return 1
    }
    state=$(printf '%s' "$sessions" | jq -r --arg name "$name" '
      [.sessions[]? | select(.name == $name)]
      | if length == 0 then "absent"
        elif length == 1 and .[0].default == false and .[0].running == false then "stopped"
        elif length == 1 and .[0].default == false and .[0].running == true then "running"
        else "unsafe"
        end
    ' 2>/dev/null) || state=unsafe
    case "$state" in
      absent|stopped) return 0 ;;
      running) ;;
      *)
        fm_herdr_lab_error "refusing teardown while '$name' has ambiguous or default session state"
        return 1
        ;;
    esac
    sleep 0.1
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_error "session '$name' did not report stopped within 10 seconds"
  return 1
}

fm_herdr_lab_teardown() { # <session>
  local name=$1 tripwire sessions delete_status=0
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing destructive calls"
    return 1
  }
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before teardown"
    return 1
  }
  if ! printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_verify_tripwire "$name"
    return
  fi
  fm_herdr_lab_stop "$name" >/dev/null 2>&1 || true
  fm_herdr_lab_wait_stopped "$name" || return 1
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions after stopping '$name'"
    return 1
  }
  if ! printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_verify_tripwire "$name"
    return
  fi
  fm_herdr_lab_refuse_if_default "$name" || return 1
  fm_herdr_lab_require_default_running "$name" teardown || return 1
  fm_herdr_lab_raw "$name" session delete "$name" --json >/dev/null 2>&1 || delete_status=$?
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot confirm removal of lab session '$name' after teardown"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    if [ "$delete_status" -ne 0 ]; then
      fm_herdr_lab_error "session delete failed for '$name' and the lab session remains"
    else
      fm_herdr_lab_error "lab session '$name' remains after teardown"
    fi
    return 1
  fi
  fm_herdr_lab_verify_tripwire "$name"
}

fm_herdr_lab_name() { # <label>
  local label=${1:-lab} pid_suffix random_suffix
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-' | sed 's/^[^a-zA-Z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  # Herdr nests the name below sessions/<name>/herdr.sock. Keep the readable
  # component bounded so macOS's 104-byte Unix-socket path limit is not spent
  # by a long test filename; bounded PID plus RANDOM retain per-run uniqueness.
  label=${label:0:24}
  pid_suffix=$(( $$ % 1000000 ))
  random_suffix=$(( RANDOM % 10000 ))
  printf 'fm-lab-%s-%s-%s\n' "$label" "$pid_suffix" "$random_suffix"
}

fm_herdr_lab_usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_herdr_lab_main() {
  local command=${1:-}
  case "$command" in
    name)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_name "$2"
      ;;
    prepare)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_prepare "$2"
      ;;
    provision)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_provision "$2"
      ;;
    run)
      [ "$#" -ge 3 ] || { fm_herdr_lab_usage >&2; return 2; }
      shift
      fm_herdr_lab_cli "$@"
      ;;
    run-argv)
      [ "$#" -ge 6 ] || { fm_herdr_lab_usage >&2; return 2; }
      shift
      fm_herdr_lab_cli_argv "$@"
      ;;
    stop)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_stop "$2"
      ;;
    teardown)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_teardown "$2"
      ;;
    -h|--help|help)
      fm_herdr_lab_usage
      ;;
    *)
      fm_herdr_lab_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  fm_herdr_lab_main "$@"
fi
