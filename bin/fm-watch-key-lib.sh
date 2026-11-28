#!/usr/bin/env bash
# Shared watcher marker identity and the per-endpoint marker family list.
# Source this library, then call window_key with one backend endpoint to obtain
# its filename suffix.
#
# Every per-window watcher marker consumes this ONE derivation. SHA-256 of the
# endpoint bytes with a `v3.` prefix bounds the suffix to 67 ASCII bytes, leaving
# room for marker prefixes within a 255-byte filename. The dot cannot occur in a
# legacy key; legacy and v2 evidence is ignored, never migrated or revived.
# Identity depends only on endpoint bytes, never on other recorded windows.
# docs/configuration.md's watcher-marker upgrade note owns the intentional
# one-time cache reset and its notification-only effects.
#
# This library is also the ONE owner of the per-endpoint marker family list:
# watcher_endpoint_marker_families names every family whose suffix is a
# window_key, watcher_endpoint_markers resolves that list to concrete paths for
# one endpoint, and watcher_endpoint_markers_clear removes them. A caller that
# retires an endpoint goes through those functions instead of enumerating
# families by hand, so a family added here is retired everywhere at once. Every
# path they build is derived from window_key, so they can only ever name a v3
# marker: a legacy or v2 suffix is never matched, migrated, or revived.
#
# Two owners call them. bin/fm-teardown.sh retires a freed endpoint's family when
# it removes that endpoint's task record, and bin/fm-watch.sh retires it and queues
# nothing for it when a cleanup removed the record while a poll was already
# classifying that endpoint - a wake for work that is cleaned up and gone costs a
# supervisor turn and answers nothing.
# Neither reaches an orphan that predates them: the watcher's pane sweep
# enumerates endpoints FROM the task records (recorded_windows in
# bin/fm-watch.sh), so an endpoint no record names is never visited again. For
# those, stop both the watcher and away daemon, then archive the obsolete files
# outside STATE (or remove the reviewed files); watcher_endpoint_markers prints
# exactly the current set to compare against, and only a family file whose suffix
# is NOT the v3 key it prints is obsolete. Do not bulk-clear STATE: task records,
# wake queues, and task-keyed markers (.paused-overdue-, the .subsuper-* set) are
# outside this cleanup. Leaving obsolete files in place is safe.
#
# This RETIREMENT set is deliberately wider than a PAUSE-RELEASE set, and the two
# must not be conflated: releasing a declared wait has to keep a still-recorded
# endpoint's .hash-/.count- detection state, or an idle pane would have to
# re-accumulate two identical hashes before it could be classified again, while a
# freed endpoint has no detection left to keep and takes the whole family with it.
# clear_pause_tracking in bin/fm-watch.sh and in bin/fm-supervise-daemon.sh own
# those narrower lists.
window_key() {  # <window>
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$1" | shasum -a 256)
  else
    digest=$(printf '%s' "$1" | sha256sum)
  fi
  printf 'v3.%s' "${digest%% *}"
}

# Every per-endpoint marker family, one prefix per line, without the leading dot
# and without the trailing dash that separates it from the window_key suffix.
# Membership is exactly "this marker's filename suffix is a window_key", so
# task-keyed markers are NOT here however similar their names look.
watcher_endpoint_marker_families() {
  printf '%s\n' \
    hash \
    count \
    stale \
    stale-since \
    churn-since \
    dead-reported \
    wedge-escalations \
    wedge-permanent \
    wedge-terminal-queued \
    wedge-rollback-failed \
    paused \
    paused-rechecked \
    paused-resurfaced \
    waiting-resurfaced \
    writing-since \
    writing-resurfaced \
    validating-since \
    validating-resurfaced \
    guard-deferrals \
    model-stream-episode
}

# watcher_endpoint_markers <state-dir> <endpoint>: print the path of every marker
# in each family above for <endpoint>, whether or not it currently exists, so a
# caller can review or remove the whole set without naming a family.
watcher_endpoint_markers() {  # <state-dir> <endpoint>
  local state=$1 endpoint=$2 family suffix
  [ -n "$state" ] && [ -n "$endpoint" ] || return 1
  suffix=$(window_key "$endpoint")
  while IFS= read -r family; do
    [ -n "$family" ] || continue
    printf '%s/.%s-%s\n' "$state" "$family" "$suffix"
  done < <(watcher_endpoint_marker_families)
}

# watcher_endpoint_markers_clear <state-dir> <endpoint>: remove that whole set.
# Best effort by contract - it attempts every path before reporting, so one
# unwritable marker cannot leave the rest behind - and an orphaned marker is
# inert, so a caller treats the non-zero return as a warning, never as a failed
# cleanup. Returns 1 when any path could not be removed.
watcher_endpoint_markers_clear() {  # <state-dir> <endpoint>
  local state=$1 endpoint=$2 marker rc=0
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    rm -f -- "$marker" 2>/dev/null || rc=1
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      rc=1
    fi
  done < <(watcher_endpoint_markers "$state" "$endpoint")
  return "$rc"
}
