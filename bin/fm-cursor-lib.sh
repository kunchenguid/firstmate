#!/usr/bin/env bash
# Cursor executable resolution, Cursor process identity, and the shared
# process-identity parse. Sourced by bin/fm-spawn.sh, bin/fm-teardown.sh,
# bin/fm-harness.sh, bin/fm-session-lock-lib.sh, and bin/backends/tmux.sh.
# This file is sourced by scripts and has no side effects on source.
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
# Two independent kinds of Cursor evidence are accepted, and either alone
# carries a positive verdict, so no single vendor string is load-bearing:
#
#   Structural (no subprocess, safe during a process scan): the canonical path
#   is named cursor-agent or lives under a cursor-agent directory component.
#   Cursor's installer places both names as symlinks into
#   ~/.local/share/cursor-agent/versions/<version>/cursor-agent (verified
#   2026-08-07, cursor-agent 2026.08.04-aaa8809), so the alias resolves to
#   Cursor's own name and install tree.
#
#   Probe (a bounded `--help` run, used only when resolving an executable to
#   launch, never during a process scan): Cursor's own CLI banner and its
#   CURSOR_API_ENDPOINT / api2.cursor.sh option text. Fails closed on a
#   timeout, a non-zero exit, or missing markers - a bare zero exit is never
#   accepted as proof.
#
# Process detection deliberately uses the structural signal only. Probing an
# arbitrary pid's executable during an ancestry walk or a liveness poll would
# execute a stranger's binary, which is exactly the hazard this file exists to
# close.

# Bounded probe budget in seconds. Cursor's --help is local and returns
# immediately; the bound exists so a hung or interactive impostor cannot wedge
# a spawn or a readiness check.
FM_CURSOR_PROBE_TIMEOUT=${FM_CURSOR_PROBE_TIMEOUT:-10}

# Canonical absolute path for $1, or the input unchanged when it cannot be
# resolved. Symlink resolution is what makes the structural signal work, since
# both installed names are symlinks into Cursor's versioned install tree.
fm_cursor_canonical_path() {  # <path>
  local path=$1 dir base
  [ -n "$path" ] || return 1
  dir=$(CDPATH='' cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || { printf '%s\n' "$path"; return 0; }
  base=$(basename -- "$path")
  # Follow the symlink chain by hand: readlink -f is GNU-only and realpath is
  # not guaranteed on macOS, and this needs no new dependency.
  local hops=0 target
  while [ -L "$dir/$base" ] && [ "$hops" -lt 16 ]; do
    target=$(readlink -- "$dir/$base") || break
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

# True when path $1 carries Cursor's own structural evidence: its canonical
# name is cursor-agent, or a cursor-agent directory component appears in the
# canonical path. A directory component merely named `agent` is NEVER enough.
fm_cursor_path_is_cursor() {  # <path>
  local path=$1 canonical
  [ -n "$path" ] || return 1
  canonical=$(fm_cursor_canonical_path "$path") || return 1
  case "${canonical##*/}" in cursor-agent) return 0 ;; esac
  case "/$canonical/" in */cursor-agent/*) return 0 ;; esac
  return 1
}

# True when running `$1 --help` produces Cursor's own CLI identity. Bounded and
# fail-closed: a timeout, a non-zero exit, or output without a Cursor-specific
# marker is a refusal. Never called during a process scan.
fm_cursor_probe_is_cursor() {  # <path>
  local path=$1 out runner=
  [ -n "$path" ] && [ -x "$path" ] || return 1
  if command -v timeout >/dev/null 2>&1; then runner=timeout
  elif command -v gtimeout >/dev/null 2>&1; then runner=gtimeout
  fi
  if [ -n "$runner" ]; then
    out=$("$runner" "$FM_CURSOR_PROBE_TIMEOUT" "$path" --help 2>/dev/null) || return 1
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  case "$out" in
    *"Start the Cursor Agent"*) return 0 ;;
    *CURSOR_API_ENDPOINT*) return 0 ;;
    *api2.cursor.sh*) return 0 ;;
  esac
  return 1
}

# True when executable $1 may be launched as Cursor.
#
# An executable whose own name is cursor-agent is accepted on the ordinary
# executable check: the name is Cursor's and is specific enough to stand alone.
# Anything else - which in practice means the legacy `agent` alias - must first
# prove itself Cursor, structurally or by the bounded probe.
fm_cursor_verify_executable() {  # <path>
  local path=$1
  [ -n "$path" ] && [ -x "$path" ] || return 1
  case "${path##*/}" in cursor-agent) return 0 ;; esac
  fm_cursor_path_is_cursor "$path" && return 0
  fm_cursor_probe_is_cursor "$path"
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
    if fm_cursor_verify_executable "$candidate"; then
      printf '%s\n' "$(fm_cursor_canonical_path "$candidate")"
      return 0
    fi
  done
  echo "error: no verified cursor executable found; searched PATH for 'cursor-agent' and 'agent', plus '${HOME:-}/.local/bin/cursor-agent' and '${HOME:-}/.local/bin/agent'. A file named 'agent' is accepted only when it resolves into Cursor's install tree or its --help identifies the Cursor Agent CLI." >&2
  return 1
}

# True when the full argument string $1 carries structural Cursor evidence.
# Used by every process-scanning caller, so it never executes anything.
#
# Cursor's Node bundle runs with kernel comm MainThread and an argument string
# whose argv0 still names the versioned cursor-agent install path, which is the
# first and cheapest signal. Structural evidence comes only from argv0: a later
# argument path/token named cursor-agent must never classify an unrelated
# process as Cursor. When argv0 carries no cursor-agent token, it is resolved
# on disk instead, which is what proves a legacy `agent` alias without trusting
# its name.
fm_cursor_args_are_cursor() {  # <args>
  local args=$1 argv0
  [ -n "$args" ] || return 1
  argv0=${args%% *}
  case "$argv0" in
    ''|MainThread) return 1 ;;
    cursor-agent) return 0 ;;
  esac
  fm_cursor_path_is_cursor "$argv0"
}

# True when the process described by command name $1 and full argument string
# $2 is Cursor. The single owner of Cursor process identity for the ancestry
# walk (bin/fm-session-lock-lib.sh), harness detection (bin/fm-harness.sh),
# pane liveness (bin/backends/tmux.sh), and worker-server discovery
# (bin/fm-spawn.sh).
#
# Accepted: an exact cursor-agent command name; a MainThread or bare
# interpreter whose arguments carry Cursor's install path; a legacy `agent`
# whose argv[0] resolves into Cursor's install tree.
#
# Rejected: a bare MainThread with no Cursor evidence; any executable whose
# basename merely happens to be `agent`; any path with an `agent/` directory
# component that is running something else.
fm_cursor_process_matches() {  # <comm> <args>
  local comm=$1 args=${2:-} base
  base=$(basename -- "$comm")
  base=${base#-}
  case "$base" in
    cursor-agent) return 0 ;;
    agent|MainThread|node|node-*|node[0-9]*|python|python[0-9]*|python[0-9].[0-9]*)
      fm_cursor_args_are_cursor "$args" && return 0
      # A legacy alias may also be reported by its own path in comm.
      fm_cursor_path_is_cursor "$comm" && return 0
      return 1
      ;;
  esac
  # A version-named or otherwise renamed executable still identifies through
  # its install path.
  case "$comm" in */*) fm_cursor_path_is_cursor "$comm" && return 0 ;; esac
  return 1
}

# The process identity recorded at spawn and re-checked at teardown, so a
# recycled pid is never mistaken for the process that was recorded.
#
# Linux /proc/<pid>/stat is authoritative when readable. The parse must strip
# through the FINAL `)` before splitting, because field 2 is the parenthesized
# comm and a comm containing spaces (or parentheses) shifts every positional
# field after it - reading `$22` from the raw line records the wrong number and
# silently breaks the recycled-pid check. `starttime` is field 22 overall,
# which is index 19 of the remainder after the comm.
#
# `ps -o lstart=` is the portable fallback for platforms without /proc. Both
# forms are self-describing, so a recorded value always states which it is.
fm_process_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

fm_process_identity_matches() {  # <pid> <identity>
  local current
  current=$(fm_process_identity "$1") || return 1
  [ "$current" = "$2" ]
}
