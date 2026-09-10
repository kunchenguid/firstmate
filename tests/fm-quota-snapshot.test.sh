#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-snapshot.sh: quota-axi read under one
# candidate runner's account pin, so each pin's capacity is read from that
# pin's own account and a missing pin refuses exactly as a spawn would.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-snapshot)
SNAPSHOT="$ROOT/bin/fm-quota-snapshot.sh"
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_test_account_pins "$HOME_DIR"

# The fake quota-axi reports the roots it was run under and its arguments.
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/bin/sh
printf '%s|%s|%s\n' "${CLAUDE_CONFIG_DIR:-unset}" "${PI_CODING_AGENT_DIR:-unset}" "$*"
SH
chmod +x "$FAKEBIN/quota-axi"

run_snapshot() {
  env FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE='' CLAUDE_CONFIG_DIR=ambient-claude PI_CODING_AGENT_DIR=ambient-pi \
    PATH="$FAKEBIN:$PATH" "$SNAPSHOT" "$@" 2>&1
}

test_pinned_runners_read_under_their_pin() {
  local out harness
  out=$(run_snapshot claude --json) || fail "claude snapshot failed: $out"
  [ "$out" = "$HOME_DIR/accounts/claude|ambient-pi|--json" ] \
    || fail "claude snapshot did not run under the Claude pin: $out"
  for harness in pi pi-signed; do
    out=$(run_snapshot "$harness" auth --json) || fail "$harness snapshot failed: $out"
    [ "$out" = "ambient-claude|$HOME_DIR/accounts/pi|auth --json" ] \
      || fail "$harness snapshot did not run under the Pi pin: $out"
  done
  pass "claude, pi, and pi-signed snapshots run quota-axi under the home's pin, never an ambient root, arguments unchanged"
}

test_unpinned_runner_reads_ambient() {
  local out
  out=$(run_snapshot codex) || fail "codex snapshot failed: $out"
  [ "$out" = "ambient-claude|ambient-pi|" ] || fail "an unpinned runner's snapshot changed the environment: $out"
  pass "an unpinned runner's snapshot runs quota-axi in the ambient environment"
}

test_missing_pin_refuses_without_reading() {
  local out status
  rm "$HOME_DIR/config/pi-agent-dir"
  out=$(run_snapshot pi); status=$?
  expect_code 1 "$status" "a Pi snapshot without a pin must refuse: $out"
  assert_contains "$out" "require an account pin: create $HOME_DIR/config/pi-agent-dir" \
    "a missing-pin snapshot refusal must name the file to create"
  assert_not_contains "$out" "|" "a missing-pin snapshot still read quota-axi"
  printf '%s\n' "$HOME_DIR/accounts/pi" > "$HOME_DIR/config/pi-agent-dir"
  pass "a snapshot for a runner with no pin refuses before reading quota"
}

test_unknown_harness_is_a_usage_error() {
  local out status
  out=$(run_snapshot bogus); status=$?
  expect_code 2 "$status" "an unknown harness must be a usage error: $out"
  assert_contains "$out" "unknown harness: bogus" "the usage error must name the harness"
  pass "an unknown harness is refused as a usage error"
}

test_pinned_runners_read_under_their_pin
test_unpinned_runner_reads_ambient
test_missing_pin_refuses_without_reading
test_unknown_harness_is_a_usage_error
