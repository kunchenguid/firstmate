#!/usr/bin/env bash
# Hibernation lifecycle for finished PR workers.
#
# Usage:
#   fm-latent.sh enter <task-id>
#   fm-latent.sh verify <task-id>
#   fm-latent.sh resume <task-id>
#   fm-latent.sh finish <task-id>
#   fm-latent.sh recover <task-id>
#   fm-latent.sh recover-all
#   fm-latent.sh transition <task-id> <token>
#   fm-latent.sh project-removal-check <project-dir>
#
# Hibernation is not teardown.  enter releases a worker only after exact GitHub
# PR identity, ancestry, cleanliness, obligation, validation, endpoint, and Git
# recovery-ref proofs pass twice.  It retains task metadata, status history, PR
# monitoring, and refs/firstmate/latent/<task-id>.  finish delegates to
# fm-teardown.sh, which remains the only task-finalization path.
#
# The manifest schema and transaction phases are private implementation details
# owned here.  No operation accepts a force or discard bypass.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-task-safety-lib.sh
. "$SCRIPT_DIR/fm-task-safety-lib.sh"

LATENT_SCHEMA=fm-latent.v1
LATENT_TX_SCHEMA=fm-latent-transaction.v1
LATENT_REF_PREFIX=refs/firstmate/latent
LATENT_RESUME_REF_PREFIX=refs/firstmate/latent-resume
LATENT_TMP_REF_PREFIX=refs/firstmate/latent-tmp
LATENT_TASK_LOCK=
LATENT_BACKEND_LOCK=
LATENT_PRESENTATION_LOCK=
LATENT_TMP_REF=
LATENT_RESUME_REF=
LATENT_REACHED_END=0

latent_die() {
  echo "REFUSED: $*" >&2
  exit 1
}

latent_cleanup() {
  local rc=$?
  if [ -n "$LATENT_TMP_REF" ] && [ -n "${LATENT_PROJECT:-}" ]; then
    git -C "$LATENT_PROJECT" update-ref -d "$LATENT_TMP_REF" >/dev/null 2>&1 || true
  fi
  if [ -n "$LATENT_RESUME_REF" ] && [ -n "${LATENT_PROJECT:-}" ]; then
    git -C "$LATENT_PROJECT" update-ref -d "$LATENT_RESUME_REF" >/dev/null 2>&1 || true
  fi
  [ -z "$LATENT_PRESENTATION_LOCK" ] || fm_lock_release "$LATENT_PRESENTATION_LOCK" || true
  [ -z "$LATENT_BACKEND_LOCK" ] || fm_lock_release "$LATENT_BACKEND_LOCK" || true
  [ -z "$LATENT_TASK_LOCK" ] || fm_lock_release "$LATENT_TASK_LOCK" || true
  # `return "$rc"` alone cannot make this honest. Under `set -e` a FATAL abort -
  # sourcing a missing file, such as a backend adapter fm-backend.sh loads
  # lazily - reaches an EXIT trap with $? already 0, so installing any EXIT trap
  # turns that failure into a reported success. The status is gone before this
  # handler runs, so the only surviving evidence is that no subcommand ever
  # completed. bin/fm-watch.sh branches on `fm-latent.sh enter`, and would
  # otherwise read such an abort as a released worker and a completed
  # hibernation. Ordinary refusals carry their own non-zero $? through here.
  if [ "$rc" -eq 0 ] && [ "$LATENT_REACHED_END" -ne 1 ]; then
    echo "error: fm-latent.sh aborted before completing; no lifecycle change was recorded." >&2
    exit 1
  fi
  return "$rc"
}
trap latent_cleanup EXIT
trap 'exit 1' HUP INT TERM

latent_id_valid() {
  fm_task_id_path_safe "${1:-}"
}

latent_meta_value() {  # <meta> <key>
  fm_meta_get "$1" "$2"
}

latent_exact_meta_value() {  # <meta> <key>
  local count
  count=$(grep -c "^$2=" "$1" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  grep "^$2=" "$1" | cut -d= -f2-
}

latent_sha256() {
  fm_pr_sha256 "$1"
}

latent_canonical_dir() {
  fm_task_safety_canonical_existing_dir "$1"
}

latent_repository_identity() {  # <project>
  local project=$1 common common_abs device inode
  common=$(git -C "$project" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) common_abs=$common ;;
    *) common_abs=$(latent_canonical_dir "$project/$common") || return 1 ;;
  esac
  device=$(fm_pr_file_device "$common_abs") || return 1
  inode=$(fm_pr_file_inode "$common_abs") || return 1
  printf '%s:%s\n' "$device" "$inode"
}

latent_manifest_dir() { printf '%s/%s/latent\n' "$DATA" "$1"; }
latent_manifest_path() { printf '%s/manifest\n' "$(latent_manifest_dir "$1")"; }
latent_transaction_path() { printf '%s/transaction\n' "$(latent_manifest_dir "$1")"; }
latent_pending_manifest_path() { printf '%s/pending-manifest\n' "$(latent_manifest_dir "$1")"; }
latent_resume_brief_path() { printf '%s/resume-brief.md\n' "$(latent_manifest_dir "$1")"; }
latent_ref() { printf '%s/%s\n' "$LATENT_REF_PREFIX" "$1"; }
latent_zero_oid() { printf '%*s' "$1" '' | tr ' ' 0; }

latent_safe_value() {
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
}

latent_atomic_file() {  # <destination> <mode>; content on stdin
  local dest=$1 mode=$2 dir tmp
  dir=$(dirname "$dest")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  tmp=$(mktemp "$dir/.fm-latent.XXXXXX") || return 1
  if ! cat > "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

latent_prepare_manifest_dir() {
  local task_dir="$DATA/$LATENT_ID" dir
  [ -d "$task_dir" ] && [ ! -L "$task_dir" ] || return 1
  dir=$(latent_manifest_dir "$LATENT_ID")
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    mkdir -- "$dir" || return 1
  fi
  chmod 0700 "$dir"
}

latent_generation_next() {  # <manifest-or-absent>
  local old=${1:-} generation
  generation=0
  if [ -f "$old" ] && [ ! -L "$old" ]; then
    generation=$(sed -n 's/^generation=//p' "$old" | head -1)
    case "$generation" in ''|*[!0-9]*) generation=0 ;; esac
  fi
  printf '%s\n' "$((generation + 1))"
}

latent_write_transaction() {  # <phase>
  local phase=$1
  latent_atomic_file "$LATENT_TRANSACTION" 0600 <<EOF
schema=$LATENT_TX_SCHEMA
task_id=$LATENT_ID
generation=$LATENT_GENERATION
phase=$phase
project=$LATENT_PROJECT
repository_id=$LATENT_REPOSITORY_ID
recovery_ref=$LATENT_RECOVERY_REF
old_ref_oid=${LATENT_OLD_REF_OID:-}
pr_head=$LATENT_PR_HEAD
metadata_hash=$LATENT_METADATA_HASH
EOF
}

latent_write_manifest_to() {  # <destination> <phase>
  local destination=$1 phase=$2
  latent_atomic_file "$destination" 0600 <<EOF
schema=$LATENT_SCHEMA
task_id=$LATENT_ID
generation=$LATENT_GENERATION
phase=$phase
project=$LATENT_PROJECT
repository_id=$LATENT_REPOSITORY_ID
branch=$LATENT_BRANCH
local_head=$LATENT_LOCAL_HEAD
pr_url=$LATENT_PR_URL
pr_head=$LATENT_PR_HEAD
recovery_ref=$LATENT_RECOVERY_REF
backend=$LATENT_BACKEND
previous_target=$LATENT_TARGET
metadata_hash=$LATENT_METADATA_HASH
EOF
}

latent_write_manifest() {  # <phase>
  latent_write_manifest_to "$LATENT_MANIFEST" "$1"
}

latent_write_pending_manifest() {  # <phase>
  latent_write_manifest_to "$LATENT_PENDING_MANIFEST" "$1"
}

latent_manifest_parse() {  # <task-id> [manifest-path]
  local id=$1 file=${2:-} line key value seen='' count=0
  [ -n "$file" ] || file=$(latent_manifest_path "$id")
  LATENT_MANIFEST=$file
  LATENT_M_SCHEMA=''
  LATENT_M_TASK_ID=''
  LATENT_M_GENERATION=''
  LATENT_M_PHASE=''
  LATENT_M_PROJECT=''
  LATENT_M_REPOSITORY_ID=''
  LATENT_M_BRANCH=''
  LATENT_M_LOCAL_HEAD=''
  LATENT_M_PR_URL=''
  LATENT_M_PR_HEAD=''
  LATENT_M_RECOVERY_REF=''
  LATENT_M_BACKEND=''
  LATENT_M_PREVIOUS_TARGET=''
  LATENT_M_METADATA_HASH=''
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(fm_pr_file_mode "$file")" = 600 ] || return 1
  [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    count=$((count + 1))
    case "$line" in *=*) key=${line%%=*}; value=${line#*=} ;; *) return 1 ;; esac
    latent_safe_value "$value" || return 1
    case " $seen " in *" $key "*) return 1 ;; esac
    seen="$seen $key"
    case "$key" in
      schema) LATENT_M_SCHEMA=$value ;;
      task_id) LATENT_M_TASK_ID=$value ;;
      generation) LATENT_M_GENERATION=$value ;;
      phase) LATENT_M_PHASE=$value ;;
      project) LATENT_M_PROJECT=$value ;;
      repository_id) LATENT_M_REPOSITORY_ID=$value ;;
      branch) LATENT_M_BRANCH=$value ;;
      local_head) LATENT_M_LOCAL_HEAD=$value ;;
      pr_url) LATENT_M_PR_URL=$value ;;
      pr_head) LATENT_M_PR_HEAD=$value ;;
      recovery_ref) LATENT_M_RECOVERY_REF=$value ;;
      backend) LATENT_M_BACKEND=$value ;;
      previous_target) LATENT_M_PREVIOUS_TARGET=$value ;;
      metadata_hash) LATENT_M_METADATA_HASH=$value ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ "$count" -eq 14 ] || return 1
  [ "$LATENT_M_SCHEMA" = "$LATENT_SCHEMA" ] || return 1
  [ "$LATENT_M_TASK_ID" = "$id" ] || return 1
  case "$LATENT_M_GENERATION" in ''|*[!0-9]*) return 1 ;; esac
  case "$LATENT_M_PHASE" in prepared|returning|latent|active-retained) ;; *) return 1 ;; esac
  [ -n "$LATENT_M_PROJECT" ] && [ -d "$LATENT_M_PROJECT" ] || return 1
  [[ "$LATENT_M_REPOSITORY_ID" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  case "$LATENT_M_BRANCH" in ''|HEAD|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  git check-ref-format "refs/heads/$LATENT_M_BRANCH" >/dev/null 2>&1 || return 1
  fm_pr_head_valid "$LATENT_M_LOCAL_HEAD" || return 1
  fm_pr_url_parse "$LATENT_M_PR_URL" || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 1
  fm_pr_head_valid "$LATENT_M_PR_HEAD" || return 1
  [ "$LATENT_M_RECOVERY_REF" = "$(latent_ref "$id")" ] || return 1
  fm_backend_is_known "$LATENT_M_BACKEND" || return 1
  [ -n "$LATENT_M_PREVIOUS_TARGET" ] || return 1
  [[ "$LATENT_M_METADATA_HASH" =~ ^[0-9a-f]{64}$ ]] || return 1
}

latent_transaction_parse() {  # <task-id>
  local id=$1 file line key value seen='' count=0
  file=$(latent_transaction_path "$id")
  LATENT_TRANSACTION=$file
  LATENT_T_SCHEMA=''
  LATENT_T_TASK_ID=''
  LATENT_T_GENERATION=''
  LATENT_T_PHASE=''
  LATENT_T_PROJECT=''
  LATENT_T_REPOSITORY_ID=''
  LATENT_T_RECOVERY_REF=''
  LATENT_T_OLD_REF_OID=''
  LATENT_T_PR_HEAD=''
  LATENT_T_METADATA_HASH=''
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(fm_pr_file_mode "$file")" = 600 ] || return 1
  [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    count=$((count + 1))
    case "$line" in *=*) key=${line%%=*}; value=${line#*=} ;; *) return 1 ;; esac
    latent_safe_value "$value" || return 1
    case " $seen " in *" $key "*) return 1 ;; esac
    seen="$seen $key"
    case "$key" in
      schema) LATENT_T_SCHEMA=$value ;;
      task_id) LATENT_T_TASK_ID=$value ;;
      generation) LATENT_T_GENERATION=$value ;;
      phase) LATENT_T_PHASE=$value ;;
      project) LATENT_T_PROJECT=$value ;;
      repository_id) LATENT_T_REPOSITORY_ID=$value ;;
      recovery_ref) LATENT_T_RECOVERY_REF=$value ;;
      old_ref_oid) LATENT_T_OLD_REF_OID=$value ;;
      pr_head) LATENT_T_PR_HEAD=$value ;;
      metadata_hash) LATENT_T_METADATA_HASH=$value ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ "$count" -eq 10 ] || return 1
  [ "$LATENT_T_SCHEMA" = "$LATENT_TX_SCHEMA" ] || return 1
  [ "$LATENT_T_TASK_ID" = "$id" ] || return 1
  case "$LATENT_T_GENERATION" in ''|*[!0-9]*) return 1 ;; esac
  case "$LATENT_T_PHASE" in started|ref-pinned|manifest-sealed|backend-stopped|worktree-returned|metadata-committed) ;; *) return 1 ;; esac
  [ "$LATENT_T_RECOVERY_REF" = "$(latent_ref "$id")" ] || return 1
  fm_pr_head_valid "$LATENT_T_PR_HEAD" || return 1
  [ -z "$LATENT_T_OLD_REF_OID" ] || fm_pr_head_valid "$LATENT_T_OLD_REF_OID" || return 1
  [[ "$LATENT_T_METADATA_HASH" =~ ^[0-9a-f]{64}$ ]] || return 1
}

latent_lock_task() {  # <task-id>
  mkdir -p "$STATE"
  LATENT_TASK_LOCK="$STATE/.latent-$1.lock"
  fm_lock_try_acquire "$LATENT_TASK_LOCK" || latent_die "task $1 is already in a lifecycle transaction"
}

latent_lock_backend() {  # <backend> <target>
  local key
  key=$(printf '%s' "$1:$2" | tr -c 'A-Za-z0-9._-' '_')
  LATENT_BACKEND_LOCK="$STATE/.backend-$key.lock"
  fm_lock_try_acquire "$LATENT_BACKEND_LOCK" || latent_die "the recorded backend endpoint is already in a lifecycle transaction"
}

latent_require_meta_hash() {
  [ -f "$LATENT_META" ] && [ ! -L "$LATENT_META" ] || latent_die "task metadata changed or disappeared"
  [ "$(latent_sha256 "$LATENT_META")" = "$LATENT_METADATA_HASH" ] || latent_die "task metadata identity changed during hibernation"
}

latent_load_active() {  # <task-id>
  LATENT_ID=$1
  LATENT_META="$STATE/$LATENT_ID.meta"
  [ -f "$LATENT_META" ] && [ ! -L "$LATENT_META" ] || latent_die "task $LATENT_ID has no regular metadata"
  [ "$(latent_meta_value "$LATENT_META" tier)" != latent ] || latent_die "task $LATENT_ID is already latent"
  [ "$(latent_meta_value "$LATENT_META" tier)" != attention ] || latent_die "task $LATENT_ID requires attention before another entry"
  fm_task_safety_validate_endpoint "$LATENT_META" "$LATENT_ID" || exit 1
  LATENT_BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  LATENT_TARGET=$FM_BACKEND_VALIDATED_TARGET
  LATENT_WORKTREE=$(latent_exact_meta_value "$LATENT_META" worktree) || latent_die "worktree identity is missing or ambiguous"
  LATENT_PROJECT=$(latent_exact_meta_value "$LATENT_META" project) || latent_die "project identity is missing or ambiguous"
  LATENT_KIND=$(latent_meta_value "$LATENT_META" kind)
  [ -n "$LATENT_KIND" ] || LATENT_KIND=ship
  LATENT_MODE=$(latent_meta_value "$LATENT_META" mode)
  LATENT_TASKTMP=$(latent_meta_value "$LATENT_META" tasktmp)
  [ "$LATENT_KIND" = ship ] || latent_die "only ordinary ship tasks can hibernate"
  case "$LATENT_MODE" in no-mistakes|direct-PR) ;; *) latent_die "task mode $LATENT_MODE is not a PR-based ship mode" ;; esac
  case "$LATENT_BACKEND" in tmux|herdr) ;; *) latent_die "backend $LATENT_BACKEND has no recovery-grade termination proof in latent v1" ;; esac
  [ -d "$LATENT_WORKTREE" ] || latent_die "recorded worktree is unavailable"
  [ -d "$LATENT_PROJECT" ] || latent_die "recorded project is unavailable"
  LATENT_PROJECT=$(latent_canonical_dir "$LATENT_PROJECT") || latent_die "project path cannot be canonicalized"
  LATENT_REPOSITORY_ID=$(latent_repository_identity "$LATENT_PROJECT") || latent_die "repository identity cannot be established"
  LATENT_METADATA_HASH=$(latent_sha256 "$LATENT_META") || latent_die "task metadata cannot be hashed"
  LATENT_PR_URL=$(latent_exact_meta_value "$LATENT_META" pr) || latent_die "canonical PR identity is missing or ambiguous"
  fm_pr_url_parse "$LATENT_PR_URL" || latent_die "canonical PR URL is invalid"
  [ "$FM_PR_PROVIDER" = github ] || latent_die "latent v1 supports GitHub pull requests only"
  LATENT_PR_NUMBER=$FM_PR_NUMBER
  LATENT_PR_HEAD=$(latent_exact_meta_value "$LATENT_META" pr_head) || latent_die "exact GitHub PR head is missing or ambiguous"
  fm_pr_head_valid "$LATENT_PR_HEAD" || latent_die "recorded GitHub PR head is invalid"
  LATENT_READY_HEAD=$(latent_exact_meta_value "$LATENT_META" pr_ready_head) || latent_die "durable PR-ready identity is missing or ambiguous"
  [ "$LATENT_READY_HEAD" = "$LATENT_PR_HEAD" ] || latent_die "durable PR-ready identity does not match the exact PR head"
  LATENT_LOCAL_HEAD=$(git -C "$LATENT_WORKTREE" rev-parse --verify HEAD 2>/dev/null) || latent_die "local HEAD cannot be resolved"
  fm_pr_head_valid "$LATENT_LOCAL_HEAD" || latent_die "local HEAD is invalid"
  LATENT_BRANCH=$(git -C "$LATENT_WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null) || latent_die "detached local HEAD cannot enter latent"
  LATENT_RECOVERY_REF=$(latent_ref "$LATENT_ID")
  LATENT_MANIFEST=$(latent_manifest_path "$LATENT_ID")
  LATENT_PENDING_MANIFEST=$(latent_pending_manifest_path "$LATENT_ID")
  LATENT_TRANSACTION=$(latent_transaction_path "$LATENT_ID")
}

latent_query_pr() {
  local view
  view=$(cd "$LATENT_PROJECT" && gh pr view "$LATENT_PR_URL" --json state,headRefOid,reviewDecision -q '.state + "\t" + .headRefOid + "\t" + (.reviewDecision // "")' 2>/dev/null) \
    || return 1
  LATENT_FORGE_STATE=${view%%$'\t'*}
  view=${view#*$'\t'}
  [ "$view" != "$LATENT_FORGE_STATE" ] || return 1
  LATENT_FORGE_HEAD=${view%%$'\t'*}
  if [ "$view" = "$LATENT_FORGE_HEAD" ]; then
    LATENT_FORGE_REVIEW=
  else
    LATENT_FORGE_REVIEW=${view#*$'\t'}
  fi
  fm_pr_head_valid "$LATENT_FORGE_HEAD"
}

latent_fetch_exact_head() {
  local tmp_oid
  LATENT_TMP_REF="$LATENT_TMP_REF_PREFIX/$LATENT_ID.$$"
  git -C "$LATENT_PROJECT" update-ref -d "$LATENT_TMP_REF" >/dev/null 2>&1 || true
  git -C "$LATENT_PROJECT" fetch --quiet origin "+refs/pull/$LATENT_PR_NUMBER/head:$LATENT_TMP_REF" \
    || return 1
  tmp_oid=$(git -C "$LATENT_PROJECT" rev-parse --verify "$LATENT_TMP_REF^{commit}" 2>/dev/null) || return 1
  [ "$tmp_oid" = "$LATENT_PR_HEAD" ] || return 1
  git -C "$LATENT_PROJECT" cat-file -e "$LATENT_PR_HEAD^{commit}" 2>/dev/null
}

latent_no_obligations() {
  local open
  open=$(status_open_decisions "$STATE/$LATENT_ID.status" 2>/dev/null || true)
  [ -z "$open" ] || { echo "REFUSED: task $LATENT_ID has an unresolved keyed decision" >&2; return 1; }
  ! fm_pending_reply_task_has_open "$STATE" "$LATENT_ID" \
    || { echo "REFUSED: task $LATENT_ID has a pending routed reply" >&2; return 1; }
  [ -z "$(fm_pf_registry_ids_for_work "$STATE" main "$LATENT_ID")" ] \
    || { echo "REFUSED: task $LATENT_ID has a pending public follow-up" >&2; return 1; }
  ! fm_procevent_any_registered "$STATE" \
    || { echo "REFUSED: this home has a registered process-event obligation" >&2; return 1; }
}

latent_no_active_validation() {
  local current state source
  current=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-crew-state.sh" "$LATENT_ID" 2>/dev/null || true)
  state=${current#state: }
  state=${state%%' · '*}
  source=${current#*'source: '}
  source=${source%%' · '*}
  if [ "$LATENT_MODE" = no-mistakes ]; then
    if [ "$source" != run-step ] || [ "$state" != "done" ]; then
      echo "REFUSED: completed validation cannot be proved for no-mistakes task $LATENT_ID" >&2
      return 1
    fi
  elif [ "$source" = run-step ] && [ "$state" != "done" ]; then
    echo "REFUSED: task $LATENT_ID still has an active or parked validation run" >&2
    return 1
  fi
}

latent_check_pr_and_git() {
  latent_query_pr || { echo "REFUSED: authenticated GitHub PR identity cannot be read" >&2; return 1; }
  [ "$LATENT_FORGE_STATE" = OPEN ] || { echo "REFUSED: pull request is not open" >&2; return 1; }
  [ "$LATENT_FORGE_HEAD" = "$LATENT_PR_HEAD" ] || { echo "REFUSED: recorded and current pull request heads differ" >&2; return 1; }
  git -C "$LATENT_PROJECT" cat-file -e "$LATENT_PR_HEAD^{commit}" 2>/dev/null || { echo "REFUSED: exact pull request commit object is missing" >&2; return 1; }
  [ "$(git -C "$LATENT_WORKTREE" rev-parse --verify HEAD 2>/dev/null)" = "$LATENT_LOCAL_HEAD" ] \
    || { echo "REFUSED: local HEAD changed during hibernation" >&2; return 1; }
  git -C "$LATENT_WORKTREE" merge-base --is-ancestor "$LATENT_LOCAL_HEAD" "$LATENT_PR_HEAD" 2>/dev/null \
    || { echo "REFUSED: local HEAD is not contained in the exact pull request head" >&2; return 1; }
}

latent_check_clean() {
  fm_task_safety_worktree_clean "$LATENT_WORKTREE" 2>/dev/null \
    || { echo "REFUSED: worktree is dirty or cleanliness cannot be proved" >&2; return 1; }
}

latent_check_validation_and_obligations() {
  latent_no_obligations && latent_no_active_validation
}

latent_ref_matches() {
  [ "$(git -C "$LATENT_PROJECT" rev-parse --verify "$LATENT_RECOVERY_REF^{commit}" 2>/dev/null)" = "$LATENT_PR_HEAD" ]
}

latent_validate_prior_generation() {
  local manifest_present=0 ref_present=0 old_oid
  if [ -e "$LATENT_MANIFEST" ] || [ -L "$LATENT_MANIFEST" ]; then
    manifest_present=1
  fi
  old_oid=$(git -C "$LATENT_PROJECT" rev-parse --verify "$LATENT_RECOVERY_REF^{commit}" 2>/dev/null || true)
  [ -z "$old_oid" ] || ref_present=1
  if [ "$manifest_present" -eq 0 ] && [ "$ref_present" -eq 0 ]; then
    return 0
  fi
  [ "$manifest_present" -eq 1 ] && [ "$ref_present" -eq 1 ] || {
    echo "REFUSED: prior latent manifest/ref presence does not agree" >&2
    return 1
  }
  latent_manifest_parse "$LATENT_ID" || { echo "REFUSED: prior latent manifest is invalid" >&2; return 1; }
  [ "$LATENT_M_PHASE" = active-retained ] || { echo "REFUSED: prior latent generation is not an active retained generation" >&2; return 1; }
  [ "$LATENT_M_PROJECT" = "$LATENT_PROJECT" ] || return 1
  [ "$LATENT_M_REPOSITORY_ID" = "$LATENT_REPOSITORY_ID" ] || return 1
  [ "$LATENT_M_RECOVERY_REF" = "$LATENT_RECOVERY_REF" ] || return 1
  [ "$LATENT_M_PR_HEAD" = "$old_oid" ] || return 1
  [ "$(latent_meta_value "$LATENT_META" latent_generation)" = "$LATENT_M_GENERATION" ] || return 1
}

latent_poll_valid() {
  fm_pr_poll_artifacts_valid "$STATE" "$LATENT_ID" "$SCRIPT_DIR/fm-pr-poll.sh"
}

latent_processes_clear() {
  local pids='' dir current
  command -v lsof >/dev/null 2>&1 || { echo "REFUSED: lsof is required to prove task processes are gone" >&2; return 1; }
  for dir in "$LATENT_WORKTREE" "$LATENT_TASKTMP"; do
    [ -n "$dir" ] || continue
    current=$(fm_task_safety_pids_with_cwd_under "$dir") || { echo "REFUSED: task process inventory is unreadable" >&2; return 1; }
    pids="$pids$current"
  done
  [ -z "$pids" ] || { echo "REFUSED: task processes remain after endpoint termination" >&2; return 1; }
}

latent_terminate_backend() {
  local journal session pane meta_session workspace meta_pane
  if [ "$LATENT_BACKEND" != herdr ]; then
    fm_backend_kill "$LATENT_BACKEND" "$LATENT_TARGET" \
      "$(latent_meta_value "$LATENT_META" zellij_tab_id)" "fm-$LATENT_ID" || return 1
    fm_task_safety_backend_terminated "$LATENT_BACKEND" "$LATENT_TARGET"
    return
  fi

  fm_backend_source herdr || return 1
  fm_backend_herdr_parse_target "$LATENT_TARGET" || return 1
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  LATENT_PRESENTATION_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$session") || return 1
  fm_lock_try_acquire "$LATENT_PRESENTATION_LOCK" || return 1
  journal="$STATE/$LATENT_ID.herdr-presentation"
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
    meta_session=$(latent_exact_meta_value "$LATENT_META" herdr_session) || return 1
    workspace=$(latent_exact_meta_value "$LATENT_META" herdr_workspace_id) || return 1
    meta_pane=$(latent_exact_meta_value "$LATENT_META" herdr_pane_id) || return 1
    [ "$meta_session" = "$session" ] && [ "$meta_pane" = "$pane" ] || return 1
    fm_backend_herdr_projection_endpoint_matches_journal \
      "$session" "$workspace" "$journal" "$LATENT_ID" || return 1
    fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$pane" || return 1
  else
    fm_backend_herdr_kill_serialized "$session" "$pane" || return 1
  fi
  fm_backend_herdr_endpoint_confirmed_gone "$LATENT_TARGET" || return 1
  [ ! -e "$journal" ] && [ ! -L "$journal" ] || rm -f -- "$journal"
  fm_task_safety_backend_terminated "$LATENT_BACKEND" "$LATENT_TARGET"
}

latent_remove_turnend_auth() {
  local token hooks
  token=$(cat "$STATE/$LATENT_ID.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) ;; *) hooks="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"; rm -f -- "$hooks/$token" ;; esac
  token=$(cat "$STATE/$LATENT_ID.kimi-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) ;; *) hooks="$HOME/.kimi-code/fm-turn-end.d"; rm -f -- "$hooks/$token" ;; esac
  rm -f -- "$STATE/$LATENT_ID.grok-turnend-token" "$STATE/$LATENT_ID.kimi-turnend-token"
}

latent_treehouse_identity_present() {
  local project=$1 worktree=$2 status expected candidate candidate_real count=0
  status=$(cd "$project" && treehouse status --json 2>/dev/null) || return 1
  expected=$(latent_canonical_dir "$worktree") || return 1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    candidate_real=$(latent_canonical_dir "$candidate" 2>/dev/null || true)
    [ "$candidate_real" = "$expected" ] || continue
    count=$((count + 1))
  done <<EOF
$(printf '%s\n' "$status" | jq -r '.[].path' 2>/dev/null)
EOF
  [ "$count" -eq 1 ]
}

latent_return_worktree() {
  latent_treehouse_identity_present "$LATENT_PROJECT" "$LATENT_WORKTREE" \
    || { echo "REFUSED: Treehouse does not report exactly the recorded worktree" >&2; return 1; }
  ( CDPATH='' cd -- "$LATENT_PROJECT" && treehouse return "$LATENT_WORKTREE" )
}

latent_meta_commit() {
  local tmp line inserted=0
  latent_require_meta_hash
  tmp=$(mktemp "$STATE/.fm-latent-meta.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      window=*) printf 'window=\n' >> "$tmp" ;;
      worktree=*) printf 'worktree=\n' >> "$tmp" ;;
      tier=*|latent_generation=*|latent_manifest=*|latent_saved_head=*|latent_local_head=*|pr_ready_head=*) ;;
      herdr_session=*|herdr_workspace_id=*|herdr_tab_id=*|herdr_pane_id=*|zellij_session=*|zellij_tab_id=*|zellij_pane_id=*|orca_worktree_id=*|terminal=*|cmux_workspace_id=*|cmux_surface_id=*) ;;
      pr=*)
        if [ "$inserted" -eq 0 ]; then
          printf 'tier=latent\nlatent_generation=%s\nlatent_manifest=%s\nlatent_saved_head=%s\nlatent_local_head=%s\n' \
            "$LATENT_GENERATION" "$LATENT_MANIFEST" "$LATENT_PR_HEAD" "$LATENT_LOCAL_HEAD" >> "$tmp"
          inserted=1
        fi
        printf '%s\n' "$line" >> "$tmp"
        ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$LATENT_META"
  [ "$inserted" -eq 1 ] || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$LATENT_META"
}

latent_restore_old_ref() {
  local project=$1 ref=$2 old=$3 current=$4
  if [ -n "$old" ]; then
    git -C "$project" update-ref "$ref" "$old" "$current"
  else
    git -C "$project" update-ref -d "$ref" "$current"
  fi
}

latent_enter() {
  local id=$1 old_ref meta_hash_after_kill
  latent_lock_task "$id"
  latent_recover_one "$id" quiet || latent_die "an incomplete latent transaction could not be recovered"
  latent_load_active "$id"
  latent_lock_backend "$LATENT_BACKEND" "$LATENT_TARGET"
  latent_require_meta_hash
  fm_task_safety_validate_endpoint "$LATENT_META" "$LATENT_ID" || exit 1
  [ "$FM_BACKEND_VALIDATED_BACKEND" = "$LATENT_BACKEND" ] && [ "$FM_BACKEND_VALIDATED_TARGET" = "$LATENT_TARGET" ] \
    || latent_die "backend identity changed while locks were acquired"
  latent_poll_valid || latent_die "canonical authenticated pull request poll is unavailable"
  latent_prepare_manifest_dir || latent_die "latent recovery directory is unsafe"
  latent_validate_prior_generation || latent_die "prior latent generation cannot be reconciled"
  latent_fetch_exact_head || latent_die "exact pull request commit could not be fetched and verified"
  latent_check_pr_and_git || exit 1
  latent_check_clean || exit 1
  latent_check_validation_and_obligations || exit 1

  LATENT_GENERATION=$(latent_generation_next "$LATENT_MANIFEST")
  old_ref=$(git -C "$LATENT_PROJECT" rev-parse --verify "$LATENT_RECOVERY_REF^{commit}" 2>/dev/null || true)
  LATENT_OLD_REF_OID=$old_ref
  latent_write_transaction started || latent_die "transaction journal could not be created"
  if [ -n "$old_ref" ]; then
    git -C "$LATENT_PROJECT" update-ref "$LATENT_RECOVERY_REF" "$LATENT_PR_HEAD" "$old_ref" \
      || latent_die "recovery ref changed concurrently"
  else
    git -C "$LATENT_PROJECT" update-ref "$LATENT_RECOVERY_REF" "$LATENT_PR_HEAD" "$(latent_zero_oid "${#LATENT_PR_HEAD}")" \
      || latent_die "recovery ref appeared concurrently"
  fi
  latent_ref_matches || latent_die "recovery ref does not resolve to the pull request head"
  latent_write_transaction ref-pinned || latent_die "ref-pinned transaction phase could not be recorded"
  if [ "${FM_LATENT_CRASH_AFTER:-}" = ref ]; then exit 86; fi
  latent_write_pending_manifest prepared || latent_die "sealed recovery manifest could not be written"
  latent_write_transaction manifest-sealed || latent_die "manifest transaction phase could not be recorded"

  latent_terminate_backend \
    || latent_die "recorded backend endpoint could not be terminated and proved absent"
  latent_write_transaction backend-stopped || latent_die "backend-stopped transaction phase could not be recorded"

  latent_require_meta_hash
  meta_hash_after_kill=$(latent_sha256 "$LATENT_META") || latent_die "metadata cannot be rehashed"
  [ "$meta_hash_after_kill" = "$LATENT_METADATA_HASH" ] || latent_die "metadata changed after backend termination"
  latent_check_pr_and_git || exit 1
  latent_check_clean || exit 1
  latent_ref_matches || latent_die "recovery ref changed after backend termination"
  latent_check_validation_and_obligations || exit 1
  latent_processes_clear || exit 1
  latent_write_pending_manifest returning || latent_die "returning manifest phase could not be recorded"
  latent_remove_turnend_auth
  latent_return_worktree || latent_die "Treehouse did not confirm the non-forced worktree return"
  latent_write_transaction worktree-returned || latent_die "worktree-returned transaction phase could not be recorded"
  if [ "${FM_LATENT_CRASH_AFTER:-}" = return ]; then exit 87; fi
  latent_meta_commit || latent_die "latent metadata could not be committed"
  latent_write_manifest latent || latent_die "latent manifest could not be sealed"
  latent_write_transaction metadata-committed || latent_die "metadata commit could not be journaled"
  rm -f -- "$LATENT_PENDING_MANIFEST" "$LATENT_TRANSACTION"
  printf 'latent: PR %s saved at %s\n' "$LATENT_PR_URL" "$LATENT_PR_HEAD" >> "$STATE/$LATENT_ID.status"
  printf 'latent %s: %s\n' "$LATENT_ID" "$LATENT_PR_HEAD"
}

latent_verify_loaded() {  # <task-id>
  local id=$1 meta repo ref_oid tier pr project worktree window
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  tier=$(latent_meta_value "$meta" tier)
  case "$tier" in latent|attention) ;; *) return 1 ;; esac
  project=$(latent_meta_value "$meta" project)
  window=$(latent_meta_value "$meta" window)
  worktree=$(latent_meta_value "$meta" worktree)
  [ -z "$window" ] && [ -z "$worktree" ] || return 1
  latent_manifest_parse "$id" || return 1
  [ "$LATENT_M_PHASE" = latent ] || return 1
  [ "$(latent_canonical_dir "$project")" = "$(latent_canonical_dir "$LATENT_M_PROJECT")" ] || return 1
  repo=$(latent_repository_identity "$LATENT_M_PROJECT") || return 1
  [ "$repo" = "$LATENT_M_REPOSITORY_ID" ] || return 1
  pr=$(latent_exact_meta_value "$meta" pr) || return 1
  [ "$pr" = "$LATENT_M_PR_URL" ] || return 1
  [ "$(latent_exact_meta_value "$meta" pr_head)" = "$LATENT_M_PR_HEAD" ] || return 1
  [ "$(latent_meta_value "$meta" latent_generation)" = "$LATENT_M_GENERATION" ] || return 1
  [ "$(latent_meta_value "$meta" latent_manifest)" = "$(latent_manifest_path "$id")" ] || return 1
  ref_oid=$(git -C "$LATENT_M_PROJECT" rev-parse --verify "$LATENT_M_RECOVERY_REF^{commit}" 2>/dev/null) || return 1
  [ "$ref_oid" = "$LATENT_M_PR_HEAD" ] || return 1
  git -C "$LATENT_M_PROJECT" merge-base --is-ancestor "$LATENT_M_LOCAL_HEAD" "$LATENT_M_PR_HEAD" 2>/dev/null
}

latent_verify() {
  local id=$1 tier
  if latent_verify_loaded "$id"; then
    tier=$(latent_meta_value "$STATE/$id.meta" tier)
    printf '%s\n' "$tier"
    return 0
  fi
  printf 'quarantined\n'
  return 1
}

latent_recover_one() {  # <task-id> [quiet]
  local id=$1 quiet=${2:-} meta current_hash current_ref metadata_already=0
  LATENT_TRANSACTION=$(latent_transaction_path "$id")
  [ -e "$LATENT_TRANSACTION" ] || [ -L "$LATENT_TRANSACTION" ] || return 0
  latent_transaction_parse "$id" || { [ "$quiet" = quiet ] || echo "quarantined $id: corrupt transaction"; return 1; }
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || { [ "$quiet" = quiet ] || echo "quarantined $id: metadata missing"; return 1; }
  [ "$(latent_repository_identity "$LATENT_T_PROJECT" 2>/dev/null || true)" = "$LATENT_T_REPOSITORY_ID" ] \
    || { [ "$quiet" = quiet ] || echo "quarantined $id: repository identity mismatch"; return 1; }
  current_ref=$(git -C "$LATENT_T_PROJECT" rev-parse --verify "$LATENT_T_RECOVERY_REF^{commit}" 2>/dev/null || true)
  case "$LATENT_T_PHASE" in
    started)
      [ "$current_ref" = "$LATENT_T_OLD_REF_OID" ] || { [ "$quiet" = quiet ] || echo "quarantined $id: recovery ref changed before pinning"; return 1; }
      rm -f -- "$LATENT_TRANSACTION"
      ;;
    ref-pinned|manifest-sealed|backend-stopped)
      [ "$current_ref" = "$LATENT_T_PR_HEAD" ] || { [ "$quiet" = quiet ] || echo "quarantined $id: recovery ref mismatch"; return 1; }
      if [ -n "$(latent_meta_value "$meta" worktree)" ] && [ -d "$(latent_meta_value "$meta" worktree)" ]; then
        latent_restore_old_ref "$LATENT_T_PROJECT" "$LATENT_T_RECOVERY_REF" "$LATENT_T_OLD_REF_OID" "$LATENT_T_PR_HEAD" || return 1
        rm -f -- "$(latent_pending_manifest_path "$id")" "$LATENT_TRANSACTION"
        [ "$quiet" = quiet ] || printf 'active %s: incomplete pre-return transaction rolled back\n' "$id"
      else
        [ "$quiet" = quiet ] || echo "quarantined $id: worktree disappeared before a returned phase was recorded"
        return 1
      fi
      ;;
    worktree-returned)
      [ "$current_ref" = "$LATENT_T_PR_HEAD" ] || { [ "$quiet" = quiet ] || echo "quarantined $id: recovery ref mismatch"; return 1; }
      current_hash=$(latent_sha256 "$meta") || return 1
      latent_manifest_parse "$id" "$(latent_pending_manifest_path "$id")" || return 1
      if [ "$current_hash" != "$LATENT_T_METADATA_HASH" ]; then
        [ "$(latent_meta_value "$meta" tier)" = latent ] || return 1
        [ "$(latent_meta_value "$meta" latent_generation)" = "$LATENT_M_GENERATION" ] || return 1
        [ -z "$(latent_meta_value "$meta" window)" ] && [ -z "$(latent_meta_value "$meta" worktree)" ] || return 1
        [ "$(latent_exact_meta_value "$meta" pr)" = "$LATENT_M_PR_URL" ] || return 1
        [ "$(latent_exact_meta_value "$meta" pr_head)" = "$LATENT_M_PR_HEAD" ] || return 1
        metadata_already=1
      fi
      LATENT_ID=$id
      LATENT_META=$meta
      LATENT_PROJECT=$LATENT_M_PROJECT
      LATENT_REPOSITORY_ID=$LATENT_M_REPOSITORY_ID
      LATENT_BRANCH=$LATENT_M_BRANCH
      LATENT_LOCAL_HEAD=$LATENT_M_LOCAL_HEAD
      LATENT_PR_URL=$LATENT_M_PR_URL
      LATENT_PR_HEAD=$LATENT_M_PR_HEAD
      LATENT_RECOVERY_REF=$LATENT_M_RECOVERY_REF
      LATENT_BACKEND=$LATENT_M_BACKEND
      LATENT_TARGET=$LATENT_M_PREVIOUS_TARGET
      LATENT_METADATA_HASH=$LATENT_M_METADATA_HASH
      LATENT_GENERATION=$LATENT_M_GENERATION
      LATENT_MANIFEST=$(latent_manifest_path "$id")
      LATENT_PENDING_MANIFEST=$(latent_pending_manifest_path "$id")
      [ "$metadata_already" -eq 1 ] || latent_meta_commit || return 1
      latent_write_manifest latent || return 1
      rm -f -- "$LATENT_PENDING_MANIFEST" "$LATENT_TRANSACTION"
      [ "$quiet" = quiet ] || printf 'latent %s: completed interrupted metadata commit\n' "$id"
      ;;
    metadata-committed)
      [ "$current_ref" = "$LATENT_T_PR_HEAD" ] || return 1
      latent_verify_loaded "$id" || return 1
      rm -f -- "$(latent_pending_manifest_path "$id")" "$LATENT_TRANSACTION"
      ;;
  esac
}

latent_recover() {
  local id=$1
  latent_lock_task "$id"
  latent_recover_one "$id"
}

latent_recover_all() {
  local tx id out rc=0
  [ -d "$DATA" ] || return 0
  for tx in "$DATA"/*/latent/transaction; do
    [ -e "$tx" ] || [ -L "$tx" ] || continue
    id=${tx%/latent/transaction}
    id=${id##*/}
    if ! latent_id_valid "$id"; then
      echo "LATENT_RECOVERY: quarantined invalid task record $tx" >&2
      rc=1
      continue
    fi
    if out=$("$0" recover "$id" 2>/dev/null); then
      [ -z "$out" ] || printf 'BOOTSTRAP_INFO: latent recovery: %s\n' "$out"
    else
      echo "LATENT_RECOVERY: quarantined $id" >&2
      rc=1
    fi
  done
  return "$rc"
}

latent_transition() {  # <task-id> <token>
  local id=$1 token=$2 meta tmp line
  case "$token" in merged|closed-unmerged|changes-requested:*|head-changed:*) ;; *) latent_die "invalid pull request transition" ;; esac
  latent_lock_task "$id"
  latent_verify_loaded "$id" || latent_die "task $id has no valid latent recovery record"
  meta="$STATE/$id.meta"
  tmp=$(mktemp "$STATE/.fm-latent-attention.XXXXXX") || exit 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in tier=*) printf 'tier=attention\n' >> "$tmp" ;; *) printf '%s\n' "$line" >> "$tmp" ;; esac
  done < "$meta"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$meta"
  printf 'attention: PR transition %s\n' "$token" >> "$STATE/$id.status"
}

latent_write_resume_brief() {
  local path mode=$1
  path=$(latent_resume_brief_path "$LATENT_ID")
  latent_atomic_file "$path" 0600 <<EOF
# Latent task rehydration

Delivery contract: mode=$mode

The prior model conversation and validation prompt were not preserved.
Reconstruct the task from the original instructions at $DATA/$LATENT_ID/brief.md, the Git branch, the pull request, review feedback, and durable status history.
The isolated copy is already checked out at the authenticated current pull request head on branch $LATENT_M_BRANCH.
Do not create the branch again or reset it away from that head.
Pull request: $LATENT_M_PR_URL
Saved generation head: $LATENT_M_PR_HEAD
Current authenticated pull request head: $LATENT_FORGE_HEAD
Review transition: ${LATENT_FORGE_REVIEW:-none}
Resume only the bounded rework needed for this pull request and follow the original delivery contract.
EOF
  printf '%s\n' "$path"
}

latent_resume() {
  local id=$1 meta mode yolo harness model effort backend brief args current_resume_oid tmp line
  latent_lock_task "$id"
  latent_verify_loaded "$id" || latent_die "task $id has no valid latent recovery record"
  latent_lock_backend "$LATENT_M_BACKEND" "$LATENT_M_PREVIOUS_TARGET"
  LATENT_ID=$id
  LATENT_PROJECT=$LATENT_M_PROJECT
  LATENT_PR_URL=$LATENT_M_PR_URL
  LATENT_PR_HEAD=$LATENT_M_PR_HEAD
  LATENT_PR_NUMBER=${LATENT_M_PR_URL##*/}
  latent_query_pr || latent_die "authenticated GitHub pull request identity cannot be read"
  case "$LATENT_FORGE_STATE" in
    MERGED) latent_die "pull request is merged; finish the task instead of resuming it" ;;
    OPEN) ;;
    *) latent_die "closed-unmerged pull request remains protected and requires a reopen or explicit abandonment decision" ;;
  esac
  LATENT_PR_HEAD=$LATENT_FORGE_HEAD
  latent_fetch_exact_head || latent_die "current pull request head cannot be fetched exactly"
  LATENT_RESUME_REF="$LATENT_RESUME_REF_PREFIX/$id.$$"
  git -C "$LATENT_PROJECT" update-ref "$LATENT_RESUME_REF" "$LATENT_FORGE_HEAD" \
    || latent_die "temporary resume ref could not be created"
  current_resume_oid=$(git -C "$LATENT_PROJECT" rev-parse --verify "$LATENT_RESUME_REF^{commit}")
  [ "$current_resume_oid" = "$LATENT_FORGE_HEAD" ] || latent_die "temporary resume ref identity mismatch"

  meta="$STATE/$id.meta"
  mode=$(latent_meta_value "$meta" mode)
  yolo=$(latent_meta_value "$meta" yolo)
  harness=$(latent_meta_value "$meta" harness)
  model=$(latent_meta_value "$meta" model)
  effort=$(latent_meta_value "$meta" effort)
  backend=$(latent_meta_value "$meta" backend)
  [ -n "$backend" ] || backend=tmux
  brief=$(latent_write_resume_brief "$mode") || latent_die "resume instructions could not be written"
  args=("$SCRIPT_DIR/fm-spawn.sh" "$id" "$LATENT_PROJECT" --mode "$mode" --yolo "$yolo" --harness "$harness" --backend "$backend" --resume-ref "$LATENT_RESUME_REF" --resume-branch "$LATENT_M_BRANCH" --brief-override "$brief")
  [ -z "$model" ] || [ "$model" = default ] || args+=(--model "$model")
  [ -z "$effort" ] || [ "$effort" = default ] || args+=(--effort "$effort")
  fm_lock_release "$LATENT_TASK_LOCK" || latent_die "task lock could not be handed to the fresh worker launch"
  LATENT_TASK_LOCK=
  FM_HOME="$FM_HOME" "${args[@]}" || latent_die "fresh worker launch failed; the saved generation remains protected"

  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || latent_die "fresh worker did not publish metadata"
  tmp=$(mktemp "$STATE/.fm-latent-active.XXXXXX") || exit 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in tier=*|pr=*|pr_head=*|pr_ready_head=*|latent_generation=*|latent_saved_head=*|latent_local_head=*) ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$meta"
  printf 'tier=active\nlatent_generation=%s\nlatent_saved_head=%s\npr=%s\npr_head=%s\n' \
    "$LATENT_M_GENERATION" "$LATENT_M_PR_HEAD" "$LATENT_M_PR_URL" "$LATENT_FORGE_HEAD" >> "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$meta"
  LATENT_GENERATION=$LATENT_M_GENERATION
  LATENT_PROJECT=$LATENT_M_PROJECT
  LATENT_REPOSITORY_ID=$LATENT_M_REPOSITORY_ID
  LATENT_BRANCH=$LATENT_M_BRANCH
  LATENT_LOCAL_HEAD=$LATENT_M_LOCAL_HEAD
  LATENT_PR_URL=$LATENT_M_PR_URL
  LATENT_PR_HEAD=$LATENT_M_PR_HEAD
  LATENT_RECOVERY_REF=$LATENT_M_RECOVERY_REF
  LATENT_BACKEND=$LATENT_M_BACKEND
  LATENT_TARGET=$LATENT_M_PREVIOUS_TARGET
  LATENT_METADATA_HASH=$LATENT_M_METADATA_HASH
  LATENT_MANIFEST=$(latent_manifest_path "$id")
  latent_write_manifest active-retained || latent_die "active recovery manifest could not be updated"
  printf 'working: rehydrated from latent generation %s at PR head %s\n' "$LATENT_M_GENERATION" "$LATENT_FORGE_HEAD" >> "$STATE/$id.status"
  printf 'active %s: %s\n' "$id" "$LATENT_FORGE_HEAD"
}

latent_finish() {
  local id=$1
  latent_lock_task "$id"
  latent_verify_loaded "$id" || latent_die "task $id has no valid latent recovery record"
  fm_lock_release "$LATENT_TASK_LOCK" || latent_die "latent task lock could not be released for final teardown"
  LATENT_TASK_LOCK=
  FM_LATENT_FINISH_REQUEST=1 exec "$SCRIPT_DIR/fm-teardown.sh" "$id"
}

latent_project_removal_check() {
  local requested=$1 project manifest found=0
  project=$(latent_canonical_dir "$requested") || latent_die "project directory is unavailable"
  for manifest in "$DATA"/*/latent/manifest; do
    [ -e "$manifest" ] || [ -L "$manifest" ] || continue
    if ! latent_manifest_parse "$(basename "$(dirname "$(dirname "$manifest")")")"; then
      echo "REFUSED: corrupt latent manifest exists at $manifest" >&2
      found=1
      continue
    fi
    if [ "$(latent_canonical_dir "$LATENT_M_PROJECT")" = "$project" ]; then
      echo "REFUSED: project has protected latent task $LATENT_M_TASK_ID at $LATENT_M_RECOVERY_REF" >&2
      found=1
    fi
  done
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    echo "REFUSED: project has protected latent recovery ref $ref" >&2
    found=1
  done <<EOF
$(git -C "$project" for-each-ref --format='%(refname)' "$LATENT_REF_PREFIX/" 2>/dev/null || true)
EOF
  [ "$found" -eq 0 ]
}

cmd=${1:-}
case "$cmd" in
  enter|verify|resume|finish|recover|transition)
    [ "$#" -ge 2 ] || { echo "usage: fm-latent.sh $cmd <task-id>" >&2; exit 2; }
    latent_id_valid "$2" || { echo "error: invalid latent task id" >&2; exit 2; }
    ;;
esac
case "$cmd" in
  enter) [ "$#" -eq 2 ] || exit 2; latent_enter "$2" ;;
  verify) [ "$#" -eq 2 ] || exit 2; latent_verify "$2" ;;
  resume) [ "$#" -eq 2 ] || exit 2; latent_resume "$2" ;;
  finish) [ "$#" -eq 2 ] || exit 2; latent_finish "$2" ;;
  recover) [ "$#" -eq 2 ] || exit 2; latent_recover "$2" ;;
  recover-all) [ "$#" -eq 1 ] || exit 2; latent_recover_all ;;
  transition) [ "$#" -eq 3 ] || exit 2; latent_transition "$2" "$3" ;;
  project-removal-check) [ "$#" -eq 2 ] || exit 2; latent_project_removal_check "$2" ;;
  *)
    echo "usage: fm-latent.sh <enter|verify|resume|finish|recover|recover-all|transition|project-removal-check> ..." >&2
    exit 2
    ;;
esac
LATENT_REACHED_END=1
