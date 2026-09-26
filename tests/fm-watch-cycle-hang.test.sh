#!/usr/bin/env bash
# A watcher stuck in one backend call must still age past the stale-beacon guard.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-cycle-hang)
WATCH="$ROOT/bin/fm-watch.sh"
dir=$(make_case watcher-cycle-hang)
state="$dir/state"
fakebin="$dir/fakebin"
out="$dir/watch.out"
marker="$dir/captures"
capture="$dir/pane.txt"
release="$dir/release-capture"
pid=

cleanup_hung_watcher() {
  : > "$release"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}
trap cleanup_hung_watcher EXIT

: > "$marker"
printf 'fixture pane\n' > "$capture"
printf 'window=fixture:fm-hung\nkind=ship\n' > "$state/hung.meta"
PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
  FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CAPTURE_BLOCK_FILE="$release" \
  FM_FAKE_TMUX_CAPTURE_MARKER="$marker" FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
pid=$!
i=0
while [ ! -s "$marker" ] && [ "$i" -lt 100 ]; do
  kill -0 "$pid" 2>/dev/null || fail "watcher exited before the blocking capture"
  sleep 0.05
  i=$((i + 1))
done
[ -s "$marker" ] || fail "watcher did not enter the blocking backend capture"
sleep 2.2
guard=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=2 \
  FM_SUPERVISION_MODEL=persistent "$ROOT/bin/fm-guard.sh" 2>&1)
assert_contains "$guard" 'WATCHER DOWN - SUPERVISION IS OFF' \
  "a blocked backend call must still age out as a stale watcher"
pass "a hung watcher remains detectable without progress beats"
