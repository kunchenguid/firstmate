#!/usr/bin/env bash
# Focused behavior tests for Hermes detection and primary lock ownership.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
HOLDER_PIDS=()

cleanup() {
  local pid
  for pid in "${HOLDER_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

make_fake_ps() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "${2:-}" in
  comm=) printf '%s\n' "${FM_TEST_PS_COMM:-bash}" ;;
  args=) printf '%s\n' "${FM_TEST_PS_ARGS:-bash}" ;;
  ppid=) printf '%s\n' "${FM_TEST_PS_PPID:-1}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

start_holder() {
  sleep 300 &
  HOLDER_PID=$!
  HOLDER_PIDS+=("$HOLDER_PID")
}

write_marker() {
  local state=$1 pid=$2
  mkdir -p "$state"
  printf 'sha256:%064d\n%s\n%s\n' 0 "$pid" "$ROOT" > "$state/.hermes-primary-plugin-loaded"
}

run_detect() {
  local fakebin=$1 state=$2
  shift 2
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u HERMES_HOME \
    FM_STATE_OVERRIDE="$state" PATH="$fakebin:$BASE_PATH" "$@" "$ROOT/bin/fm-harness.sh"
}

test_hermes_identity_requires_loaded_plugin_marker() {
  local fakebin state out
  fakebin=$(make_fake_ps "$TMP_ROOT/identity")
  state="$TMP_ROOT/identity/state"
  mkdir -p "$state"

  out=$(run_detect "$fakebin" "$state" env HERMES_HOME="$TMP_ROOT/hermes-home")
  [ "$out" = unknown ] || fail "HERMES_HOME alone must not impersonate Hermes, got '$out'"

  out=$(run_detect "$fakebin" "$state" env FM_TEST_PS_COMM=hermes \
    FM_TEST_PS_ARGS='hermes --cli --no-restore-cwd' FM_TEST_PS_PPID=1)
  [ "$out" = unknown ] || fail "persistent argv without a loaded plugin marker must stay unknown, got '$out'"

  start_holder
  write_marker "$state" "$HOLDER_PID"
  out=$(run_detect "$fakebin" "$state" env FM_TEST_PS_COMM=python3 \
    FM_TEST_PS_ARGS='python3 worker.py "hermes --cli"' FM_TEST_PS_PPID="$HOLDER_PID")
  [ "$out" = hermes ] || fail "loaded Hermes marker and process ancestry were not detected, got '$out'"
  pass "Hermes detection requires the loaded plugin marker and its process ancestry"
}

test_hermes_identity_preserves_quoted_classic_arguments() {
  local fakebin state out
  fakebin=$(make_fake_ps "$TMP_ROOT/quoted")
  state="$TMP_ROOT/quoted/state"
  start_holder
  write_marker "$state" "$HOLDER_PID"

  out=$(run_detect "$fakebin" "$state" env FM_TEST_PS_COMM=hermes \
    FM_TEST_PS_ARGS='hermes --cli --no-restore-cwd --continue "Project Alpha"' \
    FM_TEST_PS_PPID="$HOLDER_PID")
  [ "$out" = hermes ] || fail "quoted classic-session arguments broke trusted Hermes detection, got '$out'"

  rm -f "$state/.hermes-primary-plugin-loaded"
  out=$(run_detect "$fakebin" "$state" env FM_TEST_PS_COMM=hermes \
    FM_TEST_PS_ARGS='hermes --cli --no-restore-cwd --continue "Project Alpha"' \
    FM_TEST_PS_PPID="$HOLDER_PID")
  [ "$out" = unknown ] || fail "quoted argv was trusted after its plugin marker was removed, got '$out'"
  pass "Hermes identity does not reconstruct quoted argv from ps output"
}

test_lock_accepts_only_marker_bound_primary() {
  local fakebin home out rc holder
  fakebin=$(make_fake_ps "$TMP_ROOT/lock")
  home="$TMP_ROOT/lock-home"
  mkdir -p "$home/state"
  start_holder
  holder=$HOLDER_PID
  write_marker "$home/state" "$holder"

  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_TEST_PS_COMM=hermes \
    FM_TEST_PS_ARGS='hermes --cli --no-restore-cwd' FM_TEST_PS_PPID="$holder" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh") || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lock rejected a marker-bound Hermes primary: $out"
  assert_contains "$out" "lock acquired: harness pid $holder" "Hermes primary acquired the wrong lock identity"

  rm -f "$home/state/.hermes-primary-plugin-loaded" "$home/state/.lock"
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_TEST_PS_COMM=hermes \
    FM_TEST_PS_ARGS='hermes --cli --no-restore-cwd' FM_TEST_PS_PPID="$holder" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lock accepted Hermes argv without the loaded plugin marker"

  printf '%s\n' "$holder" > "$home/state/.lock"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_TEST_PS_COMM=hermes \
    FM_TEST_PS_ARGS='hermes --cli --no-restore-cwd' FM_TEST_PS_PPID="$holder" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: stale" "markerless Hermes pid must not retain the primary lock"
  pass "primary lock ownership requires a marker-bound Hermes process"
}

test_hermes_identity_requires_loaded_plugin_marker
test_hermes_identity_preserves_quoted_classic_arguments
test_lock_accepts_only_marker_bound_primary

echo "# all fm-hermes-harness tests passed"
