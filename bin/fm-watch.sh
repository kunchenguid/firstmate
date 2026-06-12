#!/usr/bin/env bash
# Firstmate watcher.
# Blocks until any managed crewmate needs attention, then exits printing one reason line:
#   signal: <file>        a crewmate wrote a status line or a turn-end hook fired
#   stale: <window>       a crewmate pane stopped changing and shows no busy signature
#   check: <script>: <out> a per-task check script (e.g. merged-PR poll) produced output
#   heartbeat              fleet review due; starts at FM_HEARTBEAT and backs off to FM_HEARTBEAT_MAX
# Run as a background task. Restart it after handling each wake.
set -u

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$FM_ROOT/state"
mkdir -p "$STATE"

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat wakes
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working..."
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.'}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
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
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

while :; do
  # Layer 2 + 3 signals: status files and turn-end markers. Each file is
  # compared against a persisted size:mtime signature (.seen-*) rather than
  # mtime-vs-a-startup-touch, so signals that land while no watcher is running
  # are caught by the next one, and same-second writes cannot slip through a
  # strict -nt comparison.
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat -f '%z:%Fm' "$f" 2>/dev/null || stat -c '%s:%Y' "$f" 2>/dev/null) || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s' "$sig" > "$sf"
      wake "signal: $f"
    fi
  done

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale state is reported once (.stale-* remembers the hash already reported).
  while IFS= read -r w; do
    tail40=$(tmux capture-pane -p -t "$w" -S -40 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
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
          printf '%s' "$h" > "$sf"
          wake "stale: $w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
    fi
  done < <(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep ':fm-' || true)

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    touch "$STATE/.last-check"
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      out=$(bash "$c" 2>/dev/null || true)
      if [ -n "$out" ]; then
        wake "check: $c: $out"
      fi
    done
  fi

  # Heartbeat: firstmate reviews the whole fleet at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any other wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    touch "$STATE/.last-heartbeat"
    wake "heartbeat"
  fi

  sleep "$POLL"
done
