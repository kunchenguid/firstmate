#!/usr/bin/env bash
# Live Pi footer-clock drift guard on a private tmux socket.
# It launches each installed Pi identity without submitting a prompt, observes a
# real idle HH:MM transition, drives the watcher through that transition, and
# then types unsubmitted composer text to prove genuine pane progress surfaces.
set -u

if [ "${FM_PI_FOOTER_CLOCK_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_PI_FOOTER_CLOCK_LIVE=1 to run the live Pi footer-clock guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
BASE_PATH=$PATH
LAB="$ROOT/.pi-footer-clock-live.$$"
SOCKET="fm-pi-footer-clock-$$"
SESSION=pifooter
WATCH_PID=
CHECKED=0

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "FM_PI_FOOTER_CLOCK_LIVE=1 but tmux is not installed"
REAL_TMUX=$(command -v tmux)

cleanup() {
  if [ -n "${WATCH_PID:-}" ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB/shim" "$LAB/project" "$LAB/root"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
cat > "$LAB/shim/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'state: unknown · source: none · idle live Pi guard'
SH
chmod +x "$LAB/shim/fm-crew-state.sh"

git -C "$LAB/project" init -q || fail "could not initialize the isolated Pi project"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -x 220 -y 50 \
  -c "$LAB/project" -- sleep 600 || fail "could not start the private tmux server"

capture() {  # <target>
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$1" -S -40 2>/dev/null
}

footer_clock() {  # <target>
  capture "$1" | awk '
    {
      if ($0 ~ /^[[:space:]]*▶▶ agent (ready|working)([[:space:]].*)?$/ &&
          previous ~ /ctx:(\?|[0-9]+%).*\([0-9]+(\.[0-9]+)?[kM]? context\)/) {
        line = previous
        if (match(line, /  [0-9][0-9]:[0-9][0-9]([[:space:]]|$)/))
          value = substr(line, RSTART + 2, 5)
      }
      previous = $0
    }
    END { if (value != "") print value }
  '
}

wait_footer_clock() {  # <target> [different-from]
  local target=$1 previous=${2:-} clock i=0
  while [ "$i" -lt 240 ]; do
    clock=$(footer_clock "$target")
    if [ -n "$clock" ] && { [ -z "$previous" ] || [ "$clock" != "$previous" ]; }; then
      printf '%s\n' "$clock"
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

is_live_non_zombie() {  # <pid>
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in Z*) return 1 ;; esac
  return 0
}

wait_for_exit() {  # <pid> [ticks]
  local pid=$1 limit=${2:-200} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 124
}

wait_counter_gt() {  # <file> <baseline> <pid>
  local file=$1 baseline=$2 pid=$3 value i=0
  while [ "$i" -lt 100 ]; do
    is_live_non_zombie "$pid" || return 1
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) [ "$value" -gt "$baseline" ] && return 0 ;;
    esac
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

ack_stopped_cycle() {  # <state>
  local state=$1
  local err="$state/drain.err" sequence generation
  PATH="$LAB/shim:$BASE_PATH" FM_ROOT_OVERRIDE="$LAB/root" FM_STATE_OVERRIDE="$state" \
    "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  PATH="$LAB/shim:$BASE_PATH" FM_ROOT_OVERRIDE="$LAB/root" FM_STATE_OVERRIDE="$state" \
    "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}

start_watcher() {  # <state> <stdout> <stderr>
  local state=$1 out=$2 err=$3
  : > "$out"
  : > "$err"
  PATH="$LAB/shim:$BASE_PATH" FM_ROOT_OVERRIDE="$LAB/root" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$LAB/shim/fm-crew-state.sh" FM_POLL=0.5 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999999 FM_HEARTBEAT=999999999 "$WATCH" > "$out" 2> "$err" &
  WATCH_PID=$!
}

for harness in pi pi-signed; do
  binary=$(command -v "$harness" 2>/dev/null || true)
  if [ -z "$binary" ]; then
    note "harness absent, not verified here: $harness"
    continue
  fi
  version=$("$binary" --version 2>/dev/null | head -1 | tr -d '\r')
  [ -n "$version" ] || version='version-unknown'
  target="$SESSION:$harness"
  state="$LAB/$harness/state"
  out="$LAB/$harness/watch.out"
  err="$LAB/$harness/watch.err"
  mkdir -p "$state"

  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/project" -- \
    env FM_PI_HARNESS="$harness" "$binary" --approve --no-session --no-context-files \
      --no-skills --no-prompt-templates --tui-mode regular \
    || fail "$harness ($version): could not launch in the private tmux server"

  clock_before=$(wait_footer_clock "$target") || {
    capture "$target" | tail -12 >&2
    fail "$harness ($version): real Claude-style idle footer was not observed"
  }

  printf 'window=%s\nbackend=tmux\nkind=ship\nharness=%s\n' "$target" "$harness" \
    > "$state/footer-clock.meta"
  key=$(printf '%s' "$target" | tr ':/.' '___')

  start_watcher "$state" "$out" "$err"
  initial_pid=$WATCH_PID
  wait_for_exit "$initial_pid" 200 \
    || fail "$harness ($version): initial real idle pane did not surface: $(cat "$err")"
  WATCH_PID=
  grep -Fx "stale: $target" "$out" >/dev/null \
    || fail "$harness ($version): initial real idle pane did not print stale"
  initial_count=$(cat "$state/.count-$key" 2>/dev/null || true)
  case "$initial_count" in
    ''|*[!0-9]*) fail "$harness ($version): initial stale counter was not numeric" ;;
  esac
  ack_stopped_cycle "$state" \
    || fail "$harness ($version): initial stale cycle could not be acknowledged"

  clock_before=$(footer_clock "$target")
  [ -n "$clock_before" ] || fail "$harness ($version): idle footer disappeared before clock observation"
  start_watcher "$state" "$out" "$err"
  quiet_pid=$WATCH_PID
  clock_after=$(wait_footer_clock "$target" "$clock_before") || {
    fail "$harness ($version): idle footer clock did not change within the live observation bound"
  }
  tick_count=$(cat "$state/.count-$key" 2>/dev/null || true)
  case "$tick_count" in
    ''|*[!0-9]*) fail "$harness ($version): stale counter was not numeric at the clock transition" ;;
  esac
  poll_baseline=$tick_count
  [ "$initial_count" -le "$poll_baseline" ] || poll_baseline=$initial_count
  wait_counter_gt "$state/.count-$key" "$poll_baseline" "$quiet_pid" \
    || fail "$harness ($version): watcher did not complete a monotonic stale scan after $clock_before changed to $clock_after: $(cat "$out") $(cat "$err")"
  [ ! -s "$out" ] \
    || fail "$harness ($version): real idle clock transition emitted another wake: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "$harness ($version): real idle clock transition queued another wake"

  probe="LIVE_PI_PANE_PROGRESS_${harness}_$$"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" -l "$probe" \
    || fail "$harness ($version): could not type the genuine-progress probe"
  capture "$target" | grep -F "$probe" >/dev/null \
    || fail "$harness ($version): genuine-progress probe was not visible in the real pane"
  wait_for_exit "$quiet_pid" 200 \
    || fail "$harness ($version): genuine real pane progress did not surface: $(cat "$err")"
  WATCH_PID=
  grep -Fx "stale: $target" "$out" >/dev/null \
    || fail "$harness ($version): genuine real pane progress lost its stale notification"

  pass "$harness ($version): real idle footer clock changed without another stale wake and typed pane progress still surfaced"
  CHECKED=$((CHECKED + 1))
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
done

[ "$CHECKED" -gt 0 ] \
  || fail "no Pi harness is installed, so the live footer-clock guard verified nothing"
pass "live Pi footer-clock guard verified $CHECKED installed harness(es)"
