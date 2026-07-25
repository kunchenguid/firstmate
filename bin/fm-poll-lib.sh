# shellcheck shell=bash
# The decision logic behind a task's armed PR/MR poll.
# Usage: . bin/fm-poll-lib.sh ; fm_poll_run <state-dir> <task-id> [pr-url]
#
# Two callers reach it. bin/fm-poll-extra.sh, which today's polls run beside the
# byte-static bin/fm-pr-poll.sh, uses the pieces below and owns how the questions
# are split between the two files. fm_poll_run is the whole cycle in one call,
# which is what bin/fm-scm-lib.sh's legacy shim needs to upgrade a poll generated
# before this library existed.
#
# Why the logic lives in a library instead of the generated poll:
# bin/fm-pr-check.sh WRITES state/<id>.check.sh when a PR is recorded, so
# anything inlined into that file is frozen at the version that armed it. A poll
# armed on 2026-07-17 was still running the judgement of that day weeks later and
# could never see a signal added afterwards, while a poll armed the day that
# signal landed did. The generated file therefore keeps only per-task parameters
# and one call; every judgement lives here, is read from disk on each poll, and
# so reaches polls armed long before it was written.
#
# What the poll asks: only what firstmate must act on as the orchestration layer.
# It runs no validation of its own - the no-mistakes watch run already reviews
# CI, review threads, approval, and mergeability - so it asks three questions and
# prints at most one line:
#   1. has the PR/MR merged?                 -> "merged"
#   2. has THIS task's watch run parked?     -> "watch parked: ..."
#   3. is THIS task's watch run still alive? -> "watch gone: ..."
# The watcher's check contract is unchanged: output = wake firstmate, silence =
# keep sleeping. At most one line per poll, because a wake reason is one line; a
# signal not printed this cycle stays pending and prints on the next one.
#
# The one thing it does besides answer: a merge also ENDS this task's watch run,
# because nothing else ever does. fm_poll_end_watch_run owns that reasoning and
# the cost of the only ending verb no-mistakes has.
#
# Run-id scoping is a hard boundary. Both watch questions are answered only for
# the run id state/<id>.meta records as this task's (nm_watch_run=, written by
# bin/fm-nm-watch.sh). The captain runs no-mistakes on their own work outside the
# fleet, and `no-mistakes parked` is a machine-wide record: those runs belong to
# no task, and firstmate must never read, report, or answer them. A task with no
# recorded run id simply has no watch question to ask.
#
# Fail-closed, never silently blind: a lookup that cannot answer (missing
# gh/bytedcli/no-mistakes, revoked auth, a dead daemon, network) counts as a
# consecutive failure, and after FM_CHECK_FAIL_WAKE_AFTER of them the poll wakes
# firstmate once with a diagnostic and records state/<id>.check.error. A poll in
# which every lookup answered resets the count. An unreadable answer is never
# turned into a signal.
#
# State this owns under <state-dir>, all cleaned up by bin/fm-teardown.sh:
#   <id>.check.fails  consecutive lookup failures
#   <id>.check.error  the poll-broken diagnostic was already reported
#   <id>.check.nm     one-shot dedup for the watch signals (run=, parked=, gone=)

# Where the firstmate repo is, for the git-checkout fallback below. Resolved from
# this library's own path when it is sourced, so the poll needs no extra
# parameter and no generated file can bake in a stale one.
if [ -z "${FM_POLL_ROOT:-}" ]; then
  FM_POLL_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
fi

# The provider seam the merge question is answered through. Sourcing it here
# keeps the generated poll to a single source line; the guard tells
# bin/fm-scm-lib.sh's legacy-poll shim that a poll is already in progress, so it
# cannot re-enter this library.
if ! command -v fm_scm_pr_state >/dev/null 2>&1; then
  fm_poll_shim_active=1
  # shellcheck source=bin/fm-scm-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-scm-lib.sh"
fi

# Consecutive lookup failures before the poll reports itself broken.
fm_poll_wake_after() {
  local n=${FM_CHECK_FAIL_WAKE_AFTER:-3}
  case "$n" in ''|0|*[!0-9]*) n=3 ;; esac
  printf '%s\n' "$n"
}

fm_poll_field() {  # <file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Collapse to a single bounded line: a wake reason is one line, and provider or
# no-mistakes text carries newlines, tabs, and paragraphs of finding detail.
fm_poll_one_line() {  # <text> [max]
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -s ' ' | cut -c "1-${2:-240}"
}

# Report the poll as broken exactly once per episode: the marker survives every
# later cycle, so a permanently broken lookup costs one wake rather than one per
# cycle. Ending the episode belongs to whoever owns the cycle - bin/fm-poll-extra.sh
# clears the marker on a cycle in which everything answered.
fm_poll_report_broken() {  # <marker> <detail> <subject>
  local marker=$1 detail=$2 subject=$3
  [ -e "$marker" ] && return 0
  : > "$marker" 2>/dev/null || true
  fm_poll_one_line "poll broken: $detail; merge polling for '$subject' is not running"
}

# Echo a one-line detail when THIS run is parked, nothing when it is not.
# Returns non-zero only when the record could not be read, so an unreadable
# record is never mistaken for "not parked".
#
# `no-mistakes parked` reads <NM_HOME>/parked.json, the durable record, so it
# answers with no daemon in the path - which is the point of this poll existing
# beside the watch run it reports on. It exits 0 when something is parked and 1
# when nothing is, so both are successful reads and anything else is not. The
# record is machine-wide, so the run-id filter below is what keeps the captain's
# own runs out of firstmate's sight.
fm_poll_parked_detail() {  # <run-id>
  local run=$1 nm=${FM_NM_BIN:-no-mistakes} json rc out
  command -v "$nm" >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  json=$("$nm" parked --json 2>/dev/null)
  rc=$?
  case "$rc" in
    0|1) ;;
    *) return 1 ;;
  esac
  [ -n "$json" ] || return 1
  out=$(printf '%s' "$json" | jq -r --arg run "$run" '
    [ .[]? | select(.run == $run) ] as $mine
    | if ($mine | length) == 0 then ""
      else $mine[0] as $p
        | [ ($p.step // "step"), "/", ($p.gate // "gate"),
            (if $p.parked_for then " for " + $p.parked_for else "" end),
            (if (($p.findings // []) | length) > 0
             then ": " + (($p.findings[0].id // "finding") + " - "
                          + (($p.findings[0].description // "") | .[0:120]))
             else "" end) ]
        | join("")
      end' 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  fm_poll_one_line "$out" 160
}

# Echo "alive", "gone|<why>", or nothing when the run's state is not decidable.
# Returns non-zero when the lookup could not answer at all.
#
# `no-mistakes axi status --run <id>` resolves a run by id alone - it answers for
# a run recorded against another repository - so this needs some git checkout to
# run in, not the task's own. A run id that is not on record is the definitive
# gone answer; a status this vocabulary does not know is left undecided rather
# than guessed, because a wrong "gone" makes firstmate re-arm a healthy watch.
fm_poll_watch_state() {  # <run-id> <git-dir>
  local run=$1 dir=$2 nm=${FM_NM_BIN:-no-mistakes} out rc status
  command -v "$nm" >/dev/null 2>&1 || return 1
  out=$(cd "$dir" 2>/dev/null && "$nm" axi status --run "$run" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"not found"*) printf 'gone|no run %s on record\n' "$run"; return 0 ;;
      *) return 1 ;;
    esac
  fi
  status=$(printf '%s\n' "$out" | awk -F': ' '/^[[:space:]]*status:/ { gsub(/"/, "", $2); print $2; exit }')
  [ -n "$status" ] || return 1
  case "$status" in
    running|pending|queued|parked|paused|watching)
      printf 'alive\n'
      ;;
    completed|failed|cancelled|interrupted|aborted|errored|error|timeout|timed_out)
      printf 'gone|run %s is %s\n' "$run" "$status"
      ;;
    *)
      : # An unrecognized status is evidence of nothing; stay silent.
      ;;
  esac
  return 0
}

# First readable git checkout among the task's worktree, its project clone, and
# firstmate's own repo. The watch run outlives crew teardown, so the task's
# worktree is often gone by the time this matters; the firstmate repo is the
# fallback that always exists, and the lookup is by run id either way.
fm_poll_git_dir() {  # <meta>
  local meta=$1 candidate
  for candidate in \
    "$(fm_poll_field "$meta" worktree)" \
    "$(fm_poll_field "$meta" project)" \
    "${FM_POLL_ROOT:-}"; do
    [ -n "$candidate" ] || continue
    [ -d "$candidate" ] || continue
    git -C "$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# End this task's watch run once its PR/MR has landed, so a merge never leaves
# behind a run that nothing will ever finish. Silent and best effort, always.
#
# Nothing ends an external watch on its own. The daemon parks it on the first
# thing that needs a person - an unresolved review thread, or checks green and
# waiting for approval - and a parked run stops polling, so the merge it was
# waiting for never reaches it. Three direct-PR tasks landed here on 2026-07-24
# and 2026-07-25 with their watch runs still on the books (01KY80J684V29V81BM43M618ZF,
# 01KY96ZNA6D9Q7HCCXFG8HECPR, 01KYBZVKTD5PBAEV4GBY1ZX59W); no-mistakes' own
# records show all three still at pr_state=open, parked for up to 36 hours,
# each ended by hand in the end. Until then each one blocked bin/fm-teardown.sh,
# which refuses to delete the meta that names a live run.
#
# `axi abort --run <id>` is the only ending verb no-mistakes has - there is no
# complete and no finish - so a watch whose PR landed is recorded as
# "cancelled: aborted by user" with its watch step failed. That mislabels a
# watch that did its job, in no-mistakes' own history, and it is the price of
# ending it at all: a watch run holds no work, edits no code, and no firstmate
# decision reads that history. `axi respond --action approve` would end a parked
# run as completed instead, but it blocks until the next gate or outcome (which
# one check's timeout cannot afford), it has nothing to answer when the run
# never parked, and approving a finding nobody read would claim a review that
# did not happen.
#
# Scoped to the run id state/<id>.meta records as this task's, exactly like every
# other watch question here: `no-mistakes` records are machine-wide, and the
# captain's own runs are never firstmate's to touch.
#
# Idempotent by the CLI's own contract: aborting a run that already ended prints
# "aborted: false ... no active run with that id (no-op)" and exits 0, leaving
# the record alone. Verified 2026-07-25 against no-mistakes 60d5741.
#
# Bounded where a timeout binary exists, because the whole check shares one
# FM_CHECK_TIMEOUT with the provider lookup that just ran. Where none exists -
# stock macOS has neither timeout nor gtimeout - the bound is the watcher's own
# per-check watchdog, and being killed by it costs the poll nothing: the merge
# answer is already on disk by then, because bash flushes stdout before forking
# a child. Verified 2026-07-25 on this machine by running a poll-shaped script
# under bin/fm-watch.sh's own perl watchdog: killed at 2s of a 30s child, exit
# 124, and the captured output was still exactly "merged".
#
# Returns non-zero when the run could not be ended. Only bin/fm-teardown.sh's
# backstop acts on that; the poll prints nothing either way, because a failure
# here must never become a wake and the merge answer is already given.
fm_poll_end_watch_run() {  # <meta>
  local meta=$1 run nm dir secs runner out rc
  nm=${FM_NM_BIN:-no-mistakes}
  run=$(fm_poll_field "$meta" nm_watch_run)
  [ -n "$run" ] || return 0
  command -v "$nm" >/dev/null 2>&1 || return 1
  dir=$(fm_poll_git_dir "$meta") || return 1
  secs=${FM_POLL_NM_TIMEOUT_SECS:-10}
  case "$secs" in ''|0|*[!0-9]*) secs=10 ;; esac
  runner=
  if command -v timeout >/dev/null 2>&1; then
    runner=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    runner=gtimeout
  fi
  rc=0
  if [ -n "$runner" ]; then
    out=$(cd "$dir" && "$runner" "$secs" "$nm" axi abort --run "$run" 2>&1) || rc=$?
  else
    out=$(cd "$dir" && "$nm" axi abort --run "$run" 2>&1) || rc=$?
  fi
  [ "$rc" -eq 0 ] || return 1
  case "$out" in
    *'aborted: true'*|*'no active run with that id'*) return 0 ;;
  esac
  return 1
}

# Echo at most one watch-run signal line, and return non-zero when a lookup could
# not answer. Each signal is one-shot: it fires when the condition first appears
# and stays quiet until the condition clears or the task's run id changes, so a
# park nobody has answered yet costs one wake rather than one per poll. A lookup
# that failed leaves its own one-shot untouched, so a transient outage cannot
# make an already-reported condition report itself again.
fm_poll_watch_signals() {  # <meta> <run-id> <nm-file>
  local meta=$1 run=$2 nmfile=$3
  local prev_run parked_flag gone_flag parked watch ok=1 line='' dir
  prev_run=$(fm_poll_field "$nmfile" run)
  parked_flag=$(fm_poll_field "$nmfile" parked)
  gone_flag=$(fm_poll_field "$nmfile" gone)
  if [ "$prev_run" != "$run" ]; then
    parked_flag=0
    gone_flag=0
  fi

  if parked=$(fm_poll_parked_detail "$run"); then
    if [ -n "$parked" ]; then
      if [ "$parked_flag" != 1 ]; then
        line="watch parked: no-mistakes run $run parked at $parked (answer it, then re-arm with bin/fm-nm-watch.sh; details: no-mistakes parked)"
      fi
      parked_flag=1
    else
      parked_flag=0
    fi
  else
    ok=0
  fi

  if dir=$(fm_poll_git_dir "$meta") && watch=$(fm_poll_watch_state "$run" "$dir"); then
    case "$watch" in
      gone\|*)
        if [ "$gone_flag" != 1 ] && [ -z "$line" ]; then
          line="watch gone: this task's PR is no longer watched (${watch#gone|}); re-arm with bin/fm-nm-watch.sh while the PR is open"
        fi
        gone_flag=1
        ;;
      alive)
        gone_flag=0
        ;;
    esac
  else
    ok=0
  fi

  printf 'run=%s\nparked=%s\ngone=%s\n' "$run" "$parked_flag" "$gone_flag" > "$nmfile" 2>/dev/null || true
  if [ -n "$line" ]; then
    fm_poll_one_line "$line"
  fi
  [ "$ok" = 1 ]
}

# One poll cycle. Prints at most one line and always returns 0: the watcher reads
# the output, not the exit status.
fm_poll_run() {  # <state-dir> <task-id> [pr-url]
  local state=$1 id=$2 url=${3:-}
  local meta="$state/$id.meta"
  local marker="$state/$id.check.error"
  local failfile="$state/$id.check.fails"
  local nmfile="$state/$id.check.nm"
  local fails ok=1 signal='' prstate run

  [ -n "$url" ] || url=$(fm_poll_field "$meta" pr)
  if [ -z "$url" ]; then
    fm_poll_report_broken "$marker" "no PR/MR URL recorded for task $id" "$id"
    return 0
  fi

  # Count the attempt BEFORE any lookup, so a poll the watcher kills at its
  # timeout still leaves the evidence that it never answered.
  fails=$(cat "$failfile" 2>/dev/null || true)
  case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
  fails=$((fails + 1))
  printf '%s\n' "$fails" > "$failfile" 2>/dev/null || true

  if prstate=$(fm_scm_pr_state "" "$url" 2>/dev/null); then
    case "$prstate" in
      MERGED|merged)
        # Landing ends the task's whole monitoring story: no watch question
        # outlives it, so the one-shot state goes with the failure count - and
        # the watch run itself goes with them, because nothing else ever ends
        # it (fm_poll_end_watch_run owns why). The merge answer is printed
        # first, so an ending that fails or times out cannot delay or colour it.
        rm -f "$failfile" "$nmfile"
        echo "merged"
        fm_poll_end_watch_run "$meta" || true
        return 0
        ;;
    esac
  else
    ok=0
  fi

  run=$(fm_poll_field "$meta" nm_watch_run)
  if [ -n "$run" ]; then
    signal=$(fm_poll_watch_signals "$meta" "$run" "$nmfile") || ok=0
  fi

  if [ "$ok" = 1 ]; then
    rm -f "$failfile"
  fi

  if [ -n "$signal" ]; then
    printf '%s\n' "$signal"
    return 0
  fi

  # Only a cycle in which something failed to answer can be a broken poll: the
  # count is of CONSECUTIVE failures, and this cycle answering resets it.
  if [ "$ok" != 1 ] && [ "$fails" -ge "$(fm_poll_wake_after)" ]; then
    fm_poll_report_broken "$marker" \
      "cannot read the PR/MR or its watch run after $fails consecutive lookup failures (check gh/bytedcli auth and no-mistakes)" \
      "$url"
  fi
  return 0
}
