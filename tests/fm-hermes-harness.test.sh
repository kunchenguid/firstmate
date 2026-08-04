#!/usr/bin/env bash
# Focused behavior tests for Hermes detection and primary lock ownership.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

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

run_detect() {
  local fakebin=$1
  shift
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u HERMES_HOME \
    PATH="$fakebin:$BASE_PATH" "$@" "$ROOT/bin/fm-harness.sh"
}

test_hermes_identity_requires_the_executable() {
  local fakebin out
  fakebin=$(make_fake_ps "$TMP_ROOT/identity")

  out=$(run_detect "$fakebin" env HERMES_HOME="$TMP_ROOT/hermes-home")
  [ "$out" = unknown ] || fail "HERMES_HOME alone must not impersonate Hermes, got '$out'"

  out=$(run_detect "$fakebin" env FM_TEST_PS_COMM=python3 \
    FM_TEST_PS_ARGS="python3 worker.py 'write about hermes'" FM_TEST_PS_PPID=1)
  [ "$out" = unknown ] || fail "an unrelated Python prompt mentioning Hermes must stay unknown, got '$out'"

  out=$(run_detect "$fakebin" env FM_TEST_PS_COMM=python3 \
    FM_TEST_PS_ARGS="python3 worker.py /opt/hermes" FM_TEST_PS_PPID=1)
  [ "$out" = unknown ] || fail "a prompt path ending in /hermes must stay unknown, got '$out'"
  pass "Hermes detection rejects home markers and unrelated Python prompt text"
}

test_hermes_process_shapes() {
  local fakebin out
  fakebin=$(make_fake_ps "$TMP_ROOT/shapes")

  out=$(run_detect "$fakebin" env FM_TEST_PS_COMM=hermes \
    FM_TEST_PS_ARGS='hermes --cli')
  [ "$out" = hermes ] || fail "persistent Hermes CLI was not detected, got '$out'"

  out=$(run_detect "$fakebin" env FM_TEST_PS_COMM=hermes \
    FM_TEST_PS_ARGS='hermes -p firstmate --tui')
  [ "$out" = hermes ] || fail "the normal Firstmate Hermes TUI was not detected, got '$out'"

  out=$(run_detect "$fakebin" env FM_TEST_PS_COMM=python3 \
    FM_TEST_PS_ARGS='/opt/hermes-agent/venv/bin/python3 /opt/hermes-agent/venv/bin/hermes -p firstmate --tui')
  [ "$out" = hermes ] || fail "the Hermes interpreter launch was not detected, got '$out'"

  out=$(run_detect "$fakebin" env FM_TEST_PS_COMM=hermes \
    FM_TEST_PS_ARGS='hermes -z prompt')
  [ "$out" = unknown ] || fail "one-shot Hermes workers must stay out of primary detection, got '$out'"

  out=$(PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$0/bin/fm-harness-process-lib.sh"; if fm_process_is_hermes_primary "$1"; then printf primary; fi' \
    "$ROOT" 'hermes -z prompt' 2>/dev/null) || true
  [ "$out" != primary ] || fail "one-shot Hermes must not satisfy the primary predicate"

  out=$(PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$0/bin/fm-harness-process-lib.sh"; fm_process_is_hermes_primary "$1"; printf primary' \
    "$ROOT" 'hermes --cli')
  [ "$out" = primary ] || fail "persistent Hermes CLI did not satisfy the primary predicate"

  out=$(PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$0/bin/fm-harness-process-lib.sh"; fm_process_is_hermes_primary "$1"; printf primary' \
    "$ROOT" 'hermes -p firstmate --tui')
  [ "$out" = primary ] || fail "the normal Firstmate Hermes TUI did not satisfy the primary predicate"

  out=$(PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$0/bin/fm-harness-process-lib.sh"; if fm_process_is_hermes_primary "$1"; then printf primary; fi' \
    "$ROOT" 'hermes -p unrelated --tui' 2>/dev/null) || true
  [ "$out" != primary ] || fail "an unrelated Hermes profile must not satisfy the primary predicate"
  pass "Hermes detection distinguishes persistent CLI and one-shot worker argv"
}

test_lock_accepts_primary_and_rejects_worker_or_prompt() {
  local fakebin home out rc=0
  fakebin=$(make_fake_ps "$TMP_ROOT/lock")
  home="$TMP_ROOT/lock-home"
  mkdir -p "$home/state"

  out=$(FM_HOME="$home" FM_TEST_PS_COMM=hermes \
    FM_TEST_PS_ARGS='hermes --cli' PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-lock.sh") || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lock rejected a persistent Hermes primary: $out"
  assert_contains "$out" "lock acquired: harness pid" "Hermes primary did not acquire the lock"

  rm -f "$home/state/.lock"
  out=$(FM_HOME="$home" FM_TEST_PS_COMM=hermes \
    FM_TEST_PS_ARGS='hermes -p firstmate --tui' PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-lock.sh") || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lock rejected the normal Firstmate Hermes TUI: $out"

  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" FM_TEST_PS_COMM=hermes FM_TEST_PS_ARGS='hermes -z prompt' \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: stale" "one-shot Hermes must not own the primary lock"

  out=$(FM_HOME="$home" FM_TEST_PS_COMM=python3 \
    FM_TEST_PS_ARGS="python3 worker.py 'hermes --cli'" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: stale" "unrelated Python prompt text must not own the lock"
  pass "primary lock ownership accepts only persistent Hermes"
}

test_hermes_identity_requires_the_executable
test_hermes_process_shapes
test_lock_accepts_primary_and_rejects_worker_or_prompt

echo "# all fm-hermes-harness tests passed"
