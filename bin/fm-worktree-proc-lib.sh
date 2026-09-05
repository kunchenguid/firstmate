#!/usr/bin/env bash
# fm-worktree-proc-lib.sh - the single owner of "which running processes belong
# to a task's disposable local copy", and of stopping them without ever reaching
# outside it.
#
# Why this exists. A crewmate that starts a long-running process in its task
# worktree - a dev server, a watcher, a queue worker - leaves that process
# running when the AGENT itself dies without a teardown: quota exhausted, harness
# crash, session closed. The worktree keeps its slot and the process keeps its
# sockets, CPU, and file descriptors for as long as the machine is up. Observed
# 2026-08-27: one such server outlived its agent by eight and a half hours and
# drove the host to 97% CPU (90.6% system time) through accumulated proxied
# connections; 41 processes of the same shape had been reaped by hand the day
# before.
#
# ATTRIBUTION IS BY WORKING DIRECTORY, NEVER BY NAME. The only question this
# library answers is "is this process's real current working directory inside
# that exact disposable copy". A command-name match (pkill -f node and friends)
# would reach into other firstmate homes and into the operator's own stack, so
# no function here ever looks at a command line to decide whether to signal.
#
# Resolution order, and why /proc comes first. `lsof` is not installed
# everywhere - it is absent on the host the incident above was observed on - and
# a cwd scan that depends on it degrades silently exactly where the reap matters
# most. On any host exposing a Linux-compatible /proc, the cwd is read from
# /proc/<pid>/cwd, which is a kernel fact rather than a tool's output. lsof stays
# as the fallback for a host with no /proc (macOS), and a host with neither
# reports that it cannot establish a safe result rather than guessing.
#
# An unreadable /proc/<pid>/cwd (another user's process, a race with exit) is
# NOT evidence of anything: such a process is skipped and left alone. Nothing
# here ever signals a pid it could not positively place inside the copy.
#
# A pid that has GONE between the listing and the reading of it is dropped at
# the same point, and that is not an optimisation. A scan is itself a process
# tree: taking the machine listing needs command substitutions, whose subshells
# inherit the caller's working directory and are in /proc when the listing's
# glob expands. Run from inside the very copy being scanned - which is where an
# operator naturally stands - the scanner therefore lists its OWN helpers as
# occupants of the copy. They have exited by the time anything reads the
# result, so re-checking the entry at the point of collection removes them and
# nothing else: a scanner that reports its own helpers as leftovers discredits
# every line it prints.
#
# Two things this deliberately is NOT. It is not exclusion by descent: a genuine
# leftover is frequently a descendant of the shell a cleanup is run from, so
# excluding descendants would hide exactly what this exists to find. And it is
# not a `kill -0` probe, which answers "may I signal it" rather than "is it
# there" - another user's process fails that probe while being very much alive,
# and dropping it would let a teardown remove a copy with a live foreign
# process still in it.
#
# Sparing the endpoint's shell is POSITIVE IDENTIFICATION, never an inference.
# The paths that reuse a terminal endpoint must not close it, and the shell that
# endpoint runs sits in the task copy like any leftover does. That shell is
# resolved from the task's OWN recorded endpoint (the backend's pane pid), so a
# daemon that called setsid inside the copy - the shape that saturated the host
# on 2026-08-27, an API reparented to init - is eligible again. When the record
# cannot yield that pid, nothing is guessed: every session leader is left alone
# AND the count of leaders left alone is reported, because a silently empty
# result reads as "this copy is clean" and would hide exactly the process this
# library exists to find.
#
# Ownership boundary. This library owns RESOLUTION (which pids, under which
# roots, with which guards) for every caller. It also owns the report-and-
# continue reap used by the paths that are not destroying anything.
# bin/fm-teardown.sh keeps its own multi-pass refuse-before-removal loop,
# because there the reap gates an irreversible worktree removal and an
# unresolved process must block it; that loop calls this library's resolver so
# there is still exactly one definition of "processes of this copy".
#
# Public surface:
#   fm_wtproc_resolver                  -> proc | lsof | none (prints; cannot
#                                          memoise from inside `$( )`)
#   _fm_wtproc_resolve                  -> settles _FM_WTPROC_RESOLVER in the
#                                          CALLER's shell; call it bare
#   fm_wtproc_pids_under <dir>          -> pids, one per line (0 = safe result)
#   fm_wtproc_session_id <pid>          -> session id
#   fm_wtproc_is_session_leader <pid>   -> 0 when sid == pid
#   fm_wtproc_endpoint_shell_pid <backend> <target>
#                                       -> the pid of the shell that endpoint
#                                          runs, or 1 when the record cannot
#                                          yield one
#   fm_wtproc_disposable_worktree <dir> -> echoes the resolved path, 0 when the
#                                          path is provably a linked worktree
#                                          and not a primary checkout
#   fm_wtproc_task_tmp <task-id> <dir>  -> echoes the resolved per-task tmp root
#   fm_wtproc_signalling_root <dir> <label>
#                                       -> echoes the resolved path after the
#                                          shape refusals alone (0/1/2 as above)
#                                          (0 = accepted, 1 = refused with a
#                                          reason, 2 = absent, nothing there)
#   fm_wtproc_worker_is_gone <task-id> <agent-state>
#   fm_wtproc_collect <dir>...          -> FM_WTPROC_PIDS
#   fm_wtproc_snapshot_begin / _end     -> hold one machine listing across a
#                                          read-only sweep of several copies
#   fm_wtproc_select <spare>            -> FM_WTPROC_SELECTED,
#                                          FM_WTPROC_SPARED_LEADERS,
#                                          FM_WTPROC_SPARED_ENDPOINT
#   fm_wtproc_reap <label> <spare> <dir>...
#
# <spare> is the one thing a caller may hold back, and it is the same argument
# for the report and for the reap so the two can never disagree: a numeric pid
# (the endpoint's shell, positively identified from the record), `unknown` (the
# record could not yield one, so every session leader is held back and counted),
# or `none` (hold nothing back).
#
# Environment knobs:
#   FM_PROC_ROOT_OVERRIDE   proc root (default /proc); a path that is not a
#                           directory, one that does not answer the cwd
#                           question, or one whose cwd listing cannot be
#                           produced at all, selects the lsof fallback
#   FM_TASK_TMP_ROOT        parent of each task's per-task temp root (default
#                           /tmp). fm_wtproc_task_tmp rebuilds bin/fm-spawn.sh's
#                           `$FM_TASK_TMP_ROOT/fm-<id>` from it and refuses a
#                           recorded `tasktmp=` that resolves anywhere else, so
#                           the two must be read with the same value set
#   FM_WTPROC_GRACE         seconds between TERM and KILL (default 3)
#   FM_WTPROC_KILL_SETTLE   seconds to wait before confirming the KILL (default 1)
#   FM_WTPROC_CREW_STATE_TIMEOUT  bound on the current-state read (default 20)
#   FM_WTPROC_CREW_STATE_BIN      current-state reader (default bin/fm-crew-state.sh)

# shellcheck source=bin/fm-wake-lib.sh
if ! declare -F fm_pid_identity >/dev/null 2>&1; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-wake-lib.sh"
fi

FM_WTPROC_GRACE=${FM_WTPROC_GRACE:-3}
FM_WTPROC_KILL_SETTLE=${FM_WTPROC_KILL_SETTLE:-1}

_fm_wtproc_proc_root() {
  printf '%s' "${FM_PROC_ROOT_OVERRIDE:-/proc}"
}

# _fm_wtproc_proc_answers_cwd: does this proc root actually expose a working
# directory, or does it merely exist?
#
# The existence of the directory proves nothing. A /proc that is not
# Linux-shaped in this one respect - Cygwin/MSYS, a supported platform here
# (bin/fm-wake-lib.sh), where a native Windows process's cwd link does not
# resolve - would make every scan return an empty set with status 0, and every
# caller reads that as "nothing is running there": a teardown would remove a
# worktree with its processes still in it and a scan would report a leaking copy
# as clean forever. That is the same silent degradation this library refuses to
# accept from lsof, so the verdict is gated on a cwd link resolving to the
# directory whose occupant it names.
#
# The caller's own working directory answers that question best, but it is not
# allowed to be the only way of asking it. A process whose working directory has
# been REMOVED under it - the state a torn-down task copy leaves the shell that
# was sitting in it, and the reachable trigger for a fleet scan run from
# bin/fm-session-start.sh - cannot resolve its own cwd at all, and that says
# nothing whatsoever about whether this /proc exposes cwd links. Concluding
# `none` from it would turn a perfectly answerable host into one that reports it
# cannot look. So when the caller cannot be placed, the same question is put
# again from a directory that is known to exist: the proc root itself, entered
# by the probing subshell whose own self link then has to name it back.
_fm_wtproc_proc_answers_cwd() {  # <root>
  local root=$1 link target here probe
  here=$(pwd -P 2>/dev/null) || here=
  if [ -n "$here" ]; then
    for link in "$root/self/cwd" "$root/${BASHPID:-$$}/cwd" "$root/$$/cwd"; do
      [ -L "$link" ] || continue
      target=$(cd "$link" 2>/dev/null && pwd -P) || continue
      [ "$target" = "$here" ] && return 0
    done
  fi
  [ -L "$root/self/cwd" ] || return 1
  probe=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  target=$(cd "$root" 2>/dev/null && cd "$root/self/cwd" 2>/dev/null && pwd -P) || return 1
  [ "$target" = "$probe" ]
}

# _fm_wtproc_proc_lists_cwd_entries: can the scan's OWN mechanism be run here?
#
# A cwd link that resolves proves the kernel exposes the fact; it does not prove
# the listing this library reads that fact through can be produced. `ls`
# unresolvable on PATH would leave the self-test satisfied and every scan
# answering "nothing is running there" with status 0 - the same silent
# degradation the cwd probe exists to refuse, reached one step further along. So
# the verdict is gated on the listing too, taken once here and thrown away
# rather than cached: the resolver is memoised for the life of the shell and a
# listing may never outlive one observation.
_fm_wtproc_proc_lists_cwd_entries() {  # <root>
  local root=$1 listing
  listing=$(_fm_wtproc_listing_run "$root") || return 1
  case "$listing" in
    *"$root"/[0-9]*/cwd*) return 0 ;;
  esac
  return 1
}

# _fm_wtproc_resolve: settle which cwd source this host can answer with, into
# _FM_WTPROC_RESOLVER, memoised per proc root.
#
# THIS MUST BE CALLED BARE, never inside `$( )`. The memo is the whole point:
# the self-test is not cheap - _fm_wtproc_proc_lists_cwd_entries takes a whole
# machine listing - and the question is asked once per scanned root, on a host
# that is already saturated when this code matters most. A command substitution
# runs it in a subshell, so the assignment dies with that subshell and the
# listing is retaken every single time; that is exactly what every call site
# used to do, and the memo never once survived. Callers that ask more than once
# resolve bare first, then read $_FM_WTPROC_RESOLVER directly.
_FM_WTPROC_RESOLVER=
_FM_WTPROC_RESOLVER_ROOT=
_fm_wtproc_resolve() {
  local root
  root=$(_fm_wtproc_proc_root)
  if [ -n "$_FM_WTPROC_RESOLVER" ] && [ "$_FM_WTPROC_RESOLVER_ROOT" = "$root" ]; then
    return 0
  fi
  _FM_WTPROC_RESOLVER_ROOT=$root
  if [ -d "$root" ] && _fm_wtproc_proc_answers_cwd "$root" \
     && _fm_wtproc_proc_lists_cwd_entries "$root"; then
    _FM_WTPROC_RESOLVER=proc
  elif command -v lsof >/dev/null 2>&1; then
    _FM_WTPROC_RESOLVER=lsof
  else
    _FM_WTPROC_RESOLVER=none
  fi
}

# The printing form, kept for callers that ask once and for readability inside a
# message. It is safe inside `$( )` - it simply cannot memoise from there, which
# is why the hot paths below use _fm_wtproc_resolve instead.
fm_wtproc_resolver() {
  _fm_wtproc_resolve
  printf '%s' "$_FM_WTPROC_RESOLVER"
}

# The one whole-machine listing every root is matched against.
#
# The listing is the expensive part of a /proc scan and it is identical for
# every root, so it is taken once and reused: a task has two roots (its copy and
# its temp root), a reap re-collects up to five times, and a fleet scan runs
# from the session-start digest on a host that was already saturated.
#
# The cache MUST NOT outlive one logical observation, and that is the whole of
# its contract. A reap re-scans precisely to see which of the processes it
# signalled have died since the last pass, and a listing carried across those
# passes would report a survivor that is already gone - or miss one that is not.
# So it is loaded and released inside a single fm_wtproc_collect, and the only
# way to hold one across several is fm_wtproc_snapshot_begin, which
# fm_wtproc_reap drops before it collects anything.
#
# It is loaded in the CALLER's own shell rather than inside the command
# substitution that reads the pids, because an assignment made in a subshell
# would be thrown away with it and every root would pay for its own walk again.
_FM_WTPROC_LISTING=
_FM_WTPROC_LISTING_ROOT=
_FM_WTPROC_LISTING_HELD=0
_FM_WTPROC_LISTING_PASS=0

# Take the listing, and answer whether it could be taken at all.
#
# `ls` exits non-zero as soon as it meets one link it may not read, which is the
# ordinary case on a multi-user host and must never fail a scan - the entry is
# still listed, with no `-> target`, and an unreadable working directory is not
# evidence of anything. So the exit status is deliberately discarded. What may
# NOT be discarded is the listing coming back with nothing at all: the scanning
# process's own entry is always in it (it is filtered out of the results, not
# out of the listing), so an empty listing means the command did not run - `ls`
# unresolvable on PATH, the proc root gone since the resolver answered - and
# that is unanswerable, never a clean machine.
_fm_wtproc_listing_run() {  # <root>
  local out
  out=$(ls -l "$1"/[0-9]*/cwd 2>/dev/null || true)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

_fm_wtproc_listing_load() {  # <root>
  local root=$1 out
  [ -d "$root" ] || return 1
  [ "$_FM_WTPROC_LISTING_ROOT" = "$root" ] && return 0
  out=$(_fm_wtproc_listing_run "$root") || return 1
  _FM_WTPROC_LISTING=$out
  _FM_WTPROC_LISTING_ROOT=$root
}

# Drop the listing unless a collect pass or an explicit snapshot is holding it.
# The default is to drop: a caller that asks the question on its own - the
# multi-pass loop in bin/fm-teardown.sh does - gets a fresh look every time.
_fm_wtproc_listing_release() {
  { [ "$_FM_WTPROC_LISTING_HELD" = 1 ] || [ "$_FM_WTPROC_LISTING_PASS" = 1 ]; } && return 0
  _FM_WTPROC_LISTING=
  _FM_WTPROC_LISTING_ROOT=
  return 0
}

# fm_wtproc_snapshot_begin / fm_wtproc_snapshot_end: hold ONE listing across a
# read-only sweep of several copies, so a fleet-wide report costs one walk of
# the machine rather than one per task. Only a caller that signals nothing may
# open one, and it has to close it: everything inside it is answered from the
# same instant.
fm_wtproc_snapshot_begin() {
  _FM_WTPROC_LISTING=
  _FM_WTPROC_LISTING_ROOT=
  _FM_WTPROC_LISTING_HELD=1
}

fm_wtproc_snapshot_end() {
  _FM_WTPROC_LISTING_HELD=0
  _FM_WTPROC_LISTING=
  _FM_WTPROC_LISTING_ROOT=
}

# Every pid whose /proc cwd link resolves to <dir> or below it.
#
# One `ls -l` over the whole proc root rather than a readlink per pid: the scan
# runs on the session-start path, and a fork per process would cost seconds on a
# busy host where the single listing costs milliseconds. A link the caller may
# not read is listed with no `-> target` at all, which is exactly the required
# behaviour - an unreadable working directory is not evidence of anything, so
# that process is skipped and left alone. Never this shell.
_fm_wtproc_pids_under_proc() {  # <real-dir>
  local dir=$1 root line entry link pid self
  root=$(_fm_wtproc_proc_root)
  _fm_wtproc_listing_load "$root" || return 1
  self=${BASHPID:-$$}
  while IFS= read -r line; do
    case "$line" in *' -> '*) ;; *) continue ;; esac
    entry=${line%%' -> '*}
    link=${line#*' -> '}
    # The listing prefixes each path with ls's own columns; take the path from
    # the proc root onwards so a root containing a space is still parsed right.
    case "$entry" in
      *"$root"/*/cwd) pid=${entry##*"$root"/} ;;
      *) continue ;;
    esac
    pid=${pid%/cwd}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "$self" ] && continue
    [ "$pid" = "$$" ] && continue
    # Still there? The entry is re-checked against /proc rather than probed with
    # a signal. `kill -0` answers "may I signal it", which is a different
    # question: another user's process fails that test while being very much
    # alive, and dropping it would let a teardown remove a copy with a live
    # foreign process still sitting in it. Directory existence is the exact
    # question and is permission-independent.
    # An `if`, not `test && printf`. This is the last command of the case, of
    # the while body, and of this function, so an `&&` list whose test fails
    # makes all three yield 1 - and the function would report FAILURE having
    # produced a perfectly correct answer. Callers read that as "the scan could
    # not be done": teardown refuses and preserves a copy it should have
    # cleaned, and the sweep calls a copy it read correctly unexaminable. The
    # trigger is the very thing this recheck exists for, a helper that exited
    # between the listing and the read, so it would fire routinely.
    case "$link" in
      "$dir"|"$dir"/*)
        if _fm_wtproc_pid_exists "$pid"; then
          printf '%s\n' "$pid"
        fi
        ;;
    esac
  done <<EOF
$_FM_WTPROC_LISTING
EOF
}

# The same question answered from one bounded system-wide `lsof -a -d cwd` scan
# (never the recursive +D file-tree walk, which lsof itself documents as slow).
# A malformed field stream returns failure rather than a partial answer.
_fm_wtproc_pids_under_lsof() {  # <real-dir>
  local dir=$1 out pid path line self
  self=${BASHPID:-$$}
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  pid=
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
        # The same two corrections the /proc arm carries, for the same two
        # reasons. An `if`, because this is the last command of the case, of
        # the while body, and of this function, so an `&&` list whose test
        # fails makes the function report FAILURE on a correct answer - and a
        # caller reads that as "the scan could not be done", refusing a
        # teardown or calling a copy it read correctly unexaminable. And the
        # liveness recheck, because `lsof` is itself forked from the caller and
        # walks the process table with the caller's working directory, so a
        # scan run from inside the copy lists lsof's own pid as an occupant of
        # it. The existence test is _fm_wtproc_pid_exists, NOT `kill -0`: this
        # library's own rule, stated at the top of this file, is that liveness
        # here means "is it there" and never "may I signal it", because the
        # second drops another user's live process and would let a teardown
        # remove a copy with one still in it.
        #
        # NOT EXERCISED ON THIS HOST. lsof is absent from the machine this was
        # written and verified on, so this arm has no test coverage here and
        # was corrected by inspection alone, in step with its /proc twin. It is
        # labelled rather than left asymmetric: a reader finding one arm fixed
        # and the other not would reasonably conclude the second was examined
        # and judged sound.
        case "$path" in
          "$dir"|"$dir"/*)
            if [ "$pid" != "$self" ] && [ "$pid" != "$$" ] && _fm_wtproc_pid_exists "$pid"; then
              printf '%s\n' "$pid"
            fi
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

# _fm_wtproc_pid_exists: is that pid still there?
#
# "Is it there", never "may I signal it". `kill -0` answers the second: another
# user's process fails it while being very much alive, and dropping such a pid
# would let a teardown remove a copy with a live foreign process still in it.
# So the proc entry is used where there is one, and `ps -p` - which reports
# another user's process just as readily - on the hosts this library reaches
# through lsof, which are exactly the hosts with no /proc to consult.
_fm_wtproc_pid_exists() {  # <pid>
  local pid=$1 root
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  root=$(_fm_wtproc_proc_root)
  if [ -d "$root" ]; then
    [ -e "$root/$pid" ]
    return
  fi
  ps -p "$pid" >/dev/null 2>&1
}

# fm_wtproc_pids_under: pids whose real cwd is <dir> or below. An empty result
# with status 0 means "nothing is running there"; a non-zero status means the
# question could not be answered safely and the caller must not assume either.
fm_wtproc_pids_under() {  # <dir>
  local dir=$1 real rc=0
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  real=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  _fm_wtproc_resolve
  case "$_FM_WTPROC_RESOLVER" in
    proc) _fm_wtproc_pids_under_proc "$real" || rc=$? ;;
    lsof) _fm_wtproc_pids_under_lsof "$real" || rc=$? ;;
    *) rc=1 ;;
  esac
  _fm_wtproc_listing_release
  return "$rc"
}

# fm_wtproc_session_id: the process's session id, from /proc stat field 6 where
# a compatible /proc exists and from ps otherwise.
fm_wtproc_session_id() {  # <pid>
  local pid=$1 root stat_line sess
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  root=$(_fm_wtproc_proc_root)
  if [ -r "$root/$pid/stat" ]; then
    stat_line=$(cat "$root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 3 is proc stat field 6.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 4 ] || return 1
    sess=${stat_fields[3]}
  else
    sess=$(ps -o sess= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
  fi
  case "$sess" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$sess"
}

# fm_wtproc_ppid: the process's parent pid, from /proc stat field 4 where a
# compatible /proc exists and from ps otherwise.
fm_wtproc_ppid() {  # <pid>
  local pid=$1 root stat_line ppid
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  root=$(_fm_wtproc_proc_root)
  if [ -r "$root/$pid/stat" ]; then
    stat_line=$(cat "$root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 1 is proc stat field 4.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 2 ] || return 1
    ppid=${stat_fields[1]}
  else
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
  fi
  case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$ppid"
}

# fm_wtproc_ancestry: this process and every parent above it, up to init.
#
# The reaping process is already kept out of its own results, but its PARENTS
# are not, and a cleanup is routinely started from inside the very copy it is
# cleaning: `cd <home>/worktrees/fm-x1 && fm-control.sh x1 relaunch` is what the
# stuck-crewmate recovery does, and that interactive shell's cwd is under the
# root exactly like a leaked server's. The endpoint spare names ONE pid, so it
# cannot stand in for a chain. Signalling the terminal an operator is typing in,
# mid-relaunch, is the same class of harm as reaching outside the copy, so the
# whole chain is held back - and a chain member is a process with a live owner
# by definition, which is the one thing this mechanism never touches.
#
# Bounded so a /proc that reports a cycle cannot spin here.
fm_wtproc_ancestry() {
  local pid=${BASHPID:-$$} hops=0 ppid
  printf '%s\n' "$pid"
  if [ "$pid" != "$$" ]; then
    printf '%s\n' "$$"
  fi
  pid=$$
  while [ "$hops" -lt 64 ]; do
    ppid=$(fm_wtproc_ppid "$pid") || break
    case "$ppid" in 0|1) break ;; esac
    printf '%s\n' "$ppid"
    pid=$ppid
    hops=$((hops + 1))
  done
}

# fm_wtproc_is_session_leader: a terminal endpoint's shell is the session leader
# of the pty the backend opened for it, and its cwd is the task worktree - so it
# is indistinguishable from a leaked server by cwd alone. This is the LAST
# RESORT, used only when the record could not name the endpoint's shell: it is
# not a way of identifying that shell, it is a way of not guessing, and it
# withholds a daemon that called setsid inside the copy along with it. A process
# that cannot be classified is treated as a leader, so an unreadable state
# withholds rather than kills.
fm_wtproc_is_session_leader() {  # <pid>
  local pid=$1 sess
  sess=$(fm_wtproc_session_id "$pid") || return 0
  [ "$sess" = "$pid" ]
}

# fm_wtproc_endpoint_shell_pid: the pid of the shell the task's OWN recorded
# endpoint runs, asked of the backend that owns that endpoint.
#
# This is the whole of "which process must survive a cleanup that reuses the
# endpoint". It is a fact read from the record, not a property inferred from the
# process: a session leader that is not this pid has no claim on being spared,
# and a backend that cannot answer the question gets no answer invented for it -
# it fails, and the caller withholds and says so.
fm_wtproc_endpoint_shell_pid() {  # <backend> <target>
  local backend=$1 target=$2 pid
  [ -n "$backend" ] && [ -n "$target" ] || return 1
  case "$backend" in
    tmux)
      command -v tmux >/dev/null 2>&1 || return 1
      pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || return 1
      ;;
    *) return 1 ;;
  esac
  pid=$(printf '%s' "$pid" | tr -d '[:space:]')
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_pid_alive "$pid" || return 1
  printf '%s' "$pid"
}

# fm_wtproc_disposable_worktree: prove <dir> is a task's disposable local copy
# before anything running in it may be signalled, and echo its resolved path.
#
# The structural test is that the path is the ROOT of a LINKED git worktree:
# `git rev-parse --git-dir` differs from `--git-common-dir` only for a worktree
# added beside a checkout, never for the checkout itself. That single fact
# excludes every primary checkout on the machine - the operator's own clones and
# this home's projects/ clones alike - without depending on where they happen to
# live. The remaining guards refuse the paths whose shape alone makes them
# implausible as a task copy.
#
# The shape refusals are what keep a record that names the operator's own tree
# from turning into a kill root, and both VALIDATED entry points run them:
# fm_wtproc_disposable_worktree for a task's copy and fm_wtproc_task_tmp for its
# temp root, each before it hands the path back.
#
# They are deliberately NOT applied inside fm_wtproc_pids_under, so a caller that
# hands a recorded path straight to the scan clears no wall at all.
# bin/fm-teardown.sh is such a caller: it passes the `worktree=` and `tasktmp=`
# values off a task's meta to its own reap loop unvalidated. That predates this
# library and closing it would change teardown's behaviour, so it stands as it
# is - but nothing NEW may rely on this wall being behind it. A new caller that
# may signal into a root resolves it through one of the two validators above.
_fm_wtproc_refuse_sensitive_root() {  # <real-path> <fm-home> <what>
  local real=$1 home=$2 what=$3 home_real
  case "$real" in
    /) echo "fm-worktree-proc: refusing the filesystem root" >&2; return 1 ;;
    /*/*) ;;
    *) echo "fm-worktree-proc: '$real' is too shallow to be $what" >&2; return 1 ;;
  esac
  if [ -n "${HOME:-}" ]; then
    home_real=$(cd "$HOME" 2>/dev/null && pwd -P) || home_real=$HOME
    if [ "$real" = "$home_real" ] || [ "$(dirname "$real")" = "$home_real" ]; then
      echo "fm-worktree-proc: '$real' sits directly in the home directory, not in a disposable copy" >&2
      return 1
    fi
  fi
  [ -n "$home" ] || return 0
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || home_real=$home
  if [ "$real" = "$home_real" ]; then
    echo "fm-worktree-proc: '$real' is the firstmate home itself" >&2
    return 1
  fi
  case "$real" in
    "$home_real"/projects|"$home_real"/projects/*)
      echo "fm-worktree-proc: '$real' is a primary clone, not a disposable copy" >&2
      return 1
      ;;
  esac
}

# fm_wtproc_signalling_root: resolve <dir> and apply the shape refusals that no
# task root may ever fail, without asserting what KIND of root it is.
#
# For bin/fm-teardown.sh, whose recorded roots reach a signalling loop. That
# caller cannot use fm_wtproc_disposable_worktree: it supports a task copy that
# is an ordinary clone rather than a linked worktree, which its own suite pins,
# so the linked-worktree proof would refuse a shape the command is required to
# handle. What it can and must have is the half that names the harm - the
# filesystem root, a path sitting directly in the home, anything under
# projects/, which is where the operator's own stack lives - so a stale or
# hand-edited record can never point a signal at it.
#
#   0  accepted; the resolved path is printed
#   1  refused; the reason is printed on stderr
#   2  absent; nothing is there, so there is nothing to scan and nothing to say
fm_wtproc_signalling_root() {  # <dir> <label> [fm-home]
  local dir=$1 label=$2 home=${3:-${FM_HOME:-}} real
  [ -n "$dir" ] || { echo "fm-worktree-proc: no path was recorded for $label" >&2; return 1; }
  [ -e "$dir" ] || return 2
  [ -d "$dir" ] || { echo "fm-worktree-proc: $label '$dir' exists but is not a directory" >&2; return 1; }
  real=$(cd "$dir" 2>/dev/null && pwd -P) || {
    echo "fm-worktree-proc: $label '$dir' exists but could not be entered" >&2
    return 1
  }
  _fm_wtproc_refuse_sensitive_root "$real" "$home" "$label" || return 1
  printf '%s' "$real"
}

# ---------------------------------------------------------------------------
# Allocation ownership: proving a directory is THIS task's, not merely shaped
# like one of its roots.
#
# Every guard above this point answers a question about a path's SHAPE - is it
# a linked worktree, is it the deterministic temp path, is it clear of the home
# and projects/. None of them answer the question that actually licenses a
# signal: does this directory belong to the task whose record named it.
#
# Shape cannot answer it, because shape is reproducible. The task temp path is
# built from the task id, so anything that recreates or reuses
# `$FM_TASK_TMP_ROOT/fm-<id>` satisfies path equality exactly. A worktree is
# allocated from a shared pool and handed back when a task ends, so the same
# directory is a valid linked worktree for whichever task holds it NOW - the
# structural checks pass identically for the task that left and the task that
# arrived. In both cases a stale record still naming that path reaches a live
# stranger's processes, and every check above says yes.
#
# Observed 2026-08-27 on the captain's host, from the other side: a stale task
# record pointed at a copy that had since been reassigned to a running task,
# and a forced cleanup on that record stopped the live agent. Path equality had
# nothing to fail on - the path really was that shape - which is precisely why
# it cannot stand in for ownership.
#
# The binding is a marker bin/fm-spawn.sh writes into each root when it
# ALLOCATES it, carrying the task id and a token minted for that allocation and
# recorded in state/<id>.meta. Reuse cannot forge it: a directory recreated for
# other work carries no marker, and one reassigned to another task carries that
# task's allocation instead, because its new owner's spawn overwrote it. The
# token is what makes the second case fail - a task id alone would still match
# after a pool worktree came back around to the same task.
#
# The worktree's marker lives in its per-worktree git directory rather than in
# the working tree, so it never shows in `git status`, never blocks teardown's
# dirty check, and never reaches a commit. The temp root has no such place, so
# its marker is a dotfile at its top level.
#
# An UNMARKED root is refused, not accepted. It is what a copy allocated before
# this binding existed looks like, and it is also what a reused path looks like;
# nothing distinguishes them, so the safe reading is the one that stops. That
# costs automatic cleanup on copies predating this change, which is a real loss
# of coverage and is stated as such wherever the refusal surfaces.
_FM_WTPROC_OWNER_FILE=fm-task-owner

# _fm_wtproc_owner_marker_path: where a root's allocation marker lives.
# Prints the path; fails only when a worktree's git directory cannot be read.
_fm_wtproc_owner_marker_path() {  # <real-root> <kind:worktree|tmp>
  local real=$1 kind=$2 git_dir
  case "$kind" in
    tmp) printf '%s/.%s' "$real" "$_FM_WTPROC_OWNER_FILE" ;;
    worktree)
      git_dir=$(git -C "$real" rev-parse --absolute-git-dir 2>/dev/null) || return 1
      [ -n "$git_dir" ] || return 1
      printf '%s/%s' "$git_dir" "$_FM_WTPROC_OWNER_FILE"
      ;;
    *) return 1 ;;
  esac
}

# fm_wtproc_write_owner: called by bin/fm-spawn.sh at allocation. Writing the
# marker is what makes a later cleanup possible at all, so a failure to write
# is reported rather than swallowed - a root whose marker never landed will be
# refused later, and the operator should learn that here and not in six hours.
fm_wtproc_write_owner() {  # <real-root> <kind> <task-id> <token>
  local real=$1 kind=$2 id=$3 token=$4 marker
  [ -n "$real" ] && [ -n "$id" ] && [ -n "$token" ] || {
    echo "fm-worktree-proc: refusing to write an allocation marker without a root, task id and token" >&2
    return 1
  }
  marker=$(_fm_wtproc_owner_marker_path "$real" "$kind") || {
    echo "fm-worktree-proc: could not locate where $kind '$real' keeps its allocation marker" >&2
    return 1
  }
  ( umask 077 && printf 'task=%s\ntoken=%s\n' "$id" "$token" > "$marker" ) || {
    echo "fm-worktree-proc: could not write the allocation marker for $kind '$real'" >&2
    return 1
  }
}

# fm_wtproc_owns_root: 0 only when <real-root> carries an allocation marker
# naming exactly this task AND this allocation token.
#
# Every refusal states which of the four it was - no recorded token, no marker,
# another task, another allocation of this task - because they mean different
# things to the operator reading it, and it names the marker file it looked for
# and what to do about it.
#
# That is not message polish. This refusal is what a copy allocated before the
# binding existed will hit, so it is the one an operator meets while trying to
# clean up work that predates the change, and it stops a command they expected
# to run. A refusal that explains costs a minute; a bare one costs an
# investigation. The remedy is deliberately the two lines of the marker itself
# rather than a flag: adopting a copy has to be a thing someone did on purpose,
# after looking at what is running in it.
fm_wtproc_owns_root() {  # <real-root> <kind> <task-id> <expected-token>
  local real=$1 kind=$2 id=$3 want=$4 marker have_task have_token
  marker=$(_fm_wtproc_owner_marker_path "$real" "$kind") || {
    echo "fm-worktree-proc: could not locate where $kind '$real' keeps its allocation marker" >&2
    return 1
  }
  [ -n "$want" ] || {
    echo "fm-worktree-proc: task $id's record carries no allocation token, so nothing can prove $kind '$real' is its own. Its record predates this binding. Check what is running in that copy and that it really is task $id's, then add an 'owner_token=<token>' line to its record and write the same token into $marker as 'task=$id' and 'token=<token>'." >&2
    return 1
  }
  [ -f "$marker" ] || {
    echo "fm-worktree-proc: $kind '$real' carries no allocation marker at $marker, so it cannot be shown to belong to task $id: either it was allocated before this binding existed, or the path has since been reused by something else. Check what is running in it, and if it really is task $id's copy write 'task=$id' and 'token=$want' into $marker; if it is not, correct the record that names it." >&2
    return 1
  }
  have_task=$(sed -n 's/^task=//p' "$marker" 2>/dev/null | head -n 1)
  have_token=$(sed -n 's/^token=//p' "$marker" 2>/dev/null | head -n 1)
  [ "$have_task" = "$id" ] || {
    echo "fm-worktree-proc: $kind '$real' is allocated to task ${have_task:-an unnamed task}, not to task $id, so task $id's record is stale and that copy belongs to somebody who may still be working in it. Do not force past this. Correct task $id's record; the copy is ${have_task:-that task}'s to clean up." >&2
    return 1
  }
  [ "$have_token" = "$want" ] || {
    echo "fm-worktree-proc: $kind '$real' carries a different allocation of task $id than the record names, so the record is stale - the copy was handed back and given out again since it was written. Re-read the current record for task $id rather than acting on this one." >&2
    return 1
  }
}

fm_wtproc_disposable_worktree() {  # <dir> [fm-home] <task-id> <allocation-token>
  local dir=$1 home=${2:-${FM_HOME:-}} id=${3:-} token=${4:-} real top top_real git_dir common_dir
  [ -n "$dir" ] || { echo "fm-worktree-proc: no local copy recorded" >&2; return 1; }
  [ -d "$dir" ] || { echo "fm-worktree-proc: '$dir' is not a directory" >&2; return 1; }
  real=$(cd "$dir" 2>/dev/null && pwd -P) || {
    echo "fm-worktree-proc: '$dir' cannot be resolved" >&2
    return 1
  }
  _fm_wtproc_refuse_sensitive_root "$real" "$home" "a task's local copy" || return 1
  top=$(git -C "$real" rev-parse --show-toplevel 2>/dev/null) || {
    echo "fm-worktree-proc: '$real' is not a git worktree" >&2
    return 1
  }
  top_real=$(cd "$top" 2>/dev/null && pwd -P) || top_real=
  [ "$top_real" = "$real" ] || {
    echo "fm-worktree-proc: '$real' is not a worktree root (root is ${top:-unknown})" >&2
    return 1
  }
  git_dir=$(git -C "$real" rev-parse --absolute-git-dir 2>/dev/null) || git_dir=
  common_dir=$(cd "$real" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || common_dir=
  [ -n "$git_dir" ] && [ -n "$common_dir" ] || {
    echo "fm-worktree-proc: '$real' git layout cannot be inspected" >&2
    return 1
  }
  [ "$git_dir" != "$common_dir" ] || {
    echo "fm-worktree-proc: '$real' is a primary checkout, not a linked worktree" >&2
    return 1
  }
  # Everything above is shape, and shape is reproducible: a pool worktree is a
  # valid linked worktree for whichever task holds it now, so these checks pass
  # identically for the task that left and the task that arrived. Ownership is
  # the last word.
  fm_wtproc_owns_root "$real" worktree "$id" "$token" || return 1
  printf '%s' "$real"
}

# fm_wtproc_task_tmp: the per-task temp root fm-spawn records, accepted only when
# it clears the same shape refusals the worktree root does, resolves to the one
# path fm-spawn actually creates for this task, AND carries that spawn's own
# allocation marker.
#
# This root cannot prove itself a linked git worktree - it is not a checkout at
# all - so nothing in its own structure vouches for it. A name test cannot
# stand in for that: matching any directory whose name ends in `fm-<id>` accepts
# a correctly named root anywhere on the machine, so a stale or hand-edited
# `tasktmp=` reaches processes that were never this task's. The path is bound to
# the exact one bin/fm-spawn.sh builds - `$FM_TASK_TMP_ROOT/fm-<id>`, with the
# same /tmp default both sides read - and a record naming anything else is
# refused rather than reconciled.
#
# That equality is necessary and not sufficient, and the difference is the whole
# point of the ownership check that follows it. The path is DERIVED from the
# task id, so it is not evidence about the directory currently sitting there:
# remove that directory and let unrelated work recreate the same path, and the
# equality test passes on a root this task never owned. Only the allocation
# marker separates the two.
#
# The home and projects/ refusals still run first, so a record reading
# `tasktmp=$HOME/projects/fm-x1` is turned away by the boundary that names the
# operator's own stack, not merely by failing to be the recorded path.
#
# Three outcomes, not two:
#   0  accepted; the resolved path is printed
#   1  REFUSED; the reason is printed on stderr, and every refusing path here
#      prints one - a refusal a caller can only report as "no reason was given"
#      is an alarm with nothing in it
#   2  ABSENT; nothing exists at that path, so there is nothing to examine and
#      nothing to report
fm_wtproc_task_tmp() {  # <task-id> <dir> [fm-home] <allocation-token>
  local id=$1 dir=$2 home=${3:-${FM_HOME:-}} token=${4:-} real expect expect_real
  [ -n "$id" ] || { echo "fm-worktree-proc: no task id was given for a temp root" >&2; return 1; }
  [ -n "$dir" ] || { echo "fm-worktree-proc: no temp root was recorded for task $id" >&2; return 1; }
  # ABSENT is not UNEXAMINABLE, and the difference decides whether an operator
  # is alarmed. A recorded root that no longer exists has nothing in it to
  # examine - fm_wtproc_pids_under says so itself, treating a missing directory
  # as "nothing is running there" with status 0 - so it is reported back with
  # its own status 2 and the caller drops it silently. Refusing it as a root
  # that "cannot be called clean" is an alarm with no content behind it, and a
  # report that raises those is one people stop reading.
  [ -e "$dir" ] || return 2
  [ -d "$dir" ] || {
    echo "fm-worktree-proc: task $id's recorded temp root '$dir' exists but is not a directory" >&2
    return 1
  }
  real=$(cd "$dir" 2>/dev/null && pwd -P) || {
    echo "fm-worktree-proc: task $id's recorded temp root '$dir' exists but could not be entered" >&2
    return 1
  }
  _fm_wtproc_refuse_sensitive_root "$real" "$home" "a task's temp root" || return 1
  expect="${FM_TASK_TMP_ROOT:-/tmp}/fm-$id"
  expect_real=$(cd "$expect" 2>/dev/null && pwd -P) || {
    echo "fm-worktree-proc: task $id has no temp root at $expect" >&2
    return 1
  }
  [ "$real" = "$expect_real" ] || {
    echo "fm-worktree-proc: temp root '$real' is not task $id's own temp root $expect_real" >&2
    return 1
  }
  # Path equality got us this far and can go no further: this path is BUILT from
  # the task id, so anything that recreated or reused it matches exactly here.
  fm_wtproc_owns_root "$real" tmp "$id" "$token" || return 1
  printf '%s' "$real"
}

# fm_wtproc_worker_is_gone: 0 only when TWO independent sources agree that a
# task's worker is gone, so no single classifier can license a cleanup on its
# own.
#
# This gate is not defensive decoration. Observed 2026-08-27 on the captain's
# host: the Herdr backend's agent-state classifier reported `dead` for a worker
# that was running at that moment, while bin/fm-crew-state.sh - reading the
# harness busy signal rather than the rendered pane - correctly reported it
# working. A cleanup that had trusted the first source alone would have stopped
# a live worker's processes, which is the one outcome worse than the leak this
# whole mechanism exists to stop.
#
# <agent-state> is the backend classifier's verdict, read by the caller. Only
# `dead` and `missing` pass it. Current state then has to agree, and only `done`
# and `failed` do: they are positive readings of a finished worker. Everything
# else vetoes the verdict - `working`, `parked`, `blocked`, and `paused` because
# something is still going on, a read that times out or cannot be taken because
# there is no second source at all, and `unknown` because it is the reader
# saying it could not determine the state, which is not agreement that the
# worker is gone.
#
# `unknown` used to let the verdict stand, on the reading that a torn-off worker
# with no attributed run surfaces that way. It also surfaces that way when the
# record is stale: observed 2026-08-27 on the captain's host, bin/fm-crew-state.sh
# read `unknown · backend target gone` for a task whose recorded copy had since
# been handed to a live task, and treating that as corroboration would have
# stopped the new owner's processes. An undetermined state is left to the
# operator, at the cost of reporting a leak instead of clearing it.
#
# FM_WTPROC_CREW_STATE is set on EVERY path, including the ones that never reach
# the reader, so a caller quoting it can never name the wrong blocker: a live
# endpoint reads `not-consulted`, a missing reader reads `no-reader`, and a read
# that timed out or failed reads `unreadable`. Left carrying a previous call's
# value it would tell an operator that a current-state read vetoed a cleanup the
# endpoint verdict had already vetoed on its own.
FM_WTPROC_CREW_STATE_TIMEOUT=${FM_WTPROC_CREW_STATE_TIMEOUT:-20}
fm_wtproc_worker_is_gone() {  # <task-id> <agent-state>
  local id=$1 verdict=$2 bin out state
  FM_WTPROC_CREW_STATE=not-consulted
  export FM_WTPROC_CREW_STATE
  case "$verdict" in
    dead|missing) ;;
    *) return 1 ;;
  esac
  bin=${FM_WTPROC_CREW_STATE_BIN:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-crew-state.sh"}
  [ -x "$bin" ] || { FM_WTPROC_CREW_STATE=no-reader; return 1; }
  out=$(timeout "$FM_WTPROC_CREW_STATE_TIMEOUT" "$bin" "$id" 2>/dev/null) || {
    FM_WTPROC_CREW_STATE=unreadable
    return 1
  }
  state=${out#state: }
  state=${state%% *}
  [ -n "$state" ] || state=unreadable
  # Exposed so a caller can name the state that vetoed it.
  FM_WTPROC_CREW_STATE=$state
  case "$state" in
    done|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# Collect the pids under every root, deduplicated. Sets FM_WTPROC_PIDS and
# FM_WTPROC_FAILED_ROOT; returns 1 when any root could not be scanned safely.
#
# All of a task's roots are matched against ONE listing of the machine, taken
# here and released here: this call is the logical observation, and nothing that
# follows it may be answered from what it saw.
fm_wtproc_collect() {  # <dir>...
  local dir out pids="" rc=0
  FM_WTPROC_PIDS=
  FM_WTPROC_FAILED_ROOT=
  _FM_WTPROC_LISTING_PASS=1
  # Bare, and before the loop: fm_wtproc_pids_under runs inside a command
  # substitution below, so this is the one call whose memo survives to serve
  # every root of this observation.
  _fm_wtproc_resolve
  if [ "$_FM_WTPROC_RESOLVER" = proc ]; then
    _fm_wtproc_listing_load "$(_fm_wtproc_proc_root)" || true
  fi
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    if ! out=$(fm_wtproc_pids_under "$dir"); then
      FM_WTPROC_FAILED_ROOT=$dir
      rc=1
      break
    fi
    pids="$pids
$out"
  done
  [ "$rc" = 0 ] && FM_WTPROC_PIDS=$(printf '%s\n' "$pids" | grep -E '^[0-9]+$' | sort -un || true)
  _FM_WTPROC_LISTING_PASS=0
  _fm_wtproc_listing_release
  return "$rc"
}

_fm_wtproc_contains() {  # <pid-list> <pid>
  printf '%s\n' "$1" | grep -Fxq "$2"
}

# fm_wtproc_select: split the collected pids into the ones a caller may act on
# and the ones it holds back, from FM_WTPROC_PIDS into FM_WTPROC_SELECTED.
#
# One implementation for the report and for the reap: `scan` naming a copy as
# leaking and `reap` stopping what is in it have to be talking about the same
# set of processes, and two filters written twice would eventually disagree
# about which. Sets FM_WTPROC_SPARED_ENDPOINT to the endpoint shell it held back,
# FM_WTPROC_SPARED_LEADERS to the number of session leaders it could not rule out
# - a count callers are required to report rather than fold into an empty result
# - and FM_WTPROC_SPARED_ANCESTORS to the number of the caller's own ancestors it
# found sitting in the copy (see fm_wtproc_ancestry).
FM_WTPROC_SELECTED=
FM_WTPROC_SPARED_LEADERS=0
FM_WTPROC_SPARED_ENDPOINT=
FM_WTPROC_SPARED_ANCESTORS=0
fm_wtproc_select() {  # <spare>
  local spare=$1 pid out="" ancestry
  case "$spare" in
    none|unknown) ;;
    ''|*[!0-9]*) spare=unknown ;;
  esac
  FM_WTPROC_SELECTED=
  FM_WTPROC_SPARED_LEADERS=0
  FM_WTPROC_SPARED_ENDPOINT=
  FM_WTPROC_SPARED_ANCESTORS=0
  [ -n "$FM_WTPROC_PIDS" ] || return 0
  # Read once, before the loop: the chain is the same for every candidate, and a
  # /proc walk per pid would cost a fork per process on the saturated host this
  # runs on.
  ancestry=$(fm_wtproc_ancestry)
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    # Ahead of the spare arms, and of `none`: a caller that holds nothing back
    # still may not signal the shell it was invoked from.
    if _fm_wtproc_contains "$ancestry" "$pid"; then
      FM_WTPROC_SPARED_ANCESTORS=$((FM_WTPROC_SPARED_ANCESTORS + 1))
      continue
    fi
    case "$spare" in
      none) ;;
      unknown)
        if fm_wtproc_is_session_leader "$pid"; then
          FM_WTPROC_SPARED_LEADERS=$((FM_WTPROC_SPARED_LEADERS + 1))
          continue
        fi
        ;;
      *)
        if [ "$pid" = "$spare" ]; then
          # shellcheck disable=SC2034 # Consumed by sourcing callers.
          FM_WTPROC_SPARED_ENDPOINT=$pid
          continue
        fi
        ;;
    esac
    out="$out$pid
"
  done <<EOF
$FM_WTPROC_PIDS
EOF
  FM_WTPROC_SELECTED=${out%$'\n'}
}

# fm_wtproc_reap: stop everything rooted (by cwd) under <dir>..., TERM first and
# KILL after the grace period. Every signal is guarded twice: the pid must still
# be under one of the roots at signal time, and its birth identity must still
# match the one recorded when it was selected, so a pid recycled between the
# scan and the signal is never touched.
#
# <spare> is passed straight to fm_wtproc_select: the endpoint shell's pid when
# the caller reuses that endpoint and the record could name it, `unknown` when
# it could not, `none` when nothing is held back. `none` still holds back this
# cleanup's own ancestor chain (fm_wtproc_ancestry) - a shell the operator is
# typing in is never a leftover, whatever the caller asked for.
#
# Prints one human-readable line per action on stderr and the reaped pids on
# stdout, and sets FM_WTPROC_REAPED and FM_WTPROC_SURVIVORS for callers that
# need more than the exit status. The status distinguishes the four outcomes,
# because "cannot be determined" said before any signal and said after one are
# different facts about the machine and an operator acts on them differently:
#
#   0  nothing selected, or everything selected is gone
#   1  the scan failed BEFORE anything was signalled - nothing was signalled
#   2  signals were delivered and the outcome could not be established
#   3  signals were delivered and something survived them (FM_WTPROC_SURVIVORS)
FM_WTPROC_REAPED=
FM_WTPROC_SURVIVORS=
fm_wtproc_reap() {  # <label> <spare> <dir>...
  local label=$1 spare=$2 pid identity i reaped=""
  local -a sel_pids sel_ids left_pids left_ids survivors
  shift 2
  FM_WTPROC_REAPED=
  FM_WTPROC_SURVIVORS=
  # The selection globals are reset here as well as inside fm_wtproc_select,
  # because the paths below return before the selector ever runs - a scan that
  # failed, a copy with nothing in it - and a caller quoting them afterwards
  # must never be handed a previous copy's held-back shell or leader count.
  FM_WTPROC_SELECTED=
  FM_WTPROC_SPARED_LEADERS=0
  FM_WTPROC_SPARED_ANCESTORS=0
  # shellcheck disable=SC2034 # Consumed by sourcing callers.
  FM_WTPROC_SPARED_ENDPOINT=
  # A reap observes the machine again between every pass, so it never reads a
  # listing some outer report is holding: whatever a caller snapshotted, this
  # drops it.
  fm_wtproc_snapshot_end
  if ! fm_wtproc_collect "$@"; then
    echo "fm-worktree-proc: cannot determine the $label processes under ${FM_WTPROC_FAILED_ROOT:-<missing>} on this host (no readable /proc and no lsof); nothing was signalled" >&2
    return 1
  fi
  [ -n "$FM_WTPROC_PIDS" ] || return 0
  fm_wtproc_select "$spare"
  if [ "$FM_WTPROC_SPARED_LEADERS" -gt 0 ]; then
    echo "fm-worktree-proc: $FM_WTPROC_SPARED_LEADERS session leader(s) in ${*} were left alone because the endpoint's own shell could not be identified from the task record; inspect them by hand rather than assuming the copy is clean" >&2
  fi
  if [ "$FM_WTPROC_SPARED_ANCESTORS" -gt 0 ]; then
    echo "fm-worktree-proc: $FM_WTPROC_SPARED_ANCESTORS process(es) in ${*} are this cleanup's own ancestors - it was started from inside the copy - and were left alone" >&2
  fi
  sel_pids=()
  sel_ids=()
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    identity=$(fm_pid_identity "$pid") || continue
    sel_pids+=("$pid")
    sel_ids+=("$identity")
  done <<EOF
$FM_WTPROC_SELECTED
EOF
  [ "${#sel_pids[@]}" -gt 0 ] || return 0
  echo "fm-worktree-proc: stopping $label process(es) left in ${*}: ${sel_pids[*]}" >&2
  fm_wtproc_collect "$@" || {
    echo "fm-worktree-proc: the $label processes under ${FM_WTPROC_FAILED_ROOT:-<missing>} stopped being listable between selecting them and signalling them; nothing was signalled" >&2
    return 1
  }
  for i in "${!sel_pids[@]}"; do
    pid=${sel_pids[$i]}
    if _fm_wtproc_contains "$FM_WTPROC_PIDS" "$pid" \
       && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${sel_ids[$i]}" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      reaped="$reaped $pid"
    fi
  done
  FM_WTPROC_REAPED=${reaped# }
  # Past this point something HAS been signalled, so a scan that cannot answer
  # any more leaves those processes in an unknown state rather than an untouched
  # one; 2, never 1.
  [ -n "$FM_WTPROC_REAPED" ] || return 0
  sleep "$FM_WTPROC_GRACE"
  fm_wtproc_collect "$@" || {
    echo "fm-worktree-proc: the $label processes under ${FM_WTPROC_FAILED_ROOT:-<missing>} could not be re-checked after they were signalled; ${FM_WTPROC_REAPED} were sent TERM and their fate is unknown" >&2
    return 2
  }
  left_pids=()
  left_ids=()
  for i in "${!sel_pids[@]}"; do
    pid=${sel_pids[$i]}
    if _fm_wtproc_contains "$FM_WTPROC_PIDS" "$pid" \
       && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${sel_ids[$i]}" ]; then
      left_pids+=("$pid")
      left_ids+=("${sel_ids[$i]}")
    fi
  done
  if [ "${#left_pids[@]}" -eq 0 ]; then
    printf '%s\n' "$FM_WTPROC_REAPED"
    return 0
  fi
  echo "fm-worktree-proc: force-stopping $label process(es): ${left_pids[*]}" >&2
  fm_wtproc_collect "$@" || {
    echo "fm-worktree-proc: the $label processes under ${FM_WTPROC_FAILED_ROOT:-<missing>} could not be re-checked before the force-stop; ${left_pids[*]} survived TERM and their fate is unknown" >&2
    return 2
  }
  for i in "${!left_pids[@]}"; do
    pid=${left_pids[$i]}
    if _fm_wtproc_contains "$FM_WTPROC_PIDS" "$pid" \
       && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${left_ids[$i]}" ]; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  # A KILL is not a receipt. A process wedged in an uninterruptible wait - the
  # socket-heavy shape of the 2026-08-27 incident - stays on the process table
  # after it, and reporting "stopped" for one of those tells an operator a leak
  # is cleaned when it is still burning the host. Re-collect and say so.
  sleep "$FM_WTPROC_KILL_SETTLE"
  fm_wtproc_collect "$@" || {
    echo "fm-worktree-proc: the $label processes under ${FM_WTPROC_FAILED_ROOT:-<missing>} could not be re-checked after the force-stop; ${left_pids[*]} were sent KILL and their fate is unknown" >&2
    return 2
  }
  survivors=()
  for i in "${!left_pids[@]}"; do
    pid=${left_pids[$i]}
    if _fm_wtproc_contains "$FM_WTPROC_PIDS" "$pid" \
       && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${left_ids[$i]}" ]; then
      survivors+=("$pid")
    fi
  done
  printf '%s\n' "$FM_WTPROC_REAPED"
  [ "${#survivors[@]}" -eq 0 ] || {
    # shellcheck disable=SC2034 # Consumed by sourcing callers (bin/fm-control.sh, bin/fm-orphan-reap.sh).
    FM_WTPROC_SURVIVORS="${survivors[*]}"
    echo "fm-worktree-proc: $label process(es) still running after being force-stopped: ${survivors[*]}" >&2
    return 3
  }
  return 0
}
