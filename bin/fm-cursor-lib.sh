#!/usr/bin/env bash
# Cursor executable resolution and Cursor process identity.
# Sourced by bin/fm-spawn.sh, bin/fm-harness.sh, bin/fm-session-lock-lib.sh,
# bin/backends/tmux.sh, bin/fm-tmux-lib.sh, and bin/backends/herdr.sh.
# This file is sourced by scripts and has no side effects on source.
# Generic spawn/teardown PID reuse guards live in bin/fm-process-identity-lib.sh.
# Cursor composer raw-render normalization (reverse-video cursor-cell gap) also
# lives here - see fm_cursor_composer_normalize below.
#
# Why one owner: cursor ships TWO executable names - `cursor-agent`, plus the
# legacy alias `agent` it installs on every platform. `agent` is far too
# generic to trust on its name alone, so every spawn, teardown, ancestry, and
# liveness caller has to agree on the same narrowed rule or an unrelated
# `/opt/agent`, an unrelated `agent` on PATH, or a path that merely contains an
# `agent/` directory component silently classifies as this harness. That
# widening previously let firstmate launch an unrelated executable with Cursor
# flags, report a remote host ready with no Cursor installed, and bind
# worker-server discovery to the wrong process.
#
# Resolver evidence is a bounded `--help` probe of the canonical executable.
# Cursor's own CLI banner and CURSOR_API_ENDPOINT / api2.cursor.sh option text
# identify it. Fails closed on timeout, non-zero exit, or missing markers.
# Process detection consumes launch identity metadata from the actual process,
# so upgrades do not invalidate already-running sessions.

# Bounded probe budget in seconds. Cursor's --help is local and returns
# immediately; the bound exists so a hung or interactive impostor cannot wedge
# a spawn or a readiness check.
FM_CURSOR_PROBE_TIMEOUT=${FM_CURSOR_PROBE_TIMEOUT:-10}
case "$FM_CURSOR_PROBE_TIMEOUT" in
  ''|*[!0-9]*|0*) FM_CURSOR_PROBE_TIMEOUT=10 ;;
esac

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
# shellcheck source=bin/fm-process-identity-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-process-identity-lib.sh"

# Canonical absolute path for $1, or the input unchanged when it cannot be
# resolved. Symlink resolution makes process and resolver paths comparable.
fm_cursor_canonical_path() {  # <path>
  local path=$1 dir base
  [ -n "$path" ] || return 1
  dir=$(CDPATH='' cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || { printf '%s\n' "$path"; return 0; }
  base=$(basename -- "$path")
  # Follow the symlink chain by hand: readlink -f is GNU-only and realpath is
  # not guaranteed on macOS, and this needs no new dependency.
  local hops=0 target
  while [ -L "$dir/$base" ] && [ "$hops" -lt 16 ]; do
    target=$(readlink "$dir/$base") || break
    case "$target" in
      /*) dir=$(CDPATH='' cd -- "$(dirname -- "$target")" 2>/dev/null && pwd -P) || break
          base=$(basename -- "$target") ;;
      *)  dir=$(CDPATH='' cd -- "$dir/$(dirname -- "$target")" 2>/dev/null && pwd -P) || break
          base=$(basename -- "$target") ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s\n' "$dir/$base"
}

# True when path $1 is an executable whose canonical target proves Cursor's CLI.
fm_cursor_path_is_cursor() {  # <path>
  local path=$1 canonical
  [ -n "$path" ] || return 1
  canonical=$(fm_cursor_canonical_path "$path") || return 1
  [ -x "$canonical" ] || return 1
  fm_cursor_probe_is_cursor "$canonical"
}

# True when running `$1 --help` produces Cursor's own CLI identity. Bounded and
# fail-closed: a timeout, a non-zero exit, or output without a Cursor-specific
# marker is a refusal.
fm_cursor_probe_is_cursor() {  # <path>
  local path=$1 out
  [ -n "$path" ] && [ -x "$path" ] || return 1
  out=$(fm_run_timed "$FM_CURSOR_PROBE_TIMEOUT" "$path" --help 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  case "$out" in
    *"Usage:"*"Start the Cursor Agent"*CURSOR_API_ENDPOINT*api2.cursor.sh*) return 0 ;;
  esac
  return 1
}

# True when executable $1 may be launched as Cursor.
#
# A basename or install-tree shape alone is not executable identity.
fm_cursor_verify_executable() {  # <path>
  fm_cursor_path_is_cursor "$1"
}

# Print the canonical absolute path of the Cursor executable to launch, or
# return 1 with a diagnostic on stderr.
#
# Resolution order, shared by bin/fm-spawn.sh and bin/fm-remote-doctor.sh:
# cursor-agent on PATH, `agent` on PATH, then the ~/.local/bin installs of
# both. cursor-agent is preferred over the alias at every stage. The
# ~/.local/bin fallbacks exist because Cursor's user-local install is routinely
# absent from a non-interactive login PATH. Every `agent` candidate passes
# fm_cursor_verify_executable before it is accepted, so an unrelated executable
# named agent is rejected rather than launched with Cursor's flags.
fm_cursor_resolve_binary() {
  local name candidate
  for name in cursor-agent agent; do
    candidate=$(command -v "$name" 2>/dev/null || true)
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    candidate=$(fm_cursor_canonical_path "$candidate") || continue
    if fm_cursor_verify_executable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  for name in cursor-agent agent; do
    [ -n "${HOME:-}" ] || break
    candidate="$HOME/.local/bin/$name"
    [ -x "$candidate" ] || continue
    candidate=$(fm_cursor_canonical_path "$candidate") || continue
    if fm_cursor_verify_executable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "error: no verified cursor executable found; searched PATH for 'cursor-agent' and 'agent', plus '${HOME:-}/.local/bin/cursor-agent' and '${HOME:-}/.local/bin/agent'. A candidate is accepted only when it passes its bounded CLI probe." >&2
  return 1
}

# Read one argv element without flattening it into a whitespace-delimited command line.
fm_cursor_ps_arg_at() {  # <args> <index>
  local args=$1 wanted=$2 token= ch quote= escaped=0 started=0 index=0 i
  for ((i = 0; i < ${#args}; i++)); do
    ch=${args:i:1}
    if [ "$escaped" -eq 1 ]; then
      token=$token$ch
      escaped=0
      started=1
      continue
    fi
    if [ -n "$quote" ]; then
      if [ "$ch" = "$quote" ]; then
        quote=
      else
        token=$token$ch
      fi
      started=1
      continue
    fi
    case "$ch" in
      "'"|\") quote=$ch; started=1 ;;
      \\) escaped=1; started=1 ;;
      [[:space:]])
        if [ "$started" -eq 1 ]; then
          if [ "$index" -eq "$wanted" ]; then
            printf '%s\n' "$token"
            return 0
          fi
          index=$((index + 1))
          token=
          started=0
        fi
        ;;
      *) token=$token$ch; started=1 ;;
    esac
  done
  [ "$started" -eq 1 ] && [ "$index" -eq "$wanted" ] || return 1
  printf '%s\n' "$token"
}

fm_cursor_argv0_from_ps_args() {  # <args>
  fm_cursor_ps_arg_at "$1" 0
}

fm_cursor_argv0_for_pid() {  # <pid> [comm-fallback] [args-fallback]
  local pid=$1 fallback=${2:-} args=${3:-} proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} argv0=
  if [ -r "$proc_root/$pid/cmdline" ]; then
    IFS= read -r -d '' argv0 < "$proc_root/$pid/cmdline" || true
    [ -n "$argv0" ] && { printf '%s\n' "$argv0"; return 0; }
  fi
  if [ -z "$fallback" ]; then
    fallback=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null || true)
  fi
  case "${fallback##*/}" in
    ''|agent|MainThread|node|node-*|node[0-9]*|python|python[0-9]*|python[0-9].[0-9]*) ;;
    *) printf '%s\n' "$fallback"; return 0 ;;
  esac
  if [ -z "$args" ]; then
    args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null || true)
  fi
  if [ -n "$args" ] && argv0=$(fm_cursor_argv0_from_ps_args "$args"); then
    printf '%s\n' "$argv0"
    return 0
  fi
  [ -n "$fallback" ] || return 1
  printf '%s\n' "$fallback"
}

fm_cursor_process_path_is_cursor() {  # <path>
  local path=$1 canonical
  [ -n "$path" ] && [ -x "$path" ] || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  canonical=$(fm_cursor_canonical_path "$path") || return 1
  fm_cursor_probe_is_cursor "$canonical"
}

fm_cursor_argv0_is_cursor() {  # <argv0>
  local argv0=$1
  [ -n "$argv0" ] || return 1
  fm_cursor_process_path_is_cursor "$argv0"
}

fm_cursor_process_environment_value() {  # <pid> <name>
  local pid=$1 name=$2 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} command_line environment value
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "$proc_root/$pid/environ" ]; then
    tr '\0' '\n' < "$proc_root/$pid/environ" 2>/dev/null \
      | awk -v name="$name" 'index($0, name "=") == 1 { sub(/^[^=]*=/, ""); print; exit }'
    return 0
  fi
  command_line=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null || true)
  environment=$(LC_ALL=C ps eww -p "$pid" -o command= 2>/dev/null || true)
  if [ -n "$command_line" ]; then
    case "$environment" in
      "$command_line") environment= ;;
      "$command_line"\ *) environment=${environment#"$command_line" } ;;
      *" $command_line") environment=${environment%" $command_line"} ;;
    esac
  fi
  value=$(LC_ALL=C awk -v needle=" $name=" '
    {
      text = " " $0
      position = index(text, needle)
      if (!position) exit
      value = substr(text, position + length(needle))
      if (match(value, / [A-Za-z_][A-Za-z0-9_]*=/))
        value = substr(value, 1, RSTART - 1)
      print value
      exit
    }
  ' <<EOF
$environment
EOF
  )
  if [ -n "$value" ]; then
    if [ -n "$command_line" ]; then
      case "$value" in
        "$command_line") value= ;;
        *" $command_line") value=${value%" $command_line"} ;;
      esac
    fi
  fi
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return 0
  fi
  return 1
}

fm_cursor_process_parent_pid() {  # <pid>
  local pid=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} stat_line
  local -a stat_fields
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 2 ] || return 1
    printf '%s\n' "${stat_fields[1]}"
    return 0
  fi
  LC_ALL=C ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]'
}

fm_cursor_process_has_launch_ancestor() {  # <pid> <launch-record>
  local pid=$1 launch_file=$2 launch_pid launch_identity launch_pgid current parent
  [ -f "$launch_file" ] && [ ! -L "$launch_file" ] || return 1
  IFS=$'\t' read -r launch_pid launch_identity launch_pgid < "$launch_file" || return 1
  case "$launch_pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$launch_identity" in starttime=*|lstart=*) ;; *) return 1 ;; esac
  current=$pid
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    if [ "$current" = "$launch_pid" ]; then
      fm_process_identity_matches "$current" "$launch_identity"
      return
    fi
    parent=$(fm_cursor_process_parent_pid "$current" 2>/dev/null || true)
    case "$parent" in ''|*[!0-9]*|0|1) return 1 ;; esac
    current=$parent
  done
  return 1
}

fm_cursor_launch_record_matches() {  # <launch-record> <token> <path>
  local launch_file=$1 token=$2 expected=$3 recorded_token recorded_path
  IFS=$'\t' read -r recorded_token recorded_path < <(sed -n '2p' "$launch_file")
  [ "$recorded_token" = "$token" ] || return 1
  case "$recorded_path" in /*) ;; *) return 1 ;; esac
  recorded_path=$(fm_cursor_canonical_path "$recorded_path") || return 1
  [ "$recorded_path" = "$expected" ]
}

fm_cursor_process_executable_path() {  # <pid>
  local pid=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} path
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -L "$proc_root/$pid/exe" ] || [ -r "$proc_root/$pid/exe" ] || return 1
  path=$(readlink "$proc_root/$pid/exe" 2>/dev/null || true)
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in *" (deleted)") path=${path% (deleted)} ;; esac
  fm_cursor_canonical_path "$path"
}

fm_cursor_process_executable_was_deleted() {  # <pid>
  local pid=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} path
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  path=$(readlink "$proc_root/$pid/exe" 2>/dev/null || true)
  case "$path" in *" (deleted)") return 0 ;; esac
  return 1
}

fm_cursor_process_first_script_arg() {  # <args>
  fm_cursor_ps_arg_at "$1" 1
}

fm_cursor_process_launch_files_are_owned() {  # <identity-file> <launch-file> <token>
  local record=$1 boundary_file=$2 token=$3 record_dir record_base id token_file meta expected_boundary recorded_token
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  [ -f "$boundary_file" ] && [ ! -L "$boundary_file" ] || return 1
  case "$token" in ''|*[![:xdigit:]]) return 1 ;; esac
  record_dir=$(CDPATH='' cd -- "$(dirname -- "$record")" 2>/dev/null && pwd -P) || return 1
  record_base=$(basename -- "$record")
  case "$record_base" in
    .*.cursor-identity."$token") ;;
    *) return 1 ;;
  esac
  id=${record_base#.}
  id=${id%.cursor-identity."$token"}
  [ -n "$id" ] || return 1
  token_file="$record_dir/$id.cursor-launch-token"
  meta="$record_dir/$id.meta"
  expected_boundary="$record_dir/.$id.cursor-boundary.$token.proof.launch"
  [ -f "$token_file" ] && [ ! -L "$token_file" ] || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  recorded_token=$(tr -d '\r\n' < "$token_file") || return 1
  [ "$recorded_token" = "$token" ] || return 1
  [ "$(fm_cursor_canonical_path "$boundary_file")" = "$expected_boundary" ] || return 1
}

fm_cursor_process_launch_identity_matches() {  # <pid> <canonical-path>
  local pid=$1 expected=$2 record recorded process_token boundary_file
  process_token=$(fm_cursor_process_environment_value "$pid" FM_CURSOR_LAUNCH_TOKEN 2>/dev/null || true)
  case "$process_token" in ''|*[![:xdigit:]]) return 1 ;; esac
  record=$(fm_cursor_process_environment_value "$pid" FM_CURSOR_IDENTITY_FILE 2>/dev/null || true)
  case "$record" in /*) ;; *) return 1 ;; esac
  boundary_file=$(fm_cursor_process_environment_value "$pid" FM_CURSOR_BOUNDARY_LAUNCH_FILE 2>/dev/null || true)
  case "$boundary_file" in /*) ;; *) return 1 ;; esac
  fm_cursor_process_launch_files_are_owned "$record" "$boundary_file" "$process_token" || return 1
  fm_cursor_process_has_launch_ancestor "$pid" "$boundary_file" || return 1
  fm_cursor_launch_record_matches "$boundary_file" "$process_token" "$expected" || return 1
  case "$record" in *".cursor-identity.$process_token") ;; *) return 1 ;; esac
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  IFS=$'\t' read -r recorded_token recorded < "$record" || return 1
  [ "$recorded_token" = "$process_token" ] || return 1
  [ -n "$recorded" ] || return 1
  recorded=$(fm_cursor_canonical_path "$recorded") || return 1
  [ "$recorded" = "$expected" ]
}

fm_cursor_process_has_identity() {  # <pid> <comm> <args> <argv0>
  local pid=$1 comm=${2:-} args=${3:-} argv0=${4:-}
  local expected expected_canonical observed observed_base first_arg first_canonical marker boundary_file process_token record
  first_arg=$(fm_cursor_process_first_script_arg "$args" 2>/dev/null || true)
  expected=$(fm_cursor_process_environment_value "$pid" FM_CURSOR_EXECUTABLE 2>/dev/null || true)
  case "$expected" in
    /*)
      case "$first_arg" in
        /*) case "$expected" in
          "$first_arg"|"$first_arg"\ *) expected=$first_arg ;;
        esac ;;
      esac
      expected_canonical=$(fm_cursor_canonical_path "$expected") || return 1
      fm_cursor_process_launch_identity_matches "$pid" "$expected_canonical" || return 1
      if observed=$(fm_cursor_process_executable_path "$pid"); then
        [ "$observed" = "$expected_canonical" ] && return 0
        observed_base=${observed##*/}
      else
        observed_base=${comm##*/}
      fi

      if [ -n "$argv0" ] && case "$argv0" in /*) true ;; *) false ;; esac; then
        if observed=$(fm_cursor_canonical_path "$argv0"); then
          [ "$observed" = "$expected_canonical" ] && return 0
        fi
      fi

      case "$observed_base" in
        node|node-*|node[0-9]*|python|python[0-9]*|python[0-9].[0-9]*|bun|deno) ;;
        *) return 1 ;;
      esac
      case "$first_arg" in /*) ;; *) return 1 ;; esac
      first_canonical=$(fm_cursor_canonical_path "$first_arg") || return 1
      [ "$first_canonical" = "$expected_canonical" ]
      return
      ;;
  esac

  marker=$(fm_cursor_process_environment_value "$pid" CURSOR_AGENT 2>/dev/null || true)
  [ "$marker" = 1 ] || return 1
  record=$(fm_cursor_process_environment_value "$pid" FM_CURSOR_IDENTITY_FILE 2>/dev/null || true)
  case "$record" in /*) ;; *) return 1 ;; esac
  boundary_file=$(fm_cursor_process_environment_value "$pid" FM_CURSOR_BOUNDARY_LAUNCH_FILE 2>/dev/null || true)
  case "$boundary_file" in /*) ;; *) return 1 ;; esac
  fm_cursor_process_has_launch_ancestor "$pid" "$boundary_file" || return 1
  process_token=$(fm_cursor_process_environment_value "$pid" FM_CURSOR_LAUNCH_TOKEN 2>/dev/null || true)
  case "$process_token" in ''|*[![:xdigit:]]) return 1 ;; esac
  fm_cursor_process_launch_files_are_owned "$record" "$boundary_file" "$process_token" || return 1
  if observed=$(fm_cursor_process_executable_path "$pid"); then
    case "${observed##*/}" in
      cursor-agent|agent)
        fm_cursor_launch_record_matches "$boundary_file" "$process_token" "$observed" && return 0
        ;;
      node|node-*|node[0-9]*|python|python[0-9]*|python[0-9].[0-9]*|bun|deno)
        first_canonical=$(fm_cursor_canonical_path "$first_arg") || return 1
        fm_cursor_launch_record_matches "$boundary_file" "$process_token" "$first_canonical" && return 0
        ;;
    esac
    return 1
  elif fm_cursor_launch_record_matches "$boundary_file" "$process_token" \
      "$(fm_cursor_canonical_path "$argv0" 2>/dev/null || true)"; then
    return 0
  fi
  first_canonical=$(fm_cursor_canonical_path "$first_arg") || return 1
  fm_cursor_launch_record_matches "$boundary_file" "$process_token" "$first_canonical"
}

fm_cursor_launch_token_process_absent() {  # <token> [excluded-pid]
  local token=$1 excluded_pid=${2:-} pid pids
  pids=$(LC_ALL=C ps -e -o pid= 2>/dev/null) || return 1
  while IFS= read -r pid; do
    pid=${pid#"${pid%%[![:space:]]*}"}
    pid=${pid%"${pid##*[![:space:]]}"}
    [ -n "$pid" ] || continue
    if [ "$pid" = "$$" ] || [ "$pid" = "${BASHPID:-$$}" ] \
       || [ "$pid" = "${PPID:-}" ] || [ "$pid" = "$excluded_pid" ]; then
      continue
    fi
    [ "$(fm_cursor_process_environment_value "$pid" FM_CURSOR_LAUNCH_TOKEN 2>/dev/null || true)" = "$token" ] \
      || continue
    return 1
  done <<EOF
$pids
EOF
  return 0
}

fm_cursor_launch_boundary_absent_file() {  # <launch-record> <token> [completion-file]
  local launch_file=$1 token=$2
  local launch_pid launch_identity launch_pgid launch_sid record_pgid pid pids
  local own_pgid own_sid current_pgid current_sid
  [ -f "$launch_file" ] || return 1
  IFS=$'\t' read -r launch_pid launch_identity launch_pgid < "$launch_file" || return 1
  record_pgid=$launch_pgid
  IFS=$'\t' read -r launch_pgid launch_sid < <(sed -n '3p' "$launch_file")
  [ -n "$launch_pgid" ] || launch_pgid=$record_pgid
  case "$launch_pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$launch_identity" in starttime=*|lstart=*) ;; *) return 1 ;; esac
  if kill -0 "$launch_pid" 2>/dev/null \
     && fm_process_identity_matches "$launch_pid" "$launch_identity"; then
    return 1
  fi
  case "$launch_pgid" in
    ''|*[!0-9]*|0|1) ;;
    *)
      own_pgid=$(LC_ALL=C ps -p "$$" -o pgid= 2>/dev/null || true)
      own_pgid=$(printf '%s' "$own_pgid" | tr -d '[:space:]')
      own_sid=$(LC_ALL=C ps -p "$$" -o sid= 2>/dev/null || true)
      own_sid=$(printf '%s' "$own_sid" | tr -d '[:space:]')
      if [ "$launch_pgid" != "$own_pgid" ]; then
        pids=$(LC_ALL=C ps -e -o pid= 2>/dev/null) || return 1
        while IFS= read -r pid; do
          pid=${pid#"${pid%%[![:space:]]*}"}
          pid=${pid%"${pid##*[![:space:]]}"}
          [ -n "$pid" ] || continue
          if [ "$pid" = "$$" ] || [ "$pid" = "${BASHPID:-$$}" ] \
             || [ "$pid" = "${PPID:-}" ] || [ "$pid" = "$launch_pid" ]; then
            continue
          fi
          current_pgid=$(LC_ALL=C ps -p "$pid" -o pgid= 2>/dev/null || true)
          current_pgid=$(printf '%s' "$current_pgid" | tr -d '[:space:]')
          [ "$current_pgid" = "$launch_pgid" ] && return 1
        done <<EOF
$pids
EOF
      fi
      if [ -n "$launch_sid" ] && [ "$launch_sid" != "$own_sid" ]; then
        pids=$(LC_ALL=C ps -e -o pid= 2>/dev/null) || return 1
        while IFS= read -r pid; do
          pid=${pid#"${pid%%[![:space:]]*}"}
          pid=${pid%"${pid##*[![:space:]]}"}
          [ -n "$pid" ] || continue
          if [ "$pid" = "$$" ] || [ "$pid" = "${BASHPID:-$$}" ] \
             || [ "$pid" = "${PPID:-}" ] || [ "$pid" = "$launch_pid" ]; then
            continue
          fi
          current_sid=$(LC_ALL=C ps -p "$pid" -o sid= 2>/dev/null || true)
          current_sid=$(printf '%s' "$current_sid" | tr -d '[:space:]')
          [ "$current_sid" = "$launch_sid" ] && return 1
        done <<EOF
$pids
EOF
      fi
      ;;
  esac
  fm_cursor_launch_token_process_absent "$token" "$launch_pid"
}

fm_cursor_launch_boundary_complete_file() {  # <launch-record> <completion-file>
  local launch_file=$1 completion_file=$2
  local launch_pid launch_identity launch_pgid launch_token launch_executable launch_sid
  local own_pgid own_sid current_pgid current_sid pid pids worker_pid worker_file
  local token_absent_file tree_complete_file
  [ -f "$launch_file" ] && [ -f "$completion_file" ] || return 1
  IFS=$'\t' read -r launch_pid launch_identity launch_pgid < "$launch_file" || return 1
  case "$launch_pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$launch_identity" in starttime=*|lstart=*) ;; *) return 1 ;; esac
  IFS=$'\t' read -r launch_token launch_executable < <(sed -n '2p' "$launch_file")
  case "$launch_token" in ''|*[![:xdigit:]]) return 1 ;; esac
  worker_file="${launch_file%.launch}.worker"
  token_absent_file="${launch_file%.launch}.token.absent"
  tree_complete_file="${launch_file%.launch}.tree.complete"
  [ -f "$token_absent_file" ] || return 1
  [ -f "$tree_complete_file" ] || return 1
  worker_pid=
  if [ -f "$worker_file" ]; then
    read -r worker_pid _ < "$worker_file" || return 1
  fi
  if kill -0 "$launch_pid" 2>/dev/null \
     && fm_process_identity_matches "$launch_pid" "$launch_identity"; then
    return 1
  fi
  IFS=$'\t' read -r launch_pgid launch_sid < <(sed -n '3p' "$launch_file")
  own_pgid=$(LC_ALL=C ps -p "$$" -o pgid= 2>/dev/null || true)
  own_pgid=$(printf '%s' "$own_pgid" | tr -d '[:space:]')
  own_sid=$(LC_ALL=C ps -p "$$" -o sid= 2>/dev/null || true)
  own_sid=$(printf '%s' "$own_sid" | tr -d '[:space:]')
  pids=$(LC_ALL=C ps -e -o pid= 2>/dev/null) || return 1
  while IFS= read -r pid; do
    pid=${pid#"${pid%%[![:space:]]*}"}
    pid=${pid%"${pid##*[![:space:]]}"}
    [ -n "$pid" ] || continue
    if [ "$pid" = "$$" ] || [ "$pid" = "${BASHPID:-$$}" ] || \
       [ "$pid" = "$launch_pid" ]; then
      continue
    fi
    if [ -n "$worker_pid" ] && [ "$pid" = "$worker_pid" ]; then
      continue
    fi
    if [ -n "$launch_pgid" ] && [ "$launch_pgid" != "$own_pgid" ]; then
      current_pgid=$(LC_ALL=C ps -p "$pid" -o pgid= 2>/dev/null || true)
      current_pgid=$(printf '%s' "$current_pgid" | tr -d '[:space:]')
      [ "$current_pgid" = "$launch_pgid" ] && return 1
    fi
    if [ -n "$launch_sid" ] && [ "$launch_sid" != "$own_sid" ]; then
      current_sid=$(LC_ALL=C ps -p "$pid" -o sid= 2>/dev/null || true)
      current_sid=$(printf '%s' "$current_sid" | tr -d '[:space:]')
      [ "$current_sid" = "$launch_sid" ] && return 1
    fi
  done <<EOF
$pids
EOF
  return 0
}

# True when the process described by command name $1 and structured argv0 $3 is
# Cursor. The single owner of Cursor process identity for the ancestry walk
# (bin/fm-session-lock-lib.sh), harness detection (bin/fm-harness.sh), pane
# liveness (bin/backends/tmux.sh), and worker-server discovery (bin/fm-spawn.sh).
#
# Accepted: a process carrying Cursor's verified launch identity metadata.
#
# Rejected: a bare MainThread with no Cursor evidence; any executable whose
# basename merely happens to be `agent`; any path with an `agent/` directory
# component that is running something else.
fm_cursor_process_matches() {  # <comm> <args> [argv0] [pid]
  local comm=$1 args=${2:-} argv0=${3:-} pid=${4:-}
  [ -n "$comm" ] || [ -n "$argv0" ] || return 1
  [ -n "$pid" ] || return 1
  fm_cursor_process_has_identity "$pid" "$comm" "$args" "$argv0"
}

# --- Cursor composer raw-render normalization ---------------------------------
# Cursor renders its idle composer prompt fully de-emphasised, with the cursor
# cell wrapped in reverse video (SGR 7) between two de-emphasised runs. A raw
# ANSI capture of that row survives the generic ghost stripper with the cursor
# cell intact, which would classify the idle composer as pending. The gap is a
# Cursor RENDERER artefact, so its mechanics live here, not in the shared
# stripper: fm_cursor_composer_normalize turns a raw ANSI row into a normalized
# row with the reverse-video cursor cell removed, then the generic
# fm_composer_strip_ghost (bin/fm-composer-lib.sh) classifies the rest. The
# boundary is "raw ANSI row -> Cursor normalization -> generic ghost/composer
# classifier": no generic semantic rule (empty|pending|unknown, idle
# placeholder, busy-queued Enter) is duplicated here.
#
# The gap machine: when de-emphasis (dim/dark-truecolor) EXITS, buffer every
# following byte (SGRs and text) as a span; on de-emphasis RE-ENTRY, drop the
# span when it is reverse-video-marked (the cursor cell) and emit it otherwise
# (real typed text must survive). A bare reset (SGR 0) inside the span is a
# split-SGR relay artefact (herdr transmits ESC[0m + ESC[2m where tmux
# coalesces 0;2m) and must NOT flush the span; only a real dim/dark re-entry
# closes it. End of line always emits (no re-entry means the gap is real).
# Verified against cursor-agent 2026.07.23-e383d2b (tmux coalesced and herdr
# split forms) and pinned by tests/fm-composer-ghost.test.sh.
FM_CURSOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-composer-lib.sh
if ! declare -F fm_composer_strip_ghost >/dev/null 2>&1; then
  . "$FM_CURSOR_LIB_DIR/fm-composer-lib.sh"
fi

fm_cursor_composer_normalize() {  # raw ANSI row on stdin -> normalized ANSI row on stdout
  LC_ALL=C awk -v lumamax="${FM_COMPOSER_GHOST_LUMA_MAX:-128}" '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    function fg38_is_dark(a, p, k, lumamax,   spec, nf, f, r, g, b) {
      spec = a[p]
      if (index(spec, ":") > 0) {
        nf = split(spec, f, ":")
        if (f[2] != "2" || nf < 5) return 0
        r = f[nf - 2] + 0; g = f[nf - 1] + 0; b = f[nf] + 0
        return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
      }
      if (p + 1 > k || a[p + 1] != "2" || p + 4 > k) return 0
      r = a[p + 2] + 0; g = a[p + 3] + 0; b = a[p + 4] + 0
      return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
    }
    {
      line = $0; out = ""; dim = 0; darkfg = 0; n = length(line); i = 1
      ghost_gap = 0; gap_buf = ""; gap_rev = 0
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {
              if (params == "") params = "0"
              if (ghost_gap) {
                # Peek: is this SGR de-emphasis-changing (flushes the span) or
                # color-only (stays inside the span)? Color payloads (38;2,
                # 38;5, 48;2, 48;5, 58;2, 58;5) are skipped so a "2" inside a
                # TRUECOLOR spec is not read as a dim code. Two scans: one for
                # any de-emphasis code, one for dim/dark-38 re-entry (code "0"
                # is de-emphasis but does NOT re-enter dim; "2" may follow "0"
                # in the same params).
                is_deemph = 0; dim_reentered = 0; dark_reentered = 0
                k_check = split(params, a_check, ";")
                for (p_check = 1; p_check <= k_check; p_check++) {
                  v_check = a_check[p_check]; code_check = sgr_code(v_check)
                  if (code_check == "38" || code_check == "48" || code_check == "58") {
                    if (code_check == "38" && fg38_is_dark(a_check, p_check, k_check, lumamax)) {
                      is_deemph = 1; dark_reentered = 1; break
                    }
                    p_check = skip_color_payload(a_check, p_check, k_check)
                    continue
                  }
                  if (code_check == "2") { is_deemph = 1; break }
                  if (code_check == "0" || code_check == "22") { is_deemph = 1; break }
                  if (code_check == "39") { is_deemph = 1; break }
                  if (code_check + 0 >= 30 && code_check + 0 <= 37) { is_deemph = 1; break }
                  if (code_check + 0 >= 90 && code_check + 0 <= 97) { is_deemph = 1; break }
                }
                if (is_deemph) {
                  for (p_check = 1; p_check <= k_check; p_check++) {
                    v_check = a_check[p_check]; code_check = sgr_code(v_check)
                    if (code_check == "38" || code_check == "48" || code_check == "58") {
                      if (code_check == "38" && fg38_is_dark(a_check, p_check, k_check, lumamax)) {
                        dark_reentered = 1; break
                      }
                      p_check = skip_color_payload(a_check, p_check, k_check)
                      continue
                    }
                    if (code_check == "2") { dim_reentered = 1; break }
                  }
                  if (!(gap_rev && !dim_reentered && !dark_reentered)) {
                    ghost_gap = 0
                    if ((dim_reentered || dark_reentered) && gap_rev) {
                      gap_buf = ""   # reverse-video span is the cursor cell, drop it
                    } else {
                      out = out gap_buf   # span is real, emit it in place
                    }
                    gap_buf = ""; gap_rev = 0
                  }
                  # else: de-emphasis-END-ONLY SGR on a reverse-video span
                  # (split-SGR relay) - the span stays open untouched.
                }
              }
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38") {
                  darkfg = fg38_is_dark(a, p, k, lumamax)
                  p = skip_color_payload(a, p, k)
                } else if (code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") {
                  if (!dim) { dim = 1; ghost_gap = 0; gap_buf = ""; gap_rev = 0 }
                } else if (code == "0") {
                  if (dim || darkfg) { ghost_gap = 1; gap_buf = ""; gap_rev = 0 }
                  dim = 0; darkfg = 0
                } else if (code == "22") {
                  if (dim) { ghost_gap = 1; gap_buf = ""; gap_rev = 0 }
                  dim = 0
                } else if (code == "7") {
                  if (ghost_gap) gap_rev = 1
                } else if (code == "27") {
                  gap_rev = 0
                } else if (code == "39") { darkfg = 0 }
                else if (code + 0 >= 30 && code + 0 <= 37) { darkfg = 0 }
                else if (code + 0 >= 90 && code + 0 <= 97) { darkfg = 0 }
              }
              if (ghost_gap) {
                gap_buf = gap_buf "\033[" params "m"
              } else {
                out = out "\033[" params "m"
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue
        }
        if (ghost_gap) {
          gap_buf = gap_buf c
        } else {
          out = out c
        }
        i++
      }
      if (ghost_gap && gap_buf != "") out = out gap_buf
      print out
    }
  '
}

# fm_cursor_composer_strip: the Cursor-aware entry point callers route raw rows
# through when FM_COMPOSER_HARNESS=cursor: normalize the reverse-video cursor
# cell away, then delegate the ghost/placeholder extraction to the shared
# generic stripper.
fm_cursor_composer_strip() {  # raw ANSI row on stdin -> plain non-ghost text on stdout
  fm_cursor_composer_normalize | fm_composer_strip_ghost
}

# fm_cursor_bare_prompt_re: the effective structural bare-prompt regex for a
# composer scan under Cursor identity. Cursor's `→` prompt glyph is admitted as
# a bare composer candidate only when FM_COMPOSER_HARNESS=cursor (verified on
# herdr 2026-08-05); an unscoped arrow is a common decoration and must never be
# inferred from an idle regex alone.
fm_cursor_bare_prompt_re() {  # <base-re> -> effective regex
  if [ "${FM_COMPOSER_HARNESS:-}" = cursor ]; then
    printf '%s' "${1%)}|${FM_COMPOSER_CURSOR_PROMPT_GLYPH:-→})"
  else
    printf '%s' "$1"
  fi
}
