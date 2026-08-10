# shellcheck shell=bash

fm_update_action_dir() {
  [ -n "${FM_UPDATE_ACTION_DIR:-}" ] || return 1
  printf '%s\n' "$FM_UPDATE_ACTION_DIR"
}

fm_update_action_dir_is_valid() {
  local dir=$1
  case "$dir" in
    /*/.fm-deps-pending) ;;
    *) return 1 ;;
  esac
  case "$dir" in *$'\n'*|*$'\r'*) return 1 ;; esac
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ]
}

fm_update_action_firstmate_path() {
  local dir
  dir=$(fm_update_action_dir) || return 1
  fm_update_action_dir_is_valid "$dir" || return 1
  printf '%s/firstmate-update-reread.pending\n' "$dir"
}

fm_update_action_secondmate_path() {
  local id=$1 dir
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  dir=$(fm_update_action_dir) || return 1
  fm_update_action_dir_is_valid "$dir" || return 1
  printf '%s/firstmate-update-secondmate-%s.pending\n' "$dir" "$id"
}

fm_update_action_write() {
  local marker=$1 dir tmp line
  shift
  dir=$(fm_update_action_dir) || return 1
  fm_update_action_dir_is_valid "$dir" || return 1
  case "$marker" in "$dir"/firstmate-update-*.pending) ;; *) return 1 ;; esac
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  fi
  tmp=$(umask 077; mktemp "$dir/.update-action.XXXXXX" 2>/dev/null) || return 1
  for line in "$@"; do
    case "$line" in *$'\n'*|*$'\r'*) rm -f -- "$tmp"; return 1 ;; esac
    printf '%s\n' "$line" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  done
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; return 1; }
}

fm_update_action_write_firstmate() {
  local phase=$1 root=$2 before=$3 after=$4 marker
  case "$phase" in prepared|updated) ;; *) return 1 ;; esac
  [ -n "$root" ] && [ -n "$before" ] && [ -n "$after" ] || return 1
  marker=$(fm_update_action_firstmate_path) || return 1
  fm_update_action_write "$marker" \
    'action=firstmate-update-reread' "phase=$phase" \
    "path=$root/AGENTS.md" "before=$before" "after=$after"
}

fm_update_action_remove_firstmate() {
  local marker
  marker=$(fm_update_action_firstmate_path) || return 1
  rm -f -- "$marker"
}

fm_update_action_commit_is_valid() {
  local commit=$1
  case "${#commit}" in 40|64) ;; *) return 1 ;; esac
  case "$commit" in *[!0-9A-Fa-f]*) return 1 ;; esac
}

fm_update_action_write_secondmate() {
  local phase=$1 id=$2 home=$3 before=$4 after=$5 remote=$6 remote_host=$7 marker
  case "$phase" in prepared|updated) ;; *) return 1 ;; esac
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -n "$home" ] || return 1
  case "$remote" in
    0) [ -n "$before" ] && [ -n "$after" ] && [ -z "$remote_host" ] || return 1 ;;
    1)
      [ -z "$before" ] && [ -n "$remote_host" ] || return 1
      case "$phase" in
        prepared) [ -z "$after" ] || return 1 ;;
        updated) fm_update_action_commit_is_valid "$after" || return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  marker=$(fm_update_action_secondmate_path "$id") || return 1
  fm_update_action_write "$marker" \
    'action=firstmate-update-secondmate' "phase=$phase" "id=$id" \
    "selector=fm-$id" "home=$home" "before=$before" "after=$after" \
    "remote=$remote" "remote_host=$remote_host"
}

fm_update_action_remove_secondmate() {
  local marker
  marker=$(fm_update_action_secondmate_path "$1") || return 1
  rm -f -- "$marker"
}

fm_update_action_value() {
  local marker=$1 key=$2
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  awk -v key="$key" '
    index($0, key "=") == 1 {
      count += 1
      value = substr($0, length(key) + 2)
    }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$marker"
}
