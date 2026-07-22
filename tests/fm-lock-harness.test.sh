#!/usr/bin/env bash
# Behavior tests for session-lock holder detection (bin/fm-lock.sh).
# Lock identity may recognize a primary harness before that harness is a
# verified spawn/crew adapter - hermes is the first such case.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-harness)

# Write a fake `ps` that always reports the given comm/args for every pid query.
make_ps_shim() {
  local fakebin=$1 comm=$2 args=$3
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"comm="*) printf '%s\\n' '$comm'; exit 0 ;;
  *"args="*) printf '%s\\n' '$args'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

assert_status_held() {
  local name=$1 comm=$2 args=$3 home fakebin out
  home="$TMP_ROOT/$name-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/$name-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  make_ps_shim "$fakebin" "$comm" "$args"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" \
    "fm-lock status did not treat $name ($comm) as a live harness holder"
  pass "fm-lock status recognizes $name holder"
}

assert_acquire_ok() {
  local name=$1 comm=$2 args=$3 home fakebin out status
  home="$TMP_ROOT/$name-acq-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/$name-acq-fake")
  mkdir -p "$home/state"
  make_ps_shim "$fakebin" "$comm" "$args"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "fm-lock acquire should succeed for $name primary"
  assert_contains "$out" "lock acquired: harness pid" \
    "fm-lock acquire did not report success for $name"
  pass "fm-lock acquire works under $name"
}

# Hermes primary: process name is the CLI entrypoint (python -m / venv bin).
assert_status_held hermes-bin hermes \
  '/home/iqbal/.hermes/hermes-agent/venv/bin/python3 /home/iqbal/.hermes/hermes-agent/venv/bin/hermes'
assert_acquire_ok hermes-bin hermes \
  '/home/iqbal/.hermes/hermes-agent/venv/bin/python3 /home/iqbal/.hermes/hermes-agent/venv/bin/hermes'

# Hermes under a bare interpreter name (comm=python3, path still contains hermes).
assert_status_held hermes-python python3 \
  '/home/iqbal/.hermes/hermes-agent/venv/bin/python3 /home/iqbal/.hermes/hermes-agent/venv/bin/hermes'
assert_acquire_ok hermes-python python3 \
  '/home/iqbal/.hermes/hermes-agent/venv/bin/python3 /home/iqbal/.hermes/hermes-agent/venv/bin/hermes'

# Regression: already-verified lock holders still match.
assert_status_held grok-bin grok 'grok'
assert_status_held claude-bin claude 'claude'
