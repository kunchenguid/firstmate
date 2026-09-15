#!/usr/bin/env bash
# Behavior tests for the verified Junie CLI crewmate/scout adapter.
#
# The facts pinned here are the ones a Junie release could silently change and
# the ones a wrong guess would make dangerous:
#   1. Junie is detected via anchored process name `junie`.
#   2. The anchored match must never claim unrelated commands containing the
#      fragment (e.g. junie-helper, fakejunie).
#   3. A structural junie ancestor outranks an inherited CLAUDECODE.
#   4. Junie is a crewmate/scout adapter only: secondmate launch is refused.
#   5. Control plane mappings: Escape interrupt key, single press, /exit exit
#      command, wiring path is state/<id>.junie-config.json.
#   6. Busy-state trusts Junie's per-task hook source.
#   7. Process classifier recognizes `junie` as an agent process and rejects decoys.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-junie-harness)

test_junie_ancestry_detects_the_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/junie'; exit 0 ;;
  *"args="*) printf '%s\n' 'junie --brave'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = junie ] \
    || fail "a natively-named junie command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named junie command"
}

test_junie_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(FAKE_PS_COMM=junie-helper FAKE_PS_ARGS='junie-helper --serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != junie ] \
    || fail "an unrelated junie-helper command must not detect junie, got '$out'"

  out=$(FAKE_PS_COMM=fakejunie FAKE_PS_ARGS='fakejunie run' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != junie ] \
    || fail "an unrelated fakejunie command must not detect junie, got '$out'"

  pass "fm-harness.sh: ancestry rejects unrelated commands matching junie fragments"
}

test_junie_structural_ancestry_outranks_inherited_claudecode() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-outrank")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'junie'; exit 0 ;;
  *"args="*) printf '%s\n' 'junie --brave'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" CLAUDECODE=1 "$HARNESS")
  [ "$out" = junie ] \
    || fail "comm junie must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: structural junie ancestry outranks an inherited CLAUDECODE"
}

test_junie_control_table_contract() {
  fm_control_harness_supported junie || fail "junie must be a supported harness in fm-control-lib"
  [ "$(fm_control_harness_family junie)" = junie ] \
    || fail "junie family must be junie"
  fm_control_harness_supports_kind junie ship \
    || fail "junie must support ship kind"
  fm_control_harness_supports_kind junie scout \
    || fail "junie must support scout kind"
  if fm_control_harness_supports_kind junie secondmate; then
    fail "junie must refuse secondmate kind (worker-only adapter)"
  fi
  [ "$(fm_control_interrupt_key junie)" = Escape ] \
    || fail "junie interrupt key must be Escape"
  [ "$(fm_control_interrupt_repeat junie)" = 1 ] \
    || fail "junie interrupt must use a single Escape press"
  [ "$(fm_control_exit_command junie)" = "/exit" ] \
    || fail "junie exit command must be /exit"

  local wiring
  wiring=$(fm_control_harness_wiring_paths junie /tmp/wt /tmp/state mytask)
  [ "$wiring" = "/tmp/state/mytask.junie-config.json" ] \
    || fail "junie wiring path must be state/id.junie-config.json, got '$wiring'"

  pass "fm-control-lib.sh: junie control table entries behave as expected"
}

test_junie_busy_source_contract() {
  local sources
  sources=$(fm_busy_sources_for_harness junie)
  case " $sources " in
    *" junie-hook "*) ;;
    *) fail "junie busy-state sources must trust junie-hook, got '$sources'" ;;
  esac
  pass "fm-busy-lib.sh: junie hook events are trusted busy-state sources"
}

test_junie_process_classification() {
  [ "$(fm_agent_process_classify_name junie)" = agent ] \
    || fail "bare junie process must classify as agent"
  [ "$(fm_agent_process_classify_name /usr/local/bin/junie)" = agent ] \
    || fail "junie path must classify as agent"
  [ "$(fm_agent_process_classify_name junie-helper)" = other ] \
    || fail "junie-helper must classify as other"
  [ "$(fm_agent_process_classify_name fakejunie)" = other ] \
    || fail "fakejunie must classify as other"
  pass "fm-agent-process-lib.sh: junie process classification is anchored and accurate"
}

run_suite() {
  test_junie_ancestry_detects_the_native_command_name
  test_junie_ancestry_rejects_unrelated_mentions
  test_junie_structural_ancestry_outranks_inherited_claudecode
  test_junie_control_table_contract
  test_junie_busy_source_contract
  test_junie_process_classification
}

run_suite
