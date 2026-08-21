#!/usr/bin/env bash
# Publish a current-incarnation completion receipt without changing lifecycle.
#
# Usage:
#   fm-complete.sh <task-id> --spawn-gen <gen> --outcome <done|failed>
#     --summary <legacy-status-note> [--artifact <path>] [--pr <canonical-url>]
#
# FM_SPAWN_GEN may supply --spawn-gen for a process launched by fm-spawn.sh.
# The receipt is atomically published only while the supplied generation still
# matches state/<id>.meta. During migration this helper also appends the same
# done:/failed: status event existing readers consume. It never calls a control,
# merge, park, teardown, cleanup, or forge command.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-completion-lib.sh
. "$SCRIPT_DIR/fm-completion-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

ID=${1:-}
[ -n "$ID" ] || usage
shift
fm_pr_task_id_valid "$ID" || die "invalid task id"
SPAWN_GEN=${FM_SPAWN_GEN:-}
OUTCOME=
SUMMARY=
ARTIFACT=
PR_URL=
while [ $# -gt 0 ]; do
  case "$1" in
    --spawn-gen) SPAWN_GEN=${2-}; shift 2 || usage ;;
    --outcome) OUTCOME=${2-}; shift 2 || usage ;;
    --summary) SUMMARY=${2-}; shift 2 || usage ;;
    --artifact) ARTIFACT=${2-}; shift 2 || usage ;;
    --pr) PR_URL=${2-}; shift 2 || usage ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
fm_completion_token_valid "$SPAWN_GEN" || die "--spawn-gen is required and must be a safe token"
case "$OUTCOME" in done|failed) : ;; *) die "--outcome must be done or failed" ;; esac
[ -n "$SUMMARY" ] || die "--summary is required"
case "$SUMMARY" in *$'\n'*|*$'\r'*) die "--summary must be one line" ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] || die "no task metadata for $ID"
KIND=$(fm_backend_meta_exact_value "$META" kind) || die "task $ID has no exact kind"
[ "$KIND" != secondmate ] || die "persistent secondmates are outside the completion-receipt lifecycle"
case "$KIND" in
  scout) MODE=scout ;;
  ship) MODE=$(fm_backend_meta_exact_value "$META" mode) || die "ship task $ID has no exact mode" ;;
  *) die "unsupported task kind '$KIND'" ;;
esac
case "$MODE" in scout|no-mistakes|direct-PR|local-only) : ;; *) die "unsupported task mode '$MODE'" ;; esac
WT=$(fm_backend_meta_exact_value "$META" worktree) || die "task $ID has no exact worktree"
[ -d "$WT" ] || die "task $ID worktree is missing"
HEAD=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || die "cannot resolve worktree HEAD for $ID"
fm_pr_head_valid "$HEAD" || die "worktree HEAD for $ID is not a full object id"

if [ "$KIND" = scout ]; then
  [ -n "$ARTIFACT" ] || die "investigation completion requires --artifact with its report path"
  [ -f "$ARTIFACT" ] || die "investigation report path is not a file: $ARTIFACT"
fi
if [ -n "$ARTIFACT" ]; then
  case "$ARTIFACT" in *$'\n'*|*$'\r'*) die "artifact path must be one line" ;; esac
  ARTIFACT_DIR=$(CDPATH='' cd -- "$(dirname "$ARTIFACT")" 2>/dev/null && pwd -P) \
    || die "cannot resolve artifact path: $ARTIFACT"
  ARTIFACT="$ARTIFACT_DIR/$(basename "$ARTIFACT")"
fi
if [ "$MODE" = local-only ]; then
  [ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ] \
    || die "local-only completion requires a clean worktree"
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || die "local-only completion requires task branch fm/$ID, not detached HEAD"
  [ "$BRANCH" = "fm/$ID" ] || die "local-only completion requires task branch fm/$ID, found $BRANCH"
fi
if [ -n "$PR_URL" ]; then
  fm_pr_url_parse "$PR_URL" || die "--pr must be a canonical supported PR or MR URL"
  PR_URL=$FM_PR_URL
fi

LOCK=$(fm_meta_lock_path "$META") || die "cannot resolve metadata lock for $ID"
fm_lock_acquire_wait "$LOCK"
LOCK_HELD=1
cleanup() {
  local rc=$?
  [ "${LOCK_HELD:-0}" -eq 0 ] || fm_lock_release "$LOCK"
  [ -z "${TMP:-}" ] || rm -f "$TMP" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT INT TERM
CURRENT_GEN=$(fm_backend_meta_exact_value "$META" spawn_gen) || die "task $ID has no exact spawn generation"
[ "$CURRENT_GEN" = "$SPAWN_GEN" ] || die "stale spawn generation for $ID (receipt rejected)"

DEST="$STATE/$ID.completion-receipt"
TMP="$STATE/.$ID.completion-receipt.${BASHPID:-$$}"
OLD_UMASK=$(umask)
umask 077
{
  printf 'schema=%s\n' "$FM_COMPLETION_SCHEMA"
  printf 'task_id=%s\n' "$ID"
  printf 'spawn_gen=%s\n' "$SPAWN_GEN"
  printf 'kind=%s\n' "$KIND"
  printf 'mode=%s\n' "$MODE"
  printf 'outcome=%s\n' "$OUTCOME"
  printf 'artifact_path=%s\n' "$ARTIFACT"
  printf 'worktree_head=%s\n' "$HEAD"
  printf 'created_epoch=%s\n' "$(date +%s)"
  [ -z "$PR_URL" ] || printf 'pr_url=%s\n' "$PR_URL"
} > "$TMP" || die "could not write completion receipt temporary file"
umask "$OLD_UMASK"
fm_completion_receipt_load "$TMP" "$ID" "$SPAWN_GEN" || die "generated completion receipt failed schema validation"
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  fm_completion_receipt_load "$DEST" || die "existing completion receipt is malformed; refusing to replace it"
  if [ "$FM_COMPLETION_SPAWN_GEN" = "$SPAWN_GEN" ]; then
    cmp -s <(grep -v '^created_epoch=' "$DEST") <(grep -v '^created_epoch=' "$TMP") \
      || die "current incarnation already has a different completion receipt"
    rm -f "$TMP"
    TMP=
  fi
fi
if [ -n "$TMP" ]; then
  mv -f "$TMP" "$DEST" || die "could not atomically publish completion receipt"
  TMP=
fi
fm_lock_release "$LOCK"
LOCK_HELD=0
trap - EXIT INT TERM

STATUS_LINE="$OUTCOME: $SUMMARY"
if [ "$(tail -n 1 "$STATE/$ID.status" 2>/dev/null || true)" != "$STATUS_LINE" ]; then
  printf '%s\n' "$STATUS_LINE" >> "$STATE/$ID.status" || die "receipt published but legacy status append failed"
fi
FM_SHADOW_TRIGGER=completion "$SCRIPT_DIR/fm-completion-shadow.sh" record "$ID" >/dev/null 2>&1 || true
printf '%s\n' "$DEST"
