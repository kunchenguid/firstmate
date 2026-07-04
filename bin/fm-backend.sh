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
# running inside a cmux-spawned terminal (CMUX_WORKSPACE_ID) with no explicit
# backend setting - unlike Orca, which stays never-auto-detected because it
# also owns the task worktree; see docs/cmux-backend.md for its empirical
# basis.
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
fm_backend_detect() {
  if [ -n "${TMUX:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ]; then
    printf 'herdr'
    return 0
  fi
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    printf 'cmux'
    return 0
  fi
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
# today's default-path behavior and callers must see zero change.
fm_backend_name() {
  local line v detected
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
  if detected=$(fm_backend_detect); then
    if [ "$detected" = herdr ]; then
      echo "NOTICE: auto-detected herdr runtime (HERDR_ENV=1) - spawning into the EXPERIMENTAL herdr backend. Set config/backend or pass --backend tmux to opt out." >&2
    fi
    if [ "$detected" = cmux ]; then
      echo "NOTICE: auto-detected cmux runtime (CMUX_WORKSPACE_ID) - spawning into the EXPERIMENTAL cmux backend. Set config/backend or pass --backend tmux to opt out." >&2
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
      HERDR_SESSION="$session" herdr pane get "$pane" >/dev/null 2>&1
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
