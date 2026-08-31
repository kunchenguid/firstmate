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
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-task-model-route-lib.sh
. "$SCRIPT_DIR/fm-task-model-route-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  fm-codex-app-task.sh register <id> --thread <uuid> --host <host-id>
      --project <checkout> --worktree <desktop-worktree> --kind <kind>
      --model <model> --effort <effort> --route-record <path>
      --session-envelope <small|normal|research>
      --mode <direct-PR|local-only> --yolo <on|off>
  fm-codex-app-task.sh reconcile <id> --thread <uuid> --host <host-id>
      --generation <number> --state <state> [--detail <text>]
      [--event <status-line>]
  fm-codex-app-task.sh hard-stop <id> --reason <text> --handoff <external-path>
  fm-codex-app-task.sh resume <id> --thread <uuid> --host <host-id>
      --checkpoint <sha> --handoff <external-path>
  fm-codex-app-task.sh archive-preflight <id> [--report <firstmate-home>/data/<id>/report.md]

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
  fm_task_id_creation_valid "$1"
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

TASK_MUTATION_LOCK=
TASK_MUTATION_OWNER=
TASK_META_LOCK=
TASK_META_LOCK_HELD=0
TASK_MUTATION_RECORD_PID=
TASK_MUTATION_RECORD_IDENTITY=
task_mutation_lock_record_parse() {
  local record=$1 kind pid identity extra
  IFS=: read -r kind pid identity extra <<EOF
$record
EOF
  [ "$kind" = codex-app-mutation ] && [ -z "$extra" ] || return 1
  case "$pid" in ''|*[!0-9]*|0|1|0*) return 1 ;; esac
  [[ "$identity" =~ ^[0-9a-f]{64}$ ]] || return 1
  [ "$record" = "codex-app-mutation:$pid:$identity" ] || return 1
  TASK_MUTATION_RECORD_PID=$pid
  TASK_MUTATION_RECORD_IDENTITY=$identity
}

task_mutation_lock_release() {
  [ -n "$TASK_MUTATION_LOCK" ] || return 0
  if [ "$(cat "$TASK_MUTATION_LOCK/owner" 2>/dev/null || true)" = "$TASK_MUTATION_OWNER" ]; then
    rm -f -- "$TASK_MUTATION_LOCK/owner"
    rmdir -- "$TASK_MUTATION_LOCK" 2>/dev/null || true
  fi
  TASK_MUTATION_LOCK=
  TASK_MUTATION_OWNER=
}

task_metadata_lock_release() {
  if [ "$TASK_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$TASK_META_LOCK" || true
    TASK_META_LOCK_HELD=0
  fi
  TASK_META_LOCK=
}

task_mutation_cleanup() {
  task_metadata_lock_release
  task_mutation_lock_release
}

task_metadata_lock_acquire() {  # <task-id>
  local id=$1
  TASK_META_LOCK=$(fm_meta_lock_path "$STATE/$id.meta") \
    || die "cannot resolve task $id metadata lock"
  fm_lock_acquire_wait "$TASK_META_LOCK" \
    || die "cannot acquire task $id metadata lock"
  TASK_META_LOCK_HELD=1
}

task_mutation_recovery_die() {  # <recovery-lock> <message>
  local recovery_lock=$1 message=$2
  fm_lock_release "$recovery_lock" || true
  die "$message"
}

task_mutation_lock_acquire() {  # <task-id>
  local id=$1 lock owner identity self_record mtime age recovery_lock
  lock="$STATE/.$id.codex-app-mutation-lock"
  recovery_lock="$STATE/.$id.codex-app-mutation-recovery.lock"
  identity=$(fm_process_command_identity "$$" fm-codex-app-task.sh) \
    || die "cannot establish task $id mutation process identity"
  self_record="codex-app-mutation:$$:$identity"
  while ! mkdir -- "$lock" 2>/dev/null; do
    fm_lock_acquire_wait "$recovery_lock" \
      || die "cannot acquire task $id mutation recovery ownership"
    if mkdir -- "$lock" 2>/dev/null; then
      fm_lock_release "$recovery_lock" || true
      break
    fi
    owner=$(cat "$lock/owner" 2>/dev/null || true)
    if [ -z "$owner" ] && [ -d "$lock" ] && [ ! -L "$lock" ] \
      && [ ! -e "$lock/owner" ]; then
      mtime=$(fm_path_mtime "$lock") \
        || task_mutation_recovery_die "$recovery_lock" \
          "task $id mutation lock is invalid; refusing concurrent mutation"
      age=$(($(date +%s) - mtime))
      [ "$age" -ge 0 ] || age=0
      [ "$age" -ge 5 ] \
        || task_mutation_recovery_die "$recovery_lock" \
          "task $id mutation lock initialization is incomplete; retry after five seconds"
      rmdir -- "$lock" 2>/dev/null \
        || task_mutation_recovery_die "$recovery_lock" \
          "task $id mutation ownership changed while recovering an incomplete lock"
    else
      task_mutation_lock_record_parse "$owner" \
        || task_mutation_recovery_die "$recovery_lock" \
          "task $id mutation lock is invalid; refusing concurrent mutation"
      if [ "$(fm_process_command_identity "$TASK_MUTATION_RECORD_PID" \
        fm-codex-app-task.sh 2>/dev/null || true)" = "$TASK_MUTATION_RECORD_IDENTITY" ]; then
        task_mutation_recovery_die "$recovery_lock" \
          "task $id is already being mutated by process $TASK_MUTATION_RECORD_PID"
      fi
      rm -f -- "$lock/owner" 2>/dev/null || true
      rmdir -- "$lock" 2>/dev/null \
        || task_mutation_recovery_die "$recovery_lock" \
          "task $id mutation ownership changed while recovering a stale lock"
    fi
    if mkdir -- "$lock" 2>/dev/null; then
      fm_lock_release "$recovery_lock" || true
      break
    fi
    fm_lock_release "$recovery_lock" || true
  done
  printf '%s\n' "$self_record" > "$lock/owner" || {
    rm -f -- "$lock/owner" 2>/dev/null || true
    rmdir -- "$lock" 2>/dev/null || true
    die "cannot record task $id mutation ownership"
  }
  chmod 0600 "$lock/owner" || {
    rm -f -- "$lock/owner" 2>/dev/null || true
    rmdir -- "$lock" 2>/dev/null || true
    die "cannot protect task $id mutation ownership"
  }
  TASK_MUTATION_LOCK=$lock
  TASK_MUTATION_OWNER=$self_record
  trap task_mutation_cleanup EXIT
  trap 'task_mutation_cleanup; exit 129' HUP
  trap 'task_mutation_cleanup; exit 130' INT
  trap 'task_mutation_cleanup; exit 143' TERM
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

desktop_transition_request_hash() {
  local digest value
  if command -v shasum >/dev/null 2>&1; then
    digest=$(
      for value in "$@"; do printf '%s\0' "$value"; done \
        | env -u LC_CTYPE LC_ALL=C LANG=C shasum -a 256 2>/dev/null \
        | awk '{print $1}'
    )
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(
      for value in "$@"; do printf '%s\0' "$value"; done \
        | env -u LC_CTYPE LC_ALL=C LANG=C sha256sum 2>/dev/null \
        | awk '{print $1}'
    )
  else
    return 1
  fi
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

DESKTOP_TRANSITION_OPERATION=
DESKTOP_TRANSITION_REQUEST=
DESKTOP_TRANSITION_META_PREIMAGE=
DESKTOP_TRANSITION_META_HASH=
DESKTOP_TRANSITION_CURRENT_PREIMAGE=
DESKTOP_TRANSITION_CURRENT_HASH=
DESKTOP_TRANSITION_STATUS_PREIMAGE=
DESKTOP_TRANSITION_STATUS_HASH=
DESKTOP_TRANSITION_RECEIPT_PREIMAGE=
DESKTOP_TRANSITION_RECEIPT_HASH=
desktop_transition_journal_parse() {
  local journal=$1 key lines value
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  lines=$(wc -l < "$journal" | tr -d ' ')
  [ "$lines" = 11 ] || return 1
  [ "$(exact_meta_value "$journal" version)" = 2 ] || return 1
  for key in operation request_sha256 meta_preimage_sha256 meta_sha256 \
    current_preimage_sha256 current_sha256 status_preimage_sha256 status_sha256 \
    receipt_preimage_sha256 receipt_sha256; do
    value=$(exact_meta_value "$journal" "$key") || return 1
    case "$key" in
      operation) case "$value" in register|resume) ;; *) return 1 ;; esac ;;
      *_preimage_sha256)
        [ "$value" = none ] || [ "$value" = absent ] \
          || [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
        ;;
      status_sha256|receipt_sha256)
        [ "$value" = none ] || [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
        ;;
      *) [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1 ;;
    esac
  done
  DESKTOP_TRANSITION_OPERATION=$(exact_meta_value "$journal" operation)
  DESKTOP_TRANSITION_REQUEST=$(exact_meta_value "$journal" request_sha256)
  DESKTOP_TRANSITION_META_PREIMAGE=$(exact_meta_value "$journal" meta_preimage_sha256)
  DESKTOP_TRANSITION_META_HASH=$(exact_meta_value "$journal" meta_sha256)
  DESKTOP_TRANSITION_CURRENT_PREIMAGE=$(exact_meta_value "$journal" current_preimage_sha256)
  DESKTOP_TRANSITION_CURRENT_HASH=$(exact_meta_value "$journal" current_sha256)
  DESKTOP_TRANSITION_STATUS_PREIMAGE=$(exact_meta_value "$journal" status_preimage_sha256)
  DESKTOP_TRANSITION_STATUS_HASH=$(exact_meta_value "$journal" status_sha256)
  DESKTOP_TRANSITION_RECEIPT_PREIMAGE=$(exact_meta_value "$journal" receipt_preimage_sha256)
  DESKTOP_TRANSITION_RECEIPT_HASH=$(exact_meta_value "$journal" receipt_sha256)
}

desktop_transition_file_matches() {  # <path> <sha256>
  local actual
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  actual=$(fm_task_route_sha256 "$1") || return 1
  [ "$actual" = "$2" ]
}

desktop_transition_snapshot() {  # <path>
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then
    printf 'absent\n'
    return 0
  fi
  fm_task_route_sha256 "$1"
}

desktop_transition_publish_file() {  # <task-id> <staged> <destination> <preimage> <sha256>
  local id=$1 staged=$2 destination=$3 preimage=$4 expected_hash=$5 tmp
  if desktop_transition_file_matches "$destination" "$expected_hash"; then
    return 0
  fi
  case "$preimage" in
    absent) [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1 ;;
    *) desktop_transition_file_matches "$destination" "$preimage" || return 1 ;;
  esac
  tmp=$(umask 077; mktemp "$STATE/.$id.codex-app-publish.XXXXXX") || return 1
  cp -- "$staged" "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$destination" || { rm -f -- "$tmp"; return 1; }
}

desktop_transition_resume_current_supersedes() {  # <staged-current> <current>
  local staged=$1 current=$2 state
  [ -f "$current" ] && [ ! -L "$current" ] || return 1
  [ "$(exact_meta_value "$current" thread_id)" = "$(exact_meta_value "$staged" thread_id)" ] \
    && [ "$(exact_meta_value "$current" host_id)" = "$(exact_meta_value "$staged" host_id)" ] \
    || return 1
  state=$(exact_meta_value "$current" state) || return 1
  valid_state "$state"
}

desktop_transition_finish() {  # <task-id> <operation> <request-sha256>
  local id=$1 operation=$2 request_hash=$3 journal meta_stage current_stage status_stage
  local receipt_stage meta current status receipt
  journal="$STATE/$id.codex-app-transition"
  meta_stage="$STATE/.$id.codex-app-transition.meta"
  current_stage="$STATE/.$id.codex-app-transition.current"
  status_stage="$STATE/.$id.codex-app-transition.status"
  receipt_stage="$STATE/.$id.codex-app-transition.resume-receipt"
  meta="$STATE/$id.meta"
  current="$STATE/$id.codex-app-current"
  status="$STATE/$id.status"
  receipt="$STATE/$id.codex-app-resume-receipt"
  desktop_transition_journal_parse "$journal" || return 1
  [ "$DESKTOP_TRANSITION_OPERATION" = "$operation" ] \
    && [ "$DESKTOP_TRANSITION_REQUEST" = "$request_hash" ] || return 1
  desktop_transition_file_matches "$meta_stage" "$DESKTOP_TRANSITION_META_HASH" \
    && desktop_transition_file_matches "$current_stage" "$DESKTOP_TRANSITION_CURRENT_HASH" \
    || return 1
  if [ "$DESKTOP_TRANSITION_STATUS_HASH" != none ]; then
    desktop_transition_file_matches "$status_stage" "$DESKTOP_TRANSITION_STATUS_HASH" \
      || return 1
  fi
  if [ "$DESKTOP_TRANSITION_RECEIPT_HASH" != none ]; then
    desktop_transition_file_matches "$receipt_stage" "$DESKTOP_TRANSITION_RECEIPT_HASH" \
      || return 1
  fi
  desktop_transition_publish_file "$id" "$meta_stage" "$meta" \
    "$DESKTOP_TRANSITION_META_PREIMAGE" "$DESKTOP_TRANSITION_META_HASH" || return 1
  if ! desktop_transition_file_matches "$current" "$DESKTOP_TRANSITION_CURRENT_HASH"; then
    if [ "$operation" = resume ] \
      && ! desktop_transition_file_matches "$current" "$DESKTOP_TRANSITION_CURRENT_PREIMAGE" \
      && desktop_transition_resume_current_supersedes "$current_stage" "$current"; then
      :
    else
      desktop_transition_publish_file "$id" "$current_stage" "$current" \
        "$DESKTOP_TRANSITION_CURRENT_PREIMAGE" "$DESKTOP_TRANSITION_CURRENT_HASH" || return 1
    fi
  fi
  if [ "$DESKTOP_TRANSITION_STATUS_HASH" != none ]; then
    desktop_transition_publish_file "$id" "$status_stage" "$status" \
      "$DESKTOP_TRANSITION_STATUS_PREIMAGE" "$DESKTOP_TRANSITION_STATUS_HASH" || return 1
  fi
  if [ "$DESKTOP_TRANSITION_RECEIPT_HASH" != none ]; then
    desktop_transition_publish_file "$id" "$receipt_stage" "$receipt" \
      "$DESKTOP_TRANSITION_RECEIPT_PREIMAGE" "$DESKTOP_TRANSITION_RECEIPT_HASH" || return 1
  fi
  rm -f -- "$journal" "$meta_stage" "$current_stage" "$status_stage" \
    "$receipt_stage" || return 1
}

desktop_transition_begin() {  # <task-id> <operation> <request-sha256> <meta> <current> [status] [receipt]
  local id=$1 operation=$2 request_hash=$3 meta_source=$4 current_source=$5
  local status_source=${6:-} receipt_source=${7:-}
  local journal meta_stage current_stage status_stage receipt_stage
  local meta_preimage current_preimage status_preimage=none receipt_preimage=none
  local meta_hash current_hash status_hash=none receipt_hash=none journal_tmp
  journal="$STATE/$id.codex-app-transition"
  meta_stage="$STATE/.$id.codex-app-transition.meta"
  current_stage="$STATE/.$id.codex-app-transition.current"
  status_stage="$STATE/.$id.codex-app-transition.status"
  receipt_stage="$STATE/.$id.codex-app-transition.resume-receipt"
  [ ! -e "$journal" ] || return 1
  meta_preimage=$(desktop_transition_snapshot "$STATE/$id.meta") || return 1
  current_preimage=$(desktop_transition_snapshot "$STATE/$id.codex-app-current") || return 1
  if [ -n "$status_source" ]; then
    status_preimage=$(desktop_transition_snapshot "$STATE/$id.status") || return 1
  fi
  if [ -n "$receipt_source" ]; then
    receipt_preimage=$(desktop_transition_snapshot "$STATE/$id.codex-app-resume-receipt") || return 1
  fi
  rm -f -- "$meta_stage" "$current_stage" "$status_stage" "$receipt_stage" || return 1
  mv -f -- "$meta_source" "$meta_stage" || return 1
  mv -f -- "$current_source" "$current_stage" || return 1
  if [ -n "$status_source" ]; then
    mv -f -- "$status_source" "$status_stage" || return 1
  fi
  if [ -n "$receipt_source" ]; then
    mv -f -- "$receipt_source" "$receipt_stage" || return 1
  fi
  meta_hash=$(fm_task_route_sha256 "$meta_stage") || return 1
  current_hash=$(fm_task_route_sha256 "$current_stage") || return 1
  if [ -n "$status_source" ]; then
    status_hash=$(fm_task_route_sha256 "$status_stage") || return 1
  fi
  if [ -n "$receipt_source" ]; then
    receipt_hash=$(fm_task_route_sha256 "$receipt_stage") || return 1
  fi
  journal_tmp=$(umask 077; mktemp "$STATE/.$id.codex-app-transition.XXXXXX") || return 1
  {
    printf 'version=2\n'
    printf 'operation=%s\n' "$operation"
    printf 'request_sha256=%s\n' "$request_hash"
    printf 'meta_preimage_sha256=%s\n' "$meta_preimage"
    printf 'meta_sha256=%s\n' "$meta_hash"
    printf 'current_preimage_sha256=%s\n' "$current_preimage"
    printf 'current_sha256=%s\n' "$current_hash"
    printf 'status_preimage_sha256=%s\n' "$status_preimage"
    printf 'status_sha256=%s\n' "$status_hash"
    printf 'receipt_preimage_sha256=%s\n' "$receipt_preimage"
    printf 'receipt_sha256=%s\n' "$receipt_hash"
  } > "$journal_tmp" || { rm -f -- "$journal_tmp"; return 1; }
  mv -f -- "$journal_tmp" "$journal" || { rm -f -- "$journal_tmp"; return 1; }
  desktop_transition_finish "$id" "$operation" "$request_hash"
}

register_task() {
  local id=$1
  shift
  local thread='' host='' project='' worktree='' kind='' model='' effort='' mode='' yolo=''
  local route_record='' envelope=''
  local project_real worktree_real git_common_dir route_real route_hash
  local meta current status meta_tmp status_tmp current_tmp request_hash journal
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
  task_mutation_lock_acquire "$id"
  task_metadata_lock_acquire "$id"
  meta="$STATE/$id.meta"
  status="$STATE/$id.status"
  current="$STATE/$id.codex-app-current"
  journal="$STATE/$id.codex-app-transition"
  request_hash=$(desktop_transition_request_hash register "$id" "$thread" "$host" \
    "$project_real" "$worktree_real" "$git_common_dir" "$kind" "$model" "$effort" \
    "$route_real" "$route_hash" "$envelope" "$mode" "$yolo") \
    || die "cannot bind Desktop registration request for $id"
  task_mutation_recovery_owner "$id" register "$request_hash"
  if [ -e "$journal" ]; then
    desktop_transition_finish "$id" register "$request_hash" \
      || die "cannot recover the journaled Desktop registration for $id"
    printf 'registered: %s -> Codex Desktop task %s (host=%s worktree=%s)\n' \
      "$id" "$thread" "$host" "$worktree_real"
    return 0
  fi
  if [ -f "$meta" ] && [ ! -L "$meta" ] \
    && [ -f "$status" ] && [ ! -L "$status" ] \
    && [ -f "$current" ] && [ ! -L "$current" ] \
    && [ "$(exact_meta_value "$meta" endpoint_task_id)" = "$id" ] \
    && [ "$(exact_meta_value "$meta" codex_app_thread_id)" = "$thread" ] \
    && [ "$(exact_meta_value "$meta" codex_app_host_id)" = "$host" ] \
    && [ "$(exact_meta_value "$meta" project)" = "$project_real" ] \
    && [ "$(exact_meta_value "$meta" worktree)" = "$worktree_real" ] \
    && [ "$(exact_meta_value "$meta" git_common_dir)" = "$git_common_dir" ] \
    && [ "$(exact_meta_value "$meta" kind)" = "$kind" ] \
    && [ "$(exact_meta_value "$meta" model)" = "$model" ] \
    && [ "$(exact_meta_value "$meta" effort)" = "$effort" ] \
    && [ "$(exact_meta_value "$meta" model_route_record)" = "$route_real" ] \
    && [ "$(exact_meta_value "$meta" model_route_sha256)" = "$route_hash" ] \
    && [ "$(exact_meta_value "$meta" session_envelope)" = "$envelope" ] \
    && [ "$(exact_meta_value "$meta" session_generation)" = 1 ] \
    && [ "$(exact_meta_value "$meta" mode)" = "$mode" ] \
    && [ "$(exact_meta_value "$meta" yolo)" = "$yolo" ] \
    && [ "$(exact_meta_value "$current" thread_id)" = "$thread" ] \
    && [ "$(exact_meta_value "$current" host_id)" = "$host" ] \
    && [ "$(exact_meta_value "$current" state)" = working ]; then
    printf 'registered: %s -> Codex Desktop task %s (host=%s worktree=%s)\n' \
      "$id" "$thread" "$host" "$worktree_real"
    return 0
  fi
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

  desktop_transition_begin "$id" register "$request_hash" \
    "$meta_tmp" "$current_tmp" "$status_tmp" \
    || die "cannot publish journaled durable task state for $id; retry the exact registration"
  printf 'registered: %s -> Codex Desktop task %s (host=%s worktree=%s)\n' \
    "$id" "$thread" "$host" "$worktree_real"
}

reconcile_task() {
  local id=$1
  shift
  local current_state='' detail='' event='' observed_thread='' observed_host=''
  local observed_generation='' meta thread host generation
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --thread) [ "$#" -ge 2 ] || usage; observed_thread=$2; shift 2 ;;
      --host) [ "$#" -ge 2 ] || usage; observed_host=$2; shift 2 ;;
      --generation) [ "$#" -ge 2 ] || usage; observed_generation=$2; shift 2 ;;
      --state) [ "$#" -ge 2 ] || usage; current_state=$2; shift 2 ;;
      --detail) [ "$#" -ge 2 ] || usage; detail=$2; shift 2 ;;
      --event) [ "$#" -ge 2 ] || usage; event=$2; shift 2 ;;
      *) die_usage "unknown reconcile argument '$1'" ;;
    esac
  done

  valid_id "$id" || die_usage "invalid task id '$id'"
  valid_thread "$observed_thread" \
    || die_usage "invalid observed Codex Desktop thread id '$observed_thread'"
  valid_atom "$observed_host" \
    || die_usage "invalid observed Codex Desktop host id '$observed_host'"
  case "$observed_generation" in
    ''|*[!0-9]*|0|0*) die_usage "invalid observed session generation '$observed_generation'" ;;
  esac
  valid_state "$current_state" \
    || die_usage "invalid current state '$current_state'"
  valid_scalar "$detail" || die_usage "current-state detail must be a single-line value"
  valid_scalar "$event" || die_usage "status event must be a single-line value"
  case "$event" in
    ''|working:*|needs-decision:*|blocked:*|paused:*|done:*|failed:*) ;;
    *) die_usage "invalid status event '$event'" ;;
  esac
  require_owner
  task_mutation_lock_acquire "$id"
  task_metadata_lock_acquire "$id"
  task_mutation_recovery_owner "$id" reconcile none
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
  generation=$(exact_meta_value "$meta" session_generation) \
    || die "task $id has no exact Desktop generation binding"
  [ "$thread" = "$observed_thread" ] && [ "$host" = "$observed_host" ] \
    && [ "$generation" = "$observed_generation" ] \
    || die "task $id observed Desktop endpoint does not match its current thread, host, and generation binding"
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
HARD_STOP_REQUEST=
HARD_STOP_META_PREIMAGE=
HARD_STOP_CURRENT_PREIMAGE=
HARD_STOP_CHECKPOINT=
HARD_STOP_META_HASH=
HARD_STOP_CURRENT_HASH=
hard_stop_journal_parse() {  # <journal>
  local journal=$1 key lines value
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  lines=$(wc -l < "$journal" | tr -d ' ')
  [ "$lines" = 16 ] || return 1
  [ "$(exact_meta_value "$journal" version)" = 2 ] || return 1
  for key in request_sha256 pre_head index_tree reason handoff thread host envelope \
    generation worktree meta_preimage_sha256 current_preimage_sha256 checkpoint \
    meta_sha256 current_sha256; do
    value=$(exact_meta_value "$journal" "$key") || return 1
    valid_scalar "$value" || return 1
  done
  HARD_STOP_REQUEST=$(exact_meta_value "$journal" request_sha256)
  HARD_STOP_PRE_HEAD=$(exact_meta_value "$journal" pre_head)
  HARD_STOP_INDEX_TREE=$(exact_meta_value "$journal" index_tree)
  HARD_STOP_REASON=$(exact_meta_value "$journal" reason)
  HARD_STOP_HANDOFF=$(exact_meta_value "$journal" handoff)
  HARD_STOP_THREAD=$(exact_meta_value "$journal" thread)
  HARD_STOP_HOST=$(exact_meta_value "$journal" host)
  HARD_STOP_ENVELOPE=$(exact_meta_value "$journal" envelope)
  HARD_STOP_GENERATION=$(exact_meta_value "$journal" generation)
  HARD_STOP_WORKTREE=$(exact_meta_value "$journal" worktree)
  HARD_STOP_META_PREIMAGE=$(exact_meta_value "$journal" meta_preimage_sha256)
  HARD_STOP_CURRENT_PREIMAGE=$(exact_meta_value "$journal" current_preimage_sha256)
  HARD_STOP_CHECKPOINT=$(exact_meta_value "$journal" checkpoint)
  HARD_STOP_META_HASH=$(exact_meta_value "$journal" meta_sha256)
  HARD_STOP_CURRENT_HASH=$(exact_meta_value "$journal" current_sha256)
  [[ "$HARD_STOP_REQUEST" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$HARD_STOP_PRE_HEAD" | grep -Eq '^[0-9a-f]{40,64}$' || return 1
  printf '%s' "$HARD_STOP_INDEX_TREE" | grep -Eq '^[0-9a-f]{40,64}$' || return 1
  [[ "$HARD_STOP_META_PREIMAGE" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$HARD_STOP_CURRENT_PREIMAGE" =~ ^[0-9a-f]{64}$ ]] || return 1
  valid_thread "$HARD_STOP_THREAD" && valid_atom "$HARD_STOP_HOST" \
    && valid_envelope "$HARD_STOP_ENVELOPE" || return 1
  [ -n "$HARD_STOP_REASON" ] && [ -n "$HARD_STOP_HANDOFF" ] \
    && [ -n "$HARD_STOP_WORKTREE" ] || return 1
  case "$HARD_STOP_GENERATION" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$HARD_STOP_CHECKPOINT" = none ]; then
    [ "$HARD_STOP_META_HASH" = none ] && [ "$HARD_STOP_CURRENT_HASH" = none ] \
      || return 1
  else
    printf '%s' "$HARD_STOP_CHECKPOINT" | grep -Eq '^[0-9a-f]{40,64}$' || return 1
    [[ "$HARD_STOP_META_HASH" =~ ^[0-9a-f]{64}$ ]] \
      && [[ "$HARD_STOP_CURRENT_HASH" =~ ^[0-9a-f]{64}$ ]] || return 1
  fi
}

hard_stop_journal_write() {  # <journal>
  local journal=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.hard-stop-journal.XXXXXX") || return 1
  {
    printf 'version=2\n'
    printf 'request_sha256=%s\n' "$HARD_STOP_REQUEST"
    printf 'pre_head=%s\n' "$HARD_STOP_PRE_HEAD"
    printf 'index_tree=%s\n' "$HARD_STOP_INDEX_TREE"
    printf 'reason=%s\n' "$HARD_STOP_REASON"
    printf 'handoff=%s\n' "$HARD_STOP_HANDOFF"
    printf 'thread=%s\n' "$HARD_STOP_THREAD"
    printf 'host=%s\n' "$HARD_STOP_HOST"
    printf 'envelope=%s\n' "$HARD_STOP_ENVELOPE"
    printf 'generation=%s\n' "$HARD_STOP_GENERATION"
    printf 'worktree=%s\n' "$HARD_STOP_WORKTREE"
    printf 'meta_preimage_sha256=%s\n' "$HARD_STOP_META_PREIMAGE"
    printf 'current_preimage_sha256=%s\n' "$HARD_STOP_CURRENT_PREIMAGE"
    printf 'checkpoint=%s\n' "$HARD_STOP_CHECKPOINT"
    printf 'meta_sha256=%s\n' "$HARD_STOP_META_HASH"
    printf 'current_sha256=%s\n' "$HARD_STOP_CURRENT_HASH"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$journal" || { rm -f -- "$tmp"; return 1; }
}

HARD_STOP_RECEIPT_REQUEST=
HARD_STOP_RECEIPT_CHECKPOINT=
HARD_STOP_RECEIPT_HANDOFF=
HARD_STOP_RECEIPT_THREAD=
HARD_STOP_RECEIPT_HOST=
HARD_STOP_RECEIPT_GENERATION=
HARD_STOP_RECEIPT_WORKTREE=
hard_stop_receipt_parse() {  # <receipt>
  local receipt=$1 lines key value
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  lines=$(wc -l < "$receipt" | tr -d ' ')
  [ "$lines" = 8 ] || return 1
  [ "$(exact_meta_value "$receipt" version)" = 1 ] || return 1
  for key in request_sha256 checkpoint handoff thread host generation worktree; do
    value=$(exact_meta_value "$receipt" "$key") || return 1
    valid_scalar "$value" || return 1
  done
  HARD_STOP_RECEIPT_REQUEST=$(exact_meta_value "$receipt" request_sha256)
  HARD_STOP_RECEIPT_CHECKPOINT=$(exact_meta_value "$receipt" checkpoint)
  HARD_STOP_RECEIPT_HANDOFF=$(exact_meta_value "$receipt" handoff)
  HARD_STOP_RECEIPT_THREAD=$(exact_meta_value "$receipt" thread)
  HARD_STOP_RECEIPT_HOST=$(exact_meta_value "$receipt" host)
  HARD_STOP_RECEIPT_GENERATION=$(exact_meta_value "$receipt" generation)
  HARD_STOP_RECEIPT_WORKTREE=$(exact_meta_value "$receipt" worktree)
  [[ "$HARD_STOP_RECEIPT_REQUEST" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$HARD_STOP_RECEIPT_CHECKPOINT" | grep -Eq '^[0-9a-f]{40,64}$' \
    || return 1
  valid_thread "$HARD_STOP_RECEIPT_THREAD" \
    && valid_atom "$HARD_STOP_RECEIPT_HOST" || return 1
  case "$HARD_STOP_RECEIPT_GENERATION" in ''|*[!0-9]*|0|0*) return 1 ;; esac
  [ -n "$HARD_STOP_RECEIPT_HANDOFF" ] && [ -n "$HARD_STOP_RECEIPT_WORKTREE" ]
}

hard_stop_receipt_matches() {  # <receipt> <request> <handoff> <meta> <current> <worktree>
  local receipt=$1 request_hash=$2 handoff=$3 meta=$4 current=$5 worktree=$6
  hard_stop_receipt_parse "$receipt" || return 1
  [ "$HARD_STOP_RECEIPT_REQUEST" = "$request_hash" ] \
    && [ "$HARD_STOP_RECEIPT_HANDOFF" = "$handoff" ] \
    && [ "$HARD_STOP_RECEIPT_WORKTREE" = "$worktree" ] \
    && [ "$(exact_meta_value "$meta" session_checkpoint)" = \
      "$HARD_STOP_RECEIPT_CHECKPOINT" ] \
    && [ "$(exact_meta_value "$meta" session_handoff)" = "$handoff" ] \
    && [ "$(exact_meta_value "$meta" codex_app_thread_id)" = \
      "$HARD_STOP_RECEIPT_THREAD" ] \
    && [ "$(exact_meta_value "$meta" codex_app_host_id)" = \
      "$HARD_STOP_RECEIPT_HOST" ] \
    && [ "$(exact_meta_value "$meta" session_generation)" = \
      "$HARD_STOP_RECEIPT_GENERATION" ] \
    && [ "$(exact_meta_value "$current" thread_id)" = \
      "$HARD_STOP_RECEIPT_THREAD" ] \
    && [ "$(exact_meta_value "$current" host_id)" = \
      "$HARD_STOP_RECEIPT_HOST" ] \
    && [ "$(exact_meta_value "$current" state)" = paused ] \
    && [ "$(git -C "$HARD_STOP_RECEIPT_WORKTREE" rev-parse HEAD 2>/dev/null)" = \
      "$HARD_STOP_RECEIPT_CHECKPOINT" ] \
    && [ -f "$handoff" ] && [ ! -L "$handoff" ] \
    && grep -qx "checkpoint_sha: $HARD_STOP_RECEIPT_CHECKPOINT" "$handoff" \
    && grep -qx "previous_thread_id: $HARD_STOP_RECEIPT_THREAD" "$handoff" \
    && grep -qx "previous_host_id: $HARD_STOP_RECEIPT_HOST" "$handoff"
}

hard_stop_receipt_write() {  # <receipt> <request> <checkpoint> <handoff> <thread> <host> <generation> <worktree>
  local receipt=$1 request_hash=$2 checkpoint=$3 handoff=$4 thread=$5 host=$6
  local generation=$7 worktree=$8 tmp
  tmp=$(umask 077; mktemp "$STATE/.hard-stop-receipt.XXXXXX") || return 1
  {
    printf 'version=1\n'
    printf 'request_sha256=%s\n' "$request_hash"
    printf 'checkpoint=%s\n' "$checkpoint"
    printf 'handoff=%s\n' "$handoff"
    printf 'thread=%s\n' "$thread"
    printf 'host=%s\n' "$host"
    printf 'generation=%s\n' "$generation"
    printf 'worktree=%s\n' "$worktree"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$receipt" || { rm -f -- "$tmp"; return 1; }
}

task_mutation_recovery_owner() {  # <task-id> <operation> <request-sha256-or-none>
  local id=$1 operation=$2 request_hash=$3 transition hard_stop
  transition="$STATE/$id.codex-app-transition"
  hard_stop="$STATE/$id.hard-stop-journal"
  if { [ -e "$transition" ] || [ -L "$transition" ]; } \
    && { [ -e "$hard_stop" ] || [ -L "$hard_stop" ]; }; then
    die "task $id has conflicting mutation recovery journals"
  fi
  if [ -e "$transition" ] || [ -L "$transition" ]; then
    desktop_transition_journal_parse "$transition" \
      || die "task $id has an invalid Desktop transition recovery journal"
    if [ "$operation" != "$DESKTOP_TRANSITION_OPERATION" ] \
      || [ "$request_hash" != "$DESKTOP_TRANSITION_REQUEST" ]; then
      die "task $id has an interrupted $DESKTOP_TRANSITION_OPERATION mutation; retry that exact mutation before $operation"
    fi
  elif [ -e "$hard_stop" ] || [ -L "$hard_stop" ]; then
    hard_stop_journal_parse "$hard_stop" \
      || die "task $id has an invalid hard-stop recovery journal"
    [ "$operation" = hard-stop ] \
      || die "task $id has an interrupted hard-stop mutation; retry that exact mutation before $operation"
  fi
}

hard_stop_task() {
  local id=$1
  shift
  local reason='' handoff='' meta current worktree_real handoff_parent handoff_real journal receipt
  local thread host envelope generation checkpoint tmp pre_head index_tree head parent commit_tree subject
  local request_hash meta_preimage current_preimage hard_meta_stage hard_current_stage
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
  task_mutation_lock_acquire "$id"
  task_metadata_lock_acquire "$id"
  task_mutation_recovery_owner "$id" hard-stop none
  meta="$STATE/$id.meta"
  current="$STATE/$id.codex-app-current"
  [ -f "$meta" ] || die "no metadata for Desktop task $id"
  [ -f "$current" ] || die "no current state for Desktop task $id"
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
  receipt="$STATE/$id.codex-app-hard-stop-receipt"
  hard_meta_stage="$STATE/.$id.hard-stop.meta"
  hard_current_stage="$STATE/.$id.hard-stop.current"
  request_hash=$(desktop_transition_request_hash hard-stop "$id" "$reason" \
    "$handoff_real" "$thread" "$host" "$envelope" "$generation" "$worktree_real") \
    || die "cannot bind Desktop hard-stop request for $id"
  if [ ! -e "$journal" ] && [ ! -L "$journal" ] \
    && { [ -e "$receipt" ] || [ -L "$receipt" ]; }; then
    hard_stop_receipt_parse "$receipt" \
      || die "task $id has an invalid hard-stop completion receipt"
    if [ "$HARD_STOP_RECEIPT_REQUEST" = "$request_hash" ]; then
      hard_stop_receipt_matches "$receipt" "$request_hash" "$handoff_real" \
        "$meta" "$current" "$worktree_real" \
        || die "task $id hard-stop completion receipt no longer matches the completed transition"
      printf 'hard-stop: %s checkpoint=%s handoff=%s\n' \
        "$id" "$HARD_STOP_RECEIPT_CHECKPOINT" "$handoff_real"
      return 0
    fi
  fi
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    hard_stop_journal_parse "$journal" \
      || die "task $id has an invalid hard-stop recovery journal"
    [ "$HARD_STOP_REQUEST" = "$request_hash" ] \
      && [ "$HARD_STOP_REASON" = "$reason" ] && [ "$HARD_STOP_HANDOFF" = "$handoff_real" ] \
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
    meta_preimage=$(desktop_transition_snapshot "$meta") \
      || die "cannot record hard-stop metadata preimage for $id"
    current_preimage=$(desktop_transition_snapshot "$current") \
      || die "cannot record hard-stop current-state preimage for $id"
    [[ "$meta_preimage" =~ ^[0-9a-f]{64}$ ]] \
      && [[ "$current_preimage" =~ ^[0-9a-f]{64}$ ]] \
      || die "cannot bind hard-stop task preimages for $id"
    rm -f -- "$hard_meta_stage" "$hard_current_stage" \
      || die "cannot clear stale hard-stop stages for $id"
    HARD_STOP_REQUEST=$request_hash
    HARD_STOP_PRE_HEAD=$pre_head
    HARD_STOP_INDEX_TREE=$index_tree
    HARD_STOP_REASON=$reason
    HARD_STOP_HANDOFF=$handoff_real
    HARD_STOP_THREAD=$thread
    HARD_STOP_HOST=$host
    HARD_STOP_ENVELOPE=$envelope
    HARD_STOP_GENERATION=$generation
    HARD_STOP_WORKTREE=$worktree_real
    HARD_STOP_META_PREIMAGE=$meta_preimage
    HARD_STOP_CURRENT_PREIMAGE=$current_preimage
    HARD_STOP_CHECKPOINT=none
    HARD_STOP_META_HASH=none
    HARD_STOP_CURRENT_HASH=none
    hard_stop_journal_write "$journal" \
      || die "cannot publish hard-stop recovery journal for $id"
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
  if [ "$HARD_STOP_CHECKPOINT" = none ]; then
    if ! desktop_transition_file_matches "$meta" "$HARD_STOP_META_PREIMAGE" \
      || ! desktop_transition_file_matches "$current" "$HARD_STOP_CURRENT_PREIMAGE"; then
      die "task $id changed after its hard-stop recovery journal was written"
    fi
    rm -f -- "$hard_meta_stage" "$hard_current_stage" \
      || die "cannot reset hard-stop publication stages for $id"
    tmp=$(umask 077; mktemp "$STATE/.$id.meta.XXXXXX") \
      || die "cannot stage checkpoint metadata for $id"
    grep -v -e '^session_checkpoint=' -e '^session_handoff=' "$meta" > "$tmp" || true
    {
      printf 'session_checkpoint=%s\n' "$checkpoint"
      printf 'session_handoff=%s\n' "$handoff_real"
    } >> "$tmp"
    mv -f -- "$tmp" "$hard_meta_stage" \
      || { rm -f -- "$tmp"; die "cannot retain staged checkpoint metadata for $id"; }
    tmp=$(umask 077; mktemp "$STATE/.$id.codex-app-current.XXXXXX") \
      || die "cannot stage checkpoint current state for $id"
    {
      printf 'thread_id=%s\n' "$thread"
      printf 'host_id=%s\n' "$host"
      printf 'state=paused\n'
      printf 'updated_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf 'detail=hard session boundary; checkpoint %s\n' "$checkpoint"
    } > "$tmp" || { rm -f -- "$tmp"; die "cannot write staged checkpoint current state for $id"; }
    mv -f -- "$tmp" "$hard_current_stage" \
      || { rm -f -- "$tmp"; die "cannot retain staged checkpoint current state for $id"; }
    HARD_STOP_CHECKPOINT=$checkpoint
    HARD_STOP_META_HASH=$(fm_task_route_sha256 "$hard_meta_stage") \
      || die "cannot bind staged checkpoint metadata for $id"
    HARD_STOP_CURRENT_HASH=$(fm_task_route_sha256 "$hard_current_stage") \
      || die "cannot bind staged checkpoint current state for $id"
    hard_stop_journal_write "$journal" \
      || die "cannot bind hard-stop publication stages for $id"
  else
    [ "$HARD_STOP_CHECKPOINT" = "$checkpoint" ] \
      || die "task $id checkpoint changed during hard-stop recovery"
  fi
  if ! desktop_transition_file_matches "$hard_meta_stage" "$HARD_STOP_META_HASH" \
    || ! desktop_transition_file_matches "$hard_current_stage" "$HARD_STOP_CURRENT_HASH"; then
    die "task $id hard-stop publication stages are incomplete"
  fi
  desktop_transition_publish_file "$id" "$hard_meta_stage" "$meta" \
    "$HARD_STOP_META_PREIMAGE" "$HARD_STOP_META_HASH" \
    || die "task $id metadata changed during hard-stop recovery; refusing to overwrite it"
  desktop_transition_publish_file "$id" "$hard_current_stage" "$current" \
    "$HARD_STOP_CURRENT_PREIMAGE" "$HARD_STOP_CURRENT_HASH" \
    || die "task $id current state changed during hard-stop recovery; refusing to overwrite it"
  hard_stop_receipt_write "$receipt" "$request_hash" "$checkpoint" "$handoff_real" \
    "$thread" "$host" "$generation" "$worktree_real" \
    || die "cannot publish hard-stop completion receipt for $id"
  rm -f -- "$journal" || die "cannot retire hard-stop recovery journal for $id"
  rm -f -- "$hard_meta_stage" "$hard_current_stage" \
    || die "cannot retire hard-stop publication stages for $id"
  printf 'hard-stop: %s checkpoint=%s handoff=%s\n' "$id" "$checkpoint" "$handoff_real"
}

DESKTOP_RESUME_RECEIPT_REQUEST=
DESKTOP_RESUME_RECEIPT_CHECKPOINT=
DESKTOP_RESUME_RECEIPT_HANDOFF=
DESKTOP_RESUME_RECEIPT_OLD_THREAD=
DESKTOP_RESUME_RECEIPT_NEW_THREAD=
DESKTOP_RESUME_RECEIPT_HOST=
DESKTOP_RESUME_RECEIPT_OLD_GENERATION=
DESKTOP_RESUME_RECEIPT_NEW_GENERATION=
desktop_resume_receipt_parse() {  # <receipt>
  local receipt=$1 lines key value
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  lines=$(wc -l < "$receipt" | tr -d ' ')
  [ "$lines" = 9 ] || return 1
  [ "$(exact_meta_value "$receipt" version)" = 1 ] || return 1
  for key in request_sha256 checkpoint handoff old_thread_id new_thread_id host_id \
    old_generation new_generation; do
    value=$(exact_meta_value "$receipt" "$key") || return 1
    valid_scalar "$value" || return 1
  done
  DESKTOP_RESUME_RECEIPT_REQUEST=$(exact_meta_value "$receipt" request_sha256)
  DESKTOP_RESUME_RECEIPT_CHECKPOINT=$(exact_meta_value "$receipt" checkpoint)
  DESKTOP_RESUME_RECEIPT_HANDOFF=$(exact_meta_value "$receipt" handoff)
  DESKTOP_RESUME_RECEIPT_OLD_THREAD=$(exact_meta_value "$receipt" old_thread_id)
  DESKTOP_RESUME_RECEIPT_NEW_THREAD=$(exact_meta_value "$receipt" new_thread_id)
  DESKTOP_RESUME_RECEIPT_HOST=$(exact_meta_value "$receipt" host_id)
  DESKTOP_RESUME_RECEIPT_OLD_GENERATION=$(exact_meta_value "$receipt" old_generation)
  DESKTOP_RESUME_RECEIPT_NEW_GENERATION=$(exact_meta_value "$receipt" new_generation)
  [[ "$DESKTOP_RESUME_RECEIPT_REQUEST" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$DESKTOP_RESUME_RECEIPT_CHECKPOINT" | grep -Eq '^[0-9a-f]{40,64}$' \
    || return 1
  valid_thread "$DESKTOP_RESUME_RECEIPT_OLD_THREAD" \
    && valid_thread "$DESKTOP_RESUME_RECEIPT_NEW_THREAD" \
    && [ "$DESKTOP_RESUME_RECEIPT_OLD_THREAD" != "$DESKTOP_RESUME_RECEIPT_NEW_THREAD" ] \
    && valid_atom "$DESKTOP_RESUME_RECEIPT_HOST" || return 1
  case "$DESKTOP_RESUME_RECEIPT_OLD_GENERATION" in ''|*[!0-9]*) return 1 ;; esac
  case "$DESKTOP_RESUME_RECEIPT_NEW_GENERATION" in ''|*[!0-9]*) return 1 ;; esac
  [ "$DESKTOP_RESUME_RECEIPT_OLD_GENERATION" -ge 1 ] || return 1
  [ "$DESKTOP_RESUME_RECEIPT_NEW_GENERATION" -eq \
    $((DESKTOP_RESUME_RECEIPT_OLD_GENERATION + 1)) ]
}

desktop_resume_receipt_matches() {  # <receipt> <request> <checkpoint> <handoff> <thread> <host> <meta> <current>
  local receipt=$1 request_hash=$2 checkpoint=$3 handoff=$4 thread=$5 host=$6
  local meta=$7 current=$8 state
  desktop_resume_receipt_parse "$receipt" || return 1
  [ "$DESKTOP_RESUME_RECEIPT_REQUEST" = "$request_hash" ] \
    && [ "$DESKTOP_RESUME_RECEIPT_CHECKPOINT" = "$checkpoint" ] \
    && [ "$DESKTOP_RESUME_RECEIPT_HANDOFF" = "$handoff" ] \
    && [ "$DESKTOP_RESUME_RECEIPT_NEW_THREAD" = "$thread" ] \
    && [ "$DESKTOP_RESUME_RECEIPT_HOST" = "$host" ] \
    && [ "$(exact_meta_value "$meta" codex_app_thread_id)" = "$thread" ] \
    && [ "$(exact_meta_value "$meta" codex_app_host_id)" = "$host" ] \
    && [ "$(exact_meta_value "$meta" session_generation)" = \
      "$DESKTOP_RESUME_RECEIPT_NEW_GENERATION" ] \
    && [ "$(exact_meta_value "$current" thread_id)" = "$thread" ] \
    && [ "$(exact_meta_value "$current" host_id)" = "$host" ] || return 1
  state=$(exact_meta_value "$current" state) || return 1
  valid_state "$state"
}

resume_task() {
  local id=$1
  shift
  local thread='' host='' checkpoint='' handoff='' meta current worktree handoff_real
  local recorded_checkpoint recorded_handoff old_thread generation next_generation tmp
  local current_tmp receipt receipt_tmp request_hash journal
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
  task_mutation_lock_acquire "$id"
  task_metadata_lock_acquire "$id"
  meta="$STATE/$id.meta"
  current="$STATE/$id.codex-app-current"
  receipt="$STATE/$id.codex-app-resume-receipt"
  journal="$STATE/$id.codex-app-transition"
  request_hash=$(desktop_transition_request_hash resume "$id" "$thread" "$host" \
    "$checkpoint" "$handoff_real") || die "cannot bind Desktop resume request for $id"
  task_mutation_recovery_owner "$id" resume "$request_hash"
  if [ -e "$journal" ]; then
    desktop_transition_finish "$id" resume "$request_hash" \
      || die "cannot recover the journaled Desktop resume for $id"
  fi
  [ -f "$meta" ] && [ -f "$current" ] || die "task $id has incomplete Desktop state"
  [ "$(fm_backend_of_meta "$meta")" = codex-app-host ] \
    || die "task $id is not a Codex Desktop host task"
  registered_route_validate "$meta" \
    || die "task $id no longer matches its immutable model route evidence"
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
  if desktop_resume_receipt_matches "$receipt" "$request_hash" "$checkpoint" \
    "$handoff_real" "$thread" "$host" "$meta" "$current"; then
    generation=$DESKTOP_RESUME_RECEIPT_NEW_GENERATION
    printf 'resumed: %s generation=%s thread=%s checkpoint=%s\n' \
      "$id" "$generation" "$thread" "$checkpoint"
    return 0
  fi
  [ "$(exact_meta_value "$current" state)" = paused ] \
    || die "task $id must be paused at a hard session boundary before resume"
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
  current_tmp=$(umask 077; mktemp "$STATE/.$id.codex-app-current.XXXXXX") \
    || { rm -f -- "$tmp"; die "cannot stage resumed current state for $id"; }
  {
    printf 'thread_id=%s\n' "$thread"
    printf 'host_id=%s\n' "$host"
    printf 'state=working\n'
    printf 'updated_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'detail=resumed from checkpoint %s\n' "$checkpoint"
  } > "$current_tmp" || {
    rm -f -- "$tmp" "$current_tmp"
    die "cannot write staged resumed current state for $id"
  }
  receipt_tmp=$(umask 077; mktemp "$STATE/.$id.codex-app-resume-receipt.XXXXXX") \
    || { rm -f -- "$tmp" "$current_tmp"; die "cannot stage resume receipt for $id"; }
  {
    printf 'version=1\n'
    printf 'request_sha256=%s\n' "$request_hash"
    printf 'checkpoint=%s\n' "$checkpoint"
    printf 'handoff=%s\n' "$handoff_real"
    printf 'old_thread_id=%s\n' "$old_thread"
    printf 'new_thread_id=%s\n' "$thread"
    printf 'host_id=%s\n' "$host"
    printf 'old_generation=%s\n' "$generation"
    printf 'new_generation=%s\n' "$next_generation"
  } > "$receipt_tmp" || {
    rm -f -- "$tmp" "$current_tmp" "$receipt_tmp"
    die "cannot write staged resume receipt for $id"
  }
  desktop_transition_begin "$id" resume "$request_hash" "$tmp" "$current_tmp" \
    '' "$receipt_tmp" \
    || die "cannot publish journaled Desktop resume for $id; retry the exact resume"
  printf 'resumed: %s generation=%s thread=%s checkpoint=%s\n' \
    "$id" "$next_generation" "$thread" "$checkpoint"
}

archive_preflight_task() {
  local id=$1
  shift
  local report='' meta current kind worktree worktree_real report_real state canonical_report
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --report) [ "$#" -ge 2 ] || usage; report=$2; shift 2 ;;
      *) die_usage "unknown archive-preflight argument '$1'" ;;
    esac
  done

  valid_id "$id" || die_usage "invalid task id '$id'"
  valid_scalar "$report" || die_usage "report path must be a single-line value"
  require_owner
  task_mutation_lock_acquire "$id"
  task_metadata_lock_acquire "$id"
  task_mutation_recovery_owner "$id" archive-preflight none
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
  [ ! -L "$DATA/$id/report.md" ] \
    || die "canonical retained scout report must not be a symbolic link: $DATA/$id/report.md"
  canonical_report=$(resolve_existing_file "$DATA/$id/report.md") \
    || die "Desktop scout $id requires the canonical retained report at $DATA/$id/report.md"
  [ -s "$report_real" ] \
    || die "retained scout report is empty: $report_real"
  case "$report_real" in
    "$worktree_real"|"$worktree_real"/*)
      die "report is inside the Desktop worktree and would be deleted by archive: $report_real"
      ;;
  esac
  [ "$report_real" = "$canonical_report" ] \
    || die "retained scout report must be the canonical task report: $DATA/$id/report.md"

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
