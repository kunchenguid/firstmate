# shellcheck shell=bash
# T3 main-thread lead delegation records for a Firstmate home.
#
# The T3 Code MCP tools (delegate_task, task_status, t3_thread_send, task_cancel)
# run only inside the captain's active main T3 thread.
# This library owns durable home-bound records, validation, idempotent transitions,
# worktree isolation checks, and the mapping from imported tool JSON into Firstmate
# task status and backlog-facing semantics.
# It never calls T3 tools itself.
#
# Usage: . bin/fm-t3-delegation-lib.sh
#
# Record path: state/t3-delegations/<clientRequestId>.json
# Enablement: config/t3-main-thread-lead presence flag, or FM_T3_MAIN_THREAD_LEAD=on|off
#
# See docs/t3-main-thread-lead.md and .agents/skills/t3-main-thread-lead/SKILL.md.

FM_T3_DELEGATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_T3_DELEGATION_SCHEMA=1

fm_t3_delegation_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-t3-delegation: jq is required\n' >&2
    return 2
  }
}

fm_t3_delegation_home_state() {
  FM_T3_STATE="${FM_STATE_OVERRIDE:-${STATE:-${FM_HOME:-}/state}}"
  FM_T3_CONFIG="${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}"
  FM_T3_RECORD_DIR="$FM_T3_STATE/t3-delegations"
}

fm_t3_delegation_enabled() { # [<config-dir>]
  local cfg=${1:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}}
  case "${FM_T3_MAIN_THREAD_LEAD:-}" in
    1 | on | ON | true | yes | YES) return 0 ;;
    0 | off | OFF | false | no | NO) return 1 ;;
    '') ;;
    *) return 1 ;;
  esac
  [ -f "$cfg/t3-main-thread-lead" ]
}

fm_t3_delegation_valid_client_request_id() { # <id>
  local id=$1
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$ ]]
}

fm_t3_delegation_valid_thread_id() { # <uuid-ish>
  local id=$1
  [[ $id =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

fm_t3_delegation_record_path() { # <clientRequestId>
  fm_t3_delegation_home_state
  printf '%s/%s.json\n' "$FM_T3_RECORD_DIR" "$1"
}

fm_t3_delegation_real_dir() {
  local d=$1 out
  out=$(cd "$d" 2>/dev/null && pwd -P) || return 1
  printf '%s' "$out"
}

fm_t3_delegation_common_dir() { # <path>
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  fm_t3_delegation_real_dir "$common"
}

# Isolated worktree of <project>: own worktree root, not the project primary checkout.
fm_t3_worktree_isolated() { # <project> <worktree>
  local project=$1 worktree=$2 proj_real wt_real wt_top wt_top_real wt_git proj_common reason=''
  proj_real=$(fm_t3_delegation_real_dir "$project") || return 1
  wt_real=$(fm_t3_delegation_real_dir "$worktree") || return 1
  if [ "$wt_real" = "$proj_real" ]; then
    FM_T3_WT_REASON="it is the project primary checkout"
    return 1
  fi
  wt_top=$(git -C "$wt_real" rev-parse --show-toplevel 2>/dev/null) || {
    FM_T3_WT_REASON="it is not inside a git worktree"
    return 1
  }
  wt_top_real=$(fm_t3_delegation_real_dir "$wt_top") || {
    FM_T3_WT_REASON="worktree root could not be resolved"
    return 1
  }
  if [ "$wt_real" != "$wt_top_real" ]; then
    FM_T3_WT_REASON="path is not a worktree root"
    return 1
  fi
  wt_git=$(git -C "$wt_real" rev-parse --absolute-git-dir 2>/dev/null) &&
    wt_git=$(fm_t3_delegation_real_dir "$wt_git") || wt_git=
  proj_common=$(fm_t3_delegation_common_dir "$proj_real") || proj_common=
  if [ -z "$wt_git" ] || [ -z "$proj_common" ]; then
    FM_T3_WT_REASON="git directories could not be resolved"
    return 1
  fi
  if [ "$wt_git" = "$proj_common" ]; then
    FM_T3_WT_REASON="it is the repository primary checkout"
    return 1
  fi
  local wt_common
  wt_common=$(fm_t3_delegation_common_dir "$wt_real") || {
    FM_T3_WT_REASON="worktree common dir could not be resolved"
    return 1
  }
  if [ "$wt_common" != "$proj_common" ]; then
    FM_T3_WT_REASON="it is not a worktree of the given project"
    return 1
  fi
  FM_T3_WT_REASON=
  return 0
}

fm_t3_delegation_atomic_write() { # <path> <json>
  local path=$1 json=$2 dir tmp
  dir=${path%/*}
  mkdir -p "$dir" || return 1
  tmp="${path}.tmp.$$"
  printf '%s\n' "$json" > "$tmp" || return 1
  mv "$tmp" "$path"
}

fm_t3_delegation_read() { # <clientRequestId>
  local path
  path=$(fm_t3_delegation_record_path "$1")
  [ -f "$path" ] || return 1
  jq -c . "$path"
}

fm_t3_delegation_phase_terminal() { # <phase>
  case "$1" in
    completed | failed | interrupted | cancelled) return 0 ;;
    *) return 1 ;;
  esac
}

# Merge-update an existing record; refuses illegal phase regressions and identity drift.
fm_t3_delegation_merge() { # <clientRequestId> <jq-merge-program> [slurpfile args...]
  local id=$1 program=$2 path existing merged
  shift 2
  fm_t3_delegation_require_jq || return 2
  path=$(fm_t3_delegation_record_path "$id")
  existing=
  if [ -f "$path" ]; then
    existing=$(jq -c . "$path") || return 1
  else
    existing='null'
  fi
  merged=$(jq -cn --argjson cur "$existing" "$program") || return 1
  [ "$merged" != null ] || {
    printf 'fm-t3-delegation: merge produced null for %s\n' "$id" >&2
    return 1
  }
  fm_t3_delegation_atomic_write "$path" "$merged"
  printf '%s' "$merged"
}

fm_t3_delegation_now() {
  date +%s
}

fm_t3_delegation_record_intent() { # args via env vars set by caller
  local id=$1 task=$2 parent=$3 kind=$4 mode=$5 yolo=$6 project=$7 base=$8
  local prefix=$9 source_wt=${10} isolation_req=${11} branch=${12}
  fm_t3_delegation_require_jq || return 2
  fm_t3_delegation_valid_client_request_id "$id" || return 1
  fm_t3_delegation_valid_thread_id "$parent" || return 1
  fm_t3_delegation_home_state
  mkdir -p "$FM_T3_RECORD_DIR" || return 1
  local path now prog
  now=$(fm_t3_delegation_now)
  path=$(fm_t3_delegation_record_path "$id")
  if [ -f "$path" ]; then
    local cur_task cur_parent
    cur_task=$(jq -r '.taskId // empty' "$path")
    cur_parent=$(jq -r '.parentThreadId // empty' "$path")
    if [ "$cur_task" != "$task" ] || [ "$cur_parent" != "$parent" ]; then
      printf 'fm-t3-delegation: clientRequestId %s already bound to a different task or parent thread\n' "$id" >&2
      return 1
    fi
    out=$(jq --arg kind "$kind" --arg mode "$mode" --arg yolo "$yolo" --arg project "$project" \
      --arg base "$base" --arg prefix "$prefix" --arg source "$source_wt" \
      --arg branch "$branch" --argjson iso "$isolation_req" --argjson now "$now" \
      '.kind = $kind | .mode = $mode | .yolo = $yolo | .project = $project
       | .baseBranch = $base | .branchPrefix = $prefix | .sourceWorktree = $source
       | .isolationRequired = $iso | .shipBranch = $branch | .updatedAt = $now' "$path")
    fm_t3_delegation_atomic_write "$path" "$out" || return 1
    printf '%s' "$out"
    return 0
  fi
  json=$(jq -cn \
    --argjson schema "$FM_T3_DELEGATION_SCHEMA" \
    --arg id "$id" --arg task "$task" --arg parent "$parent" \
    --arg kind "$kind" --arg mode "$mode" --arg yolo "$yolo" \
    --arg project "$project" --arg base "$base" --arg prefix "$prefix" \
    --arg source "$source_wt" --argjson iso "$isolation_req" --arg branch "$branch" \
    --argjson now "$now" \
    '{
      schema: $schema,
      clientRequestId: $id,
      taskId: $task,
      parentThreadId: $parent,
      kind: $kind,
      mode: ($mode // ""),
      yolo: ($yolo // "off"),
      project: ($project // ""),
      baseBranch: ($base // ""),
      branchPrefix: ($prefix // "fm/"),
      sourceWorktree: ($source // ""),
      isolationRequired: $iso,
      isolatedWorktree: "",
      shipBranch: ($branch // ""),
      providerInstanceId: "",
      model: "",
      t3TaskId: "",
      childThreadId: "",
      phase: "intent",
      outcomeKind: "none",
      prUrl: "",
      reportPath: "",
      lastImportDigest: "",
      recoveryNotes: "",
      updatedAt: $now
    }')
  fm_t3_delegation_atomic_write "$path" "$json" || return 1
  printf '%s' "$json"
}

fm_t3_delegation_parse_dispatch_json() { # <file>
  local file=$1
  jq -c '{
    t3TaskId: (.taskId // .t3TaskId // .id // empty),
    childThreadId: (.childThreadId // .threadId // empty),
    providerInstanceId: (.target.providerInstanceId // .providerInstanceId // empty),
    model: (.target.model // .model // empty),
    accepted: (.accepted // true)
  }' "$file" 2>/dev/null
}

fm_t3_delegation_bind_dispatch() { # <clientRequestId> <parentThreadId> <dispatch-json-file>
  local id=$1 parent=$2 file=$3 parsed path now
  fm_t3_delegation_require_jq || return 2
  path=$(fm_t3_delegation_record_path "$id")
  [ -f "$path" ] || {
    printf 'fm-t3-delegation: no intent record for %s\n' "$id" >&2
    return 1
  }
  local rec_parent
  rec_parent=$(jq -r '.parentThreadId // empty' "$path")
  [ "$rec_parent" = "$parent" ] || {
    printf 'fm-t3-delegation: parentThreadId mismatch for %s\n' "$id" >&2
    return 1
  }
  parsed=$(fm_t3_delegation_parse_dispatch_json "$file") || {
    printf 'fm-t3-delegation: malformed dispatch JSON\n' >&2
    return 1
  }
  local t3_task child provider model accepted
  t3_task=$(printf '%s' "$parsed" | jq -r '.t3TaskId // empty')
  child=$(printf '%s' "$parsed" | jq -r '.childThreadId // empty')
  provider=$(printf '%s' "$parsed" | jq -r '.providerInstanceId // empty')
  model=$(printf '%s' "$parsed" | jq -r '.model // empty')
  accepted=$(printf '%s' "$parsed" | jq -r '.accepted // empty')
  now=$(fm_t3_delegation_now)
  if [ -z "$t3_task" ] && [ "$accepted" != true ]; then
    out=$(jq --argjson now "$now" '.phase = "dispatch_uncertain" | .updatedAt = $now' "$path")
    fm_t3_delegation_atomic_write "$path" "$out" || return 1
    printf '%s' "$out"
    return 0
  fi
  [ -n "$t3_task" ] || {
    printf 'fm-t3-delegation: dispatch JSON missing taskId\n' >&2
    return 1
  }
  local existing_t3 existing_child
  existing_t3=$(jq -r '.t3TaskId // empty' "$path")
  existing_child=$(jq -r '.childThreadId // empty' "$path")
  if [ -n "$existing_t3" ] && [ "$existing_t3" != "$t3_task" ]; then
    printf 'fm-t3-delegation: t3TaskId drift for %s\n' "$id" >&2
    return 1
  fi
  if [ -n "$existing_child" ] && [ -n "$child" ] && [ "$existing_child" != "$child" ]; then
    printf 'fm-t3-delegation: childThreadId drift for %s\n' "$id" >&2
    return 1
  fi
  out=$(jq --arg t3 "$t3_task" --arg child "$child" --arg prov "$provider" --arg mod "$model" \
    --argjson now "$now" \
    '.t3TaskId = $t3
     | .childThreadId = (if ($child|length)>0 then $child else .childThreadId end)
     | .providerInstanceId = (if ($prov|length)>0 then $prov else .providerInstanceId end)
     | .model = (if ($mod|length)>0 then $mod else .model end)
     | .phase = (if .phase == "intent" or .phase == "dispatch_uncertain" then "dispatch_accepted" else .phase end)
     | .updatedAt = $now' "$path")
  fm_t3_delegation_atomic_write "$path" "$out" || return 1
  printf '%s' "$out"
}

fm_t3_delegation_map_tool_status() { # <record-json> <status-json>
  local record=$1 status=$2
  jq -cn --argjson rec "$record" --argjson st "$status" '
    def norm: ascii_downcase;
    def st_state: ($st.state // $st.status // $st.phase // "" | tostring | norm);
    def nested_live: ($st.waitingForChildren // $st.hasLiveChildren // $st.nestedLive // false);
    def terminal_completed: st_state | IN("completed","complete","succeeded","success","done");
    def terminal_failed: st_state | IN("failed","error");
    def terminal_cancelled: st_state | IN("cancelled","canceled");
    def terminal_interrupted: st_state | IN("interrupted","stopped");
    (if terminal_completed and nested_live then
      {phase:"waiting_for_children", outcomeKind:$rec.outcomeKind}
    elif terminal_completed then
      {phase:"completed", outcomeKind:(
        if ($rec.kind == "scout") then "scout_report"
        elif ($st.prUrl // $st.pullRequestUrl // "") != "" then "ready_pr"
        elif ($st.branch // $st.readyBranch // "") != "" then "ready_branch"
        else $rec.outcomeKind end)}
    elif terminal_failed then {phase:"failed", outcomeKind:"failure"}
    elif terminal_cancelled then {phase:"cancelled", outcomeKind:"failure"}
    elif terminal_interrupted then {phase:"interrupted", outcomeKind:"failure"}
    elif (st_state | IN("running","working","in_progress","active")) then {phase:"working", outcomeKind:$rec.outcomeKind}
    elif (st_state | IN("pending","queued","accepted")) then {phase:"dispatch_accepted", outcomeKind:$rec.outcomeKind}
    else {phase:$rec.phase, outcomeKind:$rec.outcomeKind} end) as $mapped |
    $mapped + {
      prUrl: ($st.prUrl // $st.pullRequestUrl // $rec.prUrl // ""),
      reportPath: ($st.reportPath // $st.report // $rec.reportPath // ""),
      childThreadId: ($st.childThreadId // $st.threadId // $rec.childThreadId // "")
    }
  '
}

fm_t3_delegation_import_status() { # <clientRequestId> <parentThreadId> <status-json-file>
  local id=$1 parent=$2 file=$3 path digest mapped now rec st
  fm_t3_delegation_require_jq || return 2
  path=$(fm_t3_delegation_record_path "$id")
  [ -f "$path" ] || return 1
  rec_parent=$(jq -r '.parentThreadId // empty' "$path")
  [ "$rec_parent" = "$parent" ] || {
    printf 'fm-t3-delegation: parentThreadId mismatch on import\n' >&2
    return 1
  }
  st=$(jq -c . "$file") || return 1
  digest=$(printf '%s' "$st" | shasum -a 256 | awk '{print $1}')
  local last
  last=$(jq -r '.lastImportDigest // empty' "$path")
  if [ "$last" = "$digest" ]; then
    jq -c . "$path"
    return 0
  fi
  rec=$(jq -c . "$path")
  mapped=$(fm_t3_delegation_map_tool_status "$rec" "$st") || return 1
  now=$(fm_t3_delegation_now)
  out=$(jq --argjson mapped "$mapped" --arg digest "$digest" --argjson now "$now" \
    '.phase = $mapped.phase
     | .outcomeKind = $mapped.outcomeKind
     | .prUrl = $mapped.prUrl
     | .reportPath = $mapped.reportPath
     | .childThreadId = (if ($mapped.childThreadId|length)>0 then $mapped.childThreadId else .childThreadId end)
     | .lastImportDigest = $digest
     | .updatedAt = $now' "$path")
  fm_t3_delegation_atomic_write "$path" "$out" || return 1
  printf '%s' "$out"
}

fm_t3_delegation_list_outstanding() { # <parentThreadId>
  local parent=$1
  fm_t3_delegation_require_jq || return 2
  fm_t3_delegation_home_state
  [ -d "$FM_T3_RECORD_DIR" ] || return 0
  local f
  for f in "$FM_T3_RECORD_DIR"/*.json; do
    [ -f "$f" ] || continue
    jq -r --arg p "$parent" \
      'select(.parentThreadId == $p) | select(.phase != "completed" and .phase != "failed" and .phase != "cancelled" and .phase != "interrupted") |
       [.clientRequestId, .taskId, .phase, .t3TaskId] | @tsv' "$f"
  done
}

fm_t3_delegation_status_line_for_record() { # <record-json>
  local rec=$1
  jq -r '
    . as $r |
    if $r.phase == "waiting_for_children" then
      "paused: T3 delegated work still has live nested children (clientRequestId=\($r.clientRequestId) t3TaskId=\($r.t3TaskId))"
    elif $r.phase == "completed" and $r.outcomeKind == "scout_report" then
      "done: scout report ready for \($r.taskId)\(if ($r.reportPath|length)>0 then " \($r.reportPath)" else "" end)"
    elif $r.phase == "completed" and ($r.outcomeKind == "ready_pr" or ($r.prUrl|length)>0) then
      "checks-passed: PR ready \($r.prUrl)"
    elif $r.phase == "completed" and $r.outcomeKind == "ready_branch" then
      "checks-passed: branch ready for \($r.taskId)"
    elif $r.phase == "completed" then
      "done: T3 delegated task completed (clientRequestId=\($r.clientRequestId))"
    elif $r.phase == "failed" then
      "failed: T3 delegated task failed (clientRequestId=\($r.clientRequestId))"
    elif $r.phase == "cancelled" then
      "cancelled: T3 delegated task cancelled (clientRequestId=\($r.clientRequestId))"
    elif $r.phase == "interrupted" then
      "blocked: T3 delegated task interrupted; reconcile before retry (clientRequestId=\($r.clientRequestId))"
    elif $r.phase == "dispatch_uncertain" then
      "blocked: T3 dispatch uncertain for \($r.clientRequestId); reconcile with task_status before re-delegating"
    elif $r.phase == "working" or $r.phase == "dispatch_accepted" then
      "paused: waiting on T3 delegated task (clientRequestId=\($r.clientRequestId) t3TaskId=\($r.t3TaskId))"
    else empty end
  ' <<<"$rec"
}

fm_t3_delegation_publish_supervision() { # <task-id> <record-json>
  local task=$1 rec=$2 line status_file state
  fm_t3_delegation_home_state
  state=$FM_T3_STATE
  status_file="$state/${task}.status"
  [ -f "$status_file" ] || return 0
  line=$(fm_t3_delegation_status_line_for_record "$rec") || return 0
  [ -n "$line" ] || return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_T3_DELEGATION_LIB_DIR/fm-wake-lib.sh"
  _fm_wake_require_classify || return 1
  if status_event_recorded "$status_file" "$line"; then
    return 0
  fi
  local append_rc=0
  fm_wake_status_append_self_announced "$state" "$status_file" "$line" || append_rc=$?
  case "$append_rc" in
    0 | 1) ;;
    *) return 1 ;;
  esac
  fm_wake_append signal "$task" "t3-delegation import" || true
}

fm_t3_delegation_set_isolated_worktree() { # <clientRequestId> <path>
  local id=$1 wt=$2 path now
  path=$(fm_t3_delegation_record_path "$id")
  [ -f "$path" ] || return 1
  now=$(fm_t3_delegation_now)
  out=$(jq --arg wt "$wt" --argjson now "$now" \
    '.isolatedWorktree = $wt | .updatedAt = $now' "$path")
  fm_t3_delegation_atomic_write "$path" "$out"
  printf '%s' "$out"
}
