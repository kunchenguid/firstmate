#!/usr/bin/env bash
# Tests for bin/fm-report-finalize.sh archive capture, index regeneration,
# refusal paths, and teardown integration.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FINALIZE="$ROOT/bin/fm-report-finalize.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
DECISION_HOLD="$ROOT/bin/fm-decision-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-report-finalize)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {
  local name=$1 home fakebin
  home="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$home")
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects/sample"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_finalize() {
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$FINALIZE" "$id"
}

run_teardown() {
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

run_decisions() {
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$DECISION_HOLD" "$@"
}

write_scout_meta() {
  local home=$1 id=$2
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
}

write_ship_meta() {
  local home=$1 id=$2
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
}

test_scout_finalize_archives_and_records_meta() {
  local home id archive
  home=$(make_home scout-archive)
  id=scout-a1
  mkdir -p "$home/data/$id"
  write_scout_meta "$home" "$id"
  printf '# Scout findings\n\nAll clear.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "decision completion failed"

  out=$(run_finalize "$home" "$id") || fail "scout finalize failed: $out"
  archive="$home/data/reports/sample/$id.md"
  assert_present "$archive" "scout archive file missing"
  assert_grep "report_archive=data/reports/sample/$id.md" "$home/state/$id.meta" \
    "meta missing archive pointer"
  assert_present "$home/data/reports/sample/INDEX.md" "project index missing"
  assert_grep "$id" "$home/data/reports/sample/INDEX.md" "index missing task id"
  assert_contains "$out" "finalized: data/reports/sample/$id.md" "finalize output wrong"
  pass "scout finalize archives report, records meta, and regenerates index"
}

test_scout_finalize_refuses_without_report() {
  local home id rc
  home=$(make_home scout-missing)
  id=scout-missing
  write_scout_meta "$home" "$id"
  run_decisions "$home" complete "$id" --none >/dev/null || fail "decision completion failed"
  set +e
  run_finalize "$home" "$id" >/dev/null 2>"$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "finalize should refuse without working report"
  assert_grep "no working report" "$home/err" "refusal message missing"
  pass "scout finalize refuses when working report is absent"
}

test_scout_finalize_refuses_without_decision_gate() {
  local home id rc
  home=$(make_home scout-gate)
  id=scout-gate
  mkdir -p "$home/data/$id"
  write_scout_meta "$home" "$id"
  printf 'report\n' > "$home/data/$id/report.md"
  set +e
  run_finalize "$home" "$id" >/dev/null 2>"$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "finalize should refuse before decision gate"
  assert_grep "unresolved-decision" "$home/err" "decision gate refusal missing"
  pass "scout finalize refuses before decision completion gate"
}

test_finalize_is_idempotent() {
  local home id first second
  home=$(make_home scout-idempotent)
  id=scout-idem
  mkdir -p "$home/data/$id"
  write_scout_meta "$home" "$id"
  printf 'same bytes\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null || fail "decision completion failed"
  first=$(run_finalize "$home" "$id") || fail "first finalize failed"
  second=$(run_finalize "$home" "$id") || fail "second finalize failed"
  assert_contains "$first" "finalized:" "first finalize output missing"
  assert_contains "$second" "finalized:" "second finalize output missing"
  pass "finalize is idempotent for identical report bytes"
}

test_ship_finalize_writes_delivery_receipt() {
  local home id archive
  home=$(make_home ship-receipt)
  id=ship-r1
  write_ship_meta "$home" "$id"
  printf 'done: PR https://github.com/example/example/pull/1 checks green\n' > "$home/state/$id.status"
  run_finalize "$home" "$id" >/dev/null || fail "ship finalize failed"
  archive="$home/data/reports/sample/$id.md"
  assert_present "$archive" "ship receipt archive missing"
  assert_grep "Ship delivery receipt" "$archive" "ship receipt heading missing"
  assert_grep "checks green" "$archive" "ship receipt missing terminal status"
  pass "ship finalize writes a short structured delivery receipt"
}

test_teardown_requires_finalize_for_scout() {
  local home id rc
  home=$(make_home teardown-scout)
  id=scout-td
  mkdir -p "$home/data/$id"
  write_scout_meta "$home" "$id"
  printf 'report body\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null || fail "decision completion failed"
  touch "$home/state/.last-watcher-beat"
  set +e
  run_teardown "$home" "$id" >/dev/null 2>"$home/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "teardown failed after implicit finalize: $(cat "$home/err")"
  assert_present "$home/data/reports/sample/$id.md" "teardown did not leave archived report"
  pass "teardown finalizes scout deliverables before cleanup"
}

test_teardown_refuses_unfinalizable_scout() {
  local home id rc
  home=$(make_home teardown-refuse)
  id=scout-refuse
  mkdir -p "$home/data/$id"
  write_scout_meta "$home" "$id"
  printf 'report body\n' > "$home/data/$id/report.md"
  set +e
  run_teardown "$home" "$id" >/dev/null 2>"$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown should refuse without decision gate"
  assert_grep "not finalized" "$home/err" "teardown refusal missing"
  pass "teardown refuses when finalize cannot succeed"
}

test_scout_finalize_archives_and_records_meta
test_scout_finalize_refuses_without_report
test_scout_finalize_refuses_without_decision_gate
test_finalize_is_idempotent
test_ship_finalize_writes_delivery_receipt
test_teardown_requires_finalize_for_scout
test_teardown_refuses_unfinalizable_scout
