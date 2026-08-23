#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal path is absorb-only-when-provably-working: such a signal
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed.
# The liveness probe below replaced the old pane-stillness stale path (plan v3
# U1.4): window stillness is not a signal, liveness is measured at the process
# (probe_window owns the decision procedure), and a declared wait is the
# machine field owned by bin/fm-wait-lib.sh, never a prose prefix - a worker's
# `paused:` status append still wakes once through the signal path, but only
# the field silences the probe.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed
#                          status file's newly appended CONTENT classifies as
#                          wake (status_span_wake_class in fm-classify-lib.sh)
#                          OR a routine-content signal's crew is not provably
#                          working, unless afk is active
#   stale: <window> (...)  a liveness-probe alarm, each carrying its evidence
#                          in the reason:
#                          - "agent process gone: <state>": the endpoint's
#                            process family confidently holds no agent
#                            (fm_backend_agent_state dead/missing); fired once
#                            per observed death.
#                          - "no progress evidence ...": the agent looks alive
#                            but a whole probe interval passed with no CPU
#                            delta, no worktree write, and no pipeline
#                            movement; while unrefuted it re-fires at most
#                            once per FM_PAUSE_RESURFACE_SECS.
#                          - "turn ended with no run and no report": the crew
#                            is semantically idle with no attributed run and
#                            owes an inspection; fired once per idle identity.
#                          - "declared wait expired ...": the machine wait
#                            field passed its deadline; fired exactly once per
#                            field identity, never once per poll.
#                          An ACTIVE declared wait silences every probe alarm
#                          until its deadline, even while a run or busy pane
#                          makes the worker look occupied - the old precedence
#                          of surface/run-step busy-ness over the worker's own
#                          declaration is abolished, as is the escalation
#                          counter with its demand-deep-inspection decoration.
#                          An alarm later refuted by real progress clears
#                          itself and DOUBLES this window's probe interval
#                          (bounded backoff), so a false alarm makes the probe
#                          quieter, never louder. Alarms are inspection
#                          triggers only - never an automatic interrupt,
#                          signal, or restart of the worker or its tool
#                          process.
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
#   heartbeat              fleet-scan backstop found unclassified actionable
#                          content, or an open decision due its bounded
#                          re-surface, unless afk is active
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
# shellcheck source=bin/fm-wait-lib.sh
. "$SCRIPT_DIR/fm-wait-lib.sh"

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
# path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a
# liveness-probe alarm, or anything unknown) is written to the durable queue and
# exits, which is what wakes the LLM through the background-task completion. The
# same classifier (fm-classify-lib.sh) backs the away-mode daemon; while
# state/.afk exists the daemon owns triage, so this watcher reverts to one-shot
# (enqueue + exit on every wake) and never double-triages - the probe still
# runs its cheap process-evidence reads, but skips the costly current-state
# split and hands every alarm to the daemon undecorated.
PROBE_INTERVAL_SECS=${FM_PROBE_INTERVAL_SECS:-240}  # base seconds between one window's liveness probes
# Each refuted alarm doubles that window's probe interval (backoff instead of
# escalation), capped at 2^PROBE_BACKOFF_MAX times the base. There is no
# counter that makes alarms louder: repetition earns quiet, evidence earns a
# wake.
PROBE_BACKOFF_MAX=${FM_PROBE_BACKOFF_MAX:-6}
# Bounded re-surface cadence: an unrefuted no-progress alarm, and any other
# deliberately quiet absorb, re-surfaces at most once per PAUSE_RESURFACE_SECS
# so nothing can rot invisibly behind a wake that was lost or mishandled.
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

# The ONE derivation of a window's per-window marker key: `:`, `/` and `.` become
# `_` so a window name is usable as a filename suffix. Every per-window file the
# watcher keeps is named by it (.probe-last-, .probe-backoff-, .alarm-,
# .alarm-resurfaced-, .agent-gone-, .idle-surfaced-, .wait-checked-, and
# bin/fm-busy-lib.sh's .proc-cpu- sample), and live homes hold those markers on
# disk under the current format, so the format lives here alone: a second copy is
# how a future change to it silently orphans a window's markers instead of clearing
# them. The helpers below take the derived key rather than re-deriving it, so one
# poll of one window derives it once.
window_key() {  # <window>
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
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

# One bounded re-surface for a pane the watcher is deliberately keeping quiet,
# so no quiet absorb can rot invisibly. <age> is how long the current quiet
# stretch has held and <throttle> is the per-window marker whose mtime records
# the last re-surface, so once past PAUSE_RESURFACE_SECS the pane wakes once
# per window rather than every poll. Today's one caller is the unrefuted
# no-progress alarm; the helper stays caller-agnostic so any future quiet
# absorb shares the same bounded cadence. Returns without waking while either
# the quiet stretch or the throttle is inside the window; wake() itself exits
# the cycle, exactly as it does inline.
resurface_absorbed() {  # <window> <throttle-marker> <age> <reason>
  local win=$1 throttle=$2 age=$3 reason=$4
  [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] || return 0
  [ "$(age_of "$throttle")" -ge "$PAUSE_RESURFACE_SECS" ] || return 0   # 999999 when no prior re-surface
  fm_wake_append stale "$win" "$reason" || exit 1
  date +%s > "$throttle"
  wake "$reason"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# --- liveness probe (plan v3 U1.4) ------------------------------------------
#
# probe_window is the ONE statement of the watcher's liveness alarm rule.
# Sources, in consultation order (the caller has already handled the machine
# wait field and excluded secondmates):
#   1. fm_backend_agent_state - a confident dead/missing verdict is the
#      agent-gone alarm, fired once per observed death.
#   2. progress evidence, cheap to costly, any one of which proves liveness:
#      CPU delta across the probe interval (fm_busy_cpu_progress), task-
#      worktree writes since the previous probe (crew_worktree_written_since),
#      pipeline movement (crew_run_progressed). Evidence found clears an
#      unrefuted alarm and doubles this window's probe interval (backoff).
#   3. flat - no evidence across a whole interval - splits on the semantic
#      turn state: an idle crew with no attributed run owes an inspection
#      (surfaced once per idle identity); an idle crew whose authoritative
#      state is a vendor-derived external wait stays quiet on the bounded
#      re-surface cadence; everything else is the no-progress alarm, fired
#      once and then re-surfaced at most once per PAUSE_RESURFACE_SECS while
#      unrefuted.
# Window stillness and the rendered pane are read by NONE of these; every
# alarm is inspection-only and never touches the worker. In away mode the
# daemon owns triage, so the costly current-state split is skipped and every
# flat verdict goes to the queue undecorated.
# probe_window touches .probe-last-<key> itself, right after the evidence
# reads that anchor on the PREVIOUS probe time, so a wake exit cannot leave
# the window due again on the very next poll.

probe_backoff_interval() {  # <key> -> effective probe interval seconds
  local n
  n=$(cat "$STATE/.probe-backoff-$1" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt "$PROBE_BACKOFF_MAX" ] && n=$PROBE_BACKOFF_MAX
  echo $(( PROBE_INTERVAL_SECS * (1 << n) ))
}

probe_refute_alarm() {  # <key> <evidence> - progress arrived after an alarm
  local key=$1 evidence=$2 n
  [ -e "$STATE/.alarm-$key" ] || return 0
  rm -f "$STATE/.alarm-$key" "$STATE/.alarm-resurfaced-$key"
  n=$(cat "$STATE/.probe-backoff-$key" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$(( n + 1 ))
  [ "$n" -gt "$PROBE_BACKOFF_MAX" ] && n=$PROBE_BACKOFF_MAX
  echo "$n" > "$STATE/.probe-backoff-$key"
  triage_log "alarm refuted by $evidence - probe interval backs off to 2^$n x base: $key"
}

# The idle identity: the newest cheap turn boundary. Any completed turn or
# busy-record change mints a new identity, so the once-only idle surfacing
# re-arms per turn instead of firing per poll.
probe_idle_identity() {  # <task>
  local f
  for f in "$STATE/$1.busy-state" "$STATE/$1.turn-ended" "$STATE/$1.status"; do
    if [ -e "$f" ]; then
      printf '%s:%s' "$(stat_mtime "$f")" "$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')"
      return 0
    fi
  done
  printf 'none'
}

probe_window() {  # <window> <task> <key>
  local win=$1 task=$2 key=$3 backend agent cpu evidence='' cpu_note verdict cls idle_id reason alarm_epoch age
  local anchor="$STATE/.probe-last-$key"
  backend=$(window_backend "$win")
  agent=$(fm_backend_agent_state "$backend" "$win")
  case "$agent" in
    dead|missing)
      date +%s > "$anchor"
      if [ "$(cat "$STATE/.agent-gone-$key" 2>/dev/null)" != "$agent" ]; then
        # Queue-safety invariant: enqueue BEFORE advancing the suppressor, so
        # a watcher killed between the two never swallows the death.
        reason="stale: $win (agent process gone: $agent - the endpoint recorded for $task holds no live agent)"
        fm_wake_append stale "$win" "$reason" || exit 1
        printf '%s' "$agent" > "$STATE/.agent-gone-$key"
        wake "$reason"
      fi
      triage_log "absorbed probe (agent still $agent, already surfaced): $win"
      return 0
      ;;
  esac
  rm -f "$STATE/.agent-gone-$key"
  if [ ! -e "$anchor" ]; then
    # First probe for this window: every delta source needs a measured
    # interval, so seed the CPU sample and the anchor and measure next time.
    # Agent death above still fires immediately - it is not delta-based.
    fm_busy_cpu_progress "$backend" "$win" "$STATE" "$key" >/dev/null
    date +%s > "$anchor"
    triage_log "absorbed probe (first probe, seeding baselines): $win"
    return 0
  fi
  cpu=$(fm_busy_cpu_progress "$backend" "$win" "$STATE" "$key")
  case "$cpu" in
    progress*)
      evidence="cpu delta ${cpu#progress }"
      cpu_note="cpu active"
      ;;
    no-baseline)
      # First sample for this key: a delta needs two reads, so this probe
      # neither alarms nor refutes. The next due probe measures for real.
      date +%s > "$anchor"
      triage_log "absorbed probe (first cpu sample, no interval yet): $win"
      return 0
      ;;
    flat*) cpu_note="cpu flat across ${cpu#flat }" ;;
    *) cpu_note="cpu source unavailable" ;;
  esac
  if [ -z "$evidence" ] && crew_worktree_written_since "$task" "$STATE" "$anchor"; then
    evidence="worktree writes"
  fi
  if [ -z "$evidence" ] && ! afk_present && crew_run_progressed "$task" "$STATE"; then
    evidence="pipeline movement"
  fi
  date +%s > "$anchor"
  if [ -n "$evidence" ]; then
    probe_refute_alarm "$key" "$evidence"
    triage_log "absorbed probe (progress: $evidence): $win"
    return 0
  fi
  # Flat. Split on the semantic turn state unless the daemon owns triage.
  if ! afk_present; then
    verdict=$(fm_busy_classify_meta "$STATE/$task.meta" "$task" "$STATE" "")
    if [ "${verdict%% *}" = idle ]; then
      cls=$(crew_absorb_class "$task")
      case "$cls" in
        paused)
          # A vendor-derived external wait (e.g. the Claude account-limit
          # widget). Quiet, but bounded: re-surface once per cadence window.
          [ -e "$STATE/.flat-since-$key" ] || date +%s > "$STATE/.flat-since-$key"
          age=$(age_of "$STATE/.flat-since-$key")
          triage_log "absorbed probe (flat but externally waiting per current state): $win"
          resurface_absorbed "$win" "$STATE/.alarm-resurfaced-$key" "$age" \
            "stale: $win (externally waiting ${age}s per its own current state, rechecked on the long cadence - confirm the wait still holds)"
          return 0
          ;;
        working) ;;  # attributed run with no measured movement: alarm below
        *)
          idle_id=$(probe_idle_identity "$task")
          if [ "$(cat "$STATE/.idle-surfaced-$key" 2>/dev/null)" != "$idle_id" ]; then
            # Queue-safety invariant: enqueue before the suppressor advances.
            reason="stale: $win (turn ended with no run and no report - inspect: it may be finished via an interactive menu, waiting on a decision, or stopped)"
            fm_wake_append stale "$win" "$reason" || exit 1
            printf '%s' "$idle_id" > "$STATE/.idle-surfaced-$key"
            wake "$reason"
          fi
          triage_log "absorbed probe (idle already surfaced for this turn): $win"
          return 0
          ;;
      esac
    fi
  fi
  rm -f "$STATE/.flat-since-$key"
  # The no-progress alarm: evidence of a whole interval with no movement.
  if [ ! -e "$STATE/.alarm-$key" ]; then
    # Queue-safety invariant: enqueue before the alarm marker suppresses.
    reason="stale: $win (no progress evidence for $(probe_backoff_interval "$key")s: $cpu_note, no worktree writes, no pipeline movement - inspect for a hung call or wedge)"
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$STATE/.alarm-$key"
    wake "$reason"
  fi
  alarm_epoch=$(cat "$STATE/.alarm-$key" 2>/dev/null || echo 0)
  case "$alarm_epoch" in ''|*[!0-9]*) alarm_epoch=0 ;; esac
  age=$(( $(date +%s) - alarm_epoch ))
  triage_log "absorbed probe (still flat, alarm standing ${age}s): $win"
  resurface_absorbed "$win" "$STATE/.alarm-resurfaced-$key" "$age" \
    "stale: $win (still no progress evidence ${age}s after the unhandled alarm - inspect for a hung call or wedge)"
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

# Content triage for a changed-signal file list (U1.3: wake on content, never on
# the last line's verb alone). 0 when any listed status file's newly appended
# span - the bytes since this watcher's own .seen-* signature - classifies as
# wake. The rule itself is owned by bin/fm-classify-lib.sh
# (status_span_wake_class); this function owns only the span-cursor mechanics,
# reusing the seen signature's recorded size as the already-classified byte
# offset so no second cursor exists. Non-.status arguments (.turn-ended markers
# carry no content) are skipped.
signal_span_actionable() {  # <file> ...
  local f prev offset kind span task
  for f in "$@"; do
    case "$f" in *.status) ;; *) continue ;; esac
    [ -e "$f" ] || continue
    prev=$(cat "$(fm_wake_signal_seen_path "$STATE" "$f")" 2>/dev/null || true)
    offset=${prev%%:*}
    task=${f##*/}
    task=${task%.status}
    kind=$(grep '^kind=' "$STATE/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    span=$(status_lines_from_offset "$f" "$offset") || span=''
    [ -n "$span" ] || continue
    if [ "$(printf '%s\n' "$span" | status_span_wake_class "$kind")" = wake ]; then
      return 0
    fi
  done
  return 1
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

# Content-rule heartbeat backstop (U1.3). 0 if either:
#   - any status file's span since its .seen-* signature classifies as wake -
#     content the signal path never classified, which only a crash or race can
#     produce, caught here so it cannot rot;
#   - or the fleet-wide open-decisions fold still carries an open decision and
#     none has been re-surfaced for PAUSE_RESURFACE_SECS - the same bounded
#     anti-rot cadence a declared pause gets, so a forgotten open decision
#     re-wakes once per window instead of waiting silently for the next drain.
# Pure detect, no side effects: the caller enqueues its heartbeat wake first,
# then records the re-surface by touching the throttle marker. The fold call
# reuses the drain's own presentation lock via a non-blocking try, so a drain
# mid-presentation (which is itself about to print OPEN DECISIONS) skips the
# duplicate re-surface instead of contending.
OPEN_DECISIONS_RESURFACE_MARKER="$STATE/.last-open-decisions-resurface"
heartbeat_scan_finds_actionable() {
  local open
  if signal_span_actionable "$STATE"/*.status; then
    return 0
  fi
  if [ "$(age_of "$OPEN_DECISIONS_RESURFACE_MARKER")" -ge "$PAUSE_RESURFACE_SECS" ]; then
    if fm_lock_try_acquire "$STATE/.status-presentation-lock"; then
      open=$(scan_open_decisions_incremental "$STATE") || open=''
      fm_lock_release "$STATE/.status-presentation-lock"
      [ -n "$open" ] && return 0
    fi
  fi
  return 1
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of on the liveness probe's
# cadence. For every other home - no push-capable window, backend not
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
    # they are excluded from the fast escalation exactly as the liveness probe
    # skips them.
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
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" != 1 ]; then
  if ! fm_recovery_marker_reopen_announced "$WATCHER_DOWNTIME_MARKER"; then
    echo "watcher: recovery state could not be reopened safely; retaining stale lock evidence" >&2
    exit 1
  fi
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
  # Handling successors already have a predecessor-delivered wake on the way.
  # Re-announcing from this cycle is what turned a lost handshake into an
  # unbounded recovery loop; stay in the poll loop and supervise instead.
  if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
    return 0
  fi
  if [ "$WATCHER_RECOVERY_PENDING" -ne 1 ]; then
    if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
      echo "watcher: recovery state could not be consumed safely" >&2
      exit 1
    fi
    [ "$FM_RECOVERY_MARKER_ACTION" = recover ] || return 0
  fi
  wake "check: rearm-resurface"
}

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
    #   - the newly appended status CONTENT since this watcher's own seen
    #     signature classifies as wake (signal_span_actionable above, rule owned
    #     by bin/fm-classify-lib.sh's status_span_wake_class) - never the last
    #     line's verb alone, so a decision buried under a quick routine append
    #     still wakes and a stale terminal leftover no longer re-reads as new;
    #   - or it is a routine-content wake (a bare turn-end, working: lines) whose
    #     crew is NOT provably working - the crew stopped its turn with no
    #     actively-running pipeline and no busy pane, so it may be done (even via
    #     an interactive menu that wrote no done: status), waiting on a decision,
    #     or wedged. Absorbing such a turn-end is exactly the swallowed-finish
    #     this guard exists for.
    # Actionable -> enqueue, advance .seen-* markers, exit. Routine content with
    # a provably-working crew is BUNDLED: the markers advance so it will not
    # re-fire, and the content reaches the next presentation's annotations and
    # UNREAD STATUS sections instead of costing its own wake turn. The
    # provably-working check is the only costly one (it may run a bounded
    # no-mistakes call), so the || ordering evaluates it ONLY for a non-afk,
    # routine-content signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_span_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
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
      triage_log "absorbed routine $reason (bundled for the next presentation)"
    fi
  fi

  # Liveness-probe backbone (plan v3 U1.4): per recorded window, on its own
  # backoff-scaled cadence, measure process evidence and let probe_window
  # (the one owner of the alarm rule) decide. No pane capture, no hashes:
  # window stillness is not a signal here.
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=$(window_key "$w")
    [ -n "$task" ] || continue
    # The machine wait field (bin/fm-wait-lib.sh) silences the probe until its
    # deadline and is checked exactly once per field identity after it; a
    # malformed field silences nothing. Secondmates take ONLY this path: an
    # idle mate endpoint is healthy by design and is never probed.
    if fm_wait_read "$STATE" "$task"; then
      case "$FM_WAIT_STATE" in
        active)
          continue
          ;;
        *)
          if [ "$(cat "$STATE/.wait-checked-$key" 2>/dev/null)" != "$FM_WAIT_IDENTITY" ]; then
            # Queue-safety invariant: enqueue before the single-fire marker.
            reason="stale: $w (declared wait expired $(( $(date +%s) - FM_WAIT_UNTIL ))s ago: $FM_WAIT_REASON - check it once, then the worker refreshes or clears it with bin/fm-wait.sh)"
            fm_wake_append stale "$w" "$reason" || exit 1
            printf '%s' "$FM_WAIT_IDENTITY" > "$STATE/.wait-checked-$key"
            wake "$reason"
          fi
          ;;
      esac
    fi
    [ "$kind" = secondmate ] && continue
    [ "$(age_of "$STATE/.probe-last-$key")" -ge "$(probe_backoff_interval "$key")" ] || continue
    probe_window "$w" "$task" "$key"
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
      # Backstop: unclassified actionable content, or an open decision due its
      # bounded re-surface. Enqueue first, then advance the re-surface throttle
      # so the next heartbeat does not re-fire it (enqueue-before-suppress
      # preserved; the still-open decision itself keeps re-appearing on every
      # drain until answered - the throttle bounds only the extra wake).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      date +%s > "$OPEN_DECISIONS_RESURFACE_MARKER"
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
