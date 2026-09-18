#!/usr/bin/env bash
# Manage repository-local Project Implementation Decisions (PIDs).
#
# Usage:
#   fm-product-decision.sh create --input <json-file>
#   fm-product-decision.sh list
#   fm-product-decision.sh show <pid-n>
#   fm-product-decision.sh answer <pid-n> --answer-file <file> [--release|--done]
#   fm-product-decision.sh retry <pid-n>
#   fm-product-decision.sh route-answer <owner/task|project/pid-n> --answer-file <file> [--release|--done]
#   fm-product-decision.sh route-reconcile <owner/task|project/pid-n> --source-id <id> --source <provenance>
#   fm-product-decision.sh retry-routes
#   fm-product-decision.sh accept-task-answer <task-id> [--release|--done] (stdin from fm-on)
#   fm-product-decision.sh accept-pid-answer <pid-n> [--release|--done] (stdin from fm-on)
#   fm-product-decision.sh accept-task-reconcile <task-id> --source-id <id> --source <provenance>
#   fm-product-decision.sh accept-pid-reconcile <pid-n> --source-id <id> --source <provenance>
#
# A create input is an fm-product-decision-input.v1 object with project,
# decision_type="product", request_key, optional supersedes, originating_task, question, context, user_impact, options,
# recommendation, rationale, consequences, and affected fields. Each option
# has a sequential letter label, title, non-empty pros and cons arrays, and
# neutral consequences. The script owns timestamps, repository identity,
# owner identity, status, supersession history, and resolution.
#
# Records live in the repository authority home, one JSON file per PID.
# The authority lock protects only ID allocation and its tiny recovery journal.
# Captain answers always pass through fm-captain-hold.sh in the task-owning home.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-repo-concurrency-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-repo-concurrency-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

fail() { printf 'fm-product-decision: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else sha256sum | awk '{print $1}'; fi
}
atomic_json() {  # <path> <json>
  local path=$1 json=$2 dir tmp
  dir=$(dirname "$path")
  mkdir -p "$dir" || return 1
  [ ! -L "$dir" ] && [ ! -L "$path" ] || return 1
  tmp=$(mktemp "$dir/.pid-write.XXXXXX") || return 1
  if ! printf '%s\n' "$json" > "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
}
PID_LOCK=
PID_LOCK_HELD=0
CREATE_SUPERSEDE_LOCK=
release_pid_lock() {
  [ "$PID_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$PID_LOCK" || return 1
  PID_LOCK_HELD=0
}
acquire_pid_lock() {  # <pid-number>
  PID_LOCK="$RECORDS_DIR/.pid-$1.lock"
  fm_lock_acquire_wait "$PID_LOCK" || fail "PID-$1 is being updated; retry after the current transition"
  PID_LOCK_HELD=1
  trap 'release_pid_lock || true' EXIT HUP INT TERM
}
release_create_locks() {
  local rc=0
  if [ -n "$CREATE_SUPERSEDE_LOCK" ]; then
    fm_lock_release "$CREATE_SUPERSEDE_LOCK" || rc=1
    CREATE_SUPERSEDE_LOCK=
  fi
  fm_repo_scope_lock_release || rc=1
  return "$rc"
}
lock_superseded_pid() {  # <pid-key>
  local key=$1 number
  number=$(pid_number "$key") || fail "invalid superseded PID: $key"
  CREATE_SUPERSEDE_LOCK="$RECORDS_DIR/.pid-$number.lock"
  fm_lock_acquire_wait "$CREATE_SUPERSEDE_LOCK" \
    || fail "cannot lock superseded PID $key for amendment"
}
record_path() { printf '%s/pid-%s.json\n' "$RECORDS_DIR" "$1"; }
pid_number() {
  [[ "$1" =~ ^pid-([1-9][0-9]*)$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

resolve_authority() {
  local rc
  if fm_repo_scope_authority_for_home "$FM_HOME"; then
    AUTHORITY_HOME=$FM_REPO_SCOPE_HOME
    PROJECT_NAME=$FM_REPO_SCOPE_PROJECT
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      fail 'this home is not a project repository authority or its local child secondmate'
    fi
    fail "cannot resolve repository authority: ${FM_REPO_SCOPE_LAST_ERROR:-invalid authority}"
  fi
  RECORDS_DIR="$AUTHORITY_HOME/data/product-decisions"
  AUTHORITY_DATA="$AUTHORITY_HOME/data"
  AUTHORITY_STATE="$AUTHORITY_HOME/state"
}

validate_input() {  # <input-json>
  local input=$1
  [ -f "$input" ] && [ ! -L "$input" ] || fail "input must be a regular non-symlinked file: $input"
  [ "$(wc -c < "$input" | tr -d ' ')" -le 65536 ] || fail 'input exceeds 65536 bytes'
  jq -e --arg project "$PROJECT_NAME" '
    . as $x
    | ($x.schema == "fm-product-decision-input.v1")
    and ($x.decision_type == "product")
    and ($x.project == $project)
    and ($x.request_key | type == "string" and length > 0 and length <= 300)
    and (($x.supersedes // null) == null or ($x.supersedes | type == "string" and test("^pid-[1-9][0-9]*$")))
    and ($x.originating_task | type == "string" and test("^[A-Za-z0-9._-]+$"))
    and ($x.question | type == "string" and length > 0 and length <= 1200)
    and ($x.context | type == "string" and length > 0 and length <= 3000)
    and ($x.user_impact | type == "string" and length > 0 and length <= 1200)
    and ($x.options | type == "array" and length >= 2 and length <= 8)
    and (($x.options | map(.label)) == (["A","B","C","D","E","F","G","H"][:($x.options | length)]))
    and all($x.options[]; (.title | type == "string" and length > 0 and length <= 600)
      and (.pros | type == "array" and length > 0 and length <= 8
        and all(.[]; type == "string" and length > 0 and length <= 1000))
      and (.cons | type == "array" and length > 0 and length <= 8
        and all(.[]; type == "string" and length > 0 and length <= 1000))
      and (.consequences | type == "string" and length > 0 and length <= 1200))
    and ($x.recommendation | type == "string" and length > 0 and length <= 1200)
    and (($x.answer_mode // "release") == "release" or ($x.answer_mode // "release") == "done")
    and ($x.recommended_option | type == "string" and test("^[A-H]$"))
    and any($x.options[]; .label == $x.recommended_option)
    and ($x.rationale | type == "string" and length > 0 and length <= 2000)
    and ($x.consequences | type == "string" and length > 0 and length <= 2000)
    and ($x.affected | type == "object")
    and all([$x.affected.requirements, $x.affected.docs, $x.affected.tasks][];
      type == "array" and length <= 64
      and all(.[]; type == "string" and length > 0 and length <= 500))
  ' "$input" >/dev/null 2>&1 || fail 'input does not meet the product-decision presentation contract'
}

finalize_supersession() {  # <new-record-file>
  local new_file=$1 old_key old_number old_file new_key old_status old_record now
  old_key=$(jq -r '.supersedes // empty' "$new_file")
  [ -n "$old_key" ] || return 0
  old_number=$(pid_number "$old_key") || fail "invalid superseded PID: $old_key"
  old_file=$(record_path "$old_number")
  [ -f "$old_file" ] && [ ! -L "$old_file" ] || fail "superseded PID does not exist: $old_key"
  new_key=$(jq -r '.key' "$new_file")
  old_status=$(jq -r '.status' "$old_file")
  if [ "$old_status" = superseded ] \
    && [ "$(jq -r '.superseded_by // empty' "$old_file")" = "$new_key" ]; then
    return 0
  fi
  [ "$old_status" = open ] \
    && [ "$(jq -r '.project' "$old_file")" = "$(jq -r '.project' "$new_file")" ] \
    && [ "$(jq -r '.originating_task' "$old_file")" = "$(jq -r '.originating_task' "$new_file")" ] \
    && [ "$(jq -r '.owner_id' "$old_file")" = "$(jq -r '.owner_id' "$new_file")" ] \
    || fail "superseded PID must be open and owned by the same task: $old_key"
  now=$(now_utc)
  old_record=$(jq --arg successor "$new_key" --arg now "$now" '
    .status="superseded" | .superseded_by=$successor
    | .amendment_history=((.amendment_history // []) + [{kind:"superseded",successor:$successor,recorded_at:$now}])
    | .updated_at=$now
  ' "$old_file")
  atomic_json "$old_file" "$old_record" || fail "cannot persist supersession history for $old_key"
}

owner_identity() {
  local marker="$FM_HOME/.fm-secondmate-home" id rc=0
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    id=$(fm_parent_channel_home_id "$FM_HOME") || rc=$?
    [ "$rc" -eq 0 ] || fail 'the originating secondmate identity is invalid'
    OWNER_ID=$id
  else
    OWNER_ID='project-firstmate'
  fi
}

held_lifecycle() {  # <task>
  local task=$1 life
  life=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --identity 2>/dev/null) \
    || fail "originating task is not currently held for the captain in this home: $task"
  [ -n "$life" ] || fail "originating task has no captain-hold lifecycle identity: $task"
  printf '%s\n' "$life"
}

max_allocated_id() {
  local file n max=0
  for file in "$RECORDS_DIR"/pid-*.json "$RECORDS_DIR"/.create-*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    n=$(jq -r '.id // empty' "$file" 2>/dev/null || true)
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -le "$max" ] || max=$n
  done
  printf '%s\n' "$max"
}

command_create() {
  local input='' request_key req_hash digest tx_file candidate existing existing_digest id n highwater allocator_last tx_json record life supersedes old_file old_number old_status
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --input) [ "$#" -ge 2 ] || usage; input=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$input" ] || usage
  validate_input "$input"
  request_key=$(jq -r '.request_key' "$input")
  digest=$(jq -cS 'del(.request_key)' "$input" | sha256)
  req_hash=$(printf '%s' "$request_key" | sha256)
  tx_file="$RECORDS_DIR/.create-$req_hash.json"
  mkdir -p "$RECORDS_DIR" || fail 'cannot create repository decision directory'
  [ ! -L "$RECORDS_DIR" ] || fail 'repository decision directory is a symlink'

  fm_repo_scope_lock_acquire "$AUTHORITY_HOME" || fail "repository allocator lock unavailable: $FM_REPO_SCOPE_LAST_ERROR"
  trap 'release_create_locks || true' EXIT HUP INT TERM

  for existing in "$RECORDS_DIR"/pid-*.json; do
    [ -f "$existing" ] && [ ! -L "$existing" ] || continue
    if [ "$(jq -r '.request_key // empty' "$existing" 2>/dev/null || true)" = "$request_key" ]; then
      existing_digest=$(jq -r '.request_digest // empty' "$existing")
      [ "$existing_digest" = "$digest" ] || fail 'request_key already exists with different decision content'
      id=$(jq -r '.id' "$existing")
      supersedes=$(jq -r '.supersedes // empty' "$existing")
      [ -z "$supersedes" ] || lock_superseded_pid "$supersedes"
      finalize_supersession "$existing"
      rm -f "$tx_file"
      release_create_locks
      trap - EXIT HUP INT TERM
      printf 'PID-%s\n' "$id"
      return 0
    fi
  done

  life=$(held_lifecycle "$(jq -r '.originating_task' "$input")")
  owner_identity
  supersedes=$(jq -r '.supersedes // empty' "$input")
  if [ -n "$supersedes" ]; then
    old_number=$(pid_number "$supersedes") || fail "invalid superseded PID: $supersedes"
    lock_superseded_pid "$supersedes"
    old_file=$(record_path "$old_number")
    [ -f "$old_file" ] && [ ! -L "$old_file" ] || fail "superseded PID does not exist: $supersedes"
    old_status=$(jq -r '.status' "$old_file")
    [ "$old_status" = open ] \
      && [ "$(jq -r '.project' "$old_file")" = "$PROJECT_NAME" ] \
      && [ "$(jq -r '.originating_task' "$old_file")" = "$(jq -r '.originating_task' "$input")" ] \
      && [ "$(jq -r '.owner_id' "$old_file")" = "$OWNER_ID" ] \
      || fail "superseded PID must be open and owned by this task: $supersedes"
  fi

  if [ -f "$tx_file" ]; then
    [ ! -L "$tx_file" ] || fail 'create recovery record is a symlink'
    [ "$(jq -r '.request_digest // empty' "$tx_file")" = "$digest" ] \
      || fail 'request_key has an unfinished create with different decision content'
    id=$(jq -r '.id // empty' "$tx_file")
  else
    id=
  fi
  if [ -z "$id" ]; then
    highwater=0
    if [ -f "$RECORDS_DIR/.allocator.json" ]; then
      [ ! -L "$RECORDS_DIR/.allocator.json" ] || fail 'allocator record is a symlink'
      highwater=$(jq -r '.last_id // 0' "$RECORDS_DIR/.allocator.json")
      case "$highwater" in ''|*[!0-9]*) fail 'allocator record is corrupt' ;; esac
    fi
    n=$(max_allocated_id)
    [ "$highwater" -ge "$n" ] && n=$highwater
    id=$((n + 1))
    tx_json=$(jq -n --arg request_key "$request_key" --arg request_digest "$digest" --argjson id "$id" --arg created "$(now_utc)" \
      --arg supersedes "$supersedes" \
      '{schema:"fm-product-decision-create-txn.v1",request_key:$request_key,request_digest:$request_digest,id:$id,created_at:$created,supersedes:(if $supersedes == "" then null else $supersedes end)}')
    atomic_json "$tx_file" "$tx_json" || fail 'cannot persist decision create recovery record'
    atomic_json "$RECORDS_DIR/.allocator.json" "$(jq -n --argjson last_id "$id" --arg updated "$(now_utc)" '{schema:"fm-product-decision-allocator.v1",last_id:$last_id,updated_at:$updated}')" \
      || fail 'cannot persist allocated decision number'
  fi

  allocator_last=0
  if [ -f "$RECORDS_DIR/.allocator.json" ]; then
    [ ! -L "$RECORDS_DIR/.allocator.json" ] || fail 'allocator record is a symlink'
    allocator_last=$(jq -r '.last_id // 0' "$RECORDS_DIR/.allocator.json")
    case "$allocator_last" in ''|*[!0-9]*) fail 'allocator record is corrupt' ;; esac
  fi
  if [ "$id" -gt "$allocator_last" ]; then
    atomic_json "$RECORDS_DIR/.allocator.json" "$(jq -n --argjson last_id "$id" --arg updated "$(now_utc)" '{schema:"fm-product-decision-allocator.v1",last_id:$last_id,updated_at:$updated}')" \
      || fail 'cannot reconcile the reserved decision number with its allocator'
  fi

  candidate=$(jq --argjson id "$id" --arg request_digest "$digest" --arg owner "$OWNER_ID" --arg supersedes "$supersedes" \
    --arg origin_lifecycle "$life" --arg created "$(now_utc)" '
      . as $input | {
        schema:"fm-product-decision.v1", id:$id, key:("pid-" + ($id|tostring)),
        project:$input.project, decision_type:$input.decision_type, status:"open", request_key:$input.request_key,
        request_digest:$request_digest, question:$input.question, context:$input.context,
        user_impact:$input.user_impact, options:$input.options,
        recommendation:$input.recommendation, recommended_option:$input.recommended_option,
        rationale:$input.rationale, consequences:$input.consequences,
        originating_task:$input.originating_task, originating_lifecycle:$origin_lifecycle,
        owner_id:$owner, answer_mode:($input.answer_mode // "release"), affected:$input.affected,
        created_at:$created, updated_at:$created,
        amendment_history:(if $supersedes == "" then [] else [{kind:"supersedes",decision:$supersedes,recorded_at:$created}] end),
        supersedes:(if $supersedes == "" then null else $supersedes end),
        resolution:null, docs_sync:{status:(if ($input.affected.docs|length)>0 then "pending" else "not-required" end),task_id:null},
        publication:{status:"pending"}
      }' "$input")
  record=$(record_path "$id")
  if [ -f "$record" ]; then
    [ "$(jq -r '.request_digest // empty' "$record")" = "$digest" ] || fail "allocated PID pid-$id already contains different content"
  else
    atomic_json "$record" "$candidate" || fail "cannot publish PID record pid-$id"
  fi
  finalize_supersession "$record"
  rm -f "$tx_file"
  release_create_locks
  trap - EXIT HUP INT TERM
  printf 'PID-%s\n' "$id"
}

command_list() {
  local file count=0
  if [ ! -d "$RECORDS_DIR" ]; then printf 'No project implementation decisions.\n'; return; fi
  for file in "$RECORDS_DIR"/pid-*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    jq -r '"PID-\(.id) [\(.status)] \(.question)"' "$file" || fail "invalid decision record: $file"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || printf 'No project implementation decisions.\n'
}

command_summary() {
  local limit=${FM_PRODUCT_DECISION_SUMMARY_LIMIT:-8} files=() file
  case "$limit" in ''|*[!0-9]*) fail 'summary limit must be a non-negative integer' ;; esac
  [ -d "$RECORDS_DIR" ] || { printf '{"open":[],"total":0,"omitted":0}\n'; return; }
  for file in "$RECORDS_DIR"/pid-*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    [ "$(jq -r '.status // "corrupt"' "$file" 2>/dev/null || true)" = open ] && files+=("$file")
  done
  if [ "${#files[@]}" -eq 0 ]; then printf '{"open":[],"total":0,"omitted":0}\n'; return; fi
  jq -s --argjson limit "$limit" '
    def trunc($n): tostring | gsub("\\s+"; " ") | if length > $n then .[:$n] + "…" else . end;
    map(select(.schema == "fm-product-decision.v1" and .status == "open"))
    | sort_by(.id) as $all
    | {
        open:([$all[] | {
          id, key:(.project + "/" + .key), repo:.project, project:.project,
          question:(.question | trunc(500)), context:(.context | trunc(700)),
          user_impact:(.user_impact | trunc(500)),
          options:(.options | map({label,title:(.title|trunc(300)),
            pros:(.pros[:3] | map(trunc(250))),cons:(.cons[:3] | map(trunc(250))),
            consequences:(.consequences|trunc(500))})),
          recommendation:(.recommendation|trunc(500)),recommended_option,
          rationale:(.rationale|trunc(700)),owner_id,originating_task
        }][:$limit]),
        total:($all|length),omitted:((($all|length)-$limit)|if . < 0 then 0 else . end)
      }
  ' "${files[@]}"
}

command_show() {
  local n=$1 file
  n=$(pid_number "$n") || fail 'decision id must look like pid-1'
  file=$(record_path "$n")
  [ -f "$file" ] && [ ! -L "$file" ] || fail "decision does not exist: pid-$n"
  jq . "$file"
}

apply_hold_answer() {  # <record-file>
  local file=$1 n owner task answer_file mode doc_id body line rc=0 route route_id route_file routes_dir remote_delivered=0
  n=$(jq -r '.id' "$file")
  owner=$(jq -r '.owner_id' "$file")
  task=$(jq -r '.originating_task' "$file")
  answer_file=$(mktemp "$RECORDS_DIR/.answer.XXXXXX") || fail 'cannot stage captain answer'
  jq -j '.resolution.answer_verbatim' "$file" > "$answer_file"
  mode=$(jq -r '.resolution.mode' "$file")
  local owner_home=$FM_HOME
  if [ "$owner" != project-firstmate ]; then
    local reg="$AUTHORITY_DATA/secondmates.md" line matches=0
    [ -f "$reg" ] && [ ! -L "$reg" ] || { rm -f "$answer_file"; fail 'owner registry is missing'; }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "- $owner"|"- $owner "*) secondmate_registry_parse_line "$line" || continue; matches=$((matches + 1)); owner_home=$SECONDMATE_REGISTRY_HOME ;; esac
    done < "$reg"
    [ "$matches" -eq 1 ] || { rm -f "$answer_file"; fail "owner $owner is not uniquely registered in the repository authority"; }
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      route="$owner/$task"
      routes_dir="$AUTHORITY_STATE/product-decision-routes"
      mkdir -p "$routes_dir" || { rm -f "$answer_file"; fail 'cannot create durable remote-owner answer routes'; }
      [ ! -L "$routes_dir" ] || { rm -f "$answer_file"; fail 'remote-owner answer route directory is a symlink'; }
      route_id=$(printf '%s\n%s\n%s' "$route" "$(sha256 < "$answer_file")" "$mode" | sha256)
      route_file="$routes_dir/$route_id.json"
      route_request_record "$route_file" "$route" "$answer_file" "$mode"
      if ! deliver_route_record "$route_file"; then
        rm -f "$answer_file"
        return 1
      fi
      rm -f "$answer_file"
      if [ "$(jq -r '.status' "$route_file")" != delivered ]; then
        printf 'Captain answer is durably recorded; delivery to %s remains queued for retry.\n' "$route"
        return 0
      fi
      remote_delivered=1
    fi
  fi
  if [ "$remote_delivered" -eq 0 ]; then
    # Exact retries remain safe through the owner's guarded answer command.
    if [ "$mode" = release ]; then
      FM_HOME="$owner_home" FM_DATA_OVERRIDE="$owner_home/data" FM_STATE_OVERRIDE="$owner_home/state" \
        "$SCRIPT_DIR/fm-captain-hold.sh" answer "$task" --decision-file "$answer_file" --release >/dev/null
    else
      FM_HOME="$owner_home" FM_DATA_OVERRIDE="$owner_home/data" FM_STATE_OVERRIDE="$owner_home/state" \
        "$SCRIPT_DIR/fm-captain-hold.sh" answer "$task" --decision-file "$answer_file" >/dev/null
    fi
    rm -f "$answer_file"
  fi
  doc_id=$(jq -r '.docs_sync.task_id // empty' "$file")
  if [ "$(jq -r '.docs_sync.status' "$file")" = pending ]; then
    if [ "$(jq -r '.affected.docs | length' "$file")" -gt 0 ]; then
      doc_id="pid-docs-$n"
      if FM_HOME="$AUTHORITY_HOME" FM_DATA_OVERRIDE="$AUTHORITY_DATA" FM_STATE_OVERRIDE="$AUTHORITY_STATE" \
        "$SCRIPT_DIR/fm-tasks-axi.sh" show "$doc_id" --json >/dev/null 2>&1; then
        :
      else
        body=$(jq -r '"Decision: PID-\(.id)\n\n\(.question)\n\nCaptain answer: \(.resolution.answer_verbatim)\n\nImplementation consequences: \(.resolution.consequences)\n\nRequirements: \(.affected.requirements|join(", "))\n\nDocumentation to sync:\n" + (.affected.docs|map("- " + .)|join("\n")) + "\n\nRelated tasks: " + (.affected.tasks|join(", "))' "$file")
        printf '%s' "$body" > "$RECORDS_DIR/.docs-body-$n"
        FM_HOME="$AUTHORITY_HOME" FM_DATA_OVERRIDE="$AUTHORITY_DATA" FM_STATE_OVERRIDE="$AUTHORITY_STATE" \
          "$SCRIPT_DIR/fm-tasks-axi.sh" add "$doc_id" "Sync requirements documentation for PID-$n" \
          --kind docs --repo "$(jq -r '.project' "$file")" --body-file "$RECORDS_DIR/.docs-body-$n" >/dev/null
        rm -f "$RECORDS_DIR/.docs-body-$n"
      fi
      record=$(jq --arg task_id "$doc_id" --arg now "$(now_utc)" '.docs_sync={status:"queued",task_id:$task_id,updated_at:$now} | .updated_at=$now' "$file")
      atomic_json "$file" "$record" || fail 'answer was recorded but documentation-sync status could not be updated'
    else
      record=$(jq --arg now "$(now_utc)" '.docs_sync={status:"not-required",task_id:null,updated_at:$now} | .updated_at=$now' "$file")
      atomic_json "$file" "$record" || fail 'answer was recorded but decision status could not be updated'
    fi
  fi
  record=$(jq --arg now "$(now_utc)" '.status="resolved" | .updated_at=$now' "$file")
  atomic_json "$file" "$record" || fail 'captain answer is durable but PID final status could not be updated'
  line="resolved [key=pid-$n-answer]: PID-$(jq -r '.id' "$file") for $(jq -r '.project' "$file") recorded; documentation sync $(jq -r '.docs_sync.status' "$file")$(if [ -n "$doc_id" ]; then printf ' as %s' "$doc_id"; fi)"
  fm_parent_channel_report_project_decision "$AUTHORITY_HOME" "$AUTHORITY_STATE" "$line" || rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || [ "$rc" -eq 5 ]; then
    record=$(jq --arg now "$(now_utc)" '.publication={status:"published",updated_at:$now} | .updated_at=$now' "$file")
    atomic_json "$file" "$record" || fail 'answer was recorded but publication status could not be stored'
  else
    printf 'actionable: PID-%s answer is recorded; parent summary publication remains pending (rc=%s)\n' "$n" "$rc" >&2
    return 1
  fi
  printf 'PID-%s resolved; documentation sync %s%s.\n' "$n" "$(jq -r '.docs_sync.status' "$file")" "${doc_id:+ ($doc_id)}"
}

command_answer() {
  local raw=$1 answer_file='' requested_mode=record n file existing digest mode reason record timestamp
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --answer-file) [ "$#" -ge 2 ] || usage; answer_file=$2; shift 2 ;;
      --release) requested_mode=release; shift ;;
      --done) requested_mode='done'; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$answer_file" ] && [ -f "$answer_file" ] && [ ! -L "$answer_file" ] || fail 'answer-file must name a regular file'
  [ "$(wc -c < "$answer_file" | tr -d ' ')" -le 8192 ] || fail 'captain answer exceeds 8192 bytes'
  [ -s "$answer_file" ] || fail 'captain answer must not be empty'
  n=$(pid_number "$raw") || fail 'decision id must look like pid-1'
  file=$(record_path "$n")
  [ -f "$file" ] && [ ! -L "$file" ] || fail "decision does not exist: pid-$n"
  acquire_pid_lock "$n"
  reason=$(jq -r '.status' "$file")
  digest=$(sha256 < "$answer_file")
  mode=$(jq -r '.answer_mode // "release"' "$file")
  [ "$requested_mode" = record ] || mode=$requested_mode
  if [ "$reason" = resolved ]; then
    existing=$(jq -r '.resolution.answer_digest // empty' "$file")
    [ "$existing" = "$digest" ] || fail 'PID is already resolved with a different answer'
    [ "$(jq -r '.resolution.mode' "$file")" = "$mode" ] || fail 'PID is already resolved with a different close mode'
  elif [ "$reason" = answer-pending ]; then
    existing=$(jq -r '.resolution.answer_digest // empty' "$file")
    [ "$existing" = "$digest" ] || fail 'a different answer transition is already pending'
    [ "$(jq -r '.resolution.mode' "$file")" = "$mode" ] || fail 'a different close mode is already pending'
  elif [ "$reason" = open ]; then
    timestamp=$(now_utc)
    record=$(jq --rawfile answer "$answer_file" --arg digest "$digest" --arg mode "$mode" --arg timestamp "$timestamp" --arg consequences "$(jq -r '.consequences' "$file")" \
      '.status="answer-pending" | .resolution={answer_verbatim:$answer,answer_digest:$digest,mode:$mode,consequences:$consequences,answered_at:$timestamp} | .updated_at=$timestamp' "$file")
    atomic_json "$file" "$record" || fail 'cannot persist captain answer recovery record'
  else
    fail "cannot answer PID in status $reason"
  fi
  apply_hold_answer "$file"
  if [ "$(jq -r '.status' "$file")" = answer-pending ]; then
    release_pid_lock
    trap - EXIT HUP INT TERM
    printf 'PID-%s answer is recorded; delivery to its task owner remains durably queued.\n' "$n"
    return 10
  fi
  release_pid_lock
  trap - EXIT HUP INT TERM
}

command_retry() {
  local raw=$1 n file status
  n=$(pid_number "$raw") || fail 'decision id must look like pid-1'
  file=$(record_path "$n")
  [ -f "$file" ] && [ ! -L "$file" ] || fail "decision does not exist: pid-$n"
  acquire_pid_lock "$n"
  status=$(jq -r '.status' "$file")
  case "$status" in answer-pending|resolved) ;; *) fail "nothing recoverable is pending for PID-$n" ;; esac
  apply_hold_answer "$file"
  if [ "$(jq -r '.status' "$file")" = answer-pending ]; then
    release_pid_lock
    trap - EXIT HUP INT TERM
    printf 'PID-%s answer is recorded; delivery to its task owner remains durably queued.\n' "$n"
    return 10
  fi
  release_pid_lock
  trap - EXIT HUP INT TERM
}

resolve_owner_route() {  # <owner-id> <kind> <pid-or-task>
  local owner=$1 kind=$2 target=$3 registry=${4:-$DATA/secondmates.md} line matches=0
  ROUTE_HOME=$FM_HOME
  ROUTE_REMOTE=0
  if [ "$kind" = task ] && [ "$owner" = main ]; then return 0; fi
  [ -f "$registry" ] && [ ! -L "$registry" ] || fail "owner registry is unavailable: $registry"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- $owner"|"- $owner "*)
      secondmate_registry_parse_line "$line" || fail "owner registry entry is malformed: $owner"
      matches=$((matches + 1))
      ROUTE_HOME=$SECONDMATE_REGISTRY_HOME
      ROUTE_REMOTE=$SECONDMATE_REGISTRY_REMOTE
      ;;
    esac
  done < "$registry"
  [ "$matches" -eq 1 ] || fail "owner $owner is not uniquely registered in this home's route table"
}

resolve_pid_route() {  # <project> <pid>
  local project=$1 pid=$2 home_line home_project matches=0
  ROUTE_HOME=
  ROUTE_REMOTE=0
  if fm_repo_scope_authority_for_home "$FM_HOME" && [ "$FM_REPO_SCOPE_PROJECT" = "$project" ]; then
    if [ -f "$FM_REPO_SCOPE_HOME/data/product-decisions/$pid.json" ]; then
      ROUTE_HOME=$FM_REPO_SCOPE_HOME
      return 0
    fi
  fi
  [ -f "$DATA/secondmates.md" ] && [ ! -L "$DATA/secondmates.md" ] \
    || fail "project Firstmate registry is unavailable: $DATA/secondmates.md"
  while IFS= read -r home_line || [ -n "$home_line" ]; do
    case "$home_line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$home_line" || fail 'secondmate registry contains a malformed route'
    home_project=" $SECONDMATE_REGISTRY_PROJECTS "
    case "$home_project" in *" $project "*) ;; *) continue ;; esac
    [ -f "$SECONDMATE_REGISTRY_HOME/.fm-project-firstmate" ] || continue
    matches=$((matches + 1))
    ROUTE_HOME=$SECONDMATE_REGISTRY_HOME
    ROUTE_REMOTE=$SECONDMATE_REGISTRY_REMOTE
    ROUTE_OWNER=$SECONDMATE_REGISTRY_ID
  done < "$DATA/secondmates.md"
  [ "$matches" -eq 1 ] || fail "project $project does not resolve to exactly one registered project Firstmate"
}

route_request_record() {  # <journal-path> <route-key> <answer-file> <mode>
  local path=$1 key=$2 answer_file=$3 mode=$4 digest record id
  digest=$(sha256 < "$answer_file")
  id=$(printf '%s\n%s\n%s' "$key" "$digest" "$mode" | sha256)
  record=$(jq -n --arg id "$id" --arg route "$key" --rawfile answer "$answer_file" \
    --arg digest "$digest" --arg mode "$mode" --arg created "$(now_utc)" \
    '{schema:"fm-owner-answer-route.v1",id:$id,action:"answer",route:$route,answer_verbatim:$answer,
      answer_digest:$digest,mode:$mode,status:"pending",created_at:$created,updated_at:$created,
      attempts:0,last_error:null}')
  if [ -f "$path" ]; then
    [ ! -L "$path" ] || fail 'owner answer route journal is a symlink'
    [ "$(jq -r '.answer_digest' "$path")" = "$digest" ] \
      && [ "$(jq -r '.route' "$path")" = "$key" ] \
      && [ "$(jq -r '.mode' "$path")" = "$mode" ] \
      || fail 'a different answer is already journaled for this route request'
  else
    atomic_json "$path" "$record" || fail 'cannot persist durable owner answer route'
  fi
}

deliver_reconcile_to_task() {  # <owner-id> <owner-home> <remote-0-or-1> <task> <source-id> <provenance>
  local owner=$1 owner_home=$2 remote=$3 task=$4 source_id=$5 provenance=$6 rc=0 output
  if [ "$remote" -eq 1 ]; then
    output=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-on.sh" --stdin "$owner" \
      fm-product-decision.sh accept-task-reconcile "$task" --source-id "$source_id" --source "$provenance" \
      < /dev/null 2>&1) || rc=$?
  else
    FM_HOME="$owner_home" FM_DATA_OVERRIDE="$owner_home/data" FM_STATE_OVERRIDE="$owner_home/state" \
      "$SCRIPT_DIR/fm-captain-hold.sh" bind "$source_id" >/dev/null \
      || return 1
    output=$(printf '%s\n' "$task" \
      | FM_HOME="$owner_home" FM_DATA_OVERRIDE="$owner_home/data" FM_STATE_OVERRIDE="$owner_home/state" \
          "$SCRIPT_DIR/fm-captain-hold.sh" reconcile-requests \
          --source-id "$source_id" --source "$provenance" 2>&1) || rc=$?
  fi
  [ "$rc" -eq 0 ] || { printf '%s\n' "$output" >&2; return "$rc"; }
}

deliver_reconcile_record() {  # <journal-file>
  local path=$1 route source_id provenance target project owner owner_home remote rc=0 output pid_file
  route=$(jq -r '.route' "$path")
  source_id=$(jq -r '.source_id' "$path")
  provenance=$(jq -r '.provenance' "$path")
  if [[ "$route" =~ ^([A-Za-z0-9._-]+)/pid-([1-9][0-9]*)$ ]]; then
    project=${BASH_REMATCH[1]}; target="pid-${BASH_REMATCH[2]}"
    resolve_pid_route "$project" "$target"
    owner=$ROUTE_OWNER
    owner_home=$ROUTE_HOME
    remote=$ROUTE_REMOTE
    if [ "$remote" -eq 1 ]; then
      output=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-on.sh" --stdin "$owner" \
        fm-product-decision.sh accept-pid-reconcile "$target" --source-id "$source_id" --source "$provenance" \
        < /dev/null 2>&1) || rc=$?
    else
      pid_file="$owner_home/data/product-decisions/$target.json"
      [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || return 1
      owner=$(jq -r '.owner_id' "$pid_file")
      target=$(jq -r '.originating_task' "$pid_file")
      if [ "$owner" != project-firstmate ]; then
        resolve_owner_route "$owner" task "$target" "$owner_home/data/secondmates.md"
        owner_home=$ROUTE_HOME
        remote=$ROUTE_REMOTE
      fi
      deliver_reconcile_to_task "$owner" "$owner_home" "$remote" "$target" "$source_id" "$provenance" || rc=$?
    fi
  elif [[ "$route" =~ ^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$ ]]; then
    owner=${BASH_REMATCH[1]}; target=${BASH_REMATCH[2]}
    resolve_owner_route "$owner" task "$target"
    deliver_reconcile_to_task "$owner" "$ROUTE_HOME" "$ROUTE_REMOTE" "$target" "$source_id" "$provenance" || rc=$?
  else
    return 2
  fi
  return "$rc"
}

deliver_route_record() {  # <journal-file>
  local path=$1 route kind owner target mode answer_file rc=0 output record status note
  local action
  local -a release_args=()
  action=$(jq -r '.action // "answer"' "$path")
  if [ "$action" = reconcile ]; then
    if deliver_reconcile_record "$path"; then
      record=$(jq --arg now "$(now_utc)" '.status="delivered" | .attempts=((.attempts // 0)+1) | .last_error=null | .updated_at=$now' "$path")
      atomic_json "$path" "$record" || fail 'reconcile route outcome could not be persisted'
      printf 'Reconcile request delivered to %s.\n' "$(jq -r '.route' "$path")"
      return 0
    else
      rc=$?
    fi
    if [ "$rc" -eq 255 ]; then
      note='remote delivery is unavailable or completion is unknown; identical retry is safe through the owner-held request intake'
    else
      note="owner reconcile intake refused or failed (rc=$rc)"
    fi
    record=$(jq --arg now "$(now_utc)" --arg error "$note" '.status="pending" | .attempts=((.attempts // 0)+1) | .last_error=$error | .updated_at=$now' "$path")
    atomic_json "$path" "$record" || fail 'reconcile route failure could not be persisted'
    if [ "$rc" -eq 255 ]; then
      printf 'Reconcile request is durably queued for %s; retry with fm-product-decision.sh retry-routes.\n' "$(jq -r '.route' "$path")"
      return 0
    fi
    printf 'actionable: reconcile request remains durably queued for %s\n' "$(jq -r '.route' "$path")" >&2
    return 1
  fi
  route=$(jq -r '.route' "$path")
  mode=$(jq -r '.mode' "$path")
  answer_file=$(mktemp "$(dirname "$path")/.route-answer.XXXXXX") || fail 'cannot stage durable answer'
  jq -j '.answer_verbatim' "$path" > "$answer_file"
  case "$mode" in
    release) release_args=(--release) ;;
    done) release_args=(--done) ;;
    owner-default) ;;
    *) rm -f "$answer_file"; fail "invalid owner answer close mode: $mode" ;;
  esac
  if [[ "$route" =~ ^([A-Za-z0-9._-]+)/pid-([1-9][0-9]*)$ ]]; then
    kind=pid; owner=${BASH_REMATCH[1]}; target="pid-${BASH_REMATCH[2]}"
    resolve_pid_route "$owner" "$target"
    if [ "$ROUTE_REMOTE" -eq 1 ]; then
      output=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-on.sh" --stdin "$ROUTE_OWNER" \
        fm-product-decision.sh accept-pid-answer "$target" ${release_args[@]+"${release_args[@]}"} < "$answer_file" 2>&1) || rc=$?
    else
      output=$(FM_HOME="$ROUTE_HOME" FM_DATA_OVERRIDE="$ROUTE_HOME/data" FM_STATE_OVERRIDE="$ROUTE_HOME/state" \
        FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-product-decision.sh" answer "$target" \
        --answer-file "$answer_file" ${release_args[@]+"${release_args[@]}"} 2>&1) || rc=$?
    fi
  elif [[ "$route" =~ ^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$ ]]; then
    kind=task; owner=${BASH_REMATCH[1]}; target=${BASH_REMATCH[2]}
    resolve_owner_route "$owner" task "$target"
    if [ "$ROUTE_REMOTE" -eq 1 ]; then
      output=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-on.sh" --stdin "$owner" \
        fm-product-decision.sh accept-task-answer "$target" ${release_args[@]+"${release_args[@]}"} < "$answer_file" 2>&1) || rc=$?
    else
      output=$(FM_HOME="$ROUTE_HOME" FM_DATA_OVERRIDE="$ROUTE_HOME/data" FM_STATE_OVERRIDE="$ROUTE_HOME/state" \
        FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-captain-hold.sh" answer "$target" \
        --decision-file "$answer_file" ${release_args[@]+"${release_args[@]}"} 2>&1) || rc=$?
    fi
  elif [[ "$route" =~ ^[A-Za-z0-9._-]+$ ]]; then
    kind=task; owner=main; target=$route
    resolve_owner_route "$owner" task "$target"
    output=$(FM_HOME="$ROUTE_HOME" FM_DATA_OVERRIDE="$ROUTE_HOME/data" FM_STATE_OVERRIDE="$ROUTE_HOME/state" \
      FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-captain-hold.sh" answer "$target" \
      --decision-file "$answer_file" ${release_args[@]+"${release_args[@]}"} 2>&1) || rc=$?
  else
    rm -f "$answer_file"
    fail "unsupported owner-qualified answer key: $route"
  fi
  rm -f "$answer_file"
  status=pending
  note="$output"
  if [ "$rc" -eq 0 ]; then
    status=delivered
    note='answer accepted by the task-owning captain-hold intake'
  elif [ "$rc" -eq 255 ]; then
    note='remote delivery is unavailable or completion is unknown; identical retry is safe through the guarded answer intake'
  fi
  record=$(jq --arg status "$status" --arg now "$(now_utc)" --arg error "$note" \
    '.status=$status | .attempts=((.attempts // 0)+1) | .last_error=(if $status == "delivered" then null else $error end) | .updated_at=$now' "$path")
  atomic_json "$path" "$record" || fail 'owner route outcome could not be persisted'
  if [ "$status" = delivered ]; then
    printf 'Answer delivered to %s.\n' "$route"
    return 0
  fi
  if [ "$rc" -eq 10 ]; then
    record=$(jq --arg now "$(now_utc)" --arg error "$note" \
      '.status="pending" | .attempts=((.attempts // 0)+1) | .last_error=$error | .updated_at=$now' "$path")
    atomic_json "$path" "$record" || fail 'owner answer pending result could not be persisted'
    printf 'Answer is durably queued for %s; retry with fm-product-decision.sh retry-routes.\n' "$route"
    return 0
  fi
  if [ "$rc" -eq 255 ]; then
    printf 'Answer is durably queued for %s; retry with fm-product-decision.sh retry-routes.\n' "$route"
    return 0
  fi
  printf 'actionable: answer remains durably queued for %s: %s\n' "$route" "$note" >&2
  return 1
}

command_route_answer() {
  local route=$1 answer_file='' requested_mode=auto mode path digest id routes_dir
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --answer-file) [ "$#" -ge 2 ] || usage; answer_file=$2; shift 2 ;;
      --release) requested_mode=release; shift ;;
      --done) requested_mode='done'; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$answer_file" ] && [ -f "$answer_file" ] && [ ! -L "$answer_file" ] || fail 'answer-file must name a regular file'
  [ -s "$answer_file" ] || fail 'captain answer must not be empty'
  [ "$(wc -c < "$answer_file" | tr -d ' ')" -le 8192 ] || fail 'captain answer exceeds 8192 bytes'
  if [[ "$route" =~ ^[A-Za-z0-9._-]+/pid-[1-9][0-9]*$ ]]; then
    mode='owner-default'
  else
    mode='done'
  fi
  [ "$requested_mode" = auto ] || mode=$requested_mode
  routes_dir="$STATE/product-decision-routes"
  mkdir -p "$routes_dir" || fail 'cannot create durable owner route directory'
  [ ! -L "$routes_dir" ] || fail 'durable owner route directory is a symlink'
  digest=$(sha256 < "$answer_file")
  id=$(printf '%s\n%s\n%s' "$route" "$digest" "$mode" | sha256)
  path="$routes_dir/$id.json"
  route_request_record "$path" "$route" "$answer_file" "$mode"
  deliver_route_record "$path"
}

command_route_reconcile() {
  local route=$1 source_id='' provenance='' action_id path routes_dir record
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source-id) [ "$#" -ge 2 ] || usage; source_id=$2; shift 2 ;;
      --source) [ "$#" -ge 2 ] || usage; provenance=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$route" =~ ^[A-Za-z0-9._-]+/([A-Za-z0-9._-]+|pid-[1-9][0-9]*)$ ]] \
    || fail "reconcile route must be owner/task or repo/pid-n: $route"
  [ -n "$source_id" ] && [ -n "$provenance" ] || fail 'reconcile route needs source-id and provenance'
  routes_dir="$STATE/product-decision-routes"
  mkdir -p "$routes_dir" || fail 'cannot create durable owner route directory'
  [ ! -L "$routes_dir" ] || fail 'durable owner route directory is a symlink'
  action_id=$(printf '%s\n%s\n%s' reconcile "$route" "$source_id" | sha256)
  path="$routes_dir/$action_id.json"
  if [ -f "$path" ]; then
    [ ! -L "$path" ] || fail 'owner reconcile route journal is a symlink'
    [ "$(jq -r '.route' "$path")" = "$route" ] \
      && [ "$(jq -r '.source_id' "$path")" = "$source_id" ] \
      || fail 'reconcile route identity collides with a different durable request'
  else
    record=$(jq -n --arg id "$action_id" --arg route "$route" --arg source_id "$source_id" \
      --arg provenance "$provenance" --arg now "$(now_utc)" \
      '{schema:"fm-owner-answer-route.v1",id:$id,action:"reconcile",route:$route,
        source_id:$source_id,provenance:$provenance,status:"pending",created_at:$now,
        updated_at:$now,attempts:0,last_error:null}')
    atomic_json "$path" "$record" || fail 'cannot persist durable owner reconcile route'
  fi
  deliver_route_record "$path"
}

command_retry_routes() {
  local dir="$STATE/product-decision-routes" file status pending=0 failed=0 pid_file pid_status pid pid_rc
  [ -d "$dir" ] && [ ! -L "$dir" ] || { printf 'No queued owner answers.\n'; return 0; }
  for file in "$dir"/*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    status=$(jq -r '.status // "invalid"' "$file" 2>/dev/null || true)
    [ "$status" = pending ] || continue
    pending=$((pending + 1))
    if ! deliver_route_record "$file"; then failed=$((failed + 1)); fi
  done
  if fm_repo_scope_authority_for_home "$FM_HOME" && [ -d "$FM_REPO_SCOPE_HOME/data/product-decisions" ]; then
    AUTHORITY_HOME=$FM_REPO_SCOPE_HOME
    PROJECT_NAME=$FM_REPO_SCOPE_PROJECT
    AUTHORITY_DATA="$AUTHORITY_HOME/data"
    AUTHORITY_STATE="$AUTHORITY_HOME/state"
    RECORDS_DIR="$FM_REPO_SCOPE_HOME/data/product-decisions"
    for pid_file in "$RECORDS_DIR"/pid-*.json; do
      [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || continue
      pid_status=$(jq -r '.status // "invalid"' "$pid_file" 2>/dev/null || true)
      [ "$pid_status" = answer-pending ] || continue
      pending=$((pending + 1))
      pid=$(jq -r '.key' "$pid_file")
      if command_retry "$pid"; then
        :
      else
        pid_rc=$?
        [ "$pid_rc" -eq 10 ] || failed=$((failed + 1))
      fi
    done
  fi
  [ "$pending" -gt 0 ] || printf 'No queued owner answers.\n'
  [ "$failed" -eq 0 ]
}

command_accept_task_answer() {  # <task-id> [--release], stdin is exact captain answer
  local task=$1 answer_file
  local -a release_args=()
  shift
  while [ "$#" -gt 0 ]; do case "$1" in --release|--done) release_args=("$1"); shift ;; *) usage ;; esac; done
  answer_file=$(mktemp "$STATE/.owner-answer.XXXXXX") || fail 'cannot stage remotely routed answer'
  cat > "$answer_file"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" answer "$task" --decision-file "$answer_file" ${release_args[@]+"${release_args[@]}"}
  rm -f "$answer_file"
}

command_accept_pid_answer() {  # <pid-n> [--release], stdin is exact captain answer
  local pid=$1 answer_file
  local -a release_args=()
  shift
  while [ "$#" -gt 0 ]; do case "$1" in --release|--done) release_args=("$1"); shift ;; *) usage ;; esac; done
  answer_file=$(mktemp "$STATE/.owner-answer.XXXXXX") || fail 'cannot stage remotely routed answer'
  cat > "$answer_file"
  command_answer "$pid" --answer-file "$answer_file" ${release_args[@]+"${release_args[@]}"}
  rm -f "$answer_file"
}

command_accept_task_reconcile() {  # <task-id> --source-id <id> --source <provenance>
  local task=$1 source_id='' provenance=''
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source-id) [ "$#" -ge 2 ] || usage; source_id=$2; shift 2 ;;
      --source) [ "$#" -ge 2 ] || usage; provenance=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$source_id" ] && [ -n "$provenance" ] || fail 'owner reconcile intake needs source-id and provenance'
  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$source_id" >/dev/null
  printf '%s\n' "$task" | "$SCRIPT_DIR/fm-captain-hold.sh" reconcile-requests \
    --source-id "$source_id" --source "$provenance"
}

command_accept_pid_reconcile() {  # <pid-n> --source-id <id> --source <provenance>
  local raw=$1 source_id='' provenance='' n file owner task owner_home remote=0
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source-id) [ "$#" -ge 2 ] || usage; source_id=$2; shift 2 ;;
      --source) [ "$#" -ge 2 ] || usage; provenance=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$source_id" ] && [ -n "$provenance" ] || fail 'owner reconcile intake needs source-id and provenance'
  n=$(pid_number "$raw") || fail 'decision id must look like pid-1'
  file=$(record_path "$n")
  [ -f "$file" ] && [ ! -L "$file" ] || fail "decision does not exist: pid-$n"
  owner=$(jq -r '.owner_id' "$file")
  task=$(jq -r '.originating_task' "$file")
  owner_home=$AUTHORITY_HOME
  if [ "$owner" != project-firstmate ]; then
    resolve_owner_route "$owner" task "$task"
    owner_home=$ROUTE_HOME
    remote=$ROUTE_REMOTE
  fi
  deliver_reconcile_to_task "$owner" "$owner_home" "$remote" "$task" "$source_id" "$provenance"
}

case "${1:-}" in
  route-answer) shift; [ "$#" -ge 1 ] || usage; command_route_answer "$@"; exit $? ;;
  route-reconcile) shift; [ "$#" -ge 1 ] || usage; command_route_reconcile "$@"; exit $? ;;
  retry-routes) shift; [ "$#" -eq 0 ] || usage; command_retry_routes; exit $? ;;
  accept-task-answer) shift; [ "$#" -ge 1 ] || usage; command_accept_task_answer "$@"; exit $? ;;
  accept-pid-answer) shift; [ "$#" -ge 1 ] || usage; resolve_authority; command_accept_pid_answer "$@"; exit $? ;;
  accept-task-reconcile) shift; [ "$#" -ge 1 ] || usage; command_accept_task_reconcile "$@"; exit $? ;;
  accept-pid-reconcile) shift; [ "$#" -ge 1 ] || usage; resolve_authority; command_accept_pid_reconcile "$@"; exit $? ;;
  create|list|summary|show|answer|retry) resolve_authority ;;
  *) usage ;;
esac
case "${1:-}" in
  create) shift; command_create "$@" ;;
  list) shift; [ "$#" -eq 0 ] || usage; command_list ;;
  summary) shift; [ "$#" -eq 0 ] || usage; command_summary ;;
  show) shift; [ "$#" -eq 1 ] || usage; command_show "$1" ;;
  answer) shift; [ "$#" -ge 1 ] || usage; command_answer "$@" ;;
  retry) shift; [ "$#" -eq 1 ] || usage; command_retry "$1" ;;
  -h|--help|help|"") usage ;;
  *) usage ;;
esac
