#!/usr/bin/env bash
# tests/fm-watch-session.test.sh - home-scoped durable active watcher runner.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH_SESSION="$ROOT/bin/fm-watch-session.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-session-tests)
PRIMARY_ROOT="$TMP_ROOT/primary-root"
mkdir -p "$PRIMARY_ROOT"
git -C "$PRIMARY_ROOT" init -q
printf '# agents\n' > "$PRIMARY_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$PRIMARY_ROOT/bin"
git -C "$PRIMARY_ROOT" add AGENTS.md bin
git -C "$PRIMARY_ROOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
FM_ROOT_OVERRIDE="$PRIMARY_ROOT"
export FM_ROOT_OVERRIDE
CODEX_THREAD_ID=watch-session-tests
export CODEX_THREAD_ID
cd "$PRIMARY_ROOT" || exit 1

prepare_watch_home() {
  local home=$1 token
  mkdir -p "$home/state" "$home/data" "$home/config"
  token="watch-$(basename "$home")"
  printf 'root=%s\ntoken=%s\n' "$FM_ROOT_OVERRIDE" "$token" > "$home/state/.primary-attestation"
  chmod 600 "$home/state/.primary-attestation"
  printf '%s|codex:%s|fallback\n' "$$" "$CODEX_THREAD_ID" > "$home/state/.lock"
}

watch_attestation_token() {
  awk -F= '$1 == "token" {print substr($0, index($0, "=") + 1); exit}' \
    "$1/state/.primary-attestation"
}

install_fake_tmux() {
  local dir=$1 fakebin log root
  fakebin=$(fm_fakebin "$dir")
  log="$dir/tmux.log"
  root="$dir/tmux-state"
  mkdir -p "$root"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TMUX_LOG:?}
root=${FM_FAKE_TMUX_ROOT:?}
cmd=${1:-}
shift || true
printf '%s\n' "tmux $cmd $*" >> "$log"
case "$cmd" in
  has-session)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; *) shift ;; esac
    done
    target=${target%%:*}
    [ -n "$target" ] && [ -d "$root/$target" ]
    ;;
  new-session)
    session= window= command=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d) shift ;;
        -s) session=$2; shift 2 ;;
        -n) window=$2; shift 2 ;;
        *) command=$1; shift ;;
      esac
    done
    mkdir -p "$root/$session"
    printf '%s\n' "$command" > "$root/$session/$window"
    ;;
  new-window)
    target= window= command=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d) shift ;;
        -t) target=$2; shift 2 ;;
        -n) window=$2; shift 2 ;;
        *) command=$1; shift ;;
      esac
    done
    session=${target%%:*}
    mkdir -p "$root/$session"
    printf '%s\n' "$command" > "$root/$session/$window"
    ;;
  list-windows)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; -F) shift 2 ;; *) shift ;; esac
    done
    session=${target%%:*}
    [ -d "$root/$session" ] || exit 1
    for f in "$root/$session"/*; do
      [ -f "$f" ] || continue
      basename "$f"
    done | sort
    ;;
  kill-window)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; *) shift ;; esac
    done
    session=${target%%:*}
    window=${target#*:}
    rm -f "$root/$session/$window"
    ;;
  *)
    echo "unsupported fake tmux command: $cmd" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_watch_session_bootstraps_missing_attestation() {
  local dir fakebin attestation
  dir=$(make_case session-primary-attestation-bootstrap)
  fakebin=$(install_fake_tmux "$dir")
  prepare_watch_home "$dir/home"
  attestation="$dir/home/state/.primary-attestation"
  rm -rf "$dir/home/state"
  mkdir -p "$dir/home/state"
  printf '%s|codex:%s|fallback\n' "$$" "$CODEX_THREAD_ID" > "$dir/home/state/.lock"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" "$WATCH_SESSION" start >/dev/null \
    || fail "watch-session did not bootstrap a missing primary attestation"
  [ -f "$attestation" ] || fail "watch-session did not create the primary attestation"
  grep -F "root=$FM_ROOT_OVERRIDE" "$attestation" >/dev/null \
    || fail "watch-session wrote an attestation for the wrong primary root"
  pass "watch-session bootstraps a missing primary attestation before its guard"
}

test_watch_session_does_not_replay_attestation_without_trusted_entry() {
  local dir fakebin out status
  dir=$(make_case session-primary-attestation-replay)
  fakebin=$(install_fake_tmux "$dir")
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$fakebin/ps"
  chmod +x "$fakebin/ps"
  prepare_watch_home "$dir/home"
  status=0
  out=$(env -u CODEX_THREAD_ID -u FM_PRIMARY_ATTESTATION \
    -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
    PATH="$fakebin:$PATH" FM_HOME="$dir/home" \
    "$WATCH_SESSION" --status 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "watch-session accepted a persisted attestation without trusted entry proof"
  assert_contains "$out" "primary harness or session-lock ownership is unproven" \
    "watch-session replay refusal did not explain the missing trusted entry proof"
  assert_not_contains "$out" "watch-session: stopped" \
    "watch-session replay refusal reached the runner status path"
  pass "watch-session does not replay a persisted attestation without trusted entry proof"
}

test_watch_session_start_status_stop_are_home_scoped() {
  local dir fakebin state_a state_b out_a out_b status_a status_b after_stop log live identity start
  dir=$(make_case session-home-scope)
  fakebin=$(install_fake_tmux "$dir")
  prepare_watch_home "$dir/home-a"
  prepare_watch_home "$dir/home-b"
  log="$dir/tmux.log"
  state_a="$dir/home-a/state"
  state_b="$dir/home-b/state"
  mkdir -p "$state_a" "$state_b"
  out_a="$dir/a.out"
  out_b="$dir/b.out"
  status_a="$dir/a.status"
  status_b="$dir/b.status"
  after_stop="$dir/after-stop.status"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-a" "$WATCH_SESSION" start > "$out_a" \
    || fail "watch-session did not start home A: $(cat "$out_a" 2>/dev/null || true)"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-b" "$WATCH_SESSION" start > "$out_b" \
    || fail "watch-session did not start home B: $(cat "$out_b" 2>/dev/null || true)"

  grep -F 'watch-session: started target=' "$out_a" >/dev/null || fail "home A start did not report started"
  grep -F 'watch-session: started target=' "$out_b" >/dev/null || fail "home B start did not report started"
  [ "$(find "$dir/tmux-state/firstmate-watch" -type f | wc -l | tr -d '[:space:]')" = 2 ] \
    || fail "expected separate tmux windows for two FM_HOME values"

  sleep 300 &
  live=$!
  identity=$(FM_HOME="$dir/home-a" FM_STATE_OVERRIDE="$state_a" \
    FM_PRIMARY_ATTESTATION="$(watch_attestation_token "$dir/home-a")" \
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$live") \
    || fail "could not identify the home A watcher"
  start=$(FM_HOME="$dir/home-a" FM_STATE_OVERRIDE="$state_a" \
    FM_PRIMARY_ATTESTATION="$(watch_attestation_token "$dir/home-a")" \
    bash -c '. "$1"; fm_pid_start "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$live") \
    || fail "could not pin the home A watcher start"
  mkdir "$state_a/.watch.lock"
  printf '%s\n' "$live" > "$state_a/.watch.lock/pid"
  printf '%s\n' "$start" > "$state_a/.watch.lock/pid-start"
  printf '%s\n' "$identity" > "$state_a/.watch.lock/pid-identity"
  printf '%s\n' "$dir/home-a" > "$state_a/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state_a/.watch.lock/watcher-path"
  touch "$state_a/.last-watcher-beat"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-a" "$WATCH_SESSION" --status > "$status_a" \
    || fail "watch-session status failed for home A"
  grep -F 'watch-session: running target=' "$status_a" >/dev/null || fail "home A status did not report running"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-a" "$WATCH_SESSION" stop >/dev/null \
    || fail "watch-session stop failed for home A"
  ! is_live_non_zombie "$live" || fail "watch-session stop left the detached home A watcher alive"
  wait "$live" 2>/dev/null || true
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-a" "$WATCH_SESSION" --status > "$after_stop" \
    && fail "home A status succeeded after stop"
  grep -F 'watch-session: stopped' "$after_stop" >/dev/null || fail "home A status after stop did not report stopped"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" FM_HOME="$dir/home-b" "$WATCH_SESSION" --status > "$status_b" \
    || fail "stopping home A stopped home B too"
  grep -F 'watch-session: running target=' "$status_b" >/dev/null || fail "home B did not remain running"
  ! grep -F 'pkill -f' "$WATCH_SESSION" >/dev/null || fail "watch-session contains broad pkill -f"
  pass "watch-session start/status/stop are scoped to one FM_HOME and never use broad pkill"
}

test_watch_session_stop_waits_for_starting_watcher() {
  local dir fakebin state live identity start racer
  dir=$(make_case session-stop-start-race)
  fakebin=$(install_fake_tmux "$dir")
  prepare_watch_home "$dir/home"
  state="$dir/home/state"
  mkdir -p "$state"

  sleep 300 &
  live=$!
  identity=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_PRIMARY_ATTESTATION="$(watch_attestation_token "$dir/home")" \
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$live") \
    || fail "could not identify the starting home watcher"
  start=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_PRIMARY_ATTESTATION="$(watch_attestation_token "$dir/home")" \
    bash -c '. "$1"; fm_pid_start "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$live") \
    || fail "could not pin the starting home watcher"
  (
    sleep 0.2
    mkdir "$state/.watch.lock"
    printf '%s\n' "$live" > "$state/.watch.lock/pid"
    printf '%s\n' "$start" > "$state/.watch.lock/pid-start"
    printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
    printf '%s\n' "$dir/home" > "$state/.watch.lock/fm-home"
    printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"
  ) &
  racer=$!

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" FM_WATCH_SESSION_STOP_POLLS=30 "$WATCH_SESSION" stop >/dev/null \
    || fail "watch-session stop failed during watcher startup"
  wait "$racer" 2>/dev/null || true
  ! is_live_non_zombie "$live" || fail "watch-session stop returned before killing a delayed watcher lock"
  wait "$live" 2>/dev/null || true
  pass "watch-session stop waits through delayed watcher lock startup"
}

test_watch_session_stop_fails_for_unpinned_legacy_watcher() {
  local dir fakebin state live identity out status
  dir=$(make_case session-stop-legacy-no-start)
  fakebin=$(install_fake_tmux "$dir")
  prepare_watch_home "$dir/home"
  state="$dir/home/state"
  mkdir -p "$state"
  out="$dir/stop.out"

  sleep 300 &
  live=$!
  identity=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_PRIMARY_ATTESTATION="$(watch_attestation_token "$dir/home")" \
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$live") \
    || fail "could not identify the legacy watcher"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$dir/home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"

  status=0
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_WATCH_SESSION_STOP_POLLS=3 "$WATCH_SESSION" stop > "$out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "watch-session stop claimed success for an unpinned legacy watcher"
  grep -F 'watcher identity is not safely pinned' "$out" >/dev/null \
    || fail "watch-session stop did not explain the unpinned legacy watcher: $(cat "$out")"
  is_live_non_zombie "$live" || fail "watch-session stop killed an unpinned legacy watcher"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch-session stop fails closed for an unpinned legacy watcher"
}

test_watch_session_status_reports_runner_not_inner_arm_health() {
  local dir fakebin state out status arm_out
  dir=$(make_case session-status-runner-contract)
  fakebin=$(install_fake_tmux "$dir")
  prepare_watch_home "$dir/home"
  state="$dir/home/state"
  mkdir -p "$state"
  out="$dir/start.out"
  status="$dir/status.out"
  arm_out="$state/.watch-session/arm.out"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" "$WATCH_SESSION" start > "$out" \
    || fail "watch-session did not start for runner-status contract"
  mkdir -p "$(dirname "$arm_out")"
  printf '%s\n' 'watcher: FAILED - no live watcher with a fresh beacon' > "$arm_out"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" "$WATCH_SESSION" --status > "$status" \
    || fail "watch-session status should report live runner even when last arm output failed"
  grep -F 'watch-session: running target=' "$status" >/dev/null \
    || fail "watch-session status did not report runner window as running"
  ! grep -F 'FAILED' "$status" >/dev/null \
    || fail "watch-session status should not report inner arm health"
  pass "watch-session status reports runner-window liveness, not inner arm health"
}

test_watch_session_refuses_grok_primary_without_override() {
  local dir fakebin out status
  dir=$(make_case grok-primary-refusal)
  fakebin=$(install_fake_tmux "$dir")
  prepare_watch_home "$dir/home"
  out="$dir/start.out"

  status=0
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" GROK_AGENT=1 "$WATCH_SESSION" start >"$out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "Grok primary watch-session start was not refused"
  grep -F 'refusing Grok primary' "$out" >/dev/null \
    || fail "Grok refusal did not explain the native background owner: $(cat "$out")"
  [ ! -e "$dir/tmux-state/firstmate-watch" ] \
    || fail "Grok refusal created a tmux fallback before failing"
  pass "watch-session refuses to steal the Grok primary follower slot"
}

test_watch_session_refuses_grok_restart_without_stopping_fallback() {
  local dir fakebin state out status after_status log
  dir=$(make_case grok-primary-restart-refusal)
  fakebin=$(install_fake_tmux "$dir")
  prepare_watch_home "$dir/home"
  state="$dir/home/state"
  out="$dir/restart.out"
  after_status="$dir/status.out"
  log="$dir/tmux.log"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" GROK_AGENT=1 FM_ALLOW_WATCH_SESSION_WITH_GROK=1 "$WATCH_SESSION" start >/dev/null \
    || fail "could not establish the fallback runner before Grok restart refusal"

  status=0
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" GROK_AGENT=1 "$WATCH_SESSION" restart >"$out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "Grok primary watch-session restart was not refused"
  grep -F 'refusing Grok primary' "$out" >/dev/null \
    || fail "Grok restart refusal did not explain the native background owner: $(cat "$out")"
  [ -e "$dir/tmux-state/firstmate-watch" ] \
    || fail "Grok restart refusal removed the existing fallback session"
  [ ! -e "$state/.watch-session/stop" ] \
    || fail "Grok restart refusal touched the fallback stop marker"
  ! grep -F 'tmux kill-window' "$log" >/dev/null \
    || fail "Grok restart refusal stopped the fallback before refusing"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" "$WATCH_SESSION" --status >"$after_status" \
    || fail "fallback status failed after Grok restart refusal"
  grep -F 'watch-session: running target=' "$after_status" >/dev/null \
    || fail "existing fallback was not intact after Grok restart refusal"
  pass "watch-session restart refuses Grok overlap before stopping the fallback"
}

test_watch_session_grok_emergency_override_allows_fallback() {
  local dir fakebin out
  dir=$(make_case grok-primary-override)
  fakebin=$(install_fake_tmux "$dir")
  prepare_watch_home "$dir/home"
  out="$dir/start.out"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_ROOT="$dir/tmux-state" \
    FM_HOME="$dir/home" GROK_AGENT=1 FM_ALLOW_WATCH_SESSION_WITH_GROK=1 "$WATCH_SESSION" start >"$out" \
    || fail "explicit Grok watch-session emergency override did not allow fallback: $(cat "$out")"
  grep -F 'watch-session: started target=' "$out" >/dev/null \
    || fail "Grok emergency override did not start the fallback runner"
  pass "watch-session emergency override remains available for Grok fallback"
}

test_watch_session_bootstraps_missing_attestation
test_watch_session_does_not_replay_attestation_without_trusted_entry
test_watch_session_start_status_stop_are_home_scoped
test_watch_session_stop_waits_for_starting_watcher
test_watch_session_stop_fails_for_unpinned_legacy_watcher
test_watch_session_status_reports_runner_not_inner_arm_health
test_watch_session_refuses_grok_primary_without_override
test_watch_session_refuses_grok_restart_without_stopping_fallback
test_watch_session_grok_emergency_override_allows_fallback
