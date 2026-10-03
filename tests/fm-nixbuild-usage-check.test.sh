#!/usr/bin/env bash
# tests/fm-nixbuild-usage-check.test.sh - nixbuild.net quota usage poll.
#
# Coverage:
#   1. All accounts healthy (under threshold) - no output at all
#   2. One account at warning threshold - single line with "warn"
#   3. One account fully exhausted (100%) - single line with "exhausted"
#   4. Unreachable account (ssh exits non-zero) - single line with "unverifiable"
#   5. Malformed output (no parseable numbers) - single line with "unverifiable"
#   6. Multiple mixed states collapse to one line
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-nixbuild-usage-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-nixbuild-usage-check)

# make_fakebin: write a PATH-shim ssh that returns canned output per alias.
# Tests set env vars FM_FAKE_SSH_<KEY>_OUT and FM_FAKE_SSH_<KEY>_RC where KEY
# is the alias uppercased and with dashes replaced by underscores.
make_fakebin() {  # <dir> -> fakebin-path
  local dir=$1
  local fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/ssh" <<'SH'
#!/usr/bin/env bash
set -u
# Parse args: skip -o flags, extract alias as first bare positional arg.
alias_name=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *)  alias_name=$1; break ;;
  esac
done
# Derive env var key: nixbuild-1 -> NIXBUILD_1
key=$(printf '%s' "$alias_name" | tr 'a-z-' 'A-Z_')
out_var="FM_FAKE_SSH_${key}_OUT"
rc_var="FM_FAKE_SSH_${key}_RC"
out=${!out_var:-}
rc=${!rc_var:-0}
[ -n "$out" ] && printf '%s\n' "$out"
exit "$rc"
SH
  chmod +x "$fb/ssh"
  printf '%s\n' "$fb"
}

run_check() {  # <fakebin> [env-assignments...]
  local fakebin=$1; shift
  env PATH="$fakebin:$PATH" FM_NIXBUILD_PROBE_SECS=5 "$@" "$CHECK" check
}

# --- canned usage strings ----------------------------------------------------

HEALTHY_OUT="cpu_seconds_used 50000
cpu_seconds_quota 324000"

WARN_OUT="cpu_seconds_used 262000
cpu_seconds_quota 324000"
# 262000/324000 = 80.86% - above the 80% default threshold

EXHAUSTED_OUT="cpu_seconds_used 324000
cpu_seconds_quota 324000"
# 100%

MALFORMED_OUT="no usage data could be retrieved
server returned an unexpected response"

# --- test functions ----------------------------------------------------------

test_healthy_silent() {
  local fakebin tmp
  tmp="$TMP_ROOT/healthy"
  mkdir -p "$tmp"
  fakebin=$(make_fakebin "$tmp")
  # All four accounts healthy at ~15%
  local healthy="cpu_seconds_used 50000
cpu_seconds_quota 324000"
  out=$(FM_FAKE_SSH_NIXBUILD_1_OUT="$healthy" \
        FM_FAKE_SSH_NIXBUILD_2_OUT="$healthy" \
        FM_FAKE_SSH_NIXBUILD_3_OUT="$healthy" \
        FM_FAKE_SSH_NIXBUILD_4_OUT="$healthy" \
        run_check "$fakebin") || true
  assert_equals '' "$out" "all healthy accounts must produce no output"
  pass "all healthy accounts: silent"
}

test_warn_threshold_trip() {
  local fakebin tmp out
  tmp="$TMP_ROOT/warn"
  mkdir -p "$tmp"
  fakebin=$(make_fakebin "$tmp")
  out=$(FM_FAKE_SSH_NIXBUILD_1_OUT="$WARN_OUT" \
        FM_FAKE_SSH_NIXBUILD_2_OUT="$HEALTHY_OUT" \
        FM_FAKE_SSH_NIXBUILD_3_OUT="$HEALTHY_OUT" \
        FM_FAKE_SSH_NIXBUILD_4_OUT="$HEALTHY_OUT" \
        run_check "$fakebin") || true
  assert_contains "$out" 'nixbuild usage:' "warn case must produce a nixbuild usage line"
  assert_contains "$out" 'nixbuild-1'     "warn line must name the tripped alias"
  assert_contains "$out" 'warn'            "warn line must include 'warn' label"
  assert_not_contains "$out" 'nixbuild-2'  "healthy alias must not appear in warn line"
  pass "warn threshold trip: one line with warn label"
}

test_exhausted_account() {
  local fakebin tmp out
  tmp="$TMP_ROOT/exhausted"
  mkdir -p "$tmp"
  fakebin=$(make_fakebin "$tmp")
  out=$(FM_FAKE_SSH_NIXBUILD_1_OUT="$HEALTHY_OUT" \
        FM_FAKE_SSH_NIXBUILD_2_OUT="$EXHAUSTED_OUT" \
        FM_FAKE_SSH_NIXBUILD_3_OUT="$HEALTHY_OUT" \
        FM_FAKE_SSH_NIXBUILD_4_OUT="$HEALTHY_OUT" \
        run_check "$fakebin") || true
  assert_contains "$out" 'nixbuild usage:' "exhausted case must produce a nixbuild usage line"
  assert_contains "$out" 'nixbuild-2'      "exhausted line must name the alias"
  assert_contains "$out" 'exhausted'       "exhausted line must include 'exhausted' label"
  pass "exhausted account: one line with exhausted label"
}

test_unreachable_account() {
  local fakebin tmp out
  tmp="$TMP_ROOT/unreachable"
  mkdir -p "$tmp"
  fakebin=$(make_fakebin "$tmp")
  # nixbuild-3 exits 255 (ssh connection refused)
  out=$(FM_FAKE_SSH_NIXBUILD_1_OUT="$HEALTHY_OUT" \
        FM_FAKE_SSH_NIXBUILD_2_OUT="$HEALTHY_OUT" \
        FM_FAKE_SSH_NIXBUILD_3_OUT="" \
        FM_FAKE_SSH_NIXBUILD_3_RC=255 \
        FM_FAKE_SSH_NIXBUILD_4_OUT="$HEALTHY_OUT" \
        run_check "$fakebin") || true
  assert_contains "$out" 'nixbuild usage:'  "unreachable case must produce a nixbuild usage line"
  assert_contains "$out" 'nixbuild-3'       "unreachable line must name the alias"
  assert_contains "$out" 'unverifiable'     "unreachable line must include 'unverifiable'"
  pass "unreachable account: one line with unverifiable label"
}

test_malformed_output() {
  local fakebin tmp out
  tmp="$TMP_ROOT/malformed"
  mkdir -p "$tmp"
  fakebin=$(make_fakebin "$tmp")
  out=$(FM_FAKE_SSH_NIXBUILD_1_OUT="$HEALTHY_OUT" \
        FM_FAKE_SSH_NIXBUILD_2_OUT="$HEALTHY_OUT" \
        FM_FAKE_SSH_NIXBUILD_3_OUT="$HEALTHY_OUT" \
        FM_FAKE_SSH_NIXBUILD_4_OUT="$MALFORMED_OUT" \
        run_check "$fakebin") || true
  assert_contains "$out" 'nixbuild usage:'  "malformed case must produce a nixbuild usage line"
  assert_contains "$out" 'nixbuild-4'       "malformed line must name the alias"
  assert_contains "$out" 'unverifiable'     "malformed line must include 'unverifiable'"
  pass "malformed output: one line with unverifiable label"
}

test_mixed_states_single_line() {
  local fakebin tmp out
  tmp="$TMP_ROOT/mixed"
  mkdir -p "$tmp"
  fakebin=$(make_fakebin "$tmp")
  # nixbuild-1: warn; nixbuild-2: unreachable; nixbuild-3: healthy; nixbuild-4: exhausted
  out=$(FM_FAKE_SSH_NIXBUILD_1_OUT="$WARN_OUT" \
        FM_FAKE_SSH_NIXBUILD_2_OUT="" \
        FM_FAKE_SSH_NIXBUILD_2_RC=1 \
        FM_FAKE_SSH_NIXBUILD_3_OUT="$HEALTHY_OUT" \
        FM_FAKE_SSH_NIXBUILD_4_OUT="$EXHAUSTED_OUT" \
        run_check "$fakebin") || true
  line_count=$(printf '%s\n' "$out" | grep -c 'nixbuild usage:' || true)
  assert_equals '1' "$line_count" "mixed states must collapse to exactly one output line"
  assert_contains "$out" 'nixbuild-1' "warn alias must appear in mixed line"
  assert_contains "$out" 'nixbuild-2' "unreachable alias must appear in mixed line"
  assert_contains "$out" 'nixbuild-4' "exhausted alias must appear in mixed line"
  assert_not_contains "$out" 'nixbuild-3' "healthy alias must not appear in mixed line"
  pass "mixed states collapse to a single output line"
}

# --- run all tests -----------------------------------------------------------

test_healthy_silent
test_warn_threshold_trip
test_exhausted_account
test_unreachable_account
test_malformed_output
test_mixed_states_single_line
