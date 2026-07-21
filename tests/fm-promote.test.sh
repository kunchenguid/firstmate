#!/usr/bin/env bash
# Behavior tests for bin/fm-promote.sh delivery-mode preservation and override.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-promote)
PROMOTE="$ROOT/bin/fm-promote.sh"

make_case() {
  local name=$1 mode=$2 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data/task-a"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/task-a.meta" \
    'window=fm-task-a' 'worktree=/tmp/task-a' 'project=/tmp/project' \
    'harness=claude' 'kind=scout' "mode=$mode" 'yolo=on'
  printf '%s\n' "$home"
}

run_promote() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$PROMOTE" task-a "$@" 2>&1
}

test_existing_mode_is_preserved() {
  local home out
  home=$(make_case preserve direct-PR)
  out=$(run_promote "$home") || fail "promotion without an override failed"
  assert_contains "$out" 'promoted task-a to ship mode=direct-PR' \
    "promotion did not report the preserved delivery mode"
  assert_grep 'kind=ship' "$home/state/task-a.meta" "promotion did not set ship kind"
  assert_grep 'mode=direct-PR' "$home/state/task-a.meta" "promotion changed the existing delivery mode"
  assert_grep 'yolo=on' "$home/state/task-a.meta" "promotion changed the orthogonal yolo posture"
  assert_absent "$home/data/task-a/delivery-mode" \
    "promotion wrote an unnecessary task override"
  pass "fm-promote.sh: promotion preserves the resolved delivery mode and yolo"
}

test_missing_mode_uses_standard_default() {
  local home out
  home=$(make_case missing '')
  out=$(run_promote "$home") || fail "promotion with missing legacy mode failed"
  assert_contains "$out" 'promoted task-a to ship mode=direct-PR' \
    "promotion did not use the standard delivery mode for missing legacy metadata"
  assert_grep 'mode=direct-PR' "$home/state/task-a.meta" \
    "promotion retained the old no-mistakes fallback for missing legacy metadata"
  pass "fm-promote.sh: missing legacy mode uses the standard direct-PR default"
}

test_explicit_mode_updates_meta_and_task_override() {
  local home out
  home=$(make_case override direct-PR)
  out=$(run_promote "$home" --mode no-mistakes) || fail "promotion with no-mistakes override failed"
  assert_contains "$out" 'promoted task-a to ship mode=no-mistakes' \
    "promotion did not report the explicit delivery mode"
  assert_grep 'kind=ship' "$home/state/task-a.meta" "override promotion did not set ship kind"
  assert_grep 'mode=no-mistakes' "$home/state/task-a.meta" \
    "override promotion did not update durable metadata"
  [ "$(cat "$home/data/task-a/delivery-mode")" = no-mistakes ] \
    || fail "override promotion did not record task mode for later resolution"
  assert_grep 'yolo=on' "$home/state/task-a.meta" "override promotion changed the yolo posture"
  pass "fm-promote.sh: explicit mode keeps promotion metadata and task resolution aligned"
}

test_invalid_mode_refuses_without_mutation() {
  local home out rc
  home=$(make_case invalid direct-PR)
  rc=0
  out=$(run_promote "$home" --mode mystery) || rc=$?
  expect_code 1 "$rc" "invalid promotion mode must be rejected"
  assert_contains "$out" "unknown delivery mode 'mystery'" \
    "invalid promotion mode refusal was not explicit"
  assert_grep 'kind=scout' "$home/state/task-a.meta" \
    "invalid promotion mutated the task kind"
  assert_grep 'mode=direct-PR' "$home/state/task-a.meta" \
    "invalid promotion mutated the task mode"
  pass "fm-promote.sh: invalid task modes refuse before mutation"
}

test_existing_mode_is_preserved
test_missing_mode_uses_standard_default
test_explicit_mode_updates_meta_and_task_override
test_invalid_mode_refuses_without_mutation

echo "# all fm-promote tests passed"
