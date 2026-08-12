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
# cmux-spawned terminal (primary CMUX_WORKSPACE_ID marker, with documented
# macOS fallback signals for wrapper-stripped claude). Unlike Orca, cmux is a
# pure session provider (treehouse still owns the worktree) and Escape IS
# natively supported.
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
#      surface and the workspace untouched. `close-workspace` removes the
#      whole workspace (surface included) only when it is not the last
#      workspace in its window. `fm_backend_cmux_kill` handles the documented
#      last-in-window exception below, while still reclaiming every surface in
#      the task workspace.
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
#   external shell, `automation.socketControlMode` must be one of the three
#   externally-viable modes (docs/cmux-backend.md "Setup" owns the full
#   matrix, verified from cmux source): `automation` (RECOMMENDED - same-user
#   external clients, no shared secret), `password` (works, needs
#   config/cmux-socket-password or CMUX_SOCKET_PASSWORD supplied on every
#   invocation), or `allowAll` (works, but opens the socket to every local
#   user - not recommended). `off` and `cmuxOnly` can never work externally.
#   A configured password is harmless under non-password modes: cmux's own
#   CLI sends `auth` preemptively and tolerates the server's "Unknown
#   command 'auth'" reply (cli/cmux.swift, authenticateSocketClientIfNeeded).
#
# Requires: cmux (CLI, bundled inside cmux.app - not guaranteed to be on PATH;
# see fm_backend_cmux_bin), jq (JSON parsing). Bootstrap detects these through
# fm_backend_required_tools only when cmux is the resolved backend; this adapter
# also gates them again before spawning.

# FM_HOME fallback: every real caller already sets FM_HOME as a global before
# sourcing fm-backend.sh (which sources this file); this exists only so this
# file's own unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/zellij.sh's identical fallback.
FM_BACKEND_CMUX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_CMUX_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_CMUX_ROOT/bin/fm-backend-hometag-lib.sh"

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_CMUX_ROOT/bin/fm-composer-lib.sh"

# Verified minimum: the version the live pass ran against (docs/cmux-backend.md).
FM_BACKEND_CMUX_MIN_MAJOR=0
FM_BACKEND_CMUX_MIN_MINOR=64

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
# The three auth-shaped server replies (verified from cmux source,
# Sources/TerminalController.swift): "Authentication required" (password mode,
# no password presented), "Password mode is enabled but no socket password"
# (password mode, app side has no password configured), and "Invalid password"
# (password mode, wrong password presented) all classify as unauth - each is a
# password-configuration problem on one side or the other, never fixable by
# relaunching the app.
fm_backend_cmux_ping_state() {
  local out
  out=$(fm_backend_cmux_cli ping 2>&1)
  if [ "$out" = "PONG" ]; then
    printf 'ok'
    return 0
  fi
  case "$out" in
    *'only processes started inside cmux can connect'*) printf 'denied' ;;
    *'Password mode is enabled but no socket password'*|*'Authentication required'*|*'Invalid password'*) printf 'unauth' ;;
    *'Socket not found'*) printf 'down' ;;
    *) printf 'error' ;;
  esac
}

# fm_backend_cmux_refuse_denied / fm_backend_cmux_refuse_unauth: the two
# fail-fast auth refusals, factored so the pre-launch and post-launch checks
# cannot drift. Each names every externally-viable socket mode (automation
# RECOMMENDED, password, allowAll - docs/cmux-backend.md "Setup" owns the
# matrix) plus the config/backend opt-out for a caller who only landed on
# cmux via auto-detection.
fm_backend_cmux_refuse_denied() {
  echo "error: backend=cmux socket rejected the connection (automation.socketControlMode is cmuxOnly, the default, which never admits an external CLI like firstmate). In cmux Settings > Automation set Socket Control Mode to 'Automation mode' (recommended - same-user external clients, no password), or 'Password mode' plus config/cmux-socket-password/CMUX_SOCKET_PASSWORD, or 'Full open access' (NOT recommended - admits every local user) - see docs/cmux-backend.md 'Setup' - or set config/backend to tmux (or pass --backend tmux) if you did not mean to use cmux." >&2
}

fm_backend_cmux_refuse_unauth() {
  echo "error: backend=cmux socket requires a password (automation.socketControlMode=password) but none is configured for this caller, or the configured one was rejected. Set config/cmux-socket-password or export CMUX_SOCKET_PASSWORD to the password from cmux Settings > Automation, or switch Socket Control Mode to 'Automation mode' (recommended - no password needed) - see docs/cmux-backend.md 'Setup' - or set config/backend to tmux (or pass --backend tmux) if you did not mean to use cmux." >&2
}

# fm_backend_cmux_ensure_running: launch cmux (mirrors the CLI's own
# `connectClient`/`launchApp` `open -a cmux` fallback) only when the socket is
# simply not up yet (`down`); an auth failure (`denied`/`unauth`) is a
# configuration problem a relaunch cannot fix, so it fails fast with an
# actionable pointer to docs/cmux-backend.md instead of retry-looping. A
# launch that never becomes reachable also names the `off` mode (socket
# listener disabled entirely - no listener ever comes up, no matter how long
# the app has been running), since that is indistinguishable from a slow
# launch on the wire.
fm_backend_cmux_ensure_running() {
  local state i
  state=$(fm_backend_cmux_ping_state)
  case "$state" in
    ok) return 0 ;;
    denied)
      fm_backend_cmux_refuse_denied
      return 1
      ;;
    unauth)
      fm_backend_cmux_refuse_unauth
      return 1
      ;;
  esac
  open -a cmux >/dev/null 2>&1 || { echo "error: failed to launch cmux ('open -a cmux' failed)" >&2; return 1; }
  for i in $(seq 1 20); do
    state=$(fm_backend_cmux_ping_state)
    case "$state" in
      ok) return 0 ;;
      denied)
        fm_backend_cmux_refuse_denied
        return 1
        ;;
      unauth)
        fm_backend_cmux_refuse_unauth
        return 1
        ;;
    esac
    sleep 0.5
  done
  echo "error: cmux did not become reachable within 10s of launch. If the app is already running, its Socket Control Mode may be 'Off' (no control socket at all) - set it to 'Automation mode' (recommended) in Settings > Automation, see docs/cmux-backend.md 'Setup'." >&2
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
# relocation is already outside the supported recovery contract. Derivation
# itself lives in bin/fm-backend-hometag-lib.sh, shared with zellij's
# identical shared-namespace collision fix (docs/zellij-backend.md
# "Home-scoped tab titles").
fm_backend_cmux_home_label() {
  fm_backend_hometag
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

fm_backend_cmux_provider_id_valid() {
  local provider_id=${1:-}
  [ -n "$provider_id" ] || return 1
  case "$provider_id" in
    *' '*|*'='*|*':'*) return 1 ;;
  esac
  if LC_ALL=C printf '%s' "$provider_id" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return 1
  fi
  return 0
}

fm_backend_cmux_workspace_id_valid() {
  fm_backend_cmux_provider_id_valid "$1"
}

fm_backend_cmux_all_workspace_inventory() {
  local wins wid wss count workspace_id title
  wins=$(fm_backend_cmux_cli list-windows --json --id-format uuids 2>/dev/null) || return 1
  printf '%s' "$wins" | jq -s -e '
    def valid_id:
      if type != "string" then false
      elif length == 0 then false
      else test("^[^[:cntrl:] =:]+$")
      end;
    if length != 1 then
      error("expected one cmux window list response")
    elif (.[0] | type) != "array" then
      error("cmux window list response is not an array")
    elif any(.[0][]?; (type != "object") or ((.id | valid_id) | not)) then
      error("cmux window list response has an invalid window")
    elif ([.[0][] | .id] | unique | length) != (.[0] | length) then
      error("cmux window list response has duplicate window ids")
    else
      true
    end
  ' >/dev/null 2>&1 || return 1
  while IFS= read -r wid; do
    [ -n "$wid" ] || continue
    fm_backend_cmux_workspace_id_valid "$wid" || return 1
    wss=$(fm_backend_cmux_cli workspace list --json --id-format uuids --window "$wid" 2>/dev/null) || return 1
    printf '%s' "$wss" | jq -s -e '
      def valid_id:
        if type != "string" then false
        elif length == 0 then false
        else test("^[^[:cntrl:] =:]+$")
        end;
      def valid_title:
        if type != "string" then false
        else (test("[[:cntrl:]]") | not)
        end;
      if length != 1 then
        error("expected one cmux workspace list response")
      elif (.[0] | type) != "object" then
        error("cmux workspace list response is not an object")
      elif (.[0].workspaces | type) != "array" then
        error("cmux workspace list response has no workspaces array")
      elif any(.[0].workspaces[]?;
        (type != "object")
        or ((.id | valid_id) | not)
        or ((.title | valid_title) | not)) then
        error("cmux workspace list response has an invalid workspace")
      elif ([.[0].workspaces[].id] | unique | length) != (.[0].workspaces | length) then
        error("cmux workspace list response has duplicate workspace ids")
      else
        true
      end
    ' >/dev/null 2>&1 || return 1
    count=$(printf '%s' "$wss" | jq -er '.workspaces | length' 2>/dev/null) || return 1
    while IFS=$'\t' read -r workspace_id title; do
      [ -n "$workspace_id" ] || return 1
      printf '%s\t%s\t%s\t%s\n' "$wid" "$workspace_id" "$title" "$count"
    done < <(printf '%s' "$wss" | jq -r '.workspaces[] | [.id, .title] | @tsv' 2>/dev/null) || return 1
  done < <(printf '%s' "$wins" | jq -r '.[] | .id' 2>/dev/null)
}

fm_backend_cmux_workspace_inventory() {
  local response
  response=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null) || return 1
  printf '%s' "$response" | jq -s -e -c '
    def valid_id:
      if type != "string" then false
      elif length == 0 then false
      else test("^[^[:cntrl:] =:]+$")
      end;
    def valid_title:
      if type != "string" then false
      else (test("[[:cntrl:]]") | not)
      end;
    if length != 1 then
      error("expected one cmux workspace list response")
    elif (.[0] | type) != "object" then
      error("cmux workspace list response is not an object")
    elif (.[0].workspaces | type) != "array" then
      error("cmux workspace list response has no workspaces array")
    else
      .[0].workspaces as $workspaces
      | if any($workspaces[]?;
          (. | type) != "object"
          or ((.id | valid_id) | not)
          or ((.title | valid_title) | not)) then
          error("cmux workspace list response has an invalid workspace")
        elif ([ $workspaces[] | .id ] | unique | length) != ($workspaces | length) then
          error("cmux workspace list response has duplicate workspace ids")
        else
          $workspaces
        end
    end
  ' 2>/dev/null
}

fm_backend_cmux_workspace_ids_for_label() {  # <label>
  local label=$1 inventory ids id
  inventory=$(fm_backend_cmux_workspace_inventory) || return 1
  ids=$(printf '%s' "$inventory" | jq -r --arg want "$label" '.[] | select(.title == $want) | .id' 2>/dev/null) || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    fm_backend_cmux_workspace_id_valid "$id" || return 1
    printf '%s\n' "$id"
  done <<EOF
$ids
EOF
}

fm_backend_cmux_workspace_id_for_label_from_inventory() {  # <inventory> <label>
  local inventory=$1 label=$2 workspace_id
  workspace_id=$(printf '%s' "$inventory" | jq -e -r --arg want "$label" '
    [.[] | select(.title == $want) | .id] as $matches
    | if ($matches | length) == 1 then
        $matches[0]
      else
        error("cmux workspace title is absent or ambiguous")
      end
  ' 2>/dev/null) || return 1
  fm_backend_cmux_workspace_id_valid "$workspace_id" || return 1
  printf '%s' "$workspace_id"
}

fm_backend_cmux_workspace_id_for_label() {  # <label>
  local label=$1 inventory
  inventory=$(fm_backend_cmux_workspace_inventory) || return 1
  fm_backend_cmux_workspace_id_for_label_from_inventory "$inventory" "$label"
}

fm_backend_cmux_workspace_matches_context() {  # <workspace-id> <title>
  local workspace_id=$1 title=$2 wss
  fm_backend_cmux_workspace_id_valid "$workspace_id" || return 1
  wss=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null) || return 1
  printf '%s' "$wss" | jq -s -e --arg id "$workspace_id" --arg title "$title" '
    if length != 1 or (.[0] | type) != "object" or (.[0].workspaces | type) != "array" then
      false
    else
      .[0].workspaces as $workspaces
      | ($workspaces | map(.id)) as $ids
      | if any($workspaces[]?; ((.id | type) != "string") or (.id == "")) then
          false
        elif ($ids | unique | length) != ($ids | length) then
          false
        else
          ([$workspaces[] | select(.id == $id)]) as $matches
          | ($matches | length == 1)
            and (($matches[0].title | type) == "string")
            and ($matches[0].title == $title)
        end
    end
  ' >/dev/null 2>&1
}

fm_backend_cmux_created_workspace_id() {  # <provider-output>
  local output=$1 workspace_id
  workspace_id=$(printf '%s' "$output" | jq -s -e -r '
    if length != 1 then
      error("expected one cmux workspace creation response")
    elif (.[0] | type) != "object" then
      error("cmux workspace creation response is not an object")
    elif (.[0].workspace_id | type) != "string" or (.[0].workspace_id | length) == 0 then
      error("cmux workspace creation response has no workspace_id")
    else
      .[0].workspace_id
    end
  ' 2>/dev/null) || return 1
  fm_backend_cmux_workspace_id_valid "$workspace_id" || return 1
  printf '%s' "$workspace_id"
}

fm_backend_cmux_surface_id_for_workspace() {  # <workspace_id>
  local wsid=$1 response surface_id
  response=$(fm_backend_cmux_cli list-panes --workspace "$wsid" --json --id-format uuids 2>/dev/null) || return 1
  surface_id=$(printf '%s' "$response" | jq -s -e -r '
    def valid_id:
      if type != "string" then false
      elif length == 0 then false
      else test("^[^[:cntrl:] =:]+$")
      end;
    if length != 1 then
      error("expected one cmux list-panes response")
    elif (.[0] | type) != "object" then
      error("cmux list-panes response is not an object")
    elif (.[0].panes | type) != "array" then
      error("cmux list-panes response has no panes array")
    elif (.[0].panes | length) != 1 then
      error("cmux list-panes response does not identify exactly one pane")
    else
      .[0].panes[0] as $pane
      | if ($pane | type) != "object" then
          error("cmux list-panes pane is not an object")
        elif ($pane | has("selected_surface_id")) then
          if (($pane.selected_surface_id | valid_id) | not) then
            error("cmux list-panes response has an invalid selected surface id")
          elif ($pane | has("surface_ids")) then
            if (($pane.surface_ids | type) != "array") then
              error("cmux list-panes response has an invalid surface id list")
            elif ($pane.surface_ids | length) != 1 then
              error("cmux list-panes response does not identify exactly one surface")
            elif ($pane.surface_ids[0] != $pane.selected_surface_id) then
              error("cmux list-panes response has conflicting surface ids")
            elif (($pane.surface_ids[0] | valid_id) | not) then
              error("cmux list-panes response has an invalid surface id")
            else
              $pane.selected_surface_id
            end
          else
            $pane.selected_surface_id
          end
        elif ($pane | has("surface_ids")) then
          if (($pane.surface_ids | type) != "array") then
            error("cmux list-panes response has an invalid surface id list")
          elif ($pane.surface_ids | length) != 1 then
            error("cmux list-panes response does not identify exactly one surface")
          elif (($pane.surface_ids[0] | valid_id) | not) then
            error("cmux list-panes response has an invalid surface id")
          else
            $pane.surface_ids[0]
          end
        else
          error("cmux list-panes response has no surface id")
        end
    end
  ' 2>/dev/null) || return 1
  fm_backend_cmux_provider_id_valid "$surface_id" || return 1
  printf '%s' "$surface_id"
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
fm_backend_cmux_acquisition_record_path() {
  local file=$1 absolute cwd parent base parent_real
  [ -n "$file" ] || return 1
  case "$file" in
    -* ) file=./$file ;;
  esac
  case "$file" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  case "$file" in
    /*) absolute=$file ;;
    *)
      cwd=$(CDPATH='' pwd -P) || return 1
      absolute="$cwd/${file#./}"
      ;;
  esac
  parent=${absolute%/*}
  base=${absolute##*/}
  [ -n "$parent" ] || parent=/
  case "$base" in ''|.|..) return 1 ;; esac
  if [ -e "$absolute" ] || [ -L "$absolute" ]; then
    [ ! -L "$absolute" ] || return 1
  fi
  [ -d "$parent" ] || return 1
  parent_real=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P) || return 1
  absolute="$parent_real/$base"
  if [ -e "$absolute" ] || [ -L "$absolute" ]; then
    [ -f "$absolute" ] && [ ! -L "$absolute" ] || return 1
  fi
  printf '%s\n' "$absolute"
}

fm_backend_cmux_acquisition_identity() {
  local path=$1
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i' "$path" 2>/dev/null
  else
    stat -c '%d:%i' "$path" 2>/dev/null
  fi
}

fm_backend_cmux_acquisition_record_write() {
  local requested_file=$1 kind=$2 file parent parent_identity target_identity target_state
  local label workspace_id surface_id title workspace_candidate_id
  shift 2
  file=$(fm_backend_cmux_acquisition_record_path "$requested_file") || return 1
  parent=${file%/*}
  parent_identity=$(fm_backend_cmux_acquisition_identity "$parent") || return 1
  target_state=absent
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    target_state=present
    target_identity=$(fm_backend_cmux_acquisition_identity "$file") || return 1
  fi
  (
    staged=
    cleanup() {
      [ -z "$staged" ] || rm -f "$staged"
    }
    trap 'cleanup' EXIT
    trap 'cleanup; exit 1' HUP INT TERM
    staged=$(umask 077; mktemp "$parent/.fm-cmux-acquisition.XXXXXX") || exit 1
    staged_identity=$(fm_backend_cmux_acquisition_identity "$staged") || exit 1
    case "$kind" in
      exact)
        label=$1
        workspace_id=$2
        surface_id=${3:-}
        printf 'backend=cmux\nkind=%s\nworkspace_id=%s\nsurface_id=%s\nlabel=%s\n' \
          "$([ -n "$surface_id" ] && printf target || printf cmux-workspace)" \
          "$workspace_id" "$surface_id" "$label" > "$staged" || exit 1
        ;;
      unresolved)
        label=$1
        title=$2
        workspace_candidate_id=${3:-}
        if [ -n "$workspace_candidate_id" ]; then
          fm_backend_cmux_workspace_id_valid "$workspace_candidate_id" || exit 1
          printf 'backend=cmux\nkind=cmux-unresolved\nworkspace_id=\nsurface_id=\nlabel=%s\nworkspace_title=%s\nworkspace_candidate_id=%s\nreason=workspace-identity-unresolved\n' \
            "$label" "$title" "$workspace_candidate_id" > "$staged" || exit 1
        else
          printf 'backend=cmux\nkind=cmux-unresolved\nworkspace_id=\nsurface_id=\nlabel=%s\nworkspace_title=%s\nreason=workspace-identity-unresolved\n' \
            "$label" "$title" > "$staged" || exit 1
        fi
        ;;
      *) exit 1 ;;
    esac
    chmod 600 "$staged" || exit 1
    [ -f "$staged" ] && [ ! -L "$staged" ] || exit 1
    current_staged_identity=$(fm_backend_cmux_acquisition_identity "$staged") || exit 1
    [ "$current_staged_identity" = "$staged_identity" ] || exit 1
    current_file=$(fm_backend_cmux_acquisition_record_path "$requested_file") || exit 1
    [ "$current_file" = "$file" ] || exit 1
    current_parent_identity=$(fm_backend_cmux_acquisition_identity "$parent") || exit 1
    [ "$current_parent_identity" = "$parent_identity" ] || exit 1
    case "$target_state" in
      present)
        [ -f "$file" ] && [ ! -L "$file" ] || exit 1
        current_target_identity=$(fm_backend_cmux_acquisition_identity "$file") || exit 1
        [ "$current_target_identity" = "$target_identity" ] || exit 1
        ;;
      absent)
        [ ! -e "$file" ] && [ ! -L "$file" ] || exit 1
        ;;
      *) exit 1 ;;
    esac
    staged_parent=${staged%/*}
    [ "$(CDPATH='' cd -- "$staged_parent" 2>/dev/null && pwd -P)" = "$parent" ] || exit 1
    mv -f "$staged" "$file" || exit 1
    staged=
    trap - EXIT HUP INT TERM
  )
}

fm_backend_cmux_acquisition_record() {
  local file=${FM_BACKEND_ACQUISITION_FILE:-} label=$1 workspace_id=$2 surface_id=${3:-}
  fm_backend_cmux_provider_id_valid "$workspace_id" || return 1
  if [ -n "$surface_id" ]; then
    fm_backend_cmux_provider_id_valid "$surface_id" || return 1
  fi
  [ -n "$file" ] || return 0
  fm_backend_cmux_acquisition_record_write "$file" exact "$label" "$workspace_id" "$surface_id"
}

fm_backend_cmux_unresolved_acquisition_record() {
  local file=${FM_BACKEND_ACQUISITION_FILE:-} label=$1 title=$2 workspace_candidate_id=${3:-}
  [ -n "$file" ] || return 0
  fm_backend_cmux_acquisition_record_write "$file" unresolved "$label" "$title" "$workspace_candidate_id"
}

fm_backend_cmux_create_task() {  # <label> <cwd>
  local label=$1 cwd=$2 title before_ids out wsid sfid create_status
  title=$(fm_backend_cmux_scoped_title "$label")
  before_ids=$(fm_backend_cmux_workspace_ids_for_label "$title") || {
    echo "error: could not inspect existing cmux workspaces for '$title'" >&2
    return 1
  }
  if [ -n "$before_ids" ]; then
    echo "error: cmux workspace '$title' already exists" >&2
    return 1
  fi
  if out=$(fm_backend_cmux_cli new-workspace --name "$title" --cwd "$cwd" --focus false --id-format uuids --json 2>&1); then
    create_status=0
  else
    create_status=$?
  fi
  if ! wsid=$(fm_backend_cmux_created_workspace_id "$out"); then
    if ! fm_backend_cmux_unresolved_acquisition_record "$label" "$title"; then
      echo "error: cmux new-workspace failed for '$title' without a provable workspace identity or an unresolved acquisition record" >&2
    else
      echo "error: cmux new-workspace failed for '$title' without a provable workspace identity; retaining a non-destructive unresolved acquisition record" >&2
    fi
    printf 'cmux-unresolved\n'
    return 1
  fi
  if ! fm_backend_cmux_workspace_matches_context "$wsid" "$title"; then
    if ! fm_backend_cmux_unresolved_acquisition_record "$label" "$title" "$wsid"; then
      echo "error: could not prove the new cmux workspace identity or persist an unresolved acquisition record for '$title'" >&2
    else
      echo "error: could not prove the new cmux workspace identity for '$title'; retaining a non-destructive unresolved acquisition record" >&2
    fi
    printf 'cmux-unresolved\n'
    return 1
  fi
  if ! fm_backend_cmux_acquisition_record "$label" "$wsid"; then
    printf '%s\n' "$wsid"
    return 1
  fi
  if [ "$create_status" -ne 0 ]; then
    echo "error: cmux new-workspace reported failure after returning verified workspace '$wsid'; retaining its exact cleanup identity" >&2
    printf '%s\n' "$wsid"
    return 1
  fi
  sfid=$(fm_backend_cmux_surface_id_for_workspace "$wsid")
  [ -n "$sfid" ] || { echo "error: could not resolve the default surface for cmux workspace '$title' ($wsid)" >&2; return 1; }
  if ! fm_backend_cmux_acquisition_record "$label" "$wsid" "$sfid"; then
    printf '%s %s\n' "$wsid" "$sfid"
    return 1
  fi
  printf '%s %s' "$wsid" "$sfid"
}

# fm_backend_cmux_parse_target: split "<workspace_uuid>:<surface_uuid>" on the
# FIRST colon (neither UUID contains a colon, so this is unambiguous). Sets
# FM_BACKEND_CMUX_WORKSPACE and FM_BACKEND_CMUX_SURFACE for the caller.
fm_backend_cmux_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_CMUX_WORKSPACE=${target%%:*}
  FM_BACKEND_CMUX_SURFACE=${target#*:}
  [ -n "$FM_BACKEND_CMUX_WORKSPACE" ] && [ -n "$FM_BACKEND_CMUX_SURFACE" ] && [ "$FM_BACKEND_CMUX_SURFACE" != "$target" ] \
    || return 1
  fm_backend_cmux_provider_id_valid "$FM_BACKEND_CMUX_WORKSPACE" \
    && fm_backend_cmux_provider_id_valid "$FM_BACKEND_CMUX_SURFACE"
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
  local wsid=$1 sfid=$2 response
  fm_backend_cmux_workspace_id_valid "$wsid" || return 1
  fm_backend_cmux_provider_id_valid "$sfid" || return 1
  response=$(fm_backend_cmux_cli list-panes --workspace "$wsid" --json --id-format uuids 2>/dev/null) || return 1
  printf '%s' "$response" | jq -s -e --arg s "$sfid" '
    def valid_id:
      if type != "string" then false
      elif length == 0 then false
      else test("^[^[:cntrl:] =:]+$")
      end;
    if length != 1 or (.[0] | type) != "object" then
      false
    elif (.[0].panes | type) != "array" then
      false
    else
      .[0].panes as $panes
      | if any($panes[]?;
          (type != "object")
          or ((.surface_ids | type) != "array")
          or ((.surface_ids | length) == 0)
          or (any(.surface_ids[]?; (valid_id | not)))
          or ((.surface_ids | unique | length) != (.surface_ids | length))
          or (has("selected_surface_id") and ((.selected_surface_id | valid_id) | not))
          or (has("selected_surface_id") and (. as $pane | ($pane.surface_ids | index($pane.selected_surface_id)) == null))
          or (has("pane_id") and ((.pane_id | valid_id) | not))
          or (has("workspace_id") and ((.workspace_id | valid_id) | not))
          or (has("tab_id") and ((.tab_id | valid_id) | not))
        ) then
          false
        elif ([$panes[] | .surface_ids[]] | unique | length)
             != ([$panes[] | .surface_ids[]] | length) then
          false
        else
          ([$panes[] | .surface_ids[] | select(. == $s)] | length) == 1
        end
    end
  ' >/dev/null 2>&1
}

fm_backend_cmux_recovery_meta_path() {
  local expected_label=$1 id state state_real
  case "$expected_label" in
    fm-*) id=${expected_label#fm-} ;;
    *) return 1 ;;
  esac
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  [ -d "$state" ] || return 1
  state_real=$(CDPATH='' cd -P "$state" 2>/dev/null && pwd -P) || return 1
  [ -f "$state_real/$id.meta" ] && [ ! -L "$state_real/$id.meta" ] || return 1
  printf '%s/%s.meta' "$state_real" "$id"
}

fm_backend_cmux_recovery_meta_value() {
  local meta=$1 key=$2 count value
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^$key=" "$meta" 2>/dev/null | cut -d= -f2-) || return 1
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  printf '%s' "$value"
}

fm_backend_cmux_recovery_meta_matches() {
  local expected_label=$1 workspace_id=$2 surface_id=$3 meta id
  fm_backend_cmux_workspace_id_valid "$workspace_id" || return 1
  fm_backend_cmux_provider_id_valid "$surface_id" || return 1
  meta=$(fm_backend_cmux_recovery_meta_path "$expected_label") || return 1
  id=${expected_label#fm-}
  [ "$(fm_backend_cmux_recovery_meta_value "$meta" backend)" = cmux ] || return 1
  [ "$(fm_backend_cmux_recovery_meta_value "$meta" endpoint_task_id)" = "$id" ] || return 1
  [ "$(fm_backend_cmux_recovery_meta_value "$meta" window)" = "$workspace_id:$surface_id" ] || return 1
  [ "$(fm_backend_cmux_recovery_meta_value "$meta" cmux_workspace_id)" = "$workspace_id" ] || return 1
  [ "$(fm_backend_cmux_recovery_meta_value "$meta" cmux_surface_id)" = "$surface_id" ] || return 1
}

fm_backend_cmux_persist_recovered_target() {
  local expected_label=$1 old_workspace=$2 old_surface=$3 new_workspace=$4 new_surface=$5
  local meta id parent lock
  fm_backend_cmux_workspace_id_valid "$old_workspace" || return 1
  fm_backend_cmux_provider_id_valid "$old_surface" || return 1
  fm_backend_cmux_workspace_id_valid "$new_workspace" || return 1
  fm_backend_cmux_provider_id_valid "$new_surface" || return 1
  meta=$(fm_backend_cmux_recovery_meta_path "$expected_label") || return 1
  fm_backend_cmux_recovery_meta_matches "$expected_label" "$old_workspace" "$old_surface" || return 1
  if ! declare -F fm_meta_lock_path >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_BACKEND_CMUX_ROOT/bin/fm-wake-lib.sh" || return 1
  fi
  lock=$(fm_meta_lock_path "$meta") || return 1
  parent=${meta%/*}
  id=${expected_label#fm-}
  (
    local staged= lock_held=0 original_identity current_identity
    cleanup() {
      [ -z "$staged" ] || rm -f "$staged"
      [ "$lock_held" = 1 ] && fm_lock_release "$lock" || true
    }
    trap 'cleanup' EXIT HUP INT TERM
    fm_lock_acquire_wait "$lock" || exit 1
    lock_held=1
    [ -f "$meta" ] && [ ! -L "$meta" ] || exit 1
    fm_backend_cmux_recovery_meta_matches "$expected_label" "$old_workspace" "$old_surface" || exit 1
    original_identity=$(fm_backend_cmux_acquisition_identity "$meta") || exit 1
    staged=$(umask 077; mktemp "$parent/.$id.cmux-meta.XXXXXX") || exit 1
    if ! { grep -vE '^(window|cmux_workspace_id|cmux_surface_id)=' "$meta" || true; } > "$staged"; then
      exit 1
    fi
    printf 'window=%s:%s\ncmux_workspace_id=%s\ncmux_surface_id=%s\n' \
      "$new_workspace" "$new_surface" "$new_workspace" "$new_surface" >> "$staged" || exit 1
    chmod 600 "$staged" || exit 1
    [ -f "$staged" ] && [ ! -L "$staged" ] || exit 1
    current_identity=$(fm_backend_cmux_acquisition_identity "$meta") || exit 1
    [ "$current_identity" = "$original_identity" ] || exit 1
    mv -f "$staged" "$meta" || exit 1
    staged=
    fm_lock_release "$lock" || exit 1
    lock_held=0
    trap - EXIT HUP INT TERM
  )
}

# fm_backend_cmux_target_ready: parse the target and verify it is live via
# fm_backend_cmux_surface_exists (never read-screen - see that function's
# header for the fresh-surface pitfall this avoids). When the caller knows
# the owning firstmate task label, refresh stale workspace/surface ids by label.
fm_backend_cmux_target_ready() {  # <target> [expected-label]
  local expected_label=${2:-} expected_title wsid sfid recorded_workspace recorded_surface
  fm_backend_cmux_parse_target "$1" || return 1
  if [ -n "$expected_label" ]; then
    expected_title=$(fm_backend_cmux_scoped_title "$expected_label")
    recorded_workspace=$FM_BACKEND_CMUX_WORKSPACE
    recorded_surface=$FM_BACKEND_CMUX_SURFACE
    fm_backend_cmux_target_workspace_for_label "$recorded_workspace" "$expected_title" || return 1
    wsid=$FM_BACKEND_CMUX_EXACT_WORKSPACE
    if [ "$wsid" = "$recorded_workspace" ] \
       && fm_backend_cmux_surface_exists "$wsid" "$recorded_surface"; then
      return 0
    fi
    sfid=$(fm_backend_cmux_surface_id_for_workspace "$wsid")
    [ -n "$sfid" ] || return 1
    if ! fm_backend_cmux_persist_recovered_target \
      "$expected_label" "$recorded_workspace" "$recorded_surface" "$wsid" "$sfid"; then
      fm_backend_cmux_recovery_meta_matches "$expected_label" "$wsid" "$sfid" || return 1
    fi
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
    # C-u clears a composer line. fm-send.sh's muse interrupt path needs it to
    # drop the prompt muse restores into the composer after Escape.
    C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u) printf 'ctrl-u' ;;
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

# fm_backend_cmux_send_text_line: send one line of TEXT then submit.
fm_backend_cmux_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_cmux_send_literal "$1" "$2" "${3:-}" || return 1
  fm_backend_cmux_send_key "$1" Enter "${3:-}" && return 0
  fm_backend_cmux_send_key "$1" C-c "${3:-}" >/dev/null 2>&1 && return 1
  return 2
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

# fm_backend_cmux_composer_capture: the cmux composer screen - a bounded
# plain-text tail of the surface. cmux's `read-screen` is plain text by
# construction (its --help: "Read terminal text from a surface as plain
# text"), which is why the capability descriptor below declares styled=0: the
# shared classifier then degrades a glyph row carrying trailing text to
# `unknown` instead of misreading an idle suggestion as unsent input.
fm_backend_cmux_composer_capture() {  # <target> [expected-label]
  fm_backend_cmux_capture "$1" "$FM_COMPOSER_CAPTURE_LINES" "${2:-}"
}

# fm_backend_cmux_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh).
fm_backend_cmux_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_cmux_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (including the borderless claude row this
# adapter once carried its own NBSP workaround for) lives in
# bin/fm-composer-lib.sh, so a new harness shape is taught there once and
# never here. cmux has no identity probe, so the classifier's identity
# sentinel resolves to unknown.
fm_backend_cmux_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_cmux_composer_capture "$1" "${2:-}") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_cmux_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_cmux_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then drive the shared verify-and-retry-Enter
# loop (bin/fm-composer-lib.sh: fm_composer_submit_retry_core) against the
# shared composer verdict. Echoes empty|pending|unknown|send-failed, a subset
# of the proof-carrying submit vocabulary.
fm_backend_cmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-}
  fm_backend_cmux_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_cmux_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_cmux_send_key fm_backend_cmux_composer_state \
    "$target" "$retries" "$sleep_s" "$expected_label"
}

fm_backend_cmux_workspace_exact_location() {  # <workspace_id>
  local wsid=$1 inventory window_id workspace_id title count match_count=0
  FM_BACKEND_CMUX_EXACT_WINDOW=
  FM_BACKEND_CMUX_EXACT_COUNT=
  FM_BACKEND_CMUX_EXACT_TITLE=
  FM_BACKEND_CMUX_EXACT_WORKSPACE=
  fm_backend_cmux_workspace_id_valid "$wsid" || return 1
  inventory=$(fm_backend_cmux_all_workspace_inventory) || return 1
  while IFS=$'\t' read -r window_id workspace_id title count; do
    [ -n "$window_id" ] || continue
    if [ "$workspace_id" = "$wsid" ]; then
      match_count=$((match_count + 1))
      [ "$match_count" -eq 1 ] || return 1
      FM_BACKEND_CMUX_EXACT_WORKSPACE=$workspace_id
      FM_BACKEND_CMUX_EXACT_WINDOW=$window_id
      FM_BACKEND_CMUX_EXACT_COUNT=$count
      FM_BACKEND_CMUX_EXACT_TITLE=$title
    fi
  done <<< "$inventory"
  [ "$match_count" -eq 1 ] && return 0
  return 2
}

fm_backend_cmux_workspace_exact_location_for_title() {
  local expected_title=$1 inventory window_id workspace_id title count match_count=0 identity_count=0
  [ -n "$expected_title" ] || return 1
  if LC_ALL=C printf '%s' "$expected_title" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return 1
  fi
  FM_BACKEND_CMUX_EXACT_WINDOW=
  FM_BACKEND_CMUX_EXACT_COUNT=
  FM_BACKEND_CMUX_EXACT_TITLE=
  FM_BACKEND_CMUX_EXACT_WORKSPACE=
  inventory=$(fm_backend_cmux_all_workspace_inventory) || return 1
  while IFS=$'\t' read -r window_id workspace_id title count; do
    [ -n "$window_id" ] || continue
    if [ "$title" = "$expected_title" ]; then
      match_count=$((match_count + 1))
      [ "$match_count" -eq 1 ] || return 1
      fm_backend_cmux_workspace_id_valid "$workspace_id" || return 1
      FM_BACKEND_CMUX_EXACT_WORKSPACE=$workspace_id
      FM_BACKEND_CMUX_EXACT_WINDOW=$window_id
      FM_BACKEND_CMUX_EXACT_COUNT=$count
      FM_BACKEND_CMUX_EXACT_TITLE=$title
    fi
  done <<< "$inventory"
  [ "$match_count" -eq 1 ] || return 2
  while IFS=$'\t' read -r window_id workspace_id title count; do
    [ -n "$window_id" ] || continue
    [ "$workspace_id" = "$FM_BACKEND_CMUX_EXACT_WORKSPACE" ] \
      && identity_count=$((identity_count + 1))
  done <<< "$inventory"
  [ "$identity_count" -eq 1 ] || return 1
  return 0
}

fm_backend_cmux_target_workspace_for_label() {  # <recorded-workspace-id> <expected-title>
  local recorded_workspace=$1 expected_title=$2 inventory window_id workspace_id title count
  local exact_count=0 title_count=0 identity_count=0 exact_title=
  local title_workspace= title_window= title_count_value=
  FM_BACKEND_CMUX_EXACT_WINDOW=
  FM_BACKEND_CMUX_EXACT_COUNT=
  FM_BACKEND_CMUX_EXACT_TITLE=
  FM_BACKEND_CMUX_EXACT_WORKSPACE=
  fm_backend_cmux_workspace_id_valid "$recorded_workspace" || return 1
  [ -n "$expected_title" ] || return 1
  if LC_ALL=C printf '%s' "$expected_title" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return 1
  fi
  inventory=$(fm_backend_cmux_all_workspace_inventory) || return 1
  while IFS=$'\t' read -r window_id workspace_id title count; do
    [ -n "$window_id" ] || continue
    if [ "$workspace_id" = "$recorded_workspace" ]; then
      exact_count=$((exact_count + 1))
      [ "$exact_count" -eq 1 ] || return 1
      exact_title=$title
      FM_BACKEND_CMUX_EXACT_WORKSPACE=$workspace_id
      FM_BACKEND_CMUX_EXACT_WINDOW=$window_id
      FM_BACKEND_CMUX_EXACT_COUNT=$count
    fi
    if [ "$title" = "$expected_title" ]; then
      title_count=$((title_count + 1))
      [ "$title_count" -eq 1 ] || return 1
      title_workspace=$workspace_id
      title_window=$window_id
      title_count_value=$count
    fi
  done <<< "$inventory"
  if [ "$exact_count" -eq 1 ]; then
    [ "$exact_title" = "$expected_title" ] || return 1
    FM_BACKEND_CMUX_EXACT_TITLE=$exact_title
    return 0
  fi
  [ "$title_count" -eq 1 ] || return 1
  while IFS=$'\t' read -r window_id workspace_id title count; do
    [ -n "$window_id" ] || continue
    [ "$workspace_id" = "$title_workspace" ] && identity_count=$((identity_count + 1))
  done <<< "$inventory"
  [ "$identity_count" -eq 1 ] || return 1
  FM_BACKEND_CMUX_EXACT_WORKSPACE=$title_workspace
  FM_BACKEND_CMUX_EXACT_WINDOW=$title_window
  FM_BACKEND_CMUX_EXACT_COUNT=$title_count_value
  FM_BACKEND_CMUX_EXACT_TITLE=$expected_title
}

# fm_backend_cmux_window_of_workspace: echo "<window_id> <workspace_count>" for
# the window that contains <workspace_id>, or nothing if it is not found live.
# `workspace list --json` with no `--window` is scoped to the CURRENT window
# only (verified live), so the containing window is found by walking every
# window from `list-windows --json` and asking each for its own scoped list.
# The count comes from the same scoped workspace list that confirms membership.
fm_backend_cmux_window_of_workspace() {  # <workspace_id> -> "<window_id> <count>"
  if fm_backend_cmux_workspace_exact_location "$1"; then
    printf '%s %s' "$FM_BACKEND_CMUX_EXACT_WINDOW" "$FM_BACKEND_CMUX_EXACT_COUNT"
  fi
  return 0
}

# fm_backend_cmux_kill: remove the task's whole workspace, best-effort (mirrors
# every other backend's `kill` `|| true` contract). A cmux task owns one
# workspace, so teardown reclaims that workspace and all of its surfaces.
#
# The selected-workspace teardown bug (docs/cmux-backend.md "Closing the last
# workspace in a window"): cmux keeps every window at >=1 workspace, so
# `close-workspace` on the ONLY workspace in its window silently no-ops - it
# still returns `OK`, but the workspace stays, which is exactly what left a
# selected task workspace open at teardown (the last workspace in a window is
# always the selected one). `close-window`/`window.close` cannot rescue it
# either: a window holding a live terminal session cannot be closed over the
# control socket (verified: returns success-shaped output, closes nothing).
# The reliable primitive is close-workspace on a NON-last workspace, so when the
# target is the last one in its window a throwaway sibling is created first,
# leaving that window a fresh default workspace (never an fm-<home>- title, so
# recovery/list_live ignore it) - cmux's own "closed the last tab" outcome.
fm_backend_cmux_kill() {  # <target> [unused] [expected-label]
  local expected_label=${3:-} wsid wininfo win count
  if [ -n "$expected_label" ]; then
    fm_backend_cmux_target_ready "$1" "$expected_label" || return 0
  else
    fm_backend_cmux_parse_target "$1" || return 0
  fi
  wsid=$FM_BACKEND_CMUX_WORKSPACE
  wininfo=$(fm_backend_cmux_window_of_workspace "$wsid")
  win=${wininfo%% *}
  count=${wininfo##* }
  if [ -n "$win" ] && [ "$count" = 1 ]; then
    fm_backend_cmux_cli new-workspace --window "$win" --focus false --id-format uuids >/dev/null 2>&1 || true
  fi
  fm_backend_cmux_cli close-workspace --workspace "$wsid" >/dev/null 2>&1 || true
}

fm_backend_cmux_kill_workspace_exact() {  # <workspace-id> <expected-label>
  local wsid=$1 expected_label=$2 location_rc
  if fm_backend_cmux_workspace_exact_location "$wsid"; then
    fm_backend_cmux_kill_workspace_exact_at_location "$wsid" "$expected_label"
    return $?
  else
    location_rc=$?
    [ "$location_rc" -eq 2 ] && return 0
    return 1
  fi
}

fm_backend_cmux_kill_workspace_exact_at_location() {
  local wsid=$1 expected_label=$2 expected_title title win count location_rc
  expected_title=$(fm_backend_cmux_scoped_title "$expected_label")
  [ "$FM_BACKEND_CMUX_EXACT_WORKSPACE" = "$wsid" ] || return 1
  title=$FM_BACKEND_CMUX_EXACT_TITLE
  win=$FM_BACKEND_CMUX_EXACT_WINDOW
  count=$FM_BACKEND_CMUX_EXACT_COUNT
  [ "$title" = "$expected_title" ] || return 1
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  if [ -n "$win" ] && [ "$count" = 1 ]; then
    fm_backend_cmux_cli new-workspace --window "$win" --focus false --id-format uuids >/dev/null 2>&1 || true
  fi
  fm_backend_cmux_cli close-workspace --workspace "$wsid" >/dev/null 2>&1 || return 1
  if fm_backend_cmux_workspace_exact_location "$wsid"; then
    return 1
  else
    location_rc=$?
  fi
  [ "$location_rc" -eq 2 ]
}

fm_backend_cmux_kill_published() {
  local target=${1:-} expected_label=${2:-} location_rc expected_title
  [ -n "$expected_label" ] || return 1
  fm_backend_cmux_parse_target "$target" || return 1
  if fm_backend_cmux_workspace_exact_location "$FM_BACKEND_CMUX_WORKSPACE"; then
    fm_backend_cmux_kill_workspace_exact_at_location "$FM_BACKEND_CMUX_WORKSPACE" "$expected_label"
    return $?
  else
    location_rc=$?
  fi
  [ "$location_rc" -eq 2 ] || return 1
  expected_title=$(fm_backend_cmux_scoped_title "$expected_label")
  fm_backend_cmux_workspace_exact_location_for_title "$expected_title" || return 1
  fm_backend_cmux_kill_workspace_exact_at_location "$FM_BACKEND_CMUX_EXACT_WORKSPACE" "$expected_label"
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
