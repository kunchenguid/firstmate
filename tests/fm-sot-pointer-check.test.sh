#!/usr/bin/env bash
# Behavioral coverage for the optional durable-SoT program registry and bootstrap signal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-sot-pointer-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-sot-pointer-check)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/config"
  printf '%s\n' "$home"
}

assert_silent_success() {
  local label=$1 home=$2 out rc
  set +e
  out=$(FM_HOME="$home" "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$label exited $rc"
  [ -z "$out" ] || fail "$label should be silent, got: $out"
}

test_absent_registry_is_silent() {
  local home
  home=$(new_home absent)
  assert_silent_success "absent registry" "$home"
  : > "$home/data/sot-programs.tsv"
  assert_silent_success "empty registry" "$home"
  pass "sot pointer check: absent and empty registries are silent success"
}

test_done_sources_with_matching_pointers_are_clean() {
  local home
  home=$(new_home matching)
  mkdir -p "$home/data/decisions"
  printf '%s\n' \
    '- [x] gex-research - Research complete' \
    '- [x] gex-review - Review complete' > "$home/data/done-archive.md"
  printf '%s\n' '- Standing pointer: gex-v1.1 is the durable source.' > "$home/data/captain.md"
  printf '%s\n' 'The material lock is filed as locked-by-review.' > "$home/data/decisions/2026-08-12-gex.md"
  printf '%s\t%s\t%s\n' \
    captain-pointer 'gex-v1\.1' 'gex-research,gex-review' \
    decision-pointer 'locked-by-review' 'gex-research,gex-review' \
    > "$home/config/sot-programs.tsv"

  assert_silent_success "matching captain and decision pointers" "$home"
  pass "sot pointer check: completed sources accept matching captain and decision pointers"
}

test_done_sources_without_pointer_report_gap_and_strict_fails() {
  local home registry expected out rc strict_out strict_rc
  home=$(new_home missing)
  registry="$home/explicit.tsv"
  printf '%s\n' \
    '- [x] source-a - Complete' \
    '- [x] source-b - Complete' > "$home/data/backlog.md"
  printf '%s\n' '# No matching standing pointer.' > "$home/data/captain.md"
  printf '%s\t%s\t%s\n' program-b 'program-b-v2\.0' 'source-a,source-b' > "$registry"
  expected='SOT_GAP: program-b - sources Done but no standing pointer matching /program-b-v2\.0/ in captain.md|decisions/'

  set +e
  out=$(FM_HOME="$home" "$CHECK" --registry "$registry" 2>&1)
  rc=$?
  strict_out=$(FM_HOME="$home" "$CHECK" --strict --registry "$registry" 2>&1)
  strict_rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "default gap check exited $rc instead of bootstrap-safe success"
  [ "$out" = "$expected" ] || fail "gap output mismatch: $out"
  [ "$strict_rc" -eq 1 ] || fail "strict gap check exited $strict_rc instead of 1"
  [ "$strict_out" = "$expected" ] || fail "strict gap output mismatch: $strict_out"
  pass "sot pointer check: missing pointers report exactly and fail only in strict mode"
}

test_incomplete_sources_are_not_enforced() {
  local home
  home=$(new_home incomplete)
  printf '%s\n' \
    '- [x] source-a - Complete' \
    '- [ ] source-b - Still open' > "$home/data/backlog.md"
  printf '%s\t%s\t%s\n' program-open 'missing-pointer' 'source-a,source-b' \
    > "$home/data/sot-programs.tsv"

  assert_silent_success "incomplete source set" "$home"
  pass "sot pointer check: incomplete source sets are skipped"
}

make_fake_toolchain() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi gh
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
  fm_fake_version_tool "$fakebin" quota-axi FM_FAKE_QUOTA_AXI_VERSION 0.1.17
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
fi
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '%s\n' '0.2.4' ;;
  update:--help) printf '%s\n' '--archive-body' ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

test_bootstrap_surfaces_gap_in_detect_only_local_phase() {
  local home fakebin out expected
  home=$(new_home bootstrap)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/bootstrap")
  printf '%s\n' '- [x] source-a - Complete' > "$home/data/done-archive.md"
  printf '%s\t%s\t%s\n' bootstrap-program 'standing-pointer' source-a \
    > "$home/data/sot-programs.tsv"
  expected='SOT_GAP: bootstrap-program - sources Done but no standing pointer matching /standing-pointer/ in captain.md|decisions/'

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "$expected" "detect-only bootstrap did not surface the SoT gap"
  pass "bootstrap: detect-only local startup surfaces SOT_GAP diagnostics"
}

test_absent_registry_is_silent
test_done_sources_with_matching_pointers_are_clean
test_done_sources_without_pointer_report_gap_and_strict_fails
test_incomplete_sources_are_not_enforced
test_bootstrap_surfaces_gap_in_detect_only_local_phase
