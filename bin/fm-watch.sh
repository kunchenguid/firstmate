#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crewmate shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crewmate that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A declared external-wait pause is
# the separate idle absorb case and re-surfaces only on its long bounded cadence,
# although its initial no-verb status signal still surfaces in normal mode.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crewmate
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crewmate's own log gets no new entry once
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
#                          resume. A recognized harness permission prompt surfaces
#                          immediately with an explicit permission-blocked reason.
#                          A pane that remains busy without meaningful output,
#                          status, or turn-end progress surfaces after
#                          FM_PERMISSION_STALL_ESCALATE_SECS as a possible macOS
#                          permission/system-dialog block. Unless afk is active.
#   check: <script>: <out> per-task check output, always actionable
#                          A merged-PR check first attempts fail-closed automatic
#                          teardown; its success or refusal is included here.
#   auto-reap: <out>       stale crashed-spawn acquisition recovery made progress
#                          or refused and retained state for operator inspection
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status or a dead/unknown command-step liveness reading,
#                          unless afk is active
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
WATCHER_ENV="$CONFIG/watcher.env"
if [ -e "$WATCHER_ENV" ] || [ -L "$WATCHER_ENV" ]; then
  [ -f "$WATCHER_ENV" ] && [ ! -L "$WATCHER_ENV" ] \
    || { echo "error: unsafe watcher config: $WATCHER_ENV" >&2; exit 1; }
  # shellcheck disable=SC1090 # The effective home-local watcher config is intentionally dynamic.
  . "$WATCHER_ENV" || { echo "error: could not source watcher config: $WATCHER_ENV" >&2; exit 1; }
fi
mkdir -p "$STATE"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: unsafe watcher state directory: $STATE" >&2; exit 1; }

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Shared wake classifier (captain-relevant verbs + signal/stale/heartbeat
# predicates), the SAME library the away-mode daemon uses, so the triage policy
# has one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# The DEFAULT EVENT SOURCE: this watcher's poll loop over the pull primitives
# (capture, recorded windows, backend busy-state, and the BUSY_REGEX fallback)
# synthesizes the signal/stale/check/heartbeat wake vocabulary for backends with
# no native event push. tmux always reports unknown busy-state, preserving the
# original regex path. A push-capable backend (herdr) additionally replaces this
# watcher's blind terminal sleep with a bounded wait on its native event stream
# (event_wait_or_sleep below), so a crewmate entering `blocked` wakes its supervisor
# sub-second; the poll loop stays live every cycle as the permanent fail-closed
# backstop. See bin/fm-backend.sh and docs/herdr-backend.md.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# Shared normalized-transition accessors and the single-owner status->action
# policy table, so the event-wait splice reads transition records the same way
# the herdr subscriber writes them (bin/fm-transition-lib.sh).
# shellcheck source=bin/fm-transition-lib.sh
. "$SCRIPT_DIR/fm-transition-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
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
ACCOUNT_SESSION_SYNC_INTERVAL=${FM_ACCOUNT_SESSION_SYNC_INTERVAL:-60}
ACCOUNT_SESSION_SYNC_TIMEOUT=${FM_ACCOUNT_SESSION_SYNC_TIMEOUT:-5}
ACCOUNT_SESSION_SYNC_TOTAL_TIMEOUT=${FM_ACCOUNT_SESSION_SYNC_TOTAL_TIMEOUT:-$((ACCOUNT_SESSION_SYNC_TIMEOUT + 3))}
REPORT_RETENTION_INTERVAL=${FM_REPORT_RETENTION_INTERVAL:-86400}
REPORT_RETENTION_TIMEOUT=${FM_REPORT_RETENTION_TIMEOUT:-30}
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working...";
# grok: "Ctrl+c:cancel" (the mid-turn cancel hint in grok's keybind bar, shown iff a
# turn is running; absent when idle - verified grok 0.2.73, ASCII to avoid the
# locale fragility of matching grok's braille spinner glyph directly).
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'}
# Always-on wake triage: most wakes during a long crewmate validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crewmate shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crewmate that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crewmate is not provably working, any check, a stale
# pane whose crewmate is not provably working, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A macOS TCC/system dialog can block a foreground tool while the harness keeps
# rendering its busy footer, so ordinary stale detection never starts. Track a
# semantic pane fingerprint that excludes verified busy-footer churn and surface
# a suspected permission/system-dialog block after this bounded interval. This is
# deliberately a timeout heuristic: direct OS-dialog inspection requires
# pre-granted Accessibility or Screen Recording access and cannot be assumed.
PERMISSION_STALL_ESCALATE_SECS=${FM_PERMISSION_STALL_ESCALATE_SECS:-900}
case "$PERMISSION_STALL_ESCALATE_SECS" in
  ''|*[!0-9]*|0) PERMISSION_STALL_ESCALATE_SECS=900 ;;
esac
# A crewmate that DECLARED a pause (paused: <reason>, fm-classify-lib.sh) is idling on
# a known external wait, so its stale pane is absorbed rather than wedge-escalated;
# it re-surfaces once for a recheck every PAUSE_RESURFACE_SECS - far longer than the
# wedge threshold, but finite so a forgotten pause cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
case "$PAUSE_RESURFACE_SECS" in
  ''|*[!0-9]*|0) PAUSE_RESURFACE_SECS=$FM_PAUSE_RESURFACE_SECS_DEFAULT ;;
esac
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
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

# Append one line to the triage debug log explaining an absorbed (benign) wake,
# size-capped so a long benign stretch cannot grow it without bound. Best-effort:
# a logging hiccup never affects supervision.
triage_log() {
  local sz tmp
  [ ! -L "$TRIAGE_LOG" ] && { [ ! -e "$TRIAGE_LOG" ] || [ -f "$TRIAGE_LOG" ]; } || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tmp=$(mktemp "$STATE/.watch-triage.pending.XXXXXX") || return 0
    if tail -n 2000 "$TRIAGE_LOG" > "$tmp" 2>/dev/null \
      && [ ! -L "$TRIAGE_LOG" ] \
      && { [ ! -e "$TRIAGE_LOG" ] || [ -f "$TRIAGE_LOG" ]; }; then
      mv -f "$tmp" "$TRIAGE_LOG" 2>/dev/null || true
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi
}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is actively working. Prefers
# a backend's native semantic busy state (fm_backend_busy_state - herdr's
# agent.get; herdr-addendum "busy state" row, "the first backend where
# fm_session_busy_state gets real semantics"); falls back to the existing
# pane-tail regex ONLY when the backend reports unknown (tmux always does, so
# its path is unchanged byte-for-byte). <tail40> is the same bounded capture
# already read for hashing, so this adds no extra backend calls on the
# regex-fallback path.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 bs
  bs=$(fm_backend_busy_state "$(window_backend "$w")" "$w" "$(window_label "$w")" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
    idle) return 1 ;;
    *)
      printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
      ;;
  esac
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

window_harness() {
  local w=$1 meta harness
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    harness=$(grep '^harness=' "$meta" | tail -1 | cut -d= -f2- || true)
    [ -n "$harness" ] && { printf '%s' "$harness"; return 0; }
  fi
  printf 'unknown'
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

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

window_scoped_target() {
  local w=$1 meta
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] && fm_meta_get "$meta" tmux_session_target
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

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {  # <reason> [durable-resurface-marker]
  local reason=$1 resurface_marker=${2:-}
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  # A wake exits this watcher immediately and hands control back to the harness.
  # Refresh a supplied cadence marker in this final return path so a newly armed
  # watcher cannot observe the pre-wake age and re-fire the same bounded recheck.
  if [ -n "$resurface_marker" ]; then
    safe_touch_marker "$resurface_marker" \
      || { echo "error: unsafe watcher re-surface marker: $resurface_marker" >&2; exit 1; }
  fi
  echo "$reason"
  exit 0
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
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crewmate
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

# Absorb a stale pane whose crewmate is in a DECLARED external-wait pause (paused:),
# and re-surface it once every PAUSE_RESURFACE_SECS for a recheck so it cannot rot
# invisibly. Called on any stale poll once the crewmate is known paused (first sight,
# after crew_absorb_class; and repeat sights, gated by the .paused-<key> flag), so
# it must be cheap: it NEVER re-reads the crewmate state. The re-surface age is anchored
# on the pause's own STATUS-FILE mtime, not a per-hash marker, so a churny idle pane
# (a ticking clock, a token counter) cannot keep resetting the cadence the way a
# hash-tied timer would. A .paused-resurfaced-<key> throttle marker records the last
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
    wake "$reason" "$rf"
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

pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task" "$last")
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    working|none) rm -f "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

# Surface a stopped stale pane immediately. Pause cadence markers belong to the
# durable status, not to this one surface event: retain them while that status still
# declares a pause, and clear them only after the task has genuinely resumed.
surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last
  key=$(printf '%s' "$win" | tr ':/.' '___')
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if ! status_is_paused "$last"; then
    clear_pause_state "$win"
  fi
  wake "stale: $win"
}

# Recognize the stable confirmation chrome rendered by verified harnesses when a
# mid-run permission or trust grant is waiting on a human. The question alone is
# insufficient because pane output can quote it; each shape also requires its
# title-specific choices and any verified footer in the final 16 lines, and the
# caller requires the harness not to show its busy indicator.
# Exact live-capture evidence and version details live in
# docs/permission-stall-detection.md.
# Pi has no permission system, while firstmate launches OpenCode and Grok in
# their verified unattended modes; their unexpected
# or future prompt shapes remain covered by the bounded no-progress fallback.
permission_prompt_kind() {  # <harness> <tail40> <allow-directory-trust>
  local harness=$1 tail40=$2 allow_directory_trust=${3:-0} prompt_tail
  prompt_tail=$(printf '%s\n' "$tail40" | tail -16)
  case "$harness" in
    claude|unknown)
      if printf '%s\n' "$tail40" | grep -Fq 'Do you want to proceed?' \
        && printf '%s\n' "$prompt_tail" | grep -Eq '1\. Yes' \
        && printf '%s\n' "$prompt_tail" | grep -Eq '3\. No' \
        && printf '%s\n' "$prompt_tail" | grep -Eq 'Esc to cancel.*Tab to amend'; then
        printf 'command/tool permission'
        return 0
      fi
      if [ "$allow_directory_trust" = 1 ] \
        && printf '%s\n' "$tail40" | grep -Fq 'Quick safety check: Is this a project you created or one you trust?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, I trust this folder' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'No, exit' \
        && printf '%s\n' "$prompt_tail" | grep -Eq 'Enter to confirm.*Esc to cancel'; then
        printf 'directory trust'
        return 0
      fi
      ;;
  esac
  case "$harness" in
    codex|unknown)
      if printf '%s\n' "$tail40" | grep -Fq 'Would you like to run the following command?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, proceed' \
        && printf '%s\n' "$prompt_tail" | grep -Eq "No, (continue without running it|and tell Codex what to do differently)" \
        && printf '%s\n' "$prompt_tail" | grep -Fqi 'Press enter to confirm or esc to cancel'; then
        printf 'command/tool permission'
        return 0
      fi
      if printf '%s\n' "$tail40" | grep -Fq 'Would you like to grant these permissions?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, grant these permissions for this turn' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'No, continue without permissions' \
        && printf '%s\n' "$prompt_tail" | grep -Fqi 'Press enter to confirm or esc to cancel'; then
        printf 'permission profile'
        return 0
      fi
      if printf '%s\n' "$tail40" | grep -Fq 'Would you like to make the following edits?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, proceed' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'No, and tell Codex what to do differently' \
        && printf '%s\n' "$prompt_tail" | grep -Fqi 'Press enter to confirm or esc to cancel'; then
        printf 'file edit permission'
        return 0
      fi
      if printf '%s\n' "$tail40" | grep -Eq 'Do you want to approve network access to ".+"\?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, just this once' \
        && printf '%s\n' "$prompt_tail" | grep -Eq "No, (continue without running it|and tell Codex what to do differently|and block this host in the future)" \
        && printf '%s\n' "$prompt_tail" | grep -Fqi 'Press enter to confirm or esc to cancel'; then
        printf 'network access'
        return 0
      fi
      if [ "$allow_directory_trust" = 1 ] \
        && printf '%s\n' "$tail40" | grep -Fq 'Do you trust the contents of this directory?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, continue' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'No, quit'; then
        printf 'directory trust'
        return 0
      fi
      ;;
  esac
  return 1
}

clear_busy_stall_tracking() {  # <window>
  local win=$1 key
  key=$(printf '%s' "$win" | tr ':/.' '___')
  rm -f "$STATE/.stale-busy-hash-$key" "$STATE/.stale-busy-since-$key" \
    "$STATE/.wedge-escalations-busy-$key"
}

handle_permission_prompt() {  # <window> <task> <hash> <kind>
  local win=$1 task=$2 h=$3 kind=$4 key marker escalation_file prior n reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  marker="$STATE/.stale-permission-$key"
  escalation_file="$STATE/.wedge-escalations-permission-$key"
  prior=$(cat "$marker" 2>/dev/null || true)
  if [ "$prior" = "$h" ] && [ "$(age_of "$marker")" -lt "$PERMISSION_STALL_ESCALATE_SECS" ]; then
    return 0
  fi
  if [ "$prior" = "$h" ]; then
    n=$(( $(cat "$escalation_file" 2>/dev/null || echo 1) + 1 ))
  else
    n=1
  fi
  printf '%s' "$n" > "$escalation_file"
  reason="stale: $win (permission-prompt detected: waiting for a $kind grant; inspect the requested action and escalate it to the captain - do not approve it automatically; escalation $n)"
  if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
    reason="stale: $win (permission-prompt detected: waiting for a $kind grant; inspect the requested action and escalate it to the captain - do not approve it automatically; escalation $n; demand-deep-inspection)"
  fi
  fm_wake_append stale "$win" "$reason" || exit 1
  printf '%s' "$h" > "$marker"
  clear_busy_stall_tracking "$win"
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}

# Hash meaningful progress while a harness stays busy. Verified busy-footer lines
# are excluded because elapsed counters and spinners can change on every capture
# while a foreground tool is actually blocked behind an OS modal. Claude's
# separate "Running N shell command" row can also animate its leading glyph, so
# normalize that prefix while preserving the semantic row. Status and turn-end
# signatures are folded in so either signal resets the no-progress clock.
busy_progress_hash() {  # <task> <tail40>
  local task=$1 tail40=$2 status_sig turn_sig
  status_sig=$(stat_sig "$STATE/$task.status" || true)
  turn_sig=$(stat_sig "$STATE/$task.turn-ended" || true)
  {
    printf '%s\n' "$tail40" \
      | awk -v busy_re="$BUSY_REGEX" '{ line[NR] = $0 } END { start = NR - 5; if (start < 1) start = 1; for (i = 1; i <= NR; i++) if (i < start || line[i] !~ busy_re) print line[i] }' \
      | sed -E 's/^.*(Running [0-9]+ shell commands?)/\1/'
    printf 'status=%s\nturn=%s\n' "$status_sig" "$turn_sig"
  } | hash_pane
}

# The OS does not provide a reliable unprivileged TCC-dialog query. This bounded
# fallback detects the observable consequence instead: a harness remains busy but
# its semantic pane, status, and turn-end state make no progress. The wake says
# "possible" rather than claiming a dialog was observed, and repeats only once per
# threshold window while preserving the existing demand-deep-inspection counter.
busy_stall_check() {  # <window> <task> <tail40>
  local win=$1 task=$2 tail40=$3 key hash_file since_file escalation_file h prev since age n reason now
  key=$(printf '%s' "$win" | tr ':/.' '___')
  hash_file="$STATE/.stale-busy-hash-$key"
  since_file="$STATE/.stale-busy-since-$key"
  escalation_file="$STATE/.wedge-escalations-busy-$key"
  h=$(busy_progress_hash "$task" "$tail40")
  prev=$(cat "$hash_file" 2>/dev/null || true)
  now=$(date +%s)
  if [ "$h" != "$prev" ]; then
    printf '%s' "$h" > "$hash_file"
    printf '%s' "$now" > "$since_file"
    rm -f "$escalation_file"
    return 0
  fi
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*) printf '%s' "$now" > "$since_file"; return 0 ;;
  esac
  age=$(( now - since ))
  [ "$age" -ge "$PERMISSION_STALL_ESCALATE_SECS" ] || return 0
  n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$n" > "$escalation_file"
  reason="stale: $win (permission/system-dialog suspected: no meaningful progress for ${age}s while the harness remained busy; inspect the visible macOS dialog or Privacy & Security in System Settings and escalate any grant to the captain; timeout heuristic, not direct OS detection; escalation $n)"
  if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
    reason="stale: $win (permission/system-dialog suspected: no meaningful progress for ${age}s while the harness remained busy; inspect the visible macOS dialog or Privacy & Security in System Settings and escalate any grant to the captain; timeout heuristic, not direct OS detection; escalation $n; demand-deep-inspection)"
  fi
  fm_wake_append stale "$win" "$reason" || exit 1
  printf '%s' "$now" > "$since_file"
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

run_bounded() {  # <seconds> <command> [args...]
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=1 "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=1 "$seconds" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  fi
}

run_check() {
  local c=$1
  run_bounded "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
}

run_auto_reap() {
  "$FM_ROOT/bin/fm-auto-reap.sh" "$@" 2>&1
}

safe_touch_marker() {  # <path>
  local marker=$1
  if [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
    return 1
  fi
  touch "$marker"
}

safe_marker_path() {  # <path>
  local marker=$1
  [ ! -L "$marker" ] && { [ ! -e "$marker" ] || [ -f "$marker" ]; }
}

task_generation_id() {  # <task>
  local task=$1 meta generation
  meta="$STATE/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  generation=$(fm_meta_get "$meta" generation_id)
  [ -n "$generation" ] || return 1
  printf '%s' "$generation"
}

brief_processing_started() {  # <task>
  local task=$1 generation marker
  generation=$(task_generation_id "$task") || return 1
  marker="$STATE/.brief-started-$task"
  safe_marker_path "$marker" || return 1
  [ "$(cat "$marker" 2>/dev/null || true)" = "$generation" ]
}

mark_brief_processing_started() {  # <task>
  local task=$1 generation marker tmp
  brief_processing_started "$task" && return 0
  generation=$(task_generation_id "$task") || return 1
  marker="$STATE/.brief-started-$task"
  tmp=$(mktemp "$STATE/.brief-started-$task.XXXXXX") || return 1
  printf '%s' "$generation" > "$tmp" || { rm -f "$tmp"; return 1; }
  safe_marker_path "$marker" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$marker"
}

UNSAFE_MARKERS_LOGGED='|'
safe_touch_marker_or_log() {  # <path> <label>
  local marker=$1 label=$2
  safe_touch_marker "$marker" && return 0
  case "$UNSAFE_MARKERS_LOGGED" in
    *"|$label|"*) ;;
    *)
      triage_log "unsafe $label marker: $marker"
      UNSAFE_MARKERS_LOGGED="$UNSAFE_MARKERS_LOGGED$label|"
      ;;
  esac
  return 1
}

marker_due() {  # <path> <interval-seconds> <label>
  local marker=$1 interval=$2 label=$3
  if ! safe_marker_path "$marker"; then
    safe_touch_marker_or_log "$marker" "$label" || true
    return 0
  fi
  [ "$(age_of "$marker")" -ge "$interval" ]
}

sync_account_sessions_if_due() {
  local cadence="$STATE/.last-account-session-sync"
  marker_due "$cadence" "$ACCOUNT_SESSION_SYNC_INTERVAL" "watcher cadence" || return 0
  safe_touch_marker_or_log "$cadence" "watcher cadence" || true
  FM_ACCOUNT_SESSION_QUERY_TIMEOUT="$ACCOUNT_SESSION_SYNC_TIMEOUT" \
    FM_ACCOUNT_SESSION_TASK_TIMEOUT="$ACCOUNT_SESSION_SYNC_TOTAL_TIMEOUT" \
    "$FM_ROOT/bin/fm-account-session-sync.sh" --all >/dev/null 2>&1 || true
}

prune_reports_if_due() {
  local cadence="$STATE/.last-report-retention"
  marker_due "$cadence" "$REPORT_RETENTION_INTERVAL" "report retention cadence" || return 0
  if run_bounded "$REPORT_RETENTION_TIMEOUT" "$FM_ROOT/bin/fm-report-stack.mjs" prune >/dev/null 2>&1; then
    safe_touch_marker_or_log "$cadence" "report retention cadence" || true
  fi
}

# Surfaced-marker bookkeeping for the heartbeat backstop. The watcher records the
# captain-relevant status line it SURFACED (woke firstmate for) in
# .hb-surfaced-<task>, the watcher's analogue of the daemon's
# .subsuper-seen-status. Unlike .seen-* (a size:mtime signature advanced on BOTH
# surface and absorb), .hb-surfaced is advanced ONLY on surface, so the heartbeat
# fleet-scan can tell apart a captain-relevant status that already woke firstmate
# from one that has not - the latter being a per-wake-path miss it must surface.
_hb_surfaced_path() { printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }

# Record a status file's captain-relevant last line as surfaced (no-op for a
# non-captain-relevant or empty status). Call AFTER the wake is enqueued, so the
# enqueue-before-suppress ordering holds for this marker too.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

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

# Heartbeat fleet-scan (the always-on twin of the daemon's catch-all). Status
# events retain their surfaced-marker dedup. Command-step liveness is handled as
# three explicit states: alive is healthy, while dead and unknown both surface
# because neither may be absorbed as positive evidence. A line with no liveness
# observation keeps its prior behavior.
heartbeat_scan_finds_actionable() {
  local f task last surfaced verdict
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  while IFS=$(printf '\t') read -r task verdict _; do
    [ -n "$task" ] || continue
    case "$verdict" in
      alive) ;;
      dead|unknown) return 0 ;;
      *) return 0 ;;
    esac
  done < <(scan_crew_liveness_observations "$STATE")
  return 1
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crewmate going
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

# handle_push_transition: act on a fresh actionable (blocked) transition record
# the backend returned. Maps the pane back to its window and task, applies the
# declared-pause exemption (a crewmate waiting on a known external dependency is not
# a surprise block - absorb it on the poll loop's long pause cadence instead),
# and otherwise enqueues an immediate `stale` wake and wakes the supervisor. The
# `stale` kind is deliberate: the supervisor's handler for it ("peek the pane to
# diagnose") is exactly right for a blocked crewmate, and the drain/dedupe/guard
# machinery already understands it (queued by key=window, so a later poll-path
# stale for the same pane collapses on drain).
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task key h reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    # The durable status is the trusted gate on this native edge. Commit the
    # handled transition, then enter the shared pause path so it owns the marker
    # and bounded re-surface cadence even when no auxiliary crew-state read exists.
    key=$(printf '%s' "$window" | tr ':/.' '___')
    h=$(cat "$STATE/.hash-$key" 2>/dev/null || true)
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    handle_paused_stale "$window" "$task" "$h"
    triage_log "absorbed push $to (declared pause, awaiting external): $window"
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

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
trap 'fm_lock_release "$WATCH_LOCK"' EXIT
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

if ! safe_marker_path "$STATE/.last-heartbeat" || [ ! -e "$STATE/.last-heartbeat" ]; then
  safe_touch_marker_or_log "$STATE/.last-heartbeat" "watcher heartbeat" || true
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
  safe_touch_marker_or_log "$STATE/.last-watcher-beat" "watcher beacon" || true

  prune_reports_if_due

  # A managed provider's SessionStart hook may race the initial spawn return.
  # Reconcile only metas still missing provider_session_id; failures stay
  # silent and retry here, while recovery itself requires the mapping and
  # fails closed.
  sync_account_sessions_if_due

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if marker_due "$STATE/.last-check" "$CHECK_INTERVAL" "watcher check"; then
    auto_reap_out=$(run_auto_reap maintenance || true)
    if [ -n "$auto_reap_out" ]; then
      reason="auto-reap: $auto_reap_out"
      fm_wake_append check auto-reap "$reason" || exit 1
      safe_touch_marker_or_log "$STATE/.last-check" "watcher check" || true
      wake "$reason"
    fi
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      out=$(run_check "$c")
      if [ -n "$out" ]; then
        task=${c##*/}
        task=${task%.check.sh}
        if [ "$(printf '%s\n' "$out" | tail -1)" = merged ] && [ -f "$STATE/$task.meta" ]; then
          auto_reap_out=$(run_auto_reap task "$task" pr-merged || true)
          reason="check: $c: $out; $auto_reap_out"
        else
          reason="check: $c: $out"
        fi
        fm_wake_append check "$c" "$reason" || exit 1
        safe_touch_marker_or_log "$STATE/.last-check" "watcher check" || true
        wake "$reason"
      fi
    done
    safe_touch_marker_or_log "$STATE/.last-check" "watcher check" || true
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
    # A scout's terminal done event is its automatic reaping trigger. Ship work
    # waits for the separate merged-PR or approved local-merge authority.
    for f in $files; do
      case "$f" in
        "$STATE"/*.status)
          task=${f##*/}
          task=${task%.status}
          if [ -f "$STATE/$task.meta" ] \
            && [ "$(fm_meta_get "$STATE/$task.meta" kind)" = scout ] \
            && [ "$(status_line_verb "$(last_status_line "$f")")" = "done" ]; then
            auto_reap_out=$(run_auto_reap task "$task" scout-done || true)
            reason="signal: $f; $auto_reap_out"
            fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
            wake "$reason"
          fi
          ;;
      esac
    done
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crewmate is
    #     NOT provably working - the crewmate stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crewmate IS provably working) in always-on mode -> advance the markers so it
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
    if ! status_is_paused "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$w"
    fi
    if [ "$kind" = secondmate ] && ! status_is_paused "$last"; then
      continue
    fi
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" "$(window_scoped_target "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    window_busy=0
    if window_is_busy "$w" "$tail40"; then
      window_busy=1
      mark_brief_processing_started "$task" || true
    fi
    # A declared external wait is its own idle state and must be classified
    # before every stale fast path. Permission-prompt detection previously ran
    # first, so a permission-shaped Herdr pane woke on every changing capture
    # without ever creating .paused-<key>. Authoritative working state still
    # outranks a stale paused log and falls through to ordinary stale handling.
    if ! afk_present && [ "$window_busy" != 1 ] && status_is_paused "$last"; then
      case "$(pause_state_class "$w" "$task")" in
        paused)
          handle_paused_stale "$w" "$task" "$h"
          continue
          ;;
        working)
          clear_pause_state "$w"
          ;;
        none)
          clear_pause_tracking "$w"
          ;;
        *)
          clear_pause_tracking "$w"
          ;;
      esac
    fi
    if [ "$window_busy" != 1 ]; then
      allow_directory_trust=0
      brief_processing_started "$task" && allow_directory_trust=1
      prompt_kind=$(permission_prompt_kind "$(window_harness "$w")" "$tail40" "$allow_directory_trust" || true)
      if [ -n "$prompt_kind" ]; then
        handle_permission_prompt "$w" "$task" "$h" "$prompt_kind"
        continue
      fi
    fi
    rm -f "$STATE/.stale-permission-$key" "$STATE/.wedge-escalations-permission-$key"
    if [ "$window_busy" = 1 ]; then
      busy_stall_check "$w" "$task" "$tail40"
    else
      clear_busy_stall_tracking "$w"
    fi
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's current stale is a declared pause
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy match: a backend's native semantic state when available (herdr),
      # else the last 6 non-blank lines only (the TUI footer area, where every
      # verified harness renders its busy indicator) so busy-looking strings
      # in displayed content cannot suppress stale detection.
      if [ "$n" -ge 2 ] && [ "$window_busy" != 1 ]; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            working|none) clear_pause_tracking "$w" ;;
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
          # proof the crewmate is actually done: a crewmate's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crewmate was surfaced as stale every few minutes despite an
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
            # without re-reading the crewmate state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crewmate gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly run-step read runs only
          # on first sight, never every poll) via crew_absorb_class, which returns
          # BOTH absorb reasons from one fm-crew-state.sh read:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: the crewmate DECLARED an external wait (paused:), so absorb on the
          #     long PAUSE_RESURFACE_SECS recheck cadence instead of wedge-escalating;
          #   - none: no running pipeline, idle pane, no busy signature, no declared
          #     pause - the crewmate has STOPPED. Surface immediately so firstmate peeks
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(crew_absorb_class "$task")" in
              working)
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              none)
                surface_nonterminal_stale "$w" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$w"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                none)    surface_nonterminal_stale "$w" "$h" ;;
                *)       surface_nonterminal_stale "$w" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping.
        rm -f "$ssf" "$ewf"
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      rm -f "$ssf" "$ewf"
      task=$(window_to_task "$w" "$STATE")
      if ! afk_present && status_is_paused "$(last_status_line "$STATE/$task.status")" && [ "$window_busy" != 1 ]; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          working|none) clear_pause_tracking "$w" ;;
          *)      clear_pause_tracking "$w" ;;
        esac
      else
        [ -e "$pf" ] && clear_pause_tracking "$w"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a bounded fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if marker_due "$STATE/.last-heartbeat" "$hb" "watcher heartbeat"; then
    # Triage: in always-on mode a heartbeat is benign unless the fleet-scan turns
    # up a captain-relevant status or a dead/unknown command-step liveness reading.
    # Unknown is grouped with actionable here because a heartbeat needs only the
    # binary absorb/surface decision, and unknown is not proof of health. The
    # away-mode daemon, when present, owns triage and wants every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      safe_touch_marker_or_log "$STATE/.last-heartbeat" "watcher heartbeat" || true
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      safe_touch_marker_or_log "$STATE/.last-heartbeat" "watcher heartbeat" || true
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      safe_touch_marker_or_log "$STATE/.last-heartbeat" "watcher heartbeat" || true
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
