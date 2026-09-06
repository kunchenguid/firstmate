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
# per task inside its home's workspace. The default-on presentation projection
# creates a disposable workspace for a clean fresh task instead unless the home
# opts out. That
# workspace is a non-authoritative visual projection containing only the normal
# task pane. Its random token and mutable label never authorize lookup,
# adoption, reuse, closure, deletion, task ownership, or endpoint selection.
# A version 2 journal can participate in replacing only its exact same-identity
# endpoint after metadata, home, session, workspace, tab, pane, parent, shape,
# focus, and agent-absence checks all agree under the session lock.
# Every ambiguous recovered launch uses the default flat home workspace when
# duplicate-agent risk is independently absent.
# Target resolution stays parallel to the tmux adapter in both layouts.
# Projected create, move, and cleanup operations capture the named session's
# exact active workspace and tab. On Herdr 0.7.5, an explicit close that
# empties a non-focused workspace moves focus to that workspace's neighbor
# (upstream discussion #1328, fixed by PR #1877), while a pane-death removal
# preserves focus exactly when the dying workspace sits behind the focused
# one or the focused one is last (upstream issue #1621, fixed by PR #1912);
# both fixes first shipped in Herdr 0.8.0, which is the version floor for
# default-on projection (FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION). Projected cleanup
# therefore serializes under the session lock, repositions a doomed workspace
# behind the focused one when needed, and ends its verified lone idle shell
# so Herdr removes the emptied workspace through the focus-preserving
# pane-death path, with the exact pre-close tab restore as the backstop and a
# refusal to close the active tab itself.
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
# The version floor for DEFAULT-ON presentation projection. Projection turns
# every crewmate teardown into a workspace-emptying removal, and the focus-safe
# removal plan can only avoid Herdr's focus-stealing explicit close while the
# doomed pane holds a provably lone idle childless shell; a persistent child of
# that shell (gitstatusd, a zsh-async worker, direnv) makes the plan fall back
# to the plain explicit close, which steals focus on every release without the
# two upstream focus fixes (PR #1877 commit 165dca45, PR #1912 commit a979916).
# Herdr 0.8.0 is the first release carrying both, so a home that configured
# nothing is projected only at or above it. An explicit "on" is still honored
# below the floor.
# Protocol 19 is the structural signal for that floor, measured against the real
# macOS aarch64 release binaries (docs/verification/runtime-backends.md
# "Presentation version floor"): 0.7.3 and 0.7.4 report 16, 0.7.5 reports 17,
# the first post-fix preview reports 18, and 0.8.0 reports 19. No build lacking
# both fixes reaches 19, and the pre-fix builds top out at 17.
FM_BACKEND_HERDR_MIN_PRESENTATION_PROTOCOL=19
FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION=0.8.0
# One-warning-per-release dedupe marker prefix, under the state dir. The
# projection decision is remade on every spawn, so an undeduplicated
# below-floor warning would repeat on every crewmate; the key is the detected
# release, so an upgrade or a downgrade is announced again.
FM_BACKEND_HERDR_PRESENTATION_FLOOR_MARKER_PREFIX=".herdr-presentation-floor-"
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
# The presentation projection is intentionally separate from the authoritative
# task endpoint record.
# A per-task journal lives under state/ as <id>.herdr-presentation.
# Version 1 records only the attempted projection's random correlator.
# Version 2 additionally binds the successful projection's exact home,
# session, workspace, tab, pane, parent, and presentation labels so a resumed
# spawn can replace one verified agent-free husk under the session lock.
# No send, capture, Treehouse, or general task-ownership path reads it.
FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX=".herdr-presentation"

# The config item a home writes to opt out of, or explicitly in to, the
# projection.
FM_BACKEND_HERDR_PRESENTATION_CONFIG="herdr-presentation-spaces"

# fm_backend_herdr_presentation_preference <config-dir>: the single owner of
# config/herdr-presentation-spaces parsing. Echoes exactly one of "off", "on"
# (a deliberate opt-in, honored even below the version floor), or "default"
# (this home configured nothing, so the floor decides).
# Values are read with the whole-file whitespace-stripped convention the other
# scalar config items already use (config/backlog-backend, config/crew-harness),
# plus case folding. An empty file is the historical presence-based opt-in form
# and still means an explicit "on", so no home that deliberately enabled the
# projection can lose it. An unrecognized value warns and falls back to the
# default rather than failing a spawn over a purely visual setting, so a typo is
# visible instead of silently deciding anything.
fm_backend_herdr_presentation_preference() {  # <config-dir>
  local config_dir=${1:-} file value
  [ -n "$config_dir" ] || { printf 'default\n'; return 0; }
  file="$config_dir/$FM_BACKEND_HERDR_PRESENTATION_CONFIG"
  [ -f "$file" ] || { printf 'default\n'; return 0; }
  value=$(tr -d '[:space:]' < "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]') || value=""
  case "$value" in
    off) printf 'off\n' ;;
    ''|on) printf 'on\n' ;;
    *)
      echo "warning: $file: unrecognized value \"$value\"; herdr presentation spaces fall back to the default (write \"off\" to opt out, \"on\" to force the projection on)" >&2
      printf 'default\n'
      ;;
  esac
}

# fm_backend_herdr_version_at_least <candidate> <floor>: numeric dotted-release
# comparison. Return codes: 0 candidate >= floor, 1 candidate < floor, 2 the
# candidate is unparseable. Any prerelease or build suffix is stripped first, so
# a 0.8.0-preview build compares as 0.8.0 (it is built from the 0.8.0 line and
# carries its fixes) while a 0.7.5-preview build compares as 0.7.5.
fm_backend_herdr_version_at_least() {  # <candidate> <floor>
  local candidate=${1:-} floor=${2:-} c f
  candidate=${candidate%%[-+]*}
  case "$candidate" in ''|*[!0-9.]*) return 2 ;; esac
  while [ -n "$floor" ]; do
    c=${candidate%%.*}
    f=${floor%%.*}
    [ -n "$c" ] || c=0
    [ "$c" -gt "$f" ] 2>/dev/null && return 0
    [ "$c" -lt "$f" ] 2>/dev/null && return 1
    case "$candidate" in *.*) candidate=${candidate#*.} ;; *) candidate= ;; esac
    case "$floor" in *.*) floor=${floor#*.} ;; *) floor= ;; esac
  done
  return 0
}

# fm_backend_herdr_release_floor_verdict <protocol> <version>: the pure
# classifier for the presentation version floor. Return codes: 0 at or above the
# floor, 1 provably below it, 2 indeterminate.
# Two independent signals are read so no single field is load-bearing, and
# either one can carry a positive verdict: the protocol number, which is the
# structural signal this adapter already uses for every other capability gate,
# and the release core of the version string. A signal that is unreadable or
# unparseable simply cannot carry a verdict; a readable protocol below the floor
# is decisive on its own, and only losing BOTH signals reports indeterminate.
fm_backend_herdr_release_floor_verdict() {  # <protocol> <version>
  local protocol=${1:-} version=${2:-} protocol_known=0 version_status=0
  case "$protocol" in
    ''|*[!0-9]*) ;;
    *)
      protocol_known=1
      [ "$protocol" -ge "$FM_BACKEND_HERDR_MIN_PRESENTATION_PROTOCOL" ] && return 0
      ;;
  esac
  fm_backend_herdr_version_at_least "$version" "$FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION" \
    || version_status=$?
  [ "$version_status" -eq 0 ] && return 0
  { [ "$protocol_known" -eq 1 ] || [ "$version_status" -eq 1 ]; } && return 1
  return 2
}

# fm_backend_herdr_presentation_release_supported: run the floor classifier
# against the installed client and, when one exists, the selected session's
# running server. A running server and client compose conservatively: both must
# be supported. When status positively reports no running server, only the
# client that will start it is applicable. Same return codes as
# fm_backend_herdr_release_floor_verdict, and sets
# FM_BACKEND_HERDR_PRESENTATION_RELEASE to the identifier a caller's warning
# names. An unreadable server-running state is indeterminate rather than
# permission to substitute the client release.
fm_backend_herdr_presentation_release_supported() {  # [<session>]
  local session=${1:-} status running client_protocol client_version client_verdict=0
  local server_protocol server_version server_verdict=0
  FM_BACKEND_HERDR_PRESENTATION_RELEASE="an unreadable release"
  command -v herdr >/dev/null 2>&1 || return 2
  command -v jq >/dev/null 2>&1 || return 2
  [ -n "$session" ] || session=$(fm_backend_herdr_session)
  status=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null) || return 2
  client_protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null) || return 2
  client_version=$(printf '%s' "$status" | jq -r '.client.version // empty' 2>/dev/null) || return 2
  fm_backend_herdr_release_floor_verdict "$client_protocol" "$client_version" || client_verdict=$?
  running=$(printf '%s' "$status" | jq -r '
    if .server.running == true then "true"
    elif .server.running == false then "false"
    else "unknown"
    end
  ' 2>/dev/null) || return 2
  case "$running" in
    true)
      server_protocol=$(printf '%s' "$status" | jq -r '.server.protocol // empty' 2>/dev/null) || return 2
      server_version=$(printf '%s' "$status" | jq -r '.server.version // empty' 2>/dev/null) || return 2
      fm_backend_herdr_release_floor_verdict "$server_protocol" "$server_version" || server_verdict=$?
      if [ "$server_verdict" -eq 1 ]; then
        FM_BACKEND_HERDR_PRESENTATION_RELEASE="server version ${server_version:-unknown} (protocol ${server_protocol:-unknown})"
        return 1
      fi
      if [ "$client_verdict" -eq 1 ]; then
        FM_BACKEND_HERDR_PRESENTATION_RELEASE="version ${client_version:-unknown} (protocol ${client_protocol:-unknown})"
        return 1
      fi
      if [ "$server_verdict" -ne 0 ]; then
        FM_BACKEND_HERDR_PRESENTATION_RELEASE="server version ${server_version:-unknown} (protocol ${server_protocol:-unknown})"
        return 2
      fi
      if [ "$client_verdict" -ne 0 ]; then
        FM_BACKEND_HERDR_PRESENTATION_RELEASE="version ${client_version:-unknown} (protocol ${client_protocol:-unknown})"
        return 2
      fi
      return 0
      ;;
    false)
      FM_BACKEND_HERDR_PRESENTATION_RELEASE="version ${client_version:-unknown} (protocol ${client_protocol:-unknown})"
      return "$client_verdict"
      ;;
    *) return 2 ;;
  esac
}

# fm_backend_herdr_presentation_floor_warn <state-dir> <verdict>: emit the one
# clear below-floor warning, deduplicated per home per detected release when a
# usable state dir is given. Without one the warning is emitted every call,
# which is what a one-shot caller wants.
fm_backend_herdr_presentation_floor_warn() {  # <state-dir> <verdict>
  local state_dir=${1:-} verdict=${2:-2} release=${FM_BACKEND_HERDR_PRESENTATION_RELEASE:-an unreadable release} key marker reason tmp=""
  if [ "$verdict" -eq 1 ]; then
    reason="herdr $release is older than the $FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION floor for presentation spaces, where projected cleanup can steal the active workspace"
  else
    reason="the selected herdr release could not be read, so the $FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION floor for presentation spaces cannot be verified"
  fi
  if [ -n "$state_dir" ] && [ -d "$state_dir" ] && [ ! -L "$state_dir" ]; then
    key=${release//[^a-zA-Z0-9]/-}
    marker="$state_dir/$FM_BACKEND_HERDR_PRESENTATION_FLOOR_MARKER_PREFIX$key"
    { [ -e "$marker" ] || [ -L "$marker" ]; } && return 0
    tmp=$(umask 077; mktemp "$state_dir/.herdr-presentation-floor.XXXXXX" 2>/dev/null) || tmp=""
    if [ -n "$tmp" ]; then
      if ln "$tmp" "$marker" 2>/dev/null; then
        rm -f -- "$tmp"
      else
        rm -f -- "$tmp"
        { [ -e "$marker" ] || [ -L "$marker" ]; } && return 0
      fi
    fi
  fi
  echo "warning: $reason; using the ordinary flat layout instead. Upgrade herdr to $FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION or newer (herdr update) to restore the projection, or write \"on\" into config/$FM_BACKEND_HERDR_PRESENTATION_CONFIG to force it on this release." >&2
  return 0
}

# fm_backend_herdr_presentation_default_supported <state-dir> [<session>]:
# compose the applicable release verdict and the shared warning contract for
# one unconfigured home.
fm_backend_herdr_presentation_default_supported() {  # <state-dir> [<session>]
  local state_dir=${1:-} session=${2:-} verdict=0
  fm_backend_herdr_presentation_release_supported "$session" || verdict=$?
  [ "$verdict" -eq 0 ] && return 0
  fm_backend_herdr_presentation_floor_warn "$state_dir" "$verdict"
  return 1
}

# fm_backend_herdr_presentation_enabled <config-dir> [<state-dir>]: the one gate
# bin/fm-spawn.sh consults before projecting this home's children into
# disposable one-task workspaces (docs/herdr-backend.md "Presentation spaces"
# owns the full contract). An explicit "off" or "on" is obeyed as written; a
# home that configured nothing is projected only at or above the version floor,
# and otherwise falls back to the flat layout with one warning. Sets
# FM_BACKEND_HERDR_PRESENTATION_PREFERENCE for the new-projection boundary to
# distinguish an unconfigured default from an explicit opt-in.
fm_backend_herdr_presentation_enabled() {  # <config-dir> [<state-dir>]
  local config_dir=${1:-} state_dir=${2:-} preference
  preference=$(fm_backend_herdr_presentation_preference "$config_dir")
  # bin/fm-spawn.sh reads this out-parameter after sourcing this adapter.
  # shellcheck disable=SC2034
  FM_BACKEND_HERDR_PRESENTATION_PREFERENCE=$preference
  case "$preference" in
    off) return 1 ;;
    on) return 0 ;;
  esac
  fm_backend_herdr_presentation_default_supported "$state_dir"
}

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

fm_backend_herdr_projection_journal_field() {  # <journal> <key>
  local journal=$1 key=$2 count
  count=$(grep -c "^${key}=" "$journal" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$journal" 2>/dev/null | cut -d= -f2-
}

# fm_backend_herdr_projection_journal_snapshot: validate a version 1 attempt
# journal or a version 2 exact projection binding without sourcing shell code.
# Version 2 sets FM_BACKEND_HERDR_JOURNAL_* globals for same-process callers.
fm_backend_herdr_projection_journal_snapshot() {  # <journal> <task-id>
  local journal=$1 id=$2 lines expected_label expected_task_label exact
  FM_BACKEND_HERDR_JOURNAL_VERSION=""
  FM_BACKEND_HERDR_JOURNAL_TASK_ID=""
  FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID=""
  FM_BACKEND_HERDR_JOURNAL_HOME=""
  FM_BACKEND_HERDR_JOURNAL_SESSION=""
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID=""
  FM_BACKEND_HERDR_JOURNAL_TAB_ID=""
  FM_BACKEND_HERDR_JOURNAL_PANE_ID=""
  FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID=""
  FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL=""
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL=""
  FM_BACKEND_HERDR_JOURNAL_TASK_LABEL=""
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  lines=$(wc -l < "$journal" 2>/dev/null | tr -d '[:space:]')
  FM_BACKEND_HERDR_JOURNAL_VERSION=$(fm_backend_herdr_projection_journal_field "$journal" version) || return 1
  FM_BACKEND_HERDR_JOURNAL_TASK_ID=$(fm_backend_herdr_projection_journal_field "$journal" task_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID=$(fm_backend_herdr_projection_journal_field "$journal" projection_id) || return 1
  [ "$FM_BACKEND_HERDR_JOURNAL_TASK_ID" = "$id" ] || return 1
  [ "${#FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID}" -eq 22 ] || return 1
  case "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  case "$FM_BACKEND_HERDR_JOURNAL_VERSION:$lines" in
    1:3) return 0 ;;
    2:12) ;;
    *) return 1 ;;
  esac
  FM_BACKEND_HERDR_JOURNAL_HOME=$(fm_backend_herdr_projection_journal_field "$journal" home) || return 1
  FM_BACKEND_HERDR_JOURNAL_SESSION=$(fm_backend_herdr_projection_journal_field "$journal" session) || return 1
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID=$(fm_backend_herdr_projection_journal_field "$journal" workspace_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_TAB_ID=$(fm_backend_herdr_projection_journal_field "$journal" tab_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_PANE_ID=$(fm_backend_herdr_projection_journal_field "$journal" pane_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID=$(fm_backend_herdr_projection_journal_field "$journal" parent_workspace_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL=$(fm_backend_herdr_projection_journal_field "$journal" parent_label) || return 1
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL=$(fm_backend_herdr_projection_journal_field "$journal" workspace_label) || return 1
  FM_BACKEND_HERDR_JOURNAL_TASK_LABEL=$(fm_backend_herdr_projection_journal_field "$journal" task_label) || return 1
  case "$FM_BACKEND_HERDR_JOURNAL_HOME" in
    /*) ;;
    *) return 1 ;;
  esac
  for exact in \
    "$FM_BACKEND_HERDR_JOURNAL_SESSION" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID"; do
    case "$exact" in
      ''|*[[:space:]]*) return 1 ;;
    esac
  done
  [ -n "$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL" ] \
    && [ -n "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" ] \
    && [ -n "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL" ] || return 1
  expected_label=$(fm_backend_herdr_projection_workspace_label "$id" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID")
  expected_task_label="fm-$id"
  [ "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" = "$expected_label" ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL" = "$expected_task_label" ]
}

# fm_backend_herdr_projection_journal_token: validate and read either journal
# version's non-authoritative visual correlator.
fm_backend_herdr_projection_journal_token() {  # <journal> <task-id>
  fm_backend_herdr_projection_journal_snapshot "$1" "$2" || return 1
  printf '%s' "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID"
}

fm_backend_herdr_projection_home_identity() {  # <home>
  local home=$1
  [ -d "$home" ] || return 1
  (cd "$home" 2>/dev/null && pwd -P)
}

fm_backend_herdr_projection_journal_write_v2() {  # <journal> <task-id> <token> <home> <session> <workspace> <tab> <pane> <parent-workspace> <parent-label> <workspace-label> <task-label>
  local journal=$1 id=$2 token=$3 home=$4 session=$5 workspace=$6 tab=$7 pane=$8
  local parent_workspace=$9 parent_label=${10} workspace_label=${11} task_label=${12} state tmp
  state=$(dirname "$journal")
  tmp=$(mktemp "$state/.${id}.herdr-presentation.bind.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! {
    printf 'version=2\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
    printf 'home=%s\n' "$home"
    printf 'session=%s\n' "$session"
    printf 'workspace_id=%s\n' "$workspace"
    printf 'tab_id=%s\n' "$tab"
    printf 'pane_id=%s\n' "$pane"
    printf 'parent_workspace_id=%s\n' "$parent_workspace"
    printf 'parent_label=%s\n' "$parent_label"
    printf 'workspace_label=%s\n' "$workspace_label"
    printf 'task_label=%s\n' "$task_label"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  [ -f "$journal" ] && [ ! -L "$journal" ] || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$journal"
}

# fm_backend_herdr_projection_journal_bind: upgrade one exact version 1
# attempt to a version 2 binding after the live projection and parent relation
# have both been verified under the session lock.
fm_backend_herdr_projection_journal_bind() {  # <journal> <task-id> <home> <session> <workspace> <tab> <pane> <parent-workspace> <parent-label> <workspace-label> <task-label>
  local journal=$1 id=$2 home=$3 session=$4 workspace=$5 tab=$6 pane=$7
  local parent_workspace=$8 parent_label=$9 workspace_label=${10} task_label=${11} token
  fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || return 1
  [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 1 ] || return 1
  token=$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID
  fm_backend_herdr_projection_journal_write_v2 \
    "$journal" "$id" "$token" "$home" "$session" "$workspace" "$tab" "$pane" \
    "$parent_workspace" "$parent_label" "$workspace_label" "$task_label"
}

# fm_backend_herdr_projection_journal_replace_endpoint: atomically advance one
# exact version 2 binding after its old husk was replaced successfully.
fm_backend_herdr_projection_journal_replace_endpoint() {  # <journal> <task-id> <old-tab> <old-pane> <new-tab> <new-pane>
  local journal=$1 id=$2 old_tab=$3 old_pane=$4 new_tab=$5 new_pane=$6
  fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || return 1
  [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" = "$old_tab" ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" = "$old_pane" ] || return 1
  fm_backend_herdr_projection_journal_write_v2 \
    "$journal" "$id" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_HOME" "$FM_BACKEND_HERDR_JOURNAL_SESSION" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" "$new_tab" "$new_pane" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" "$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL"
}

# fm_backend_herdr_projection_concise_task_label: strip redundant owner
# prefixes from a task id used only in the presentation workspace label.
# Removes firstmate/, 2ndmate-<id>/, and a presentation-level fm- owner
# prefix when present. The ordinary task tab remains fm-<id> and is not
# built by this helper.
fm_backend_herdr_projection_concise_task_label() {  # <task-id>
  local task=$1
  case "$task" in
    firstmate/*) task=${task#firstmate/} ;;
    2ndmate-*/*) task=${task#*/} ;;
  esac
  case "$task" in
    fm-*) task=${task#fm-} ;;
  esac
  printf '%s' "$task"
}

# fm_backend_herdr_projection_workspace_label: presentation-only child label.
# Format is literal U+2514 BOX DRAWINGS LIGHT UP AND RIGHT, one space, the
# concise task label, then the unchanged · p:<full-22-char-token> suffix.
# Labels and tokens remain non-authoritative correlators only.
fm_backend_herdr_projection_workspace_label() {  # <task-id> <projection-id>
  printf '└ %s · p:%s' "$(fm_backend_herdr_projection_concise_task_label "$1")" "$2"
}

# fm_backend_herdr_presentation_session_lock_path: one machine-private lock
# path per live named Herdr session/socket, shared across every Firstmate home
# that uses that session.
# The path is never under any one home's state/ and secondmates never write the
# primary home. Returns non-zero when the named session's socket cannot be
# resolved unambiguously.
fm_backend_herdr_presentation_lock_namespace() {
  printf '%s' '/tmp/firstmate-herdr-presentation'
}

fm_backend_herdr_presentation_lock_namespace_mode() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

fm_backend_herdr_presentation_lock_namespace_uid() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%u' "$1" 2>/dev/null
  else
    stat -c '%u' "$1" 2>/dev/null
  fi
}

fm_backend_herdr_presentation_lock_namespace_valid() {
  local dir=$1 expected_uid owner mode
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  expected_uid=$(id -u 2>/dev/null) || return 1
  owner=$(fm_backend_herdr_presentation_lock_namespace_uid "$dir") || return 1
  mode=$(fm_backend_herdr_presentation_lock_namespace_mode "$dir") || return 1
  [ "$owner" = "$expected_uid" ] && [ "$mode" = 700 ]
}

# Resolve the one verified running named-session socket path as an absolute
# string. Requires JSON string type and non-empty length (jq -r is never used:
# it would turn JSON null into the literal string "null"). Canonicalizes the
# parent directory when that directory exists so symlink parents such as /tmp
# -> /private/tmp cannot yield two lock identities for the same socket.
# fm_backend_herdr_canonical_socket_path: normalize one absolute Unix-socket
# path so two spellings of the same socket compare equal. Refuses a relative
# or empty path. An unresolvable directory is left as-is rather than treated as
# a failure, so a socket whose directory was removed still compares by its own
# literal path. Single owner for every socket-identity comparison in this
# adapter (the presentation session lock and the launcher-identity same-session
# proof both use it).
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

fm_backend_herdr_presentation_session_socket_path() {  # <session>
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

fm_backend_herdr_presentation_session_lock_path() {  # <session>
  local session=$1 socket key dir hash
  [ -n "$session" ] || return 1
  socket=$(fm_backend_herdr_presentation_session_socket_path "$session") || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s\0%s' "$session" "$socket" | shasum -a 256 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s\0%s' "$session" "$socket" | sha256sum 2>/dev/null | awk '{print $1}')
  else
    return 1
  fi
  [ -n "$hash" ] || return 1
  key=${hash:0:32}
  dir=$(fm_backend_herdr_presentation_lock_namespace) || return 1
  [ -n "$dir" ] || return 1
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    if ! mkdir -m 700 "$dir" 2>/dev/null; then
      fm_backend_herdr_presentation_lock_namespace_valid "$dir" || return 1
    fi
  fi
  fm_backend_herdr_presentation_lock_namespace_valid "$dir" || return 1
  printf '%s/order-%s.lock' "$dir" "$key"
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
# This is the backstop for every focus-unsafe instant: on Herdr 0.7.5 an
# explicit pane.close that empties a non-focused workspace moves focus to
# that workspace's neighbor (upstream #1328/#1877), and a pane-death removal
# before a non-last focused workspace moves focus to the focused workspace's
# right neighbor (upstream #1621/#1912); both fixes are unreleased.
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
# When the close would empty the target workspace, Herdr 0.7.5's explicit
# close moves focus to the workspace's neighbor, so the close is planned by
# fm_backend_herdr_emptying_close_plan: reposition the doomed workspace
# behind the focused one when needed, then end the pane's verified lone idle
# shell so Herdr removes the emptied workspace through its focus-preserving
# pane-death path. The exact-tab restore below remains the backstop, and any
# ambiguity falls back to the plain explicit close, which the backstop masks
# exactly as before this hardening.
fm_backend_herdr_projection_close_pane_focus_preserving() {  # <session> <pane-id> [required-agent-state]
  local session=$1 pane_id=$2 required_agent_state=${3:-}
  local before active_tab info target_pane target_tab target_ws close_status state plan plan_shell_pid plan_move_record workspace_presence
  FM_BACKEND_HERDR_PROJECTION_CLOSE_AGENT_STATE=""
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
  target_ws=$(printf '%s' "$info" | jq -r '.result.pane.workspace_id // empty' 2>/dev/null)
  if [ "$target_pane" != "$pane_id" ] || [ -z "$target_tab" ]; then
    echo "warning: herdr presentation cleanup received an ambiguous exact-pane response; refusing focus-unsafe pane close" >&2
    return 1
  fi
  if [ "$target_tab" = "$active_tab" ]; then
    echo "warning: herdr presentation cleanup target is the captain's active tab; refusing a close that cannot preserve focus" >&2
    return 1
  fi
  if [ -n "$required_agent_state" ]; then
    state=$(fm_backend_herdr_pane_agent_state "$session" "$pane_id")
    FM_BACKEND_HERDR_PROJECTION_CLOSE_AGENT_STATE=$state
    [ "$state" = "$required_agent_state" ] || return 1
  fi
  plan=plain
  plan_shell_pid=
  plan_move_record=
  if [ -n "$target_ws" ]; then
    plan=$(fm_backend_herdr_emptying_close_plan "$session" "$pane_id" "$target_ws" "$target_tab" "${before%%$'\t'*}")
    case "$plan" in
      moved$'\t'*)
        plan_move_record=${plan%%$'\n'*}
        plan=${plan##*$'\n'}
        ;;
    esac
    case "$plan" in
      death\ *)
        plan_shell_pid=${plan#death }
        plan=death
        ;;
      *)
        plan=plain
        ;;
    esac
  fi
  if [ "$plan" = death ]; then
    if fm_backend_herdr_death_close_pane "$session" "$pane_id" "$plan_shell_pid"; then
      close_status=0
    elif fm_backend_herdr_explicit_close_pane_confirmed "$session" "$pane_id"; then
      close_status=0
    else
      close_status=1
    fi
  elif fm_backend_herdr_explicit_close_pane_confirmed "$session" "$pane_id"; then
    close_status=0
  else
    close_status=1
  fi
  if [ "$close_status" -eq 0 ] && [ -n "$plan_move_record" ]; then
    workspace_presence=$(fm_backend_herdr_workspace_presence_state "$session" "$target_ws")
    if [ "$workspace_presence" != dead ]; then
      echo "warning: herdr presentation cleanup did not confirm removal of the repositioned workspace" >&2
      close_status=1
    fi
  fi
  if [ "$close_status" -ne 0 ]; then
    fm_backend_herdr_emptying_move_rollback "$plan_move_record" || true
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$before" "pane close" || return 2
  [ "$close_status" -eq 0 ]
}

# Herdr 0.7.5 workspace-removal focus rules (verified against the installed
# 0.7.5 binary, its v0.7.5 tag source, and the isolated named lab):
# - An EXPLICIT close that empties a workspace (API pane.close of its last
#   pane, tab close, or workspace close) routes through
#   close_selected_workspace, which assigns focus to the closing workspace's
#   right neighbor (or the new last workspace when it was last), ignoring the
#   previously focused workspace entirely (upstream discussion #1328, fixed
#   by PR #1877, commit 165dca45).
# - A PANE-DEATH removal (handle_pane_died) keeps the focused index stale,
#   which preserves the exact focused workspace whenever the dying workspace
#   sat behind it (or the focused workspace was last), and moves focus to the
#   focused workspace's right neighbor otherwise (upstream issue #1621, fixed
#   by PR #1912, commit a979916).
# Both fixes first shipped in Herdr 0.8.0 (protocol 19), verified 2026-08-05.
# Firstmate therefore removes a doomed non-focused workspace by ending its
# verified lone idle shell (the pane-death path), repositioning it behind the
# focused workspace first when needed. Moving it to the end preserves every
# other workspace's relative order, so no presentation ordering change
# persists.
# That reasoning covers the pane-death route only. The plan's plain-close
# FALLBACK is reachable exactly when the doomed pane's shell cannot be proved
# lone, childless, and idle - a persistent gitstatusd, zsh-async worker, or
# direnv fails that proof permanently - and on a release without both fixes the
# fallback is the focus-stealing close itself, so the mitigation is conditional
# rather than unconditional and a version gate IS required. Default-on
# projection is therefore floored at FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION,
# where every removal primitive preserves focus and the proof stops being
# load-bearing. That floor has ONE owner, the spawn-time gate
# fm_backend_herdr_presentation_enabled, so every new projection is either on a
# supported release or is a home's deliberate below-floor opt-in. Session-start
# cleanup deliberately retires a leftover projection husk on every release,
# including below the floor. The accepted exposure is limited to the rare
# downgrade path where a home projected on Herdr 0.8.0 or newer and then moved
# to a 0.7.x release, and occurs once per leftover workspace at session start
# rather than once per task teardown; the exact prior-tab restore bounds it.
# Refusing that close below the floor would leak workspaces that nothing else
# removes and block teardown because fm-teardown treats an unconfirmed close as
# a hard stop. That cleanup is therefore authorized containment rather than a
# second gate, and the spawn-time gate remains the floor's sole owner.

# fm_backend_herdr_workspace_move_capable: verify that one guarded raw
# workspace.move request is possible in <session>: python3 for the transport,
# the minimum protocol, and the exact whitelisted method and parameter
# schema. Silent; each caller owns its own warning wording.
# Return codes: 1 python3 missing, 2 protocol unreadable, 3 protocol too old,
# 4 schema unreadable, 5 method or parameter schema unsupported.
fm_backend_herdr_workspace_move_capable() {  # <session>
  local session=$1 protocol schema
  command -v python3 >/dev/null 2>&1 || return 1
  protocol=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*) return 2 ;;
  esac
  [ "$protocol" -lt "$FM_BACKEND_HERDR_MIN_WORKSPACE_MOVE_PROTOCOL" ] && return 3
  schema=$(fm_backend_herdr_cli "$session" api schema --json 2>/dev/null) || return 4
  printf '%s' "$schema" | jq -e '
    any(.schemas.request.oneOf[]?; .properties.method.const == "workspace.move")
    and .schemas.request["$defs"].WorkspaceMoveParams.required == ["workspace_id", "insert_index"]
    and .schemas.request["$defs"].WorkspaceMoveParams.properties.insert_index.type == "integer"
  ' >/dev/null 2>&1 || return 5
}

# fm_backend_herdr_emptying_close_plan: choose the focus-safe removal for one
# exact pane. The LAST echoed line is the plan: "plain" (use the ordinary
# explicit close; below the presentation version floor the exact-tab restore
# backstop masks the focus move it causes when it empties a non-focused
# workspace) or "death <shell-pid>" (end the proved lone idle shell so Herdr
# removes the emptied workspace through its focus-preserving pane-death path).
# Whenever the repositioning mover was invoked, a preceding
# "moved<TAB><ws><TAB><original-index><TAB><socket><TAB><focused><TAB><pre-move-order-json>"
# record line is echoed first so the caller can hand it to
# fm_backend_herdr_emptying_move_rollback when removal is not confirmed.
# Never fails; every ambiguity plans "plain".
# The death plan requires the close to empty the workspace (exactly one tab
# and one pane, both the target), the target workspace to sit behind the
# focused one (repositioned to the end first when it does not, with the move
# verified against the server-returned order and focus), and the exact pane
# to hold one provably lone idle recognized shell.
fm_backend_herdr_emptying_close_plan() {  # <session> <pane-id> <workspace-id> <tab-id> <focused-workspace-id>
  local session=$1 pane_id=$2 ws_id=$3 tab_id=$4 focused_ws=$5
  local tabs panes list indices r rest a len capable socket mover response move_status shell_pid before_order
  [ -n "$ws_id" ] && [ -n "$tab_id" ] && [ -n "$focused_ws" ] || { printf 'plain\n'; return 0; }
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$ws_id" 2>/dev/null) || { printf 'plain\n'; return 0; }
  printf '%s' "$tabs" | jq -e --arg tab "$tab_id" '
    (.result.tabs | type) == "array" and (.result.tabs | length) == 1
    and .result.tabs[0].tab_id == $tab
  ' >/dev/null 2>&1 || { printf 'plain\n'; return 0; }
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$ws_id" 2>/dev/null) || { printf 'plain\n'; return 0; }
  printf '%s' "$panes" | jq -e --arg pane "$pane_id" '
    (.result.panes | type) == "array" and (.result.panes | length) == 1
    and .result.panes[0].pane_id == $pane
  ' >/dev/null 2>&1 || { printf 'plain\n'; return 0; }
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || { printf 'plain\n'; return 0; }
  indices=$(printf '%s' "$list" | jq -r --arg ws "$ws_id" --arg focused "$focused_ws" '
    (.result.workspaces // null) as $s
    | select(($s | type) == "array" and ($s | length) > 1)
    | ([range(0; $s | length) | select($s[.].workspace_id == $ws)]) as $w
    | ([range(0; $s | length) | select($s[.].workspace_id == $focused)]) as $f
    | select(($w | length) == 1 and ($f | length) == 1 and $w[0] != $f[0])
    | "\($w[0])\t\($f[0])\t\($s | length)"
  ' 2>/dev/null) || indices=
  if [ -z "$indices" ]; then
    printf 'plain\n'
    return 0
  fi
  r=${indices%%$'\t'*}
  rest=${indices#*$'\t'}
  a=${rest%%$'\t'*}
  len=${rest#*$'\t'}
  case "$r:$a:$len" in
    *[!0-9:]*)
      printf 'plain\n'
      return 0
      ;;
  esac
  if [ "$r" -lt "$a" ] && [ "$a" -lt $((len - 1)) ]; then
    # The doomed workspace sits before the focused one, where the pane-death
    # path would land focus on the focused workspace's right neighbor.
    # Reposition it behind everything first: insert_index equal to the list
    # length is the verified move-to-last form, and removing the moved
    # workspace afterward leaves every other relative order untouched.
    if fm_backend_herdr_workspace_move_capable "$session"; then
      capable=0
    else
      capable=$?
    fi
    if [ "$capable" -ne 0 ]; then
      echo "warning: herdr presentation cleanup could not verify workspace.move support; closing without the focus-safe removal path" >&2
      printf 'plain\n'
      return 0
    fi
    socket=$(fm_backend_herdr_presentation_session_socket_path "$session") || {
      echo "warning: herdr presentation cleanup found an ambiguous named session socket; closing without the focus-safe removal path" >&2
      printf 'plain\n'
      return 0
    }
    mover=${FM_BACKEND_HERDR_WORKSPACE_MOVER:-$FM_BACKEND_HERDR_ROOT/bin/backends/herdr-workspace-move.py}
    before_order=$(printf '%s' "$list" | jq -c '[.result.workspaces[].workspace_id]' 2>/dev/null)
    if response=$("$mover" "$socket" "$ws_id" "$len" 2>/dev/null); then
      move_status=0
    else
      move_status=$?
    fi
    # Every mover invocation is recorded, even an unverified one, so a later
    # unconfirmed removal can restore the exact original order; restoring an
    # unmoved workspace to its own position is a verified no-op.
    printf 'moved\t%s\t%s\t%s\t%s\t%s\n' "$ws_id" "$r" "$socket" "$focused_ws" "$before_order"
    if [ "$move_status" -ne 0 ] \
      || ! printf '%s' "$response" | jq -e --arg ws "$ws_id" --arg focused "$focused_ws" \
        --argjson before "$before_order" '
        ($before | map(select(. != $ws)) + [$ws]) as $expected
        | .result.type == "workspace_list"
        and ([.result.workspaces[].workspace_id] == $expected)
        and ([.result.workspaces[] | select(.focused == true) | .workspace_id] == [$focused])
      ' >/dev/null 2>&1; then
      echo "warning: herdr presentation cleanup could not move the doomed workspace behind the focused one; closing without the focus-safe removal path" >&2
      printf 'plain\n'
      return 0
    fi
  fi
  if shell_pid=$(fm_backend_herdr_pane_idle_shell_pid "$session" "$pane_id"); then
    printf 'death %s\n' "$shell_pid"
  else
    printf 'plain\n'
  fi
}

# fm_backend_herdr_emptying_move_rollback: restore the exact pre-move
# workspace order recorded by an emptying-close plan whose removal was not
# confirmed, under the caller's still-held session lock.
# <move-record> is the plan's tab-separated
# "moved<TAB><ws><TAB><original-index><TAB><socket><TAB><focused><TAB><pre-move-order-json>"
# line, or empty for a no-op when no move was attempted.
# The rollback is verified against the mover's returned order and focus and
# warns on any failure, so a lasting reorder is never silent.
fm_backend_herdr_emptying_move_rollback() {  # <move-record>
  local record=$1 marker ws index socket focused order mover response
  [ -n "$record" ] || return 0
  IFS=$'\t' read -r marker ws index socket focused order <<FMEOF
$record
FMEOF
  if [ "$marker" != moved ] || [ -z "$ws" ] || [ -z "$socket" ] || [ -z "$order" ]; then
    echo "warning: herdr presentation cleanup has a malformed move record after a failed removal; the workspace order may remain changed" >&2
    return 1
  fi
  case "$index" in
    ''|*[!0-9]*)
      echo "warning: herdr presentation cleanup has a malformed move record after a failed removal; the workspace order may remain changed" >&2
      return 1
      ;;
  esac
  mover=${FM_BACKEND_HERDR_WORKSPACE_MOVER:-$FM_BACKEND_HERDR_ROOT/bin/backends/herdr-workspace-move.py}
  if ! response=$("$mover" "$socket" "$ws" "$index" 2>/dev/null) \
    || ! printf '%s' "$response" | jq -e --argjson expected "$order" --arg focused "$focused" '
      .result.type == "workspace_list"
      and ([.result.workspaces[].workspace_id] == $expected)
      and ([.result.workspaces[] | select(.focused == true) | .workspace_id] == [$focused])
    ' >/dev/null 2>&1; then
    echo "warning: herdr presentation cleanup could not restore the original workspace order after a failed removal" >&2
    return 1
  fi
}

# fm_backend_herdr_death_close_pane: end the exact pane's proved lone idle
# shell so Herdr removes the emptied workspace through its focus-preserving
# pane-death path, then confirm the pane is gone.
# Each signal is sent only while the exact pane still owns the recorded pid
# as its lone idle shell: SIGHUP relies on the proof taken just before, and
# the SIGKILL escalation re-reads the pane's process information and refuses
# unless the same pid is still the pane's strict bare idle shell, so an
# exited or reused pid is never signaled.
# Returns 0 only when the pane is confirmed gone.
fm_backend_herdr_death_close_pane() {  # <session> <pane-id> <shell-pid>
  local session=$1 pane_id=$2 shell_pid=$3 ps_bin attempt max_attempts presence resampled_pid
  ps_bin=${FM_HERDR_PS_BIN:-ps}
  case "$shell_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  command -v "$ps_bin" >/dev/null 2>&1 || return 1
  max_attempts=${FM_BACKEND_HERDR_DEATH_CLOSE_POLLS:-40}
  fm_backend_herdr_pid_is_bare_shell "$ps_bin" "$shell_pid" || return 1
  kill -HUP "$shell_pid" 2>/dev/null || true
  attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane_id")
    [ "$presence" = dead ] && return 0
    sleep 0.05
    attempt=$((attempt + 1))
  done
  # SIGKILL escalation revalidates exact pane ownership, not just the pid: a
  # fresh strict pane sample must still name the SAME shell pid, so a pid
  # that exited and was reused by an unrelated process is never signaled.
  resampled_pid=$(fm_backend_herdr_pane_idle_shell_sample "$session" "$pane_id") || return 1
  [ "$resampled_pid" = "$shell_pid" ] || return 1
  fm_backend_herdr_pid_is_bare_shell "$ps_bin" "$shell_pid" || return 1
  kill -KILL "$shell_pid" 2>/dev/null || true
  attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane_id")
    [ "$presence" = dead ] && return 0
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

# fm_backend_herdr_pid_is_bare_shell: <pid> currently resolves to a bare
# recognized shell process per <ps-bin>.
# BSD ps reports comm as argv0, so a login shell arrives as "-zsh"; strip the
# login dash exactly like the idle-shell proof's argv0 normalization.
fm_backend_herdr_pid_is_bare_shell() {  # <ps-bin> <pid>
  local comm
  comm=$("$1" -p "$2" -o comm= 2>/dev/null) || return 1
  comm=$(printf '%s' "$comm" | tr -d '[:space:]')
  comm=${comm#-}
  comm=${comm##*/}
  case "$comm" in sh|bash|zsh|dash|ksh|fish) return 0 ;; esac
  return 1
}

# fm_backend_herdr_pane_idle_shell_pid: print the shell pid of <pane-id> only
# when the exact pane provably holds one lone idle recognized shell: pane
# process-info agrees on the pane id, the shell pid is both the foreground
# process group and the sole foreground process, the foreground process name
# and argv0 resolve to the same recognized shell, the operating-system
# process table shows exactly that one shell row with no child process, and
# the shell sits in a sleeping or idle state.
# An idle interactive shell transiently hosts short-lived prompt helpers
# (verified on the real 0.7.5 lab: a workspace.move relayout makes zsh redraw
# its prompt, spawning starship as a second foreground process for a few
# samples), so the proof retries strict single samples for a bounded settle
# window and succeeds on the first fully clean one; a genuinely busy pane
# fails every sample and still refuses.
# This is the single owner of the idle-shell proof; the session-start
# projection cleanup and every pane-death close path both rely on it.
fm_backend_herdr_pane_idle_shell_pid() {  # <session> <pane-id>
  local attempt=0 max_attempts=${FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS:-10}
  while :; do
    if fm_backend_herdr_pane_idle_shell_sample "$1" "$2"; then
      return 0
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$max_attempts" ] || return 1
    sleep 0.1
  done
}

# fm_backend_herdr_pane_idle_shell_sample: one strict instantaneous
# observation for fm_backend_herdr_pane_idle_shell_pid, which owns the proof
# contract and the settle retry.
fm_backend_herdr_pane_idle_shell_sample() {  # <session> <pane-id>
  local session=$1 pane=$2 info shell_pid foreground_pgid count
  local process_pid name argv0 shell_name rows stat ps_bin
  info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
  printf '%s' "$info" | jq -e --arg pane "$pane" '
    .result.type == "pane_process_info"
    and .result.process_info.pane_id == $pane
  ' >/dev/null 2>&1 || return 1
  shell_pid=$(printf '%s' "$info" | jq -er \
    '.result.process_info.shell_pid | select(type == "number" and . > 1) | floor' 2>/dev/null) || return 1
  foreground_pgid=$(printf '%s' "$info" | jq -er \
    '.result.process_info.foreground_process_group_id | select(type == "number" and . > 1) | floor' 2>/dev/null) || return 1
  [ "$foreground_pgid" = "$shell_pid" ] || return 1
  count=$(printf '%s' "$info" | jq -er \
    '.result.process_info.foreground_processes | select(type == "array") | length' 2>/dev/null) || return 1
  [ "$count" -eq 1 ] || return 1
  process_pid=$(printf '%s' "$info" | jq -er \
    '.result.process_info.foreground_processes[0].pid | select(type == "number") | floor' 2>/dev/null) || return 1
  [ "$process_pid" = "$shell_pid" ] || return 1
  name=$(printf '%s' "$info" | jq -er \
    '.result.process_info.foreground_processes[0].name | select(type == "string" and length > 0)' 2>/dev/null) || return 1
  argv0=$(printf '%s' "$info" | jq -er '
    .result.process_info.foreground_processes[0] as $process
    | ($process.argv0 // $process.argv[0])
    | select(type == "string" and length > 0)
  ' 2>/dev/null) || return 1
  shell_name=${name##*/}
  argv0=${argv0#-}
  argv0=${argv0##*/}
  [ "$argv0" = "$shell_name" ] || return 1
  case "$shell_name" in sh|bash|zsh|dash|ksh|fish) ;; *) return 1 ;; esac

  ps_bin=${FM_HERDR_PS_BIN:-ps}
  command -v "$ps_bin" >/dev/null 2>&1 || return 1
  rows=$("$ps_bin" -axo pid=,ppid= 2>/dev/null) || return 1
  printf '%s\n' "$rows" | awk -v shell="$shell_pid" '
    $1 == shell { found++ }
    $2 == shell { child++ }
    END { exit(found == 1 && child == 0 ? 0 : 1) }
  ' || return 1
  stat=$("$ps_bin" -p "$shell_pid" -o stat= 2>/dev/null | tr -d '[:space:]') || return 1
  case "$stat" in S*|I*) ;; *) return 1 ;; esac
  printf '%s\n' "$shell_pid"
}

# fm_backend_herdr_projection_order_best_effort: place the exact workspace id
# returned by THIS projected create immediately after its owning parent's
# contiguous child block and before the next parent.
#
# <parent-label> is the owning FM_HOME label (firstmate or 2ndmate-<id>).
# Optional <parent-workspace-id> is that parent's EXACT id, which the caller
# already resolved from the launching agent's own herdr identity. When given it
# anchors the owning parent by id, so two workspaces sharing the home label no
# longer make the whole layout ambiguous; when omitted the parent is located by
# label exactly as before. With a unique label the two select the same
# workspace, so ordering behavior is unchanged in the ordinary case.
# New-format └ ... · p:<token> children and, for compatibility only, already
# adjacent old-format firstmate/... or 2ndmate-<id>/... projections may extend
# the block read-only; they are never renamed or moved.
#
# This is presentation-only and always returns success.
# Every unavailable, ambiguous, failed, or unverifiable ordering step prints a
# warning and leaves the safely-created worker running in Herdr's current
# order.
# It never looks up a task endpoint, adopts or reuses a workspace, retries an
# ambiguous move, or calls any close/delete/rename primitive.
# The sole move target is <created-workspace-id>, captured directly from the
# current workspace-create response.
# After a successful move, every pre-existing workspace id sequence excluding
# the new id must be byte-identical to the pre-move sequence.
fm_backend_herdr_projection_order_best_effort() {  # <session> <created-workspace-id> <parent-label> [<parent-workspace-id>]
  local session=$1 created=$2 parent=$3 parent_ws=${4:-} list analysis current desired socket mover response move_status focus_before move_capable
  local before_existing after_existing
  [ -n "$parent" ] || {
    echo "warning: herdr presentation ordering missing owning parent label; leaving worker in Herdr's current order" >&2
    return 0
  }
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    echo "warning: herdr presentation ordering could not list workspaces; leaving worker in Herdr's current order" >&2
    return 0
  }
  analysis=$(printf '%s' "$list" | jq -c --arg created "$created" --arg parent "$parent" --arg parent_ws "$parent_ws" '
    def is_parent:
      if ($parent_ws | length) > 0
      then .workspace_id == $parent_ws
      else (.label | type) == "string" and .label == $parent
      end;
    def is_top_level_parent:
      (.label | type) == "string"
      and ((.label == "firstmate") or (.label | test("^2ndmate-[^/]+$")));
    def is_new_child:
      (.label | type) == "string"
      and (.label | test("^└ .+ · p:[A-Za-z0-9_-]{22}$"));
    def is_legacy_child:
      (.label | type) == "string"
      and (.label | test("^(firstmate|2ndmate-[^/]+)/.+ · p:[A-Za-z0-9_-]{22}$"));
    def is_legacy_child_for($owner):
      is_legacy_child and (.label | startswith($owner + "/"));
    def is_child_for($owner):
      is_new_child or is_legacy_child_for($owner);
    (.result.workspaces // null) as $spaces
    | select(($spaces | type) == "array" and ($spaces | length) > 0)
    | ([range(0; $spaces | length) | select($spaces[.].workspace_id == $created)]) as $matches
    | select(($matches | length) == 1)
    | ($matches[0]) as $current
    | select($current == (($spaces | length) - 1))
    | ([range(0; $spaces | length) | select($spaces[.] | is_parent)]) as $parents
    | select(($parents | length) == 1)
    | ($parents[0]) as $pidx
    | select($pidx < $current)
    | (
        reduce range($pidx + 1; $current) as $i (
          0;
          if ($spaces[$i] | is_child_for($parent)) and (. == ($i - $pidx - 1))
          then . + 1
          else .
          end
        )
      ) as $block
    | (reduce range($pidx + 1 + $block; $current) as $i (
        {valid: true, active_parent: null};
        if .valid == false then .
        elif ($spaces[$i] | is_top_level_parent) then
          .active_parent = $spaces[$i].label
        elif ($spaces[$i] | is_new_child) then
          if .active_parent == null then .valid = false else . end
        elif ($spaces[$i] | is_legacy_child) then
          .active_parent as $owner
          | if $owner == null then
              .valid = false
            elif (($spaces[$i] | is_legacy_child_for($owner)) | not) then
              .valid = false
            else
              .
            end
        else
          .active_parent = null
        end
      )) as $remainder
    | select($remainder.valid == true)
    | {
        current: $current,
        desired: ($pidx + 1 + $block),
        parent_index: $pidx,
        existing: [$spaces[] | select(.workspace_id != $created) | .workspace_id]
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

  if fm_backend_herdr_workspace_move_capable "$session"; then
    move_capable=0
  else
    move_capable=$?
  fi
  case "$move_capable" in
    0) ;;
    1)
      echo "warning: herdr presentation ordering requires python3; leaving worker in Herdr's current order" >&2
      return 0
      ;;
    2)
      echo "warning: herdr presentation ordering could not verify the client protocol; leaving worker in Herdr's current order" >&2
      return 0
      ;;
    3)
      echo "warning: herdr presentation ordering needs protocol $FM_BACKEND_HERDR_MIN_WORKSPACE_MOVE_PROTOCOL or newer; leaving worker in Herdr's current order" >&2
      return 0
      ;;
    4)
      echo "warning: herdr presentation ordering could not read the API schema; leaving worker in Herdr's current order" >&2
      return 0
      ;;
    *)
      echo "warning: herdr presentation ordering API support is unavailable or ambiguous; leaving worker in Herdr's current order" >&2
      return 0
      ;;
  esac
  socket=$(fm_backend_herdr_presentation_session_socket_path "$session") || {
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
  if ! printf '%s' "$response" | jq -e --arg created "$created" --arg parent "$parent" --arg parent_ws "$parent_ws" --argjson desired "$desired" '
    def is_parent:
      if ($parent_ws | length) > 0
      then .workspace_id == $parent_ws
      else (.label | type) == "string" and .label == $parent
      end;
    .result.type == "workspace_list"
    and (.result.workspaces | type) == "array"
    and .result.workspaces[$desired].workspace_id == $created
    and ([.result.workspaces[] | select(is_parent)] | length) == 1
    and (
      [range(0; .result.workspaces | length) as $i
        | select(.result.workspaces[$i] | is_parent)
        | $i][0] < $desired
    )
  ' >/dev/null 2>&1; then
    echo "warning: herdr presentation workspace move returned an unverifiable order; leaving worker running without cleanup" >&2
    return 0
  fi

  before_existing=$(printf '%s' "$analysis" | jq -c '.existing' 2>/dev/null)
  after_existing=$(printf '%s' "$response" | jq -c --arg created "$created" '[.result.workspaces[] | select(.workspace_id != $created) | .workspace_id]' 2>/dev/null)
  if [ "$after_existing" != "$before_existing" ]; then
    echo "warning: herdr presentation workspace move did not preserve relative order; leaving worker running without cleanup" >&2
  fi
  return 0
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
  session_socket=$(fm_backend_herdr_presentation_session_socket_path "$session") || {
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

fm_backend_herdr_workspace_presence_state() {  # <session> <workspace_id>
  local session=$1 workspace_id=$2 out matches
  out=$(fm_backend_herdr_cli "$session" workspace list 2>&1)
  matches=$(printf '%s' "$out" | jq -r --arg workspace "$workspace_id" '
    select((.result.workspaces | type) == "array")
    | [.result.workspaces[] | select(.workspace_id == $workspace)] | length
  ' 2>/dev/null) || matches=
  case "$matches" in
    0) printf 'dead' ;;
    1) printf 'present' ;;
    *) printf 'unknown' ;;
  esac
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

# fm_backend_herdr_pane_pid: <target>'s root process pid, Herdr's own pane
# process-info shell_pid, accepted only when the response echoes the exact pane
# id back (the same round-trip guard the idle-shell proof applies). Prints
# nothing and returns 1 on any other outcome, so a caller can never walk a
# process tree from a guessed root.
fm_backend_herdr_pane_pid() {  # <target>
  local info pid
  fm_backend_herdr_parse_target "$1" || return 1
  info=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane process-info --pane "$FM_BACKEND_HERDR_PANE" 2>/dev/null) || return 1
  pid=$(printf '%s' "$info" | jq -er --arg pane "$FM_BACKEND_HERDR_PANE" '
    select(.result.type == "pane_process_info" and .result.process_info.pane_id == $pane)
    | .result.process_info.shell_pid | select(type == "number" and . > 1) | floor
  ' 2>/dev/null) || return 1
  printf '%s\n' "$pid"
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

# fm_backend_herdr_projection_parent_workspace_exact: resolve one exact parent
# workspace only when its presentation label is unique in the named session.
fm_backend_herdr_projection_parent_workspace_exact() {  # <session> <parent-label>
  local session=$1 parent_label=$2 list
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$list" | jq -er --arg parent_label "$parent_label" '
    (.result.workspaces // null) as $spaces
    | select(($spaces | type) == "array")
    | [$spaces[]? | select(.label == $parent_label)]
    | if length == 1
        and (.[0].workspace_id | type) == "string"
        and (.[0].workspace_id | length) > 0
      then .[0].workspace_id
      else empty
      end
  ' 2>/dev/null
}

# fm_backend_herdr_projection_live_binding_matches: verify one exact projected
# workspace, its single task tab/pane, its unique token label, and its current
# position inside the exact parent workspace's contiguous child block.
# This read-only predicate grants no mutation authority by itself.
fm_backend_herdr_projection_live_binding_matches() {  # <session> <token> <workspace> <tab> <pane> <parent-workspace> <parent-label> <workspace-label> <task-label>
  local session=$1 token=$2 workspace=$3 tab=$4 pane=$5 parent_workspace=$6
  local parent_label=$7 workspace_label=$8 task_label=$9 list tabs panes
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e \
    --arg token "$token" \
    --arg workspace "$workspace" \
    --arg parent_workspace "$parent_workspace" \
    --arg parent_label "$parent_label" \
    --arg workspace_label "$workspace_label" '
      def is_new_child:
        (.label | type) == "string"
        and (.label | test("^└ .+ · p:[A-Za-z0-9_-]{22}$"));
      def is_legacy_child_for($owner):
        (.label | type) == "string"
        and (.label | test("^(firstmate|2ndmate-[^/]+)/.+ · p:[A-Za-z0-9_-]{22}$"))
        and (.label | startswith($owner + "/"));
      (.result.workspaces // null) as $spaces
      | select(($spaces | type) == "array")
      | select(([$spaces[]? | select(.workspace_id == $workspace)] | length) == 1)
      | select(([$spaces[]? | select(.workspace_id == $workspace and .label == $workspace_label)] | length) == 1)
      | select(([$spaces[]? | select((.label | type) == "string" and (.label | endswith(" · p:" + $token)))] | length) == 1)
      | select(([$spaces[]? | select((.label | type) == "string" and (.label | endswith(" · p:" + $token)) and .workspace_id == $workspace)] | length) == 1)
      | select(([$spaces[]? | select(.workspace_id == $parent_workspace and .label == $parent_label)] | length) == 1)
      | ([range(0; $spaces | length) | select($spaces[.].workspace_id == $parent_workspace)]) as $parents
      | ([range(0; $spaces | length) | select($spaces[.].workspace_id == $workspace)]) as $children
      | select(($parents | length) == 1 and ($children | length) == 1)
      | ($parents[0]) as $parent_index
      | ($children[0]) as $child_index
      | select($child_index > $parent_index)
      | reduce range($parent_index + 1; $child_index) as $i
          (true; . and (($spaces[$i] | is_new_child) or ($spaces[$i] | is_legacy_child_for($parent_label))))
      | select(. == true)
    ' >/dev/null 2>&1 || return 1
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" --arg task_label "$task_label" '
    (.result.tabs | type) == "array"
    and (.result.tabs | length) == 1
    and .result.tabs[0].tab_id == $tab
    and .result.tabs[0].label == $task_label
  ' >/dev/null 2>&1 || return 1
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e --arg tab "$tab" --arg pane "$pane" '
    (.result.panes | type) == "array"
    and (.result.panes | length) == 1
    and .result.panes[0].pane_id == $pane
    and .result.panes[0].tab_id == $tab
  ' >/dev/null 2>&1
}

fm_backend_herdr_projection_reclaim_rollback() {  # <session> <new-pane>
  local session=$1 new_pane=$2 state
  state=$(fm_backend_herdr_pane_agent_state "$session" "$new_pane")
  case "$state" in
    dead) return 0 ;;
    no-agent) ;;
    live|unknown) return 1 ;;
  esac
  fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$new_pane" no-agent || return 1
  [ "$(fm_backend_herdr_pane_agent_state "$session" "$new_pane")" = dead ]
}

# fm_backend_herdr_projection_reclaim_task: replace one exact agent-free
# restored projection husk inside its original workspace.
# The caller holds the session presentation lock and has already established
# that flat fallback is safe across every token match.
# Return 0 means exact reclaim, 2 means non-mutating or exactly rolled-back
# refusal with flat fallback permitted, and 1 means a live/unknown or
# post-mutation uncertainty that must refuse the launch.
fm_backend_herdr_projection_reclaim_task() {  # <session> <journal> <task-id> <home> <meta-workspace> <meta-tab> <meta-pane> <parent-label> <task-label> <cwd>
  local session=$1 journal=$2 id=$3 home=$4 meta_workspace=$5 meta_tab=$6 meta_pane=$7
  local parent_label=$8 task_label=$9 cwd=${10} canonical_home state focus_before active_tab out new_tab new_pane info close_status
  FM_BACKEND_HERDR_PROJECTION_TAB_ID=""
  FM_BACKEND_HERDR_PROJECTION_PANE_ID=""
  fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || return 1
  if [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" != 2 ]; then
    echo "warning: herdr presentation journal for $id has no exact restart binding; spawning flat" >&2
    return 2
  fi
  canonical_home=$(fm_backend_herdr_projection_home_identity "$home") || {
    echo "warning: herdr presentation home for $id could not be resolved exactly; spawning flat" >&2
    return 2
  }
  if [ "$FM_BACKEND_HERDR_JOURNAL_HOME" != "$canonical_home" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" != "$session" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" != "$meta_workspace" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" != "$meta_tab" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" != "$meta_pane" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL" != "$parent_label" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL" != "$task_label" ]; then
    echo "warning: herdr presentation binding for $id does not match its exact home, endpoint, or parent; spawning flat" >&2
    return 2
  fi
  if ! fm_backend_herdr_projection_live_binding_matches \
    "$session" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" \
    "$meta_workspace" "$meta_tab" "$meta_pane" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" "$parent_label" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" "$task_label"; then
    echo "warning: herdr presentation binding for $id has an ambiguous, renamed, foreign, or non-nested live shape; spawning flat" >&2
    return 2
  fi
  state=$(fm_backend_herdr_pane_agent_state "$session" "$meta_pane")
  case "$state" in
    no-agent) ;;
    dead)
      echo "warning: exact herdr presentation pane for $id is gone; spawning flat" >&2
      return 2
      ;;
    live|unknown)
      echo "error: exact herdr presentation pane for $id is $state; refusing duplicate launch" >&2
      return 1
      ;;
  esac
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "warning: herdr presentation reclaim for $id could not capture exact focus; spawning flat" >&2
    return 2
  }
  active_tab=${focus_before#*$'\t'}
  if [ "$active_tab" = "$meta_tab" ]; then
    echo "warning: herdr presentation reclaim for $id would replace the active tab; spawning flat" >&2
    return 2
  fi
  if ! out=$(fm_backend_herdr_cli "$session" tab create \
    --workspace "$meta_workspace" --cwd "$cwd" --label "$task_label" --no-focus 2>/dev/null); then
    fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "husk replacement create" || return 1
    echo "warning: herdr presentation reclaim for $id could not create an exact replacement; spawning flat" >&2
    return 2
  fi
  new_tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  new_pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$new_tab" ] || [ -z "$new_pane" ]; then
    fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "husk replacement create" || return 1
    echo "warning: herdr presentation reclaim for $id returned ambiguous replacement ids; spawning flat" >&2
    return 2
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "husk replacement create" || return 1
  info=$(fm_backend_herdr_cli "$session" tab get "$new_tab" 2>/dev/null) || info=
  if ! printf '%s' "$info" | jq -e --arg tab "$new_tab" --arg workspace "$meta_workspace" '
    .result.tab.tab_id == $tab and .result.tab.workspace_id == $workspace
  ' >/dev/null 2>&1; then
    fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
    echo "warning: herdr presentation reclaim for $id could not verify its replacement tab; spawning flat" >&2
    return 2
  fi
  info=$(fm_backend_herdr_cli "$session" pane get "$new_pane" 2>/dev/null) || info=
  if ! printf '%s' "$info" | jq -e --arg pane "$new_pane" --arg tab "$new_tab" --arg workspace "$meta_workspace" '
    .result.pane.pane_id == $pane
    and .result.pane.tab_id == $tab
    and .result.pane.workspace_id == $workspace
  ' >/dev/null 2>&1; then
    fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
    echo "warning: herdr presentation reclaim for $id could not verify its replacement pane; spawning flat" >&2
    return 2
  fi
  state=$(fm_backend_herdr_pane_agent_state "$session" "$meta_pane")
  case "$state" in
    no-agent) ;;
    live|unknown)
      fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
      echo "error: herdr presentation pane for $id became $state during reclaim; refusing duplicate launch" >&2
      return 1
      ;;
    dead)
      fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
      echo "warning: herdr presentation pane for $id disappeared during reclaim; spawning flat" >&2
      return 2
      ;;
  esac
  if fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$meta_pane" no-agent; then
    close_status=0
  else
    close_status=$?
  fi
  if [ "$close_status" -ne 0 ]; then
    if [ "$close_status" -eq 2 ]; then
      return 1
    fi
    state=$FM_BACKEND_HERDR_PROJECTION_CLOSE_AGENT_STATE
    fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
    case "$state" in
      live|unknown)
        echo "error: herdr presentation pane for $id became $state at the close boundary; refusing duplicate launch" >&2
        return 1
        ;;
    esac
    echo "warning: herdr presentation reclaim for $id could not close the exact old husk; spawning flat" >&2
    return 2
  fi
  if [ "$(fm_backend_herdr_pane_agent_state "$session" "$meta_pane")" != dead ]; then
    fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
    return 1
  fi
  if ! fm_backend_herdr_projection_live_binding_matches \
    "$session" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" \
    "$meta_workspace" "$new_tab" "$new_pane" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" "$parent_label" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" "$task_label"; then
    fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
    echo "warning: herdr presentation reclaim for $id did not converge exactly; spawning flat" >&2
    return 2
  fi
  if ! fm_backend_herdr_projection_journal_replace_endpoint \
    "$journal" "$id" "$meta_tab" "$meta_pane" "$new_tab" "$new_pane"; then
    fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
    echo "warning: herdr presentation reclaim for $id could not publish its replacement binding; spawning flat" >&2
    return 2
  fi
  FM_BACKEND_HERDR_PROJECTION_TAB_ID=$new_tab
  FM_BACKEND_HERDR_PROJECTION_PANE_ID=$new_pane
  return 0
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
  echo "warning: quarantined herdr presentation for $id is dead or agent-free; exact bound reclaim may proceed, otherwise spawning flat" >&2
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

# fm_backend_herdr_kill: remove the task's pane, best-effort (mirrors
# tmux-kill-window's `|| true` contract). Verified: closing a tab's only pane
# closes the tab too, so a separate tab close is unnecessary.
# When the close would empty a non-focused workspace, Herdr 0.7.5's explicit
# close moves focus to that workspace's neighbor with no restore anywhere in
# this path, so the kill follows the same focus-safe removal plan as
# projected cleanup (a verified pane-death removal with the doomed workspace
# repositioned behind the focused one when needed), keeping the exact-tab
# restore as the backstop. A close that empties the FOCUSED workspace moves
# focus legitimately, and every in-lock planning ambiguity or failure falls
# back to the plain close, matching the pre-hardening contract.
fm_backend_herdr_kill_serialized() {  # <session> <pane>
  local session=$1 pane=$2
  local before active_tab info target_pane target_tab target_ws plan shell_pid plan_move_record close_failed workspace_presence
  before=$(fm_backend_herdr_projection_focus_snapshot "$session") || before=
  if [ -n "$before" ]; then
    active_tab=${before#*$'\t'}
    info=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || info=
    target_pane=$(printf '%s' "$info" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
    target_tab=$(printf '%s' "$info" | jq -r '.result.pane.tab_id // empty' 2>/dev/null)
    target_ws=$(printf '%s' "$info" | jq -r '.result.pane.workspace_id // empty' 2>/dev/null)
    if [ "$target_pane" = "$pane" ] && [ -n "$target_tab" ] && [ "$target_tab" != "$active_tab" ]; then
      plan=$(fm_backend_herdr_emptying_close_plan "$session" "$pane" "$target_ws" "$target_tab" "${before%%$'\t'*}")
      plan_move_record=
      case "$plan" in
        moved$'\t'*)
          plan_move_record=${plan%%$'\n'*}
          plan=${plan##*$'\n'}
          ;;
      esac
      close_failed=0
      case "$plan" in
        death\ *)
          shell_pid=${plan#death }
          if ! fm_backend_herdr_death_close_pane "$session" "$pane" "$shell_pid" \
            && ! fm_backend_herdr_explicit_close_pane_confirmed "$session" "$pane"; then
            close_failed=1
          fi
          ;;
        *)
          fm_backend_herdr_explicit_close_pane_confirmed "$session" "$pane" || close_failed=1
          ;;
      esac
      if [ "$close_failed" = 0 ] && [ -n "$plan_move_record" ]; then
        workspace_presence=$(fm_backend_herdr_workspace_presence_state "$session" "$target_ws")
        if [ "$workspace_presence" != dead ]; then
          echo "warning: herdr task kill did not confirm removal of the repositioned workspace" >&2
          close_failed=1
        fi
      fi
      if [ "$close_failed" = 1 ]; then
        fm_backend_herdr_emptying_move_rollback "$plan_move_record" || true
      fi
      fm_backend_herdr_projection_focus_restore "$session" "$before" "task kill" || true
      return 0
    fi
  fi
  fm_backend_herdr_explicit_close_pane_confirmed "$session" "$pane" || true
}

fm_backend_herdr_kill() {  # <target>
  fm_backend_herdr_target_ready "$1" || return 0
  local session=$FM_BACKEND_HERDR_SESSION pane=$FM_BACKEND_HERDR_PANE
  local lock_path attempt=0 lock_held=0
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_BACKEND_HERDR_ROOT/bin/fm-wake-lib.sh"
  fi
  if lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session"); then
    while [ "$attempt" -lt 50 ]; do
      if fm_lock_try_acquire "$lock_path"; then
        lock_held=1
        break
      fi
      sleep 0.1
      attempt=$((attempt + 1))
    done
  fi
  if [ "$lock_held" = 1 ]; then
    fm_backend_herdr_kill_serialized "$session" "$pane"
    fm_lock_release "$lock_path" || true
  else
    echo "warning: herdr task kill could not acquire its session presentation lock; refusing an unlocked pane close" >&2
  fi
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
