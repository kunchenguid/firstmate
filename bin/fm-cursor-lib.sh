#!/usr/bin/env bash
# Cursor executable resolution and Cursor process identity.
# Sourced by bin/fm-spawn.sh, bin/fm-harness.sh, bin/fm-busy-lib.sh, and
# bin/backends/tmux.sh. This file is sourced by scripts and has no side effects
# on source.
#
# Why one owner: cursor ships TWO executable names - `cursor-agent`, plus the
# legacy alias `agent` it installs on every platform. `agent` is far too
# generic to trust on its name alone, so every spawn, ancestry, and liveness
# caller has to agree on the same narrowed rule or an unrelated `/opt/agent`,
# an unrelated `agent` on PATH, or a path that merely contains an `agent/`
# directory component silently classifies as this harness. That widening would
# let firstmate launch an unrelated executable with Cursor flags.
#
# Two independent kinds of Cursor evidence are accepted, and either alone
# carries a positive verdict, so no single vendor string is load-bearing:
#
#   Structural (no subprocess, safe during a process scan): the canonical path
#   is named cursor-agent or lives under Cursor's versioned install tree.
#   Cursor's installer places both names as symlinks into
#   ~/.local/share/cursor-agent/versions/<version>/cursor-agent (verified
#   2026-08-11, cursor-agent 2026.08.11-e8db854), so the alias resolves to
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
#
# Cursor's composer shape is deliberately NOT here. Its reverse-video
# placeholder remnant is taught to the ONE fleet-wide screen classifier in
# bin/fm-composer-lib.sh, which every backend already delegates to; an
# adapter-local composer normalizer would be the second copy that owner exists
# to prevent.

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
# name is cursor-agent, or it is inside Cursor's
# cursor-agent/versions/<version>/ install tree. A directory component merely
# named `agent` or `cursor-agent` is NEVER enough.
fm_cursor_path_is_cursor() {  # <path>
  local path=$1 canonical
  [ -n "$path" ] || return 1
  canonical=$(fm_cursor_canonical_path "$path") || return 1
  case "${canonical##*/}" in cursor-agent) return 0 ;; esac
  case "$canonical" in */cursor-agent/versions/*/*) return 0 ;; esac
  return 1
}

# True when running `$1 --help` produces Cursor's own CLI identity. Bounded and
# fail-closed: a timeout, a non-zero exit, or output without a Cursor-specific
# marker is a refusal. Never called during a process scan.
fm_cursor_bounded_output() {  # <path> <args...>
  local path=$1 runner=
  shift
  [ -n "$path" ] && [ -x "$path" ] || return 1
  if command -v timeout >/dev/null 2>&1; then runner=timeout
  elif command -v gtimeout >/dev/null 2>&1; then runner=gtimeout
  fi
  [ -n "$runner" ] || return 1
  "$runner" "$FM_CURSOR_PROBE_TIMEOUT" "$path" "$@" 2>/dev/null
}

fm_cursor_probe_is_cursor() {  # <path>
  local path=$1 out
  out=$(fm_cursor_bounded_output "$path" --help) || return 1
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

fm_cursor_list_models() {  # <path>
  fm_cursor_bounded_output "$1" --list-models
}

fm_cursor_catalog_has_model() {  # <model>
  local wanted=$1
  awk -v wanted="$wanted" '
    BEGIN { ansi = sprintf("%c\\[[0-9;]*[A-Za-z]", 27) }
    {
      line = $0
      gsub(ansi, "", line)
      separator = index(line, " - ")
      if (!separator) next
      id = substr(line, 1, separator - 1)
      sub(/^[[:space:]]+/, "", id)
      sub(/[[:space:]]+$/, "", id)
      if (id == wanted) found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

# Print the stable absolute launcher path for the Cursor executable, or return 1
# with a diagnostic on stderr.
#
# Resolution order, shared by bin/fm-spawn.sh and bin/fm-remote-doctor.sh:
# cursor-agent on PATH, `agent` on PATH, then the ~/.local/bin installs of
# both. cursor-agent is preferred over the alias at every stage. The
# ~/.local/bin fallbacks exist because Cursor's user-local install is routinely
# absent from a non-interactive login PATH. Every `agent` candidate passes
# fm_cursor_verify_executable before it is accepted, so an unrelated executable
# named agent is rejected rather than launched with Cursor's flags.
#
# The STABLE path is printed, not the canonical one. Identity is proven THROUGH
# canonicalization (that is what makes the `agent` alias safe), but cursor's
# installer points both stable names at
# ~/.local/share/cursor-agent/versions/<version>/cursor-agent, so the canonical
# path carries a version that the CLI replaces on its own auto-update. Printing
# the stable launcher keeps a recorded launch command valid across an upgrade;
# printing the canonical one would pin a task to a version that can vanish.
fm_cursor_resolve_binary() {
  local name candidate
  for name in cursor-agent agent; do
    candidate=$(command -v "$name" 2>/dev/null || true)
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
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
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "error: no verified cursor executable found; searched PATH for 'cursor-agent' and 'agent', plus '${HOME:-}/.local/bin/cursor-agent' and '${HOME:-}/.local/bin/agent'. A file named 'agent' is accepted only when it resolves into Cursor's install tree or its --help identifies the Cursor Agent CLI." >&2
  return 1
}

# Read argv[0] without flattening it into a whitespace-delimited command line.
fm_cursor_argv0_for_pid() {  # <pid> [comm-fallback]
  local pid=$1 fallback=${2:-} proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} argv0=
  if [ -r "$proc_root/$pid/cmdline" ]; then
    IFS= read -r -d '' argv0 < "$proc_root/$pid/cmdline" || true
    [ -n "$argv0" ] && { printf '%s\n' "$argv0"; return 0; }
  fi
  if [ -z "$fallback" ]; then
    fallback=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null || true)
  fi
  [ -n "$fallback" ] || return 1
  printf '%s\n' "$fallback"
}

fm_cursor_argv0_is_cursor() {  # <argv0>
  local argv0=$1
  [ -n "$argv0" ] || return 1
  case "$argv0" in
    ''|MainThread) return 1 ;;
    cursor-agent) return 0 ;;
  esac
  fm_cursor_path_is_cursor "$argv0"
}

# True when the process described by command name $1 and structured argv0 $3 is
# Cursor. The single owner of Cursor process identity for the ancestry walk
# (bin/fm-session-lock-lib.sh), harness detection (bin/fm-harness.sh), pane
# liveness (bin/backends/tmux.sh), and worker-server discovery (bin/fm-spawn.sh).
#
# Accepted: an exact cursor-agent command name; a MainThread or bare
# interpreter whose structured argv[0] carries Cursor's install path; a legacy
# `agent` whose argv[0] resolves into Cursor's install tree.
#
# Rejected: a bare MainThread with no Cursor evidence; any executable whose
# basename merely happens to be `agent`; any path with an `agent/` directory
# component that is running something else.
fm_cursor_process_matches() {  # <comm> <args> [argv0]
  local comm=$1 argv0=${3:-} base
  [ -n "$comm" ] || [ -n "$argv0" ] || return 1
  argv0=${argv0:-$comm}
  base=$(basename -- "$comm")
  base=${base#-}
  case "$base" in
    cursor-agent) return 0 ;;
    agent|MainThread|node|node-*|node[0-9]*|python|python[0-9]*|python[0-9].[0-9]*)
      fm_cursor_argv0_is_cursor "$argv0" && return 0
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

