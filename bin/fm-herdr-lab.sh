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
# Session stop is available only through guarded stop, and session delete is
# available only through teardown after a verified guarded stop.
# Both paths perform fresh baseline and ownership checks immediately before
# each destructive call.
# Provision records the initial fleet baseline and a nonce-bound process and
# storage identity, and every lifecycle operation requires both to match.
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

fm_herdr_lab_pid_identity() { # <pid>
  local pid=$1 identity
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  identity=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity" | sed 's/^[[:space:]]*//'
}

fm_herdr_lab_pid_descends_from() { # <pid> <ancestor-pid>
  local pid=$1 ancestor=$2 parent
  while [ "$pid" -gt 1 ] 2>/dev/null; do
    [ "$pid" = "$ancestor" ] && return 0
    parent=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ') || return 1
    case "$parent" in
      ''|*[!0-9]*) return 1 ;;
    esac
    pid=$parent
  done
  return 1
}

fm_herdr_lab_path_owner_pid() { # <path>
  local path=$1 owners
  command -v lsof >/dev/null 2>&1 || return 1
  owners=$(lsof -n -P -t -- "$path" 2>/dev/null | sort -u) || return 1
  [ -n "$owners" ] && [ "$(printf '%s\n' "$owners" | wc -l | tr -d ' ')" = 1 ] || return 1
  printf '%s\n' "$owners"
}

fm_herdr_lab_pid_holds_path() { # <pid> <path>
  local pid=$1 path=$2 holders
  holders=$(lsof -n -P -a -p "$pid" -t -- "$path" 2>/dev/null | sort -u) || return 1
  [ "$holders" = "$pid" ]
}

fm_herdr_lab_new_token() { # <session>
  local name=$1 state_dir token nonce
  state_dir=$(fm_herdr_lab_state_dir)
  token=$(mktemp "$state_dir/$name.launch-token.XXXXXX") || return 1
  nonce=$(od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n') || {
    rm -f "$token"
    return 1
  }
  [ "${#nonce}" = 64 ] || {
    rm -f "$token"
    return 1
  }
  chmod 600 "$token" || {
    rm -f "$token"
    return 1
  }
  printf '%s\n' "$nonce" > "$token" || {
    rm -f "$token"
    return 1
  }
  printf '%s\n' "$token"
}

fm_herdr_lab_server_with_token() { # <session> <token-path>
  local name=$1 token=$2
  exec 9< "$token" || return 1
  FM_HERDR_LAB_TOKEN_PATH="$token" fm_herdr_lab_raw "$name" server
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
          )
        )
      )
      then {sessions: ($baseline | map({default, name, running, socket_path}))}
      else empty
      end
  ' 2>/dev/null
}

fm_herdr_lab_identity_from_list() { # <session> <session-list-json>
  local name=$1 info=$2
  fm_herdr_lab_session_list_is_valid "$info" || return 1
  printf '%s' "$info" | jq -S -c -s --arg name "$name" '
    [.[0].sessions[] | select(.name == $name)]
    | if (length == 1 and .[0].default == false)
      then .[0] | {default, name, socket_path}
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
          and ((.[0].owned_session | keys | sort) == ["instance", "phase", "record"])
          and ((.[0].owned_session.record | keys | sort) == ["default", "name", "socket_path"])
          and .[0].owned_session.record.name == $name
          and .[0].owned_session.record.default == false
          and (.[0].owned_session.record.socket_path | type == "string" and length > 0)
          and (.[0].owned_session.record | has("running") | not)
          and (.[0].owned_session.phase == "running" or .[0].owned_session.phase == "stopped")
          and ((.[0].owned_session.instance | keys | sort) == ["pid", "process_identity", "storage_identity", "token_nonce", "token_path"])
          and (.[0].owned_session.instance.pid | type == "number" and . > 1 and floor == .)
          and (.[0].owned_session.instance.process_identity | type == "string" and length > 0)
          and (.[0].owned_session.instance.storage_identity | type == "string" and test("^[0-9]+:[0-9]+$"))
          and (.[0].owned_session.instance.token_path | type == "string" and length > 0)
          and (.[0].owned_session.instance.token_nonce | type == "string" and test("^[0-9a-f]{64}$"))
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

fm_herdr_lab_state_owned_record() { # <session>
  local state
  state=$(fm_herdr_lab_state_read "$1") || return 1
  printf '%s' "$state" | jq -S -c -r '.owned_session.record // empty' 2>/dev/null
}

fm_herdr_lab_state_instance() { # <session>
  local state
  state=$(fm_herdr_lab_state_read "$1") || return 1
  printf '%s' "$state" | jq -S -c -r '.owned_session.instance // empty' 2>/dev/null
}

fm_herdr_lab_state_phase() { # <session>
  local state
  state=$(fm_herdr_lab_state_read "$1") || return 1
  printf '%s' "$state" | jq -r '.owned_session.phase // empty' 2>/dev/null
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

fm_herdr_lab_record_storage_identity() { # <record-json>
  local record=$1 name socket storage identity
  name=$(printf '%s' "$record" | jq -r '.name') || return 1
  socket=$(printf '%s' "$record" | jq -r '.socket_path') || return 1
  storage=${socket%/*}
  [ "$storage" != "$socket" ] && [ -d "$storage" ] && [ ! -L "$storage" ] || return 1
  [ "${storage##*/}" = "$name" ] || return 1
  identity=$(LC_ALL=C stat -c '%d:%i' "$storage" 2>/dev/null) \
    || identity=$(LC_ALL=C stat -f '%d:%i' "$storage" 2>/dev/null) \
    || return 1
  case "$identity" in
    *[!0-9:]*|:|*::*|:*|*:) return 1 ;;
  esac
  printf '%s\n' "$identity"
}

fm_herdr_lab_instance_storage_matches() { # <session>
  local name=$1 state instance record token nonce state_dir expected_storage actual_storage
  state=$(fm_herdr_lab_state_read "$name") || return 1
  instance=$(printf '%s' "$state" | jq -S -c '.owned_session.instance') || return 1
  record=$(printf '%s' "$state" | jq -S -c '.owned_session.record') || return 1
  [ -n "$instance" ] || return 1
  token=$(printf '%s' "$instance" | jq -r '.token_path') || return 1
  nonce=$(printf '%s' "$instance" | jq -r '.token_nonce') || return 1
  state_dir=$(fm_herdr_lab_state_dir)
  case "$token" in
    "$state_dir/$name.launch-token."*) ;;
    *) return 1 ;;
  esac
  [ -f "$token" ] && [ ! -L "$token" ] || return 1
  [ "$(cat "$token" 2>/dev/null)" = "$nonce" ] || return 1
  expected_storage=$(printf '%s' "$instance" | jq -r '.storage_identity') || return 1
  actual_storage=$(fm_herdr_lab_record_storage_identity "$record") || return 1
  [ "$actual_storage" = "$expected_storage" ]
}

fm_herdr_lab_live_instance_matches() { # <session> <record-json>
  local name=$1 record=$2 instance pid expected_identity actual_identity socket token owner
  fm_herdr_lab_instance_storage_matches "$name" || return 1
  instance=$(fm_herdr_lab_state_instance "$name") || return 1
  pid=$(printf '%s' "$instance" | jq -r '.pid') || return 1
  expected_identity=$(printf '%s' "$instance" | jq -r '.process_identity') || return 1
  actual_identity=$(fm_herdr_lab_pid_identity "$pid") || return 1
  [ "$actual_identity" = "$expected_identity" ] || return 1
  socket=$(printf '%s' "$record" | jq -r '.socket_path') || return 1
  token=$(printf '%s' "$instance" | jq -r '.token_path') || return 1
  owner=$(fm_herdr_lab_path_owner_pid "$socket") || return 1
  [ "$owner" = "$pid" ] || return 1
  fm_herdr_lab_pid_holds_path "$pid" "$token"
}

fm_herdr_lab_assert_owned_from_list() { # <session> <session-list-json>
  local name=$1 info=$2 expected actual running phase
  fm_herdr_lab_check_baseline_from_list "$name" "$info" || return 1
  expected=$(fm_herdr_lab_state_owned_record "$name") || expected=""
  actual=$(fm_herdr_lab_identity_from_list "$name" "$info") || actual=""
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || {
    fm_herdr_lab_error "OWNERSHIP TRIPWIRE FAILED: session '$name' is missing, unproven, or changed"
    return 1
  }
  running=$(printf '%s' "$info" | jq -r --arg name "$name" \
    '.sessions[] | select(.name == $name) | .running' 2>/dev/null) || return 1
  phase=$(fm_herdr_lab_state_phase "$name") || return 1
  if [ "$running" = true ]; then
    [ "$phase" = running ] || {
      fm_herdr_lab_error "INSTANCE TRIPWIRE FAILED: stopped proof cannot authorize a running session '$name'"
      return 1
    }
    fm_herdr_lab_live_instance_matches "$name" "$actual" || {
      fm_herdr_lab_error "INSTANCE TRIPWIRE FAILED: live session '$name' is not the launched process"
      return 1
    }
  else
    case "$phase" in
      running|stopped) ;;
      *) return 1 ;;
    esac
    fm_herdr_lab_instance_storage_matches "$name" || {
      fm_herdr_lab_error "INSTANCE TRIPWIRE FAILED: stopped session '$name' lost its launch nonce"
      return 1
    }
  fi
}

fm_herdr_lab_capture_identity_from_list() { # <session> <session-list-json> <server-pid> <token-path>
  local name=$1 info=$2 server_pid=$3 token=$4 state expected actual updated running
  local socket owner process_identity storage_identity nonce old_token old_nonce
  kill -0 "$server_pid" 2>/dev/null || {
    fm_herdr_lab_error "cannot prove ownership for '$name': provisioning process exited"
    return 1
  }
  fm_herdr_lab_check_baseline_from_list "$name" "$info" || return 1
  state=$(fm_herdr_lab_state_read "$name") || return 1
  expected=$(printf '%s' "$state" | jq -S -c -r '.owned_session.record // empty' 2>/dev/null) || return 1
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
  [ -z "$expected" ] || [ "$expected" = "$actual" ] || {
    fm_herdr_lab_error "OWNERSHIP TRIPWIRE FAILED: session '$name' changed during provisioning"
    return 1
  }
  socket=$(printf '%s' "$actual" | jq -r '.socket_path') || return 1
  owner=$(fm_herdr_lab_path_owner_pid "$socket") || {
    fm_herdr_lab_error "cannot prove ownership for '$name': socket owner is missing or ambiguous"
    return 1
  }
  fm_herdr_lab_pid_descends_from "$owner" "$server_pid" || {
    fm_herdr_lab_error "cannot prove ownership for '$name': socket owner is outside the launched process tree"
    return 1
  }
  fm_herdr_lab_pid_holds_path "$owner" "$token" || {
    fm_herdr_lab_error "cannot prove ownership for '$name': socket owner lacks the launch nonce descriptor"
    return 1
  }
  process_identity=$(fm_herdr_lab_pid_identity "$owner") || return 1
  storage_identity=$(fm_herdr_lab_record_storage_identity "$actual") || {
    fm_herdr_lab_error "cannot prove ownership for '$name': session storage identity is unavailable"
    return 1
  }
  nonce=$(cat "$token") || return 1
  if [ -n "$expected" ]; then
    fm_herdr_lab_instance_storage_matches "$name" || return 1
    old_token=$(printf '%s' "$state" | jq -r '.owned_session.instance.token_path') || return 1
    old_nonce=$(printf '%s' "$state" | jq -r '.owned_session.instance.token_nonce') || return 1
  else
    old_token=""
    old_nonce=""
  fi
  updated=$(printf '%s' "$state" | jq -S -c \
    --argjson record "$actual" --argjson pid "$owner" --arg process_identity "$process_identity" \
    --arg storage_identity "$storage_identity" --arg token_path "$token" --arg token_nonce "$nonce" \
    '.owned_session = {record:$record,phase:"running",instance:{pid:$pid,process_identity:$process_identity,storage_identity:$storage_identity,token_path:$token_path,token_nonce:$token_nonce}}') || return 1
  fm_herdr_lab_write_state "$name" "$updated" || return 1
  fm_herdr_lab_live_instance_matches "$name" "$actual" || {
    fm_herdr_lab_write_state "$name" "$state" || true
    fm_herdr_lab_error "cannot prove ownership for '$name': instance changed during identity capture"
    return 1
  }
  if [ -n "$old_token" ] && [ "$old_token" != "$token" ] && [ "$(cat "$old_token" 2>/dev/null)" = "$old_nonce" ]; then
    rm -f "$old_token"
  fi
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

fm_herdr_lab_prepare_unlocked() { # <session>
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
    fm_herdr_lab_error "initial fleet-state must be exactly empty or exactly one default session"
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
  expected=$(fm_herdr_lab_state_owned_record "$name") || expected=""
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

fm_herdr_lab_cleanup_unclaimed_token() { # <session> <token-path>
  local name=$1 token=$2 instance claimed
  instance=$(fm_herdr_lab_state_instance "$name" 2>/dev/null) || instance=""
  claimed=$(printf '%s' "$instance" | jq -r '.token_path // empty' 2>/dev/null) || claimed=""
  if [ "$claimed" != "$token" ]; then
    rm -f "$token"
  fi
}

fm_herdr_lab_provision_unlocked() { # <session>
  local name=$1 sessions tripwire running attempt server_pid expected state token
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }
  command -v lsof >/dev/null 2>&1 || { fm_herdr_lab_error "lsof is required for instance ownership"; return 1; }

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
    fm_herdr_lab_prepare_unlocked "$name" || return 1
  fi
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions immediately before provisioning '$name'"
    return 1
  }
  expected=$(fm_herdr_lab_state_owned_record "$name") || expected=""
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
  token=$(fm_herdr_lab_new_token "$name") || {
    fm_herdr_lab_error "cannot create launch nonce for '$name'"
    return 1
  }
  fm_herdr_lab_server_with_token "$name" "$token" >/dev/null 2>&1 &
  server_pid=$!
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    running=$(fm_herdr_lab_cli "$name" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null) || running=false
    if [ "$running" = true ]; then
      sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || sessions=""
      fm_herdr_lab_capture_identity_from_list "$name" "$sessions" "$server_pid" "$token" || {
        fm_herdr_lab_cancel_provision "$server_pid"
        fm_herdr_lab_timeout_postcheck "$name" || true
        fm_herdr_lab_cleanup_unclaimed_token "$name" "$token"
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
  fm_herdr_lab_cleanup_unclaimed_token "$name" "$token"
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
  local name=$1 tripwire instance token nonce
  fm_herdr_lab_check_tripwire "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  instance=$(fm_herdr_lab_state_instance "$name" 2>/dev/null) || instance=""
  if [ -n "$instance" ]; then
    token=$(printf '%s' "$instance" | jq -r '.token_path') || return 1
    nonce=$(printf '%s' "$instance" | jq -r '.token_nonce') || return 1
    [ "$(cat "$token" 2>/dev/null)" = "$nonce" ] || return 1
    rm -f "$token" || return 1
  fi
  rm -f "$tripwire"
}

fm_herdr_lab_instance_process_is_gone() { # <session>
  local name=$1 state instance record pid expected_identity actual_identity socket
  state=$(fm_herdr_lab_state_read "$name") || return 1
  instance=$(printf '%s' "$state" | jq -c '.owned_session.instance') || return 1
  record=$(printf '%s' "$state" | jq -c '.owned_session.record') || return 1
  pid=$(printf '%s' "$instance" | jq -r '.pid') || return 1
  expected_identity=$(printf '%s' "$instance" | jq -r '.process_identity') || return 1
  actual_identity=$(fm_herdr_lab_pid_identity "$pid" 2>/dev/null) || actual_identity=""
  [ "$actual_identity" != "$expected_identity" ] || return 1
  socket=$(printf '%s' "$record" | jq -r '.socket_path') || return 1
  [ ! -e "$socket" ]
}

fm_herdr_lab_stop_postcheck() { # <session>
  local name=$1 sessions state running attempt=0
  while [ "$attempt" -lt 20 ]; do
    sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
      fm_herdr_lab_error "STOP POSTCHECK FAILED: cannot read Herdr sessions"
      return 1
    }
    fm_herdr_lab_check_baseline_from_list "$name" "$sessions" || return 1
    state=$(fm_herdr_lab_session_state_from_list "$name" "$sessions") || state=invalid
    case "$state" in
      absent)
        fm_herdr_lab_instance_process_is_gone "$name" && return 0
        ;;
      nondefault)
        running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
          '.sessions[] | select(.name == $name) | .running' 2>/dev/null) || running=invalid
        if [ "$running" = false ]; then
          fm_herdr_lab_assert_owned_from_list "$name" "$sessions" || {
            fm_herdr_lab_error "STOP POSTCHECK FAILED: stopped instance changed"
            return 1
          }
          fm_herdr_lab_instance_process_is_gone "$name" && return 0
        fi
        ;;
      *)
        fm_herdr_lab_error "STOP POSTCHECK FAILED: session '$name' is ambiguous"
        return 1
        ;;
    esac
    sleep 0.1
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_error "STOP POSTCHECK FAILED: launched instance did not stop"
  return 1
}

fm_herdr_lab_mark_stopped() { # <session>
  local name=$1 state updated
  state=$(fm_herdr_lab_state_read "$name") || return 1
  [ "$(printf '%s' "$state" | jq -r '.owned_session.phase')" = running ] || return 1
  updated=$(printf '%s' "$state" | jq -S -c '.owned_session.phase = "stopped"') || return 1
  fm_herdr_lab_write_state "$name" "$updated"
}

fm_herdr_lab_stop_unlocked() { # <session>
  local name=$1 tripwire sessions running phase stop_status=0 post_status=0
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing stop"
    return 1
  }
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions immediately before stop"
    return 1
  }
  fm_herdr_lab_assert_owned_from_list "$name" "$sessions" || return 1
  running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
    '.sessions[] | select(.name == $name) | .running' 2>/dev/null) || return 1
  phase=$(fm_herdr_lab_state_phase "$name") || return 1
  if [ "$running" = false ]; then
    [ "$phase" = stopped ] && return 0
    fm_herdr_lab_stop_postcheck "$name" || return 1
    fm_herdr_lab_mark_stopped "$name"
    return
  fi
  fm_herdr_lab_raw "$name" session stop "$name" --json || stop_status=$?
  fm_herdr_lab_stop_postcheck "$name" || post_status=$?
  if [ "$post_status" -eq 0 ]; then
    fm_herdr_lab_mark_stopped "$name" || post_status=$?
  fi
  if [ "$stop_status" -ne 0 ]; then
    fm_herdr_lab_error "session stop failed for '$name' (status=$stop_status)"
  fi
  [ "$stop_status" -eq 0 ] && [ "$post_status" -eq 0 ]
}

fm_herdr_lab_teardown_unlocked() { # <session>
  local name=$1 tripwire sessions state running phase owned delete_status=0 attempt=0
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
    absent)
      owned=$(fm_herdr_lab_state_owned_record "$name" 2>/dev/null) || owned=""
      if [ -n "$owned" ]; then
        fm_herdr_lab_instance_process_is_gone "$name" || {
          fm_herdr_lab_error "refusing teardown: session '$name' disappeared while its launched process remains"
          return 1
        }
      fi
      fm_herdr_lab_verify_tripwire "$name"
      return
      ;;
    nondefault) fm_herdr_lab_assert_owned_from_list "$name" "$sessions" || return 1 ;;
    *) fm_herdr_lab_error "refusing teardown for '$name': unsafe session state '$state'"; return 1 ;;
  esac
  running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
    '.sessions[] | select(.name == $name) | .running' 2>/dev/null) || running=invalid
  phase=$(fm_herdr_lab_state_phase "$name") || phase=invalid
  [ "$running" = true ] && [ "$phase" = running ] || {
    fm_herdr_lab_error "refusing delete for '$name': Herdr exposes no persistent instance identity after a separate stop; reprovision through the helper before teardown"
    return 1
  }
  fm_herdr_lab_stop_unlocked "$name" || return 1
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions immediately before delete"
    return 1
  }
  state=$(fm_herdr_lab_session_state_from_list "$name" "$sessions") || state=invalid
  if [ "$state" = absent ]; then
    fm_herdr_lab_instance_process_is_gone "$name" || {
      fm_herdr_lab_error "refusing teardown: session '$name' disappeared while its launched process remains"
      return 1
    }
    fm_herdr_lab_verify_tripwire "$name"
    return
  fi
  [ "$state" = nondefault ] || {
    fm_herdr_lab_error "refusing delete for '$name': session changed immediately before delete"
    return 1
  }
  running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
    '.sessions[] | select(.name == $name) | .running' 2>/dev/null) || running=invalid
  phase=$(fm_herdr_lab_state_phase "$name") || phase=invalid
  [ "$running" = false ] && [ "$phase" = stopped ] || {
    fm_herdr_lab_error "refusing delete for '$name': guarded stopped proof is missing"
    return 1
  }
  fm_herdr_lab_assert_owned_from_list "$name" "$sessions" || return 1
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
    fm_herdr_lab_check_baseline_from_list "$name" "$sessions" || return 1
    if [ "$state" = absent ]; then
      if fm_herdr_lab_instance_process_is_gone "$name"; then
        fm_herdr_lab_verify_tripwire "$name"
        return
      fi
    elif [ "$state" = nondefault ]; then
      fm_herdr_lab_assert_owned_from_list "$name" "$sessions" || return 1
    else
      fm_herdr_lab_error "lab session '$name' became unsafe while awaiting deletion (state=$state)"
      return 1
    fi
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

fm_herdr_lab_release_lock() { # <lock-file> <owner-token>
  local lock=$1 owner=$2 actual
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  actual=$(cat "$lock") || return 1
  [ "$actual" = "$owner" ] || return 1
  rm -f "$lock"
}

fm_herdr_lab_with_lock() ( # <function> <session>
  local operation=$1 name=$2 state_dir lock owner_tmp="" pid_file pid identity nonce owner lock_status=0
  fm_herdr_lab_validate_name "$name" || return 1
  state_dir=$(fm_herdr_lab_state_dir)
  mkdir -p "$state_dir" || return 1
  lock="$state_dir/$name.lifecycle-lock"
  pid_file=$(mktemp "$state_dir/$name.lock-pid.XXXXXX") || return 1
  sh -c 'printf "%s\n" "$PPID" > "$1"' _ "$pid_file" || {
    rm -f "$pid_file"
    return 1
  }
  pid=$(cat "$pid_file") || {
    rm -f "$pid_file"
    return 1
  }
  rm -f "$pid_file" || return 1
  identity=$(fm_herdr_lab_pid_identity "$pid") || return 1
  nonce=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  owner=$(printf '%s\n%s\n%s' "$pid" "$identity" "$nonce")
  trap 'lock_status=$?; trap - EXIT INT TERM; if [ -e "$lock" ]; then fm_herdr_lab_release_lock "$lock" "$owner" || lock_status=1; fi; [ -z "$owner_tmp" ] || rm -f "$owner_tmp" || lock_status=1; exit "$lock_status"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  owner_tmp=$(mktemp "$state_dir/$name.lock-owner.XXXXXX") || return 1
  printf '%s\n' "$owner" > "$owner_tmp" || return 1
  ln "$owner_tmp" "$lock" 2>/dev/null || {
    fm_herdr_lab_error "lifecycle operation already active for '$name'"
    return 1
  }
  rm -f "$owner_tmp" || return 1
  owner_tmp=""
  "$operation" "$name"
)

fm_herdr_lab_prepare() { # <session>
  fm_herdr_lab_with_lock fm_herdr_lab_prepare_unlocked "$1"
}

fm_herdr_lab_provision() { # <session>
  fm_herdr_lab_with_lock fm_herdr_lab_provision_unlocked "$1"
}

fm_herdr_lab_stop() { # <session>
  fm_herdr_lab_with_lock fm_herdr_lab_stop_unlocked "$1"
}

fm_herdr_lab_teardown() { # <session>
  fm_herdr_lab_with_lock fm_herdr_lab_teardown_unlocked "$1"
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
