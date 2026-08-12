#!/usr/bin/env bash
# macOS keep-awake process lifecycle regression with fake caffeinate and pmset.
#
# Covers idempotent start/status/stop, strict state publication, stale and
# reused PIDs, unsupported hosts, exact-only cleanup, identity-backed locking,
# and return-bound assertions. No test changes real power settings.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEEP_AWAKE="$ROOT/bin/fm-keep-awake.sh"
TMP_ROOT=$(fm_test_tmproot fm-keep-awake-tests)
PIDS_FILE="$TMP_ROOT/fake-pids"

cleanup() {
  local pid
  if [ -f "$PIDS_FILE" ]; then
    while IFS= read -r pid; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      kill -TERM "$pid" 2>/dev/null || true
    done < "$PIDS_FILE"
  fi
  fm_test_cleanup
}
trap cleanup EXIT

make_case() {  # <name>
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir/home/state" "$dir/fakebin"
  cat > "$dir/fakebin/caffeinate" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "${FAKE_KEEP_AWAKE_PIDS:?}"
printf '%s\n' "$*" >> "${FAKE_KEEP_AWAKE_LOG:?}"
trap 'exit 0' TERM
while :; do sleep 0.1; done
SH
  cat > "$dir/fakebin/pmset" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_PMSET_LOG:?}"
exit 99
SH
  chmod +x "$dir/fakebin/caffeinate" "$dir/fakebin/pmset"
  printf '%s\n' "$dir"
}

run_keep_awake() {  # <case-dir> <command...>
  local dir=$1
  shift
  FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    FM_KEEP_AWAKE_PLATFORM=Darwin \
    FM_KEEP_AWAKE_CAFFEINATE="$dir/fakebin/caffeinate" \
    FAKE_KEEP_AWAKE_LOG="$dir/caffeinate.log" \
    FAKE_KEEP_AWAKE_PIDS="$PIDS_FILE" \
    FAKE_PMSET_LOG="$dir/pmset.log" \
    PATH="$dir/fakebin:$PATH" \
    "$KEEP_AWAKE" "$@" 2>&1
}

run_keep_awake_as() {  # <case-dir> <platform> <tool> <command...>
  local dir=$1 platform=$2 tool=$3
  shift 3
  FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    FM_KEEP_AWAKE_PLATFORM="$platform" \
    FM_KEEP_AWAKE_CAFFEINATE="$tool" \
    FAKE_KEEP_AWAKE_LOG="$dir/caffeinate.log" \
    FAKE_KEEP_AWAKE_PIDS="$PIDS_FILE" \
    FAKE_PMSET_LOG="$dir/pmset.log" \
    PATH="$dir/fakebin:$PATH" \
    "$KEEP_AWAKE" "$@" 2>&1
}

record_pid() { awk -F= '$1 == "pid" { print $2; exit }' "$1/home/state/.keep-awake"; }

record_identity() {  # <case-dir> <pid>
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$pid"
}

write_record() {  # <case-dir> <pid> <identity> <tool> <mode>
  local dir=$1 pid=$2 identity=$3 tool=$4 mode=$5
  cat > "$dir/home/state/.keep-awake" <<EOF
schema=fm-keep-awake.v1
pid=$pid
identity=$identity
tool=$tool
mode=$mode
EOF
  chmod 600 "$dir/home/state/.keep-awake"
}

wait_pid_gone() {  # <pid>
  local pid=$1 attempt=0
  while [ "$attempt" -lt 60 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    attempt=$((attempt + 1))
    sleep 0.05
  done
  return 1
}

file_mode() {
  if [ "$(uname -s)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

test_start_status_stop_are_idempotent() {
  local dir out pid repeat_pid starts
  dir=$(make_case lifecycle)
  out=$(run_keep_awake "$dir" start) || fail "start failed: $out"
  assert_contains "$out" 'active (manual)' "start did not report an active manual assertion"
  pid=$(record_pid "$dir")
  kill -0 "$pid" 2>/dev/null || fail "start did not leave the managed fake process alive"
  [ "$(file_mode "$dir/home/state/.keep-awake")" = 600 ] || fail "identity record was not mode 0600"

  out=$(run_keep_awake "$dir" start) || fail "idempotent start failed: $out"
  repeat_pid=$(record_pid "$dir")
  [ "$repeat_pid" = "$pid" ] || fail "idempotent start replaced the managed process"
  starts=$(wc -l < "$dir/caffeinate.log" | tr -d ' ')
  [ "$starts" = 1 ] || fail "idempotent start invoked caffeinate $starts times"

  out=$(run_keep_awake "$dir" status) || fail "status failed: $out"
  assert_contains "$out" 'active (manual)' "status did not report the existing assertion"
  [ ! -e "$dir/pmset.log" ] || fail "managed lifecycle invoked pmset instead of owning the process directly"

  out=$(run_keep_awake "$dir" stop) || fail "stop failed: $out"
  assert_contains "$out" 'stopped' "stop did not report exact managed cleanup"
  [ ! -e "$dir/home/state/.keep-awake" ] || fail "stop left its identity record behind"
  wait_pid_gone "$pid" || fail "stop left its managed fake process alive"

  out=$(run_keep_awake "$dir" stop) || fail "idempotent stop failed: $out"
  assert_contains "$out" inactive "idempotent stop did not converge to inactive"
  pass "keep-awake start, status, and stop are idempotent without pmset"
}

test_stale_and_reused_pids_are_never_signalled() {
  local dir out reused dead_pid=999999
  dir=$(make_case stale)
  sleep 30 &
  reused=$!
  printf '%s\n' "$reused" >> "$PIDS_FILE"
  write_record "$dir" "$reused" 'deliberately-stale-identity' "$dir/fakebin/caffeinate" manual
  out=$(run_keep_awake "$dir" stop) || fail "stale reused-PID stop failed: $out"
  assert_contains "$out" 'stale record cleared' "reused PID was not classified as stale"
  [ ! -e "$dir/home/state/.keep-awake" ] || fail "reused PID left its stale record behind"
  kill -0 "$reused" 2>/dev/null || fail "stop signalled an unrelated reused PID"

  write_record "$dir" "$dead_pid" 'dead-identity' "$dir/fakebin/caffeinate" manual
  out=$(run_keep_awake "$dir" status) || fail "dead stale-record status failed: $out"
  assert_contains "$out" 'stale record cleared' "dead stale record was not recovered"
  [ ! -e "$dir/home/state/.keep-awake" ] || fail "status retained a dead stale record"
  pass "stale and reused PIDs lose only their record"
}

test_unsupported_and_missing_caffeinate_do_not_start() {
  local dir out rc
  dir=$(make_case unsupported)
  set +e
  out=$(run_keep_awake_as "$dir" Linux "$dir/fakebin/caffeinate" start)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "non-macOS start should be unavailable (rc=$rc): $out"
  assert_contains "$out" 'macOS is required' "non-macOS refusal did not explain the limit"
  [ ! -e "$dir/home/state/.keep-awake" ] || fail "non-macOS start wrote a state record"
  [ ! -e "$dir/caffeinate.log" ] || fail "non-macOS start launched fake caffeinate"

  set +e
  out=$(run_keep_awake_as "$dir" Darwin "$dir/missing-caffeinate" start)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "missing caffeinate should be unavailable (rc=$rc): $out"
  assert_contains "$out" unavailable "missing-caffeinate refusal was not actionable"
  [ ! -e "$dir/home/state/.keep-awake" ] || fail "missing caffeinate start wrote a state record"
  pass "unsupported hosts and missing caffeinate stop safely before launch"
}

test_unsafe_record_is_retained_without_signalling() {
  local dir out pid rc
  dir=$(make_case restrictive)
  run_keep_awake "$dir" start >/dev/null || fail "fixture start failed"
  pid=$(record_pid "$dir")
  chmod 644 "$dir/home/state/.keep-awake"
  set +e
  out=$(run_keep_awake "$dir" status)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "nonprivate record was accepted"
  assert_contains "$out" 'unsafe managed-process record' "unsafe-record refusal was unclear"
  [ -e "$dir/home/state/.keep-awake" ] || fail "unsafe record was silently removed"
  kill -0 "$pid" 2>/dev/null || fail "unsafe-record inspection signalled the process"
  chmod 600 "$dir/home/state/.keep-awake"
  ln "$dir/home/state/.keep-awake" "$dir/record-alias"
  set +e
  out=$(run_keep_awake "$dir" status)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "hard-linked record was accepted"
  assert_contains "$out" 'unsafe managed-process record' "hard-linked record refusal was unclear"
  kill -0 "$pid" 2>/dev/null || fail "hard-linked record inspection signalled the process"
  rm -f "$dir/record-alias"
  run_keep_awake "$dir" stop >/dev/null || fail "cleanup after restoring the private record failed"
  pass "only a restrictive private identity record authorizes lifecycle changes"
}

test_exact_cleanup_preserves_unrelated_caffeinate() {
  local dir out owned unrelated
  dir=$(make_case exact-cleanup)
  run_keep_awake "$dir" start >/dev/null || fail "fixture start failed"
  owned=$(record_pid "$dir")
  FAKE_KEEP_AWAKE_LOG="$dir/caffeinate.log" FAKE_KEEP_AWAKE_PIDS="$PIDS_FILE" \
    "$dir/fakebin/caffeinate" -i &
  unrelated=$!
  sleep 0.2
  kill -0 "$unrelated" 2>/dev/null || fail "unrelated fake caffeinate did not start"

  out=$(run_keep_awake "$dir" stop) || fail "exact stop failed: $out"
  [ ! -e "$dir/home/state/.keep-awake" ] || fail "exact stop left the record behind"
  wait_pid_gone "$owned" || fail "exact stop left its own process alive"
  kill -0 "$unrelated" 2>/dev/null || fail "exact stop broadly killed an unrelated caffeinate process"
  kill -TERM "$unrelated" 2>/dev/null || true
  pass "stop cleans only the recorded identity-matched process"
}

test_lock_requires_live_owner_identity() {
  local dir out identity rc
  dir=$(make_case lock-identity)
  mkdir "$dir/home/state/.keep-awake.lock"
  identity=$(record_identity "$dir" "$$") || fail "could not identify lock-owning test process"
  printf '%s\n' "$$" > "$dir/home/state/.keep-awake.lock/pid"
  printf '%s\n' "$identity" > "$dir/home/state/.keep-awake.lock/pid-identity"
  chmod 600 "$dir/home/state/.keep-awake.lock/"*
  set +e
  out=$(run_keep_awake "$dir" status)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "identity-matched live lock was reclaimed"
  assert_contains "$out" 'identity-matched lock' "live-lock refusal did not name its identity boundary"
  [ -d "$dir/home/state/.keep-awake.lock" ] || fail "live lock was removed"

  printf '%s\n' stale-identity > "$dir/home/state/.keep-awake.lock/pid-identity"
  out=$(run_keep_awake "$dir" status) || fail "stale lock identity was not reclaimed: $out"
  assert_contains "$out" inactive "status did not proceed after stale lock reclamation"
  [ ! -e "$dir/home/state/.keep-awake.lock" ] || fail "stale lock remained after successful status"
  pass "keep-awake lock ownership requires the live process identity"
}

test_return_bound_assertion_stops_without_stopping_manual_mode() {
  local dir out return_pid manual_pid
  dir=$(make_case return-bound)
  run_keep_awake "$dir" start --until-return >/dev/null || fail "return-bound start failed"
  return_pid=$(record_pid "$dir")
  out=$(run_keep_awake "$dir" stop-return-bound) || fail "return-bound stop failed: $out"
  assert_contains "$out" stopped "return-bound stop did not stop the assertion"
  wait_pid_gone "$return_pid" || fail "return-bound assertion remained alive"

  run_keep_awake "$dir" start >/dev/null || fail "manual start failed"
  manual_pid=$(record_pid "$dir")
  out=$(run_keep_awake "$dir" stop-return-bound) || fail "manual return-bound check failed: $out"
  assert_contains "$out" 'return does not stop it' "return cleanup did not preserve a manual assertion"
  kill -0 "$manual_pid" 2>/dev/null || fail "return cleanup stopped a manual assertion"
  run_keep_awake "$dir" stop >/dev/null || fail "manual cleanup failed"
  pass "return-bound cleanup stops only assertions explicitly bound to return"
}

test_start_status_stop_are_idempotent
test_stale_and_reused_pids_are_never_signalled
test_unsupported_and_missing_caffeinate_do_not_start
test_unsafe_record_is_retained_without_signalling
test_exact_cleanup_preserves_unrelated_caffeinate
test_lock_requires_live_owner_identity
test_return_bound_assertion_stops_without_stopping_manual_mode
