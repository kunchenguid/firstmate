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
. "$FM_CURSOR_LIB_DIR/fm-composer-lib.sh"

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
