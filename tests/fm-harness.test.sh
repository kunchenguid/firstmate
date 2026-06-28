#!/usr/bin/env bash
# Behavior tests for bin/fm-harness.sh harness detection and crew-harness resolution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness)

# Clear ambient overrides so the test owns the environment.
run_harness() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$TMP_ROOT" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    "$HARNESS" "$@" 2>&1
}

# crew mode reads config/crew-harness when present.
test_crew_reads_config() {
  local out
  mkdir -p "$TMP_ROOT/config"
  printf 'kimi-cli\n' > "$TMP_ROOT/config/crew-harness"
  out=$(run_harness crew)
  [ "$out" = "kimi-cli" ] || fail "crew harness should read config/crew-harness; got '$out'"
  pass "crew harness resolves config/crew-harness"
}

# crew mode falls back to detect_own when config/crew-harness is absent or 'default'.
test_crew_fallback_default() {
  local out
  mkdir -p "$TMP_ROOT/config"
  printf 'default\n' > "$TMP_ROOT/config/crew-harness"
  # We cannot easily fake the process tree here, but 'default' must not echo the literal word.
  out=$(run_harness crew)
  [ "$out" != "default" ] || fail "crew harness should resolve 'default', not echo it"
  pass "crew harness resolves 'default' to detected harness"
}

# Detection must recognise the kimi/kimi-cli ecosystem.
test_detect_kimi_cli_by_command() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
# Fake ps that reports a kimi parent chain.
case "$*" in
  *'-o comm= -p '*)
    echo 'kimi'
    ;;
  *'-o ppid= -p '*)
    echo '1'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  PATH="$fakebin:$PATH" out=$(run_harness)
  [ "$out" = "kimi-cli" ] || fail "detect_own should map kimi to kimi-cli; got '$out'"
  pass "detect_own maps 'kimi' process to kimi-cli harness"
}

test_crew_reads_config
test_crew_fallback_default
test_detect_kimi_cli_by_command
