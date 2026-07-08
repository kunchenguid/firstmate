#!/usr/bin/env bash
# fm-backend.sh - runtime-backend selection, meta helpers, selector resolution,
# and dispatch for firstmate's session-provider abstraction.
#
# Design: data/fm-backend-design-d7/report.md ("Backend Interface") and
# data/fm-backend-design-d7/herdr-addendum.md ("Events as the core
# abstraction"). P1 extracted the tmux command sequences that fm-send.sh,
# fm-peek.sh, fm-watch.sh, fm-spawn.sh, and fm-teardown.sh already ran inline
# into bin/backends/tmux.sh, with those SAME command sequences, so the default
# (tmux) path stays byte-identical. P2 adds bin/backends/herdr.sh, an
# EXPERIMENTAL spawn-capable backend behind `--backend herdr`/`FM_BACKEND=herdr`/
# `config/backend`, and behind runtime auto-detection when firstmate itself is
# running inside herdr with no explicit backend setting; see herdr-addendum.md and
# data/fm-backend-design-d7/herdr-verification-p2.md for its empirical basis.
# P3 adds bin/backends/zellij.sh, also EXPERIMENTAL and spawn-capable, behind
# `--backend zellij`/`FM_BACKEND=zellij`/`config/backend` - NOT behind runtime
# auto-detection (report.md's Open Question #2: start with a dedicated
# background session for predictability, unlike tmux's/herdr's ambient-session
# reuse); see report.md's "Zellij Backend" section and docs/zellij-backend.md
# for its empirical basis. P4 makes Orca spawn-capable: Orca owns both the
# task worktree and the terminal endpoint. P5 adds bin/backends/cmux.sh, also
# EXPERIMENTAL and spawn-capable, behind `--backend cmux`/`FM_BACKEND=cmux`/
# `config/backend`, and behind runtime auto-detection when firstmate itself is
# running inside a cmux-spawned terminal (primary CMUX_WORKSPACE_ID marker, or
# the documented macOS fallback signals when cmux's claude wrapper strips that
# marker) with no explicit backend setting - unlike Orca, which stays
# never-auto-detected because it also owns the task worktree; see
# docs/cmux-backend.md for its empirical basis.
# Codex App is intentionally not in the known set yet.
# docs/codex-app-backend.md owns that blocked backend contract.
#
# Compatibility contract: a task's meta may omit `backend=`; every reader here
# treats that as `tmux` (fm_backend_of_meta), and fm-spawn.sh does not write
# `backend=tmux` for a default-backend task, so existing and newly spawned
# default-path metas stay byte-identical. Only a task spawned on a non-tmux
# spawn-capable backend, currently experimental herdr, zellij, orca, or cmux,
# carries an explicit `backend=` line.
#
# Event-source framing (herdr-addendum "Events as the core abstraction"): a
# backend's supervision surface is conceptually an EVENT SOURCE - it produces
# task events (status-changed, went-stale, exited) that map onto firstmate's
# existing signal/stale/check/heartbeat wake vocabulary. The tmux adapter has
# no native event push, so fm-watch.sh's poll loop over the pull primitives
# below (capture, list-live, busy-state via regex) IS the default event-source
# implementation that synthesizes those events; P1 only names that seam, it
# does not change the loop's behavior. The pull primitives also stay available
# on their own for on-demand reads (fm-peek.sh, fm-crew-state.sh).

FM_BACKEND_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_BACKEND_LIB_DIR="$(cd "$(dirname "$FM_BACKEND_SCRIPT")" && pwd)"
unset FM_BACKEND_SCRIPT
FM_BACKEND_DEFAULT_ROOT="$(cd "$FM_BACKEND_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKEND_CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# Verified backend adapters. Extend only after a backend gets its own
# bin/backends/<name>.sh and empirical verification, mirroring AGENTS.md
# section 4's harness-verification discipline. herdr is EXPERIMENTAL (P2;
# data/fm-backend-design-d7/herdr-addendum.md) - verified against the real
# v0.7.1/protocol-14 binary (data/fm-backend-design-d7/herdr-verification-p2.md)
# but newer than tmux's long-proven default path. zellij is EXPERIMENTAL (P3;
# data/fm-backend-design-d7/report.md "Zellij Backend") - verified against the
# real 0.44.0 binary (docs/zellij-backend.md). orca is EXPERIMENTAL and
# spawn-capable; unlike tmux/herdr/zellij it is also the worktree provider.
# cmux is EXPERIMENTAL and spawn-capable, session-provider-only like
# herdr/zellij - verified against the real 0.64.17 binary (docs/cmux-backend.md).
# codex-app remains deliberately absent; see docs/codex-app-backend.md.
FM_BACKEND_KNOWN="tmux herdr zellij orca cmux"
FM_BACKEND_SPAWN="tmux herdr zellij orca cmux"

# fm_backend_list_contains: whitespace-delimited membership without relying on
# shell word splitting. fm-backend.sh is normally sourced by bash scripts, but
# zsh diagnostics can source it too, so backend-name matching must stay portable.
fm_backend_list_contains() {  # <list> <name>
  local list=$1 name=$2
  case "$name" in
    *[[:space:]]*) return 1 ;;
  esac
  case " $list " in
    *" $name "*) return 0 ;;
  esac
  return 1
}

fm_backend_is_known() {  # <name>
  fm_backend_list_contains "$FM_BACKEND_KNOWN" "$1"
}

# fm_backend_detect: detect the runtime firstmate itself is CURRENTLY executing
# inside, from verified environment markers (mirrors bin/fm-harness.sh's
# env-marker detection layer for harnesses). Prints the detected backend name
# and returns 0, or returns 1 when nothing is detected. Nesting resolves
# INNERMOST-first: tmux sets $TMUX in every process running inside it, even a
# tmux started inside a herdr pane, so $TMUX is checked first and wins over
# HERDR_ENV=1 in that nested case. herdr injects HERDR_ENV=1 (plus
# HERDR_SOCKET_PATH/HERDR_PANE_ID) into every process it manages a pane for;
# HERDR_ENV=1 alone (no $TMUX) selects herdr. cmux injects CMUX_WORKSPACE_ID
# (plus CMUX_SURFACE_ID/CMUX_SOCKET_PATH and the legacy CMUX_TAB_ID/
# CMUX_PANEL_ID aliases) into every terminal surface it spawns - verified from
# the shipped source (`TerminalSurface+StartupEnvironment.swift`'s
# `applyManagedCmuxContextEnvironment`, which marks all five keys
# `protectedKeys`, i.e. non-overridable) and corroborated by cmux's own CLI
# (`cmux_open.swift`) reading `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` as its own
# ambient-target fallback, exactly how `$TMUX` and `HERDR_ENV` work for their
# backends. CMUX_WORKSPACE_ID, not CMUX_SOCKET_PATH, is the chosen marker:
# CMUX_SOCKET_PATH is independently documented as a user-settable override for
# pointing the CLI at a non-default socket, so its mere presence would not
# reliably mean "running inside a cmux-spawned terminal" the way
# CMUX_WORKSPACE_ID does. cmux is checked LAST because it is a terminal
# application (the outermost layer, like iTerm2/Terminal.app), not a session
# multiplexer - both tmux and herdr can run nested inside a cmux-provided
# shell, but cmux cannot run nested inside either of them, so a tmux or herdr
# marker set alongside CMUX_WORKSPACE_ID always means that multiplexer is the
# innermost, currently-executing layer and must win.
#
# cmux FALLBACK signals (docs/cmux-backend.md "Runtime auto-detection" owns
# the empirical record): cmux's bundled `claude` PATH shim routes through
# cmux-claude-wrapper, whose passthrough path unsets every CMUX_* variable
# before exec'ing the real binary - so a claude-harness firstmate launched in
# a cmux tab can have NO CMUX_WORKSPACE_ID at all. When that primary marker is
# absent (and only then), two macOS-only fallback signals are consulted:
#   1. __CFBundleIdentifier == com.cmuxterm.app - LaunchServices' app-identity
#      env var, inherited by every process a cmux tab spawns and NOT stripped
#      by the wrapper (it only unsets CMUX_*, TERMINFO, and CLAUDECODE).
#      Authoritative in the common wrapper-strip case, but also inherited into
#      every pane of a tmux server started from a cmux tab - the $TMUX check
#      winning FIRST is what keeps that false positive absorbed.
#   2. Process ancestry reaching the running cmux app (resolved by bundle id
#      via lsappinfo, plus a bundle-shaped `ps` comm match so the install
#      location is never hardcoded). Authoritative when the environment was
#      scrubbed entirely (no bundle id to inherit); NOT usable from inside
#      tmux, where the tmux server reparents to launchd and the chain never
#      reaches cmux - which is fine, because $TMUX already won there.
# Callers needing the winning signal read FM_BACKEND_DETECT_SIGNAL (set to
# TMUX, HERDR_ENV, CMUX_WORKSPACE_ID, bundle-id, or ancestry) and
# FM_BACKEND_DETECTED after a direct (non-command-substitution) call.
FM_BACKEND_CMUX_BUNDLE_ID="com.cmuxterm.app"

fm_backend_detect() {
  FM_BACKEND_DETECTED=""
  FM_BACKEND_DETECT_SIGNAL=""
  if [ -n "${TMUX:-}" ]; then
    FM_BACKEND_DETECTED=tmux
    FM_BACKEND_DETECT_SIGNAL=TMUX
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ]; then
    FM_BACKEND_DETECTED=herdr
    FM_BACKEND_DETECT_SIGNAL=HERDR_ENV
    printf 'herdr'
    return 0
  fi
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    FM_BACKEND_DETECTED=cmux
    FM_BACKEND_DETECT_SIGNAL=CMUX_WORKSPACE_ID
    printf 'cmux'
    return 0
  fi
  if fm_backend_detect_cmux_fallback; then
    FM_BACKEND_DETECTED=cmux
    printf 'cmux'
    return 0
  fi
  return 1
}

# fm_backend_detect_cmux_fallback: the two macOS-only cmux fallback signals
# (see fm_backend_detect's header comment). Sets FM_BACKEND_DETECT_SIGNAL to
# bundle-id or ancestry on success. Cheap-first: the bundle-id check is a pure
# env read; the ancestry walk (subprocess-per-hop) runs only when it misses.
fm_backend_detect_cmux_fallback() {
  [ "$(uname 2>/dev/null)" = Darwin ] || return 1
  if [ "${__CFBundleIdentifier:-}" = "$FM_BACKEND_CMUX_BUNDLE_ID" ]; then
    FM_BACKEND_DETECT_SIGNAL=bundle-id
    return 0
  fi
  if fm_backend_detect_cmux_app_is_ancestor; then
    FM_BACKEND_DETECT_SIGNAL=ancestry
    return 0
  fi
  return 1
}

# fm_backend_detect_cmux_app_pid: the running cmux app's pid, resolved by
# bundle id via lsappinfo (`"pid"=<n>`), or failure when lsappinfo is missing,
# errors, or the app is not running (lsappinfo prints nothing, exit 0).
fm_backend_detect_cmux_app_pid() {
  command -v lsappinfo >/dev/null 2>&1 || return 1
  local out pid
  out=$(lsappinfo info -only pid -app "$FM_BACKEND_CMUX_BUNDLE_ID" 2>/dev/null) || return 1
  pid=${out##*=}
  pid=$(printf '%s' "$pid" | tr -d '[:space:]"')
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$pid"
}

# fm_backend_detect_cmux_app_is_ancestor: walk this process's parent chain and
# report whether it reaches the cmux app - matching either the lsappinfo-
# resolved pid (bundle id, no path assumption) or a bundle-shaped comm path
# (`*/cmux.app/Contents/MacOS/cmux`, any install location) when lsappinfo
# could not resolve one. Stops at launchd (ppid 1), where a tmux server that
# was started from a cmux tab has already reparented - ancestry can never
# false-positive from inside tmux.
fm_backend_detect_cmux_app_is_ancestor() {
  local cmux_pid pid ppid comm hops=0
  cmux_pid=$(fm_backend_detect_cmux_app_pid) || cmux_pid=""
  pid=$$
  while [ "$hops" -lt 32 ]; do
    if [ -n "$cmux_pid" ] && [ "$pid" = "$cmux_pid" ]; then
      return 0
    fi
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || comm=""
    comm="${comm#"${comm%%[![:space:]]*}"}"
    comm="${comm%"${comm##*[![:space:]]}"}"
    [ -n "$comm" ] || return 1
    case "$comm" in
      */cmux.app/Contents/MacOS/cmux) return 0 ;;
    esac
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$ppid" -gt 1 ] || return 1
    pid=$ppid
    hops=$((hops + 1))
  done
  return 1
}

# fm_backend_name: resolve the ACTIVE backend for a NEW spawn, absent an
# explicit per-task override. Precedence: FM_BACKEND env, then config/backend
# (a single word on its first non-empty line, mirroring config/crew-harness),
# then runtime auto-detection (fm_backend_detect), then default tmux. A
# per-task `--backend` flag is parsed by the caller (fm-spawn.sh) and takes
# precedence over this resolution entirely; it is not read here. Auto-detect
# fires only when nothing was explicitly configured, so an explicit setting
# always wins. Selecting herdr or cmux via auto-detect prints one loud stderr
# notice (both are experimental); auto-detecting tmux stays silent - it is
# today's default-path behavior and callers must see zero change. The cmux
# notice names the winning signal, so a fallback-detected cmux (bundle id or
# ancestry, after the claude wrapper stripped CMUX_WORKSPACE_ID) is visibly
# distinct from the primary-marker case.
fm_backend_name() {
  local line v detected marker
  if [ -n "${FM_BACKEND:-}" ]; then
    printf '%s' "$FM_BACKEND"
    return 0
  fi
  if [ -f "$FM_BACKEND_CONFIG_DIR/backend" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      v=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$v" ]; then
        printf '%s' "$v"
        return 0
      fi
    done < "$FM_BACKEND_CONFIG_DIR/backend"
  fi
  # Called directly (not in a command substitution) so the detect signal
  # globals survive into the notice below.
  if fm_backend_detect >/dev/null; then
    detected=$FM_BACKEND_DETECTED
    if [ "$detected" = herdr ]; then
      echo "NOTICE: auto-detected herdr runtime (HERDR_ENV=1) - spawning into the EXPERIMENTAL herdr backend. Set config/backend or pass --backend tmux to opt out." >&2
    fi
    if [ "$detected" = cmux ]; then
      case "$FM_BACKEND_DETECT_SIGNAL" in
        bundle-id) marker="FALLBACK signal __CFBundleIdentifier=$FM_BACKEND_CMUX_BUNDLE_ID; CMUX_WORKSPACE_ID absent, stripped by cmux's bundled claude wrapper" ;;
        ancestry) marker="FALLBACK signal process-ancestry reaching the running cmux app; CMUX_WORKSPACE_ID absent, stripped by cmux's bundled claude wrapper" ;;
        *) marker="CMUX_WORKSPACE_ID" ;;
      esac
      echo "NOTICE: auto-detected cmux runtime ($marker) - spawning into the EXPERIMENTAL cmux backend. Set config/backend or pass --backend tmux to opt out." >&2
    fi
    printf '%s' "$detected"
    return 0
  fi
  printf 'tmux'
}

# fm_backend_validate: refuse an unknown backend LOUDLY. Silent on success.
fm_backend_validate() {  # <name>
  local name=$1
  if ! fm_backend_is_known "$name"; then
    echo "error: unknown backend '$name' (known: $FM_BACKEND_KNOWN)" >&2
    return 1
  fi
  return 0
}

fm_backend_validate_spawn() {  # <name>
  local name=$1
  fm_backend_validate "$name" || return 1
  fm_backend_list_contains "$FM_BACKEND_SPAWN" "$name" && return 0
  echo "error: backend '$name' does not support task spawning yet (spawn-supported: $FM_BACKEND_SPAWN)" >&2
  return 1
}

# fm_meta_get: the LAST value of `key=` in <meta-file>, or empty (never
# errors) if the file or key is absent. Mirrors the ad hoc `grep '^key=' |
# tail -1 | cut -d= -f2-` snippet every fm-*.sh script used to repeat inline.
fm_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# fm_backend_of_meta: the backend recorded in <meta-file>, defaulting to
# `tmux` when the field is absent - the P1 compatibility contract.
fm_backend_of_meta() {  # <meta-file>
  local v
  v=$(fm_meta_get "$1" backend)
  printf '%s' "${v:-tmux}"
}

fm_backend_target_of_meta() {  # <meta-file>
  local meta=$1 backend terminal window
  backend=$(fm_backend_of_meta "$meta")
  if [ "$backend" = orca ]; then
    terminal=$(fm_meta_get "$meta" terminal)
    [ -n "$terminal" ] && { printf '%s' "$terminal"; return 0; }
  fi
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] && printf '%s' "$window"
}

fm_backend_meta_for_window() {  # <target> <state-dir>
  local target=$1 state=$2 meta window terminal
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    window=$(fm_meta_get "$meta" window)
    terminal=$(fm_meta_get "$meta" terminal)
    { [ -n "$window" ] && [ "$window" = "$target" ]; } || { [ -n "$terminal" ] && [ "$terminal" = "$target" ]; } || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_backend_of_selector() {  # <raw-target> <resolved-target> <state-dir>
  local raw=$1 resolved=$2 state=$3 meta
  case "$raw" in
    fm-*)
      meta="$state/${raw#fm-}.meta"
      [ -f "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
      ;;
  esac
  if [ -n "$resolved" ]; then
    meta=$(fm_backend_meta_for_window "$resolved" "$state" 2>/dev/null || true)
    [ -n "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
  fi
  printf 'tmux'
}

fm_backend_expected_label_of_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 meta
  case "$raw" in
    fm-*)
      meta="$state/${raw#fm-}.meta"
      [ -f "$meta" ] && printf '%s' "$raw"
      ;;
  esac
}

# fm_backend_source: source the named backend's adapter file, once per shell.
fm_backend_source() {  # <name>
  local name=$1
  fm_backend_validate "$name" || return 1
  case "$name" in
    tmux)
      if [ -z "${_FM_BACKEND_TMUX_SOURCED:-}" ]; then
        # shellcheck source=bin/backends/tmux.sh
        . "$FM_BACKEND_LIB_DIR/backends/tmux.sh" || return 1
        _FM_BACKEND_TMUX_SOURCED=1
      fi
      ;;
    herdr)
      if [ -z "${_FM_BACKEND_HERDR_SOURCED:-}" ]; then
        # shellcheck source=bin/backends/herdr.sh
        . "$FM_BACKEND_LIB_DIR/backends/herdr.sh" || return 1
        _FM_BACKEND_HERDR_SOURCED=1
      fi
      ;;
    zellij)
      if [ -z "${_FM_BACKEND_ZELLIJ_SOURCED:-}" ]; then
        # shellcheck source=bin/backends/zellij.sh
        . "$FM_BACKEND_LIB_DIR/backends/zellij.sh" || return 1
        _FM_BACKEND_ZELLIJ_SOURCED=1
      fi
      ;;
    orca)
      if [ -z "${_FM_BACKEND_ORCA_SOURCED:-}" ]; then
        # shellcheck source=bin/backends/orca.sh
        . "$FM_BACKEND_LIB_DIR/backends/orca.sh" || return 1
        _FM_BACKEND_ORCA_SOURCED=1
      fi
      ;;
    cmux)
      if [ -z "${_FM_BACKEND_CMUX_SOURCED:-}" ]; then
        # shellcheck source=bin/backends/cmux.sh
        . "$FM_BACKEND_LIB_DIR/backends/cmux.sh" || return 1
        _FM_BACKEND_CMUX_SOURCED=1
      fi
      ;;
  esac
}

# fm_backend_resolve_selector: resolve a raw fm-send.sh/fm-peek.sh style
# selector to a live session-provider target. Three forms, in order:
#   target with ":"   used as-is (the escape hatch for a window/pane outside
#                      this firstmate home) - backend-independent, a literal string.
#   "fm-<id>"          routed through <state-dir>/<id>.meta's backend target
#                      (`window=` normally, `terminal=` for Orca) -
#                      backend-independent, a stored value, NOT re-verified
#                      against a live backend inventory (matches today's
#                      behavior: tmux window names can be trusted from meta
#                      without a live re-check).
#   anything else      first matched against recorded `window=`/`terminal=`
#                      metadata, then treated as an ad hoc bare window name and
#                      resolved by searching the legacy tmux live inventory.
fm_backend_resolve_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 meta window
  case "$raw" in
    *:*)
      printf '%s' "$raw"
      return 0
      ;;
    fm-*)
      meta="$state/${raw#fm-}.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $raw in $state; pass session:window to target a window outside this firstmate home" >&2
        return 1
      fi
      window=$(fm_backend_target_of_meta "$meta")
      [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
      printf '%s' "$window"
      return 0
      ;;
    *)
      meta=$(fm_backend_meta_for_window "$raw" "$state" 2>/dev/null || true)
      if [ -n "$meta" ]; then
        window=$(fm_backend_target_of_meta "$meta")
        [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
        printf '%s' "$window"
        return 0
      fi
      fm_backend_source tmux || return 1
      fm_backend_tmux_resolve_bare_selector "$raw"
      ;;
  esac
}

# --- generic per-op dispatch -------------------------------------------------
#
# Thin case-dispatch wrappers so a caller names an operation and a backend
# rather than hand-writing `case "$backend" in tmux) fm_backend_tmux_x ;; esac`
# at every call site. Each verified backend adds its own arm here, without
# changing call sites.

# fm_backend_capture: bounded plain-text session capture.
fm_backend_capture() {  # <backend> <target> <lines> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_capture "$@" ;;
    herdr) fm_backend_herdr_capture "$@" ;;
    zellij) fm_backend_zellij_capture "$@" ;;
    orca) fm_backend_orca_capture "$@" ;;
    cmux) fm_backend_cmux_capture "$@" ;;
    *) echo "error: no capture implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_send_key: one backend-supported named special key.
fm_backend_send_key() {  # <backend> <target> <key> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_send_key "$@" ;;
    herdr) fm_backend_herdr_send_key "$@" ;;
    zellij) fm_backend_zellij_send_key "$@" ;;
    orca) fm_backend_orca_send_key "$@" ;;
    cmux) fm_backend_cmux_send_key "$@" ;;
    *) echo "error: no send-key implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_send_text_submit: type text once, then submit and verify,
# retrying only the submission (never retyping). Echoes the verdict
# (empty|pending|unknown|send-failed for submit-verifying adapters).
fm_backend_send_text_submit() {  # <backend> <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_send_text_submit "$@" ;;
    herdr) fm_backend_herdr_send_text_submit "$@" ;;
    zellij) fm_backend_zellij_send_text_submit "$@" ;;
    orca) fm_backend_orca_send_text_submit "$@" ;;
    cmux) fm_backend_cmux_send_text_submit "$@" ;;
    *) echo "error: no send-text implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_kill: remove the task's session endpoint (best-effort; a
# nonexistent/already-gone target is not an error - callers already swallow
# failures here exactly as the inline `tmux kill-window ... || true` did).
fm_backend_kill() {  # <backend> <target>
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_kill "$@" ;;
    herdr) fm_backend_herdr_kill "$@" ;;
    zellij) fm_backend_zellij_kill "$@" ;;
    orca) fm_backend_orca_kill "$@" ;;
    cmux) fm_backend_cmux_kill "$@" ;;
    *) echo "error: no kill implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_remove_worktree() {  # <backend> <worktree-id>
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    orca) fm_backend_orca_remove_worktree "$@" ;;
    *) echo "error: backend '$backend' does not own task worktrees" >&2; return 1 ;;
  esac
}

fm_backend_worktree_path() {  # <backend> <worktree-id>
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    orca) fm_backend_orca_worktree_path "$@" ;;
    *) echo "error: backend '$backend' does not own task worktrees" >&2; return 1 ;;
  esac
}

# fm_backend_busy_state: semantic busy/idle/unknown for backends that expose
# native agent-state (herdr-addendum "busy state" row - the first backend
# where this gets real semantics beyond pane-regex). Backends with no such
# primitive (tmux) report unknown. Callers own the fallback policy: fm-watch.sh
# uses unknown as the cue for its pane-hash + FM_BUSY_REGEX detection, while
# fm-crew-state.sh also corroborates native idle verdicts before treating a
# no-run crew as not busy.
fm_backend_busy_state() {  # <backend> <target>
  local backend=$1
  shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    herdr) fm_backend_herdr_busy_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_composer_state: classify the composer/input row of <target> as
# empty|pending|unknown for callers that need a pre-submit pending-input guard
# or an adapter's conservative submit fallback. It is exposed generically so a
# caller other than the send path (the away-mode daemon's supervisor-pane
# pending-input guard, bin/fm-supervise-daemon.sh) can ask the same question
# without duplicating per-backend composer-reading logic. tmux and herdr both
# expose a named classifier already (fm_tmux_composer_state,
# fm_backend_herdr_composer_state), as do orca and cmux
# (fm_backend_orca_composer_state, fm_backend_cmux_composer_state); zellij's
# submit path uses an internal content-diff approach with no separately named
# classifier, so it reports unknown here - callers fall back to their own
# policy, exactly as an unknown fm_backend_busy_state already does.
fm_backend_composer_state() {  # <backend> <target> -> empty|pending|unknown
  local backend=$1
  shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    tmux) fm_tmux_composer_state "$@" ;;
    herdr) fm_backend_herdr_composer_state "$@" ;;
    orca) fm_backend_orca_composer_state "$@" ;;
    cmux) fm_backend_cmux_composer_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_target_exists: cheap, READ-ONLY existence check - does the
# recorded TARGET endpoint still exist on BACKEND? Never starts a server or
# session: for herdr this deliberately queries the pane directly instead of
# going through fm_backend_herdr_target_ready (which auto-starts the herdr
# server as a side effect via fm_backend_herdr_server_ensure - fine for an
# operation that is about to use the pane, wrong for a passive liveness
# probe). A gone tmux window or an unqueryable herdr pane (server down, pane
# closed), missing zellij pane, or unreadable Orca terminal simply fails, which
# IS "does not exist" for this purpose.
# Mirrors fm-crew-state.sh's pane_readable check; exists here as one shared
# primitive so callers that only need a fast alive/dead read (recovery
# digests, the session-start fleet digest) do not re-derive it inline.
fm_backend_target_exists() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 expected_label=${3:-} session pane
  case "$backend" in
    tmux)
      tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1
      ;;
    herdr)
      fm_backend_source herdr || return 1
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      # fm_backend_herdr_cli (not a raw HERDR_SESSION-only call): verified
      # empirically (docs/herdr-backend.md "Session targeting") that the bare
      # env var alone is NOT reliably honored once another herdr server is
      # already bound on the machine - it silently queries whatever server IS
      # running instead. fm_backend_herdr_cli appends the required --session
      # flag on top, so this check is correctly scoped even when the caller's
      # own ambient session (e.g. the primary firstmate's default session) is
      # a DIFFERENT one than the target's.
      fm_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
      ;;
    zellij)
      fm_backend_source zellij || return 1
      fm_backend_zellij_target_ready "$target" "$expected_label"
      ;;
    orca)
      fm_backend_source orca || return 1
      fm_backend_orca_capture "$target" 1 >/dev/null 2>&1
      ;;
    cmux)
      fm_backend_source cmux || return 1
      fm_backend_cmux_target_ready "$target" "$expected_label"
      ;;
    *)
      return 1
      ;;
  esac
}

# fm_backend_agent_alive: CONFIDENT liveness of a live harness-agent PROCESS
# under <target>, distinct from fm_backend_target_exists's pane-PRESENCE-only
# check above. A secondmate agent that has exited leaves its backend endpoint
# alive as a bare shell; fm_backend_target_exists reports that shell as
# "alive" because the pane itself still exists, which is exactly the gap
# bin/fm-bootstrap.sh's session-start secondmate-liveness sweep exists to
# close (AGENTS.md "Session start"). Prints one of:
#   alive   - a real agent process is confirmed running.
#   dead    - CONFIDENTLY not an agent: a bare shell (tmux) or a
#             structurally-gone/no-agent-registered pane (herdr).
#   unknown - anything ambiguous, unreadable, or unverified for this backend.
# Scoped to today's --secondmate-spawn-capable backends with an empirically
# verified classifier: tmux (docs/tmux-backend.md "Agent liveness probe") and
# herdr (docs/herdr-backend.md "Agent liveness probe reuses the husk
# classifier"). zellij, orca, and cmux report unknown until independently
# verified - future work, not a functional gap for the two backends
# --secondmate spawns actually support today plus tmux's reference path.
# Callers must treat unknown exactly like an unreadable target: NEVER license
# an action from it alone - the secondmate-liveness sweep gates a respawn on
# `dead` only, precisely so a momentary read glitch can never duplicate a
# live supervisor.
fm_backend_agent_alive() {  # <backend> <target>
  local backend=$1 target=$2
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    tmux) fm_backend_tmux_agent_alive "$target" ;;
    herdr) fm_backend_herdr_agent_alive "$target" ;;
    *) printf 'unknown' ;;
  esac
}
