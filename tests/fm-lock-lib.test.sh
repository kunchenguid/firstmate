#!/usr/bin/env bash
# Behavior tests for bin/fm-lock-lib.sh's fm_lock_lsof_holder contract: 0 a
# live holder, 1 provably none, 2 cannot tell. The cannot-tell cases cover an
# lsof error and, the reason this file exists, an lsof call that outlives its
# wall-clock bound - a mounted-but-unresponsive network share stalls lsof's
# mount-table phase for minutes, and the bound must turn that into a bounded
# "assume held" rather than a hang or a false "provably none". Every case drives
# a PATH fake of lsof; the bound itself is bin/fm-timeout-lib.sh's fm_run_timed,
# driven through the real coreutils timeout where the host has one, through a
# recording fake where the test needs to see the bound that was requested, and
# through its bash watchdog fallback where no timeout tool is visible at all.
# shellcheck disable=SC2016 # the inner bash -c scripts and fake bodies expand their own arguments
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-lib)

# A minimal PATH holding only the shell tools the fakes need, so a case can
# decide for itself whether a timeout variant is visible.
BASE_BIN="$TMP_ROOT/base-bin"
mkdir -p "$BASE_BIN"
for tool in bash sleep cat printf mktemp rm dirname; do
  path=$(command -v "$tool") || continue
  ln -s "$path" "$BASE_BIN/$tool"
done

REAL_TIMEOUT=$(command -v timeout || command -v gtimeout || true)

# holder_rc <path> <target> <stderr-file> [env...]: run fm_lock_lsof_holder in a
# fresh bash under <path>, exactly as a sourcing caller would, and echo its
# return code. Diagnostics land in <stderr-file>.
holder_rc() {
  local path=$1 target=$2 errfile=$3 rc=0
  shift 3
  env -i PATH="$path" "$@" bash -c '
    . "$1/bin/fm-lock-lib.sh"
    fm_lock_lsof_holder "$2"
  ' _ "$ROOT" "$target" 2> "$errfile" || rc=$?
  printf '%s\n' "$rc"
}

# live_holder_rc <path> <lock> <dir> [env...]: same shape for the caller-facing
# fm_lock_has_live_holder, whose 0 means "held or cannot tell".
live_holder_rc() {
  local path=$1 lock=$2 dir=$3 rc=0
  shift 3
  env -i PATH="$path" "$@" bash -c '
    . "$1/bin/fm-lock-lib.sh"
    fm_lock_has_live_holder "$2" "$3"
  ' _ "$ROOT" "$lock" "$dir" 2>/dev/null || rc=$?
  printf '%s\n' "$rc"
}

make_fakebin() {  # <name> -> echoes a fresh dir seeded with the base tools
  local dir="$TMP_ROOT/$1-bin"
  mkdir -p "$dir"
  cp -R "$BASE_BIN/." "$dir/"
  printf '%s\n' "$dir"
}

write_fake_lsof() {  # <dir> <body>
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1/lsof"
  chmod +x "$1/lsof"
}

test_live_holder_returns_0() {
  local bin rc
  bin=$(make_fakebin live)
  write_fake_lsof "$bin" 'printf "COMMAND PID\nsleep 4242\n"; exit 0'
  rc=$(holder_rc "$bin" /some/lock "$TMP_ROOT/live.err")
  expect_code 0 "$rc" "live-holder: a listed holder"
  pass "an lsof listing is a live holder (0)"
}

test_provably_none_returns_1() {
  local bin rc
  bin=$(make_fakebin none)
  write_fake_lsof "$bin" 'exit 1'
  rc=$(holder_rc "$bin" /some/lock "$TMP_ROOT/none.err")
  expect_code 1 "$rc" "provably-none: exit 1 with no output"
  [ ! -s "$TMP_ROOT/none.err" ] || fail "provably-none: logged a diagnostic on the clean path"
  pass "lsof exit 1 with empty output is provably none (1)"
}

test_lsof_error_returns_2_and_logs() {
  local bin rc
  bin=$(make_fakebin error)
  write_fake_lsof "$bin" 'echo "lsof: status error on $2: Resource temporarily unavailable" >&2; exit 1'
  rc=$(holder_rc "$bin" /some/lock "$TMP_ROOT/error.err")
  expect_code 2 "$rc" "lsof-error: exit 1 with output"
  assert_grep "fm-lock: lsof check failed: lsof: status error on /some/lock" "$TMP_ROOT/error.err" \
    "lsof-error: the lsof diagnostic was not logged"
  pass "an lsof error is cannot-tell (2) with the diagnostic logged"
}

test_timed_out_lsof_returns_2_and_logs() {
  local bin rc started elapsed
  [ -n "$REAL_TIMEOUT" ] || { pass "timed-out: skipped, no timeout or gtimeout on this host"; return; }
  bin=$(make_fakebin stall)
  ln -s "$REAL_TIMEOUT" "$bin/$(basename "$REAL_TIMEOUT")"
  # A stalled lsof: never prints, never exits on its own. `exec` so the bound's
  # TERM reaches the sleeper itself.
  write_fake_lsof "$bin" 'exec sleep 120'
  started=$(date +%s)
  rc=$(holder_rc "$bin" /some/lock "$TMP_ROOT/stall.err" FM_LOCK_LSOF_TIMEOUT=1)
  elapsed=$(( $(date +%s) - started ))
  expect_code 2 "$rc" "timed-out: lsof outliving the bound"
  [ "$elapsed" -lt 30 ] || fail "timed-out: holder check took ${elapsed}s; the bound did not end the call"
  assert_grep "fm-lock: lsof check timed out after 1s for /some/lock; cannot tell whether it is held" \
    "$TMP_ROOT/stall.err" "timed-out: the timeout diagnostic was not logged"
  pass "an lsof call that outlives the bound is cannot-tell (2), never provably none, and is logged"
}

test_timed_out_lsof_is_a_live_holder_for_callers() {
  local bin rc
  [ -n "$REAL_TIMEOUT" ] || { pass "timed-out-live: skipped, no timeout or gtimeout on this host"; return; }
  bin=$(make_fakebin stall-live)
  ln -s "$REAL_TIMEOUT" "$bin/$(basename "$REAL_TIMEOUT")"
  write_fake_lsof "$bin" 'exec sleep 120'
  rc=$(live_holder_rc "$bin" /some/lock /some/dir FM_LOCK_LSOF_TIMEOUT=1)
  expect_code 0 "$rc" "timed-out-live: has_live_holder must assume a holder"
  pass "a timed-out lsof makes fm_lock_has_live_holder assume a live holder (fail safe)"
}

test_bound_is_requested_with_the_default_seconds() {
  local bin rc
  bin=$(make_fakebin recording)
  # A recording timeout: skip the kill-grace option, note the requested bound,
  # then run the command bare.
  cat > "$bin/timeout" <<EOF
#!/usr/bin/env bash
while [ "\$1" = -k ]; do shift 2; done
printf '%s\n' "\$1" >> '$TMP_ROOT/recording.bound'
shift
exec "\$@"
EOF
  chmod +x "$bin/timeout"
  write_fake_lsof "$bin" 'exit 1'
  rc=$(holder_rc "$bin" /some/lock "$TMP_ROOT/recording.err")
  expect_code 1 "$rc" "recording: the bare result must pass through the bound"
  assert_equals "60" "$(cat "$TMP_ROOT/recording.bound")" \
    "recording: default bound is not 60 seconds"
  pass "lsof runs under a 60 s bound by default when timeout exists"
}

test_zero_override_falls_back_to_the_default_bound() {
  local bin rc
  bin=$(make_fakebin zero)
  # Same recording timeout as above: the bound that lsof actually ran under is
  # the observable, not the variable's value.
  cat > "$bin/timeout" <<EOF
#!/usr/bin/env bash
while [ "\$1" = -k ]; do shift 2; done
printf '%s\n' "\$1" >> '$TMP_ROOT/zero.bound'
shift
exec "\$@"
EOF
  chmod +x "$bin/timeout"
  write_fake_lsof "$bin" 'exit 1'
  rc=$(holder_rc "$bin" /some/lock "$TMP_ROOT/zero.err" FM_LOCK_LSOF_TIMEOUT=0)
  expect_code 1 "$rc" "zero: the bare result must pass through the bound"
  assert_equals "60" "$(cat "$TMP_ROOT/zero.bound")" \
    "zero: FM_LOCK_LSOF_TIMEOUT=0 did not fall back to the 60 s bound"
  assert_grep "fm-lock: ignoring FM_LOCK_LSOF_TIMEOUT='0' (not a positive integer); using the 60s default" \
    "$TMP_ROOT/zero.err" "zero: the fallback was not logged"
  assert_equals "1" "$(grep -c 'ignoring FM_LOCK_LSOF_TIMEOUT' "$TMP_ROOT/zero.err")" \
    "zero: the fallback was not logged exactly once"
  pass "FM_LOCK_LSOF_TIMEOUT=0 is not unbounded: lsof still runs under the 60 s default, and the fallback is logged once"
}

test_without_a_timeout_tool_the_bound_still_holds() {
  local bin rc started elapsed
  bin=$(make_fakebin bare)
  write_fake_lsof "$bin" 'printf "%s\n" "$*" > '"'$TMP_ROOT/bare.args'"'; exec sleep 120'
  for tool in timeout gtimeout perl; do
    PATH="$bin" command -v "$tool" >/dev/null 2>&1 && fail "bare: fixture PATH unexpectedly exposes $tool"
  done
  started=$(date +%s)
  rc=$(holder_rc "$bin" /some/lock "$TMP_ROOT/bare.err" FM_LOCK_LSOF_TIMEOUT=1)
  elapsed=$(( $(date +%s) - started ))
  expect_code 2 "$rc" "bare: a stalled lsof must still be cannot-tell without a timeout tool"
  [ "$elapsed" -lt 30 ] || fail "bare: holder check took ${elapsed}s; the fallback bound did not end the call"
  assert_grep "fm-lock: lsof check timed out after 1s for /some/lock; cannot tell whether it is held" \
    "$TMP_ROOT/bare.err" "bare: the timeout diagnostic was not logged"
  assert_equals "-- /some/lock" "$(cat "$TMP_ROOT/bare.args")" \
    "bare: lsof was not called with the plain path argument"
  pass "without timeout, gtimeout, or perl the bound still holds through the bash fallback, and lsof runs without -b"
}

test_live_holder_returns_0
test_provably_none_returns_1
test_lsof_error_returns_2_and_logs
test_timed_out_lsof_returns_2_and_logs
test_timed_out_lsof_is_a_live_holder_for_callers
test_bound_is_requested_with_the_default_seconds
test_zero_override_falls_back_to_the_default_bound
test_without_a_timeout_tool_the_bound_still_holds
