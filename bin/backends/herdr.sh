#!/usr/bin/env bash
# bin/backends/herdr.sh - the herdr session-provider adapter (EXPERIMENTAL).
#
# Design: data/fm-backend-design-d7/herdr-addendum.md ("Interface mapping",
# decisions D1-D6) and the empirical verification recorded in
# data/fm-backend-design-d7/herdr-verification-p2.md (real herdr v0.7.1,
# protocol 14, macOS aarch64), refined by docs/herdr-backend.md's
# "workspace-per-home" pass (AGENTS.md task herdr-sm-spaces-k4). Herdr is a
# session provider ONLY (D3): the worktree provider stays treehouse, exactly
# like tmux. Sourced only through bin/fm-backend.sh's fm_backend_source in
# normal operation; the unit tests source it directly, so the FM_HOME fallback
# below keeps that path sane without fm-backend.sh's preamble.
#
# Default container shape (D4, decided empirically - see
# herdr-verification-p2.md "Task container shape", refined by
# docs/herdr-backend.md "Default task container shape"): ONE herdr workspace PER
# FIRSTMATE HOME (the primary, and each secondmate, gets its own), ONE herdr TAB
# per task inside its home's workspace.
# Target resolution stays parallel to the tmux adapter.
#
# Target string shape: "<herdr-session>:<pane-id>", e.g. "default:w1:p2" (the
# pane id itself contains a colon; the session is always the FIRST field, the
# remainder is the whole pane id - fm_backend_herdr_parse_target splits on the
# first colon only). This is the value stored in a herdr task's meta window=
# field and is what fm_backend_resolve_selector already returns unchanged for
# exact task-id, legacy fm-<id>, and explicit backend-target forms (that
# function has no herdr-specific logic; it just returns meta's window=
# verbatim).
#
# Authoritative task recovery/orphan discovery (ids may not deterministically match live state
# after a server restart in a differently-configured session; see the
# verification doc) uses LABEL matching (fm-<id> tab labels), never trusts a
# stored pane id blindly: fm_backend_herdr_list_live.
#
# Requires: herdr (CLI + socket), jq (JSON parsing). Bootstrap detects these
# through fm_backend_required_tools only when herdr is the resolved backend;
# this adapter also gates them again before spawning.

# FM_HOME fallback: every real caller (fm-spawn.sh, fm-peek.sh, fm-send.sh,
# fm-teardown.sh, fm-watch.sh, fm-crew-state.sh) already sets FM_HOME as a
# global before sourcing fm-backend.sh (which sources this file), so this
# never overrides a real invocation. It exists only so this file's own unit
# tests, which source it directly without that preamble, resolve to a sane
# default (the firstmate repo root - never a secondmate home, so
# fm_backend_herdr_workspace_label falls through to "firstmate" exactly like
# pre-P3 behavior when a test does not care about home-specific labeling).
FM_BACKEND_HERDR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_HERDR_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_HERDR_ROOT/bin/fm-composer-lib.sh"

# Shared, backend-neutral normalized-transition shape and the single-owner
# status->action policy table (bin/fm-transition-lib.sh). This adapter's event
# subscriber (fm_backend_herdr_wait_transition) normalizes every
# pane.agent_status_changed edge through fm_transition_record and routes it
# through fm_transition_policy - it never re-encodes the mapping.
# shellcheck source=bin/fm-transition-lib.sh
. "$FM_BACKEND_HERDR_ROOT/bin/fm-transition-lib.sh"

FM_BACKEND_HERDR_MIN_PROTOCOL=14
# events.subscribe (the native pane.agent_status_changed push stream) and its
# subscription_event schema first shipped at protocol 16 (verified: herdr
# 0.7.3). Below this, or with the events surface absent from `herdr api schema`,
# the event fast-path fails closed to the watcher's poll loop
# (fm_backend_herdr_events_capable). Distinct from FM_BACKEND_HERDR_MIN_PROTOCOL
# (14): the adapter's spawn/capture/send primitives work on 14, only the push
# subscriber needs 16.
FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL=16
# Per-pane escalation dedupe marker prefix, under the state dir. One marker per
# window (keyed like the watcher's own .stale-<key>): set when a ->blocked edge
# is enqueued, cleared on any working edge, so exactly one wake fires per
# ->blocked edge and a reconnect level-reconcile never re-delivers a still-
# blocked pane. Mirrors bin/fm-watch.sh's .stale-<key> naming.
FM_BACKEND_HERDR_ESCALATED_PREFIX=".herdr-escalated-"
# .fm-secondmate-home is written by bin/fm-home-seed.sh (AGENTS.md section 6)
# at a seeded secondmate home's root, containing exactly that secondmate's id.
# The primary firstmate home never carries this marker.
FM_BACKEND_HERDR_SECONDMATE_MARKER=".fm-secondmate-home"
# fm_backend_herdr_workspace_label: the per-firstmate-HOME herdr workspace
# label (docs/herdr-backend.md "Default task container shape"). The PRIMARY home (no
# secondmate marker) resolves to the constant "firstmate", byte-identical to
# every pre-existing task's recorded label - no forced migration. A SECONDMATE
# home resolves to "2ndmate-<secondmate-id>", so its tasks land in their own
# workspace, obviously distinguishable from the primary's (and from every
# other secondmate's) in herdr's spaces sidebar. Read fresh from FM_HOME on
# every call rather than cached at source time: FM_HOME is the home's own
# durable identity, not env plumbing threaded through a call chain, so the
# label is automatically stable across every respawn/recovery for the life of
# that home. fm-spawn.sh briefly shadows FM_HOME to a secondmate's own home
# when the PRIMARY spawns that secondmate (its own process's FM_HOME still
# names the primary at that point) - see fm-spawn.sh's herdr case arm.
fm_backend_herdr_workspace_label() {
  local marker="$FM_HOME/$FM_BACKEND_HERDR_SECONDMATE_MARKER" id
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      printf '2ndmate-%s' "$id"
      return 0
    fi
  fi
  printf 'firstmate'
}

# fm_backend_herdr_cli: run `herdr <args...>` scoped to <session>, setting
# BOTH the HERDR_SESSION env var AND appending a trailing `--session <name>`
# CLI flag. Verified empirically (docs/herdr-backend.md "Session targeting: the
# --session flag, not HERDR_SESSION alone"): on the installed herdr 0.7.1
# client, the HERDR_SESSION env var is NOT reliably honored by CLI subcommands
# once ANY other herdr server is already bound on the machine - queries
# silently fall back to whatever server IS running (the wrong one) instead of
# routing to the requested session or refusing. The `--session <name>` global
# flag (verified in both leading and trailing position; trailing used here to
# keep every call site a minimal, append-only diff) always routes correctly,
# including starting a genuinely separate, isolated server process. The env
# var is kept alongside it - harmless, self-documenting, and forward-
# compatible if a future herdr build honors it. Never used by
# fm_backend_herdr_version_check, which is intentionally session-independent
# (reads only .client.* fields).
fm_backend_herdr_cli() {  # <session> <herdr-subcommand-and-args...>
  local session=$1
  shift
  HERDR_SESSION="$session" herdr "$@" --session "$session"
}

# fm_backend_herdr_tool_check: refuse loudly if herdr or jq is missing.
fm_backend_herdr_tool_check() {
  command -v herdr >/dev/null 2>&1 || { echo "error: backend=herdr selected but the 'herdr' CLI is not installed (https://herdr.dev) (dual-licensed AGPL-3.0-or-later/commercial)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=herdr selected but 'jq' is not installed (required to parse herdr's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_herdr_version_check: refuse loudly on a missing/incompatible
# herdr client. Verified locally: v0.7.1, protocol 14 (herdr status --json's
# .client.protocol; client info is session-independent, unlike .server).
fm_backend_herdr_version_check() {
  fm_backend_herdr_tool_check || return 1
  local status protocol version
  status=$(herdr status --json 2>/dev/null) || { echo "error: 'herdr status --json' failed; is herdr installed correctly?" >&2; return 1; }
  protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null)
  version=$(printf '%s' "$status" | jq -r '.client.version // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*)
      echo "error: could not read herdr client protocol from 'herdr status --json'; refusing to use an unverified herdr build" >&2
      return 1
      ;;
  esac
  if [ "$protocol" -lt "$FM_BACKEND_HERDR_MIN_PROTOCOL" ]; then
    echo "error: herdr protocol $protocol (version ${version:-unknown}) is older than the verified minimum $FM_BACKEND_HERDR_MIN_PROTOCOL; update herdr (herdr update) before using backend=herdr" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_session: resolve which named herdr session this normal
# spawn/op uses. HERDR_SESSION mirrors tmux's $TMUX ambient-selection for
# adapter workspace/tab/pane operations: an operator (or firstmate's own
# isolated test harness) sets it explicitly; absent means herdr's own
# "default" session. Do not use HERDR_SESSION alone for destructive test
# cleanup; tests/herdr-test-safety.sh documents and guards that path.
fm_backend_herdr_session() {
  printf '%s' "${HERDR_SESSION:-default}"
}

# fm_backend_herdr_session_socket: resolve the one verified running
# named-session socket path as an absolute string. Requires JSON string type
# and non-empty length (jq -r is never used: it would turn JSON null into the
# literal string "null"). Canonicalizes the parent directory when that
# directory exists so symlink parents such as /tmp -> /private/tmp cannot
# yield two identities for the same socket.
fm_backend_herdr_session_socket() {  # <session>
  local session=$1 sessions socket
  [ -n "$session" ] || return 1
  sessions=$(fm_backend_herdr_cli "$session" session list --json 2>/dev/null) || return 1
  socket=$(printf '%s' "$sessions" | jq -er --arg want "$session" '
    [.sessions[]?
      | select(.name == $want and .running == true)
      | select((.socket_path | type) == "string")
      | select((.socket_path | length) > 0)
      | .socket_path]
    | if length == 1 then .[0] else empty end
  ' 2>/dev/null) || return 1
  fm_backend_herdr_canonical_socket_path "$socket"
}

# fm_backend_herdr_canonical_socket_path: normalize one absolute Unix-socket
# path so two spellings of the same socket compare equal. Refuses a relative
# or empty path. An unresolvable directory is left as-is rather than treated as
# a failure, so a socket whose directory was removed still compares by its own
# literal path. Single owner for every socket-identity comparison in this
# adapter (the launcher-identity same-session proof uses it).
fm_backend_herdr_canonical_socket_path() {  # <socket-path>
  local socket=$1 sock_dir sock_base
  [ -n "$socket" ] || return 1
  case "$socket" in
    /*) ;;
    *) return 1 ;;
  esac
  sock_dir=$(dirname "$socket")
  sock_base=$(basename "$socket")
  [ -n "$sock_dir" ] && [ -n "$sock_base" ] || return 1
  if [ -d "$sock_dir" ]; then
    sock_dir=$(cd "$sock_dir" 2>/dev/null && pwd -P) || return 1
    socket="$sock_dir/$sock_base"
  fi
  printf '%s' "$socket"
}
# fm_backend_herdr_server_ensure: start the herdr server for <session>
# headless (no TUI client) if not already running, mirroring tmux's `tmux
# has-session || tmux new-session -d`. Verified: a bare socket CLI call does
# NOT auto-start the server, so this must run before any workspace/tab/pane
# call. The server outlives its launcher and passes its startup environment to
# every later pane, so remove home, harness identity, and supervision selection
# inherited from whichever agent happened to start it. Bounded poll for the
# server to report running.
fm_backend_herdr_server_ensure() {  # <session>
  local session=$1 running out i
  running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
  [ "$running" = "true" ] && return 0
  (
    unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE \
      CURSOR_AGENT CURSOR_INVOKED_AS CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT FM_SUPERVISION_MODEL
    fm_backend_herdr_cli "$session" server >/dev/null 2>&1 &
  ) || return 1
  for i in $(seq 1 20); do
    running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
    [ "$running" = "true" ] && return 0
    sleep 0.5
  done
  echo "error: herdr server for session '$session' did not report running within 10s" >&2
  return 1
}

# fm_backend_herdr_workspace_find_all: EVERY workspace id inside <session>
# whose label equals this HOME's own label (fm_backend_herdr_workspace_label),
# one per line, in herdr's own list order (normally creation order, oldest
# first). Empty when none match. Never creates anything.
#
# Single owner of the home-label workspace query. Herdr enforces no workspace
# label uniqueness at all (docs/herdr-backend.md "Label collisions"), so this
# can legitimately return MORE THAN ONE id: a captain-owned workspace can
# collide by label, a cwd-basename-derived label can coincide, and concurrent
# first spawns can mint two same-labeled home workspaces. Callers decide what a
# duplicate means for them - fm_backend_herdr_workspace_ensure refuses to guess
# which one is the caller's, while the read-only recovery path below keeps its
# historical first-match behavior.
fm_backend_herdr_workspace_find_all() {  # <session>
  local session=$1 label list
  label=$(fm_backend_herdr_workspace_label)
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 0
  # NOTE: the jq variable is $want, NOT $label - `label` is a jq reserved
  # keyword (label/break), so declaring a jq variable named "label" is a
  # compile error that `2>/dev/null` would silently swallow, making this find
  # ALWAYS return empty and every spawn mint a fresh "firstmate" workspace
  # (the workspace leak).
  printf '%s' "$list" | jq -r --arg want "$label" \
    '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null
}

# fm_backend_herdr_workspace_find: this HOME's own workspace id inside
# <session>, or empty (never creates). Read-only, safe for recovery/list
# paths, which address panes they already recorded and only need a container
# to scan. Keeps the historical FIRST-match behavior on a label collision -
# identical in spirit to the pre-existing tab duplicate-label check below.
# NOT the spawn-time resolver: placing a new worker by first label match is
# exactly the defect fm_backend_herdr_workspace_ensure now refuses.
fm_backend_herdr_workspace_find() {  # <session>
  fm_backend_herdr_workspace_find_all "$1" | head -1
}

# fm_backend_herdr_launcher_identity: the EXACT herdr workspace that the
# process making this spawn is itself running in.
#
# Herdr 0.7.5 injects HERDR_ENV=1, HERDR_PANE_ID, HERDR_SESSION,
# HERDR_SOCKET_PATH, HERDR_TAB_ID, and HERDR_WORKSPACE_ID into every process it
# manages a pane for (docs/verification/runtime-backends.md), and a firstmate
# or secondmate agent's own tool calls inherit them. Older injection shapes are
# unverified and cannot establish launcher ancestry without both pane and
# socket identity. Workspace LABELS are mutable and herdr enforces no
# uniqueness on them, so a label search cannot tell one `firstmate` workspace
# from another, and herdr's globally focused workspace is whatever the captain
# happens to be looking at, not the launcher's.
#
# The injected HERDR_TAB_ID/HERDR_WORKSPACE_ID are deliberately NOT read as the
# answer. They are a snapshot taken when the pane's process started, and herdr
# can move a pane between tabs and workspaces afterwards without being able to
# rewrite a running process's environment. Only a live read is the CURRENT
# parent, which is what placement has to bind to.
#
# Sets, only on a 0 return:
#   FM_BACKEND_HERDR_LAUNCHER_PANE_ID
#   FM_BACKEND_HERDR_LAUNCHER_TAB_ID
#   FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID
#
# Returns:
#   0 - one exact, self-consistent launcher pane/tab/workspace in <session>.
#   2 - this process is NOT running in a herdr pane (no HERDR_PANE_ID at all),
#       so there is no launcher workspace to inherit and the caller falls back
#       to its per-home container. HERDR_ENV=1 on its own is only a backend
#       SELECTION marker (bin/fm-backend.sh's fm_backend_detect), never a
#       parent binding - herdr always injects the pane id alongside it.
#   1 - a launcher pane IS claimed but its binding is missing, stale,
#       contradictory, or belongs to another herdr session. The caller must
#       refuse before creating or publishing any worker endpoint rather than
#       degrading to a label search.
fm_backend_herdr_launcher_identity() {  # <session>
  local session=$1 pane=${HERDR_PANE_ID:-} claimed_session claimed_socket session_socket
  local pane_out tab_out list tab workspace
  FM_BACKEND_HERDR_LAUNCHER_PANE_ID=""
  FM_BACKEND_HERDR_LAUNCHER_TAB_ID=""
  FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID=""
  [ -n "$pane" ] || return 2

  # Same-session proof, before the pane id is trusted at all: herdr pane ids
  # ("w2:p1") restart at the same low numbers in every session, so a pane id
  # borrowed from another session can silently resolve to a real but unrelated
  # workspace here. The injected socket path is the server identity herdr
  # exposes, and the session name independently binds the named session.
  claimed_session=$(fm_backend_herdr_session)
  if [ "$claimed_session" != "$session" ]; then
    echo "error: herdr launcher pane '$pane' reports session '$claimed_session' but this spawn targets session '$session'; refusing to place a worker from a cross-session parent identity" >&2
    return 1
  fi
  claimed_socket=${HERDR_SOCKET_PATH:-}
  if [ -z "$claimed_socket" ]; then
    echo "error: herdr launcher pane '$pane' has no injected socket identity; refusing to place a worker from an unverifiable parent identity" >&2
    return 1
  fi
  claimed_socket=$(fm_backend_herdr_canonical_socket_path "$claimed_socket") || {
    echo "error: herdr launcher pane '$pane' reports an unusable socket path; refusing to place a worker from an unverifiable parent identity" >&2
    return 1
  }
  session_socket=$(fm_backend_herdr_session_socket "$session") || {
    echo "error: herdr session '$session' has no unambiguous socket to match against the launcher pane's own; refusing to place a worker from an unverifiable parent identity" >&2
    return 1
  }
  if [ "$claimed_socket" != "$session_socket" ]; then
    echo "error: herdr launcher pane '$pane' belongs to the server at '$claimed_socket', not session '$session' at '$session_socket'; refusing to place a worker from a cross-session parent identity" >&2
    return 1
  fi

  pane_out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || {
    echo "error: herdr launcher pane '$pane' could not be read in session '$session'; refusing to place a worker without its exact parent workspace" >&2
    return 1
  }
  tab=$(printf '%s' "$pane_out" | jq -r --arg pane "$pane" '
    select(.result.pane.pane_id == $pane)
    | select((.result.pane.tab_id | type) == "string" and (.result.pane.tab_id | length) > 0)
    | .result.pane.tab_id
  ' 2>/dev/null)
  workspace=$(printf '%s' "$pane_out" | jq -r --arg pane "$pane" '
    select(.result.pane.pane_id == $pane)
    | select((.result.pane.workspace_id | type) == "string" and (.result.pane.workspace_id | length) > 0)
    | .result.pane.workspace_id
  ' 2>/dev/null)
  if [ -z "$tab" ] || [ -z "$workspace" ]; then
    echo "error: herdr launcher pane '$pane' returned an ambiguous tab or workspace identity in session '$session'; refusing to place a worker without its exact parent workspace" >&2
    return 1
  fi

  # Independent second read: the tab must agree that it lives in the same
  # workspace the pane just claimed. A restored-but-stale pane record that
  # disagrees with its own tab is exactly the contradictory binding this must
  # refuse rather than resolve.
  tab_out=$(fm_backend_herdr_cli "$session" tab get "$tab" 2>/dev/null) || {
    echo "error: herdr launcher tab '$tab' could not be read in session '$session'; refusing to place a worker without its exact parent workspace" >&2
    return 1
  }
  if ! printf '%s' "$tab_out" | jq -e --arg tab "$tab" --arg workspace "$workspace" '
    .result.tab.tab_id == $tab and .result.tab.workspace_id == $workspace
  ' >/dev/null 2>&1; then
    echo "error: herdr launcher pane '$pane' and tab '$tab' disagree about their workspace in session '$session'; refusing to place a worker from a contradictory parent identity" >&2
    return 1
  fi

  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    echo "error: could not list herdr workspaces in session '$session' to confirm the launcher's own workspace '$workspace'; refusing to place a worker without its exact parent workspace" >&2
    return 1
  }
  if ! printf '%s' "$list" | jq -e --arg workspace "$workspace" '
    (.result.workspaces | type) == "array"
    and ([.result.workspaces[] | select(.workspace_id == $workspace)] | length) == 1
  ' >/dev/null 2>&1; then
    echo "error: herdr launcher workspace '$workspace' is missing or duplicated in session '$session'; refusing to place a worker from a stale parent identity" >&2
    return 1
  fi

  # shellcheck disable=SC2034  # callers consume the verified binding's parts
  FM_BACKEND_HERDR_LAUNCHER_PANE_ID=$pane
  # shellcheck disable=SC2034  # callers consume the verified binding's parts
  FM_BACKEND_HERDR_LAUNCHER_TAB_ID=$tab
  FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID=$workspace
  return 0
}

# fm_backend_herdr_workspace_prune_seeded_default_tab: close EXACTLY
# <seeded_tab_id>, the auto-created default tab id that THIS SAME
# fm_backend_herdr_workspace_ensure call captured straight from its own
# `workspace create` response (never re-derived from a label pattern at
# create_task time - see the incident note below). Best-effort: a failure
# here never fails the caller, mirroring the fm_backend_herdr_kill `|| true`
# contract.
#
# Live-fire incident fix (2026-07-02): the prior implementation
# (fm_backend_herdr_workspace_prune_default_tabs, removed) re-derived
# "prunable" at create_task time from a pure label heuristic - exactly one
# tab, labeled "1" - run against whatever workspace fm_backend_herdr_workspace_find
# had just resolved. Herdr enforces no label uniqueness (docs/herdr-backend.md
# "Label collisions") and derives an unlabeled workspace's DISPLAYED label from
# its pane cwd's basename, so a captain launching herdr directly inside a
# directory named "firstmate" produces a workspace that looks byte-identical,
# by label alone, to firstmate's own auto-created container - one tab, label
# "1". workspace_find adopted that pre-existing (captain-owned, LIVE) workspace
# by the label match, the heuristic matched too, and the very next spawn
# closed the captain's own live pane 27ms after creating its task tab. The
# fix is structural, not another heuristic: only a workspace THIS SAME
# fm_backend_herdr_workspace_ensure call just created carries a non-empty
# seeded_tab_id at all (see FM_BACKEND_HERDR_WS_SEEDED_TAB_ID below); an
# ADOPTED workspace's seeded_tab_id is always empty, so create_task never
# calls this function for one, regardless of how its tabs happen to be
# labeled.
#
# Defense in depth on top of that gate (not the primary safety mechanism):
# re-verify <seeded_tab_id> is still present, still carries label "1" (a
# human could have renamed or repurposed it in the interim), and refuse to
# close it if its pane hosts an actively working agent per herdr's own
# agent-state detection (`agent get`) - belt-and-suspenders against any other
# unforeseen path landing a live agent in a tab this function was about to
# close.
#
# Verified real-herdr behavior (not modeled by the canned-response fake-CLI
# unit tests; modeled by make_herdr_statefake): closing a workspace's LAST
# remaining tab deletes the whole workspace, not just the tab. So this must
# never run while the seeded default tab is still the ONLY tab in the
# workspace - callers only invoke it once at least one other (real task) tab
# exists alongside it, never right after workspace creation - and this
# function independently re-checks the tab count as a second layer.
fm_backend_herdr_workspace_prune_seeded_default_tab() {  # <session> <workspace_id> <seeded_tab_id>
  local session=$1 wsid=$2 tab_id=$3 tabs tab_count current_label pane_id agent_out agent_status
  [ -n "$tab_id" ] || return 0
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 0
  tab_count=$(printf '%s' "$tabs" | jq -r '.result.tabs? // [] | length' 2>/dev/null)
  case "$tab_count" in ''|*[!0-9]*|0|1) return 0 ;; esac
  current_label=$(printf '%s' "$tabs" | jq -r --arg t "$tab_id" '.result.tabs[]? | select(.tab_id == $t) | .label' 2>/dev/null)
  [ "$current_label" = "1" ] || return 0
  pane_id=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || return 0
  [ -n "$pane_id" ] || return 0
  agent_out=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>/dev/null)
  agent_status=$(printf '%s' "$agent_out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  [ "$agent_status" = working ] && return 0
  fm_backend_herdr_cli "$session" pane close "$pane_id" >/dev/null 2>&1 || true
}

# fm_backend_herdr_workspace_ensure: the workspace this spawn's task tab
# belongs in inside <session> - the launching agent's own exact workspace when
# it has one, otherwise this HOME's persistent workspace, created in <cwd> if
# absent. Must be called as a PLAIN STATEMENT, never through command
# substitution ($(...)) - it communicates through these globals, not solely
# through stdout, and a command substitution forks a subshell that would
# discard them:
#   FM_BACKEND_HERDR_WS_ID          - the resolved workspace_id (also echoed,
#                                      for callers that only need the id)
#   FM_BACKEND_HERDR_WS_SEEDED_TAB_ID - non-empty ONLY when THIS call just
#                                      CREATED the workspace: the tab_id of
#                                      the auto-created default tab herdr
#                                      seeded it with, read straight from the
#                                      `workspace create` response's
#                                      `.result.tab.tab_id` (verified
#                                      empirically against the real binary -
#                                      no follow-up tab-list call needed).
#                                      Empty whenever this call instead
#                                      ADOPTED a pre-existing workspace -
#                                      either the launcher's own
#                                      (fm_backend_herdr_launcher_identity) or
#                                      a single label match
#                                      (fm_backend_herdr_workspace_find_all -
#                                      docs/herdr-backend.md "Label
#                                      collisions": that match can never
#                                      distinguish an explicitly
#                                      `--label`-created workspace from one
#                                      whose label only coincidentally
#                                      matches this home's own, e.g. a
#                                      cwd-basename-derived label). An
#                                      ADOPTED workspace's tabs are NEVER
#                                      inspected or identified as prunable by
#                                      this function, no matter what they are
#                                      labeled - see
#                                      fm_backend_herdr_workspace_prune_seeded_default_tab.
# --no-focus (docs/herdr-backend.md "Focus behavior"): verified that workspace
# create does NOT focus by default once at least one workspace already exists
# in the session, matching pre-existing (flagless) behavior; the ONE exception
# is the very first workspace ever created in a brand-new session, which
# focuses regardless of --no-focus (herdr always needs something focused to
# attach to). --no-focus is passed unconditionally anyway, for defense in
# depth and because it is a no-op in the already-safe case.
#
# <launcher-relationship> (3rd arg, default "launcher-home") says whether the
# container being ensured belongs to the SAME firstmate home as the process
# calling this:
#   launcher-home - a crewmate or scout for the caller's own home. When the
#                   caller is itself running in a herdr pane, the worker MUST
#                   land in that exact workspace
#                   (fm_backend_herdr_launcher_identity), never in whichever
#                   same-labeled workspace happens to sort first.
#   other-home    - a --secondmate launch, which stands up a DIFFERENT home's
#                   own per-home workspace by design. The launcher's workspace
#                   is deliberately not inherited here.
# With no herdr ancestry at all there is no launcher workspace to inherit, so
# the per-home label lookup below stays the resolver - but it must then resolve
# to exactly ONE workspace. Two same-labeled home workspaces with no launcher
# identity to disambiguate them is an unresolvable placement, and adopting
# either one is the very defect this refuses.
#
# Returns 0 on success, 3 for a refusal whose exact reason is already on
# stderr, and 1 for a failed or unparseable herdr call.
fm_backend_herdr_workspace_ensure() {  # <session> <cwd> [<launcher-relationship>]
  local session=$1 cwd=$2 relationship=${3:-launcher-home} wsid out label matches count status
  FM_BACKEND_HERDR_WS_ID=""
  FM_BACKEND_HERDR_WS_SEEDED_TAB_ID=""
  if [ "$relationship" = launcher-home ]; then
    fm_backend_herdr_launcher_identity "$session" && status=0 || status=$?
    case "$status" in
      0)
        FM_BACKEND_HERDR_WS_ID=$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID
        printf '%s' "$FM_BACKEND_HERDR_WS_ID"
        return 0
        ;;
      2) ;;
      *) return 3 ;;
    esac
  fi
  label=$(fm_backend_herdr_workspace_label)
  matches=$(fm_backend_herdr_workspace_find_all "$session")
  count=$(printf '%s' "$matches" | grep -c '[^[:space:]]' || true)
  if [ "$count" -gt 1 ]; then
    echo "error: ${count} herdr workspaces in session '$session' are labeled '$label' (${matches//$'\n'/ }) and this spawn has no herdr parent pane to identify which one is its own; rename or close the extras, or run firstmate inside the workspace its workers belong in" >&2
    return 3
  fi
  wsid=${matches%%$'\n'*}
  if [ -n "$wsid" ]; then
    FM_BACKEND_HERDR_WS_ID=$wsid
    printf '%s' "$wsid"
    return 0
  fi
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || return 1
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  [ -n "$wsid" ] || return 1
  FM_BACKEND_HERDR_WS_ID=$wsid
  # Herdr seeds a new workspace with one auto-created default tab firstmate
  # never uses. It is NOT pruned here: at this instant it is the workspace's
  # ONLY tab, and closing a workspace's last tab deletes the workspace itself
  # (verified against the real herdr binary) - pruning here would destroy the
  # workspace we just created. fm_backend_herdr_create_task prunes it instead,
  # once the first real task tab exists alongside it, and only ever targets
  # this exact captured tab_id.
  FM_BACKEND_HERDR_WS_SEEDED_TAB_ID=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  printf '%s' "$wsid"
}

# fm_backend_herdr_container_ensure: the full spawn-time container-ensure
# sequence (version gate, server, workspace). Echoes
# "<session>:<workspace_id>\t<seeded_default_tab_id>" - a single TAB character
# always separates the two fields (the second is empty for an ADOPTED
# workspace) so a caller can split unambiguously with
# CONTAINER=${RAW%%$'\t'*}; SEEDED_TAB_ID=${RAW#*$'\t'}. The seeded tab id
# must be threaded through to fm_backend_herdr_create_task, which is the only
# function allowed to prune it (fm_backend_herdr_workspace_prune_seeded_default_tab).
# <launcher-relationship> is passed straight through to
# fm_backend_herdr_workspace_ensure, which owns its meaning.
fm_backend_herdr_container_ensure() {  # <cwd-for-a-fresh-workspace> [<launcher-relationship>]
  local cwd=${1:-$PWD} relationship=${2:-launcher-home} session label status
  fm_backend_herdr_version_check || return 1
  session=$(fm_backend_herdr_session)
  fm_backend_herdr_server_ensure "$session" || return 1
  fm_backend_herdr_workspace_ensure "$session" "$cwd" "$relationship" >/dev/null && status=0 || status=$?
  # A 3 already reported the exact placement it refused to guess at; adding the
  # generic message here would bury it.
  [ "$status" -ne 3 ] || return 1
  if [ "$status" -ne 0 ] || [ -z "$FM_BACKEND_HERDR_WS_ID" ]; then
    label=$(fm_backend_herdr_workspace_label)
    echo "error: failed to ensure herdr workspace '$label' in session '$session'" >&2
    return 1
  fi
  printf '%s:%s\t%s' "$session" "$FM_BACKEND_HERDR_WS_ID" "$FM_BACKEND_HERDR_WS_SEEDED_TAB_ID"
}

# fm_backend_herdr_pane_presence_state: classify one exact pane get response
# as dead|present|unknown from its JSON body, never from process exit status.
fm_backend_herdr_pane_presence_state() {  # <session> <pane_id>
  local session=$1 pane_id=$2 out code pid
  out=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>&1)
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    [ "$code" = "pane_not_found" ] && printf 'dead' || printf 'unknown'
    return 0
  fi
  pid=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  [ "$pid" = "$pane_id" ] && printf 'present' || printf 'unknown'
}

# fm_backend_herdr_explicit_close_pane_confirmed: issue one explicit close and
# succeed only when a structured follow-up proves the exact pane is gone.
fm_backend_herdr_explicit_close_pane_confirmed() {  # <session> <pane_id>
  local session=$1 pane_id=$2 presence
  fm_backend_herdr_cli "$session" pane close "$pane_id" >/dev/null 2>&1 || return 1
  presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane_id")
  [ "$presence" = dead ]
}

# fm_backend_herdr_pane_agent_state: classify <pane_id> in <session> as one of
# dead|no-agent|live|unknown, purely from the JSON body of two read-only
# calls - never from process exit status, since a business-logic "not found"
# response is a normal, expected outcome here, not a call failure (real herdr
# 0.7.1 exits 1 for it; the canned-response test fakes exit 0; parsing only
# the JSON keeps this function correct against either).
#
#   dead     - `pane get` responds with error code pane_not_found: the pane
#              itself is gone (closed, or its process died and herdr already
#              reaped it - verified empirically: killing a pane's shell pid
#              on a live server makes herdr immediately drop both the pane
#              and its tab from `pane get`/`tab list`).
#   no-agent - `pane get` succeeds (the pane structurally exists) but `agent
#              get` responds with error code agent_not_found: nothing is
#              registered in it - exactly what a herdr session-layout restore
#              produces (verified empirically: `session stop` + fresh `herdr
#              server` restart leaves the pane alive, agent_status "unknown",
#              agent get -> agent_not_found - docs/herdr-backend.md "ID
#              stability across a server restart"), and what a future
#              `resume_agents_on_restore = false` restore would produce too
#              (a plain shell, never an agent).
#   live     - `agent get` succeeds and reports a real agent_status (working,
#              idle, done, or blocked - any registered value). An idle or
#              blocked agent is still a genuine, still-registered agent, not
#              a restored husk, so it is never a close-and-replace candidate.
#   unknown  - anything else: an unparseable/unexpected response from either
#              call, or a `pane get` success whose own echoed pane_id does not
#              round-trip (guards against misreading a herdr response shape
#              change as "the pane exists"). The caller must fail safe toward
#              refusal here, never toward closing - this is the conservative
#              backstop the husk check depends on.
fm_backend_herdr_pane_agent_state() {  # <session> <pane_id>
  local session=$1 pane_id=$2 out code presence status
  presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane_id")
  if [ "$presence" != present ]; then
    case "$presence" in
      dead|unknown) printf '%s' "$presence" ;;
      *) printf 'unknown' ;;
    esac
    return 0
  fi
  out=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>&1)
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    [ "$code" = "agent_not_found" ] && printf 'no-agent' || printf 'unknown'
    return 0
  fi
  status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$status" in
    working|idle|done|blocked) printf 'live' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_herdr_tab_is_husk: true (0) only for the two conservative husk
# states (dead, no-agent) fm_backend_herdr_pane_agent_state can positively
# confirm; live and unknown both refuse (1), so an inconclusive read never
# licenses closing anything. Restored-layout recovery depends on this
# fail-safe-toward-refusal behavior.
fm_backend_herdr_tab_is_husk() {  # <session> <pane_id>
  case "$(fm_backend_herdr_pane_agent_state "$1" "$2")" in
    dead|no-agent) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_backend_herdr_agent_state: recovery-grade state for the same session-start
# sweep as the tmux classifier. It reuses the husk classifier rather than
# creating a second Herdr state machine: a structurally gone pane is `missing`,
# a confirmed agent-less pane is `dead`, a registered agent is `alive`, and an
# unexpected or failed API read is `unreadable`.
fm_backend_herdr_agent_state() {  # <target>
  local target=$1
  fm_backend_herdr_parse_target "$target" || { printf 'unreadable'; return 0; }
  case "$(fm_backend_herdr_pane_agent_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" in
    dead) printf 'missing' ;;
    no-agent) printf 'dead' ;;
    live) printf 'alive' ;;
    *) printf 'unreadable' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_herdr_agent_alive() {  # <target>
  case "$(fm_backend_herdr_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_herdr_create_task: create the task's tab (one pane) in
# <container> ("session:workspace_id"). Herdr does NOT enforce label
# uniqueness itself (verified: two tabs can share a label), so the duplicate
# check is ours, mirroring tmux's manual check.
#
# A same-labeled tab already existing no longer means an automatic refusal:
# herdr persists and restores its whole session layout (workspaces/tabs/
# panes) across a server restart, including a reboot, and a restored fm-<id>
# task tab comes back a HUSK - a dead pane, or (today, and unconditionally
# once a future `resume_agents_on_restore = false` config ships) a plain
# agent-less shell sitting in the saved cwd, never the crewmate that used to
# be there. Before this fix, every fleet respawn after such a restart needed
# the operator to manually close each husk pane first before firstmate could
# spawn into it again. fm_backend_herdr_tab_is_husk classifies the existing
# tab's pane conservatively (dead or no-agent only; anything live or
# ambiguous refuses exactly as before) and, when it is a confirmed husk,
# this function CLOSES AND REPLACES it instead of refusing.
#
# Ordering is deliberate: the REPLACEMENT tab is created FIRST, and the husk
# is closed only AFTER that succeeds - never the reverse. Closing a
# workspace's LAST remaining tab deletes the whole workspace on real herdr
# (docs/herdr-backend.md "Default workspace lifecycle"), and a session-restore husk
# can legitimately be that workspace's only tab (e.g. its own seeded default
# tab was already pruned, long before the restart, by a prior real task tab
# existing alongside it). Herdr's lack of label-uniqueness enforcement is
# exactly what makes this safe: the new and the husk tab can briefly share
# the same label with no error, so the workspace never drops to zero tabs.
# This mirrors fm_backend_herdr_workspace_prune_seeded_default_tab's own
# create-before-close safety argument.
#
# --no-focus: verified tab create never focuses by default regardless of
# sibling tabs, so this is defense in depth rather than a behavior change.
# <seeded_default_tab_id> (4th arg, may be empty) is exactly the value
# fm_backend_herdr_workspace_ensure captured as FM_BACKEND_HERDR_WS_SEEDED_TAB_ID
# for THIS SAME container - non-empty only when this spawn's own
# container_ensure call just created the workspace. Once the real task tab
# above is created, this is the ONLY input that may trigger a prune, and it is
# passed by the caller, never re-derived here from tab list contents or
# labels (the live-fire self-kill fix - see
# fm_backend_herdr_workspace_prune_seeded_default_tab for the incident and
# the safety argument). An ADOPTED workspace's caller always passes an empty
# 4th arg, so this function never even queries for a prune candidate in that
# case. Echoes "<tab_id> <pane_id>" on success.
fm_backend_herdr_create_task() {  # <container> <label> <cwd> <seeded_default_tab_id>
  local container=$1 label=$2 cwd=$3 seeded_tab_id=${4:-} session wsid list dup_tabs dup dup_pane dup_tab_ids out tab_id pane_id remaining_dup_tabs
  session=${container%%:*}
  wsid=${container#*:}
  list=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  dup_tabs=$(printf '%s' "$list" | jq -r --arg want "$label" 'if (.result.tabs | type) == "array" then .result.tabs[] | select(.label == $want) | .tab_id else error("missing result.tabs") end' 2>/dev/null) || {
    echo "error: could not parse herdr tab list output for workspace $wsid (session $session)" >&2
    return 1
  }
  dup_tab_ids=""
  if [ -n "$dup_tabs" ]; then
    while IFS= read -r dup; do
      [ -n "$dup" ] || continue
      dup_pane=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$dup")
      if [ -z "$dup_pane" ] || ! fm_backend_herdr_tab_is_husk "$session" "$dup_pane"; then
        echo "error: herdr tab '$label' already exists in workspace $wsid (session $session)" >&2
        return 1
      fi
      dup_tab_ids="${dup_tab_ids}${dup}"$'\n'
    done <<EOF
$dup_tabs
EOF
  fi
  out=$(fm_backend_herdr_cli "$session" tab create --workspace "$wsid" --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || return 1
  tab_id=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane_id=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$tab_id" ] || [ -z "$pane_id" ]; then
    echo "error: could not parse tab/pane id from herdr tab create output" >&2
    return 1
  fi
  [ -z "$seeded_tab_id" ] || fm_backend_herdr_workspace_prune_seeded_default_tab "$session" "$wsid" "$seeded_tab_id"
  if [ -n "$dup_tab_ids" ]; then
    while IFS= read -r dup; do
      [ -n "$dup" ] || continue
      fm_backend_herdr_cli "$session" tab close "$dup" >/dev/null 2>&1 || true
    done <<EOF
$dup_tab_ids
EOF
    list=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || {
      echo "error: could not verify herdr husk removal for tab '$label' in workspace $wsid (session $session)" >&2
      return 1
    }
    if ! printf '%s' "$list" | jq -e '(.result.tabs | type) == "array"' >/dev/null 2>&1; then
      echo "error: could not parse herdr tab list output for workspace $wsid (session $session)" >&2
      return 1
    fi
    remaining_dup_tabs=$(printf '%s' "$list" | jq -r --arg want "$label" --arg replacement "$tab_id" \
      '.result.tabs[]? | select(.label == $want and .tab_id != $replacement) | .tab_id' 2>/dev/null)
    remaining_dup_tabs=${remaining_dup_tabs//$'\n'/ }
    if [ -n "$remaining_dup_tabs" ]; then
      echo "error: failed to remove preexisting herdr tab(s) $remaining_dup_tabs for label '$label' in workspace $wsid (session $session)" >&2
      return 1
    fi
  fi
  printf '%s %s' "$tab_id" "$pane_id"
}
# fm_backend_herdr_parse_target: split "<session>:<pane_id>" (pane_id itself
# contains a colon, e.g. "w1:p2") on the FIRST colon only. Sets
# FM_BACKEND_HERDR_SESSION and FM_BACKEND_HERDR_PANE for the caller.
fm_backend_herdr_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_HERDR_SESSION=${target%%:*}
  FM_BACKEND_HERDR_PANE=${target#*:}
  [ -n "$FM_BACKEND_HERDR_SESSION" ] && [ -n "$FM_BACKEND_HERDR_PANE" ] && [ "$FM_BACKEND_HERDR_PANE" != "$target" ]
}

fm_backend_herdr_target_ready() {  # <target>
  fm_backend_herdr_parse_target "$1" || return 1
  fm_backend_herdr_server_ensure "$FM_BACKEND_HERDR_SESSION" || return 1
}

# fm_backend_herdr_current_path: the live FOREGROUND process's cwd, or empty on
# any error. Mirrors tmux's pane_current_path poll used for worktree-path
# discovery after `treehouse get`.
#
# Verified pitfall: `pane get`'s `.result.pane.cwd` is the pane's cwd AT
# CREATION TIME - the top-level shell's cwd - and does NOT update when that
# shell `cd`s or enters a subshell (as `treehouse get` does). Reading it here
# would make fm-spawn.sh's worktree-discovery poll never see the pane "leave"
# the project directory, since `cwd` stays frozen at the original path forever.
# `.result.pane.foreground_cwd` tracks the ACTUALLY RUNNING foreground
# process's cwd instead, which is what changes when `treehouse get` enters its
# worktree subshell - confirmed live against a real treehouse acquisition.
fm_backend_herdr_current_path() {  # <target>
  fm_backend_herdr_target_ready "$1" || return 0
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
    | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null
}

# fm_backend_herdr_send_text_line: send one line of TEXT then submit,
# ATOMICALLY - mirrors tmux's `send-keys -t T text Enter`. Used for the fixed
# spawn-time commands (treehouse get, the GOTMPDIR export). `pane run` types
# the command and submits it in one call (verified).
fm_backend_herdr_send_text_line() {  # <target> <text>
  fm_backend_herdr_target_ready "$1" || return 1
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane run "$FM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

# fm_backend_herdr_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately. Mirrors tmux's `send-keys -t T -l text`.
# Verified: `pane send-text` does NOT auto-submit (contrary to the addendum's
# original guess); it behaves exactly like tmux's `-l` literal send.
fm_backend_herdr_send_literal() {  # <target> <text>
  fm_backend_herdr_target_ready "$1" || return 1
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-text "$FM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

# fm_backend_herdr_normalize_key: map firstmate's key vocabulary (Enter,
# Escape, C-c, as used by fm-send.sh --key and stuck-crewmate-recovery) onto
# herdr's `pane send-keys` names. Verified empirically: enter, escape/esc, and
# both ctrl+c/C-c all work (case-insensitive on herdr's side, but normalize
# explicitly rather than relying on that).
fm_backend_herdr_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf 'ctrl+c' ;;
    # C-u clears a composer line. fm-send.sh's muse interrupt path needs it to
    # drop the prompt muse restores into the composer after Escape.
    C-u|c-u|ctrl+u|Ctrl+U) printf 'ctrl+u' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_backend_herdr_send_key: one named special key. Mirrors fm-send.sh's --key
# path (tmux's `send-keys -t T key`).
fm_backend_herdr_send_key() {  # <target> <key>
  fm_backend_herdr_target_ready "$1" || return 1
  local key
  key=$(fm_backend_herdr_normalize_key "$2")
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-keys "$FM_BACKEND_HERDR_PANE" "$key" >/dev/null 2>&1
}

# fm_backend_herdr_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's/fm-watch.sh's `tmux capture-pane -p -t T -S -N`. --source recent
# is the closest herdr analogue to tmux's scrollback-bounded capture.
#
# Verified CLI quirk (herdr-verification-p2.md "pane read --lines bug", v0.7.1):
# `pane read --source recent --lines N` returns COMPLETELY EMPTY output when N
# is smaller than the pane's current viewport height (observed threshold ~23
# rows for a default-sized pane), instead of clamping to the last N lines - it
# does not merely ignore the bound, it drops the read entirely. This silently
# broke exactly the small bounded reads this adapter relies on most (including
# the composer-state guard/fallback reads around submit and injection). Workaround:
# always request a generous fetch far above any realistic viewport height, then
# trim to the caller's requested bound ourselves with `tail`.
fm_backend_herdr_capture() {  # <target> <lines>
  fm_backend_herdr_target_ready "$1" || return 1
  local lines=${2:-200} fetch out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  case "$fetch" in ''|*[!0-9]*) fetch=200 ;; *) [ "$fetch" -ge 200 ] || fetch=200 ;; esac
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" --source recent --lines "$fetch" 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

fm_backend_herdr_capture_ansi() {  # <target> <lines>
  fm_backend_herdr_target_ready "$1" || return 1
  local lines=${2:-200} fetch out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  case "$fetch" in ''|*[!0-9]*) fetch=200 ;; *) [ "$fetch" -ge 200 ] || fetch=200 ;; esac
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" --source recent --lines "$fetch" --format ansi 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# --- herdr composer capture and capability primitives -----------------------
#
# These functions are the ONLY herdr-specific composer knowledge left: the
# ANSI pane capture (with its small-N workaround), the native `agent get`
# identity probe, and the capability descriptor. Every shape - the bordered
# box, the bare agent-glyph row, opencode's left-bar, and pi's
# identity-gated separated pair (which this adapter pioneered) - now lives in
# the shared owner (bin/fm-composer-lib.sh, fm_composer_classify_screen), so
# a new harness shape is taught there once and every backend learns it in the
# same commit. The muse `⟩` glyph this adapter's local bare-prompt pattern
# silently omitted is exactly the drift class that consolidation removes.

fm_backend_herdr_agent_identity_raw() {  # <session> <pane> -> <agent>\t<status>
  local out
  out=$(fm_backend_herdr_cli "$1" agent get "$2" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '[.result.agent.agent // "", .result.agent.agent_status // ""] | @tsv' 2>/dev/null
}

# fm_backend_herdr_composer_identity: the native agent identity/state probe
# backing the shared classifier's separated (pi) shape - the genuine herdr
# primitive no other backend has natively.
fm_backend_herdr_composer_identity() {  # <target> -> "<agent>\t<status>"
  fm_backend_herdr_parse_target "$1" || return 1
  fm_backend_herdr_agent_identity_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE"
}

# fm_backend_herdr_composer_state: thin adapter - capture plus capabilities
# in, shared verdict out. The ANSI capture is preferred (styled=1 lets the
# shared classifier strip ghost/placeholder text); when it fails on an older
# herdr, the plain capture degrades the descriptor to styled=0 rather than
# letting ghost text be misread as typed input. Identity is fetched lazily,
# only when the classifier reports the verdict depends on it (a pi separator
# pair below every other candidate), preserving this adapter's original
# consult-only-when-needed behavior.
fm_backend_herdr_composer_state() {  # <target> -> empty|pending|pending-unproven|unknown
  local target=$1 cap caps verdict identity
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  if cap=$(fm_backend_herdr_capture_ansi "$target" "$FM_COMPOSER_CAPTURE_LINES" 2>/dev/null); then
    caps=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=%s' "$FM_COMPOSER_CAPTURE_LINES")
  elif cap=$(fm_backend_herdr_capture "$target" "$FM_COMPOSER_CAPTURE_LINES"); then
    caps=$(printf 'styled=0\ncursor=0\nidentity=1\nrows=%s' "$FM_COMPOSER_CAPTURE_LINES")
  else
    printf 'unknown'
    return 0
  fi
  verdict=$(fm_composer_classify_screen "$caps" "$cap")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_backend_herdr_composer_identity "$target" 2>/dev/null) || [ -z "$identity" ]; then
      identity=probe-absent
    fi
    verdict=$(fm_composer_classify_screen "$caps" "$cap" '' "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

# fm_backend_herdr_rendered_busy_state: busy|idle|unknown from the pane's
# RENDERED busy footer, the same delivery-only signal bin/fm-tmux-lib.sh's
# fm_pane_busy_state reads, scanning the same 40-line tail folded to its last
# 12 non-blank rows. This is NOT a worker-state source: herdr's native
# agent-state (fm_backend_herdr_busy_state) stays the semantic owner, and this
# read exists only so the submit core below can confirm a delivery for a
# harness whose native state never transitions. Without a harness argument the
# shared matcher uses its union of verified tokens, which is what the submit
# core wants: it has no recorded harness for the pane.
fm_backend_herdr_rendered_busy_state() {  # <target> [harness] -> busy|idle|unknown
  local target=$1 harness=${2:-} cap visible
  cap=$(fm_backend_herdr_capture "$target" 40) || { printf 'unknown'; return 0; }
  visible=$(printf '%s' "$cap" | grep -v '^[[:space:]]*$' | tail -12)
  [ -n "$visible" ] || { printf 'unknown'; return 0; }
  if printf '%s' "$visible" | fm_busy_lines_match "$harness"; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

# fm_backend_herdr_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then submit with a named Enter key, retried
# (Enter only, never retyped) until native agent-state, a cleared composer, or
# fm_composer_queued_enter_verdict confirms delivery. Verified hazard
# (herdr-verification-p2.md "slash/$ autocomplete popup"): a `/`- or
# `$`-prefixed send opens a completion popup within ~0.1s, exactly like tmux's
# claude/codex popups, so the caller's <settle> before the first Enter matters
# here the same way it does for tmux.
#
# Confirmation signal: when the target is legibly idle before Enter,
# submission is confirmed by fm_backend_herdr_wait_for_working observing a
# submit-active agent_status after Enter. Live Claude on Herdr 0.8.0 can
# keep agent_status idle for a whole landed turn, so an idle native result
# falls through to the shared composer verdict: empty is positive delivery,
# proven pending retries Enter, and retries-exhausted pending plus a
# generating busy signal is a queued Enter via
# fm_composer_queued_enter_verdict (bin/fm-composer-lib.sh).
#
# Incident (2026-07-07, followed up on 2026-07-08): a redelivery loop in the
# away-mode daemon. Root cause: composer-content submit confirmation was too
# sensitive to harness rendering details. Real claude/codex use bare prompt
# rows, and real codex adds dynamic idle suggestions after `›`; the later
# ANSI-aware composer classifier now handles that Codex shape, and idle-baseline
# submit confirmation still prefers native agent-state so a faint idle tip
# cannot block a landed send. Composer content is consulted only after native
# state stays idle, as the empty/pending owner, and for submit attempts whose
# pre-Enter agent-state baseline is not legibly idle.
#
# This also still correctly handles the earlier 2026-07-03 incident (a
# slash-command popup selection/placeholder-fill on the FIRST Enter is not a
# genuine submission) without any popup-specific logic at all: filling a
# composer placeholder never starts a turn, so agent_status simply never
# reports "working" for that Enter, the composer stays pending, and the retry
# loop below sends a second Enter exactly as it did before - the fix
# generalizes instead of special-casing the popup shape.
#
# Failure-mode analysis (the two directions the caller-facing contract must
# not get wrong - see docs/herdr-backend.md "Native agent-state submit
# confirmation" for the empirical timing behind this):
#   - Slow transition: fm_backend_herdr_wait_for_working samples repeatedly
#     across herdr's per-attempt confirmation budget (not once at the end), so a
#     transition landing partway through a window is still caught before this
#     loop gives up and sends a needless extra Enter.
#   - Instant round-trip or a native status that never leaves idle: bounded by
#     the composer fallback. A cleared composer is delivery; a proven-pending
#     composer on an idle pane is a swallow; extra Enter on an already-empty
#     composer is a no-op, not a duplicate delivery of <text>.
# Fallback path, for a harness whose native agent-state is never legibly idle
# (measured live: herdr reports a cursor pane `blocked` in every state - idle,
# mid-turn, and after - so the idle-baseline path above is structurally
# unreachable for it). That harness always lands in the composer branch, and
# cursor's mid-turn composer row renders its own placeholder beside a
# right-aligned `ctrl+c to stop`, so the content verdict is `pending` on a
# composer that holds no user text at all and every steer reported delivery
# unconfirmed on a message that had actually landed.
# The escape is the SAME semantic signal the idle-baseline path uses, read from
# the pane's verified busy footer instead of native agent-state, and it is the
# rendered-footer twin of the tmux submit core's turn-started confirmation
# (bin/fm-tmux-lib.sh): an idle-to-busy transition ACROSS our Enter is proof the
# harness accepted the submission. The baseline is taken before the first Enter
# and only when the native baseline was not legibly idle, so the idle-baseline
# path still never reads pane content until native stays idle. A pane already
# mid-turn cannot use a rendered-footer transition as proof of this Enter;
# only the separate retries-exhausted, proven-pending queued-Enter verdict can
# confirm delivery from its native working state.
# Queued-while-busy Enter (OpenCode 1.18.4, and any harness that keeps typed
# text visible until the current turn ends): after the retry budget, a proven
# pending composer plus native agent_status=working is delivered, not swallowed.
# blocked is not working, so a Cursor pane that is blocked in every state does
# not receive this conversion. On an idle native baseline, a rendered busy
# footer may supply the same generating signal because live Claude never leaves
# idle. The policy is fm_composer_queued_enter_verdict; this adapter only
# supplies the busy primitive.
# Echoes empty|pending|unknown|send-failed, a subset of the proof-carrying
# submit vocabulary. Empty means confirmed submitted for every backend; how
# each backend confirms it is an internal decision.
#
# fm_backend_herdr_queued_enter_busy: delivery-busy for the shared queued-Enter
# conversion. Native agent_status=working is generating; blocked is not (a
# permission prompt, or Cursor's always-blocked native state, is not a queued
# mid-turn). When <allow-rendered> is 1, an idle native baseline may also take
# the pane's rendered busy footer, because live Claude keeps agent_status idle
# through a whole turn.
fm_backend_herdr_queued_enter_busy() {  # <target> <allow-rendered>
  local target=$1 allow_rendered=${2:-0} raw
  raw=$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")
  case "$raw" in
    working) printf 'busy'; return 0 ;;
  esac
  if [ "$allow_rendered" = 1 ]; then
    fm_backend_herdr_rendered_busy_state "$target"
  else
    printf 'idle'
  fi
}

fm_backend_herdr_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 verdict baseline confirm_sleep
  local raw_status footer_baseline='' allow_rendered=0 enter_sent=0
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_herdr_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  raw_status=$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")
  baseline=$(fm_backend_herdr_classify_submit_agent_status "$raw_status")
  confirm_sleep=$(fm_backend_herdr_submit_confirm_budget "$sleep_s")
  # Typing never starts a turn, so a footer read taken after the literal send
  # and before the first Enter is still a pre-submission baseline.
  if [ "$baseline" = idle ]; then
    allow_rendered=1
  else
    footer_baseline=$(fm_backend_herdr_rendered_busy_state "$target")
  fi
  while :; do
    if fm_backend_herdr_send_key "$target" Enter; then
      enter_sent=1
    elif [ "$enter_sent" -eq 0 ]; then
      i=$((i + 1))
      if [ "$i" -ge "$retries" ]; then
        printf 'send-failed'
        return 0
      fi
      sleep "$sleep_s"
      continue
    fi
    if [ "$baseline" = idle ]; then
      verdict=$(fm_backend_herdr_wait_for_working "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" \
        "$confirm_sleep" "$FM_BACKEND_HERDR_SUBMIT_POLLS")
      case "$verdict" in
        busy) printf 'empty'; return 0 ;;
        unknown) printf 'unknown'; return 0 ;;
      esac
      # Native stayed idle. Composer empty is positive delivery (a landed
      # Claude turn that never flipped agent_status). Proven pending retries.
      verdict=$(fm_backend_herdr_composer_state "$target")
      case "$verdict" in
        empty) printf 'empty'; return 0 ;;
        pending|pending-unproven) ;;
        *) printf '%s' "$verdict"; return 0 ;;
      esac
    else
      sleep "$sleep_s"
      verdict=$(fm_backend_herdr_composer_state "$target")
      if [ "$verdict" = pending ] && [ "$raw_status" != working ] \
        && [ "$footer_baseline" = idle ] \
        && [ "$(fm_backend_herdr_rendered_busy_state "$target")" = busy ]; then
        verdict=busy
      fi
      case "$verdict" in
        busy) printf 'empty'; return 0 ;;
        empty) printf 'empty'; return 0 ;;
        unknown) printf 'unknown'; return 0 ;;
      esac
    fi
    i=$((i + 1))
    if [ "$i" -ge "$retries" ]; then
      if [ "$enter_sent" -eq 0 ]; then
        printf 'send-failed'
      else
        fm_composer_queued_enter_verdict "$verdict" \
          "$(fm_backend_herdr_queued_enter_busy "$target" "$allow_rendered")"
      fi
      return 0
    fi
  done
}
fm_backend_herdr_kill() {  # <target>
  fm_backend_herdr_target_ready "$1" || return 0
  fm_backend_herdr_explicit_close_pane_confirmed \
    "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" || true
}

# fm_backend_herdr_endpoint_confirmed_gone: gate durable-record removal on
# the exact recorded pane's structured presence
# (fm_backend_herdr_pane_presence_state), read-only, so a refused, skipped,
# or failed close never erases a live task's endpoint identity.
# Only a structured pane_not_found proves the endpoint gone; present and
# unknown presence refuse after every close path, and a missing or malformed
# target identity is ambiguity that also refuses, never proof of a gone pane.
fm_backend_herdr_endpoint_confirmed_gone() {  # <target>
  local presence
  fm_backend_herdr_parse_target "$1" || return 1
  presence=$(fm_backend_herdr_pane_presence_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")
  [ "$presence" = dead ]
}

# fm_backend_herdr_classify_agent_status: map a raw `agent get` agent_status
# value to the adapter's watcher busy|idle|unknown vocabulary. working ->
# busy (actively generating); idle/done -> idle; blocked -> idle (a blocked
# agent is stuck waiting on the human, not grinding - the watcher should
# treat it like a stale pane needing attention, not suppress it as busy);
# unknown/unparseable/empty -> unknown, the caller's cue to fall back to
# pane-regex detection.
fm_backend_herdr_classify_agent_status() {  # <raw-agent_status>
  case "$1" in
    working) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    blocked) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_herdr_classify_submit_agent_status() {  # <raw-agent_status>
  case "$1" in
    working|blocked) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_herdr_agent_status_raw: one `agent get` read, echoing the raw
# agent_status string (working/idle/done/blocked/...), or empty on any
# failure. Deliberately skips fm_backend_herdr_target_ready's server-ensure
# round trip (an extra `status --json` call) that fm_backend_herdr_busy_state
# pays on every call: fm_backend_herdr_wait_for_working polls this in a tight
# loop right after a caller has already parsed the target and confirmed the
# server is live (e.g. fm_backend_herdr_send_text_submit, immediately after a
# successful send-text), so re-checking server liveness on every poll would
# only add latency without adding safety.
fm_backend_herdr_agent_status_raw() {  # <session> <pane_id>
  local session=$1 pane_id=$2 out
  out=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>/dev/null) || { printf ''; return 0; }
  printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null
}

# fm_backend_herdr_busy_state: semantic busy state from herdr's native
# agent-state detection (agent.get), the "first backend where fm_session_busy_state
# gets real semantics" per the design report. See
# fm_backend_herdr_classify_agent_status for the status->busy/idle/unknown
# mapping.
fm_backend_herdr_busy_state() {  # <target>
  fm_backend_herdr_target_ready "$1" || { printf 'unknown'; return 0; }
  fm_backend_herdr_classify_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")"
}

# fm_backend_herdr_wait_for_working: poll <session>:<pane_id>'s NATIVE
# agent-state (agent get) up to <polls> times spread evenly across
# <budget-seconds>, returning on stdout the STRONGEST signal observed:
#
#   busy    - a submit-active status was observed at least once. This is
#             confirmation that a real turn started or reached a prompt -
#             the submit landed - independent of
#             whatever the composer's own text happens to show (docs/
#             herdr-backend.md "Incident (2026-07-07)": composer content is
#             what fooled the OLD confirmation on codex's dynamic idle-tip
#             text). Returned the INSTANT it is seen, without waiting out the
#             rest of the budget.
#   idle    - the target was legibly read at least once and never reported
#             "busy" across the whole window. This is readable but
#             inconclusive: native state can remain idle for a landed turn,
#             so the caller falls through to composer confirmation.
#   unknown - EVERY poll in the window failed to read the target at all (a
#             hard I/O failure - pane gone, socket error - not a timing
#             race). The caller must not keep retrying Enter against a target
#             it cannot even read.
#
# <polls> spread across <budget-seconds> (rather than one check at the end)
# lets the fast path catch a native transition that lands partway through the
# window. A whole-window idle result remains inconclusive and is resolved by
# the caller's shared composer fallback.
# FM_BACKEND_HERDR_SUBMIT_POLLS (default 6): how many samples
# fm_backend_herdr_send_text_submit spreads across each Enter attempt's
# confirmation budget. Overridable for tests (a value of 1
# reproduces the old single-check-at-the-end timing exactly, for byte-for-byte
# call-count assertions).
FM_BACKEND_HERDR_SUBMIT_POLLS=${FM_BACKEND_HERDR_SUBMIT_POLLS:-6}
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=${FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP:-0.6}

fm_backend_herdr_submit_confirm_budget() {  # <caller-budget-seconds>
  awk -v b="${1:-0}" -v m="$FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP" 'BEGIN {
    b += 0
    m += 0
    if (b < 0) b = 0
    if (m < 0) m = 0
    if (m > b) b = m
    printf "%.4f", b
  }' 2>/dev/null || printf '%s' "${1:-0}"
}

fm_backend_herdr_wait_for_working() {  # <session> <pane_id> <budget-seconds> <polls>
  local session=$1 pane_id=$2 budget=$3 polls=${4:-1} i interval raw bs saw_idle=0
  case "$polls" in ''|*[!0-9]*|0) polls=1 ;; esac
  interval=$(awk -v b="$budget" -v p="$polls" 'BEGIN { d = p - 1; if (d < 1) d = 1; v = b / d; if (v < 0) v = 0; printf "%.4f", v }' 2>/dev/null)
  case "$interval" in ''|*[!0-9.]*) interval=0 ;; esac
  for ((i = 0; i < polls; i++)); do
    if [ "$polls" -eq 1 ] || [ "$i" -gt 0 ]; then
      sleep "$interval"
    fi
    raw=$(fm_backend_herdr_agent_status_raw "$session" "$pane_id")
    bs=$(fm_backend_herdr_classify_submit_agent_status "$raw")
    case "$bs" in
      busy) printf 'busy'; return 0 ;;
      idle) saw_idle=1 ;;
    esac
  done
  if [ "$saw_idle" -eq 1 ]; then
    printf 'idle'
  else
    printf 'unknown'
  fi
}

# fm_backend_herdr_pane_for_tab: the root pane id for <tab_id> in <workspace_id>
# of <session>, via one pane list call filtered by tab_id (never assumes a
# tab-number/pane-number correspondence - herdr numbers them independently).
fm_backend_herdr_pane_for_tab() {  # <session> <workspace_id> <tab_id>
  local session=$1 wsid=$2 tab_id=$3 panes
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -r --arg tab "$tab_id" \
    '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null | head -1
}

# fm_backend_herdr_resolve_bare_selector: the live-tab-listing fallback for an
# ad hoc selector with no meta (mirrors tmux's list-windows grep). Searches
# every RUNNING named herdr session (herdr session list) for a tab whose label
# matches <name>, since herdr sessions are not addressed by one ambient
# server the way a single tmux server is. Rare path in practice (herdr tasks
# normally carry meta), best-effort.
fm_backend_herdr_resolve_bare_selector() {  # <name>
  local name=$1 sessions session tabs tab_id wsid pane_id
  sessions=$(herdr session list --json 2>/dev/null | jq -r '.sessions[]? | select(.running == true) | .name' 2>/dev/null)
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    tabs=$(fm_backend_herdr_cli "$session" tab list 2>/dev/null) || continue
    tab_id=$(printf '%s' "$tabs" | jq -r --arg want "$name" \
      '.result.tabs[]? | select(.label == $want) | .tab_id' 2>/dev/null | head -1)
    [ -n "$tab_id" ] || continue
    wsid=$(printf '%s' "$tabs" | jq -r --arg tab "$tab_id" '.result.tabs[]? | select(.tab_id == $tab) | .workspace_id' 2>/dev/null | head -1)
    [ -n "$wsid" ] || continue
    pane_id=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || continue
    [ -n "$pane_id" ] || continue
    printf '%s:%s' "$session" "$pane_id"
    return 0
  done <<EOF
$sessions
EOF
  echo "error: no herdr tab named $name in any running session" >&2
  return 1
}

# fm_backend_herdr_list_live: recovery/orphan discovery. Lists every tab whose
# label looks like a firstmate task window (fm-<id>) in <session>'s, THIS
# HOME'S OWN workspace (fm_backend_herdr_workspace_label - never another
# home's), by LABEL - never by trusting a stored pane id, since ids are not
# guaranteed stable across every server lifecycle (see herdr-verification-p2.md
# "ID stability"). A caller running as a given home (e.g. a secondmate
# recovering its own in-flight work) naturally scopes to that home's own
# workspace because FM_HOME already names it - no glue needed, unlike the
# primary-spawns-a-secondmate path in fm-spawn.sh. Read-only: a session/
# workspace that does not exist yet simply lists nothing. One
# "<session>:<pane_id>\t<label>" line per live task tab.
fm_backend_herdr_list_live() {  # <session>
  local session=$1 wsid tabs tab_id label pane_id
  wsid=$(fm_backend_herdr_workspace_find "$session") || return 0
  [ -n "$wsid" ] || return 0
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 0
  while IFS=$'\t' read -r tab_id label; do
    [ -n "$tab_id" ] || continue
    pane_id=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || continue
    [ -n "$pane_id" ] || continue
    printf '%s:%s\t%s\n' "$session" "$pane_id" "$label"
  done < <(printf '%s' "$tabs" | jq -r '.result.tabs[]? | select(.label | startswith("fm-")) | "\(.tab_id)\t\(.label)"' 2>/dev/null)
}

# --- native event push: pane.agent_status_changed subscriber -----------------
#
# The push half of the immediate blocked-state escalation (AGENTS.md section 8,
# docs/herdr-backend.md "Native pane.agent_status_changed push escalation").
# fm_backend_herdr_wait_transition is the watcher's bounded wait primitive for
# herdr homes: instead of a blind sleep, it blocks on herdr's native event
# stream and returns the instant a subscribed pane transitions to `blocked`, so
# a crew waiting on the human wakes its supervisor sub-second instead of after
# the ~240s stale-pane wedge timer. Everything not `blocked` is streamed too
# (the policy, not the subscription, makes `blocked` the sole immediate action)
# so `working` edges clear the per-pane dedupe marker. Polling stays the
# permanent fail-closed backstop: below-capability, a connect/subscribe failure,
# or a missing reader all fall back to the caller sleeping the same budget.

# fm_backend_herdr_socket_path: the control-socket path for <session>, read from
# `herdr session list --json` (the default session's socket differs from a named
# session's - verified: default -> ~/.config/herdr/herdr.sock, named ->
# ~/.config/herdr/sessions/<name>/herdr.sock). Empty on any failure.
fm_backend_herdr_socket_path() {  # <session>
  local session=$1
  herdr session list --json 2>/dev/null \
    | jq -r --arg name "$session" '.sessions[]? | select(.name == $name) | .socket_path // empty' 2>/dev/null \
    | head -1
}

# fm_backend_herdr_events_capable: the version/capability gate for the event
# fast-path (report section 5c trigger 1). Fails closed to the poll loop unless
# ALL hold: herdr+jq present; the raw-socket reader available (python3, unless a
# reader override is configured); client protocol >= FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL;
# and both `events.subscribe` and `pane.agent_status_changed` present in `herdr
# api schema`. FM_BACKEND_HERDR_EVENTS_FORCE overrides the whole verdict for
# tests (1 = capable, 0 = incapable) without touching the real binary. The
# `api schema` read is ~220KB, so callers (the watcher) memoize this per session
# for a process lifetime rather than probing every poll.
fm_backend_herdr_events_capable() {  # <session>
  local session=$1 protocol schema
  case "${FM_BACKEND_HERDR_EVENTS_FORCE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  fm_backend_herdr_tool_check || return 1
  if [ -z "${FM_BACKEND_HERDR_EVENT_READER:-}" ]; then
    command -v python3 >/dev/null 2>&1 || return 1
  fi
  protocol=$(herdr status --json 2>/dev/null | jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in ''|*[!0-9]*) return 1 ;; esac
  [ "$protocol" -ge "$FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL" ] || return 1
  schema=$(herdr api schema --json 2>/dev/null) || return 1
  printf '%s' "$schema" | grep -Fq 'events.subscribe' || return 1
  printf '%s' "$schema" | grep -Fq 'pane.agent_status_changed' || return 1
  return 0
}

# fm_backend_herdr_normalize_event: THE single normalize point (report section 5
# refinement: one backend transition shape, one parse point). Both the stream
# reader's projected lines AND the level-reconcile's `agent get` reads flow
# through here into the shared normalized-transition record. herdr's event
# carries no previous status and its stream is edge-triggered, so from_status is
# left empty; to_status drives the policy.
fm_backend_herdr_normalize_event() {  # <pane_id> <workspace_id> <agent_status> <agent>
  fm_transition_record "${1:-}" "${2:-}" "" "${3:-}" "${4:-}"
}

# fm_backend_herdr_event_reader_cmd: emit the reader argv (one word per line) for
# the raw-socket subscriber. Default: `python3 <this dir>/herdr-eventwait.py`.
# FM_BACKEND_HERDR_EVENT_READER overrides it with a whitespace-split command so
# tests can substitute a fake reader that replays canned stream lines.
fm_backend_herdr_event_reader_cmd() {
  local word
  if [ -n "${FM_BACKEND_HERDR_EVENT_READER:-}" ]; then
    for word in $FM_BACKEND_HERDR_EVENT_READER; do
      printf '%s\n' "$word"
    done
    return 0
  fi
  printf 'python3\n'
  printf '%s\n' "$FM_BACKEND_HERDR_ROOT/bin/backends/herdr-eventwait.py"
}

# fm_backend_herdr_escalation_marker: the per-pane dedupe marker path for a
# <window> ("<session>:<pane_id>"), keyed identically to the watcher's
# .stale-<key> (tr ':/.' '___'), under <state_dir>.
fm_backend_herdr_escalation_marker() {  # <state_dir> <window>
  local state=$1 window=$2 key
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s/%s%s' "$state" "$FM_BACKEND_HERDR_ESCALATED_PREFIX" "$key"
}

# fm_backend_herdr_apply_transition: route one normalized record through the
# shared policy table, maintaining the per-pane dedupe marker under <state_dir>.
# On a fresh `actionable` (blocked) edge - policy actionable AND no marker yet -
# it prints the record on stdout and returns 0 (the caller stops and hands the
# record up). The caller commits the marker only after handling the record.
# `absorb` (working) clears the marker and
# returns 1. `defer`/`fallback`, and an already-marked `actionable`, return 1
# with no output. <session> reconstructs the window ("<session>:<pane_id>") for
# the marker key, matching the watcher's own key scheme.
fm_backend_herdr_apply_transition() {  # <state_dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id to action window marker
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  to=$(fm_transition_to_status "$record")
  action=$(fm_transition_policy "$to")
  window="$session:$pane_id"
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  case "$action" in
    actionable)
      if [ ! -e "$marker" ]; then
        printf '%s' "$record"
        return 0
      fi
      ;;
    absorb)
      rm -f "$marker" 2>/dev/null || true
      ;;
  esac
  return 1
}

fm_backend_herdr_commit_transition() {  # <state_dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id window marker
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  window="$session:$pane_id"
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  : > "$marker"
}

fm_backend_herdr_clear_transition() {  # <state_dir> <window>
  local state=$1 window=$2 marker
  [ -n "$window" ] || return 0
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  rm -f "$marker" 2>/dev/null || true
}

# fm_backend_herdr_wait_transition: the bounded event wait. Blocks up to
# <timeout_secs> for one of <pane_window...> ("<session>:<pane_id>") to reach a
# fresh `blocked` edge, then prints the normalized record and returns 0.
# Returns 1 on a clean timeout (the reader ran the full budget, no fresh
# actionable edge - the caller has effectively already slept and just continues)
# and 2 when the event path is unusable (not capable, socket unresolved, reader
# failed to run/subscribe - the caller sleeps the budget itself, the fail-closed
# backstop). See the header block above for the full contract.
fm_backend_herdr_wait_transition() {  # <session> <timeout_secs> <state_dir> <pane_window...>
  local session=$1 timeout=$2 state=$3
  shift 3
  local windows=("$@")
  [ "${#windows[@]}" -gt 0 ] || return 2
  if [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" != 1 ]; then
    fm_backend_herdr_events_capable "$session" || return 2
  fi
  local sock
  sock=$(fm_backend_herdr_socket_path "$session")
  [ -n "$sock" ] || return 2

  # Map each window to its herdr pane id (strip the leading "<session>:").
  local w pane_id
  local pane_ids=()
  for w in "${windows[@]}"; do
    pane_id=${w#*:}
    if [ -z "$pane_id" ] || [ "$pane_id" = "$w" ]; then
      continue
    fi
    pane_ids+=("$pane_id")
  done
  [ "${#pane_ids[@]}" -gt 0 ] || return 2

  # Start the raw-socket reader and wait for its subscription acknowledgement
  # before level reconciliation, so edges occurring during reconciliation are
  # already buffered in the live stream.
  local reader=()
  while IFS= read -r w; do
    reader+=("$w")
  done < <(fm_backend_herdr_event_reader_cmd)
  [ "${#reader[@]}" -gt 0 ] || return 2

  local fifo_dir fifo reader_pid line ws status agent raw record hit rc=1 reader_rc=0
  fifo_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-eventwait.XXXXXX") || return 2
  fifo="$fifo_dir/events"
  if ! mkfifo "$fifo" 2>/dev/null; then
    rm -rf "$fifo_dir" 2>/dev/null || true
    return 2
  fi
  "${reader[@]}" "$sock" "$timeout" "${pane_ids[@]}" > "$fifo" 2>/dev/null &
  reader_pid=$!
  if ! exec 9< "$fifo"; then
    kill "$reader_pid" 2>/dev/null || true
    wait "$reader_pid" 2>/dev/null || true
    rm -rf "$fifo_dir" 2>/dev/null || true
    return 2
  fi
  if ! IFS= read -r -u 9 line || [ "$line" != "@subscribed" ]; then
    rc=2
  fi

  # Level reconcile on (re)connect (report section 3d): a pane already `blocked`
  # during the gap since the last subscription is returned now, once, while
  # newer edges accumulate in the active stream. `working` panes clear their
  # marker here too.
  if [ "$rc" -ne 2 ]; then
    for w in "${windows[@]}"; do
      pane_id=${w#*:}
      if [ -z "$pane_id" ] || [ "$pane_id" = "$w" ]; then
        continue
      fi
      raw=$(fm_backend_herdr_agent_status_raw "$session" "$pane_id")
      [ -n "$raw" ] || continue
      record=$(fm_backend_herdr_normalize_event "$pane_id" "" "$raw" "")
      if hit=$(fm_backend_herdr_apply_transition "$state" "$session" "$record"); then
        printf '%s' "$hit"
        rc=0
        break
      fi
    done
  fi

  # Drain stream edges until a fresh blocked edge or the timeout. The reader is
  # a subprocess of this call (NOT a second watcher), and is killed the instant
  # a blocked edge is found.
  # Split each raw projected line (pane_id\tworkspace_id\tagent_status\tagent)
  # with `cut`, NOT `IFS=$'\t' read`: a tab is IFS-whitespace, so `read` would
  # collapse an empty middle field (e.g. an absent workspace_id) and shift the
  # status into the wrong column. `cut` preserves empty fields.
  while [ "$rc" -eq 1 ] && IFS= read -r line <&9; do
    [ -n "$line" ] || continue
    pane_id=$(printf '%s' "$line" | cut -f1)
    ws=$(printf '%s' "$line" | cut -f2)
    status=$(printf '%s' "$line" | cut -f3)
    agent=$(printf '%s' "$line" | cut -f4)
    [ -n "$pane_id" ] || continue
    record=$(fm_backend_herdr_normalize_event "$pane_id" "$ws" "$status" "$agent")
    if hit=$(fm_backend_herdr_apply_transition "$state" "$session" "$record"); then
      printf '%s' "$hit"
      rc=0
      break
    fi
  done
  if [ "$rc" -eq 0 ]; then
    kill "$reader_pid" 2>/dev/null || true
  fi
  if [ "$rc" -eq 2 ]; then
    kill "$reader_pid" 2>/dev/null || true
  fi
  # No actionable edge: distinguish a clean full-budget wait (reader exit 0 ->
  # return 1, caller already waited) from a reader error (connect/subscribe
  # failure, exit non-zero -> return 2, caller sleeps and counts toward the
  # runtime-disable threshold).
  wait "$reader_pid" 2>/dev/null || reader_rc=$?
  exec 9<&-
  rm -rf "$fifo_dir" 2>/dev/null || true
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 2 ] && return 2
  [ "$reader_rc" -eq 0 ] && return 1
  return 2
}
