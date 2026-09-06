#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

write_terminal_footer_case() {
  local home=$1 delivered=$2 style=${3:-herdr} fakebin key sig hash
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane) cat "$FM_HOME/state/pane.txt"; exit 0 ;;
  display-message) printf '\n'; exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf 'window=test:fm-footer\nkind=ship\n' > "$home/state/footer.meta"
  printf 'done: PR https://example.test/pr/footer\n' > "$home/state/footer.status"
  sig=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_signal_sig "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state/footer.status")
  printf '%s' "$sig" > "$home/state/.seen-footer_status"
  if [ "$style" = claude-statusline ]; then
    printf 'finished, awaiting review\n5h ███ 61%% (1h34m) | api wait 12s\n' > "$home/state/pane.txt"
  else
    printf 'finished, awaiting review\n⏱  16m | 12%% context\n' > "$home/state/pane.txt"
  fi
  key=test_fm-footer
  if [ "$style" = claude-statusline ]; then
    hash=$(hash_text $'finished, awaiting review\n5h ███ 61% (1h34m) | api wait 11s')
  else
    hash=$(hash_text $'finished, awaiting review\n⏱  15m | 12% context')
  fi
  printf '%s' "$hash" > "$home/state/.hash-$key"
  printf '1\n' > "$home/state/.count-$key"
  if [ "$delivered" = 1 ]; then
    printf 'done: PR https://example.test/pr/footer' > "$home/state/.hb-surfaced-footer"
  fi
}

# assert_no_live_watch_lock <lockdir> <msg> - the checkpoint must leave no LIVE
# watcher holding <lockdir>. A live holder is what wedges the next arm; a marker
# left by a watcher the checkpoint killed is reclaimed by the next arm's
# liveness/recovery path instead, so only liveness is asserted here.
assert_no_live_watch_lock() {
  local pid
  pid=$(cat "$1/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  ! kill -0 "$pid" 2>/dev/null || fail "$2 (live pid $pid)"
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
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
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
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_delivered_terminal_footer_checkpoint_is_quiet() {
  local home out status absorbed
  home=$(make_home terminal-footer-delivered)
  out="$home/out.txt"
  write_terminal_footer_case "$home" 1
  absorbed=$(hash_text $'finished, awaiting review\n⏱  16m | 12% context')
  status=0
  # Quiet is only evidence of the delivered-status dedup once the watcher has
  # actually reached this pane's terminal-stale triage; a window shorter than
  # that latency would go quiet on the pre-fix watcher too and prove nothing.
  # Measured latency from checkpoint start to the pre-fix surface is ~2.6-4.3s
  # serial and ~10s when several watcher tests overlap, so the window carries
  # real headroom and the absorb assertion below fails loudly rather than
  # passing vacuously if the watcher never got that far.
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW=test:fm-footer \
    FM_POLL=0.2 FM_SIGNAL_GRACE=0.1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 20 >"$out" 2>&1 || status=$?
  expect_code 124 "$status" "delivered changing-footer checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 20s" "quiet delivered checkpoint line missing"
  assert_absent "$home/state/.wake-queue" "delivered changing-footer checkpoint queued a wake"
  [ "$(cat "$home/state/.stale-test_fm-footer" 2>/dev/null || true)" = "$absorbed" ] \
    || fail "the quiet checkpoint never reached the delivered-terminal absorb: stale=$(cat "$home/state/.stale-test_fm-footer" 2>/dev/null || true) expected=$absorbed"
  # Unlike the sibling cases, this watcher polls a real pane every FM_POLL, so it
  # is usually inside a forked capture when the checkpoint expires. Without
  # coreutils timeout(1) the perl fallback SIGKILLs the process group 0.2s after
  # SIGTERM, which can beat the watcher's lock-releasing EXIT trap under load.
  assert_no_live_watch_lock "$home/state/.watch.lock" "delivered changing-footer checkpoint left a live watcher"
  pass "delivered changing-footer state stays quiet through the Codex checkpoint"
}

test_undelivered_terminal_footer_checkpoint_wakes_once() {
  local home out status
  home=$(make_home terminal-footer-undelivered)
  out="$home/out.txt"
  write_terminal_footer_case "$home" 0
  status=0
  # The checkpoint returns as soon as the wake lands, so this window is only a
  # failure bound and costs nothing on success - keep it well clear of the ~10s
  # wake latency seen when several watcher tests overlap.
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW=test:fm-footer \
    FM_POLL=0.2 FM_SIGNAL_GRACE=0.1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 60 >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "undelivered changing-footer checkpoint exit"
  [ "$(grep -c '^stale: test:fm-footer$' "$out")" -eq 1 ] \
    || fail "undelivered changing-footer checkpoint did not pass through exactly one stale wake: $(cat "$out")"
  pass "the first undelivered changing-footer state wakes the Codex checkpoint once"
}

test_delivered_terminal_claude_statusline_checkpoint_is_quiet() {
  local home out status absorbed
  home=$(make_home claude-statusline-delivered)
  out="$home/out.txt"
  write_terminal_footer_case "$home" 1 claude-statusline
  absorbed=$(hash_text $'finished, awaiting review
5h ███ 61% (1h34m) | api wait 12s')
  status=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW=test:fm-footer \
    FM_POLL=0.2 FM_SIGNAL_GRACE=0.1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 20 >"$out" 2>&1 || status=$?
  expect_code 124 "$status" "delivered Claude statusLine checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 20s" "quiet delivered Claude statusLine checkpoint line missing"
  assert_absent "$home/state/.wake-queue" "delivered Claude statusLine checkpoint queued a wake"
  [ "$(cat "$home/state/.stale-test_fm-footer" 2>/dev/null || true)" = "$absorbed" ] \
    || fail "the quiet checkpoint never reached the delivered Claude statusLine absorb"
  assert_no_live_watch_lock "$home/state/.watch.lock" "delivered Claude statusLine checkpoint left a live watcher"
  pass "delivered Claude statusLine churn stays quiet through the Codex checkpoint"
}

test_undelivered_terminal_claude_statusline_checkpoint_wakes_once() {
  local home out status
  home=$(make_home claude-statusline-undelivered)
  out="$home/out.txt"
  write_terminal_footer_case "$home" 0 claude-statusline
  status=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW=test:fm-footer \
    FM_POLL=0.2 FM_SIGNAL_GRACE=0.1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 60 >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "undelivered Claude statusLine checkpoint exit"
  [ "$(grep -c '^stale: test:fm-footer$' "$out")" -eq 1 ] \
    || fail "undelivered Claude statusLine checkpoint did not pass through exactly one stale wake: $(cat "$out")"
  pass "the first undelivered Claude statusLine state wakes the Codex checkpoint once"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_delivered_terminal_footer_checkpoint_is_quiet
test_undelivered_terminal_footer_checkpoint_wakes_once
test_delivered_terminal_claude_statusline_checkpoint_is_quiet
test_undelivered_terminal_claude_statusline_checkpoint_wakes_once
