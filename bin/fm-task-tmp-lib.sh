#!/usr/bin/env bash
# Per-task temp root: one deterministic directory per task, created by
# bin/fm-spawn.sh, handed to the launched agent as TMPDIR (and GOTMPDIR at
# gotmp/), recorded as tasktmp= in the task's meta, and removed by
# bin/fm-teardown.sh. Sourced by both so the path shape has exactly one owner.
#
# TMPDIR is what makes the agent's own scratch land here: every supported
# harness derives its scratch tree from the process TMPDIR, so a per-task TMPDIR
# turns harness scratch from an unbounded /tmp leak into one directory teardown
# owns. That scratch is often large (search indexes, database copies) and /tmp is
# commonly a RAM-backed tmpfs, so leaking it leaks memory until reboot.
#
# The safe unit of removal is the TASK, never the worktree slot: the worktree
# pool reuses slot numbers, so several tasks - including live ones - share a slot
# path over time. Nothing here deletes by slot, by age, or by scanning for
# sibling directories; teardown removes only the one path this task's own record
# names, and only when it is exactly the path this library derives for that task.
#
# FM_TASK_TMP_BASE overrides the /tmp parent (tests and non-default temp roots).
# Creation and removal must agree on it: a mismatch is reported and removal is
# refused rather than guessed at.

# fm_task_tmp_root <task-id>
# Prints the canonical per-task temp root. Fails on an id that is empty or
# carries path syntax.
fm_task_tmp_root() {
  local id=${1:-} base=${FM_TASK_TMP_BASE:-/tmp}
  case "$id" in ''|.|..|*/*) return 1 ;; esac
  case "$base" in /*) ;; *) return 1 ;; esac
  printf '%s/fm-%s\n' "${base%/}" "$id"
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
  local id=${1:-} recorded=${2:-} canonical
  [ -n "$recorded" ] || return 0
  if ! canonical=$(fm_task_tmp_root "$id"); then
    echo "warning: cannot derive the temp root for task '$id'; left $recorded in place" >&2
    return 1
  fi
  if [ "$recorded" != "$canonical" ]; then
    echo "warning: recorded temp root $recorded is not $id's own ($canonical); left it in place" >&2
    return 1
  fi
  if [ -L "$recorded" ]; then
    echo "warning: temp root $recorded is a symlink; left it in place" >&2
    return 1
  fi
  [ -e "$recorded" ] || return 0
  if [ ! -d "$recorded" ]; then
    echo "warning: temp root $recorded is not a directory; left it in place" >&2
    return 1
  fi
  if ! rm -rf -- "$recorded" 2>/dev/null || [ -e "$recorded" ]; then
    echo "warning: temp root $recorded could not be removed; cleanup is otherwise complete" >&2
    return 1
  fi
  return 0
}
