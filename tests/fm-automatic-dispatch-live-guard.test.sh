#!/usr/bin/env bash
# Portable guard coverage for the opt-in live automatic-dispatch test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIVE="$ROOT/tests/fm-automatic-dispatch-live-e2e.test.sh"
LAB=$(fm_test_tmproot fm-automatic-dispatch-live-guard)
FAKEBIN="$LAB/fakebin"
CODEX_DIR="$LAB/codex"
mkdir -p "$FAKEBIN" "$CODEX_DIR"

cat >"$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    printf '%s\n' '9.9.9 (Claude Code)'
    exit "${FAKE_CLAUDE_VERSION_EXIT:-0}"
    ;;
  --help) printf '%s\n' '  --model <model> aliases include sonnet' ;;
  *) exit 64 ;;
esac
SH
cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] || exit 64
printf '%s\n' 'codex-cli 9.9.9'
SH
cat >"$FAKEBIN/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '9.9.9' ;;
  --list-models)
    cat <<'ROWS'
provider model context max-out thinking images
cliproxyapi gemini-3.7-flash-high 1M 16K yes yes
zai glm-5.3 1M 16K yes no
cliproxyapi kimi-k3 1M 16K yes yes
cliproxyapi grok-4.6 500K 16K yes yes
ROWS
    ;;
  *) exit 64 ;;
esac
SH
cat >"$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' 'quota-axi 9.9.9' ;;
  --json) printf '%s\n' '{"schemaVersion":5,"providers":[]}' ;;
  *) exit 64 ;;
esac
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/codex" "$FAKEBIN/pi" "$FAKEBIN/quota-axi"

jq -n '{models:[{slug:"gpt-5.6-sol"},{slug:"gpt-5.6-luna"}]}' >"$CODEX_DIR/models_cache.json"

assert_no_cleanup_registry() {
  local directory=$1 leaked
  leaked=$(find "$directory" -maxdepth 1 -name '.fm-test-cleanup.*' -print)
  [ -z "$leaked" ] || fail "live guard leaked cleanup registry: $leaked"
}

run_live() {
  local case_tmp=$1
  shift
  mkdir -p "$case_tmp"
  TMPDIR="$case_tmp" PATH="$FAKEBIN:$PATH" CODEX_HOME="$CODEX_DIR" "$@" "$LIVE"
}

test_skip_does_not_create_cleanup_registry() {
  local case_tmp="$LAB/skip" out
  out=$(run_live "$case_tmp" env -u FM_AUTOMATIC_DISPATCH_LIVE_E2E) \
    || fail "live guard opt-in skip failed"
  assert_contains "$out" 'skip: set FM_AUTOMATIC_DISPATCH_LIVE_E2E=1' "live guard skip diagnostic"
  assert_no_cleanup_registry "$case_tmp"
  pass "live guard skip creates no cleanup registry"
}

test_nonzero_version_with_output_fails_before_reporting() {
  local case_tmp="$LAB/version-failure" out rc
  set +e
  out=$(run_live "$case_tmp" env FM_AUTOMATIC_DISPATCH_LIVE_E2E=1 FAKE_CLAUDE_VERSION_EXIT=42 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "nonzero Claude version probe was hidden by first-line extraction"
  assert_contains "$out" 'Claude version probe failed' "nonzero version probe diagnostic"
  assert_not_contains "$out" 'runtime claude version=' "failed version probe was reported as installed"
  assert_no_cleanup_registry "$case_tmp"
  pass "nonzero version output is never mistaken for a successful probe"
}

test_success_composes_shared_cleanup() {
  local case_tmp="$LAB/success" out
  out=$(run_live "$case_tmp" env FM_AUTOMATIC_DISPATCH_LIVE_E2E=1) \
    || fail "fake live verification did not complete: $out"
  assert_contains "$out" 'ok - live automatic dispatch verified' "fake live verification result"
  assert_no_cleanup_registry "$case_tmp"
  pass "successful live verification preserves shared cleanup"
}

test_skip_does_not_create_cleanup_registry
test_nonzero_version_with_output_fails_before_reporting
test_success_composes_shared_cleanup
