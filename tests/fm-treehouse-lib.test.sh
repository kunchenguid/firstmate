#!/usr/bin/env bash
# Tests for bin/fm-treehouse-lib.sh, the treehouse path-spelling translation
# bin/fm-teardown.sh and bin/fm-home-seed.sh use before calling `treehouse return`.
#
# The bug these exist for: `treehouse return <path>` matches its argument against
# the pool's recorded worktree paths without resolving a symlink, while treehouse
# records the spelling derived from its own $HOME. On a host whose home directory
# is a symlink - /home/x -> /data00/home/x - the pool records
# /home/x/.treehouse/<pool>/1/<repo> and firstmate, which stores every path
# canonicalized with `pwd -P`, hands back /data00/home/x/.treehouse/... .
# Every return failed with "worktree ... is not managed by treehouse", aborting
# every task teardown and every leased-home release on that host. Reproduced on
# treehouse v2.1.0 (2026-07-28) against a scratch pool under a symlinked HOME.
#
# The fixtures build their own symlinked pool root rather than depending on any
# real host layout, so the same case is covered on a host where the home
# directory is not a symlink at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-path-lib.sh disable=SC1091
. "$ROOT/bin/fm-path-lib.sh"
# shellcheck source=bin/fm-treehouse-lib.sh disable=SC1091
. "$ROOT/bin/fm-treehouse-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-lib-tests)

# make_pool <case> <recorded-prefix-kind> echoes "<physical-worktree> <recorded-path>".
# Builds <case>/real/.treehouse/proj-abc123/1/proj plus a <case>/link symlink to
# <case>/real, and writes a pool state file recording the requested spelling.
make_pool() {
  local case_name=$1 recorded_kind=$2 base real link pool wt recorded
  base="$TMP_ROOT/$case_name"
  real="$base/real"
  link="$base/link"
  pool="$real/.treehouse/proj-abc123"
  wt="$pool/1/proj"
  mkdir -p "$wt"
  ln -s "$real" "$link"
  case "$recorded_kind" in
    logical) recorded="$link/.treehouse/proj-abc123/1/proj" ;;
    physical) recorded="$wt" ;;
    *) fail "unknown recorded kind $recorded_kind" ;;
  esac
  cat >"$pool/treehouse-state.json" <<EOF
{
  "worktrees": [
    {
      "name": "1",
      "path": "$recorded",
      "created_at": "2026-07-27T20:29:00.427037451+08:00"
    }
  ]
}
EOF
  printf '%s %s\n' "$wt" "$recorded"
}

test_symlinked_recording_translates_back() {
  local wt recorded got
  read -r wt recorded <<<"$(make_pool symlinked logical)"
  # Precondition: the two spellings really are distinct strings for one directory.
  [ "$wt" != "$recorded" ] || fail "fixture spellings are not distinct"
  fm_same_physical_dir "$wt" "$recorded" || fail "fixture spellings are not the same directory"

  got=$(fm_treehouse_recorded_path "$wt") || fail "no recorded path found for a symlink-aliased worktree"
  [ "$got" = "$recorded" ] || fail "translated to '$got', expected the recorded '$recorded'"
  got=$(fm_treehouse_return_path "$wt")
  [ "$got" = "$recorded" ] || fail "return path was '$got', expected the recorded '$recorded'"
  pass "a canonical path translates back to treehouse's symlinked recorded spelling"
}

test_non_symlinked_recording_is_unchanged() {
  local wt recorded got
  read -r wt recorded <<<"$(make_pool plain physical)"
  [ "$wt" = "$recorded" ] || fail "fixture should record the physical spelling"
  # The non-symlinked host must keep working unchanged: same string in, same out.
  got=$(fm_treehouse_return_path "$wt")
  [ "$got" = "$wt" ] || fail "return path was '$got', expected the unchanged '$wt'"
  pass "a pool that recorded the physical spelling is passed through unchanged"
}

test_logical_input_also_resolves() {
  local wt recorded got logical
  read -r wt recorded <<<"$(make_pool logicalin logical)"
  logical=$recorded
  # A caller that already holds the logical spelling must get it back, not lose it.
  got=$(fm_treehouse_return_path "$logical")
  [ "$got" = "$recorded" ] || fail "return path was '$got', expected '$recorded'"
  [ "$wt" != "$logical" ] || fail "fixture spellings are not distinct"
  pass "an already-logical path still resolves to the recorded spelling"
}

test_unrelated_recorded_entry_is_never_used() {
  local base real pool wt other got
  base="$TMP_ROOT/unrelated"
  real="$base/real"
  pool="$real/.treehouse/proj-abc123"
  wt="$pool/1/proj"
  other="$pool/2/proj"
  mkdir -p "$wt" "$other"
  cat >"$pool/treehouse-state.json" <<EOF
{
  "worktrees": [
    {
      "name": "2",
      "path": "$other"
    }
  ]
}
EOF
  # The pool knows a DIFFERENT worktree. Translating to it would return the wrong
  # directory, so the device+inode check must reject it and keep the caller's path.
  fm_treehouse_recorded_path "$wt" >/dev/null && fail "a different worktree's entry was accepted as a translation"
  got=$(fm_treehouse_return_path "$wt")
  [ "$got" = "$wt" ] || fail "return path was '$got', expected the unchanged '$wt'"
  pass "a recorded entry for a different directory is rejected, not used"
}

test_missing_pool_state_falls_back() {
  local dir got
  dir="$TMP_ROOT/nopool/a/b/c"
  mkdir -p "$dir"
  # Not a treehouse pool at all: no state file, so behavior is exactly as before.
  fm_treehouse_recorded_path "$dir" >/dev/null && fail "a directory outside any pool reported a recorded path"
  got=$(fm_treehouse_return_path "$dir")
  [ "$got" = "$dir" ] || fail "return path was '$got', expected the unchanged '$dir'"
  pass "a directory with no pool state falls back to the caller's own path"
}

test_missing_directory_never_translates() {
  local got
  fm_treehouse_recorded_path "$TMP_ROOT/gone/1/proj" >/dev/null && fail "a missing directory reported a recorded path"
  fm_treehouse_recorded_path "" >/dev/null && fail "an empty path reported a recorded path"
  got=$(fm_treehouse_return_path "$TMP_ROOT/gone/1/proj")
  [ "$got" = "$TMP_ROOT/gone/1/proj" ] || fail "return path was '$got', expected the unchanged input"
  pass "a missing or empty path is never translated"
}

test_state_paths_reads_every_entry() {
  local base pool count
  base="$TMP_ROOT/multi"
  pool="$base/.treehouse/proj-abc123"
  mkdir -p "$pool"
  # Field-per-line shape, matching the indented JSON treehouse writes.
  cat >"$pool/treehouse-state.json" <<'EOF'
{
  "worktrees": [
    {
      "name": "1",
      "path": "/one/1/proj",
      "created_at": "2026-07-27T20:29:00.427037451+08:00"
    },
    {
      "name": "2",
      "path": "/two/2/proj"
    }
  ]
}
EOF
  count=$(fm_treehouse_state_paths "$pool/treehouse-state.json" | grep -c .)
  [ "$count" = 2 ] || fail "read $count recorded paths, expected 2"
  fm_treehouse_state_paths "$pool/treehouse-state.json" | grep -qx '/one/1/proj' \
    || fail "first recorded path was not read verbatim"
  fm_treehouse_state_paths "$pool/treehouse-state.json" | grep -qx '/two/2/proj' \
    || fail "second recorded path was not read verbatim"
  pass "every recorded path is read verbatim from the pool state"
}

test_teardown_and_seed_use_the_translation() {
  # The fix is only real if the two boundaries actually call it; pin that so a
  # future edit cannot quietly go back to passing the canonical path.
  grep -q 'fm_treehouse_return_path' "$ROOT/bin/fm-teardown.sh" \
    || fail "bin/fm-teardown.sh no longer translates the treehouse return path"
  # shellcheck disable=SC2016 # The patterns match literal shell source text.
  grep -q 'treehouse return --force "\$return_path"' "$ROOT/bin/fm-teardown.sh" \
    || fail "bin/fm-teardown.sh calls treehouse return with an untranslated path"
  # shellcheck disable=SC2016 # The patterns match literal shell source text.
  grep -q 'treehouse return --force "\$dir"' "$ROOT/bin/fm-teardown.sh" \
    && fail "bin/fm-teardown.sh still has a treehouse return on the untranslated dir"
  grep -q 'fm_treehouse_return_path' "$ROOT/bin/fm-home-seed.sh" \
    || fail "bin/fm-home-seed.sh no longer translates the treehouse return path"
  # shellcheck disable=SC2016 # The patterns match literal shell source text.
  grep -q 'treehouse return --force "\$abs_home"' "$ROOT/bin/fm-home-seed.sh" \
    && fail "bin/fm-home-seed.sh still has a treehouse return on the untranslated home"
  pass "teardown and seed rollback both call the translation before returning"
}

test_symlinked_recording_translates_back
test_non_symlinked_recording_is_unchanged
test_logical_input_also_resolves
test_unrelated_recorded_entry_is_never_used
test_missing_pool_state_falls_back
test_missing_directory_never_translates
test_state_paths_reads_every_entry
test_teardown_and_seed_use_the_translation

echo "# all fm-treehouse-lib tests passed"
