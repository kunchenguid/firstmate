#!/usr/bin/env bash
# bin/fm-conflict-marker-check.sh must fail a tracked tree that carries an
# unresolved conflict marker and pass one that does not.
#
# The guard exists because a squash merge landed a marker block inside AGENTS.md,
# the always-loaded instruction file, where it read as authoritative text until a
# human happened to notice. Every marker in this test is assembled at runtime, so
# this file never carries a literal marker and is never itself an exclusion case.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/bin/fm-conflict-marker-check.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=""
cleanup() {
  # Pinned to this test's own temp root and never to an empty path, so cleanup
  # can never reach the checkout the tests live in.
  [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ] && rm -rf "$TMP_ROOT"
  return 0
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-conflict-marker.XXXXXX") \
  || fail "could not create a temp root"

repeat_char() {
  local char=$1 count=$2 out='' i=0
  while [ "$i" -lt "$count" ]; do
    out="$out$char"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

OURS="$(repeat_char '<' 7)"
THEIRS="$(repeat_char '>' 7)"
BASE="$(repeat_char '|' 7)"
SEPARATOR="$(repeat_char '=' 7)"

# Build a fresh tracked-file fixture repo under this test's own temp root and
# echo its path on stdout. Never uses `fail` here: `fail` inside a command
# substitution would kill only the subshell and hand the caller an empty path.
make_fixture_repo() {
  local name=$1 repo
  repo="$TMP_ROOT/$name"
  mkdir -p "$repo" || return 1
  git -C "$repo" init -q || return 1
  git -C "$repo" config user.email fixture@example.invalid || return 1
  git -C "$repo" config user.name fixture || return 1
  printf 'clean line\n' >"$repo/clean.md" || return 1
  git -C "$repo" add -A || return 1
  git -C "$repo" -c commit.gpgsign=false commit -qm fixture || return 1
  printf '%s' "$repo"
}

run_check() {
  local repo=$1
  [ -n "$repo" ] || fail "run_check received an empty repo path"
  "$CHECK" --repo "$repo" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
}

track_file() {
  local repo=$1 path=$2
  git -C "$repo" add -- "$path" \
    && git -C "$repo" -c commit.gpgsign=false commit -qm "add $path"
}

test_clean_tree_passes() {
  local repo status
  repo=$(make_fixture_repo clean) || fail "fixture repo setup failed"
  [ -n "$repo" ] || fail "fixture repo path came back empty"
  run_check "$repo"
  status=$?
  [ "$status" -eq 0 ] || fail "clean tree exited $status, expected 0"
  pass "a tracked tree with no conflict markers passes"
}

test_each_marker_form_fails() {
  local repo status form label
  for form in "$OURS ours" "$THEIRS theirs" "$BASE base"; do
    label=${form#* }
    repo=$(make_fixture_repo "marker-$label") || fail "fixture repo setup failed"
    [ -n "$repo" ] || fail "fixture repo path came back empty"
    {
      printf 'before\n'
      printf '%s HEAD\n' "${form%% *}"
      printf 'ours side\n'
      printf '%s\n' "$SEPARATOR"
      printf 'theirs side\n'
      printf 'after\n'
    } >"$repo/conflicted.md"
    track_file "$repo" conflicted.md || fail "could not track the $label fixture"
    run_check "$repo"
    status=$?
    [ "$status" -eq 1 ] || fail "$label marker exited $status, expected 1"
    grep -q 'conflicted.md' "$TMP_ROOT/err" \
      || fail "$label marker failure did not name the offending file"
    pass "a tracked $label conflict marker fails the check"
  done
}

test_resolution_turns_the_check_green() {
  local repo status
  repo=$(make_fixture_repo resolve) || fail "fixture repo setup failed"
  [ -n "$repo" ] || fail "fixture repo path came back empty"
  {
    printf '%s HEAD\n' "$OURS"
    printf 'ours side\n'
    printf '%s\n' "$SEPARATOR"
    printf 'theirs side\n'
    printf '%s branch\n' "$THEIRS"
  } >"$repo/conflicted.md"
  track_file "$repo" conflicted.md || fail "could not track the conflicted fixture"
  run_check "$repo"
  status=$?
  [ "$status" -eq 1 ] || fail "negative control exited $status, expected 1"

  printf 'theirs side\n' >"$repo/conflicted.md"
  track_file "$repo" conflicted.md || fail "could not track the resolved fixture"
  run_check "$repo"
  status=$?
  [ "$status" -eq 0 ] || fail "resolved tree exited $status, expected 0"
  pass "resolving the marker block turns the same check green"
}

test_untracked_marker_is_not_a_repo_invariant_failure() {
  local repo status
  repo=$(make_fixture_repo untracked) || fail "fixture repo setup failed"
  [ -n "$repo" ] || fail "fixture repo path came back empty"
  printf '%s HEAD\n' "$OURS" >"$repo/scratch.md"
  run_check "$repo"
  status=$?
  [ "$status" -eq 0 ] || fail "untracked marker exited $status, expected 0"
  pass "an untracked working file with a marker does not fail the tracked-tree check"
}

test_setext_heading_underline_is_not_a_marker() {
  local repo status
  repo=$(make_fixture_repo setext) || fail "fixture repo setup failed"
  [ -n "$repo" ] || fail "fixture repo path came back empty"
  printf 'Heading\n%s\n\nbody\n' "$SEPARATOR" >"$repo/doc.md"
  track_file "$repo" doc.md || fail "could not track the setext fixture"
  run_check "$repo"
  status=$?
  [ "$status" -eq 0 ] || fail "setext underline exited $status, expected 0"
  pass "a seven-character setext heading underline is not treated as a marker"
}

test_this_repo_is_clean() {
  local status
  run_check "$ROOT"
  status=$?
  [ "$status" -eq 0 ] || {
    cat "$TMP_ROOT/err" >&2
    fail "this repo carries conflict markers in tracked files"
  }
  pass "this repo's tracked files carry no conflict markers"
}

test_clean_tree_passes
test_each_marker_form_fails
test_resolution_turns_the_check_green
test_untracked_marker_is_not_a_repo_invariant_failure
test_setext_heading_underline_is_not_a_marker
test_this_repo_is_clean
