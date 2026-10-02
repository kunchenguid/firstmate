#!/usr/bin/env bash
# Herdr-only runtime selection, historical metadata parsing and endpoint dispatch.
# New intake defaults to Herdr. Explicit retired/unknown selections refuse.
# Historical records without backend= retain their tmux identity and cannot be
# controlled or migrated by this library. docs/herdr-backend.md owns support.

FM_BACKEND_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_BACKEND_LIB_DIR="$(cd "$(dirname "$FM_BACKEND_SCRIPT")" && pwd)"
unset FM_BACKEND_SCRIPT
FM_BACKEND_DEFAULT_ROOT="$(cd "$FM_BACKEND_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKEND_CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_BACKEND_KNOWN="herdr"
FM_BACKEND_SPAWN="herdr"

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

# Runtime detection is informational; new unconfigured intake always uses Herdr.
fm_backend_detect() {
  FM_BACKEND_DETECTED=""
  FM_BACKEND_DETECT_SIGNAL=""
  [ "${HERDR_ENV:-}" = 1 ] || return 1
  FM_BACKEND_DETECTED=herdr
  FM_BACKEND_DETECT_SIGNAL=HERDR_ENV
  printf 'herdr'
}

# Explicit settings are preserved verbatim for validation, never coerced.
fm_backend_name() {
  local line v
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
  printf 'herdr'
}

# fm_backend_validate: refuse an unknown backend LOUDLY. Silent on success.
fm_backend_validate() {  # <name>
  local name=$1
  if ! fm_backend_is_known "$name"; then
    case "$name" in
      tmux|cmux|zellij|orca) echo "error: retired backend '$name'; only Herdr is supported; historical records are preserved without migration" >&2 ;;
      *) echo "error: unknown backend '$name' (supported: $FM_BACKEND_KNOWN)" >&2 ;;
    esac
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

# Herdr owns terminals; Treehouse remains the worktree provider.
fm_backend_required_tools() {  # <backend>
  case "$1" in
    herdr)  printf '%s' 'herdr jq treehouse' ;;
    *) return 1 ;;
  esac
}

fm_backend_required_tool_available() {  # <backend> <tool>
  local required
  required=$(fm_backend_required_tools "$1") || return 1
  fm_backend_list_contains "$required" "$2" || return 1
  command -v "$2" >/dev/null 2>&1
}

# fm_meta_get: the LAST value of `key=` in <meta-file>, or empty (never
# errors) if the file or key is absent. Mirrors the ad hoc `grep '^key=' |
# tail -1 | cut -d= -f2-` snippet every fm-*.sh script used to repeat inline.
fm_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2 line value=''
  [ -f "$meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done < "$meta" 2>/dev/null || true
  printf '%s' "$value"
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

# fm_backend_validate_task_endpoint: validate a task cleanup record entirely
# from its durable metadata before any runtime command or cleanup mutation.
# The validation binds the exact task id, selected backend, target, project,
# and worktree. Herdr records carry endpoint_task_id because their opaque runtime ids do
# not encode the task label. Retired and backend-less records refuse.
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
  local pane recorded_session workspace tab
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
    echo "REFUSED: task $id backend '${backend:-missing/ambiguous}' is unsupported; historical identity and task state are preserved." >&2
    return 1
  fi
  # Old provider-owned copies remain historical even if a backend selector
  # was edited by hand. Never release an Orca copy as a Treehouse worktree.
  if grep -Eq '^(orca_worktree_id=|cleanup_recovery=orca$)' "$meta"; then
    echo "REFUSED: task $id retains retired Orca worktree ownership; preserving its copy and records." >&2
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

  case "$backend" in
    herdr)
      [ "$binding" = "$id" ] || {
        echo "REFUSED: legacy Herdr endpoint metadata for task $id lacks an exact task binding; preserving task state." >&2
        return 1
      }
      recorded_session=$(fm_backend_meta_exact_value "$meta" herdr_session) || recorded_session=
      workspace=$(fm_backend_meta_exact_value "$meta" herdr_workspace_id) || workspace=
      tab=$(fm_backend_meta_exact_value "$meta" herdr_tab_id) || tab=
      pane=$(fm_backend_meta_exact_value "$meta" herdr_pane_id) || pane=
      if [ -z "$recorded_session" ] || [ -z "$workspace" ] || [ -z "$tab" ] || [ -z "$pane" ] \
        || [ "$window" != "$recorded_session:$pane" ] \
        || ! fm_backend_endpoint_atom_valid "$recorded_session" \
        || ! fm_backend_endpoint_atom_valid "$workspace" \
        || ! fm_backend_endpoint_atom_valid "${tab//:/_}" \
        || ! fm_backend_endpoint_atom_valid "${pane//:/_}"; then
        echo "REFUSED: Herdr endpoint metadata for task $id is malformed or inconsistent; preserving task state." >&2
        return 1
      fi
      ;;
  esac
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_BACKEND_VALIDATED_BACKEND=$backend
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_BACKEND_VALIDATED_TARGET=$window
  return 0
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
  # An unrecorded two-part selector is a historical tmux shape, never a
  # request to reinterpret that endpoint in the new provider.
  case "$resolved" in
    *:*:*) fm_backend_name ;;
    *) printf 'tmux' ;;
  esac
}

fm_backend_expected_label_of_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(fm_backend_task_id_for_selector "$raw" "$state" 2>/dev/null || true)
  [ -n "$id" ] && printf 'fm-%s' "$id"
  return 0
}

# fm_backend_source: source the named backend's adapter file, once per shell.
# Each adapter is an independently linted canonical root. The /dev/null source
# boundaries keep runtime dispatch from importing the adapter AST into
# every dispatcher consumer while preserving the runtime source operations.
fm_backend_source() {  # <name>
  local name=$1
  fm_backend_validate "$name" || return 1
  case "$name" in
    herdr)
      if [ -z "${_FM_BACKEND_HERDR_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_BACKEND_LIB_DIR/backends/herdr.sh" || return 1
        _FM_BACKEND_HERDR_SOURCED=1
      fi
      ;;
  esac
}

# fm_backend_resolve_selector: resolve a raw fm-send.sh/fm-peek.sh style
# selector to a live session-provider target. Four forms, in order:
#   target with ":"   used as-is (the escape hatch for a window/pane outside
#                      this firstmate home) - backend-independent, a literal string.
#   exact task id      routed through <state-dir>/<id>.meta's backend target
#                      (`window=` normally, `terminal=` for Orca) -
#                      a stored value; resolution does not grant control authority.
#   "fm-<id>"          legacy task window label fallback routed through
#                      <state-dir>/<id>.meta when no exact
#                      <state-dir>/fm-<id>.meta exists.
#   anything else      first matched against recorded `window=`/`terminal=`
#                      metadata, then refused if unmatched; there is no live-name discovery fallback.
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
      echo "error: no recorded endpoint for $raw; pass an explicit Herdr session:pane target" >&2
      return 1
      ;;
  esac
}

# --- generic per-op dispatch -------------------------------------------------
#
# Thin case-dispatch wrappers let callers name an operation and backend without
# coupling themselves to Herdr function names. A future verified backend would
# add its own arm here without changing call sites.

# fm_backend_capture: bounded plain-text session capture.
fm_backend_capture() {  # <backend> <target> <lines> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_capture "$@" ;;
    *) echo "error: no capture implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_send_key: one backend-supported named special key.
fm_backend_send_key() {  # <backend> <target> <key> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_send_key "$@" ;;
    *) echo "error: no send-key implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_send_text_submit: submit text through the backend's native prompt
# API without consulting vendor transcripts. Echoes submitted|unknown|send-failed.
# `submitted` is transport acceptance only, never proof that the worker read or
# completed the instruction. `unknown` forbids blind replay.
fm_backend_send_text_submit() {  # <backend> <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_send_text_submit "$@" ;;
    *) echo "error: no send-text implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_kill: remove the task's session endpoint best-effort.
# A nonexistent or already-gone target is not an error.
fm_backend_kill() {  # <backend> <target>
  local backend=$1
  shift
  [ -n "${1:-}" ] || { echo "error: refusing empty backend kill target" >&2; return 1; }
  fm_backend_source "$backend" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_kill "$@" ;;
    *) echo "error: no kill implementation for backend '$backend'" >&2; return 1 ;;
  esac
}



fm_backend_worktree_path() {  # <backend> <worktree-id>
  echo "error: backend '$1' worktree lookup is unsupported; preserving historical identity" >&2
  return 1
}

# fm_backend_busy_state: semantic busy/idle/unknown from Herdr's native agent
# state. Historical and unknown backends report unknown. Callers own the
# fallback policy. Codex and TraeX ordinary task state additionally requires
# this native status to be paired with fm_backend_agent_state's exact process
# result; Pi keeps its generation-bound lifecycle source.
fm_backend_busy_state() {  # <backend> <target>
  local backend=$1
  shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    herdr) fm_backend_herdr_busy_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_composer_state: classify the composer/input area of <target> as
# empty|pending|pending-unproven|unknown for callers that need a supervisor
# input guard or a launch-readiness check. It is exposed for the away-mode
# daemon's supervisor-pane pending-input guard and retained lifecycle checks;
# ordinary message submission does not call it. Callers can ask the same question
# without duplicating per-backend composer reading. Every adapter's named
# classifier is a THIN wrapper - capture plus a capability descriptor fed to
# the one shared shape owner (bin/fm-composer-lib.sh,
# fm_composer_classify_screen) - so no backend can hold a private shape
# assumption.
fm_backend_composer_state() {  # <backend> <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local backend=$1
  shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    herdr) fm_backend_herdr_composer_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_target_exists: cheap, READ-ONLY existence check - does the
# recorded TARGET endpoint still exist on BACKEND? Never starts a server or
# session: for herdr this deliberately queries the pane directly instead of
# going through fm_backend_herdr_target_ready (which auto-starts the herdr
# server as a side effect via fm_backend_herdr_server_ensure - fine for an
# operation that is about to use the pane, wrong for a passive liveness
# probe). An absent or unreadable pane fails this cheap check; cleanup requires
# the separate recovery-grade classifier below.
# Mirrors fm-crew-state.sh's pane_readable check; exists here as one shared
# primitive so callers that only need a fast alive/dead read (recovery
# digests, the session-start fleet digest) do not re-derive it inline.
fm_backend_target_exists() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 session pane
  case "$backend" in
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
    *)
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
# Only `dead` and `missing` license recovery. Every `alive` is proven at
# process level through the shared classifier in bin/fm-agent-process-lib.sh,
# never from a registration or a rendered title alone. Herdr verifies native
# registrations against pane process-info and the process table, so a stale
# registration over a shell-only pane is dead. A positively stopped session
# maps to missing only in this recovery-grade view. Retired providers refuse.
fm_backend_agent_state() {  # <backend> <target>
  local backend=$1 target=$2
  fm_backend_source "$backend" || { printf 'unverified'; return 0; }
  case "$backend" in
    herdr) fm_backend_herdr_agent_state "$target" ;;
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
# The watcher's event-wait splice (bin/fm-watch.sh) is backend-agnostic: it asks
# fm_backend_has_push whether a window's backend can push semantic state changes,
# and for those backends replaces its blind `sleep POLL` with a bounded wait on
# fm_backend_wait_transition. Every push-capable backend reuses the shared
# normalized-transition shape and policy table (bin/fm-transition-lib.sh); today
# only herdr implements the surface (docs/herdr-backend.md "Native
# pane.agent_status_changed push escalation"). A backend with no native push
# reports has-push false and returns 2 from the dispatchers below, so the
# watcher falls back to its poll loop - the permanent fail-closed backstop.

# fm_backend_has_push: 0 if <backend> exposes a native transition push stream.
fm_backend_has_push() {  # <backend>
  case "$1" in
    herdr) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_backend_events_capable: 0 if <backend>'s push path is usable for <session>
# right now (version/schema/reader gate). Non-push backends are never capable.
# The watcher memoizes this per session so the potentially heavy capability
# probe is not repeated every poll.
fm_backend_events_capable() {  # <backend> <session>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 1
  fm_backend_source "$backend" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_events_capable "$@" ;;
    *) return 1 ;;
  esac
}

# fm_backend_wait_transition: bounded wait for a fresh actionable (blocked)
# transition on one of <pane_window...> in <session>, up to <timeout_secs>.
# Prints the normalized transition record and returns 0 on a fresh actionable
# edge; returns 1 on a clean timeout (the caller has effectively already slept);
# returns 2 when the event path is unusable (the caller sleeps the budget
# itself). Non-push backends always return 2.
fm_backend_wait_transition() {  # <backend> <session> <timeout_secs> <state_dir> <pane_window...>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 2
  fm_backend_source "$backend" || return 2
  case "$backend" in
    herdr) fm_backend_herdr_wait_transition "$@" ;;
    *) return 2 ;;
  esac
}

fm_backend_commit_transition() {  # <backend> <state_dir> <session> <record>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 1
  fm_backend_source "$backend" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_commit_transition "$@" ;;
    *) return 1 ;;
  esac
}

fm_backend_clear_transition() {  # <backend> <state_dir> <window>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 0
  fm_backend_source "$backend" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_clear_transition "$@" ;;
    *) return 0 ;;
  esac
}
