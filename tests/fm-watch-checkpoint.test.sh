#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
RENDER="$ROOT/bin/fm-supervision-instructions.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)
QUIET_OUTCOME=
FAILED_OUTCOME=
SINGLETON_OUTCOME=

first_checkpoint_line() {
  grep -m1 '^checkpoint:' "$@" 2>/dev/null || true
}

# Route one real emitted checkpoint outcome through the rendered operating
# instructions: print every numbered rule whose quoted outcome literal is a
# prefix of the emitted line.
rules_matching_outcome() {
  local block=$1 emitted=$2
  printf '%s\n' "$block" | awk -v emitted="$emitted" '
    match($0, /^[0-9]+\./) { rule = substr($0, 1, RLENGTH - 1) }
    rule == "" { next }
    {
      n = split($0, parts, "`")
      for (i = 2; i <= n; i += 2) {
        tok = parts[i]
        if (tok != "" && substr(emitted, 1, length(tok)) == tok && !(rule in seen)) {
          seen[rule] = 1
          print rule
        }
      }
    }
  ' | tr '\n' ' ' | sed 's/ $//'
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  QUIET_OUTCOME=$(first_checkpoint_line "$out")
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  SINGLETON_OUTCOME=$(first_checkpoint_line "$err")
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_self_evicted_watcher_is_not_empty_success() {
  local home out err status replacer
  local beacon_budget_ds=600 checkpoint_seconds=120
  home=$(make_home self-eviction)
  out="$home/out.txt"
  err="$home/err.txt"
  # Wait for the real watcher to publish its first beacon, then replace only
  # this fixture's singleton owner. The watcher must yield without deleting
  # the replacement lock, but its checkpoint must report the lost wait.
  # Real watcher startup takes seconds and varies with machine load, so the
  # beacon budget stays well inside the checkpoint deadline: neither the
  # replacement nor the checkpoint may expire before the eviction lands.
  (
    for ((i = 0; i < beacon_budget_ds; i++)); do
      if [ -f "$home/state/.last-watcher-beat" ]; then
        printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
        exit 0
      fi
      sleep 0.1
    done
    exit 1
  ) &
  replacer=$!
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds "$checkpoint_seconds" >"$out" 2>"$err" || status=$?
  wait "$replacer" \
    || fail "real watcher published no beacon within $((beacon_budget_ds / 10))s"
  [ "$(cat "$home/state/.watch.lock/pid")" = "$$" ] || fail "checkpoint disturbed replacement owner"
  expect_code 1 "$status" "self-evicted checkpoint exit"
  assert_contains "$(cat "$err")" "ended without an actionable wake" "lost checkpoint wait was not explained"
  FAILED_OUTCOME=$(first_checkpoint_line "$err")
  pass "checkpoint reports self-eviction as failure and preserves the replacement owner"
}

test_codex_instructions_separate_quiet_deadline_from_failed_wait() {
  local block matched
  block=$("$RENDER" --harness codex)

  [ -n "$QUIET_OUTCOME" ] || fail "quiet checkpoint emitted no checkpoint outcome line"
  [ -n "$FAILED_OUTCOME" ] || fail "lost checkpoint wait emitted no checkpoint outcome line"
  [ -n "$SINGLETON_OUTCOME" ] || fail "singleton checkpoint emitted no checkpoint outcome line"

  matched=$(rules_matching_outcome "$block" "$QUIET_OUTCOME")
  [ "$matched" = "5" ] \
    || fail "quiet deadline routed to rules [$matched] instead of the continue-anyway rule 5"

  matched=$(rules_matching_outcome "$block" "$FAILED_OUTCOME")
  [ "$matched" = "8" ] \
    || fail "lost checkpoint wait routed to rules [$matched] instead of the ownership-inspection rule 8"

  matched=$(rules_matching_outcome "$block" "$SINGLETON_OUTCOME")
  [ "$matched" = "8" ] \
    || fail "already-running checkpoint routed to rules [$matched] instead of the ownership-inspection rule 8"

  pass "codex instructions route failed checkpoint waits to ownership inspection, not the quiet-deadline rule"
}

test_self_evicted_watcher_is_not_empty_success
test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_codex_instructions_separate_quiet_deadline_from_failed_wait
