#!/usr/bin/env bash
# Automatic pull-request review and feedback lifecycle owner.
#
# Usage:
#   fm-pr-review.sh arm
#   fm-pr-review.sh source
#   fm-pr-review.sh poll [--force]
#   fm-pr-review.sh list [--json]
#   fm-pr-review.sh next
#   fm-pr-review.sh show <item-id>
#   fm-pr-review.sh claim <item-id> --owner-task <task-id>
#   fm-pr-review.sh fetch-feedback <item-id>
#   fm-pr-review.sh complete-review <item-id> --head <sha> --generation <n> --outcome <clean|findings|findings-corrected> --evidence-file <path> [--reply-file <path>]
#   fm-pr-review.sh resolve-feedback <item-id> --head <sha> --generation <n> --verdict <fixed|dismissed|duplicate|superseded|captain-decision-pending> --evidence-file <path> [--validation-evidence <path>] [--reply-file <path>]
#   fm-pr-review.sh deliver <item-id>
#   fm-pr-review.sh reopen <item-id>
#   fm-pr-review.sh acknowledge-event <event-id>
#   fm-pr-review.sh opt-out <canonical-pr-url>
#   fm-pr-review.sh opt-in <canonical-pr-url>
#   fm-pr-review.sh source-id
#
# `arm` installs one ongoing source in this home's existing process-event runner.
# Locked session-start bootstrap calls it automatically for the main Firstmate
# home, so no cron job, LaunchAgent, daemon, custom watcher check, token, or
# separate credential is needed. The source uses gh-axi and its authenticated
# GitHub identity, sleeps until its durable slow-poll deadline, and remains
# silent when the relevant PR set, exact heads, feedback identities, and queue
# actionability are unchanged. An unchanged poll makes no model call and starts
# no worker. A pull request whose live detail read answers closed is omitted; a
# read, pagination, or schema failure for one open pull request keeps that pull
# request's last covered head and feedback cursor, records the failure in the
# snapshot, announces one deduplicated diagnostic, and lets the rest of the
# inventory reconcile. Authentication, rate, and total-deadline failures still
# fail the whole poll without publishing a partial inventory.
#
# `opt-out` is the explicit durable captain-takeover control for one canonical
# pull request. It parks nonterminal work while preserving the last covered head
# and feedback cursor. `opt-in` removes that one record, reopens parked work, and
# makes the next poll due immediately, so every intervening exact head and
# feedback identity is compared against the last covered cursor rather than
# silently becoming the new baseline.
#
# Queue and response mechanics are private under state/pr-review/. The Node state
# owner binds every item to repository, PR number, exact head, feedback node,
# parent thread, generation, verdict, response state, owning task, and retry
# count. Claims serialize the standing one-at-a-time review lane. A truncated
# feedback prefix is completed by `fetch-feedback` through bounded authenticated
# chunks and stored privately before adjudication. Completion and response
# delivery re-read the exact GitHub head. A moved head requeues the same
# item at a new generation. A live read that finds the pull request closed or
# merged ends the item with the terminal outcome pull-closed-without-response and
# exit 7 at every completion boundary, discards any pending public response,
# releases the lane, and never posts after closure; a response GitHub already
# accepted is still reconciled instead. Observing that pull request open again
# resumes exactly those closed items at a new generation, whether or not the
# covered head moved and whether or not the item's head was requeued away from
# the head it was created at, and leaves every other terminal outcome and the
# live review owner alone. A failed reply keeps one already-bound response
# for retry instead of rerunning a correction. Delivery first searches the
# original thread for the response's self-authored exact-body binding marker, so
# a crash after GitHub accepted the response is reconciled without knowingly
# posting it twice. Immediately before any formal COMMENT review or legacy
# fallback-comment write, delivery re-reads the live PR author and authenticated
# actor. Equality returns exit 6, discards the outward response, and preserves a
# private implementation-owner route; no fallback-comment write is supported.
#
# Fixed feedback requires a private validation JSON file with schema
# fm-pr-review-validation.v1, owner_task matching the claim, the exact head,
# result checks-green or selected-lifecycle-passed, and a focused proof string.
# The only terminal feedback outcomes are fixed-and-replied,
# dismissed-and-replied, duplicate-and-replied, superseded-and-replied,
# captain-decision-pending, and pull-closed-without-response. A captain decision
# stages no outward response.
# An authored initial review records clean privately or stages supported findings
# with `complete-review --outcome findings` for its owning implementation task;
# after correction, `findings-corrected` completes that same private review. It
# never counts as independent evidence and never stages a reply. A foreign PR can
# post only a COMMENT review after the live identity guard. No command in this
# interface approves or merges a pull request.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PRIVATE_ROOT="$STATE/pr-review"
LOCK="$PRIVATE_ROOT/.command.lock"
ENGINE="$SCRIPT_DIR/fm-pr-review-state.mjs"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { awk 'NR == 1 { next } /^set -u$/ { exit } { sub(/^# ?/, ""); print }' "$0"; exit 2; }

prepare_private_root() {
  if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "Firstmate state directory is unsafe"
  else
    (umask 077; mkdir -p "$STATE") || die "cannot create Firstmate state directory"
  fi
  chmod 0700 "$STATE" || die "cannot secure Firstmate state directory"
  if [ -e "$PRIVATE_ROOT" ] || [ -L "$PRIVATE_ROOT" ]; then
    [ -d "$PRIVATE_ROOT" ] && [ ! -L "$PRIVATE_ROOT" ] || die "private pull-request review state is unsafe"
  else
    (umask 077; mkdir -p "$PRIVATE_ROOT") || die "cannot create private pull-request review state"
  fi
  chmod 0700 "$PRIVATE_ROOT" || die "cannot secure private pull-request review state"
}

with_lock() {
  prepare_private_root
  fm_lock_acquire_wait "$LOCK" || die "cannot lock pull-request review state"
  "$@"
  local rc=$?
  fm_lock_release "$LOCK"
  return "$rc"
}

source_id() {
  local digest real
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$FM_HOME" 2>/dev/null) \
    || die "cannot resolve the physical Firstmate home"
  [ -d "$real" ] || die "physical Firstmate home is unavailable"
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$real" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$real" | sha256sum | awk '{print $1}')
  else
    die "no SHA-256 tool is available"
  fi
  printf 'pr-review-%s\n' "${digest:0:20}"
}

cmd_arm() {
  local sid
  command -v node >/dev/null 2>&1 || die "automatic pull-request review requires node"
  command -v gh-axi >/dev/null 2>&1 || die "automatic pull-request review requires gh-axi"
  with_lock node "$ENGINE" init || return 1
  sid=$(source_id)
  "$SCRIPT_DIR/fm-procevent.sh" register pr-review "$sid" -- \
    "$SCRIPT_DIR/fm-procevent-pr-review.sh" source || return 1
  printf 'armed: %s\n' "$sid"
}

cmd_source() {
  local wait rc
  wait=$(with_lock node "$ENGINE" seconds-until-due) || return 1
  case "$wait" in ''|*[!0-9]*) die "stored pull-request review deadline is invalid" ;; esac
  if [ "$wait" -gt 0 ] && [ "${FM_PR_REVIEW_NO_SLEEP:-0}" != 1 ]; then
    sleep "$wait"
  fi
  with_lock node "$ENGINE" poll
  rc=$?
  return "$rc"
}

case "${1-}" in
  arm)
    [ "$#" -eq 1 ] || usage
    cmd_arm
    ;;
  source)
    [ "$#" -eq 1 ] || usage
    cmd_source
    ;;
  source-id)
    [ "$#" -eq 1 ] || usage
    source_id
    ;;
  poll)
    shift
    [ "$#" -le 1 ] || usage
    [ "$#" -eq 0 ] || [ "$1" = --force ] || usage
    with_lock node "$ENGINE" poll "$@"
    ;;
  list)
    shift
    [ "$#" -le 1 ] || usage
    [ "$#" -eq 0 ] || [ "$1" = --json ] || usage
    with_lock node "$ENGINE" list "$@"
    ;;
  next)
    [ "$#" -eq 1 ] || usage
    with_lock node "$ENGINE" next
    ;;
  show)
    [ "$#" -eq 2 ] || usage
    fm_pr_task_id_valid "$2" || die "invalid item id" 2
    with_lock node "$ENGINE" show "$2"
    ;;
  claim|fetch-feedback|complete-review|resolve-feedback|deliver|reopen|acknowledge-event)
    command=$1
    shift
    [ "$#" -ge 1 ] || usage
    with_lock node "$ENGINE" "$command" "$@"
    ;;
  opt-out|opt-in)
    command=$1
    [ "$#" -eq 2 ] || usage
    fm_pr_url_parse "$2" && [ "$FM_PR_PROVIDER" = github ] || die "invalid canonical GitHub pull-request URL" 2
    with_lock node "$ENGINE" "$command" "$2"
    ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" 2 ;;
esac
