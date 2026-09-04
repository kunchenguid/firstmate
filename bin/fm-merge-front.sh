#!/usr/bin/env bash
# Own the per-project structural merge-front queue and the only initial
# Greptile retrigger gate.
#
# Commands:
#   fm-merge-front.sh enqueue <project-key> <task-id> <pr-url>
#   fm-merge-front.sh status <project-key>
#   fm-merge-front.sh promote <project-key>
#   fm-merge-front.sh remove <project-key> <task-id> <pr-url>
#   fm-merge-front.sh greptile-kick <project-key>
#
# Each project has exactly one ordered queue. Its first entry is the front and
# every later entry is parked. enqueue is idempotent for one exact task/URL pair
# and rebinds a task in place, keeping its queue position, when that same task
# opens a replacement PR; it refuses only a URL already bound to another task.
# promote reuses the canonical merge poll to fail closed until the front is
# confirmed merged, then removes exactly that entry and exposes the next one. It
# snapshots the front under the lock, releases it for the bounded merge poll, and
# reacquires it to confirm the same identity is still the front before removing
# it, so a front that changed meanwhile is refused rather than mis-promoted.
#
# remove is the operator recovery path for a queued PR that will never merge -
# a closed or superseded PR, or a torn-down task. Every retirement is keyed on
# the exact task and canonical URL together, never either alone, so at most the
# one named row is retired and a stale identity retires nothing rather than
# dropping another task's live entry. It advances nothing by itself, so retiring
# a stuck front simply exposes the next entry and unblocks the project. Teardown and a
# confirmed merge whose task metadata is already gone reach the same retirement
# automatically (bin/fm-teardown.sh, bin/fm-merge-outcome-lib.sh), scanning every
# project queue when the task's own project key can no longer be derived, so a
# torn-down front cannot silently park the PRs behind it.
#
# The shared already-confirmed merge-outcome path uses the same identity-bound
# retirement. A confirmed merge is a fact the queue may never veto: an
# out-of-order merged entry is removed where it sits with the current front left
# untouched, and an unqueued identity is nothing to do. That path reports queue
# reconciliation as advisory, so no queue state can suppress or replay a merge
# already published to supervision.
#
# Durable private state lives at state/merge-front/<project-key>.queue under a
# mode-0700 directory. Each single-link mode-0600 file has this schema:
#   fm-merge-front-v1
#   project=<project-key>
#   task=<task-id><TAB>url=<canonical-pr-url>
#   ...
# The task rows are queue order. Writers hold the per-project lock, validate the
# complete old state, publish a complete same-device temporary by atomic rename,
# and validate the result. Project keys and task IDs are confined path-safe
# slugs; PR/MR URLs use bin/fm-pr-lib.sh's canonical parser. PR registration
# derives the project key from the task metadata's project= path with a pure,
# deterministic mapping: the checkout basename with every character outside
# [A-Za-z0-9._-] replaced by "-", trimmed to 40 characters and to a leading
# alphanumeric (or "project" when nothing survives), then "-" and a 12-hex-digit
# SHA-256 prefix of the whole path. So an ordinary checkout named "my repo" or
# "app (v2)" registers instead of refusing, and two checkouts sharing a basename
# keep isolated queues. Registration also refuses a PR URL already bound to a
# different task before it rewrites any task metadata or arms any poll, so that
# unretryable conflict never lands on half-applied registration state.
#
# Every wait for the per-project lock is bounded (FM_MERGE_FRONT_LOCK_TIMEOUT,
# default 30s), and every live GitHub read or comment is bounded
# (FM_MERGE_FRONT_GH_TIMEOUT, default 60s), so a stuck holder or a hung forge
# call yields a refusal instead of wedging the watcher. No command holds the
# lock across a GitHub call, so the longest hold is one state read plus one
# atomic rewrite and a slow forge can never starve enqueue or merge retirement.
#
# status reports one front= row plus zero or more parked= rows. It never grants
# authority by itself: only the front may be updated from main or retriggered.
# greptile-kick snapshots the front under the lock, releases it for its live
# GitHub reads, and reacquires it to re-read the structural gate immediately
# before its single side effect, so a front that promoted, rebound, or retired
# meanwhile is refused rather than kicked.
# It refuses unless the queued PR is the first entry (therefore has no preceding
# entry), is open against main, has behind_by=0 compared with main, has every
# non-Greptile required check satisfied, and has no pending Greptile check. A
# required check counts as satisfied at SUCCESS, SKIPPED, or NEUTRAL - the states
# GitHub's own merge gate accepts - and blocks at every other state. Any
# unreadable or unrecognised state fails closed. Its sole action is one explicit
# `gh pr comment <number> --repo <owner/repo> --body "@greptile review"`.
# Greploop's separate follow-up trigger remains unchanged: a finished Greptile
# review below 5/5 may ask this owner to attempt another gated kick.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-merge-front-lib.sh
. "$SCRIPT_DIR/fm-merge-front-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  enqueue)
    [ "$#" -eq 4 ] || { echo 'error: invalid merge-front enqueue request' >&2; exit 2; }
    fm_merge_front_enqueue "$STATE" "$2" "$3" "$4" || exit $?
    ;;
  status)
    [ "$#" -eq 2 ] || { echo 'error: invalid merge-front status request' >&2; exit 2; }
    fm_merge_front_status "$STATE" "$2" || exit $?
    ;;
  promote)
    [ "$#" -eq 2 ] || { echo 'error: invalid merge-front promote request' >&2; exit 2; }
    fm_merge_front_promote "$STATE" "$2" || exit $?
    ;;
  remove)
    [ "$#" -eq 4 ] || { echo 'error: invalid merge-front remove request' >&2; exit 2; }
    fm_merge_front_remove "$STATE" "$2" "$3" "$4" || exit $?
    ;;
  greptile-kick)
    [ "$#" -eq 2 ] || { echo 'error: invalid merge-front Greptile request' >&2; exit 2; }
    fm_merge_front_greptile_kick "$STATE" "$2" || exit $?
    ;;
  *)
    echo 'error: expected enqueue, status, promote, remove, or greptile-kick' >&2
    exit 2
    ;;
esac
