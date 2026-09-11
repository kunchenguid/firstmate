#!/usr/bin/env bash
# Same-home structured messaging for fm-send.sh; shared codec/inbox owner:
# fm-task-inbox-lib.sh. No daemon, room server, or model-owned sender label.
# Usage: fm_peer_send <target[,target...]> [--kind <kind>] [--ref <request-id>]
#                     [--thread <name>] <single-line text>
#        fm_peer_send --reply <request-id> <text>  (all thread members by default)
#        fm_peer_send --retry <message-id> --thread <name>
# Identity: FM_TASK_ID is a lookup hint, checked against exact live metadata and
# the physical working directory. Without it, structured supervisory sends
# require cwd=FM_HOME. This guards operator mistakes, not hostile same-UID code
# able to edit metadata or write directly to another participant's files.
# Existing thread members may add live recipients. Every copy shares one id,
# thread and recipient list. data/threads/<thread>.md is append-only JSON lines
# indented as Markdown code, readable directly with jq. The ledger is written
# before fan-out; an interrupted/partial send is retried only with --retry and
# its original thread, never by minting a replacement message. Inbox delivery
# deduplicates by id, including handled records. Supervisor wakes are at-least-
# once notifications of the same deduplicated supervisor inbox record.
# Lock order: thread first, then task metadata in sorted id order. All endpoints
# are validated before recording a new message; locks stay held through fan-out.
# A sender may reserve ten new messages per sixty seconds; retries do not mint
# messages. The limiter follows the sender's existing inbox cleanup. Helpers
# report only to their recorded parent; no key, decision-close or remote route.

fm_peer_live_task() {  # <state> <id>
  local id=$2 meta="$1/$2.meta" kind
  case "$id" in ''|*[!A-Za-z0-9._-]*|.|..|supervisor) return 1 ;; esac
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 1
  kind=$(fm_backend_meta_exact_value "$meta" kind) || return 1
  case "$kind" in ship|scout) ;; *) return 1 ;; esac
  fm_backend_validate_task_endpoint "$meta" "$id" || return 1
  [ "$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET")" = alive ]
}

fm_peer_sender() {  # <state> <task-hint>
  local state=$1 id=$2 worktree cwd root
  cwd=$(pwd -P) || return 1
  if [ -z "$id" ]; then
    [ "$cwd" = "$(cd "$FM_HOME" && pwd -P)" ] || {
      echo 'error: a structured supervisor send must run from its own home' >&2; return 1;
    }
    printf supervisor; return 0
  fi
  fm_peer_live_task "$state" "$id" || {
    echo 'error: sender is not an exactly recorded live local task' >&2; return 1;
  }
  worktree=$(fm_backend_meta_exact_value "$state/$id.meta" worktree) || return 1
  worktree=$(cd "$worktree" && pwd -P) || return 1
  case "$cwd/" in "$worktree/"*) ;; *)
    echo 'error: sender identity does not match its recorded worktree' >&2; return 1 ;;
  esac
  root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$root" ]; then
    root=$(cd "$root" && pwd -P) || return 1
    [ "$root" = "$worktree" ] || return 1
  fi
  printf '%s' "$id"
}

fm_peer_request() {  # <state> <sender> <ref>
  local record message
  for record in "$1/$2.inbox/"*.msg "$1/$2.inbox/handled/"*.msg; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    message=$(fm_task_inbox_message "$record") || continue
    if printf '%s' "$message" | jq -e --arg ref "$3" --arg sender "$2" \
      '.id==$ref and .kind=="request" and (.to|index($sender))!=null' >/dev/null; then
      printf '%s' "$message"; return 0
    fi
  done
  echo 'error: reply ref does not name a request in the sender inbox' >&2
  return 1
}

fm_peer_send() (
  set -eu
  local targets=${1:-} sender kind=note ref='' thread='' retry='' text request='' message ledger
  local lock thread_lock held='' id recipients members record count since now dir rate parent meta
  local status_path failed=0 records='' first_args rows
  local request_id started_ms step_ms phase=intake refusal_reason=operation_failed
  local text_size=0 recipient_count=0 validated_count=0 delivered_count=0 failed_count=0 retry_count=0
  local sender_model='' sender_harness='' sender_effort='' finish_rc outcome
  # shellcheck source=bin/fm-message-telemetry-lib.sh
  . "$SCRIPT_DIR/fm-message-telemetry-lib.sh"
  request_id="req-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  started_ms=$(fm_timing_now_ms); step_ms=$started_ms
  thread_lock=''
  trap 'finish_rc=$?; for meta in $held; do lock=$(fm_meta_lock_path "$STATE/$meta.meta"); fm_lock_release "$lock"; done;
    [ -z "$thread_lock" ] || fm_lock_release "$thread_lock";
    outcome=rejected; [ "$finish_rc" -ne 0 ] || outcome=accepted;
    if [ "$finish_rc" -ne 0 ]; then case "$phase" in ledger_append|inbox_fanout) outcome=error ;; esac; fi;
    fm_message_log finished "$outcome" "$refusal_reason"' EXIT
  fm_message_log intake accepted received
  [ "$#" -ge 2 ] || { echo 'error: message requires recipients and text, or --reply/--retry' >&2; exit 1; }
  shift
  case "$targets" in
    --reply) ref=$1; kind=reply; targets=''; shift ;;
    --retry) retry=$1; targets=''; shift ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind|--ref|--thread)
        [ "$#" -ge 2 ] || exit 1
        [ -n "$2" ] || { echo 'error: message options require nonempty values' >&2; exit 1; }
        first_args=$1
        case "$first_args" in --kind) kind=$2 ;; --ref) ref=$2 ;; --thread) thread=$2 ;; esac
        shift 2 ;;
      --) shift; break ;;
      --*) echo 'error: messages accept --kind, --ref and --thread, never control or decision authority' >&2; exit 1 ;;
      *) break ;;
    esac
  done
  text=$*; text_size=$(printf '%s' "$text" | wc -c | tr -d ' ')
  fm_message_step sender_identity
  refusal_reason=sender_identity_refused
  [ "$(cd "$STATE" && pwd -P)" = "$(cd "$FM_HOME/state" && pwd -P)" ] || {
    echo 'error: messages cannot override the home state directory' >&2; exit 1;
  }
  fm_message_log port.enter '' sender_identity
  sender=$(fm_peer_sender "$STATE" "${FM_TASK_ID:-}") || exit 1
  fm_message_log port.exit accepted sender_identity
  if [ "$sender" != supervisor ]; then
    sender_model=$(fm_meta_get "$STATE/$sender.meta" model)
    sender_harness=$(fm_meta_get "$STATE/$sender.meta" harness)
    sender_effort=$(fm_meta_get "$STATE/$sender.meta" effort)
  fi
  fm_message_log decision accepted identity_bound
  fm_message_step request_validation
  refusal_reason=invalid_request
  if [ -z "$retry" ]; then
    case "$text" in ''|*[[:cntrl:]]*) echo 'error: message text must be a nonempty single printable line' >&2; exit 1 ;; esac
    [ "${#text}" -le 4096 ] || { echo 'error: message text exceeds 4096 characters' >&2; exit 1; }
    if [ "$kind" = reply ]; then
      request=$(fm_peer_request "$STATE" "$sender" "$ref") || exit 1
      if [ -z "$thread" ]; then thread=$(printf '%s' "$request" | jq -r '.thread // empty'); fi
      if [ -z "$targets" ] && [ -z "$thread" ]; then targets=$(printf '%s' "$request" | jq -r '.from'); fi
    fi
    if [ -z "$thread" ]; then thread="thread-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"; fi
  else
    [ -z "$text" ] && [ -n "$thread" ] && [ "$kind" = note ] && [ -z "$ref" ] || {
      echo 'error: --retry requires only --thread, without replacement text, kind or ref' >&2; exit 1;
    }
  fi
  fm_message_step thread_membership
  refusal_reason=thread_membership_or_ledger_refused
  case "$thread" in ''|*[!A-Za-z0-9._-]*|.|..) echo 'error: invalid thread name' >&2; exit 1 ;; esac
  [ "${#thread}" -le 128 ] || exit 1
  dir="$FM_HOME/data/threads"
  [ ! -L "$FM_HOME/data" ] && [ ! -L "$dir" ] || exit 1
  mkdir -p "$dir"
  ledger="$dir/$thread.md"; thread_lock="$dir/.$thread.lock"
  [ ! -L "$ledger" ] || exit 1
  [ ! -e "$ledger" ] || [ -f "$ledger" ] || exit 1
  fm_task_inbox_lock_acquire "$thread_lock" || exit 1
  members='[]'
  if [ -s "$ledger" ]; then
    # ponytail: linear thread scans; add an index only if measured threads need it.
    # Parsing first catches a torn final line even when it lacks a newline.
    fm_message_log port.enter '' ledger_read
    rows=$(jq -c . "$ledger") || exit 1
    while IFS= read -r message; do
      printf '%s' "$message" | fm_message_validate >/dev/null || exit 1
    done <<EOF
$rows
EOF
    jq -se --arg thread "$thread" 'all(.[]; .thread==$thread)
      and ([.[].id]|length)==([.[].id]|unique|length)' "$ledger" >/dev/null || exit 1
    members=$(jq -sc '[.[] | .from, .to[]] | unique' "$ledger") || exit 1
    fm_message_log port.exit accepted ledger_read
    printf '%s' "$members" | jq -e --arg sender "$sender" 'index($sender)!=null' >/dev/null || {
      echo 'error: only a thread member may send or add recipients' >&2; exit 1;
    }
  fi
  if [ -n "$retry" ]; then
    retry_count=1
    message=$(jq -sce --arg id "$retry" --arg sender "$sender" \
      '[.[]|select(.id==$id and .from==$sender)] | select(length==1) | .[0]' "$ledger") || {
      echo 'error: retry must name one message recorded by this sender' >&2; exit 1;
    }
    message=$(printf '%s' "$message" | fm_message_validate) || exit 1
  else
    if [ -z "$targets" ]; then
      targets=$(printf '%s' "$members" | jq -r --arg sender "$sender" 'map(select(.!=$sender)) | join(",")')
    fi
    message=$(fm_message_encode "$sender" "$targets" "$kind" "$ref" "$text" "$thread") || {
      echo 'error: invalid recipients, kind or ref' >&2; exit 1;
    }
    if [ -n "$request" ]; then
      printf '%s' "$message" | jq -e --argjson request "$request" \
        '($request.thread==null or .thread==$request.thread)' >/dev/null || {
        echo 'error: a reply must keep the original thread' >&2; exit 1;
      }
    fi
  fi
  id=$(printf '%s' "$message" | jq -r .id)
  recipients=$(printf '%s' "$message" | jq -r '.to[]')
  recipient_count=$(printf '%s' "$message" | jq '.to|length')
  text_size=$(printf '%s' "$message" | jq '.text|utf8bytelength')
  fm_message_log decision accepted membership_bound
  fm_message_step endpoints
  refusal_reason=endpoint_not_live_or_not_local
  printf '%s' "$message" | jq -e --arg sender "$sender" '(.to|index($sender))==null' >/dev/null || {
    echo 'error: a sender cannot include itself as a recipient' >&2; exit 1;
  }
  # Sorting is over validated participant ids, never paths or message text.
  for meta in $(printf '%s\n%s\n' "$sender" "$recipients" | LC_ALL=C sort -u); do
    lock=$(fm_meta_lock_path "$STATE/$meta.meta") || exit 1
    fm_task_inbox_lock_acquire "$lock" || { echo 'error: message metadata could not be locked' >&2; exit 1; }
    held="${held}${held:+ }$meta"
    if [ "$meta" = supervisor ]; then
      [ ! -e "$STATE/supervisor.meta" ] && [ ! -L "$STATE/supervisor.meta" ] || {
        echo 'error: reserved supervisor participant conflicts with a task record' >&2; exit 1;
      }
      continue
    fi
    fm_message_log port.enter '' live_endpoint
    fm_peer_live_task "$STATE" "$meta" || { echo "error: $meta is not a live same-home task" >&2; exit 1; }
    validated_count=$((validated_count+1))
    fm_message_log port.exit accepted live_endpoint
  done
  [ "$(fm_peer_sender "$STATE" "${FM_TASK_ID:-}")" = "$sender" ] || exit 1
  if [ "$sender" != supervisor ]; then
    parent=$(fm_meta_get "$STATE/$sender.meta" parent)
    if [ -n "$parent" ] && [ "$recipients" != "$parent" ]; then
      echo 'error: a helper reports only to its recorded parent' >&2; exit 1
    fi
  fi
  fm_message_log decision accepted endpoints_bound
  fm_message_step rate_limit
  refusal_reason=sender_rate_limit_or_unsafe_path
  if [ -z "$retry" ]; then
    dir="$STATE/$sender.inbox"
    [ ! -L "$dir" ] && [ ! -L "$dir/handled" ] || exit 1
    mkdir -p "$dir/handled"
    rate="$dir/.peer.rate"; now=$(date +%s); since=$now; count=0
    [ ! -L "$rate" ] || exit 1
    if [ -e "$rate" ]; then
      read -r since count < "$rate" || exit 1
      case "$since:$count" in *[!0-9:]*) echo 'error: malformed sender rate record' >&2; exit 1 ;; esac
      [ -n "$since" ] && [ -n "$count" ] && [ "${#since}" -le 12 ] && [ "${#count}" -le 2 ] || exit 1
      if [ "$now" -ge "$since" ] && [ "$((now-since))" -ge 60 ]; then since=$now; count=0; fi
    fi
    [ "$count" -lt 10 ] || { echo 'error: sender rate limit reached (10 messages per 60 seconds)' >&2; exit 1; }
    printf '%s %s\n' "$since" "$((count+1))" > "$rate"
    fm_message_log decision accepted rate_reserved
    fm_message_step ledger_append
    refusal_reason=ledger_append_failed
    fm_message_log port.enter '' ledger_append
    printf '    %s\n' "$message" >> "$ledger"
    fm_message_log port.exit accepted recorded_before_fanout
  fi
  fm_message_step inbox_fanout
  refusal_reason=partial_delivery
  for meta in $recipients; do
    fm_message_log port.enter '' inbox_delivery
    if ! record=$(fm_task_inbox_deliver_message "$STATE" "$meta" "$message"); then
      failed=1; failed_count=$((failed_count+1))
      fm_message_log port.exit error inbox_write_failed
      continue
    fi
    delivered_count=$((delivered_count+1))
    fm_message_log port.exit accepted inbox_delivered
    records="${records}${records:+ }$meta"
    if [ "$meta" = supervisor ]; then
      fm_message_log port.enter '' wake_publish
      if fm_wake_append check "message-$id" "message $id: read $record with bin/fm-message.sh read; acknowledge the inbox record after processing"; then
        fm_message_log port.exit accepted wake_queued
      else
        failed=1; failed_count=$((failed_count+1)); fm_message_log port.exit error wake_write_failed
      fi
    else
      # Reuse the existing runtime-independent doorbell; it carries no payload.
      fm_message_log port.enter '' doorbell
      if fm_task_inbox_ring "$(fm_backend_of_meta "$STATE/$meta.meta")" \
        "$(fm_backend_target_of_meta "$STATE/$meta.meta")" "$record" "fm-$meta"; then
        fm_message_log port.exit accepted doorbell_rang
      else
        fm_message_log port.exit error doorbell_deferred
      fi
    fi
  done
  if [ "$sender" != supervisor ]; then
    status_path="$STATE/$sender.status"
    if [ -L "$status_path" ] || { [ -e "$status_path" ] && [ ! -f "$status_path" ]; } \
      || ! printf 'peer: %s -> %s: %.80s\n' "$sender" "$(printf '%s' "$message" | jq -r '.to|join(",")')" \
        "$(printf '%s' "$message" | jq -r '.text')" >> "$status_path"; then
      echo "warning: message $id recorded, but sender status append failed; do not send replacement text" >&2
    fi
  fi
  printf 'message=%s thread=%s delivered=%s\n' "$id" "$thread" "$records"
  if [ "$failed" -ne 0 ]; then
    printf 'error: partial delivery retained in ledger; retry only: fm-send.sh --retry %s --thread %s\n' "$id" "$thread" >&2
    exit 3
  fi
  refusal_reason=delivered
)
