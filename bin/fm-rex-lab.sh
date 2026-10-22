#!/usr/bin/env bash
# Provision and operate an isolated Rex lab server without risking the live
# Rex server and its sessions.
#
# Usage:
#   fm-rex-lab.sh name <label>
#   fm-rex-lab.sh provision <lab>
#   fm-rex-lab.sh server <lab>
#   fm-rex-lab.sh run <lab> <rex arguments...>
#   fm-rex-lab.sh teardown <lab>
#
# Lab names must begin with "fm-rexlab-"; the name command sanitizes the
# label, caps it at 16 characters, and appends process/random suffixes.
# Provision starts a private headless server with `rex server run --listen
# unix://<dir>/s.sock --state-dir <dir>/state --config <dir>/empty.lua` from a
# scrubbed environment (REX_*, TMUX*, HERDR_*, FM_*, CLAUDE*, and TERM_PROGRAM*
# removed), where <dir> is a short private directory under
# FM_REX_LAB_STATE_DIR (default /tmp/fm-rex-lab-<uid>), because macOS caps
# Unix socket paths near 104 bytes.
# Server prints the lab's `unix://` address, for FM_REX_SERVER.
# Every Rex call made here carries `-S <lab address> --autostart=false` with
# REX_SESSION, REX_BLOCK, REX_CLIENT, and REX_SERVER removed from its
# environment, so it can neither reach another server nor autostart one.
# The run command rejects caller-supplied server, client, or autostart options
# and every `server` subcommand.
# Provision records the live default server's instance id and session ids as a
# fleet-state tripwire when that server is running; teardown stops only the lab
# server, through its own socket, and then requires the live server to report
# the same instance id with every recorded session still present.
# A lab whose socket is the live server's endpoint is refused everywhere.
set -u

fm_rex_lab_error() {
  echo "fm-rex-lab: $*" >&2
}

fm_rex_lab_bin() {
  if [ -n "${REX_BIN_DIR:-}" ] && [ -x "$REX_BIN_DIR/rex" ]; then
    printf '%s' "$REX_BIN_DIR/rex"
  elif command -v rex >/dev/null 2>&1; then
    command -v rex
  else
    return 1
  fi
}

fm_rex_lab_validate_name() { # <lab>
  [[ "${1:-}" =~ ^fm-rexlab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && return 0
  fm_rex_lab_error "lab name must start with 'fm-rexlab-' and contain only letters, digits, underscores, or dashes: ${1:-<empty>}"
  return 1
}

fm_rex_lab_root() {
  printf '%s' "${FM_REX_LAB_STATE_DIR:-/tmp/fm-rex-lab-${UID}}"
}

fm_rex_lab_dir() { # <lab>
  printf '%s/%s' "$(fm_rex_lab_root)" "$1"
}

fm_rex_lab_address() { # <lab>
  printf 'unix://%s/s.sock' "$(fm_rex_lab_dir "$1")"
}

fm_rex_lab_raw() { # <rex arguments...>
  local bin
  bin=$(fm_rex_lab_bin) || { fm_rex_lab_error "rex is required"; return 1; }
  env -u REX_SESSION -u REX_BLOCK -u REX_CLIENT -u REX_SERVER "$bin" "$@"
}

# The live default server's endpoint, or empty when none is running.
fm_rex_lab_live_endpoint() {
  fm_rex_lab_raw --autostart=false server status --json 2>/dev/null | jq -r '.endpoint // empty' 2>/dev/null
}

fm_rex_lab_refuse_live() { # <lab>
  local live
  live=$(fm_rex_lab_live_endpoint)
  [ -n "$live" ] && [ "$live" = "$(fm_rex_lab_address "$1")" ] || return 0
  fm_rex_lab_error "refusing lab '$1': its socket is the live Rex server's endpoint"
  return 1
}

fm_rex_lab_lab() { # <lab> <rex arguments...>
  local name=$1
  shift
  fm_rex_lab_raw -S "$(fm_rex_lab_address "$name")" --autostart=false "$@"
}

# The tripwire snapshot: {instance_id, sessions[]} of the live default server,
# or {} when no live server is running.
fm_rex_lab_fleet_state() {
  local status sessions
  status=$(fm_rex_lab_raw --autostart=false server status --json 2>/dev/null) || {
    printf '{}\n'
    return 0
  }
  sessions=$(fm_rex_lab_raw --autostart=false ls --json 2>/dev/null) || {
    fm_rex_lab_error "cannot list the live Rex server's sessions for the fleet-state tripwire"
    return 1
  }
  jq -cn --argjson st "$status" --argjson ls "$sessions" \
    '{instance_id: $st.instance_id, sessions: [$ls.sessions[]?.session_id] | sort}'
}

fm_rex_lab_name() { # <label>
  local label=${1:-lab}
  label=$(printf '%s' "$label" | tr -c 'a-zA-Z0-9_-' '-' | cut -c1-16)
  printf 'fm-rexlab-%s-%s%s\n' "$label" "$$" "$RANDOM"
}

fm_rex_lab_provision() { # <lab>
  local name=$1 dir address i env_args=(-u REX_SERVER) var
  fm_rex_lab_validate_name "$name" || return 1
  command -v jq >/dev/null 2>&1 || { fm_rex_lab_error "jq is required"; return 1; }
  fm_rex_lab_bin >/dev/null || { fm_rex_lab_error "rex is required"; return 1; }
  fm_rex_lab_refuse_live "$name" || return 1
  dir=$(fm_rex_lab_dir "$name")
  address=$(fm_rex_lab_address "$name")
  [ ! -e "$dir" ] || { fm_rex_lab_error "lab '$name' already exists at $dir; refusing to adopt it"; return 1; }
  mkdir -p "$(fm_rex_lab_root)" && chmod 700 "$(fm_rex_lab_root)" && mkdir -m 700 "$dir" "$dir/state" || return 1
  : > "$dir/empty.lua"
  fm_rex_lab_fleet_state > "$dir/fleet-state.json" || return 1
  for var in $(env | awk -F= '/^(REX|TMUX|HERDR|FM|CLAUDE|TERM_PROGRAM)[A-Za-z0-9_]*=/ {print $1}'); do
    env_args+=(-u "$var")
  done
  env "${env_args[@]}" "$(fm_rex_lab_bin)" server run --listen "$address" \
    --state-dir "$dir/state" --config "$dir/empty.lua" > "$dir/server.log" 2>&1 &
  printf '%s\n' "$!" > "$dir/server.pid"
  for i in $(seq 1 50); do
    fm_rex_lab_lab "$name" server status --json >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  fm_rex_lab_error "lab server '$name' did not become reachable at $address (log: $dir/server.log)"
  return 1
}

fm_rex_lab_run() { # <lab> <rex arguments...>
  local name=$1 arg
  shift
  fm_rex_lab_validate_name "$name" || return 1
  [ -d "$(fm_rex_lab_dir "$name")" ] || { fm_rex_lab_error "lab '$name' is not provisioned"; return 1; }
  [ "$#" -gt 0 ] || { fm_rex_lab_error "run needs rex arguments"; return 1; }
  [ "$1" != server ] || { fm_rex_lab_error "refusing 'rex server ...' through run; use provision or teardown"; return 1; }
  for arg in "$@"; do
    [ "$arg" != -- ] || break
    case "$arg" in
      -S | --server | --server=* | -S* | -C | --client | --client=* | --autostart | --autostart=*)
        fm_rex_lab_error "refusing caller-supplied '$arg'; the lab supplies its own server and autostart options"
        return 1
        ;;
    esac
  done
  fm_rex_lab_refuse_live "$name" || return 1
  fm_rex_lab_lab "$name" "$@"
}

fm_rex_lab_teardown() { # <lab>
  local name=$1 dir pid i before after
  fm_rex_lab_validate_name "$name" || return 1
  dir=$(fm_rex_lab_dir "$name")
  [ -d "$dir" ] || return 0
  fm_rex_lab_refuse_live "$name" || return 1
  fm_rex_lab_lab "$name" server stop >/dev/null 2>&1 || true
  pid=$(cat "$dir/server.pid" 2>/dev/null || true)
  for i in $(seq 1 50); do
    { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || break
    sleep 0.1
  done
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    fm_rex_lab_error "lab server '$name' (pid $pid) did not stop through its own socket"
    return 1
  fi
  before=$(cat "$dir/fleet-state.json" 2>/dev/null || printf '{}')
  after=$(fm_rex_lab_fleet_state) || return 1
  if [ "$before" != '{}' ]; then
    jq -en --argjson b "$before" --argjson a "$after" \
      '$a.instance_id == $b.instance_id and ($b.sessions - $a.sessions | length) == 0' >/dev/null 2>&1 || {
      fm_rex_lab_error "TRIPWIRE: the live Rex server changed during lab '$name' (before $before, after $after)"
      return 1
    }
  fi
  rm -rf -- "$dir"
}

main() {
  local cmd=${1:-}
  [ "$#" -gt 0 ] && shift
  case "$cmd" in
    name) fm_rex_lab_name "$@" ;;
    provision) [ "$#" -eq 1 ] || { fm_rex_lab_error "usage: provision <lab>"; return 2; }; fm_rex_lab_provision "$1" ;;
    server) [ "$#" -eq 1 ] || { fm_rex_lab_error "usage: server <lab>"; return 2; }; fm_rex_lab_validate_name "$1" && fm_rex_lab_address "$1" && echo ;;
    run) [ "$#" -ge 1 ] || { fm_rex_lab_error "usage: run <lab> <rex arguments...>"; return 2; }; fm_rex_lab_run "$@" ;;
    teardown) [ "$#" -eq 1 ] || { fm_rex_lab_error "usage: teardown <lab>"; return 2; }; fm_rex_lab_teardown "$1" ;;
    -h | --help | help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) fm_rex_lab_error "unknown command '${cmd:-<none>}' (name, provision, server, run, teardown)"; return 2 ;;
  esac
}

main "$@"
