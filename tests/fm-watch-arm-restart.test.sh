#!/usr/bin/env bash
# Inject a generation change through the real arm command, without touching a
# live fleet. Two real processes stand in for successive lock owners.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-arm-restart)
owned_pids=()
cleanup_restart_fixture() {
  local pid
  for pid in "${owned_pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
    wait_for_exit "$pid" 30 >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup_restart_fixture EXIT

test_restart_preserves_successor() {
  local phase=$1 dir state home fakebin old peer old_owner peer_owner pid owner identity arm i
  dir=$(make_case "restart-$phase")
  state="$dir/state" home="$dir/home" fakebin="$dir/fakebin"
  old_owner="$state/.watch.lock.owner.old"
  peer_owner="$state/.watch.lock.owner.peer"
  mkdir -p "$home/data" "$old_owner" "$peer_owner"
  sleep 300 & old=$!
  sleep 299 & peer=$!
  owned_pids+=("$old" "$peer")
  for owner in "$old_owner" "$peer_owner"; do
    pid=$old
    [ "$owner" != "$peer_owner" ] || pid=$peer
    identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid")
    if [ "$phase" = stale-clear ] && [ "$pid" = "$old" ]; then identity=stale-identity; fi
    printf '%s\n' "$pid" > "$owner/pid"
    printf '%s\n' "$home" > "$owner/fm-home"
    printf '%s\n' "$WATCH" > "$owner/watcher-path"
    printf '%s\n' "$identity" > "$owner/pid-identity"
  done
  ln -s "$old_owner" "$state/.watch.lock"
  touch "$state/.last-watcher-beat"

  # Read the old value, then publish the complete successor. The first case
  # flips after the PID read; the second after the final identity read, before
  # stale cleanup can commit. No implementation function is copied or mocked.
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
"$REAL_CAT" "$@" || exit $?
trigger=false
if [ "$FLIP_PHASE" = pid-read ]; then
  case "${1:-}" in "$FLIP_STATE/.watch.lock/pid"|"$FLIP_OLD/pid") trigger=true ;; esac
elif [ "${1:-}" = "$FLIP_OLD/pid-identity" ]; then
  if ! mkdir "$FLIP_STATE/.identity-read" 2>/dev/null; then trigger=true; fi
fi
if "$trigger" && mkdir "$FLIP_STATE/.flipped" 2>/dev/null; then
  rm "$FLIP_STATE/.watch.lock"
  ln -s "$FLIP_PEER" "$FLIP_STATE/.watch.lock"
fi
SH
  chmod +x "$fakebin/cat"
  REAL_CAT=$(command -v cat) FLIP_PHASE="$phase" FLIP_STATE="$state" \
    FLIP_OLD="$old_owner" FLIP_PEER="$peer_owner" PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_ARM_CONFIRM_TIMEOUT=3 \
    FM_ARM_ATTACH_POLL=0.1 FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH_ARM" --restart > "$dir/arm.out" 2>&1 &
  arm=$!
  owned_pids+=("$arm")
  for ((i=0; i<100; i++)); do
    grep -q "^watcher: attached pid=$peer " "$dir/arm.out" && break
    is_live_non_zombie "$arm" || break
    sleep 0.05
  done
  [ -d "$state/.flipped" ] || fail "$phase: generation-change fixture did not run"
  is_live_non_zombie "$peer" || fail "$phase: restart signaled the successor"
  [ "$(readlink "$state/.watch.lock" 2>/dev/null || true)" = "$peer_owner" ] \
    || fail "$phase: restart removed the live successor's lock"
  grep -q "^watcher: attached pid=$peer " "$dir/arm.out" \
    || fail "$phase: restart did not attach to the successor: $(cat "$dir/arm.out")"
  [ ! -e "$state/.watcher-down" ] || fail "$phase: successor caused false recovery"
  kill -TERM "$arm" "$old" "$peer" 2>/dev/null || true
  wait_for_exit "$arm" 30 >/dev/null 2>&1 || true
  wait "$old" "$peer" 2>/dev/null || true
  owned_pids=()
  pass "watch-arm restart: preserves successor across $phase generation change"
}

test_restart_preserves_successor pid-read
test_restart_preserves_successor stale-clear
