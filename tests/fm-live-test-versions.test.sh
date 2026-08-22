#!/usr/bin/env bash
# tests/fm-live-test-versions.test.sh - behavior tests for the live-test
# version-change detection that fires at session start.
#
# The version check records installed tool versions in a baseline file and
# prints a LIVE_TEST_VERSIONS_CHANGED: diagnostic when any version differs.
# These tests pin:
#   1. First run silently records a baseline (no diagnostic).
#   2. Unchanged versions produce no diagnostic.
#   3. A changed version produces the LIVE_TEST_VERSIONS_CHANGED: line and
#      updates the baseline.
#   4. An unreadable version is recorded as the raw first line (or "unknown")
#      and is NOT treated as changed from a previous identical value.
#   5. A missing tool is "unknown" and stable across runs.
#   6. The baseline file format is tool=version, sorted.
#   7. Bootstrap integration: detect_local_tools calls the check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-live-test-versions.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-test-versions)

# --- helpers ----------------------------------------------------------------

# Build a fake toolchain with controlled versions for the tools the check
# cares about. Each tool answers --version with its controlled value.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  # The twelve tools the nine fleet-relevant live tests depend on.
  for tool in agy claude codex cursor grok herdr kimi muse opencode pi tmux zellij; do
    cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\\n' "\${FM_FAKE_${tool^^}_VERSION:-1.0.0}"
  exit 0
fi
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
  printf '%s\n' "$fakebin"
}

# Run the version check with a controlled PATH and state directory.
run_check() {
  local fakebin=$1 state_dir=$2
  PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$SCRIPT" check --state-dir "$state_dir"
}

run_show() {
  local state_dir=$1
  "$SCRIPT" show --state-dir "$state_dir"
}

# --- test 1: first run records baseline silently ----------------------------

t1="$TMP_ROOT/t1"
mkdir -p "$t1/state"
fakebin=$(make_fake_toolchain "$t1")
out=$(run_check "$fakebin" "$t1/state")

[ -z "$out" ] || fail "first run should be silent, got: $out"
[ -f "$t1/state/.live-test-versions" ] || fail "baseline file not created on first run"

# Verify format: tool=version lines, sorted
baseline=$(cat "$t1/state/.live-test-versions")
case "$baseline" in
  *"agy=1.0.0"*) : ;;
  *) fail "baseline missing agy=1.0.0, got: $baseline" ;;
esac
case "$baseline" in
  *"zellij=1.0.0"*) : ;;
  *) fail "baseline missing zellij=1.0.0, got: $baseline" ;;
esac
pass "first run records baseline silently"

# --- test 2: unchanged versions produce no output ---------------------------

out=$(run_check "$fakebin" "$t1/state")
[ -z "$out" ] || fail "unchanged versions should be silent, got: $out"
pass "unchanged versions produce no output"

# --- test 3: changed version triggers diagnostic ---------------------------

t3="$TMP_ROOT/t3"
mkdir -p "$t3/state"
fakebin3=$(make_fake_toolchain "$t3")

# First run to establish baseline
run_check "$fakebin3" "$t3/state" >/dev/null

# Change agy's version
out=$(FM_FAKE_AGY_VERSION=2.0.0 run_check "$fakebin3" "$t3/state")
case "$out" in
  *"LIVE_TEST_VERSIONS_CHANGED:"*"agy"*"1.0.0"*"2.0.0"*)
    pass "changed version prints LIVE_TEST_VERSIONS_CHANGED diagnostic" ;;
  *)
    fail "expected LIVE_TEST_VERSIONS_CHANGED for agy, got: $out" ;;
esac

# Verify baseline was updated
updated=$(cat "$t3/state/.live-test-versions")
case "$updated" in
  *"agy=2.0.0"*)
    pass "baseline updated after version change" ;;
  *)
    fail "baseline not updated, got: $updated" ;;
esac

# --- test 4: second run after update is silent (baseline was updated) -------

out=$(FM_FAKE_AGY_VERSION=2.0.0 run_check "$fakebin3" "$t3/state")
[ -z "$out" ] || fail "second run after update should be silent, got: $out"
pass "second run after update is silent"

# --- test 5: missing tool is 'unknown' and stable --------------------------

t5="$TMP_ROOT/t5"
mkdir -p "$t5/state"
fakebin5=$(make_fake_toolchain "$t5")

# Remove one tool from the fake PATH
rm "$fakebin5/cursor"

# First run
run_check "$fakebin5" "$t5/state" >/dev/null
baseline5=$(cat "$t5/state/.live-test-versions")
case "$baseline5" in
  *"cursor=unknown"*)
    pass "missing tool recorded as unknown" ;;
  *)
    fail "missing tool should be unknown, got: $baseline5" ;;
esac

# Second run: still missing, should be silent
out=$(run_check "$fakebin5" "$t5/state")
[ -z "$out" ] || fail "missing tool should be stable (unknown=unknown), got: $out"
pass "missing tool is stable across runs"

# --- test 6: unreadable version (non-semver output) -------------------------

t6="$TMP_ROOT/t6"
mkdir -p "$t6/state"
fakebin6=$(make_fake_toolchain "$t6")

# Make herdr return non-semver output
cat > "$fakebin6/herdr" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "herdr dev-build-abc123"
  exit 0
fi
exit 0
SH
chmod +x "$fakebin6/herdr"

# First run records whatever it got
run_check "$fakebin6" "$t6/state" >/dev/null
baseline6=$(cat "$t6/state/.live-test-versions")
case "$baseline6" in
  *"herdr=herdr dev-build-abc123"*)
    pass "non-semver version recorded as raw first line" ;;
  *)
    fail "non-semver version not recorded correctly, got: $baseline6" ;;
esac

# Second run with same non-semver output: should be silent
out=$(run_check "$fakebin6" "$t6/state")
[ -z "$out" ] || fail "same non-semver output should be stable, got: $out"
pass "unreadable version is stable when unchanged"

# --- test 7: multiple tools change at once ----------------------------------

t7="$TMP_ROOT/t7"
mkdir -p "$t7/state"
fakebin7=$(make_fake_toolchain "$t7")

run_check "$fakebin7" "$t7/state" >/dev/null

out=$(FM_FAKE_AGY_VERSION=3.0.0 FM_FAKE_HERDR_VERSION=2.5.0 run_check "$fakebin7" "$t7/state")
case "$out" in
  *"LIVE_TEST_VERSIONS_CHANGED:"*"agy"*"herdr"*)
    pass "multiple changed tools reported in one line" ;;
  *)
    fail "expected both agy and herdr in diagnostic, got: $out" ;;
esac

# --- test 8: bootstrap integration -----------------------------------------

t8="$TMP_ROOT/t8"
mkdir -p "$t8/state" "$t8/config" "$t8/projects" "$t8/data"
fakebin8=$(make_fake_toolchain "$t8")

# Add the other tools bootstrap needs
fm_fake_exit0 "$fakebin8" node chrome-devtools-axi
fm_fake_version_tool "$fakebin8" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
fm_fake_version_tool "$fakebin8" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
fm_fake_version_tool "$fakebin8" no-mistakes FM_FAKE_NO_MISTAKES_VERSION 1.31.2
fm_fake_version_tool "$fakebin8" tasks-axi FM_FAKE_TASKS_AXI_VERSION 0.5.0
fm_fake_version_tool "$fakebin8" quota-axi FM_FAKE_QUOTA_AXI_VERSION 0.1.10
cat > "$fakebin8/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  echo "  --lease"
fi
exit 0
SH
chmod +x "$fakebin8/treehouse"
cat > "$fakebin8/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fakebin8/gh"

# Run bootstrap with controlled environment - first run records baseline
boot_out=$(
  PATH="$fakebin8:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$t8" \
  FM_STATE_OVERRIDE="$t8/state" \
  FM_CONFIG_OVERRIDE="$t8/config" \
  FM_PROJECTS_OVERRIDE="$t8/projects" \
  FM_DATA_OVERRIDE="$t8/data" \
  FM_BOOTSTRAP_NETWORK=skip \
  "$BOOTSTRAP" 2>&1
)

[ -f "$t8/state/.live-test-versions" ] || fail "bootstrap did not create baseline"
pass "bootstrap integration: baseline created on first run"

# Second run with a changed version
boot_out=$(
  PATH="$fakebin8:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$t8" \
  FM_STATE_OVERRIDE="$t8/state" \
  FM_CONFIG_OVERRIDE="$t8/config" \
  FM_PROJECTS_OVERRIDE="$t8/projects" \
  FM_DATA_OVERRIDE="$t8/data" \
  FM_BOOTSTRAP_NETWORK=skip \
  FM_FAKE_AGY_VERSION=9.9.9 \
  "$BOOTSTRAP" 2>&1
)

case "$boot_out" in
  *"LIVE_TEST_VERSIONS_CHANGED:"*"agy"*)
    pass "bootstrap integration: version change detected" ;;
  *)
    fail "bootstrap should have reported version change, got: $boot_out" ;;
esac

# Third run - unchanged after update - should be silent about versions
boot_out=$(
  PATH="$fakebin8:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$t8" \
  FM_STATE_OVERRIDE="$t8/state" \
  FM_CONFIG_OVERRIDE="$t8/config" \
  FM_PROJECTS_OVERRIDE="$t8/projects" \
  FM_DATA_OVERRIDE="$t8/data" \
  FM_BOOTSTRAP_NETWORK=skip \
  FM_FAKE_AGY_VERSION=9.9.9 \
  "$BOOTSTRAP" 2>&1
)

case "$boot_out" in
  *"LIVE_TEST_VERSIONS_CHANGED:"*)
    fail "bootstrap should be silent after baseline update, got: $boot_out" ;;
  *)
    pass "bootstrap integration: silent after baseline update" ;;
esac

# --- test 9: show command ---------------------------------------------------

t9="$TMP_ROOT/t9"
mkdir -p "$t9/state"
fakebin9=$(make_fake_toolchain "$t9")
run_check "$fakebin9" "$t9/state" >/dev/null

show_out=$(run_show "$t9/state")
case "$show_out" in
  *"agy=1.0.0"*"zellij=1.0.0"*)
    pass "show command prints baseline" ;;
  *)
    fail "show command wrong output, got: $show_out" ;;
esac

# No baseline
show_empty=$("$SCRIPT" show --state-dir "$t9/empty")
[ "$show_empty" = "no baseline" ] || fail "show with no baseline should say 'no baseline', got: $show_empty"
pass "show command handles missing baseline"

# --- test 10: record command ------------------------------------------------

t10="$TMP_ROOT/t10"
mkdir -p "$t10/state"
fakebin10=$(make_fake_toolchain "$t10")

rec_out=$(PATH="$fakebin10:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
  "$SCRIPT" record --state-dir "$t10/state")
[ "$rec_out" = "recorded" ] || fail "record should print 'recorded', got: $rec_out"
[ -f "$t10/state/.live-test-versions" ] || fail "record did not create baseline"
pass "record command creates baseline"
