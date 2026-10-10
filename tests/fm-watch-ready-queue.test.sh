#!/usr/bin/env bash
# Exercise heartbeat delivery through the watcher and the real backlog consumer.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-ready-queue)

test_ready_queue_addressing() {
  local form=$1 dir result rc
  dir=$(make_case "addressing-$form")
  mkdir -p "$dir/data" "$dir/home/.tasks-axi"
  printf 'backend = "beads"\n' > "$dir/.tasks.toml"
  printf 'backend = "markdown"\n' > "$dir/home/.tasks-axi/config.toml"
  cat > "$dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "$1" = ready ] || exit 2
[ "$PWD" = "$FM_TEST_BACKLOG_ROOT" ] || exit 2
[ -z "${TASKS_AXI_FILE:-}" ] || exit 2
printf '%s\n' "$PWD" >> "$FM_TEST_READY_LOG"
case "$FM_TEST_READY_RESULT" in
  ready) printf 'count: 1\n' ;;
  empty) printf 'count: 0\n' ;;
  failed) exit 2 ;;
esac
SH
  chmod +x "$dir/fakebin/tasks-axi"
  for result in ready empty failed; do
    : > "$dir/ready.log"
    (
      cd "$dir" || exit 2
      local addressing_home="$dir"
      export FM_TEST_BACKLOG_ROOT="$dir" FM_TEST_READY_LOG="$dir/ready.log"
      export FM_TEST_READY_RESULT="$result"
      unset TASKS_AXI_BACKEND FM_DATA_OVERRIDE
      case "$form" in
        absolute) export FM_DATA_OVERRIDE="$dir/data" ;;
        relative) export FM_DATA_OVERRIDE=data ;;
        trailing-slash) export FM_DATA_OVERRIDE="$dir/data/" ;;
        relative-home) addressing_home=. ;;
        trailing-slash-home) addressing_home="$dir/" ;;
      esac
      # shellcheck source=bin/fm-ready-queue-lib.sh
      . "$ROOT/bin/fm-ready-queue-lib.sh"
      FM_HOME="$addressing_home" HOME="$dir/home" PATH="$dir/fakebin:$PATH" \
        fm_ready_queue_needs_review
    )
    rc=$?
    if [ "$result" = empty ]; then
      [ "$rc" = 1 ] || fail "$form empty queue required review"
    else
      [ "$rc" = 0 ] || fail "$form $result queue was silently suppressed"
    fi
    [ "$(cat "$dir/ready.log")" = "$dir" ] || fail "$form did not query the selected backlog root"
  done
  pass "$form backlog addressing preserves ready, empty, and unavailable verdicts"
}

test_ready_heartbeat() {
  local mode=${1:-ready} dir pid out
  dir=$(make_case "$mode-heartbeat")
  mkdir -p "$dir/data" "$dir/config"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add cap-ready 'beyond current spend cap' >/dev/null \
    || fail 'could not queue candidate with stale spending title'
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add dependency 'landed dependency' >/dev/null \
    || fail 'could not create dependency'
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" block cap-ready --by dependency >/dev/null \
    || fail 'could not record dependency'
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" 'done' dependency --pr https://github.com/example/fixture/pull/1 >/dev/null \
    || fail 'could not record landed dependency'
  if [ "$mode" = unreadable ]; then
    printf '#!/usr/bin/env bash\nprintf "readiness unavailable\\n" >&2\nexit 2\n' > "$dir/fakebin/tasks-axi"
    chmod +x "$dir/fakebin/tasks-axi"
  fi
  # No away record, live worker, or new status event: the queue itself must
  # cause a fleet review after a restriction expires.
  out="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_POLL=0.2 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail 'ready queue heartbeat was absorbed without a supervision turn'
  [ "$(cat "$out")" = heartbeat ] || fail 'ready queue did not produce heartbeat wake'
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2>/dev/null \
    || fail 'could not drain queued heartbeat'
  assert_contains "$(cat "$dir/drain.out")" "$(printf '\theartbeat\t')" 'heartbeat was not durably delivered'
  pass "$mode queue reaches supervision despite stale title and silent status logs"
}

test_not_ready_heartbeat() {
  local mode=$1 dir pid out i rc
  dir=$(make_case "$mode-heartbeat")
  mkdir -p "$dir/data" "$dir/config"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  if [ "$mode" = held ]; then
    FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add held 'waiting for captain' >/dev/null \
      || fail 'could not add held task'
    FM_HOME="$dir" "$ROOT/bin/fm-captain-hold.sh" hold held --reason 'explicit captain hold' >/dev/null \
      || fail 'could not hold task'
  fi
  out="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_POLL=0.2 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  for ((i=0; i<60; i++)); do
    [ "$(cat "$dir/state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] && break
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait_for_exit "$pid" 60
  rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 143 ] || fail 'quiet watcher did not stop'
  [ "$(cat "$dir/state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] \
    || fail "$mode queue was not reviewed"
  [ ! -s "$out" ] && [ ! -s "$dir/state/.wake-queue" ] \
    || fail "$mode queue produced an unnecessary heartbeat wake"
  pass "$mode queue remains quiet without dispatchable work"
}

test_emitted_stop_revalidation_contract() {
  local prompt
  # This is the final generated agent interface, not implementation source;
  # it verifies delivery of the rule, not the model's interpretation of it.
  prompt=$("$ROOT/bin/fm-branch-prompt.sh") || fail 'could not generate supervision prompt'
  assert_contains "$prompt" "Before treating any finish or fleet check as handled, verify every candidate's recorded stop against current dependencies, holds, away posture, spend cap, and worker capacity" 'emitted prompt omitted current-stop verification'
  assert_contains "$prompt" 'a stale title or earlier restriction never establishes a current stop, and a cleared restriction requires dispatch or the attended handoff in this turn' 'emitted prompt omitted expired-stop dispatch'
  pass 'emitted supervision prompt requires current stop verification after finish'
}

test_emitted_away_scope_gate() {
  local prompt
  # The away-scope gate is delivered through this generated interface, so the
  # emitted bytes are the surface a test can prove; the branch's own reading of
  # the captain's words is not.
  prompt=$("$ROOT/bin/fm-branch-prompt.sh") || fail 'could not generate supervision prompt'
  assert_contains "$prompt" 'Away, standing autonomy does not widen: dispatch only the queued unblocked work the recorded away words name or a standing grant covers' 'emitted prompt let away dispatch widen past the recorded words'
  assert_contains "$prompt" 'Every other ready unit waits for MAIN, and you record its not-ready reason on its backlog note' 'emitted prompt omitted the waiting reason for out-of-scope away work'
  assert_contains "$prompt" 'This is the durable handoff, even for an unsolicited cleanup or heartbeat; a routine note never substitutes for it' 'emitted prompt lost the attended handoff'
  pass 'emitted supervision prompt gates away dispatch to the recorded words and keeps the attended handoff'
}

test_daemon_heartbeat() {
  local mode=$1 skip=${2:-heartbeat} dir state
  dir=$(make_case "daemon-$mode-$skip")
  state="$dir/state"
  mkdir -p "$dir/data" "$dir/config"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  printf 'mode: quiet\n' > "$state/.afk"
  if [ "$mode" != empty ]; then
    FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add queued 'next unit' >/dev/null || fail 'could not queue unit'
    FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add dependency 'dependency' >/dev/null || fail 'could not add dependency'
    FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" block queued --by dependency >/dev/null || fail 'could not set dependency'
    FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" 'done' dependency --pr https://github.com/example/fixture/pull/1 >/dev/null || fail 'could not land dependency'
  fi
  if [ "$mode" = held ]; then
    FM_HOME="$dir" "$ROOT/bin/fm-captain-hold.sh" hold queued --reason 'explicit hold' >/dev/null || fail 'could not hold unit'
  fi
  if [ "$mode" = unreadable ]; then
    printf '#!/usr/bin/env bash\nexit 2\n' > "$dir/fakebin/tasks-axi"
    chmod +x "$dir/fakebin/tasks-axi"
  fi
  if [ "$mode" = failed ]; then
    mkdir "$state/.subsuper-escalations"
  fi
  append_wake "$state" heartbeat heartbeat heartbeat || fail 'could not enqueue daemon heartbeat'
  (
    # shellcheck source=/dev/null # Production module is linted separately.
    . "$ROOT/bin/fm-supervise-daemon.sh"
    # shellcheck disable=SC2034 # Used by the sourced daemon's log function.
    LOG="$state/daemon.log"
    if [ "$mode" = failed ]; then
      if FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
        PATH="$dir/fakebin:$PATH" FM_INJECT_SKIP="$skip" FM_ESCALATE_BATCH_SECS=90 \
        handle_durable_wakes heartbeat "$state"; then
        fail 'failed handoff acknowledged its heartbeat'
      fi
    else
      FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
        PATH="$dir/fakebin:$PATH" FM_INJECT_SKIP="$skip" FM_ESCALATE_BATCH_SECS=90 \
        handle_durable_wakes heartbeat "$state" || fail 'daemon heartbeat handling failed'
    fi
  ) || fail 'daemon handling assertions failed'
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/remaining" 2>/dev/null || fail 'could not inspect remaining wakes'
  case "$mode" in
    empty|held)
      [ ! -s "$state/.subsuper-escalations" ] || fail 'nonready work reached dispatcher'
      [ ! -s "$dir/remaining" ] || fail 'nonready heartbeat remained unacknowledged'
      ;;
    failed)
      assert_contains "$(cat "$dir/remaining")" "$(printf '\theartbeat\t')" 'failed handoff lost its durable wake'
      ;;
    *)
      assert_contains "$(cat "$state/.subsuper-escalations")" 'ready-queue fleet check:' 'ready work was silently consumed'
      [ ! -s "$dir/remaining" ] || fail 'successful durable handoff did not acknowledge heartbeat'
      ;;
  esac
  pass "daemon $mode heartbeat respects readiness before skip=$skip and acknowledgement"
}

test_ready_queue_addressing absolute
test_ready_queue_addressing relative
test_ready_queue_addressing trailing-slash
test_ready_queue_addressing relative-home
test_ready_queue_addressing trailing-slash-home
test_ready_heartbeat
test_ready_heartbeat unreadable
test_not_ready_heartbeat empty
test_not_ready_heartbeat held
test_emitted_stop_revalidation_contract
test_emitted_away_scope_gate
test_daemon_heartbeat ready
test_daemon_heartbeat ready signal
test_daemon_heartbeat empty
test_daemon_heartbeat held
test_daemon_heartbeat unreadable
test_daemon_heartbeat failed
