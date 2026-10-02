#!/usr/bin/env bash
# tests/fm-sandbox.test.sh - portable regressions for the opt-in worker command
# sandbox wrapper (bin/fm-sandbox.sh).
#
# These drive the wrapper's public interface with a canned `srt` CLI: the
# off-default passthrough, the fail-closed refusals (missing runtime, wrong
# version, unusable settings, unenforced isolation), and the exact sandbox
# command construction. A live guard against a real srt lives in the
# live-harness-optin family; this suite never runs a real sandbox.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SANDBOX="$ROOT/bin/fm-sandbox.sh"
TMP_ROOT=$(fm_test_tmproot fm-sandbox)

# new_home <name> -> echoes a home directory with an empty config dir.
new_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/config"
  printf '%s\n' "$dir"
}

settings_file() {  # <home>
  printf '%s\n' "$1/config/worker-sandbox-settings.json"
}

write_settings() {  # <home>
  printf '%s\n' \
    '{"filesystem":{"denyRead":[],"allowRead":[],"allowWrite":["."],"denyWrite":[]},"network":{"allowedDomains":[],"deniedDomains":[]}}' \
    > "$(settings_file "$1")"
}

enable_sandbox() {  # <home>
  : > "$1/config/worker-sandbox"
}

install_srt() {  # <home> [version] -> prints the fake srt path
  local fakebin
  fakebin=$(fm_fakebin "$1")
  fm_test_fake_srt "$fakebin" "${2:-0.0.78}"
  printf '%s\n' "$fakebin/srt"
}

# A runtime that reports the pinned version but ignores its settings and runs
# every command unsandboxed: the probe must refuse it rather than trust a
# runtime that enforces nothing.
install_broken_srt() {  # <home> -> prints the fake srt path
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/srt" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_SRT_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_SRT_LOG"
if [ "${1:-}" = --version ]; then printf '0.0.78\n'; exit 0; fi
cmd=
while [ $# -gt 0 ]; do
  case "$1" in
    -c) cmd=${2:-}; shift 2; continue ;;
    --settings|-s) shift 2; continue ;;
  esac
  shift
done
[ -n "$cmd" ] || exit 0
exec /bin/bash -c "$cmd"
SH
  chmod +x "$fakebin/srt"
  printf '%s\n' "$fakebin/srt"
}

run_sandbox() {  # <home> <srt-path> <args...>
  local home=$1 srt=$2
  shift 2
  FM_HOME="$home" FM_SANDBOX_SRT_BIN="$srt" "$SANDBOX" "$@"
}

test_disabled_prefix_is_empty_and_silent() {
  local home out status
  home=$(new_home disabled-prefix)
  out=$(FM_HOME="$home" "$SANDBOX" prefix 2>&1)
  status=$?
  expect_code 0 "$status" "prefix with the flag absent should succeed: $out"
  assert_equals "" "$out" "prefix with the flag absent must print nothing"
  pass "sandbox flag absent: prefix prints nothing and exits 0"
}

test_disabled_exec_passthrough_runs_without_the_runtime() {
  local home out status
  home=$(new_home disabled-exec)
  out=$(FM_SANDBOX_SRT_BIN="$home/missing-srt" FM_HOME="$home" "$SANDBOX" exec -- /bin/sh -c 'echo passthrough-ok' 2>&1)
  status=$?
  expect_code 0 "$status" "exec with the flag absent should succeed: $out"
  assert_contains "$out" "passthrough-ok" "exec with the flag absent must run the command unchanged"
  pass "sandbox flag absent: exec runs the command unchanged with no runtime present"
}

test_enabled_missing_runtime_refuses_and_runs_nothing() {
  local home out status marker
  home=$(new_home enabled-missing-runtime)
  enable_sandbox "$home"
  write_settings "$home"
  marker="$home/ran-marker"
  out=$(FM_SANDBOX_SRT_BIN="$home/no-such-srt" FM_HOME="$home" "$SANDBOX" prefix 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "prefix must refuse when the runtime is missing, got: $out"
  assert_contains "$out" "not an executable file" "the refusal must name the unusable runtime"
  out=$(FM_SANDBOX_SRT_BIN="$home/no-such-srt" FM_HOME="$home" "$SANDBOX" exec -- /bin/sh -c "touch '$marker'" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "exec must refuse when the runtime is missing, got: $out"
  assert_absent "$marker" "fail-closed exec must not run the command when the runtime is missing"
  pass "sandbox flag on with no runtime: prefix and exec refuse and run nothing"
}

test_enabled_wrong_version_refuses() {
  local home srt out status
  home=$(new_home enabled-wrong-version)
  enable_sandbox "$home"
  write_settings "$home"
  srt=$(install_srt "$home" 9.9.9)
  out=$(run_sandbox "$home" "$srt" prefix 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "prefix must refuse an unpinned runtime version, got: $out"
  assert_contains "$out" "is not the pinned 0.0.78" "the refusal must name the pinned version"
  pass "sandbox flag on with a wrong runtime version: refused"
}

test_enabled_missing_settings_refuses() {
  local home srt out status
  home=$(new_home enabled-missing-settings)
  enable_sandbox "$home"
  srt=$(install_srt "$home")
  out=$(run_sandbox "$home" "$srt" prefix 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "prefix must refuse when the settings file is missing, got: $out"
  assert_contains "$out" "does not exist" "the refusal must name the missing settings file"
  pass "sandbox flag on with no settings file: refused"
}

test_enabled_empty_settings_refuses() {
  local home srt out status
  home=$(new_home enabled-empty-settings)
  enable_sandbox "$home"
  : > "$(settings_file "$home")"
  srt=$(install_srt "$home")
  out=$(run_sandbox "$home" "$srt" prefix 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "prefix must refuse an empty settings file, got: $out"
  assert_contains "$out" "is empty" "the refusal must name the empty settings file"
  pass "sandbox flag on with an empty settings file: refused"
}

test_enabled_invalid_settings_refuses() {
  local home srt out status
  command -v jq >/dev/null 2>&1 || {
    pass "sandbox invalid-settings refusal skipped: jq is not installed"
    return 0
  }
  home=$(new_home enabled-invalid-settings)
  enable_sandbox "$home"
  printf 'not-json\n' > "$(settings_file "$home")"
  srt=$(install_srt "$home")
  out=$(run_sandbox "$home" "$srt" prefix 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "prefix must refuse a settings file that is not a JSON object, got: $out"
  assert_contains "$out" "is not a JSON object" "the refusal must name the invalid settings file"
  pass "sandbox flag on with an invalid settings file: refused"
}

test_enabled_probe_reports_ready_and_prefix_is_exact() {
  local home srt out status expected
  home=$(new_home enabled-ready)
  enable_sandbox "$home"
  write_settings "$home"
  srt=$(install_srt "$home")
  out=$(run_sandbox "$home" "$srt" probe 2>&1)
  status=$?
  expect_code 0 "$status" "probe should succeed against a capable runtime: $out"
  assert_contains "$out" "worker sandbox ready" "probe must report readiness"
  out=$(run_sandbox "$home" "$srt" prefix 2>&1)
  status=$?
  expect_code 0 "$status" "prefix should succeed against a capable runtime: $out"
  expected="'$srt' --settings '$(settings_file "$home")' -c"
  assert_equals "$expected" "$out" "prefix must emit the pinned runtime, the settings, and -c"
  pass "sandbox flag on with a capable runtime: probe reports ready and prefix is exact"
}

test_runtime_rejects_supplied_settings_for_every_consumer() {
  local home srt config command out status marker
  home=$(new_home runtime-invalid-settings)
  enable_sandbox "$home"
  srt=$(install_srt "$home")
  marker="$home/ran-marker"
  for config in '{}' '{"network":{"allowedDomains":[],"deniedDomains":[],"allowLocalBinding":"invalid"},"filesystem":{"denyRead":[],"allowWrite":[],"denyWrite":[]}}'; do
    printf '%s\n' "$config" > "$(settings_file "$home")"
    for command in probe prefix exec; do
      if [ "$command" = exec ]; then
        out=$(run_sandbox "$home" "$srt" exec -- touch "$marker" 2>&1)
      else
        out=$(run_sandbox "$home" "$srt" "$command" 2>&1)
      fi
      status=$?
      expect_code 1 "$status" "$command must reject settings the runtime rejects: $out"
      assert_contains "$out" "did not accept the supplied settings" "the runtime must validate the supplied configuration"
      assert_absent "$marker" "invalid settings must never execute the worker"
    done
  done
  pass "runtime configuration rejection propagates through probe, prefix, and exec"
}

test_masked_and_failed_denied_reads_both_preserve_readiness() {
  local home srt out status read_exit
  home=$(new_home denied-read-modes)
  enable_sandbox "$home"
  write_settings "$home"
  srt=$(install_srt "$home")
  for read_exit in 0 1; do
    out=$(FM_FAKE_SRT_DENY_READ_EXIT="$read_exit" run_sandbox "$home" "$srt" probe 2>&1)
    status=$?
    expect_code 0 "$status" "hidden contents must pass readiness with read exit $read_exit: $out"
    assert_contains "$out" "worker sandbox ready" "readiness must accept both denied-read representations"
  done
  pass "empty successful reads and failed reads both preserve sandbox readiness"
}

test_enabled_exec_runs_the_command_through_the_runtime() {
  local home srt log out status
  home=$(new_home enabled-exec)
  enable_sandbox "$home"
  write_settings "$home"
  srt=$(install_srt "$home")
  log="$home/srt.log"
  out=$(FM_FAKE_SRT_LOG="$log" run_sandbox "$home" "$srt" exec -- /bin/sh -c 'echo sandboxed-ok' 2>&1)
  status=$?
  expect_code 0 "$status" "exec should succeed against a capable runtime: $out"
  assert_contains "$out" "sandboxed-ok" "exec must still run the command inside the runtime"
  assert_grep "--settings $(settings_file "$home")" "$log" "exec must hand the settings to the runtime"
  assert_grep "-c " "$log" "exec must hand the command to the runtime's -c form"
  pass "sandbox flag on: exec runs the command through the runtime with the configured settings"
}

test_enabled_unenforced_isolation_refuses() {
  local home srt out status marker
  home=$(new_home enabled-broken)
  enable_sandbox "$home"
  write_settings "$home"
  srt=$(install_broken_srt "$home")
  marker="$home/ran-marker"
  out=$(run_sandbox "$home" "$srt" prefix 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "prefix must refuse a runtime that enforces nothing, got: $out"
  assert_contains "$out" "unenforced isolation" "the refusal must name unenforced isolation"
  out=$(run_sandbox "$home" "$srt" exec -- /bin/sh -c "touch '$marker'" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "exec must refuse a runtime that enforces nothing, got: $out"
  assert_absent "$marker" "a refused sandbox must not run the command"
  pass "sandbox flag on with a runtime that enforces nothing: refused and nothing ran"
}

test_disabled_prefix_is_empty_and_silent
test_disabled_exec_passthrough_runs_without_the_runtime
test_enabled_missing_runtime_refuses_and_runs_nothing
test_enabled_wrong_version_refuses
test_enabled_missing_settings_refuses
test_enabled_empty_settings_refuses
test_enabled_invalid_settings_refuses
test_runtime_rejects_supplied_settings_for_every_consumer
test_masked_and_failed_denied_reads_both_preserve_readiness
test_enabled_probe_reports_ready_and_prefix_is_exact
test_enabled_exec_runs_the_command_through_the_runtime
test_enabled_unenforced_isolation_refuses
