#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
# addressed through gh by the derived owner and repository on the derived host,
# exported as GH_HOST for the whole run, which is github.com or a GitHub
# Enterprise host this home names in config/github-hosts; a GitLab merge
# request is addressed through glab by the project URL rebuilt from the parsed
# host and path, so any instance works and no host is hardcoded; a Forgejo
# pull request is addressed through tea by the derived owner and repository
# plus a "tea login" resolved fresh from the parsed host on every run. A Gerrit
# change is refused outright: that adapter is read-only, and the refusal at the
# parse below owns why.
#
# Usage:
#   fm-pr-merge.sh <task-id> <pr-url> [--attended-override] [--allow-red <check>]
#     [--allow-missing <check>] [--allow-no-pipeline] [-- <forge merge flags>]
#   fm-pr-merge.sh <task-id> <pr-url> --queue-at-green
#   fm-pr-merge.sh <task-id> <pr-url> --queue-requeue
#   fm-pr-merge.sh -h | --help
#
# Merge method on GitHub defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# On Forgejo the merge style defaults to the repository's own
# default_merge_style, read live, and a merge is refused when it cannot be read.
# A GitHub merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the pull request
# is open, not a draft, mergeable, free of conflicts, every unwaived check
# is green at the exact current head commit, where github_checks_not_green below
# owns what makes a check green and judges each one by its current run, and
# every unwaived check the forge requires for the base branch has reported at
# that head. When mergeable is the only failing condition and reads UNKNOWN,
# meaning GitHub has not finished recomputing it, the caller re-reads and
# re-checks every condition after a short bounded wait instead of refusing;
# once that bound is spent it reports mergeability still pending rather than
# unmergeable, with the same nonzero exit as any other refusal.
# A required check that never reported is absent from the checks
# list rather than red, so github_read_required_contexts below reads the
# required set from classic branch protection and active rulesets. Check-run
# requirements retain their producer app binding: a same-named check run from another app cannot
# satisfy them, and a duplicate name-only entry cannot weaken that binding.
# Unbound requirements match by name. A bound requirement reported as a check
# run also needs a matching producer in the check-runs read at the verified
# head, while one reported as a commit status matches by name, because the
# status carries no app id to compare. Status-creator app binding is not verified
# here, so an attended --attended-override -- --admin merge can bypass that
# protection without a missing-check waiver when a same-named status reported.
# An unreadable producer read still refuses.
# Successfully read requirements remain checked even if another
# source fails, so known missing checks and all read errors are reported together.
# github_branch_rules_unavailable_on_plan owns the narrow plan-unavailable
# exception; every other unreadable required source refuses.
# Every failing condition is reported, not just the first.
# The verified head is then passed to gh as
# --match-head-commit, so a push that lands between that read and the merge
# fails the merge instead of landing commits nothing verified. Reading that
# state needs gh and jq, and either one absent stops the merge before any
# state is recorded. An attended --allow-red <check-name> may be passed once,
# with the name as a separate argument; it waives only checks with that exact
# name, still requires every other check green, and still binds the head. Its
# twin, an attended --allow-missing <check-name>, follows the same rules for one
# required check that has not reported: it waives only that exact name, still
# requires every other required check to have reported and every check to be
# green unless separately waived by --allow-red. It matches the required
# context name even for an app-bound requirement, and never waives an unreadable
# required source or producer read. Both are
# refused while the away-posture record exists, and neither
# applies on GitLab, where a merge already requires the head pipeline to have
# succeeded, or on Forgejo, where a merge already requires the head's combined
# commit status to have succeeded. After gh returns success, GitHub's live
# state is read back and
# accepted only when the pull request is merged or in the merge queue. gh's
# GraphQL API supplies that queue-aware read; when that read fails, gh-axi's
# own view still proves a landed merge, and every outcome it cannot prove
# refuses, reporting the failed gh read and naming both failed reads when the
# gh-axi view could not prove the outcome either.
# A base branch with an effective merge_queue rule merges through the queue when
# the caller passed nothing beyond an optional merge method (the queue's own
# method applies; the flag is only noted), in attended and away posture alike:
# the task's no-mistakes CI monitor on that branch is ended with axi handoff so
# nothing rebases or pushes to a queued pull request (a run that cannot be ended
# refuses the enqueue), the pull request is enqueued through GraphQL
# enqueuePullRequest bound to the verified head with expectedHeadOid, the
# accepted authority is persisted, and both locks are released before this script
# waits synchronously until GitHub reports it merged. That wait is what the away
# rule asks of a queued merge; a fire-and-forget enqueue is never done. A pull
# request that left the queue without merging (removed, failed required check,
# closed), a wait longer than FM_PR_MERGE_QUEUE_TIMEOUT seconds (default 7200),
# and a queue state unreadable five polls in a row (gh-axi may still prove a
# landing) are refusals, never landings; a removal quotes GitHub's recorded
# reason, and the poll stays armed. FM_PR_MERGE_QUEUE_POLL_INTERVAL
# (default 30) sets the poll gap. A run against an already queued pull request
# only waits. An explicit --auto, or any extra argument beyond a merge method,
# keeps the direct gh route below.
# If the pull request remains open after that direct route and the base branch
# has an effective merge_queue rule, an attended refusal names the queue's configured merge
# method and exact --attended-override -- --auto --<method> retry flags. While
# the away-posture record exists, the one asynchronous request that may run is
# exactly those retry flags with a single recognised queue method: --auto with
# any other method, with no method, on a base whose rules disagree or cannot be
# read, or with any argument beyond the method, is refused, and a base with no
# queue rule refuses --auto outright because no enqueue can carry it. Every
# pull request enqueued under away authority (this --auto route and the queue
# route alike) is recorded in the away queue list (bin/fm-afk-contract.sh),
# which the record's archive sweeps: an entry still in the merge queue when the
# away posture ends is dequeued, so a queued merge never lands on lapsed
# authority. An attended caller that already passed the configured method with
# --auto is told instead that the accepted request has not entered the queue and
# its queue state has to be re-checked.
# No method is selected for the caller in any case. A rules response that names
# no queue rule, one that could not be read, rules that disagree, and a method
# this script does not recognise are four distinct outcomes and are reported
# apart, because each one leaves the operator somewhere different.
# A caller-requested --auto that leaves the pull request neither merged nor
# queued is refused the same way and says auto-merge was armed with nothing
# landed or queued yet, or, when the merge command itself failed, that auto-merge
# was only requested; both are read from the caller's own arguments rather than
# from the forge's prose.
#
# --queue-at-green is the registration-time arm bin/fm-pr-check.sh invokes
# once a task's PR is recorded (never the merge-time re-record, and never on
# a forge other than GitHub, which is the only forge with a merge queue): it
# merges nothing and enqueues nothing by itself. It re-verifies the live
# pull request at the exact head (open, not a draft, conflict-free, every
# required check reported, and - the one difference from the merge verify -
# no check that has COMPLETED with a failing conclusion, because checks still
# pending are the point), proves no-mistakes review coverage for that exact
# head from the run record the same way a merge turn's supervision session
# would (fm_nm_review_coverage), requires the task's yolo posture (with yolo
# off a captain approves each merge, so nothing is armed), requires a single
# recognised merge-queue method on the base branch (no merge_queue rule at
# all means the project has no merge queue: nothing is armed and that is not
# an error; conflicting, unrecognised or unreadable rules refuse), ends any
# branch-pushing no-mistakes run exactly as the queue route does (FM-3), and
# only then asks gh for merge-when-ready: --auto --<queue method> bound to
# the verified head with --match-head-commit, so GitHub itself puts the pull
# request into the merge queue the moment its required checks are green,
# without waiting for a firstmate turn. The result is read back live: merged
# or queued proves the arm (an already-green pull request may enter the queue
# at once); anything else - an approval-required pull request, a forge-side
# refusal, an unreadable state - is disarmed again with --disable-auto before
# refusing, so no arm this script cannot prove is left live. A proved arm
# persists the accepted merge authority, records itself in the away queue
# list while away exactly like the queue route, and writes the private
# $STATE/<ID>.queue-arm record (fm_queue_arm_write) the watcher sweeps. A
# record that cannot be written disarms the arm too: an arm the sweep cannot
# see could neither requeue once nor disarm on a new push. The arm writes to
# stderr only; registration owns stdout, and an arm that refuses never fails
# the registration that asked for it.
#
# --queue-requeue is the watcher's sweep over that record
# (bin/fm-watch.sh runs it under its check timeout, and it takes the control
# lock through a bounded wait: a task owned by a live merge turn or poll is
# left for the next sweep). Merged retires the arm quietly (the merge poll
# owns the landing wake); a head that moved disarms GitHub's request and
# reports it, because GitHub does not disarm a push from this write
# credential by itself and nothing verified the new head; a pull request no
# longer open, and an ejection whose reason is anything but failed_checks,
# retire and report; an ejection with reason failed_checks at the unchanged
# head re-enqueues itself once, replaying the queue route's own FM-3 and
# authority discipline (including the away queue list), and a second such
# ejection retires and reports as an ordinary blocked wake for firstmate to
# decide. An arm still waiting for its checks - not queued, no new ejection
# event since the baseline recorded at arm time - stays silent, and so does
# every lock or read this sweep cannot take: it does nothing and the next
# sweep retries. Its stdout is exactly one terminal line when the arm ends,
# which is the watcher's wake reason, and nothing otherwise.
# Every refusal that follows a merge command which returned success quotes that
# command's own output, marked as the forge's text and kept apart from this
# script's verdict, including the refusal for an outcome that cannot be read;
# a merge command that failed keeps its original error surfaced raw and first.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
#
# A GitLab merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the merge request
# is open, detailed_merge_status is mergeable, has_conflicts is false,
# blocking_discussions_resolved is true, and the head pipeline succeeded at the
# exact current head commit. Every failing condition is reported, not just the
# first. An attended --allow-no-pipeline, for a repository that deliberately
# runs no merge request pipeline, waives only the pipeline condition and only
# when GitLab reports head_pipeline as present and null: a failed, running,
# canceled, or stale pipeline still refuses, every other condition still
# holds, and a project that requires a pipeline to succeed still refuses
# through detailed_merge_status. It is refused while the away-posture record
# exists and on any forge other than GitLab. The verified head is then passed
# to glab as --sha, so a push that lands between that read and the merge fails
# the merge instead of landing commits nothing verified. A recorded pr_head that disagrees with the live head is
# reported rather than trusted, because a rebase moves the head and leaves the
# recorded value stale. Reading that state needs glab and jq, and either one
# absent stops the merge before any state is recorded.
#
# A Forgejo merge is refused unless every pre-merge condition holds, each read
# live at merge time: the pull request is open, not a draft, mergeable is
# true, and the combined commit status at the exact current head, read across
# every status page, is success (an unconfigured status, reported as "none",
# refuses rather than being treated as nothing to check, the same reading
# GitLab's null head_pipeline gets above). Every
# failing condition is reported, not just the first. tea exposes no head-
# binding flag on its own merge subcommand, so the verified head is instead
# passed as head_commit_id to a direct call against Forgejo/Gitea's REST API
# (through "tea api"), which rejects a mismatched value with "head out of
# date" - verified against a real instance, along with every claim below about
# tea's and the API's exact behavior. Also unlike gh and glab, that API call
# reports an HTTP-level failure with exit status 0, so the merge is never
# judged by its own exit status: only a follow-up read confirming merged=true
# counts as landed. tea addresses a repository by owner/repository slug only;
# the host comes from a named "tea login" rather than the URL the way gh and
# glab take one, so the login registered for the parsed host is re-resolved
# fresh at merge time (bin/fm-pr-check.sh already required one at arm time,
# but a login can be renamed or removed afterwards). Reading and merging both
# need tea and jq, and either one absent stops the merge before any state is
# recorded. Forgejo has no merge-queue or scheduled-merge concept, so unlike
# GitHub and GitLab there is no away-mode async/queued case to detect: every
# accepted Forgejo merge here is immediate, and any caller-passed extra
# argument beyond a merge method is refused rather than silently dropped,
# because there is no established translation from a gh/glab-style flag into
# a Forgejo API field yet.
#
# Before either forge merge, the task's existing per-task control lock
# serializes the captain-hold check through the forge command. A still-held or
# unreadable row refuses before that command, so a captain approval must be
# recorded as an `answer --release` before this entrypoint is invoked. While
# an away record exists (a quiet-mode record is a present captain, so its
# merges stay attended: bin/fm-afk-contract.sh mode) any green merge may
# proceed under away authority:
# the record's presence is the whole mechanical fact, and which merge the
# captain's away words meant is the supervision session's reading
# (bin/fm-branch-prompt.sh "Postures"). An unreadable record refuses rather
# than being skipped, neither posture releases a captain hold, and away
# authority lapses when the record is archived.
# The authority read and synchronous forge command share the away record's
# cross-subsystem lock, which bin/fm-afk-contract.sh owns, closing the common
# live-owner TOCTOU; failure to take it refuses before the forge call. While
# away, every asynchronous merge path is refused except the merge-queue
# enqueues the away-posture record's archive can dequeue: the queue route and
# the exact --auto --<method> enqueue (see the queue notes above). Two
# confused-agent-grade limitations are
# accepted rather than hidden: queue or base changes after GitHub's preflight can
# still enqueue, and killing this shell can orphan a forge child after stale-lock
# recovery. docs/architecture.md owns those away-merge limits, while
# docs/captain-hold-lifecycle.md owns the separate merge-to-cleanup residual.
# A failed forge command releases the lock after it returns. A successful one
# retains the lock until the accepted merge authority is persisted against the
# still-matching task metadata.
#
# Extra args must not include --repo or -R in any form, including a bundled
# short-option cluster such as -yR, because the repository comes only from the
# URL, nor --sha or --match-head-commit because the head comes only from the
# live read. An existing task-meta pr= must equal the requested canonical URL,
# unless that bound PR has already merged - proven by its recorded merge
# notification - in which case the task's next PR is accepted so several PRs
# from one task can each merge in turn; while the bound PR is still unmerged a
# different URL is refused. Auto-merge (--auto), a protection bypass
# (--admin), and branch
# deletion (--delete-branch, -d and short-flag clusters, and GitLab's
# --remove-source-branch) are refused by default; --attended-override, parsed
# before the optional -- separator, re-enables those forge flags for an
# explicit captain instruction and never skips the live green check, the
# away-record read, or a captain hold.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--attended-override] [--allow-red <check-name>] [--allow-missing <check-name>] [--allow-no-pipeline] [-- <extra forge merge args>]
#
# On GitLab, this script confirms the MR is actually merged before reporting it;
# an auto-merge-queued or unconfirmed request leaves the poll armed and records
# no landed outcome. bin/fm-merge-outcome-lib.sh owns a confirmed merge's
# destination, normal-case deduplication, and at-least-once recovery.
# A landed merge whose outcome cannot be written is reported loudly rather than
# misreported as a failed merge.
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# shellcheck source=bin/fm-merge-authority-lib.sh
. "$SCRIPT_DIR/fm-merge-authority-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
# Azure DevOps exposes auto-complete via az repos pr update, but that request
# may land later at a different head and after away authority has lapsed. Unlike
# gh/glab's pinned-head merge, it cannot satisfy this entrypoint's synchronous
# verified-head contract; leave the read-only merge poll armed for a hand merge.
if [ "$PROVIDER" = ado ]; then
  echo "error: Azure DevOps auto-complete for $URL can merge asynchronously at an unverified head; fm-pr-merge refuses it. Merge it by hand and keep the poll armed with bin/fm-pr-check.sh" >&2
  exit 2
fi
PR_HOST=$FM_PR_HOST
PR_PATH=$FM_PR_PATH
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
# gh and gh-axi address github.com unless told otherwise, so a GitHub Enterprise
# host is exported once here and every forge call this run makes addresses the
# host the parsed identity names, including the gh merge command that carries
# only owner and repository. A gitlab, gerrit, or forgejo run keeps its own
# per-call host handling.
if [ "$PROVIDER" = github ]; then
  fm_pr_github_host_export "$PR_HOST"
fi
# glab resolves the instance from the project URL passed to -R, so the host is
# rebuilt from the parsed identity rather than read from any ambient default.
PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
# Firstmate never submits a Gerrit change, even though gerrit-axi can, so the
# refusal is stated rather than left as a silently absent provider branch.
# Submitting a Gerrit change means first recording a Code-Review+2, which is a
# positive attributed claim that a named human approved the change, read by
# colleagues and by any audit of the repository. Firstmate must not manufacture
# one. The server permitting self-approval is what makes this a policy boundary
# rather than a capability limit, so it is enforced here rather than assumed.
if [ "$PROVIDER" = gerrit ]; then
  echo "error: firstmate does not submit a Gerrit change: submitting requires an attributed human approval it must not manufacture, so a human submits the change on the server" >&2
  exit 2
fi
shift 2
# The two sweep-owned modes. --queue-at-green is what a registration arms
# (bin/fm-pr-check.sh): it never merges and never enqueues by itself, it only
# hands GitHub a merge-when-ready request bound to the exact head this run
# verifies, so the pull request enters the base branch's merge queue when its
# required checks turn green without waiting for a firstmate turn.
# --queue-requeue is the watcher's follow-up sweep over that arm
# (bin/fm-watch.sh): it re-enqueues once after a failed-checks ejection at an
# unchanged head and reports a second ejection as an ordinary blocked wake.
# Both take no further arguments, and both are refused on any forge but
# GitHub, the only forge here with a merge queue to address.
MODE=merge
case "${1:-}" in
  --queue-at-green|--queue-requeue)
    if [ "$#" -ne 1 ]; then
      echo "error: $1 takes no further arguments" >&2
      exit 2
    fi
    if [ "$PROVIDER" != github ]; then
      echo "error: $1 applies only to GitHub pull requests" >&2
      exit 2
    fi
    MODE=${1#--queue-}
    ;;
esac
ATTENDED_OVERRIDE=false
ALLOW_NO_PIPELINE=false
ALLOW_RED=()
ALLOW_MISSING=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attended-override)
      ATTENDED_OVERRIDE=true
      shift
      ;;
    --attended-override=*)
      echo "error: --attended-override takes no value" >&2
      exit 2
      ;;
    --allow-red)
      [ -n "${2:-}" ] || { echo "error: --allow-red requires a check name" >&2; exit 2; }
      [ "${#ALLOW_RED[@]}" -eq 0 ] || { echo "error: --allow-red may be specified only once" >&2; exit 2; }
      ALLOW_RED+=("$2")
      shift 2
      ;;
    --allow-red=*)
      echo "error: --allow-red requires a separate check name argument" >&2
      exit 2
      ;;
    --allow-missing)
      [ -n "${2:-}" ] || { echo "error: --allow-missing requires a check name" >&2; exit 2; }
      [ "${#ALLOW_MISSING[@]}" -eq 0 ] || { echo "error: --allow-missing may be specified only once" >&2; exit 2; }
      ALLOW_MISSING+=("$2")
      shift 2
      ;;
    --allow-missing=*)
      echo "error: --allow-missing requires a separate check name argument" >&2
      exit 2
      ;;
    --allow-no-pipeline)
      ALLOW_NO_PIPELINE=true
      shift
      ;;
    --allow-no-pipeline=*)
      echo "error: --allow-no-pipeline takes no value" >&2
      exit 2
      ;;
    --) shift; break ;;
    *) break ;;
  esac
done
# --allow-red names one check run to waive, which only GitHub's per-check
# reading can match. GitLab and Forgejo each collapse their checks into a
# single head verdict - a head pipeline status and a combined commit status -
# so there is no per-check name to waive there; GitLab's only waiver is the
# whole-pipeline absence --allow-no-pipeline covers. Refuse the combination
# rather than accept a flag that would be silently dropped into a refusal the
# caller cannot explain.
if [ "${#ALLOW_RED[@]}" -gt 0 ]; then
  case "$PROVIDER" in
    gitlab)
      echo "error: --allow-red does not apply to GitLab, where a merge already requires the head pipeline to have succeeded; --allow-no-pipeline waives only a merge request with no head pipeline at all" >&2
      exit 2
      ;;
    forgejo)
      echo "error: --allow-red does not apply to Forgejo, where a merge already requires the head's combined commit status to have succeeded" >&2
      exit 2
      ;;
  esac
fi
# --allow-no-pipeline waives only GitLab's own reading of a merge request that
# has no head pipeline at all. GitHub's per-check waivers and Forgejo's
# combined status have no such state to waive, so it is refused there too.
if [ "$ALLOW_NO_PIPELINE" = true ] && [ "$PROVIDER" != gitlab ]; then
  echo "error: --allow-no-pipeline applies only to GitLab, where it waives a merge request that has no head pipeline at all" >&2
  exit 2
fi
if [ "${#ALLOW_MISSING[@]}" -gt 0 ]; then
  case "$PROVIDER" in
    gitlab)
      echo "error: --allow-missing does not apply to GitLab, where a merge already requires the head pipeline to have succeeded; --allow-no-pipeline waives only a merge request with no head pipeline at all" >&2
      exit 2
      ;;
    forgejo)
      echo "error: --allow-missing does not apply to Forgejo, where a merge already requires the head's combined commit status to have succeeded" >&2
      exit 2
      ;;
  esac
fi

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

# The merge method the caller's own extra arguments named, in the --flag,
# --method <value> and --method=<value> forms caller_has_merge_method accepts.
caller_merge_method() {
  local arg method='' pending=false
  for arg in "$@"; do
    if [ "$pending" = true ]; then
      method=$arg
      pending=false
      continue
    fi
    case "$arg" in
      --squash) method=squash ;;
      --merge) method=merge ;;
      --rebase) method=rebase ;;
      --method) pending=true ;;
      --method=*) method=${arg#--method=} ;;
    esac
  done
  printf '%s' "$method"
}

# Whether every extra argument the caller passed is a merge method (--squash,
# --merge, --rebase and their short forms, --method <value>, --method=<value>),
# or there are none. The merge queue route takes nothing else, because the
# enqueue has no subject, body, bypass or branch-deletion field to carry it.
caller_args_are_method_only() {
  local arg pending=false
  for arg in "$@"; do
    if [ "$pending" = true ]; then
      pending=false
      continue
    fi
    case "$arg" in
      --squash | --merge | --rebase | -s | -m | -r | --method=*) ;;
      --method) pending=true ;;
      *) return 1 ;;
    esac
  done
  [ "$pending" = false ]
}

# Whether the caller's own extra arguments asked for auto-merge, including the
# --flag=value spelling the forge's flag parser accepts. --disable-auto cancels
# the request, and gh exposes no short option that could bundle either flag.
caller_requested_auto_merge() {
  local arg requested=1
  for arg in "$@"; do
    case "$arg" in
      --auto) requested=0 ;;
      --auto=*)
        case "${arg#--auto=}" in
          [tT]|[tT][rR][uU][eE]|1) requested=0 ;;
          *) requested=1 ;;
        esac
        ;;
      --disable-auto) requested=1 ;;
    esac
  done
  return "$requested"
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster, which both CLIs expand
      # one character at a time, so -yR carries --repo exactly as a bare -R does.
      -*R*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_head_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --sha|--sha=*|--match-head-commit|--match-head-commit=*)
        echo "error: extra merge arguments must not override the head commit" >&2
        return 1
        ;;
    esac
  done
}

reject_protected_forge_args() {
  local arg
  [ "$ATTENDED_OVERRIDE" = true ] && return 0
  for arg in "$@"; do
    case "$arg" in
      --auto|--auto=*|--admin|--admin=*|--delete-branch|--delete-branch=*|--remove-source-branch|--remove-source-branch=*)
        echo "error: extra merge arguments must not request auto-merge, a protection bypass, or branch deletion; pass --attended-override only for an explicit captain instruction" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster. -d is gh's
      # --delete-branch, and -yd carries it the same way -yR carries --repo.
      -*d*)
        echo "error: extra merge arguments must not request auto-merge, a protection bypass, or branch deletion; pass --attended-override only for an explicit captain instruction" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1
reject_head_overrides "$@" || exit 1
reject_protected_forge_args "$@" || exit 1

FM_PR_GITHUB_AUTO_REQUESTED=false
if [ "$PROVIDER" = github ] && caller_requested_auto_merge "$@"; then
  FM_PR_GITHUB_AUTO_REQUESTED=true
fi
FM_PR_GITLAB_ASYNC_REQUESTED=false
if [ "$PROVIDER" = gitlab ]; then
  for arg in "$@"; do
    case "$arg" in
      --auto-merge|--when-pipeline-succeeds) FM_PR_GITLAB_ASYNC_REQUESTED=true ;;
      --auto-merge=*|--when-pipeline-succeeds=*)
        case "${arg#*=}" in
          [tT]|[tT][rR][uU][eE]|1) FM_PR_GITLAB_ASYNC_REQUESTED=true ;;
          [fF]|[fF][aA][lL][sS][eE]|0) FM_PR_GITLAB_ASYNC_REQUESTED=false ;;
        esac
        ;;
    esac
  done
fi
FM_PR_AWAY_POSTURE=false

fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: PR merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Role partition: merging is MAIN-owned while attended; the Pi supervision
# branch reports the green PR and never merges (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). While the away-posture record exists
# main is parked and this one action relocates to the branch, which then meets
# exactly the same gates below as main would: green at its live head,
# synchronous, under the record lock. This precedes
# reading the task record, because the wrong actor is refused for its role
# whatever that record says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "PR merge (fm-pr-merge)" --away-relocated

if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: PR merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
MERGE_META_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_META_LOCK" ] || fm_lock_release "$MERGE_META_LOCK" || true
  fm_afk_contract_lock_release || true
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
if [ "$MODE" = requeue ] || [ "$MODE" = at-green ]; then
  # The requeue sweep runs under the watcher's check timeout, so its control
  # lock wait is bounded: when a merge turn or a poll owns the task, the sweep
  # exits silent and the next sweep retries. The arm is opportunistic in the
  # same way: registration arms the queue only when the task is free, because
  # a lock held there means a merge turn or a poll cycle already owns the
  # task and the ordinary merge path still applies; blocking inside it would
  # stall that owner's cycle (an fm-pr-check nested in a poll or a merge
  # re-record must never wait on the lock that owner holds). Every other mode
  # waits as long as the task takes.
  if [ "$MODE" = requeue ]; then
    queue_lock_wait=${FM_PR_QUEUE_REQUEUE_LOCK_WAIT:-10}
  else
    queue_lock_wait=${FM_PR_QUEUE_ARM_LOCK_WAIT:-0}
  fi
  case "$queue_lock_wait" in
    ''|*[!0-9]*|0)
      if [ "$MODE" = requeue ]; then
        queue_lock_wait=10
      else
        queue_lock_wait=0
      fi
      ;;
  esac
  [ "$queue_lock_wait" -le 120 ] || queue_lock_wait=$([ "$MODE" = requeue ] && echo 10 || echo 0)
  if ! fm_lock_acquire_wait_max "$MERGE_CONTROL_LOCK" "$queue_lock_wait"; then
    if [ "$MODE" = requeue ]; then
      MERGE_CONTROL_LOCK=
      exit 0
    fi
    printf 'queue arm: %s was not armed: the task control lock is held, so a merge or poll owns it and the ordinary merge path still applies\n' \
      "$URL" >&2
    MERGE_CONTROL_LOCK=
    exit 1
  fi
else
  fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
fi
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

# Reading the merge request state needs both tools. Report them together and
# before anything is recorded, so a missing tool is a named prerequisite rather
# than a merge that is armed and then refused for an unexplained reason.
GITLAB_MISSING=
if [ "$PROVIDER" = gitlab ]; then
  command -v glab >/dev/null 2>&1 || GITLAB_MISSING="glab"
  if ! command -v jq >/dev/null 2>&1; then
    GITLAB_MISSING="${GITLAB_MISSING:+$GITLAB_MISSING and }jq"
  fi
  if [ -n "$GITLAB_MISSING" ]; then
    echo "error: merging a GitLab merge request requires $GITLAB_MISSING on PATH" >&2
    exit 1
  fi
fi
GITHUB_MISSING=
if [ "$PROVIDER" = github ]; then
  command -v gh >/dev/null 2>&1 || GITHUB_MISSING="gh"
  if ! command -v jq >/dev/null 2>&1; then
    GITHUB_MISSING="${GITHUB_MISSING:+$GITHUB_MISSING and }jq"
  fi
  if [ -n "$GITHUB_MISSING" ]; then
    echo "error: merging a GitHub pull request requires $GITHUB_MISSING on PATH" >&2
    exit 1
  fi
fi
# tea addresses a repo by slug only; the host comes from a named "tea login"
# rather than the URL, so the login registered for this exact host is
# resolved here too (bin/fm-pr-check.sh already refused arming without one,
# but a login can be removed or renamed after arming, so this is re-derived
# fresh rather than trusted from that earlier check).
FORGEJO_MISSING=
FORGEJO_LOGIN=
if [ "$PROVIDER" = forgejo ]; then
  command -v tea >/dev/null 2>&1 || FORGEJO_MISSING="tea"
  if ! command -v jq >/dev/null 2>&1; then
    FORGEJO_MISSING="${FORGEJO_MISSING:+$FORGEJO_MISSING and }jq"
  fi
  if [ -n "$FORGEJO_MISSING" ]; then
    echo "error: merging a Forgejo pull request requires $FORGEJO_MISSING on PATH" >&2
    exit 1
  fi
  FORGEJO_LOGIN=$(fm_pr_forgejo_login "$PR_HOST") || {
    echo "error: merging a Forgejo pull request at $PR_HOST requires exactly one 'tea login' registered for that host (see 'tea login list')" >&2
    exit 1
  }
fi

# The recorded head is read before bin/fm-pr-check.sh rewrites the metadata,
# because that script re-records pr= and drops a pr_head= it cannot resolve.
RECORDED_HEAD=
if [ "$PROVIDER" = gitlab ] || [ "$PROVIDER" = forgejo ]; then
  RECORDED_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
fi

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
FM_PR_GITLAB_ASYNC_CONFIGURED=false
gitlab_verify_mergeable() {
  local json fields line pipeline_waived
  local total=0 named=0 refusals=''
  local state='' detail='' conflicts='' discussions=''
  local live_head='' pipeline_sha='' pipeline_status='' pipeline_absent='' async_configured=''

  # GITLAB_HOST is set to the same host the project URL already carries, so the
  # instance is taken from the parsed URL by both signals and never from the
  # operator's configured default.
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" -R "$PROJECT_URL" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  # One named field per line. The names keep a trailing empty value readable
  # after command substitution strips blank lines, and an absent or null field
  # becomes an empty string or the literal "null", neither of which satisfies any
  # check below, so an unreadable field refuses the merge instead of passing it.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + (.has_conflicts | tostring),
        "discussions=" + (.blocking_discussions_resolved | tostring),
        "head=" + ((.sha // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring),
        "pipeline_status=" + ((.head_pipeline.status // "") | tostring),
        "pipeline_absent=" + (if has("head_pipeline") and .head_pipeline == null then "true" else "false" end),
        "async_configured=" + (if .merge_when_pipeline_succeeds == true or (.merge_after != null) then "true" else "false" end)
      else
        error("merge request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      detail=*) detail=${line#detail=} ;;
      conflicts=*) conflicts=${line#conflicts=} ;;
      discussions=*) discussions=${line#discussions=} ;;
      head=*) live_head=${line#head=} ;;
      pipeline_sha=*) pipeline_sha=${line#pipeline_sha=} ;;
      pipeline_status=*) pipeline_status=${line#pipeline_status=} ;;
      pipeline_absent=*) pipeline_absent=${line#pipeline_absent=} ;;
      async_configured=*) async_configured=${line#async_configured=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  # Every field named exactly once and no unnamed line: a value carrying a
  # newline would split into a line no name matches, so it is refused here
  # rather than silently truncated into a value a check could accept.
  if [ "$named" -ne 9 ] || [ "$total" -ne 9 ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitLab merge request head commit before merging" >&2
    return 1
  fi
  # A rebase moves the head and leaves the recorded value behind, so the
  # disagreement is reported and the live head is what gets verified and merged.
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  [ "$state" = opened ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$detail" = mergeable ] \
    || refusals="$refusals  - detailed_merge_status is \"${detail:-unreadable}\", not mergeable
"
  [ "$conflicts" = false ] \
    || refusals="$refusals  - has_conflicts is \"${conflicts:-unreadable}\", not false
"
  [ "$discussions" = true ] \
    || refusals="$refusals  - blocking_discussions_resolved is \"${discussions:-unreadable}\", not true
"
  # The waiver covers only a head_pipeline GitLab reports as null; a failed,
  # running, canceled, or stale pipeline is a verdict, not an absence of one.
  pipeline_waived=false
  if [ "$ALLOW_NO_PIPELINE" = true ] && [ "$pipeline_absent" = true ]; then
    pipeline_waived=true
  else
    [ "$pipeline_status" = success ] \
      || refusals="$refusals  - the head pipeline status is \"${pipeline_status:-none}\", not success
"
    [ "$pipeline_sha" = "$live_head" ] \
      || refusals="$refusals  - the head pipeline ran at \"${pipeline_sha:-none}\", not at the current head $live_head
"
  fi

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  if [ "$pipeline_waived" = true ]; then
    printf 'verified: %s is open and mergeable at head %s, with no head pipeline, waived by --allow-no-pipeline\n' \
      "$URL" "$live_head" >&2
  else
    printf 'verified: %s is open and mergeable, with a successful pipeline at head %s\n' \
      "$URL" "$live_head" >&2
  fi
  FM_PR_MERGE_HEAD=$live_head
  FM_PR_GITLAB_ASYNC_CONFIGURED=$async_configured
}

# Pre-merge conditions for a Forgejo pull request, read from one live view of
# it. tea's single-PR view ignores field selection entirely (verified against
# a real instance), so the raw API is read directly through "tea api" instead
# of any tea subcommand, exactly like glab's JSON view above but through
# Forgejo/Gitea's REST API. Sets FM_PR_MERGE_HEAD to the verified head on
# success and returns non-zero after reporting every condition that failed.
#
# Forgejo has no merge-queue or scheduled-merge concept to detect, so unlike
# GitHub and GitLab this never sets an async/queued signal: every accepted
# Forgejo merge here is immediate. Shares FM_PR_MERGE_HEAD, declared above.
forgejo_verify_mergeable() {
  local pr_json status_json fields line
  local total=0 named=0 refusals=''
  local state='' mergeable='' draft='' live_head='' ci_state='' page_state='' page_count='' page=1

  if ! pr_json=$(tea api --login "$FORGEJO_LOGIN" --repo "$PR_OWNER/$PR_REPO" \
      "/repos/{owner}/{repo}/pulls/$PR_NUMBER" 2>/dev/null) || [ -z "$pr_json" ]; then
    echo "error: could not read the Forgejo pull request state before merging" >&2
    return 1
  fi
  if ! fields=$(printf '%s' "$pr_json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "mergeable=" + (.mergeable | tostring),
        "draft=" + (.draft | tostring),
        "head=" + ((.head.sha // "") | tostring)
      else
        error("pull request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the Forgejo pull request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      mergeable=*) mergeable=${line#mergeable=} ;;
      draft=*) draft=${line#draft=} ;;
      head=*) live_head=${line#head=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 4 ] || [ "$total" -ne 4 ]; then
    echo "error: could not read the Forgejo pull request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the Forgejo pull request head commit before merging" >&2
    return 1
  fi
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  # An absent combined status (no statuses on any page, as a repo with no
  # configured Actions reports) is a real "none" here rather than nothing to
  # check, the same reading GitLab's null head_pipeline gets above. The
  # endpoint computes its combined state from one page of the latest status
  # per context, so every page is read until an empty one and the head is
  # green only when each non-empty page is; the first page that is not
  # success, or that cannot be read, decides the refusal.
  ci_state=none
  while :; do
    if ! status_json=$(tea api --login "$FORGEJO_LOGIN" --repo "$PR_OWNER/$PR_REPO" \
        "/repos/{owner}/{repo}/commits/$live_head/status?limit=50&page=$page" 2>/dev/null) \
      || ! fields=$(printf '%s' "$status_json" | jq -r '
          if type == "object" and ((.statuses // []) | type) == "array" then
            "count=" + ((.statuses // []) | length | tostring),
            "state=" + ((.state // "") | tostring)
          else
            error("status payload is not a combined status")
          end' 2>/dev/null); then
      ci_state=unreadable
      break
    fi
    page_count='' page_state=''
    while IFS= read -r line; do
      case "$line" in
        count=*) page_count=${line#count=} ;;
        state=*) page_state=${line#state=} ;;
      esac
    done <<FIELDS
$fields
FIELDS
    [ "$page_count" != 0 ] || break
    if [ "$page_state" != success ]; then
      ci_state=${page_state:-unreadable}
      break
    fi
    ci_state=success
    page=$((page + 1))
    # A server that ignores the page parameter would repeat a non-empty page
    # forever, so an implausible page count is unreadable rather than green.
    if [ "$page" -gt 100 ]; then
      ci_state=unreadable
      break
    fi
  done

  [ "$state" = open ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$mergeable" = true ] \
    || refusals="$refusals  - mergeable is \"${mergeable:-unreadable}\", not true
"
  # Only a positive draft reading refuses: an instance too old to report the
  # field still refuses a work-in-progress merge server side.
  [ "$draft" != true ] \
    || refusals="$refusals  - the pull request is a draft
"
  [ "$ci_state" = success ] \
    || refusals="$refusals  - the combined commit status is \"$ci_state\", not success
"

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with a successful combined status at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
}

# The caller's own extra arguments may only name a merge method, in the same
# forms caller_merge_method reads. There is no translation from a gh/glab-style
# flag such as --auto, --admin, or --delete-branch into a Forgejo API field
# yet (reject_protected_forge_args above already forbids those exact spellings
# outright), so anything else is refused rather than silently dropped.
forgejo_reject_unsupported_args() {
  local arg pending=false
  for arg in "$@"; do
    if [ "$pending" = true ]; then
      pending=false
      continue
    fi
    case "$arg" in
      --squash|--merge|--rebase) ;;
      --method) pending=true ;;
      --method=*) ;;
      *)
        echo "error: extra merge arguments are not yet supported for Forgejo merges" >&2
        return 1
        ;;
    esac
  done
}

# The merge style a Forgejo merge uses when the caller names none: the
# repository's own default_merge_style, read live through the same tea login,
# so a repository that allows only squash or rebase merges is not sent a merge
# commit it refuses. An unreadable or unrecognized value is refused rather than
# replaced by a style chosen here.
forgejo_default_merge_style() {
  local repo_json style
  repo_json=$(tea api --login "$FORGEJO_LOGIN" --repo "$PR_OWNER/$PR_REPO" \
    "/repos/{owner}/{repo}" 2>/dev/null) || repo_json=
  style=$(printf '%s' "$repo_json" | jq -r '
    if type == "object" and (.default_merge_style | type) == "string"
    then .default_merge_style else "" end' 2>/dev/null) || style=
  case "$style" in
    merge|rebase|rebase-merge|squash|fast-forward-only) printf '%s' "$style" ;;
    *)
      echo "error: refusing to merge $URL: the repository's default merge style could not be read; name one with --merge, --rebase, --squash, or --method <style>" >&2
      return 1
      ;;
  esac
}

# Every GitHub check that is not green in the given live pull-request JSON, one
# name per line. An entry is green when it is a status context whose state is
# SUCCESS, or a check run that completed with SUCCESS, NEUTRAL, or SKIPPED (so
# a pending check is not green either). Exits nonzero when the rollup cannot be
# read, so a malformed answer is a failed read and never an empty red set.
#
# The rollup can hold several runs of one check name at the same head, because
# GitHub cancels a pull request's in-flight run when the base branch advances
# and re-triggers it; the cancelled run stays in the rollup beside the passing
# re-run. A check is therefore judged by its current run rather than by any run
# that a later one superseded, which is what makes this agree with GitHub's own
# CLEAN mergeStateStatus instead of refusing a pull request GitHub considers
# mergeable.
#
# Supersession applies only among check runs with the same reported name. A
# name is dropped from the red set only when every non-green run is COMPLETED,
# has a whole-second UTC startedAt, and started strictly before a green run.
# Status contexts are never grouped or superseded, and every non-green one is
# reported independently. A still-running, queued, undated, or tied check run
# stays red. A name whose runs are all green needs no timestamp, while a name
# with no green run stays red.
#
# The reported name is also what --allow-red matches. An unnamed check run is
# grouped alone and can neither supersede nor be superseded, because unrelated
# unnamed checks must not be treated as one.
github_checks_not_green() {
  local json=$1
  printf '%s' "$json" | jq -r '
    def settled_at:
      if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      then . else null end;
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | [ .statusCheckRollup
        | to_entries[]
        | .key as $i
        | .value
        | if .__typename == "CheckRun" then
            {
              kind: "check_run",
              name: (.name // ""),
              completed: (.status == "COMPLETED"),
              ok: (.status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")),
              at: (.startedAt | settled_at)
            }
            | . + {group: (if .name == "" then ["", $i] else [.name, -1] end)}
          else
            {kind: "status_context", name: (.context // ""), ok: (.state == "SUCCESS")}
          end
      ]
    | . as $entries
    | (
        ($entries[]
          | select(.kind == "status_context" and (.ok | not))
          | .name
        ),
        ($entries
          | [.[] | select(.kind == "check_run")]
          | group_by(.group)[]
          | {
              name: .[0].name,
              reds: [.[] | select(.ok | not)],
              newest_green: ([.[] | select(.ok) | .at | select(. != null)] | max)
            }
          | select(
              (.reds | length) > 0
              and (
                .newest_green == null
                or any(.reds[]; (.completed | not) or .at == null)
                or ([.reds[] | .at] | max) >= .newest_green
              )
            )
          | .name
        )
      )
    | if . == "" then "(unnamed check)" else . end
  ' 2>/dev/null || return 1
}

# The arm-time reading of the same rollup, for --queue-at-green: a check that
# is still running - a QUEUED or IN_PROGRESS check run, or a PENDING or
# EXPECTED commit status - has not failed yet, so it does not block arming;
# GitHub's merge-when-ready is exactly what waits for it to finish. A check
# blocks the arm only when it has COMPLETED with a conclusion outside the
# same green set, or reported ERROR or FAILURE as a commit status, judged
# per name on the current run with the same supersession rule as the merge
# verify, so a failure a later green run superseded does not block either.
# Like github_checks_not_green it prints one failed check name per line and
# refuses the whole read if the rollup itself is unreadable.
github_checks_failed() {
  local json=$1
  printf '%s' "$json" | jq -r '
    def settled_at:
      if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      then . else null end;
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | [ .statusCheckRollup
        | to_entries[]
        | .key as $i
        | .value
        | if .__typename == "CheckRun" then
            {
              kind: "check_run",
              name: (.name // ""),
              completed: (.status == "COMPLETED"),
              ok: (.status != "COMPLETED" or (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")),
              at: (.startedAt | settled_at)
            }
            | . + {group: (if .name == "" then ["", $i] else [.name, -1] end)}
          else
            {kind: "status_context", name: (.context // ""), ok: (.state == "SUCCESS" or .state == "PENDING" or .state == "EXPECTED")}
          end
      ]
    | . as $entries
    | (
        ($entries[]
          | select(.kind == "status_context" and (.ok | not))
          | .name
        ),
        ($entries
          | [.[] | select(.kind == "check_run")]
          | group_by(.group)[]
          | {
              name: .[0].name,
              reds: [.[] | select(.ok | not)],
              newest_green: ([.[] | select(.ok) | .at | select(. != null)] | max)
            }
          | select(
              (.reds | length) > 0
              and (
                .newest_green == null
                or any(.reds[]; (.completed | not) or .at == null)
                or ([.reds[] | .at] | max) >= .newest_green
              )
            )
          | .name
        )
      )
    | if . == "" then "(unnamed check)" else . end
  ' 2>/dev/null || return 1
}

FM_PR_GITHUB_REQUIRED=
FM_PR_GITHUB_REQUIRED_ERROR=
github_read_required_contexts() {
  local base=$1 branch_path branch_json rules_json classic='' ruleset='' api_err api_err_text
  FM_PR_GITHUB_REQUIRED='[]'
  FM_PR_GITHUB_REQUIRED_ERROR=
  branch_path=$(github_urlencode_path_segment "$base")

  if ! branch_json=$(gh api "repos/$PR_OWNER/$PR_REPO/branches/$branch_path" 2>/dev/null) \
    || [ -z "$branch_json" ] \
    || ! classic=$(printf '%s' "$branch_json" | jq -c '
      if type != "object" or (.protected | type) != "boolean" then
        error("branch payload is unreadable")
      elif .protected == false then
        empty
      elif (.protection.required_status_checks | type) != "object" then
        error("branch protection summary is unreadable")
      else
        .protection.required_status_checks
        | ((.checks // []) | if type == "array" then .[] else error("invalid checks") end
           | {context, app_id}),
          ((.contexts // []) | if type == "array" then .[] else error("invalid contexts") end
           | {context: ., app_id: null})
        | if (.context | type) == "string" and (.context | length) > 0
             and (.app_id == null or (.app_id | type) == "number")
          then . else error("invalid required check") end
        | if .app_id == -1 then .app_id = null else . end
      end' 2>/dev/null); then
    classic=''
    FM_PR_GITHUB_REQUIRED_ERROR="the branch protection summary for base branch $base could not be read"
  fi

  if ! api_err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-required-rules.XXXXXX"); then
    FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
  else
    if ! rules_json=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" 2>"$api_err"); then
      api_err_text=$(cat "$api_err" 2>/dev/null)
      if ! github_branch_rules_unavailable_on_plan "$api_err_text"; then
        FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
      fi
    elif [ -z "$rules_json" ] || ! ruleset=$(printf '%s' "$rules_json" | jq -c '
        if type != "array" then error("rules payload is unreadable") else .[] end
        | select(type != "object" or .type == "required_status_checks")
        | if type == "object" and (.parameters.required_status_checks | type) == "array"
          then .parameters.required_status_checks[] else error("invalid required check rule") end
        | if type == "object" and (.context | type) == "string" and (.context | length) > 0
             and (.integration_id == null or (.integration_id | type) == "number")
          then {context, app_id: .integration_id} else error("invalid required check rule") end
        | if .app_id == -1 then .app_id = null else . end' 2>/dev/null); then
      ruleset=''
      FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
    fi
    rm -f "$api_err"
  fi

  FM_PR_GITHUB_REQUIRED=$(printf '%s\n%s\n' "$classic" "$ruleset" | jq -sc '
    unique_by([.context, .app_id]) | group_by(.context)
    | map(if any(.[]; .app_id != null) then map(select(.app_id != null)) else . end) | add // []')
  [ -z "$FM_PR_GITHUB_REQUIRED_ERROR" ]
}

# The required set and the head's check-run producers are read by jq from
# process substitutions, never as --argjson arguments: a head with re-run check
# sets carries a producers payload past the kernel's 128 KiB limit on a single
# argument, and jq then cannot start at all.
github_required_checks_missing() {
  local json=$1 required=$2 producers=$3
  printf '%s' "$json" | jq -r \
    --slurpfile required_file <(printf '%s' "$required") \
    --slurpfile producers_file <(printf '%s' "$producers") '
    $required_file[0] as $required | $producers_file[0] as $producers |
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | .statusCheckRollup as $reported
    | $required
    | map(. as $requirement
      | select(any($reported[];
          if $requirement.app_id == null then
            (if .__typename == "CheckRun" then .name else .context end) == $requirement.context
          elif .__typename == "CheckRun" then
            .name == $requirement.context
            and any($producers[]; .name == $requirement.context and .app.id == $requirement.app_id)
          else
            .context == $requirement.context
          end) | not)
      | .context) | unique[]
  ' 2>/dev/null || return 1
}

# Pre-merge conditions from a live PR view, base requirements, and head producers.
# Sets FM_PR_MERGE_HEAD to the verified head on success. Returns 3, rather than
# the usual 1, when mergeable=UNKNOWN is the only failing condition, so the
# caller can retry a still-computing mergeability read instead of refusing.
github_verify_mergeable() {
  local json fields line red name covered missing unreported producers runs
  local total=0 named=0 refusals='' mergeable_refusal=''
  local state='' draft='' mergeable='' merge_state='' live_head='' base=''

  if ! json=$(gh pr view "$URL" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitHub pull request state before merging" >&2
    return 1
  fi
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "mergeable=" + ((.mergeable // "") | tostring),
        "merge_state=" + ((.mergeStateStatus // "") | tostring),
        "head=" + ((.headRefOid // "") | tostring),
        "base=" + ((.baseRefName // "") | tostring)
      else
        error("pull request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitHub pull request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      mergeable=*) mergeable=${line#mergeable=} ;;
      merge_state=*) merge_state=${line#merge_state=} ;;
      head=*) live_head=${line#head=} ;;
      base=*) base=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 5 ] || [ "$total" -ne 5 ] || [ -z "$base" ]; then
    echo "error: could not read the GitHub pull request state before merging" >&2
    return 1
  fi

  draft=$(fm_pr_json_draft_state "$json")
  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitHub pull request head commit before merging" >&2
    return 1
  fi
  if ! red=$(github_checks_not_green "$json"); then
    echo "error: could not read the GitHub pull request state before merging" >&2
    return 1
  fi

  case "$state" in
    [oO][pP][eE][nN]) ;;
    *)
      refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
      ;;
  esac
  [ "$draft" = false ] \
    || refusals="$refusals  - the pull request is a draft
"
  [ "$mergeable" = MERGEABLE ] \
    || mergeable_refusal="  - mergeable is \"${mergeable:-unreadable}\", not MERGEABLE
"
  [ "$merge_state" != DIRTY ] \
    || refusals="$refusals  - mergeStateStatus is DIRTY (conflicts)
"

  uncovered=''
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    covered=0
    if [ "${#ALLOW_RED[@]}" -gt 0 ]; then
      for check in "${ALLOW_RED[@]}"; do
        [ "$check" = "$name" ] && covered=1
      done
    fi
    [ "$covered" -eq 1 ] || {
      refusals="$refusals  - check '$name' is not green
"
      uncovered="${uncovered:+$uncovered, }$name"
    }
  done <<EOF
$red
EOF

  unreported=''
  if ! github_read_required_contexts "$base"; then
    while IFS= read -r line; do
      refusals="$refusals  - $line, so a required check that has not reported cannot be ruled out
"
    done <<EOF
$FM_PR_GITHUB_REQUIRED_ERROR
EOF
  fi
  producers='[]'
  if printf '%s' "$FM_PR_GITHUB_REQUIRED" | jq -e 'any(.[]; .app_id != null)' >/dev/null; then
    if ! runs=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/commits/$live_head/check-runs" 2>/dev/null) \
      || [ -z "$runs" ] \
      || ! producers=$(printf '%s' "$runs" | jq -sc --arg head "$live_head" '
        [ .[] | if (.check_runs | type) == "array" then .check_runs[] else error("invalid check runs") end
          | if (.name | type) == "string" and (.app.id | type) == "number" and .head_sha == $head
            then . else error("invalid check producer") end ]' 2>/dev/null); then
      producers='[]'
      refusals="$refusals  - required check producers at head $live_head could not be read
"
    fi
  fi
  if ! missing=$(github_required_checks_missing "$json" "$FM_PR_GITHUB_REQUIRED" "$producers"); then
    refusals="$refusals  - the GitHub pull request check rollup could not be read
"
  else
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      [ "${#ALLOW_MISSING[@]}" -gt 0 ] && [ "${ALLOW_MISSING[0]}" = "$name" ] && continue
      refusals="$refusals  - required check '$name' has not reported at head $live_head
"
      unreported="${unreported:+$unreported, }$name"
    done <<EOF
$missing
EOF
  fi

  if [ -n "$mergeable_refusal" ]; then
    if [ -z "$refusals" ] && [ "$mergeable" = UNKNOWN ]; then
      return 3
    fi
    refusals="$refusals$mergeable_refusal"
  fi

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    [ -z "$uncovered" ] || printf 'error: these checks are not green: %s\n' "$uncovered" >&2
    [ -z "$unreported" ] || printf 'error: these required checks have not reported: %s\n' "$unreported" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with every unwaived required check reported and every unwaived check green at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
  FM_PR_GITHUB_BASE=$base
}

# The arm-time verify for --queue-at-green: the same live read, the same field
# parse and the same required-checks proof as github_verify_mergeable, with
# the one difference a registration at PR-creation time needs - a check that
# is still running has not failed, so github_checks_failed owns the rollup
# reading and checks still pending do not block. A draft, a closed pull
# request, a conflict (mergeable CONFLICTING or mergeStateStatus DIRTY), a
# check that COMPLETED with a failing conclusion, and a required check that
# has not reported all still refuse the arm: arming one of those would either
# wait forever or queue a pull request nothing here verified. It reads the
# same json once, so it is its own function rather than a mode flag inside
# the merge verify. There are no waivers: an arm runs unattended, so it takes
# no --allow-red and no --allow-missing. mergeable UNKNOWN alone still
# returns 3 for the caller's bounded retry; a read that cannot produce all
# five named fields refuses outright, exactly like the merge verify. Sets
# FM_PR_MERGE_HEAD and FM_PR_GITHUB_BASE on success.
github_verify_armable() {
  local json fields line failed name missing unreported producers runs
  local total=0 named=0 refusals='' mergeable_refusal=''
  local state='' draft='' mergeable='' merge_state='' live_head='' base=''

  if ! json=$(gh pr view "$URL" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitHub pull request state before arming the merge queue" >&2
    return 1
  fi
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "mergeable=" + ((.mergeable // "") | tostring),
        "merge_state=" + ((.mergeStateStatus // "") | tostring),
        "head=" + ((.headRefOid // "") | tostring),
        "base=" + ((.baseRefName // "") | tostring)
      else
        error("pull request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitHub pull request state before arming the merge queue" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      mergeable=*) mergeable=${line#mergeable=} ;;
      merge_state=*) merge_state=${line#merge_state=} ;;
      head=*) live_head=${line#head=} ;;
      base=*) base=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 5 ] || [ "$total" -ne 5 ] || [ -z "$base" ]; then
    echo "error: could not read the GitHub pull request state before arming the merge queue" >&2
    return 1
  fi

  draft=$(fm_pr_json_draft_state "$json")
  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitHub pull request head commit before arming the merge queue" >&2
    return 1
  fi
  if ! failed=$(github_checks_failed "$json"); then
    echo "error: could not read the GitHub pull request state before arming the merge queue" >&2
    return 1
  fi

  case "$state" in
    [oO][pP][eE][nN]) ;;
    *)
      refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
      ;;
  esac
  [ "$draft" = false ] \
    || refusals="$refusals  - the pull request is a draft
"
  [ "$mergeable" = MERGEABLE ] \
    || mergeable_refusal="  - mergeable is \"${mergeable:-unreadable}\", not MERGEABLE
"
  [ "$merge_state" != DIRTY ] \
    || refusals="$refusals  - mergeStateStatus is DIRTY (conflicts)
"

  unreported=''
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    refusals="$refusals  - check '$name' has failed
"
  done <<EOF
$failed
EOF

  if ! github_read_required_contexts "$base"; then
    while IFS= read -r line; do
      refusals="$refusals  - $line, so a required check that has not reported cannot be ruled out
"
    done <<EOF
$FM_PR_GITHUB_REQUIRED_ERROR
EOF
  fi
  producers='[]'
  if printf '%s' "$FM_PR_GITHUB_REQUIRED" | jq -e 'any(.[]; .app_id != null)' >/dev/null; then
    if ! runs=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/commits/$live_head/check-runs" 2>/dev/null) \
      || [ -z "$runs" ] \
      || ! producers=$(printf '%s' "$runs" | jq -sc --arg head "$live_head" '
        [ .[] | if (.check_runs | type) == "array" then .check_runs[] else error("invalid check runs") end
          | if (.name | type) == "string" and (.app.id | type) == "number" and .head_sha == $head
            then . else error("invalid check producer") end ]' 2>/dev/null); then
      producers='[]'
      refusals="$refusals  - required check producers at head $live_head could not be read
"
    fi
  fi
  if ! missing=$(github_required_checks_missing "$json" "$FM_PR_GITHUB_REQUIRED" "$producers"); then
    refusals="$refusals  - the GitHub pull request check rollup could not be read
"
  else
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      refusals="$refusals  - required check '$name' has not reported at head $live_head
"
      unreported="${unreported:+$unreported, }$name"
    done <<EOF
$missing
EOF
  fi

  if [ -n "$mergeable_refusal" ]; then
    if [ -z "$refusals" ] && [ "$mergeable" = UNKNOWN ]; then
      return 3
    fi
    refusals="$refusals$mergeable_refusal"
  fi

  if [ -n "$refusals" ]; then
    printf 'error: refusing to arm the merge queue for %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    [ -z "$unreported" ] || printf 'error: these required checks have not reported: %s\n' "$unreported" >&2
    return 1
  fi
  printf 'verified: %s is open, not a draft, and conflict-free, with every required check reported and no check failed at head %s; checks still pending may finish\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
  FM_PR_GITHUB_BASE=$base
}

# Read one live GitHub pull request view after gh returns. The selected
# fields distinguish a landed pull request from a merge-queue entry and retain
# the concrete state needed for a refusal. gh supplies the complete queue-aware
# view; if that post-merge read becomes unavailable, gh-axi is the degradation
# path that can prove only a landed merge. gh remains a pre-merge prerequisite.
FM_PR_GITHUB_STATE=
FM_PR_GITHUB_MERGED=
FM_PR_GITHUB_QUEUED=
FM_PR_GITHUB_BASE=
FM_PR_GITHUB_QUEUE_OBSERVED=false
github_read_outcome_with_gh() {
  local fields line
  local total=0 named=0
  local state='' merged='' queued='' base=''

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue baseRefName}}}' \
    -F "owner=$PR_OWNER" -F "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "base=" + (.baseRefName // "")' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      queued=*) queued=${line#queued=} ;;
      base=*) base=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 4 ] || [ "$total" -ne 4 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; } \
    || { [ "$queued" != true ] && [ "$queued" != false ]; } \
    || [ -z "$base" ]; then
    return 1
  fi

  FM_PR_GITHUB_STATE=$state
  FM_PR_GITHUB_MERGED=$merged
  FM_PR_GITHUB_QUEUED=$queued
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_QUEUE_OBSERVED=true
}

github_read_outcome_with_gh_axi() {
  local output state
  if ! output=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    merged)
      FM_PR_GITHUB_STATE=MERGED
      FM_PR_GITHUB_MERGED=true
      FM_PR_GITHUB_QUEUED=false
      ;;
    *)
      FM_PR_GITHUB_STATE=$state
      FM_PR_GITHUB_MERGED=false
      FM_PR_GITHUB_QUEUED=unknown
      ;;
  esac
  FM_PR_GITHUB_BASE=
  FM_PR_GITHUB_QUEUE_OBSERVED=false
}

github_read_outcome() {
  if ! command -v gh >/dev/null 2>&1; then
    if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
      return 0
    fi
    echo "error: could not read the GitHub pull request outcome after the merge attempt; PR metadata and merge poll remain recorded" >&2
    return 1
  fi
  # Only a failed gh read falls back. A gh read that completes and reports the
  # pull request as neither merged nor queued is a concrete outcome, not a
  # missing one, so it keeps its own refusal. The gh-axi view cannot observe the
  # merge queue, so it can only turn this into a proved merge or into a refusal.
  github_read_outcome_with_gh && return 0
  if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
    return 0
  fi
  echo "error: could not read the GitHub pull request outcome after the merge attempt: the gh read failed and the gh-axi view could not prove the outcome either; PR metadata and merge poll remain recorded" >&2
  return 1
}

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Whether a failed branch-rules read (the gh stderr given) is GitHub's
# plan-gated 403 ("Upgrade to GitHub Pro or make this repository public"),
# which means the repository's plan cannot expose branch rules at all, on
# GitHub or GitHub Enterprise Server - not that this script failed to read
# them, and not that the token lacks a permission. Such a repository has no
# active ruleset rule of any kind. Any other failure (auth, rate limit,
# network, a 404, an unrelated 403) is not this and stays unreadable.
github_branch_rules_unavailable_on_plan() {
  case "$1" in
    *"Upgrade to GitHub Pro or make this repository public"*) return 0 ;;
  esac
  return 1
}

# Read the effective merge-queue method for the observed base branch. The four
# situations the refusal has to keep apart - no queue rule, a rules response
# that could not be read, several rules that disagree, and a rule whose method
# this script does not recognise - are reported as a status rather than folded
# into one failure, because each one means something different to the operator.
FM_PR_GITHUB_QUEUE_METHOD=
FM_PR_GITHUB_QUEUE_METHODS=
FM_PR_GITHUB_QUEUE_STATUS=unreadable
github_read_queue_method() {
  local methods line candidate method='' count=0 branch_path
  local unrecognised=false conflicting=false api_err api_err_text
  FM_PR_GITHUB_QUEUE_METHOD=
  FM_PR_GITHUB_QUEUE_METHODS=
  FM_PR_GITHUB_QUEUE_STATUS=unreadable
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$FM_PR_GITHUB_BASE" ] || return 0
  branch_path=$(github_urlencode_path_segment "$FM_PR_GITHUB_BASE")
  api_err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-queue-rules.XXXXXX") || return 0
  if ! methods=$(gh api \
    --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" \
    --jq '.[] | select(.type == "merge_queue") | "merge_method=" + (.parameters.merge_method // "")' \
    2>"$api_err"); then
    api_err_text=$(cat "$api_err" 2>/dev/null)
    rm -f "$api_err"
    # A repository that cannot have branch rules cannot have a merge_queue
    # rule either, so that specific refusal resolves to no queue rather than
    # the generic unreadable status.
    if github_branch_rules_unavailable_on_plan "$api_err_text"; then
      FM_PR_GITHUB_QUEUE_STATUS=none
    fi
    return 0
  fi
  rm -f "$api_err"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      merge_method=*) candidate=${line#merge_method=} ;;
      *) return 0 ;;
    esac
    count=$((count + 1))
    case "$candidate" in
      MERGE|SQUASH|REBASE) ;;
      *) unrecognised=true ;;
    esac
    if [ -z "$FM_PR_GITHUB_QUEUE_METHODS" ] && [ "$count" -eq 1 ]; then
      FM_PR_GITHUB_QUEUE_METHODS=$candidate
    else
      case ",$FM_PR_GITHUB_QUEUE_METHODS," in
        *",$candidate,"*) ;;
        *)
          FM_PR_GITHUB_QUEUE_METHODS="$FM_PR_GITHUB_QUEUE_METHODS,$candidate"
          conflicting=true
          ;;
      esac
    fi
    method=$candidate
  done <<METHODS
$methods
METHODS
  if [ "$count" -eq 0 ]; then
    FM_PR_GITHUB_QUEUE_STATUS=none
  elif [ "$conflicting" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=conflicting
  elif [ "$unrecognised" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=unrecognised
  else
    FM_PR_GITHUB_QUEUE_STATUS=single
    FM_PR_GITHUB_QUEUE_METHOD=$method
  fi
}

record_pr_metadata() {
  if ! FM_PR_CHECK_MERGE=1 "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"; then
    return 1
  fi
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    return 1
  }
}

require_released_captain_hold() {
  local hold_status=0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
  case "$hold_status" in
    0)
      echo "error: task $ID is still held for the captain; release it before merging" >&2
      return 1
      ;;
    1|3) return 0 ;;
    *)
      echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
      return 1
      ;;
  esac
}

FM_PR_MERGE_AUTHORITY=
# The authority read. bin/fm-merge-authority-lib.sh owns what the away-posture
# record's presence means; this function owns what a merge run may do about it,
# so the answer the merge poll later tags its ledger row with is the same answer
# resolved here. An unreadable record refuses rather than being skipped.
resolve_merge_authority() {
  FM_PR_MERGE_AUTHORITY=
  if fm_merge_authority_resolve "$FM_HOME" "$STATE" "$META" "$ID"; then
    FM_PR_MERGE_AUTHORITY=$FM_MERGE_AUTHORITY
    return 0
  fi
  echo "error: PR merge refused - the away-posture record could not be read; nothing was merged" >&2
  return 1
}

# Take the away record's own lock (bin/fm-afk-contract.sh owns it) so that
# record cannot be published, replaced, or archived between the authority read
# below and the forge command that acts on it. Refuses without the lock: a merge
# on authority nothing is holding still is exactly what this closes. This is the
# only path that holds both the per-task control lock and the away-record lock,
# and it always takes them in that order; the away-record side takes only its own
# lock, so the pair cannot deadlock.
hold_away_record_for_merge() {
  fm_afk_contract_lock_hold "$STATE" && return 0
  echo "error: PR merge refused - the away-posture record could not be locked for the merge; nothing was merged" >&2
  return 1
}

require_current_away_authority() {
  FM_PR_AWAY_POSTURE=false
  # GitHub --auto is not refused here: whether an --auto may run under away
  # authority depends on the base branch's merge-queue state, which only
  # github_resolve_merge_route reads (inside the away-record lock, after this
  # read), so that route owns the whole decision. GitLab's auto-merge has no
  # queue to enqueue through, so it stays refused here. Every other away gate
  # below is posture-only and never sees the queue state.
  if fm_afk_contract_away_present "$STATE"; then
    FM_PR_AWAY_POSTURE=true
    if [ "$PROVIDER" = gitlab ] \
      && { [ "$FM_PR_GITLAB_ASYNC_REQUESTED" = true ] || [ "$FM_PR_GITLAB_ASYNC_CONFIGURED" = true ]; }; then
      echo "error: GitLab auto-merge is attended-only; while the away-posture record exists only an immediate merge may run under its authority lock" >&2
      return 2
    fi
  fi
  fm_lease_forbid_branch "PR merge (fm-pr-merge)" --away-relocated
  resolve_merge_authority || return 1
  if [ "$FM_PR_AWAY_POSTURE" = true ] && [ "${#ALLOW_RED[@]}" -gt 0 ]; then
    echo "error: --allow-red is attended-only; while the away-posture record exists the green check is absolute" >&2
    return 2
  fi
  if [ "$FM_PR_AWAY_POSTURE" = true ] && [ "${#ALLOW_MISSING[@]}" -gt 0 ]; then
    echo "error: --allow-missing is attended-only; while the away-posture record exists every required check must report" >&2
    return 2
  fi
  if [ "$FM_PR_AWAY_POSTURE" = true ] && [ "$ALLOW_NO_PIPELINE" = true ]; then
    echo "error: --allow-no-pipeline is attended-only; while the away-posture record exists a GitLab merge requires a successful head pipeline" >&2
    return 2
  fi
}

persist_accepted_merge_authority() {
  local status=0
  MERGE_META_LOCK=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$MERGE_META_LOCK" || return 1
  fm_merge_authority_persist "$STATE" "$ID" "$META" \
    "$PROVIDER" "$PR_HOST" "$PR_PATH" "$PR_NUMBER" "$FM_PR_MERGE_AUTHORITY" \
    || status=1
  fm_lock_release "$MERGE_META_LOCK" || status=1
  MERGE_META_LOCK=
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  printf 'actionable: the forge accepted the merge request for %s but its merge authority could not be persisted; the merge poll remains armed\n' \
    "$URL" >&2
  return 1
}

# FM-1: record each pull request enqueued in a merge queue under away authority
# in the away-posture record's queue list (bin/fm-afk-contract.sh), so the
# record's archive dequeues any entry that has not landed when the away posture
# ends and a queued merge never lands on lapsed authority. Runs while the away
# record lock is still held; a failure is loud and refuses the run, because an
# accepted enqueue that cannot be recorded can no longer be dequeued.
record_away_queue_enqueue() {
  if fm_afk_contract_queue_record "$STATE" "$URL"; then
    printf 'queued under away authority: %s is recorded in the away queue list and is dequeued if it is still queued when the away posture ends\n' \
      "$URL" >&2
    return 0
  fi
  printf 'actionable: the forge accepted the queue enqueue for %s under away authority, but it could not be recorded in the away queue list, so the away archive cannot dequeue it; the merge poll remains armed\n' \
    "$URL" >&2
  return 1
}

# Which way a GitHub merge runs. A base branch whose rules prove no merge queue
# merges directly (gh pr merge), as ever. A base branch with a merge_queue rule
# merges through the queue route below when the caller asked for nothing but a
# merge method: the queue's own configured method applies, so a method flag is
# only noted, and any other extra argument (or an explicit --auto) keeps the
# direct route, which its own contract owns. While away, a merge may run only
# when it is synchronous or when the away queue list can carry it to the
# archive's dequeue: a queue base takes the queue route (a synchronous wait
# until merged or failed), the exact --auto --<method> enqueue of a single
# recognised queue method runs on the direct route and is recorded for the
# archive sweep (FM_PR_GITHUB_AWAY_QUEUE_ENQUEUE below), and every other shape
# on a queue base is refused. A base whose rules cannot be read refuses because
# neither an immediate merge nor a queue can be proved. A
# repository whose plan does not expose branch rules at all (GitHub's "Upgrade
# to GitHub Pro or make this repository public" 403) proves no queue on its own,
# since such a repository cannot have a merge_queue rule either; see
# github_read_queue_method, which resolves that specific 403 to status=none.
# Every other failure to read the queue state (auth, rate limit, network, a
# 404, or an unrelated 403) stays unreadable and refuses the merge while away,
# and merges directly while attended, as before.
FM_PR_GITHUB_MERGE_ROUTE=direct
FM_PR_GITHUB_AWAY_QUEUE_ENQUEUE=false
github_resolve_merge_route() {  # <caller extra args>
  local queue_method
  FM_PR_GITHUB_MERGE_ROUTE=direct
  FM_PR_GITHUB_AWAY_QUEUE_ENQUEUE=false
  # Accepted confused-agent-grade limitation, as in bin/fm-lease-lib.sh, not an
  # oversight: a queue rule or PR base change after this preflight can still
  # enqueue the merge, which can land after its away authority lapses.
  github_read_queue_method
  case "$FM_PR_GITHUB_QUEUE_STATUS" in
    single | conflicting | unrecognised)
      if [ "$FM_PR_GITHUB_AUTO_REQUESTED" != true ] && caller_args_are_method_only "$@"; then
        FM_PR_GITHUB_MERGE_ROUTE=queue
        return 0
      fi
      ;;
  esac
  [ "$FM_PR_AWAY_POSTURE" = true ] || return 0
  if [ "$FM_PR_GITHUB_QUEUE_STATUS" = none ]; then
    # No queue rule: no enqueue can carry an --auto through the away posture,
    # and a direct auto-merge could land after away authority lapses.
    if [ "$FM_PR_GITHUB_AUTO_REQUESTED" != true ]; then
      return 0
    fi
    printf 'error: --auto is attended-only while the away-posture record exists; base branch %s has no merge queue rule, so no enqueue can carry it and an auto-merge could land after away authority lapses\n' \
      "$FM_PR_GITHUB_BASE" >&2
    return 2
  fi
  if [ "$FM_PR_GITHUB_QUEUE_STATUS" = single ]; then
    queue_method=$(printf '%s' "$FM_PR_GITHUB_QUEUE_METHOD" | tr '[:upper:]' '[:lower:]')
    if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ] \
      && github_caller_method_is "$queue_method" \
      && caller_args_are_auto_method_only "$@"; then
      # The one asynchronous request away authority allows: the exact enqueue
      # the queue's own rule names, recorded in the away queue list so the
      # archive dequeues it if the away posture ends first.
      FM_PR_GITHUB_AWAY_QUEUE_ENQUEUE=true
      return 0
    fi
    if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
      printf 'error: --auto is attended-only while the away-posture record exists; base branch %s requires the merge queue, so under away authority only the exact enqueue flags --auto --%s and nothing else may run\n' \
        "$FM_PR_GITHUB_BASE" "$queue_method" >&2
      return 2
    fi
  fi
  echo "error: GitHub merge refused while away because the base branch's merge-queue state does not prove an immediate merge; nothing was handed to the forge" >&2
  return 2
}

require_recorded_pr_identity() {
  local existing
  existing=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$existing" ] || return 0
  [ "$existing" = "$URL" ] && return 0
  # Parsed in a subshell so FM_PR_* stays the new URL's identity for every
  # caller after this gate; only the already-notified verdict escapes.
  if ( fm_pr_url_parse "$existing" \
    && fm_pr_poll_merge_already_notified "$STATE" "$ID" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" ); then
    return 0
  fi
  echo "error: task $ID is bound to $existing, not $URL" >&2
  return 1
}

FM_PR_GITHUB_MERGE_ACCEPTED=false
FM_PR_GITHUB_CALLER_METHOD=

# The single gate every statement about what the forge accepted, armed, or
# reported has to pass. A merge command that failed accepted nothing, so no
# such statement may be made on its path, and routing them all through one
# predicate keeps a later one from being written without the gate.
github_merge_command_succeeded() {
  [ "$FM_PR_GITHUB_MERGE_ACCEPTED" = true ]
}

github_report_forge_output() {
  local output=$1 line
  github_merge_command_succeeded || return 0
  [ -n "$output" ] || return 0
  echo "error: the merge command's own output follows, quoted; it is the forge CLI's report, not this script's verdict:" >&2
  while IFS= read -r line; do
    printf 'error: > %s\n' "$line" >&2
  done <<OUTPUT
$output
OUTPUT
}

github_state_is_open() {
  case "$FM_PR_GITHUB_STATE" in
    [oO][pP][eE][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# Whether the caller's extra arguments are exactly an auto-merge request plus
# merge method flags (--auto or --auto=true with the method flags
# caller_args_are_method_only accepts), the one enqueue shape the away
# authority allows a --auto to take. Anything else riding along (a subject, a
# bypass, branch deletion) is not that enqueue.
caller_args_are_auto_method_only() {
  local arg auto=false
  local rest=()
  for arg in "$@"; do
    case "$arg" in
      --auto | --auto=true) auto=true ;;
      *) rest+=("$arg") ;;
    esac
  done
  [ "$auto" = true ] || return 1
  caller_args_are_method_only "${rest[@]+"${rest[@]}"}"
}

# Whether the caller's own named method is the one the queue is configured for,
# compared without regard to the spelling either side happens to use.
github_caller_method_is() {
  case "$FM_PR_GITHUB_CALLER_METHOD" in
    [mM][eE][rR][gG][eE]) [ "$1" = merge ] ;;
    [sS][qQ][uU][aA][sS][hH]) [ "$1" = squash ] ;;
    [rR][eE][bB][aA][sS][eE]) [ "$1" = rebase ] ;;
    *) return 1 ;;
  esac
}

github_report_queue_rules() {
  local queue_method methods_display
  github_read_queue_method
  case "$FM_PR_GITHUB_QUEUE_STATUS" in
    single)
      case "$FM_PR_GITHUB_QUEUE_METHOD" in
        MERGE) queue_method=merge ;;
        SQUASH) queue_method=squash ;;
        REBASE) queue_method=rebase ;;
      esac
      if github_merge_command_succeeded \
        && [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ] \
        && github_caller_method_is "$queue_method"; then
        printf 'error: this run refuses even though the request for %s was accepted with the exact flags base branch %s requires (--auto --%s): the pull request has still not entered the merge queue, so no landed or queued outcome is proven; re-check the pull request'"'"'s merge queue state before retrying\n' \
          "$URL" "$FM_PR_GITHUB_BASE" "$queue_method" >&2
      else
        printf 'error: base branch %s requires the merge queue; retry with: %s %s %s --attended-override -- --auto --%s%s\n' \
          "$FM_PR_GITHUB_BASE" "$0" "$ID" "$URL" "$queue_method" \
          "$( [ "$FM_PR_AWAY_POSTURE" = true ] && printf ' (away authority allows exactly that enqueue, and records it for the archive to dequeue)' )" >&2
      fi
      ;;
    conflicting)
      printf 'error: base branch %s has conflicting merge queue methods (%s); exact retry flags are ambiguous\n' \
        "$FM_PR_GITHUB_BASE" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }" >&2
      ;;
    unrecognised)
      methods_display=${FM_PR_GITHUB_QUEUE_METHODS//,/, }
      [ -n "$methods_display" ] || methods_display='<none reported>'
      printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises, so exact retry flags cannot be named\n' \
        "$FM_PR_GITHUB_BASE" "$methods_display" >&2
      ;;
    unreadable)
      printf 'error: the branch rules for base branch %s could not be read, so a merge queue requirement can be neither confirmed nor ruled out here\n' \
        "${FM_PR_GITHUB_BASE:-<unknown>}" >&2
      ;;
  esac
}

github_report_unmerged_outcome() {
  printf 'error: GitHub merge outcome was not successful: state=%s, merged=%s, isInMergeQueue=%s\n' \
    "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
  if ! github_state_is_open || [ "$FM_PR_GITHUB_MERGED" != false ] \
    || [ "$FM_PR_GITHUB_QUEUED" = true ]; then
    return 0
  fi
  if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
    if github_merge_command_succeeded; then
      printf 'error: auto-merge was requested and armed for %s, but nothing is merged or in the merge queue yet, so this run refuses instead of reporting an unproved merge\n' \
        "$URL" >&2
    else
      printf 'error: auto-merge was requested for %s, but the merge command itself failed, so nothing was enabled, merged or queued\n' \
        "$URL" >&2
    fi
  fi
  if [ "$FM_PR_GITHUB_QUEUE_OBSERVED" != true ]; then
    if [ "$FM_PR_AWAY_POSTURE" = true ]; then
      printf 'error: the synchronous merge did not land while the away-posture record exists, and the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; if this run enqueued it under away authority it is recorded in the away queue list for the archive to dequeue; re-check the pull request'"'"'s merge queue state before retrying\n' >&2
    else
      printf 'error: the merge queue could not be observed for %s because the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; re-check the pull request'"'"'s merge queue state before retrying\n' \
        "$URL" >&2
    fi
    return 0
  fi
  github_report_queue_rules
}

# The merge queue route. When the base branch requires a merge queue, a pull
# request is enqueued through GitHub's GraphQL enqueuePullRequest mutation, bound
# to the verified head with expectedHeadOid exactly as --match-head-commit binds
# the direct merge, and this script then waits, synchronously, until GitHub
# reports the pull request merged. Only a merged pull request counts as landed.
# A pull request that leaves the queue without merging (removed by a person,
# ejected after a failed required check, or closed) is a refusal, never a
# landing, and a wait that runs out is a refusal too, because a queued merge
# nothing observed to completion is exactly the unproved outcome this script
# refuses everywhere else. The wait, not the enqueue, is what keeps a queued
# merge inside the away rule that a merge is synchronous.
FM_PR_QUEUE_ID=
FM_PR_QUEUE_STATE=
FM_PR_QUEUE_MERGED=
FM_PR_QUEUE_QUEUED=
FM_PR_QUEUE_ENTRY=
FM_PR_QUEUE_HEAD=
FM_PR_QUEUE_BRANCH=
FM_PR_QUEUE_REMOVED_AT=
FM_PR_QUEUE_REMOVED_REASON=
# One live read of the pull request's queue state: its node id (the mutation
# needs it), state, merged and queued flags, its queue entry's own state, its
# head and head branch, and the latest removed-from-queue event with GitHub's
# stated reason. A read that does not return every field fails as a whole.
github_queue_read() {
  local fields line total=0 named=0
  FM_PR_QUEUE_ID=''
  FM_PR_QUEUE_STATE=''
  FM_PR_QUEUE_MERGED=''
  FM_PR_QUEUE_QUEUED=''
  FM_PR_QUEUE_ENTRY=''
  FM_PR_QUEUE_HEAD=''
  FM_PR_QUEUE_BRANCH=''
  FM_PR_QUEUE_REMOVED_AT=''
  FM_PR_QUEUE_REMOVED_REASON=''
  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){id state merged isInMergeQueue headRefOid headRefName mergeQueueEntry{state} timelineItems(last:1,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]){nodes{... on RemovedFromMergeQueueEvent{createdAt reason}}}}}}' \
    -f "owner=$PR_OWNER" -f "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository.pullRequest | "id=" + (.id // ""), "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "entry=" + (.mergeQueueEntry.state // ""), "head=" + (.headRefOid // ""), "branch=" + (.headRefName // ""), "removed_at=" + (.timelineItems.nodes[-1].createdAt // ""), "removed_reason=" + ((.timelineItems.nodes[-1].reason // "") | gsub("[\r\n]+"; " "))' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      id=*) FM_PR_QUEUE_ID=${line#id=} ;;
      state=*) FM_PR_QUEUE_STATE=${line#state=} ;;
      merged=*) FM_PR_QUEUE_MERGED=${line#merged=} ;;
      queued=*) FM_PR_QUEUE_QUEUED=${line#queued=} ;;
      entry=*) FM_PR_QUEUE_ENTRY=${line#entry=} ;;
      head=*) FM_PR_QUEUE_HEAD=${line#head=} ;;
      branch=*) FM_PR_QUEUE_BRANCH=${line#branch=} ;;
      removed_at=*) FM_PR_QUEUE_REMOVED_AT=${line#removed_at=} ;;
      removed_reason=*) FM_PR_QUEUE_REMOVED_REASON=${line#removed_reason=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 9 ] || [ "$total" -ne 9 ] || [ -z "$FM_PR_QUEUE_STATE" ] \
    || [ -z "$FM_PR_QUEUE_ID" ] || [ -z "$FM_PR_QUEUE_HEAD" ] \
    || { [ "$FM_PR_QUEUE_MERGED" != true ] && [ "$FM_PR_QUEUE_MERGED" != false ]; } \
    || { [ "$FM_PR_QUEUE_QUEUED" != true ] && [ "$FM_PR_QUEUE_QUEUED" != false ]; }; then
    return 1
  fi
}

# A bounded non-negative integer from an environment override, else the default.
github_queue_setting() {  # <value> <default> <max>
  case "$1" in
    '' | *[!0-9]*) printf '%s' "$2" ;;
    *) if [ "$1" -le "$3" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi ;;
  esac
}

# FM-3: a pull request in the merge queue must not be rebased or pushed to,
# because a new head drops it from the queue and invalidates the queue builds
# behind it. The only thing in this home that rebases and pushes a task's
# branch on its own is the no-mistakes CI monitor, which "watches CI and
# auto-rebases when the base branch advances" until its pull request is merged,
# and a queued pull request waits through exactly such base advances. So before
# the enqueue the task's own run on this pull request's head branch is ended
# with no-mistakes axi handoff, which leaves the pull request open. A run that
# cannot be handed off (still working, parked at a gate, or its handoff
# refused) refuses the enqueue rather than leave a pipeline that can push. A
# task with no worktree, no no-mistakes, or no run on the branch has nothing
# to end; the query is read-only and fails open, as teardown's does.
github_release_branch_before_enqueue() {
  local wt kind out run_status timeout
  kind=$(sed -n 's/^kind=//p' "$META" | tail -n 1)
  [ "${kind:-ship}" = ship ] || return 0
  wt=$(sed -n 's/^worktree=//p' "$META" | tail -n 1)
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  timeout=$(github_queue_setting "${FM_PR_MERGE_NM_TIMEOUT:-}" 10 600)
  out=$(fm_nm_run "$wt" "$timeout" axi status)
  [ -n "$out" ] || return 0
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")" = "$FM_PR_QUEUE_BRANCH" ] || return 0
  fm_nm_run_is_active "$out" || return 0
  run_status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  if [ "$run_status" = ci ] && ! fm_nm_run_is_parked "$out" \
    && fm_nm_run_checked "$wt" "$timeout" axi handoff >/dev/null; then
    out=$(fm_nm_run "$wt" "$timeout" axi status)
    fm_nm_run_is_active "$out" || {
      printf 'ended the no-mistakes CI monitor for %s before enqueueing, so nothing rebases or pushes to the queued pull request\n' \
        "$FM_PR_QUEUE_BRANCH" >&2
      return 0
    }
  fi
  printf 'error: a no-mistakes run is still driving branch %s and could rebase or push to the pull request once it is queued, which would drop it from the merge queue; end it first (no-mistakes axi handoff, or axi abort), then retry; nothing was enqueued\n' \
    "$FM_PR_QUEUE_BRANCH" >&2
  return 1
}

# One live queue read that binds this run to the entry it is about to enqueue,
# for both paths that hand a pull request to a merge queue: refuses when the
# queue state cannot be read or the head moved after verification, because in
# both cases nothing was handed to the forge.
github_require_queue_entry_ready() {
  if ! github_queue_read; then
    echo "error: the merge queue state of $URL could not be read, so nothing was enqueued" >&2
    exit 1
  fi
  if [ "$FM_PR_QUEUE_HEAD" != "$FM_PR_MERGE_HEAD" ]; then
    printf 'error: %s moved to %s after head %s was verified; nothing was enqueued\n' \
      "$URL" "$FM_PR_QUEUE_HEAD" "$FM_PR_MERGE_HEAD" >&2
    exit 1
  fi
}

github_enqueue_pull_request() {
  local output
  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if output=$(gh api graphql \
    -f query='mutation($id:ID!,$oid:GitObjectID){enqueuePullRequest(input:{pullRequestId:$id,expectedHeadOid:$oid}){mergeQueueEntry{state}}}' \
    -f "id=$FM_PR_QUEUE_ID" -f "oid=$FM_PR_MERGE_HEAD" \
    --jq '.data.enqueuePullRequest.mergeQueueEntry.state // ""' 2>&1); then
    return 0
  fi
  [ -z "$output" ] || printf '%s\n' "$output" >&2
  return 1
}

github_queue_refuse_left() {  # <how it was observed>
  printf 'error: %s left the merge queue without merging (state=%s, merged=%s, isInMergeQueue=%s), so nothing landed and this is a refusal, not a merge\n' \
    "$URL" "$FM_PR_QUEUE_STATE" "$FM_PR_QUEUE_MERGED" "$FM_PR_QUEUE_QUEUED" >&2
  if [ -n "$FM_PR_QUEUE_REMOVED_AT" ] && [ "$FM_PR_QUEUE_REMOVED_AT" != "${1:-}" ]; then
    printf 'error: GitHub recorded its removal at %s with this reason, quoted; it is the forge'"'"'s text, not this script'"'"'s verdict:\n' \
      "$FM_PR_QUEUE_REMOVED_AT" >&2
    printf 'error: > %s\n' "${FM_PR_QUEUE_REMOVED_REASON:-<no reason reported>}" >&2
  else
    printf 'error: GitHub recorded no removal reason for this entry; read the queue entry'"'"'s checks on the pull request\n' >&2
  fi
  printf 'error: fix the cause, then run this command again to enqueue it afresh; the merge poll for %s stays armed\n' "$URL" >&2
}

# The queue route's whole merge: read, end any branch-pushing pipeline, enqueue,
# persist the accepted authority, release both locks, then wait. Returns 0 only
# for a proved merge; every other outcome exits 1 with its refusal.
github_merge_through_queue() {
  local interval timeout started elapsed baseline_removed_at last_entry=''
  local left_reads=0 read_failures=0
  interval=$(github_queue_setting "${FM_PR_MERGE_QUEUE_POLL_INTERVAL:-}" 30 3600)
  timeout=$(github_queue_setting "${FM_PR_MERGE_QUEUE_TIMEOUT:-}" 7200 604800)
  [ "$timeout" -gt 0 ] || timeout=7200
  if [ -n "$FM_PR_GITHUB_CALLER_METHOD" ] && [ "$FM_PR_GITHUB_QUEUE_STATUS" = single ] \
    && ! github_caller_method_is "$(printf '%s' "$FM_PR_GITHUB_QUEUE_METHOD" | tr '[:upper:]' '[:lower:]')"; then
    printf 'notice: base branch %s merges through its merge queue, whose own method (%s) applies instead of --%s\n' \
      "$FM_PR_GITHUB_BASE" "$FM_PR_GITHUB_QUEUE_METHOD" "$FM_PR_GITHUB_CALLER_METHOD" >&2
  fi
  github_require_queue_entry_ready
  baseline_removed_at=$FM_PR_QUEUE_REMOVED_AT
  github_release_branch_before_enqueue || exit 1
  if [ "$FM_PR_QUEUE_QUEUED" = true ]; then
    printf 'queued: %s is already in the merge queue; waiting for it to merge\n' "$URL" >&2
  else
    if ! github_enqueue_pull_request; then
      # A failed call can still have enqueued; only the live read decides.
      if ! github_queue_read || [ "$FM_PR_QUEUE_QUEUED" != true ]; then
        echo "error: the merge queue did not accept $URL, so nothing was enqueued or merged" >&2
        exit 1
      fi
    fi
    printf 'queued: %s entered the merge queue; waiting up to %ss for it to merge\n' "$URL" "$timeout" >&2
  fi
  FM_PR_GITHUB_MERGE_ACCEPTED=true
  persist_accepted_merge_authority || exit 1
  [ "$FM_PR_AWAY_POSTURE" != true ] || record_away_queue_enqueue || exit 1
  fm_afk_contract_lock_release || true
  fm_lock_release "$MERGE_CONTROL_LOCK" || true
  MERGE_CONTROL_LOCK=
  started=$SECONDS
  while :; do
    if github_queue_read; then
      read_failures=0
      if [ "$FM_PR_QUEUE_MERGED" = true ]; then
        printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s)\n' \
          "$URL" "$FM_PR_QUEUE_STATE" "$FM_PR_QUEUE_MERGED" "$FM_PR_QUEUE_QUEUED"
        return 0
      fi
      if [ "$FM_PR_QUEUE_QUEUED" = true ]; then
        left_reads=0
        if [ "$FM_PR_QUEUE_ENTRY" != "$last_entry" ]; then
          last_entry=$FM_PR_QUEUE_ENTRY
          printf 'queued: %s queue entry is %s\n' "$URL" "${last_entry:-unknown}" >&2
        fi
      else
        # Not queued and not merged. A closed pull request has left for good; an
        # open one is read twice more so a lagging flag is not mistaken for an
        # ejection, then it is a refusal.
        left_reads=$((left_reads + 1))
        if ! github_state_is_open_value "$FM_PR_QUEUE_STATE" || [ "$left_reads" -ge 3 ]; then
          github_queue_refuse_left "$baseline_removed_at"
          exit 1
        fi
        sleep "$(github_queue_setting "${FM_PR_MERGE_QUEUE_RECHECK_DELAY:-}" 5 60)"
        continue
      fi
    else
      read_failures=$((read_failures + 1))
      if [ "$read_failures" -ge 5 ]; then
        if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
          printf 'verified: %s is merged (state=%s, merged=%s)\n' \
            "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED"
          return 0
        fi
        printf 'error: the merge queue state of %s could not be read %s times in a row, so its merge is unproved; the merge poll remains armed\n' \
          "$URL" "$read_failures" >&2
        exit 1
      fi
    fi
    elapsed=$((SECONDS - started))
    if [ "$elapsed" -ge "$timeout" ]; then
      printf 'error: %s was still in the merge queue after %ss, so its merge is unproved; the merge poll remains armed and records the landing if it happens, and running this command again waits again without enqueueing twice\n' \
        "$URL" "$elapsed" >&2
      exit 1
    fi
    sleep "$interval"
  done
}

github_state_is_open_value() {
  case "$1" in
    [oO][pP][eE][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# The arm's own review-coverage proof. A merge turn gets its coverage from
# the supervision session that decided to merge; an arm that will let GitHub
# enqueue on its own does not, so it reads the coverage the record keeps: the
# task's no-mistakes run (axi status names the run id) must hold a completed
# review whose approved head is exactly the head being armed
# (fm_nm_review_coverage). A task with no run record, a run without a review,
# or a review of an older head prints unverified or stale and is not armed -
# a URL-bound queue-pending intent lets the watcher retry the same guarded
# arm once coverage catches up. The verdict is left in
# FM_PR_ARM_COVERAGE for the refusal line.
FM_PR_ARM_COVERAGE=
github_arm_review_coverage() {  # <head>
  local head=$1 kind wt timeout out run_id
  FM_PR_ARM_COVERAGE=unverified
  kind=$(sed -n 's/^kind=//p' "$META" | tail -n 1)
  [ "${kind:-ship}" = ship ] || return 1
  wt=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  case "$wt" in
    /*) ;;
    *) wt="$PWD/$wt" ;;
  esac
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  command -v no-mistakes >/dev/null 2>&1 || return 1
  timeout=$(github_queue_setting "${FM_PR_MERGE_NM_TIMEOUT:-}" 10 600)
  out=$(fm_nm_run "$wt" "$timeout" axi status)
  [ -n "$out" ] || return 1
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  case "$run_id" in
    ''|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  FM_PR_ARM_COVERAGE=$(cd "$wt" && fm_nm_review_coverage "$run_id" "$head") \
    || FM_PR_ARM_COVERAGE=unverified
  [ "$FM_PR_ARM_COVERAGE" = covered ]
}

# --queue-at-green, the registration-time arm bin/fm-pr-check.sh invokes.
# Every guard a merge turn runs is here in the form an unattended arm needs:
# the live PR verified by github_verify_armable; review coverage for the
# exact head; a single recognised merge-queue method on the base branch (no
# merge_queue rule at all means the project has no merge queue: nothing is
# armed and that is not an error, because without a queue there is nothing to
# wait for green); a fresh queue read at the verified head with the removed-
# from-queue timestamp recorded as the arm's baseline; the away-record lock
# with a re-read of the merge authority, exactly as a merge; and FM-3,
# github_release_branch_before_enqueue, so nothing here can rebase or push
# the branch once it is armed for the queue. Only then does the arm run, as
# gh's merge-when-ready request --auto --<queue method> bound to the verified
# head with --match-head-commit: nothing is merged or enqueued by this script,
# GitHub itself puts the pull request into the merge queue when the required
# checks turn green. The result is read back live: merged or queued proves the
# arm (an already-green pull request may enter the queue at once); anything
# else - an approval-required pull request, a forge-side refusal, an
# unreadable state - is disarmed again with --disable-auto before refusing,
# so no arm this script cannot prove is left live. A proved arm persists the
# accepted merge authority, records itself in the away queue list while away
# (the away archive can then dequeue it), and writes the private
# $STATE/$ID.queue-arm record the watcher sweeps with --queue-requeue; a
# record that cannot be written disarms the arm too, because an arm the sweep
# cannot see could neither requeue once nor disarm on a new push. The mode
# writes to stderr only and never fails the registration that invoked it.
github_arm_queue_at_green() {
  local verify_status=1 attempt=1 arm_status=0 merge_output
  local queue_method arm_baseline
  # mergeable reads UNKNOWN for a short while after a push, exactly as in the
  # merge route; retry bounded so a just-pushed pull request can still be
  # armed.
  local retry_delay=${FM_PR_GITHUB_MERGEABLE_RETRY_DELAY:-3}
  case "$retry_delay" in
    [0-9] | 10) ;;
    *) retry_delay=3 ;;
  esac
  while :; do
    verify_status=0
    github_verify_armable || verify_status=$?
    if [ "$verify_status" -eq 0 ] || [ "$verify_status" -ne 3 ] || [ "$attempt" -ge 5 ]; then
      break
    fi
    sleep "$retry_delay"
    attempt=$((attempt + 1))
  done
  [ "$verify_status" -eq 0 ] || exit 1
  # The queue itself is proved first, before any review-coverage read: a
  # project without a merge queue has nothing to arm whatever its coverage,
  # and reading coverage needs state this script must not demand there.
  github_read_queue_method
  case "$FM_PR_GITHUB_QUEUE_STATUS" in
    none)
      rm -f "$STATE/$ID.queue-pending"
      printf 'queue arm: %s was not armed: base branch %s has no merge queue rule, so the pull request follows the ordinary merge path\n' \
        "$URL" "${FM_PR_GITHUB_BASE:-<unreadable>}" >&2
      exit 0
      ;;
    single)
      case "$FM_PR_GITHUB_QUEUE_METHOD" in
        MERGE) queue_method=merge ;;
        SQUASH) queue_method=squash ;;
        REBASE) queue_method=rebase ;;
        *)
          printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises, so %s was not armed\n' \
            "${FM_PR_GITHUB_BASE:-<unreadable>}" "${FM_PR_GITHUB_QUEUE_METHOD:-<unset>}" "$URL" >&2
          exit 1
          ;;
      esac
      ;;
    conflicting)
      printf 'error: base branch %s has conflicting merge queue methods (%s), so %s was not armed\n' \
        "${FM_PR_GITHUB_BASE:-<unreadable>}" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }" "$URL" >&2
      exit 1
      ;;
    unrecognised)
      printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises, so %s was not armed\n' \
        "${FM_PR_GITHUB_BASE:-<unreadable>}" "${FM_PR_GITHUB_QUEUE_METHOD:-<unset>}" "$URL" >&2
      exit 1
      ;;
    *)
      printf 'error: the branch rules for base branch %s could not be read, so a merge queue cannot be proved for %s and it was not armed\n' \
        "${FM_PR_GITHUB_BASE:-<unreadable>}" "$URL" >&2
      exit 1
      ;;
  esac
  if ! github_arm_review_coverage "$FM_PR_MERGE_HEAD"; then
    if [ ! -e "$STATE/$ID.queue-arm" ]; then
      fm_queue_pending_write "$STATE" "$ID" "$URL" \
        || printf 'error: could not persist coverage retry intent for %s\n' "$URL" >&2
    fi
    printf 'error: review coverage for head %s is %s, not covered, so %s was not armed; the watcher retries with the same guards after coverage catches up\n' \
      "$FM_PR_MERGE_HEAD" "$FM_PR_ARM_COVERAGE" "$URL" >&2
    exit 1
  fi
  hold_away_record_for_merge || exit 1
  away_status=0
  require_current_away_authority || away_status=$?
  if [ "$away_status" -ne 0 ]; then
    exit "$away_status"
  fi
  github_require_queue_entry_ready
  arm_baseline=${FM_PR_QUEUE_REMOVED_AT:--}
  if [ "$FM_PR_QUEUE_QUEUED" = true ]; then
    rm -f "$STATE/$ID.queue-pending"
    printf 'queue arm: %s is already in the merge queue at head %s, so nothing was armed; the merge poll owns its landing\n' \
      "$URL" "$FM_PR_MERGE_HEAD" >&2
    fm_afk_contract_lock_release || true
    exit 0
  fi
  github_release_branch_before_enqueue || exit 1
  merge_output=
  arm_status=0
  if ! merge_output=$(gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
    --match-head-commit "$FM_PR_MERGE_HEAD" --auto "--$queue_method" 2>&1); then
    arm_status=$?
  fi
  if [ "$arm_status" -ne 0 ]; then
    [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
    printf 'error: the merge-when-ready request for %s was refused, so nothing was armed; a merge turn can still merge it once its checks are green\n' \
      "$URL" >&2
    exit 1
  fi
  if ! github_queue_read; then
    gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --disable-auto >/dev/null 2>&1 || true
    printf 'error: the merge queue state of %s could not be read after arming, so the arm was undone and nothing was armed\n' \
      "$URL" >&2
    exit 1
  fi
  if [ "$FM_PR_QUEUE_MERGED" != true ] && [ "$FM_PR_QUEUE_QUEUED" != true ]; then
    gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --disable-auto >/dev/null 2>&1 || true
    printf 'error: %s did not enter the merge queue after the merge-when-ready request (state=%s, merged=%s, isInMergeQueue=%s), so the arm was undone; re-check its review and branch-protection requirements\n' \
      "$URL" "${FM_PR_QUEUE_STATE:-<unreadable>}" "${FM_PR_QUEUE_MERGED:-<unreadable>}" "${FM_PR_QUEUE_QUEUED:-<unreadable>}" >&2
    exit 1
  fi
  if ! persist_accepted_merge_authority; then
    printf 'actionable: %s was armed for the merge queue but its merge authority could not be persisted, so firstmate must record it; the merge poll remains armed\n' \
      "$URL" >&2
    exit 1
  fi
  if [ "$FM_PR_AWAY_POSTURE" = true ] && ! record_away_queue_enqueue; then
    printf 'actionable: %s was armed for the merge queue under away authority but could not be recorded in the away queue list, so the away archive cannot dequeue it; firstmate must record it\n' \
      "$URL" >&2
    exit 1
  fi
  if [ "$FM_PR_QUEUE_MERGED" = true ]; then
    rm -f "$STATE/$ID.queue-pending"
    fm_afk_contract_lock_release || true
    printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s); its checks were already green, so the merge-when-ready request merged it at once and the merge poll reports the landing\n' \
      "$URL" "${FM_PR_QUEUE_STATE:-<unreadable>}" "${FM_PR_QUEUE_MERGED:-<unreadable>}" "${FM_PR_QUEUE_QUEUED:-<unreadable>}" >&2
    exit 0
  fi
  if ! fm_queue_arm_write "$STATE" "$ID" "$FM_PR_MERGE_HEAD" "$(date +%s)" 0 "$arm_baseline"; then
    gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --disable-auto >/dev/null 2>&1 || true
    printf 'actionable: %s was armed for the merge queue but its queue-arm record could not be written, so the arm was undone and GitHub will not enqueue it; the merge poll remains armed and a merge turn can re-arm it\n' \
      "$URL" >&2
    exit 1
  fi
  rm -f "$STATE/$ID.queue-pending"
  fm_afk_contract_lock_release || true
  printf 'queue arm: %s is armed at head %s (merge-when-ready, method %s); GitHub enqueues it in the merge queue when the required checks are green, one failed-checks ejection at this head re-enqueues itself, and a new push disarms it\n' \
    "$URL" "$FM_PR_MERGE_HEAD" "$queue_method" >&2
  exit 0
}

# --queue-requeue, the watcher's sweep over a $STATE/$ID.queue-arm record.
# The control lock is already held (through a bounded wait). Everything here
# is silent on stdout unless a terminal observation ends the arm, which
# prints exactly one line for the watcher's wake reason. The steady states -
# merged (the merge poll owns the landing wake), queued, or armed and still
# waiting for green checks (no removed-from-queue event after the recorded
# baseline) - stay silent. A head that moved disarms GitHub's request and
# reports the change, because GitHub does not disarm a push from this write
# credential by itself and nothing verified the new head; a pull request no
# longer open, and an ejection whose reason is anything but failed_checks,
# retire and report; a failed_checks ejection at the unchanged head
# re-enqueues itself once, replaying the queue route's own FM-3 and authority
# discipline (including the away queue list), and a second such ejection
# retires and reports as an ordinary blocked wake for firstmate to decide.
# Every lock or authority read that cannot be taken is silent too: the sweep
# does nothing and the next sweep retries, because a re-enqueue on an
# unproven authority is the one mistake this mode must never make. A
# re-enqueue this script cannot prove (forge refused it, or the read-back
# cannot confirm it) disarms and reports instead.
github_queue_requeue_once() {
  local arm_path="$STATE/$ID.queue-arm"
  local ejected_removed_at
  if ! fm_queue_arm_read "$arm_path"; then
    rm -f "$arm_path"
    printf 'queue arm blocked: the queue-arm record for %s is unreadable; firstmate decides whether to arm it again\n' \
      "$URL"
    return 0
  fi
  if ! github_queue_read; then
    return 0
  fi
  if [ "$FM_PR_QUEUE_MERGED" = true ]; then
    fm_queue_arm_retire "$arm_path" "$FM_QUEUE_ARM_HEAD" "$FM_QUEUE_ARM_ARMED" \
      "$FM_QUEUE_ARM_REENQUEUES" "$FM_QUEUE_ARM_BASELINE"
    return 0
  fi
  if [ "$FM_PR_QUEUE_HEAD" != "$FM_QUEUE_ARM_HEAD" ]; then
    gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --disable-auto >/dev/null 2>&1 \
      || printf 'actionable: could not disable the armed merge-when-ready for %s after its head moved; disable it manually if it re-enters the queue\n' \
        "$URL" >&2
    fm_queue_arm_retire "$arm_path" "$FM_QUEUE_ARM_HEAD" "$FM_QUEUE_ARM_ARMED" \
      "$FM_QUEUE_ARM_REENQUEUES" "$FM_QUEUE_ARM_BASELINE"
    printf 'queue arm disarmed: %s moved from head %s to %s, so the armed merge-when-ready no longer matches; the changed head follows the ordinary merge path\n' \
      "$URL" "$FM_QUEUE_ARM_HEAD" "${FM_PR_QUEUE_HEAD:-<unreadable>}"
    return 0
  fi
  if ! github_state_is_open_value "$FM_PR_QUEUE_STATE"; then
    fm_queue_arm_retire "$arm_path" "$FM_QUEUE_ARM_HEAD" "$FM_QUEUE_ARM_ARMED" \
      "$FM_QUEUE_ARM_REENQUEUES" "$FM_QUEUE_ARM_BASELINE"
    printf 'queue arm disarmed: %s is %s, no longer open, so the merge queue will never take it\n' \
      "$URL" "${FM_PR_QUEUE_STATE:-<unreadable>}"
    return 0
  fi
  if [ "$FM_PR_QUEUE_QUEUED" = true ]; then
    return 0
  fi
  if [ "$FM_PR_QUEUE_REMOVED_AT" = "$FM_QUEUE_ARM_BASELINE" ]; then
    return 0
  fi
  if [ "$FM_PR_QUEUE_REMOVED_REASON" != failed_checks ]; then
    fm_queue_arm_retire "$arm_path" "$FM_QUEUE_ARM_HEAD" "$FM_QUEUE_ARM_ARMED" \
      "$FM_QUEUE_ARM_REENQUEUES" "$FM_QUEUE_ARM_BASELINE"
    printf 'queue arm disarmed: %s left the merge queue (GitHub reason: %s), which this arm does not retry; firstmate decides\n' \
      "$URL" "${FM_PR_QUEUE_REMOVED_REASON:-<no reason reported>}"
    return 0
  fi
  if [ "$FM_QUEUE_ARM_REENQUEUES" = 1 ]; then
    fm_queue_arm_retire "$arm_path" "$FM_QUEUE_ARM_HEAD" "$FM_QUEUE_ARM_ARMED" \
      "$FM_QUEUE_ARM_REENQUEUES" "$FM_QUEUE_ARM_BASELINE"
    printf 'queue arm blocked: %s left the merge queue a second time after failed checks at head %s; firstmate decides the next step\n' \
      "$URL" "$FM_QUEUE_ARM_HEAD"
    return 0
  fi
  ejected_removed_at=$FM_PR_QUEUE_REMOVED_AT
  # The one automatic re-enqueue, at the unchanged head the arm verified. A
  # lock or authority read that cannot be taken here stays silent and
  # retries next sweep: never enqueue on an unproven authority.
  if ! hold_away_record_for_merge; then
    return 0
  fi
  away_status=0
  require_current_away_authority || away_status=$?
  if [ "$away_status" -ne 0 ]; then
    fm_afk_contract_lock_release || true
    return 0
  fi
  if ! github_release_branch_before_enqueue; then
    fm_afk_contract_lock_release || true
    fm_queue_arm_retire "$arm_path" "$FM_QUEUE_ARM_HEAD" "$FM_QUEUE_ARM_ARMED" \
      "$FM_QUEUE_ARM_REENQUEUES" "$FM_QUEUE_ARM_BASELINE"
    printf 'queue arm blocked: %s could not be re-enqueued after failed checks because a no-mistakes run could still push to its branch; firstmate decides\n' \
      "$URL"
    return 0
  fi
  FM_PR_MERGE_HEAD=$FM_QUEUE_ARM_HEAD
  if ! github_enqueue_pull_request; then
    if ! github_queue_read || [ "$FM_PR_QUEUE_QUEUED" != true ]; then
      gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --disable-auto >/dev/null 2>&1 || true
      fm_afk_contract_lock_release || true
      fm_queue_arm_retire "$arm_path" "$FM_QUEUE_ARM_HEAD" "$FM_QUEUE_ARM_ARMED" \
        "$FM_QUEUE_ARM_REENQUEUES" "$FM_QUEUE_ARM_BASELINE"
      printf 'queue arm blocked: re-enqueueing %s after failed checks did not put it back in the merge queue; firstmate decides\n' \
        "$URL"
      return 0
    fi
  else
    if ! github_queue_read || [ "$FM_PR_QUEUE_QUEUED" != true ] \
      || [ "$FM_PR_QUEUE_HEAD" != "$FM_QUEUE_ARM_HEAD" ]; then
      gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --disable-auto >/dev/null 2>&1 || true
      fm_afk_contract_lock_release || true
      fm_queue_arm_retire "$arm_path" "$FM_QUEUE_ARM_HEAD" "$FM_QUEUE_ARM_ARMED" \
        "$FM_QUEUE_ARM_REENQUEUES" "$FM_QUEUE_ARM_BASELINE"
      printf 'queue arm blocked: re-enqueueing %s after failed checks did not put it back in the merge queue; firstmate decides\n' \
        "$URL"
      return 0
    fi
  fi
  if ! persist_accepted_merge_authority; then
    fm_afk_contract_lock_release || true
    fm_queue_arm_retire "$arm_path" "$FM_QUEUE_ARM_HEAD" "$FM_QUEUE_ARM_ARMED" \
      "$FM_QUEUE_ARM_REENQUEUES" "$FM_QUEUE_ARM_BASELINE"
    printf 'queue arm blocked: %s was re-enqueued after failed checks but its merge authority could not be persisted; firstmate must record it\n' \
      "$URL"
    return 0
  fi
  if [ "$FM_PR_AWAY_POSTURE" = true ] && ! record_away_queue_enqueue; then
    fm_afk_contract_lock_release || true
    fm_queue_arm_retire "$arm_path" "$FM_QUEUE_ARM_HEAD" "$FM_QUEUE_ARM_ARMED" \
      "$FM_QUEUE_ARM_REENQUEUES" "$FM_QUEUE_ARM_BASELINE"
    printf 'queue arm blocked: %s was re-enqueued after failed checks under away authority but could not be recorded in the away queue list; firstmate must record it\n' \
      "$URL"
    return 0
  fi
  if ! fm_queue_arm_write "$STATE" "$ID" "$FM_QUEUE_ARM_HEAD" \
    "$FM_QUEUE_ARM_ARMED" 1 "${ejected_removed_at:--}"; then
    gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --disable-auto >/dev/null 2>&1 || true
    fm_afk_contract_lock_release || true
    fm_queue_arm_retire "$arm_path" "$FM_QUEUE_ARM_HEAD" "$FM_QUEUE_ARM_ARMED" \
      "$FM_QUEUE_ARM_REENQUEUES" "$FM_QUEUE_ARM_BASELINE"
    printf 'queue arm blocked: %s was re-enqueued after failed checks but its queue-arm record could not be rewritten; firstmate must re-arm it\n' \
      "$URL"
    return 0
  fi
  fm_afk_contract_lock_release || true
  return 0
}

gitlab_confirm_merged() {
  local json state
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" \
    -R "$PROJECT_URL" -F json 2>/dev/null) || [ -z "$json" ]; then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  if ! state=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.state | type == "string") then .state else error("invalid state") end' \
    2>/dev/null); then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  [ "$state" = merged ]
}

# Unlike gh and glab, "tea api" reports an HTTP-level failure (a rejected or
# malformed merge request included) with exit status 0 and the error only in
# the response body, verified empirically against a real Forgejo instance. So
# this confirmation is not a bonus corroboration of an already-trusted exit
# code the way gitlab_confirm_merged's is: it is the only reliable signal that
# a Forgejo merge landed at all.
forgejo_confirm_merged() {
  local json merged
  if ! json=$(tea api --login "$FORGEJO_LOGIN" --repo "$PR_OWNER/$PR_REPO" \
    "/repos/{owner}/{repo}/pulls/$PR_NUMBER" 2>/dev/null) || [ -z "$json" ]; then
    return 2
  fi
  if ! merged=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.merged | type == "boolean") then .merged else error("invalid merged field") end' \
    2>/dev/null); then
    return 2
  fi
  [ "$merged" = true ]
}

# Record before either forge call. This arms the merge poll without claiming a
# landed outcome, so even a provider read failure after a real merge cannot
# leave teardown without the PR identity it needs to verify the result.
away_status=0
require_current_away_authority || away_status=$?
[ "$away_status" -eq 0 ] || exit "$away_status"
require_recorded_pr_identity || exit 1
# The requeue sweep dispatches before the recording gates: its stdout is the
# watcher's wake line and must stay empty while the arm is healthy, and
# record_pr_metadata re-records through fm-pr-check, whose own stdout belongs
# to the registration it reports to. A captain hold on the task backs the
# sweep off silently: a captain is already deciding.
if [ "$MODE" = requeue ]; then
  require_released_captain_hold || exit 1
  github_queue_requeue_once
  exit $?
fi
# --queue-at-green is a yolo posture only: with yolo off, a captain approves
# each merge, so nothing is armed and the merge-turn path is unchanged. A
# missing or unreadable yolo= is off. (The arm mode reads no --allow-red or
# --allow-missing: an arm runs unattended.)
if [ "$MODE" = at-green ] \
  && [ "$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)" != on ]; then
  printf 'queue arm: %s was not armed: the task is not in the yolo posture, so a captain approves each merge\n' \
    "$URL" >&2
  exit 0
fi
record_pr_metadata || exit 1
require_released_captain_hold || exit 1

# Accepted confused-agent-grade limitation, as in bin/fm-lease-lib.sh, not an
# oversight: if this lock-owning shell dies while its gh or glab child lives,
# stale-owner recovery can release the record for archive or replacement and
# the orphaned forge child can still merge on the lapsed away authority.
case "$PROVIDER" in
  github)
    if [ "$MODE" = at-green ]; then
      github_arm_queue_at_green
      # shellcheck disable=SC2317 # the arm exits on every path; this guard
      # keeps a returning arm from falling into the merge-turn path.
      exit $?
    fi
    merge_output=
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    FM_PR_GITHUB_CALLER_METHOD=$(caller_merge_method "$@")
    # mergeable reads UNKNOWN for a short while after a push or base-branch
    # change while GitHub recomputes it; retry a bounded number of times,
    # re-reading and re-checking every live condition on each attempt, rather
    # than refusing a pull request that is simply still being computed. The
    # delay is capped at 0-10 seconds so the wait stays short under the lock.
    mergeable_retry_delay=${FM_PR_GITHUB_MERGEABLE_RETRY_DELAY:-3}
    case "$mergeable_retry_delay" in
      [0-9] | 10) ;;
      *) mergeable_retry_delay=3 ;;
    esac
    mergeable_attempt=1
    while :; do
      mergeable_status=0
      github_verify_mergeable || mergeable_status=$?
      if [ "$mergeable_status" -eq 0 ]; then
        break
      fi
      if [ "$mergeable_status" -ne 3 ] || [ "$mergeable_attempt" -ge 5 ]; then
        break
      fi
      sleep "$mergeable_retry_delay"
      mergeable_attempt=$((mergeable_attempt + 1))
    done
    if [ "$mergeable_status" -ne 0 ]; then
      if [ "$mergeable_status" -eq 3 ]; then
        printf 'error: mergeability for %s is still being computed by GitHub; retry shortly\n' "$URL" >&2
      fi
      exit 1
    fi
    # The away record is locked first, so this last presence and authority read
    # and the forge command below share one live-owner critical section.
    hold_away_record_for_merge || exit 1
    away_status=0
    require_current_away_authority || away_status=$?
    [ "$away_status" -eq 0 ] || exit "$away_status"
    github_resolve_merge_route "$@" || exit 2
    if [ "$FM_PR_GITHUB_MERGE_ROUTE" = queue ]; then
      github_merge_through_queue
    else
      # The away --auto enqueue rides the direct route, but nothing may hand a
      # queued pull request a forge command before its queue entry is read at
      # the verified head and any branch-pushing pipeline is ended (FM-3).
      if [ "$FM_PR_GITHUB_AWAY_QUEUE_ENQUEUE" = true ]; then
        github_require_queue_entry_ready
        github_release_branch_before_enqueue || exit 1
      fi
      merge_status=0
      merge_output=$(gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
        --match-head-commit "$FM_PR_MERGE_HEAD" \
        "${merge_args[@]+"${merge_args[@]}"}" "$@" 2>&1) || merge_status=$?
      if [ "$merge_status" -eq 0 ]; then
        FM_PR_GITHUB_MERGE_ACCEPTED=true
        persist_accepted_merge_authority || exit 1
        [ "$FM_PR_GITHUB_AWAY_QUEUE_ENQUEUE" != true ] || record_away_queue_enqueue || exit 1
        fm_afk_contract_lock_release || true
        fm_lock_release "$MERGE_CONTROL_LOCK" || true
        MERGE_CONTROL_LOCK=
      else
        fm_afk_contract_lock_release || true
        fm_lock_release "$MERGE_CONTROL_LOCK" || true
        MERGE_CONTROL_LOCK=
        [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
        if github_read_outcome; then
          if [ "$FM_PR_GITHUB_MERGED" != true ] && [ "$FM_PR_GITHUB_QUEUED" != true ]; then
            github_report_unmerged_outcome
          else
            printf 'actionable: the merge command for %s failed, but the pull request reads back as state=%s, merged=%s, isInMergeQueue=%s\n' \
              "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
            # A failed command can still have enqueued (gh may fail after the
            # forge accepted it); a queue entry read back under away authority is
            # recorded for the archive like any other.
            if [ "$FM_PR_GITHUB_AWAY_QUEUE_ENQUEUE" = true ] && [ "$FM_PR_GITHUB_QUEUED" = true ]; then
              record_away_queue_enqueue || exit 1
            fi
          fi
        fi
        exit "$merge_status"
      fi
      if ! github_read_outcome; then
        github_report_forge_output "$merge_output"
        exit 1
      fi
      if [ "$FM_PR_GITHUB_MERGED" = true ]; then
        printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s)\n' \
          "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
      elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
        printf 'verified: %s is queued (state=%s, merged=%s, isInMergeQueue=%s)\n' \
          "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
        exit 0
      else
        github_report_forge_output "$merge_output"
        github_report_unmerged_outcome
        exit 1
      fi
    fi
    ;;
  gitlab)
    gitlab_verify_mergeable || exit 1
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    # The away record is locked first, so this last presence and authority read
    # and the forge command below share one live-owner critical section.
    hold_away_record_for_merge || exit 1
    away_status=0
    require_current_away_authority || away_status=$?
    [ "$away_status" -eq 0 ] || exit "$away_status"
    merge_status=0
    gitlab_merge_args=()
    if [ "$FM_PR_AWAY_POSTURE" = true ]; then
      gitlab_merge_args=(--auto-merge=false)
    fi
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --yes "$@" "${gitlab_merge_args[@]+"${gitlab_merge_args[@]}"}" || merge_status=$?
    if [ "$merge_status" -ne 0 ]; then
      fm_afk_contract_lock_release || true
      fm_lock_release "$MERGE_CONTROL_LOCK" || true
      MERGE_CONTROL_LOCK=
      exit "$merge_status"
    fi
    persist_accepted_merge_authority || exit 1
    fm_afk_contract_lock_release || true
    fm_lock_release "$MERGE_CONTROL_LOCK" || true
    MERGE_CONTROL_LOCK=
    gitlab_confirm_rc=0
    gitlab_confirm_merged || gitlab_confirm_rc=$?
    [ "$gitlab_confirm_rc" -eq 0 ] || exit 0
    ;;
  forgejo)
    forgejo_reject_unsupported_args "$@" || exit 1
    forgejo_method=$(caller_merge_method "$@")
    [ -n "$forgejo_method" ] || forgejo_method=$(forgejo_default_merge_style) || exit 1
    forgejo_verify_mergeable || exit 1
    # The away record is locked first, so this last presence and authority
    # read and the forge command below share one live-owner critical section.
    hold_away_record_for_merge || exit 1
    away_status=0
    require_current_away_authority || away_status=$?
    [ "$away_status" -eq 0 ] || exit "$away_status"
    # head_commit_id binds the merge to the head this run verified: Forgejo's
    # REST API rejects a mismatched value with "head out of date" (verified
    # against a real instance), matching --match-head-commit/--sha above. tea
    # exposes no such flag on its own merge subcommand, so the API is called
    # directly through "tea api" instead.
    merge_output=$(tea api --login "$FORGEJO_LOGIN" --repo "$PR_OWNER/$PR_REPO" \
      -X POST "/repos/{owner}/{repo}/pulls/$PR_NUMBER/merge" \
      -f "Do=$forgejo_method" -f "head_commit_id=$FM_PR_MERGE_HEAD" 2>&1) || true
    # "tea api" reports an HTTP-level failure with exit status 0 (also
    # verified against a real instance), so that output is kept only for the
    # failure report below; the merge is judged solely by reading the pull
    # request back through forgejo_confirm_merged. Only an unreadable read-back
    # (status 2) is retried, a bounded number of times, so a transient read
    # failure after a landed merge is not reported as unmerged; a definite
    # merged=false stops at once.
    forgejo_confirm_attempt=1
    while :; do
      forgejo_confirm_rc=0
      forgejo_confirm_merged || forgejo_confirm_rc=$?
      [ "$forgejo_confirm_rc" -eq 2 ] && [ "$forgejo_confirm_attempt" -lt 5 ] || break
      sleep 1
      forgejo_confirm_attempt=$((forgejo_confirm_attempt + 1))
    done
    if [ "$forgejo_confirm_rc" -ne 0 ]; then
      fm_afk_contract_lock_release || true
      fm_lock_release "$MERGE_CONTROL_LOCK" || true
      MERGE_CONTROL_LOCK=
      [ -z "$merge_output" ] || printf 'error: > %s\n' "$merge_output" >&2
      echo "error: Forgejo did not confirm $URL as merged" >&2
      exit 1
    fi
    persist_accepted_merge_authority || exit 1
    fm_afk_contract_lock_release || true
    fm_lock_release "$MERGE_CONTROL_LOCK" || true
    MERGE_CONTROL_LOCK=
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac

# Reached only after the forge confirmed the merge landed: set -e exits on a
# refused or failed merge above, and a queued forge merge exits without an
# outcome while its existing poll remains armed.
outcome_rc=0
fm_merge_outcome_report "$FM_HOME" "$STATE" "$ID" "$URL" self \
  "${FM_PR_MERGE_AUTHORITY:-}" || outcome_rc=$?
case "$outcome_rc" in
  0) ;;
  3)
    printf 'actionable: merged %s but could not report it upward: this home has no readable secondmate identity or parent binding (.fm-secondmate-home, .fm-secondmate-parent)\n' \
      "$URL" >&2
    ;;
  *)
    printf 'actionable: merged %s but could not record the outcome for supervision\n' "$URL" >&2
    ;;
esac
