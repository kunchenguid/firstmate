#!/usr/bin/env bash
# Map one newly received status record to the self-hosted Discord decision push.
# Only send: (a) captain action/approval/choice requests and (b) completed task
# outcomes. Do NOT send routine blocked/failed status, progress, stale requests,
# internal diagnostics, or replayed/duplicate completion messages.
# Usage: fm-discord-notify-status.sh <status-task-id> <status-line>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_CREW_STATE_BIN=${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

# Push one completed-task outcome to this home's configured Discord channel,
# reusing fm-discord-notify.sh --report's send path. The event id binds the
# message to the durable exactly-once outbox, so a replayed status line, a
# concurrent sender, a failed POST, or a crash before the receipt still yields
# exactly one Discord message. Silent no-op when Discord is not configured.
fm_discord_send_completion() {
  local task_id=$1 event_id=$2 message=$3 channel_id
  fm_discord_load_config
  [ -n "${FM_DISCORD_TOKEN:-}" ] || return 0
  channel_id=$(fm_discord_trim "${FM_DISCORD_CHANNELS%%,*}")
  [ -n "$channel_id" ] || return 0
  case "$channel_id" in *[!0-9]*) return 0 ;; esac
  "$SCRIPT_DIR/fm-discord-notify.sh" --report "$channel_id" "$message" "$event_id"
}

# A completion's stable identity: the task and the exact outcome text it
# reported. Two different completions therefore never share a record, and the
# same completion re-read on a later poll always resolves to the same one.
fm_discord_completion_event_id() {
  local task_id=$1 note=$2 task_hash note_hash
  task_hash=$(printf '%s' "$task_id" | shasum -a 256 | cut -c1-16)
  note_hash=$(printf '%s' "$note" | shasum -a 256 | cut -c1-16)
  printf 'completion-%s-%s' "$task_hash" "$note_hash"
}

fm_discord_task_is_done() {
  local task_id=$1 line state rest part
  line=$("$FM_CREW_STATE_BIN" "$task_id" 2>/dev/null) || return 1
  case "$line" in state:*) ;; *) return 1 ;; esac
  state=${line#state: }; state=${state%% *}
  [ "$state" = "done" ] || return 1
  rest="$line · "
  while [ -n "$rest" ]; do
    part=${rest%% · *}
    rest=${rest#* · }
    [ "$part" = "$FM_PR_AWAITS_MERGE_DECISION" ] && return 1
  done
  return 0
}

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
      "$summary" "병합|열어 두기" "열어 두기" "$task_id"
    ;;
  done:*)
    fm_discord_task_is_done "$task_id" || exit 0
    note=$(status_line_note "$line")
    note=$(printf '%s' "$note" | tr '\n\r' '  ')
    fm_discord_send_completion "$task_id" \
      "$(fm_discord_completion_event_id "$task_id" "$note")" \
      "작업 완료 [$task_id]: ${note:-완료}" || exit $?
    ;;
  *) exit 0 ;;
esac
