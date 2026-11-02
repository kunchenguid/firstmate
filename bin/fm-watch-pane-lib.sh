#!/usr/bin/env bash
# Watched-pane registry parsing and resolved-snapshot lookup.
# docs/configuration.md owns the registry schema; fm-watch-pane.sh owns edits.
# FM_WATCHED_PANES is a per-wait snapshot: target<TAB>label<TAB>notify_done.
# It is passed through the existing waited backend call, never persisted as IDs.

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
fm_watch_pane_resolve() {  # <state_dir> -> resolved snapshot
  local state=$1 session workspace tab label notify target seen='|'
  fm_watch_pane_validate "$state/watched-panes" || {
    echo 'error: invalid watched-pane registry' >&2
    return 1
  }
  [ -f "$state/watched-panes" ] || return 0
  fm_backend_source herdr || return 1
  while IFS=$'\t' read -r session workspace tab label notify || [ -n "$session" ]; do
    target=$(fm_backend_herdr_resolve_watched_pane "$session" "$workspace" "$tab") || continue
    [ -z "$(fm_backend_meta_for_window "$target" "$state" 2>/dev/null)" ] || continue
    case "$seen" in *"|$target|"*) continue ;; esac
    seen="$seen$target|"
    printf '%s\t%s\t%s\n' "$target" "$label" "$notify"
  done < "$state/watched-panes"
}

# The per-cycle read the watcher runs through its waited, bounded group: the
# resolved snapshot joined with one live agent-status read per pane, printed as
#   <target>\t<label>\t<notify_done>\t<agent_status>
# A pane whose read fails keeps an empty status so the caller can skip just
# that row and retry it next cycle.
fm_watch_pane_probe() {  # <state_dir>
  local state=$1 rows target label notify status
  rows=$(fm_watch_pane_resolve "$state") || return 1
  [ -n "$rows" ] || return 0
  fm_backend_source herdr || return 1
  while IFS=$'\t' read -r target label notify || [ -n "$target" ]; do
    [ -n "$target" ] || continue
    status=$(fm_backend_herdr_agent_status_raw "${target%%:*}" "${target#*:}")
    printf '%s\t%s\t%s\t%s\n' "$target" "$label" "$notify" "$status"
  done <<EOF
$rows
EOF
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
  target=$(fm_backend_herdr_resolve_watched_pane "$session" "$workspace" "$tab" 2>/dev/null) || return 0
  [ -z "$(fm_backend_meta_for_window "$target" "$state" 2>/dev/null)" ] || return 0
  fm_backend_herdr_clear_transition "$state" "$target" || return 0
}
