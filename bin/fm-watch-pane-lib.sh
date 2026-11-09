#!/usr/bin/env bash
# Watched-pane registry parsing and resolved-snapshot lookup.
# docs/configuration.md owns the registry schema; fm-watch-pane.sh owns edits.
# FM_WATCHED_PANES is a per-wait snapshot: target<TAB>label<TAB>notify_done.
# It is passed through the existing waited backend call, never persisted as IDs.

_FM_WATCH_PANE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_watch_pane_validate() {  # <registry>
  [ ! -L "$1" ] || return 1
  [ -e "$1" ] || return 0
  [ -f "$1" ] && [ -r "$1" ] || return 1
  LC_ALL=C awk -F '\t' '
    NF != 5 || $1 == "" || $2 == "" || $3 == "" || $4 == "" { exit 1 }
    $1 !~ /^[a-zA-Z0-9_.-]+$/ || $5 !~ /^[01]$/ { exit 1 }
    { for (i = 1; i <= NF; i++) if ($i ~ /[[:cntrl:]]/) exit 1 }
    seen_label[$4]++ || seen_identity[$1 FS $2 FS $3]++ { exit 1 }
  ' "$1"
}

fm_watch_pane_lookup() {  # <target> -> label<TAB>notify_done
  printf '%s\n' "${FM_WATCHED_PANES:-}" | FM_WATCH_PANE_TARGET="$1" awk -F '\t' \
    '$1 == ENVIRON["FM_WATCH_PANE_TARGET"] { print $2 "\t" $3; exit }'
}

fm_watch_pane_context() {  # <target> -> policy context
  local row
  row=$(fm_watch_pane_lookup "$1")
  case "$row" in
    *$'\t'1) printf 'watched-done' ;;
    ?*) printf 'watched' ;;
    *) printf 'task' ;;
  esac
}

# Resolve afresh each cycle; metadata always wins, including secondmates and
# endpoints owned by a different backend. No endpoint namespace discovery.
fm_watch_pane_probe() {  # <state_dir> <start-offset>
  local state=$1 start=$2 row i session workspace tab label notify target status seen='|'
  local rows=()
  fm_watch_pane_validate "$state/watched-panes" || {
    echo 'error: invalid watched-pane registry' >&2
    return 1
  }
  [ -f "$state/watched-panes" ] || return 0
  fm_backend_source herdr || return 1
  while IFS= read -r row || [ -n "$row" ]; do
    rows+=("$row")
  done < "$state/watched-panes"
  for ((i = 0; i < ${#rows[@]}; i++)); do
    IFS=$'\t' read -r session workspace tab label notify <<< "${rows[$(((start + i) % ${#rows[@]}))]}"
    target=$(fm_backend_herdr_resolve_watched_pane "$session" "$workspace" "$tab") || continue
    [ -z "$(fm_backend_meta_for_window "$target" "$state" 2>/dev/null)" ] || continue
    case "$seen" in *"|$target|"*) continue ;; esac
    seen="$seen$target|"
    status=$(fm_backend_herdr_agent_status_raw "${target%%:*}" "${target#*:}") || status=
    printf '%s\t%s\t%s\t%s\n' "$target" "$label" "$notify" "$status"
  done
}

fm_watch_pane_registry_identity() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f '%d:%i:%FB' "$1/watched-panes" 2>/dev/null
  else
    stat -c '%d:%i:%w' "$1/watched-panes" 2>/dev/null
  fi
}

fm_watch_pane_lock_current() {
  local state=$1 identity
  [ -n "${FM_WATCHED_PANES_IDENTITY:-}" ] || return 1
  fm_lock_try_acquire "$state/.watched-panes.lock" || return 1
  identity=$(fm_watch_pane_registry_identity "$state") || identity=
  [ "$identity" != "$FM_WATCHED_PANES_IDENTITY" ] || return 0
  fm_lock_release "$state/.watched-panes.lock"
  return 1
}

# A locked registry mutation runs its real Herdr reads in a bounded child so
# one hung session cannot hold .watched-panes.lock across an unbounded wait and
# silence every healthy watch: fm_run_timed kills the whole read group at
# FM_WATCHED_PANE_READ_SECS (default 5, the probe budget's normalization)
# before the caller's lock is released, and a killed read fails like an
# unresolvable pane. Prints the resolved "session:pane" target on success
# only - whatever a killed read managed to emit is never a usable identity.
fm_watch_pane_resolve_timed() {  # <session> <workspace-label> <tab-label>
  local secs out rc=0
  secs=${FM_WATCHED_PANE_READ_SECS:-5}
  case "$secs" in
    ''|*[!0-9]*|0) secs=5 ;;
  esac
  if ! declare -F fm_run_timed >/dev/null 2>&1; then
    # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
    . "$_FM_WATCH_PANE_LIB_DIR/fm-timeout-lib.sh" || return 1
  fi
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  out=$(fm_run_timed "$secs" bash -c '
    . "$1/fm-backend.sh"
    fm_backend_source herdr || exit 1
    fm_backend_herdr_resolve_watched_pane "$2" "$3" "$4"
  ' _ "$_FM_WATCH_PANE_LIB_DIR" "$@") || rc=$?
  if fm_timed_out "$rc"; then
    printf 'error: watched pane read exceeded the %ss bound\n' "$secs" >&2
    return 124
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out"
}

# Retire the watch-owned escalation marker of a registration's pane after its
# row leaves the registry (remove or replace). The marker suppresses a pane's
# next actionable edge, so leaving it behind would let a re-registered pane
# inherit it and stay silent on its next blocked. A pane a task metadata record
# claims is task-owned and keeps its state. Quiet and best effort: a pane that
# no longer resolves has no marker key to derive, so nothing can be retired.
fm_watch_pane_retire() {  # <state_dir> <session> <workspace-label> <tab-label>
  local state=$1 session=$2 workspace=$3 tab=$4 target
  fm_backend_source herdr || return 0
  target=$(fm_watch_pane_resolve_timed "$session" "$workspace" "$tab" 2>/dev/null) || return 0
  [ -z "$(fm_backend_meta_for_window "$target" "$state" 2>/dev/null)" ] || return 0
  fm_backend_herdr_clear_transition "$state" "$target" || return 0
}
