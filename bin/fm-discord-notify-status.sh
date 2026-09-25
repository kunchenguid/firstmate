#!/usr/bin/env bash
# Map one newly received status record to the self-hosted Discord decision push.
# Usage: fm-discord-notify-status.sh <status-task-id> <status-line>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

[ "$#" -eq 2 ] || exit 2
task_id=$1
line=$2
verb=$(status_line_verb "$line")
key=$(_fm_decision_key "$line" 2>/dev/null) || key=

case "$verb:$key" in
  needs-decision:nm-*)
    "$SCRIPT_DIR/fm-discord-notify.sh" ask-user "$task_id" "$key" \
      "제안된 변경 사항에 대한 결정이 필요합니다." \
      "제안된 변경 사항 승인|현재 동작 유지"
    ;;
  needs-decision:pr-ready-*)
    note=$(status_line_note "$line")
    case "$note" in *'yolo=off'*) ;; *) exit 0 ;; esac
    route_task_id=$task_id
    detail=" $note "
    case "$detail" in
      *" task="*) route_task_id=${detail#* task=}; route_task_id=${route_task_id%% *} ;;
    esac
    url=''
    case "$detail" in
      *" pull request ready: "*) url=${detail#* pull request ready: }; url=${url%% choose *} ;;
    esac
    summary="검토할 풀 리퀘스트가 준비되었습니다."
    [ -z "$url" ] || summary="$summary $url"
    "$SCRIPT_DIR/fm-discord-notify.sh" pr-ready "$route_task_id" "$key" \
      "$summary" "병합|열어 두기" "$task_id"
    ;;
  *) exit 0 ;;
esac
