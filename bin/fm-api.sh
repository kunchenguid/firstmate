#!/usr/bin/env bash
# fm-api.sh - JSON CLI over Firstmate's existing task and lifecycle owners.
# Usage: fm-api.sh list
#        fm-api.sh status <task-id>
#        fm-api.sh create < request.json
#        fm-api.sh steer <task-id> < request.json
#        fm-api.sh cancel <task-id>
# Create JSON: {"request_id":"...","project":"<registered-name>","title":"...","instruction":"..."}
# Steer JSON: {"message":"...","resolve_keys":["decision-key"]}
# Create is local-only, no-push, and non-deploying. FM_API_PROJECT_ALLOWLIST and
# FM_API_OWNER_ID are trusted caller configuration; ownership/idempotency markers
# live in the existing backlog task body. Status/list use fm-fleet-snapshot;
# steer/cancel call fm-send/fm-control only after ownership checks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MAX_REQUEST_BYTES=65536
MAX_OUTPUT_BYTES=16384
MAX_REPORT_BYTES=12000
API_PROJECTS=()

api_error() {
  local code=$1 message=$2 task_id=${3:-}
  jq -cn --arg code "$code" --arg message "$message" --arg task_id "$task_id" \
    '{error:{code:$code,message:$message},task_id:(if $task_id == "" then null else $task_id end)}'
  exit 1
}

read_request() {
  REQUEST=$(head -c "$((MAX_REQUEST_BYTES + 1))") || api_error invalid_input 'Could not read JSON input.'
  [ -n "$REQUEST" ] || api_error invalid_input 'JSON input is required.'
  [ "$(printf '%s' "$REQUEST" | wc -c | tr -d '[:space:]')" -le "$MAX_REQUEST_BYTES" ] \
    || api_error invalid_input 'JSON input exceeds 65536 bytes.'
  printf '%s' "$REQUEST" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
    || api_error invalid_input 'Input must contain one JSON object.'
}

valid_id() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ] && [ "$1" != . ] && [ "$1" != .. ]
}

api_owner() {
  OWNER=${FM_API_OWNER_ID:-}
  case "$OWNER" in ''|.*|*[!A-Za-z0-9._-]*) api_error owner_required 'A trusted FM_API_OWNER_ID is required.' ;; esac
  [ "${#OWNER}" -le 64 ] || api_error owner_required 'FM_API_OWNER_ID is too long.'
}

api_projects() {
  local item
  API_PROJECTS=()
  IFS=, read -r -a API_PROJECTS <<< "${FM_API_PROJECT_ALLOWLIST:-}"
  [ "${#API_PROJECTS[@]}" -gt 0 ] && [ -n "${API_PROJECTS[0]}" ] \
    || api_error project_allowlist_required 'A trusted FM_API_PROJECT_ALLOWLIST is required.'
  for item in "${API_PROJECTS[@]}"; do
    [[ "$item" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
      || api_error project_allowlist_invalid 'FM_API_PROJECT_ALLOWLIST contains an invalid project name.'
  done
  PROJECTS_JSON=$(printf '%s\n' "${API_PROJECTS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))') \
    || api_error internal_error 'Could not encode the project allowlist.'
}

api_project_allowed() {
  local candidate=$1 item
  for item in "${API_PROJECTS[@]}"; do
    [ "$candidate" = "$item" ] && return 0
  done
  return 1
}

api_emit() {
  local result=$1 bytes
  bytes=$(printf '%s' "$result" | wc -c | tr -d '[:space:]')
  [ "$bytes" -le "$MAX_OUTPUT_BYTES" ] \
    || api_error result_too_large 'JSON result exceeds the 16384-byte output limit.'
  printf '%s\n' "$result"
}

api_record_for_task() {
  local task_id=$1 prefix="<!-- fm-api:v1 owner=$OWNER request=" record_rows task_rows record_count task_count
  record_rows=$(printf '%s\n' "$SNAPSHOT" | jq -ce --arg id "$task_id" \
    '[.backlog.records[]? | select(.structured == true and .id == $id)]' 2>/dev/null) \
    || api_error not_found 'Task is not owned by this Firstmate API session.'
  record_count=$(printf '%s\n' "$record_rows" | jq 'length')
  [ "$record_count" -eq 1 ] \
    || api_error not_found 'Task is not owned by this Firstmate API session.'
  RECORD=$(printf '%s\n' "$record_rows" | jq -c '.[0]')
  printf '%s\n' "$RECORD" | jq -e --arg prefix "$prefix" \
    'any(.body_lines[]?; startswith($prefix))' >/dev/null 2>&1 \
    || api_error not_found 'Task is not owned by this Firstmate API session.'
  PROJECT=$(printf '%s\n' "$RECORD" | jq -r '.repo // empty')
  api_project_allowed "$PROJECT" \
    || api_error not_found 'Task is not owned by this Firstmate API session.'
  task_rows=$(printf '%s\n' "$SNAPSHOT" | jq -ce --arg id "$task_id" \
    '[.tasks[]? | select(.id == $id)]' 2>/dev/null) \
    || api_error snapshot_invalid 'Firstmate returned an invalid task snapshot.' "$task_id"
  task_count=$(printf '%s\n' "$task_rows" | jq 'length')
  [ "$task_count" -le 1 ] \
    || api_error snapshot_invalid 'Firstmate returned duplicate task IDs.' "$task_id"
  TASK=$(printf '%s\n' "$task_rows" | jq -c '.[0] // empty')
  if [ -n "$TASK" ]; then
    [ "$(printf '%s\n' "$TASK" | jq -r '.project // empty')" = "$PROJECT" ] \
      || api_error not_found 'Task is not owned by this Firstmate API session.'
  fi
}

api_snapshot() {
  local project_root
  SNAPSHOT=$(project_snapshot) \
    || api_error snapshot_failed 'Firstmate could not produce a fleet snapshot.'

  # Spawn records use absolute paths; backlog records use registered names.
  project_root=$(CDPATH='' cd -- "$PROJECTS" 2>/dev/null && pwd -P) || return 0
  SNAPSHOT=$(printf '%s\n' "$SNAPSHOT" | jq -ce --arg root "$project_root" --argjson allowed "$PROJECTS_JSON" '
    if (.tasks | type) == "array" then
      .tasks |= map(.project as $path
        | ([$allowed[] | select(($root + "/" + .) == $path)] | first) as $name
        | if $name == null then . else .project = $name end)
    else . end') \
    || api_error snapshot_invalid 'Firstmate returned an invalid task snapshot.'
}

# shellcheck disable=SC2016 # This single-quoted jq program is passed as data, not evaluated by Bash.
json_state_filter='def api_task:
  . as $t
  | {task_id:$t.id,
     state:(if $t.hints.pending_decision then "needs-user"
            elif $t.current_state.state == "done" then "complete"
            else ($t.current_state.state // "unknown") end),
     summary:($t.current_state.detail // null),
     needs_user:($t.hints.pending_decision // false),
     open_decisions:($t.hints.open_decisions // []),
     project:($t.project // null),kind:($t.kind // null),
     endpoint_status:($t.endpoint.status // "unknown")};'

project_snapshot() {
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null
}

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

COMMAND=${1:-}
case "$COMMAND" in
  -h|--help) usage; exit 0 ;;
  list)
    [ "$#" -eq 1 ] || api_error invalid_input 'Usage: fm-api.sh list'
    api_owner
    api_projects
    api_snapshot
    RESULT=$(printf '%s\n' "$SNAPSHOT" | jq -ce --arg owner "$OWNER" --argjson projects "$PROJECTS_JSON" --argjson limit 50 \
      "$json_state_filter . as \$snapshot
       | [\$snapshot.backlog.records[]? | select(.structured == true and any(.body_lines[]?; startswith(\"<!-- fm-api:v1 owner=\" + \$owner + \" request=\")))
           | select(.repo as \$project | \$projects | index(\$project) != null) | {id,repo}] as \$owned
       | [\$snapshot.tasks[]? | select(.current_state.state != \"done\" and .current_state.state != \"failed\" and .current_state.state != \"cancelled\")
           | select(. as \$task | any(\$owned[]; .id == \$task.id and .repo == \$task.project))] as \$all
       | {tasks:(\$all[0:\$limit] | map(api_task)),truncated:((\$all | length) > \$limit)}" 2>/dev/null) \
      || api_error snapshot_invalid 'Firstmate returned an invalid task snapshot.'
    api_emit "$RESULT"
    ;;
  status)
    if [ "$#" -ne 2 ] || ! valid_id "${2:-}"; then
      api_error invalid_input 'Usage: fm-api.sh status <task-id>'
    fi
    api_owner
    api_projects
    api_snapshot
    api_record_for_task "$2"
    RESULT=null
    REPORT="$DATA/$2/report.md"
    [ ! -L "$DATA/$2" ] || api_error unsafe_result 'Refusing to read a report from a symlinked task directory.'
    if [ -L "$REPORT" ]; then api_error unsafe_result 'Refusing to read a symlinked task report.'; fi
    if [ -f "$REPORT" ]; then
      BYTES=$(wc -c < "$REPORT" | tr -d '[:space:]')
      [ "$BYTES" -le "$MAX_REPORT_BYTES" ] || api_error result_too_large 'Task report exceeds the 12000-byte result limit.' "$2"
      RESULT=$(jq -Rn --rawfile result "$REPORT" '$result') || api_error result_unreadable 'Could not encode the task report.' "$2"
    fi
    if [ -n "$TASK" ]; then
      TASK_RESULT=$(printf '%s\n' "$TASK" | jq -c --argjson result "$RESULT" "$json_state_filter api_task + {result:\$result}") \
        || api_error snapshot_invalid 'Firstmate returned an invalid task record.' "$2"
    else
      TASK_RESULT=$(printf '%s\n' "$RECORD" | jq -c --argjson result "$RESULT" '
        {task_id:.id,state:(if .state == "in_flight" then "working" elif .state == "done" then "complete" else "queued" end),
         summary:.title,needs_user:false,open_decisions:[],project:.repo,kind:null,
         endpoint_status:"unknown",result:$result}') \
        || api_error snapshot_invalid 'Firstmate returned an invalid backlog record.' "$2"
    fi
    [ -n "$TASK_RESULT" ] || api_error snapshot_invalid 'Firstmate returned an empty task result.' "$2"
    api_emit "$TASK_RESULT"
    ;;
  create)
    shift
    [ "$#" -eq 0 ] || api_error invalid_input 'Usage: fm-api.sh create < request.json'
    read_request
    api_owner
    api_projects
    if printf '%s' "$REQUEST" | jq -e 'has("authority") or has("mode") or has("push") or has("deploy")' >/dev/null 2>&1; then
      api_error unsupported_authority 'The JSON API accepts only its fixed local-only, no-push, non-deploying authority.'
    fi
    printf '%s' "$REQUEST" | jq -e 'keys | sort == ["instruction","project","request_id","title"]' >/dev/null 2>&1 \
      || api_error invalid_input 'create accepts only request_id, project, title, and instruction.'
    REQUEST_ID=$(printf '%s' "$REQUEST" | jq -er '.request_id | strings | select(test("^[A-Za-z0-9._-]{8,64}$"))' 2>/dev/null) \
      || api_error invalid_input 'request_id must be 8-64 letters, digits, dots, underscores, or hyphens.'
    PROJECT=$(printf '%s' "$REQUEST" | jq -er '.project | strings | select(test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))' 2>/dev/null) \
      || api_error invalid_input 'project must be a registered project name.'
    api_project_allowed "$PROJECT" \
      || api_error project_not_allowlisted 'Project is outside this node integration allowlist.'
    TITLE=$(printf '%s' "$REQUEST" | jq -er '.title | strings | select(length > 0 and length <= 120 and (contains("\n") | not) and (contains("\r") | not))' 2>/dev/null) \
      || api_error invalid_input 'title must be one non-empty line of at most 120 characters.'
    INSTRUCTION=$(printf '%s' "$REQUEST" | jq -er '.instruction | strings | select(length > 0 and length <= 20000 and (contains("\u0000") | not))' 2>/dev/null) \
      || api_error invalid_input 'instruction must be non-empty, contain no NUL, and be at most 20000 characters.'
    MODE=local-only
    COMMIT=true
    PUSH=false
    case "$PROJECT" in *..*|.*) api_error invalid_input 'project name is not a safe registry key.' ;; esac
    PROJECT_ROOT=$(CDPATH='' cd -- "$PROJECTS" 2>/dev/null && pwd -P) \
      || api_error project_unavailable 'This home projects/ directory is unavailable.'
    PROJECT_PATH="$PROJECT_ROOT/$PROJECT"
    [ -d "$PROJECT_PATH" ] && [ ! -L "$PROJECT_PATH" ] \
      || api_error project_unavailable 'Project must already exist as a registered, non-symlink directory under this home projects/.'
    [ "$(CDPATH='' cd -- "$PROJECT_PATH" 2>/dev/null && pwd -P)" = "$PROJECT_PATH" ] \
      || api_error project_unavailable 'Project resolves outside its registered projects/ directory.'
    REGISTRY_ERROR=$(mktemp) || api_error internal_error 'Could not create a temporary validation file.'
    if ! REGISTERED_POSTURE=$("$SCRIPT_DIR/fm-project-mode.sh" --raw "$PROJECT" 2>"$REGISTRY_ERROR") \
      || [ -s "$REGISTRY_ERROR" ]; then
      rm -f -- "$REGISTRY_ERROR"
      api_error project_unregistered 'Project is not valid in this home data/projects.md registry.'
    fi
    rm -f -- "$REGISTRY_ERROR"
    REGISTERED_MODE=${REGISTERED_POSTURE%% *}
    [ "$REGISTERED_MODE" = local-only ] \
      || api_error unsupported_mode 'This API accepts only projects registered with local-only posture.'
    BRANCH_PREFIX=$("$SCRIPT_DIR/fm-project-mode.sh" --branch-prefix "$PROJECT" 2>/dev/null) \
      || api_error project_unregistered 'Project branch-prefix registration is invalid.'
    REGISTERED_FORGE=$("$SCRIPT_DIR/fm-project-mode.sh" --forge "$PROJECT" 2>/dev/null) \
      || api_error project_unregistered 'Project forge registration is invalid.'
    [ ! -e "$CONFIG/crew-dispatch.json" ] && [ ! -L "$CONFIG/crew-dispatch.json" ] \
      || api_error dispatch_requires_intake 'A configured crew-dispatch profile needs Firstmate intake; this API does not select harness, model, or effort.'
    [ -d "$DATA" ] || api_error home_unavailable 'Firstmate data directory is unavailable.'
    command -v flock >/dev/null 2>&1 || api_error create_unavailable 'flock is required for idempotent Firstmate create.'
    exec {CREATE_LOCK_FD}>"$DATA/.fm-api-create.lock" \
      || api_error create_unavailable 'Could not acquire the Firstmate create lock.'
    flock -n "$CREATE_LOCK_FD" \
      || api_error create_busy 'Another Firstmate API create is in progress; retry later with the same request_id.'
    api_snapshot
    PAYLOAD_HASH=$(jq -cnS --arg project "$PROJECT" --arg title "$TITLE" --arg instruction "$INSTRUCTION" \
      '{project:$project,title:$title,instruction:$instruction}' | sha256sum | cut -d' ' -f1) \
      || api_error internal_error 'Could not fingerprint the create request.'
    MARKER="<!-- fm-api:v1 owner=$OWNER request=$REQUEST_ID digest=$PAYLOAD_HASH -->"
    MARKER_PREFIX="<!-- fm-api:v1 owner=$OWNER request=$REQUEST_ID "
    printf '%s\n' "$SNAPSHOT" | jq -e '.backlog.records | type == "array"' >/dev/null 2>&1 \
      || api_error snapshot_invalid 'Firstmate returned an invalid create snapshot.'
    EXISTING_ROWS=$(printf '%s\n' "$SNAPSHOT" | jq -c --arg prefix "$MARKER_PREFIX" '
      [.backlog.records[] | select(.structured == true and any(.body_lines[]?; startswith($prefix)))
       | {task_id:.id,marker:([.body_lines[] | select(startswith($prefix))][0])}]' 2>/dev/null) \
      || api_error snapshot_invalid 'Firstmate returned an invalid create snapshot.'
    EXISTING_COUNT=$(printf '%s\n' "$EXISTING_ROWS" | jq -r 'length')
    [ "$EXISTING_COUNT" -le 1 ] \
      || api_error create_uncertain 'Multiple tasks carry this owner/request marker; reconcile Firstmate state before retrying.'
    EXISTING=$(printf '%s\n' "$EXISTING_ROWS" | jq -c '.[0] // empty')
    if [ -n "$EXISTING" ]; then
      EXISTING_ID=$(printf '%s\n' "$EXISTING" | jq -r '.task_id')
      EXISTING_MARKER=$(printf '%s\n' "$EXISTING" | jq -r '.marker')
      valid_id "$EXISTING_ID" || api_error create_uncertain 'Existing request marker has an invalid task id; reconcile Firstmate state before creating again.'
      [ "$EXISTING_MARKER" = "$MARKER" ] \
        || api_error idempotency_conflict 'request_id was already used with a different create payload.' "$EXISTING_ID"
      RESULT=$(jq -cn --arg task_id "$EXISTING_ID" '{task_id:$task_id,created:false,reused:true,state:"existing",outcome:"not_retried"}')
      api_emit "$RESULT"
      exit 0
    fi
    TASK_BODY="$INSTRUCTION"$'\n\n'"$MARKER"
    TASK_JSON=$("$SCRIPT_DIR/fm-tasks-axi.sh" add "$TITLE" --mint --kind ship --repo "$PROJECT" --body "$TASK_BODY" --json 2>/dev/null) \
      || api_error create_uncertain 'Firstmate intake did not confirm its result. Reconcile or retry only with the same request_id.'
    TASK_ID=$(printf '%s' "$TASK_JSON" | jq -er '.task.id' 2>/dev/null) \
      || api_error create_uncertain 'Firstmate intake returned no task id. Reconcile or retry only with the same request_id.'
    valid_id "$TASK_ID" || api_error create_uncertain 'Firstmate intake returned an unsafe task id; reconcile before retrying.'
    BRIEF_ARGS=("$TASK_ID" "$PROJECT" --mode "$MODE" --branch-prefix "$BRANCH_PREFIX" --forge "$REGISTERED_FORGE")
    if ! "$SCRIPT_DIR/fm-brief.sh" "${BRIEF_ARGS[@]}" >/dev/null 2>&1; then
      api_error create_uncertain 'Task was queued, but Firstmate could not scaffold its brief; do not create a replacement task.' "$TASK_ID"
    fi
    SPEC="Authority: inspect=true, edit=true, commit=$COMMIT, push=$PUSH, deploy=false. Stay within the Firstmate-isolated worktree. Do not deploy."
    if ! jq -Rrs --arg task "$INSTRUCTION" --arg spec "$SPEC" '
      def replace_first($old; $new): index($old) as $i | if $i == null then error("placeholder missing") else .[:$i] + $new + .[$i + ($old|length):] end;
      replace_first("{FIRSTMATE_SPEC}"; $spec) | replace_first("{TASK}"; $task)
    ' "$DATA/$TASK_ID/brief.md" > "$DATA/$TASK_ID/brief.tmp" 2>/dev/null \
      ; then
      api_error create_uncertain 'Task was queued, but the generated brief could not be filled; do not create a replacement task.' "$TASK_ID"
    fi
    mv -- "$DATA/$TASK_ID/brief.tmp" "$DATA/$TASK_ID/brief.md" \
      || api_error create_uncertain 'Task was queued, but the generated brief could not be published; do not create a replacement task.' "$TASK_ID"
    SPAWN_ARGS=("$TASK_ID" "$PROJECT_PATH" --mode "$MODE" --yolo off --branch-prefix "$BRANCH_PREFIX" --harness codex --effort low --codex-appserver)
    # The detached backend must not inherit the create lock through tmux.
    exec {CREATE_LOCK_FD}>&-
    if ! "$SCRIPT_DIR/fm-spawn.sh" "${SPAWN_ARGS[@]}" >/dev/null 2>&1; then
      api_error create_uncertain 'Task was queued and briefed, but Firstmate could not confirm a worker launch; do not create a replacement task.' "$TASK_ID"
    fi
    RESULT=$(jq -cn --arg task_id "$TASK_ID" '{task_id:$task_id,state:"working",created:true}')
    api_emit "$RESULT"
    ;;
  steer)
    if [ "$#" -ne 2 ] || ! valid_id "${2:-}"; then
      api_error invalid_input 'Usage: fm-api.sh steer <task-id> < request.json>'
    fi
    read_request
    api_owner
    api_projects
    printf '%s' "$REQUEST" | jq -e 'has("message") and ((keys - ["message","resolve_keys"]) | length == 0)' >/dev/null 2>&1 \
      || api_error invalid_input 'steer accepts only message and optional resolve_keys.'
    MESSAGE=$(printf '%s' "$REQUEST" | jq -er '.message | strings | select(length > 0 and length <= 20000)' 2>/dev/null) \
      || api_error invalid_input 'message must be non-empty and at most 20000 characters.'
    KEY_JSON=$(printf '%s' "$REQUEST" | jq -ce '
      .resolve_keys as $keys
      | if $keys == null then []
        elif ($keys | type) == "array" and ($keys | length) <= 10
          and all($keys[]; type == "string" and test("^[A-Za-z0-9._-]{1,64}$"))
          and (($keys | unique | length) == ($keys | length)) then $keys
        else error("invalid resolve_keys") end' 2>/dev/null) \
      || api_error invalid_input 'resolve_keys must be an array of valid decision keys.'
    api_snapshot
    api_record_for_task "$2"
    if [ "$(printf '%s\n' "$KEY_JSON" | jq 'length')" -gt 0 ]; then
      [ -n "$TASK" ] \
        || api_error decision_not_open 'A supplied decision key is not open on this owned task; nothing was sent.' "$2"
      printf '%s\n' "$TASK" | jq -e --argjson keys "$KEY_JSON" '
        [.hints.open_decisions[]?.key] as $open
        | all($keys[]; . as $key | $open | index($key) != null)' >/dev/null 2>&1 \
        || api_error decision_not_open 'A supplied decision key is not open on this owned task; nothing was sent.' "$2"
    elif [ -n "$TASK" ] && [ "$(printf '%s\n' "$TASK" | jq '(.hints.open_decisions // []) | length')" -gt 0 ]; then
      api_error decision_key_required 'This task has an open decision; answer it with its current decision key.' "$2"
    fi
    mapfile -t KEYS < <(printf '%s' "$KEY_JSON" | jq -r '.[]')
    SEND_ARGS=("$2")
    for key in "${KEYS[@]}"; do SEND_ARGS+=(--resolve-key "$key"); done
    SEND_ARGS+=("$MESSAGE")
    "$SCRIPT_DIR/fm-send.sh" "${SEND_ARGS[@]}" >/dev/null 2>&1 \
      || api_error steer_uncertain 'Firstmate did not confirm steer delivery; inspect the same task before retrying.' "$2"
    RESULT=$(jq -cn --arg task_id "$2" '{task_id:$task_id,accepted:true}')
    api_emit "$RESULT"
    ;;
  cancel)
    if [ "$#" -ne 2 ] || ! valid_id "${2:-}"; then
      api_error invalid_input 'Usage: fm-api.sh cancel <task-id>'
    fi
    api_owner
    api_projects
    api_snapshot
    api_record_for_task "$2"
    "$SCRIPT_DIR/fm-control.sh" "$2" exit >/dev/null 2>&1 \
      || api_error cancel_unconfirmed 'Firstmate could not verify agent exit; task and work were not discarded.' "$2"
    RESULT=$(jq -cn --arg task_id "$2" '{task_id:$task_id,agent_stopped:true,task_state_retained:true,semantics:"verified agent exit; query status for the task outcome"}')
    api_emit "$RESULT"
    ;;
  *) api_error invalid_command 'Expected one of: create, status, list, steer, cancel.' ;;
esac
