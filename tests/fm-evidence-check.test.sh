#!/usr/bin/env bash
# Tests for bin/fm-evidence-check.sh: the deterministic check that catches a
# byte-identical before/after evidence image pair, the fabricated-verification
# shape a crewmate produced once (correctly named files, real code fix, but a
# before/after pair that never actually differed).
#
# Matrix:
#   (a) an identical before-<suffix>/after-<suffix> pair is refused (git ref mode)
#   (b) a genuinely different pair passes
#   (c) an after-only set passes silently (no before counterpart)
#   (d) a tree with no images passes silently
#   (e) the reversed <prefix>-before/<prefix>-after convention is also paired
#   (f) a shared leading ordinal pairs images whose suffix describes state
#       rather than a shared viewport name (real filenames from
#       we-pack-together's docs/pr-assets/sidebar-silent-discard)
#   (g) a before/after set with no shared suffix or ordinal refuses loudly
#       rather than printing a bare "ok" having verified nothing
#   (h) a leftover, differently-named pair beside an already-matched pair in
#       the same directory still refuses instead of being silently dropped
#   (i) the .allow-identical marker opts an identical pair back in
#   (j) --local mode hashes files on disk instead of reading a git ref
#   (k) usage errors exit 2 without touching git
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CHECK="$ROOT/bin/fm-evidence-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-evidence-check-tests)

# write_png <path> <bytes>: write literal bytes standing in for image content.
write_png() {
  printf '%s' "$2" > "$1"
}

# init_repo <dir>: a fresh git repo with one initial commit so ls-tree has a
# HEAD to read; callers add fixture files and commit again themselves.
init_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf init > "$dir/.gitkeep"
  git -C "$dir" add .gitkeep
  git -C "$dir" commit -qm initial
}

commit_all() {
  local dir=$1
  git -C "$dir" add -A
  git -C "$dir" commit -qm fixture
}

test_identical_pair_refused() {
  local dir rc out err
  dir="$TMP_ROOT/identical"
  init_repo "$dir"
  write_png "$dir/before-desktop-1280.png" SAMEBYTES
  write_png "$dir/after-desktop-1280.png" SAMEBYTES
  commit_all "$dir"

  out="$dir/stdout"; err="$dir/stderr"
  set +e
  "$CHECK" --ref HEAD --root "$dir" > "$out" 2> "$err"
  rc=$?
  set -e

  expect_code 1 "$rc" "identical: fm-evidence-check should refuse"
  assert_grep 'refused: byte-identical before/after pair' "$err" \
    "identical: refusal did not explain the pair"
  assert_grep 'before-desktop-1280.png == after-desktop-1280.png' "$err" \
    "identical: refusal did not name both files"
  pass "fm-evidence-check refuses a byte-identical before/after pair"
}

test_different_pair_passes() {
  local dir rc
  dir="$TMP_ROOT/different"
  init_repo "$dir"
  write_png "$dir/before-mobile.png" OLDBYTES
  write_png "$dir/after-mobile.png" NEWBYTES
  commit_all "$dir"

  set +e
  "$CHECK" --ref HEAD --root "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "different: fm-evidence-check should pass a real before/after change"
  pass "fm-evidence-check passes a genuinely different before/after pair"
}

test_after_only_set_passes_silently() {
  local dir rc
  dir="$TMP_ROOT/after-only"
  init_repo "$dir"
  write_png "$dir/after-card-one.png" CARDONE
  write_png "$dir/after-card-two.png" CARDTWO
  commit_all "$dir"

  set +e
  "$CHECK" --ref HEAD --root "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "after-only: an after-only set must not be a failure"
  [ ! -s "$dir/stderr" ] || fail "after-only: unexpected stderr output: $(cat "$dir/stderr")"
  pass "fm-evidence-check silently passes a legitimate after-only image set"
}

test_no_images_passes_silently() {
  local dir rc
  dir="$TMP_ROOT/no-images"
  init_repo "$dir"

  set +e
  "$CHECK" --ref HEAD --root "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-images: a tree with no evidence images must pass"
  pass "fm-evidence-check silently passes a tree with no images"
}

test_reversed_convention_paired() {
  local dir rc err
  dir="$TMP_ROOT/reversed"
  init_repo "$dir"
  write_png "$dir/sample-before.png" SAMEBYTES
  write_png "$dir/sample-after.png" SAMEBYTES
  commit_all "$dir"

  err="$dir/stderr"
  set +e
  "$CHECK" --ref HEAD --root "$dir" > "$dir/stdout" 2> "$err"
  rc=$?
  set -e

  expect_code 1 "$rc" "reversed: <prefix>-before/<prefix>-after must still be paired"
  assert_grep 'sample-before.png == sample-after.png' "$err" \
    "reversed: refusal did not name the reversed-convention pair"
  pass "fm-evidence-check pairs the reversed <prefix>-before/<prefix>-after convention"
}

test_ordinal_pairs_state_described_suffixes() {
  # Real filenames from we-pack-together's docs/pr-assets/sidebar-silent-discard
  # (commit d71bc9c): the suffix after before-/after- describes the state
  # rather than a shared viewport name, so only a shared leading "<N>-"
  # ordinal pairs them.
  local dir rc
  dir="$TMP_ROOT/ordinal"
  init_repo "$dir"
  write_png "$dir/before-1-typed-not-saved.png" DRAFTBYTES
  write_png "$dir/after-1-typed-with-save-button.png" SAVEDBYTES
  write_png "$dir/before-2-reopened-empty-data-lost.png" LOSTBYTES
  write_png "$dir/after-2-reopened-persisted.png" KEPTBYTES
  commit_all "$dir"

  set +e
  "$CHECK" --ref HEAD --root "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "ordinal: a genuinely different ordinal-paired set must pass"
  assert_grep 'pairs_checked=2' "$dir/stdout" \
    "ordinal: both ordinal pairs were not counted as checked"
  pass "fm-evidence-check pairs before/after images on a shared leading ordinal"
}

test_unpairable_set_refuses_not_silent_ok() {
  # An honest worker's before/after set whose suffixes differ with no shared
  # leading ordinal either: exact-suffix and ordinal matching both find
  # nothing, so this must be a loud refusal, never a silent "ok" that implies
  # verification happened when it did not.
  local dir rc out err
  dir="$TMP_ROOT/unpairable"
  init_repo "$dir"
  write_png "$dir/before-empty-cart.png" EMPTYBYTES
  write_png "$dir/after-checkout-complete.png" DONEBYTES
  commit_all "$dir"

  out="$dir/stdout"; err="$dir/stderr"
  set +e
  "$CHECK" --ref HEAD --root "$dir" > "$out" 2> "$err"
  rc=$?
  set -e

  expect_code 1 "$rc" "unpairable: an unpaired before/after set must refuse, not pass"
  assert_no_grep 'fm-evidence-check: ok' "$out" \
    "unpairable: a bare ok was printed despite pairing nothing"
  assert_grep 'none could be paired' "$err" \
    "unpairable: refusal did not explain that nothing could be paired"
  assert_grep 'before-empty-cart.png' "$err" \
    "unpairable: refusal did not name the unpaired before image"
  assert_grep 'after-checkout-complete.png' "$err" \
    "unpairable: refusal did not name the unpaired after image"
  pass "fm-evidence-check refuses (not a silent ok) when before/after images cannot be paired at all"
}

test_leftover_pair_beside_matched_pair_refuses() {
  # A directory can hold one legitimately matched pair alongside a second,
  # differently-named pair that never matched by suffix or ordinal. The
  # leftover pair must still be reported as unpaired rather than silently
  # dropped just because the directory already matched something else.
  local dir rc out err
  dir="$TMP_ROOT/leftover-beside-matched"
  init_repo "$dir"
  write_png "$dir/before-desktop.png" OLDBYTES
  write_png "$dir/after-desktop.png" NEWBYTES
  write_png "$dir/before-extra-thing.png" SNEAKYBYTES
  write_png "$dir/after-different-name.png" SNEAKYBYTES
  commit_all "$dir"

  out="$dir/stdout"; err="$dir/stderr"
  set +e
  "$CHECK" --ref HEAD --root "$dir" > "$out" 2> "$err"
  rc=$?
  set -e

  expect_code 1 "$rc" "leftover-beside-matched: a leftover pair must refuse even beside a matched pair"
  assert_no_grep 'fm-evidence-check: ok' "$out" \
    "leftover-beside-matched: a bare ok was printed despite an unpaired leftover"
  assert_grep 'before-extra-thing.png' "$err" \
    "leftover-beside-matched: refusal did not name the leftover before image"
  assert_grep 'after-different-name.png' "$err" \
    "leftover-beside-matched: refusal did not name the leftover after image"
  pass "fm-evidence-check refuses a leftover unpaired image even beside a matched pair"
}

test_allow_identical_marker_opts_in() {
  local dir rc out
  dir="$TMP_ROOT/opt-out"
  init_repo "$dir"
  write_png "$dir/before-noop.png" SAMEBYTES
  write_png "$dir/after-noop.png" SAMEBYTES
  : > "$dir/after-noop.png.allow-identical"
  commit_all "$dir"

  out="$dir/stdout"
  set +e
  "$CHECK" --ref HEAD --root "$dir" > "$out" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "opt-out: a marked identical pair must not refuse the merge"
  assert_grep 'identical-ok (opted out): before-noop.png == after-noop.png' "$out" \
    "opt-out: opted-out pair was not reported"
  pass "fm-evidence-check lets an explicit .allow-identical marker through"
}

test_local_mode_hashes_disk_files() {
  local dir rc err
  dir="$TMP_ROOT/local-mode"
  mkdir -p "$dir"
  write_png "$dir/before-widget.png" SAMEBYTES
  write_png "$dir/after-widget.png" SAMEBYTES

  err="$dir/stderr"
  set +e
  "$CHECK" --local "$dir" > "$dir/stdout" 2> "$err"
  rc=$?
  set -e

  expect_code 1 "$rc" "local-mode: an identical on-disk pair must be refused"
  assert_grep "$dir/before-widget.png == $dir/after-widget.png" "$err" \
    "local-mode: refusal did not name the on-disk pair"
  pass "fm-evidence-check --local hashes files on disk without a git ref"
}

test_usage_errors_exit_2() {
  local rc

  set +e
  "$CHECK" > /dev/null 2>/dev/null
  rc=$?
  set -e
  expect_code 2 "$rc" "usage: no arguments at all"

  set +e
  "$CHECK" --local > /dev/null 2>/dev/null
  rc=$?
  set -e
  expect_code 2 "$rc" "usage: --local with no paths"

  set +e
  "$CHECK" --ref > /dev/null 2>/dev/null
  rc=$?
  set -e
  expect_code 2 "$rc" "usage: --ref with no value"

  pass "fm-evidence-check exits 2 on usage errors"
}

test_identical_pair_refused
test_different_pair_passes
test_after_only_set_passes_silently
test_no_images_passes_silently
test_reversed_convention_paired
test_ordinal_pairs_state_described_suffixes
test_unpairable_set_refuses_not_silent_ok
test_leftover_pair_beside_matched_pair_refuses
test_allow_identical_marker_opts_in
test_local_mode_hashes_disk_files
test_usage_errors_exit_2
