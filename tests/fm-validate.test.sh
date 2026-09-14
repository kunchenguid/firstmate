#!/usr/bin/env bash
# tests/fm-validate.test.sh - the host-wide validation slot.
#
# Drives bin/fm-validate.sh through its executable interface only. `free` and
# `pgrep` are shimmed on PATH so the memory and duplicate-compiler branches can
# be driven deterministically on any host; the lock, the exit-code passthrough
# and the nesting guard are exercised for real. Linux additionally exercises
# real process ancestry and argument classification without shimming pgrep.

set -uo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VALIDATE="$ROOT/bin/fm-validate.sh"
TMP_ROOT=$(fm_test_tmproot fm-validate) || fail "could not create temp root"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOCK="$TMP_ROOT/validation.lock"

# fake_free <available-mb>: shim `free -m` so the preflight reads a chosen
# amount of AVAILABLE memory (column 7 of the Mem: row).
fake_free() {
  cat > "$FAKEBIN/free" <<SH
#!/usr/bin/env bash
cat <<'OUT'
               total        used        free      shared  buff/cache   available
Mem:            5800        4000         200          10        1600        $1
Swap:              0           0           0
OUT
SH
  chmod +x "$FAKEBIN/free"
}

# fake_pgrep <output>: shim pgrep so the duplicate-compiler check sees exactly
# the given lines. Empty means nothing is running.
fake_pgrep() {
  cat > "$FAKEBIN/pgrep" <<SH
#!/usr/bin/env bash
printf '%s' "\${FM_TEST_PGREP_OUT:-}"
exit 0
SH
  chmod +x "$FAKEBIN/pgrep"
  export FM_TEST_PGREP_OUT="$1"
}

# Every case controls its own environment. FM_VALIDATE_ACTIVE in particular must
# be cleared: this suite is itself run inside the validation slot, so inheriting
# it would silently put every case on the nested passthrough and quietly vacate
# the resource assertions rather than failing them.
run_validate() {
  env -u FM_VALIDATE_ACTIVE -u FM_VALIDATE_CAPTAIN_APPROVED \
    PATH="$FAKEBIN:$PATH" FM_VALIDATE_LOCK="$LOCK" "$VALIDATE" "$@" 2>&1
}

fake_free 4096
fake_pgrep ''

# --- usage ------------------------------------------------------------------

out=$(run_validate --help)
expect_code 0 $? "--help must exit 0"
assert_contains "$out" "host-wide validation slot" "--help must describe the slot"

out=$(run_validate)
expect_code 64 $? "no command must be a usage error"

out=$(run_validate --label)
expect_code 64 $? "--label without a value must be a usage error"

out=$(run_validate --nonsense -- true)
expect_code 64 $? "an unknown flag must be a usage error"

pass "usage errors are refused with the usage code"

# --- explicit-approval-only commands ----------------------------------------

for banned in "npm run ci:gates:static" "npm run gate:orphan-tables" \
  "node scripts/gates/check-orphan-tables.mjs"; do
  # Deliberately unquoted: $banned is a command line that must reach the script
  # split into separate arguments, exactly as a caller would type it.
  # shellcheck disable=SC2086
  out=$(run_validate -- $banned)
  expect_code 70 $? "'$banned' must be refused without captain approval"
  assert_contains "$out" "captain's explicit approval" \
    "the refusal must name the approval requirement for '$banned'"
done

# The refusal must fire before anything runs: a banned command that would have
# created a marker must not have created it.
marker="$TMP_ROOT/banned-ran"
out=$(run_validate -- sh -c "echo ci:gates:static >/dev/null; touch '$marker'")
expect_code 70 $? "a banned string anywhere in the command line must be refused"
assert_absent "$marker" "a refused command must not have executed"

pass "explicit-approval-only commands are refused before they run"

out=$(env -u FM_VALIDATE_ACTIVE FM_VALIDATE_CAPTAIN_APPROVED=1 PATH="$FAKEBIN:$PATH" \
  FM_VALIDATE_LOCK="$LOCK" "$VALIDATE" -- sh -c 'echo ran-ci:gates:static' 2>&1)
expect_code 0 $? "captain approval must permit the heavy command"
assert_contains "$out" "ran-ci:gates:static" "the approved command must actually run"
assert_contains "$out" "captain-approved heavy command" \
  "an approved heavy run must still announce itself"

pass "captain approval is the documented escape hatch and is loud"

# --- memory preflight -------------------------------------------------------

fake_free 400
out=$(run_validate -- true)
expect_code 71 $? "emergency memory must refuse"
assert_contains "$out" "emergency memory pressure" "the emergency band must be named"

fake_free 900
out=$(run_validate -- true)
expect_code 71 $? "sub-1024 MiB must refuse"
assert_contains "$out" "resource pressure" "the pressure band must be named"

fake_free 1400
out=$(run_validate -- true)
expect_code 71 $? "sub-floor memory must refuse"
assert_contains "$out" "1536 MiB is the floor" "the refusal must name the floor"

fake_free 1700
out=$(run_validate -- true)
expect_code 0 $? "the 1536-2048 band must run"
assert_contains "$out" "essential targeted validation only" \
  "the tight band must warn rather than proceed silently"

fake_free 4096
out=$(run_validate -- true)
expect_code 0 $? "comfortable memory must run"
assert_not_contains "$out" "essential targeted validation only" \
  "comfortable memory must not print the tight-band warning"

pass "the captain's four memory bands are enforced, not described"

# An unreadable reading must not block every validation on this host.
cat > "$FAKEBIN/free" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN/free"
out=$(run_validate -- true)
expect_code 0 $? "an unreadable memory reading must not block validation"
assert_contains "$out" "could not be read" "an unknown reading must be stated, not hidden"
fake_free 4096

pass "an unreadable memory reading degrades to the slot alone, and says so"

# --- a compiler is already working ------------------------------------------

fake_pgrep '99001 node /x/tsc --noEmit'
marker="$TMP_ROOT/busy-ran"
out=$(run_validate -- touch "$marker")
expect_code 72 $? "a running compiler must refuse a second one"
assert_contains "$out" "already running" "the refusal must say what is running"
assert_contains "$out" "99001" "the refusal must name the pid so the operator can act"
assert_contains "$out" "Nothing was killed" \
  "the refusal must state that no process was killed"
assert_absent "$marker" "a refused run must not have executed the command"
fake_pgrep ''

pass "a busy compiler blocks a second one and is never killed"

# --- real process argument boundaries ---------------------------------------
# Keep search phrases out of launch argv: construct the compiler invocation at
# runtime, including for the shell-source regression. No compiler workload is
# needed to prove classification; the executable fixture stays alive on a FIFO.
if [ -r /proc/self/cmdline ]; then
  compiler=tsc
  compiler_flag=--noEmit
  real_pgrep=$(command -v pgrep)
  rm "$FAKEBIN/pgrep"
  marker="$TMP_ROOT/parent-ran"
  cat > "$FAKEBIN/$compiler" <<'SH'
#!/usr/bin/env bash
touch "$FM_TEST_MARKER"
SH
  chmod +x "$FAKEBIN/$compiler"
  # shellcheck disable=SC2016 # The invoking shell must capture its own status.
  printf -v invocation '%q -- %q %s; result=$?; exit "$result"' \
    "$VALIDATE" "$FAKEBIN/$compiler" "$compiler_flag"
  out=$(env -u FM_VALIDATE_ACTIVE PATH="$FAKEBIN:$PATH" FM_VALIDATE_LOCK="$LOCK" \
    FM_TEST_MARKER="$marker" bash -c "$invocation" 2>&1)
  code=$?
  [ "$code" -eq 0 ] || printf '%s\n' "$out" >&2
  expect_code 0 "$code" "an invoking shell carrying compiler text must run"
  assert_present "$marker" "the wrapped command must actually execute"

  # Two intermediate shells prove the ancestor filter is not fixed-depth.
  # shellcheck disable=SC2016 # Keep the outer shell alive until its child exits.
  printf -v invocation 'bash -c %q; result=$?; exit "$result"' "$invocation"
  out=$(env -u FM_VALIDATE_ACTIVE PATH="$FAKEBIN:$PATH" FM_VALIDATE_LOCK="$LOCK" \
    FM_TEST_MARKER="$marker" bash -c "$invocation" 2>&1)
  expect_code 0 $? "nested invoking shells must not block validation"
  pass "real invoking shells and wrapper subshells do not refuse or kill themselves"

  fixture_pid=
  cleanup_process() {
    if [ -n "$fixture_pid" ]; then
      kill "$fixture_pid" 2>/dev/null || true
      wait "$fixture_pid" 2>/dev/null || true
    fi
    fm_test_cleanup
  }
  trap cleanup_process EXIT
  mkfifo "$TMP_ROOT/process-fifo"
  # Opening both ends avoids a helper process and keeps cleanup limited to one
  # owned PID. read has a timeout even if the suite is interrupted.
  printf -v waiter 'exec 8<>%q; printf ready >%q; read -r -t 30 -u 8; : %s %s' \
    "$TMP_ROOT/process-fifo" "$TMP_ROOT/ready" "$compiler" "$compiler_flag"
  bash -c "$waiter" &
  fixture_pid=$!
  for ((attempt=0; attempt<100; attempt++)); do
    [ -f "$TMP_ROOT/ready" ] && break
    sleep 0.1
  done
  assert_present "$TMP_ROOT/ready" "waiter must start before inspection"
  matches=$("$real_pgrep" -af "$compiler $compiler_flag")
  assert_contains "$matches" "$fixture_pid" "the broad matcher must see the real waiter"
  out=$(run_validate -- true)
  expect_code 0 $? "a waiter mentioning a compiler must not block"
  kill -0 "$fixture_pid" || fail "cleanup must not kill the unrelated waiter"
  kill "$fixture_pid"
  wait "$fixture_pid" 2>/dev/null || true
  fixture_pid=
  rm "$TMP_ROOT/ready"
  pass "an unrelated live waiter is ignored and survives validation cleanup"

  cat > "$FAKEBIN/$compiler" <<'SH'
#!/usr/bin/env bash
exec 8<>"$FM_TEST_FIFO"
printf ready > "$FM_TEST_READY"
read -r -t 30 -u 8
SH
  chmod +x "$FAKEBIN/$compiler"
  FM_TEST_FIFO="$TMP_ROOT/process-fifo" FM_TEST_READY="$TMP_ROOT/ready" \
    "$FAKEBIN/$compiler" "$compiler_flag" &
  fixture_pid=$!
  for ((attempt=0; attempt<100; attempt++)); do
    [ -f "$TMP_ROOT/ready" ] && break
    sleep 0.1
  done
  assert_present "$TMP_ROOT/ready" "compiler fixture must start before inspection"
  out=$(run_validate -- touch "$TMP_ROOT/external-ran")
  expect_code 72 $? "an external compiler executable must still refuse"
  assert_contains "$out" "$fixture_pid" "refusal must identify the external compiler"
  assert_absent "$TMP_ROOT/external-ran" "busy refusal must prevent execution"
  kill -0 "$fixture_pid" || fail "refusal must leave the compiler alive"
  kill "$fixture_pid"
  wait "$fixture_pid" 2>/dev/null || true
  fixture_pid=
  pass "a real external compiler-shaped process still refuses without being killed"

  # Optional real tool proof supplements the dependency-free process fixture.
  # A tiny watch program holds one compiler alive without a project-wide build.
  typescript_bin=${FM_TEST_TYPESCRIPT_BIN:-$(command -v tsc || true)}
  if [ -n "$typescript_bin" ]; then
    printf '%s\n' '{"compilerOptions":{"noLib":true},"files":["empty.ts"]}' \
      > "$TMP_ROOT/tsconfig.json"
    touch "$TMP_ROOT/empty.ts"
    "$typescript_bin" "$compiler_flag" --watch -p "$TMP_ROOT/tsconfig.json" \
      > "$TMP_ROOT/compiler-output" 2>&1 &
    fixture_pid=$!
    for ((attempt=0; attempt<100; attempt++)); do
      [ -s "$TMP_ROOT/compiler-output" ] && break
      sleep 0.1
    done
    kill -0 "$fixture_pid" || fail "real TypeScript compiler must remain running"
    out=$(run_validate -- touch "$TMP_ROOT/real-compiler-ran")
    expect_code 72 $? "a real external TypeScript compiler must refuse"
    assert_contains "$out" "$fixture_pid" "refusal must name the real compiler"
    assert_absent "$TMP_ROOT/real-compiler-ran" "real compiler must prevent execution"
    kill "$fixture_pid"
    wait "$fixture_pid" 2>/dev/null || true
    fixture_pid=
    pass "a real TypeScript compiler outside the wrapper still refuses"
  else
    pass "skip: real TypeScript unavailable; set FM_TEST_TYPESCRIPT_BIN to exercise it"
  fi
  fake_pgrep ''
else
  pass "skip: procfs unavailable; non-ancestor candidates conservatively refuse"
fi

# Failed discovery cannot silently become a clear preflight.
cat > "$FAKEBIN/pgrep" <<'SH'
#!/usr/bin/env bash
exit 2
SH
out=$(run_validate --check -- true)
expect_code 72 $? "an unavailable process scan must refuse"
assert_contains "$out" "scan failed" "the operator must see why inspection failed"
fake_pgrep ''
pass "process scan errors fail closed"

# --- the slot is exclusive --------------------------------------------------

flock -x "$LOCK" sleep 5 &
holder=$!
sleep 0.3
out=$(env -u FM_VALIDATE_ACTIVE PATH="$FAKEBIN:$PATH" FM_VALIDATE_LOCK="$LOCK" \
  FM_VALIDATE_LOCK_TIMEOUT=1 "$VALIDATE" -- touch "$TMP_ROOT/slot-ran" 2>&1)
code=$?
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
expect_code 73 "$code" "a held slot must refuse rather than overlap"
assert_contains "$out" "host-wide slot" "the refusal must name the slot"
assert_absent "$TMP_ROOT/slot-ran" "a run refused on the slot must not have executed"

pass "a second validation waits for the slot and refuses rather than overlapping"

# --- exit-code passthrough --------------------------------------------------

run_validate -- sh -c 'exit 7' >/dev/null
expect_code 7 $? "the command's own exit code must pass through unchanged"

run_validate -- sh -c 'exit 0' >/dev/null
expect_code 0 $? "success must pass through as success"

pass "the wrapped command's exit code is passed through, not rewritten"

# --- turbo fan-out is pinned ------------------------------------------------

# Single quotes are required on both lines below: the variable must be expanded
# by the inner shell the slot starts, not by this test shell, which is the whole
# point of the assertion.
# shellcheck disable=SC2016
out=$(run_validate -- sh -c 'printf "TC=%s\n" "$TURBO_CONCURRENCY"')
assert_contains "$out" "TC=1" "TURBO_CONCURRENCY must be pinned to 1 inside the command"

# shellcheck disable=SC2016
out=$(env -u FM_VALIDATE_ACTIVE PATH="$FAKEBIN:$PATH" FM_VALIDATE_LOCK="$LOCK" \
  FM_VALIDATE_TURBO_CONCURRENCY=3 "$VALIDATE" -- sh -c 'printf "TC=%s\n" "$TURBO_CONCURRENCY"' 2>&1)
assert_contains "$out" "TC=3" "an explicit concurrency override must be honoured"

pass "turbo fan-out is pinned inside the slot"

# --- nesting does not deadlock ----------------------------------------------
#
# The real hazard: a validation command that itself calls fm-validate.sh would
# block for ever on a lock its own process tree already holds.

out=$(timeout 20 env -u FM_VALIDATE_ACTIVE PATH="$FAKEBIN:$PATH" FM_VALIDATE_LOCK="$LOCK" \
  "$VALIDATE" -- "$VALIDATE" -- sh -c 'echo inner-ran' 2>&1)
code=$?
expect_code 0 "$code" "a nested validation must not deadlock on its own slot"
assert_contains "$out" "inner-ran" "the nested command must actually run"

pass "a nested validation passes through instead of deadlocking"

# The bypass this pins: an earlier ordering ran the nesting passthrough BEFORE
# the approval refusal, so a heavy gate invoked from inside an already-held slot
# was not refused at all - the one place it was most likely to be invoked was the
# one place it was permitted. Resources may be inherited from the outer call;
# the captain's approval may not.
marker="$TMP_ROOT/nested-banned-ran"
out=$(env -u FM_VALIDATE_CAPTAIN_APPROVED PATH="$FAKEBIN:$PATH" FM_VALIDATE_LOCK="$LOCK" \
  FM_VALIDATE_ACTIVE=999 "$VALIDATE" -- sh -c "echo gate:orphan-tables; touch '$marker'" 2>&1)
expect_code 70 $? "a banned command must be refused even inside a held slot"
assert_contains "$out" "captain's explicit approval" \
  "the nested refusal must name the approval requirement"
assert_absent "$marker" "a nested banned command must not have executed"

pass "the approval refusal is not inherited away by nesting"

# --- preflight-only mode ----------------------------------------------------

marker="$TMP_ROOT/check-ran"
out=$(run_validate --check -- touch "$marker")
expect_code 0 $? "--check must succeed when the preflight is clear"
assert_contains "$out" "preflight clear" "--check must report the verdict"
assert_absent "$marker" "--check must not execute the command"

fake_free 400
out=$(run_validate --check -- true)
expect_code 71 $? "--check must report a failing preflight with the real code"
fake_free 4096

pass "--check answers whether validation may start without starting it"

printf '\nall fm-validate tests passed\n'
