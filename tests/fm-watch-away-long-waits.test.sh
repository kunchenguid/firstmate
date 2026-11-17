#!/usr/bin/env bash
# Away-mode long-wait escalation through the watcher's real queue interface.
# The away and quiet records are written by bin/fm-afk-contract.sh itself; only
# the crew-state verdict is stubbed through FM_CREW_STATE_BIN, its documented
# test seam. No endpoint, harness process, model call, or remote host is needed.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-away-long-waits)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"

# The stub prints the line recorded in <state>/<id>.crew-state-line, exactly as
# bin/fm-crew-state.sh would print its one canonical line, and records whether
# the caller asked it to skip the forge read.
STUB="$TMP_ROOT/crew-state-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "${FM_CREW_STATE_NO_FORGE:-0}" >> "$FM_STATE_OVERRIDE/.stub-calls"
cat "$FM_STATE_OVERRIDE/$1.crew-state-line" 2>/dev/null || printf 'state: unknown · source: none · no metadata for %s\n' "$1"
EOF
chmod +x "$STUB"
export FM_CREW_STATE_BIN="$STUB"

# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

AWAY_LONG_WAIT_SCAN_SECS=0
PAUSE_RESURFACE_SECS=10000

reset_case() {
  rm -rf -- "$STATE"/afk-*
  rm -f -- "$STATE"/* "$STATE"/.[!.]* "$CONFIG"/*
  AWAY_LONG_WAIT=
}

enter_away() {
  "$ROOT/bin/fm-afk-contract.sh" enter --words 'cap at 1' --spend 1 --spend-words 'cap at 1' >/dev/null || fail "away entry failed"
}

lane() {  # <task> <crew-state line>
  printf 'working [at=1000]: on it\n' > "$STATE/$1.status"
  printf 'worktree=%s\nkind=ship\n' "$TMP_ROOT" > "$STATE/$1.meta"
  printf '%s\n' "$2" > "$STATE/$1.crew-state-line"
}

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

test_thresholds_have_one_owner() {
  local class
  [ "$(fm_away_long_wait_threshold ci-active)" = 3600 ] || fail "CI-active default is not 60 min"
  [ "$(fm_away_long_wait_threshold base-drift)" = 1800 ] || fail "base-drift default is not 30 min"
  [ "$(fm_away_long_wait_threshold idle-green)" = 7200 ] || fail "idle-green default is not 2 h"
  for class in ci-active base-drift idle-green; do
    [ "$(FM_AWAY_CI_ACTIVE_ESCALATE_SECS=0 FM_AWAY_BASE_DRIFT_ESCALATE_SECS=abc \
      FM_AWAY_IDLE_GREEN_ESCALATE_SECS=-5 fm_away_long_wait_threshold "$class")" \
      = "$(fm_away_long_wait_threshold "$class")" ] || fail "invalid override changed the $class threshold"
  done
  [ "$(FM_AWAY_BASE_DRIFT_ESCALATE_SECS=60 fm_away_long_wait_threshold base-drift)" = 60 ] \
    || fail "a valid override was ignored"
  if fm_away_long_wait_threshold wedge >/dev/null; then fail "an unknown class has a threshold"; fi
  pass "the three thresholds default to 60 min, 30 min and 2 h, and only valid overrides apply"
}

test_classes_match_whole_components() {
  reset_case
  lane ci 'state: working · source: run-step · ci running · run: r1'
  lane nochecks 'state: working · source: run-step · no CI checks reported (or repository declares no CI): nothing has verified the PR (still monitoring for merge/close) · run: r2'
  lane drift 'state: parked · source: run-step · parked at rebase: 2 finding(s) · run: r3'
  lane green 'state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close): https://example.test/pr/1 · run: r4'
  lane held 'state: done · source: run-step · checks green: PR held for merge (ci monitor ended) · run: r5'
  lane merged 'state: done · source: run-step · checks green: PR merged (ci monitor ended) · run: r6'
  lane validating 'state: working · source: run-step · validating (running) · run: r7'
  lane review 'state: parked · source: run-step · parked at review: 1 finding(s) · run: r8'
  lane prose 'state: done · source: status-log · checks green: PR ready for review'
  lane pane 'state: working · source: pane · ci running'
  [ "$(crew_away_long_wait_class ci)" = ci-active ] || fail "ci running did not classify"
  [ "$(crew_away_long_wait_class nochecks)" = ci-active ] || fail "no-checks ci monitor did not classify"
  [ "$(crew_away_long_wait_class drift)" = base-drift ] || fail "rebase gate did not classify"
  [ "$(crew_away_long_wait_class green)" = idle-green ] || fail "green PR ready for review did not classify"
  [ "$(crew_away_long_wait_class held)" = idle-green ] || fail "green PR held for merge did not classify"
  for task in merged validating review prose pane missing; do
    [ -z "$(crew_away_long_wait_class "$task")" ] || fail "$task was classified as a long wait"
  done
  grep -qv ' 1$' "$STATE/.stub-calls" && fail "a classification read did not skip the forge"
  pass "only run-step components minted by fm-crew-state classify, and the forge read is skipped"
}

test_not_away_does_nothing() {
  reset_case
  lane ci 'state: working · source: run-step · ci running · run: r1'
  away_long_wait_tick 100000
  [ "$(count_wakes)" = 0 ] || fail "an attended home escalated a long wait"
  [ ! -e "$STATE/.stub-calls" ] || fail "an attended home paid a crew-state read"
  FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'cap at 1' --spend 1 --spend-words 'cap at 1' >/dev/null || fail "quiet entry failed"
  away_long_wait_tick 100000
  away_long_wait_tick 200000
  [ "$(count_wakes)" = 0 ] || fail "quiet mode escalated a long wait"
  pass "without an away record, including quiet mode, the tick reads nothing and wakes nothing"
}

test_thresholds_and_repeat() {
  reset_case
  enter_away
  lane ci 'state: working · source: run-step · ci running · run: r1'
  lane drift 'state: parked · source: run-step · parked at rebase · run: r2'
  lane green 'state: done · source: run-step · checks green: PR held for merge (ci monitor ended) · run: r3'
  away_long_wait_tick 1000
  away_long_wait_tick 2799
  [ "$(count_wakes)" = 0 ] || fail "a lane escalated before its threshold"
  away_long_wait_tick 2800
  [ "$(count_wakes)" = 1 ] || fail "base drift did not escalate at 30 min"
  [ "$AWAY_LONG_WAIT" = 'check: away long wait: drift base-drift 1800s (threshold 1800s)' ] \
    || fail "unexpected base-drift reason: $AWAY_LONG_WAIT"
  away_long_wait_tick 4600
  [ "$AWAY_LONG_WAIT" = 'check: away long wait: ci ci-active 3600s (threshold 3600s)' ] \
    || fail "unexpected CI-active reason: $AWAY_LONG_WAIT"
  away_long_wait_tick 8200
  [ "$AWAY_LONG_WAIT" = 'check: away long wait: green idle-green 7200s (threshold 7200s)' ] \
    || fail "unexpected idle-green reason: $AWAY_LONG_WAIT"
  [ "$(count_wakes)" = 3 ] || fail "each lane did not escalate exactly once"
  away_long_wait_tick 12799
  [ "$(count_wakes)" = 3 ] || fail "an escalated lane repeated before the recheck cadence"
  away_long_wait_tick 12800
  [ "$(count_wakes)" = 4 ] || fail "an escalated lane did not repeat on the recheck cadence"
  [ "$AWAY_LONG_WAIT" = 'check: away long wait: drift base-drift 11800s (threshold 1800s)' ] \
    || fail "the repeat did not carry the whole age: $AWAY_LONG_WAIT"
  away_long_wait_tick 18200
  case "$AWAY_LONG_WAIT" in
    'check: away long wait: ci ci-active 17200s (threshold 3600s); green idle-green 17200s (threshold 7200s)') ;;
    *) fail "simultaneously due lanes were not joined into one wake: $AWAY_LONG_WAIT" ;;
  esac
  [ "$(count_wakes)" = 5 ] || fail "simultaneously due lanes queued more than one wake"
  pass "each class escalates at its own threshold, once, then once per recheck cadence, joined per scan"
}

test_episode_resets() {
  reset_case
  enter_away
  lane ci 'state: working · source: run-step · ci running · run: r1'
  away_long_wait_tick 1000
  printf '%s\n' 'state: working · source: run-step · validating (fixing) · run: r1' > "$STATE/ci.crew-state-line"
  away_long_wait_tick 3000
  printf '%s\n' 'state: working · source: run-step · ci running · run: r1' > "$STATE/ci.crew-state-line"
  away_long_wait_tick 4000
  away_long_wait_tick 7599
  [ "$(count_wakes)" = 0 ] || fail "a lane that left CI kept its earlier clock"
  printf '%s\n' 'state: parked · source: run-step · parked at rebase · run: r1' > "$STATE/ci.crew-state-line"
  away_long_wait_tick 7600
  away_long_wait_tick 9399
  [ "$(count_wakes)" = 0 ] || fail "a class change inherited the previous class's clock"
  away_long_wait_tick 9400
  [ "$(count_wakes)" = 1 ] || fail "the new class did not escalate on its own clock"
  "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null || fail "away exit failed"
  away_long_wait_tick 9500
  [ ! -e "$STATE/.away-long-waits" ] || fail "leaving away kept the ledger"
  enter_away
  away_long_wait_tick 9600
  away_long_wait_tick 11399
  [ "$(count_wakes)" = 1 ] || fail "a new away session inherited an earlier session's clock"
  pass "leaving a class, changing class, or leaving away each start a fresh episode"
}

test_scan_throttle_and_scope() {
  reset_case
  enter_away
  AWAY_LONG_WAIT_SCAN_SECS=300
  lane ci 'state: working · source: run-step · ci running · run: r1'
  printf 'working [at=1000]: no meta\n' > "$STATE/nometa.status"
  away_long_wait_tick 1000
  away_long_wait_tick 1299
  [ "$(wc -l < "$STATE/.stub-calls" | tr -d ' ')" = 1 ] \
    || fail "the scan ran inside its interval or read a task without a meta record"
  away_long_wait_tick 1300
  [ "$(wc -l < "$STATE/.stub-calls" | tr -d ' ')" = 2 ] || fail "the scan did not run after its interval"
  AWAY_LONG_WAIT_SCAN_SECS=0
  pass "the scan runs once per interval and only for tasks with a meta record"
}

test_watcher_loop() {
  local dir="$TMP_ROOT/watcher-loop" pid i=0
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  touch "$dir/state/home-summary.json"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-afk-contract.sh" enter --words 'cap at 1' --spend 1 --spend-words 'cap at 1' >/dev/null \
    || fail "away entry failed"
  printf 'working [at=1000]: on it\n' > "$dir/state/worker.status"
  printf 'worktree=%s\nkind=ship\n' "$dir" > "$dir/state/worker.meta"
  printf '%s\n' 'state: parked · source: run-step · parked at rebase · run: r1' > "$dir/state/worker.crew-state-line"
  # A ledger an earlier watcher left behind: the episode clock survives a restart.
  printf 'worker\tbase-drift\t1000\t0\n' > "$dir/state/.away-long-waits"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$STUB" \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "real watcher failed to wake on a long away wait"
  fi
  wait "$pid" || fail "real watcher exited unsuccessfully: $(cat "$dir/err")"
  grep -F 'check: away long wait: worker base-drift ' "$dir/out" >/dev/null \
    || fail "real watcher did not print the long-wait wake: $(cat "$dir/out")"
  grep -F 'away-long-wait' "$dir/state/.wake-queue" >/dev/null \
    || fail "real watcher did not durably queue the long-wait wake"
  pass "the actual watcher wakes and exits on a long away wait, keeping the clock across a restart"
}

fm_test_run test_thresholds_have_one_owner test_classes_match_whole_components \
  test_not_away_does_nothing test_thresholds_and_repeat test_episode_resets \
  test_scan_throttle_and_scope test_watcher_loop
