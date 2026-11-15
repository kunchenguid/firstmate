#!/usr/bin/env bash
set -u
. tests/wake-helpers.sh
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-dbg)
dir=$(make_case startup-teardown)
state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 bash -x "$WATCH" > "$out" 2>&1 &
pid=$!
end=$((SECONDS + 20)); stopped=0
while [ "$SECONDS" -lt "$end" ] && is_live_non_zombie "$pid"; do
  [ -e "$state/.watch.lock/watcher-path" ] && kill -STOP "$pid" 2>/dev/null && { stopped=1; break; }
done
mv "$state" "$dir/retired-state"; mkdir -p "$state"; kill -CONT "$pid"
wait_for_exit "$pid" 100; echo rc=$?
sed -n 1236,1256p "$out"; grep -n "fm_test_track_watcher_state()" -A25 tests/wake-helpers.sh tests/*.sh | head -40
