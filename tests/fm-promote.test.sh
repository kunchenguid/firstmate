#!/usr/bin/env bash
# Tests for bin/fm-promote.sh: a promoted scout receives ship instructions
# naming its task branch through the home's task-branch prefix
# (config/branch-prefix, default fm/; bin/fm-branch-prefix-lib.sh) - the same
# resolution an ordinary scaffolded brief uses - so the promoted worker lands
# on a branch the local landing and review helpers can resolve.
#
# Matrix:
#   (a) absent config -> ship instructions name the default fm/<id> branch
#   (b) custom prefix -> ship instructions name ardy/<id>, Setup and
#       Definition of done agreeing with each other
#   (c) invalid prefix -> refused before any instructions are written, meta
#       stays kind=scout
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-promote-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data"
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/promote-x1.meta" \
    "kind=scout" \
    "window=fm-promote-x1"
  printf '%s\n' "$case_dir"
}

run_promote() {
  local case_dir=$1
  shift
  FM_HOME="$case_dir" \
    "$PROMOTE" promote-x1 "$@"
}

test_default_prefix_names_fm_branch() {
  local case_dir out instr
  case_dir=$(make_case default-prefix)

  out=$(run_promote "$case_dir" --mode local-only --yolo off)

  instr="$case_dir/data/promote-x1/ship-instructions.md"
  assert_present "$instr" "default-prefix: ship instructions were not written"
  assert_grep 'git checkout -b fm/promote-x1' "$instr" \
    "default-prefix: instructions must name the default-prefixed branch"
  assert_grep 'ready in branch fm/promote-x1' "$instr" \
    "default-prefix: Definition of done must keep the default-prefixed branch"
  assert_contains "$out" 'promoted promote-x1 to ship mode=local-only yolo=off' \
    "default-prefix: success line missing"
  pass "fm-promote names the default fm/<id> branch when no prefix is configured"
}

test_custom_prefix_names_renamed_branch_consistently() {
  local case_dir out instr
  case_dir=$(make_case custom-prefix)
  mkdir -p "$case_dir/config"
  printf 'ardy\n' > "$case_dir/config/branch-prefix"

  out=$(run_promote "$case_dir" --mode local-only --yolo off)

  instr="$case_dir/data/promote-x1/ship-instructions.md"
  assert_present "$instr" "custom-prefix: ship instructions were not written"
  assert_grep 'git checkout -b ardy/promote-x1' "$instr" \
    "custom-prefix: instructions must name the renamed branch"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'committed on your branch `ardy/promote-x1`' "$instr" \
    "custom-prefix: Definition of done must name the same renamed branch"
  assert_grep 'ready in branch ardy/promote-x1' "$instr" \
    "custom-prefix: completion line must name the renamed branch"
  assert_no_grep 'fm/promote-x1' "$instr" \
    "custom-prefix: default prefix leaked into renamed-branch instructions"
  pass "fm-promote names the renamed <prefix>/<id> branch consistently with its Definition of done"
}

test_invalid_prefix_refuses_before_writing() {
  local case_dir out err status
  case_dir=$(make_case invalid-prefix)
  mkdir -p "$case_dir/config"
  printf 'ar/dy\n' > "$case_dir/config/branch-prefix"

  out=$(run_promote "$case_dir" --mode local-only --yolo off 2> "$case_dir/stderr")
  status=$?
  err=$(cat "$case_dir/stderr")

  expect_code 1 "$status" "invalid-prefix: promotion must refuse, got $status"
  assert_contains "$err" 'branch-prefix' "invalid-prefix: refusal must name the config file"
  assert_absent "$case_dir/data/promote-x1/ship-instructions.md" \
    "invalid-prefix: refused promotion still wrote ship instructions"
  grep -qx 'kind=scout' "$case_dir/state/promote-x1.meta" \
    || fail "invalid-prefix: refused promotion must leave the meta as kind=scout"
  pass "fm-promote refuses an invalid prefix before writing instructions or flipping the meta"
}

test_default_prefix_names_fm_branch
test_custom_prefix_names_renamed_branch_consistently
test_invalid_prefix_refuses_before_writing
