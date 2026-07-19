#!/usr/bin/env bash
# fm-supervise-daemon.sh — presence-gated sub-supervisor (closes #27's P2).
#
# Wraps bin/fm-watch.sh: runs it as a child, classifies each wake reason, and
# either SELF-HANDLES the routine majority in bash (no firstmate turn) or
# ESCALATES a batched, distilled digest to the supervisor pane on
# captain-relevant events plus bounded declared-pause rechecks. This is the
# token-efficient replacement for the prior always-inject daemon: routine
# signal/stale/heartbeat wakes cost zero firstmate context; only done/
# needs-decision/blocked/failed/persistent-wedge/check-output events and a
# declared-pause recheck reach the LLM, and even then as one pre-read digest per
# batch window.
#
# PRESENCE-GATING (the /afk contract). The daemon is the away-mode engine: it
# injects ONLY when the durable away-mode flag state/.afk is present. Invoking
# the /afk skill sets that flag and starts this daemon; any real (unmarked)
# user message clears it and firstmate resumes full responsiveness.
# When afk is off, normal fm-watch.sh always-on triage is the active mechanism.
# Any buffered daemon escalations that remain while afk is off survive in
# state/.subsuper-escalations and are flushed on the next "while you were out"
# catch-up or when afk is re-entered.
#
# IN-BAND SENTINEL MARKER. Every daemon injection is prefixed with
# FM_INJECT_MARK (U+2063 INVISIBLE SEPARATOR), a character a human cannot type
# from a normal keyboard at the start of a message and Herdr transports as text.
# Firstmate's contract: a message that starts with the marker is an internal
# escalation (stay afk); a message without it means the captain is back (exit
# afk, flush catch-up, resume per-wake responsiveness). The marker and the
# busy-guard solve the same problem - the daemon and the human share one input
# channel - so they live together under /afk.
#
# Reliability model (see the /afk skill):
#   - Nothing is lost in away mode: while state/.afk exists, the watcher reverts
#     to daemon-owned one-shot behavior and enqueues every wake to
#     state/.wake-queue BEFORE advancing its suppression markers, so a
#     crash/restart/missed injection is recovered on the next fm-wake-drain.sh.
#     The daemon does not touch the queue; it only reads the watcher's stdout
#     reason.
#   - Fail-safe-to-escalate: any wake the classifier cannot confidently mark
#     routine is escalated.
#   - Bounded wedge latency: a stale pane without a declared external wait is
#     escalated only after it has been idle for STALE_ESCALATE_SECS
#     (configurable), rechecked once. A wedged crewmate is therefore detected
#     within STALE_ESCALATE_SECS + a tick, never lost. A declared pause instead
#     gets its own longer PAUSE_RESURFACE_SECS recheck, never a wedge escalation.
#     Crewmates are autonomous, so a delayed stale response does not stall a
#     healthy crewmate's own progress.
#     Buffered escalation delivery also has a max-defer alarm: if a digest stays
#     undelivered past FM_MAX_DEFER_SECS, the daemon retries a normal flush and
#     writes state/.subsuper-inject-wedged and attempts a configurable active
#     alert if submit still cannot be confirmed.
#   - Cheap heartbeat catch-all: every HEARTBEAT_SCAN_SECS the daemon greps all
#     state/*.status for a captain-relevant line the per-wake classifier might
#     have missed (e.g. a status verb outside CAPTAIN_RE) and escalates it.
#
# The robustness shell from the prior always-inject version is preserved:
# single-instance lock (portable helper, no flock dependency), crash-loop
# backoff, pane-gone guard, and a signal-trapped shutdown that flushes buffered
# escalations before exit.
#
# Usage: fm-supervise-daemon.sh
#          Long-lived background loop. Normally started by the /afk skill, which
#          sets state/.afk first. Env knobs:
#          FM_SUPERVISOR_TARGET     supervisor pane target (override; otherwise
#                                   auto-discovered per backend - $TMUX_PANE
#                                   under tmux, "<session>:<pane-id>" from
#                                   $HERDR_PANE_ID under herdr - then
#                                   firstmate:0 fallback). Accepts either a
#                                   tmux target or a herdr "<session>:<pane-id>"
#                                   target; which one it's read as is decided by
#                                   FM_SUPERVISOR_BACKEND (below), independently.
#          FM_SUPERVISOR_BACKEND    supervisor pane BACKEND (tmux|herdr;
#                                   override; otherwise auto-discovered the same
#                                   way bin/fm-backend.sh's fm_backend_detect
#                                   resolves the runtime firstmate itself is
#                                   executing inside - $TMUX_PANE selects tmux,
#                                   $HERDR_ENV=1 selects herdr - falling back to
#                                   tmux). zellij, orca, and cmux are not yet
#                                   supported as supervisor backends; the daemon
#                                   refuses loudly at startup rather than trying
#                                   tmux primitives against a non-tmux pane.
#          FM_INJECT_SKIP           |-prefixes force-self-handle bypassing
#                                   classification (default "heartbeat"); empty
#                                   disables. Use sparingly: it overrides the
#                                   captain-relevant escalation for matching
#                                   kinds.
#          FM_STALE_ESCALATE_SECS   idle seconds before a stale pane escalates
#                                   as a possible wedge (default 240)
#          FM_PAUSE_RESURFACE_SECS  idle seconds before a declared external wait
#                                   re-surfaces as a recheck (default 3600)
#          FM_ESCALATE_BATCH_SECS   buffer window for batched escalation
#                                   digests; 0 = flush immediately (default 90)
#          FM_HEARTBEAT_SCAN_SECS   cadence for the catch-all status scan
#                                   (default 300)
#          FM_HOUSEKEEPING_TICK     seconds between housekeeping passes while
#                                   the watcher is mid-cycle (default 15)
#          FM_BUSY_REGEX            OR-ed busy signatures (mirrors fm-watch.sh)
#          FM_COMPOSER_IDLE_RE      empty-composer regex applied after dim-ghost
#                                   and structural border stripping (default:
#                                   bare prompt glyphs plus busy footers)
#          FM_MAX_DEFER_SECS        max seconds a buffered escalation may sit
#                                   undelivered before one normal flush attempt;
#                                   if that cannot confirm a submit, a wedge
#                                   alarm fires (default 300; 0 disables)
#          FM_WEDGE_ALARM_CHANNEL   override config/wedge-alarm with a single
#                                   active-alert directive for that wedge alarm
#                                   (off|auto|osascript|herdr|command:<cmd>). An
#                                   absent file/var means auto: on macOS that is
#                                   an OS-level notification, so the alarm is
#                                   never silent. See wedge_alarm_notify below
#                                   and docs/configuration.md.
#          FM_WEDGE_ALARM_EXEC      notifier seam: when set, every notifier
#                                   channel routes through this command as
#                                   `<cmd> <channel> <summary>` instead of
#                                   invoking its real notifier; "discard" fires
#                                   nothing. Unset in production. When SOURCED the
#                                   daemon defaults this to "discard" so no test
#                                   can post a real notification (wedge_alarm_emit
#                                   and the library-mode guard at the foot).
#          FM_WEDGE_ALARM_TIMEOUT_SECS seconds allowed for each notifier before
#                                   its watchdog terminates it and continues to the
#                                   next channel (default 10; invalid/zero uses the
#                                   default).
#          FM_INJECT_CONFIRM_RETRIES Enter-retry attempts on a swallowed Enter
#                                   (default 3); the digest is typed once, only
#                                   Enter is retried. Composer-empty detection is
#                                   structural and style-aware (bin/fm-tmux-lib.sh):
#                                   it drops dim/faint ghost text and strips the
#                                   harness's box borders before deciding, so a
#                                   ghost-only or bordered-but-empty composer is
#                                   not misread as pending input.
#          FM_INJECT_CONFIRM_SLEEP  seconds between daemon submit checks
#                                   (default 0.5)
#          FM_LOG_MAX_BYTES / FM_LOG_KEEP_LINES / FM_CRASH_*  log + crash guards
#          FM_STATE_OVERRIDE        alternate state dir (testing)
#          Logs each wake to state/.supervise-daemon.log (size-capped). Single
#          instance via portable lock on state/.supervise-daemon.lock. Trapped
#          SIGTERM/SIGINT shut down within ~1s, flush escalations, release the
#          lock. A crashing fm-watch.sh is logged and restarted, never killing
#          the daemon; a tight crash-restart spin is detected and backed off.
set -u

FM_DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_DAEMON_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Shared tmux pane primitives for supervisor injection (busy/composer detection
# + verify-retry submit). Sourced at top level so BOTH the executed daemon and
# the unit tests (which source this file for its pure functions) get the
# corrected composer detection. Stale task rechecks use fm-backend.sh below.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_DAEMON_DIR/fm-tmux-lib.sh"

# shellcheck source=bin/fm-backend.sh
. "$FM_DAEMON_DIR/fm-backend.sh"

# Shared wake classifier (last_status_line, status_is_captain_relevant,
# window_to_task, scan_captain_relevant_statuses). The SAME library backs the
# always-on watcher's triage, so the captain-relevant verb set and the
# classification predicates have exactly one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_DAEMON_DIR/fm-classify-lib.sh"

# Supervisor-pane discovery (FM_SUPERVISOR_TARGET_DEFAULT,
# FM_SUPERVISOR_BACKEND_DEFAULT, discover_supervisor_target,
# discover_supervisor_backend). Shared with the script-owned away launcher
# (bin/fm-afk-launch.sh) so the captain-pane resolution has exactly one owner.
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_DAEMON_DIR/fm-supervisor-target-lib.sh"

# --- tunables ---------------------------------------------------------------
# Supervisor backends this daemon knows how to inject into today. zellij, orca,
# and cmux are real backends elsewhere in firstmate (bin/fm-backend.sh) but this
# daemon has no verified composer/busy primitives wired up for them yet - see
# docs/herdr-backend.md and AGENTS.md section 4's
# harness-verification discipline. Selecting one refuses loudly at startup
# instead of silently running tmux primitives against a pane that is not a tmux
# pane.
FM_SUPERVISOR_SUPPORTED_BACKENDS="tmux herdr"
INJECT_SKIP_DEFAULT="heartbeat"
STALE_ESCALATE_SECS_DEFAULT=240
ESCALATE_BATCH_SECS_DEFAULT=90
HEARTBEAT_SCAN_SECS_DEFAULT=300
HOUSEKEEPING_TICK_DEFAULT=15
# Max time a buffered escalation may sit undelivered before the daemon retries
# the normal flush path and, if that cannot confirm a submit, raises a loud wedge
# alarm. The escape hatch makes a guard false-positive visible instead of silent.
MAX_DEFER_SECS_DEFAULT=300
WEDGE_ALARM_TIMEOUT_SECS_DEFAULT=10
WEDGE_ALARM_LAST_EPOCH=0
WEDGE_ALARM_NOTIFIER_PID=
# The captain-relevant verb set and the status classifiers (last_status_line,
# status_is_captain_relevant, window_to_task, scan_captain_relevant_statuses) now
# live in bin/fm-classify-lib.sh, shared with the always-on watcher.
# Composer-empty detection and the tmux busy-footer fallback live in
# bin/fm-tmux-lib.sh (FM_TMUX_BUSY_REGEX_DEFAULT / fm_tmux_composer_state);
# FM_BUSY_REGEX still overrides the fallback busy set here, as before.
INJECT_FAIL_SLEEP_DEFAULT=30
INJECT_CONFIRM_RETRIES_DEFAULT=3
INJECT_CONFIRM_SLEEP_DEFAULT=0.5
CRASH_THRESHOLD_DEFAULT=10
CRASH_WINDOW_DEFAULT=60
CRASH_BACKOFF_DEFAULT=60
CRASH_NORMAL_SLEEP_DEFAULT=5
LOG_MAX_BYTES_DEFAULT=1048576
LOG_KEEP_LINES_DEFAULT=2000

# --- presence-gating + sentinel marker --------------------------------------
# The in-band sentinel: U+2063 INVISIBLE SEPARATOR (UTF-8 e2 81 a3). It has no
# normal keyboard keystroke, so no real user message starts with it. Unlike the
# original ASCII unit separator, Herdr transports U+2063 through Pi's terminal
# editor as text instead of consuming it as a control action. Every daemon
# injection is prefixed with this character; firstmate treats a leading marker
# as an internal escalation (stay afk) and its absence as "captain is back"
# (exit afk). Portable across harnesses: it travels with the message text,
# independent of any harness-level typed-vs-injected distinction.
FM_INJECT_MARK=$'\xE2\x81\xA3'
AFK_FLAG_NAME=".afk"

# Resolve the effective state dir. FM_STATE_OVERRIDE wins (testing); otherwise
# $FM_HOME/state. Kept as a function so the pure
# classifiers can take an explicit state arg without depending on globals.
_state_root() { printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"; }

# --- portable stat (same trap as fm-watch.sh: no `stat -f || stat -c`) -------
if [ "$(uname)" = Darwin ]; then
  _stat_file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  _stat_file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
_now() { date +%s; }
_file_age() {  # seconds since mtime; very large if missing
  local f=$1 m
  m=$(_stat_file_mtime "$f") || { echo 999999; return; }
  echo $(( $(_now) - m ))
}

_hash_text() {
  if command -v md5 >/dev/null 2>&1; then printf '%s' "$1" | md5 -q
  else printf '%s' "$1" | md5sum | cut -d ' ' -f1; fi
}

# --- presence-gating helpers (PURE-ish: side-effect-free reads of state) -----
# afk_active: 0 if the durable away-mode flag exists, 1 otherwise.
afk_active() {  # <state>
  [ -e "$1/$AFK_FLAG_NAME" ]
}

# afk_enter / afk_exit: write/clear the away-mode flag. Called by the /afk
# skill (enter) and by firstmate on user return (exit). Durable: a plain file,
# so recovery (§5) re-enters afk if it is present after a restart.
afk_enter() {  # <state>
  mkdir -p "$1"
  date '+%s' > "$1/$AFK_FLAG_NAME"
}

afk_exit() {  # <state>
  rm -f "$1/$AFK_FLAG_NAME"
}

# should_exit_afk: encodes firstmate's afk-exit contract as a testable function.
#   afk inactive            -> 1 (nothing to exit)
#   message has marker      -> 1 (internal escalation; stay afk)
#   message is /afk command -> 1 (re-entering/extending afk; stay afk)
#   anything else           -> 0 (captain is back; exit afk)
# Bias toward exit: only the marker and an explicit /afk invocation keep afk
# alive. A false exit is self-correcting (the captain re-runs /afk).
should_exit_afk() {  # <state> <message-text>
  local state=$1 msg=$2
  afk_active "$state" || return 1
  message_is_injection "$msg" && return 1
  case "$msg" in
    /afk*) return 1 ;;
  esac
  return 0
}

# message_is_injection: 0 if the given message text starts with the sentinel
# marker (a daemon escalation), 1 otherwise (a real user message). Firstmate's
# afk-exit contract uses this: marker present -> stay afk; absent -> captain is
# back. Bias ambiguous cases toward exit (a false exit is self-correcting).
message_is_injection() {  # <message-text>
  local msg=$1
  [ -n "$msg" ] || return 1
  case "$msg" in
    "$FM_INJECT_MARK"*) return 0 ;;
  esac
  return 1
}

# strip_injection_marker: remove the leading sentinel marker (if present) so the
# digest text is clean for classification/relay. The afk-exit contract keys off
# the marker's PRESENCE; once detected, the marker byte should not appear in the
# distilled content firstmate relays to the captain or feeds back to classifiers.
strip_injection_marker() {  # <message-text>
  local msg=$1
  printf '%s' "${msg#"$FM_INJECT_MARK"}"
}

# Collapse all newlines to a literal " - " separator so the injected digest is
# a single line. Submission via send-keys + Enter is then unambiguous regardless
# of how the target TUI handles embedded newlines in its composer.
_collapse_newlines() {  # <text>
  local s=$1
  s=${s//$'\n'/ - }
  printf '%s' "$s"
}

# discover_supervisor_target / discover_supervisor_backend are owned by
# bin/fm-supervisor-target-lib.sh (sourced above). fm_super_main below calls
# them exactly as before; the away launcher reuses the identical resolution to
# pass the captain pane in as FM_SUPERVISOR_TARGET.

# --- classification helpers (PURE: no side effects, testable) ---------------
# last_status_line, status_is_captain_relevant, window_to_task, and
# scan_captain_relevant_statuses come from bin/fm-classify-lib.sh (sourced above),
# the single classifier shared with bin/fm-watch.sh. The decision-string wrappers
# and dedup state below layer the daemon's escalation-digest concerns on top.
#
# Decision protocol: every classifier prints exactly one line on stdout of the
# form "<action>|<distilled>" where action is "self" or "escalate". The distilled
# field for "self" is informational (logged); for "escalate" it is the pre-read
# summary firstmate would otherwise have to re-read.

classify_signal() {  # <reason-after-colon> <state>
  local reason=$1 state=$2 f last distilled="" rel="" all_seen=1 task seen
  for f in $reason; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    distilled="${distilled}$(basename "$f"): ${last} | "
    status_is_captain_relevant "$last" || continue
    rel=1
    # Dedupe against the catch-all scan: if this status was already escalated
    # (seen marker matches), skip escalating again. The seen marker is the
    # single source of truth shared between the per-wake signal path and the
    # heartbeat scan. all_seen stays 1 only if EVERY relevant file was seen.
    task=$(basename "$f"); task="${task%.status}"
    seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
    [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ] || all_seen=0
  done
  # strip a trailing " | " separator so the distilled line is clean
  distilled="${distilled% | }"
  if [ -z "$rel" ]; then
    printf 'self|routine signal: %s' "$distilled"
  elif [ "$all_seen" = "1" ]; then
    # Every relevant status was already escalated by the catch-all scan;
    # self-handle to avoid a duplicate entry in the digest.
    printf 'self|signal already escalated (catch-all scan): %s' "$distilled"
  else
    printf 'escalate|%s' "$distilled"
  fi
}

# classify_stale decides the WAKE itself (one-shot per distinct hash). On a
# first sight of a non-terminal stale it returns "self" and the caller records a
# timestamp marker; persistence is escalated by housekeeping's recheck, not here.
classify_stale() {  # <window> <state>
  local win=$1 state=$2 task last seen
  task=$(window_to_task "$win" "$state")
  last=$(last_status_line "$state/$task.status")
  if [ -n "$last" ] && status_is_paused "$last"; then
    # A DECLARED external-wait pause (fm-classify-lib.sh): an idle pane is EXPECTED,
    # so this is not a wedge. The caller records a pause marker (long re-surface
    # cadence in housekeeping) rather than a wedge stale marker. Cheap: reuses the
    # status line already read, no fm-crew-state.sh call, mirroring the daemon's
    # existing status-log classification.
    printf 'pause|paused (awaiting external), rechecked on a long cadence: %s' "$last"
    return
  fi
  if [ -n "$last" ] && status_is_captain_relevant "$last"; then
    # Dedupe against the signal path: if this status was already escalated
    # (seen marker matches), self-handle to avoid a duplicate in the digest.
    seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
    if [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ]; then
      printf 'self|stale + terminal (already escalated by signal): %s' "$last"
      return
    fi
    printf 'escalate|stale + terminal status: %s' "$last"
    return
  fi
  # Non-terminal (or no status): defer to the persistence recheck. The caller
  # records/refreshes the stale marker so housekeeping can age it.
  printf 'self|transient stale (%s): %s' "$win" "${last:-no status}"
}

classify_check() {  # <full reason>  — check scripts print only when firstmate should wake
  printf 'escalate|%s' "$1"
}

classify_heartbeat() {
  # The wake itself is routine; the catch-all scan runs separately in
  # housekeeping on the HEARTBEAT_SCAN_SECS cadence.
  printf 'self|heartbeat (catch-all scan runs in housekeeping)'
}

# Anything unrecognized is escalated (fail-safe).
classify_unknown() {  # <reason>
  printf 'escalate|unknown wake: %s' "$1"
}

# --- stale marker + escalation buffer (stateful, but via explicit state dir) -
# Marker:   state/.subsuper-stale-<key>   contains the epoch first seen idle.
# Buffer:   state/.subsuper-escalations    one distilled line per escalation.
# Seen:     state/.subsuper-seen-status-<task>  last status line the scan
#           escalated, so the catch-all does not re-fire the same terminal.

_stale_key() { printf '%s' "$1" | tr ':/.' '___'; }

stale_marker_record() {  # <window> <state>  — create if absent
  local win=$1 state=$2 key marker
  key=$(_stale_key "$(window_to_task "$win" "$state")")
  marker="$state/.subsuper-stale-$key"
  [ -e "$marker" ] || _now > "$marker"
}

stale_marker_remove() {  # <window> <state>
  local win=$1 state=$2 key
  key=$(_stale_key "$(window_to_task "$win" "$state")")
  rm -f "$state/.subsuper-stale-$key"
}

# Pause marker: state/.subsuper-paused-<key> holds the epoch a declared pause was
# first observed idle. Housekeeping ages it against PAUSE_RESURFACE_SECS (much
# longer than a wedge) and re-surfaces the pause once per window. Recording is
# create-if-absent so the timestamp is stable across a churny idle pane (many
# distinct stale hashes map to one marker), keeping the cadence hash-immune.
pause_marker_record() {  # <window> <state> - create if absent
  local win=$1 state=$2 key marker
  key=$(_stale_key "$(window_to_task "$win" "$state")")
  marker="$state/.subsuper-paused-$key"
  [ -e "$marker" ] || _now > "$marker"
}

pause_marker_remove() {  # <window> <state>
  local win=$1 state=$2 key
  key=$(_stale_key "$(window_to_task "$win" "$state")")
  rm -f "$state/.subsuper-paused-$key"
}

clear_pause_tracking() {  # <window> <state>
  local win=$1 state=$2 task key watcher_key
  task=$(window_to_task "$win" "$state")
  key=$(_stale_key "$task")
  watcher_key=$(_stale_key "$win")
  rm -f "$state/.subsuper-paused-$key" "$state/.subsuper-stale-$key" \
    "$state/.paused-$watcher_key" "$state/.paused-rechecked-$watcher_key" "$state/.paused-resurfaced-$watcher_key" \
    "$state/.stale-$watcher_key" "$state/.stale-since-$watcher_key" "$state/.wedge-escalations-$watcher_key"
}

reconcile_pause_tracking() {  # <window> <state> <last-status-line>
  local win=$1 state=$2 last=$3 task key marker watcher_key
  task=$(window_to_task "$win" "$state")
  key=$(_stale_key "$task")
  marker="$state/.subsuper-paused-$key"
  watcher_key=$(_stale_key "$win")
  if status_is_paused "$last"; then
    stale_marker_remove "$win" "$state"
    pause_marker_record "$win" "$state"
  elif [ -e "$marker" ] || [ -e "$state/.paused-$watcher_key" ]; then
    clear_pause_tracking "$win" "$state"
  fi
}

migrate_watcher_pause_markers() {  # <state>
  local state=$1 meta win task key last watcher_key
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    win=$(fm_backend_target_of_meta "$meta")
    [ -n "$win" ] || continue
    task=$(basename "$meta"); task=${task%.meta}
    key=$(_stale_key "$task")
    watcher_key=$(_stale_key "$win")
    last=$(last_status_line "$state/$task.status")
    if status_is_paused "$last" || [ -e "$state/.subsuper-paused-$key" ] || [ -e "$state/.paused-$watcher_key" ]; then
      reconcile_pause_tracking "$win" "$state" "$last"
    fi
  done
}

sync_pause_markers_from_signal() {  # <state> <signal files>
  local state=$1 paths=$2 f last task win
  local -a files
  read -r -a files <<<"$paths"
  for f in "${files[@]}"; do
    case "$f" in *.status) ;; *) continue ;; esac
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    task=$(basename "$f"); task=${task%.status}
    win=$(window_for_task "$task" "$state" 2>/dev/null || true)
    [ -n "$win" ] || continue
    reconcile_pause_tracking "$win" "$state" "$last"
  done
}

# Record the seen-status marker for a captain-relevant status line so the
# heartbeat catch-all scan does not re-fire it. The single source of truth for
# the .subsuper-seen-status-<task> dedup state: called from both the per-wake
# escalate path and the catch-all scan.
mark_status_seen() {  # <state> <task> <last-line>
  local state=$1 task=$2 line=$3
  printf '%s' "$line" > "$state/.subsuper-seen-status-$(_stale_key "$task")"
}

# Mark every captain-relevant status line a per-wake classification escalated as
# seen, so the catch-all scan does not re-escalate the same line within
# HEARTBEAT_SCAN_SECS. Mirrors classify_signal/classify_stale's relevance test.
mark_escalated_seen() {  # <kind> <arg> <state>
  local kind=$1 arg=$2 state=$3 f last task
  case "$kind" in
    signal)
      for f in $arg; do
        [ -e "$f" ] || continue
        last=$(last_status_line "$f")
        [ -n "$last" ] || continue
        status_is_captain_relevant "$last" || continue
        task=$(basename "$f"); task="${task%.status}"
        mark_status_seen "$state" "$task" "$last"
      done ;;
    stale)
      task=$(window_to_task "$arg" "$state")
      last=$(last_status_line "$state/$task.status")
      [ -n "$last" ] && status_is_captain_relevant "$last" \
        && mark_status_seen "$state" "$task" "$last" ;;
  esac
}

# Busy + composer-empty detection are the shared primitives in fm-tmux-lib.sh
# (one source of truth with fm-send.sh). These thin wrappers keep the daemon's
# call sites and the unit tests stable.
#
# pane_input_pending returns 0 (pending) when the cursor line holds real
# unsubmitted text - a human's half-typed line (the return race) or a previous
# injection whose Enter was swallowed. The detector drops dim/faint ghost text and
# strips the harness's composer box borders, so a ghost-only or idle bordered
# claude composer ("│ > … │") is correctly read as empty, not pending (incidents
# afk-invx-i5 and composer-robust).
# pane_is_busy / pane_input_pending: BACKEND-AWARE now (previously tmux-only
# direct calls). <backend> defaults to tmux when omitted, so every existing
# caller/test that passes only <target> is unaffected. Dispatch goes through
# bin/fm-backend.sh's generic per-backend primitives (fm_backend_busy_state,
# fm_backend_capture, fm_backend_composer_state) rather than hand-rolling a
# case statement here, mirroring the same fallback pattern
# stale_window_is_busy already uses for per-task panes: try the backend's
# native busy-state first, and fall back to the shared regex-over-capture
# reader whenever it does not report "busy" (tmux has no native busy-state
# primitive, so it always takes this fallback path - byte-identical to the
# pre-existing fm_pane_is_busy, since fm_backend_capture's tmux arm runs the
# exact same `tmux capture-pane -p -t <target> -S -40`).
pane_is_busy() {  # <target> [backend]
  local target=$1 backend=${2:-tmux} bs tail40
  bs=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

# pane_input_pending: the standalone "is there real unsubmitted text" predicate,
# dispatching through fm_backend_composer_state (byte-identical to a direct
# fm_tmux_composer_state call for the default/omitted-backend case). inject_msg
# no longer routes its composer-guard through this boolean: a safe injection
# target must be affirmatively 'empty', and a boolean pending/not-pending check
# cannot distinguish an empty agent composer from a bare dead-shell prompt or an
# unreadable pane (both 'unknown'), so inject_msg reads the full tri-state
# verdict directly. This predicate is retained as the shared pending check and
# as the vehicle for the composer-classifier dispatch regression tests.
pane_input_pending() {  # <target> [backend]
  local target=$1 backend=${2:-tmux}
  [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" = pending ]
}

task_window_backend() {  # <window> <state>
  local win=$1 state=$2 task meta
  task=$(window_to_task "$win" "$state")
  meta="$state/$task.meta"
  fm_backend_of_meta "$meta"
}

stale_window_is_busy() {  # <window> <state>
  local win=$1 state=$2 backend label tail40 bs
  backend=$(task_window_backend "$win" "$state")
  label="fm-$(window_to_task "$win" "$state")"
  tail40=$(fm_backend_capture "$backend" "$win" 40 "$label" 2>/dev/null) || return 2
  bs=$(fm_backend_busy_state "$backend" "$win" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
  esac
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

escalate_add() {  # <state> <distilled-item>
  local state=$1 item=$2 buf
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || _now > "${buf}.since"
  printf '%s\n' "$item" >> "$buf"
}

# Flush the escalation buffer as ONE batched, single-line digest to the
# supervisor pane. Returns 0 on successful inject (or empty buffer), non-zero on
# inject failure (buffer preserved for retry / catch-up).
escalate_flush() {  # <state>
  local state=$1 buf item n msg
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || return 0
  n=$(wc -l < "$buf" 2>/dev/null || echo 0)
  # Join buffered items with the literal " | " separator into one digest line.
  msg=$(awk 'NR>1{printf " | "} {printf "%s",$0} END{print ""}' "$buf" 2>/dev/null)
  # Single-line wrapper: no embedded newlines (inject_msg also collapses as a
  # safety net, but keeping the source single-line makes the intent explicit).
  msg=$(printf 'Supervisor escalate (%s event(s)): %s (pre-read; re-arm not needed — watcher daemon-managed)' "$n" "$msg")
  if inject_msg "$msg" "$state"; then : > "$buf"; rm -f "${buf}.since" "$state/.subsuper-inject-wedged"; return 0; fi
  return 1
}

# --- backend-independent active wedge alert ---------------------------------
# The tmux status-line flash in inject_wedge_alarm below is a cosmetic,
# client-side OSD with no cross-backend equivalent, so a wedged non-tmux primary
# (the 2026-07-10 overnight incident: a claude-on-herdr primary) got NO active
# signal - only the passive state/.subsuper-inject-wedged marker, which nothing
# surfaces until the next fleet action (that night, 20 escalations sat buffered
# for 8.5h). These helpers add a configurable active alert that does not depend
# on any pane or its backend status-line: an OS-level macOS notification, a
# herdr notification, or a captain-supplied command (push to a phone, etc.).
# Every channel is best-effort - a missing or failing channel logs and is
# skipped, never crashing the daemon loop - and the durable marker plus the tmux
# flash stay exactly as before.
#
# Config: config/wedge-alarm (local, gitignored), one channel directive per
# non-empty, non-comment line. FM_WEDGE_ALARM_CHANNEL overrides the file with a
# single directive. Directives:
#   off              disable the active alert entirely, regardless of position
#                    (marker + flash remain)
#   auto | default   platform default: macOS -> osascript; otherwise none
#   osascript        macOS Notification Center banner (backend-independent)
#   herdr            herdr UI notification (herdr notification show)
#   command:<cmd>    run <cmd> via `sh -c`, summary on $1 and on stdin
# An absent config means auto, i.e. default-ON on macOS: the alarm's whole
# purpose is to never be silent, so the reachable OS channel fires unless the
# captain explicitly disables it.

# Print the configured channel directives, one per line. FM_WEDGE_ALARM_CHANNEL
# wins (a single directive); else each non-empty, non-comment line of
# config/wedge-alarm; else "auto".
wedge_alarm_configured_channels() {
  local cfg line found=
  if [ -n "${FM_WEDGE_ALARM_CHANNEL:-}" ]; then
    printf '%s\n' "$FM_WEDGE_ALARM_CHANNEL"
    return 0
  fi
  cfg="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/wedge-alarm"
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac
      printf '%s\n' "$line"
      found=1
    done < "$cfg"
  fi
  [ -n "$found" ] || printf 'auto\n'
}

# Resolve the platform's default OS-level channel for `auto`. macOS reaches the
# captain via an osascript Notification Center banner; other platforms have no
# built-in OS channel (the captain wires a command: directive), so this prints
# nothing and wedge_alarm_notify logs that the marker is the only signal.
wedge_alarm_platform_default() {
  case "$(uname)" in
    Darwin) command -v osascript >/dev/null 2>&1 && printf 'osascript' ;;
    *) : ;;
  esac
}

wedge_alarm_run_bounded() {
  local channel=$1 timeout monitor_was_on=0 pid start elapsed rc
  shift
  timeout=${FM_WEDGE_ALARM_TIMEOUT_SECS:-$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*) timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
    *) [ "$timeout" -gt 0 ] 2>/dev/null || timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
  esac
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  case $- in
    *m*) ;;
    *) log "wedge alarm: ${channel} notifier skipped because its watchdog could not start"; return 125 ;;
  esac
  "$@" &
  pid=$!
  WEDGE_ALARM_NOTIFIER_PID=$pid
  start=$SECONDS
  while kill -0 "-$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      wedge_alarm_stop_active_notifier
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      log "wedge alarm: ${channel} notifier timed out after ${elapsed}s (limit ${timeout}s)"
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  WEDGE_ALARM_NOTIFIER_PID=
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  return "$rc"
}

wedge_alarm_stop_active_notifier() {
  local pid=${WEDGE_ALARM_NOTIFIER_PID:-}
  [ -n "$pid" ] || return 0
  WEDGE_ALARM_NOTIFIER_PID=
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# The single execution seam for every configured notifier channel.
# FM_WEDGE_ALARM_EXEC, when set, REPLACES the real notifier: the resolved channel
# name and summary are handed to that command instead of ever invoking osascript
# or herdr or a captain-supplied command. This is the one injection point the test harness forces to a recorder
# so no test can post a real desktop notification - the library-mode guard at the
# foot of this file defaults it to "discard" whenever the daemon is SOURCED
# rather than executed, which is the only way a test reaches these functions. The
# special value "discard" fires nothing; unset means production (the executed
# daemon), so the real channels fire.
wedge_alarm_os_notifier_override() {  # <channel> <summary>
  local channel=$1 summary=$2 rc exec_override=${FM_WEDGE_ALARM_EXEC:-}
  case "$exec_override" in
    '') return 2 ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
}

# Post a macOS Notification Center banner. `display notification` is OS-level,
# independent of any terminal pane or multiplexer status-line. The summary is
# passed as an argv item (never interpolated into the AppleScript source) so its
# text can never break the script. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_osascript() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override osascript "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v osascript >/dev/null 2>&1 || {
    log "wedge alarm: osascript not found; cannot post a macOS notification"; return 1; }
  wedge_alarm_run_bounded osascript osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "firstmate: away-mode escalations WEDGED" sound name "Basso"' \
    -e 'end run' "$summary" >/dev/null 2>&1 && return 0
  log "wedge alarm: osascript notification failed"
  return 1
}

# Post a herdr UI notification - herdr's own surface, separate from the pane and
# its status-line. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_herdr() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override herdr "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v herdr >/dev/null 2>&1 || {
    log "wedge alarm: herdr not found; cannot post a herdr notification"; return 1; }
  wedge_alarm_run_bounded herdr herdr notification show "firstmate: away-mode escalations WEDGED" \
    --body "$summary" --sound request >/dev/null 2>&1 && return 0
  log "wedge alarm: herdr notification failed"
  return 1
}

# Run a captain-supplied command with the summary on $1 and on stdin, so an
# alert can reach a phone/pager (ntfy, Slack, SMS) even when the captain is away
# from the machine entirely. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_command() {  # <cmd> <summary>
  local cmd=$1 summary=$2 rc
  if [ "${WEDGE_ALARM_EMIT_ACTIVE:-}" != 1 ]; then
    wedge_alarm_emit command "$summary" "$cmd"
    return $?
  fi
  [ -n "$cmd" ] || { log "wedge alarm: empty command: channel; nothing to run"; return 1; }
  wedge_alarm_run_bounded command sh -c "$cmd" fm-wedge-alarm "$summary" \
    <<< "$summary" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  log "wedge alarm: command channel exited $rc (command redacted)"
  return 1
}

wedge_alarm_emit() {  # <channel> <summary>
  local channel=$1 summary=$2 cmd=${3:-} rc exec_override=${FM_WEDGE_ALARM_EXEC:-} WEDGE_ALARM_EMIT_ACTIVE=1
  case "$exec_override" in
    '') ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
  case "$channel" in
    osascript) wedge_alarm_via_osascript "$summary" ;;
    herdr) wedge_alarm_via_herdr "$summary" ;;
    command) wedge_alarm_via_command "$cmd" "$summary" ;;
  esac
}

# Fire every configured active-alert channel, best-effort. Always returns 0: a
# channel failure can never abort inject_wedge_alarm or the daemon loop. Any
# `off` directive disables the alert, regardless of position; an unresolvable
# `auto` (no OS channel on this platform) logs that the durable marker is the
# only signal. Every notifier routes through the test-forced recorder seam.
wedge_alarm_notify() {  # <summary> <marker>
  local summary=$1 marker=$2 ch
  local -a channels=()
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    channels+=("$ch")
  done < <(wedge_alarm_configured_channels)
  for ch in "${channels[@]}"; do
    [ "$ch" = off ] && return 0
  done
  for ch in "${channels[@]}"; do
    case "$ch" in auto|default) ch=$(wedge_alarm_platform_default) ;; esac
    case "$ch" in
      '') log "wedge alarm: no OS-level alert channel on $(uname); durable marker $marker is the only signal - set config/wedge-alarm (e.g. a command: directive)" ;;
      osascript|herdr) wedge_alarm_emit "$ch" "$summary" || true ;;
      command:*) wedge_alarm_emit command "$summary" "${ch#command:}" || true ;;
      *) log "wedge alarm: unrecognized active-alert channel directive (redacted); marker still written" ;;
    esac
  done
  return 0
}

# Raise a loud, rate-limited alarm when escalations cannot be delivered after
# max-defer (the supervisor pane is genuinely busy/wedged, or the submit's Enter
# is swallowed). The daemon must NEVER silently wedge: this logs
# an ERROR, drops a durable marker firstmate/recovery can surface, flashes
# the tmux supervisor client's status line when applicable, and attempts a
# configurable backend-independent active alert (wedge_alarm_notify). Nothing
# is lost - the buffer and the
# wake-queue both survive - but the stall stops being invisible.
inject_wedge_alarm() {  # <state> <age-seconds>
  local state=$1 age=$2 marker target backend max_defer now notify=1
  marker="$state/.subsuper-inject-wedged"
  max_defer="${FM_MAX_DEFER_SECS:-$MAX_DEFER_SECS_DEFAULT}"
  # Re-alarm at most once per max-defer window so a long wedge does not spam.
  if [ "$(_file_age "$marker")" -lt "$max_defer" ]; then
    return 0
  fi
  now=$(_now)
  if [ "$WEDGE_ALARM_LAST_EPOCH" -gt 0 ] && [ $((now - WEDGE_ALARM_LAST_EPOCH)) -lt "$max_defer" ]; then
    notify=0
  else
    WEDGE_ALARM_LAST_EPOCH=$now
    log "ERROR: away-mode escalation undelivered ${age}s; inject could not confirm a submit (supervisor pane busy or wedged). Buffer + wake-queue preserved; alarm marker written."
  fi
  {
    printf 'fm away-mode inject WEDGED: %ss undelivered as of %s\n' "$age" "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'The supervisor pane could not accept an escalation. Buffered items:\n'
    cat "$state/.subsuper-escalations" 2>/dev/null
  } 2>/dev/null > "$marker" || true
  target="${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}"
  backend="${FM_SUPERVISOR_BACKEND:-$FM_SUPERVISOR_BACKEND_DEFAULT}"
  # Best-effort status-line flash. tmux's display-message is a client-side OSD
  # with no herdr equivalent; the log line + durable marker above are already
  # the primary, backend-independent signal, so a non-tmux backend just skips
  # this cosmetic extra rather than attempting an unsupported call.
  if [ "$backend" = tmux ]; then
    tmux display-message -t "$target" "fm: away-mode escalations WEDGED ${age}s — see $marker" 2>/dev/null || true
  fi
  # Backend-independent active alert. Unlike the tmux flash above (skipped on
  # every non-tmux backend), this can reach the captain even when every pane and
  # its backend status-line is unreadable - the gap the 2026-07-10 overnight
  # incident fell through. Configurable and best-effort; the marker above stays
  # the durable record whether or not any channel fires.
  if [ "$notify" -eq 1 ]; then
    wedge_alarm_notify "away-mode escalations WEDGED ${age}s undelivered - see $marker" "$marker"
  fi
}

_oldest_line_age() {  # <buf> -> seconds since the oldest buffered item first arrived (sidecar epoch)
  local f=$1 since
  [ -s "$f" ] || { echo 999999; return; }
  since="${f}.since"
  if [ -r "$since" ]; then
    echo $(( $(_now) - $(cat "$since" 2>/dev/null || echo 0) ))
  else
    echo 999999
  fi
}

# --- housekeeping (runs every tick while the watcher is mid-cycle) ----------
# Four cheap jobs, each guarded so an empty/quiet fleet costs near zero:
#  1) batch flush: if the escalation buffer's oldest content is older than
#     ESCALATE_BATCH_SECS (or batching is disabled), inject one digest.
#  1b) max-defer escape: if the buffer is STILL undelivered past MAX_DEFER_SECS,
#     attempt one normal delivery; if it cannot confirm, raise the wedge alarm.
#     Never silently defer forever.
#  2) stale recheck: for each pending stale marker past STALE_ESCALATE_SECS,
#     re-peek the pane; still idle -> escalate (wedge); resumed -> clear marker.
#  2b) pause re-surface: for each declared-pause marker past PAUSE_RESURFACE_SECS,
#     re-peek; busy/gone -> clear; still idle + still paused -> escalate a recheck
#     digest and reset the window (repeating bounded re-surface, never a wedge).
#  3) heartbeat scan: every HEARTBEAT_SCAN_SECS, grep state/*.status for a
#     captain-relevant line the per-wake classifier missed and escalate it.
housekeeping() {  # <state>
  local state=$1 now due f key task win marker age last max_defer oldest pause_secs
  now=$(_now)
  migrate_watcher_pause_markers "$state"

  # (1) batch flush
  if [ "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" -le 0 ]; then
    escalate_flush "$state" || true
  else
    due=$(_oldest_line_age "$state/.subsuper-escalations")
    if [ "$due" -ge "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" ]; then
      escalate_flush "$state" || true
    fi
  fi

  # (1b) max-defer escape. If anything is still buffered past MAX_DEFER_SECS,
  # retry the normal delivery path. If that still cannot confirm, raise a loud
  # wedge alarm while preserving the buffer.
  max_defer=${FM_MAX_DEFER_SECS:-$MAX_DEFER_SECS_DEFAULT}
  if afk_active "$state" && [ "$max_defer" -gt 0 ] && [ -s "$state/.subsuper-escalations" ]; then
    oldest=$(_oldest_line_age "$state/.subsuper-escalations")
    # Throttle the alarm to once per max-defer window (the wedge marker doubles
    # as the throttle). A successful flush clears the buffer; a failed one alarms
    # and waits.
    if [ "$oldest" -ge "$max_defer" ] \
       && [ "$(_file_age "$state/.subsuper-inject-wedged")" -ge "$max_defer" ]; then
      if escalate_flush "$state"; then
        log "inject recovered: max-defer flush succeeded after ${oldest}s undelivered"
        rm -f "$state/.subsuper-inject-wedged"
      else
        inject_wedge_alarm "$state" "$oldest"
      fi
    fi
  fi

  # (2) stale persistence recheck
  for marker in "$state"/.subsuper-stale-*; do
    [ -e "$marker" ] || continue
    key="${marker##*.subsuper-stale-}"
    # Reconstruct the backend target from metadata, with the live tmux list as the
    # legacy fallback for old markers that predate meta lookup.
    win=$(window_for_task "$key" "$state" 2>/dev/null || true)
    if [ -z "$win" ]; then
      # Window gone (task torn down): drop the marker, nothing to escalate.
      rm -f "$marker"; continue
    fi
    task=$(window_to_task "$win" "$state")
    last=$(last_status_line "$state/$task.status")
    if [ -n "$last" ] && status_is_paused "$last"; then
      reconcile_pause_tracking "$win" "$state" "$last"
      continue
    fi
    age=$(( now - $(cat "$marker" 2>/dev/null || echo "$now") ))
    [ "$age" -ge "${FM_STALE_ESCALATE_SECS:-$STALE_ESCALATE_SECS_DEFAULT}" ] || continue
    stale_window_is_busy "$win" "$state"
    case "$?" in
      0) rm -f "$marker" ;;
      2) rm -f "$marker" ;;
      *) escalate_add "$state" "stale persisted ${age}s (possible wedge): $win"
         stale_marker_remove "$win" "$state" ;;
    esac
  done

  # (2b) pause re-surface recheck. A DECLARED external-wait pause idles by design,
  # so it is rechecked on a much longer cadence than a wedge (PAUSE_RESURFACE_SECS)
  # and never escalated as one - but it MUST re-surface, so a forgotten pause cannot
  # rot invisibly. Past the window: busy (resumed) or gone -> drop; still idle and
  # still declaring the pause -> escalate a recheck digest and reset the marker so
  # the window repeats.
  pause_secs=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
  for marker in "$state"/.subsuper-paused-*; do
    [ -e "$marker" ] || continue
    key="${marker##*.subsuper-paused-}"
    win=$(window_for_task "$key" "$state" 2>/dev/null || true)
    if [ -z "$win" ]; then
      rm -f "$marker"; continue
    fi
    task=$(window_to_task "$win" "$state")
    last=$(last_status_line "$state/$task.status")
    if [ -z "$last" ] || ! status_is_paused "$last"; then
      reconcile_pause_tracking "$win" "$state" "$last"
      continue
    fi
    age=$(( now - $(cat "$marker" 2>/dev/null || echo "$now") ))
    [ "$age" -ge "$pause_secs" ] || continue
    stale_window_is_busy "$win" "$state"
    case "$?" in
      0) rm -f "$marker" ;;
      2) rm -f "$marker" ;;
      *)
        last=$(last_status_line "$state/$task.status")
        if [ -n "$last" ] && status_is_paused "$last"; then
          escalate_add "$state" "paused ${age}s (awaiting external, recheck whether the wait still holds): $win"
          _now > "$marker"
        else
          rm -f "$marker"
        fi
        ;;
    esac
  done

  # (3) heartbeat scan (catch-all for a captain-relevant status the per-wake
  #     classifier may have missed). Cheap: status files only, no tmux. The
  #     captain-relevant filtering is the shared classifier's
  #     scan_captain_relevant_statuses; the daemon layers its digest dedup on top.
  if [ "$(_file_age "$state/.subsuper-last-scan")" -ge "${FM_HEARTBEAT_SCAN_SECS:-$HEARTBEAT_SCAN_SECS_DEFAULT}" ]; then
    _now > "$state/.subsuper-last-scan"
    local seen
    while IFS="$(printf '\t')" read -r f task last; do
      [ -n "$f" ] || continue
      seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
      [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ] && continue
      escalate_add "$state" "$(basename "$f"): $last (catch-all scan)"
      mark_status_seen "$state" "$task" "$last"
    done < <(scan_captain_relevant_statuses "$state")
  fi
}

# Find a recorded or live window target whose task id matches the marker key.
window_for_task() {  # <task-key> [state]
  local key=$1 state=${2:-$(_state_root)} meta task w t
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta"); task=${task%.meta}
    [ "$(_stale_key "$task")" = "$key" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] && { printf '%s' "$w"; return 0; }
  done
  for w in $(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep ':fm-' || true); do
    t=$(window_to_task "$w" "$state")
    [ "$(_stale_key "$t")" = "$key" ] && { printf '%s' "$w"; return 0; }
  done
  return 1
}

# --- injection --------------------------------------------------------------
# inject_msg: send one escalation digest to the supervisor pane.
# Returns 0 on successful inject (or empty buffer), non-zero if the pane is
# gone, the supervisor is busy, afk is inactive, or the verified submit cannot
# be confirmed after bounded retries. On non-zero the caller preserves
# the buffer so the escalation survives for the next cycle or the catch-up flush.
#
# Submit model:
#   - TYPE ONCE, then submit with Enter. Never retype the digest: a swallowed
#     Enter leaves our text in the composer, and retyping would concatenate two
#     sentinel-prefixed digests into one corrupted turn.
#   - SUBMIT ACK = the backend submit primitive reports `empty` after Enter.
#     For tmux that means a cleared composer; for herdr's normal idle-baseline
#     path it means native agent-state observed a real turn start.
#     Pending means Enter was swallowed; unknown is treated as undelivered by
#     this strict daemon path.
#   - COMPOSER GUARD before typing: if the cursor line already has real content
#     after dim/faint ghost text and borders are ignored (a human's half-typed
#     line, or a previous injection's unsent text), defer entirely - injecting
#     would merge with the human's text.
inject_msg() {  # <message> [state]
  local msg=$1 state target backend retries sleep_s verdict composer
  state="${2:-$(_state_root)}"
  # (1) Presence-gate: inject ONLY when afk is active. When afk is off, the
  # daemon self-handles and stays quiet; firstmate drives the normal always-on
  # watcher triage. Escalations buffer and survive for the next catch-up flush.
  afk_active "$state" || { log "inject deferred: afk inactive"; return 1; }
  # (2) Single-line digest: collapse any embedded newlines so submission via
  # send-keys + Enter is unambiguous regardless of how the TUI composer treats
  # them. Then prepend the sentinel marker - firstmate's afk-exit contract
  # keys off its presence at the start of the message.
  msg=$(_collapse_newlines "$msg")
  msg="${FM_INJECT_MARK}${msg}"
  target="${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}"
  # BACKEND-AWARE (previously a raw `tmux display-message` pane-exists probe):
  # dispatches through bin/fm-backend.sh so a herdr supervisor pane is checked
  # via the herdr adapter instead of always assuming tmux. Falls back to tmux
  # when unset (sourced/test contexts that never ran fm_super_main's startup
  # discovery), matching this function's pre-existing default assumption.
  backend="${FM_SUPERVISOR_BACKEND:-tmux}"
  fm_backend_target_exists "$backend" "$target" || return 1
  # (3) Busy-guard: never inject into an in-use pane.
  #   a) pane_is_busy: the harness shows a busy footer (agent mid-turn).
  if pane_is_busy "$target" "$backend"; then
    log "inject deferred: supervisor pane busy (agent mid-turn)"
    return 1
  fi
  #   b) Composer-guard: inject ONLY into a confirmed-empty GENUINE agent
  #      composer. The shared classifier (fm_backend_composer_state ->
  #      fm_composer_classify_content, bin/fm-composer-lib.sh) reports 'pending'
  #      for real unsubmitted text (a human's half-typed line, or a swallowed
  #      prior injection) and 'unknown' for a bare dead-shell prompt (the agent
  #      exited to its login shell) or an unreadable pane. Neither is a safe
  #      target - typing the escalation into a shell could execute it - so defer
  #      on anything that is not affirmatively 'empty'. A deferred escalation
  #      stays buffered for the next cycle or the catch-up flush.
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$composer" != empty ]; then
    log "inject deferred: supervisor composer not confirmed-empty (state=${composer:-unknown}: pending input, dead-shell prompt, or unreadable pane)"
    return 1
  fi
  # (4) Type the digest ONCE, then submit with Enter (retry Enter only, never
  # retype) via the shared submit primitive. Success = the backend confirms
  # submit. An unconfirmed/unknown pane does NOT count as delivered, so the
  # buffer is preserved (strict) rather than cleared.
  # Dispatches through fm_backend_send_text_submit (bin/fm-backend.sh): for
  # backend=tmux this calls fm_backend_tmux_send_text_submit, a verbatim
  # re-export of fm_tmux_submit_core - byte-identical to calling it directly.
  retries=${FM_INJECT_CONFIRM_RETRIES:-$INJECT_CONFIRM_RETRIES_DEFAULT}
  sleep_s=${FM_INJECT_CONFIRM_SLEEP:-$INJECT_CONFIRM_SLEEP_DEFAULT}
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$msg" "$retries" "$sleep_s" "$sleep_s")
  if [ "$verdict" = empty ]; then
    return 0  # Backend confirmed the submit.
  fi
  log "inject failed: submit unconfirmed after $retries retries (verdict=$verdict, text may be in composer)"
  return 1
}

# --- INJECT_SKIP prefix match (literal prefixes, no regex) ------------------
should_force_self() {  # <reason>
  local reason=$1 skip="${FM_INJECT_SKIP:-$INJECT_SKIP_DEFAULT}" prefix
  [ -n "$skip" ] || return 1
  local -a prefixes
  IFS='|' read -ra prefixes <<<"$skip"
  for prefix in "${prefixes[@]}"; do
    [ -n "$prefix" ] || continue
    [ "$reason" != "${reason#"$prefix"}" ] && return 0
  done
  return 1
}

# A real watcher WAKE reason starts with one of these prefixes. Anything else on
# the watcher child's stdout (e.g. "watcher: already running" on a singleton-lock
# collision, reachable if the daemon was SIGKILL'd and its orphaned watcher child
# still holds the #29 singleton lock) is a STATUS line, not a wake: handling it
# as an unknown wake would flood the escalation buffer and restart the child with
# no crash backoff. The main loop treats a non-wake line as idle (log + sleep +
# continue), so a singleton collision cannot hot-loop escalations.
is_wake_reason() {  # <reason>
  local reason=$1
  case "$reason" in
    signal:*|stale:*|check:*|heartbeat|heartbeat:*) return 0 ;;
  esac
  return 1
}

# --- dispatch one wake reason to self-handle or escalate --------------------
# Side effects: logging, marker records, escalation buffer appends.
handle_wake() {  # <reason> <state>
  local reason=$1 state=$2 decision action distilled task last
  local kind="" arg=""
  if should_force_self "$reason"; then
    log "wake force-self (FM_INJECT_SKIP): $reason"
    return
  fi
  case "$reason" in
    signal:*) kind=signal; arg="${reason#signal: }"
              decision=$(classify_signal "$arg" "$state") ;;
    stale:*)  kind=stale; arg="${reason#stale: }"
              decision=$(classify_stale "$arg" "$state") ;;
    check:*)  decision=$(classify_check "$reason") ;;
    heartbeat|heartbeat:*) decision=$(classify_heartbeat) ;;
    *)        decision=$(classify_unknown "$reason") ;;
  esac
  action=${decision%%|*}
  distilled=${decision#*|}
  [ "$kind" = signal ] && sync_pause_markers_from_signal "$state" "$arg"
  case "$action" in
    escalate)
      log "escalate: $reason -> $distilled"
      escalate_add "$state" "$distilled"
      # A terminal-stale escalate must not leave a persistence marker behind, or
      # housekeeping re-escalates the same pane as a false wedge later.
      [ "$kind" = "stale" ] && stale_marker_remove "$arg" "$state"
      mark_escalated_seen "$kind" "$arg" "$state"
      [ "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" -le 0 ] && { escalate_flush "$state" || true; }
      ;;
    pause)
      # Declared external-wait pause: record a pause marker (long re-surface
      # cadence in housekeeping) and drop any wedge stale marker, so a pane that
      # transitioned working->paused is not still wedge-aged. Only stale produces
      # this action.
      if [ "$kind" = "stale" ]; then
        stale_marker_remove "$arg" "$state"
        pause_marker_record "$arg" "$state"
      fi
      log "self-handle (paused): $reason -> $distilled"
      ;;
    *)
      # Transient (non-terminal) stale: record/refresh the wedge marker so
      # housekeeping can age it, and drop any pause marker (a crew that left its
      # pause reverts to normal wedge aging). The persistence recheck, not this
      # wake, escalates a wedge.
      if [ "$kind" = "stale" ]; then
        task=$(window_to_task "$arg" "$state")
        last=$(last_status_line "$state/$task.status")
        if [ -n "$last" ] && status_is_captain_relevant "$last"; then
          stale_marker_remove "$arg" "$state"
        else
          pause_marker_remove "$arg" "$state"
          stale_marker_record "$arg" "$state"
        fi
      fi
      log "self-handle: $reason -> $distilled"
      ;;
  esac
}

# --- log --------------------------------------------------------------------
# Uses LOG set by fm_super_main; harmless no-op-ish if unset (tests source fns
# directly and pass state explicitly, so they do not call log).
log() { [ -n "${LOG:-}" ] && printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

trim_log() {
  local sz tmp
  [ -n "${LOG:-}" ] || return 0
  sz=$(wc -c < "$LOG" 2>/dev/null) || return 0
  [ "$sz" -ge "${FM_LOG_MAX_BYTES:-$LOG_MAX_BYTES_DEFAULT}" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-daemon-log.XXXXXX") || return 0
  tail -n "${FM_LOG_KEEP_LINES:-$LOG_KEEP_LINES_DEFAULT}" "$LOG" >"$tmp" 2>/dev/null && mv -f "$tmp" "$LOG"
}

# ============================================================================
# Everything below runs only when the script is EXECUTED, not sourced. The pure
# classifiers above are sourceable for unit tests (tests/fm-daemon.test.sh).
# ============================================================================

fm_super_main() {
  local STATE
  STATE="$(_state_root)"
  mkdir -p "$STATE"

  # Source the portable lock helpers (works on macOS where flock is absent).
  # Export FM_STATE_OVERRIDE so the lib resolves the same state dir.
  # shellcheck source=bin/fm-wake-lib.sh
  FM_STATE_OVERRIDE="$STATE" . "$FM_DAEMON_DIR/fm-wake-lib.sh"

  local WATCH="$FM_DAEMON_DIR/fm-watch.sh"
  local LOG="$STATE/.supervise-daemon.log"
  local WATCH_ERR="$STATE/.supervise-daemon.watcher.err"
  local LOCK="$STATE/.supervise-daemon.lock"
  local PIDFILE="$STATE/.supervise-daemon.pid"
  local INJECT_FAIL_SLEEP=${FM_INJECT_FAIL_SLEEP:-$INJECT_FAIL_SLEEP_DEFAULT}
  local CRASH_THRESHOLD=${FM_CRASH_THRESHOLD:-$CRASH_THRESHOLD_DEFAULT}
  local CRASH_WINDOW=${FM_CRASH_WINDOW:-$CRASH_WINDOW_DEFAULT}
  local CRASH_BACKOFF=${FM_CRASH_BACKOFF:-$CRASH_BACKOFF_DEFAULT}
  local CRASH_NORMAL_SLEEP=${FM_CRASH_NORMAL_SLEEP:-$CRASH_NORMAL_SLEEP_DEFAULT}

  [ -x "$WATCH" ] || { echo "error: watcher not found or not executable: $WATCH" >&2; exit 1; }

  # --- single instance (portable lock, no flock dependency) ------------------
  if ! fm_lock_try_acquire "$LOCK"; then
    if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
      echo "error: another fm-supervise-daemon is already running (pid $FM_LOCK_HELD_PID, lock $LOCK held)" >&2
    else
      echo "error: another fm-supervise-daemon is already running (lock $LOCK held)" >&2
    fi
    exit 1
  fi
  echo "$$" > "$PIDFILE"
  fm_pid_identity "${BASHPID:-$$}" > "$LOCK/pid-identity" 2>/dev/null || true

  # --- auto-discover the supervisor BACKEND (tmux vs herdr) first -----------
  # Priority: FM_SUPERVISOR_BACKEND override > $TMUX_PANE (tmux) > $HERDR_ENV=1
  # (herdr) > tmux fallback. Resolved before the target below, since target
  # discovery composes a herdr "<session>:<pane-id>" string using the same
  # $HERDR_PANE_ID/$HERDR_SESSION markers this checks. Exporting the result
  # into FM_SUPERVISOR_BACKEND makes inject_msg/pane_is_busy/pane_input_pending
  # (which read that env var) dispatch through the right backend without an
  # extra global thread-through.
  local discovered_backend backend_source
  backend_source="FM_SUPERVISOR_BACKEND"
  if [ -z "${FM_SUPERVISOR_BACKEND:-}" ]; then
    if [ -n "${TMUX_PANE:-}" ]; then
      backend_source="TMUX_PANE"
    elif [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
      backend_source="HERDR_ENV"
    else
      backend_source="FALLBACK($FM_SUPERVISOR_BACKEND_DEFAULT)"
    fi
  fi
  discovered_backend=$(discover_supervisor_backend) || true
  FM_SUPERVISOR_BACKEND="$discovered_backend"
  local BACKEND="$FM_SUPERVISOR_BACKEND"

  # --- refuse an unsupported supervisor backend loudly, before ever trying a
  # tmux/herdr-specific call against it (zellij, orca, and cmux have no verified
  # composer/busy primitives wired up for this daemon yet - AGENTS.md section 4
  # harness-verification discipline). This is the clear refusal the task calls
  # for, instead of a confusing "does not resolve to a tmux pane" error.
  if ! fm_backend_list_contains "$FM_SUPERVISOR_SUPPORTED_BACKENDS" "$BACKEND"; then
    echo "error: away-mode daemon does not support supervisor backend '$BACKEND' yet (supported: $FM_SUPERVISOR_SUPPORTED_BACKENDS); set FM_SUPERVISOR_BACKEND=tmux|herdr and FM_SUPERVISOR_TARGET to run firstmate's own pane under a supported backend" >&2
    log "startup failed: unsupported supervisor backend '$BACKEND' (source=$backend_source)"
    fm_lock_release "$LOCK" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    exit 1
  fi

  # --- auto-discover the supervisor target (the pane running firstmate) -----
  # Priority: FM_SUPERVISOR_TARGET override > $TMUX_PANE (tmux; inherited from
  # the pane that launched the daemon, normally firstmate's own) >
  # $HERDR_PANE_ID (herdr, composed into "<session>:<pane-id>") > firstmate:0
  # fallback. Exporting the result into FM_SUPERVISOR_TARGET makes inject_msg
  # (which reads that env var) use the discovered pane without an extra global.
  local discovered target_source
  target_source="FM_SUPERVISOR_TARGET"
  if [ -z "${FM_SUPERVISOR_TARGET:-}" ]; then
    if [ -n "${TMUX_PANE:-}" ]; then
      target_source="TMUX_PANE"
    elif [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
      target_source="HERDR_ENV(HERDR_PANE_ID)"
    else
      target_source="FALLBACK(firstmate:0)"
    fi
  fi
  if discovered=$(discover_supervisor_target); then
    : # resolved cleanly
  else
    echo "warn: could not auto-discover supervisor pane (no FM_SUPERVISOR_TARGET, TMUX_PANE, or HERDR_ENV/HERDR_PANE_ID); falling back to '$discovered' — verify this is firstmate's pane" >&2
  fi
  FM_SUPERVISOR_TARGET="$discovered"
  local TARGET="$FM_SUPERVISOR_TARGET"

  # --- validate supervisor target at startup (a missing target is a typo) ---
  # Dispatches through bin/fm-backend.sh instead of a raw `tmux display-message`
  # probe, so a herdr supervisor pane is checked via the herdr adapter; for
  # backend=tmux this runs the exact same `tmux display-message -p -t "$TARGET"
  # '#{pane_id}'` call as before.
  if ! fm_backend_target_exists "$BACKEND" "$TARGET"; then
    echo "error: supervisor target '$TARGET' does not resolve to a $BACKEND pane; set FM_SUPERVISOR_TARGET" >&2
    log "startup failed: target '$TARGET' not found (backend=$BACKEND)"
    fm_lock_release "$LOCK" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    exit 1
  fi

  local afk_status="off"
  afk_active "$STATE" && afk_status="on"
  log "daemon starting (pid $$); target=$TARGET; target_source=$target_source; backend=$BACKEND; backend_source=$backend_source; afk=$afk_status; inject_skip='${FM_INJECT_SKIP:-$INJECT_SKIP_DEFAULT}'; stale_escalate=${FM_STALE_ESCALATE_SECS:-$STALE_ESCALATE_SECS_DEFAULT}s; batch=${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}s"
  migrate_watcher_pause_markers "$STATE"

  # --- shutdown: flush buffered escalations, reap child, release lock -------
  local WATCHER_PID="" CUR_TMP=""
  cleanup() {
    trap - TERM INT
    wedge_alarm_stop_active_notifier
    escalate_flush "$STATE" 2>/dev/null || true
    if [ -n "${WATCHER_PID:-}" ]; then
      kill "$WATCHER_PID" 2>/dev/null || true
      wait "$WATCHER_PID" 2>/dev/null || true
    fi
    if [ -n "${CUR_TMP:-}" ]; then
      rm -f "$CUR_TMP" 2>/dev/null || true
    fi
    fm_lock_release "$LOCK" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    log "daemon shutting down"
    exit 0
  }
  trap cleanup TERM INT

  # --- crash-loop guard -----------------------------------------------------
  local crash_times=() backoff_secs=$CRASH_NORMAL_SLEEP
  record_crash() {
    local now t
    now=$(_now)
    local -a keep=()
    for t in "${crash_times[@]:-}"; do
      [ -n "$t" ] && [ $((now - t)) -lt "$CRASH_WINDOW" ] && keep+=("$t")
    done
    keep+=("$now")
    crash_times=("${keep[@]}")
    if [ "${#crash_times[@]}" -gt "$CRASH_THRESHOLD" ]; then
      log "ERROR: watcher crashed ${#crash_times[@]} times within ${CRASH_WINDOW}s; backing off ${CRASH_BACKOFF}s"
      crash_times=()
      backoff_secs=$CRASH_BACKOFF
    else
      backoff_secs=$CRASH_NORMAL_SLEEP
    fi
  }

  start_watcher() {
    CUR_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-watch.XXXXXX") || { log "error: mktemp failed; retrying in 5s"; sleep 5; return 1; }
    "$WATCH" >"$CUR_TMP" 2>>"$WATCH_ERR" &
    WATCHER_PID=$!
  }

  local rc reason
  while true; do
    # --- pane-gone guard (preserved) ---------------------------------------
    # With the #29 watcher's enqueue-before-suppress, a wake is no longer
    # swallowed by running the watcher with no injection target. We still back
    # off while the pane is gone: self-handling needs no pane, but escalation
    # has nowhere to go, and firstmate itself is the consumer of escalations.
    # Catch-up signals persist in state/*.status and flow on the next run, so
    # this delays rather than loses work.
    if ! fm_backend_target_exists "$BACKEND" "$TARGET"; then
      log "warn: supervisor target '$TARGET' gone; backing off ${INJECT_FAIL_SLEEP}s, will retry"
      # Flush is pointless with no pane; preserve any buffered escalations.
      sleep "$INJECT_FAIL_SLEEP"
      continue
    fi

    # --- (re)start watcher if it has exited --------------------------------
    if [ -z "${WATCHER_PID:-}" ] || ! kill -0 "${WATCHER_PID:-}" 2>/dev/null; then
      if [ -n "${WATCHER_PID:-}" ]; then
        # child exited: reap + classify its wake reason
        if wait "${WATCHER_PID}"; then rc=0; else rc=$?; fi
        reason=""
        if [ -n "${CUR_TMP:-}" ] && [ -e "${CUR_TMP:-}" ]; then
          reason=$(<"${CUR_TMP}")
        fi
        if [ -n "${CUR_TMP:-}" ]; then
          rm -f "${CUR_TMP}" 2>/dev/null || true
        fi
        CUR_TMP=""
        if [ "$rc" -ne 0 ] || [ -z "$reason" ]; then
          record_crash
          log "watcher exited rc=$rc reason='$reason'; restarting after ${backoff_secs}s"
          WATCHER_PID=""
          sleep "$backoff_secs"
          continue
        fi
        # Non-wake stdout (e.g. a watcher singleton-collision "already running"
        # status line) is NOT a wake: idling here prevents an escalation flood
        # and a backoff-less child restart. record_crash is intentionally
        # skipped (rc=0, this is normal idle, not a crash).
        if ! is_wake_reason "$reason"; then
          log "watcher non-wake stdout, idling: $reason"
          WATCHER_PID=""
          sleep "${HOUSEKEEPING_TICK:-$HOUSEKEEPING_TICK_DEFAULT}"
          continue
        fi
        log "wake: $reason"
        handle_wake "$reason" "$STATE"
        trim_log
      fi
      start_watcher || continue
    fi

    # --- one housekeeping tick (gated to HOUSEKEEPING_TICK), then poll -------
    # The watcher child runs on its own FM_POLL cadence internally; we only need
    # to detect its exit (the kill -0 above) promptly and run housekeeping often
    # enough that batch flushes, stale rechecks, and the catch-all scan fire on
    # cadence. Gating keeps a large fleet cheap between ticks.
    sleep 1
    if [ "$(_file_age "$STATE/.subsuper-last-housekeep")" -ge "${FM_HOUSEKEEPING_TICK:-$HOUSEKEEPING_TICK_DEFAULT}" ]; then
      _now > "$STATE/.subsuper-last-housekeep"
      housekeeping "$STATE"
    fi
  done
}

# Run only when executed, not when sourced (tests source the classifiers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_super_main "$@"
else
  # Library mode: these functions were SOURCED (only tests do this - production
  # execs the daemon, see bin/fm-afk-start.sh). Make it structurally impossible
  # for a sourced context to fire a real desktop notification from the wedge
  # alarm: default the FM_WEDGE_ALARM_EXEC notifier seam to "discard" unless the
  # embedder already wired one (e.g. a recorder in tests/wake-helpers.sh). It is
  # exported so a real daemon a test later spawns inherits the safe default too.
  # The executed branch above never runs this, so production is untouched.
  : "${FM_WEDGE_ALARM_EXEC:=discard}"
  export FM_WEDGE_ALARM_EXEC
fi
