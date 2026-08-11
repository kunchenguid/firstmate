#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A declared external-wait pause is
# the separate idle absorb case and re-surfaces only on its long bounded cadence,
# although its initial no-verb status signal still surfaces in normal mode.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause is absorbed instead with its own long
#                          re-surface cadence, never as a wedge. Only when neither
#                          absorb class applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless afk is active. A genuinely busy pane
#                          (window_is_busy true) is exempt from the above, but
#                          only up to BUSY_TURN_MAX_SECS with no completed turn
#                          (state/<id>.turn-ended, or the spawn record before any
#                          turn completes); past that bound busy_turn_over_age
#                          routes it through the same wedge timer, so it surfaces
#                          with the identical "stale: ..." reason, escalation
#                          count, and demand-deep-inspection marker, for human
#                          inspection only - never an automatic interrupt,
#                          signal, or restart of the worker or its tool process.
#   check: <script>: <out> authenticated check output, always actionable
#   check: process-event result captured: <keys>
#                          a durably captured process-to-event result is queued
#                          and has not been surfaced yet; reported once per
#                          captured generation, never again while that record
#                          stays queued and never once it is acknowledged
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: rejected unauthenticated PR poll retirement receipts: <paths>
#                          invalid pending retirements were preserved without
#                          running a check or removing poll artifacts
#   check: fast-repair <id> <state>
#                          the Fast-Repair-only progress cadence found a CHANGED
#                          actionable state for a task whose meta records an
#                          eligible fast-repair delivery: broader tests failed,
#                          or its PR checks failed or turned green. A result
#                          identical to the one already surfaced is never
#                          re-surfaced (docs/fast-repair.md)
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
mkdir -p "$STATE"

# The native event fast-path and only its true dependencies have one narrow
# production owner. The Herdr event-wait smoke test consumes this same owner
# without sourcing the entire watcher graph.
# The shared transition owner is a canonical lint root itself. Stop duplicate
# source-graph expansion here: following its backend graph from this large
# runtime can exceed the bounded CI lint worker while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-push-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_DOWNTIME_MARKER="$STATE/.watcher-down"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
FAST_REPAIR_PROGRESS_INTERVAL=${FM_FAST_REPAIR_PROGRESS_INTERVAL:-20} # Fast Repair only
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy state is decided by the semantic contract in bin/fm-busy-lib.sh, which
# is the single owner of per-harness sources, source attribution, and the one
# remaining rendered-text fallback (Grok only).
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A busy pane is unconditional proof of liveness with no built-in duration bound,
# so a hung foreground call can remain hidden even while its rendered busy
# footer changes every poll. BUSY_TURN_MAX_SECS bounds how long any busy pane
# may go with no completed turn: once its task's
# state/<id>.turn-ended marker (or, before any turn has completed, the task's
# spawn record) is this old, busy_turn_over_age routes the pane through the
# same STALE_ESCALATE_SECS-paced wedge_timer_check used for a provably-working
# non-busy stale, so it escalates via the existing stale reason, escalation
# counter, and demand-deep-inspection marker for human inspection only - never
# an automatic interrupt, signal, or restart. A completed turn touches
# turn-ended and resets the age. Set generously above any legitimate interval
# between completed turns, including long tool calls, builds, or test runs.
BUSY_TURN_MAX_SECS=${FM_BUSY_TURN_MAX_SECS:-3600}
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# A captain-held or paused crew whose agent has confidently exited uses the same
# bounded cadence, while a live or ambiguously read agent still surfaces once.
# These cases re-surface once for a recheck every PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten hold cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is PROVABLY working, through
# the semantic busy-state contract (bin/fm-busy-lib.sh). Only an exact busy
# verdict returns 0: idle, unknown, and dead all return 1, so a converted
# adapter whose semantic state is missing, malformed, stale, or unverified is
# treated as not-provably-working and surfaces rather than being absorbed.
# <tail40> is the same bounded capture already read for hashing and is
# consumed only by the Grok-scoped fallback inside the contract.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 task meta verdict
  task=$(window_to_task "$w" "$STATE")
  meta="$STATE/$task.meta"
  if [ -n "$task" ] && [ -f "$meta" ]; then
    verdict=$(fm_busy_classify_meta "$meta" "$task" "$STATE" "$tail40")
  else
    verdict=$(fm_busy_classify "$(window_backend "$w")" "$w" "$(window_harness "$w")" \
      "${task:-unknown}" "$STATE" "$tail40")
  fi
  [ "${verdict%% *}" = busy ]
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_harness() {
  local w=$1 meta
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  grep '^harness=' "$meta" | cut -d= -f2- || true
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane outranked).
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 since age n reason
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        wake "$reason"
      fi
      ;;
  esac
}

# busy_turn_over_age: 0 iff <task>'s latest completed-turn marker is at least
# BUSY_TURN_MAX_SECS old. Ages the per-task turn-ended marker, the harness-neutral
# signal every verified harness's turn-end hook touches; before any turn has
# completed, ages the task's spawn record instead so a fresh task still gets a
# bound. The caller checks that the pane is busy and routes a crossed bound
# through the existing wedge_timer_check, never anything that touches the
# worker itself.
busy_turn_over_age() {  # <task>
  local task=$1 f
  f="$STATE/$task.turn-ended"
  [ -e "$f" ] || f="$STATE/$task.meta"
  [ "$(age_of "$f")" -ge "$BUSY_TURN_MAX_SECS" ]
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# dead-agent captain-held transfer, and re-surface it once every
# PAUSE_RESURFACE_SECS for a recheck so it cannot rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads crew state. The re-surface age is anchored on the
# status file mtime, not a per-hash marker, so a churny idle pane (a ticking
# clock, a token counter) cannot keep resetting the cadence the way a hash-tied
# timer would. A .paused-resurfaced-<key> throttle marker records the last
# re-surface epoch so, once past the window, it fires once per window rather than
# every poll. Advances the stale suppressor to <hash> and flags the key paused.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age rf rf_age reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale (paused, awaiting external, age ${age}s): $win"
}

clear_pause_state() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  clear_pause_state "$win"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# Only a confidently dead ordinary crew may recover paused classification after
# fm-crew-state has fallen back to stopped or unknown.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$(window_kind "$win")" != secondmate ]; then
      agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$(window_kind "$win")" != secondmate ]; then
    agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  [ "$class" = none ] && [ "${agent_alive:-unknown}" = dead ] && class=paused
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last
  key=$(printf '%s' "$win" | tr ':/.' '___')
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if status_is_paused_or_captain_held "$last"; then
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    date +%s > "$STATE/.paused-resurfaced-$key"
  else
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  fi
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

FAST_REPAIR_ACTIVE=0
FAST_REPAIR_TIMER_PID=
FAST_REPAIR_TIMER_MARKER=
FAST_REPAIR_TIMER_GENERATION=0
FAST_REPAIR_TIMER_WAIT_FILE=

# The one place that decides whether durable task metadata opts a task into Fast
# Repair.
fast_repair_eligible_meta() {  # <meta-path>
  grep -qx 'mode=fast-repair' "$1" 2>/dev/null || return 1
  grep -qx 'fast_repair=eligible' "$1" 2>/dev/null
}

# The twenty-second forge poll exists to surface the first actionable transition
# of an open Fast Repair PR. Once a green rollup has been queued for firstmate
# there is nothing left for it to catch there, so this marker retires the task
# from the forge poll and the ordinary CHECK_INTERVAL PR poll owns PR checks from
# then on. The beat itself continues in local-only mode, because the broader test
# family can still be running and its failure has no other machine-side surface.
fast_repair_progress_green_marker() {  # <task-id>
  printf '%s/.fast-repair-progress-green-%s' "$STATE" "$1"
}

fast_repair_progress_forge_retired() {  # <task-id>
  [ -e "$(fast_repair_progress_green_marker "$1")" ]
}

fast_repair_progress_surfaced_marker() {  # <task-id>
  printf '%s/.fast-repair-progress-%s' "$STATE" "$1"
}

fast_repair_progress_surfaced() {  # <task-id> <result>
  [ "$(cat "$(fast_repair_progress_surfaced_marker "$1")" 2>/dev/null || true)" = "$2" ]
}

# The cadence exists to catch the transitions of an open Fast Repair PR, and its
# last one is the broader family reaching a terminal result. A broader failure
# permanently short-circuits the progress helper ahead of any forge read, so once
# that failure is surfaced there is nothing left to report; a broader pass after
# the forge poll already retired leaves the same nothing. In both cases the beat
# retires and the ordinary lifecycle and PR polling own the task from then on.
fast_repair_progress_followup_done() {  # <task-id>
  local id=$1 record broader
  record="$STATE/$id.fast-repair-broader"
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  broader=$(sed -n 's/^broader=//p' "$record" | head -n 1)
  case "$broader" in
    failed) fast_repair_progress_surfaced "$id" "fast-repair $id broader-tests-failed" ;;
    passed) fast_repair_progress_forge_retired "$id" ;;
    *) return 1 ;;
  esac
}

# The single owner of which tasks the Fast Repair progress cadence works on:
# durable metadata says eligible and the cadence still has a transition left to
# catch. Every consumer below - the activity flag, the missing-schedule repair,
# the timer delay, and the tick itself - reads this one emitter, so the rule and
# the id derivation have one place to change.
fast_repair_progress_task_ids() {
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    fast_repair_eligible_meta "$meta" || continue
    id=$(basename "$meta" .meta)
    fast_repair_progress_followup_done "$id" && continue
    printf '%s\n' "$id"
  done
  return 0
}

# A drain that cannot consume a handoff keeps the record durable for a later
# retry, but the record must stop shortening waits once it has proven it cannot
# be delivered - otherwise every later wait returns immediately and the whole
# supervision loop spins. Attempts are counted per handoff so retry stays bounded
# and the wake record itself is never discarded.
FAST_REPAIR_HANDOFF_RETRY_MAX=${FM_FAST_REPAIR_HANDOFF_RETRY_MAX:-1}

fast_repair_progress_handoff_attempts() {  # <handoff-file>
  local n
  n=$(cat "$1.attempts" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

fast_repair_progress_handoff_attempt_record() {  # <handoff-file>
  local file=$1 n tmp
  n=$(( $(fast_repair_progress_handoff_attempts "$file") + 1 ))
  tmp=$(mktemp "$STATE/.fast-repair-progress-attempt.XXXXXX") || return 1
  if ! printf '%s\n' "$n" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$file.attempts"; then
    rm -f "$tmp"
    return 1
  fi
}

fast_repair_progress_handoff_forget() {  # <handoff-file>
  rm -f "$1" "$1.attempts"
}

# A durable handoff that has not yet spent its delivery budget. The wait entry
# points consult this after publishing their interruptible pid, which closes the
# window between forking a wait and making it reachable by
# fast_repair_progress_timer_notify.
fast_repair_progress_handoff_pending() {
  local file
  for file in "$STATE"/.fast-repair-progress-handoff-*; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    case "$file" in *.attempts) continue ;; esac
    [ "$(fast_repair_progress_handoff_attempts "$file")" -lt "$FAST_REPAIR_HANDOFF_RETRY_MAX" ] || continue
    return 0
  done
  return 1
}

# Replaying an undeliverable result on every beat would otherwise leave one
# handoff file per beat behind, since each cycle publishes under a fresh
# generation. An identical undrained record for the same task carries no extra
# information, so the replay supersedes it instead of stacking on it.
fast_repair_progress_handoff_supersede() {  # <task-id> <result>
  local id=$1 result=$2 file f_lifecycle f_id f_result
  for file in "$STATE"/.fast-repair-progress-handoff-*; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    case "$file" in *.attempts) continue ;; esac
    exec 9< "$file" || continue
    IFS= read -r f_lifecycle <&9 || { exec 9<&-; continue; }
    # A record whose first line is the generation is the legacy three-line shape;
    # anything else carries the lifecycle first and the generation on its own line.
    if ! [[ "$f_lifecycle" =~ ^[0-9]+$ ]]; then
      IFS= read -r _ <&9 || { exec 9<&-; continue; }
    fi
    IFS= read -r f_id <&9 || { exec 9<&-; continue; }
    IFS= read -r f_result <&9 || { exec 9<&-; continue; }
    exec 9<&-
    [ "$f_id" = "$id" ] && [ "$f_result" = "$result" ] || continue
    fast_repair_progress_handoff_forget "$file"
  done
  return 0
}

# A result byte-identical to the one already surfaced carries no transition, so
# publishing it would tear the watcher out of its wait for nothing. The marker is
# written only after the durable wake is queued, so a failed enqueue still leaves
# the result unmarked and the next beat replays it.
fast_repair_progress_result_is_new() {  # <task-id> <result>
  ! fast_repair_progress_surfaced "$1" "$2"
}

# Fast Repair has a short, task-scoped progress cadence for broader-test and PR
# check results. It is inert, byte-for-byte, when no durable task metadata says
# mode=fast-repair and fast_repair=eligible. It does not change the normal signal,
# stale, custom-check, heartbeat, or sleep cadence, and it never starts another
# watcher. Each actionable result is deduplicated per task so an unchanged failed
# PR check cannot wake firstmate every twenty seconds. That dedup marker is
# advanced only after the durable wake is queued, the same discipline .seen-*
# follows above, so a watcher that dies mid-cycle re-announces the transition
# instead of swallowing it.
# The progress helper reads the PR's checks from the forge, so it is a network
# call and runs through run_check_capture exactly like every other per-task
# check: bounded by CHECK_TIMEOUT in its own process group, so a hung or slow
# forge call can neither stall the beat, the signal scan, and the stale and
# wedge detection of other crewmates, nor hold off a stop signal.
fast_repair_progress_discover() {
  local id
  FAST_REPAIR_ACTIVE=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    FAST_REPAIR_ACTIVE=1
    break
  done < <(fast_repair_progress_task_ids)
  return 0
}

fast_repair_progress_generation_next() {
  local counter="$STATE/.fast-repair-progress-next-generation"
  local lock="$STATE/.fast-repair-progress-generation.lock"
  local current next tmp
  fm_lock_acquire_wait "$lock" || return 1
  current=$(cat "$counter" 2>/dev/null || true)
  case "$current" in ''|*[!0-9]*) current=0 ;; esac
  next=$((current + 1))
  tmp=$(mktemp "$counter.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  if ! printf '%s\n' "$next" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$counter"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
  printf '%s\n' "$next"
}

fast_repair_eligible_task() {
  local meta="$STATE/$1.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] && fast_repair_eligible_meta "$meta"
}

fast_repair_progress_lifecycle() {
  local f="$DATA/$1/fast-repair-eligibility" lifecycle
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    lifecycle=$(sed -n 's/^lifecycle=//p' "$f" | head -n 1)
    case "$lifecycle" in ?*[!A-Za-z0-9._-]*|'') return 1 ;; esac
    printf '%s\n' "$lifecycle"
    return 0
  fi
  printf '%s\n' legacy
}

fast_repair_progress_due_path() {
  printf '%s/.fast-repair-progress-next-due-%s' "$STATE" "$1"
}

fast_repair_progress_due_set() {
  local id=$1 due=$2 path tmp
  fm_pr_task_id_valid "$id" || return 1
  case "$due" in *[!0-9]*|'') return 1 ;; esac
  path=$(fast_repair_progress_due_path "$id") || return 1
  tmp=$(mktemp "$path.XXXXXX") || return 1
  if ! printf '%s\n' "$due" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
}

fast_repair_progress_due_in() {
  local path now due
  path=$(fast_repair_progress_due_path "$1") || return 1
  now=$(date +%s) || return 1
  due=$(cat "$path" 2>/dev/null || true)
  case "$due" in *[!0-9]*|'') printf '0\n'; return 0 ;; esac
  if [ "$due" -le "$now" ]; then
    printf '0\n'
  else
    printf '%s\n' "$((due - now))"
  fi
}

fast_repair_progress_schedule_missing() {
  local id path now due
  now=$(date +%s) || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    path=$(fast_repair_progress_due_path "$id") || continue
    due=$(cat "$path" 2>/dev/null || true)
    case "$due" in *[!0-9]*|'') fast_repair_progress_due_set "$id" "$((now + FAST_REPAIR_PROGRESS_INTERVAL))" || continue ;; esac
  done < <(fast_repair_progress_task_ids)
  return 0
}

# A task whose progress child is still running has no schedule to wait on: its
# next due time is written by that child when the check completes. Counting its
# stale zero delay here would spin the timer loop once a second for the whole
# life of a slow forge call, so it is skipped and the interval is used instead;
# the child's own due write is what the next iteration reads.
fast_repair_progress_timer_delay() {  # [<generation>]
  local generation=${1:-} id delay shortest=
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ -n "$generation" ] && fast_repair_progress_task_running "$id" "$generation"; then
      continue
    fi
    delay=$(fast_repair_progress_due_in "$id") || continue
    case "$delay" in *[!0-9]*|'') continue ;; esac
    if [ -z "$shortest" ] || [ "$delay" -lt "$shortest" ]; then
      shortest=$delay
    fi
  done < <(fast_repair_progress_task_ids)
  printf '%s\n' "${shortest:-$FAST_REPAIR_PROGRESS_INTERVAL}"
}

fast_repair_progress_record() {
  local id=$1 result=$2 generation=${3:-} marker generation_marker prior prior_generation
  marker=$(fast_repair_progress_surfaced_marker "$id")
  generation_marker="$STATE/.fast-repair-progress-generation-$id"
  if [ -n "$generation" ]; then
    case "$generation" in *[!0-9]*|'') return 3 ;; esac
    prior_generation=$(cat "$generation_marker" 2>/dev/null || true)
    case "$prior_generation" in *[!0-9]*|'') prior_generation=0 ;; esac
    [ "$prior_generation" -le "$generation" ] || return 3
  fi
  prior=$(cat "$marker" 2>/dev/null || true)
  if [ "$prior" = "$result" ]; then
    [ -z "$generation" ] || printf '%s' "$generation" > "$generation_marker"
    return 1
  fi
  fm_wake_append check "fast-repair:$id" "check: $result" || return 2
  printf '%s' "$result" > "$marker"
  [ -z "$generation" ] || printf '%s' "$generation" > "$generation_marker"
}

fast_repair_progress_task_marker() { # <task-id> <generation>
  printf '%s/.fast-repair-progress-child-%s-%s' "$STATE" "$1" "$2"
}

fast_repair_progress_task_running() { # <task-id> <generation>
  local marker
  marker=$(fast_repair_progress_task_marker "$1" "$2") || return 1
  [ ! -e "$marker.starting" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ]
}

fast_repair_progress_timer_tasks_finish() { # <generation>
  local generation=$1 marker ready reservation pid i=0 live
  local markers=() pids=()
  for reservation in "$STATE"/.fast-repair-progress-child-*"-$generation".starting; do
    [ -f "$reservation" ] && [ ! -L "$reservation" ] || continue
    : > "$reservation.closing" || continue
    rm -f "$reservation"
  done
  for marker in "$STATE"/.fast-repair-progress-child-*"-$generation"; do
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    ready="$marker.ready"
    pid=$(cat "$marker" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) rm -f "$marker" "$ready"; continue ;;
    esac
    markers+=("$marker")
    pids+=("$pid")
    kill -TERM "$pid" 2>/dev/null || true
  done
  while [ "$i" -lt 40 ]; do
    live=0
    for pid in "${pids[@]+"${pids[@]}"}"; do
      kill -0 "$pid" 2>/dev/null && { live=1; break; }
    done
    [ "$live" -eq 0 ] && break
    sleep 0.01
    i=$((i + 1))
  done
  for pid in "${pids[@]+"${pids[@]}"}"; do
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  done
  for marker in "${markers[@]+"${markers[@]}"}"; do
    rm -f "$marker" "$marker.ready"
  done
}

fast_repair_progress_task_start() { # <task-id> <generation>
  local id=$1 generation=$2 marker ready reservation result now closing=${FM_FAST_REPAIR_TIMER_CLOSING:-} lifecycle pid tmp
  local progress_args=(progress "$id")
  [ -z "$closing" ] || [ ! -e "$closing" ] || return 0
  marker=$(fast_repair_progress_task_marker "$id" "$generation") || return 1
  lifecycle=$(fast_repair_progress_lifecycle "$id") || return 1
  ! fast_repair_progress_forge_retired "$id" || progress_args+=(--local-only)
  ready="$marker.ready"
  reservation="$marker.starting"
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    return 0
  fi
  [ ! -e "$reservation" ] || return 0
  tmp=$(mktemp "$reservation.XXXXXX") || return 1
  if ! chmod 600 "$tmp" || ! mv -f "$tmp" "$reservation"; then
    rm -f "$tmp"
    return 1
  fi
  if [ -e "$reservation.closing" ] || { [ -n "$closing" ] && [ -e "$closing" ]; }; then
    rm -f "$reservation" "$reservation.closing"
    return 0
  fi
  touch "$STATE/.last-fast-repair-progress-$id"
  (
    trap 'rm -f "$marker" "$ready" "$reservation" "$reservation.closing"' EXIT
    trap 'fm_active_check_stop || true; exit 0' HUP INT TERM
    while [ ! -f "$ready" ]; do
      [ ! -e "$reservation.closing" ] || exit 0
      sleep 0.01
    done
    [ ! -e "$reservation.closing" ] || exit 0
    [ -z "$closing" ] || [ ! -e "$closing" ] || exit 0
    if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      run_check_capture --stop-active-check-on-signal "$SCRIPT_DIR/fm-fast-repair.sh" "${progress_args[@]}"; then
      result=$FM_CHECK_RESULT
    else
      result=
    fi
    now=$(date +%s) && fast_repair_progress_due_set "$id" "$((now + FAST_REPAIR_PROGRESS_INTERVAL))"
    if [ -n "$result" ] && fast_repair_progress_result_is_new "$id" "$result"; then
      FM_FAST_REPAIR_TASK_LIFECYCLE="$lifecycle" fast_repair_progress_timer_publish "$id" "$result"
    fi
  ) &
  pid=$!
  if [ -e "$reservation.closing" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    rm -f "$reservation"
    return 0
  fi
  tmp=$(mktemp "$marker.XXXXXX") || { kill -TERM "$pid" 2>/dev/null || true; return 1; }
  if [ -e "$reservation.closing" ] || { [ -n "$closing" ] && [ -e "$closing" ]; }; then
    rm -f "$tmp" "$reservation"
    kill -TERM "$pid" 2>/dev/null || true
    return 0
  fi
  if ! printf '%s\n' "$pid" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$marker"; then
    rm -f "$tmp"
    kill -TERM "$pid" 2>/dev/null || true
    rm -f "$reservation" "$reservation.closing"
    return 1
  fi
  rm -f "$reservation"
  touch "$ready"
}

# One tick collects the eligible ids once and reuses that list for both the
# activity flag and the work. The next due time is deliberately NOT advanced
# here: the child that actually runs the check advances it once that check
# completes. A child reaped at a poll boundary therefore leaves the due time
# behind it, so the beat is retried on the next tick instead of being silently
# skipped for a whole interval. That is a retry guarantee, not a delivery one: a
# forge call slower than the remaining poll window is reaped before it can
# publish on every attempt, so a persistently slow forge still surfaces nothing
# through this cadence and the ordinary CHECK_INTERVAL PR poll remains the
# backstop. A start that fails before forking re-arms the due at the normal
# interval, so it retries on the cadence instead of spinning the timer loop.
fast_repair_progress_tick() {
  local id due generation now
  local ids=()
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ids+=("$id")
  done < <(fast_repair_progress_task_ids)
  if [ "${#ids[@]}" -eq 0 ]; then
    FAST_REPAIR_ACTIVE=0
    return 0
  fi
  FAST_REPAIR_ACTIVE=1
  generation=${FM_FAST_REPAIR_TIMER_GENERATION:-}
  case "$generation" in *[!0-9]*|'') return 1 ;; esac
  for id in "${ids[@]}"; do
    due=$(fast_repair_progress_due_in "$id") || continue
    [ "$due" -eq 0 ] || continue
    fast_repair_progress_task_running "$id" "$generation" && continue
    touch "$STATE/.last-fast-repair-progress-$id"
    if ! fast_repair_progress_task_start "$id" "$generation"; then
      now=$(date +%s) && fast_repair_progress_due_set "$id" "$((now + FAST_REPAIR_PROGRESS_INTERVAL))"
    fi
  done
  return 0
}

fast_repair_progress_timer_publish() {
  local id=$1 result=$2 generation=${FM_FAST_REPAIR_TIMER_GENERATION:-}
  local file tmp lock counter current next lifecycle
  case "$generation" in *[!0-9]*|'') return 1 ;; esac
  case "$id:$result" in *$'\n'*|*$'\r'*) return 1 ;; esac
  fm_pr_task_id_valid "$id" || return 1
  lifecycle=${FM_FAST_REPAIR_TASK_LIFECYCLE:-$(fast_repair_progress_lifecycle "$id")} || return 1
  case "$lifecycle" in ?*[!A-Za-z0-9._-]*|'') return 1 ;; esac
  fast_repair_progress_handoff_supersede "$id" "$result"
  lock="$STATE/.fast-repair-progress-sequence-$id-$generation.lock"
  counter="$STATE/.fast-repair-progress-sequence-$id-$generation"
  fm_lock_acquire_wait "$lock" || return 1
  current=$(cat "$counter" 2>/dev/null || true)
  case "$current" in ''|*[!0-9]*) current=0 ;; esac
  next=$((current + 1))
  tmp=$(mktemp "$STATE/.fast-repair-progress-pending.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  file=$(printf '%s/.fast-repair-progress-handoff-%s-%s-%020d' "$STATE" "$id" "$generation" "$next")
  if ! {
    printf '%s\n' "$lifecycle"
    printf '%s\n' "$generation"
    printf '%s\n' "$id"
    printf '%s\n' "$result"
  } > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$file" || ! printf '%s\n' "$next" > "$counter"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
  fast_repair_progress_timer_notify
}

# Every interruptible wait is published as its own process-group leader, so the
# whole wait - including a backend event reader forked inside it - can be stopped
# here rather than only the shell that owns it. A recorded pid is signalled only
# once it is proven to be BOTH a direct child of this watcher AND its own process
# group leader: the group form is what reaches the reader, and without that proof
# a pid that has already exited and been reused would aim it at an unrelated
# group. Failing the group proof still stops the pid itself, which is all the
# plain sleep path ever needed.
fast_repair_progress_timer_notify() {
  local parent=${FM_FAST_REPAIR_TIMER_PARENT:-} wait_file=${FM_FAST_REPAIR_TIMER_WAIT_FILE:-} wait_pid wait_parent wait_pgid
  case "$parent" in *[!0-9]*|'') return 0 ;; esac
  [ -f "$wait_file" ] && [ ! -L "$wait_file" ] || return 0
  wait_pid=$(cat "$wait_file" 2>/dev/null || true)
  case "$wait_pid" in *[!0-9]*|'') return 0 ;; esac
  wait_parent=$(ps -o ppid= -p "$wait_pid" 2>/dev/null | tr -d '[:space:]')
  [ "$wait_parent" = "$parent" ] || return 0
  wait_pgid=$(ps -o pgid= -p "$wait_pid" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$wait_pgid" ] && [ "$wait_pgid" = "$wait_pid" ]; then
    kill -TERM -- "-$wait_pid" 2>/dev/null || true
  fi
  kill -TERM "$wait_pid" 2>/dev/null || true
}

# Deliver a durably queued process-event result to firstmate. Publication is
# owned by bin/fm-procevent.sh - by the runner at capture time and by reconcile's
# re-announcement - so this decides only whether a queued check record has been
# surfaced yet, then reports it through the same actionable exit every other wake
# uses. Without it a captured result sits on the queue until something else
# happens to wake firstmate, which is exactly the missed delivery this repairs.
# Dedup uses the same .seen-* discipline as scan_signals: the durable record is
# always written before its marker, so nothing is suppressed before it is queued,
# and re-announcement, drain-time deduplication, and the handled acknowledgement
# keep their existing owners untouched.
procevent_surfaced_marker() {  # <queue-key>
  printf '%s/.seen-procevent-%s' "$STATE" "$(printf '%s' "$1" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
}

procevent_surface_after_output() {
  local output_status=$1 key marker tmp status=0
  if [ "$output_status" -eq 0 ]; then
    for key in $PROCEVENT_SURFACED; do
      marker=$(procevent_surfaced_marker "$key")
      tmp=$(umask 077; mktemp "$STATE/.seen-procevent.XXXXXX") || { status=1; continue; }
      if ! mv -f -- "$tmp" "$marker"; then
        rm -f -- "$tmp"
        status=1
      fi
    done
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

procevent_surface_queued() {
  local key reason
  PROCEVENT_SURFACED=
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  while IFS= read -r key; do
    case "$key" in procevent:*) ;; *) continue ;; esac
    [ -e "$(procevent_surfaced_marker "$key")" ] && continue
    PROCEVENT_SURFACED="$PROCEVENT_SURFACED $key"
  done < <(fm_wake_queued_keys_locked check)
  if [ -z "$PROCEVENT_SURFACED" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  reason="check: process-event result captured:$PROCEVENT_SURFACED"
  # shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
  FM_WAKE_POST_OUTPUT_ACTION=procevent_surface_after_output
  wake "$reason"
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid stop_active_check=0
  case "${1:-}" in
    --stop-active-check-on-signal) stop_active_check=1; shift ;;
  esac
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  if [ "$stop_active_check" -eq 1 ]; then
    trap 'fm_active_check_stop || true; exit 1' HUP INT TERM
  else
    trap 'exit 1' HUP INT TERM
  fi
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  # A signal delivered between installing the pending-flag trap and swapping in
  # the real one lands here instead of in a handler, so this exit owes the same
  # guarantee the swapped-in trap gives: under --stop-active-check-on-signal the
  # forked check's whole process group is stopped first, or it would outlive the
  # caller with only its recorded child pid known to any later reaper.
  if [ -n "$FM_CHECK_SIGNAL_PENDING" ]; then
    [ "$stop_active_check" -eq 0 ] || fm_active_check_stop || true
    fm_check_output_cleanup
    exit 1
  fi
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop is owned by
# fm-push-transition-lib.sh because push and poll paths must write one format.
# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

fast_repair_progress_timer_start() {
  local marker parent closing generation delay wait_file
  [ "$FAST_REPAIR_ACTIVE" = 1 ] || return 0
  case "$POLL:$FAST_REPAIR_PROGRESS_INTERVAL" in *[!0-9:]*|:*|*:) return 0 ;; esac
  fast_repair_progress_schedule_missing || return 0
  generation=$(fast_repair_progress_generation_next) || return 0
  FAST_REPAIR_TIMER_GENERATION=$generation
  marker=$(mktemp "$STATE/.fast-repair-progress-timer.XXXXXX") || return 0
  closing="$marker.closing"
  wait_file="$marker.wait-pid"
  FAST_REPAIR_TIMER_MARKER=$marker
  FAST_REPAIR_TIMER_WAIT_FILE=$wait_file
  parent=$WATCHER_PID
  (
    trap 'rm -f "$closing"' EXIT
    trap 'fm_active_check_stop || true; exit 0' HUP INT TERM
    while [ -f "$marker" ]; do
      [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" = "$parent" ] || exit 0
      FM_FAST_REPAIR_TIMER_PARENT="$parent" \
        FM_FAST_REPAIR_TIMER_CLOSING="$closing" \
        FM_FAST_REPAIR_TIMER_GENERATION="$generation" \
        FM_FAST_REPAIR_TIMER_WAIT_FILE="$wait_file" \
        fast_repair_progress_tick
      [ "$FAST_REPAIR_ACTIVE" = 1 ] || rm -f "$marker"
      [ -f "$marker" ] || exit 0
      delay=$(fast_repair_progress_timer_delay "$generation") || exit 0
      case "$delay" in *[!0-9]*|'') exit 0 ;; esac
      [ "$delay" -gt 0 ] || delay=1
      sleep "$delay"
      [ -f "$marker" ] || exit 0
    done
  ) &
  FAST_REPAIR_TIMER_PID=$!
}

fast_repair_progress_timer_finish() {
  local marker=${FAST_REPAIR_TIMER_MARKER:-} pid=${FAST_REPAIR_TIMER_PID:-} generation=${FAST_REPAIR_TIMER_GENERATION:-} wait_file=${FAST_REPAIR_TIMER_WAIT_FILE:-} i=0
  # Runs first and unconditionally: a watcher signalled while blocked in `wait`
  # reaches here through its EXIT trap with the forked backend wait still live,
  # and that wait's own reader keeps mutating this home's transition state until
  # its budget expires. Nothing else knows the group.
  fast_repair_progress_wait_cleanup
  [ -n "$marker" ] || return 0
  : > "$marker.closing" || return 0
  rm -f "$marker"
  FAST_REPAIR_TIMER_MARKER=
  case "$generation" in *[!0-9]*|'') ;; *) fast_repair_progress_timer_tasks_finish "$generation" ;; esac
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 40 ]; do
      sleep 0.01
      i=$((i + 1))
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  FAST_REPAIR_TIMER_PID=
  rm -f "$marker.closing"
  rm -f "$wait_file"
  FAST_REPAIR_TIMER_WAIT_FILE=
}

FAST_REPAIR_WAIT_PID=
FAST_REPAIR_WAIT_OUTPUT=

fast_repair_progress_timer_wait_pid_publish() { # <pid>
  local wait_file=${FAST_REPAIR_TIMER_WAIT_FILE:-} pid=$1 tmp
  FAST_REPAIR_WAIT_PID=$pid
  [ -n "$wait_file" ] || return 1
  tmp=$(mktemp "$wait_file.XXXXXX") || return 1
  if ! printf '%s\n' "$pid" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$wait_file"; then
    rm -f "$tmp"
    return 1
  fi
}

fast_repair_progress_timer_wait_pid_clear() {
  local wait_file=${FAST_REPAIR_TIMER_WAIT_FILE:-}
  FAST_REPAIR_WAIT_PID=
  [ -n "$wait_file" ] || return 0
  rm -f "$wait_file"
}

# Stop whatever interruptible wait is still live. Safe to call when none is
# running, and idempotent. The recorded pid stays set for the window between
# `wait` returning and the clear, so a signal arriving there would otherwise
# reach an already-reaped pid; this applies the same rule
# fast_repair_progress_timer_notify does - signal only a pid proven to be a
# direct child of this watcher, and use the group form, which is what reaches a
# backend event reader forked inside the wait, only once it is also proven to be
# its own group leader.
fast_repair_progress_wait_stop() {
  local pid=${FAST_REPAIR_WAIT_PID:-} parent=${WATCHER_PID:-} pgid
  [ -n "$pid" ] || return 0
  FAST_REPAIR_WAIT_PID=
  case "$parent" in *[!0-9]*|'') return 0 ;; esac
  [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')" = "$parent" ] || return 0
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
  fi
  kill -TERM "$pid" 2>/dev/null || true
}

# Teardown form: stop the wait and drop the capture file the interrupted wait
# never got to read, so a stopped watcher leaves no .fm-event-wait.* behind.
fast_repair_progress_wait_cleanup() {
  fast_repair_progress_wait_stop
  [ -z "${FAST_REPAIR_WAIT_OUTPUT:-}" ] || rm -f "$FAST_REPAIR_WAIT_OUTPUT"
  FAST_REPAIR_WAIT_OUTPUT=
}

# A handoff published between forking a wait and making that wait reachable by
# fast_repair_progress_timer_notify would otherwise sit undelivered for the whole
# poll budget - the exact delay this cadence exists to remove. Re-scan once the
# pid is published and interrupt immediately if one is already waiting.
fast_repair_progress_wait_interrupt_if_pending() {
  fast_repair_progress_handoff_pending || return 0
  fast_repair_progress_wait_stop
}

fast_repair_progress_timer_sleep() { # <seconds>
  local seconds=$1 wait_file=${FAST_REPAIR_TIMER_WAIT_FILE:-} pid
  [ -n "$wait_file" ] || { sleep "$seconds"; return; }
  set -m
  ( sleep "$seconds" ) &
  pid=$!
  set +m
  if ! fast_repair_progress_timer_wait_pid_publish "$pid"; then
    wait "$pid" || true
    FAST_REPAIR_WAIT_PID=
    return
  fi
  fast_repair_progress_wait_interrupt_if_pending
  wait "$pid" || true
  fast_repair_progress_timer_wait_pid_clear
}

# The push wait is a foreground read on the backend's event stream, so unlike the
# sleep path it cannot be signalled where it stands. Run it as its own process
# group whose leader is published as the interruptible wait, so a Fast Repair
# progress result stops the wait and its backend reader together and the result
# is delivered in this cycle instead of after the whole poll budget. The record
# the wait printed is returned through FM_EVENT_WAIT_RECORD; the exit status is
# the backend's own, and an interrupted wait reports neither an edge (0) nor an
# unusable event path (2), so it falls through to the ordinary no-edge branch.
FM_EVENT_WAIT_RECORD=
fast_repair_progress_timer_wait_transition() { # <backend> <session> <budget> <state> <window...>
  local out pid rc=0
  FM_EVENT_WAIT_RECORD=
  out=$(mktemp "$STATE/.fm-event-wait.XXXXXX") || return 2
  chmod 0600 "$out" || { rm -f "$out"; return 2; }
  # Registered before the fork so a signalled teardown still removes it, and the
  # backend's own stderr stays on the watcher's stderr exactly as it does on the
  # unforked path, so a socket or subscribe diagnostic is reported identically.
  FAST_REPAIR_WAIT_OUTPUT=$out
  set -m
  ( FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$@" ) > "$out" &
  pid=$!
  set +m
  fast_repair_progress_timer_wait_pid_publish "$pid" || true
  fast_repair_progress_wait_interrupt_if_pending
  wait "$pid" || rc=$?
  fast_repair_progress_timer_wait_pid_clear
  FM_EVENT_WAIT_RECORD=$(cat "$out" 2>/dev/null || true)
  rm -f "$out"
  FAST_REPAIR_WAIT_OUTPUT=
  return "$rc"
}

fast_repair_progress_timer_wake() {
  local file lifecycle current_lifecycle generation id result status reasons=
  for file in "$STATE"/.fast-repair-progress-handoff-*; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    case "$file" in *.attempts) continue ;; esac
    exec 9< "$file" || continue
    IFS= read -r lifecycle <&9 || { exec 9<&-; continue; }
    if [[ "$lifecycle" =~ ^[0-9]+$ ]]; then
      generation=$lifecycle
      lifecycle=legacy
    else
      IFS= read -r generation <&9 || { exec 9<&-; continue; }
    fi
    IFS= read -r id <&9 || { exec 9<&-; continue; }
    IFS= read -r result <&9 || { exec 9<&-; continue; }
    if IFS= read -r <&9; then
      exec 9<&-
      continue
    fi
    exec 9<&-
    case "$generation" in *[!0-9]*|'') continue ;; esac
    case "$result" in ''|*$'\n'*|*$'\r'*) continue ;; esac
    fm_pr_task_id_valid "$id" || continue
    if ! fast_repair_eligible_task "$id"; then
      fast_repair_progress_handoff_forget "$file" || continue
      continue
    fi
    current_lifecycle=$(fast_repair_progress_lifecycle "$id" 2>/dev/null || true)
    if [ "$lifecycle" != "$current_lifecycle" ]; then
      fast_repair_progress_handoff_forget "$file" || continue
      continue
    fi
    status=0
    fast_repair_progress_record "$id" "$result" "$generation" || status=$?
    case "$status" in
      0)
        fast_repair_progress_handoff_forget "$file" || continue
        # The green rollup is the last transition this cadence exists to catch.
        # Retire the task from it only after its wake is durably queued, the same
        # order every other marker here follows.
        case "$result" in
          "fast-repair $id pr-checks-green:"*) : > "$(fast_repair_progress_green_marker "$id")" || true ;;
        esac
        reasons="$reasons $result"
        ;;
      1|3) fast_repair_progress_handoff_forget "$file" || continue ;;
      # The wake queue refused the record. Keep it on disk so a later cycle can
      # still deliver it, but count the attempt so it stops cutting waits short.
      *) fast_repair_progress_handoff_attempt_record "$file" || true; continue ;;
    esac
  done
  [ -z "$reasons" ] || wake "check:${reasons}"
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  fast_repair_progress_timer_start
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    fast_repair_progress_timer_sleep "$POLL"
    fast_repair_progress_timer_finish
    fast_repair_progress_timer_wake
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    fast_repair_progress_timer_sleep "$POLL"
    fast_repair_progress_timer_finish
    fast_repair_progress_timer_wake
    return
  fi

  if [ -n "${FAST_REPAIR_TIMER_WAIT_FILE:-}" ]; then
    fast_repair_progress_timer_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}"
    rc=$?
    rec=$FM_EVENT_WAIT_RECORD
  else
    rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
    rc=$?
  fi
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      fast_repair_progress_timer_sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
  fast_repair_progress_timer_finish
  fast_repair_progress_timer_wake
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Before acquiring the watcher lock or enumerating any runnable check, replace
# or quarantine checks created by older versions. The migration compares bytes
# and reads data only; it never invokes legacy check files through Bash.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || {
  echo "watcher: PR check migration blocked; refusing to execute state checks" >&2
  exit 1
}

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
WATCHER_RECOVERY_PENDING=0
if [ -n "${FM_LOCK_RECOVERED_PID:-}" ]; then
  WATCHER_RECOVERY_PENDING=1
fi
if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
  echo "watcher: recovery state could not be consumed safely; retaining stale lock evidence" >&2
  exit 1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
  WATCHER_RECOVERY_PENDING=0
elif [ "$FM_RECOVERY_MARKER_ACTION" = recover ]; then
  WATCHER_RECOVERY_PENDING=1
fi
watcher_cleanup() {
  local cleanup_status=0 owns_lock=0 transition=release-lock
  fast_repair_progress_timer_finish
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" = "${WATCHER_PID:-}" ]; then
    owns_lock=1
    if [ "${WATCHER_RECOVERY_PENDING:-0}" -eq 1 ] \
      && [ "${FM_WATCH_DELIVERED_REASON:-}" = "check: rearm-resurface" ]; then
      transition=release-lock-existing
    fi
  fi
  fm_active_check_stop || cleanup_status=1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  if [ "$owns_lock" -eq 1 ] \
    && ! fm_recovery_transition "$WATCHER_DOWNTIME_MARKER" "$transition" "$WATCH_LOCK" downtime; then
    echo "watcher: recovery state could not be persisted; retaining stale lock evidence" >&2
    cleanup_status=1
  fi
  return "$cleanup_status"
}
trap watcher_cleanup EXIT
trap 'exit 1' HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
# shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
FM_WATCH_DELIVERY_PID=$WATCHER_PID
FM_WATCH_DELIVERY_IDENTITY=$(fm_pid_identity "$WATCHER_PID" 2>/dev/null || true)
printf '%s\n' "$FM_WATCH_DELIVERY_IDENTITY" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# A merged poll may have queued its terminal wake and then lost the process
# between receipt publication and fixed-path removal.
# Finish only identity-bound retirement receipts before any check can run.
if ! fm_pr_poll_retirement_recover_all "$STATE" "$SCRIPT_DIR/fm-pr-poll.sh"; then
  reason="check: rejected unauthenticated PR poll retirement receipts:$FM_PR_POLL_RETIREMENT_REJECTED"
  fm_wake_append check pr-poll-retirement "$reason" || exit 1
  touch "$STATE/.last-check"
  wake "$reason"
fi

resurface_after_downtime() {
  if [ "$WATCHER_RECOVERY_PENDING" -ne 1 ]; then
    if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
      echo "watcher: recovery state could not be consumed safely" >&2
      exit 1
    fi
    [ "$FM_RECOVERY_MARKER_ACTION" = recover ] || return 0
  fi
  wake "check: rearm-resurface"
}

if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
  touch "$STATE/.last-watcher-beat"
  handling_wait=0
  while [ "$handling_wait" -lt 600 ]; do
    fm_recovery_marker_snapshot "$WATCHER_DOWNTIME_MARKER" || true
    case "$FM_RECOVERY_MARKER_TOKEN" in
      pending:downtime:*) ;;
      *) break ;;
    esac
    sleep 0.05
    handling_wait=$((handling_wait + 1))
  done
  [ "$handling_wait" -lt 600 ] || WATCHER_RECOVERY_PENDING=1
fi

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  fm_pending_reply_tick "$STATE" || true

  # This is the only shortened cadence. It reads only durable Fast Repair task
  # records and leaves ordinary task scanning and schedules untouched.
  fast_repair_progress_discover
  fast_repair_progress_timer_wake

  # Process-to-event liveness repair. This never discovers a result by polling:
  # each registered source has its own child blocking on that source, and this
  # only republishes results already captured durably and restarts a source
  # whose owner is gone. It is a no-op with nothing registered.
  if [ -d "$STATE/procevent" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
  fi
  # Then deliver any queued-but-unsurfaced result, including one a runner
  # published while this watcher was between cycles.
  procevent_surface_queued

  # A process-event result carries richer adapter-owned wake context than the
  # generic recovery reason, so give that owner first refusal.
  resurface_after_downtime

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      is_pr_poll=0
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          is_pr_poll=1
          provider=$FM_PR_POLL_SNAPSHOT_PROVIDER
          url=$FM_PR_POLL_SNAPSHOT_URL
          host=$FM_PR_POLL_SNAPSHOT_HOST
          path=$FM_PR_POLL_SNAPSHOT_PATH
          number=$FM_PR_POLL_SNAPSHOT_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        if [ "$is_pr_poll" -eq 1 ] && [ "$out" = merged ]; then
          if fm_pr_poll_retirement_publish "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" "$out"; then
            fm_pr_poll_retirement_recover_one "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
              || triage_log "merged PR poll retirement remains recoverable for $id"
          else
            triage_log "merged PR poll retirement deferred because its canonical snapshot changed for $id"
          fi
        fi
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=${w//:/_}
    key=${key//\//_}
    key=${key//./_}
    last=$(last_status_line "$STATE/$task.status")
    if ! status_is_paused_or_captain_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$w"
    fi
    if [ "$kind" = secondmate ] && ! status_is_paused "$last"; then
      continue
    fi
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    prev=$(cat "$hf" 2>/dev/null || true)
    # Busy match: a backend's native semantic state when available (herdr), else
    # the last 6 non-blank lines only (the TUI footer area, where every verified
    # harness renders its busy indicator) so busy-looking strings in displayed
    # content cannot suppress stale detection. Read once per window per poll and
    # reused below so a busy verdict is consistent within one cycle.
    if window_is_busy "$w" "$tail40"; then busy_now=0; else busy_now=1; fi
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      if [ "$n" -ge 2 ] && [ "$busy_now" -ne 0 ]; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$w" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: the crew declared an external wait, or a declared pause or
          #     captain hold is paired with a confidently dead agent, so absorb on
          #     the long PAUSE_RESURFACE_SECS cadence instead of wedge-escalating;
          #   - none: no running pipeline, no exact busy verdict, no declared pause.
          #     Surface immediately so firstmate inspects the inconclusive state
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$w"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping,
        # unless a genuinely busy pane has gone too long with no completed turn -
        # then route it through the same wedge timer instead of erasing it.
        if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
          wedge_timer_check "$w" "$ssf" "busy (no completed turn)" "$ewf"
        else
          rm -f "$ssf" "$ewf"
        fi
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_captain_held "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
        wedge_timer_check "$w" "$ssf" "busy (no completed turn)" "$ewf"
      else
        rm -f "$ssf" "$ewf"
      fi
      task=$(window_to_task "$w" "$STATE")
      if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")" && [ "$busy_now" -ne 0 ]; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$w" ;;
        esac
      else
        [ -e "$pf" ] && clear_pause_tracking "$w"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
