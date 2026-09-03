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
#     - (direct-PR only) the branch the forge says the PR is built from is this
#       task's own fm/<task-id>. Without it the whole check is that the claim
#       and the forge agree about a head, which any open PR whose head a worker
#       states correctly would satisfy: consistency, not authorship. A
#       no-mistakes task needs no counterpart because the validated-commit check
#       already requires the run's branch to be this worktree's own.
#     - the checks state is RECORDED as fact, never judged: a claim is not
#       contradicted for having red or absent checks, because merge authority,
#       not this script, owns that decision
#   local-only
#     - the claim names this task's own branch, exactly fm/<task-id>
#     - the claimed head= resolves in the task's local copy and is the tip of
#       that branch, AND git's own log says the branch RECORDED a commit.
#       That last one is the question this arm asks, and it took three tries to
#       ask it. A merge base, then "the tip moved since creation", both tested
#       whether something CHANGED rather than whether this branch AUTHORED
#       anything - and bin/fm-brief.sh's local-only contract tells a worker to
#       rebase onto the default branch when it advances, so a worker that
#       commits nothing and obeys that instruction moves fm/<task-id> onto
#       someone else's work and satisfied both. Only an entry git writes when a
#       commit is recorded (`commit:`, `commit (amend):`, `commit (initial):`)
#       says this branch made something; a rebase preserves it, so honest work
#       that was later rebased still answers.
#     - once the branch has been retired after the work merged, the claimed head
#       must be BOTH the local copy's own HEAD and contained in the local default
#       branch, and the local copy's own history must record a commit it made.
#       Bare containment is never enough: every commit already on the default
#       branch is its own ancestor, so containment alone would pass any claim
#       naming the default branch's tip. Retiring the branch deletes the branch
#       reflog with it, so the authorship question is asked of the worktree's
#       HEAD log, which survives and records the same commits.
#     - a history that cannot be read, or whose oldest surviving entry is no
#       longer the creation (`git gc` prunes entries past gc.reflogExpire), or
#       that reaches back but records no commit, is all absence of evidence and
#       reads unverified. Only a branch demonstrably still sitting on the commit
#       it was created at is contradicted.
#   scout
#     - the claimed report= exists as a non-empty regular file INSIDE this task's
#       own directory under the home's data root. A file existing is not this
#       task having produced it, so the path is bound to <data>/<task-id>/ the
#       same way the local-only arm is bound to fm/<task-id>. That binding is
#       made on the real location, not on the spelling of one: a `report=`
#       carrying a `..` component is refused outright, and the containing
#       directory is then resolved physically before it is compared, so neither
#       an upward walk nor a directory symlink can present another task's
#       deliverable as this one's. An absolute path is used as given (what
#       bin/fm-brief.sh renders into a scout brief); a relative one is resolved
#       against the data root, so a relocated FM_DATA_OVERRIDE resolves the same
#       claim as an unrelocated one. A leading `data/` is the home-relative
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
# The line between the last two is enforced by fm_done_verdict_resolve (in
# bin/fm-done-claim-lib.sh), which every arm here records through, rather than
# left to each arm's care: a `contradicted` verdict must carry the observation it
# contradicts with, and one that carries none is recorded as `unverified`.
#
# There is a fourth verdict this script never reaches for and must still expect
# to find in the record it is re-judging: `stale`. Terminal evidence about a
# claim has THREE shapes, not two - absence of evidence (`unverified`), positive
# evidence of falsity (`contradicted`), and the world having CHANGED under a
# verdict that was true when it was made (`stale`). Only the site that observes
# a PR reach a terminal state can see the third, so bin/fm-merge-outcome-lib.sh
# writes it when a merge lands under an established claim. What that record asks
# for is exactly this script: `stale` is not established, so every gate re-runs
# the verifier against the world that now exists. See bin/fm-done-claim-lib.sh
# for the three shapes and the write precedence that keeps them apart.
#
# The verdict record binds to the exact claim line it judged, so appending a new
# `done:` line invalidates it rather than inheriting its verdict. A task whose
# claim a later `failed:` line has withdrawn has no claim to verify and exits 2:
# withdrawing a claim, not overriding the gate, is the way out of a false one
# (see fm_done_claim_last in bin/fm-done-claim-lib.sh).
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
# Every arm below records its verdict through here, and here defers to
# fm_done_verdict_resolve in bin/fm-done-claim-lib.sh - the owner of the verdict
# vocabulary - so the rule that `contradicted` must carry the observation it
# contradicts with is one implementation shared by every judging site, testable
# on its own, rather than a habit each arm has to remember. Read that helper for
# the rule and for the limit of what it can enforce.
verdict_is() {  # <verdict> <reason> [<observed>]
  fm_done_verdict_resolve "$1" "$2" "${3:-}"
  VERDICT=$FM_DONE_VERDICT_RESOLVED
  REASON=$FM_DONE_VERDICT_RESOLVED_REASON
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
    verdict_is contradicted 'scout claim names no report' "$FM_DONE_CLAIM_LINE"
    finish
  fi
  # A `..` component makes the spelling of a path and its location two different
  # things, and every containment test below is about the location. Refused
  # outright rather than normalised away: a scout report path has no legitimate
  # reason to walk upward, and the claim naming one is itself the observation.
  case "/$FM_DONE_CLAIM_REPORT/" in
    */../*)
      verdict_is contradicted "the claimed report walks out of its own directory: $FM_DONE_CLAIM_REPORT" \
        "$FM_DONE_CLAIM_REPORT"
      finish
      ;;
  esac
  case "$REPORT" in
    /*) ;;
    data/*) REPORT="$DATA/${REPORT#data/}" ;;
    *) REPORT="$DATA/$REPORT" ;;
  esac
  # A file existing is not this task having produced it. Every scout report lives
  # under the home's data root in the task's own directory, so a claim resolving
  # anywhere else names someone else's deliverable however real that file is -
  # the same binding the local-only arm makes by requiring branch = fm/<id>.
  #
  # Tested twice, on the spelling and then on the real location, because a prefix
  # match alone tests only how a path is written: this same binding was added to
  # stop a substitution and shipped with `..` walking straight through it. The
  # second test resolves both sides physically, so a directory symlink cannot
  # stand in for the walk either. A path that will not resolve is left to the
  # existence checks below, which report it as missing rather than as foreign.
  case "$REPORT" in
    "$DATA/$ID/"?*) ;;
    *)
      verdict_is contradicted "the claimed report is not this task's own: $FM_DONE_CLAIM_REPORT resolves to $REPORT, outside $DATA/$ID/" \
        "$REPORT"
      finish
      ;;
  esac
  # The task's own directory has to BE a directory for containment in it to mean
  # anything: a link there points containment wherever the link does. Refusing to
  # read it is not proof the claim is false, so it names the link and reads
  # unverified, exactly as the report symlink below does.
  if [ -L "$DATA/$ID" ]; then
    verdict_is unverified "this task's report directory is a symlink, which is not read as evidence: $DATA/$ID"
    finish
  fi
  REPORT_DIR=$(cd "$(dirname "$REPORT")" 2>/dev/null && pwd -P) || REPORT_DIR=
  OWN_DIR=$(cd "$DATA/$ID" 2>/dev/null && pwd -P) || OWN_DIR=
  if [ -n "$REPORT_DIR" ] && [ -n "$OWN_DIR" ]; then
    case "$REPORT_DIR/" in
      "$OWN_DIR/"*) ;;
      *)
        verdict_is contradicted "the claimed report is not this task's own: $FM_DONE_CLAIM_REPORT is really in $REPORT_DIR, outside $OWN_DIR" \
          "$REPORT_DIR"
        finish
        ;;
    esac
  fi
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
  elif [ ! -e "$REPORT" ]; then
    verdict_is contradicted "claimed report is missing: $FM_DONE_CLAIM_REPORT" \
      "nothing exists at $REPORT"
  elif [ ! -f "$REPORT" ]; then
    verdict_is contradicted "claimed report is not a file: $FM_DONE_CLAIM_REPORT" \
      "$REPORT is not a regular file"
  else
    verdict_is contradicted "claimed report is empty: $FM_DONE_CLAIM_REPORT" \
      "$REPORT is a regular file of zero bytes"
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

# The commit a named ref RECORDED, or empty when its log holds none. Movement is
# not authorship: bin/fm-brief.sh's local-only contract tells a worker to rebase
# onto the default branch when it advances, so a worker that commits nothing and
# follows that instruction fast-forwards fm/<id> onto someone else's work. The
# ref then differs from where it was created while having introduced nothing,
# which is why every earlier version of this test - a merge base, then "the tip
# moved" - passed a claim it should have refused. Only an entry git writes when a
# commit is RECORDED says this branch authored something, so that is what is
# read. A rebase preserves the original `commit:` entry, so honest work that was
# later rebased still answers here.
AUTHORED_AT=
ref_recorded_a_commit() {  # <git-dir-owner> <ref>
  local wt=$1 ref=$2 entry sha msg
  AUTHORED_AT=
  while IFS= read -r entry; do
    sha=${entry%% *}
    case "$entry" in *' '*) msg=${entry#* } ;; *) continue ;; esac
    case "$sha" in *[!0-9a-f]*|'') continue ;; esac
    case "$msg" in
      'commit: '*|'commit (amend): '*|'commit (initial): '*)
        AUTHORED_AT=$sha
        return 0
        ;;
    esac
  done <<EOF
$(git -C "$wt" reflog show --format='%H %gs' "$ref" 2>/dev/null || true)
EOF
  return 1
}

# --- local-only: git is the whole authority ----------------------------------
if [ "$MODE" = local-only ]; then
  BRANCH=$FM_DONE_CLAIM_BRANCH
  if [ -z "$BRANCH" ]; then
    verdict_is contradicted 'local-only claim names no branch' "$FM_DONE_CLAIM_LINE"
    finish
  fi
  # A local-only task's branch is not a free field: bin/fm-brief.sh renders the
  # claim template with this task's own fm/<id>. A claim naming anything else is
  # not this task's work, however true it may be of some other branch.
  if [ "$BRANCH" != "fm/$ID" ]; then
    verdict_is contradicted "claim names branch $BRANCH, not this task's fm/$ID" "$BRANCH"
    finish
  fi
  if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    verdict_is unverified 'the local copy is gone, so the claimed commit cannot be established'
    finish
  fi
  # Asked before anything is concluded from a git answer: a directory that is
  # not a readable repository answers "no such commit" to every question, and
  # reading that as falsity would contradict every honest claim made from a
  # copy whose .git has gone missing.
  if ! git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
    verdict_is unverified "the local copy at $WT is not a readable git repository, so the claimed commit cannot be established"
    finish
  fi
  if ! git -C "$WT" rev-parse --verify --quiet "$HEAD_CLAIM^{commit}" >/dev/null 2>&1; then
    verdict_is contradicted "claimed commit $HEAD_CLAIM does not exist in the local copy" \
      "the readable object database at $WT holds no commit $HEAD_CLAIM"
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
      verdict_is contradicted "branch $BRANCH is at $TIP, not the claimed $HEAD_CLAIM" "$TIP"
      finish
    fi
    # Being the branch tip is not the same as being this task's work. Every
    # worker creates fm/<id> at the spawn base before it does anything, so a
    # worker that commits nothing leaves the branch existing and pointing at
    # that base. The commit the claim names must be one the branch introduced,
    # which is what the branch's own history in git says: a branch still sitting
    # exactly where it was created has introduced nothing, whatever is claimed
    # of it. Its history being unreadable is absence of evidence, not falsity.
    #
    # The OLDEST SURVIVING reflog entry is only the creation point while the
    # creation entry survives. `git gc` prunes entries past gc.reflogExpire (90
    # days by default), and on a long-lived branch that leaves the oldest
    # surviving entry somewhere in the middle of the branch's life - possibly
    # the tip itself, which would read a true claim as falsity. So the entry is
    # required to SAY it is the creation ("branch: Created from ..."), which is
    # what git writes for `git checkout -b fm/<id>` (bin/fm-brief.sh's first
    # instruction to every worker). Anything else is a history that no longer
    # reaches back to the creation, which is absence of evidence.
    CREATED_ENTRY=$(git -C "$WT" reflog show --format='%H %gs' "refs/heads/$BRANCH" 2>/dev/null | tail -1 || true)
    CREATED=${CREATED_ENTRY%% *}
    case "$CREATED_ENTRY" in
      *' '*) CREATED_MSG=${CREATED_ENTRY#* } ;;
      *) CREATED_MSG= ;;
    esac
    case "$CREATED" in *[!0-9a-f]*|'') CREATED= ;; esac
    if [ -z "$CREATED" ]; then
      verdict_is unverified "branch $BRANCH is at the claimed $HEAD_CLAIM, but its own history could not be read, so what $BRANCH introduced cannot be established"
      finish
    fi
    case "$CREATED_MSG" in
      'branch: Created from '*) ;;
      *)
        verdict_is unverified "branch $BRANCH is at the claimed $HEAD_CLAIM, but the oldest surviving reflog entry for it is not its creation, so what $BRANCH introduced cannot be established"
        finish
        ;;
    esac
    if [ "$CREATED" = "$HEAD_CLAIM" ]; then
      verdict_is contradicted "branch $BRANCH introduced nothing: it is still at $HEAD_CLAIM, the commit it was created at" \
        "$BRANCH was created at $CREATED and its tip is still $TIP"
      finish
    fi
    # The branch reflog reaches back to the creation entry, so it is this
    # branch's whole history. A history with no commit in it is read as absence
    # rather than falsity: this arm has been wrong three times by concluding too
    # much from a true observation, and `unverified` refuses the claim just as
    # firmly while never accusing a worker of something it cannot prove.
    if ! ref_recorded_a_commit "$WT" "refs/heads/$BRANCH"; then
      verdict_is unverified "branch $BRANCH is at the claimed $HEAD_CLAIM, but its history records no commit it made, so nothing establishes that this task authored that commit rather than inheriting it"
      finish
    fi
    verdict_is verified "branch $BRANCH is at the claimed $HEAD_CLAIM, and its history records work it committed at $AUTHORED_AT"
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
    # Retiring the branch deletes its reflog with it, so the branch's own history
    # is gone and the local copy's HEAD reflog is what survives. It records every
    # commit this worktree made, which is the same authorship question the
    # branch-exists arm asks, read off the only log still there to read.
    if ! ref_recorded_a_commit "$WT" HEAD; then
      verdict_is unverified "the local copy is at the claimed $HEAD_CLAIM and it is on $DEFAULT, but its own history records no commit it made, so nothing establishes that this task authored that commit rather than inheriting it"
      finish
    fi
    verdict_is verified "the local copy is at the claimed $HEAD_CLAIM, its own history records a commit it made at $AUTHORED_AT, and the claim is on $DEFAULT; its branch $BRANCH has been retired"
    finish
  fi
  DEFAULT_TIP=$(git -C "$WT" rev-parse --verify --quiet "$DEFAULT_REF" 2>/dev/null || true)
  verdict_is contradicted "branch $BRANCH is gone and the claimed $HEAD_CLAIM is not on $DEFAULT" \
    "${DEFAULT_TIP:+$DEFAULT is at $DEFAULT_TIP and does not contain $HEAD_CLAIM}"
  finish
fi

# --- PR modes ----------------------------------------------------------------
PR_CLAIM=$FM_DONE_CLAIM_PR
if [ -z "$PR_CLAIM" ]; then
  verdict_is contradicted 'claim names no PR' "$FM_DONE_CLAIM_LINE"
  finish
fi
if ! fm_pr_url_parse "$PR_CLAIM"; then
  verdict_is contradicted "claim names an unparseable PR reference: $PR_CLAIM" "$PR_CLAIM"
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
  --json state,headRefOid,headRefName,url,statusCheckRollup \
  -q '.state + "\t" + .headRefOid + "\t" + (.headRefName // "") + "\t" + ([.statusCheckRollup[]? | (.conclusion // .status // .state // "UNKNOWN")] | unique | join(","))' \
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
PR_BRANCH=
CHECKS=
if [ "$PR_HEAD" != "$REST" ]; then
  REST=${REST#*$'\t'}
  PR_BRANCH=${REST%%$'\t'*}
  [ "$PR_BRANCH" = "$REST" ] || CHECKS=${REST#*$'\t'}
fi
[ -n "$CHECKS" ] || CHECKS='none reported'

case "$PR_STATE" in
  CLOSED|closed)
    verdict_is contradicted "$PR_URL is closed without merging, so this task is not done" \
      "the forge reports state $PR_STATE for $PR_URL"
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
  verdict_is contradicted "$PR_URL is at $PR_HEAD, not the claimed $HEAD_CLAIM" "$PR_HEAD"
  finish
fi

# A direct-PR task has no validation run to bind the PR to it, so without this
# the whole verification is "the claim and the forge agree about a head" - two
# facts a worker could satisfy by naming any open PR whose head it states
# correctly. That is consistency, not authorship. Every other arm binds its
# evidence to this task by name (local-only to fm/<id>, scout to this task's own
# data directory) and this one binds the same way, through the branch the forge
# says the PR is built from. A no-mistakes task is already bound by the
# validated-commit check below, which requires the run's branch to be this
# worktree's own.
if [ "$MODE" != no-mistakes ]; then
  if [ -z "$PR_BRANCH" ]; then
    verdict_is unverified "the forge reported no head branch for $PR_URL, so nothing establishes that this PR is this task's work"
    finish
  fi
  if [ "$PR_BRANCH" != "fm/$ID" ]; then
    verdict_is contradicted "$PR_URL is built from $PR_BRANCH, not this task's fm/$ID" "$PR_BRANCH"
    finish
  fi
  verdict_is verified "$PR_URL is $PR_STATE at the claimed $HEAD_CLAIM from this task's $PR_BRANCH; checks: $CHECKS"
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
  verdict_is contradicted "validation ran against $RUN_HEAD, but the claim ships $HEAD_CLAIM" "$RUN_HEAD"
  finish
fi
RUN_OUTCOME=$(fm_nm_strip_quotes "$(fm_nm_field "$RUN_OUT" outcome)")
RUN_STATUS=$(fm_nm_strip_quotes "$(fm_nm_field "$RUN_OUT" status)")
verdict_is verified "$PR_URL is $PR_STATE at the claimed $HEAD_CLAIM, validated at $RUN_HEAD (run ${RUN_OUTCOME:-$RUN_STATUS}); checks: $CHECKS"
finish
