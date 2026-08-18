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
# A PROVABLY-WORKING crew whose task carries a still-open captain decision (a
# needs-decision/blocked the keyed fold has not closed) trades the wedge timer for
# that same long cadence: its inactivity is explained by the open decision, not a
# wedge, so it re-surfaces once per window instead of wedge-escalating every
# STALE_ESCALATE_SECS. The absorb-only-when-provably-working rule above is
# unweakened - a crew that stops or dies with a decision still open has no working
# signal, so it surfaces exactly as it does today. When the decision closes the
# normal wedge cadence resumes immediately, so a crew still mute after the answer
# re-escalates.
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
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
#   check: inactive-outcome bounded poll-loop reconciliation found a suspicious
#                          inactive terminal outcome that still lacks its durable
#                          upstream receipt
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
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
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
# The size:mtime signal signature and .seen-* marker format are owned by
# bin/fm-wake-lib.sh (fm_wake_signal_sig, fm_wake_signal_seen_path), shared
# with the drain's annotation staleness check and this home's own bookkeeping
# writers' guarded self-announced append.

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
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

# Absorb a stale pane on the long PAUSE_RESURFACE_SECS re-surface cadence and
# re-surface it once per window for a recheck so it cannot rot invisibly. The
# ONE implementation of that cadence, shared by every caller that trades the
# wedge timer for it (a declared pause, a dead-agent captain hold, a crew parked
# on a still-open captain decision) so a future adjustment - a different window,
# a backoff - cannot silently reach only one of them. Callers stay distinct
# through their own markers, reason text and log label, passed in: <flag-prefix>
# is the absorb marker's `.`-prefixed name stem (never shared: a decision wait is
# not a declared pause), <resurface-prefix> its throttle-marker stem,
# <reason-detail> the parenthetical appended to the wake reason and
# <log-detail> the triage-log qualifier, both with @AGE@ substituted for the
# idle age. <flag-payload> is written into the absorb marker (empty for a bare
# flag). Called on any stale poll once the caller permits the bounded cadence,
# so it must be cheap: it NEVER re-reads crew state. The re-surface age is
# anchored on <status-mtime>, the caller's reading of the status file mtime,
# rather than a per-hash marker, so a churny idle pane (a ticking clock, a token
# counter) cannot keep resetting the cadence the way a hash-tied timer would -
# which also means the throttle marker must OUTLIVE a hash change, exactly like
# the wedge timer must not. The throttle marker records the last re-surface epoch
# so, once past the window, it fires once per window rather than every poll.
# Advances the stale suppressor to <hash> and disarms the wedge timer.
absorb_stale_on_long_cadence() {  # <window> <hash> <status-mtime> <flag-prefix> <resurface-prefix> <reason-detail> <log-detail> [flag-payload]
  local win=$1 h=$2 mtime=$3 flag_prefix=$4 rf_prefix=$5 reason_detail=$6 log_detail=$7 payload=${8-}
  local key age rf rf_age reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '%s' "$h" > "$STATE/.stale-$key"
  printf '%s' "$payload" > "$STATE/.$flag_prefix$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.$rf_prefix$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (${reason_detail//@AGE@/$age})"
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale (${log_detail//@AGE@/$age}): $win"
}

# The epoch <task>'s status file last changed, falling back to now when the file
# is missing or the backend reports an unusable stamp. The ONE reader of that
# anchor: the long-cadence absorb ages against it, and the decision-held marker
# stores it as the reading its fold ran against, so both must derive it the same
# way.
status_mtime_or_now() {  # <task>
  local m
  m=$(stat_mtime "$STATE/$1.status")
  case "$m" in ''|*[!0-9]*) m=$(date +%s) ;; esac
  printf '%s' "$m"
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# dead-agent captain-held transfer. Flags the key paused; see
# absorb_stale_on_long_cadence for the shared cadence.
handle_paused_stale() {  # <window> <task> <hash>
  absorb_stale_on_long_cadence "$1" "$3" "$(status_mtime_or_now "$2")" paused- paused-resurfaced- \
    'paused @AGE@s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds' \
    'paused, awaiting external, age @AGE@s'
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
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" \
    "$STATE/.decision-held-$key"
}

# Absorb a PROVABLY-WORKING stale pane whose inactivity is explained by a
# still-open captain decision on its task (a needs-decision/blocked the fold has
# not closed). Same long cadence as handle_paused_stale but kept DISTINCT: a
# captain decision wait is not a self-resolving external pause, so it uses its
# own markers (.decision-held-/.decision-resurfaced-) and reason text and never
# touches the .paused-* flag. It replaces the wedge timer that would otherwise
# re-escalate the same parked crew every STALE_ESCALATE_SECS - the live 2026-08
# case where a crew parked on a captain decision fired a stale every four
# minutes, each costing a full firstmate turn only to conclude "still waiting for
# the same decision". Only ever reached from a first-sight path that already
# proved the crew working, or from a later poll of the SAME hash that path
# absorbed, so a crew that stopped or died while a decision stayed open is never
# swallowed here - it keeps surfacing through the ordinary terminal/non-terminal
# triage. That bound rests on the marker naming the hash it was written for
# (decision_held_absorbed is the only reader): a marker outliving its absorb -
# through a reset sub-branch, a pause-tracking reset, anything - can then never
# re-route a later, differently-classified pane onto this cadence.
#
# Re-validating the decision must stay cheap: task_has_open_decision re-folds the
# status file's entire lifetime, so on a later poll it runs ONLY when a new line
# could have closed the decision. The marker's second field is the status file's
# size:mtime signature the fold last ran against - the same append-detecting
# token scan_signals uses, rather than a bare second-resolution mtime a
# same-second closing append could slip through. An unchanged signature means no
# line landed, so the decision is still open and the absorb continues without
# folding. On a changed signature the fold re-runs: still open re-stamps the
# marker, closed clears the tracking and returns 1 so the caller skips this poll
# and the normal wedge cadence resumes from a clean first-sight on the next one -
# a crew that stays mute AFTER the answer is a real wedge and re-escalates
# exactly as before.
#
# That stored signature is only sound if it is the one the fold actually saw, so
# a first-sight caller - which folds itself, before calling - passes ITS pre-fold
# reading as <folded-status-signature> and this skips the re-validate. Reading
# the signature here instead would record a post-fold value: a resolved line
# landing in between would be stamped as already-folded, the re-validate would
# never fire on it, and the pane would stay parked on the long cadence past the
# answer. The age anchor carries no such ordering requirement - it is read here.
handle_decision_held_stale() {  # <window> <task> <hash> [folded-status-signature]
  local win=$1 task=$2 h=$3 sig tok
  if [ "$#" -ge 4 ]; then
    sig=$4
  else
    sig=$(fm_wake_signal_sig "$STATE/$task.status")
    tok=$(decision_held_token "$win")
    if [ -n "$tok" ] && [ "${tok#*$'\t'}" != "$sig" ] \
       && ! task_has_open_decision "$STATE" "$task"; then
      clear_decision_held_tracking "$win"
      return 1
    fi
  fi
  absorb_stale_on_long_cadence "$win" "$h" "$(status_mtime_or_now "$task")" \
    decision-held- decision-resurfaced- \
    'decision held @AGE@s, awaiting captain - rechecked on a long cadence not a wedge; confirm the decision is still open' \
    'decision held, awaiting captain, age @AGE@s' "$h"$'\t'"$sig"
}

# The "<hash>\t<status-signature>" a decision-held absorb recorded for <window>,
# empty when none. A marker written by an older watcher carries no TAB, so it
# reads as a hash that can never match a real pane hash - it simply expires.
decision_held_token() {  # <window>
  local key
  key=$(printf '%s' "$1" | tr ':/.' '___')
  cat "$STATE/.decision-held-$key" 2>/dev/null || true
}

# 0 iff <window>'s decision-held marker was written by an absorb of THIS exact
# stale hash. The subsequent-poll triage routes on this rather than on the
# marker's mere existence: a residual marker from an absorb the pane has since
# moved past must never hand a differently-classified pane - a crew that has
# stopped, or one with no open decision at all whose wedge timer is running - the
# long cadence and a disarmed wedge timer.
decision_held_absorbed() {  # <window> <hash>
  local tok
  tok=$(decision_held_token "$1")
  [ -n "$tok" ] && [ "${tok%%$'\t'*}" = "$2" ]
}

# Clear decision-held tracking for <window>. Called by handle_decision_held_stale
# when a re-validating fold finds the task's decision closed, so the normal wedge
# cadence resumes from a clean first-sight on the next poll. Also resets the
# stale suppressor and wedge timer so first-sight re-evaluates the pane with the
# now-closed decision's status log, rather than treating the prior decision-held
# hash as already-surfaced.
clear_decision_held_tracking() {  # <window>
  local win=$1 key
  key=$(printf '%s' "$win" | tr ':/.' '___')
  rm -f "$STATE/.decision-held-$key" "$STATE/.decision-resurfaced-$key" \
    "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
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
    sig=$(fm_wake_signal_sig "$f") || continue
    [ -n "$sig" ] || continue
    sf=$(fm_wake_signal_seen_path "$STATE" "$f")
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
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
  local pgid
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
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
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
    sleep "$POLL"
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
    sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
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
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
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

  # The existing poll loop also owns the bounded inactive-outcome cadence.
  # This is mechanical and silent unless a durable terminal-outcome obligation
  # was created, so quiet cycles never wake firstmate or consume model tokens.
  inactive_out=
  if inactive_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-inactive-reconcile.sh" scan 2>/dev/null); then
    if [ -n "$inactive_out" ]; then
      wake "check: inactive-outcome"
    fi
  else
    triage_log "inactive-outcome reconciliation unavailable"
  fi

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
              # A provably-working crew whose task carries a still-open captain
              # decision is not wedged, it is parked: its inactivity is explained
              # by that decision, so trade the wedge timer for the long
              # PAUSE_RESURFACE_SECS cadence instead of re-escalating every
              # STALE_ESCALATE_SECS. Gated on the provably-working verdict just
              # proved above, so a crew that stopped or died with a decision still
              # open takes the surface-immediately path below exactly as before.
              dsig=$(fm_wake_signal_sig "$STATE/$task.status")
              if task_has_open_decision "$STATE" "$task"; then
                handle_decision_held_stale "$w" "$task" "$h" "$dsig"
              else
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
              fi
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif decision_held_absorbed "$w" "$h"; then
            # This exact hash was absorbed as decision-held on a prior poll -
            # keep it on the long cadence, re-validating the decision only when
            # a new status line could have closed it (handle_decision_held_stale
            # owns that signature-bounded check, so no whole-file fold runs here).
            handle_decision_held_stale "$w" "$task" "$h"
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
                # Same decision-held trade as the terminal branch, on the same
                # provably-working verdict: a parked crew keeps the long cadence,
                # everything else keeps today's wedge timer untouched.
                dsig=$(fm_wake_signal_sig "$STATE/$task.status")
                if task_has_open_decision "$STATE" "$task"; then
                  handle_decision_held_stale "$w" "$task" "$h" "$dsig"
                else
                  printf '%s' "$h" > "$sf"
                  date +%s > "$ssf"
                  triage_log "absorbed non-terminal stale (provably working): $w"
                fi
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
            if decision_held_absorbed "$w" "$h"; then
              # Absorbed as decision-held on a prior poll of this same hash -
              # stay on the long cadence and let handle_decision_held_stale run
              # its signature-bounded re-validate instead of the wedge timer.
              handle_decision_held_stale "$w" "$task" "$h"
            elif [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
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
        # Neither decision-held marker is reset here: this arm is the UNCHANGED
        # hash, so the pane still sits on exactly the hash the absorb marker
        # names, and .stale-<key> still names it too - dropping the marker would
        # strand the pane on the wedge timer with no first-sight left to ever
        # route it back, so one blink of a semantic busy verdict behind a frozen
        # screen would undo the absorb for good. Keeping it makes that blink
        # self-repairing: the next idle poll matches the marker again and the
        # resumed absorb disarms the timer this reset armed. The throttle stays
        # for the same reason it survives a churning pane - one re-surface per
        # PAUSE_RESURFACE_SECS, owned by the decision's closure
        # (clear_decision_held_tracking), exactly as .paused-resurfaced-* is
        # owned by clear_pause_state.
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
      # The hash CHANGED, so the decision-held marker names a stale hash this
      # pane has moved off: it dies here whichever sub-branch runs, and the next
      # stable poll is a first-sight that re-reads crew state from scratch.
      rm -f "$STATE/.decision-held-$key"
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
