#!/usr/bin/env bash
# fm-backend.sh - tmux-only runtime helpers for firstmate.
#
# Lean firstmate keeps the historical tmux helper API so callers do not need a
# broad rewrite, but `tmux` is the only valid runtime backend.
# A task meta may omit `backend=`; readers treat that as `tmux`.
# Any other recorded backend is stale metadata and fails closed before runtime
# commands or cleanup mutation.

FM_BACKEND_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_BACKEND_LIB_DIR="$(cd "$(dirname "$FM_BACKEND_SCRIPT")" && pwd)"
unset FM_BACKEND_SCRIPT
FM_BACKEND_DEFAULT_ROOT="$(cd "$FM_BACKEND_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

FM_BACKEND_KNOWN="tmux"
FM_BACKEND_SPAWN="tmux"

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

fm_backend_detect() {
  if [ -n "${TMUX:-}" ]; then
    printf 'tmux'
    return 0
  fi
  return 1
}

fm_backend_name() {
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

# fm_backend_required_tools: backend-specific CLI tools for the tmux runtime.
fm_backend_required_tools() {  # <backend>
  case "$1" in
    tmux)   printf '%s' 'tmux treehouse' ;;
    *) return 1 ;;
  esac
}

fm_backend_required_tool_available() {  # <backend> <tool>
  local backend=$1 tool=$2 required
  required=$(fm_backend_required_tools "$backend") || return 1
  fm_backend_list_contains "$required" "$tool" || return 1
  command -v "$tool" >/dev/null 2>&1
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
  case "${v:-tmux}" in
    tmux) printf 'tmux' ;;
    *) echo "error: stale non-tmux backend '${v}' recorded in $1" >&2; return 1 ;;
  esac
}

fm_backend_target_of_meta() {  # <meta-file>
  local meta=$1 backend window
  backend=$(fm_backend_of_meta "$meta")
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] && printf '%s' "$window"
}

# fm_backend_validate_task_endpoint: validate a task cleanup record entirely
# from its durable metadata before any runtime command or cleanup mutation.
# The validation binds the exact task id, selected backend, target, project,
# and worktree. New non-tmux records carry endpoint_task_id because their
# opaque runtime ids do not encode the task label. Legacy tmux records remain
# valid only when their window name itself is exactly fm-<task-id>.
# On success, sets FM_BACKEND_VALIDATED_BACKEND and
# FM_BACKEND_VALIDATED_TARGET. On failure, prints one refusal and returns 1.
fm_backend_meta_exact_value() {  # <meta-file> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^$key=" "$meta" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

fm_backend_endpoint_atom_valid() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._@%+-]*) return 1 ;;
  esac
}

fm_backend_validate_task_endpoint() {  # <meta-file> <task-id>
  local meta=$1 id=$2 backend_count backend window worktree project binding_count binding
  local session pane
  FM_BACKEND_VALIDATED_BACKEND=
  FM_BACKEND_VALIDATED_TARGET=
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "REFUSED: task $id has no regular endpoint metadata at $meta; preserving task state." >&2
    return 1
  }
  case "$id" in ''|*[!A-Za-z0-9._-]*)
    echo "REFUSED: task endpoint identity has an invalid task id; preserving task state." >&2
    return 1
  esac
  window=$(fm_backend_meta_exact_value "$meta" window) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous window endpoint; preserving task state." >&2
    return 1
  }
  worktree=$(fm_backend_meta_exact_value "$meta" worktree) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous worktree identity; preserving task state." >&2
    return 1
  }
  project=$(fm_backend_meta_exact_value "$meta" project) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous project identity; preserving task state." >&2
    return 1
  }
  case "$worktree$project$window" in *$'\n'*|*$'\r'*|*$'\t'*)
    echo "REFUSED: task $id has malformed endpoint metadata; preserving task state." >&2
    return 1
  esac
  backend_count=$(grep -c '^backend=' "$meta" 2>/dev/null || true)
  case "$backend_count" in
    0) backend=tmux ;;
    1) backend=$(fm_backend_meta_exact_value "$meta" backend) || backend= ;;
    *) backend= ;;
  esac
  if [ -z "$backend" ] || ! fm_backend_is_known "$backend"; then
    echo "REFUSED: task $id has a missing, ambiguous, or unknown backend identity; preserving task state." >&2
    return 1
  fi
  binding_count=$(grep -c '^endpoint_task_id=' "$meta" 2>/dev/null || true)
  case "$binding_count" in
    0) binding= ;;
    1)
      binding=$(fm_backend_meta_exact_value "$meta" endpoint_task_id) || {
        echo "REFUSED: task $id has an empty endpoint task binding; preserving task state." >&2
        return 1
      }
      ;;
    *)
      echo "REFUSED: task $id has an ambiguous endpoint task binding; preserving task state." >&2
      return 1
      ;;
  esac
  if [ -n "$binding" ] && [ "$binding" != "$id" ]; then
    echo "REFUSED: endpoint metadata belongs to task $binding, not $id; preserving task state." >&2
    return 1
  fi

  session=${window%%:*}
  pane=${window#*:}
  if [ "$pane" = "$window" ] || [ "$pane" != "fm-$id" ] \
    || [ -z "$session" ]; then
    echo "REFUSED: tmux endpoint '$window' is malformed or does not belong to task $id; preserving task state." >&2
    return 1
  fi
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_BACKEND_VALIDATED_BACKEND=$backend
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_BACKEND_VALIDATED_TARGET=$window
  return 0
}

fm_backend_meta_for_window() {  # <target> <state-dir>
  local target=$1 state=$2 meta window
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] && [ "$window" = "$target" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_backend_task_id_for_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  case "$raw" in
    *:*) return 1 ;;
  esac
  if [ -f "$state/$raw.meta" ]; then
    printf '%s' "$raw"
    return 0
  fi
  case "$raw" in
    fm-*)
      id=${raw#fm-}
      [ -f "$state/$id.meta" ] || return 1
      printf '%s' "$id"
      return 0
      ;;
  esac
  return 1
}

fm_backend_meta_for_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(fm_backend_task_id_for_selector "$raw" "$state") || return 1
  printf '%s/%s.meta' "$state" "$id"
}

fm_backend_of_selector() {  # <raw-target> <resolved-target> <state-dir>
  local raw=$1 resolved=$2 state=$3 meta
  meta=$(fm_backend_meta_for_selector "$raw" "$state" 2>/dev/null || true)
  [ -n "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
  if [ -n "$resolved" ]; then
    meta=$(fm_backend_meta_for_window "$resolved" "$state" 2>/dev/null || true)
    [ -n "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
  fi
  printf 'tmux'
}

fm_backend_expected_label_of_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(fm_backend_task_id_for_selector "$raw" "$state" 2>/dev/null || true)
  [ -n "$id" ] && printf 'fm-%s' "$id"
  return 0
}

# fm_backend_source: source the tmux adapter once per shell.
fm_backend_source() {  # <name>
  local name=$1
  fm_backend_validate "$name" || return 1
  if [ -z "${_FM_BACKEND_TMUX_SOURCED:-}" ]; then
    # shellcheck source=/dev/null
    . "$FM_BACKEND_LIB_DIR/backends/tmux.sh" || return 1
    _FM_BACKEND_TMUX_SOURCED=1
  fi
}

# fm_backend_resolve_selector: resolve a raw fm-send.sh/fm-peek.sh style
# selector to a live session-provider target. Four forms, in order:
#   target with ":"   used as-is (the escape hatch for a window/pane outside
#                      this firstmate home) - backend-independent, a literal string.
#   exact task id      routed through <state-dir>/<id>.meta's backend target
#                      (`window=` normally, `terminal=` for Orca) -
#                      backend-independent, a stored value, NOT re-verified
#                      against a live backend inventory (matches today's
#                      behavior: tmux window names can be trusted from meta
#                      without a live re-check).
#   "fm-<id>"          legacy task window label fallback routed through
#                      <state-dir>/<id>.meta when no exact
#                      <state-dir>/fm-<id>.meta exists.
#   anything else      first matched against recorded `window=`
#                      metadata, then treated as an ad hoc bare window name and
#                      resolved by searching the legacy tmux live inventory.
fm_backend_resolve_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 meta window
  case "$raw" in
    *:*)
      printf '%s' "$raw"
      return 0
      ;;
  esac
  meta=$(fm_backend_meta_for_selector "$raw" "$state" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    window=$(fm_backend_target_of_meta "$meta")
    [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
    printf '%s' "$window"
    return 0
  fi
  case "$raw" in
    fm-*)
      echo "error: no metadata for $raw in $state; pass session:window to target a window outside this firstmate home" >&2
      return 1
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
# Thin wrappers preserve the old backend-dispatch call shape while routing only
# to tmux.

# fm_backend_capture: bounded plain-text session capture.
fm_backend_capture() {  # <backend> <target> <lines> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  fm_backend_tmux_capture "$@"
}

# fm_backend_send_key: one backend-supported named special key.
fm_backend_send_key() {  # <backend> <target> <key> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  fm_backend_tmux_send_key "$@"
}

# fm_backend_send_text_submit: type text once, then submit and verify,
# retrying only the submission (never retyping). Echoes the backend's
# proof-carrying verdict; callers require exact empty for confirmed delivery.
fm_backend_send_text_submit() {  # <backend> <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  fm_backend_tmux_send_text_submit "$@"
}

# fm_backend_kill: remove the task's session endpoint (best-effort; a
# nonexistent/already-gone target is not an error - callers already swallow
# failures here exactly as the inline `tmux kill-window ... || true` did).
fm_backend_kill() {  # <backend> <target>
  local backend=$1
  shift
  [ -n "${1:-}" ] || { echo "error: refusing empty backend kill target" >&2; return 1; }
  fm_backend_source "$backend" || return 1
  fm_backend_tmux_kill "$@"
}

fm_backend_remove_worktree() {  # <backend> <worktree-id>
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  echo "error: backend '$backend' does not own task worktrees" >&2
  return 1
}

fm_backend_worktree_path() {  # <backend> <worktree-id>
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  echo "error: backend '$backend' does not own task worktrees" >&2
  return 1
}

# fm_backend_busy_state: semantic busy/idle/unknown for backends that expose
# native agent-state (herdr-addendum "busy state" row - the first backend
# where this gets real semantics beyond pane-regex). Backends with no such
# primitive (tmux) report unknown. Callers own the fallback policy: fm-watch.sh
# uses unknown as the cue for harness-scoped pane-tail detection, while
# fm-crew-state.sh also corroborates native idle verdicts with the recorded
# harness's signature before treating a no-run crew as not busy.
fm_backend_busy_state() {  # <backend> <target>
  local backend=$1
  shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  printf 'unknown'
}

# fm_backend_composer_state: classify the composer/input area of <target> as
# empty|pending|pending-unproven|unknown for callers that need a pre-submit
# input guard, a submit acknowledgement, or a launch-readiness check. It is
# exposed so a caller other than the send path (the away-mode daemon's
# supervisor-pane pending-input guard in bin/fm-supervise-daemon.sh, and
# fm-spawn.sh's kimi readiness/delivery checks) can ask the same question
# without duplicating per-backend composer reading. Every adapter's named
# classifier is a THIN wrapper - capture plus a capability descriptor fed to
# the one shared shape owner (bin/fm-composer-lib.sh,
# fm_composer_classify_screen) - so no backend can hold a private shape
# assumption; zellij's classifier reads `dump-screen --ansi`, which replaced
# its old no-classifier content-diff reporting.
fm_backend_composer_state() {  # <backend> <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local backend=$1
  shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  fm_tmux_composer_state "$@"
}

# fm_backend_target_exists: cheap, READ-ONLY existence check for a tmux target.
# Mirrors fm-crew-state.sh's pane_readable check; exists here as one shared
# primitive so callers that only need a fast alive/dead read (recovery
# digests, the session-start fleet digest) do not re-derive it inline.
fm_backend_target_exists() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 expected_label=${3:-}
  case "$backend" in
    tmux)
      tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1
      ;;
    *)
      [ -z "$expected_label" ] || :
      return 1
      ;;
  esac
}

# fm_backend_agent_state: the single recovery-grade agent/endpoint state
# contract. It is deliberately richer than fm_backend_target_exists's cheap
# pane-presence read and prints exactly one of:
#   alive      - a verified harness agent is running.
#   dead       - the endpoint exists but confidently has no agent.
#   missing    - the recorded endpoint is authoritatively absent.
#   ambiguous  - the endpoint exists but its process cannot be attributed.
#   unreadable - a target or inventory read failed or contradicted itself.
#   unverified - this backend has no recovery classifier.
# Only `dead` and `missing` license recovery.
# The tmux adapter requires a successful session inventory and returns
# `missing` only when it omits the exact window.
fm_backend_agent_state() {  # <backend> <target>
  local backend=$1 target=$2
  fm_backend_source "$backend" || { printf 'unverified'; return 0; }
  case "$backend" in
    tmux) fm_backend_tmux_agent_state "$target" ;;
    *) printf 'unverified' ;;
  esac
}

# Backward-compatible three-state view for existing callers. An
# authoritatively missing endpoint is confidently not a live agent, while every
# ambiguous, unreadable, or unverified result stays unknown.
fm_backend_agent_alive() {  # <backend> <target>
  case "$(fm_backend_agent_state "$1" "$2")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# --- native event push (backend-extensible) ---------------------------------
#
# The lean tmux runtime has no native event push, so these helpers always report
# no push and let the watcher use polling.

# fm_backend_has_push: 0 if <backend> exposes a native transition push stream.
fm_backend_has_push() {  # <backend>
  return 1
}

# fm_backend_events_capable: 0 if <backend>'s push path is usable for <session>
# right now (version/schema/reader gate). Non-push backends are never capable.
# The watcher memoizes this per session so the potentially heavy capability
# probe is not repeated every poll.
fm_backend_events_capable() {  # <backend> <session>
  return 1
}

# fm_backend_wait_transition: bounded wait for a fresh actionable (blocked)
# transition on one of <pane_window...> in <session>, up to <timeout_secs>.
# Prints the normalized transition record and returns 0 on a fresh actionable
# edge; returns 1 on a clean timeout (the caller has effectively already slept);
# returns 2 when the event path is unusable (the caller sleeps the budget
# itself). Non-push backends always return 2.
fm_backend_wait_transition() {  # <backend> <session> <timeout_secs> <state_dir> <pane_window...>
  return 2
}

fm_backend_commit_transition() {  # <backend> <state_dir> <session> <record>
  return 1
}

fm_backend_clear_transition() {  # <backend> <state_dir> <window>
  return 0
}
