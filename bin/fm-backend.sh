#!/usr/bin/env bash
# fm-backend.sh - runtime session-provider selection, metadata helpers, and
# operation dispatch. Tmux remains the default; Herdr is experimental and
# opt-in through FM_BACKEND, config/backend, or its runtime marker.
#
# A missing backend= in task metadata is the compatibility spelling for tmux.
# New default-tmux spawns deliberately omit backend= so existing metadata and
# the default path remain unchanged. Later adapters add dispatch arms here and
# do not need to change callers.

FM_BACKEND_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_BACKEND_DEFAULT_ROOT="$(cd "$FM_BACKEND_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKEND_CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_BACKEND_KNOWN="tmux herdr"

fm_backend_list_contains() {  # <space-delimited-list> <name>
  local list=$1 name=$2
  case "$name" in *[[:space:]]*) return 1 ;; esac
  case " $list " in *" $name "*) return 0 ;; esac
  return 1
}

fm_backend_is_known() {  # <name>
  fm_backend_list_contains "$FM_BACKEND_KNOWN" "$1"
}

# Detect the innermost session provider. A tmux pane nested inside Herdr has
# both markers; $TMUX wins because it describes the provider running this shell.
fm_backend_detect() {
  FM_BACKEND_DETECTED=
  FM_BACKEND_DETECT_SIGNAL=
  if [ -n "${TMUX:-}" ]; then
    FM_BACKEND_DETECTED=tmux
    FM_BACKEND_DETECT_SIGNAL=TMUX
    export FM_BACKEND_DETECT_SIGNAL
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = 1 ]; then
    FM_BACKEND_DETECTED=herdr
    FM_BACKEND_DETECT_SIGNAL=HERDR_ENV
    export FM_BACKEND_DETECT_SIGNAL
    printf 'herdr'
    return 0
  fi
  return 1
}

# Resolve a backend for a new task. Explicit --backend is handled by the
# caller and has higher precedence than this helper.
fm_backend_name() {
  local line value detected
  if [ -n "${FM_BACKEND:-}" ]; then
    printf '%s' "$FM_BACKEND"
    return 0
  fi
  if [ -f "$FM_BACKEND_CONFIG_DIR/backend" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      value=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
      fi
    done < "$FM_BACKEND_CONFIG_DIR/backend"
  fi
  if fm_backend_detect >/dev/null; then
    detected=$FM_BACKEND_DETECTED
    if [ "$detected" = herdr ]; then
      echo "NOTICE: auto-detected herdr runtime (HERDR_ENV=1) - spawning into the EXPERIMENTAL herdr backend. Set config/backend or pass --backend tmux to opt out." >&2
    fi
    printf '%s' "$detected"
    return 0
  fi
  printf 'tmux'
}

# Bootstrap checks only dependencies for the backend resolved for new spawns.
fm_backend_required_tools() {  # <backend>
  case "$1" in
    tmux) printf '%s' 'tmux treehouse' ;;
    herdr) printf '%s' 'herdr jq treehouse python3' ;;
    *) return 1 ;;
  esac
}

fm_backend_required_tool_available() {  # <backend> <tool>
  local backend=$1 tool=$2 required
  required=$(fm_backend_required_tools "$backend") || return 1
  fm_backend_list_contains "$required" "$tool" || return 1
  command -v "$tool" >/dev/null 2>&1
}

fm_backend_validate() {  # <name>
  local name=$1
  if ! fm_backend_is_known "$name"; then
    echo "error: unknown backend '$name' (known: $FM_BACKEND_KNOWN)" >&2
    return 1
  fi
}

fm_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_backend_of_meta() {  # <meta-file>
  local value
  value=$(fm_meta_get "$1" backend)
  printf '%s' "${value:-tmux}"
}

fm_backend_target_of_meta() {  # <meta-file>
  local meta=$1 backend session pane window
  backend=$(fm_backend_of_meta "$meta")
  if [ "$backend" = herdr ]; then
    session=$(fm_meta_get "$meta" herdr_session)
    pane=$(fm_meta_get "$meta" herdr_pane_id)
    if [ -n "$session" ] && [ -n "$pane" ]; then
      printf '%s:%s' "$session" "$pane"
      return 0
    fi
  fi
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] && printf '%s' "$window"
}

fm_backend_meta_for_window() {  # <target> <state-dir>
  local target=$1 state=$2 meta
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(fm_backend_target_of_meta "$meta")" = "$target" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_backend_of_selector() {  # <raw-target> <resolved-target> <state-dir>
  local raw=$1 resolved=$2 state=$3 meta
  case "$raw" in
    fm-*)
      meta="$state/${raw#fm-}.meta"
      [ -f "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
      ;;
  esac
  if [ -n "$resolved" ]; then
    meta=$(fm_backend_meta_for_window "$resolved" "$state" 2>/dev/null || true)
    [ -n "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
  fi
  printf 'tmux'
}

fm_backend_source() {  # <name>
  local name=$1
  fm_backend_validate "$name" || return 1
  case "$name" in
    tmux)
      if [ -z "${_FM_BACKEND_TMUX_SOURCED:-}" ]; then
        # shellcheck source=bin/backends/tmux.sh
        . "$FM_BACKEND_LIB_DIR/backends/tmux.sh"
        _FM_BACKEND_TMUX_SOURCED=1
      fi
      ;;
    herdr)
      if [ -z "${_FM_BACKEND_HERDR_SOURCED:-}" ]; then
        # shellcheck source=bin/backends/herdr.sh
        . "$FM_BACKEND_LIB_DIR/backends/herdr.sh"
        _FM_BACKEND_HERDR_SOURCED=1
      fi
      ;;
  esac
}

fm_backend_agent_state() {  # <backend> <target>
  local backend=$1 target=$2
  fm_backend_source "$backend" || { printf 'unverified'; return 0; }
  case "$backend" in
    tmux) fm_backend_tmux_agent_state "$target" ;;
    herdr) fm_backend_herdr_agent_state "$target" ;;
    *) printf 'unverified' ;;
  esac
}

fm_backend_agent_alive() {  # <backend> <target>
  case "$(fm_backend_agent_state "$1" "$2")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_herdr_inventory_target() {  # <state> <alias> [home] [session] [workspace] [display-label] [allow-legacy]
  local state=$1 alias=$2 home=${3:-$FM_HOME} session=${4:-} wsid=${5:-}
  local display_label=${6:-} allow_legacy=${7:-0} live target
  fm_backend_source herdr || return 2
  if [ -z "$session" ]; then
    session=$(fm_backend_herdr_session) || return 2
    [ -n "$session" ] || return 2
  fi
  if ! live=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    fm_backend_list_live herdr "$session" "$wsid"); then
    return 2
  fi
  if [ -n "$display_label" ]; then
    target=$(printf '%s\n' "$live" | awk -F '\t' -v alias="$alias" -v label="$display_label" '
      $2 == alias && $3 == label { if (++count == 1) found = $1 }
      END { if (count == 1) print found }
    ')
    [ -z "$target" ] || { printf '%s' "$target"; return 0; }
  fi
  if [ "$allow_legacy" = 1 ]; then
    target=$(printf '%s\n' "$live" | awk -F '\t' -v alias="$alias" '
      $2 == alias && $3 == alias { if (++count == 1) found = $1 }
      END { if (count == 1) print found }
    ')
    [ -z "$target" ] || { printf '%s' "$target"; return 0; }
  fi
  return 1
}

fm_backend_resolve_selector_with_backend() {  # <raw-target> <state-dir>; echoes backend<TAB>target
  local raw=$1 state=$2 meta window id backend session wsid recovery_record recovery_label recovery_home
  local recovery_display_label
  local inventory_status
  case "$raw" in
    *:*)
      printf '%s\t%s' "$(fm_backend_of_selector "$raw" "$raw" "$state")" "$raw"
      ;;
    *)
      case "$raw" in
        fm-*) id=${raw#fm-} ;;
        *) id=$raw ;;
      esac
      meta="$state/$id.meta"
      [ -f "$meta" ] || meta=
      if [ -n "$meta" ]; then
        window=$(fm_backend_target_of_meta "$meta")
        [ -n "$window" ] || { echo "error: no window recorded in $meta" >&2; return 1; }
        backend=$(fm_backend_of_meta "$meta")
        if [ "$backend" != herdr ]; then
          printf '%s\t%s' "$backend" "$window"
          return 0
        fi
        if fm_backend_pane_readable herdr "$window"; then
          printf 'herdr\t%s' "$window"
          return 0
        fi
        recovery_home=$(fm_meta_get "$meta" home)
        session=$(fm_meta_get "$meta" herdr_session)
        wsid=$(fm_meta_get "$meta" herdr_workspace_id)
        recovery_display_label=$(fm_meta_get "$meta" display_label)
        if window=$(fm_backend_herdr_inventory_target "$state" "fm-$id" \
          "${recovery_home:-$FM_HOME}" "$session" "$wsid" "$recovery_display_label" 1); then
          printf 'herdr\t%s' "$window"
          return 0
        else
          inventory_status=$?
        fi
        if [ "$inventory_status" -eq 2 ]; then
          echo "error: could not inspect Herdr recovery inventory for $raw" >&2
        else
          echo "error: no live Herdr target found for $raw" >&2
        fi
        return 1
      fi
      recovery_record="$state/$id.herdr-label"
      if [ -f "$recovery_record" ]; then
        recovery_label="fm-$id"
        fm_backend_source herdr || return 1
        fm_task_label_read_record "$recovery_record" "$id" >/dev/null 2>&1 || {
          echo "error: malformed Herdr recovery journal for $raw" >&2
          return 1
        }
        recovery_home=$(fm_meta_get "$recovery_record" herdr_home)
        session=$(fm_meta_get "$recovery_record" herdr_session)
        wsid=$(fm_meta_get "$recovery_record" herdr_workspace_id)
        recovery_display_label=$(fm_meta_get "$recovery_record" display_label)
        if window=$(fm_backend_herdr_inventory_target "$state" "$recovery_label" \
          "${recovery_home:-$FM_HOME}" "$session" "$wsid" "$recovery_display_label" 1); then
          printf 'herdr\t%s' "$window"
          return 0
        else
          inventory_status=$?
        fi
        if [ "$inventory_status" -eq 2 ]; then
          echo "error: could not inspect Herdr recovery inventory for $raw" >&2
        else
          echo "error: no live Herdr target found for $raw" >&2
        fi
        return 1
      fi
      if [[ "$raw" == fm-* ]] && [ "$(fm_backend_name)" = herdr ]; then
        if window=$(fm_backend_herdr_inventory_target "$state" "fm-$id" \
          "$FM_HOME" "" "" "" 1); then
          printf 'herdr\t%s' "$window"
          return 0
        else
          inventory_status=$?
        fi
        if [ "$inventory_status" -eq 2 ]; then
          echo "error: could not inspect Herdr legacy inventory for $raw" >&2
          return 1
        fi
      fi
      if [[ "$raw" == fm-* ]]; then
        echo "error: no metadata for $raw in $state; pass session:window to target a window outside this firstmate home" >&2
        return 1
      fi
      fm_backend_source tmux || return 1
      window=$(fm_backend_tmux_resolve_bare_selector "$raw") || return 1
      printf 'tmux\t%s' "$window"
      ;;
  esac
}

fm_backend_resolve_selector() {  # <raw-target> <state-dir>
  local resolved
  resolved=$(fm_backend_resolve_selector_with_backend "$@") || return 1
  printf '%s' "${resolved#*$'\t'}"
}

# Generic dispatch wrappers. Backend-specific adapters own command spelling;
# callers pass an opaque backend and target.
fm_backend_capture() {  # <backend> <target> <lines>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_capture "$@" ;;
    herdr) fm_backend_herdr_capture "$@" ;;
    *) echo "error: no capture implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_send_key() {  # <backend> <target> <key>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_send_key "$@" ;;
    herdr) fm_backend_herdr_send_key "$@" ;;
    *) echo "error: no send-key implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_send_text_submit() {  # <backend> <target> <text> <retries> <enter-sleep> <settle>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_send_text_submit "$@" ;;
    herdr) fm_backend_herdr_send_text_submit "$@" ;;
    *) echo "error: no send-text implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_submit_enter() {  # <backend> <target> <retries> <enter-sleep> [expected-text]
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_submit_enter "$@" ;;
    herdr) fm_backend_herdr_submit_enter "$@" ;;
    *) echo "error: no submit-enter implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_kill() {  # <backend> <target>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_kill "$@" ;;
    herdr) fm_backend_herdr_kill "$@" ;;
    *) echo "error: no kill implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_busy_state() {  # <backend> <target> -> busy|idle|unknown
  local backend=$1; shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    tmux) printf 'unknown' ;;
    herdr) fm_backend_herdr_busy_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_agent_alive() {  # <backend> <target> -> alive|dead|unknown
  case "$(fm_backend_agent_state "$1" "$2")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf unknown ;;
  esac
}

fm_backend_pane_readable() {  # <backend> <target>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_pane_readable "$@" ;;
    herdr) fm_backend_herdr_target_ready "$@" ;;
    *) echo "error: no pane-readability implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# Cheap passive existence probe. In particular, the Herdr path must not call
# target_ready because that helper may start a server during a read-only fleet
# digest.
fm_backend_target_exists() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    tmux)
      tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1
      ;;
    herdr)
      fm_backend_source herdr || return 1
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
      ;;
    *)
      fm_backend_pane_readable "$@"
      ;;
  esac
}

fm_backend_composer_state() {  # <backend> <target> [text] -> empty|pending|unknown
  local backend=$1
  shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    tmux) fm_backend_tmux_composer_state "$@" ;;
    herdr) fm_backend_herdr_composer_state "${1:-}" "${2:-}" ;;
    *) printf 'unknown' ;;
  esac
}

# Native event waits are optional. A return code of 2 means the caller must
# use its normal polling sleep; Herdr remains experimental and this path is
# fail-closed when protocol/schema/socket capability is absent.
fm_backend_has_push() { [ "$1" = herdr ]; }

fm_backend_events_capable() {  # <backend> <session>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 1
  fm_backend_source "$backend" || return 1
  fm_backend_herdr_events_capable "$@"
}

fm_backend_wait_transition() {  # <backend> <session> <timeout> <state> <target...>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 2
  fm_backend_source "$backend" || return 2
  fm_backend_herdr_wait_transition "$@"
}

fm_backend_commit_transition() {  # <backend> <state> <session> <record>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 1
  fm_backend_source "$backend" || return 1
  fm_backend_herdr_commit_transition "$@"
}

fm_backend_clear_transition() {  # <backend> <state> <window>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 0
  fm_backend_source "$backend" || return 1
  fm_backend_herdr_clear_transition "$@"
}

fm_backend_container_ensure() {  # <backend> <cwd>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_container_ensure "$@" ;;
    herdr) fm_backend_herdr_container_ensure "$@" ;;
    *) echo "error: no container implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_create_task() {  # <backend> <container> <label> <cwd>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_create_task "$@" ;;
    herdr) fm_backend_herdr_create_task "$@" ;;
    *) echo "error: no task-create implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_list_task_ids() {  # <backend> <container>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_list_task_ids "$@" ;;
    herdr) fm_backend_herdr_list_task_ids "$@" ;;
    *) echo "error: no task-list implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_find_task_window_id() {  # <backend> <container> <window-name>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_find_task_window_id "$@" ;;
    *) echo "error: no task-window lookup implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_list_live() {  # <backend> <container-or-session>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_list_live "$@" ;;
    *) echo "error: no live-task inventory implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_create_labeled_task() {  # <backend> <container> <state> <id> <kind> <title> <backlog> <cwd> [seeded]
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_create_labeled_task "$@" ;;
    *) echo "error: no labeled-task create implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_set_task_option() {  # <backend> <target> <option> <value>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_set_task_option "$@" ;;
    herdr) fm_backend_herdr_set_task_option "$@" ;;
    *) echo "error: no task-option implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_rename_task() {  # <backend> <target> <name>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_rename_task "$@" ;;
    herdr) fm_backend_herdr_rename_task "$@" ;;
    *) echo "error: no task-rename implementation for backend '$backend'" >&2; return 1 ;
  esac
}

fm_backend_task_name() {  # <backend> <target>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_task_name "$@" ;;
    herdr) fm_backend_herdr_task_name "$@" ;;
    *) echo "error: no task-name implementation for backend '$backend'" >&2; return 1 ;
  esac
}

fm_backend_current_path() {  # <backend> <target>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_current_path "$@" ;;
    herdr) fm_backend_herdr_current_path "$@" ;;
    *) echo "error: no current-path implementation for backend '$backend'" >&2; return 1 ;
  esac
}

fm_backend_send_text_line() {  # <backend> <target> <text>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_send_text_line "$@" ;;
    herdr) fm_backend_herdr_send_text_line "$@" ;;
    *) echo "error: no send-text-line implementation for backend '$backend'" >&2; return 1 ;
  esac
}

fm_backend_send_literal() {  # <backend> <target> <text>
  local backend=$1; shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_send_literal "$@" ;;
    herdr) fm_backend_herdr_send_literal "$@" ;;
    *) echo "error: no literal-send implementation for backend '$backend'" >&2; return 1 ;
  esac
}
