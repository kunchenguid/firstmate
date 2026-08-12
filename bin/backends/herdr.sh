#!/usr/bin/env bash
# bin/backends/herdr.sh - the herdr session-provider adapter (EXPERIMENTAL).
#
# Design and empirical verification are recorded in docs/herdr-backend.md and
# docs/verification/runtime-backends.md, refined by the backend guide's
# "workspace-per-home" pass (AGENTS.md task herdr-sm-spaces-k4). Herdr is a
# session provider ONLY (D3): the worktree provider stays treehouse, exactly
# like tmux. Sourced only through bin/fm-backend.sh's fm_backend_source in
# normal operation; the unit tests source it directly, so the FM_HOME fallback
# below keeps that path sane without fm-backend.sh's preamble.
#
# Default container shape: one Herdr workspace per Firstmate home and one tab
# per task inside that workspace.
# Target resolution stays parallel to the tmux adapter in both layouts.
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
# Authoritative task recovery uses labels and exact persisted endpoint ids.
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
# shellcheck source=bin/fm-task-label-lib.sh
. "$FM_BACKEND_HERDR_ROOT/bin/fm-task-label-lib.sh"

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
# label (docs/herdr-backend.md "Watching and task containers"). The PRIMARY home (no
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

fm_backend_herdr_workspace_owner_file() {
  local state="$FM_HOME/state" key
  key=$(printf '%s--%s' "$1" "$2" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_') || return 1
  printf '%s/.herdr-workspace-owner.%s' "$state" "$key"
}

fm_backend_herdr_workspace_owner_home() {
  cd "$FM_HOME" 2>/dev/null && pwd -P
}

fm_backend_herdr_workspace_owner_read() {
  local session=$1 label=$2 file owner owner_home owner_session owner_label owner_wsid extra
  file=$(fm_backend_herdr_workspace_owner_file "$session" "$label") || return 2
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 3
  fi
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 2
  owner=$(cat "$file") || return 2
  case "$owner" in *$'\n'*) return 2 ;; esac
  IFS=$'\t' read -r owner_home owner_session owner_label owner_wsid extra <<EOF
$owner
EOF
  [ -z "$extra" ] || return 2
  [ -n "$owner_home" ] && [ -n "$owner_session" ] && [ -n "$owner_label" ] && [ -n "$owner_wsid" ] || return 2
  [ "$owner_home" = "$(fm_backend_herdr_workspace_owner_home)" ] || return 2
  [ "$owner_session" = "$session" ] && [ "$owner_label" = "$label" ] || return 2
  printf '%s' "$owner_wsid"
}

fm_backend_herdr_workspace_owner_write() {
  local session=$1 label=$2 workspace=$3 state file tmp home
  state="$FM_HOME/state"
  home=$(fm_backend_herdr_workspace_owner_home) || return 1
  file=$(fm_backend_herdr_workspace_owner_file "$session" "$label") || return 1
  mkdir -p "$state" || return 1
  tmp=$(mktemp "$state/.herdr-workspace-owner.XXXXXX") || return 1
  if ! printf '%s\t%s\t%s\t%s' "$home" "$session" "$label" "$workspace" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# fm_backend_herdr_cli: run `herdr <args...>` scoped to <session>, setting
# BOTH the HERDR_SESSION env var AND appending a trailing `--session <name>`
# CLI flag. Verified empirically (docs/herdr-backend.md "Current transport
# behavior"): on the installed Herdr 0.7.1
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

fm_backend_herdr_bound_close_capable() {
  local schema
  schema=$(herdr api schema --json 2>/dev/null) || return 1
  printf '%s' "$schema" | jq -e '
    . as $root
    | def params_for($method):
        $root.schemas.request.oneOf[]?
        | select(.properties.method.const? == $method)
        | .properties.params."$ref"?
        | select(startswith("#/schemas/request/$defs/"))
        | split("/")[-1] as $name
        | $root.schemas.request."$defs"[$name]?;
    def required_type($schema; $field; $type):
      (($schema.required // []) | index($field)) != null
      and (($schema.properties[$field].type? // null) == $type);
    (params_for("pane.close_bound")) as $pane
    | ($pane != null)
      and required_type($pane; "pane_id"; "string")
      and required_type($pane; "expected_pid"; "integer")
      and required_type($pane; "expected_start_time"; "string")
  ' >/dev/null 2>&1
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
  if ! fm_backend_herdr_bound_close_capable; then
    echo "error: herdr provider lacks atomic pane.close_bound(expected_pid); refusing a backend that cannot safely finish live task teardown" >&2
    return 1
  fi
  return 0
}

fm_backend_herdr_server_available() {  # <session>
  local session=$1 out running
  out=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null) || return 1
  running=$(printf '%s' "$out" | jq -r '.server.running // false' 2>/dev/null)
  [ "$running" = true ]
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

fm_backend_herdr_provider_close_bound() {
  local session=${1:-} pane_id=${2:-} pid=${3:-} start_time=${4:-}
  local socket helper=${FM_BACKEND_HERDR_BOUND_CLOSE_HELPER:-$FM_BACKEND_HERDR_ROOT/bin/backends/herdr-pane-close-bound.py}
  [ -n "$session" ] && [ -n "$pane_id" ] && [ -n "$pid" ] && [ -n "$start_time" ] || return 1
  socket=$(fm_backend_herdr_socket_path "$session") || return 1
  [ -x "$helper" ] || return 1
  "$helper" "$socket" --pane "$pane_id" "$pid" "$start_time" >/dev/null 2>&1 || return 1
  [ "$(fm_backend_herdr_pane_agent_state "$session" "$pane_id")" = dead ]
}

fm_backend_herdr_server_ensure() {  # <session>
  local session=$1 running out i
  running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
  [ "$running" = "true" ] && return 0
  ( fm_backend_herdr_cli "$session" server >/dev/null 2>&1 & ) || return 1
  for i in $(seq 1 20); do
    running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
    [ "$running" = "true" ] && return 0
    sleep 0.5
  done
  echo "error: herdr server for session '$session' did not report running within 10s" >&2
  return 1
}

# fm_backend_herdr_workspace_find: this HOME's own workspace id inside
# <session> (fm_backend_herdr_workspace_label), or empty (never creates).
# Read-only, safe for recovery/list paths. A label match is usable only when
# this home has a matching persisted owner record.
fm_backend_herdr_workspace_find() {  # <session>
  local session=$1 label list owner_wsid owner_status
  label=$(fm_backend_herdr_workspace_label)
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  # NOTE: the jq variable is $want, NOT $label - `label` is a jq reserved
  # keyword (label/break), so declaring a jq variable named "label" is a
  # compile error that `2>/dev/null` would silently swallow, making this find
  # ALWAYS return empty and every spawn mint a fresh "firstmate" workspace
  # (the workspace leak).
  printf '%s' "$list" | jq -e '
    (.result.workspaces | type) == "array"
    and all(.result.workspaces[];
      (.workspace_id | type) == "string" and (.workspace_id | length) > 0
      and (.label | type) == "string"
    )
  ' >/dev/null 2>&1 || return 1
  if owner_wsid=$(fm_backend_herdr_workspace_owner_read "$session" "$label" 2>/dev/null); then
    printf '%s' "$list" | jq -e --arg want "$label" --arg owner "$owner_wsid" \
      '[.result.workspaces[] | select(.label == $want and .workspace_id == $owner)] | length == 1' \
      >/dev/null 2>&1 || return 1
    printf '%s' "$owner_wsid"
    return 0
  else
    owner_status=$?
  fi
  [ "$owner_status" -eq 3 ] || return 1
}

fm_backend_herdr_workspace_tab_labels() {  # <session> [workspace]
  local session=$1 wsid=${2:-} tabs
  [ -n "$wsid" ] || wsid=$(fm_backend_herdr_workspace_find "$session") || return 1
  [ -n "$wsid" ] || return 0
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -r '
    if (.result.tabs | type) == "array"
    then .result.tabs[] | select((.label | type) == "string") | .label
    else error("missing result.tabs")
    end' 2>/dev/null
}

fm_backend_herdr_workspace_ensure() {  # <session> <cwd>
  local session=$1 cwd=$2 wsid out label
  FM_BACKEND_HERDR_WS_ID=""
  FM_BACKEND_HERDR_WS_SEEDED_TAB_ID=""
  wsid=$(fm_backend_herdr_workspace_find "$session") || return 1
  if [ -n "$wsid" ]; then
    FM_BACKEND_HERDR_WS_ID=$wsid
    printf '%s' "$wsid"
    return 0
  fi
  label=$(fm_backend_herdr_workspace_label)
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e '
    (.result.workspace.workspace_id | type) == "string"
    and (.result.workspace.workspace_id | length) > 0
    and (.result.tab.tab_id | type) == "string"
    and (.result.tab.tab_id | length) > 0
    and (.result.root_pane.pane_id | type) == "string"
    and (.result.root_pane.pane_id | length) > 0
  ' >/dev/null 2>&1 || return 1
  wsid=$(printf '%s' "$out" | jq -er '.result.workspace.workspace_id' 2>/dev/null) || return 1
  FM_BACKEND_HERDR_WS_ID=$wsid
  fm_backend_herdr_workspace_owner_write "$session" "$label" "$wsid" || return 1
  printf '%s' "$wsid"
}

# fm_backend_herdr_container_ensure: the full spawn-time container-ensure
# sequence (version gate, server, workspace).
fm_backend_herdr_container_ensure() {  # <cwd-for-a-fresh-workspace>
  local cwd=${1:-$PWD} session label
  fm_backend_herdr_version_check || return 1
  session=$(fm_backend_herdr_session)
  fm_backend_herdr_server_ensure "$session" || return 1
  fm_backend_herdr_workspace_ensure "$session" "$cwd" >/dev/null || { label=$(fm_backend_herdr_workspace_label); echo "error: failed to ensure herdr workspace '$label' in session '$session'" >&2; return 1; }
  if [ -z "$FM_BACKEND_HERDR_WS_ID" ]; then
    label=$(fm_backend_herdr_workspace_label)
    echo "error: failed to ensure herdr workspace '$label' in session '$session'" >&2
    return 1
  fi
  printf '%s:%s\t%s' "$session" "$FM_BACKEND_HERDR_WS_ID" "$FM_BACKEND_HERDR_WS_SEEDED_TAB_ID"
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
#              agent get -> agent_not_found - docs/herdr-backend.md "Restart
#              and liveness behavior"), and what a future
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
  local session=$1 pane_id=$2 out code pid status
  # 2>&1, not 2>/dev/null: verified empirically that real herdr 0.7.1 writes
  # an error response's JSON body to STDERR (success bodies go to stdout), so
  # discarding stderr here would blind this function to exactly the
  # error.code values (pane_not_found, agent_not_found) it exists to read -
  # every OTHER call site in this file discards stderr safely only because
  # its caller collapses both the error and the not-an-error paths to the
  # same final answer, which this function's dead/no-agent/live/unknown
  # distinction cannot afford to do.
  out=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>&1)
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    [ "$code" = "pane_not_found" ] && printf 'dead' || printf 'unknown'
    return 0
  fi
  pid=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  if [ "$pid" != "$pane_id" ]; then
    printf 'unknown'
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

fm_backend_herdr_create_labeled_task() {  # <container> <state> <id> <kind> <title> <backlog> <cwd> [seeded]
  local container=$1 state=$2 id=$3 kind=$4 title=$5 backlog=$6 cwd=$7 seeded=${8:-}
  local session wsid live prepared label key ids tab_id pane_id
  session=${container%%:*}
  wsid=${container#*:}
  wsid=${wsid%%$'\t'*}
  live=$(fm_backend_herdr_workspace_tab_labels "$session" "$wsid") || return 1
  prepared=$(fm_task_label_prepare "$state" "$id" "$kind" "$title" "$live" "$backlog" \
    "$FM_HOME" "$session" "$wsid") || return 1
  label=${prepared%%$'\t'*}
  key=${prepared#*$'\t'}
  ids=$(fm_backend_herdr_create_task "$container" "$label" "$cwd" "$seeded") || return 1
  read -r tab_id pane_id <<EOF
$ids
EOF
  [ -n "$tab_id" ] && [ -n "$pane_id" ] || return 1
  printf '%s\t%s\t%s\t%s' "$label" "$key" "$tab_id" "$pane_id"
}

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
# Verified CLI quirk (docs/herdr-backend.md "Current transport behavior"):
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

# Thin adapter over the shared plain-text stripper (bin/fm-composer-lib.sh),
# used only for STRUCTURAL row/shape detection where ghost text must be kept so
# the box border or bare prompt glyph is still visible. Content extraction uses
# the shared fm_composer_strip_ghost instead.
fm_backend_herdr_strip_ansi() {  # <text>
  printf '%s' "$1" | fm_composer_strip_ansi
}

# fm_backend_herdr_composer_state: classify the composer's own row as
# empty|pending|unknown, scanning a generous tail-window capture of <target>.
# herdr's CLI exposes no cursor-row primitive (unlike tmux's #{cursor_y}), so
# this locates the composer structurally, recognizing THREE shapes and keeping
# whichever match comes LAST (scanning forward), so a shape earlier in
# scrollback/a popup can never outrank the real (bottom-anchored) composer:
#
#   bordered - a boxed composer (verified grok 0.2.82): the row's TRIMMED
#              content both STARTS and ENDS with the same border glyph (│, ┃,
#              or a plain ASCII |). The box's own top/bottom rows use rounded
#              corners (╭─…─╮ / ╰─…─╯), which never match; popup item rows and
#              horizontal separator rows carry no border glyph at all; the
#              footer help line ("Enter:send │ … │ …") uses │ only as an
#              INTERIOR separator and does not start with one, so it never
#              matches either.
#   bare     - an UNBORDERED composer (verified real claude 2.x and codex
#              0.142.x, both under Herdr 0.7.1, docs/herdr-backend.md
#              "Composer and injection safety"): the row's TRIMMED content starts with
#              one of the verified agent-specific prompt glyphs but carries no
#              closing border at all - claude's own live input row is a bare
#              "❯ …" with no surrounding │, and codex's is a bare "› …". Both
#              harnesses ALSO render bordered decorative boxes elsewhere (a
#              startup welcome banner, an update-available notice) that
#              satisfy the bordered shape above; requiring a match on EITHER
#              shape and keeping the last (bottom-most) one is what keeps the
#              live composer winning over a stale decorative box still sitting
#              in the same capture window - a bordered box is only ever
#              followed later on screen by the actual live composer, never the
#              reverse, in every harness observed so far. The bare shape is
#              deliberately narrower than the bordered content classifier so a
#              no-agent shell fallback prompt (`>`, `$`, `%`, or `#`) falls
#              through to `unknown` instead of being misread as delivered.
#   separated - Pi's composer is one or more content rows between two solid
#              horizontal `─` separator rows, with no prompt glyph or side
#              borders. This shape is accepted ONLY when Herdr's native
#              `agent get` identifies the target as Pi and reports it idle,
#              done, or blocked. A missing/stale/non-Pi agent identity, a
#              working Pi, an over-tall candidate, or an incomplete separator
#              pair remains unknown. This identity + structure conjunction is
#              what makes a blank Pi row safe without weakening dead-shell or
#              ambiguous-pane refusal.
#
#   empty   - blank, a bare prompt glyph, known ghost/placeholder text
#             ("Type a message...", verified grok 0.2.82's empty-composer
#             placeholder), or only de-emphasised ANSI ghost/placeholder text
#             recognized by the shared fm_composer_strip_ghost extractor
#             (dim/faint or dark-TRUECOLOR foreground). Safe to treat as
#             submitted.
#   pending - real, unsubmitted text sits in the composer. This deliberately
#             also covers a slash-command popup that just closed but only
#             auto-completed or filled an argument-hint placeholder into the
#             composer (e.g. "/compact" -> "/compact compaction
#             instructions", verified live against real grok 0.2.82) - that
#             first Enter is a SELECTION, not a submission.
#   unknown - the pane could not be read, or no composer row (of either shape)
#             was found in the captured window.
#
# Ghost/placeholder note: herdr's ANSI pane read preserves the harness's own
# de-emphasis styling, and the classifier extracts real typed content with the
# shared fm_composer_strip_ghost (bin/fm-composer-lib.sh), which drops dim/faint
# runs (claude's rotating prompt suggestion, codex's idle suggestion after the
# bare `›` prompt) AND dark/muted truecolor foreground runs (grok's placeholder),
# while keeping non-de-emphasised real typed input. This is the same owner the
# tmux adapter routes through, so the two backends cannot drift (task
# afk-herdr-false-pending); it superseded a herdr-only faint byte-pattern check
# that recognized only codex's bold-wrapped bare prompt and missed claude's own
# dim ghost - the overnight away-mode injection wedge on the primary claude pane.
FM_BACKEND_HERDR_COMPOSER_LINES=${FM_BACKEND_HERDR_COMPOSER_LINES:-20}
# Known ghost/placeholder composer text. Extend this if another
# herdr-verified harness needs its own idle placeholder recognized.
FM_BACKEND_HERDR_IDLE_RE=${FM_BACKEND_HERDR_IDLE_RE:-'^Type a message\.\.\.$'}
# Known bare (unbordered) prompt glyphs a composer row may start with: ❯
# (claude) and › (codex) only. Generic shell-style glyphs > $ % # are still
# recognized after a bordered composer row has already been structurally found.
FM_BACKEND_HERDR_BARE_PROMPT_RE=${FM_BACKEND_HERDR_BARE_PROMPT_RE:-'^[❯›]'}
# Pi allows a multi-line composer between its horizontal separators. Bound the
# structural candidate so two unrelated transcript rules with an arbitrarily
# large region between them can never be promoted into a composer.
FM_BACKEND_HERDR_PI_COMPOSER_MAX_LINES=${FM_BACKEND_HERDR_PI_COMPOSER_MAX_LINES:-8}

fm_backend_herdr_pi_separator_row() {  # <plain-row>
  local row=$1
  row="${row#"${row%%[![:space:]]*}"}"
  row="${row%"${row##*[![:space:]]}"}"
  [ "${#row}" -ge 8 ] || return 1
  [ -z "${row//─/}" ]
}

# Locate the content and closing-row position of the bottom-most complete pair
# of Pi separator rows. A separator closes the preceding candidate and
# immediately opens the next, so an earlier transcript rule can never outrank
# the live bottom composer pair. Globals let the caller compare this shape's
# screen position with generic bordered/bare candidates without losing empty
# composer content through command substitution.
fm_backend_herdr_pi_composer_find() {  # <ansi-capture>
  local cap=$1 line plain open=0 lines=0 candidate="" max row=0 open_row=0
  max=$FM_BACKEND_HERDR_PI_COMPOSER_MAX_LINES
  case "$max" in ''|*[!0-9]*|0) max=8 ;; esac
  FM_BACKEND_HERDR_PI_PAIR_FOUND=0
  FM_BACKEND_HERDR_PI_PAIR_VALID=0
  FM_BACKEND_HERDR_PI_PAIR_OPEN_LINE=0
  FM_BACKEND_HERDR_PI_PAIR_LINE=0
  FM_BACKEND_HERDR_PI_LAST_SEPARATOR_LINE=0
  FM_BACKEND_HERDR_PI_CONTENT=""
  while IFS= read -r line; do
    row=$((row + 1))
    plain=$(fm_backend_herdr_strip_ansi "$line")
    if fm_backend_herdr_pi_separator_row "$plain"; then
      FM_BACKEND_HERDR_PI_LAST_SEPARATOR_LINE=$row
      if [ "$open" -eq 1 ]; then
        FM_BACKEND_HERDR_PI_PAIR_FOUND=1
        FM_BACKEND_HERDR_PI_PAIR_OPEN_LINE=$open_row
        FM_BACKEND_HERDR_PI_PAIR_LINE=$row
        if [ "$lines" -le "$max" ]; then
          FM_BACKEND_HERDR_PI_PAIR_VALID=1
          FM_BACKEND_HERDR_PI_CONTENT=$candidate
        else
          FM_BACKEND_HERDR_PI_PAIR_VALID=0
          FM_BACKEND_HERDR_PI_CONTENT=""
        fi
      fi
      open=1
      open_row=$row
      lines=0
      candidate=""
    elif [ "$open" -eq 1 ]; then
      [ -z "$candidate" ] || candidate="${candidate}"$'\n'
      candidate="${candidate}${line}"
      lines=$((lines + 1))
    fi
  done <<EOF
$cap
EOF
}

fm_backend_herdr_agent_identity_raw() {  # <session> <pane> -> <agent>\t<status>
  local out
  out=$(fm_backend_herdr_cli "$1" agent get "$2" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '[.result.agent.agent // "", .result.agent.agent_status // ""] | @tsv' 2>/dev/null
}

fm_backend_herdr_composer_state() {  # <target> [expected-text] -> empty|pending|autocomplete|unknown
  local target=$1 expected_text=${2-} session pane cap line trimmed found=0 shape="" raw_match="" bordered=0 stripped
  local identity agent agent_status row=0 generic_line=0 verdict content
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  cap=$(fm_backend_herdr_capture_ansi "$target" "$FM_BACKEND_HERDR_COMPOSER_LINES" 2>/dev/null \
    || fm_backend_herdr_capture "$target" "$FM_BACKEND_HERDR_COMPOSER_LINES") || { printf 'unknown'; return 0; }
  # Structural scan: locate the bottom-most composer row and remember its RAW
  # (styled) bytes. Shape detection runs on the plain row (fm_backend_herdr_strip_ansi
  # keeps ghost text so the border/prompt glyph is still visible); the raw row is
  # kept for ANSI-aware content extraction after the scan.
  while IFS= read -r line; do
    row=$((row + 1))
    trimmed=$(fm_backend_herdr_strip_ansi "$line")
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|')
        shape=bordered
        raw_match=$line
        generic_line=$row
        found=1
        ;;
      *)
        if printf '%s' "$trimmed" | grep -qE "$FM_BACKEND_HERDR_BARE_PROMPT_RE"; then
          shape=bare
          raw_match=$line
          generic_line=$row
          found=1
        fi
        ;;
    esac
  done < <(printf '%s\n' "$cap")
  # Pi has no prompt glyph or side border. Compare its bottom-most complete
  # separator pair with the last generic match so an earlier bordered transcript
  # row can never suppress the live Pi composer. Identity is consulted only when
  # a lower separator pair could change the verdict.
  fm_backend_herdr_pi_composer_find "$cap"
  if [ "$FM_BACKEND_HERDR_PI_PAIR_FOUND" -eq 1 ] \
     && [ "$FM_BACKEND_HERDR_PI_PAIR_LINE" -gt "$generic_line" ] \
     && [ "$generic_line" -lt "$FM_BACKEND_HERDR_PI_PAIR_OPEN_LINE" ]; then
    identity=$(fm_backend_herdr_agent_identity_raw "$session" "$pane" 2>/dev/null || true)
    IFS=$'\t' read -r agent agent_status <<EOF
$identity
EOF
    case "$agent:$agent_status" in
      pi:idle|pi:done|pi:blocked)
        if [ "$FM_BACKEND_HERDR_PI_PAIR_VALID" -eq 1 ]; then
          shape=separated
          raw_match=$FM_BACKEND_HERDR_PI_CONTENT
          found=1
        else
          found=0
        fi
        ;;
      pi:*|:*)
        # A working Pi or unreadable identity cannot authorize injection, and
        # the lower separator pair proves any generic row above is not current.
        found=0
        ;;
      *) : ;; # A known non-Pi agent keeps its established generic verdict.
    esac
  elif [ "$FM_BACKEND_HERDR_PI_PAIR_FOUND" -eq 0 ] \
       && [ "$FM_BACKEND_HERDR_PI_LAST_SEPARATOR_LINE" -gt "$generic_line" ]; then
    # A lower unmatched separator proves the generic row is stale, but does
    # not provide the complete Pi composer structure required for injection.
    found=0
  fi
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  # Content: extract the real typed text from the raw row with the shared,
  # fleet-wide ghost stripper (bin/fm-composer-lib.sh), which drops dim/faint AND
  # dark-truecolor ghost/placeholder runs. This replaces the former herdr-only
  # faint byte-pattern check (which recognized only Codex's bold-wrapped bare
  # prompt and missed claude's own dim prompt-suggestion ghost - the overnight
  # afk-herdr-false-pending wedge) and, in a dark theme, drops the composer's own
  # dark box border too, which is why the bordered flag was read from the plain
  # shape above, not from this ghost-stripped content.
  stripped=$(printf '%s\n' "$raw_match" | fm_composer_strip_ghost)
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  if [ "$shape" = bordered ]; then
    bordered=1
    stripped=${stripped//│/}
    stripped=${stripped//┃/}
    stripped=${stripped//|/}
    stripped="${stripped#"${stripped%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
  elif [ "$shape" = separated ]; then
    # The native Pi identity plus the complete separator pair is the genuine
    # composer container, equivalent to a bordered box for shared content
    # classification. ANSI stripping keeps real text and drops only styling.
    bordered=1
  fi
  # Delegate the empty/pending/unknown decision to the shared owner. The bare
  # shape only ever starts with an AGENT glyph (FM_BACKEND_HERDR_BARE_PROMPT_RE
  # is '^[❯›]'), so a bare shell prompt never reaches here - it stays 'unknown'
  # via the no-composer-row path above, exactly as before.
  verdict=$(fm_composer_classify_content "$bordered" "$stripped" "$FM_BACKEND_HERDR_IDLE_RE")
  if [ "$verdict" = pending ] && [ -n "$expected_text" ]; then
    content=$stripped
    case "$content" in
      '❯ '*|'› '*|'> '*|'$ '*|'% '*|'# '*) content=${content#??} ;;
      '❯'*|'›'*|'>'*|'$'*|'%'*|'#'*) content=${content#?} ;;
    esac
    content="${content#"${content%%[![:space:]]*}"}"
    content="${content%"${content##*[![:space:]]}"}"
    if [ "$content" != "$expected_text" ]; then
      printf 'autocomplete'
      return 0
    fi
  fi
  printf '%s' "$verdict"
}

# fm_backend_herdr_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then submit with a named Enter key, retried
# (Enter only, never retyped) until herdr's NATIVE agent-state (agent get)
# confirms a real turn started. Verified hazard (docs/herdr-backend.md
# "Current transport behavior"): a `/`- or `$`-prefixed send opens a
# completion popup within ~0.1s, exactly like tmux's claude/codex popups, so
# the caller's <settle> before the first Enter matters here the same way it
# does for tmux.
#
# Confirmation signal (rewritten for the 2026-07-07 incident below;
# superseded a composer-content read that itself replaced a delta-based check
# for the 2026-07-03 incident): when the target is legibly idle before Enter,
# submission is confirmed by fm_backend_herdr_wait_for_working observing a
# submit-active agent_status after Enter, NOT by reading the composer's own
# row. This makes the normal confirmation path cross-agent: it is the same
# semantic signal regardless of what text a harness's idle composer happens
# to display.
#
# Incident (2026-07-07, followed up on 2026-07-08): a redelivery loop in the
# away-mode daemon. Root cause: composer-content submit confirmation was too
# sensitive to harness rendering details. Real claude/codex use bare prompt
# rows, and real codex adds dynamic idle suggestions after `›`; the later
# ANSI-aware composer classifier now handles the pre-injection guard for that
# Codex shape, but idle-baseline submit confirmation deliberately stays on
# native agent-state so delivery does not depend on composer text. Composer
# content is retained for other callers (the away-mode daemon's PRE-injection
# empty-box guard, still dispatched via fm_backend_composer_state /
# fm_backend_herdr_composer_state) and for submit attempts whose pre-Enter
# agent-state baseline is not legibly idle.
#
# This also still correctly handles the earlier 2026-07-03 incident (a
# slash-command popup selection/placeholder-fill on the FIRST Enter is not a
# genuine submission) without any popup-specific logic at all: filling a
# composer placeholder never starts a turn, so agent_status simply never
# reports "working" for that Enter, and the retry loop below sends a second
# Enter exactly as it did before - the fix generalizes instead of special-
# casing the popup shape.
#
# Failure-mode analysis (the two directions the caller-facing contract must
# not get wrong - see docs/herdr-backend.md "Current transport behavior"):
#   - Slow transition: fm_backend_herdr_wait_for_working samples repeatedly
#     across herdr's per-attempt confirmation budget (not once at the end), so a
#     transition landing partway through a window is still caught before this
#     loop gives up and sends a needless extra Enter.
#   - Instant round-trip (a turn starts AND returns to idle between two
#     polls): unavoidable in the absolute, but bounded by how tightly polls
#     are packed into the budget; real claude/codex measured first-working
#     at 90-490ms, comfortably inside a several-hundred-ms, multiply-sampled
#     window, so this has not been observed in practice. On the (unobserved)
#     residual chance it happens, the verdict is "pending" and the caller
#     never retypes - only re-sends Enter, which lands on an already-empty
#     composer and is a no-op, not a duplicate delivery of <text> (see
#     fm-send.sh/fm-supervise-daemon.sh: retyping only happens if a caller
#     re-invokes this function from scratch with the same text after seeing
#     an error, which is a human/escalation decision, not an automatic
#     retry).
# Echoes empty|pending|unknown|send-failed, the SAME vocabulary fm-send.sh
# already branches on for tmux ("empty" means "confirmed submitted" for every
# backend; how each backend confirms it is an internal decision - herdr's is
# no longer literally "the composer read empty").
fm_backend_herdr_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 verdict baseline confirm_sleep current
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_herdr_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  baseline=$(fm_backend_herdr_classify_submit_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")")
  confirm_sleep=$(fm_backend_herdr_submit_confirm_budget "$sleep_s")
  while :; do
    fm_backend_herdr_send_key "$target" Enter || { printf 'send-failed'; return 0; }
    if [ "$baseline" = idle ]; then
      verdict=$(fm_backend_herdr_wait_for_working "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" \
        "$confirm_sleep" "$FM_BACKEND_HERDR_SUBMIT_POLLS")
    else
      sleep "$sleep_s"
      verdict=$(fm_backend_herdr_composer_state "$target" "$text")
    fi
    case "$verdict" in
      busy) printf 'empty'; return 0 ;;
      empty) printf 'empty'; return 0 ;;
      pending)
        if [ "$baseline" != idle ]; then
          current=$(fm_backend_herdr_classify_submit_agent_status \
            "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")")
          case "$current" in
            busy) printf 'empty'; return 0 ;;
            idle) printf 'pending'; return 0 ;;
            unknown) printf 'unknown'; return 0 ;;
          esac
        fi
        ;;
      autocomplete) ;;
      unknown) printf 'unknown'; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_backend_herdr_submit_enter() {  # <target> <retries> <enter-sleep> [expected-text]
  local target=$1 retries=$2 sleep_s=$3 expected_text=${4-} i=0 baseline verdict confirm_sleep preflight
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  [ -n "$expected_text" ] || { printf 'unknown'; return 0; }
  confirm_sleep=$(fm_backend_herdr_submit_confirm_budget "$sleep_s")
  while :; do
    preflight=$(fm_backend_herdr_composer_state "$target" "$expected_text")
    case "$preflight" in
      empty)
        baseline=$(fm_backend_herdr_classify_submit_agent_status \
          "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")")
        [ "$baseline" = busy ] && printf 'empty' || printf 'unknown'
        return 0
        ;;
      pending)
        baseline=$(fm_backend_herdr_classify_submit_agent_status \
          "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")")
        [ "$baseline" = idle ] || { printf 'unknown'; return 0; }
        ;;
      *) printf 'unknown'; return 0 ;;
    esac
    fm_backend_herdr_send_key "$target" Enter || { printf 'send-failed'; return 0; }
    verdict=$(fm_backend_herdr_wait_for_working "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" \
      "$confirm_sleep" "$FM_BACKEND_HERDR_SUBMIT_POLLS")
    case "$verdict" in
      busy) printf 'empty'; return 0 ;;
      idle) ;;
      unknown) printf 'unknown'; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# fm_backend_herdr_kill: remove the task's exact pane and prove it disappeared.
# Verified: closing a tab's only pane closes the tab too, so a separate tab
# close is unnecessary.
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
#             herdr-backend.md "Current transport behavior": composer content is
#             what fooled the OLD confirmation on codex's dynamic idle-tip
#             text). Returned the INSTANT it is seen, without waiting out the
#             rest of the budget.
#   idle    - the target was legibly read at least once and never reported
#             "busy" across the whole window - a genuine "not (yet)
#             submitted" signal, not a read failure. The caller retries
#             Enter on this verdict.
#   unknown - EVERY poll in the window failed to read the target at all (a
#             hard I/O failure - pane gone, socket error - not a timing
#             race). The caller must not keep retrying Enter against a target
#             it cannot even read.
#
# <polls> spread across <budget-seconds> (rather than one check at the end)
# is what makes this robust against a SLOW transition: a caller now gets
# several samples across that window instead of a single one, so a transition
# that lands partway through is not missed just because it had not landed by
# the FIRST sample.
# Empirical evidence (docs/herdr-backend.md "Current transport behavior"):
# real Claude and Codex observed first-working at 90-490ms
# after Enter, so a several-hundred-ms budget sampled repeatedly reliably
# catches it. The remaining, inherent gap - a turn so fast it starts AND
# returns to idle between two samples - is bounded by how tightly <polls> is
# packed into <budget-seconds>; nothing observed in real testing has come
# close to that, but it is a residual risk, not a mathematical impossibility
# (see the doc section for the full characterization and the failure-mode
# analysis for both directions this must guard).
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

fm_backend_herdr_task_id_for_display_label() {  # <label>
  local want=$1 state record data label owner found='' count=0
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_BACKEND_HERDR_ROOT}/state}
  for record in "$state"/*.meta "$state"/*.herdr-label; do
    [ -f "$record" ] || continue
    owner=$(basename "$record")
    owner=${owner%.meta}
    owner=${owner%.herdr-label}
    data=$(fm_task_label_read_record "$record" "$owner" 2>/dev/null) || continue
    label=${data%%$'\t'*}
    [ "$label" = "$want" ] || continue
    if [ -z "$found" ]; then
      found=$owner
      count=1
    elif [ "$found" != "$owner" ]; then
      count=2
    fi
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$found"
}

fm_backend_herdr_task_id_for_exact_ids() {  # <session> <workspace> <tab> <pane>
  local session=$1 wsid=$2 tab_id=$3 pane_id=$4 state record owner found='' count=0
  local backend record_session record_workspace record_tab record_pane
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_BACKEND_HERDR_ROOT}/state}
  for record in "$state"/*.meta; do
    [ -f "$record" ] || continue
    backend=$(grep '^backend=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$backend" = herdr ] || continue
    record_session=$(grep '^herdr_session=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    record_workspace=$(grep '^herdr_workspace_id=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    record_tab=$(grep '^herdr_tab_id=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    record_pane=$(grep '^herdr_pane_id=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$record_session" = "$session" ] || continue
    [ "$record_workspace" = "$wsid" ] || continue
    [ "$record_tab" = "$tab_id" ] || continue
    [ "$record_pane" = "$pane_id" ] || continue
    owner=$(basename "$record" .meta)
    if [ -z "$found" ]; then
      found=$owner
      count=1
    elif [ "$found" != "$owner" ]; then
      count=2
    fi
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$found"
}

# Recovery prefers exact persisted ids, then a uniquely recorded display
# label, while retaining legacy fm-<id> discovery.
fm_backend_herdr_list_live() {  # <session> [workspace]
  local session=$1 wsid=${2:-} tabs rows row tab_id label pane_id task_id reported
  [ -n "$wsid" ] || wsid=$(fm_backend_herdr_workspace_find "$session") || return 1
  [ -n "$wsid" ] || return 0
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e '
    (.result | type) == "object"
    and (.result.tabs | type) == "array"
    and all(.result.tabs[]; type == "object" and (.tab_id | type) == "string" and (.label | type) == "string")
  ' >/dev/null 2>&1 || return 1
  rows=$(printf '%s' "$tabs" | jq -c '
    def has_unsafe_controls:
      any(explode[];
        (. >= 0 and . <= 31)
        or . == 127
        or (. >= 8234 and . <= 8238)
        or (. >= 8294 and . <= 8297));
    .result.tabs[]
    | select(.tab_id | has_unsafe_controls | not)
    | select(.label | has_unsafe_controls | not)
    | [.tab_id, .label]
  ') || return 1
  [ -n "$rows" ] || return 0
  while IFS= read -r row; do
    tab_id=$(printf '%s' "$row" | jq -r '.[0]') || return 1
    label=$(printf '%s' "$row" | jq -r '.[1]') || return 1
    [ -n "$tab_id" ] || continue
    pane_id=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || return 1
    [ -n "$pane_id" ] || return 1
    reported=$label
    if task_id=$(fm_backend_herdr_task_id_for_exact_ids "$session" "$wsid" "$tab_id" "$pane_id"); then
      reported="fm-$task_id"
    else
      case "$label" in
        fm-*) fm_task_label_task_id_is_valid "${label#fm-}" || continue ;;
        *)
          fm_task_label_validate_display_label "$label" >/dev/null 2>&1 || continue
          if task_id=$(fm_backend_herdr_task_id_for_display_label "$label"); then
            reported="fm-$task_id"
          fi
          ;;
      esac
    fi
    printf '%s:%s\t%s\t%s\n' "$session" "$pane_id" "$reported" "$label"
  done <<<"$rows"
}

# --- native event push: pane.agent_status_changed subscriber -----------------
#
# The push half of the immediate blocked-state escalation (AGENTS.md section 8,
# docs/herdr-backend.md "Push events and polling fallback").
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

fm_backend_herdr_create_task() {  # <container> <label> <cwd> [seeded-default-tab]
  local container=$1 label=$2 cwd=$3 session wsid list duplicate out tab_id pane_id
  session=${container%%:*}
  wsid=${container#*:}
  list=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  duplicate=$(printf '%s' "$list" | jq -r --arg want "$label" \
    '.result.tabs[]? | select(.label == $want) | .tab_id' 2>/dev/null) || return 1
  [ -z "$duplicate" ] || {
    echo "error: herdr tab '$label' already exists in workspace $wsid (session $session)" >&2
    return 1
  }
  out=$(fm_backend_herdr_cli "$session" tab create --workspace "$wsid" \
    --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || return 1
  tab_id=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane_id=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  [ -n "$tab_id" ] && [ -n "$pane_id" ] || return 1
  printf '%s %s' "$tab_id" "$pane_id"
}

fm_backend_herdr_kill() {  # <target> [pid] [start-time]
  local target=$1 expected_pid=${2:-} expected_start=${3:-} state
  fm_backend_herdr_target_ready "$target" || return 1
  state=$(fm_backend_herdr_pane_agent_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")
  case "$state" in
    dead) return 0 ;;
    live)
      [ -n "$expected_pid" ] && [ -n "$expected_start" ] || return 1
      fm_backend_herdr_provider_close_bound \
        "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" "$expected_pid" \
        "$expected_start" || return 1
      ;;
    *) return 1 ;;
  esac
  [ "$(fm_backend_herdr_pane_agent_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" = dead ]
}
