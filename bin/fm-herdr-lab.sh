#!/usr/bin/env bash
# Provision and operate an isolated Herdr lab session without risking the live
# default session.
#
# Usage:
#   fm-herdr-lab.sh name <label>
#   fm-herdr-lab.sh prepare <session>
#   fm-herdr-lab.sh provision <session>
#   fm-herdr-lab.sh run <session> <herdr arguments...>
#   fm-herdr-lab.sh stop <session>
#   fm-herdr-lab.sh teardown <session>
#
# Session names must begin with "fm-lab-" and can never be "default".
# Every Herdr call made here carries a trailing --session <session>.
# The run command rejects caller-supplied --session flags, any leading option
# before the subcommand, all session lifecycle operations, and every server
# operation.
# Session stop is available only through guarded stop or teardown, and session
# delete is available only through teardown.
# Both paths perform fresh baseline and ownership checks immediately before
# each destructive call.
# Provision records the initial fleet baseline and the created lab session's
# stable identity, and every lifecycle operation requires both to match.
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

fm_herdr_lab_write_state() { # <session> <state-json>
  local name=$1 state=$2 path tmp
  path=$(fm_herdr_lab_tripwire_path "$name")
  tmp=$(mktemp "${path}.tmp.XXXXXX") || return 1
  if ! printf '%s\n' "$state" > "$tmp" || ! mv "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_herdr_lab_raw() { # <session> <herdr arguments...>
  local name=$1
  shift
  HERDR_SESSION="$name" herdr "$@" --session "$name"
}

fm_herdr_lab_session_list() { # <session>
  fm_herdr_lab_raw "$1" session list --json
}

fm_herdr_lab_session_list_is_valid() { # <session-list-json>
  printf '%s' "$1" | jq -se '
    length == 1
    and (.[0] | type == "object")
    and (.[0].sessions | type == "array")
    and (.[0].sessions | all(.[];
      type == "object"
      and (.name | type == "string" and length > 0)
      and (.default | type == "boolean")
      and (.running | type == "boolean")
      and (.socket_path | type == "string" and length > 0)
    ))
    and (([.[0].sessions[].name] | length) == ([.[0].sessions[].name] | unique | length))
    and (([.[0].sessions[] | select(.default == true)] | length) <= 1)
  ' >/dev/null 2>&1
}

fm_herdr_lab_baseline_from_list() { # <session> <session-list-json> <allow-owned>
  local name=$1 info=$2 allow_owned=$3
  fm_herdr_lab_session_list_is_valid "$info" || return 1
  printf '%s' "$info" | jq -S -c -s --arg name "$name" --argjson allow_owned "$allow_owned" '
    .[0] as $inventory
    | [$inventory.sessions[] | select(.name == $name)] as $owned
    | [$inventory.sessions[] | select(.name != $name)] as $baseline
    | if (
        (($owned | length) == 0 or ($allow_owned and ($owned | length) == 1))
        and all($owned[]; .default == false)
        and (
          ($baseline | length) == 0
          or (
            ($baseline | length) == 1
            and $baseline[0].name == "default"
            and $baseline[0].default == true
            and $baseline[0].running == true
          )
        )
      )
      then $inventory | .sessions = $baseline
      else empty
      end
  ' 2>/dev/null
}

fm_herdr_lab_identity_from_list() { # <session> <session-list-json>
  local name=$1 info=$2
  fm_herdr_lab_session_list_is_valid "$info" || return 1
  printf '%s' "$info" | jq -S -c -s --arg name "$name" '
    [.[0].sessions[] | select(.name == $name)]
    | if length == 1 and .[0].default == false
      then .[0] | del(.running)
      else empty
      end
  ' 2>/dev/null
}

fm_herdr_lab_state_read() { # <session>
  local name=$1 path raw state baseline canonical_baseline
  path=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$path" ] || return 1
  raw=$(cat "$path") || return 1
  state=$(printf '%s' "$raw" | jq -S -c -e -s --arg name "$name" '
    if (
      length == 1
      and (.[0] | type == "object")
      and ((.[0] | keys | sort) == ["baseline", "owned_session"])
      and (
        .[0].owned_session == null
        or (
          (.[0].owned_session | type == "object")
          and .[0].owned_session.name == $name
          and .[0].owned_session.default == false
          and (.[0].owned_session.socket_path | type == "string" and length > 0)
          and (.[0].owned_session | has("running") | not)
        )
      )
    )
    then .[0]
    else empty
    end
  ' 2>/dev/null) || return 1
  [ -n "$state" ] || return 1
  baseline=$(printf '%s' "$state" | jq -S -c '.baseline' 2>/dev/null) || return 1
  canonical_baseline=$(fm_herdr_lab_baseline_from_list "$name" "$baseline" false) || return 1
  [ -n "$canonical_baseline" ] && [ "$baseline" = "$canonical_baseline" ] || return 1
  printf '%s\n' "$state"
}

fm_herdr_lab_state_owned_identity() { # <session>
  local state
  state=$(fm_herdr_lab_state_read "$1") || return 1
  printf '%s' "$state" | jq -S -c -r '.owned_session // empty' 2>/dev/null
}

fm_herdr_lab_check_baseline_from_list() { # <session> <session-list-json>
  local name=$1 info=$2 state before after
  state=$(fm_herdr_lab_state_read "$name") || {
    fm_herdr_lab_error "missing or invalid fleet-state tripwire for '$name'"
    return 1
  }
  before=$(printf '%s' "$state" | jq -S -c '.baseline' 2>/dev/null) || return 1
  after=$(fm_herdr_lab_baseline_from_list "$name" "$info" true) || after=""
  if [ -n "$after" ] && [ "$before" = "$after" ]; then
    return 0
  fi
  fm_herdr_lab_error "FLEET-STATE TRIPWIRE FAILED: default session changed during lab work"
  fm_herdr_lab_error "before: $before"
  fm_herdr_lab_error "after:  ${after:-<invalid inventory>}"
  return 1
}

fm_herdr_lab_assert_owned_from_list() { # <session> <session-list-json>
  local name=$1 info=$2 expected actual
  fm_herdr_lab_check_baseline_from_list "$name" "$info" || return 1
  expected=$(fm_herdr_lab_state_owned_identity "$name") || expected=""
  actual=$(fm_herdr_lab_identity_from_list "$name" "$info") || actual=""
  if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
    return 0
  fi
  fm_herdr_lab_error "OWNERSHIP TRIPWIRE FAILED: session '$name' is missing, unproven, or changed"
  return 1
}

fm_herdr_lab_capture_identity_from_list() { # <session> <session-list-json> <server-pid>
  local name=$1 info=$2 server_pid=$3 state expected actual updated running
  kill -0 "$server_pid" 2>/dev/null || {
    fm_herdr_lab_error "cannot prove ownership for '$name': provisioning process exited"
    return 1
  }
  fm_herdr_lab_check_baseline_from_list "$name" "$info" || return 1
  state=$(fm_herdr_lab_state_read "$name") || return 1
  expected=$(printf '%s' "$state" | jq -S -c -r '.owned_session // empty' 2>/dev/null) || return 1
  actual=$(fm_herdr_lab_identity_from_list "$name" "$info") || actual=""
  running=$(printf '%s' "$info" | jq -r --arg name "$name" \
    '.sessions[] | select(.name == $name) | .running' 2>/dev/null) || running=false
  [ -n "$actual" ] || {
    fm_herdr_lab_error "cannot capture stable identity for lab session '$name'"
    return 1
  }
  [ "$running" = true ] || {
    fm_herdr_lab_error "cannot capture ownership for '$name': session is not running"
    return 1
  }
  if [ -n "$expected" ]; then
    [ "$expected" = "$actual" ] || {
      fm_herdr_lab_error "OWNERSHIP TRIPWIRE FAILED: session '$name' changed during provisioning"
      return 1
    }
    kill -0 "$server_pid" 2>/dev/null || {
      fm_herdr_lab_error "cannot prove ownership for '$name': provisioning process exited during verification"
      return 1
    }
    return 0
  fi
  updated=$(printf '%s' "$state" | jq -S -c --argjson identity "$actual" '.owned_session = $identity') || return 1
  kill -0 "$server_pid" 2>/dev/null || {
    fm_herdr_lab_error "cannot prove ownership for '$name': provisioning process exited before identity capture"
    return 1
  }
  fm_herdr_lab_write_state "$name" "$updated" || return 1
  kill -0 "$server_pid" 2>/dev/null || {
    fm_herdr_lab_write_state "$name" "$state" || true
    fm_herdr_lab_error "cannot prove ownership for '$name': provisioning process exited during identity capture"
    return 1
  }
}

fm_herdr_lab_session_state_from_list() { # <session> <session-list-json>
  local name=$1 info=$2 count flag
  fm_herdr_lab_session_list_is_valid "$info" || return 1
  count=$(printf '%s' "$info" | jq -r --arg name "$name" \
    '[.sessions[] | select(.name == $name)] | length' 2>/dev/null) || return 1
  case "$count" in
    0) printf 'absent'; return 0 ;;
    1) ;;
    *) return 1 ;;
  esac
  flag=$(printf '%s' "$info" | jq -r --arg name "$name" \
    '.sessions[] | select(.name == $name) | .default' 2>/dev/null) || return 1
  case "$flag" in
    false) printf 'nondefault' ;;
    true) printf 'default' ;;
    *) return 1 ;;
  esac
}

fm_herdr_lab_prepare() { # <session>
  local name=$1 sessions state_dir tripwire baseline state
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  fm_herdr_lab_session_list_is_valid "$sessions" || {
    fm_herdr_lab_error "invalid Herdr session inventory before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[] | select(.name == $name)' >/dev/null 2>&1; then
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
  baseline=$(fm_herdr_lab_baseline_from_list "$name" "$sessions" false) || baseline=""
  [ -n "$baseline" ] || {
    fm_herdr_lab_error "initial fleet-state must be exactly empty or exactly one running default session"
    rm -f "$tripwire"
    return 1
  }
  state=$(jq -S -c -n --argjson baseline "$baseline" '{baseline:$baseline,owned_session:null}') || {
    rm -f "$tripwire"
    return 1
  }
  fm_herdr_lab_write_state "$name" "$state" || return 1
}

fm_herdr_lab_assert_owned() { # <session>
  local name=$1 info tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "refusing destructive call without a fleet-state tripwire for '$name'"
    return 1
  }
  info=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "refusing destructive call because session list failed"
    return 1
  }
  fm_herdr_lab_assert_owned_from_list "$name" "$info" || {
    fm_herdr_lab_error "refusing destructive call for '$name': ownership is absent or ambiguous"
    return 1
  }
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

fm_herdr_lab_timeout_postcheck() { # <session>
  local name=$1 info expected state
  info=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "PROVISION POSTCHECK FAILED: cannot read Herdr sessions after cancellation"
    return 1
  }
  fm_herdr_lab_check_baseline_from_list "$name" "$info" || return 1
  expected=$(fm_herdr_lab_state_owned_identity "$name") || expected=""
  state=$(fm_herdr_lab_session_state_from_list "$name" "$info") || state=invalid
  case "$state" in
    absent) return 0 ;;
    nondefault)
      if [ -n "$expected" ]; then
        fm_herdr_lab_assert_owned_from_list "$name" "$info"
        return
      fi
      ;;
  esac
  fm_herdr_lab_error "PROVISION POSTCHECK FAILED: session '$name' exists without proven ownership"
  return 1
}

fm_herdr_lab_provision() { # <session>
  local name=$1 sessions tripwire running attempt server_pid expected state
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  fm_herdr_lab_session_list_is_valid "$sessions" || {
    fm_herdr_lab_error "invalid Herdr session inventory before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[] | select(.name == $name)' >/dev/null 2>&1; then
    tripwire=$(fm_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] || {
      fm_herdr_lab_error "missing fleet-state tripwire for existing session '$name'; refusing to adopt it"
      return 1
    }
    fm_herdr_lab_assert_owned_from_list "$name" "$sessions" || return 1
    running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
      '.sessions[] | select(.name == $name) | .running' 2>/dev/null)
    [ "$running" = false ] || {
      fm_herdr_lab_error "session '$name' is not stopped; refusing to re-provision it"
      return 1
    }
    fm_herdr_lab_check_tripwire "$name" || return 1
  else
    fm_herdr_lab_prepare "$name" || return 1
  fi
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions immediately before provisioning '$name'"
    return 1
  }
  expected=$(fm_herdr_lab_state_owned_identity "$name") || expected=""
  state=$(fm_herdr_lab_session_state_from_list "$name" "$sessions") || state=invalid
  if [ -n "$expected" ]; then
    fm_herdr_lab_assert_owned_from_list "$name" "$sessions" || return 1
    running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
      '.sessions[] | select(.name == $name) | .running' 2>/dev/null)
    [ "$running" = false ] || {
      fm_herdr_lab_error "session '$name' is not stopped immediately before provisioning"
      return 1
    }
  else
    [ "$state" = absent ] || {
      fm_herdr_lab_error "session '$name' appeared before provisioning; refusing to adopt it"
      return 1
    }
    fm_herdr_lab_check_baseline_from_list "$name" "$sessions" || return 1
  fi
  fm_herdr_lab_raw "$name" server >/dev/null 2>&1 &
  server_pid=$!
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    running=$(fm_herdr_lab_cli "$name" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null) || running=false
    if [ "$running" = true ]; then
      sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || sessions=""
      fm_herdr_lab_capture_identity_from_list "$name" "$sessions" "$server_pid" || {
        fm_herdr_lab_cancel_provision "$server_pid"
        fm_herdr_lab_timeout_postcheck "$name" || true
        return 1
      }
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_cancel_provision "$server_pid"
  fm_herdr_lab_error "lab session '$name' did not report running within 10 seconds"
  fm_herdr_lab_timeout_postcheck "$name" || true
  return 1
}

fm_herdr_lab_check_tripwire() { # <session>
  local name=$1 tripwire sessions
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing unverified teardown"
    return 1
  }
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot read Herdr sessions for the fleet-state tripwire"
    return 1
  }
  fm_herdr_lab_check_baseline_from_list "$name" "$sessions"
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
  fm_herdr_lab_assert_owned "$name" || return 1
  fm_herdr_lab_raw "$name" session stop "$name" --json
}

fm_herdr_lab_teardown() { # <session>
  local name=$1 tripwire sessions state delete_status=0 attempt=0
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
  state=$(fm_herdr_lab_session_state_from_list "$name" "$sessions") || {
    fm_herdr_lab_error "cannot classify lab session '$name' before teardown"
    return 1
  }
  case "$state" in
    absent) fm_herdr_lab_verify_tripwire "$name"; return ;;
    nondefault) fm_herdr_lab_assert_owned_from_list "$name" "$sessions" || return 1 ;;
    *) fm_herdr_lab_error "refusing teardown for '$name': unsafe session state '$state'"; return 1 ;;
  esac
  fm_herdr_lab_stop "$name" >/dev/null 2>&1 || return 1
  sleep 0.5
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before delete"
    return 1
  }
  state=$(fm_herdr_lab_session_state_from_list "$name" "$sessions") || {
    fm_herdr_lab_error "cannot classify lab session '$name' before delete"
    return 1
  }
  case "$state" in
    absent) fm_herdr_lab_verify_tripwire "$name"; return ;;
    nondefault) ;;
    *) fm_herdr_lab_error "refusing delete for '$name': unsafe session state '$state'"; return 1 ;;
  esac
  fm_herdr_lab_assert_owned "$name" || return 1
  fm_herdr_lab_raw "$name" session delete "$name" --json >/dev/null 2>&1 || delete_status=$?
  while [ "$attempt" -lt 20 ]; do
    sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
      fm_herdr_lab_error "cannot confirm removal of lab session '$name' after teardown"
      return 1
    }
    state=$(fm_herdr_lab_session_state_from_list "$name" "$sessions") || {
      fm_herdr_lab_error "cannot classify lab session '$name' after delete"
      return 1
    }
    case "$state" in
      absent) fm_herdr_lab_verify_tripwire "$name"; return ;;
      nondefault) fm_herdr_lab_assert_owned_from_list "$name" "$sessions" || return 1 ;;
      *) fm_herdr_lab_error "lab session '$name' became unsafe while awaiting deletion (state=$state)"; return 1 ;;
    esac
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if [ "$delete_status" -ne 0 ]; then
    fm_herdr_lab_error "session delete failed for '$name' and the lab session remains"
  else
    fm_herdr_lab_error "lab session '$name' remains after teardown"
  fi
  return 1
}

fm_herdr_lab_name() { # <label>
  local label=${1:-lab}
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-' | sed 's/^[^a-zA-Z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  printf 'fm-lab-%s-%s-%s\n' "$label" "$$" "$RANDOM"
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
