#!/usr/bin/env bash
# tests/fm-secondmate-liveness-scan.test.sh - registered-home watcher-beat
# scan owned by bin/fm-secondmate-liveness.sh, plus the heartbeat wake that
# surfaces a stale or dead verdict without recovering inside the watcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCAN="$ROOT/bin/fm-secondmate-liveness.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-liveness-scan)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
NOW=1000000000
GRACE=300

make_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_COMMAND:-claude}" ;;
    esac
    exit 0
    ;;
  list-windows)
    printf '%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-sm1}"
    exit 0
    ;;
  has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

new_primary() {
  local name=$1 home
  home="$TMP_ROOT/primaries/$name"
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_touch_epoch "$NOW" "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

new_sm_home() {
  local id=$1 home
  home="$TMP_ROOT/homes/$id"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  : > "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

local_record() {
  printf -- '- %s - domain summary (home: %s; scope: %s work; projects: alpha; added 2026-09-11)\n' \
    "$1" "$2" "$1"
}

write_meta() {
  local primary=$1 id=$2 window=$3 home=$4
  {
    printf 'window=%s\n' "$window"
    printf 'kind=secondmate\n'
    printf 'harness=claude\n'
    printf 'backend=tmux\n'
    printf 'home=%s\n' "$home"
  } > "$primary/state/$id.meta"
}

run_scan() {
  local primary=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$BASE_PATH" FM_HOME="$primary" FM_BACKEND=tmux \
    FM_GUARD_GRACE="$GRACE" FM_SECONDMATE_LIVENESS_NOW="$NOW" \
    FM_FAKE_TMUX_COMMAND="${FM_FAKE_TMUX_COMMAND:-claude}" \
    FM_FAKE_TMUX_WINDOW="${FM_FAKE_TMUX_WINDOW:-fm-sm1}" \
    "$SCAN" "$@"
}

test_stale_main_rearms_once() {
  local primary fakebin out arm_log slack_log
  primary=$(new_primary main-stale)
  fakebin=$(make_tmux "$TMP_ROOT/tmux-main-stale")
  arm_log="$TMP_ROOT/main-arm.log"
  slack_log="$TMP_ROOT/main-slack.log"
  fm_touch_epoch $((NOW - 900)) "$primary/state/.last-watcher-beat"
  cat > "$fakebin/fake-arm" <<SH
#!/usr/bin/env bash
printf 'home=%s args=%s\n' "\${FM_HOME:-}" "\$*" >> "$arm_log"
SH
  cat > "$fakebin/fake-slack" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$slack_log"
SH
  chmod +x "$fakebin/fake-arm" "$fakebin/fake-slack"

  out=$(FM_SECONDMATE_LIVENESS_ARM="$fakebin/fake-arm" \
    FM_SECONDMATE_LIVENESS_SLACK="$fakebin/fake-slack" \
    run_scan "$primary" "$fakebin" --recover)
  [ "$out" = "MAIN beat=900s grace=300s watcher=unhealthy verdict=stale" ] \
    || fail "a stale MAIN beat should be visible, got '$out'"
  [ "$(wc -l < "$arm_log" | tr -d '[:space:]')" = 1 ] \
    || fail "a stale MAIN beat should request exactly one re-arm: $(cat "$arm_log")"
  assert_contains "$(cat "$arm_log")" "home=$primary args=" \
    "MAIN recovery must arm without stopping a watcher it did not start"
  assert_contains "$(cat "$slack_log")" "message MAIN watcher beat stale; re-armed" \
    "MAIN recovery must post one Slack line"

  fm_touch_epoch "$NOW" "$primary/state/.last-watcher-beat"
  FM_SECONDMATE_LIVENESS_ARM="$fakebin/fake-arm" \
    FM_SECONDMATE_LIVENESS_SLACK="$fakebin/fake-slack" \
    run_scan "$primary" "$fakebin" --recover >/dev/null
  [ "$(wc -l < "$arm_log" | tr -d '[:space:]')" = 1 ] \
    || fail "a fresh beat must not request a duplicate MAIN re-arm"
  pass "stale MAIN re-arms once and a fresh beat stays untouched"
}

test_secondmate_heartbeat_recovers_stale_main() {
  local primary mate fakebin out arm_log slack_log
  primary=$(new_primary parent-stale)
  mate=$(new_sm_home sm1)
  fakebin=$(make_tmux "$TMP_ROOT/tmux-parent-stale")
  arm_log="$TMP_ROOT/parent-arm.log"
  slack_log="$TMP_ROOT/parent-slack.log"
  fm_touch_epoch $((NOW - 900)) "$primary/state/.last-watcher-beat"
  cat > "$mate/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$primary
EOF
  cat > "$fakebin/fake-arm" <<SH
#!/usr/bin/env bash
printf 'home=%s args=%s\n' "\${FM_HOME:-}" "\$*" >> "$arm_log"
SH
  cat > "$fakebin/fake-slack" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$slack_log"
SH
  chmod +x "$fakebin/fake-arm" "$fakebin/fake-slack"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$mate" FM_STATE_OVERRIDE="$mate/state" \
    FM_ROOT_OVERRIDE="$ROOT" FM_GUARD_GRACE="$GRACE" \
    FM_SECONDMATE_LIVENESS_NOW="$NOW" \
    FM_SECONDMATE_LIVENESS_ARM="$fakebin/fake-arm" \
    FM_SECONDMATE_LIVENESS_SLACK="$fakebin/fake-slack" \
    bash -c '. "$1"; secondmate_home_liveness_tick' _ "$WATCH")
  assert_contains "$out" "check: secondmate-liveness: MAIN beat=900s" \
    "a secondmate heartbeat must surface MAIN's stale beat"
  [ "$(wc -l < "$arm_log" | tr -d '[:space:]')" = 1 ] \
    || fail "a secondmate heartbeat should request exactly one MAIN re-arm: $(cat "$arm_log")"
  assert_contains "$(cat "$arm_log")" "home=$primary args=" \
    "a secondmate heartbeat must arm the parent without stopping its watcher"
  assert_contains "$(cat "$slack_log")" "message MAIN watcher beat stale; re-armed" \
    "a secondmate heartbeat must post the MAIN recovery line"
  pass "secondmate heartbeat recovers a stale local MAIN watcher"
}

test_fresh_beat_is_ok() {
  local primary home fakebin out
  primary=$(new_primary fresh-ok)
  home=$(new_sm_home sm1)
  local_record sm1 "$home" > "$primary/data/secondmates.md"
  write_meta "$primary" sm1 firstmate:fm-sm1 "$home"
  fm_touch_epoch "$NOW" "$home/state/.last-watcher-beat"
  fakebin=$(make_tmux "$TMP_ROOT/tmux-fresh")

  out=$(run_scan "$primary" "$fakebin")
  [ "$out" = "sm1 beat=0s grace=300s agent=live verdict=ok" ] \
    || fail "fresh live home should print ok, got '$out'"
  pass "fresh beat + live agent prints the ok line"
}

test_stale_beat_with_live_agent_is_stale() {
  local primary home fakebin out
  primary=$(new_primary stale-live)
  home=$(new_sm_home sm1)
  local_record sm1 "$home" > "$primary/data/secondmates.md"
  write_meta "$primary" sm1 firstmate:fm-sm1 "$home"
  fm_touch_epoch $((NOW - 900)) "$home/state/.last-watcher-beat"
  fakebin=$(make_tmux "$TMP_ROOT/tmux-stale")

  out=$(run_scan "$primary" "$fakebin")
  [ "$out" = "sm1 beat=900s grace=300s agent=live verdict=stale" ] \
    || fail "stale live home should print stale, got '$out'"
  pass "stale beat + live agent prints the stale line"
}

test_no_agent_is_dead() {
  local primary home fakebin out
  primary=$(new_primary no-agent)
  home=$(new_sm_home sm1)
  local_record sm1 "$home" > "$primary/data/secondmates.md"
  fm_touch_epoch "$NOW" "$home/state/.last-watcher-beat"
  fakebin=$(make_tmux "$TMP_ROOT/tmux-dead")

  out=$(run_scan "$primary" "$fakebin")
  [ "$out" = "sm1 beat=0s grace=300s agent=dead verdict=dead" ] \
    || fail "missing recorded agent should print dead, got '$out'"
  pass "no recorded agent prints the dead line"
}

test_recover_on_ok_changes_nothing() {
  local primary home fakebin out arm_log restart_log slack_log status
  primary=$(new_primary recover-ok)
  home=$(new_sm_home sm1)
  local_record sm1 "$home" > "$primary/data/secondmates.md"
  write_meta "$primary" sm1 firstmate:fm-sm1 "$home"
  fm_touch_epoch "$NOW" "$home/state/.last-watcher-beat"
  fakebin=$(make_tmux "$TMP_ROOT/tmux-recover-ok")
  arm_log="$TMP_ROOT/arm-ok.log"
  restart_log="$TMP_ROOT/restart-ok.log"
  slack_log="$TMP_ROOT/slack-ok.log"
  cat > "$fakebin/fake-arm" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$arm_log"
exit 0
SH
  cat > "$fakebin/fake-restart" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$restart_log"
exit 0
SH
  cat > "$fakebin/fake-slack" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$slack_log"
exit 0
SH
  chmod +x "$fakebin/fake-arm" "$fakebin/fake-restart" "$fakebin/fake-slack"
  : > "$primary/state/sm1.status"

  out=$(FM_SECONDMATE_LIVENESS_ARM="$fakebin/fake-arm" \
    FM_SECONDMATE_LIVENESS_RESTART="$fakebin/fake-restart" \
    FM_SECONDMATE_LIVENESS_SLACK="$fakebin/fake-slack" \
    run_scan "$primary" "$fakebin" --recover)
  [ "$out" = "sm1 beat=0s grace=300s agent=live verdict=ok" ] \
    || fail "ok --recover should still print the ok line, got '$out'"
  [ ! -s "$arm_log" ] || fail "ok --recover must not invoke the arm wrapper: $(cat "$arm_log")"
  [ ! -s "$restart_log" ] || fail "ok --recover must not invoke restart: $(cat "$restart_log")"
  [ ! -s "$slack_log" ] || fail "ok --recover must not post slack: $(cat "$slack_log")"
  status=$(cat "$primary/state/sm1.status")
  [ -z "$status" ] || fail "ok --recover must not append a status line, got '$status'"
  pass "--recover without stale/dead changes nothing"
}

test_recover_stale_invokes_arm() {
  local primary home fakebin out
  primary=$(new_primary recover-stale)
  home=$(new_sm_home sm1)
  local_record sm1 "$home" > "$primary/data/secondmates.md"
  write_meta "$primary" sm1 firstmate:fm-sm1 "$home"
  fm_touch_epoch $((NOW - 900)) "$home/state/.last-watcher-beat"
  fakebin=$(make_tmux "$TMP_ROOT/tmux-recover-stale")
  cat > "$fakebin/fake-arm" <<SH
#!/usr/bin/env bash
printf 'home=%s args=%s\n' "\${FM_HOME:-}" "\$*" >> "$TMP_ROOT/arm-stale.log"
exit 0
SH
  cat > "$fakebin/fake-restart" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/restart-stale.log"
exit 0
SH
  cat > "$fakebin/fake-slack" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/slack-stale.log"
exit 0
SH
  chmod +x "$fakebin/fake-arm" "$fakebin/fake-restart" "$fakebin/fake-slack"

  out=$(FM_SECONDMATE_LIVENESS_ARM="$fakebin/fake-arm" \
    FM_SECONDMATE_LIVENESS_RESTART="$fakebin/fake-restart" \
    FM_SECONDMATE_LIVENESS_SLACK="$fakebin/fake-slack" \
    run_scan "$primary" "$fakebin" --recover)
  [ "$out" = "sm1 beat=900s grace=300s agent=live verdict=stale" ] \
    || fail "stale --recover should still print the stale line, got '$out'"
  assert_contains "$(cat "$TMP_ROOT/arm-stale.log")" "home=$home args=--restart" \
    "stale --recover must run that home's arm wrapper with --restart"
  [ ! -e "$TMP_ROOT/restart-stale.log" ] || [ ! -s "$TMP_ROOT/restart-stale.log" ] \
    || fail "stale live --recover must not restart the agent"
  assert_contains "$(cat "$primary/state/sm1.status")" \
    "working: recovered sm1 watcher (stale beat; re-armed)" \
    "stale --recover must append one status line"
  assert_contains "$(cat "$TMP_ROOT/slack-stale.log")" \
    "message home sm1: watcher beat stale; re-armed" \
    "stale --recover must post one Slack line"
  pass "--recover on stale re-arms, statuses, and slacks"
}

test_missing_beat_refuses() {
  local primary home fakebin err rc
  primary=$(new_primary missing-beat)
  home=$(new_sm_home sm1)
  rm -f "$home/state/.last-watcher-beat"
  local_record sm1 "$home" > "$primary/data/secondmates.md"
  write_meta "$primary" sm1 firstmate:fm-sm1 "$home"
  fakebin=$(make_tmux "$TMP_ROOT/tmux-missing-beat")

  rc=0
  err=$(run_scan "$primary" "$fakebin" 2>&1 >/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "missing beat must refuse with a non-zero exit"
  assert_contains "$err" "cannot classify" "missing beat must say why it refused"
  pass "missing watcher beat refuses loudly"
}

test_heartbeat_wakes_only_on_stale_or_dead() {
  local primary home fakebin out pid i
  primary=$(new_primary watch-dead)
  home=$(new_sm_home sm1)
  local_record sm1 "$home" > "$primary/data/secondmates.md"
  fm_touch_epoch "$NOW" "$home/state/.last-watcher-beat"
  fakebin=$(make_tmux "$TMP_ROOT/tmux-watch")
  mkdir -p "$primary/bin"
  out="$TMP_ROOT/watch.out"

  PATH="$fakebin:$BASE_PATH" FM_HOME="$primary" FM_STATE_OVERRIDE="$primary/state" \
    FM_BACKEND=tmux FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 FM_GUARD_GRACE="$GRACE" \
    FM_SECONDMATE_LIVENESS_NOW="$NOW" \
    "$WATCH" > "$out" 2>"$TMP_ROOT/watch.err" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "watcher did not wake on a dead registered home: out=$(cat "$out") err=$(cat "$TMP_ROOT/watch.err")"
  fi
  wait "$pid" 2>/dev/null || true
  assert_contains "$(cat "$out")" "check: secondmate-liveness:" \
    "heartbeat scan must emit a wake naming the liveness check"
  assert_contains "$(cat "$out")" "verdict=dead" \
    "the wake must carry the dead verdict line"
  pass "heartbeat scan wakes on dead, without recovering inside the watcher"
}

test_stale_main_rearms_once
test_secondmate_heartbeat_recovers_stale_main
test_fresh_beat_is_ok
test_stale_beat_with_live_agent_is_stale
test_no_agent_is_dead
test_recover_on_ok_changes_nothing
test_recover_stale_invokes_arm
test_missing_beat_refuses
test_heartbeat_wakes_only_on_stale_or_dead

echo "# all fm-secondmate-liveness-scan tests passed"
