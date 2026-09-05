#!/usr/bin/env bash
# fm-orphan-reap.sh - find, and on an explicit instruction stop, the processes
# still running in the local copy of a task whose agent is gone.
#
# Usage:
#   fm-orphan-reap.sh scan [--task <id>]
#   fm-orphan-reap.sh reap <task-id>
#
# THE GAP THIS CLOSES. bin/fm-teardown.sh stops a task's processes, but it only
# runs on a deliberate cleanup. When the agent dies on its own - quota exhausted,
# harness crash, terminal closed - nobody comes back for the copy, and whatever
# it was running keeps running. Observed 2026-08-27: a server started at 00:50
# outlived the agent that started it (stopped 02:06) by eight and a half hours
# and took the host to 97% CPU, 90.6% of it system time, through 1460 accumulated
# proxied connections; stopping that one process took the load from 98 to 22 and
# system time from 90.6% to 3.9%. The day before, 41 processes of the same shape
# were found alive and stopped by hand.
#
# WHY `scan` REPORTS INSTEAD OF STOPPING. `reap` exists, but nothing calls it
# automatically, and that is the design, not an omission:
#
#   - The verdict rests on reading a worker as gone, and that reading can be
#     wrong: for several harnesses the endpoint classifier reads a
#     vendor-rendered surface, and one was observed on 2026-08-27 reporting
#     `dead` for a worker that was running. A wrong verdict would stop that
#     worker's own server in the middle of its run. The gate below makes two
#     independent sources agree, which is why this is safe enough to REPORT -
#     but agreement between two readings is still weaker than what
#     bin/fm-control.sh's relaunch normally has, where the agent was COMMANDED
#     to stop and the stop was watched happening.
#   - A dead agent's copy is exactly where firstmate or the captain looks after a
#     failure, and a captain working directly in a crewmate's window is
#     authoritative (AGENTS.md hard rule 4). An unattended sweep races that.
#   - The harm is cumulative, not instantaneous. The incident above needed eight
#     and a half hours to saturate the host. Acting on a reported orphan within a
#     supervision cycle is fast enough; automating it buys minutes and costs a
#     whole new class of failure.
#   - Every case where ownerless is a FACT is already automatic: a replaced
#     incarnation (bin/fm-control.sh relaunch) and a completed task
#     (bin/fm-teardown.sh). What is left here is the case that needs judgement,
#     and judgement is firstmate's.
#
# The asymmetry decides it: a missed leftover costs CPU in a disposable copy,
# while a wrong stop costs a live worker its run.
#
# SAFETY BOUNDARIES, all enforced here and in bin/fm-worktree-proc-lib.sh:
#   - Attribution is the process's real working directory, read from /proc, and
#     nothing else. No command name is ever matched.
#   - The copy must prove itself a linked git worktree that is not a primary
#     checkout, so no clone anyone works in directly can ever be a target.
#   - Only a task recorded here as a ship or scout qualifies; a secondmate's
#     recorded worktree is its firstmate home.
#   - The agent must read positively dead or missing AND the task's current
#     state must agree, from a second, independent source. A backend classifier
#     was observed calling a running worker dead, so neither source decides
#     alone. Only `done` and `failed` agree: an undetermined reading is the
#     second source declining to answer, and a stale record pointing at a copy
#     since handed to a live task reads exactly that way. Such a copy is
#     reported as UNDETERMINED and a reap of it is refused.
#   - `alive` is the only reading that means a living owner, and the only one
#     this command will describe that way. A reading of `ambiguous`,
#     `unreadable`, or a failed classifier call is the FIRST source declining to
#     answer about THIS task, so such a copy is reported as UNDETERMINED and
#     refused, rather than reported clean: a copy nobody could establish an
#     owner for is not a copy known to have one.
#   - `unverified` is different in kind and is treated differently. It is what a
#     backend with no recovery classifier answers for every task under it, live
#     or dead, so it carries no information about the copy at all. Such a copy
#     raises NO alert - alerting on every healthy task at every session start
#     would bury the leaks this exists to surface - while a reap of it is still
#     refused. Not alerting and not authorising a stop are independent.
#   - The same split runs through the SECOND source. A current state of
#     `unknown` or `unreadable` is the reader failing to answer for this task
#     and is reported; `no-reader` is this installation carrying no reader at
#     all, answers identically for every task, and raises no alert. Neither
#     licenses a stop.
#   - The shell of the task's OWN recorded endpoint is spared, so a copy stays
#     relaunchable - identified from that record (the backend's pane pid) and
#     never inferred from a process's own shape. A session leader that is not
#     that shell is an ordinary leftover: the process that saturated the host on
#     2026-08-27 was reparented to init, and a rule that spared every session
#     leader would have missed exactly it.
#   - When the record cannot yield that pid, nothing is guessed: every session
#     leader is left alone and the report SAYS how many, because a silently
#     empty result would read as "this copy is clean".
#   - An unreadable /proc/<pid>/cwd means the process is left alone.
#   - This command's own ancestor chain is held back too, so a sweep started
#     from a shell sitting inside the copy never signals the terminal the
#     operator is typing in.
#   - A root that was not examined AT ALL is reported as UNSCANNABLE and makes
#     the scan exit non-zero, whether this host could not list it or the record
#     naming it was refused. "I could not look" is never reported as "I looked
#     and found nothing", because the only reader of an empty result - the
#     session-start digest - would print "(none)" for a fleet nobody examined.
#   - Processes only. This script never removes a file, never touches git, and
#     never tears a copy down.
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-worktree-proc-lib.sh
. "$SCRIPT_DIR/fm-worktree-proc-lib.sh"

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

# Resolve the roots this task's processes may legitimately be attributed to.
# Prints them one per line; a task that cannot qualify prints nothing and
# returns 1, with the reason on stderr only when <verbose> is 1.
#
# A recorded temp root that validation REFUSES is not silently dropped. Doing so
# would narrow the scan to fewer roots than the record names while leaving the
# report unchanged, so a copy with an unexamined root would read exactly like a
# clean one - the same silent degradation the UNSCANNABLE line exists to remove,
# reached through a refused root instead of an unproducible listing. It is
# reported back to the caller on the two `!tmp-refused-*` marker lines, which
# travel on stdout because this function is read through a pipe and a global set
# in that subshell would never reach the caller. Absolute roots start with `/`,
# so no real root can be mistaken for a marker.
task_roots() {  # <task-id> <meta> <verbose>
  local id=$1 meta=$2 verbose=$3 kind wt tmp wt_out tmp_out tmp_rc reason owner_token
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    ship|scout) ;;
    *)
      [ "$verbose" = 1 ] && echo "task $id is recorded as $kind; its local copy is not a disposable task copy" >&2
      return 1
      ;;
  esac
  wt=$(fm_meta_get "$meta" worktree)
  # The allocation token this task's spawn minted and stamped into both roots.
  # A record without one names roots that predate this binding, and nothing in
  # them can be shown to be this task's, so the validators below refuse them.
  owner_token=$(fm_meta_get "$meta" owner_token)
  # One call, not two. On success this validator prints the resolved path and
  # nothing else; on refusal it prints only its reason. So the single capture
  # that would have carried the path carries the diagnostic instead - the same
  # shape the temp root below already uses. Re-running it purely to reproduce
  # that reason on stderr repeated the whole validation, several git
  # invocations, for every refused copy in a fleet-wide sweep, and reported the
  # reason from a SECOND reading that need not agree with the first that
  # actually decided.
  if ! wt_out=$(fm_wtproc_disposable_worktree "$wt" "$FM_HOME" "$id" "$owner_token" 2>&1); then
    if [ "$verbose" = 1 ]; then
      echo "task $id: recorded local copy '$wt' was refused, so it was NOT examined: ${wt_out:-the local-copy check refused it without stating a reason; inspect that path by hand}" >&2
    fi
    return 1
  fi
  printf '%s\n' "$wt_out"
  tmp=$(fm_meta_get "$meta" tasktmp)
  [ -n "$tmp" ] || return 0
  # Three outcomes, not two. On success fm_wtproc_task_tmp prints the resolved
  # path and nothing else; on refusal it prints only its reason, so one capture
  # carries both; and status 2 means the path simply is not there.
  tmp_rc=0
  tmp_out=$(fm_wtproc_task_tmp "$id" "$tmp" "$FM_HOME" "$owner_token" 2>&1) || tmp_rc=$?
  case "$tmp_rc" in
    0)
      printf '%s\n' "$tmp_out"
      return 0
      ;;
    2)
      # ABSENT, and that is not the same fact as UNEXAMINABLE. Nothing exists at
      # that path, so there is nothing running in it and nothing an operator
      # could inspect - the scan is not covering less than the record claims,
      # it is covering everything the record actually points at. Reporting it
      # as a root that cannot be called clean was an alarm with nothing behind
      # it, and it fired on every scan for as long as the stale path stayed in
      # the record.
      [ "$verbose" = 1 ] && echo "task $id: recorded temp root '$tmp' does not exist, so there is nothing in it to examine" >&2
      return 0
      ;;
  esac
  # Every refusing path in the validator states a reason. The fallback below is
  # a backstop for a future one that forgets to, and it still says something an
  # operator can act on rather than filling the line with "no reason".
  reason=${tmp_out:-the temp-root check refused it without stating a reason; inspect that path by hand}
  printf '!tmp-refused-path %s\n' "$tmp"
  printf '!tmp-refused-reason %s\n' "$reason"
  if [ "$verbose" = 1 ]; then
    echo "task $id's recorded temp root '$tmp' was refused, so it was NOT examined: $reason" >&2
  fi
  return 0
}

# The pid of the shell this task's OWN endpoint runs, read from the record, or
# `unknown` when the backend cannot answer for it. `unknown` is not a failure to
# report - it is the instruction to hold every session leader back and name how
# many, rather than risk a working agent's shell on a guess.
endpoint_shell_spare() {  # <meta>
  local backend target window pid
  window=$(fm_meta_get "$1" window)
  backend=$(fm_backend_of_meta "$1")
  target=$(fm_backend_target_of_meta "$1")
  pid=$(fm_wtproc_endpoint_shell_pid "$backend" "${target:-$window}" 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  printf '%s' "$pid"
}

# The agent's own verdict, from the backend's classifier. Only dead and missing
# mean the copy has no living owner.
agent_verdict() {  # <meta>
  local backend target window
  window=$(fm_meta_get "$1" window)
  [ -n "$window" ] || { printf 'missing'; return 0; }
  backend=$(fm_backend_of_meta "$1")
  target=$(fm_backend_target_of_meta "$1")
  fm_backend_agent_state "$backend" "${target:-$window}" 2>/dev/null || printf 'unknown'
}

# Listening ports held by these pids, as supporting evidence for the report.
# Best-effort and never part of any decision: ss is not everywhere, and a
# process holding no socket is exactly as much of a leftover as one that does.
listening_ports() {  # <pid>...
  local pids=" $* " out
  command -v ss >/dev/null 2>&1 || return 0
  out=$(ss -H -tlnp 2>/dev/null) || return 0
  printf '%s\n' "$out" | awk -v pids="$pids" '
    {
      port = $4
      sub(/.*:/, "", port)
      while (match($0, /pid=[0-9]+/)) {
        p = substr($0, RSTART + 4, RLENGTH - 4)
        if (index(pids, " " p " ") > 0 && !(port in seen)) { seen[port] = 1; list = list (list ? "," : "") port }
        $0 = substr($0, RSTART + RLENGTH)
      }
    }
    END { if (list) print list }
  '
}

# scan_task answers with four different facts, and they may never be folded
# into one:
#   0  something is reported on stdout (LEFTOVER, UNRESOLVED, UNSCANNABLE)
#   1  this copy was looked at and has nothing to report
#   3  this copy could NOT be looked at, so it is not known to be clean
#   4  the copy is reported (UNDETERMINED) but its owner could not be
#      established, so it is for an operator to judge and never for a reap -
#      whether processes were selected in it or every one of them was held back
#   5  no instrument on this installation can answer for this copy in either
#      direction: the backend carries no agent classifier, or this home carries
#      no current-state reader. Both answer the same way for every task under
#      them, live and dead alike, so neither says anything about THIS copy.
#      Nothing is reported - alerting every session would bury the real ones -
#      and a reap is still refused
#
# SCAN_UNEXAMINED is set alongside them when SOME recorded root was not looked
# at while the rest were, which the status alone cannot carry: that copy has an
# UNSCANNABLE line of its own and callers must not present it as fully examined.
scan_task() {  # <task-id> <verbose>
  local id=$1 verbose=$2 meta verdict pids ports line spare skipped note reason
  local undetermined=0 undetermined_why="" label refused_path="" refused_reason=""
  local -a roots=()
  # EVERY global this function publishes is reset here, not just the two the
  # early returns happened to reach. scan_task returns from a dozen places -
  # no record, a copy that cannot qualify, an unlistable root, a living owner -
  # and all but two of these were left holding the PREVIOUS task's values on
  # each of them. In the fleet-wide sweep that means a copy that returned early
  # was described by whatever the last examined copy had set: another task's
  # pids, its verdict, its held-back shell. Nothing read them across tasks
  # today, which is exactly why this had to be fixed before something did.
  SCAN_ROOTS=()
  SCAN_PIDS=
  SCAN_VERDICT=
  SCAN_SPARE=unknown
  SCAN_SKIPPED_LEADERS=0
  SCAN_UNSCANNABLE_ROOT=
  SCAN_REFUSED_ROOT=
  SCAN_UNDETERMINED_WHY=
  SCAN_UNEXAMINED=0
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || {
    [ "$verbose" = 1 ] && echo "no durable record for task $id in $STATE" >&2
    return 1
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      '!tmp-refused-path '*) refused_path=${line#'!tmp-refused-path '}; continue ;;
      '!tmp-refused-reason '*) refused_reason=${line#'!tmp-refused-reason '}; continue ;;
    esac
    # Only an absolute path resolved by a validator is ever a root. Anything
    # else on this stream is a diagnostic that grew a newline, and a scan root
    # is the last place to be lenient about what it accepts.
    case "$line" in /*) ;; *) continue ;; esac
    roots+=("$line")
  done < <(task_roots "$id" "$meta" "$verbose" || true)
  # Reported on its own line, ahead of anything the remaining roots yield: a
  # root the record names and validation refuses was NOT examined, and that is a
  # fact about the copy whether or not the roots that WERE examined turn out to
  # hold anything.
  if [ -n "$refused_path" ]; then
    SCAN_REFUSED_ROOT=$refused_path
    SCAN_UNEXAMINED=1
    printf 'UNSCANNABLE: %s copy=%s (%s, so this recorded root was NOT checked and cannot be called clean; correct the record or inspect it by hand)\n' \
      "$id" "$refused_path" "${refused_reason:-the temp-root check refused it without stating a reason}"
  fi
  [ "${#roots[@]}" -gt 0 ] || return 1
  # Cheapest question first: an empty copy needs no backend call at all, so a
  # healthy fleet costs one /proc pass per copy and nothing else.
  #
  # A copy this host cannot list is REPORTED, never dropped. "I looked and found
  # nothing" and "I could not look" are different facts about the machine, and
  # an operator reading the session-start digest acts on them differently; a
  # scan that quietly returned nothing here would print "(none)" for a fleet it
  # never examined, which is the exact silent degradation this whole mechanism
  # exists to remove.
  fm_wtproc_collect "${roots[@]}" || {
    SCAN_UNSCANNABLE_ROOT=${FM_WTPROC_FAILED_ROOT:-${roots[0]}}
    if [ "$_FM_WTPROC_RESOLVER" = none ]; then
      reason="this host can answer from neither /proc (${FM_PROC_ROOT_OVERRIDE:-/proc}) nor lsof"
    else
      reason="the working-directory scan of that root failed"
    fi
    printf 'UNSCANNABLE: %s copy=%s (%s, so this copy was NOT checked and cannot be called clean; inspect it by hand)\n' \
      "$id" "$SCAN_UNSCANNABLE_ROOT" "$reason"
    return 3
  }
  [ -n "$FM_WTPROC_PIDS" ] || return 1
  verdict=$(agent_verdict "$meta")
  case "$verdict" in
    alive)
      # The ONE positive reading of a living owner, and the only verdict that
      # licenses saying so. These processes belong to a worker that is running.
      [ "$verbose" = 1 ] && echo "task $id's agent reads 'alive'; its processes have a living owner and are left alone" >&2
      return 1
      ;;
    dead|missing) ;;
    unverified)
      # NOT doubt about this task - the absence of a measuring instrument.
      # `unverified` is what fm_backend_agent_state answers for every backend
      # that carries no recovery classifier at all, for a live worker and a
      # dead one alike, so it says nothing whatever about THIS copy. Reporting
      # it would put every healthy task on a zellij, orca, or cmux home into the
      # report at every session start, and a report that cries wolf every
      # session is one people learn to ignore - which costs exactly the leak
      # this mechanism exists to surface. So no alert line is raised.
      #
      # The safety rule is untouched: rc 5 still refuses a reap. Not alerting
      # and not authorising a stop are independent, and only the first changes
      # here.
      [ "$verbose" = 1 ] && echo "task $id runs on a backend with no agent classifier ('$verdict'), so whether its processes have a living owner cannot be established either way; nothing is reported and nothing may be stopped" >&2
      return 5
      ;;
    *)
      # `ambiguous`, `unreadable`, and the local `unknown` this script
      # substitutes when the classifier call itself fails: the classifier CAN
      # answer for this backend and could not answer for this task. That is
      # real doubt about this copy, and it is never a reading that the worker is
      # alive. It used to return the copy as clean while the diagnostic asserted
      # "its processes have a living owner" - an owner the classifier had not
      # given. It is reported under the same UNDETERMINED label an unreadable
      # current state earns, and a reap of it is refused: an operator sees the
      # leak, and only an operator judges it.
      undetermined=1
      undetermined_why="its agent state could not be determined (the classifier answered '$verdict')"
      [ "$verbose" = 1 ] && echo "task $id: $undetermined_why; its processes are reported but never stopped" >&2
      ;;
  esac
  # Two sources have to agree before a copy is called ownerless; see
  # bin/fm-worktree-proc-lib.sh's fm_wtproc_worker_is_gone for the observed
  # misclassification that makes this gate load-bearing.
  # Asked only when the endpoint itself read gone. There is nothing for a second
  # source to corroborate when the first declined to answer, and one source has
  # never been enough to call a copy ownerless.
  if [ "$undetermined" = 0 ] && ! fm_wtproc_worker_is_gone "$id" "$verdict"; then
    # `unknown` is the current-state reader saying it could not determine the
    # state. That is not a second source agreeing the worker is gone, so it
    # never licenses a stop - but it is not a positive reading of a live worker
    # either, and the copy of a torn-off worker commonly reads exactly this
    # way. Reporting it and refusing to act on it are the two halves of the
    # same answer: an operator sees the leak, and only an operator judges it.
    case "${FM_WTPROC_CREW_STATE:-}" in
      unknown|unreadable)
        # The second source was ASKED and could not answer for THIS task -
        # `unknown` from the reader itself, `unreadable` when the call timed
        # out, exited non-zero, or came back empty. Neither is disagreement,
        # and only `unknown` used to be treated that way, so a reader that
        # timed out returned the copy as clean. Real doubt about this copy is
        # reported, exactly as the header of this file has said all along.
        undetermined=1
        undetermined_why="its endpoint reads '$verdict' but its current state could not be determined (the reader answered '${FM_WTPROC_CREW_STATE}')"
        ;;
      no-reader)
        # Not doubt about this copy: this installation carries no current-state
        # reader at all, so it answers the same way for every task under it,
        # live and dead alike. That is the `unverified` case one branch above,
        # and it gets the same treatment for the same reason - alerting on
        # every copy at every session start would bury the leaks this exists to
        # surface. No alert; the stop stays refused.
        [ "$verbose" = 1 ] && echo "task $id: this home carries no current-state reader, so whether its worker is gone cannot be corroborated for any task; nothing is reported and nothing may be stopped" >&2
        return 5
        ;;
      *)
        [ "$verbose" = 1 ] && echo "task $id's endpoint reads '$verdict' but its current state reads '${FM_WTPROC_CREW_STATE:-unreadable}'; the two disagree, so nothing in its local copy is touched" >&2
        return 1
        ;;
    esac
  fi
  # Only now, for a copy that really has no living owner, is it worth asking the
  # backend which shell belongs to the endpoint - and it is asked of the task's
  # own record, so nothing else in the copy inherits that shell's protection.
  spare=$(endpoint_shell_spare "$meta")
  fm_wtproc_select "$spare"
  skipped=$FM_WTPROC_SPARED_LEADERS
  pids=$(printf '%s' "$FM_WTPROC_SELECTED" | tr '\n' ' ')
  pids=${pids% }
  SCAN_ROOTS=("${roots[@]}")
  SCAN_PIDS=$pids
  SCAN_VERDICT=$verdict
  SCAN_SPARE=$spare
  SCAN_SKIPPED_LEADERS=$skipped
  SCAN_UNDETERMINED_WHY=$undetermined_why
  # The label is settled BEFORE the empty-selection branch below. Whether this
  # copy's owner could be established is a fact about the copy, not about
  # whether anything was selected in it, so an undetermined owner has to survive
  # the path where every process was held back - otherwise the one copy a reap
  # must refuse is reported as the one that merely wants a look by hand, and the
  # rc=4 that refuses it never fires.
  label=LEFTOVER
  [ "$undetermined" = 1 ] && label=UNDETERMINED
  if [ -z "$pids" ]; then
    # Never a silent "(none)": leaders held back because the endpoint's shell
    # could not be named are the one case where an empty set is not evidence of
    # a clean copy, and the report has to say so.
    [ "$skipped" -gt 0 ] || return 1
    if [ "$undetermined" = 1 ]; then
      printf 'UNDETERMINED: %s agent=%s copy=%s leaders_skipped=%s (%s, so this copy has no established owner; the endpoint shell could not be identified from the record either, so no session leader in it was classified - inspect them by hand)\n' \
        "$id" "$verdict" "${roots[0]}" "$skipped" "$undetermined_why"
      return 4
    fi
    printf 'UNRESOLVED: %s agent=%s copy=%s leaders_skipped=%s (the endpoint shell could not be identified from the record, so no session leader in this copy was classified; inspect them by hand)\n' \
      "$id" "$verdict" "${roots[0]}" "$skipped"
    return 0
  fi
  # shellcheck disable=SC2086  # pids is a deliberate space-separated list
  ports=$(listening_ports $pids)
  note=""
  [ "$skipped" -gt 0 ] && note=" leaders_skipped=$skipped"
  # The reason travels on the line itself. An operator reading UNDETERMINED has
  # to know WHICH source declined to answer before deciding what to do about
  # the copy, and the label alone no longer says: it now covers an unreadable
  # agent state as well as an unreadable current state.
  [ "$undetermined" = 1 ] && note="$note ($undetermined_why, so nothing here is stopped for you)"
  printf '%s: %s agent=%s copy=%s pids=%s%s%s\n' \
    "$label" "$id" "$verdict" "${roots[0]}" "$(printf '%s' "$pids" | tr ' ' ',')" \
    "${ports:+ listening=$ports}" "$note"
  [ "$undetermined" = 0 ] || return 4
}

cmd_scan() {
  local want="" found=0 unscannable=0 undetermined=0 meta id rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) shift; want=${1:-}; [ -n "$want" ] || die "--task needs a task id" ;;
      *) die "unknown scan argument '$1'" ;;
    esac
    shift
  done
  if [ -n "$want" ]; then
    rc=0
    scan_task "$want" 1 || rc=$?
    case "$rc" in
      0) found=1 ;;
      3) found=1; unscannable=1 ;;
      4) found=1; undetermined=1 ;;
    esac
    if [ "$SCAN_UNEXAMINED" = 1 ]; then found=1; unscannable=1; fi
  else
    # One listing of the machine for the whole sweep: this command signals
    # nothing, so every copy in it may be answered from the same instant, and a
    # fleet-wide report on a saturated host costs one walk rather than one per
    # task. fm_wtproc_reap drops it, so nothing that stops a process ever reads
    # from it.
    fm_wtproc_snapshot_begin
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      rc=0
      scan_task "$id" 0 || rc=$?
      case "$rc" in
        0) found=1 ;;
        3) found=1; unscannable=1 ;;
        4) found=1; undetermined=1 ;;
      esac
      if [ "$SCAN_UNEXAMINED" = 1 ]; then found=1; unscannable=1; fi
    done
    fm_wtproc_snapshot_end
  fi
  [ "$found" = 1 ] || return 0
  echo "Each LEFTOVER line names a local copy whose worker is gone while processes it started are still running."
  echo "An UNRESOLVED line names one where the endpoint's own shell could not be identified from the record, so its session leaders were left unclassified rather than guessed at; inspect those by hand."
  if [ "$undetermined" = 1 ]; then
    echo "An UNDETERMINED line names a copy holding processes whose owner could not be established - its own agent state could not be read, or that state reads gone while its current state could not be read at all - and each line says which; its processes are reported but never stopped for you, because an undetermined reading is not evidence the worker is gone."
  fi
  if [ "$unscannable" = 1 ]; then
    echo "An UNSCANNABLE line names a recorded root that was not examined at all - this host could not list it, or the record naming it was refused - so nothing about it, clean or leaking, was established."
  fi
  echo "Stop one with: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-orphan-reap.sh reap <task-id>"
  # Non-zero so a caller that only reads the status - bin/fm-session-start.sh's
  # digest does - can never present an unexamined fleet as a clean one.
  [ "$unscannable" = 0 ] || return 3
}

cmd_reap() {  # <task-id>
  local id=${1:-} rc=0 scan_rc=0
  [ -n "$id" ] || { usage >&2; exit 2; }
  # scan_task resets every one of these itself, on entry, so the reap reads
  # exactly what this call established and there is no second list here to fall
  # out of step with that one.
  scan_task "$id" 1 >/dev/null || scan_rc=$?
  # Said before any outcome below, including the ones that stop the command: a
  # cleanup that covered fewer roots than the record names has to say so, or a
  # copy with an unexamined root reads afterwards like a fully cleaned one.
  if [ -n "$SCAN_REFUSED_ROOT" ]; then
    echo "warning: task $id's recorded temp root $SCAN_REFUSED_ROOT was refused, so nothing in it was examined or stopped; correct the record or inspect it by hand" >&2
  fi
  case "$scan_rc" in
    0) ;;
    4)
      die "task $id's local copy holds processes whose owner could not be established: ${SCAN_UNDETERMINED_WHY:-the reason was not recorded; read the scan line for this task and inspect the copy by hand}. An undetermined reading is not evidence its worker is gone - it is the same reading a stale record pointing at a copy since handed to a live task produces - so nothing was stopped. Inspect the copy and its processes by hand"
      ;;
    5)
      die "task $id runs on a backend with no agent classifier, so whether its worker is still alive cannot be established at all; a stop needs positive evidence the worker is gone and none can be obtained here. Inspect the copy and its processes by hand"
      ;;
    3)
      # "Nothing to stop" would be a claim about the copy; all that is known
      # here is that the copy could not be read.
      die "the processes in task $id's local copy could not be listed on this host (${SCAN_UNSCANNABLE_ROOT:-its recorded roots} could not be read); nothing was stopped and nothing is known about what is running there"
      ;;
    *)
      echo "nothing to stop for $id"
      return 0
      ;;
  esac
  if [ -z "$SCAN_PIDS" ]; then
    echo "nothing to stop for $id: $SCAN_SKIPPED_LEADERS session leader(s) in its local copy were left alone because its endpoint shell could not be identified from the record; inspect them by hand"
    return 0
  fi
  echo "$id: agent reads '$SCAN_VERDICT'; stopping $(printf '%s' "$SCAN_PIDS" | wc -w) process(es) left in its local copy"
  # Called in this shell rather than a command substitution so the reap's own
  # account of what it signalled and what outlived it survives the call.
  fm_wtproc_reap "$id ownerless" "$SCAN_SPARE" "${SCAN_ROOTS[@]}" >/dev/null || rc=$?
  case "$rc" in
    0) ;;
    2) die "the processes in task $id's local copy were signalled but could not be re-checked afterwards; they are in an unknown state - inspect them before retrying" ;;
    3) die "task $id's local copy still holds ${FM_WTPROC_SURVIVORS// /,} after a force-stop; they did not respond to it and are still running" ;;
    *) die "the processes in task $id's local copy could not be accounted for; nothing was signalled, but inspect them before retrying" ;;
  esac
  if [ -n "$FM_WTPROC_REAPED" ]; then
    echo "stopped $id pids=$(printf '%s' "$FM_WTPROC_REAPED" | tr ' ' ',')"
  else
    echo "nothing to stop for $id"
  fi
}

case "${1:-}" in
  scan) shift; cmd_scan "$@" ;;
  reap) shift; cmd_reap "$@" ;;
  *) usage >&2; exit 2 ;;
esac
