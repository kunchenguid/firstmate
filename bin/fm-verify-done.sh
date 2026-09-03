#!/usr/bin/env bash
# fm-verify-done.sh - decide whether a task's terminal `done:` claim is true.
#
# A worker asserts; this script establishes. It never reads the claim's prose
# for evidence: the claim supplies only the identity it is claiming (the
# grammar and the durable verdict record are owned by bin/fm-done-claim-lib.sh),
# and every fact used to judge it comes from the forge, from git, or from the
# validation run's own record.
#
# Usage: fm-verify-done.sh <task-id> [--quiet]
#
# Checks, by delivery mode:
#   no-mistakes, direct-PR
#     - the claim names a parseable PR/MR URL
#     - the forge reports that PR, and it is not closed-without-merging
#     - the PR's current head commit equals the claimed head=
#     - (no-mistakes only) the commit the validation run recorded as validated
#       equals the claimed head=, so a fix pushed after validation, or a
#       force-push over a validated head, cannot pass as validated work
#     - the checks state is RECORDED as fact, never judged: a claim is not
#       contradicted for having red or absent checks, because merge authority,
#       not this script, owns that decision
#   local-only
#     - the claim names this task's own branch, exactly fm/<task-id>
#     - the claimed head= resolves in the task's local copy and is the tip of
#       that branch, AND that branch has moved since git created it.
#       bin/fm-brief.sh has every worker create fm/<task-id> before it does any
#       work, so the branch exists at the spawn base from the outset: a branch
#       still sitting exactly where it was created is positive evidence that it
#       introduced nothing, whatever the claim says. The branch's own history is
#       the authority for that, not its merge base with the default branch:
#       local-only work is on the default branch by the time it may be torn
#       down, so a merge base equal to the branch tip is the ordinary shape of
#       LANDED work and would contradict every honest claim. A branch history
#       that cannot be read is absence of evidence and reads unverified.
#     - once the branch has been retired after the work merged, the claimed head
#       must be BOTH the local copy's own HEAD and contained in the local default
#       branch. Bare containment is never enough: every commit already on the
#       default branch is its own ancestor, so containment alone would pass any
#       claim naming the default branch's tip. The merge-base test has no
#       counterpart here because the branch ref it needs is gone; what stands in
#       its place is that git refuses to delete a branch a worktree has checked
#       out, so a worker still sitting on an un-retired fm/<task-id> can never
#       reach this arm.
#   scout
#     - the claimed report= exists as a non-empty regular file. An absolute path
#       is used as given (what bin/fm-brief.sh renders into a scout brief); a
#       relative one is resolved against the home's data root, which is where
#       every scout report lives, so a relocated FM_DATA_OVERRIDE resolves the
#       same claim as an unrelocated one. A leading `data/` is the home-relative
#       spelling of that root and names it rather than a directory beneath it.
#
# A task whose meta records no mode= - the population spawned before mode= was
# recorded - is routed by the shape of its own claim, because an absent record is
# the absence of evidence and must never produce contradicted: a claim carrying
# branch= and no pr= takes the local-only arm, one carrying pr= takes the PR arm
# as no-mistakes so the validated-commit check still runs for it, and one
# carrying both or neither is unverified, naming the unrecorded mode as the thing
# that could not be established. bin/fm-teardown.sh keeps its own default; the
# point is that two owners of the same meta must not disagree in a way that
# reports a true claim as false.
#
# Verdicts, written to state/<id>.done-verdict and printed on stdout:
#   verified      exit 0
#   unverified    exit 3 - a required fact could NOT be established (forge
#                 unreachable, no validation run recorded, legacy claim with no
#                 commit identity). Never a pass: not knowing is not proof.
#   contradicted  exit 4 - a required fact WAS established and the claim is false.
# exit 2 - the task has no terminal claim to verify, or the request is invalid.
#
# The verdict record binds to the exact claim line it judged, so appending a new
# `done:` line invalidates it rather than inheriting its verdict.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-done-claim-lib.sh
. "$SCRIPT_DIR/fm-done-claim-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"

QUIET=0
ID=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    # The whole leading comment block, found rather than hard-coded, so editing
    # the header cannot silently truncate the help it is.
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    -*) echo "fm-verify-done: unknown option $1" >&2; exit 2 ;;
    *) [ -z "$ID" ] || { echo "fm-verify-done: one task id" >&2; exit 2; }; ID=$1 ;;
  esac
  shift
done
[ -n "$ID" ] || { echo "usage: fm-verify-done.sh <task-id> [--quiet]" >&2; exit 2; }
fm_pr_task_id_valid "$ID" || { echo "fm-verify-done: invalid task id" >&2; exit 2; }

META="$STATE/$ID.meta"
# The bounded no-mistakes read below; the same shape fm-crew-state.sh uses.
NM_TIMEOUT=${FM_VERIFY_DONE_NM_TIMEOUT:-20}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=20 ;; esac
GH_TIMEOUT=${FM_VERIFY_DONE_GH_TIMEOUT:-30}
case "$GH_TIMEOUT" in ''|*[!0-9]*) GH_TIMEOUT=30 ;; esac

meta_field() {  # <key>
  [ -f "$META" ] || return 0
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

VERDICT=
REASON=
verdict_is() {  # <verdict> <reason>
  VERDICT=$1
  REASON=$2
}

# Record the outcome and exit. The record is written before the exit code is
# chosen so a caller that only reads the record and a caller that only reads
# the status agree.
finish() {
  local hash rc=0
  case "$VERDICT" in
    verified) rc=0 ;;
    unverified) rc=3 ;;
    contradicted) rc=4 ;;
    *) rc=2 ;;
  esac
  if hash=$(fm_done_claim_hash "$FM_DONE_CLAIM_LINE"); then
    fm_done_verdict_write "$STATE" "$ID" "$VERDICT" "$hash" "$REASON" \
      || echo "fm-verify-done: could not record the verdict for $ID" >&2
  else
    echo "fm-verify-done: could not compute a claim identity for $ID" >&2
    rc=3
  fi
  [ "$QUIET" -eq 1 ] || printf '%s: %s\n' "$VERDICT" "$REASON"
  exit "$rc"
}

CLAIM=$(fm_done_claim_last "$STATE/$ID.status")
if [ -z "$CLAIM" ]; then
  echo "fm-verify-done: $ID has made no terminal claim to verify" >&2
  exit 2
fi
FM_DONE_CLAIM_LINE=$CLAIM
fm_done_claim_parse "$CLAIM" || { echo "fm-verify-done: $ID has no terminal claim to verify" >&2; exit 2; }

KIND=$(meta_field kind); [ -n "$KIND" ] || KIND=ship
MODE=$(meta_field mode)
WT=$(meta_field worktree)

if ! fm_done_claim_has_identity; then
  verdict_is unverified 'legacy claim, no commit identity'
  finish
fi

# --- scout: the deliverable is the report ------------------------------------
if [ "$KIND" = scout ]; then
  REPORT=$FM_DONE_CLAIM_REPORT
  if [ -z "$REPORT" ]; then
    verdict_is contradicted 'scout claim names no report'
    finish
  fi
  case "$REPORT" in
    /*) ;;
    data/*) REPORT="$DATA/${REPORT#data/}" ;;
    *) REPORT="$DATA/$REPORT" ;;
  esac
  # A symlink is refused as evidence rather than followed, but refusing to read
  # something is not proof that it is false: the report may be perfectly present
  # behind the link. That is absence of evidence, so it names the link and reads
  # unverified.
  if [ -L "$REPORT" ]; then
    verdict_is unverified "the claimed report is a symlink, which is not read as evidence: $FM_DONE_CLAIM_REPORT"
    finish
  fi
  if [ -f "$REPORT" ] && [ -s "$REPORT" ]; then
    verdict_is verified "report present at $FM_DONE_CLAIM_REPORT"
  else
    verdict_is contradicted "claimed report is missing or empty: $FM_DONE_CLAIM_REPORT"
  fi
  finish
fi

# A task spawned before mode= was recorded has none, and no record is the absence
# of evidence: it may never make a true claim come back contradicted. The claim's
# own shape decides instead, because it is unambiguous in both common cases - a
# local-only claim names its branch and no PR, a PR claim names its PR. A claim
# naming both or neither establishes nothing about the mode, and says so.
if [ -z "$MODE" ]; then
  if [ -n "$FM_DONE_CLAIM_BRANCH" ] && [ -z "$FM_DONE_CLAIM_PR" ]; then
    MODE=local-only
  elif [ -n "$FM_DONE_CLAIM_PR" ] && [ -z "$FM_DONE_CLAIM_BRANCH" ]; then
    # Read as no-mistakes so this legacy population still faces the
    # validated-commit check rather than skipping it.
    MODE=no-mistakes
  else
    verdict_is unverified 'this task records no delivery mode and the claim names neither a branch alone nor a PR alone, so the mode it should be judged against cannot be established'
    finish
  fi
fi

HEAD_CLAIM=$FM_DONE_CLAIM_HEAD
if ! fm_done_claim_head_valid "$HEAD_CLAIM"; then
  verdict_is unverified 'claim carries no full commit id'
  finish
fi

# --- local-only: git is the whole authority ----------------------------------
if [ "$MODE" = local-only ]; then
  BRANCH=$FM_DONE_CLAIM_BRANCH
  if [ -z "$BRANCH" ]; then
    verdict_is contradicted 'local-only claim names no branch'
    finish
  fi
  # A local-only task's branch is not a free field: bin/fm-brief.sh renders the
  # claim template with this task's own fm/<id>. A claim naming anything else is
  # not this task's work, however true it may be of some other branch.
  if [ "$BRANCH" != "fm/$ID" ]; then
    verdict_is contradicted "claim names branch $BRANCH, not this task's fm/$ID"
    finish
  fi
  if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    verdict_is unverified 'the local copy is gone, so the claimed commit cannot be established'
    finish
  fi
  if ! git -C "$WT" rev-parse --verify --quiet "$HEAD_CLAIM^{commit}" >/dev/null 2>&1; then
    verdict_is contradicted "claimed commit $HEAD_CLAIM does not exist in the local copy"
    finish
  fi
  DEFAULT=$(fm_default_branch "$WT" 2>/dev/null || true)
  DEFAULT_REF=
  if [ -n "$DEFAULT" ] \
    && git -C "$WT" rev-parse --verify --quiet "refs/heads/$DEFAULT^{commit}" >/dev/null 2>&1; then
    DEFAULT_REF="refs/heads/$DEFAULT"
  fi
  TIP=$(git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" 2>/dev/null || true)
  if [ -n "$TIP" ]; then
    if [ "$TIP" != "$HEAD_CLAIM" ]; then
      verdict_is contradicted "branch $BRANCH is at $TIP, not the claimed $HEAD_CLAIM"
      finish
    fi
    # Being the branch tip is not the same as being this task's work. Every
    # worker creates fm/<id> at the spawn base before it does anything, so a
    # worker that commits nothing leaves the branch existing and pointing at
    # that base. The commit the claim names must be one the branch introduced,
    # which is what the branch's own history in git says: a branch still sitting
    # exactly where it was created has introduced nothing, whatever is claimed
    # of it. Its history being unreadable is absence of evidence, not falsity.
    CREATED=$(git -C "$WT" reflog show --format=%H "refs/heads/$BRANCH" 2>/dev/null | tail -1 || true)
    case "$CREATED" in *[!0-9a-f]*|'') CREATED= ;; esac
    if [ -z "$CREATED" ]; then
      verdict_is unverified "branch $BRANCH is at the claimed $HEAD_CLAIM, but its own history could not be read, so what $BRANCH introduced cannot be established"
      finish
    fi
    if [ "$CREATED" = "$HEAD_CLAIM" ]; then
      verdict_is contradicted "branch $BRANCH introduced nothing: it is still at $HEAD_CLAIM, the commit it was created at"
      finish
    fi
    verdict_is verified "branch $BRANCH is at the claimed $HEAD_CLAIM, which it introduced after being created at $CREATED"
    finish
  fi
  # The branch is gone. That is the normal end state once local-only work has
  # been merged and its branch retired, but containment in the default branch
  # cannot stand in for the branch tip on its own: a commit is its own ancestor,
  # so every commit already on the default branch satisfies containment, and a
  # worker that committed nothing could pass by naming the default branch's tip.
  # The task's own local copy supplies the missing evidence. A worker that
  # produced the claimed commit left its worktree sitting on it; one that
  # produced nothing left its worktree at the spawn base.
  WT_HEAD=$(git -C "$WT" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  if [ -z "$WT_HEAD" ]; then
    verdict_is unverified "branch $BRANCH is gone and the local copy's own HEAD could not be read, so the claimed $HEAD_CLAIM cannot be established"
    finish
  fi
  if [ "$WT_HEAD" != "$HEAD_CLAIM" ]; then
    verdict_is unverified "branch $BRANCH is gone and the local copy's own HEAD is $WT_HEAD, not the claimed $HEAD_CLAIM, so nothing establishes that this task produced it"
    finish
  fi
  if [ -z "$DEFAULT_REF" ]; then
    verdict_is unverified "branch $BRANCH is gone and the local copy has no default branch to check the claimed $HEAD_CLAIM against"
    finish
  fi
  if git -C "$WT" merge-base --is-ancestor "$HEAD_CLAIM" "$DEFAULT_REF" 2>/dev/null; then
    verdict_is verified "the local copy is at the claimed $HEAD_CLAIM and it is on $DEFAULT; its branch $BRANCH has been retired"
    finish
  fi
  verdict_is contradicted "branch $BRANCH is gone and the claimed $HEAD_CLAIM is not on $DEFAULT"
  finish
fi

# --- PR modes ----------------------------------------------------------------
PR_CLAIM=$FM_DONE_CLAIM_PR
if [ -z "$PR_CLAIM" ]; then
  verdict_is contradicted 'claim names no PR'
  finish
fi
if ! fm_pr_url_parse "$PR_CLAIM"; then
  verdict_is contradicted "claim names an unparseable PR reference: $PR_CLAIM"
  finish
fi
PROVIDER=$FM_PR_PROVIDER
PR_URL=$FM_PR_URL

# glab exposes a merge request's head commit only inside its JSON output, which
# would need a JSON processor firstmate does not require (the same reason
# bin/fm-pr-check.sh records no pr_head for GitLab). That is a standing provider
# limitation rather than a transient failure, so it is named as one: the claim
# stays unverified however many times it is re-run, and cleanup of such a task
# needs the captain's explicit discard authority.
if [ "$PROVIDER" != github ]; then
  verdict_is unverified "the $PROVIDER forge does not expose a head commit through its CLI, so the shipped commit cannot be established for $PR_URL and re-running will not change that"
  finish
fi
if ! command -v gh >/dev/null 2>&1; then
  verdict_is unverified 'gh is not on PATH, so the forge could not be asked'
  finish
fi

# Addressed by its full validated URL, so gh resolves the repository from the
# URL and needs no checkout - the same way the merge poll asks (bin/fm-pr-poll.sh).
# The checks fallback is PER ENTRY, not per field across the whole list: a
# rollup mixes check runs (.conclusion, null while still running, then .status)
# with commit statuses (.state), and a list-wide fallback silently drops every
# entry of the other shape - reporting SUCCESS for a pull request that still has
# a pending or in-progress check. Deduplicated so the recorded fact stays short
# and stable rather than repeating one word per check.
VIEW=$(fm_run_timed "$GH_TIMEOUT" gh pr view "$PR_URL" \
  --json state,headRefOid,url,statusCheckRollup \
  -q '.state + "\t" + .headRefOid + "\t" + ([.statusCheckRollup[]? | (.conclusion // .status // .state // "UNKNOWN")] | unique | join(","))' \
  2>/dev/null) || VIEW=
VIEW=$(printf '%s\n' "$VIEW" | head -1)
if [ -z "$VIEW" ]; then
  verdict_is unverified "the forge could not be reached for $PR_URL, so the shipped commit is unknown"
  finish
fi
PR_STATE=${VIEW%%$'\t'*}
REST=${VIEW#*$'\t'}
if [ "$PR_STATE" = "$VIEW" ]; then
  verdict_is unverified "the forge answer for $PR_URL could not be read"
  finish
fi
PR_HEAD=${REST%%$'\t'*}
CHECKS=${REST#*$'\t'}
[ "$PR_HEAD" != "$REST" ] || CHECKS=
[ -n "$CHECKS" ] || CHECKS='none reported'

case "$PR_STATE" in
  CLOSED|closed)
    verdict_is contradicted "$PR_URL is closed without merging, so this task is not done"
    finish
    ;;
  OPEN|open|MERGED|merged) ;;
  *)
    verdict_is unverified "the forge reports an unrecognised state '$PR_STATE' for $PR_URL"
    finish
    ;;
esac

if [ -z "$PR_HEAD" ]; then
  verdict_is unverified "the forge reported no head commit for $PR_URL"
  finish
fi
if [ "$PR_HEAD" != "$HEAD_CLAIM" ]; then
  verdict_is contradicted "$PR_URL is at $PR_HEAD, not the claimed $HEAD_CLAIM"
  finish
fi

if [ "$MODE" != no-mistakes ]; then
  verdict_is verified "$PR_URL is $PR_STATE at the claimed $HEAD_CLAIM; checks: $CHECKS"
  finish
fi

# --- the check that catches a validated-but-not-shipped commit ---------------
# The claim is only true if the commit the pipeline validated is the commit the
# PR now carries. A docstring "no-op" pushed after validation, or a force-push
# over the validated head, both land here.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  verdict_is unverified 'the local copy is gone, so the validated commit cannot be established'
  finish
fi
if ! command -v no-mistakes >/dev/null 2>&1; then
  verdict_is unverified 'no-mistakes is not on PATH, so the validated commit could not be established'
  finish
fi
RUN_OUT=$(fm_nm_run_checked "$WT" "$NM_TIMEOUT" axi status) || RUN_OUT=
if [ -z "$RUN_OUT" ]; then
  verdict_is unverified 'no validation run is recorded for this work, so the validated commit is unknown'
  finish
fi
RUN_BRANCH=$(fm_nm_strip_quotes "$(fm_nm_field "$RUN_OUT" branch)")
WT_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ -z "$RUN_BRANCH" ] || [ -z "$WT_BRANCH" ] || [ "$RUN_BRANCH" != "$WT_BRANCH" ]; then
  verdict_is unverified 'no validation run is attributed to this work, so the validated commit is unknown'
  finish
fi
RUN_HEAD=$(fm_nm_strip_quotes "$(fm_nm_field "$RUN_OUT" head)")
if [ -z "$RUN_HEAD" ]; then
  verdict_is unverified 'the validation run records no commit, so the validated commit is unknown'
  finish
fi
# The run may abbreviate; compare on the shorter of the two, which is exact for
# any abbreviation git itself would produce.
if [ "${HEAD_CLAIM#"$RUN_HEAD"}" = "$HEAD_CLAIM" ]; then
  verdict_is contradicted "validation ran against $RUN_HEAD, but the claim ships $HEAD_CLAIM"
  finish
fi
RUN_OUTCOME=$(fm_nm_strip_quotes "$(fm_nm_field "$RUN_OUT" outcome)")
RUN_STATUS=$(fm_nm_strip_quotes "$(fm_nm_field "$RUN_OUT" status)")
verdict_is verified "$PR_URL is $PR_STATE at the claimed $HEAD_CLAIM, validated at $RUN_HEAD (run ${RUN_OUTCOME:-$RUN_STATUS}); checks: $CHECKS"
finish
