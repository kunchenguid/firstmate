#!/usr/bin/env bash
# Provision and operate an isolated Herdr lab session without risking the live
# default session.
#
# Usage:
#   fm-herdr-lab.sh name <label>
#   fm-herdr-lab.sh prepare <session>
#   fm-herdr-lab.sh provision <session>
#   fm-herdr-lab.sh launchagent provision <session> <code-root>
#   fm-herdr-lab.sh launchagent restart <session>
#   fm-herdr-lab.sh launchagent kill <session> job|server <signal>
#   fm-herdr-lab.sh launchagent print <session>
#   fm-herdr-lab.sh run <session> <herdr arguments...>
#   fm-herdr-lab.sh viewer start <session>
#   fm-herdr-lab.sh viewer stop <session>
#   fm-herdr-lab.sh stop <session>
#   fm-herdr-lab.sh teardown <session>
#
# Session names must begin with "fm-lab-" and can never be "default".
# The name command sanitizes the label, caps it at 16 characters, and appends
# process/random suffixes to keep generated socket paths short.
# Every Herdr call made here carries a trailing --session <session>.
# The run command rejects caller-supplied --session flags, any leading option
# before the subcommand, all session lifecycle operations, and every server
# operation.
# Session stop is available only through guarded stop or teardown, and session
# delete is available only through teardown.
# Both paths perform a fresh refuse-default check immediately before each
# destructive call.
# Provision records the running default session as a fleet-state tripwire and
# teardown requires that record to be identical afterward.
# The viewer command attaches or detaches one real foreground Herdr client on
# an owned lab session over a fixed 40-row by 120-column pty;
# bin/fm-herdr-lab-viewer.py owns the pty mechanics.
# Start succeeds only when that session reports a foreground client and the
# recorded viewer process still matches its launch identity.
# Stop signals only identity-matched recorded processes and retains its
# ownership record until detach is confirmed or the session is stopped or
# absent; teardown refuses when that stop cannot be confirmed.
# The launchagent commands, on macOS only, run a lab session's server the way
# bin/fm-remote-doctor.sh runs the fm-remote server, so a lab can observe
# launchd supervision. Provision takes the same prepare step and tripwire as
# provision, refuses a label already loaded in gui/<uid> or user/<uid>, renders
# the fm-remote launch agent contract that bin/fm-remote-herdr-owner-lib.sh
# owns around <code-root>/bin/fm-remote-herdr-guard.sh under the one label
# dev.firstmate.herdr-lab.<session>, keeps its plist and log in the lab state
# directory rather than ~/Library/LaunchAgents, and bootstraps it into
# gui/<uid>. It also records the load state of the
# dev.firstmate.herdr and dev.firstmate.herdr.fm-remote launch agents, which
# teardown requires to be identical afterward. Restart, kill, and print act
# only on a recorded lab label; kill signals the job process itself, or the
# herdr server for the session whose parent is that job. Teardown boots the
# recorded job out before its other steps, refuses to finish while the label
# stays loaded or a server, supervisor, or guard of the session still runs, and
# leaves the launch agent log in place as evidence. Plain provision refuses a
# session that a lab launch agent runs.
set -u

FM_HERDR_LAB_BIN_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$FM_HERDR_LAB_BIN_DIR/fm-remote-herdr-owner-lib.sh"

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

fm_herdr_lab_session_list() { # <session>
  fm_herdr_lab_raw "$1" session list --json
}

fm_herdr_lab_fleet_state() { # <session>
  local name=$1 sessions snapshot
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot read Herdr sessions for the fleet-state tripwire"
    return 1
  }
  snapshot=$(printf '%s' "$sessions" | jq -c '
    [.sessions[]? | select(.default == true)]
    | if length == 1 and .[0].name == "default" and .[0].running == true
      then .[0] | {name, default, running, socket_path}
      else empty
      end
  ' 2>/dev/null)
  [ -n "$snapshot" ] || {
    fm_herdr_lab_error "fleet-state tripwire requires exactly one running default session"
    return 1
  }
  printf '%s\n' "$snapshot"
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
  fm_herdr_lab_raw "$name" "$@"
}

# --- foreground viewer ------------------------------------------------------
#
# Herdr counts a client as the session's foreground viewer only once that
# client reports a usable window grid, so a zero-sized pty attaches nothing and
# leaves `terminal title clear` answering no_foreground_client. Attaching a
# real viewer is what lets a test drive the live-client teardown paths instead
# of only their detached halves. bin/fm-herdr-lab-viewer.py owns the pty and
# environment mechanics; the guards below own who may be attached to.
# Per-session locks are deliberately absent: generated fm-lab-<label>-$$-$RANDOM
# names have no caller that starts one viewer concurrently, so locks add risk.
# A subsecond interrupt window and SIGKILL residue are accepted in this isolated
# lab helper because teardown drops any stray viewer connection with the session.

readonly fm_herdr_lab_viewer_timeout_seconds=5
readonly fm_herdr_lab_viewer_launcher_grace_seconds=6

fm_herdr_lab_viewer_record_path() { # <session>
  printf '%s/%s.viewer' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_viewer_log_path() { # <session>
  printf '%s/%s.viewer.log' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_viewer_launcher_path() {
  printf '%s/fm-herdr-lab-viewer.py' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

# Prints the session's current foreground-client reason, or nothing when it
# cannot be read.
fm_herdr_lab_viewer_reason() { # <session>
  local name=$1 out
  out=$(fm_herdr_lab_cli "$name" terminal title clear 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '.result.reason // empty' 2>/dev/null
}

fm_herdr_lab_process_start() { # <pid>
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

fm_herdr_lab_process_parent() { # <pid>
  LC_ALL=C ps -p "$1" -o ppid= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

fm_herdr_lab_viewer_recorded_value() { # <session> <key>
  local record value
  record=$(fm_herdr_lab_viewer_record_path "$1")
  [ -f "$record" ] || return 1
  value=$(sed -n "s/^$2=//p" "$record" | head -n 1)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

fm_herdr_lab_viewer_owned_pair() { # <session>
  local launcher_pid viewer_pid launcher_start viewer_start current_start parent_pid
  launcher_pid=$(fm_herdr_lab_viewer_recorded_value "$1" launcher_pid) || return 1
  viewer_pid=$(fm_herdr_lab_viewer_recorded_value "$1" viewer_pid) || return 1
  case "$launcher_pid:$viewer_pid" in
    *[!0-9:]*) return 1 ;;
  esac
  launcher_start=$(fm_herdr_lab_viewer_recorded_value "$1" launcher_start) || return 1
  viewer_start=$(fm_herdr_lab_viewer_recorded_value "$1" viewer_start) || return 1
  current_start=$(fm_herdr_lab_process_start "$launcher_pid") || return 1
  [ -n "$current_start" ] && [ "$current_start" = "$launcher_start" ] || return 1
  current_start=$(fm_herdr_lab_process_start "$viewer_pid") || return 1
  [ -n "$current_start" ] && [ "$current_start" = "$viewer_start" ] || return 1
  parent_pid=$(fm_herdr_lab_process_parent "$viewer_pid") || return 1
  [ "$parent_pid" = "$launcher_pid" ] || return 1
  printf '%s %s' "$launcher_pid" "$viewer_pid"
}

fm_herdr_lab_viewer_owned_pid() { # <session> <launcher|viewer>
  local pair
  pair=$(fm_herdr_lab_viewer_owned_pair "$1") || return 1
  case "$2" in
    launcher) printf '%s' "${pair%% *}" ;;
    viewer) printf '%s' "${pair#* }" ;;
    *) return 1 ;;
  esac
}

fm_herdr_lab_viewer_signal() { # <session> <launcher|viewer> <signal>
  local pid
  pid=$(fm_herdr_lab_viewer_owned_pid "$1" "$2") || return 0
  kill "-$3" "$pid" 2>/dev/null || true
}

# True while this lab owns a viewer process that is still running.
fm_herdr_lab_viewer_owned_alive() { # <session>
  fm_herdr_lab_viewer_owned_pair "$1" >/dev/null
}

fm_herdr_lab_viewer_session_stopped_or_absent() { # <session>
  local sessions running
  sessions=$(fm_herdr_lab_session_list "$1" 2>/dev/null) || return 1
  running=$(printf '%s' "$sessions" | jq -r --arg name "$1" \
    '[.sessions[]? | select(.name == $name) | .running] | if length == 0 then "absent" elif length == 1 then .[0] else "ambiguous" end' \
    2>/dev/null) || return 1
  [ "$running" = false ] || [ "$running" = absent ]
}

fm_herdr_lab_viewer_start() { # <session>
  local name=$1 record log launcher launcher_pid waited attempt reason pid interrupt_traps=0 timeout=$fm_herdr_lab_viewer_timeout_seconds
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }
  command -v python3 >/dev/null 2>&1 || { fm_herdr_lab_error "python3 is required for the lab viewer"; return 1; }

  [ -f "$(fm_herdr_lab_tripwire_path "$name")" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing to attach a viewer to a session this lab does not own"
    return 1
  }
  fm_herdr_lab_refuse_if_default "$name" || return 1

  record=$(fm_herdr_lab_viewer_record_path "$name")
  if fm_herdr_lab_viewer_owned_alive "$name"; then
    fm_herdr_lab_error "a lab viewer is already attached to '$name'; stop it before starting another"
    return 1
  fi
  rm -f "$record"

  launcher=$(fm_herdr_lab_viewer_launcher_path)
  [ -f "$launcher" ] || { fm_herdr_lab_error "missing viewer launcher at $launcher"; return 1; }
  log=$(fm_herdr_lab_viewer_log_path "$name")
  mkdir -p "$(fm_herdr_lab_state_dir)" || return 1
  launcher_pid=
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    interrupt_traps=1
    trap 'trap - INT TERM; [ -z "${launcher_pid:-}" ] || fm_herdr_lab_cancel_viewer_launcher "$launcher_pid"; exit 130' INT
    trap 'trap - INT TERM; [ -z "${launcher_pid:-}" ] || fm_herdr_lab_cancel_viewer_launcher "$launcher_pid"; exit 143' TERM
  fi
  nohup python3 "$launcher" "$name" "$record" >"$log" 2>&1 &
  launcher_pid=$!

  waited=0
  attempt=$((timeout * 5))
  while [ "$waited" -lt "$attempt" ]; do
    reason=$(fm_herdr_lab_viewer_reason "$name") || reason=
    if [ "$reason" = cleared ]; then
      pid=$(fm_herdr_lab_viewer_owned_pid "$name" viewer) || pid=
      if [ -n "$pid" ]; then
        [ "$interrupt_traps" = 0 ] || trap - INT TERM
        disown "$launcher_pid" 2>/dev/null || true
        printf 'viewer attached to %s (pid %s)\n' "$name" "$pid"
        return 0
      fi
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  fm_herdr_lab_cancel_viewer_launcher "$launcher_pid"
  [ "$interrupt_traps" = 0 ] || trap - INT TERM
  fm_herdr_lab_error "lab viewer did not become the foreground client of '$name' within $timeout seconds (last reason: ${reason:-<unreadable>})"
  [ ! -s "$log" ] || fm_herdr_lab_error "viewer log: $(tail -n 5 "$log" | tr '\n' ' ')"
  fm_herdr_lab_viewer_stop "$name" >/dev/null 2>&1 || true
  return 1
}

fm_herdr_lab_viewer_stop() { # <session>
  local name=$1 record log role waited attempt reason timeout=$fm_herdr_lab_viewer_timeout_seconds
  fm_herdr_lab_validate_name "$name" || return 1
  record=$(fm_herdr_lab_viewer_record_path "$name")
  log=$(fm_herdr_lab_viewer_log_path "$name")
  # An absent record means this lab owns no viewer. Any client attached in that
  # case belongs to someone else and must never be signalled from here.
  [ -f "$record" ] || return 0

  for role in viewer launcher; do
    fm_herdr_lab_viewer_signal "$name" "$role" TERM
  done
  waited=0
  while fm_herdr_lab_viewer_owned_alive "$name" && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  for role in viewer launcher; do
    fm_herdr_lab_viewer_signal "$name" "$role" KILL
  done

  waited=0
  attempt=$((timeout * 5))
  while [ "$waited" -lt "$attempt" ]; do
    reason=$(fm_herdr_lab_viewer_reason "$name") || reason=
    if [ "$reason" = no_foreground_client ] \
      || { [ -z "$reason" ] && fm_herdr_lab_viewer_session_stopped_or_absent "$name"; }; then
      rm -f "$record" "$log"
      return 0
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  fm_herdr_lab_error "lab viewer for '$name' did not detach within $timeout seconds (last reason: ${reason:-<unreadable>})"
  return 1
}

fm_herdr_lab_viewer() { # <start|stop> <session>
  case "${1:-}" in
    start) fm_herdr_lab_viewer_start "$2" ;;
    stop) fm_herdr_lab_viewer_stop "$2" ;;
    *)
      fm_herdr_lab_error "viewer takes 'start' or 'stop'"
      return 2
      ;;
  esac
}

fm_herdr_lab_cancel_viewer_launcher() { # <pid>
  local pid=$1 attempt=0 max_attempts=$((fm_herdr_lab_viewer_launcher_grace_seconds * 10))
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt "$max_attempts" ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

fm_herdr_lab_cancel_provision() { # <pid>
  local pid=$1 attempt=0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 10 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

fm_herdr_lab_provision() { # <session>
  local name=$1 sessions tripwire running attempt server_pid max_attempts timeout_seconds
  fm_herdr_lab_validate_name "$name" || return 1
  [ ! -f "$(fm_herdr_lab_launchagent_record_path "$name")" ] || {
    fm_herdr_lab_error "session '$name' is run by a lab launch agent; use launchagent restart instead of provision"
    return 1
  }
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
  fm_herdr_lab_raw "$name" server >/dev/null 2>&1 &
  server_pid=$!
  attempt=0
  max_attempts=300
  timeout_seconds=60
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
  fm_herdr_lab_error "lab session '$name' did not report running within $timeout_seconds seconds"
  return 1
}

# --- launch agent lab ---------------------------------------------------------
#
# A server that provision starts is a child of the caller, so it cannot show
# what launchd supervision does to a server. The launch agent lab runs a code
# root's guard under launchd in gui/<uid>, rendered by the same
# fm_remote_herdr_render_launch_agent that bin/fm-remote-doctor.sh installs
# for the fm-remote server, so only the label, command, and log differ.

fm_herdr_lab_launchagent_label() { # <session>
  printf 'dev.firstmate.herdr-lab.%s' "$1"
}

fm_herdr_lab_launchagent_record_path() { # <session>
  printf '%s/%s.launchagent' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_launchagent_plist_path() { # <session>
  printf '%s/%s.launchagent.plist' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_launchagent_log_path() { # <session>
  printf '%s/%s.launchagent.log' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_launchagent_agents_path() { # <session>
  printf '%s/%s.launch-agents' "$(fm_herdr_lab_state_dir)" "$1"
}

# One line per domain for each Firstmate launch agent a lab must not disturb.
fm_herdr_lab_launchagent_protected_state() {
  local uid label domain job pid
  uid=$(id -u)
  for label in dev.firstmate.herdr dev.firstmate.herdr.fm-remote; do
    for domain in gui user; do
      if job=$(launchctl print "$domain/$uid/$label" 2>/dev/null); then
        pid=$(printf '%s\n' "$job" | awk '$1 == "pid" && $2 == "=" { print $3; exit }')
        printf '%s/%s loaded pid=%s\n' "$domain" "$label" "${pid:-none}"
      else
        printf '%s/%s absent\n' "$domain" "$label"
      fi
    done
  done
}

fm_herdr_lab_shell_quote() { # <string>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Prints "<pid> <command>" for every process still running this session's
# herdr server, its supervisor or watcher, or the guard that starts them. The
# session name reaches awk through its environment, so the scan never lists
# itself.
fm_herdr_lab_launchagent_processes() { # <session>
  ps -A -o pid=,command= 2>/dev/null | FM_HERDR_LAB_SCAN_SESSION=$1 awk '
    BEGIN { session = ENVIRON["FM_HERDR_LAB_SCAN_SESSION"] }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      padded = line " "
      if (index(padded, " server --session " session " ") \
        || (index(padded, "fm-remote-herdr-guard.sh ") && index(padded, " " session " "))) print line
    }
  '
}

fm_herdr_lab_launchagent_job_pid() { # <session>
  launchctl print "gui/$(id -u)/$(fm_herdr_lab_launchagent_label "$1")" 2>/dev/null | awk '
    $1 == "pid" && $2 == "=" && $3 ~ /^[0-9]+$/ { print $3; found = 1; exit }
    END { exit found ? 0 : 1 }
  '
}

# Prints the pid of the herdr server for <session> whose parent is <job-pid>.
fm_herdr_lab_launchagent_server_pid() { # <session> <job-pid>
  ps -A -o pid=,ppid=,command= 2>/dev/null | FM_HERDR_LAB_SCAN_SESSION=$1 awk -v parent="$2" '
    BEGIN { session = ENVIRON["FM_HERDR_LAB_SCAN_SESSION"] }
    $2 == parent {
      argv0 = $3
      sub(/.*\//, "", argv0)
      if (argv0 == "herdr" && index($0 " ", " server --session " session " ")) { print $1; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  '
}

fm_herdr_lab_launchagent_owned() { # <session>
  local name=$1
  fm_herdr_lab_validate_name "$name" || return 1
  [ -f "$(fm_herdr_lab_tripwire_path "$name")" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing to act on a launch agent this lab does not own"
    return 1
  }
  [ -f "$(fm_herdr_lab_launchagent_record_path "$name")" ] || {
    fm_herdr_lab_error "no lab launch agent is recorded for '$name'"
    return 1
  }
  command -v launchctl >/dev/null 2>&1 || { fm_herdr_lab_error "launchctl is required"; return 1; }
}

fm_herdr_lab_launchagent_provision() { # <session> <code-root>
  local name=$1 root='' uid label domain record plist log herdr_bin shell program attempt running tool
  fm_herdr_lab_validate_name "$name" || return 1
  [ "$(uname -s 2>/dev/null)" = Darwin ] || { fm_herdr_lab_error "launchagent needs macOS launchd"; return 1; }
  for tool in herdr jq launchctl plutil; do
    command -v "$tool" >/dev/null 2>&1 || { fm_herdr_lab_error "$tool is required"; return 1; }
  done
  [ -z "${2:-}" ] || root=$(CDPATH='' cd -- "$2" 2>/dev/null && pwd -P) || root=
  [ -n "$root" ] && [ -f "$root/bin/fm-remote-herdr-guard.sh" ] || {
    fm_herdr_lab_error "code root has no bin/fm-remote-herdr-guard.sh: ${2:-<empty>}"
    return 1
  }
  uid=$(id -u)
  label=$(fm_herdr_lab_launchagent_label "$name")
  record=$(fm_herdr_lab_launchagent_record_path "$name")
  [ ! -e "$record" ] || {
    fm_herdr_lab_error "a lab launch agent is already recorded for '$name'; tear it down before provisioning again"
    return 1
  }
  for domain in gui user; do
    if launchctl print "$domain/$uid/$label" >/dev/null 2>&1; then
      fm_herdr_lab_error "launch agent $label is already loaded in $domain/$uid; refusing to adopt it"
      return 1
    fi
  done
  fm_herdr_lab_prepare "$name" || return 1

  herdr_bin=$(command -v herdr)
  shell=${SHELL:-}
  [ -n "$shell" ] && [ -x "$shell" ] || shell=/bin/sh
  program="exec $(fm_herdr_lab_shell_quote "$root/bin/fm-remote-herdr-guard.sh") $(fm_herdr_lab_shell_quote "$herdr_bin") $(fm_herdr_lab_shell_quote "$name")"
  plist=$(fm_herdr_lab_launchagent_plist_path "$name")
  log=$(fm_herdr_lab_launchagent_log_path "$name")
  fm_herdr_lab_launchagent_protected_state > "$(fm_herdr_lab_launchagent_agents_path "$name")" || return 1
  # Recorded before bootstrap, so teardown boots the job out even when this
  # provision stops partway.
  printf 'code_root=%s\n' "$root" > "$record" || return 1
  fm_remote_herdr_render_launch_agent "$label" "$shell" "$program" "$log" > "$plist" || return 1
  plutil -lint "$plist" >/dev/null 2>&1 || {
    fm_herdr_lab_error "the rendered launch agent is not a valid plist: $plist"
    return 1
  }
  launchctl bootstrap "gui/$uid" "$plist" || {
    fm_herdr_lab_error "launchctl bootstrap gui/$uid failed for $plist"
    return 1
  }
  attempt=0
  while [ "$attempt" -lt 300 ]; do
    running=$(fm_herdr_lab_cli "$name" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null) || running=false
    if [ "$running" = true ]; then
      fm_herdr_lab_refuse_if_default "$name" || return 1
      printf 'launch agent %s runs lab session %s (log %s)\n' "$label" "$name" "$log"
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_error "lab session '$name' did not report running within 60 seconds of bootstrapping $label; see $log"
  return 1
}

fm_herdr_lab_launchagent_restart() { # <session>
  local name=$1
  fm_herdr_lab_launchagent_owned "$name" || return 1
  fm_herdr_lab_refuse_if_default "$name" || return 1
  launchctl kickstart -k "gui/$(id -u)/$(fm_herdr_lab_launchagent_label "$name")"
}

fm_herdr_lab_launchagent_kill() { # <session> <job|server> <signal>
  local name=$1 target=$2 signal=$3 job_pid server_pid
  case "$target" in
    job|server) ;;
    *) fm_herdr_lab_error "launchagent kill targets job or server, not '$target'"; return 2 ;;
  esac
  case "$signal" in
    HUP|INT|QUIT|TERM|KILL|USR1|USR2) ;;
    *) fm_herdr_lab_error "launchagent kill sends HUP, INT, QUIT, TERM, KILL, USR1, or USR2, not '$signal'"; return 2 ;;
  esac
  fm_herdr_lab_launchagent_owned "$name" || return 1
  fm_herdr_lab_refuse_if_default "$name" || return 1
  job_pid=$(fm_herdr_lab_launchagent_job_pid "$name") || {
    fm_herdr_lab_error "launch agent $(fm_herdr_lab_launchagent_label "$name") has no running process to signal"
    return 1
  }
  if [ "$target" = job ]; then
    launchctl kill "SIG$signal" "gui/$(id -u)/$(fm_herdr_lab_launchagent_label "$name")"
    return
  fi
  server_pid=$(fm_herdr_lab_launchagent_server_pid "$name" "$job_pid") || {
    fm_herdr_lab_error "no herdr server for '$name' runs as a child of launch agent pid $job_pid"
    return 1
  }
  kill "-$signal" "$server_pid"
}

fm_herdr_lab_launchagent_print() { # <session>
  local name=$1
  fm_herdr_lab_launchagent_owned "$name" || return 1
  launchctl print "gui/$(id -u)/$(fm_herdr_lab_launchagent_label "$name")"
}

# Boots out the lab launch agent recorded for <session>, if any, and succeeds
# only once its label is unloaded and no process of the session remains.
fm_herdr_lab_launchagent_bootout() { # <session>
  local name=$1 uid label waited=0 remaining=''
  [ -f "$(fm_herdr_lab_launchagent_record_path "$name")" ] || return 0
  command -v launchctl >/dev/null 2>&1 || {
    fm_herdr_lab_error "launchctl is required to boot out the lab launch agent for '$name'"
    return 1
  }
  uid=$(id -u)
  label=$(fm_herdr_lab_launchagent_label "$name")
  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
  fi
  while [ "$waited" -lt 100 ]; do
    remaining=$(fm_herdr_lab_launchagent_processes "$name")
    if [ -z "$remaining" ] && ! launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
      rm -f "$(fm_herdr_lab_launchagent_plist_path "$name")" "$(fm_herdr_lab_launchagent_record_path "$name")"
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    fm_herdr_lab_error "launch agent $label is still loaded after bootout; refusing teardown of '$name'"
  else
    fm_herdr_lab_error "processes of lab session '$name' remain after bootout: $(printf '%s' "$remaining" | tr '\n' ';')"
  fi
  return 1
}

fm_herdr_lab_launchagent() { # <provision|restart|kill|print> <session> [arguments...]
  case "${1:-} $#" in
    "provision 3") fm_herdr_lab_launchagent_provision "$2" "$3" ;;
    "restart 2") fm_herdr_lab_launchagent_restart "$2" ;;
    "kill 4") fm_herdr_lab_launchagent_kill "$2" "$3" "$4" ;;
    "print 2") fm_herdr_lab_launchagent_print "$2" ;;
    *)
      fm_herdr_lab_usage >&2
      return 2
      ;;
  esac
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
  local name=$1 tripwire agents before after
  fm_herdr_lab_check_tripwire "$name" || return 1
  agents=$(fm_herdr_lab_launchagent_agents_path "$name")
  if [ -f "$agents" ]; then
    before=$(cat "$agents")
    after=$(fm_herdr_lab_launchagent_protected_state)
    [ "$before" = "$after" ] || {
      fm_herdr_lab_error "LAUNCH-AGENT TRIPWIRE FAILED: a Firstmate launch agent changed during lab work"
      fm_herdr_lab_error "before: $(printf '%s' "$before" | tr '\n' ';')"
      fm_herdr_lab_error "after:  $(printf '%s' "$after" | tr '\n' ';')"
      return 1
    }
    rm -f "$agents"
  fi
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
  fm_herdr_lab_raw "$name" session stop "$name" --json
}

fm_herdr_lab_teardown() { # <session>
  local name=$1 tripwire sessions delete_status=0
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing destructive calls"
    return 1
  }
  fm_herdr_lab_viewer_stop "$name" || {
    fm_herdr_lab_error "refusing teardown of '$name' while this lab's viewer is still attached"
    return 1
  }
  fm_herdr_lab_launchagent_bootout "$name" || return 1
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before teardown"
    return 1
  }
  if ! printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_verify_tripwire "$name"
    return
  fi
  fm_herdr_lab_stop "$name" >/dev/null 2>&1 || true
  sleep 0.5
  fm_herdr_lab_refuse_if_default "$name" || return 1
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
  local label=${1:-lab}
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-' | sed 's/^[^a-zA-Z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  label=${label:0:16}
  label=${label%-}
  [ -n "$label" ] || label=lab
  printf 'fm-lab-%s-%s-%s\n' "$label" "$$" "$RANDOM"
}

fm_herdr_lab_usage() {
  sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
    launchagent)
      shift
      fm_herdr_lab_launchagent "$@"
      ;;
    run)
      [ "$#" -ge 3 ] || { fm_herdr_lab_usage >&2; return 2; }
      shift
      fm_herdr_lab_cli "$@"
      ;;
    viewer)
      [ "$#" -eq 3 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_viewer "$2" "$3"
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
