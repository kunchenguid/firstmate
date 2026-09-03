#!/usr/bin/env bash
# fm-proc-cwd-lib.sh - "which processes are rooted under this directory?" (one owner).
#
# WHY. Two independent reapers need the same question answered before they
# delete a directory tree, and both are dangerous if the answer is too wide:
#   - bin/fm-teardown.sh's Fix 2 reaps processes leaked under a task's own
#     worktree or per-task tasktmp before returning the worktree.
#   - tests/lib.sh's fixture cleanup reaps processes leaked under a test's own
#     temp root before removing it. Firstmate's own spawn-exercising tests type
#     `treehouse get` into a pane; when that pane belongs to a real runtime
#     rather than a stub, the real `treehouse get` runs, opens its subshell
#     inside the test's temp tree, and survives the tree's removal.
# Keying on the CURRENT WORKING DIRECTORY, rather than walking a process tree,
# is what makes the answer both complete and safe. Complete, because a leaked
# process is typically already reparented to init and so has no tree left to
# walk back to its owner. Safe, because the roots callers pass are unique and
# unshared - one task's worktree, one test's temp root - so a process rooted
# there belongs to that caller by construction, and nothing outside that
# subtree can ever match.
#
# This file owns only that boundary computation, deliberately not the reaping
# policy on top of it: teardown is fail-closed (an unreadable process list
# refuses destructive teardown and preserves the worktree for inspection),
# while a test fixture is best-effort (it must never turn a leaked process into
# a suite failure). Sharing the boundary keeps the dangerous half from drifting
# between two hand-written copies; leaving the policy with each caller keeps a
# test-only need from reshaping a production safety path.
#
# Pure and side-effect free at source time, so the test fixture's EXIT trap can
# source it as cheaply as a long-lived script does.

# fm_pids_with_cwd_under <dir>
# Prints the pid of every process whose current working directory is <dir>
# itself or anything beneath it, one per line, excluding this shell.
#
# Returns 1 - printing nothing usable - if the process list cannot be read or
# parsed, so a caller can tell "nothing is rooted there" apart from "I could
# not find out". Callers must not treat the latter as the former.
#
# An absent or non-directory <dir> is not an error: there is nothing to protect
# and so nothing to reap. Note the corollary - a tree that has ALREADY been
# deleted can no longer be scanned, because the processes it leaked are the
# only remaining trace of it. The sweep must therefore run before the delete.
#
# <dir> is resolved to its physical path first: `lsof` reports physical paths,
# so comparing against an unresolved path would silently miss every match
# whenever any path component is a symlink - which is the default on macOS,
# where TMPDIR lives under /var -> /private/var.
#
# The `"$dir"|"$dir"/*` match is a whole-path-component test, not a string
# prefix: it deliberately does not match a sibling that merely starts with the
# same characters (/tmp/fm-x must never sweep /tmp/fm-x-other).
fm_pids_with_cwd_under() {  # <dir>
  local dir=$1 out pid path line
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  dir=$(cd "$dir" && pwd -P) || return 1
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  pid=
  # lsof -F emits one field per line, tagged by its first character: `p<pid>`
  # opens a process record, `f<fd>` opens a file record within it, `n<name>`
  # gives that file's path. Anything else on a line means the format is not
  # what this parser was written against, so refuse rather than guess.
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      fcwd) [ -n "$pid" ] || return 1 ;;
      n*)
        [ -n "$pid" ] || return 1
        path=${line#n}
        case "$path" in
          "$dir"|"$dir"/*)
            [ -n "$pid" ] && [ "$pid" != "$$" ] && printf '%s\n' "$pid"
            ;;
        esac
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}
