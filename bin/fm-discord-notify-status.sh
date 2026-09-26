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
    # A raw ask-user gate is not a captain-facing event: firstmate decides most
    # findings in-scope (ask-user-authority) with no captain involvement at all.
    # A genuine escalation records a captain-held task instead
    # (bin/fm-captain-hold.sh hold), which pushes its own Discord notification
    # carrying the real question, at the point firstmate actually escalates.
    exit 0
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
    # Name the repo up front (from a GitHub owner/repo or GitLab project path)
    # so a captain merging non-IMAC repos manually from this ping knows which
    # project it is without parsing the URL.
    repo=''
    case "$url" in
      https://github.com/*/*/pull/*)
        repo=${url#https://github.com/}
        repo=${repo%%/pull/*}
        repo=${repo##*/}
        ;;
      https://*/*/-/merge_requests/*)
        repo=${url#https://*/}
        repo=${repo%%/-/merge_requests/*}
        repo=${repo##*/}
        ;;
    esac
    if [ -n "$repo" ]; then
      summary="$repo 저장소: 검토할 풀 리퀘스트가 준비되었습니다."
    else
      summary="검토할 풀 리퀘스트가 준비되었습니다."
    fi
    [ -z "$url" ] || summary="$summary $url"
    "$SCRIPT_DIR/fm-discord-notify.sh" pr-ready "$route_task_id" "$key" \
      "$summary" "병합|열어 두기" "$task_id"
    ;;
  *) exit 0 ;;
esac
