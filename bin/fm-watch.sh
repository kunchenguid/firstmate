#!/usr/bin/env bash
# Firstmate watcher.
# Blocks until supervision work is due, then exits printing one reason line:
#   signal: <file>...     a crewmate wrote a status line or a turn-end hook fired; signals
#                         landing within FM_SIGNAL_GRACE of each other coalesce into one wake
#   stale: <window>       a crewmate pane stopped changing and shows no busy signature
#   check: <script>: <out> a per-task check script (e.g. merged-PR poll) produced output
#   heartbeat              fleet review due; starts at FM_HEARTBEAT and backs off to FM_HEARTBEAT_MAX
# Run as a background task. Re-arm it after handling each wake; duplicate
# invocations no-op through the watcher singleton lock. `--keepalive` runs a
# silent sidecar that re-arms this one-shot watcher when the liveness beacon
# goes stale and no live watcher holds the singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
KEEPALIVE_LOCK="$STATE/.watch.keepalive.lock"
KEEPALIVE_LOG="$STATE/.watch.keepalive.log"
KEEPALIVE_ERR="$STATE/.watch.keepalive.err"
KEEPALIVE_INTERVAL=${FM_WATCH_KEEPALIVE_INTERVAL:-30}
KEEPALIVE_CRASH_THRESHOLD=${FM_WATCH_KEEPALIVE_CRASH_THRESHOLD:-5}
KEEPALIVE_CRASH_BACKOFF=${FM_WATCH_KEEPALIVE_CRASH_BACKOFF:-300}

watch_lock_live() {
  local pid
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  fm_pid_alive "$pid"
}

# A task is in flight when any state/*.meta exists. The keepalive exists only to
# keep a one-shot watcher alive while work exists; with the fleet empty there is
# no consumer for the wakes a watcher would enqueue, so the keepalive must not
# spawn or keep re-arming.
work_in_flight() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] && return 0
  done
  return 1
}

keepalive_log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$KEEPALIVE_LOG" 2>/dev/null || true
}

ensure_keepalive() {
  [ "${FM_WATCH_KEEPALIVE:-1}" = "0" ] && return 0
  [ "${FM_WATCH_KEEPALIVE_CHILD:-0}" = "1" ] && return 0
  work_in_flight || return 0
  if fm_lock_try_acquire "$KEEPALIVE_LOCK"; then
    fm_lock_release "$KEEPALIVE_LOCK"
    FM_WATCH_KEEPALIVE_CHILD=1 "$0" --keepalive >/dev/null 2>>"$KEEPALIVE_ERR" &
  fi
}

run_keepalive() {
  local beat="$STATE/.last-watcher-beat" age pid="" tmp="" rc reason now backoff_until=0 crash_count=0

  if ! fm_lock_try_acquire "$KEEPALIVE_LOCK"; then
    exit 0
  fi
  trap 'kill "$pid" 2>/dev/null || true; [ -n "$pid" ] && wait "$pid" 2>/dev/null || true; [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null || true; fm_lock_release "$KEEPALIVE_LOCK"' EXIT
  keepalive_log "keepalive starting (pid $$); stale_grace=${WATCHER_STALE_GRACE}s interval=${KEEPALIVE_INTERVAL}s"

  while :; do
    if ! work_in_flight; then
      keepalive_log "fleet empty; keepalive stopping"
      break
    fi
    age=$(fm_path_age "$beat")
    if [ "$age" -ge "$WATCHER_STALE_GRACE" ] && ! watch_lock_live; then
      now=$(date +%s)
      if [ "$now" -lt "$backoff_until" ]; then
        sleep "$KEEPALIVE_INTERVAL"
        continue
      fi
      tmp=$(mktemp "${TMPDIR:-/tmp}/fm-watch-keepalive.XXXXXX") || {
        sleep "$KEEPALIVE_INTERVAL"
        continue
      }
      keepalive_log "re-arming watcher after stale beacon age ${age}s"
      FM_WATCH_KEEPALIVE_CHILD=1 FM_WATCH_KEEPALIVE=0 "$0" >"$tmp" 2>>"$KEEPALIVE_ERR" &
      pid=$!
      wait "$pid"; rc=$?
      pid=""
      reason=$(cat "$tmp" 2>/dev/null || true)
      rm -f "$tmp" 2>/dev/null || true
      tmp=""

      if [ "$rc" -ne 0 ] || [ -z "$reason" ]; then
        now=$(date +%s)
        crash_count=$((crash_count + 1))
        keepalive_log "watcher re-arm exited rc=$rc reason='$reason' (consecutive failures: $crash_count)"
        if [ "$crash_count" -gt "$KEEPALIVE_CRASH_THRESHOLD" ]; then
          backoff_until=$((now + KEEPALIVE_CRASH_BACKOFF))
          crash_count=0
          keepalive_log "watcher re-arm crash loop; backing off ${KEEPALIVE_CRASH_BACKOFF}s"
        fi
      else
        crash_count=0
        keepalive_log "watcher one-shot exited with: $reason"
      fi
    fi
    sleep "$KEEPALIVE_INTERVAL"
  done
}

case "${1:-}" in
  --keepalive)
    run_keepalive
    exit 0
    ;;
esac

ensure_keepalive
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
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat wakes
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working..."
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.'}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_meta_field: print <field> from the state/*.meta whose window= matches
# <window>, <default> when the matching meta lacks the field, and "unknown"
# when no meta records the window.
window_meta_field() {  # <window> <field> <default>
  local w=$1 field=$2 default=$3 meta mw val
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || continue
    val=$(grep "^$field=" "$meta" | cut -d= -f2- || true)
    [ -n "$val" ] || val=$default
    echo "$val"
    return 0
  done
  echo unknown
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(grep '^window=' "$meta" | cut -d= -f2- || true)
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
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# Check and heartbeat cadence must survive restarts: the watcher exits on every
# wake and is relaunched, so in-memory counters never reach their threshold on
# a busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file; .seen-* is updated only when a wake is reported, so
# a watcher killed mid-cycle never swallows a signal.
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

run_check() {
  local c=$1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  fi
}

while :; do
  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      out=$(run_check "$c")
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # waking: a crewmate's final status write and the same turn's turn-end hook
  # land seconds apart, and reporting them as separate wakes costs a full
  # firstmate turn each. The re-scan also picks up a newer signature for an
  # already-pending file (last write wins below).
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
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale state is reported once (.stale-* remembers the hash already reported).
  while IFS= read -r w; do
    key=$(printf '%s' "$w" | tr ':/.' '___')
    # Codex can block mid-turn on its additional-safety menu. Clear it before
    # classifying the recorded crewmate pane so the pause never reads as stale.
    # Only panes whose meta records the codex harness get keys, and at most
    # FM_SAFETY_AUTOCLEAR_MAX consecutive attempts - verified clears and
    # unverified attempts (copy-mode absorbing keys, lookalike content) both
    # count - after which the pane falls through to stale classification
    # instead of receiving keypresses forever. The counter resets only once
    # the menu is confirmed gone.
    if [ "$(window_meta_field "$w" harness unknown)" = codex ]; then
      clearf="$STATE/.count-safety-$key"
      cleared=$(cat "$clearf" 2>/dev/null || echo 0)
      if [ "$cleared" -lt "${FM_SAFETY_AUTOCLEAR_MAX:-5}" ]; then
        fm_clear_safety_prompt "$w"
        case $? in
          0)
            echo $(( cleared + 1 )) > "$clearf"
            continue
            ;;
          2)
            echo $(( cleared + 1 )) > "$clearf"
            ;;
          *)
            rm -f "$clearf"
            ;;
        esac
      elif ! tmux capture-pane -p -t "$w" -S -20 2>/dev/null | fm_tmux_safety_prompt_selection >/dev/null; then
        rm -f "$clearf"
      fi
    fi
    # A secondmate idling on its own watcher is healthy. Its parent supervises
    # it through status writes and heartbeats, not pane-idle staleness.
    [ "$(window_meta_field "$w" kind ship)" = secondmate ] && continue
    tail40=$(tmux capture-pane -p -t "$w" -S -40 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy match runs on the last 6 non-blank lines only (the TUI footer area,
      # where every verified harness renders its busy indicator) so busy-looking
      # strings in displayed content cannot suppress stale detection.
      if [ "$n" -ge 2 ] && ! printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"; then
        if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
          fm_wake_append stale "$w" "stale: $w" || exit 1
          printf '%s' "$h" > "$sf"
          wake "stale: $w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
    fi
  done < <(recorded_windows)

  # Heartbeat: firstmate reviews the whole fleet at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any other wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    fm_wake_append heartbeat heartbeat heartbeat || exit 1
    touch "$STATE/.last-heartbeat"
    wake "heartbeat"
  fi

  sleep "$POLL"
done
