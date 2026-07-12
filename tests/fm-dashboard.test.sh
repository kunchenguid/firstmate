#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASHBOARD="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)

make_case() {
  local dir="$TMP_ROOT/$1"
  rm -rf "$dir"
  mkdir -p "$dir/state" "$dir/data" "$dir/fakebin"
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ready) printf 'state: done · source: run-step · checks green: PR ready for review\n' ;;
  merged) printf 'state: done · source: run-step · run passed: PR merged/closed\n' ;;
esac
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  printf '%s\n' "$dir"
}

write_task() {
  local dir=$1 id=$2 pr=$3 status=$4
  fm_write_meta "$dir/state/$id.meta" "project=$dir/project" "kind=ship" "pr=$pr"
  printf '%s\n' "$status" > "$dir/state/$id.status"
}

run_dashboard() {
  local dir=$1 out
  out="$dir/dashboard.html"
  FM_HOME="$dir" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    "$DASHBOARD" -o "$out" >/dev/null
  printf '%s\n' "$out"
}

test_checks_green_pr_counts_as_attention() {
  local dir out
  dir=$(make_case checks-green)
  write_task "$dir" ready https://github.com/o/r/pull/1 \
    'done: PR https://github.com/o/r/pull/1 checks green'
  out=$(run_dashboard "$dir")
  assert_contains "$(cat "$out")" '<div class="num warn">1</div><div class="lbl">needs attention</div>' \
    "checks-green PR increments attention count"
  assert_contains "$(cat "$out")" 'Decisions needed (1)' \
    "checks-green PR appears as one decision"
  pass "checks-green PR is counted consistently"
}

test_merged_pr_does_not_count_as_attention() {
  local dir out
  dir=$(make_case merged)
  write_task "$dir" merged https://github.com/o/r/pull/2 \
    'done: PR https://github.com/o/r/pull/2 checks green'
  out=$(run_dashboard "$dir")
  assert_contains "$(cat "$out")" '<div class="num good">0</div><div class="lbl">needs attention</div>' \
    "merged PR does not increment attention count"
  assert_contains "$(cat "$out")" 'Nothing needs you.' \
    "merged PR does not appear as a decision"
  pass "merged PR remains non-actionable"
}

test_checks_green_pr_counts_as_attention
test_merged_pr_does_not_count_as_attention

echo "all fm-dashboard tests passed"
