#!/usr/bin/env bash
# fm-secondmate-report.sh - optional helper to append a correlated parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh).
#
# Usage:
#   fm-secondmate-report.sh <status-file> <verb> <corr_id> <note...>
#   fm-secondmate-report.sh --doc <status-file> <verb> <corr_id> <doc-path> <note...>
#   fm-secondmate-report.sh --local-ready <status-file> <corr_id> <task-meta> <validation-evidence...>
#
# Examples:
#   fm-secondmate-report.sh "$STATUS" done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --doc "$STATUS" done abcdef0123456789 data/x/report.md "see report"
#   fm-secondmate-report.sh --local-ready "$STATUS" abcdef0123456789 state/fix.meta "scripts/gate.sh passed"
#
# The status file must be the absolute parent route from the secondmate charter
# (state/<id>.status under the PARENT home), never a path relative to this
# secondmate home. Writing under the wrong home is detected as supporting
# evidence by the parent pending-reply guard and does not acknowledge the
# request.
#
# --local-ready is the local-only ready-result path. It refuses unless task
# metadata lives in a marked secondmate home and records a clean exact HEAD on
# the expected fm/<id> branch plus non-empty validation evidence before it
# reports that result to the parent. It never lands the work.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-secondmate-report.sh <status-file> <verb> <corr_id> <note...>
  fm-secondmate-report.sh --doc <status-file> <verb> <corr_id> <doc-path> <note...>
  fm-secondmate-report.sh --local-ready <status-file> <corr_id> <task-meta> <validation-evidence...>
EOF
  exit 2
}

DOC_MODE=0
LOCAL_READY_MODE=0
if [ "${1:-}" = "--doc" ]; then
  DOC_MODE=1
  shift
elif [ "${1:-}" = "--local-ready" ]; then
  LOCAL_READY_MODE=1
  shift
fi

if [ "$LOCAL_READY_MODE" = 1 ]; then
  [ $# -ge 4 ] || usage
  STATUS_FILE=$1
  CORR=$2
  TASK_META=$3
  shift 3
  VALIDATION_EVIDENCE=$*
  VERB='done'
else
  [ $# -ge 4 ] || usage
  STATUS_FILE=$1
  VERB=$2
  CORR=$3
  shift 3
fi

case "$CORR" in
  corr=*) CORR=${CORR#corr=} ;;
esac
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    exit 1
    ;;
esac

case "$STATUS_FILE" in
  '') usage ;;
esac
mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true
if [ ! -d "$(dirname "$STATUS_FILE")" ]; then
  echo "error: cannot create parent directory for status file '$STATUS_FILE'" >&2
  exit 1
fi

token=$(fm_pending_reply_corr_token "$CORR")
if [ "$LOCAL_READY_MODE" = 1 ]; then
  case "$VALIDATION_EVIDENCE" in
    ''|*$'\n'*|*$'\r'*)
      echo "error: local-ready validation evidence must be one non-empty line" >&2
      exit 1
      ;;
  esac
  [ -f "$TASK_META" ] || { echo "error: local-ready task metadata not found: $TASK_META" >&2; exit 1; }
  STATE_DIR=$(dirname "$TASK_META")
  SECOND_MATE_HOME=$(dirname "$STATE_DIR")
  [ "$(basename "$STATE_DIR")" = state ] \
    || { echo "error: local-ready task metadata must live under a secondmate state directory: $TASK_META" >&2; exit 1; }
  [ -f "$SECOND_MATE_HOME/.fm-secondmate-home" ] \
    || { echo "error: local-ready task metadata is not in a marked secondmate home: $TASK_META" >&2; exit 1; }

  TASK_ID=$(basename "$TASK_META" .meta)
  MODE=$(fm_meta_get "$TASK_META" mode)
  KIND=$(fm_meta_get "$TASK_META" kind)
  WORKTREE=$(fm_meta_get "$TASK_META" worktree)
  PROJECT=$(fm_meta_get "$TASK_META" project)
  [ "$MODE" = local-only ] \
    || { echo "error: local-ready task $TASK_ID is mode=${MODE:-unknown}, not local-only" >&2; exit 1; }
  [ "$KIND" = ship ] \
    || { echo "error: local-ready task $TASK_ID is kind=${KIND:-unknown}, not ship" >&2; exit 1; }
  [ -d "$WORKTREE" ] \
    || { echo "error: local-ready worktree is missing: ${WORKTREE:-<empty>}" >&2; exit 1; }
  [ -d "$PROJECT" ] \
    || { echo "error: local-ready project is missing: ${PROJECT:-<empty>}" >&2; exit 1; }

  BRANCH="fm/$TASK_ID"
  CURRENT_BRANCH=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$CURRENT_BRANCH" = "$BRANCH" ] \
    || { echo "error: local-ready worktree is on ${CURRENT_BRANCH:-detached}, expected $BRANCH" >&2; exit 1; }
  READY_COMMIT=$(git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null) \
    || { echo "error: cannot resolve local-ready HEAD in $WORKTREE" >&2; exit 1; }
  PROJECT_COMMIT=$(git -C "$PROJECT" rev-parse --verify "refs/heads/$BRANCH" 2>/dev/null || true)
  [ "$PROJECT_COMMIT" = "$READY_COMMIT" ] \
    || { echo "error: local-ready branch $BRANCH does not resolve to worktree HEAD $READY_COMMIT in $PROJECT" >&2; exit 1; }
  if ! WORKTREE_STATUS=$(git -C "$WORKTREE" status --porcelain 2>/dev/null); then
    echo "error: cannot inspect local-ready worktree status: $WORKTREE" >&2
    exit 1
  fi
  DIRTY=$(printf '%s\n' "$WORKTREE_STATUS" \
    | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' \
    | head -1 || true)
  [ -z "$DIRTY" ] \
    || { echo "error: local-ready worktree is dirty: $WORKTREE" >&2; exit 1; }

  META_TMP=
  meta_tmp_cleanup() {
    [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  }
  trap meta_tmp_cleanup EXIT
  META_TMP=$(mktemp "$STATE_DIR/.$(basename "$TASK_META").local-ready.XXXXXX") \
    || { echo "error: cannot stage local-ready metadata in $STATE_DIR" >&2; exit 1; }
  { grep -vE '^ready_commit=|^ready_branch=|^validation_evidence=' "$TASK_META" || true; } > "$META_TMP" \
    || { echo "error: cannot stage local-ready metadata for $TASK_META" >&2; exit 1; }
  printf 'ready_commit=%s\n' "$READY_COMMIT" >> "$META_TMP" || exit 1
  printf 'ready_branch=%s\n' "$BRANCH" >> "$META_TMP" || exit 1
  printf 'validation_evidence=%s\n' "$VALIDATION_EVIDENCE" >> "$META_TMP" || exit 1
  mv -f -- "$META_TMP" "$TASK_META" || exit 1
  META_TMP=
  printf '%s [%s]: local-only ready task=%s commit=%s branch=%s validation=%s (via-helper)\n' \
    "$VERB" "$token" "$TASK_ID" "$READY_COMMIT" "$BRANCH" "$VALIDATION_EVIDENCE" >> "$STATUS_FILE"
elif [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] || usage
  DOC_PATH=$1
  shift
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf '%s [%s]: %s (%s via-helper)\n' "$VERB" "$token" "$NOTE" "$DOC_PATH" >> "$STATUS_FILE"
  else
    printf '%s [%s]: %s (via-helper)\n' "$VERB" "$token" "$DOC_PATH" >> "$STATUS_FILE"
  fi
else
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf '%s [%s]: %s (via-helper)\n' "$VERB" "$token" "$NOTE" >> "$STATUS_FILE"
  else
    printf '%s [%s]: (via-helper)\n' "$VERB" "$token" >> "$STATUS_FILE"
  fi
fi
