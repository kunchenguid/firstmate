#!/usr/bin/env bash
# bin/backends/cmux.sh - the cmux session-provider adapter (EXPERIMENTAL).
#
# Design: data/cmux-backend-feasibility-c7/report.md (adapter design sketch,
# section 4) plus the live-app verification pass recorded in
# docs/cmux-backend.md (real cmux 0.64.17, macOS aarch64, 2026-07-03). cmux is
# a session provider ONLY, exactly like herdr/zellij: the worktree provider
# stays treehouse. Sourced only through bin/fm-backend.sh's fm_backend_source
# in normal operation; the unit tests source it directly.
#
# Container shape: cmux has no "session" layer to multiplex the way
# tmux/herdr/zellij do - there is just "the app" (one running GUI instance).
# ONE cmux workspace PER TASK (mirrors tmux's one-window-per-task / zellij's
# one-tab-per-task), with exactly one surface inside it. cmux has no session
# layer, so workspace titles are scoped by firstmate home and installation
# path inside this adapter.
#
# Target string shape: "<workspace_uuid>:<surface_uuid>" - both bare UUIDs
# with no embedded colon, so splitting on the FIRST colon is trivially
# correct (mirrors herdr's/zellij's target-string convention).
#
# GUI-first, macOS-only (docs/cmux-backend.md "Setup"): explicit selection or
# runtime auto-detection when firstmate itself is already running inside a
# cmux-spawned terminal (CMUX_WORKSPACE_ID). Unlike Orca, cmux is a pure
# session provider (treehouse still owns the worktree) and Escape IS natively
# supported.
#
# Empirical findings from the live verification pass (docs/cmux-backend.md has
# the full evidence log) that shaped this adapter, several of which diverge
# from the original design sketch's speculation:
#
#   1. `send` (literal) does NOT auto-submit - confirmed, matches every other
#      backend's "literal-then-separate-Enter" contract.
#   2. Surface cwd is CREATION-TIME-FROZEN (zellij-shape), not live-tracking
#      (herdr-shape): `workspace list`'s `current_directory` field reflects a
#      `cd` run directly in the surface's own top-level shell, but stays
#      frozen at wherever that shell was when it launched a foreground
#      subshell (exactly what `treehouse get` does) - verified live: a nested
#      `bash -c 'cd /Users && exec bash'` left `current_directory` reporting
#      the PARENT shell's last cwd, never following into the subshell. Fixed
#      with zellij's own pwd-marker-probe workaround, reused verbatim in
#      spirit (fm_backend_cmux_current_path below).
#   3. `read-screen --lines N` has NO herdr-style small-N empty-result bug -
#      verified N=1..10 all return correctly-clamped, non-empty content. The
#      "fetch generous, trim locally" pattern is still used for consistency
#      and because the actual viewport height (not a bug - real behavior) can
#      still cap a single `read-screen` call below a caller's requested bound.
#      A DIFFERENT, unanticipated read-screen pitfall surfaced only once real
#      spawn-shaped call sequences were exercised (not caught by the original
#      Phase 1 pass, which happened to test against surfaces that already had
#      output): read-screen against a genuinely FRESH surface that has never
#      been written to yet fails outright with `internal_error: Failed to
#      read terminal text`, for every --lines value and no matter how long
#      you wait, until at least one `send` actually writes to it - after
#      which it becomes reliably readable forever. This ruled out read-screen
#      as fm_backend_cmux_target_ready's liveness probe (the design sketch's
#      original suggestion): the very first send on a freshly created task
#      would fail its own pre-flight readiness check. `list-panes` has no such
#      gap and is used instead (fm_backend_cmux_surface_exists), mirroring
#      zellij's own structural pane_exists check.
#   4. Closing a workspace's LAST surface is a THIRD shape, matching neither
#      herdr (auto-closes the workspace) nor zellij (leaves a ghost tab):
#      `close-surface` REFUSES outright with a typed error
#      (`invalid_state: Cannot close the last surface`), leaving both the
#      surface and the workspace untouched. `close-workspace` cleanly removes
#      the whole workspace (surface included) in one call with no ghost left
#      behind. Kill therefore closes the whole workspace directly, which also
#      reclaims any extra surfaces inside the task workspace.
#   5. Workspace ids do NOT survive an app relaunch - verified via source
#      (`Sources/Workspace.swift`'s only initializer unconditionally sets
#      `self.id = UUID()`, with no restored-id parameter, unlike surfaces'
#      `restoredSurfaceId ?? UUID()` path scoped to same-run object reuse).
#      No live app restart of the captain's own content was performed to
#      confirm this; see docs/cmux-backend.md for the reasoning. Recovery
#      therefore uses scoped-title matching from the caller-facing fm-<id>
#      label, never a stored uuid, mirroring herdr's/zellij's own recovery
#      posture.
#   6. NO title uniqueness enforcement for workspaces OR surfaces/tabs -
#      verified live (two workspaces, and two surfaces in one workspace, all
#      created successfully sharing one title). The duplicate check below is
#      ours, mirroring every other adapter, and uses home-scoped titles so a
#      shared cmux app cannot cross-match another firstmate home's task.
#
#   Unanticipated finding, load-bearing for this adapter: the control socket
#   defaults to `socketControlMode=cmuxOnly`, which REJECTS any CLI process
#   not spawned inside cmux itself ("Access denied - only processes started
#   inside cmux can connect"). Since firstmate always drives cmux from an
#   external shell, `automation.socketControlMode` must be set to `password`
#   (or laxer) with a socket password configured, and firstmate must supply
#   that same password on every invocation. See docs/cmux-backend.md "Setup"
#   for the one-time configuration steps this requires.
#
# Requires: cmux (CLI, bundled inside cmux.app - not guaranteed to be on PATH;
# see fm_backend_cmux_bin), jq (JSON parsing). Both are gated behind selecting
# this backend; bin/fm-bootstrap.sh's core tool list is unaffected.

# FM_HOME fallback: every real caller already sets FM_HOME as a global before
# sourcing fm-backend.sh (which sources this file); this exists only so this
# file's own unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/zellij.sh's identical fallback.
FM_BACKEND_CMUX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_CMUX_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Verified minimum: the version the live pass ran against (docs/cmux-backend.md).
FM_BACKEND_CMUX_MIN_MAJOR=0
FM_BACKEND_CMUX_MIN_MINOR=64
FM_BACKEND_CMUX_SECONDMATE_MARKER=".fm-secondmate-home"

# fm_backend_cmux_bin: resolve the cmux CLI binary. cmux does not reliably
# land on PATH after a plain app install - it ships an OPTIONAL "install CLI"
# action (`Sources/App/CmuxCLIPathInstaller.swift`, symlinking
# /usr/local/bin/cmux -> the bundled binary) that a fresh install has not
# necessarily run. Prefer PATH (respects an operator's own setup, e.g. after
# running that install action), fall back to the well-known bundle path.
FM_BACKEND_CMUX_BUNDLE_BIN="${FM_BACKEND_CMUX_BUNDLE_BIN:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
fm_backend_cmux_bin() {
  if command -v cmux >/dev/null 2>&1; then
    printf 'cmux'
    return 0
  fi
  if [ -x "$FM_BACKEND_CMUX_BUNDLE_BIN" ]; then
    printf '%s' "$FM_BACKEND_CMUX_BUNDLE_BIN"
    return 0
  fi
  return 1
}

fm_backend_cmux_tool_check() {
  fm_backend_cmux_bin >/dev/null 2>&1 || { echo "error: backend=cmux selected but the 'cmux' CLI was not found on PATH or at $FM_BACKEND_CMUX_BUNDLE_BIN (https://cmux.com)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=cmux selected but 'jq' is not installed (required to parse cmux's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_cmux_password: the optional socket password from
# config/cmux-socket-password (first non-empty line), or empty. Read fresh
# from the effective config dir on every call, mirroring the rest of backend
# config resolution.
# Never overrides an operator's own ambient CMUX_SOCKET_PASSWORD when the file
# is absent - fm_backend_cmux_cli only exports this when it resolves non-empty.
fm_backend_cmux_password() {
  local config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" f line
  f="$config_dir/cmux-socket-password"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then
      printf '%s' "$line"
      return 0
    fi
  done < "$f"
}

# fm_backend_cmux_cli: run `cmux <args...>`, quieted (suppresses legacy-alias
# notices) and with the configured socket password exported only when one is
# actually configured, so an operator's own ambient CMUX_SOCKET_PASSWORD is
# never clobbered with an empty value.
fm_backend_cmux_cli() {  # <cmux-subcommand-and-args...>
  local bin pw
  bin=$(fm_backend_cmux_bin) || return 1
  pw=$(fm_backend_cmux_password)
  if [ -n "$pw" ]; then
    CMUX_QUIET=1 CMUX_SOCKET_PASSWORD="$pw" "$bin" "$@"
  else
    CMUX_QUIET=1 "$bin" "$@"
  fi
}

# fm_backend_cmux_version_check: refuse loudly on a missing/incompatible cmux
# client. `cmux version` needs no socket (verified: works even when the
# control socket is unreachable), so this is a pure client-version gate,
# separate from reachability/auth (fm_backend_cmux_ping_state below).
fm_backend_cmux_version_check() {
  fm_backend_cmux_tool_check || return 1
  local raw ver major rest minor
  raw=$(fm_backend_cmux_cli version 2>/dev/null) || { echo "error: 'cmux version' failed; is cmux installed correctly?" >&2; return 1; }
  ver=$(printf '%s' "$raw" | awk '{print $2}')
  case "$ver" in
    ''|*[!0-9.]*)
      echo "error: could not parse a cmux version from '$raw'; refusing to use an unverified cmux build" >&2
      return 1
      ;;
  esac
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  if [ "$major" -lt "$FM_BACKEND_CMUX_MIN_MAJOR" ] || { [ "$major" -eq "$FM_BACKEND_CMUX_MIN_MAJOR" ] && [ "$minor" -lt "$FM_BACKEND_CMUX_MIN_MINOR" ]; }; then
    echo "error: cmux $ver is older than the verified minimum $FM_BACKEND_CMUX_MIN_MAJOR.$FM_BACKEND_CMUX_MIN_MINOR; update cmux before using backend=cmux" >&2
    return 1
  fi
  return 0
}

# fm_backend_cmux_ping_state: classify socket reachability/auth from `cmux
# ping`'s own text, since a missing/rejected connection is a normal, expected
# outcome here (never treated as a scripting bug) - ok|denied|unauth|down|error.
fm_backend_cmux_ping_state() {
  local out
  out=$(fm_backend_cmux_cli ping 2>&1)
  if [ "$out" = "PONG" ]; then
    printf 'ok'
    return 0
  fi
  case "$out" in
    *'only processes started inside cmux can connect'*) printf 'denied' ;;
    *'Password mode is enabled but no socket password'*|*'Authentication required'*) printf 'unauth' ;;
    *'Socket not found'*) printf 'down' ;;
    *) printf 'error' ;;
  esac
}

# fm_backend_cmux_ensure_running: launch cmux (mirrors the CLI's own
# `connectClient`/`launchApp` `open -a cmux` fallback) only when the socket is
# simply not up yet (`down`); an auth failure (`denied`/`unauth`) is a
# configuration problem a relaunch cannot fix, so it fails fast with an
# actionable pointer to docs/cmux-backend.md instead of retry-looping.
fm_backend_cmux_ensure_running() {
  local state i
  state=$(fm_backend_cmux_ping_state)
  case "$state" in
    ok) return 0 ;;
    denied)
      echo "error: backend=cmux socket rejected the connection (automation.socketControlMode is cmuxOnly, the default). See docs/cmux-backend.md 'Setup' to switch to password mode for external CLI access, or set config/backend to tmux (or pass --backend tmux) if you did not mean to use cmux." >&2
      return 1
      ;;
    unauth)
      echo "error: backend=cmux socket requires a password (automation.socketControlMode=password) but none is configured for this caller. Set config/cmux-socket-password or export CMUX_SOCKET_PASSWORD - see docs/cmux-backend.md 'Setup' - or set config/backend to tmux (or pass --backend tmux) if you did not mean to use cmux." >&2
      return 1
      ;;
  esac
  open -a cmux >/dev/null 2>&1 || { echo "error: failed to launch cmux ('open -a cmux' failed)" >&2; return 1; }
  for i in $(seq 1 20); do
    state=$(fm_backend_cmux_ping_state)
    case "$state" in
      ok) return 0 ;;
      denied)
        echo "error: backend=cmux socket rejected the connection (automation.socketControlMode is cmuxOnly, the default). See docs/cmux-backend.md 'Setup' to switch to password mode for external CLI access, or set config/backend to tmux (or pass --backend tmux) if you did not mean to use cmux." >&2
        return 1
        ;;
      unauth)
        echo "error: backend=cmux socket requires a password (automation.socketControlMode=password) but none is configured for this caller. Set config/cmux-socket-password or export CMUX_SOCKET_PASSWORD - see docs/cmux-backend.md 'Setup' - or set config/backend to tmux (or pass --backend tmux) if you did not mean to use cmux." >&2
        return 1
        ;;
    esac
    sleep 0.5
  done
  echo "error: cmux did not become reachable within 10s of launch" >&2
  return 1
}

# fm_backend_cmux_container_ensure: the full spawn-time container-ensure
# sequence (version gate, reachability/launch-if-needed). No per-home
# container to stand up - cmux has no session layer (unlike herdr/zellij),
# the app itself is the only container. Nothing to echo; callers proceed
# straight to fm_backend_cmux_create_task.
fm_backend_cmux_container_ensure() {
  fm_backend_cmux_version_check || return 1
  fm_backend_cmux_ensure_running || return 1
  return 0
}

# fm_backend_cmux_home_label: readable home prefix plus a short hash of the
# resolved FM_ROOT path. cmux has one app-global workspace namespace, so the
# path hash distinguishes every firstmate installation, including multiple
# primary homes. Moving an installation changes this tag and old cmux titles
# stop matching; task meta already records absolute worktree paths, so repo
# relocation is already outside the supported recovery contract.
fm_backend_cmux_home_label() {
  local marker="$FM_HOME/$FM_BACKEND_CMUX_SECONDMATE_MARKER" id prefix root hash
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="2ndmate-$id"
    else
      prefix="firstmate"
    fi
  else
    prefix="firstmate"
  fi
  root=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || root=$FM_ROOT
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$root" | cksum | awk '{printf "%08x", $1}')
  fi
  printf '%s-%s' "$prefix" "$hash"
}

fm_backend_cmux_scoped_title() {  # <fm-task-label>
  local label=$1 rest home
  home=$(fm_backend_cmux_home_label)
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$home" "$rest"
}

# fm_backend_cmux_workspace_id_for_label: the live workspace id whose title
# equals <label>, or empty. cmux enforces no title uniqueness (finding #6),
# so this adopts the FIRST match `jq` returns, mirroring herdr's/zellij's own
# duplicate-check posture.
fm_backend_cmux_workspace_id_for_label() {  # <label>
  local label=$1
  fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null \
    | jq -r --arg want "$label" '.workspaces[]? | select(.title == $want) | .id' 2>/dev/null | head -1
}

fm_backend_cmux_surface_id_for_workspace() {  # <workspace_id>
  local wsid=$1
  fm_backend_cmux_cli list-panes --workspace "$wsid" --json --id-format uuids 2>/dev/null \
    | jq -r '.panes[0] // {} | .selected_surface_id // (.surface_ids[0] // empty)' 2>/dev/null
}

# fm_backend_cmux_create_task: create the task's workspace (one surface),
# refusing an existing live <label> (finding #6: cmux enforces no uniqueness
# itself). Resolves the fresh workspace's default surface via one list-panes
# call (finding: a freshly created workspace already has exactly one surface,
# so no separate new-surface call is needed). --focus false is passed for
# defense in depth though verified to already be the default (finding:
# workspace/surface/pane create all default focus to false) - no
# focus-restore dance is needed, unlike zellij. Echoes "<workspace_id>
# <surface_id>" on success.
fm_backend_cmux_create_task() {  # <label> <cwd>
  local label=$1 cwd=$2 title dup out wsid sfid
  title=$(fm_backend_cmux_scoped_title "$label")
  dup=$(fm_backend_cmux_workspace_id_for_label "$title")
  if [ -n "$dup" ]; then
    echo "error: cmux workspace '$title' already exists" >&2
    return 1
  fi
  out=$(fm_backend_cmux_cli new-workspace --name "$title" --cwd "$cwd" --focus false --id-format uuids 2>&1) || {
    echo "error: cmux new-workspace failed for '$title': $out" >&2
    return 1
  }
  wsid=$(fm_backend_cmux_workspace_id_for_label "$title")
  [ -n "$wsid" ] || { echo "error: could not resolve a cmux workspace id for '$title' after creation" >&2; return 1; }
  sfid=$(fm_backend_cmux_surface_id_for_workspace "$wsid")
  [ -n "$sfid" ] || { echo "error: could not resolve the default surface for cmux workspace '$title' ($wsid)" >&2; return 1; }
  printf '%s %s' "$wsid" "$sfid"
}

# fm_backend_cmux_parse_target: split "<workspace_uuid>:<surface_uuid>" on the
# FIRST colon (neither UUID contains a colon, so this is unambiguous). Sets
# FM_BACKEND_CMUX_WORKSPACE and FM_BACKEND_CMUX_SURFACE for the caller.
fm_backend_cmux_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_CMUX_WORKSPACE=${target%%:*}
  FM_BACKEND_CMUX_SURFACE=${target#*:}
  [ -n "$FM_BACKEND_CMUX_WORKSPACE" ] && [ -n "$FM_BACKEND_CMUX_SURFACE" ] && [ "$FM_BACKEND_CMUX_SURFACE" != "$target" ]
}

# fm_backend_cmux_surface_exists: does <surface_id> currently appear as one of
# <workspace_id>'s surfaces, per list-panes? Structural existence check, never
# a content read.
#
# Verified real-cmux pitfall NOT anticipated by the design sketch: read-screen
# against a genuinely fresh surface that has never been written to yet fails
# with a typed `internal_error: Failed to read terminal text` - EVERY
# read-screen call fails this way (with or without --lines, any value,
# regardless of how long you wait) until at least one `send` has actually
# written to the surface, at which point it becomes reliably readable. This
# would make read-screen unusable as fm_backend_cmux_target_ready's liveness
# probe: the very first send_literal on a freshly created task's surface
# would fail its own readiness pre-check before ever getting to write
# anything. list-panes has no such gap (verified: correct, immediate output
# on a completely untouched fresh surface), so it is the liveness primitive
# instead - mirroring zellij's own pane_exists check
# (fm_backend_zellij_pane_exists) rather than the design sketch's original
# read-screen-based suggestion.
fm_backend_cmux_surface_exists() {  # <workspace_id> <surface_id>
  local wsid=$1 sfid=$2
  fm_backend_cmux_cli list-panes --workspace "$wsid" --json --id-format uuids 2>/dev/null \
    | jq -e --arg s "$sfid" '[.panes[]? | select(.surface_ids // [] | index($s))] | length > 0' >/dev/null 2>&1
}

# fm_backend_cmux_target_ready: parse the target and verify it is live via
# fm_backend_cmux_surface_exists (never read-screen - see that function's
# header for the fresh-surface pitfall this avoids). When the caller knows
# the owning firstmate task label, refresh stale workspace/surface ids by label.
fm_backend_cmux_target_ready() {  # <target> [expected-label]
  local expected_label=${2:-} expected_title title wsid sfid
  fm_backend_cmux_parse_target "$1" || return 1
  if [ -n "$expected_label" ]; then
    expected_title=$(fm_backend_cmux_scoped_title "$expected_label")
    title=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r --arg id "$FM_BACKEND_CMUX_WORKSPACE" '.workspaces[]? | select(.id == $id) | .title' 2>/dev/null)
    if [ "$title" = "$expected_title" ]; then
      fm_backend_cmux_surface_exists "$FM_BACKEND_CMUX_WORKSPACE" "$FM_BACKEND_CMUX_SURFACE" && return 0
      wsid=$FM_BACKEND_CMUX_WORKSPACE
    elif [ -n "$title" ]; then
      return 1
    else
      wsid=$(fm_backend_cmux_workspace_id_for_label "$expected_title")
      [ -n "$wsid" ] || return 1
    fi
    sfid=$(fm_backend_cmux_surface_id_for_workspace "$wsid")
    [ -n "$sfid" ] || return 1
    FM_BACKEND_CMUX_WORKSPACE=$wsid
    FM_BACKEND_CMUX_SURFACE=$sfid
    return 0
  fi
  fm_backend_cmux_surface_exists "$FM_BACKEND_CMUX_WORKSPACE" "$FM_BACKEND_CMUX_SURFACE"
}

# fm_backend_cmux_current_path: the live foreground process's cwd, or empty on
# any error. Mirrors fm_backend_zellij_current_path's active pwd-marker-probe
# workaround (bin/backends/zellij.sh:306-347) verbatim in spirit.
#
# Verified pitfall (finding #2 above): cmux's `current_directory` field DOES
# reflect a `cd` run directly in the surface's own top-level shell, but stays
# FROZEN at whatever directory that shell was in when it launched `treehouse
# get` as a foreground command - it never follows that command's own internal
# `cd` into the acquired worktree. cmux's control socket exposes no
# live-process cwd field either (unlike herdr's `foreground_cwd`), so passive
# polling cannot solve this here any more than it could for zellij. Active
# probe instead: print the surface's `$PWD` with a unique marker (atomically
# submitted via send_text_line), briefly settle, then capture and read only
# that marker line. Scoped to fm-spawn.sh's own worktree-discovery poll loop.
fm_backend_cmux_current_path() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} out line marker_begin="__FM_CMUX_CWD_BEGIN__" marker_end="__FM_CMUX_CWD_END__" in_block=0 chunk="" last=""
  fm_backend_cmux_target_ready "$target" "$expected_label" || return 0
  fm_backend_cmux_send_text_line "$target" "printf '%s\n' '$marker_begin'; pwd; printf '%s\n' '$marker_end'" "$expected_label" || return 0
  sleep 0.3
  out=$(fm_backend_cmux_capture "$target" 200 "$expected_label") || return 0
  while IFS= read -r line; do
    if [ "$line" = "$marker_begin" ]; then
      in_block=1
      chunk=""
      continue
    fi
    if [ "$line" = "$marker_end" ]; then
      case "$chunk" in /*) last=$chunk ;; esac
      in_block=0
      continue
    fi
    [ "$in_block" -eq 1 ] && chunk="$chunk$line"
  done <<EOF
$out
EOF
  printf '%s' "$last"
}

# fm_backend_cmux_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately. Verified live (finding #1): `send` does NOT
# auto-submit, matching every other backend's contract exactly.
fm_backend_cmux_send_literal() {  # <target> <text> [expected-label]
  fm_backend_cmux_target_ready "$1" "${3:-}" || return 1
  fm_backend_cmux_cli send --workspace "$FM_BACKEND_CMUX_WORKSPACE" --surface "$FM_BACKEND_CMUX_SURFACE" -- "$2" >/dev/null 2>&1
}

# fm_backend_cmux_normalize_key: map firstmate's key vocabulary (Enter,
# Escape, C-c) onto cmux's `send-key` names. Verified empirically: enter,
# escape, and ctrl-c all work directly (lowercase, hyphenated). cmux's own
# key vocabulary is genuinely richer (ctrl-d/ctrl-z/ctrl-\\, semantic aliases
# sigint/sigtstp/sigquit - `TerminalSurface+Input.swift`), but firstmate's
# shared vocabulary across backends only needs these three today.
fm_backend_cmux_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'ctrl-c' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_backend_cmux_send_key: one named special key. Escape IS natively
# supported here (unlike Orca, docs/orca-backend.md), so it is wired directly.
fm_backend_cmux_send_key() {  # <target> <key> [expected-label]
  fm_backend_cmux_target_ready "$1" "${3:-}" || return 1
  local key
  key=$(fm_backend_cmux_normalize_key "$2")
  fm_backend_cmux_cli send-key --workspace "$FM_BACKEND_CMUX_WORKSPACE" --surface "$FM_BACKEND_CMUX_SURFACE" "$key" >/dev/null 2>&1
}

# fm_backend_cmux_send_text_line: send one line of TEXT then submit. cmux has
# no single-call atomic "run and submit" primitive (like herdr's `pane run`),
# so this composes send (literal) + send-key enter, exactly like zellij's
# equivalent - used for the fixed spawn-time commands (treehouse get, the
# GOTMPDIR export).
fm_backend_cmux_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_cmux_send_literal "$1" "$2" "${3:-}" || return 1
  fm_backend_cmux_send_key "$1" Enter "${3:-}"
}

# fm_backend_cmux_capture: bounded plain-text surface capture. No herdr-style
# small-N empty-result bug was found (finding #3), but "fetch generous, trim
# locally" is kept anyway: a single read-screen call is still bounded by the
# surface's actual current viewport height regardless of the requested
# --lines value, so a caller asking for more than the viewport can see would
# otherwise silently get less than it asked for with no way to tell why.
fm_backend_cmux_capture() {  # <target> <lines> [expected-label]
  fm_backend_cmux_target_ready "$1" "${3:-}" || return 1
  local lines=${2:-200} fetch raw out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  case "$fetch" in ''|*[!0-9]*) fetch=200 ;; *) [ "$fetch" -ge 200 ] || fetch=200 ;; esac
  raw=$(fm_backend_cmux_cli read-screen --workspace "$FM_BACKEND_CMUX_WORKSPACE" --surface "$FM_BACKEND_CMUX_SURFACE" --scrollback --lines "$fetch" --json 2>/dev/null) || return 1
  out=$(printf '%s' "$raw" | jq -r '.text // empty' 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# fm_backend_cmux_composer_state: classify the composer's own row as
# empty|pending|unknown. Adapted directly from herdr's structural border-row
# classifier (fm_backend_herdr_composer_state, bin/backends/herdr.sh:598-665)
# per the build task's explicit direction - this is the highest-risk piece of
# a new backend's send-and-verify logic, and cmux's `read-screen` gives the
# same kind of plain-text capture with no cursor-row primitive that herdr's
# `pane read` does, so the same structural approach applies unchanged: locate
# the composer row as the only captured line whose TRIMMED content both
# STARTS and ENDS with the same border glyph (│, ┃, or a plain ASCII |),
# scanning forward and keeping the LAST match so an earlier border-shaped line
# (scrollback, a popup) never outranks the real bottom-anchored composer row.
FM_BACKEND_CMUX_COMPOSER_LINES=${FM_BACKEND_CMUX_COMPOSER_LINES:-20}
FM_BACKEND_CMUX_IDLE_RE=${FM_BACKEND_CMUX_IDLE_RE:-'^Type a message\.\.\.$'}

fm_backend_cmux_composer_state() {  # <target> [expected-label] -> empty|pending|unknown
  local target=$1 expected_label=${2:-} cap line trimmed stripped="" found=0
  cap=$(fm_backend_cmux_capture "$target" "$FM_BACKEND_CMUX_COMPOSER_LINES" "$expected_label") || { printf 'unknown'; return 0; }
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|') : ;;
      *) continue ;;
    esac
    stripped=$trimmed
    found=1
  done < <(printf '%s\n' "$cap")
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  stripped=${stripped//│/}
  stripped=${stripped//┃/}
  stripped=${stripped//|/}
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  case "$stripped" in
    '❯'|'>'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac
  case "$stripped" in
    '❯ '*|'> '*|'$ '*|'% '*|'# '*) stripped=${stripped#??} ;;
    '❯'*|'>'*|'$'*|'%'*|'#'*) stripped=${stripped#?} ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  if printf '%s' "$stripped" | grep -qE "$FM_BACKEND_CMUX_IDLE_RE"; then
    printf 'empty'; return 0
  fi
  printf 'pending'
}

# fm_backend_cmux_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then submit with a named Enter key, retried
# (Enter only, never retyped) until the composer's own row reads empty.
# Mirrors fm_backend_herdr_send_text_submit's verification strategy exactly:
# a slash-command popup's first Enter can close the popup and fill an
# argument-hint placeholder into the composer rather than submitting, which a
# raw-diff check would misread as "submitted" - classifying the composer row
# specifically avoids that false positive, so the retry loop correctly sends
# a second Enter when needed. Echoes empty|pending|unknown|send-failed, the
# SAME vocabulary every existing backend already speaks.
fm_backend_cmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-} i=0 state
  fm_backend_cmux_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_cmux_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    fm_backend_cmux_send_key "$target" Enter "$expected_label" || true
    sleep "$sleep_s"
    state=$(fm_backend_cmux_composer_state "$target" "$expected_label")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# fm_backend_cmux_kill: remove the task's whole workspace, best-effort (mirrors
# every other backend's `kill` `|| true` contract). A cmux task owns one
# workspace, so teardown reclaims that workspace and all of its surfaces.
fm_backend_cmux_kill() {  # <target> [unused] [expected-label]
  local expected_label=${3:-}
  if [ -n "$expected_label" ]; then
    fm_backend_cmux_target_ready "$1" "$expected_label" || return 0
  else
    fm_backend_cmux_parse_target "$1" || return 0
  fi
  fm_backend_cmux_cli close-workspace --workspace "$FM_BACKEND_CMUX_WORKSPACE" >/dev/null 2>&1 || true
}

# fm_backend_cmux_list_live: recovery/orphan discovery. Lists every workspace
# whose title is scoped to this firstmate home, by TITLE - never by trusting a
# stored uuid, since workspace ids do NOT survive an app relaunch (finding #5).
# One "<workspace_id>:<surface_id>\t<fm-id>" line per live task workspace.
# Read-only: an unreachable cmux simply lists nothing.
fm_backend_cmux_list_live() {
  local wss wsid title sfid home prefix plain
  home=$(fm_backend_cmux_home_label)
  prefix="fm-$home-"
  wss=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null) || return 0
  while IFS=$'\t' read -r wsid title; do
    [ -n "$wsid" ] || continue
    plain=${title#"$prefix"}
    [ -n "$plain" ] || continue
    sfid=$(fm_backend_cmux_surface_id_for_workspace "$wsid")
    [ -n "$sfid" ] || continue
    printf '%s:%s\tfm-%s\n' "$wsid" "$sfid" "$plain"
  done < <(printf '%s' "$wss" | jq -r --arg prefix "$prefix" '.workspaces[]? | select(.title | startswith($prefix)) | "\(.id)\t\(.title)"' 2>/dev/null)
}
