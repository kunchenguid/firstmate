#!/usr/bin/env bash
# Shared single-pane protocol for fake tmux providers whose semantic model is
# window-based. Opt in explicitly; pane-routing and ambiguity tests use their
# own inventories instead. Window names determine stable fixture IDs, so a
# later window removal never renumbers surviving panes.

FM_TEST_TMUX_HELPER=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tmux-fixtures.sh

fm_test_tmux_number() {
  printf '%s' "${1##*:}" | cksum | awk '{print $1}'
}

fm_test_tmux_protocol() { # <fake executable> [meta-inventory]
  local fake=$1 inventory=${2:-provider} helper provider
  helper=$FM_TEST_TMUX_HELPER
  provider=$(mktemp "$fake.window-model.XXXXXX") || return 1
  mv "$fake" "$provider"
  {
    printf '#!/usr/bin/env bash\n'
    printf '. %q\n' "$helper"
    printf 'fm_test_tmux_dispatch %q %q "$@"\n' "$inventory" "$provider"
  } > "$fake"
  chmod +x "$fake"
}

fm_test_tmux_dispatch() {
  local inventory=$1 provider=$2 verb=$3 target='' session=firstmate name names rc arg prev='' id mapped='' format=''
  shift 3
  local args=("$@") translated=()
  for arg in "$@"; do
    case "$prev" in -t) target=$arg ;; -F) format=$arg ;; esac
    prev=$arg
  done
  case "$target" in *:*) session=${target%%:*} ;; =*) session=${target#=} ;; esac
  case "$verb" in
    new-window)
      "$provider" "$verb" "$@" >/dev/null || return $?
      prev=
      for arg in "$@"; do [ "$prev" != -n ] || name=$arg; prev=$arg; done
      printf '@%s\n' "$(fm_test_tmux_number "$name")"
      return 0 ;;
    list-windows|list-panes|display-message|capture-pane|send-keys|kill-window|set-window-option) ;;
    *) "$provider" "$verb" "$@"; return $? ;;
  esac
  if [ "$inventory" = meta-inventory ]; then
    names=$(sed -n 's/^window=//p' "${FM_STATE_OVERRIDE:-${FM_HOME:?}/state}"/*.meta 2>/dev/null)
  else
    names=$("$provider" list-windows -t "=$session" -F '#{window_name}')
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # A window model may return either names or session:name targets.
    id=$(fm_test_tmux_number "$name")
    case "$name" in *:*) ;; *) name="$session:$name" ;; esac
    case "$target" in "%$id"|"@$id") mapped=$name ;; esac
    case "$verb" in
      list-windows)
        case "$format" in
          '#{window_id}|#{window_index}|#{window_name}') printf '@%s|0|%s\n' "$id" "${name#*:}" ;;
          '#{session_name}:#{window_name}') printf '%s\n' "$name" ;;
          '#{window_id}') printf '@%s\n' "$id" ;;
          '#{window_index}') printf '0\n' ;;
          *) printf '%s\n' "${name#*:}" ;;
        esac ;;
      list-panes)
        case " ${args[*]} " in
          *' -a '*) printf '%%%s\n' "$id" ;;
          *) [ "$target" != "@$id" ] || printf '%%%s\n' "$id" ;;
        esac ;;
    esac
  done <<NAMES
$names
NAMES
  case "$verb" in list-windows|list-panes) return 0 ;; esac
  if [ "$verb" = display-message ]; then
    case " ${args[*]} " in
      *'#{pane_id}'*)
        [ -n "$mapped" ] || mapped=$target
        [ -z "$mapped" ] || printf '%%%s\n' "$(fm_test_tmux_number "$mapped")"
        return 0 ;;
    esac
  fi
  prev=
  for arg in "${args[@]}"; do
    if [ "$prev" = -t ] && [ -n "$mapped" ]; then translated+=("$mapped"); else translated+=("$arg"); fi
    prev=$arg
  done
  "$provider" "$verb" "${translated[@]}"
}
