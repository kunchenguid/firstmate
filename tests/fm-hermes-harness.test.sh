#!/usr/bin/env bash
# Focused behavior tests for Hermes detection and primary lock ownership.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-process-identity-lib.sh
. "$ROOT/bin/fm-process-identity-lib.sh"
# shellcheck source=bin/fm-adapter-marker-lib.sh
. "$ROOT/bin/fm-adapter-marker-lib.sh"

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

make_identity_root() {
  local root=$1
  mkdir -p "$root/.hermes/plugins/firstmate-primary" "$root/state"
  cp "$ROOT/.hermes/plugins/firstmate-primary/__init__.py" \
    "$root/.hermes/plugins/firstmate-primary/__init__.py"
}

start_holder() {
  sleep 300 &
  HOLDER_PID=$!
  HOLDER_PIDS+=("$HOLDER_PID")
}

write_marker() {
  local root=$1 pid=$2 identity version
  identity=$(fm_pid_identity "$pid") || fail "could not read holder process identity"
  version=$(fm_adapter_file_version "$root/.hermes/plugins/firstmate-primary/__init__.py") \
    || fail "could not hash fixture plugin"
  printf '%s\n%s\n%s\n%s\n' "$version" "$pid" "$root" "$identity" \
    > "$root/state/.hermes-primary-plugin-loaded"
}

run_detect() {
  local fakebin=$1 root=$2
  shift 2
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u HERMES_HOME \
    FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$TMP_ROOT/ignored-state" \
    PATH="$fakebin:$BASE_PATH" "$@" "$ROOT/bin/fm-harness.sh"
}

test_hermes_identity_requires_loaded_plugin_marker() {
  local fakebin fixture out
  fakebin=$(make_fake_ps "$TMP_ROOT/identity")
  fixture="$TMP_ROOT/identity/root"
  make_identity_root "$fixture"

  out=$(run_detect "$fakebin" "$fixture" env HERMES_HOME="$TMP_ROOT/hermes-home")
  [ "$out" = unknown ] || fail "HERMES_HOME alone must not impersonate Hermes, got '$out'"

  out=$(run_detect "$fakebin" "$fixture" env FM_TEST_PS_COMM=hermes \
    FM_TEST_PS_ARGS='hermes --cli --no-restore-cwd' FM_TEST_PS_PPID=1)
  [ "$out" = unknown ] || fail "persistent argv without a loaded plugin marker must stay unknown, got '$out'"

  start_holder
  write_marker "$fixture" "$HOLDER_PID"
  out=$(run_detect "$fakebin" "$fixture" env FM_TEST_PS_COMM=python3 \
    FM_TEST_PS_ARGS='python3 worker.py "hermes --cli"' FM_TEST_PS_PPID="$HOLDER_PID")
  [ "$out" = hermes ] || fail "loaded Hermes marker and process ancestry were not detected, got '$out'"
  pass "Hermes detection requires the exact loaded plugin marker and process incarnation"
}

test_hermes_identity_rejects_stale_incarnation_and_build() {
  local fakebin fixture marker out version
  fakebin=$(make_fake_ps "$TMP_ROOT/stale")
  fixture="$TMP_ROOT/stale/root"
  make_identity_root "$fixture"
  start_holder
  write_marker "$fixture" "$HOLDER_PID"
  marker="$fixture/state/.hermes-primary-plugin-loaded"

  awk 'NR == 4 {$0 = "linux-starttime=1 cmdline-hex=00"} {print}' "$marker" > "$marker.tmp"
  mv "$marker.tmp" "$marker"
  out=$(run_detect "$fakebin" "$fixture" env FM_TEST_PS_COMM=hermes FM_TEST_PS_PPID="$HOLDER_PID")
  [ "$out" = unknown ] || fail "stale process-incarnation identity retained Hermes trust"

  write_marker "$fixture" "$HOLDER_PID"
  version=$(sed -n '1p' "$marker")
  printf '%s-x\n' "$version" > "$marker.tmp"
  sed -n '2,$p' "$marker" >> "$marker.tmp"
  mv "$marker.tmp" "$marker"
  out=$(run_detect "$fakebin" "$fixture" env FM_TEST_PS_COMM=hermes FM_TEST_PS_PPID="$HOLDER_PID")
  [ "$out" = unknown ] || fail "a marker for a different plugin build retained Hermes trust"
  pass "Hermes identity rejects stale process incarnations and plugin builds"
}

test_lock_accepts_only_marker_bound_primary() {
  local fakebin fixture home out rc holder
  fakebin=$(make_fake_ps "$TMP_ROOT/lock")
  fixture="$TMP_ROOT/lock/root"
  home="$TMP_ROOT/lock/home"
  make_identity_root "$fixture"
  mkdir -p "$home/state"
  start_holder
  holder=$HOLDER_PID
  write_marker "$fixture" "$holder"

  rc=0
  out=$(FM_ROOT_OVERRIDE="$fixture" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_TEST_PS_COMM=hermes FM_TEST_PS_PPID="$holder" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-lock.sh") || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lock rejected a marker-bound Hermes primary: $out"
  assert_contains "$out" "lock acquired: harness pid $holder" "Hermes primary acquired the wrong lock identity"

  rm -f "$fixture/state/.hermes-primary-plugin-loaded" "$home/state/.lock"
  rc=0
  out=$(FM_ROOT_OVERRIDE="$fixture" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_TEST_PS_COMM=hermes FM_TEST_PS_PPID="$holder" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-lock.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lock accepted Hermes argv without the loaded plugin marker"
  pass "primary lock ownership requires a current marker-bound Hermes process"
}

test_hermes_identity_requires_loaded_plugin_marker
test_hermes_identity_rejects_stale_incarnation_and_build
test_lock_accepts_only_marker_bound_primary

echo "# all fm-hermes-harness tests passed"
