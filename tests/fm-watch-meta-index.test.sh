#!/usr/bin/env bash
# tests/fm-watch-meta-index.test.sh - the watcher's per-cycle window->meta
# index (bin/fm-backend.sh fm_backend_meta_index_build / _lookup) and its
# mid-cycle liveness beacon (bin/fm-watch.sh watcher_beat_due).
#
# A home with ~75 records made every per-window lookup rescan every meta, so one
# watcher cycle outlasted the liveness grace and every re-arm refused the live
# watcher as stale. The library cases pin that an indexed lookup returns what a
# scan returns, falls back to the scan whenever the snapshot no longer matches
# the home, and answers a hit without reading any other meta. The watcher cases
# drive a real fm-watch.sh through a deliberately slow cycle and require the
# beacon to keep advancing inside it, against a control run whose only beat is
# the cycle top.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-meta-index-tests)

BLOCKER_PID=
WATCH_PID=
cleanup() {
  [ -z "$BLOCKER_PID" ] || kill "$BLOCKER_PID" 2>/dev/null || true
  [ -z "$WATCH_PID" ] || kill "$WATCH_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# scan_meta <target> <state>: the unindexed answer, for equivalence checks.
scan_meta() {
  local saved_state=$FM_BACKEND_META_INDEX_STATE out rc
  FM_BACKEND_META_INDEX_STATE=
  out=$(fm_backend_meta_for_window "$1" "$2")
  rc=$?
  FM_BACKEND_META_INDEX_STATE=$saved_state
  printf '%s' "$out"
  return "$rc"
}

test_index_matches_scan() {
  local state="$TMP_ROOT/match/state" target want got
  mkdir -p "$state"
  fm_write_meta "$state/alpha.meta" window=sess:w1:p1 kind=ship
  fm_write_meta "$state/bravo.meta" window=sess:w1:p2 terminal=term-bravo kind=ship
  # Last value wins: a re-recorded window replaces the first one.
  fm_write_meta "$state/charlie.meta" window=sess:old:p9 kind=ship window=sess:w2:p3
  # Two records naming one target: the scan's first meta wins, and so must the index.
  fm_write_meta "$state/delta.meta" window=sess:dup:p4 kind=ship
  fm_write_meta "$state/echo.meta" window=sess:dup:p4 kind=scout
  fm_write_meta "$state/foxtrot.meta" kind=ship
  fm_backend_meta_index_build "$state"
  for target in sess:w1:p1 sess:w1:p2 term-bravo sess:w2:p3 sess:dup:p4 sess:old:p9 nowhere; do
    want=$(scan_meta "$target" "$state")
    got=$(fm_backend_meta_for_window "$target" "$state")
    [ "$got" = "$want" ] || fail "indexed lookup of $target returned '$got', scan returned '$want'"
  done
  [ "$(fm_backend_meta_for_window sess:dup:p4 "$state")" = "$state/delta.meta" ] \
    || fail "a duplicated target did not resolve to the first meta"
  [ "$(window_to_task term-bravo "$state")" = bravo ] \
    || fail "window_to_task did not resolve a terminal target through the index"
  [ "$(window_to_task sess:w2:p3 "$state")" = charlie ] \
    || fail "window_to_task did not resolve a re-recorded window through the index"
  fm_backend_meta_index_lookup sess:old:p9 "$state" \
    && fail "a superseded window value was indexed"
  fm_backend_meta_index_clear
  pass "indexed lookups match the full scan, including last-value and first-meta order"
}

test_index_falls_back_when_home_changes() {
  local state="$TMP_ROOT/change/state" other="$TMP_ROOT/change/other"
  mkdir -p "$state" "$other"
  fm_write_meta "$state/alpha.meta" window=sess:w1:p1
  fm_write_meta "$state/bravo.meta" window=sess:w1:p2
  fm_write_meta "$other/zulu.meta" window=sess:w1:p1
  fm_backend_meta_index_build "$state"

  # Rewritten after the build: the stale entry is rejected and the scan answers.
  fm_write_meta "$state/alpha.meta" window=sess:moved:p7
  fm_backend_meta_for_window sess:w1:p1 "$state" >/dev/null \
    && fail "a target its meta no longer records still resolved"
  [ "$(fm_backend_meta_for_window sess:moved:p7 "$state")" = "$state/alpha.meta" ] \
    || fail "a rewritten meta's new target did not resolve through the scan"

  # Removed after the build.
  rm -f "$state/bravo.meta"
  fm_backend_meta_for_window sess:w1:p2 "$state" >/dev/null \
    && fail "a removed meta still resolved from the index"
  [ "$(window_to_task sess:w1:p2 "$state")" = p2 ] \
    || fail "window_to_task did not fall back to the target-shaped id for a removed meta"

  # Created after the build.
  fm_write_meta "$state/charlie.meta" window=sess:new:p8
  [ "$(window_to_task sess:new:p8 "$state")" = charlie ] \
    || fail "a meta created after the build did not resolve"

  # A lookup against a different state directory never consults this index.
  [ "$(fm_backend_meta_for_window sess:w1:p1 "$other")" = "$other/zulu.meta" ] \
    || fail "a lookup in another state directory used this home's index"

  # An index built over a home with no records answers nothing under set -u.
  mkdir -p "$TMP_ROOT/change/empty"
  fm_backend_meta_index_build "$TMP_ROOT/change/empty"
  fm_backend_meta_index_lookup sess:w1:p1 "$TMP_ROOT/change/empty" \
    && fail "an empty index reported a hit"
  fm_backend_meta_index_clear
  pass "the index falls back to the scan for rewritten, removed, new, and foreign records"
}

# wait_done <pid> <ticks>: 0 when <pid> exits within <ticks> 0.1s ticks.
wait_done() {
  local pid=$1 limit=$2 i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_index_hit_reads_no_other_meta() {
  local state="$TMP_ROOT/noscan/state" out="$TMP_ROOT/noscan/out" fifo pid
  mkdir -p "$state"
  fm_write_meta "$state/mike.meta" window=sess:w5:p5
  fm_backend_meta_index_build "$state"
  # A FIFO meta that sorts first blocks any scan that opens it, so a lookup
  # that finishes proves it never walked the other records.
  fifo="$state/0-block.meta"
  mkfifo "$fifo" || fail "could not create the blocking meta"

  ( window_to_task sess:w5:p5 "$state" > "$out" ) &
  pid=$!
  wait_done "$pid" 50 || { kill "$pid" 2>/dev/null; fail "an indexed hit opened another meta"; }
  [ "$(cat "$out")" = mike ] || fail "the indexed hit returned '$(cat "$out")'"

  # Control: the same lookup without the index blocks on that FIFO, so the
  # construction above genuinely distinguishes an index hit from a scan.
  fm_backend_meta_index_clear
  ( window_to_task sess:w5:p5 "$state" > "$out" ) &
  BLOCKER_PID=$!
  wait_done "$BLOCKER_PID" 10 && fail "the unindexed control did not block on the FIFO meta"
  : > "$fifo" &
  wait_done "$BLOCKER_PID" 50 || fail "the unindexed control did not finish once the FIFO opened"
  BLOCKER_PID=
  wait 2>/dev/null || true
  pass "an indexed hit answers without reading any other meta"
}

# max_beat_gap <beacon> <seconds>: the longest interval, in seconds, between
# observed beacon mtime changes over <seconds> of polling.
max_beat_gap() {
  python3 - "$1" "$2" <<'PY'
import os, sys, time
path, span = sys.argv[1], float(sys.argv[2])
end = time.time() + span
last_m = os.stat(path).st_mtime
last_t = time.time()
gap = 0.0
while time.time() < end:
    time.sleep(0.05)
    try:
        m = os.stat(path).st_mtime
    except OSError:
        continue
    now = time.time()
    if m != last_m:
        gap = max(gap, now - last_t)
        last_m, last_t = m, now
gap = max(gap, time.time() - last_t)
print("%.2f" % gap)
PY
}

# run_slow_cycle <name> <beat-interval>: run a real watcher whose stale scan
# visits six windows, each capture taking one second, and print the longest
# beacon gap seen across ~14 seconds.
run_slow_cycle() {
  local name=$1 interval=$2 dir state fakebin i windows='' gap
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  mv "$fakebin/tmux" "$fakebin/tmux-base"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
here=$(cd "$(dirname "$0")" && pwd)
if [ "${1:-}" = capture-pane ]; then
  sleep 1
  # Fresh content every capture keeps each pane out of the stale path.
  printf 'working %s %s\n' "$$" "$(date +%s)"
  exit 0
fi
exec "$here/tmux-base" "$@"
SH
  chmod +x "$fakebin/tmux"
  for i in 1 2 3 4 5 6; do
    fm_write_meta "$state/slow$i.meta" "window=test:fm-slow$i" kind=ship harness=codex
    windows="$windows${windows:+$'\n'}fm-slow$i"
  done
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_TMUX_WINDOWS="$windows" FM_FAKE_CREW_STATE='state: working · source: pane · busy' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_WATCHER_BEAT_INTERVAL="$interval" \
    "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err" &
  WATCH_PID=$!
  i=0
  while [ ! -e "$state/.last-watcher-beat" ] && [ "$i" -lt 200 ]; do
    kill -0 "$WATCH_PID" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$state/.last-watcher-beat" ] \
    || fail "the $name watcher never beat: $(cat "$dir/watch.err" 2>/dev/null)"
  gap=$(max_beat_gap "$state/.last-watcher-beat" 14)
  kill -0 "$WATCH_PID" 2>/dev/null \
    || fail "the $name watcher exited mid-observation: $(cat "$dir/watch.out" "$dir/watch.err" 2>/dev/null)"
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=
  printf '%s\n' "$gap"
}

test_beacon_advances_inside_a_long_cycle() {
  local control fixed
  command -v python3 >/dev/null 2>&1 || { pass "skip: python3 not found"; return 0; }
  # Control: with the mid-cycle beat effectively off, the only beat is the cycle
  # top, so the gap spans the whole slow cycle (six one-second captures).
  control=$(run_slow_cycle beat-control 9999) || exit 1
  awk -v g="$control" 'BEGIN { exit !(g >= 5) }' \
    || fail "control cycle beat every ${control}s, so the fixture is not slow enough to prove anything"
  fixed=$(run_slow_cycle beat-midcycle 1) || exit 1
  awk -v g="$fixed" 'BEGIN { exit !(g <= 3.5) }' \
    || fail "the beacon went ${fixed}s without a beat inside a long cycle (control ${control}s)"
  pass "the beacon keeps advancing inside a long cycle (${fixed}s max gap vs ${control}s at the cycle top only)"
}

test_index_matches_scan
test_index_falls_back_when_home_changes
test_index_hit_reads_no_other_meta
test_beacon_advances_inside_a_long_cycle
