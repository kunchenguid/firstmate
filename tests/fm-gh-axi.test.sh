#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-gh-axi)
WRAPPER="$ROOT/bin/fm-gh-axi.sh"

test_refuses_shared_pr_body_file() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT/home" "$WRAPPER" pr create --title t --body-file /tmp/pr-body.md 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "fm-gh-axi should refuse /tmp/pr-body.md"
  assert_contains "$out" 'fixed shared /tmp name' \
    "refusal did not explain the shared-path hazard"
  pass "fm-gh-axi refuses /tmp/pr-body.md"
}

test_passes_through_with_fake_gh_axi() {
  local fakebin log
  fakebin="$TMP_ROOT/fakebin"
  mkdir -p "$fakebin"
  log="$TMP_ROOT/gh-axi.log"
  cat >"$fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FM_GH_AXI_LOG"
exit 0
EOF
  chmod +x "$fakebin/gh-axi"
  FM_GH_AXI_LOG="$log" PATH="$fakebin:$PATH" \
    "$WRAPPER" pr create --title ok --body-file /tmp/fm-task-1/pr-description.md
  assert_grep 'pr' "$log" "wrapper did not invoke gh-axi pr"
  assert_grep '/tmp/fm-task-1/pr-description.md' "$log" \
    "wrapper did not pass the task body path through"
  pass "fm-gh-axi passes safe body-file paths through"
}

test_refuses_shared_pr_body_file
test_passes_through_with_fake_gh_axi

echo "all fm-gh-axi tests passed"
