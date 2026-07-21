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
# per task inside its home's workspace. An optional, default-off presentation
# flag creates a disposable workspace for a clean fresh task instead. That
# workspace is a non-authoritative visual projection containing only the normal
# task pane. Its random token and journal never authorize lookup, adoption,
# reuse, closure, deletion, task ownership, or endpoint selection. Ambiguous or
# recovered launches use the default flat home workspace when duplicate-agent
# risk is independently absent. Target resolution stays parallel to the tmux
# adapter in both layouts.
# Projected create, move, and cleanup operations capture the named session's
# exact active workspace and tab. Herdr 0.7.4's last-pane close can focus an
# unrelated neighbor, so projected cleanup serializes and restores only the
# exact pre-close tab id, while refusing to close the active tab itself.
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
# stored pane id blindly: fm_backend_herdr_list_live. The presentation journal
# is deliberately excluded from that path.
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
# workspace.move first appears in the protocol-16 schema.
# The installed CLI does not expose it as a workspace subcommand, so the
# presentation path uses one narrowly whitelisted raw-socket request after
# verifying the exact method and parameter schema.
FM_BACKEND_HERDR_MIN_WORKSPACE_MOVE_PROTOCOL=16
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
# The default-off presentation projection is intentionally separate from the
# authoritative task endpoint record.
# A per-task journal lives under state/ as <id>.herdr-presentation and records
# only the attempted projection's random correlator.
# No send, capture, kill, recovery, Treehouse, or ownership path reads it.
FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX=".herdr-presentation"

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

# fm_backend_herdr_projection_id: generate a compact 128-bit base64url token.
# The token is a non-adversarial visual correlator, never destructive
# authority.
fm_backend_herdr_projection_id() {
  local token
  token=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null \
    | base64 \
    | tr '+/' '-_' \
    | tr -d '=\r\n') || return 1
  [ "${#token}" -eq 22 ] || return 1
  case "$token" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  printf '%s' "$token"
}

fm_backend_herdr_projection_journal_path() {  # <state-dir> <task-id>
  printf '%s/%s%s' "$1" "$2" "$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"
}

# fm_backend_herdr_projection_journal_create: atomically publish the
# non-authoritative attempt journal before any projection workspace create.
# A hard-link publication in the same state directory gives create-if-absent
# semantics, so concurrent attempts cannot overwrite each other's token.
fm_backend_herdr_projection_journal_create() {  # <state-dir> <task-id>
  local state=$1 id=$2 journal token tmp
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*)
      echo "error: invalid task id for herdr presentation journal" >&2
      return 1
      ;;
  esac
  mkdir -p "$state" || return 1
  journal=$(fm_backend_herdr_projection_journal_path "$state" "$id")
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    echo "error: herdr presentation journal already exists for $id; refusing a concurrent or repeated projected create" >&2
    return 1
  fi
  token=$(fm_backend_herdr_projection_id) || {
    echo "error: could not generate a 128-bit herdr presentation projection id" >&2
    return 1
  }
  tmp=$(mktemp "$state/.${id}.herdr-presentation.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! ln "$tmp" "$journal" 2>/dev/null; then
    rm -f "$tmp"
    echo "error: herdr presentation journal appeared concurrently for $id; refusing projected create" >&2
    return 1
  fi
  rm -f "$tmp"
  printf '%s' "$token"
}

# fm_backend_herdr_projection_journal_token: validate and read a projection
# journal without sourcing it as shell code.
fm_backend_herdr_projection_journal_token() {  # <journal> <task-id>
  local journal=$1 id=$2 version recorded_id token lines
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  lines=$(wc -l < "$journal" 2>/dev/null | tr -d '[:space:]')
  [ "$lines" = 3 ] || return 1
  version=$(grep '^version=' "$journal" 2>/dev/null | cut -d= -f2- || true)
  recorded_id=$(grep '^task_id=' "$journal" 2>/dev/null | cut -d= -f2- || true)
  token=$(grep '^projection_id=' "$journal" 2>/dev/null | cut -d= -f2- || true)
  [ "$version" = 1 ] && [ "$recorded_id" = "$id" ] && [ "${#token}" -eq 22 ] || return 1
  case "$token" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  printf '%s' "$token"
}

fm_backend_herdr_projection_workspace_label() {  # <task-id> <projection-id>
  printf '%s/%s · p:%s' "$(fm_backend_herdr_workspace_label)" "$1" "$2"
}

# fm_backend_herdr_projection_focus_snapshot: print the exact active
# workspace and tab ids as one tab-separated record.
# Presentation mutations use this read-only snapshot as their sole focus
# restoration authority.
# Labels, workspace order, and ambient client state are never focus authority.
fm_backend_herdr_projection_focus_snapshot() {  # <session>
  local session=$1 list snapshot workspace tab tabs
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  snapshot=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.workspace_id | length) > 0)
    | select((.active_tab_id | type) == "string" and (.active_tab_id | length) > 0)
    | [.workspace_id, .active_tab_id]
    | @tsv
  ' 2>/dev/null) || return 1
  [ -n "$snapshot" ] || return 1
  workspace=${snapshot%%$'\t'*}
  tab=${snapshot#*$'\t'}
  [ -n "$workspace" ] && [ -n "$tab" ] && [ "$workspace" != "$tab" ] || return 1
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    (.result.tabs | type) == "array"
    and ([.result.tabs[] | select(.focused == true)] | length) == 1
    and ([.result.tabs[] | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s\t%s' "$workspace" "$tab"
}

# fm_backend_herdr_projection_focus_restore: verify that one presentation
# mutation preserved the exact active workspace and tab captured immediately
# before it.
# Herdr 0.7.4's pane.close can focus an unrelated neighboring workspace when
# it removes a non-focused workspace's last pane.
# A single tab.focus on the exact response-independent pre-operation tab id
# restores both the workspace and tab atomically.
fm_backend_herdr_projection_focus_restore() {  # <session> <snapshot> <operation>
  local session=$1 before=$2 operation=$3 workspace tab after info restored
  [ -n "$before" ] || {
    echo "warning: herdr presentation $operation had no unambiguous pre-operation focus snapshot" >&2
    return 1
  }
  after=$(fm_backend_herdr_projection_focus_snapshot "$session") || after=
  [ "$after" != "$before" ] || return 0
  workspace=${before%%$'\t'*}
  tab=${before#*$'\t'}
  info=$(fm_backend_herdr_cli "$session" tab get "$tab" 2>/dev/null) || {
    echo "warning: herdr presentation $operation changed focus and the exact prior tab could not be verified for restoration" >&2
    return 1
  }
  if ! printf '%s' "$info" | jq -e --arg workspace "$workspace" --arg tab "$tab" '
    .result.tab.workspace_id == $workspace and .result.tab.tab_id == $tab
  ' >/dev/null 2>&1; then
    echo "warning: herdr presentation $operation changed focus and the exact prior tab response was ambiguous" >&2
    return 1
  fi
  fm_backend_herdr_cli "$session" tab focus "$tab" >/dev/null 2>&1 || {
    echo "warning: herdr presentation $operation changed focus and exact-tab restoration failed" >&2
    return 1
  }
  restored=$(fm_backend_herdr_projection_focus_snapshot "$session") || restored=
  if [ "$restored" != "$before" ]; then
    echo "warning: herdr presentation $operation did not restore the exact prior workspace and tab" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_projection_close_pane_focus_preserving: close one exact
# response-derived projection pane without leaving the captain focused
# anywhere else.
# If the target belongs to the active tab, exact tab preservation is
# impossible, so cleanup refuses instead of changing focus.
fm_backend_herdr_projection_close_pane_focus_preserving() {  # <session> <pane-id>
  local session=$1 pane_id=$2 before active_tab info target_pane target_tab close_status
  [ -n "$pane_id" ] || return 0
  before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "warning: herdr presentation cleanup could not capture exact active workspace and tab; refusing focus-unsafe pane close" >&2
    return 1
  }
  active_tab=${before#*$'\t'}
  info=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>/dev/null) || {
    echo "warning: herdr presentation cleanup could not verify the exact pane; refusing focus-unsafe pane close" >&2
    return 1
  }
  target_pane=$(printf '%s' "$info" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  target_tab=$(printf '%s' "$info" | jq -r '.result.pane.tab_id // empty' 2>/dev/null)
  if [ "$target_pane" != "$pane_id" ] || [ -z "$target_tab" ]; then
    echo "warning: herdr presentation cleanup received an ambiguous exact-pane response; refusing focus-unsafe pane close" >&2
    return 1
  fi
  if [ "$target_tab" = "$active_tab" ]; then
    echo "warning: herdr presentation cleanup target is the captain's active tab; refusing a close that cannot preserve focus" >&2
    return 1
  fi
  if fm_backend_herdr_cli "$session" pane close "$pane_id" >/dev/null 2>&1; then
    close_status=0
  else
    close_status=$?
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$before" "pane close" || true
  return "$close_status"
}

# fm_backend_herdr_projection_order_best_effort: place the exact workspace id
# returned by THIS projected create after the existing contiguous primary
# worker prefix and before every other workspace.
#
# This is presentation-only and always returns success.
# Every unavailable, ambiguous, failed, or unverifiable ordering step prints a
# warning and leaves the safely-created worker running in Herdr's current
# order.
# It never looks up a task endpoint, adopts or reuses a workspace, retries an
# ambiguous move, restores focus, or calls any close/delete primitive.
# Existing worker and secondmate workspace ids are read only to validate stable
# relative order; the sole move target is <created-workspace-id>, captured
# directly from the current workspace-create response.
fm_backend_herdr_projection_order_best_effort() {  # <session> <created-workspace-id>
  local session=$1 created=$2 list analysis current desired protocol schema sessions socket mover response move_status focus_before
  local before_secondmates before_workers after_secondmates after_workers
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    echo "warning: herdr presentation ordering could not list workspaces; leaving worker in Herdr's current order" >&2
    return 0
  }
  analysis=$(printf '%s' "$list" | jq -c --arg created "$created" '
    def primary_worker:
      (.label | type) == "string"
      and (.label | test("^firstmate/.+ · p:[A-Za-z0-9_-]{22}$"));
    (.result.workspaces // null) as $spaces
    | select(($spaces | type) == "array" and ($spaces | length) > 0)
    | ([range(0; $spaces | length) | select($spaces[.].workspace_id == $created)]) as $matches
    | select(($matches | length) == 1)
    | ($matches[0]) as $current
    | select($current == (($spaces | length) - 1))
    | select($spaces[0].label == "firstmate")
    | ($spaces[1:$current]) as $before
    | ([range(0; $before | length) | select(($before[.] | primary_worker) | not)] | first // ($before | length)) as $prefix
    | select(([$before[$prefix:][]? | select(primary_worker)] | length) == 0)
    | {
        current: $current,
        desired: (1 + $prefix),
        secondmates: [$spaces[] | select((.label | type) == "string" and (.label | startswith("2ndmate-"))) | .workspace_id],
        workers: [$spaces[] | select(primary_worker and .workspace_id != $created) | .workspace_id]
      }
  ' 2>/dev/null) || analysis=
  [ -n "$analysis" ] || {
    echo "warning: herdr presentation ordering found an ambiguous workspace layout; leaving worker in Herdr's current order" >&2
    return 0
  }
  current=$(printf '%s' "$analysis" | jq -r '.current // empty' 2>/dev/null)
  desired=$(printf '%s' "$analysis" | jq -r '.desired // empty' 2>/dev/null)
  case "$current:$desired" in
    *[!0-9:]*)
      echo "warning: herdr presentation ordering could not parse the target position; leaving worker in Herdr's current order" >&2
      return 0
      ;;
  esac
  [ "$current" != "$desired" ] || return 0

  command -v python3 >/dev/null 2>&1 || {
    echo "warning: herdr presentation ordering requires python3; leaving worker in Herdr's current order" >&2
    return 0
  }
  protocol=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*)
      echo "warning: herdr presentation ordering could not verify the client protocol; leaving worker in Herdr's current order" >&2
      return 0
      ;;
  esac
  if [ "$protocol" -lt "$FM_BACKEND_HERDR_MIN_WORKSPACE_MOVE_PROTOCOL" ]; then
    echo "warning: herdr presentation ordering needs protocol $FM_BACKEND_HERDR_MIN_WORKSPACE_MOVE_PROTOCOL or newer; leaving worker in Herdr's current order" >&2
    return 0
  fi
  schema=$(fm_backend_herdr_cli "$session" api schema --json 2>/dev/null) || {
    echo "warning: herdr presentation ordering could not read the API schema; leaving worker in Herdr's current order" >&2
    return 0
  }
  if ! printf '%s' "$schema" | jq -e '
    any(.schemas.request.oneOf[]?; .properties.method.const == "workspace.move")
    and .schemas.request["$defs"].WorkspaceMoveParams.required == ["workspace_id", "insert_index"]
    and .schemas.request["$defs"].WorkspaceMoveParams.properties.insert_index.type == "integer"
  ' >/dev/null 2>&1; then
    echo "warning: herdr presentation ordering API support is unavailable or ambiguous; leaving worker in Herdr's current order" >&2
    return 0
  fi
  sessions=$(fm_backend_herdr_cli "$session" session list --json 2>/dev/null) || {
    echo "warning: herdr presentation ordering could not resolve the named session socket; leaving worker in Herdr's current order" >&2
    return 0
  }
  socket=$(printf '%s' "$sessions" | jq -r --arg want "$session" '
    [.sessions[]? | select(.name == $want and .running == true) | .socket_path]
    | if length == 1 then .[0] else empty end
  ' 2>/dev/null)
  [ -n "$socket" ] || {
    echo "warning: herdr presentation ordering found an ambiguous named session socket; leaving worker in Herdr's current order" >&2
    return 0
  }

  mover=${FM_BACKEND_HERDR_WORKSPACE_MOVER:-$FM_BACKEND_HERDR_ROOT/bin/backends/herdr-workspace-move.py}
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "warning: herdr presentation ordering could not capture exact active workspace and tab; leaving worker in Herdr's current order" >&2
    return 0
  }
  if response=$("$mover" "$socket" "$created" "$desired" 2>/dev/null); then
    move_status=0
  else
    move_status=$?
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "workspace move" || true
  if [ "$move_status" -ne 0 ]; then
    echo "warning: herdr presentation workspace move failed or had an ambiguous response; leaving worker running without cleanup" >&2
    return 0
  fi
  if ! printf '%s' "$response" | jq -e --arg created "$created" --argjson desired "$desired" '
    .result.type == "workspace_list"
    and (.result.workspaces | type) == "array"
    and .result.workspaces[$desired].workspace_id == $created
    and .result.workspaces[0].label == "firstmate"
  ' >/dev/null 2>&1; then
    echo "warning: herdr presentation workspace move returned an unverifiable order; leaving worker running without cleanup" >&2
    return 0
  fi

  before_secondmates=$(printf '%s' "$analysis" | jq -c '.secondmates' 2>/dev/null)
  before_workers=$(printf '%s' "$analysis" | jq -c '.workers' 2>/dev/null)
  after_secondmates=$(printf '%s' "$response" | jq -c '[.result.workspaces[] | select((.label | type) == "string" and (.label | startswith("2ndmate-"))) | .workspace_id]' 2>/dev/null)
  after_workers=$(printf '%s' "$response" | jq -c --arg created "$created" '[.result.workspaces[] | select((.label | type) == "string" and (.label | test("^firstmate/.+ · p:[A-Za-z0-9_-]{22}$")) and .workspace_id != $created) | .workspace_id]' 2>/dev/null)
  if [ "$after_secondmates" != "$before_secondmates" ] \
     || [ "$after_workers" != "$before_workers" ]; then
    echo "warning: herdr presentation workspace move did not preserve relative order; leaving worker running without cleanup" >&2
  fi
  return 0
}

# fm_backend_herdr_server_ensure: start the herdr server for <session>
# headless (no TUI client) if not already running, mirroring tmux's `tmux
# has-session || tmux new-session -d`. Verified: a bare socket CLI call does
# NOT auto-start the server, so this must run before any workspace/tab/pane
# call. Bounded poll for the server to report running.
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
# Read-only, safe for recovery/list paths. Label-collision semantics
# (docs/herdr-backend.md "Label collisions"): herdr enforces no label
# uniqueness at all, so this adopts the FIRST matching workspace `jq` returns
# (list order, normally creation order/oldest) rather than disambiguating -
# identical in spirit to the pre-existing tab duplicate-label check below.
fm_backend_herdr_workspace_find() {  # <session>
  local session=$1 label list
  label=$(fm_backend_herdr_workspace_label)
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 0
  # NOTE: the jq variable is $want, NOT $label - `label` is a jq reserved
  # keyword (label/break), so declaring a jq variable named "label" is a
  # compile error that `2>/dev/null` would silently swallow, making this find
  # ALWAYS return empty and every spawn mint a fresh "firstmate" workspace
  # (the workspace leak).
  printf '%s' "$list" | jq -r --arg want "$label" \
    '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null | head -1
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
fm_backend_herdr_workspace_prune_seeded_default_tab() {  # <session> <workspace_id> <seeded_tab_id> [focus-preserving]
  local session=$1 wsid=$2 tab_id=$3 close_mode=${4:-direct} tabs tab_count current_label pane_id agent_out agent_status
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
  if [ "$close_mode" = focus-preserving ]; then
    fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$pane_id"
  else
    fm_backend_herdr_cli "$session" pane close "$pane_id" >/dev/null 2>&1 || true
  fi
}

# fm_backend_herdr_workspace_ensure: this HOME's persistent workspace inside
# <session>, creating it in <cwd> if absent. Must be called as a PLAIN
# STATEMENT, never through command substitution ($(...)) - it communicates
# through these globals, not solely through stdout, and a command
# substitution forks a subshell that would discard them:
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
#                                      ADOPTED a pre-existing workspace
#                                      (fm_backend_herdr_workspace_find
#                                      matched by label - docs/herdr-backend.md
#                                      "Label collisions": that match can
#                                      never distinguish an explicitly
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
fm_backend_herdr_workspace_ensure() {  # <session> <cwd>
  local session=$1 cwd=$2 wsid out label
  FM_BACKEND_HERDR_WS_ID=""
  FM_BACKEND_HERDR_WS_SEEDED_TAB_ID=""
  wsid=$(fm_backend_herdr_workspace_find "$session")
  if [ -n "$wsid" ]; then
    FM_BACKEND_HERDR_WS_ID=$wsid
    printf '%s' "$wsid"
    return 0
  fi
  label=$(fm_backend_herdr_workspace_label)
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

# fm_backend_herdr_agent_alive: CONFIDENT liveness of a live harness-agent
# PROCESS under <target> ("<session>:<pane_id>"), for the same
# session-start secondmate-liveness sweep fm_backend_tmux_agent_alive serves
# (bin/fm-bootstrap.sh; docs/herdr-backend.md "Agent liveness probe reuses the
# husk classifier"). Reuses fm_backend_herdr_pane_agent_state, the
# already-verified husk classifier ("Respawn idempotency" above): `dead`
# (structurally gone pane) and `no-agent` (a restored, agent-less bare shell
# - EXACTLY the shape a dead secondmate leaves behind) both collapse to
# `dead`; `live` (a real registered agent_status, including idle/blocked)
# maps to `alive`; `unknown` stays `unknown` - fail-safe toward refusal,
# exactly like the husk check itself. Callers must never treat `unknown` as a
# confirmed-dead signal.
fm_backend_herdr_agent_alive() {  # <target>
  local target=$1
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  case "$(fm_backend_herdr_pane_agent_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" in
    dead|no-agent) printf 'dead' ;;
    live) printf 'alive' ;;
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

# fm_backend_herdr_projection_create_task: create one disposable presentation
# workspace and its normal fm-<id> task tab without looking up, adopting, or
# reusing any existing workspace.
# The caller must atomically publish the projection journal first.
# This function sets exact response-derived globals and prints nothing:
#   FM_BACKEND_HERDR_PROJECTION_SESSION
#   FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
#   FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID
#   FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
#   FM_BACKEND_HERDR_PROJECTION_TAB_ID
#   FM_BACKEND_HERDR_PROJECTION_PANE_ID
#   FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE
# CLEANUP_SAFE becomes 1 only after both creates returned complete exact IDs.
# A missing, failed, or malformed create response stays ambiguous and grants no
# cleanup authority.
fm_backend_herdr_projection_create_task() {  # <cwd> <workspace-label> <task-label>
  local cwd=$1 workspace_label=$2 task_label=$3 session out tabs panes tab_count pane_count focus_before
  FM_BACKEND_HERDR_PROJECTION_SESSION=""
  FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID=""
  FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID=""
  FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID=""
  FM_BACKEND_HERDR_PROJECTION_TAB_ID=""
  FM_BACKEND_HERDR_PROJECTION_PANE_ID=""
  FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE=0

  fm_backend_herdr_version_check || return 1
  session=$(fm_backend_herdr_session)
  fm_backend_herdr_server_ensure "$session" || return 1
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "error: herdr presentation workspace create could not capture exact active workspace and tab; refusing a focus-unsafe projection" >&2
    return 1
  }
  if out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$cwd" --label "$workspace_label" --no-focus 2>/dev/null); then
    :
  else
    fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "workspace create" || true
    echo "error: herdr presentation workspace create failed ambiguously; leaving its journal quarantined" >&2
    return 1
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "workspace create" || {
    echo "error: herdr presentation workspace create did not preserve exact active focus; leaving its journal quarantined" >&2
    return 1
  }
  # shellcheck disable=SC2034  # caller consumes the response-derived global
  FM_BACKEND_HERDR_PROJECTION_SESSION=$session
  FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" ] \
     || [ -z "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" ] \
     || [ -z "$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID" ]; then
    echo "error: herdr presentation workspace create returned incomplete IDs; leaving its journal quarantined" >&2
    return 1
  fi

  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "error: herdr presentation task-tab create could not capture exact active workspace and tab; refusing a focus-unsafe projection" >&2
    return 1
  }
  if out=$(fm_backend_herdr_cli "$session" tab create \
    --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
    --cwd "$cwd" --label "$task_label" --no-focus 2>/dev/null); then
    :
  else
    fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "task-tab create" || true
    echo "error: herdr presentation task-tab create failed ambiguously; leaving its journal quarantined" >&2
    return 1
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "task-tab create" || {
    echo "error: herdr presentation task-tab create did not preserve exact active focus; leaving its journal quarantined" >&2
    return 1
  }
  FM_BACKEND_HERDR_PROJECTION_TAB_ID=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  FM_BACKEND_HERDR_PROJECTION_PANE_ID=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" ] || [ -z "$FM_BACKEND_HERDR_PROJECTION_PANE_ID" ]; then
    echo "error: herdr presentation task-tab create returned incomplete IDs; leaving its journal quarantined" >&2
    return 1
  fi
  # shellcheck disable=SC2034  # caller consumes the same-process cleanup gate
  FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE=1
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "error: herdr presentation seeded-tab prune could not capture exact active workspace and tab; refusing a focus-unsafe prune" >&2
    return 1
  }
  if ! fm_backend_herdr_workspace_prune_seeded_default_tab \
    "$session" \
    "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
    "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" \
    focus-preserving; then
    echo "error: herdr presentation seeded-tab prune refused a focus-unsafe close; leaving its journal quarantined" >&2
    return 1
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "seeded-tab prune" || {
    echo "error: herdr presentation seeded-tab prune did not preserve exact active focus; leaving its journal quarantined" >&2
    return 1
  }

  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" 2>/dev/null) || {
    echo "error: could not verify the disposable herdr presentation workspace shape" >&2
    return 1
  }
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" 2>/dev/null) || {
    echo "error: could not verify the disposable herdr presentation pane shape" >&2
    return 1
  }
  if ! printf '%s' "$tabs" | jq -e '(.result.tabs | type) == "array"' >/dev/null 2>&1 \
     || ! printf '%s' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1; then
    echo "error: could not parse the disposable herdr presentation workspace shape" >&2
    return 1
  fi
  tab_count=$(printf '%s' "$tabs" | jq -r '.result.tabs | length' 2>/dev/null)
  pane_count=$(printf '%s' "$panes" | jq -r '.result.panes | length' 2>/dev/null)
  if [ "$tab_count" != 1 ] || [ "$pane_count" != 1 ] \
     || ! printf '%s' "$tabs" | jq -e --arg task "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" \
       --arg seeded "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" \
       '.result.tabs[0].tab_id == $task and ([.result.tabs[] | select(.tab_id == $seeded)] | length) == 0' >/dev/null 2>&1 \
     || ! printf '%s' "$panes" | jq -e --arg pane "$FM_BACKEND_HERDR_PROJECTION_PANE_ID" \
       --arg tab "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" \
       '.result.panes[0].pane_id == $pane and .result.panes[0].tab_id == $tab' >/dev/null 2>&1; then
    echo "error: disposable herdr presentation workspace did not converge to exactly one task pane" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_projection_cleanup_exact: same-process abort cleanup for a
# projection whose create calls returned complete exact IDs.
# It performs no lookup and never calls workspace close.
fm_backend_herdr_projection_cleanup_exact() {  # <session> <task-pane> <seeded-pane>
  local session=$1 task_pane=$2 seeded_pane=$3
  [ -z "$task_pane" ] || fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$task_pane" || true
  if [ -n "$seeded_pane" ] && [ "$seeded_pane" != "$task_pane" ]; then
    fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$seeded_pane" || true
  fi
}

# fm_backend_herdr_projection_recovery_allows_flat: inspect an existing
# journal's exact token matches without adopting, reusing, renaming, closing,
# or deleting anything.
# Missing matches safely degrade to the normal flat workspace.
# One or more matches allow flat fallback only when every pane is positively
# dead or agent-free; a live or unknown pane refuses a duplicate launch.
fm_backend_herdr_projection_recovery_allows_flat() {  # <session> <journal> <task-id>
  local session=$1 journal=$2 id=$3 token list wsids count wsid panes pane_ids pane state
  token=$(fm_backend_herdr_projection_journal_token "$journal" "$id") || {
    echo "error: malformed herdr presentation journal for $id; refusing duplicate launch" >&2
    return 1
  }
  fm_backend_herdr_server_ensure "$session" || {
    echo "error: could not inspect the quarantined herdr presentation for $id; refusing duplicate launch" >&2
    return 1
  }
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    echo "error: could not list herdr workspaces while inspecting the quarantined presentation for $id" >&2
    return 1
  }
  if ! printf '%s' "$list" | jq -e '(.result.workspaces | type) == "array"' >/dev/null 2>&1; then
    echo "error: could not parse herdr workspaces while inspecting the quarantined presentation for $id" >&2
    return 1
  fi
  wsids=$(printf '%s' "$list" | jq -r --arg suffix " · p:$token" \
    '.result.workspaces[]? | select((.label | type) == "string" and (.label | endswith($suffix))) | .workspace_id' 2>/dev/null)
  count=$(printf '%s\n' "$wsids" | awk 'NF { n += 1 } END { print n + 0 }')
  if [ "$count" -eq 0 ]; then
    echo "warning: no exact herdr presentation token match for $id; leaving any stale space untouched and spawning flat" >&2
    return 0
  fi
  if [ "$count" -gt 1 ]; then
    echo "warning: $count exact herdr presentation token matches for $id are quarantined; inspecting only for duplicate-agent risk" >&2
  fi
  while IFS= read -r wsid; do
    [ -n "$wsid" ] || continue
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || {
      echo "error: could not inspect herdr presentation workspace $wsid for $id; refusing duplicate launch" >&2
      return 1
    }
    if ! printf '%s' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1; then
      echo "error: could not parse herdr presentation workspace $wsid for $id; refusing duplicate launch" >&2
      return 1
    fi
    pane_ids=$(printf '%s' "$panes" | jq -r '.result.panes[]? | .pane_id' 2>/dev/null)
    while IFS= read -r pane; do
      [ -n "$pane" ] || continue
      state=$(fm_backend_herdr_pane_agent_state "$session" "$pane")
      case "$state" in
        dead|no-agent) : ;;
        live|unknown)
          echo "error: quarantined herdr presentation for $id has a $state pane; refusing duplicate launch" >&2
          return 1
          ;;
      esac
    done <<EOF
$pane_ids
EOF
  done <<EOF
$wsids
EOF
  echo "warning: quarantined herdr presentation for $id is dead or agent-free; leaving it untouched and spawning flat" >&2
  return 0
}

# fm_backend_herdr_projection_endpoint_matches_journal: read-only correlation
# for retiring a successful projection journal after normal exact-pane
# teardown.
# Exactly one token-bearing workspace must match the endpoint workspace.
# This verdict never authorizes a Herdr mutation.
fm_backend_herdr_projection_endpoint_matches_journal() {  # <session> <workspace-id> <journal> <task-id>
  local session=$1 workspace_id=$2 journal=$3 id=$4 token list matches
  token=$(fm_backend_herdr_projection_journal_token "$journal" "$id") || return 1
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e '(.result.workspaces | type) == "array"' >/dev/null 2>&1 || return 1
  matches=$(printf '%s' "$list" | jq -r --arg suffix " · p:$token" \
    '.result.workspaces[]? | select((.label | type) == "string" and (.label | endswith($suffix))) | .workspace_id' 2>/dev/null)
  [ "$matches" = "$workspace_id" ]
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
#              0.142.x, both under herdr 0.7.1, docs/herdr-backend.md
#              "Incident (2026-07-07)"): the row's TRIMMED content starts with
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

fm_backend_herdr_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 session pane cap line trimmed found=0 shape="" raw_match="" bordered=0 stripped
  local identity agent agent_status row=0 generic_line=0
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
  fm_composer_classify_content "$bordered" "$stripped" "$FM_BACKEND_HERDR_IDLE_RE"
}

# fm_backend_herdr_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then submit with a named Enter key, retried
# (Enter only, never retyped) until herdr's NATIVE agent-state (agent get)
# confirms a real turn started. Verified hazard (herdr-verification-p2.md
# "slash/$ autocomplete popup"): a `/`- or `$`-prefixed send opens a
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
# not get wrong - see docs/herdr-backend.md "Native agent-state submit
# confirmation" for the empirical timing behind this):
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
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 verdict baseline confirm_sleep
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_herdr_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  baseline=$(fm_backend_herdr_classify_submit_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")")
  confirm_sleep=$(fm_backend_herdr_submit_confirm_budget "$sleep_s")
  while :; do
    fm_backend_herdr_send_key "$target" Enter || true
    if [ "$baseline" = idle ]; then
      verdict=$(fm_backend_herdr_wait_for_working "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" \
        "$confirm_sleep" "$FM_BACKEND_HERDR_SUBMIT_POLLS")
    else
      sleep "$sleep_s"
      verdict=$(fm_backend_herdr_composer_state "$target")
    fi
    case "$verdict" in
      busy) printf 'empty'; return 0 ;;
      empty) printf 'empty'; return 0 ;;
      unknown) printf 'unknown'; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# fm_backend_herdr_kill: remove the task's pane, best-effort (mirrors
# tmux-kill-window's `|| true` contract). Verified: closing a tab's only pane
# closes the tab too, so a separate tab close is unnecessary.
fm_backend_herdr_kill() {  # <target>
  fm_backend_herdr_target_ready "$1" || return 0
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane close "$FM_BACKEND_HERDR_PANE" >/dev/null 2>&1 || true
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
# Empirical evidence (docs/herdr-backend.md "Native agent-state submit
# confirmation"): real claude and codex observed first-working at 90-490ms
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
