#!/usr/bin/env bash
# Merge-attribution: the single source of truth for deciding whether an observed
# PR merge was performed by firstmate itself (attributed) or by some other actor
# (unattributed), so an out-of-band merge - a captain merging directly on GitHub,
# a future auto-merge bug, or a rogue action - is surfaced and reconciled instead
# of silently flowing into teardown.
#
# One general mechanism, not a special case: it fires on ANY merge firstmate did
# not itself perform, whatever the source. The ground truth for "firstmate merged
# this" is the merged_by_firstmate=<pr-url> marker that bin/fm-pr-merge.sh writes
# to state/<id>.meta BEFORE it calls gh-axi pr merge, so firstmate's own merges
# can never race into a false unattributed reading.
#
# Attribution is keyed by PR NUMBER, via the unique PR URL recorded in meta, never
# by branch name: sibling PRs can share one head branch (the incident had two PRs
# on fm/tracehealth-hg), so a branch-keyed marker would misattribute a sibling's
# merge. Each task's meta is 1:1 with its PR, and the marker line carries that
# PR's exact URL, so a grep -qxF match disambiguates siblings by number.
#
# Robustness contract: an empty or unparseable PR-state read is treated as
# "unknown", never as "not merged". A silently-empty gh read misled firstmate
# twice during the incident; the unknown verdict makes callers warn loudly rather
# than conclude the PR is still open.
#
# Sourced by the generated per-task state/<id>.check.sh (armed by fm-pr-check.sh)
# and by bin/fm-watch.sh's heartbeat fleet-scan backstop. Side-effect-free at
# source time: it only defines functions.

# Bound each gh read so a stalled network cannot hang the watcher loop that runs
# the heartbeat backstop, mirroring fm-watch.sh's per-check CHECK_TIMEOUT guard.
# The per-task check.sh is already run under that timeout, so this is a harmless
# second bound there. macOS ships the coreutils timeout as gtimeout; fall through
# to a bare call (gh has its own network timeouts) when neither exists.
_fm_merge_gh() {
  local t=${FM_MERGE_GH_TIMEOUT:-20}
  if command -v timeout >/dev/null 2>&1; then
    timeout "$t" gh "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$t" gh "$@"
  else
    gh "$@"
  fi
}

# fm_merge_probe_state <url>: echo the PR state ("OPEN"/"MERGED"/"CLOSED"), or
# empty on an unreadable read. Isolated so the empty/unparseable case is handled
# in exactly one place and tests can stub gh.
fm_merge_probe_state() {
  _fm_merge_gh pr view "$1" --json state -q .state 2>/dev/null
}

# fm_merge_probe_mergedby <url>: echo the login that merged the PR, or empty.
# Only queried on the rare unattributed path, to name the actor in the alarm.
fm_merge_probe_mergedby() {
  _fm_merge_gh pr view "$1" --json mergedBy -q '.mergedBy.login // empty' 2>/dev/null
}

# fm_merge_attribution <url> <meta>: classify an observed merge. Echoes one token:
#   open         PR is not merged (OPEN, or CLOSED-unmerged) - benign, silent
#   attributed   PR MERGED and meta carries the firstmate-merge marker - benign
#   unattributed PR MERGED with NO firstmate-merge marker - the alarm
#   unknown      PR state could not be read (empty/unparseable) - warn, never
#                assume unmerged
fm_merge_attribution() {
  local url=$1 meta=$2 state
  state=$(fm_merge_probe_state "$url")
  if [ -z "$state" ]; then
    echo unknown
    return 0
  fi
  if [ "$state" != MERGED ]; then
    echo open
    return 0
  fi
  if grep -qxF "merged_by_firstmate=$url" "$meta" 2>/dev/null; then
    echo attributed
  else
    echo unattributed
  fi
}

# fm_merge_scan_unattributed <state>: the fleet backstop. Print one
# "<task>\t<url>" line for every in-flight ship task whose recorded pr= URL is
# observed MERGED without a firstmate-merge marker, independent of the per-task
# check cadence, reusing the same fm_merge_attribution decision. Scout and
# secondmate tasks never ship a PR, so they are skipped. Only the definitive
# unattributed verdict is reported here; the per-task check.sh owns the loud
# unknown warning, so a transient gh blip does not spam the heartbeat.
fm_merge_scan_unattributed() {
  local state=$1 meta task kind url
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    case "$kind" in scout|secondmate) continue ;; esac
    url=$(grep '^pr=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$url" ] || continue
    [ "$(fm_merge_attribution "$url" "$meta")" = unattributed ] || continue
    task=$(basename "$meta"); task=${task%.meta}
    printf '%s\t%s\n' "$task" "$url"
  done
}
