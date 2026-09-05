#!/usr/bin/env bash
# fm-proc-cwd-lib.sh - "which processes may this reaper signal?" (one owner).
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
# A pid alone is not a safe reference to the process that was scanned, so this
# file owns a second boundary: identity across time. A pid the scan reported may
# exit before the signal is sent, and the kernel may hand that number to an
# unrelated process - so both reapers must capture what the process WAS at scan
# time and re-verify it immediately before every signal. fm_proc_safe_to_signal
# composes the two questions ("still inside the boundary?" and "still the same
# process?") into the single predicate a reaper must pass before it kills
# anything, because omitting either one is the same bug.
#
# The identity here is deliberately BIRTH ONLY (start time), which is the right
# semantics for a REAPER and not for an owner. It must survive `exec`: a leaked
# process that exec'd between the scan and the signal is still the leak, and an
# identity including the command line would silently spare it (verified against
# real processes: an exec preserves start time while rewriting the command
# line). Do not reach for bin/fm-wake-lib.sh's fm_pid_identity here - its
# command-line-inclusive identity is correct for its own question, "does this
# pid still own my lock?", where any change must read as a different process.
#
# What this file does NOT own is the reaping policy: teardown is fail-closed (an
# unreadable process list refuses destructive teardown and preserves the
# worktree for inspection), while a test fixture is best-effort (it must never
# turn a leaked process into a suite failure). Sharing the two boundaries keeps
# the dangerous half from drifting between hand-written copies; leaving the
# policy with each caller keeps a test-only need from reshaping a production
# safety path.
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

# fm_proc_reap_identity <pid>
# Prints a stable identity for the process currently holding <pid>, or returns
# 1 if it cannot be read - which a caller must treat as "I could not find out",
# never as "unchanged". See the header for why this is birth identity only.
#
# A Linux-compatible /proc is preferred where present: stat field 22 (start
# time in clock ticks since boot) is immune to the wall-clock steps that
# re-render the `ps lstart` fallback. FM_PROC_ROOT_OVERRIDE relocates that root
# so a test can exercise the portable fallback on a machine that has /proc.
fm_proc_reap_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  # Trimmed inline rather than through bin/fm-nm-run-lib.sh's fm_nm_trim: this
  # file stays dependency-free so an EXIT trap can source it (see header).
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

# fm_proc_reap_identity_matches <pid> <identity>
# True only if <pid> is readable AND still the process <identity> came from.
fm_proc_reap_identity_matches() {  # <pid> <identity>
  local current
  current=$(fm_proc_reap_identity "$1") || return 1
  [ "$current" = "$2" ]
}

# fm_proc_pid_in_list <pid-list> <pid>
# True if newline-separated <pid-list> contains <pid> as a whole line.
fm_proc_pid_in_list() {  # <pid-list> <pid>
  printf '%s\n' "$1" | grep -Fxq "$2"
}

# fm_proc_safe_to_signal <pid> <identity> <current-pid-list>
# The predicate every signal in this file's callers must pass: <pid> is still
# inside the boundary according to a FRESH scan (<current-pid-list>), and is
# still the same process whose <identity> was captured from that scan. Both
# halves are required, and a caller that checks only one has the bug this
# predicate exists to prevent.
fm_proc_safe_to_signal() {  # <pid> <identity> <current-pid-list>
  fm_proc_pid_in_list "$3" "$1" || return 1
  fm_proc_reap_identity_matches "$1" "$2"
}
