#!/usr/bin/env bash
# fm-fleet-herdr.sh - Herdr backend for interactive fleet reasoning managers.
#
# Usage: fm-fleet-herdr.sh workspace <fleet-root>
#        fm-fleet-herdr.sh launch <fleet-root> <manager-id> <home> <harness>
#        fm-fleet-herdr.sh close <fleet-root> <manager-id> <home>
#        fm-fleet-herdr.sh target <home>
#
# Managers run as one workspace per manager home (FirstMate 1..4) with one
# prompt-ready harness tab (Manager 1..4) in the resolved Herdr session, so they stay
# visible on the operator's normal Herdr surface. Tab creation reuses
# fm_backend_herdr_create_task, which refuses live duplicate labels and
# reclaims husks; command submit reuses fm_backend_herdr_send_text_submit;
# removal reuses fm_backend_herdr_kill. The recorded herdr target lives in
# <home>/state/.fleet-herdr-target and is transport, never authority. The live
# home session lock is the reasoning authority read by fleet status and start.
# FM_FLEET_HERDR_LAUNCH_HOOK and FM_FLEET_HERDR_CLOSE_HOOK replace only the
# transport in process tests; they receive the resolved human labels.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

fleet_ws_label() {
  case "$1" in manager-[1-4]) printf 'FirstMate %s' "${1#manager-}" ;; *) printf 'FirstMate %s' "$1" ;; esac
}

fleet_tab_label() {
  case "$1" in manager-[1-4]) printf 'Manager %s' "${1#manager-}" ;; *) printf 'Manager %s' "$1" ;; esac
}

usage() {
  echo "usage: fm-fleet-herdr.sh workspace|launch|close|target ..." >&2
}

[ $# -ge 1 ] || { usage; exit 2; }
SUB=$1; shift

need_tools() {
  command -v herdr >/dev/null 2>&1 || { echo "fm-fleet-herdr: herdr not found" >&2; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "fm-fleet-herdr: jq not found" >&2; exit 1; }
}

load_adapter() {
  FM_HOME="${FM_HOME:-$FM_ROOT}"
  # shellcheck source=bin/backends/herdr.sh
  . "$FM_ROOT/bin/backends/herdr.sh"
}

sq() {
  python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$1"
}

fleet_workspace() {  # <fleet-root> <session> <label> prints "<wsid>\t<seeded-tab-or-empty>"
  local root=$1 session=$2 wslabel=$3 list matches count wsid out
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    echo "fm-fleet-herdr: cannot list herdr workspaces in session '$session'" >&2
    return 1
  }
  matches=$(printf '%s' "$list" | jq -r --arg want "$wslabel" \
    '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null) || {
    echo "fm-fleet-herdr: cannot parse herdr workspace list" >&2
    return 1
  }
  count=$(printf '%s' "$matches" | grep -c '[^[:space:]]' || true)
  if [ "$count" -gt 1 ]; then
    echo "fm-fleet-herdr: ${count} workspaces labeled '$wslabel'; rename or close the extras" >&2
    return 1
  fi
  wsid=${matches%%$'\n'*}
  if [ -n "$wsid" ]; then
    printf '%s\t%s' "$wsid" ""
    return 0
  fi
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$root" --label "$wslabel" --no-focus 2>/dev/null) || {
    echo "fm-fleet-herdr: cannot create fleet workspace in session '$session'" >&2
    return 1
  }
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  [ -n "$wsid" ] || { echo "fm-fleet-herdr: cannot parse fleet workspace id" >&2; return 1; }
  printf '%s\t%s' "$wsid" "$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)"
}

case "$SUB" in
  workspace)
    need_tools
    [ $# -eq 2 ] || { usage; exit 2; }
    load_adapter
    fm_backend_herdr_version_check || exit 1
    session=$(fm_backend_herdr_session)
    fm_backend_herdr_server_ensure "$session" || exit 1
    fleet_workspace "$1" "$session" "$2" || exit 1
    printf '\n'
    ;;

  launch)
    [ $# -eq 4 ] || { usage; exit 2; }
    root=$1 mid=$2 home=$3 harness=$4
    case "$harness" in codex|claude|opencode|pi|pi-signed|grok|kimi|cursor|omp) ;; *)
      echo "fm-fleet-herdr: unsupported interactive manager harness '$harness'" >&2
      exit 1
      ;;
    esac
    command -v "$harness" >/dev/null 2>&1 || {
      [ -n "${FM_FLEET_HERDR_LAUNCH_HOOK:-}" ] || {
        echo "fm-fleet-herdr: manager harness '$harness' not found" >&2
        exit 1
      }
    }
    if [ -n "${FM_FLEET_HERDR_LAUNCH_HOOK:-}" ]; then
      "$FM_FLEET_HERDR_LAUNCH_HOOK" "$root" "$mid" "$home" "$harness" \
        "$(fleet_ws_label "$mid")" "$(fleet_tab_label "$mid")"
      exit $?
    fi
    need_tools
    FM_HOME="$home" load_adapter
    fm_backend_herdr_version_check || exit 1
    session=$(fm_backend_herdr_session)
    fm_backend_herdr_server_ensure "$session" || exit 1
    wsinfo=$(fleet_workspace "$FM_ROOT" "$session" "$(fleet_ws_label "$mid")") || exit 1
    wsid=${wsinfo%%$'\t'*}
    seeded=${wsinfo#*$'\t'}
    ids=$(FM_HOME="$home" fm_backend_herdr_create_task "$session:$wsid" "$(fleet_tab_label "$mid")" "$FM_ROOT" "$seeded") || exit 1
    tab=${ids%% *}
    pane=${ids#* }
    [ -n "$tab" ] && [ -n "$pane" ] || { echo "fm-fleet-herdr: no tab/pane for $mid" >&2; exit 1; }
    cmd="cd $(sq "$FM_ROOT") && FM_HOME=$(sq "$home") FM_FLEET_ROOT=$(sq "$root") FM_FLEET_MANAGER_ID=$(sq "$mid") exec $(sq "$harness")"
    verdict=$(fm_backend_herdr_send_text_submit "$session:$pane" "$cmd" 3 1 0.5 2>/dev/null) || verdict="send-failed"
    if [ "$verdict" = "send-failed" ]; then
      echo "fm-fleet-herdr: command submit for $mid failed; check the tab" >&2
      printf '%s:%s' "$session" "$pane" > "$home/state/.fleet-herdr-target" 2>/dev/null || true
      exit 1
    fi
    if [ "$verdict" != "empty" ]; then
      echo "fm-fleet-herdr: command submit for $mid unconfirmed ('$verdict'); session lock decides" >&2
    fi
    printf '%s:%s' "$session" "$pane" > "$home/state/.fleet-herdr-target" || exit 1
    printf '%s:%s\n' "$session" "$pane"
    ;;

  close)
    [ $# -eq 3 ] || { usage; exit 2; }
    root=$1 mid=$2 home=$3
    if [ -n "${FM_FLEET_HERDR_CLOSE_HOOK:-}" ]; then
      "$FM_FLEET_HERDR_CLOSE_HOOK" "$root" "$mid" "$home" \
        "$(fleet_ws_label "$mid")" "$(fleet_tab_label "$mid")"
      exit $?
    fi
    need_tools
    FM_HOME="$home" load_adapter
    target=""
    [ -f "$home/state/.fleet-herdr-target" ] && target=$(cat "$home/state/.fleet-herdr-target" 2>/dev/null || true)
    [ -n "$target" ] || { echo "fm-fleet-herdr: no recorded target for $mid" >&2; exit 0; }
    fm_backend_herdr_kill "$target" 2>/dev/null || true
    rm -f "$home/state/.fleet-herdr-target" 2>/dev/null || true
    echo "closed $mid ($target)"
    ;;

  target)
    [ $# -eq 1 ] || { usage; exit 2; }
    cat "$1/state/.fleet-herdr-target" 2>/dev/null || true
    ;;

  *) usage >&2; exit 2 ;;
esac
