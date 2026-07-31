#!/usr/bin/env bash
# Behavior tests for the public session-lock diagnostic when harness ancestry
# cannot be established.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock)
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

test_process_inspection_unavailable_is_distinct() {
  local home fakebin out rc=0
  home="$TMP_ROOT/inspection-unavailable"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$LOCK" 2>&1) || rc=$?
  expect_code 1 "$rc" "fm-lock must fail closed when ps is unavailable"
  assert_contains "$out" "process inspection is unavailable (ps failed for the current process)" \
    "fm-lock did not distinguish a blocked process-inspection surface"
  assert_contains "$out" "for Claude Code, disable its sandbox for this firstmate session" \
    "fm-lock did not give the concrete sandbox remedy"
  assert_contains "$out" "operate read-only until resolved" \
    "fm-lock lost its read-only fail-closed instruction"
  assert_absent "$home/state/.lock" "failed process inspection published a session lock"
  pass "fm-lock: unavailable process inspection names the sandbox remedy and stays read-only"
}

test_readable_ancestry_without_harness_is_distinct() {
  local home fakebin out rc=0
  home="$TMP_ROOT/no-harness-match"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) shift 2 ;;
    *) shift ;;
  esac
done
case "$field" in
  comm=) printf '%s\n' /bin/zsh ;;
  args=) printf '%s\n' zsh ;;
  ppid=) printf '%s\n' 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$LOCK" 2>&1) || rc=$?
  expect_code 1 "$rc" "fm-lock must fail closed when no harness matches"
  assert_contains "$out" "process inspection ran but no supported harness process matched the ancestry" \
    "fm-lock confused a completed unmatched walk with unavailable process inspection"
  assert_contains "$out" "launch firstmate from a verified harness" \
    "fm-lock did not give the unmatched-ancestry remedy"
  assert_not_contains "$out" "disable its sandbox" \
    "fm-lock prescribed a sandbox change after process inspection succeeded"
  assert_absent "$home/state/.lock" "unmatched harness ancestry published a session lock"
  pass "fm-lock: a readable unmatched ancestry names the verified-harness remedy"
}

test_process_inspection_unavailable_is_distinct
test_readable_ancestry_without_harness_is_distinct
