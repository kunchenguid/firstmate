#!/usr/bin/env bash
# Tests for shared harness process-shape classification.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-harness-process.sh
. "$ROOT/bin/fm-harness-process.sh"

expect_process() {
  local expected=$1 comm=$2 args=$3 out rc=0
  out=$(fm_harness_process_name "$comm" "$args") || rc=$?
  [ "$rc" -eq 0 ] || fail "$comm / $args was not recognized"
  [ "$out" = "$expected" ] || fail "$comm / $args resolved '$out', expected '$expected'"
}

reject_process() {
  local comm=$1 args=$2
  if fm_harness_process_name "$comm" "$args" >/dev/null; then
    fail "$comm / $args was incorrectly recognized"
  fi
}

test_accepted_process_shapes() {
  expect_process claude /opt/bin/claude claude
  expect_process claude /opt/bin/claude-code claude-code
  expect_process claude /usr/bin/node 'node /opt/claude-code/cli.js'
  expect_process codex /usr/bin/node 'node /opt/tools/codex.js'
  expect_process devin /usr/bin/python3 'python3 /opt/devin/cli.py'
  expect_process devin /opt/bin/devin devin
  pass "shared matcher accepts verified executables and harness-bearing scripts"
}

test_rejected_process_shapes() {
  reject_process /opt/bin/devinventory devinventory
  reject_process /usr/bin/node 'node /opt/worker.js --state /tmp/devin-state'
  reject_process /usr/bin/node 'node /tmp/devin-state/worker.js'
  reject_process /usr/bin/python3 'python3 /tmp/code-indexer.py --label codex'
  pass "shared matcher rejects unrelated harness substrings"
}

test_harness_ancestry_uses_shared_shapes() {
  local fakebin out
  fakebin=$(fm_fakebin "$(fm_test_tmproot fm-harness-process)")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/bin/node' ;;
  *"args="*) printf '%s\n' "${FM_TEST_ARGS:?}" ;;
  *"ppid="*) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(env -u DEVIN_CLI -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    FM_TEST_ARGS='node /opt/claude-code/cli.js' PATH="$fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "ancestry did not recognize Claude interpreter shape: $out"
  out=$(env -u DEVIN_CLI -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    FM_TEST_ARGS='node /tmp/worker.js --state /tmp/devin-state' PATH="$fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = unknown ] || fail "ancestry accepted unrelated Devin argv: $out"
  pass "fm-harness ancestry delegates to the shared matcher"
}

test_accepted_process_shapes
test_rejected_process_shapes
test_harness_ancestry_uses_shared_shapes
