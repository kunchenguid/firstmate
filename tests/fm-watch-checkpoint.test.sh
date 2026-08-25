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

write_context_failure_watcher() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
printf 'signal: context fallback fixture\n'
SH
}

write_context_failure_presenter() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
if [ ! -f "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/wake-context-presentation" ]; then
  printf 'WAKE_CONTEXT_FALLBACK: automatic wake context is disabled; run bin/fm-wake-drain.sh once.\n'
  exit 3
fi
if [ "${FM_WAKE_CONTEXT_FIXTURE_POST_PRESENTATION:-0}" = 1 ]; then
  printf 'WAKE_CONTEXT_PRESENTED: durable presentation complete; do not run bin/fm-wake-drain.sh again.\n'
  printf 'durable Codex presentation\n'
  printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 7 --recovery-generation fixture-7\n' >&2
  exit 1
fi
printf 'codex context failed on stderr\nWAKE_CONTEXT_FALLBACK: run bin/fm-wake-drain.sh once.\n' >&2
exit 1
SH
}

install_context_failure_checkpoint() { # <repo>
  mkdir -p "$1/bin"
  cp "$CHECKPOINT" "$1/bin/fm-watch-checkpoint.sh"
  write_context_failure_watcher "$1/bin/fm-watch.sh"
  write_context_failure_presenter "$1/bin/fm-wake-context.sh"
  chmod +x "$1/bin"/*.sh
}

test_context_failure_surfaces_codex_fallback() {
  local home repo out err status
  home=$(make_home context-fallback); repo="$home/repo"
  install_context_failure_checkpoint "$repo"
  : > "$home/config/wake-context-presentation"
  out="$home/out.txt"; err="$home/err.txt"; status=0
  FM_HOME="$home" "$repo/bin/fm-watch-checkpoint.sh" --seconds 2 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "Codex actionable checkpoint must survive context failure"
  assert_contains "$(cat "$out")" "codex context failed on stderr" "Codex dropped context stderr"
  assert_contains "$(cat "$out")" "WAKE_CONTEXT_FALLBACK:" "Codex omitted the canonical context fallback"
  [ "$(grep -c 'WAKE_CONTEXT_FALLBACK:' "$out")" -eq 1 ] || fail "Codex duplicated the canonical fallback"
  pass "checkpoint surfaces context stderr and canonical fallback"
}

test_context_failure_relays_post_presentation_result() {
  local home repo out err status
  home=$(make_home context-presented); repo="$home/repo"
  install_context_failure_checkpoint "$repo"
  : > "$home/config/wake-context-presentation"
  out="$home/out.txt"; err="$home/err.txt"; status=0
  FM_WAKE_CONTEXT_FIXTURE_POST_PRESENTATION=1 FM_HOME="$home" \
    "$repo/bin/fm-watch-checkpoint.sh" --seconds 2 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "Codex actionable checkpoint must preserve post-presentation context failure"
  assert_contains "$(cat "$out")" "WAKE_CONTEXT_PRESENTED:" "Codex dropped the common post-presentation result"
  assert_contains "$(cat "$out")" "--ack-through 7 --recovery-generation fixture-7" "Codex dropped the durable acknowledgement"
  assert_not_contains "$(cat "$out")" "WAKE_CONTEXT_FALLBACK:" "Codex requested a second drain after durable presentation"
  pass "checkpoint relays post-presentation result without re-drain"
}

test_actionable_checkpoint_without_opt_in_uses_manual_drain_fallback() {
  local home repo out err status
  home=$(make_home context-default-off); repo="$home/repo"
  install_context_failure_checkpoint "$repo"
  out="$home/out.txt"; err="$home/err.txt"; status=0
  FM_HOME="$home" "$repo/bin/fm-watch-checkpoint.sh" --seconds 2 > "$out" 2> "$err" || status=$?
  expect_code 0 "$status" "default-off context must preserve the Codex actionable checkpoint"
  assert_contains "$(cat "$out")" "signal: context fallback fixture" "default-off Codex wake lost its reason"
  assert_contains "$(cat "$out")" "WAKE_CONTEXT_FALLBACK:" "default-off Codex wake lost its manual-drain fallback"
  assert_not_contains "$(cat "$out")" "WAKE_ACK_REQUIRED" "default-off Codex wake exposed an acknowledgement"
  [ "$(grep -c 'WAKE_CONTEXT_FALLBACK:' "$out")" -eq 1 ] || fail "Codex duplicated the default-off fallback"
  pass "checkpoint preserves one actionable fallback while wake context is default-off"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_actionable_checkpoint_without_opt_in_uses_manual_drain_fallback
test_context_failure_surfaces_codex_fallback
test_context_failure_relays_post_presentation_result
