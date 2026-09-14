#!/usr/bin/env bash
# fm-opencode-descent-lib.sh - keep an ALREADY RUNNING opencode worker on the
# free-then-Go ladder.
# Usage: . bin/fm-opencode-descent-lib.sh
# Sourced by bin/fm-watch.sh. Defining functions is all this file does; the
# only things it pulls in on its own are the libraries below, and only when a
# caller has not already loaded them.
#
# THE HALF THE DISPATCH GATE CANNOT COVER. bin/fm-opencode-ladder-lib.sh routes
# the NEXT spawn and never looks at a lane again. A lane that starts on free
# and hits the cap mid-run does not fail: the vendor holds the session in
# `retry` and re-schedules it for hours (the 2026-09-07 twelve-lane stall),
# while supervision reads the lane as working for the whole backoff. This file
# is the re-evaluation the ladder was missing, on the watcher's own cadence,
# against the same cap evidence the dispatch gate uses - and it reuses
# bin/fm-opencode-retry.sh as that detector rather than writing a second one.
#
# THE HINGE QUESTION, ANSWERED WITH EVIDENCE. PR 96 declined to move running
# workers for lack of a verified in-session model switch. Re-verified on
# opencode 1.18.29, that is still true, in both directions:
#
#   - The TUI has an interactive `/models` picker (Select model, Search/Recent
#     rows, esc to close - driven live in a scratch pane with no prompt ever
#     submitted, so zero quota spent). It lists both ladder tiers, so a human
#     can switch mid-session. But it is a rendered picker with no verified
#     walk: row order comes from the account catalogue, and no confirmation
#     signals have been proven. Driving it unsupervised would risk parking a
#     live worker on the wrong model with no proven gain.
#   - Upstream confirms there is no programmatic path either: issue #24006
#     (runtime model switching via plugin API) is closed not_planned, the
#     `chat.params` hook output carries temperature/topP/topK/maxOutputTokens
#     but no model, and the plugin event reference (opencode.ai/docs/plugins,
#     2026-09-08) lists observer-style events plus a per-tool
#     `tool.execute.before` deny - which gates one tool while the loop keeps
#     spending, exactly the insufficiency bin/fm-agy-descent-lib.sh documents
#     for agy's own deny primitive.
#
# So the honest move is not an in-session switch but the verified control-plane
# relaunch: bin/fm-control.sh relaunch --model is transactional, keeps the same
# worktree, branch, commits, and brief, and carries a handoff note because the
# replacement inherits the local copy but none of the conversation. A capped
# lane is parked doing nothing, so ending its session loses no in-flight work
# beyond context the replacement re-derives from the brief and the commits.
# That is a heavier act than agy's conversation-preserving switch, which is
# why every move below is reported as a wake the supervisor sees.
#
# THE TRIGGER IS THE SUPERVISION-GRADE VERDICT, NOT JUST THE SIDECAR. The
# dispatch gate scans sidecars alone; a relaunch destroys a session, so this
# evaluation additionally requires the busy latch bin/fm-crew-state.sh owns:
# the record must read busy, from the opencode plugin, on the latched
# session-retry event. A stale sidecar beside a resumed turn (which writes
# session-busy first) therefore never moves a worker. The composition is
# restated here rather than calling into bin/fm-crew-state.sh because that
# file is a main script with no source guard; both owners it composes -
# bin/fm-busy-lib.sh and bin/fm-opencode-retry.sh - are called, not copied.
#
# WHAT MOVES, AND WHAT ONLY SURFACES. A lane recorded on the free tier with a
# proven cap relaunches onto Go, including when the cap evidence carries no
# model binding - the dispatch gate's own throughput-first bias, with the
# handoff note owning the ambiguity. Three cases surface as `refused` instead:
# a lane recorded on Go (the ladder has no third rung), a secondmate
# (automatic relaunch never touches a persistent supervision agent), and a
# lane recording no model at all (refusing to move blind). Off-ladder models
# are never governed and stay silent. A move the durable record did not follow
# is reported as `unrecorded`, never claimed. Each episode gets exactly one
# automatic attempt: unlike agy's switch, every attempt here stops a live
# worker, so a failed move is surfaced rather than retried, and the refusal
# wake hands the retry to firstmate with full context.
#
# THERE IS NO CLIMB-BACK FOR RUNNING WORKERS, BY DESIGN. A healthy lane on Go
# is making progress; moving it back to free would risk its conversation for
# zero gain, and new spawns already climb back through the dispatch gate the
# moment the vendor's horizon elapses. The descent is one-directional: free
# onto Go, never Go onto free.
#
# THE WATCHER IS THE ONLY DRIVER, AND THAT IS SUFFICIENT. agy needed a
# turn-end driver because a worker inside one long turn keeps spending while
# the watcher waits between firstmate's turns. A capped opencode lane spends
# nothing - the vendor parked it - so there is no spend to race, and a capped
# lane never reaches a turn end that could drive anything. The watcher's poll
# is the only evaluation, rate-limited by FM_OPENCODE_DESCENT_INTERVAL, and it
# costs local file reads only: no quota subprocess exists for opencode.
#
# NO POINT-OF-SPEND GATE EXISTS FOR OPENCODE, AND NONE IS FAKED HERE. agy's
# gate works because agy invokes it PostInvocation inside the worker's own
# loop AND because quota evidence exists to decide on before the floor is
# crossed. opencode has neither half: no hook ends the agent loop (see the
# surface above), and no pre-spend evidence exists anywhere (quota-axi answers
# "unsupported provider"; the Go plan has no public usage API). The retry
# event fires after the refusal, when the vendor has already parked the
# session - gating there would be polling pretending to be synchronous, which
# the brief forbids. This evaluation plus the sidecar detector is the whole
# of the opencode ladder's running-worker enforcement.
#
# THE FAILURE DIRECTION, STATED NOT IMPLIED. A wrong relaunch restarts a
# conversation whose work products (worktree, commits, brief, note) are all
# preserved; a missed cap stalls the lane for roughly a day. This file is
# biased toward relaunching, for the captain's own throughput-first reason.
#
# THE OVERRIDE. FM_OPENCODE_LADDER_OVERRIDE is the launch gate's deliberate
# escape and it is honoured here too: a worker held on free past a proven cap
# on the captain's explicit request is not dragged off it behind their back.
# Its use is printed, exactly as the launch gate prints it. bin/fm-spawn.sh
# records the override per task where this evaluation reads it back, because
# the variable itself never reaches the watcher: the watcher is a long-lived
# process that predates the instruction.
#
# FM_OPENCODE_DESCENT=off disables the whole evaluation, leaving the dispatch
# gate as the only enforcement. In production the off state is filed as
# <state-dir>/.opencode-descent-off, which the watcher reads: the variable
# alone never reaches it, for the same reason. The variable stays as an
# additional source for one-shot runs and the regression suite.
# FM_OPENCODE_DESCENT_CONTROL_BIN overrides the
# control-plane binary the relaunch runs through; production leaves it at the
# default, tests point it at a stub so no real agent is ever stopped.

_FM_OPENCODE_DESCENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_OPENCODE_DESCENT_LIB_DIR="."
if ! declare -f fm_opencode_ladder_model >/dev/null 2>&1; then
  # shellcheck source=bin/fm-opencode-ladder-lib.sh
  . "$_FM_OPENCODE_DESCENT_LIB_DIR/fm-opencode-ladder-lib.sh"
fi
# fm_meta_get lives in the backend library; the watcher loads it before this
# file, so the guarded source below fires only when this file stands alone.
# shellcheck source=/dev/null
if ! declare -f fm_meta_get >/dev/null 2>&1; then
  . "$_FM_OPENCODE_DESCENT_LIB_DIR/fm-backend.sh"
fi
# fm_busy_record_read lives in the busy library, loaded the same way.
# shellcheck source=/dev/null
if ! declare -f fm_busy_record_read >/dev/null 2>&1; then
  . "$_FM_OPENCODE_DESCENT_LIB_DIR/fm-busy-lib.sh"
fi
_FM_OPENCODE_DESCENT_RETRY="$_FM_OPENCODE_DESCENT_LIB_DIR/fm-opencode-retry.sh"
# The control-plane binary the relaunch runs through. Resolved at call time,
# not source time, so a caller (notably a test) may point it at a stub by
# exporting FM_OPENCODE_DESCENT_CONTROL_BIN before the tick runs; production
# leaves it at the default beside this library.
fm_opencode_descent_control() {
  printf '%s' "${FM_OPENCODE_DESCENT_CONTROL_BIN:-$_FM_OPENCODE_DESCENT_LIB_DIR/fm-control.sh}"
}

# FM_OPENCODE_DESCENT: `off` disables the whole evaluation, leaving the
# dispatch gate as the only enforcement.
FM_OPENCODE_DESCENT=${FM_OPENCODE_DESCENT:-on}

# FM_OPENCODE_DESCENT_INTERVAL: seconds between evaluations. Evidence is local
# sidecars, so the cost is file reads; a minute matches the agy descent while
# keeping the relaunch decision off every watcher poll.
FM_OPENCODE_DESCENT_INTERVAL=${FM_OPENCODE_DESCENT_INTERVAL:-60}

# fm_opencode_descent_wake_reason: the supervision wake one outcome line
# becomes. One owner for the wording, because the watcher publishes it and
# firstmate reads it; a supervisor should not need the tick to explain
# itself twice.
fm_opencode_descent_wake_reason() {  # <outcome-line>
  printf 'check: opencode ladder %s' "$1"
}

fm_opencode_descent_mark() {  # <state-dir> <name>
  printf '%s' "$1/.opencode-descent-$2"
}

# fm_opencode_descent_escalate_once: 0 the first time a task needs escalating
# in this cap episode, 1 afterwards. The episode is identified by the vendor's
# own scheduled-retry timestamp (<next>): the same refusal re-observed is the
# same episode, while fresh refusal evidence carries a new timestamp and
# re-arms both the report and the single automatic attempt. A lane that stops
# meeting the trigger clears the marker outright. Without this a refusal would
# wake the captain once a minute for as long as the condition lasted.
fm_opencode_descent_escalate_once() {  # <state-dir> <id> <next>
  local marker prev
  marker=$(fm_opencode_descent_mark "$1" "escalated-$2")
  prev=$(cat "$marker" 2>/dev/null || true)
  if [ "$prev" = "$3" ] && [ -n "$3" ]; then
    return 1
  fi
  printf '%s' "$3" > "$marker" 2>/dev/null || true
  return 0
}

# fm_opencode_descent_off_path: the filed descent off-switch for <state-dir>.
# Existence is the signal, exactly as with the escalated- markers below; see
# the FM_OPENCODE_DESCENT comment for why the production off state lives here
# rather than in the environment.
fm_opencode_descent_off_path() {  # <state-dir>
  printf '%s/.opencode-descent-off' "$1"
}

# fm_opencode_descent_off: 0 when the descent evaluation is turned off for
# <state-dir>, by the filed record the watcher reads or by the variable only
# a manual run inherits. The caller already takes <state-dir>, so this costs
# one file test on the decision path and no new plumbing.
fm_opencode_descent_off() {  # <state-dir>
  [ "${FM_OPENCODE_DESCENT:-on}" = off ] && return 0
  [ -f "$(fm_opencode_descent_off_path "$1")" ]
}

# fm_opencode_pin_mark: the recorded deliberate placement of <id>. The content
# is the reason firstmate placed it there.
fm_opencode_pin_mark() {  # <state-dir> <id>
  printf '%s/.opencode-pin-%s' "$1" "$2"
}

# fm_opencode_pin_task: pin <id> where firstmate deliberately put it, for
# <reason>. bin/fm-spawn.sh records this when FM_OPENCODE_LADDER_OVERRIDE
# holds a launch on free past a proven cap; the tick reads it back instead of
# a variable it cannot see. A pin is not drift, so the tick moves a pinned
# worker nowhere. Per task, not per home: the hold names one lane the captain
# placed, and a home-wide file would freeze every lane on free past its cap,
# including lanes the captain never asked about.
fm_opencode_pin_task() {  # <state-dir> <id> <reason>
  printf '%s' "$3" > "$(fm_opencode_pin_mark "$1" "$2")" 2>/dev/null
}

# fm_opencode_pin_clear: release <id>'s pin. A launch without the override
# calls this, so a fresh placement under the ordinary rules is not frozen by
# an earlier instruction; teardown calls it with the rest of the task's
# records.
fm_opencode_pin_clear() {  # <state-dir> <id>
  rm -f "$(fm_opencode_pin_mark "$1" "$2")" 2>/dev/null || true
}

# fm_opencode_task_pin: print <id>'s recorded pin reason, or fail when
# unpinned.
fm_opencode_task_pin() {  # <state-dir> <id>
  local path reason
  path=$(fm_opencode_pin_mark "$1" "$2")
  [ -f "$path" ] || return 1
  reason=$(cat "$path" 2>/dev/null || true)
  [ -n "$reason" ] || return 1
  printf '%s' "$reason"
}

fm_opencode_descent_clear_task() {  # <state-dir> <id>
  rm -f "$(fm_opencode_descent_mark "$1" "escalated-$2")" 2>/dev/null || true
}

# fm_opencode_descent_due: 0 when FM_OPENCODE_DESCENT_INTERVAL has elapsed
# since the last evaluation. The marker is stamped by the caller only after an
# evaluation actually ran, so a home that runs no opencode worker never starts
# a clock.
fm_opencode_descent_due() {  # <state-dir> [<now>]
  local marker=$1/.opencode-descent-last now=${2:-} stamp
  [ -f "$marker" ] || return 0
  [ -n "$now" ] || now=$(date +%s)
  stamp=$(cat "$marker" 2>/dev/null || true)
  case "$stamp" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ $((now - stamp)) -ge "$FM_OPENCODE_DESCENT_INTERVAL" ]
}

# fm_opencode_descent_when: the human time phrase for a cap horizon. A numeric
# horizon renders as "next retry in ~22h34m"; text-only evidence carries no
# trustworthy horizon (an idle lane's bracketed retry duration may never
# fire), so it owns that instead of printing a broken "next retry in ~?".
fm_opencode_descent_when() {  # <horizon>
  case "$1" in
    ''|*[!0-9]*)
      printf 'the cap is showing in its pane with no retry horizon on record' ;;
    *)
      printf 'next retry in %s' "$(fm_opencode_ladder_horizon_human "$1")" ;;
  esac
}

# fm_opencode_descent_cap: the quota-scale verdict for one lane, reusing both
# owners and re-deriving neither. Prints "<horizon_s|unknown> <bound>
# <episode>" and returns 0 on either shape:
#   structural - the sidecar classifies blocked through bin/fm-opencode-retry.sh
#     AND the busy record still latches the session-retry event that wrote it
#     (the same two halves bin/fm-crew-state.sh requires before it calls a
#     lane blocked). <bound> is `free`, `go`, `other`, or `unbound`, from the
#     sidecar's own model binding; <episode> is the vendor's own
#     scheduled-retry timestamp, which identifies the cap episode.
#   idle (2026-09-14) - no quota-scale sidecar, but the busy record says the
#     turn ended on the plugin's idle event AND the lane's pane tail carries
#     the cap verbatim through bin/fm-opencode-retry.sh scan-text (the text
#     wins over a merely transient sidecar for an idle lane: the lane is not
#     retrying, it has stopped). <bound> is `free` when the lane is recorded
#     on the free tier (the phrase names Go as the remedy, so it is free that
#     is exhausted), else `unbound`; <horizon_s> is the literal word `unknown`;
#     <episode> is the text fingerprint scan-text reports. Busy lanes are
#     deliberately excluded: a working lane with old cap text in its scrollback
#     is making progress, and moving it would spend the captain's money for
#     nothing.
# Anything else returns 1: a stale sidecar beside a resumed turn, a transient
# backoff, expired evidence, a clean pane tail, an uncapturable pane, or no
# evidence at all.
fm_opencode_descent_cap() {  # <state-dir> <id>
  local state_dir=$1 id=$2 out rec word bound='' horizon='' status='' next=''
  local r_state='' r_source='' r_event='' episode=''
  local meta lane_model cap_file scan_out
  [ -n "$state_dir" ] && [ -d "$state_dir" ] || return 1
  [ -x "$_FM_OPENCODE_DESCENT_RETRY" ] || return 1
  if out=$("$_FM_OPENCODE_DESCENT_RETRY" check "$state_dir" "$id" 2>/dev/null); then
    for word in $out; do
      case "$word" in
        status=*) status=${word#status=} ;;
        horizon_s=*) horizon=${word#horizon_s=} ;;
        model=*)
          case "${word#model=}" in
            "$FM_OPENCODE_LADDER_FREE") bound=free ;;
            "$FM_OPENCODE_LADDER_GO") bound=go ;;
            *) bound=other ;;
          esac
          ;;
      esac
    done
    if [ "$status" = blocked ]; then
      case "$horizon" in ''|*[!0-9]*) : ;; *)
        [ -n "$bound" ] || bound=unbound
        # The latch: the record the plugin maintains must still name the retry
        # event. A genuinely resumed turn writes session-busy first, which
        # drops a stale sidecar even before its horizon expires.
        if rec=$(fm_busy_record_read "$state_dir" "$id" 2>/dev/null); then
          r_state=${rec%% *}; rec=${rec#* }
          r_source=${rec%% *}; rec=${rec#* }
          r_event=${rec%% *}
          if [ "$r_state" = busy ] && [ "$r_source" = opencode-plugin ] \
            && [ "$r_event" = session-retry ]; then
            # The episode identity comes from the sidecar the check just
            # classified: the check passed, so the record is present, one
            # line, and well-formed, and its vendor timestamp names the
            # refusal this episode belongs to.
            next=$(tr ' ' '\n' < "$state_dir/$id.opencode-retry" 2>/dev/null \
              | sed -n 's/^next=\([0-9][0-9]*\)$/\1/p' | head -n 1)
            if [ -n "$next" ]; then
              printf '%s %s %s\n' "$horizon" "$bound" "$next"
              return 0
            fi
          fi
        fi
        ;;
      esac
    fi
  fi
  # The idle shape: the turn ended on the plugin's idle event, so the sidecar
  # is gone by design - the pane tail is the only evidence left. Detection
  # stays owned by bin/fm-opencode-retry.sh; this only supplies the capture.
  rec=$(fm_busy_record_read "$state_dir" "$id" 2>/dev/null) || return 1
  r_state=${rec%% *}; rec=${rec#* }
  r_source=${rec%% *}; rec=${rec#* }
  r_event=${rec%% *}
  [ "$r_state" = idle ] || return 1
  [ "$r_source" = opencode-plugin ] || return 1
  case "$r_event" in session-idle|session-status-idle) ;; *) return 1 ;; esac
  command -v fm_opencode_ladder_pane_file >/dev/null 2>&1 || return 1
  cap_file=$(fm_opencode_ladder_pane_file "$state_dir" "$id" 2>/dev/null) || return 1
  scan_out=$("$_FM_OPENCODE_DESCENT_RETRY" scan-text --file "$cap_file" 2>/dev/null) \
    || { rm -f "$cap_file"; return 1; }
  rm -f "$cap_file"
  episode=''
  for word in $scan_out; do
    case "$word" in episode=*) episode=${word#episode=} ;; esac
  done
  [ -n "$episode" ] || return 1
  bound=unbound
  meta="$state_dir/$id.meta"
  if [ -f "$meta" ]; then
    lane_model=$(fm_meta_get "$meta" model 2>/dev/null) || lane_model=''
    [ "$lane_model" = "$FM_OPENCODE_LADDER_FREE" ] && bound=free
  fi
  printf 'unknown %s %s\n' "$bound" "$episode"
}

# fm_opencode_descent_tick: one evaluation of this home's live opencode lanes.
#
# One line per outcome on stdout, and nothing at all in the ordinary case
# where every running lane is healthy or already where the ladder puts it:
#
#   relaunched <id> <from> -> <to>   the lane was moved and the record followed
#   unrecorded <id> <reason>         it moved, but the move was not written down
#   refused <id> <reason>            it was not, and the captain needs to know
#   override <id> <reason>           the captain's own override is holding it
#
# The caller decides what a line means for supervision; bin/fm-watch.sh turns
# each into a wake. Keeping the queue out of this file is what lets the whole
# decision be exercised without the watcher's wake, lock, and recovery graph.
fm_opencode_descent_tick() {  # <state-dir> [<now>]
  local state_dir=$1 now=${2:-} rc=0
  local meta id harness model kind cap horizon bound note ctl_out reason
  local recorded after next rest hold_reason when

  fm_opencode_descent_off "$state_dir" && return 0
  [ -n "$state_dir" ] && [ -d "$state_dir" ] || return 0
  [ -n "$now" ] || now=$(date +%s)

  # Cheap pre-filter: does this home run any opencode lane at all? A home
  # with none must not start the evaluation clock either.
  harness=''
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    case "$(fm_meta_get "$meta" harness 2>/dev/null)" in opencode*) harness=found; break ;; esac
  done
  [ "$harness" = found ] || return 0
  fm_opencode_descent_due "$state_dir" "$now" || return 0
  printf '%s' "$now" > "$state_dir/.opencode-descent-last" 2>/dev/null || true

  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    harness=$(fm_meta_get "$meta" harness 2>/dev/null) || continue
    case "$harness" in opencode*) ;; *) continue ;; esac
    model=$(fm_meta_get "$meta" model 2>/dev/null) || model=''
    kind=$(fm_meta_get "$meta" kind 2>/dev/null) || kind=''
    case "$model" in
      "$FM_OPENCODE_LADDER_FREE"|"$FM_OPENCODE_LADDER_GO"|'') ;;
      *) fm_opencode_descent_clear_task "$state_dir" "$id"; continue ;;
    esac

    # The trigger: a quota-scale cap on the supervision-grade verdict. A lane
    # that does not meet it ends whatever episode it was in.
    if ! cap=$(fm_opencode_descent_cap "$state_dir" "$id"); then
      fm_opencode_descent_clear_task "$state_dir" "$id"
      continue
    fi
    horizon=${cap%% *}; rest=${cap#* }
    bound=${rest%% *}; next=${rest#* }
    when=$(fm_opencode_descent_when "$horizon")

    # One automatic attempt per cap episode. A failed move is not retried
    # here - each attempt stops a live worker, so the refusal wake hands the
    # retry to firstmate with full context. Fresh refusal evidence carries a
    # new vendor timestamp and re-arms both the report and the attempt; the
    # same refusal re-observed stays quiet. The marker is cleared above the
    # moment the lane stops meeting the trigger.
    if [ -f "$(fm_opencode_descent_mark "$state_dir" "escalated-$id")" ] \
      && [ "$(cat "$(fm_opencode_descent_mark "$state_dir" "escalated-$id")" 2>/dev/null || true)" = "$next" ]; then
      continue
    fi

    # The captain's own escape, honoured before any move: a worker held on
    # free past a proven cap on explicit request is not dragged off it, and
    # the hold is said once per episode. The hold is read from the task's
    # recorded pin first and the environment second, because the tick runs
    # where the variable cannot follow it; either source names the same
    # authority and prints the same reason.
    hold_reason=${FM_OPENCODE_LADDER_OVERRIDE:-}
    [ -n "$hold_reason" ] || hold_reason=$(fm_opencode_task_pin "$state_dir" "$id" 2>/dev/null) || hold_reason=
    if [ -n "$hold_reason" ]; then
      if fm_opencode_descent_escalate_once "$state_dir" "$id" "$next"; then
        printf 'override %s %s is capped (%s) but the captain'"'"'s hold is keeping it there: %s\n' \
          "$id" "${model:-<no model>}" "$when" "$hold_reason"
      fi
      continue
    fi

    # Nowhere to move to, or nobody the descent may move: all loud, all once
    # per episode, none of them ever reaching the control plane.
    if [ -z "$model" ]; then
      if fm_opencode_descent_escalate_once "$state_dir" "$id" "$next"; then
        printf 'refused %s records no model and a quota-scale cap is proven (%s); refusing to move it blind - firstmate decision needed\n' \
          "$id" "$when"
      fi
      continue
    fi
    if [ "$model" = "$FM_OPENCODE_LADDER_GO" ]; then
      if fm_opencode_descent_escalate_once "$state_dir" "$id" "$next"; then
        printf 'refused %s is on the Go tier %s and it is capped too (%s); the ladder has no third rung - firstmate decision needed\n' \
          "$id" "$model" "$when"
      fi
      continue
    fi
    if [ "$kind" = secondmate ]; then
      if fm_opencode_descent_escalate_once "$state_dir" "$id" "$next"; then
        printf 'refused %s is a secondmate on capped free (%s); automatic relaunch never touches a persistent supervision agent - firstmate decision needed\n' \
          "$id" "$when"
      fi
      continue
    fi

    # The move: the proven free cap relaunches the lane onto Go. The handoff
    # note owns the ambiguity when the cap evidence carries no model binding,
    # exactly as the dispatch gate's own notice does.
    case "$horizon" in
      ''|*[!0-9]*)
        note="opencode descent: free tier $FM_OPENCODE_LADDER_FREE is proven exhausted (free-tier cap shown in the lane's pane, no retry horizon on record" ;;
      *)
        note="opencode descent: free tier $FM_OPENCODE_LADDER_FREE is proven exhausted (quota-scale retry backoff, $when" ;;
    esac
    if [ "$bound" = unbound ]; then
      note="$note, with no model binding on the cap evidence - biasing toward Go rather than stalling"
    fi
    note="$note); the free session is parked with no forward progress. Relaunched onto the Go tier $FM_OPENCODE_LADDER_GO. Continue the task from this note plus the brief and committed work."
    ctl_out=$(FM_HOME="${FM_HOME:-}" FM_STATE_OVERRIDE="$state_dir" \
      "$(fm_opencode_descent_control)" "$id" relaunch \
      --harness opencode --model "$FM_OPENCODE_LADDER_GO" --note "$note" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
      reason=${ctl_out%%$'\n'*}
      [ -n "$reason" ] || reason="the control plane refused without a reason"
      if fm_opencode_descent_escalate_once "$state_dir" "$id" "$next"; then
        printf 'refused %s could not be relaunched from %s onto %s: %s\n' \
          "$id" "$model" "$FM_OPENCODE_LADDER_GO" "$reason"
      fi
      continue
    fi
    # THE MOVE IS NOT FINISHED UNTIL IT IS WRITTEN DOWN. Recovery relaunches
    # from the durable record, so a record still naming free would bring the
    # next relaunch straight back onto the capped tier.
    recorded=$(fm_meta_get "$meta" model 2>/dev/null) || recorded=''
    if [ "$recorded" = "$FM_OPENCODE_LADDER_GO" ]; then
      # The dead session's backoff describes nobody now; leaving it behind
      # would brand the replacement lane capped on its first evaluation.
      "$_FM_OPENCODE_DESCENT_RETRY" clear "$state_dir" "$id" 2>/dev/null || true
      fm_opencode_descent_clear_task "$state_dir" "$id"
      printf 'relaunched %s %s -> %s\n' "$id" "$model" "$FM_OPENCODE_LADDER_GO"
    else
      after=${recorded:-<unreadable>}
      if fm_opencode_descent_escalate_once "$state_dir" "$id" "$next"; then
        printf 'unrecorded %s was relaunched onto %s but its durable record still names %s; a further relaunch would bring it back onto the capped tier - investigate before moving it again\n' \
          "$id" "$FM_OPENCODE_LADDER_GO" "$after"
      fi
    fi
  done
  return 0
}
