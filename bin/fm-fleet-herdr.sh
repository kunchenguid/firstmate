#!/usr/bin/env bash
# fm-fleet-herdr.sh - herdr backend for fleet manager processes.
#
# Usage: fm-fleet-herdr.sh workspace <fleet-root>
#        fm-fleet-herdr.sh launch <fleet-root> <manager-id> <home> <daemon-bin>
#        fm-fleet-herdr.sh close <fleet-root> <manager-id> <home>
#        fm-fleet-herdr.sh target <home>
#
# Managers run as one tab per manager (label fleet-<id>) inside one fleet
# workspace (label fm-fleet) in the resolved herdr session, so they stay
# visible on the operator's normal Herdr surface. Tab creation reuses
# fm_backend_herdr_create_task, which refuses live duplicate labels and
# reclaims husks; command submit reuses fm_backend_herdr_send_text_submit;
# removal reuses fm_backend_herdr_kill. The recorded herdr target lives in
# <home>/state/.fleet-herdr-target and is transport, never authority:
# pidfile and heartbeat remain the liveness truth read by fleet status.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FLEET_WS_LABEL="fm-fleet"

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

fleet_workspace() {  # <fleet-root> prints "<wsid>\t<seeded-tab-or-empty>"
  local root=$1 session=$2 list matches count wsid out
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    echo "fm-fleet-herdr: cannot list herdr workspaces in session '$session'" >&2
    return 1
  }
  matches=$(printf '%s' "$list" | jq -r --arg want "$FLEET_WS_LABEL" \
    '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null) || {
    echo "fm-fleet-herdr: cannot parse herdr workspace list" >&2
    return 1
  }
  count=$(printf '%s' "$matches" | grep -c '[^[:space:]]' || true)
  if [ "$count" -gt 1 ]; then
    echo "fm-fleet-herdr: ${count} workspaces labeled '$FLEET_WS_LABEL'; rename or close the extras" >&2
    return 1
  fi
  wsid=${matches%%$'\n'*}
  if [ -n "$wsid" ]; then
    printf '%s\t%s' "$wsid" ""
    return 0
  fi
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$root" --label "$FLEET_WS_LABEL" --no-focus 2>/dev/null) || {
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
    [ $# -eq 1 ] || { usage; exit 2; }
    load_adapter
    fm_backend_herdr_version_check || exit 1
    session=$(fm_backend_herdr_session)
    fm_backend_herdr_server_ensure "$session" || exit 1
    fleet_workspace "$1" "$session" || exit 1
    printf '\n'
    ;;

  launch)
    need_tools
    [ $# -eq 4 ] || { usage; exit 2; }
    root=$1 mid=$2 home=$3 daemon=$4
    FM_HOME="$home" load_adapter
    fm_backend_herdr_version_check || exit 1
    session=$(fm_backend_herdr_session)
    fm_backend_herdr_server_ensure "$session" || exit 1
    wsinfo=$(fleet_workspace "$root" "$session") || exit 1
    wsid=${wsinfo%%$'\t'*}
    seeded=${wsinfo#*$'\t'}
    ids=$(FM_HOME="$home" fm_backend_herdr_create_task "$session:$wsid" "fleet-$mid" "$home" "$seeded") || exit 1
    tab=${ids%% *}
    pane=${ids#* }
    [ -n "$tab" ] && [ -n "$pane" ] || { echo "fm-fleet-herdr: no tab/pane for $mid" >&2; exit 1; }
    cmd="FM_FLEET_POLL=${FM_FLEET_POLL:-2} exec $(sq "$daemon") $(sq "$root") $(sq "$mid")"
    verdict=$(fm_backend_herdr_send_text_submit "$session:$pane" "$cmd" 3 1 0.5 2>/dev/null) || verdict="send-failed"
    if [ "$verdict" = "send-failed" ]; then
      echo "fm-fleet-herdr: command submit for $mid failed; check the tab" >&2
      printf '%s:%s' "$session" "$pane" > "$home/state/.fleet-herdr-target" 2>/dev/null || true
      exit 1
    fi
    if [ "$verdict" != "empty" ]; then
      echo "fm-fleet-herdr: command submit for $mid unconfirmed ('$verdict'); heartbeat decides" >&2
    fi
    printf '%s:%s' "$session" "$pane" > "$home/state/.fleet-herdr-target" || exit 1
    printf '%s:%s\n' "$session" "$pane"
    ;;

  close)
    need_tools
    [ $# -eq 3 ] || { usage; exit 2; }
    root=$1 mid=$2 home=$3
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
