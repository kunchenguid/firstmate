#!/usr/bin/env bash
# Message telemetry port. Append-only daily JSONL under
# state/fm-message/telemetry/YYYY-MM-DD.jsonl; schema=fm-message-telemetry.v1.
# One request id joins intake, decisions, adapter results and terminal counters.
# No text, environment, argv or captured stderr is logged; only bounded ids,
# sizes, static reason codes, timings and public task execution dimensions.
# Model tokens/cost remain null: this module does not call a model provider.
# Logging failures warn without changing an already-delivered message outcome.
# Usage: fm_message_log <event> <outcome> <static-reason>
#        fm_message_stats <state-dir>  (rolling last 24 hours, JSON)
# The calling send's locals supply request context; this file adds no process.

# shellcheck source=bin/fm-timing-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-timing-lib.sh"

fm_message_telemetry_id() {  # <identifier>, never arbitrary rejected input
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ "${#1}" -le 128 ] || return 0
  printf '%s' "$1"
}

fm_message_telemetry_dimension() {  # <model/harness/effort>
  case "$1" in *[!A-Za-z0-9._:@/+-]*) return 0 ;; esac
  [ "${#1}" -le 160 ] || return 0
  printf '%s' "$1"
}

fm_message_log() {
  local event=$1 outcome=$2 reason=$3 dir file now row elapsed step_elapsed state thread_id evidence lock
  state="$FM_HOME/state"
  dir="$state/fm-message/telemetry"
  if [ -L "$state" ] || [ -L "$state/fm-message" ] || [ -L "$dir" ]; then
    echo 'warning: message telemetry path is symlinked; logging refused' >&2; return 0
  fi
  file="$dir/$(date -u +%Y-%m-%d).jsonl"
  if [ -L "$file" ] || ! mkdir -p "$dir"; then
    echo 'warning: message telemetry is unavailable' >&2; return 0
  fi
  now=$(fm_timing_now_ms); elapsed=$((now-${started_ms:-now})); step_elapsed=$((now-${step_ms:-now}))
  [ "$elapsed" -ge 0 ] || elapsed=0
  [ "$step_elapsed" -ge 0 ] || step_elapsed=0
  thread_id=$(fm_message_telemetry_id "${thread:-}")
  evidence=''
  [ -z "${ledger:-}" ] || evidence="data/threads/$thread_id.md"
  row=$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg event "$event" --arg request "${request_id:-}" --arg message "${id:-}" \
    --arg thread "$thread_id" --arg actor "$(fm_message_telemetry_id "${sender:-}")" --arg outcome "$outcome" \
    --arg phase "${phase:-intake}" --arg reason "$reason" --arg evidence "$evidence" \
    --arg model "$(fm_message_telemetry_dimension "${sender_model:-}")" \
    --arg harness "$(fm_message_telemetry_dimension "${sender_harness:-}")" \
    --arg effort "$(fm_message_telemetry_dimension "${sender_effort:-}")" \
    --arg recipients "${recipients:-}" --arg target "$(fm_message_telemetry_id "${meta:-}")" \
    --argjson textBytes "${text_size:-0}" --argjson recipientCount "${recipient_count:-0}" \
    --argjson elapsed "$elapsed" --argjson stepElapsed "$step_elapsed" \
    --argjson validated "${validated_count:-0}" --argjson delivered "${delivered_count:-0}" \
    --argjson failed "${failed_count:-0}" --argjson retries "${retry_count:-0}" '
      {schema:"fm-message-telemetry.v1",ts:$ts,module:"fm-message",event:$event,
       requestId:$request,messageId:($message|if .=="" then null else . end),
       threadId:($thread|if .=="" then null else . end),actor:($actor|if .=="" then null else . end),
       inputs:{bytes:$textBytes,recipientCount:$recipientCount,
         ids:($recipients|split("\n")|map(select(length>0))),targetId:($target|if .=="" then null else . end)},
       decision:$phase,reasons:[$reason],stepsMs:{total:$elapsed,($phase):$stepElapsed},
       model:($model|if .=="" then null else . end),harness:($harness|if .=="" then null else . end),
       effort:($effort|if .=="" then null else . end),tokens:null,cost:null,
       outcome:($outcome|if .=="" then null else . end),
       evidencePath:($evidence|if .=="" then null else . end),
       counters:{validated:$validated,delivered:$delivered,failed:$failed,retries:$retries}}
    ') || { echo 'warning: message telemetry encoding failed' >&2; return 0; }
  lock="$dir/.append.lock"
  if fm_task_inbox_lock_acquire "$lock"; then
    printf '%s\n' "$row" >> "$file" || echo 'warning: message telemetry append failed' >&2
    fm_lock_release "$lock"
  else
    echo 'warning: message telemetry append lock unavailable' >&2
  fi
  return 0
}

fm_message_step() {  # <step>
  phase=$1
  step_ms=$(fm_timing_now_ms)
  fm_message_log step '' entered
}

fm_message_stats() {  # <state-dir>
  local file dir="$1/fm-message/telemetry" files=()
  [ ! -L "$1/fm-message" ] && [ ! -L "$dir" ] || return 1
  for file in "$dir/"*.jsonl; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    files+=("$file")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    printf '%s\n' '{"schema":"fm-message-stats.v1","hours":24,"events":0,"requests":0,"accepted":0,"rejected":0,"errors":0,"delivered":0}'
    return 0
  fi
  jq -se '
    if any(.[]; .schema!="fm-message-telemetry.v1") then error("unknown telemetry schema") else . end
    | map(select((.ts|fromdateiso8601)>=(now-86400))) as $events
    | [$events[]|select(.event=="finished")] as $finished
    | {schema:"fm-message-stats.v1",hours:24,events:($events|length),requests:($finished|length),
       accepted:([$finished[]|select(.outcome=="accepted")]|length),
       rejected:([$finished[]|select(.outcome=="rejected")]|length),
       errors:([$finished[]|select(.outcome=="error")]|length),
       delivered:([$finished[].counters.delivered]|add//0)}
  ' "${files[@]}"
}
