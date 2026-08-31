#!/usr/bin/env bash
# Register and reconcile Codex Desktop tasks created by the app host tools.
#
# The Desktop host owns task creation, delivery, waiting, and archival. Firstmate
# owns the durable task/worktree binding and a separate current-state record.
# The append-only .status file remains the worker's return/wake event channel;
# this script never derives current state from its tail.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-task-model-route-lib.sh
. "$SCRIPT_DIR/fm-task-model-route-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  fm-codex-app-task.sh register <id> --thread <uuid> --host <host-id>
      --project <checkout> --worktree <desktop-worktree> --kind <kind>
      --model <model> --effort <effort> --route-record <path>
      --session-envelope <small|normal|research>
      --mode <direct-PR|local-only> --yolo <on|off>
  fm-codex-app-task.sh reconcile <id> --state <state> [--detail <text>]
      [--event <status-line>]
  fm-codex-app-task.sh hard-stop <id> --reason <text> --handoff <external-path>
  fm-codex-app-task.sh resume <id> --thread <uuid> --host <host-id>
      --checkpoint <sha> --handoff <external-path>
  fm-codex-app-task.sh archive-preflight <id> [--report <external-report>]

states: working parked done blocked paused failed unknown
EOF
  exit 2
}

die_usage() {
  echo "error: $1" >&2
  exit 2
}

die() {
  echo "error: $1" >&2
  exit 1
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

valid_atom() {
  case "$1" in ''|*[!A-Za-z0-9._@%:+-]*) return 1 ;; esac
}

valid_thread() {
  printf '%s' "$1" \
    | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

valid_scalar() {
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
}

valid_state() {
  case "$1" in working|parked|done|blocked|paused|failed|unknown) return 0 ;; esac
  return 1
}

valid_envelope() {
  case "$1" in small|normal|research) return 0 ;; esac
  return 1
}

valid_mode() {
  case "$1" in direct-PR|local-only) return 0 ;; esac
  return 1
}

valid_yolo() {
  case "$1" in on|off) return 0 ;; esac
  return 1
}

exact_meta_value() {
  fm_backend_meta_exact_value "$1" "$2" 2>/dev/null
}

require_owner() {
  mkdir -p "$STATE" || die "cannot create Firstmate state directory $STATE"
  fm_session_lock_owned_by_self "$STATE" \
    || die "this process does not own the live Firstmate session lock; refusing Desktop task mutation"
}

resolve_git_checkout() {  # <checkout>
  local checkout=$1 checkout_real top top_real
  [ -d "$checkout" ] || return 1
  checkout_real=$(CDPATH='' cd -- "$checkout" 2>/dev/null && pwd -P) || return 1
  top=$(git -C "$checkout_real" rev-parse --show-toplevel 2>/dev/null) || return 1
  top_real=$(CDPATH='' cd -- "$top" 2>/dev/null && pwd -P) || return 1
  [ "$checkout_real" = "$top_real" ] || return 1
  printf '%s\n' "$top_real"
}

resolve_git_common_dir() {  # <checkout>
  local checkout=$1 common
  common=$(git -C "$checkout" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in /*) ;; *) common="$checkout/$common" ;; esac
  CDPATH='' cd -- "$common" 2>/dev/null && pwd -P
}

REGISTERED_WORKTREE=
registered_worktree_validate() {  # <metadata>
  local meta=$1 project worktree common project_real worktree_real
  local project_common worktree_common
  project=$(exact_meta_value "$meta" project) || return 1
  worktree=$(exact_meta_value "$meta" worktree) || return 1
  common=$(exact_meta_value "$meta" git_common_dir) || return 1
  project_real=$(resolve_git_checkout "$project") || return 1
  worktree_real=$(resolve_git_checkout "$worktree") || return 1
  [ "$project_real" != "$worktree_real" ] || return 1
  project_common=$(resolve_git_common_dir "$project_real") || return 1
  worktree_common=$(resolve_git_common_dir "$worktree_real") || return 1
  [ "$project_common" = "$common" ] && [ "$worktree_common" = "$common" ] || return 1
  REGISTERED_WORKTREE=$worktree_real
}

registered_route_validate() {  # <metadata>
  local meta=$1 route expected_hash recorded_model recorded_effort recorded_id actual_hash
  route=$(exact_meta_value "$meta" model_route_record) || return 1
  expected_hash=$(exact_meta_value "$meta" model_route_sha256) || return 1
  recorded_id=$(exact_meta_value "$meta" endpoint_task_id) || return 1
  recorded_model=$(exact_meta_value "$meta" model) || return 1
  recorded_effort=$(exact_meta_value "$meta" effort) || return 1
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual_hash=$(fm_task_route_sha256 "$route") || return 1
  [ "$actual_hash" = "$expected_hash" ] || return 1
  fm_task_route_record_parse "$route" || return 1
  [ "$FM_TASK_ROUTE_ID" = "$recorded_id" ] \
    && [ "$FM_TASK_ROUTE_RESOLVED_MODEL" = "$recorded_model" ] \
    && [ "$FM_TASK_ROUTE_RESOLVED_EFFORT" = "$recorded_effort" ]
}

write_current() {  # <task-id> <thread> <host> <state> <detail>
  local id=$1 thread=$2 host=$3 current_state=$4 detail=$5 tmp current
  current="$STATE/$id.codex-app-current"
  tmp=$(umask 077; mktemp "$STATE/.$id.codex-app-current.XXXXXX") \
    || die "cannot stage current state for $id"
  {
    printf 'thread_id=%s\n' "$thread"
    printf 'host_id=%s\n' "$host"
    printf 'state=%s\n' "$current_state"
    printf 'updated_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'detail=%s\n' "$detail"
  } > "$tmp" || { rm -f -- "$tmp"; die "cannot write staged current state for $id"; }
  mv -f -- "$tmp" "$current" \
    || { rm -f -- "$tmp"; die "cannot publish current state for $id"; }
}

register_task() {
  local id=$1
  shift
  local thread='' host='' project='' worktree='' kind='' model='' effort='' mode='' yolo=''
  local route_record='' envelope=''
  local project_real worktree_real git_common_dir route_real route_hash
  local meta current status meta_tmp status_tmp current_tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --thread) [ "$#" -ge 2 ] || usage; thread=$2; shift 2 ;;
      --host) [ "$#" -ge 2 ] || usage; host=$2; shift 2 ;;
      --project) [ "$#" -ge 2 ] || usage; project=$2; shift 2 ;;
      --worktree) [ "$#" -ge 2 ] || usage; worktree=$2; shift 2 ;;
      --kind) [ "$#" -ge 2 ] || usage; kind=$2; shift 2 ;;
      --model) [ "$#" -ge 2 ] || usage; model=$2; shift 2 ;;
      --effort) [ "$#" -ge 2 ] || usage; effort=$2; shift 2 ;;
      --route-record) [ "$#" -ge 2 ] || usage; route_record=$2; shift 2 ;;
      --session-envelope) [ "$#" -ge 2 ] || usage; envelope=$2; shift 2 ;;
      --mode) [ "$#" -ge 2 ] || usage; mode=$2; shift 2 ;;
      --yolo) [ "$#" -ge 2 ] || usage; yolo=$2; shift 2 ;;
      *) die_usage "unknown register argument '$1'" ;;
    esac
  done

  valid_id "$id" || die_usage "invalid task id '$id'"
  valid_thread "$thread" || die_usage "invalid Codex Desktop thread id '$thread'"
  valid_atom "$host" || die_usage "invalid Codex Desktop host id '$host'"
  valid_atom "$kind" || die_usage "invalid task kind '$kind'"
  valid_atom "$model" || die_usage "invalid model '$model'"
  valid_atom "$effort" || die_usage "invalid effort '$effort'"
  valid_envelope "$envelope" || die_usage "invalid session envelope '$envelope'"
  valid_mode "$mode" || die_usage "invalid task mode '$mode'"
  valid_yolo "$yolo" || die_usage "invalid project yolo posture '$yolo'"
  if ! valid_scalar "$project" || ! valid_scalar "$worktree"; then
    die_usage "project and worktree paths must be single-line values"
  fi
  project_real=$(resolve_git_checkout "$project") \
    || die_usage "project checkout is not an exact Git worktree root: $project"
  worktree_real=$(resolve_git_checkout "$worktree") \
    || die_usage "Desktop worktree is not an exact Git worktree root: $worktree"
  [ "$project_real" != "$worktree_real" ] \
    || die_usage "Desktop task worktree must be isolated from the saved project checkout"
  git_common_dir=$(resolve_git_common_dir "$project_real") \
    || die_usage "cannot resolve project Git identity: $project_real"
  [ "$(resolve_git_common_dir "$worktree_real")" = "$git_common_dir" ] \
    || die_usage "Desktop worktree does not belong to the registered project checkout"
  route_real=$(realpath "$route_record" 2>/dev/null) \
    || die_usage "cannot resolve model route record: $route_record"
  [ -f "$route_real" ] && [ ! -L "$route_record" ] \
    || die_usage "model route record must be a regular file"
  fm_task_route_record_parse "$route_real" \
    || die_usage "model route record does not satisfy the complete routing contract"
  [ "$FM_TASK_ROUTE_ID" = "$id" ] && [ "$FM_TASK_ROUTE_RESOLVED_MODEL" = "$model" ] \
    && [ "$FM_TASK_ROUTE_RESOLVED_EFFORT" = "$effort" ] \
    || die_usage "model route record does not match task, model, and effort"
  route_hash=$(fm_task_route_sha256 "$route_real") \
    || die_usage "cannot hash model route record: $route_real"

  require_owner
  meta="$STATE/$id.meta"
  status="$STATE/$id.status"
  current="$STATE/$id.codex-app-current"
  [ ! -e "$meta" ] && [ ! -e "$status" ] && [ ! -e "$current" ] \
    || die "task $id already has durable state; refusing to overwrite it"

  meta_tmp=$(umask 077; mktemp "$STATE/.$id.meta.XXXXXX") \
    || die "cannot stage metadata for $id"
  status_tmp=$(umask 077; mktemp "$STATE/.$id.status.XXXXXX") \
    || { rm -f -- "$meta_tmp"; die "cannot stage status channel for $id"; }
  current_tmp=$(umask 077; mktemp "$STATE/.$id.codex-app-current.XXXXXX") \
    || { rm -f -- "$meta_tmp" "$status_tmp"; die "cannot stage current state for $id"; }

  {
    printf 'window=%s\n' "$thread"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$worktree_real"
    printf 'project=%s\n' "$project_real"
    printf 'git_common_dir=%s\n' "$git_common_dir"
    printf 'harness=codex\n'
    printf 'kind=%s\n' "$kind"
    printf 'mode=%s\n' "$mode"
    printf 'yolo=%s\n' "$yolo"
    printf 'model=%s\n' "$model"
    printf 'effort=%s\n' "$effort"
    printf 'model_route_record=%s\n' "$route_real"
    printf 'model_route_sha256=%s\n' "$route_hash"
    printf 'session_envelope=%s\n' "$envelope"
    printf 'session_generation=1\n'
    printf 'session_cost_telemetry=unsupported\n'
    printf 'session_context_telemetry=unsupported\n'
    printf 'session_compaction_telemetry=unsupported\n'
    printf 'session_output_telemetry=unsupported\n'
    printf 'backend=codex-app-host\n'
    printf 'codex_app_thread_id=%s\n' "$thread"
    printf 'codex_app_host_id=%s\n' "$host"
  } > "$meta_tmp" || {
    rm -f -- "$meta_tmp" "$status_tmp" "$current_tmp"
    die "cannot write staged metadata for $id"
  }
  {
    printf 'thread_id=%s\n' "$thread"
    printf 'host_id=%s\n' "$host"
    printf 'state=working\n'
    printf 'updated_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'detail=registered by the Codex Desktop host\n'
  } > "$current_tmp" || {
    rm -f -- "$meta_tmp" "$status_tmp" "$current_tmp"
    die "cannot write staged current state for $id"
  }

  if ! mv -f -- "$status_tmp" "$status" \
    || ! mv -f -- "$current_tmp" "$current" \
    || ! mv -f -- "$meta_tmp" "$meta"; then
      rm -f -- "$meta_tmp" "$status_tmp" "$current_tmp"
      die "cannot publish durable task state for $id; inspect $STATE before retrying"
  fi
  printf 'registered: %s -> Codex Desktop task %s (host=%s worktree=%s)\n' \
    "$id" "$thread" "$host" "$worktree_real"
}

reconcile_task() {
  local id=$1
  shift
  local current_state='' detail='' event='' meta thread host
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) [ "$#" -ge 2 ] || usage; current_state=$2; shift 2 ;;
      --detail) [ "$#" -ge 2 ] || usage; detail=$2; shift 2 ;;
      --event) [ "$#" -ge 2 ] || usage; event=$2; shift 2 ;;
      *) die_usage "unknown reconcile argument '$1'" ;;
    esac
  done

  valid_id "$id" || die_usage "invalid task id '$id'"
  valid_state "$current_state" \
    || die_usage "invalid current state '$current_state'"
  valid_scalar "$detail" || die_usage "current-state detail must be a single-line value"
  valid_scalar "$event" || die_usage "status event must be a single-line value"
  case "$event" in
    ''|working:*|needs-decision:*|blocked:*|paused:*|done:*|failed:*) ;;
    *) die_usage "invalid status event '$event'" ;;
  esac
  require_owner
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || die "no metadata for Desktop task $id"
  [ "$(fm_backend_of_meta "$meta")" = codex-app-host ] \
    || die "task $id is not a Codex Desktop host task"
  fm_backend_validate_task_endpoint "$meta" "$id" \
    || die "task $id has invalid Desktop endpoint metadata"
  registered_route_validate "$meta" \
    || die "task $id no longer matches its immutable model route evidence"
  thread=$(exact_meta_value "$meta" codex_app_thread_id) \
    || die "task $id has no exact Desktop thread binding"
  host=$(exact_meta_value "$meta" codex_app_host_id) \
    || die "task $id has no exact Desktop host binding"
  write_current "$id" "$thread" "$host" "$current_state" "$detail"
  [ -z "$event" ] || printf '%s\n' "$event" >> "$STATE/$id.status" \
    || die "current state changed, but status event could not be appended for $id"
  printf 'reconciled: %s state=%s\n' "$id" "$current_state"
}

resolve_existing_file() {  # <path>
  local resolved
  resolved=$(realpath "$1" 2>/dev/null) || return 1
  [ -f "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

HARD_STOP_PRE_HEAD=
HARD_STOP_INDEX_TREE=
HARD_STOP_REASON=
HARD_STOP_HANDOFF=
HARD_STOP_THREAD=
HARD_STOP_HOST=
HARD_STOP_ENVELOPE=
HARD_STOP_GENERATION=
HARD_STOP_WORKTREE=
hard_stop_journal_parse() {  # <journal>
  local journal=$1 key lines
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  lines=$(wc -l < "$journal" | tr -d ' ')
  [ "$lines" = 10 ] || return 1
  [ "$(exact_meta_value "$journal" version)" = 1 ] || return 1
  for key in pre_head index_tree reason handoff thread host envelope generation worktree; do
    exact_meta_value "$journal" "$key" >/dev/null || return 1
  done
  HARD_STOP_PRE_HEAD=$(exact_meta_value "$journal" pre_head)
  HARD_STOP_INDEX_TREE=$(exact_meta_value "$journal" index_tree)
  HARD_STOP_REASON=$(exact_meta_value "$journal" reason)
  HARD_STOP_HANDOFF=$(exact_meta_value "$journal" handoff)
  HARD_STOP_THREAD=$(exact_meta_value "$journal" thread)
  HARD_STOP_HOST=$(exact_meta_value "$journal" host)
  HARD_STOP_ENVELOPE=$(exact_meta_value "$journal" envelope)
  HARD_STOP_GENERATION=$(exact_meta_value "$journal" generation)
  HARD_STOP_WORKTREE=$(exact_meta_value "$journal" worktree)
  printf '%s' "$HARD_STOP_PRE_HEAD" | grep -Eq '^[0-9a-f]{40,64}$' || return 1
  printf '%s' "$HARD_STOP_INDEX_TREE" | grep -Eq '^[0-9a-f]{40,64}$' || return 1
  case "$HARD_STOP_GENERATION" in ''|*[!0-9]*) return 1 ;; esac
}

hard_stop_task() {
  local id=$1
  shift
  local reason='' handoff='' meta worktree_real handoff_parent handoff_real journal
  local thread host envelope generation checkpoint tmp pre_head index_tree head parent commit_tree subject
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || usage; reason=$2; shift 2 ;;
      --handoff) [ "$#" -ge 2 ] || usage; handoff=$2; shift 2 ;;
      *) die_usage "unknown hard-stop argument '$1'" ;;
    esac
  done

  valid_id "$id" || die_usage "invalid task id '$id'"
  if [ -z "$reason" ] || ! valid_scalar "$reason"; then
    die_usage "hard-stop reason must be a non-empty single-line value"
  fi
  if [ -z "$handoff" ] || ! valid_scalar "$handoff"; then
    die_usage "handoff path must be a non-empty single-line value"
  fi
  require_owner
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || die "no metadata for Desktop task $id"
  [ "$(fm_backend_of_meta "$meta")" = codex-app-host ] \
    || die "task $id is not a Codex Desktop host task"
  registered_route_validate "$meta" \
    || die "task $id no longer matches its immutable model route evidence"
  registered_worktree_validate "$meta" \
    || die "task $id no longer matches its registered Git checkout identity"
  worktree_real=$REGISTERED_WORKTREE
  handoff_parent=$(dirname "$handoff")
  [ -d "$handoff_parent" ] || die "handoff parent does not exist: $handoff_parent"
  handoff_parent=$(CDPATH='' cd -- "$handoff_parent" 2>/dev/null && pwd -P) \
    || die "cannot resolve handoff parent: $handoff_parent"
  handoff_real="$handoff_parent/$(basename "$handoff")"
  case "$handoff_real" in
    "$worktree_real"|"$worktree_real"/*)
      die "handoff must be outside the Desktop worktree: $handoff_real"
      ;;
  esac
  thread=$(exact_meta_value "$meta" codex_app_thread_id) \
    || die "task $id has no exact Desktop thread binding"
  host=$(exact_meta_value "$meta" codex_app_host_id) \
    || die "task $id has no exact Desktop host binding"
  envelope=$(exact_meta_value "$meta" session_envelope) \
    || die "task $id has no session envelope"
  generation=$(exact_meta_value "$meta" session_generation) \
    || die "task $id has no session generation"
  case "$generation" in ''|*[!0-9]*) die "task $id has invalid session generation" ;; esac
  journal="$STATE/$id.hard-stop-journal"
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    hard_stop_journal_parse "$journal" \
      || die "task $id has an invalid hard-stop recovery journal"
    [ "$HARD_STOP_REASON" = "$reason" ] && [ "$HARD_STOP_HANDOFF" = "$handoff_real" ] \
      && [ "$HARD_STOP_THREAD" = "$thread" ] && [ "$HARD_STOP_HOST" = "$host" ] \
      && [ "$HARD_STOP_ENVELOPE" = "$envelope" ] \
      && [ "$HARD_STOP_GENERATION" = "$generation" ] \
      && [ "$HARD_STOP_WORKTREE" = "$worktree_real" ] \
      || die "task $id hard-stop retry does not match its recovery journal"
    pre_head=$HARD_STOP_PRE_HEAD
    index_tree=$HARD_STOP_INDEX_TREE
  else
    [ ! -e "$handoff_real" ] && [ ! -L "$handoff_real" ] \
      || die "handoff already exists; refusing to overwrite it: $handoff_real"
    git -C "$worktree_real" diff --cached --quiet --exit-code \
      && die "hard stop requires staged intended changes for the checkpoint commit"
    pre_head=$(git -C "$worktree_real" rev-parse HEAD) \
      || die "could not read the pre-checkpoint commit for $id"
    index_tree=$(git -C "$worktree_real" write-tree) \
      || die "could not record the staged checkpoint tree for $id"
    tmp=$(umask 077; mktemp "$STATE/.$id.hard-stop-journal.XXXXXX") \
      || die "cannot stage hard-stop recovery journal for $id"
    {
      printf 'version=1\n'
      printf 'pre_head=%s\n' "$pre_head"
      printf 'index_tree=%s\n' "$index_tree"
      printf 'reason=%s\n' "$reason"
      printf 'handoff=%s\n' "$handoff_real"
      printf 'thread=%s\n' "$thread"
      printf 'host=%s\n' "$host"
      printf 'envelope=%s\n' "$envelope"
      printf 'generation=%s\n' "$generation"
      printf 'worktree=%s\n' "$worktree_real"
    } > "$tmp" || { rm -f -- "$tmp"; die "cannot write hard-stop recovery journal for $id"; }
    mv -f -- "$tmp" "$journal" \
      || { rm -f -- "$tmp"; die "cannot publish hard-stop recovery journal for $id"; }
  fi
  head=$(git -C "$worktree_real" rev-parse HEAD) \
    || die "could not read checkpoint state for $id"
  if [ "$head" = "$pre_head" ]; then
    [ "$(git -C "$worktree_real" write-tree)" = "$index_tree" ] \
      || die "task $id staged checkpoint changed after its recovery journal was written"
    git -C "$worktree_real" commit -m "checkpoint: $id session envelope" >/dev/null \
      || die "could not create staged-only checkpoint commit for $id"
    checkpoint=$(git -C "$worktree_real" rev-parse HEAD) \
      || die "could not read checkpoint commit for $id"
  else
    checkpoint=$head
  fi
  parent=$(git -C "$worktree_real" rev-parse "$checkpoint^") \
    || die "task $id checkpoint has no exact parent"
  commit_tree=$(git -C "$worktree_real" rev-parse "$checkpoint^{tree}") \
    || die "task $id checkpoint tree is unreadable"
  subject=$(git -C "$worktree_real" log -1 --format=%s "$checkpoint") \
    || die "task $id checkpoint message is unreadable"
  [ "$parent" = "$pre_head" ] && [ "$commit_tree" = "$index_tree" ] \
    && [ "$subject" = "checkpoint: $id session envelope" ] \
    || die "task $id checkpoint does not match its recovery journal"
  tmp=$(umask 077; mktemp "$handoff_parent/.session-handoff.XXXXXX") \
    || die "cannot stage session handoff for $id"
  {
    printf '# Codex Desktop session handoff\n\n'
    printf 'task_id: %s\n' "$id"
    printf 'session_envelope: %s\n' "$envelope"
    printf 'session_generation: %s\n' "$generation"
    printf 'reason: %s\n' "$reason"
    printf 'checkpoint_sha: %s\n' "$checkpoint"
    printf 'worktree: %s\n' "$worktree_real"
    printf 'previous_thread_id: %s\n' "$thread"
    printf 'previous_host_id: %s\n' "$host"
    printf 'session_cost_telemetry: unsupported\n'
    printf 'session_context_telemetry: unsupported\n'
    printf 'session_compaction_telemetry: unsupported\n'
    printf 'session_output_telemetry: unsupported\n'
    printf 'continuation: create a fresh Codex Desktop task for this exact worktree and resume from this checkpoint.\n'
  } > "$tmp" || { rm -f -- "$tmp"; die "cannot write session handoff for $id"; }
  if [ -e "$handoff_real" ] || [ -L "$handoff_real" ]; then
    if [ ! -f "$handoff_real" ] || [ -L "$handoff_real" ] \
      || ! cmp -s "$tmp" "$handoff_real"; then
      rm -f -- "$tmp"
      die "existing session handoff does not match recovery journal for $id"
    fi
    rm -f -- "$tmp"
  else
    mv -- "$tmp" "$handoff_real" \
      || { rm -f -- "$tmp"; die "cannot publish session handoff for $id"; }
  fi
  tmp=$(umask 077; mktemp "$STATE/.$id.meta.XXXXXX") \
    || die "cannot stage checkpoint metadata for $id"
  grep -v -e '^session_checkpoint=' -e '^session_handoff=' "$meta" > "$tmp" || true
  {
    printf 'session_checkpoint=%s\n' "$checkpoint"
    printf 'session_handoff=%s\n' "$handoff_real"
  } >> "$tmp"
  mv -f -- "$tmp" "$meta" || die "cannot publish checkpoint metadata for $id"
  write_current "$id" "$thread" "$host" paused "hard session boundary; checkpoint $checkpoint"
  rm -f -- "$journal" || die "cannot retire hard-stop recovery journal for $id"
  printf 'hard-stop: %s checkpoint=%s handoff=%s\n' "$id" "$checkpoint" "$handoff_real"
}

resume_task() {
  local id=$1
  shift
  local thread='' host='' checkpoint='' handoff='' meta current worktree handoff_real
  local recorded_checkpoint recorded_handoff old_thread generation next_generation tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --thread) [ "$#" -ge 2 ] || usage; thread=$2; shift 2 ;;
      --host) [ "$#" -ge 2 ] || usage; host=$2; shift 2 ;;
      --checkpoint) [ "$#" -ge 2 ] || usage; checkpoint=$2; shift 2 ;;
      --handoff) [ "$#" -ge 2 ] || usage; handoff=$2; shift 2 ;;
      *) die_usage "unknown resume argument '$1'" ;;
    esac
  done

  valid_id "$id" || die_usage "invalid task id '$id'"
  valid_thread "$thread" || die_usage "invalid Codex Desktop thread id '$thread'"
  valid_atom "$host" || die_usage "invalid Codex Desktop host id '$host'"
  printf '%s' "$checkpoint" | grep -Eq '^[0-9a-f]{40,64}$' \
    || die_usage "invalid checkpoint SHA '$checkpoint'"
  handoff_real=$(resolve_existing_file "$handoff") \
    || die_usage "cannot resolve session handoff: $handoff"
  require_owner
  meta="$STATE/$id.meta"
  current="$STATE/$id.codex-app-current"
  [ -f "$meta" ] && [ -f "$current" ] || die "task $id has incomplete Desktop state"
  [ "$(fm_backend_of_meta "$meta")" = codex-app-host ] \
    || die "task $id is not a Codex Desktop host task"
  registered_route_validate "$meta" \
    || die "task $id no longer matches its immutable model route evidence"
  [ "$(exact_meta_value "$current" state)" = paused ] \
    || die "task $id must be paused at a hard session boundary before resume"
  registered_worktree_validate "$meta" \
    || die "task $id no longer matches its registered Git checkout identity"
  worktree=$REGISTERED_WORKTREE
  [ "$(git -C "$worktree" rev-parse HEAD 2>/dev/null)" = "$checkpoint" ] \
    || die "Desktop worktree is not at requested checkpoint $checkpoint"
  recorded_checkpoint=$(exact_meta_value "$meta" session_checkpoint) \
    || die "task $id has no recorded session checkpoint"
  recorded_handoff=$(exact_meta_value "$meta" session_handoff) \
    || die "task $id has no recorded session handoff"
  [ "$recorded_checkpoint" = "$checkpoint" ] && [ "$recorded_handoff" = "$handoff_real" ] \
    || die "resume checkpoint or handoff does not match recorded hard stop"
  grep -qx "checkpoint_sha: $checkpoint" "$handoff_real" \
    || die "session handoff does not bind checkpoint $checkpoint"
  old_thread=$(exact_meta_value "$meta" codex_app_thread_id) \
    || die "task $id has no previous Desktop thread"
  [ "$thread" != "$old_thread" ] || die "resume requires a fresh Codex Desktop thread"
  generation=$(exact_meta_value "$meta" session_generation) \
    || die "task $id has no session generation"
  case "$generation" in ''|*[!0-9]*) die "task $id has invalid session generation" ;; esac
  next_generation=$((generation + 1))
  tmp=$(umask 077; mktemp "$STATE/.$id.meta.XXXXXX") \
    || die "cannot stage resumed metadata for $id"
  grep -v -e '^window=' -e '^codex_app_thread_id=' -e '^codex_app_host_id=' \
    -e '^session_generation=' "$meta" > "$tmp" || true
  {
    printf 'window=%s\n' "$thread"
    printf 'codex_app_thread_id=%s\n' "$thread"
    printf 'codex_app_host_id=%s\n' "$host"
    printf 'session_generation=%s\n' "$next_generation"
  } >> "$tmp"
  mv -f -- "$tmp" "$meta" || die "cannot publish resumed metadata for $id"
  write_current "$id" "$thread" "$host" working "resumed from checkpoint $checkpoint"
  printf 'resumed: %s generation=%s thread=%s checkpoint=%s\n' \
    "$id" "$next_generation" "$thread" "$checkpoint"
}

archive_preflight_task() {
  local id=$1
  shift
  local report='' meta current kind worktree worktree_real report_real state
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --report) [ "$#" -ge 2 ] || usage; report=$2; shift 2 ;;
      *) die_usage "unknown archive-preflight argument '$1'" ;;
    esac
  done

  valid_id "$id" || die_usage "invalid task id '$id'"
  valid_scalar "$report" || die_usage "report path must be a single-line value"
  require_owner
  meta="$STATE/$id.meta"
  current="$STATE/$id.codex-app-current"
  [ -f "$meta" ] || die "no metadata for Desktop task $id"
  [ -f "$current" ] || die "no current state for Desktop task $id"
  [ "$(fm_backend_of_meta "$meta")" = codex-app-host ] \
    || die "task $id is not a Codex Desktop host task"
  fm_backend_validate_task_endpoint "$meta" "$id" \
    || die "task $id has invalid Desktop endpoint metadata"
  registered_route_validate "$meta" \
    || die "task $id no longer matches its immutable model route evidence"

  state=$(exact_meta_value "$current" state) \
    || die "task $id has no exact reconciled current state"
  [ "$state" = 'done' ] \
    || die "task $id is state=$state; archive requires reconciled done state"
  kind=$(exact_meta_value "$meta" kind) \
    || die "task $id has no exact task kind"
  registered_worktree_validate "$meta" \
    || die "task $id no longer matches its registered Git checkout identity"
  worktree=$REGISTERED_WORKTREE

  if [ "$kind" != scout ]; then
    die "archive would delete the retained ship worktree for task $id; preserve the Desktop task until its result is independently landed or explicit discard is authorized"
  fi

  [ -n "$report" ] \
    || die "Desktop scout $id requires a retained external report before archive"
  [ -d "$worktree" ] \
    || die "Desktop scout $id worktree is already absent; cannot prove archive safety"
  worktree_real=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) \
    || die "cannot resolve Desktop worktree for task $id"
  report_real=$(resolve_existing_file "$report") \
    || die "cannot resolve retained scout report: $report"
  [ -s "$report_real" ] \
    || die "retained scout report is empty: $report_real"
  case "$report_real" in
    "$worktree_real"|"$worktree_real"/*)
      die "report is inside the Desktop worktree and would be deleted by archive: $report_real"
      ;;
  esac

  printf 'archive-safe: %s scout report retained at %s\n' "$id" "$report_real"
}

[ "$#" -ge 2 ] || usage
COMMAND=$1
ID=$2
shift 2
case "$COMMAND" in
  register) register_task "$ID" "$@" ;;
  reconcile) reconcile_task "$ID" "$@" ;;
  hard-stop) hard_stop_task "$ID" "$@" ;;
  resume) resume_task "$ID" "$@" ;;
  archive-preflight) archive_preflight_task "$ID" "$@" ;;
  *) usage ;;
esac
