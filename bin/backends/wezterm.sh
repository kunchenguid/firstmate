#!/usr/bin/env bash
# bin/backends/wezterm.sh - WezTerm session-provider adapter.
#
# Container shape: one WezTerm tab per firstmate project/home, one pane per
# crewmate/sub-agent inside that tab. Treehouse still owns task worktrees.

FM_BACKEND_WEZTERM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_WEZTERM_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKEND_WEZTERM_STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_WEZTERM_ROOT/bin/fm-backend-hometag-lib.sh"

fm_backend_wezterm_bin() {
  if [ -n "${FM_WEZTERM_BIN:-}" ]; then
    [ -x "$FM_WEZTERM_BIN" ] || { echo "error: FM_WEZTERM_BIN is not executable: $FM_WEZTERM_BIN" >&2; return 1; }
    printf '%s\n' "$FM_WEZTERM_BIN"
    return 0
  fi
  if command -v wezterm >/dev/null 2>&1; then command -v wezterm; return 0; fi
  if command -v wezterm.exe >/dev/null 2>&1; then command -v wezterm.exe; return 0; fi
  local candidate
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done <<EOF
$(fm_backend_wezterm_builtin_candidate_paths)
EOF
  return 1
}

fm_backend_wezterm_builtin_candidate_paths() {
  printf '%s\n' \
    "/mnt/c/Program Files/WezTerm/wezterm.exe" \
    "/c/Program Files/WezTerm/wezterm.exe"
}

fm_backend_wezterm_tool_check() {
  fm_backend_wezterm_bin >/dev/null 2>&1 || {
    echo "error: backend=wezterm selected but WezTerm CLI was not found (set FM_WEZTERM_BIN or install wezterm/wezterm.exe)" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: backend=wezterm selected but jq is not installed (required for 'wezterm cli list --format json')" >&2
    return 1
  }
  fm_backend_wezterm_feature_check || return 1
}

fm_backend_wezterm_feature_check() {
  local missing=0
  fm_backend_wezterm_cli list --help 2>/dev/null | grep -q -- '--format' || missing=1
  fm_backend_wezterm_cli get-text --help 2>/dev/null | grep -q -- '--start-line' || missing=1
  fm_backend_wezterm_cli send-text --help 2>/dev/null | grep -q -- '--no-paste' || missing=1
  fm_backend_wezterm_cli split-pane --help 2>/dev/null | grep -q -- '--percent' || missing=1
  fm_backend_wezterm_cli kill-pane --help 2>/dev/null | grep -q -- '--pane-id' || missing=1
  if [ "$missing" -ne 0 ]; then
    echo "error: backend=wezterm selected but the WezTerm CLI is missing required mux features (need list --format, get-text --start-line, send-text --no-paste, split-pane --percent, kill-pane --pane-id); update WezTerm or set FM_WEZTERM_BIN to a newer binary" >&2
    return 1
  fi
  return 0
}

fm_backend_wezterm_cli() {
  local bin
  bin=$(fm_backend_wezterm_bin) || return 1
  "$bin" cli "$@"
}

fm_backend_wezterm_container_ensure() {
  fm_backend_wezterm_tool_check
}

fm_backend_wezterm_home_label() {
  fm_backend_hometag
}

fm_backend_wezterm_project_key() {  # <cwd>
  ( cd "$1" 2>/dev/null && pwd -P ) || return 1
}

fm_backend_wezterm_tab_title() {  # <cwd>
  local base
  base=$(basename "$1")
  printf 'FM - %s - %s\n' "$(fm_backend_wezterm_home_label)" "$base"
}

fm_backend_wezterm_registry() {
  mkdir -p "$FM_BACKEND_WEZTERM_STATE_DIR"
  printf '%s/wezterm-tabs.tsv\n' "$FM_BACKEND_WEZTERM_STATE_DIR"
}

fm_backend_wezterm_list_json() {
  fm_backend_wezterm_cli list --format json
}

fm_backend_wezterm_pane_info() {  # <pane-id>
  fm_backend_wezterm_list_json 2>/dev/null \
    | jq -r --arg p "$1" '.[]? | select((.pane_id|tostring) == $p) | [.window_id,.tab_id,.pane_id,(.title // ""),(.cwd // "")] | @tsv' \
    | head -1
}

fm_backend_wezterm_percent_decode() {  # <string>
  local input=$1 out="" prefix rest hex char
  while [ -n "$input" ]; do
    case "$input" in
      *%*)
        prefix=${input%%\%*}
        rest=${input#*%}
        if [ ${#rest} -ge 2 ]; then
          hex=${rest:0:2}
          case "$hex" in
            [0-9A-Fa-f][0-9A-Fa-f])
              printf -v char '%b' "\\x$hex"
              out=$out$prefix$char
              input=${rest:2}
              continue
              ;;
          esac
        fi
        out=$out$prefix%
        input=$rest
        ;;
      *)
        out=$out$input
        input=
        ;;
    esac
  done
  printf '%s\n' "$out"
}

fm_backend_wezterm_cwd_path() {  # <cwd-uri-or-path>
  local cwd=$1 rest host host_lower path decoded
  case "$cwd" in
    file:///*) path=${cwd#file://} ;;
    file://*)
      rest=${cwd#file://}
      host=${rest%%/*}
      host_lower=$(printf '%s\n' "$host" | tr '[:upper:]' '[:lower:]')
      case "$host_lower" in
        [a-z]:)
          path="$host/${rest#*/}"
          ;;
        wsl.localhost|wsl\$)
          path="/${rest#*/}"
          path=${path#/}
          if [ "${path#*/}" != "$path" ]; then
            path="/${path#*/}"
          else
            path="/$path"
          fi
          ;;
        *)
          path="/${rest#*/}"
          ;;
      esac
      ;;
    *) path=$cwd ;;
  esac
  decoded=$(fm_backend_wezterm_percent_decode "$path")
  fm_backend_wezterm_normalize_local_path "$decoded"
}

fm_backend_wezterm_normalize_local_path() {  # <path>
  local path=$1 drive rest drive_lower converted
  case "$path" in
    /[A-Za-z]:/*)
      if command -v cygpath >/dev/null 2>&1; then
        converted=$(cygpath -u "${path#/}" 2>/dev/null) && { printf '%s\n' "$converted"; return 0; }
      fi
      drive=${path:1:1}
      rest=${path:3}
      drive_lower=$(printf '%s\n' "$drive" | tr '[:upper:]' '[:lower:]')
      printf '/%s%s\n' "$drive_lower" "$rest"
      return 0
      ;;
    [A-Za-z]:/*)
      if command -v cygpath >/dev/null 2>&1; then
        converted=$(cygpath -u "$path" 2>/dev/null) && { printf '%s\n' "$converted"; return 0; }
      fi
      drive=${path:0:1}
      rest=${path:2}
      drive_lower=$(printf '%s\n' "$drive" | tr '[:upper:]' '[:lower:]')
      printf '/%s%s\n' "$drive_lower" "$rest"
      return 0
      ;;
  esac
  printf '%s\n' "$path"
}

fm_backend_wezterm_pane_info_path() {  # <pane-info-tsv>
  fm_backend_wezterm_cwd_path "$(printf '%s\n' "$1" | cut -f5)"
}

fm_backend_wezterm_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_backend_wezterm_path_at_or_under() {  # <parent> <child>
  local parent=$1 child=$2 parent_real child_real
  parent_real=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  child_real=$(cd "$child" 2>/dev/null && pwd -P) || return 1
  if [ "$child_real" = "$parent_real" ]; then
    return 0
  fi
  case "$child_real" in "$parent_real"/*) return 0 ;; *) return 1 ;; esac
}

fm_backend_wezterm_registry_has_live_task() {  # <project-key> <tab-id>
  local key=$1 tab=$2 meta project meta_key pane win worktree info live_win live_tab live_pane live_path
  for meta in "$FM_BACKEND_WEZTERM_STATE_DIR"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(fm_backend_wezterm_meta_get "$meta" backend)" = wezterm ] || continue
    project=$(fm_backend_wezterm_meta_get "$meta" project)
    [ -n "$project" ] || continue
    meta_key=$(fm_backend_wezterm_project_key "$project" 2>/dev/null || printf '%s\n' "$project")
    [ "$meta_key" = "$key" ] || continue
    [ "$(fm_backend_wezterm_meta_get "$meta" wezterm_tab_id)" = "$tab" ] || continue
    pane=$(fm_backend_wezterm_meta_get "$meta" wezterm_pane_id)
    win=$(fm_backend_wezterm_meta_get "$meta" wezterm_window_id)
    worktree=$(fm_backend_wezterm_meta_get "$meta" worktree)
    if [ -z "$pane" ] || [ -z "$win" ] || [ -z "$worktree" ]; then
      continue
    fi
    info=$(fm_backend_wezterm_pane_info "$pane") || continue
    [ -n "$info" ] || continue
    live_win=$(printf '%s\n' "$info" | cut -f1)
    live_tab=$(printf '%s\n' "$info" | cut -f2)
    live_pane=$(printf '%s\n' "$info" | cut -f3)
    if [ "$live_win" != "$win" ] || [ "$live_tab" != "$tab" ] || [ "$live_pane" != "$pane" ]; then
      continue
    fi
    live_path=$(fm_backend_wezterm_pane_info_path "$info")
    fm_backend_wezterm_path_at_or_under "$worktree" "$live_path" || continue
    return 0
  done
  return 1
}

fm_backend_wezterm_registry_entry_valid() {  # <project-key> <tab-id> <seed-pane-id>
  [ -n "$2" ] || return 1
  fm_backend_wezterm_registry_has_live_task "$1" "$2"
}

fm_backend_wezterm_registry_entry() {  # <project-key>
  local reg key title tab pane
  reg=$(fm_backend_wezterm_registry)
  [ -f "$reg" ] || return 1
  while IFS=$'\t' read -r key title tab pane; do
    [ "$key" = "$1" ] || continue
    if fm_backend_wezterm_registry_entry_valid "$key" "$tab" "$pane"; then
      printf '%s\t%s\t%s\n' "$title" "$tab" "$pane"
      return 0
    fi
  done < "$reg"
  return 1
}

fm_backend_wezterm_registry_put() {  # <project-key> <title> <tab-id> <seed-pane-id>
  local reg tmp key
  reg=$(fm_backend_wezterm_registry)
  tmp="$reg.tmp.$$"
  key=$1
  if [ -f "$reg" ]; then
    awk -F '\t' -v k="$key" '$1 != k { print }' "$reg" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$tmp"
  mv "$tmp" "$reg"
}

fm_backend_wezterm_largest_pane_in_tab() {  # <tab-id>
  fm_backend_wezterm_list_json 2>/dev/null \
    | jq -r --arg t "$1" '
      [.[]? | select((.tab_id|tostring) == $t)
        | {pane_id, area: (((.size.cols // 0) | tonumber) * ((.size.rows // 0) | tonumber))}]
      | sort_by(.area) | reverse | .[0].pane_id // empty'
}

fm_backend_wezterm_pane_count_in_tab() {  # <tab-id>
  fm_backend_wezterm_list_json 2>/dev/null \
    | jq -r --arg t "$1" '[.[]? | select((.tab_id|tostring) == $t)] | length'
}

fm_backend_wezterm_split_direction() {  # <pane-count-before>
  case "$1" in
    1) printf '%s\n' --bottom ;;
    2|3) printf '%s\n' --right ;;
    *)
      if [ $(( $1 % 2 )) -eq 0 ]; then printf '%s\n' --bottom; else printf '%s\n' --right; fi
      ;;
  esac
}

fm_backend_wezterm_is_windows_bash() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_backend_wezterm_build_shell_args() {
  local shell_path shell_base converted wezterm_bin
  FM_BACKEND_WEZTERM_SHELL_ARGS=()
  if command -v bash >/dev/null 2>&1; then
    shell_path=$(command -v bash)
  elif command -v sh >/dev/null 2>&1; then
    shell_path=$(command -v sh)
  else
    echo "error: backend=wezterm requires bash or sh to start task panes" >&2
    return 1
  fi
  shell_base=$(basename "$shell_path")
  if fm_backend_wezterm_is_windows_bash && command -v cygpath >/dev/null 2>&1; then
    wezterm_bin=$(fm_backend_wezterm_bin 2>/dev/null || true)
    case "$wezterm_bin" in
      *.exe|*.EXE)
        converted=$(cygpath -w "$shell_path" 2>/dev/null) && [ -n "$converted" ] && shell_path=$converted
        ;;
    esac
  fi
  FM_BACKEND_WEZTERM_SHELL_ARGS=("$shell_path")
  case "$shell_base" in
    bash|bash.exe|zsh|zsh.exe|ksh|ksh.exe) FM_BACKEND_WEZTERM_SHELL_ARGS+=(-l) ;;
  esac
}

fm_backend_wezterm_create_task() {  # <label> <cwd>
  local label=$1 cwd=$2 key title entry tab seed pane info win direction count target spawn_args
  fm_backend_wezterm_build_shell_args || return 1
  key=$(fm_backend_wezterm_project_key "$cwd") || return 1
  title=$(fm_backend_wezterm_tab_title "$cwd")
  if entry=$(fm_backend_wezterm_registry_entry "$key" 2>/dev/null); then
    tab=$(printf '%s\n' "$entry" | cut -f2)
    count=$(fm_backend_wezterm_pane_count_in_tab "$tab")
    target=$(fm_backend_wezterm_largest_pane_in_tab "$tab")
    [ -n "$target" ] || { echo "error: backend=wezterm could not find a live pane in tab $tab" >&2; return 1; }
    direction=$(fm_backend_wezterm_split_direction "$count")
    pane=$(fm_backend_wezterm_cli split-pane --pane-id "$target" "$direction" --percent 50 --cwd "$cwd" -- "${FM_BACKEND_WEZTERM_SHELL_ARGS[@]}") || return 1
  else
    if [ -n "${WEZTERM_PANE:-}" ] && [ -n "$(fm_backend_wezterm_pane_info "$WEZTERM_PANE")" ]; then
      spawn_args=(spawn --pane-id "$WEZTERM_PANE" --cwd "$cwd")
    else
      spawn_args=(spawn --new-window --cwd "$cwd")
    fi
    spawn_args+=(-- "${FM_BACKEND_WEZTERM_SHELL_ARGS[@]}")
    pane=$(fm_backend_wezterm_cli "${spawn_args[@]}") || return 1
  fi
  pane=$(printf '%s' "$pane" | tr -d '[:space:]')
  case "$pane" in ''|*[!0-9]*) echo "error: wezterm did not return a pane id for $label (got '$pane')" >&2; return 1 ;; esac
  info=$(fm_backend_wezterm_pane_info "$pane") || true
  [ -n "$info" ] || { echo "error: backend=wezterm could not resolve pane $pane after spawn" >&2; return 1; }
  win=$(printf '%s\n' "$info" | cut -f1)
  tab=$(printf '%s\n' "$info" | cut -f2)
  seed=$(printf '%s\n' "$info" | cut -f3)
  fm_backend_wezterm_cli set-tab-title --tab-id "$tab" "$title" >/dev/null 2>&1 || true
  fm_backend_wezterm_registry_put "$key" "$title" "$tab" "$seed"
  printf '%s %s %s %s\n' "$win" "$tab" "$pane" "$title"
}

fm_backend_wezterm_parse_target() {  # <wezterm:pane-id>
  local target=${1#wezterm:}
  case "$target" in ''|*[!0-9]*) return 1 ;; esac
  FM_BACKEND_WEZTERM_PANE=$target
}

fm_backend_wezterm_target_ready() {  # <target> [expected-label]
  local expected_label=${2:-} meta info win tab pane recorded worktree live_path
  fm_backend_wezterm_parse_target "$1" || return 1
  info=$(fm_backend_wezterm_pane_info "$FM_BACKEND_WEZTERM_PANE") || return 1
  [ -n "$info" ] || return 1
  if [ -n "$expected_label" ]; then
    case "$expected_label" in fm-*) ;; *) return 1 ;; esac
    meta="$FM_BACKEND_WEZTERM_STATE_DIR/${expected_label#fm-}.meta"
    [ -f "$meta" ] || return 1
    [ "$(fm_backend_wezterm_meta_get "$meta" backend)" = wezterm ] || return 1
    [ "$(fm_backend_wezterm_meta_get "$meta" window)" = "$1" ] || return 1
    win=$(printf '%s\n' "$info" | cut -f1)
    tab=$(printf '%s\n' "$info" | cut -f2)
    pane=$(printf '%s\n' "$info" | cut -f3)
    recorded=$(fm_backend_wezterm_meta_get "$meta" wezterm_window_id)
    [ -n "$recorded" ] || return 1
    [ "$recorded" = "$win" ] || return 1
    recorded=$(fm_backend_wezterm_meta_get "$meta" wezterm_tab_id)
    [ -n "$recorded" ] || return 1
    [ "$recorded" = "$tab" ] || return 1
    recorded=$(fm_backend_wezterm_meta_get "$meta" wezterm_pane_id)
    [ -n "$recorded" ] || return 1
    [ "$recorded" = "$pane" ] || return 1
    worktree=$(fm_backend_wezterm_meta_get "$meta" worktree)
    [ -n "$worktree" ] || return 1
    live_path=$(fm_backend_wezterm_pane_info_path "$info")
    fm_backend_wezterm_path_at_or_under "$worktree" "$live_path" || return 1
  fi
  return 0
}

fm_backend_wezterm_current_path() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} out line marker_begin="__FM_WEZTERM_CWD_BEGIN__" marker_end="__FM_WEZTERM_CWD_END__" in_block=0 chunk="" last=""
  fm_backend_wezterm_target_ready "$target" "$expected_label" || return 0
  fm_backend_wezterm_send_text_line "$target" "printf '%s\n' '$marker_begin'; pwd; printf '%s\n' '$marker_end'" "$expected_label" || return 0
  sleep 0.3
  out=$(fm_backend_wezterm_capture "$target" 200 "$expected_label") || return 0
  while IFS= read -r line; do
    if [ "$line" = "$marker_begin" ]; then
      in_block=1
      chunk=""
      continue
    fi
    if [ "$line" = "$marker_end" ]; then
      case "$chunk" in /*) last=$chunk ;; esac
      in_block=0
      continue
    fi
    [ "$in_block" -eq 1 ] && chunk="$chunk$line"
  done <<EOF
$out
EOF
  printf '%s' "$last"
}

fm_backend_wezterm_send_literal() {  # <target> <text> [expected-label]
  fm_backend_wezterm_target_ready "$1" "${3:-}" || return 1
  printf '%s' "$2" | fm_backend_wezterm_cli send-text --pane-id "$FM_BACKEND_WEZTERM_PANE" --no-paste >/dev/null
}

fm_backend_wezterm_send_key() {  # <target> <key> [expected-label]
  local bytes
  fm_backend_wezterm_target_ready "$1" "${3:-}" || return 1
  case "$2" in
    Enter) bytes=$'\r' ;;
    Escape) bytes=$'\033' ;;
    C-c|C-C) bytes=$'\003' ;;
    *) echo "error: backend=wezterm unsupported key '$2' (supported: Enter, Escape, C-c)" >&2; return 1 ;;
  esac
  printf '%s' "$bytes" | fm_backend_wezterm_cli send-text --pane-id "$FM_BACKEND_WEZTERM_PANE" --no-paste >/dev/null
}

fm_backend_wezterm_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_wezterm_send_literal "$1" "$2" "${3:-}" || return 1
  fm_backend_wezterm_send_key "$1" Enter "${3:-}"
}

fm_backend_wezterm_capture() {  # <target> <lines> [expected-label]
  local lines=$2
  fm_backend_wezterm_target_ready "$1" "${3:-}" || return 1
  case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
  fm_backend_wezterm_cli get-text --pane-id "$FM_BACKEND_WEZTERM_PANE" --start-line "-$lines"
}

FM_BACKEND_WEZTERM_COMPOSER_LINES=${FM_BACKEND_WEZTERM_COMPOSER_LINES:-20}
FM_BACKEND_WEZTERM_IDLE_RE=${FM_BACKEND_WEZTERM_IDLE_RE:-'^Type a message\.\.\.$'}
FM_BACKEND_WEZTERM_BUSY_RE_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'

fm_backend_wezterm_composer_state() {  # <target> [expected-label] -> empty|pending|unknown
  local cap line trimmed stripped="" last="" found=0
  cap=$(fm_backend_wezterm_capture "$1" "$FM_BACKEND_WEZTERM_COMPOSER_LINES" "${2:-}") || { printf 'unknown'; return 0; }
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    last=$trimmed
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|') stripped=$trimmed; found=1 ;;
    esac
  done <<EOF
$cap
EOF
  [ "$found" -eq 1 ] || stripped=$last
  [ -n "$stripped" ] || { printf 'unknown'; return 0; }
  stripped=${stripped//│/}
  stripped=${stripped//┃/}
  stripped=${stripped//|/}
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  case "$stripped" in
    '❯'|'>'|'$'|'%'|'#'|*' $'|*' #'|*' %') printf 'empty'; return 0 ;;
  esac
  case "$stripped" in
    '❯ '*|'> '*|'$ '*|'% '*|'# '*) stripped=${stripped#??} ;;
    '❯'*|'>'*|'$'*|'%'*|'#'*) stripped=${stripped#?} ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  if printf '%s' "$stripped" | grep -qE "$FM_BACKEND_WEZTERM_IDLE_RE"; then
    printf 'empty'
    return 0
  fi
  if printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_BACKEND_WEZTERM_BUSY_RE_DEFAULT}"; then
    printf 'empty'
    return 0
  fi
  printf 'pending'
}

fm_backend_wezterm_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-} i state
  fm_backend_wezterm_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_wezterm_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  i=0
  while [ "$i" -lt "$retries" ]; do
    fm_backend_wezterm_send_key "$target" Enter "$expected_label" || true
    sleep "$sleep_s"
    state=$(fm_backend_wezterm_composer_state "$target" "$expected_label")
    case "$state" in
      empty) printf 'empty'; return 0 ;;
      unknown) printf 'unknown'; return 0 ;;
    esac
    i=$((i + 1))
  done
  printf 'pending'
}

fm_backend_wezterm_kill() {  # <target> [unused] [expected-label]
  fm_backend_wezterm_target_ready "$1" "${3:-}" || return 0
  fm_backend_wezterm_cli kill-pane --pane-id "$FM_BACKEND_WEZTERM_PANE" >/dev/null 2>&1 || true
}
