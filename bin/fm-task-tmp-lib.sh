#!/usr/bin/env bash
# Per-task temp root: one deterministic directory per task, created by
# bin/fm-spawn.sh, recorded as tasktmp= in the task's meta, carrying Go's build
# temp at gotmp/ (exported as GOTMPDIR), and removed by bin/fm-teardown.sh
# through the exact-match ownership check below. Sourced by both so the path
# shape has exactly one owner. That much holds unconditionally.
#
# Pinning the launched agent's own TMPDIR to this root as well - which is what
# confines the agent's harness scratch to a directory teardown owns - is opt-in
# and off by default; docs/configuration.md "Task TMPDIR pin" owns that flag and
# what it does and does not solve. With the flag absent the agent's own scratch
# stays wherever the harness puts it, outside this root, and teardown does not
# remove it. With the flag present, a harness that derives its scratch tree from
# the process TMPDIR keeps that tree here instead of leaking under /tmp. Claude
# Code is the harness verified to do so (docs/verification/runtime-backends.md,
# "Per-task temp root and harness scratch"), and it is the one whose scratch was
# observed leaking; a harness that ignores TMPDIR simply keeps its scratch
# outside this root and teardown still succeeds, as that record states. That
# scratch is often large (search indexes, database copies) and /tmp is commonly a
# RAM-backed tmpfs, so leaking it leaks memory until reboot.
#
# The root is HOME-SCOPED as well as task-scoped. /tmp is one namespace shared by
# every firstmate home on the machine and task ids are per-home slugs, so two
# homes (two secondmates, a primary plus a secondmate, two independent
# installations) can hold live tasks with the same id. The discriminator is
# fm_backend_hometag() from bin/fm-backend-hometag-lib.sh - the same tag cmux and
# zellij already use to split their own machine-global namespaces, reused rather
# than re-invented, because a second discriminator meaning the same thing as an
# existing one is how the two drift apart.
#
# Roots recorded in the older undiscriminated <base>/fm-<id> shape (tasks in
# flight when the home scoping landed) are deliberately NOT accepted for removal.
# That shape is ambiguous by construction: two homes with colliding ids both
# recorded it, and nothing available at teardown time distinguishes this task's
# root from the other home's, so removing it would be a guess. A permanent small
# leak is better than one chance of deleting a live sibling home's directory -
# and those roots hold only Go build temp, since no agent scratch was ever
# pinned there, so what is left behind is small and bounded to the tasks already
# in flight at upgrade. The exact-match guard below already refuses
# such a path and reports it on stderr; there is no separate legacy code path.
#
# The safe unit of removal is the TASK, never the worktree slot: the worktree
# pool reuses slot numbers, so several tasks - including live ones - share a slot
# path over time. Nothing here deletes by slot, by age, or by scanning for
# sibling directories; teardown removes only the one path this task's own record
# names, and only when it is exactly the path this library derives for that task.
#
# Creation is guarded here too, not only removal: the root's name is predictable
# and /tmp is world-writable, so fm_task_tmp_create refuses a path another local
# user already owns instead of letting the pinned TMPDIR write the agent's whole
# scratch tree through it.
#
# FM_TASK_TMP_BASE overrides the /tmp parent (tests and non-default temp roots).
# Creation and removal must agree on it: a mismatch is reported and removal is
# refused rather than guessed at.

# Directory of this library, used to locate the sibling home-tag library.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_TASK_TMP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_TASK_TMP_LIB_DIR="."
# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$_FM_TASK_TMP_LIB_DIR/fm-backend-hometag-lib.sh"

# fm_task_tmp_root <task-id>
# Prints the canonical per-task temp root. Fails on an id or a home tag that is
# empty or carries path syntax. Callers must have resolved FM_HOME/FM_ROOT, which
# the home tag reads; both bin/fm-spawn.sh and bin/fm-teardown.sh do so before
# sourcing this library.
fm_task_tmp_root() {
  local id=${1:-} base=${FM_TASK_TMP_BASE:-/tmp} tag
  case "$id" in ''|.|..|*/*) return 1 ;; esac
  case "$base" in /*) ;; *) return 1 ;; esac
  tag=$(fm_backend_hometag) || return 1
  case "$tag" in ''|.|..|*/*) return 1 ;; esac
  printf '%s/fm-%s-%s\n' "${base%/}" "$tag" "$id"
}

# fm_task_tmp_owned <task-id> <recorded-path>
# Prints this task's own temp root when the recorded path is exactly the root
# this library derives for that id, and prints nothing otherwise. The single
# owner of "is this recorded path ours": teardown's process reaper and the
# removal below both ask it, so both act on the same validated unit. Returns 1
# for an empty, underivable, or foreign recorded path, without reporting -
# reporting belongs to fm_task_tmp_remove, which runs once per teardown.
fm_task_tmp_owned() {
  local id=${1:-} recorded=${2:-} canonical
  [ -n "$recorded" ] || return 1
  canonical=$(fm_task_tmp_root "$id") || return 1
  [ "$recorded" = "$canonical" ] || return 1
  printf '%s\n' "$canonical"
}

# fm_task_tmp_remove <task-id> <recorded-path>
# Removes the recorded per-task temp root, and only that path. An empty recorded
# path (a task spawned before tasktmp= existed) is a silent no-op, as is a path
# that is already gone. Anything else - a recorded path that is not this task's
# canonical root, a symlink, a non-directory, or a removal that fails - prints one
# warning to stderr and returns 1. Callers must treat that as a report-and-continue
# condition: losing worktree cleanup over a leftover temp directory would be worse
# than the leak.
fm_task_tmp_remove() {
  local id=${1:-} recorded=${2:-} root
  [ -n "$recorded" ] || return 0
  if ! root=$(fm_task_tmp_owned "$id" "$recorded"); then
    root=$(fm_task_tmp_root "$id") || root="<underivable>"
    echo "warning: recorded temp root $recorded is not $id's own ($root); left it in place" >&2
    return 1
  fi
  if [ -L "$root" ]; then
    echo "warning: temp root $root is a symlink; left it in place" >&2
    return 1
  fi
  [ -e "$root" ] || return 0
  if [ ! -d "$root" ]; then
    echo "warning: temp root $root is not a directory; left it in place" >&2
    return 1
  fi
  if ! rm -rf -- "$root" 2>/dev/null || [ -e "$root" ]; then
    echo "warning: temp root $root could not be removed; cleanup is otherwise complete" >&2
    return 1
  fi
  return 0
}

# fm_task_tmp_create <root>
# Creates the per-task temp root and Go's build temp nested at gotmp/, and
# refuses rather than writing through a path this user does not own.
# The root name is deterministic and its default parent /tmp is world-writable,
# so any other local user can plant a symlink or their own directory at that
# name before a spawn reaches it. Writing through such a path would put
# everything the task nests here - Go's build temp always, and with the TMPDIR
# pin enabled the agent's whole scratch tree of search indexes and database
# copies - somewhere this user neither controls nor tears down, and the symlink
# refusal in fm_task_tmp_remove above comes too late to prevent it: it runs at
# teardown, after the task has written. So the root itself is created
# with a plain mkdir, which fails on an existing path instead of following it,
# and an already-present root - a relaunch reuses its task's root - is accepted
# only when it is a real directory owned by this user. Mode 0700 keeps the
# scratch out of other users' reach once the directory is ours.
#
# Success covers two materially different outcomes, reported in
# FM_TASK_TMP_CREATED: 1 when this call created the root itself, 0 when it
# accepted a root that was already there. Only the first means nothing can name
# the path yet, so only the first may be removed by an aborting spawn. Accepting
# an existing root can mean a live task of the same id already owns it - the
# exact-match guard would pass, because the path genuinely is that id's canonical
# root - and removing it would destroy a running agent's scratch, the one harm
# this whole path exists to prevent.
fm_task_tmp_create() {
  local root=${1:-}
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_TASK_TMP_CREATED=0
  case "$root" in /*) ;; *) return 1 ;; esac
  mkdir -p -- "${root%/*}" || return 1
  if mkdir -m 700 -- "$root" 2>/dev/null; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    FM_TASK_TMP_CREATED=1
  elif [ -L "$root" ] || [ ! -d "$root" ] || [ ! -O "$root" ]; then
    echo "error: temp root $root could not be created as a directory owned by this user; refusing to use it" >&2
    return 1
  fi
  mkdir -p -- "$root/gotmp" || return 1
  return 0
}
