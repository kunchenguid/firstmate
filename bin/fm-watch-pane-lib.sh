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
