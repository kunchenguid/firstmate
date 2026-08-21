#!/usr/bin/env bash
# bin/fm-backend-hometag-lib.sh - shared per-installation home-tag derivation
# for machine-global namespaces with no native per-home split: cmux's workspace
# list, zellij's shared session tab bar, and reader task roots under /tmp.
# Without the tag, equal task ids in distinct homes can address the same
# backend endpoint or disposable reader storage.
#
# fm_backend_hometag() derives a short, stable tag: a readable prefix
# ("firstmate" for the primary home, "2ndmate-<id>" for a secondmate home
# carrying .fm-secondmate-home) plus a short hash of the resolved FM_ROOT
# path, so distinct installations - including multiple primaries on one
# machine - never collide in the shared namespace. Callers source this file
# AFTER resolving their own
# FM_HOME/FM_ROOT fallbacks (both adapters already do this for their own
# purposes before any other function runs).
#
# Moving/relocating a firstmate installation changes its FM_ROOT path and
# therefore its tag; titles created under the old tag simply stop matching -
# an accepted limitation, no worse than the existing fact that a task's
# recorded absolute worktree path does not survive a move either.

FM_BACKEND_HOMETAG_SECONDMATE_MARKER=".fm-secondmate-home"

fm_backend_hometag() {
  local marker="$FM_HOME/$FM_BACKEND_HOMETAG_SECONDMATE_MARKER" id prefix root hash
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="2ndmate-$id"
    else
      prefix="firstmate"
    fi
  else
    prefix="firstmate"
  fi
  root=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || root=$FM_ROOT
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$root" | cksum | awk '{printf "%08x", $1}')
  fi
  printf '%s-%s' "$prefix" "$hash"
}

# fm_reader_task_tmp() is the single owner of a reader task's temp-root
# spelling. fm-spawn records it as tasktmp= and fm-teardown recomputes it as
# the destruction anchor it refuses to deviate from, even under --force; two
# independent spellings would make every already-spawned reader permanently
# untearable-down the moment one side changed. It sets FM_READER_TASK_TMP on
# success and returns non-zero when the derived tag cannot safely name a
# directory, leaving FM_READER_TASK_TMP_HOMETAG for the caller's diagnostic.
FM_READER_TASK_TMP=
FM_READER_TASK_TMP_HOMETAG=

fm_reader_task_tmp() {  # <task-id>
  local id=$1
  FM_READER_TASK_TMP=
  FM_READER_TASK_TMP_HOMETAG=$(fm_backend_hometag)
  case "$FM_READER_TASK_TMP_HOMETAG" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  # shellcheck disable=SC2034 # Output global consumed by scripts sourcing this library.
  FM_READER_TASK_TMP="/tmp/fm-$FM_READER_TASK_TMP_HOMETAG-$id"
}
