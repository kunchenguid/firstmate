#!/usr/bin/env bash
# Own the captain-facing task lifecycle projection and its minimal durable record.
#
# Usage: fm-task-lifecycle.sh project [--snapshot <path>|-] [--callsigns-json <json>] [--selector <canonical-id>]
#        fm-task-lifecycle.sh show <selector>
#        fm-task-lifecycle.sh review-start <selector>
#        fm-task-lifecycle.sh accept <selector> --actor <actor> --evidence <text> --route <close|deliver|deliver-monitor> [--limitations <text>]
#        fm-task-lifecycle.sh accept-close <selector> --actor <actor> --evidence <text> [--limitations <text>]
#        fm-task-lifecycle.sh return-to-work <selector> --reason <text>
#        fm-task-lifecycle.sh delivery-start <selector>
#        fm-task-lifecycle.sh delivery-complete <selector> --evidence <text>
#        fm-task-lifecycle.sh monitoring-start <selector>
#        fm-task-lifecycle.sh monitoring-complete <selector> --evidence <text>
#        fm-task-lifecycle.sh close-check <selector>
#
# docs/task-lifecycle.md is the single semantic owner of statuses and routes.
# This command does not rename or mutate backlog states, worker states, holds, or
# status events. It projects those authorities into the captain-facing model and
# writes only data/task-lifecycle/<id>.json after review begins. The record keeps
# review/acceptance and selected-route milestones available after runtime cleanup.
# Every mutation is selector-resolved, transition-checked, locked, and atomically
# replaced. FM_TASK_LIFECYCLE_NOW is a deterministic test seam for UTC timestamps.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LIFECYCLE_ROOT="$DATA/task-lifecycle"

# shellcheck source=bin/fm-callsigns-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-callsigns-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

fail() { printf 'fm-task-lifecycle: %s\n' "$*" >&2; return 1; }

safe_id() {
  case "${1:-}" in ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

now_utc() {
  if [ -n "${FM_TASK_LIFECYCLE_NOW:-}" ]; then
    printf '%s\n' "$FM_TASK_LIFECYCLE_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

record_path() { printf '%s/%s.json\n' "$LIFECYCLE_ROOT" "$1"; }

validate_record() {  # <id> <file>
  local id=$1 file=$2
  jq -e --arg id "$id" '
    .version == 1 and .id == $id
    and (.stage == "working" or .stage == "reviewing" or .stage == "accepted" or .stage == "delivering" or .stage == "monitoring")
    and (.updatedAt | type == "string" and length > 0)
    and (.review == null or (.review | type == "object"))
    and (.acceptance == null or
      (.acceptance | type == "object"
       and (.actor | type == "string" and length > 0)
       and (.at | type == "string" and length > 0)
       and (.evidence | type == "string" and length > 0)
       and (.limitations | type == "string" and length > 0)
       and (.route == "close" or .route == "deliver" or .route == "deliver-monitor")))
    and (.delivery == null or (.delivery | type == "object"))
    and (.monitoring == null or (.monitoring | type == "object"))
  ' "$file" >/dev/null 2>&1
}

read_record() {  # <id>; prints JSON object or null
  local id=$1 file
  safe_id "$id" || { fail "invalid task id '$id'"; return 1; }
  file=$(record_path "$id")
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'null\n'
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || { fail "unsafe lifecycle record at $file"; return 1; }
  validate_record "$id" "$file" || { fail "invalid lifecycle record at $file"; return 1; }
  jq -c . "$file"
}

ensure_root() {
  if [ -e "$LIFECYCLE_ROOT" ] || [ -L "$LIFECYCLE_ROOT" ]; then
    [ -d "$LIFECYCLE_ROOT" ] && [ ! -L "$LIFECYCLE_ROOT" ] \
      || { fail "lifecycle record directory is unsafe at $LIFECYCLE_ROOT"; return 1; }
  else
    (umask 077; mkdir -p "$LIFECYCLE_ROOT") || return 1
  fi
}

LOCK_PATH=
lock_task() {  # <id>
  local id=$1 n=0
  mkdir -p "$STATE" || return 1
  LOCK_PATH="$STATE/.task-lifecycle-$id.lock"
  while ! mkdir "$LOCK_PATH" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -lt 200 ] || { fail "another lifecycle transition is already running for $id"; return 1; }
    sleep 0.05
  done
  printf '%s\n' "$$" > "$LOCK_PATH/pid"
}

unlock_task() {
  [ -z "$LOCK_PATH" ] || rm -rf -- "$LOCK_PATH"
  LOCK_PATH=
}

write_record() {  # <id> <json>
  local id=$1 json=$2 file tmp
  ensure_root || return 1
  file=$(record_path "$id")
  [ ! -L "$file" ] || { fail "unsafe lifecycle record at $file"; return 1; }
  tmp="$file.tmp.$$"
  printf '%s\n' "$json" | jq . > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file"
}

load_snapshot() {  # <path-or-empty>
  local path=$1
  if [ -z "$path" ]; then
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json
  elif [ "$path" = - ]; then
    cat
  else
    [ -f "$path" ] || { fail "snapshot not found: $path"; return 1; }
    cat "$path"
  fi
}

project_model() {  # <snapshot-json> <callsigns-json> <selector>
  local snapshot=$1 callsigns=$2 selector=$3 records_file ids_file id record file rc=0
  records_file=$(mktemp "${TMPDIR:-/tmp}/fm-task-lifecycle-records.XXXXXX") || return 1
  ids_file=$(mktemp "${TMPDIR:-/tmp}/fm-task-lifecycle-ids.XXXXXX") || { rm -f "$records_file"; return 1; }
  printf '%s\n' "$snapshot" | jq -r '
    [(.backlog.records[]? | select(.structured == true) | .id), (.tasks[]? | .id)]
    | unique[]
  ' > "$ids_file" || rc=1
  if [ "$rc" -eq 0 ]; then
    for file in "$LIFECYCLE_ROOT"/*.json; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      id=${file##*/}; id=${id%.json}
      safe_id "$id" || { fail "invalid lifecycle record name at $file"; rc=1; break; }
      printf '%s\n' "$id" >> "$ids_file"
    done
  fi
  if [ "$rc" -eq 0 ]; then
    sort -u "$ids_file" -o "$ids_file"
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      if ! record=$(read_record "$id"); then rc=1; break; fi
      [ "$record" = null ] || printf '%s\n' "$record" >> "$records_file"
    done < "$ids_file"
  fi
  if [ "$rc" -ne 0 ]; then rm -f "$records_file" "$ids_file"; return 1; fi
  RECORDS=$(jq -s . "$records_file") || { rm -f "$records_file" "$ids_file"; return 1; }
  rm -f "$records_file" "$ids_file"

  printf '%s\n' "$snapshot" | jq \
    --argjson callsigns "$callsigns" --argjson lifecycles "$RECORDS" --arg selector "$selector" '
    def trunc($n): tostring | gsub("\\s+"; " ") | gsub("\\|"; "/") | if length > $n then .[:($n-1)] + "…" else . end;
    def call($id): ([ $callsigns[] | select(.id == $id) ] | first) // {};
    def life($id): ([ $lifecycles[] | select(.id == $id) ] | first) // null;
    def event_note($t): ($t.hints.last_event_text // "" | sub("^[^:]+:[[:space:]]*"; ""));
    def current_detail($t):
      ([$t.current_state.detail, event_note($t)] | map(select(. != null and . != "")) | .[0]) // "";
    def captain_action($r; $t):
      $r.captain_actionable == true or $r.hold_kind == "captain"
      or ($t.hints.pending_decision // false)
      or (($t.hints.open_decisions // []) | length) > 0
      or ($t.current_state.state // "") == "parked";
    def external_wait($r; $t):
      (($r.hold_kind // "") != "" and ($r.hold_kind // "") != "captain")
      or ($t.current_state.state // "") == "paused";
    def concrete_blocker($r; $t):
      (($r.unresolved_blocker_ids // []) | length) > 0
      or ($t.hints.blocked_event // false)
      or ($t.current_state.state // "") == "blocked";
    def explicit_stage($l):
      if $l == null then null
      elif ($l.stage == "reviewing" or $l.stage == "accepted" or $l.stage == "delivering" or $l.stage == "monitoring") then $l.stage
      else null end;
    def row_status($r; $t; $l):
      if captain_action($r; $t) then "needs-you"
      elif external_wait($r; $t) then "waiting"
      elif concrete_blocker($r; $t) then "blocked"
      elif $t != {} and ($t.current_state.state // "") == "failed" then "failed"
      elif explicit_stage($l) != null then explicit_stage($l)
      elif $l.stage == "working" and ($t.current_state.state // "") != "done" then "working"
      elif $r.state == "queued" then "queued"
      elif $r.state == "done" or ($t.current_state.state // "") == "done" then "done"
      elif ($t.current_state.state // "") == "working" then "working"
      elif $r.state == "in_flight" then "blocked"
      else "blocked" end;
    def route($l): $l.acceptance.route // null;
    def delivery_complete($l): ($l.delivery.completedAt // "") != "";
    def monitoring_complete($l): ($l.monitoring.completedAt // "") != "";
    def close_ready($status; $l):
      if $status == "accepted" and route($l) == "close" then true
      elif $status == "delivering" and route($l) == "deliver" and delivery_complete($l) then true
      elif $status == "monitoring" and route($l) == "deliver-monitor" and monitoring_complete($l) then true
      else false end;
    def next_action($id; $status; $l):
      if $status == "queued" then "Start authorized work"
      elif $status == "working" then "Continue the current work"
      elif $status == "waiting" then "Wait for the recorded external condition"
      elif $status == "blocked" then "Firstmate must resolve the recorded problem"
      elif $status == "needs-you" then "Provide the recorded decision, approval, credential, or security action"
      elif $status == "done" then "Start review"
      elif $status == "reviewing" then "Accept the result or return it to work with a correction"
      elif $status == "accepted" and route($l) == "close" then "Close the accepted task"
      elif $status == "accepted" then "Start the selected delivery route"
      elif $status == "delivering" and route($l) == "deliver-monitor" and delivery_complete($l) then "Start monitoring"
      elif $status == "delivering" and delivery_complete($l) then "Close the delivered task"
      elif $status == "delivering" then "Complete delivery"
      elif $status == "monitoring" and monitoring_complete($l) then "Close the monitored task"
      elif $status == "monitoring" then "Complete monitoring"
      elif $status == "failed" then "Decide whether to retry as new work"
      else "Reconcile the task" end;
    def outcome($r; $t; $status; $l):
      if $status == "queued" then "Authorized; not started"
      elif $status == "working" then (current_detail($t) | if . == "" then "Work in progress" else . end)
      elif $status == "waiting" then ($r.hold_reason // (current_detail($t) | if . == "" then "External condition has not cleared" else . end))
      elif $status == "blocked" then
        (($r.unresolved_blocker_ids // [] | join(", ")) as $b
         | if $b != "" then "Waiting on " + $b
           elif (current_detail($t)) != "" then current_detail($t)
           else "Current progress is unavailable; Firstmate must reconcile it" end)
      elif $status == "needs-you" then ($r.hold_reason // (current_detail($t) | if . == "" then "One exact captain action is required" else . end))
      elif $status == "done" then
        (current_detail($t)) as $detail
        | if $detail == "" then "Candidate result ready; review has not started"
          else $detail + "; candidate ready for review" end
      elif $status == "reviewing" then "Review in progress"
      elif $status == "accepted" then
        if route($l) == "close" then "Accepted for closure"
        elif route($l) == "deliver-monitor" then "Accepted for delivery and monitoring"
        else "Accepted for delivery" end
      elif $status == "delivering" then
        if delivery_complete($l) and route($l) == "deliver-monitor" then "Delivery complete; monitoring has not started"
        elif delivery_complete($l) then "Delivery complete; ready to close"
        else "Delivery in progress" end
      elif $status == "monitoring" then
        if monitoring_complete($l) then "Monitoring complete; ready to close" else "Post-delivery monitoring in progress" end
      elif $status == "failed" then (current_detail($t) | if . == "" then "Attempt ended unsuccessfully" else . end)
      else "Current task state unavailable" end;
    def phase_started($status; $l; $t):
      if $status == "reviewing" then ($l.review.startedAt // null)
      elif $status == "delivering" then ($l.delivery.startedAt // null)
      elif $status == "monitoring" then ($l.monitoring.startedAt // null)
      elif $status == "working" and $l.stage == "working" then ($l.correction.at // $t.started_at // null)
      else ($t.started_at // null) end;
    def make($id; $r; $t):
      (call($id)) as $c
      | (life($id)) as $l
      | (if ($c.name // "") != "" then $c.name else $id end) as $name
      | (row_status($r; $t; $l)) as $status
      | {id:$id, ref:($c.ref // "-"), name:$name, status:$status,
         started_at:phase_started($status; $l; $t),
         outcome:(outcome($r; $t; $status; $l) | trunc(100)),
         next_action:next_action($id; $status; $l), route:route($l),
         close_ready:close_ready($status; $l), lifecycle:$l};
    . as $snapshot
    | def task($id): ([$snapshot.tasks[]? | select(.id == $id)] | first) // {};
    ([.backlog.records[]? | select(.structured == true and (.state == "in_flight" or .state == "queued" or .state == "done"))
      | . as $r | make($r.id; $r; task($r.id))]) as $backlog_rows
    | ($backlog_rows | map(.id)) as $backlog_ids
    | ($backlog_rows
       + [.tasks[]? | select(.kind != "secondmate")
          | .id as $id | select(($backlog_ids | index($id)) == null)
          | make($id; {state:"in_flight",structured:true}; .)]
       + [$lifecycles[]? | .id as $id
          | select(($backlog_ids | index($id)) == null)
          | select(([$snapshot.tasks[]? | select(.id == $id)] | length) == 0)
          | make($id; {state:"done",structured:true,title:$id}; {})])
    | unique_by(.id)
    | if $selector == "" then . else map(select(.id == $selector)) end
    | sort_by([(.ref | ltrimstr("t") | tonumber? // 1000), .id])
  '
}

project_command() {
  local snapshot_path= callsigns_json= selector= snapshot
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --snapshot) [ "$#" -ge 2 ] || { usage >&2; return 2; }; snapshot_path=$2; shift 2 ;;
      --snapshot=*) snapshot_path=${1#--snapshot=}; shift ;;
      --callsigns-json) [ "$#" -ge 2 ] || { usage >&2; return 2; }; callsigns_json=$2; shift 2 ;;
      --selector) [ "$#" -ge 2 ] || { usage >&2; return 2; }; selector=$2; shift 2 ;;
      *) usage >&2; return 2 ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || { fail "jq is required"; return 1; }
  snapshot=$(load_snapshot "$snapshot_path") || return 1
  printf '%s\n' "$snapshot" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null 2>&1 \
    || { fail "project requires fm-fleet-snapshot.v1"; return 1; }
  if [ -z "$callsigns_json" ]; then callsigns_json=$(fm_callsigns_json) || return 1; fi
  printf '%s\n' "$callsigns_json" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || { fail "invalid task reference JSON"; return 1; }
  project_model "$snapshot" "$callsigns_json" "$selector"
}

resolve_id() {
  local selector=$1 id snapshot count
  snapshot=$(load_snapshot "") || return 1
  count=$(printf '%s\n' "$snapshot" | jq --arg id "$selector" '
    [.backlog.records[]? | select(.structured == true and .id == $id)] | length') || return 1
  if [ "$count" -eq 1 ]; then
    id=$selector
  else
    id=$(fm_callsign_resolve "$selector") || return 1
  fi
  safe_id "$id" || { fail "invalid resolved task id '$id'"; return 1; }
  printf '%s\n' "$id"
}

live_row() {  # <id>
  local snapshot model
  snapshot=$(load_snapshot "") || return 1
  model=$(project_model "$snapshot" '[]' "$1") || return 1
  [ "$(printf '%s\n' "$model" | jq 'length')" -eq 1 ] || { fail "task $1 is not current"; return 1; }
  printf '%s\n' "$model" | jq -c '.[0]'
}

require_status() {  # <id> <status>
  local row status
  row=$(live_row "$1") || return 1
  status=$(printf '%s\n' "$row" | jq -r '.status')
  [ "$status" = "$2" ] || { fail "task $1 must be $2, not $status"; return 1; }
}

transition_record() {  # <command> <id> <actor> <evidence> <route> <limitations> <reason>
  local command=$1 id=$2 actor=$3 evidence=$4 route=$5 limitations=$6 reason=$7 old now json stage
  lock_task "$id" || return 1
  old=$(read_record "$id") || { unlock_task; return 1; }
  now=$(now_utc)
  case "$command" in
    review-start)
      if ! require_status "$id" done; then unlock_task; return 1; fi
      if [ "$old" != null ] && [ "$(printf '%s\n' "$old" | jq -r '.stage')" != working ]; then
        fail "task $id already has an active lifecycle stage"
        unlock_task
        return 1
      fi
      json=$(jq -n --arg id "$id" --arg now "$now" '
        {version:1,id:$id,stage:"reviewing",updatedAt:$now,
         review:{startedAt:$now,completedAt:null},acceptance:null,delivery:null,monitoring:null,correction:null}')
      ;;
    accept|accept-close)
      if [ "$command" = accept ]; then
        [ "$old" != null ] && [ "$(printf '%s\n' "$old" | jq -r '.stage')" = reviewing ] \
          || { fail "task $id must be reviewing before acceptance"; unlock_task; return 1; }
        if ! require_status "$id" reviewing; then unlock_task; return 1; fi
      else
        stage=$(printf '%s\n' "$old" | jq -r 'if . == null then "none" else .stage end')
        case "$stage" in
          none|working) if ! require_status "$id" done; then unlock_task; return 1; fi ;;
          reviewing) if ! require_status "$id" reviewing; then unlock_task; return 1; fi ;;
          *) fail "task $id cannot combine acceptance and closure from $stage"; unlock_task; return 1 ;;
        esac
        route=close
      fi
      json=$(printf '%s\n' "$old" | jq \
        --arg id "$id" --arg now "$now" --arg actor "$actor" --arg evidence "$evidence" \
        --arg limitations "$limitations" --arg route "$route" '
        (if . == null then
           {version:1,id:$id,review:{startedAt:$now,completedAt:$now},delivery:null,monitoring:null,correction:null}
         else . | .review = ((.review // {startedAt:$now}) + {completedAt:$now}) end)
        | .version=1 | .id=$id | .stage="accepted" | .updatedAt=$now
        | .acceptance={actor:$actor,at:$now,evidence:$evidence,limitations:$limitations,route:$route}
        | .delivery=null | .monitoring=null')
      ;;
    return-to-work)
      [ "$old" != null ] || { fail "task $id has no review or delivery stage to return"; unlock_task; return 1; }
      stage=$(printf '%s\n' "$old" | jq -r '.stage')
      case "$stage" in reviewing|delivering|monitoring) ;; *) fail "task $id cannot return to work from $stage"; unlock_task; return 1 ;; esac
      json=$(printf '%s\n' "$old" | jq --arg now "$now" --arg reason "$reason" --arg from "$stage" '
        .stage="working" | .updatedAt=$now
        | .correction={from:$from,at:$now,reason:$reason}
        | .review=null | .acceptance=null | .delivery=null | .monitoring=null')
      ;;
    delivery-start)
      [ "$old" != null ] && [ "$(printf '%s\n' "$old" | jq -r '.stage')" = accepted ] \
        || { fail "task $id must be accepted before delivery"; unlock_task; return 1; }
      route=$(printf '%s\n' "$old" | jq -r '.acceptance.route')
      case "$route" in deliver|deliver-monitor) ;; *) fail "task $id selected route close, not delivery"; unlock_task; return 1 ;; esac
      if ! require_status "$id" accepted; then unlock_task; return 1; fi
      json=$(printf '%s\n' "$old" | jq --arg now "$now" '
        .stage="delivering" | .updatedAt=$now
        | .delivery={startedAt:$now,completedAt:null,evidence:null} | .monitoring=null')
      ;;
    delivery-complete)
      [ "$old" != null ] && [ "$(printf '%s\n' "$old" | jq -r '.stage')" = delivering ] \
        || { fail "task $id must be delivering before delivery can complete"; unlock_task; return 1; }
      [ "$(printf '%s\n' "$old" | jq -r '.delivery.completedAt // empty')" = "" ] \
        || { fail "task $id delivery is already complete"; unlock_task; return 1; }
      if ! require_status "$id" delivering; then unlock_task; return 1; fi
      json=$(printf '%s\n' "$old" | jq --arg now "$now" --arg evidence "$evidence" '
        .updatedAt=$now | .delivery.completedAt=$now | .delivery.evidence=$evidence')
      ;;
    monitoring-start)
      [ "$old" != null ] && [ "$(printf '%s\n' "$old" | jq -r '.stage')" = delivering ] \
        || { fail "task $id must finish delivery before monitoring"; unlock_task; return 1; }
      [ "$(printf '%s\n' "$old" | jq -r '.acceptance.route')" = deliver-monitor ] \
        || { fail "task $id did not select delivery with monitoring"; unlock_task; return 1; }
      [ -n "$(printf '%s\n' "$old" | jq -r '.delivery.completedAt // empty')" ] \
        || { fail "task $id delivery is not complete"; unlock_task; return 1; }
      if ! require_status "$id" delivering; then unlock_task; return 1; fi
      json=$(printf '%s\n' "$old" | jq --arg now "$now" '
        .stage="monitoring" | .updatedAt=$now
        | .monitoring={startedAt:$now,completedAt:null,evidence:null}')
      ;;
    monitoring-complete)
      [ "$old" != null ] && [ "$(printf '%s\n' "$old" | jq -r '.stage')" = monitoring ] \
        || { fail "task $id must be monitoring before monitoring can complete"; unlock_task; return 1; }
      [ "$(printf '%s\n' "$old" | jq -r '.monitoring.completedAt // empty')" = "" ] \
        || { fail "task $id monitoring is already complete"; unlock_task; return 1; }
      if ! require_status "$id" monitoring; then unlock_task; return 1; fi
      json=$(printf '%s\n' "$old" | jq --arg now "$now" --arg evidence "$evidence" '
        .updatedAt=$now | .monitoring.completedAt=$now | .monitoring.evidence=$evidence')
      ;;
    *) fail "unknown transition $command"; unlock_task; return 2 ;;
  esac
  if ! write_record "$id" "$json"; then unlock_task; return 1; fi
  unlock_task
  printf '%s\n' "$json" | jq -c .
}

transition_command() {
  local command=$1 selector=${2:-} actor= evidence= route= limitations='none declared' reason= id
  [ -n "$selector" ] || { usage >&2; return 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --actor) [ "$#" -ge 2 ] || { usage >&2; return 2; }; actor=$2; shift 2 ;;
      --evidence) [ "$#" -ge 2 ] || { usage >&2; return 2; }; evidence=$2; shift 2 ;;
      --route) [ "$#" -ge 2 ] || { usage >&2; return 2; }; route=$2; shift 2 ;;
      --limitations) [ "$#" -ge 2 ] || { usage >&2; return 2; }; limitations=$2; shift 2 ;;
      --reason) [ "$#" -ge 2 ] || { usage >&2; return 2; }; reason=$2; shift 2 ;;
      *) usage >&2; return 2 ;;
    esac
  done
  case "$command" in
    accept)
      [ -n "$actor" ] && [ -n "$evidence" ] || { fail "accept requires --actor and --evidence"; return 2; }
      case "$route" in close|deliver|deliver-monitor) ;; *) fail "accept requires --route close, deliver, or deliver-monitor"; return 2 ;; esac
      ;;
    accept-close)
      [ -n "$actor" ] && [ -n "$evidence" ] || { fail "accept-close requires --actor and --evidence"; return 2; }
      ;;
    return-to-work) [ -n "$reason" ] || { fail "return-to-work requires --reason"; return 2; } ;;
    delivery-complete|monitoring-complete) [ -n "$evidence" ] || { fail "$command requires --evidence"; return 2; } ;;
    review-start|delivery-start|monitoring-start) ;;
    *) usage >&2; return 2 ;;
  esac
  id=$(resolve_id "$selector") || return 1
  transition_record "$command" "$id" "$actor" "$evidence" "$route" "$limitations" "$reason"
}

show_command() {
  local id row
  id=$(resolve_id "$1") || return 1
  row=$(live_row "$id") || return 1
  printf '%s\n' "$row" | jq .
}

close_check_command() {
  local id row ready
  id=$(resolve_id "$1") || return 1
  row=$(live_row "$id") || return 1
  ready=$(printf '%s\n' "$row" | jq -r '.close_ready')
  if [ "$ready" != true ]; then
    fail "task $id cannot close: $(printf '%s\n' "$row" | jq -r '.next_action')"
    return 1
  fi
  printf '%s\n' "$row" | jq -c '.lifecycle'
}

command=${1:-}
case "$command" in
  project) shift; project_command "$@" ;;
  show) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; show_command "$2" ;;
  close-check) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; close_check_command "$2" ;;
  review-start|accept|accept-close|return-to-work|delivery-start|delivery-complete|monitoring-start|monitoring-complete)
    transition_command "$@"
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
