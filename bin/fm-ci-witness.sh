#!/usr/bin/env bash
# Verify a structural CI witness exception and optionally record publication.
# Usage: fm-ci-witness.sh <task-id> <GitHub-PR-url> --skip|--record
# --skip verifies the live PR/head, all controllable no-mistakes gates and the
# structural evidence, then responds only to the awaiting CI gate with skip.
# --record requires a passing run whose CI is skipped with that same structural
# proof (or completed green on a fork), or a running CI monitor: green on a fork,
# otherwise structurally unwitnessed. Green needs the destination's own completed
# workflow runs at the head; absence covers an owned or fork destination alike. It records the witness on task metadata and
# holds a published contribution externally through fm-backlog-transition-lib.
# A structurally unwitnessed running monitor is then ended with an explicit
# `no-mistakes axi abort --run <id>`, the only way the pipeline ends a monitor
# short of merge or close. The pipeline records that run's outcome as cancelled;
# the witness on task metadata, not that label, carries the truth: every
# controllable gate passed and CI was structurally not witnessed, not abandoned.
# Re-run --record after interruption to finish a metadata/hold/abort sequence.
# Origin fetch/push URLs and the API are re-read rather than trusting the
# dispatch hint or a worker's report. Unknown, pending and failing CI refuse.
# This script never merges, closes a task, or removes its worktree/endpoint.
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

refuse() { echo "REFUSED: $*" >&2; exit 1; }
[ "$#" = 3 ] || refuse 'expected task id, PR URL and --skip or --record'
ID=$1 URL=$2 ACTION=$3
case "$ACTION" in --skip|--record) ;; *) refuse 'unknown action' ;; esac
fm_pr_task_id_valid "$ID" || refuse 'invalid task identity'
fm_pr_url_parse "$URL" || refuse 'invalid PR identity'
[ "$FM_PR_PROVIDER" = github ] && [ "$FM_PR_HOST" = github.com ] || refuse 'CI witness requires a GitHub destination'
URL=$FM_PR_URL
HOME_ROOT=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$HOME_ROOT/state}
DATA=${FM_DATA_OVERRIDE:-$HOME_ROOT/data}
CONFIG=${FM_CONFIG_OVERRIDE:-$HOME_ROOT/config}
META=$STATE/$ID.meta
fm_pr_private_file_valid "$META" 600 "$(fm_pr_file_device "$STATE")" || refuse 'task metadata is unavailable'
LOCK=$(fm_meta_lock_path "$META") || refuse 'cannot resolve metadata lock'
fm_lock_acquire_wait "$LOCK" || refuse 'cannot acquire metadata lock'
TMP=
cleanup() { [ -z "$TMP" ] || rm -f -- "$TMP"; fm_lock_release "$LOCK" || true; }
trap cleanup EXIT
get() { sed -n "s/^$1=//p" "$META" | tail -1; }
[ "$(get kind)" = ship ] && [ "$(get mode)" = no-mistakes ] || refuse 'requires a no-mistakes ship'
WT=$(get worktree)
[ -d "$WT" ] || refuse 'worker copy is missing'
HEAD=$(git -C "$WT" rev-parse HEAD) || refuse 'cannot read worker head'
BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD) || refuse 'worker is not on its ship branch'
FORK=0
! fm_dod_origin_is_fork "$WT" || FORK=1
RUN=$(cd "$WT" && no-mistakes axi status) || refuse 'cannot read pipeline evidence'
[ "$(fm_nm_strip_quotes "$(fm_nm_field "$RUN" branch)")" = "$BRANCH" ] || refuse 'pipeline branch does not match task'
[ "$(fm_nm_strip_quotes "$(fm_nm_field "$RUN" pr)")" = "$URL" ] || refuse 'pipeline PR does not match task'
RUN_HEAD=$(fm_nm_branch_sync_nested "$RUN" pipeline current_head)
[ -n "$RUN_HEAD" ] || RUN_HEAD=$(fm_nm_strip_quotes "$(fm_nm_field "$RUN" head_sha)")
[ "$RUN_HEAD" = "$HEAD" ] || refuse 'pipeline head does not match worker head'
RUN_ID=$(fm_nm_strip_quotes "$(fm_nm_field "$RUN" id)")
CI=skipped
if [ "$ACTION" = --skip ]; then CI=awaiting_approval
elif fm_dod_nm_witness_gates "$RUN" running; then CI=running
elif [ "$FORK" = 1 ] && fm_dod_nm_witness_gates "$RUN" completed; then CI=completed
fi
fm_dod_nm_witness_gates "$RUN" "$CI" || refuse 'all controllable gates must have completed and CI must be at the required gate/outcome'
if [ "$CI" = completed ]; then
  fm_dod_pr_ci_green "$URL" "$HEAD" || refuse 'CI is not witnessed green at the open published head'
  WITNESS=green
elif [ "$CI" = running ] && [ "$FORK" = 1 ] && fm_dod_pr_ci_green "$URL" "$HEAD"; then
  WITNESS=green
else
  WITNESS=$(fm_dod_ci_not_witnessed "$WT" "$URL" "$HEAD") || refuse 'no structural CI exception was witnessed; slow, pending, red and unreadable checks never qualify'
fi
ABORT=
if [ "$CI" = running ] && [ "$WITNESS" != green ]; then
  case "$RUN_ID" in ''|*[!A-Za-z0-9._-]*) refuse 'cannot identify the running CI monitor' ;; esac
  ABORT="; no-mistakes run $RUN_ID CI monitor ended by explicit abort, so the pipeline records that run as cancelled, not abandoned"
fi
if [ "$ACTION" = --skip ]; then
  # Only this verified action reaches the third-party pipeline. Its return owns
  # the next gate/outcome; a timed-out hold is not itself a completed run.
  cd "$WT"
  printf 'CI not witnessed: %s; PR %s; head %s\n' "$WITNESS" "$URL" "$HEAD"
  no-mistakes axi respond --step ci --action skip --wait 1s
  exit $?
fi
OUTCOME=$(fm_nm_strip_quotes "$(fm_nm_field "$RUN" outcome)")
case "$OUTCOME:$CI" in
  passed:*|passed-with-skips:*|passed-with-override:*|:running) ;;
  *) refuse 'pipeline has no passing outcome or witnessed-green CI-ready monitor' ;;
esac
if [ "$FORK" = 1 ]; then
  REASON="published, waiting on upstream; gates intent rebase review test document lint push pr passed; CI"
  case "$WITNESS" in
    green) REASON="$REASON witnessed green" ;;
    absent) REASON="$REASON not witnessed - absent: destination has no configured workflows or checks, and none ever on its default branch" ;;
    *) REASON="$REASON not witnessed - destination withholds fork workflows pending maintainer approval" ;;
  esac
  REASON="$REASON; PR $URL; wait owned by destination maintainers$ABORT"
else
  [ "$WITNESS" = absent ] || refuse 'owned repository must use its ordinary green CI path'
  REASON="gates intent rebase review test document lint push pr passed; CI not witnessed - absent: no configured workflows or checks, and none ever on the default branch; PR $URL; awaiting configured merge authority$ABORT"
fi
# Stage a recoverable witness before the backlog transition. Repeating --record
# rechecks all evidence and reapplies the same external hold if it was interrupted.
TMP=$(mktemp "$STATE/.ci-witness.XXXXXX")
awk -F= '$1 !~ /^(ci_witness|ci_witness_head|ci_witness_report|ci_witness_run|delivery_state|pr|pr_head)$/' "$META" > "$TMP"
printf 'ci_witness=%s\nci_witness_head=%s\nci_witness_report=%s\npr=%s\npr_head=%s\n' "$WITNESS" "$HEAD" "$REASON" "$URL" "$HEAD" >> "$TMP"
[ "$FORK" != 1 ] || printf 'delivery_state=published\n' >> "$TMP"
[ -z "$ABORT" ] || printf 'ci_witness_run=%s\n' "$RUN_ID" >> "$TMP"
chmod 600 "$TMP"
mv -f -- "$TMP" "$META"
TMP=
if [ "$FORK" = 1 ]; then
  if fm_backlog_transition_applies "$CONFIG" "$DATA" ship; then
    fm_backlog_published "$DATA" "$ID" "$URL" "$REASON" || refuse "$FM_BACKLOG_TRANSITION_ERROR - rerun --record to finish publication"
  else
    RESULT=$?
    [ "$RESULT" = 1 ] || refuse "$FM_BACKLOG_TRANSITION_ERROR"
    echo "Manual backlog: hold $ID externally with witness: $REASON"
  fi
fi
if [ -n "$ABORT" ]; then
  (cd "$WT" && no-mistakes axi abort --run "$RUN_ID") >&2 || refuse 'witness recorded but the CI monitor did not end - rerun --record'
fi
printf 'witness: %s\n' "$REASON"
