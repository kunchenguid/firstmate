#!/usr/bin/env bash
# bin/fm-project-env.sh must land local, gitignored env files in a working copy
# without ever leaving something git could stage.
#
# The behaviors under test are the guarantees the spawn path depends on: a fresh
# git worktree gets the file, git still reports nothing to commit, a path the
# project does not ignore is refused rather than copied, and a project with
# nothing stored is a graceful no-op that explains itself instead of producing a
# working copy that fails at runtime.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/fm-project-env.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-project-env-test.XXXXXX") || exit 1
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# A minimal project that ignores .env*.local, like the real ones do.
make_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  printf '.env*.local\n' > "$dir/.gitignore"
  printf 'PUBLIC_KEY=example\n' > "$dir/.env.example"
  git -C "$dir" add .gitignore .env.example
  git -C "$dir" commit -qm init
}

# Sets RC and OUT in the caller's scope. A command substitution would run the
# assignment in a subshell, so RC has to be captured here, not by the caller.
RC=0
OUT=""
run_apply() {  # <store-root> <project> <target>
  local store=$1 project=$2 target=$3
  set +e
  FM_PROJECT_ENV_DIR="$store" "$SCRIPT" apply "$project" "$target" > "$TMP/apply.out" 2>&1
  RC=$?
  set -e
  OUT=$(cat "$TMP/apply.out")
}

set -e

test_applies_into_a_real_new_worktree() {
  local case_dir="$TMP/worktree" store="$TMP/worktree/store" repo wt
  repo="$case_dir/repo"
  wt="$case_dir/wt"
  make_project "$repo"
  mkdir -p "$store/repo"
  printf 'SECRET=from-store\n' > "$store/repo/.env.local"

  # A real `git worktree add`, which is what the spawn path produces, and which
  # is exactly where an ignored file does not come along on its own.
  git -C "$repo" worktree add -q -b wt-branch "$wt"
  [ ! -e "$wt/.env.local" ] || fail "a fresh git worktree unexpectedly already had .env.local"

  run_apply "$store" repo "$wt"
  [ "$RC" -eq 0 ] || fail "apply failed on a fresh worktree: $OUT"
  [ -f "$wt/.env.local" ] || fail "apply did not create .env.local in the worktree"
  [ ! -L "$wt/.env.local" ] || fail "apply created a symlink; it must copy"
  grep -q 'SECRET=from-store' "$wt/.env.local" || fail "applied file has the wrong content"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || fail "git status is not clean after apply: $(git -C "$wt" status --porcelain)"
  pass "a fresh git worktree gets the stored env file and git still reports nothing to commit"
}

test_refuses_a_path_the_project_does_not_ignore() {
  local case_dir="$TMP/unignored" store="$TMP/unignored/store" repo
  repo="$case_dir/repo"
  make_project "$repo"
  mkdir -p "$store/repo"
  printf 'SECRET=leaky\n' > "$store/repo/settings.json"

  run_apply "$store" repo "$repo"
  [ "$RC" -ne 0 ] || fail "apply accepted a path the project does not gitignore"
  [ ! -e "$repo/settings.json" ] || fail "apply created a file git could stage"
  printf '%s' "$OUT" | grep -q 'gitignore' || fail "refusal did not explain the missing ignore rule: $OUT"
  pass "a stored path the project does not ignore is refused, not copied"
}

test_refuses_a_tracked_path() {
  local case_dir="$TMP/tracked" store="$TMP/tracked/store" repo before
  repo="$case_dir/repo"
  make_project "$repo"
  mkdir -p "$store/repo"
  printf 'PUBLIC_KEY=overwritten\n' > "$store/repo/.env.example"
  before=$(cat "$repo/.env.example")

  run_apply "$store" repo "$repo"
  [ "$RC" -ne 0 ] || fail "apply overwrote a tracked file"
  [ "$(cat "$repo/.env.example")" = "$before" ] || fail "apply modified a tracked file"
  printf '%s' "$OUT" | grep -qi 'track' || fail "refusal did not name the tracking problem: $OUT"
  pass "a tracked path is refused rather than hidden or overwritten"
}

test_absent_store_is_graceful_and_explains_itself() {
  local case_dir="$TMP/absent" store="$TMP/absent/store" repo
  repo="$case_dir/repo"
  make_project "$repo"
  mkdir -p "$store"

  run_apply "$store" repo "$repo"
  [ "$RC" -eq 0 ] || fail "an absent store broke apply instead of no-opping: $OUT"
  printf '%s' "$OUT" | grep -q '.env.example' \
    || fail "apply did not report the missing local env file for a project that ships a template: $OUT"
  printf '%s' "$OUT" | grep -q "$store" || fail "apply did not say where the file should live: $OUT"
  pass "a project with nothing stored is a graceful no-op that names the gap and the store path"
}

test_absent_store_is_silent_without_a_template() {
  local case_dir="$TMP/silent" store="$TMP/silent/store" repo
  repo="$case_dir/repo"
  make_project "$repo"
  git -C "$repo" rm -q .env.example
  git -C "$repo" commit -qm "drop template"
  mkdir -p "$store"

  run_apply "$store" repo "$repo"
  [ "$RC" -eq 0 ] || fail "apply failed for a project with no env expectation: $OUT"
  [ -z "$OUT" ] || fail "apply was noisy for a project that needs no env file: $OUT"
  pass "a project with no env expectation and nothing stored produces no output"
}

test_differing_existing_file_is_replaced_out_loud() {
  local case_dir="$TMP/clobber" store="$TMP/clobber/store" repo
  repo="$case_dir/repo"
  make_project "$repo"
  mkdir -p "$store/repo"
  printf 'SECRET=current\n' > "$store/repo/.env.local"
  printf 'SECRET=stale\n' > "$repo/.env.local"

  run_apply "$store" repo "$repo"
  [ "$RC" -eq 0 ] || fail "apply failed over an existing file: $OUT"
  grep -q 'SECRET=current' "$repo/.env.local" || fail "apply left the stale file in place"
  printf '%s' "$OUT" | grep -q 'replaced' || fail "apply replaced a differing file silently: $OUT"

  # An identical file is not worth a line.
  run_apply "$store" repo "$repo"
  if printf '%s' "$OUT" | grep -q 'replaced'; then
    fail "apply announced a replacement for an identical file: $OUT"
  fi
  pass "a differing existing file is replaced with a message, an identical one silently"
}

test_adopt_captures_only_local_files() {
  local case_dir="$TMP/adopt" store="$TMP/adopt/store" repo out mode
  repo="$case_dir/repo"
  make_project "$repo"
  printf 'SECRET=captured\n' > "$repo/.env.local"

  set +e
  out=$(FM_PROJECT_ENV_DIR="$store" "$SCRIPT" adopt repo "$repo" .env.example 2>&1)
  RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail "adopt captured a tracked, non-ignored file"
  [ ! -e "$store/repo/.env.example" ] || fail "adopt stored a file that is not local-only"

  set +e
  out=$(FM_PROJECT_ENV_DIR="$store" "$SCRIPT" adopt repo "$repo" .env.local 2>&1)
  RC=$?
  set -e
  [ "$RC" -eq 0 ] || fail "adopt refused a gitignored local file: $out"
  grep -q 'SECRET=captured' "$store/repo/.env.local" || fail "adopt did not store the file content"
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$store/repo/.env.local")
  else
    mode=$(stat -c %a "$store/repo/.env.local")
  fi
  [ "$mode" = 600 ] || fail "adopt stored the file with mode $mode, expected 600"
  pass "adopt captures a gitignored local file and refuses a tracked one"
}

test_applies_into_a_real_new_worktree
test_refuses_a_path_the_project_does_not_ignore
test_refuses_a_tracked_path
test_absent_store_is_graceful_and_explains_itself
test_absent_store_is_silent_without_a_template
test_differing_existing_file_is_replaced_out_loud
test_adopt_captures_only_local_files
