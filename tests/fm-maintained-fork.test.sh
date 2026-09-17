#!/usr/bin/env bash
# Behavior tests for the maintained-fork source relationship.
#
# The suite proves routine synchronization does not adopt backup changes, an
# upstream pushurl is rejected, explicit release integration merges in isolation,
# and ordinary registry projects keep their existing posture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-maintained-fork)
SCRIPT="$ROOT/bin/fm-maintained-fork.sh"
MODE="$ROOT/bin/fm-project-mode.sh"

commit_file() {
  local dir=$1 file=$2 content=$3 message=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$message"
}

new_fixture() {
  local root=$TMP_ROOT/world project seed backup upstream_seed upstream
  root="$TMP_ROOT/world"
  rm -rf "$root"
  seed="$root/seed"
  backup="$root/backup.git"
  upstream="$root/upstream.git"
  mkdir -p "$root/home/data" "$root/home/projects"
  git init -q "$seed"
  git -C "$seed" symbolic-ref HEAD refs/heads/main
  commit_file "$seed" base.txt base base
  git clone -q --bare "$seed" "$backup"
  git clone -q --bare "$seed" "$upstream"
  upstream_seed="$root/upstream-seed"
  git clone -q "$upstream" "$upstream_seed"
  commit_file "$upstream_seed" upstream.txt release release
  git -C "$upstream_seed" tag v1
  git -C "$upstream_seed" push -q origin main v1
  project="$root/home/projects/fork"
  git clone -q "$backup" "$project"
  git -C "$project" remote add upstream "$upstream"
  git -C "$project" config remote.upstream.pushurl ''
  commit_file "$project" custom.txt custom custom
  printf '%s\n' '- fork [local-only +maintained-fork] - maintained fork (added 2026-09-03)' \
    > "$root/home/data/projects.md"
  printf '%s\n' "$root"
}

run_fork() {
  local root=$1
  shift
  FM_HOME="$root/home" FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT" "$@"
}

run_mode() {
  local root=$1
  shift
  FM_HOME="$root/home" FM_ROOT_OVERRIDE="$ROOT" "$MODE" "$@"
}

test_registry_source_and_ordinary_default() {
  local root out
  root=$(new_fixture)
  out=$(run_mode "$root" fork 2>/dev/null)
  [ "$out" = "local-only off" ] || fail "maintained-fork changed the delivery posture: $out"
  out=$(run_mode "$root" --source fork 2>/dev/null)
  [ "$out" = maintained-fork ] || fail "maintained-fork source was not exposed: $out"
  out=$(FM_HOME="$root/home" FM_ROOT_OVERRIDE="$ROOT" "$MODE" --source absent 2>/dev/null)
  [ "$out" = ordinary ] || fail "missing project was not ordinary: $out"
  pass "maintained-fork source stays orthogonal to delivery mode and ordinary projects"
}

test_upstream_pushurl_is_rejected() {
  local root project err
  root=$(new_fixture)
  project="$root/home/projects/fork"
  git -C "$project" config remote.upstream.pushurl "$root/unwanted-push-target"
  set +e
  err=$(run_fork "$root" integrate fork v1 2>&1 >/dev/null)
  set -e
  assert_contains "$err" "upstream must be fetch-only with an explicitly empty pushurl" \
    "an upstream push target was accepted"
  pass "maintained-fork integration rejects an upstream push target"
}

test_explicit_merge_and_local_acceptance() {
  local root project before out branch candidate_sha origin_sha parents
  root=$(new_fixture)
  project="$root/home/projects/fork"
  before=$(git -C "$project" rev-parse main)
  origin_sha=$(git -C "$project" rev-parse origin/main)
  out=$(run_fork "$root" integrate fork v1 --test-command 'test -f upstream.txt')
  assert_contains "$out" "candidate ready:" "integration did not produce a candidate"
  [ "$(git -C "$project" rev-parse main)" = "$before" ] \
    || fail "integration landed before local acceptance"
  branch=$(sed -n 's/^candidate ready: //p' <<<"$out")
  candidate_sha=$(git -C "$project" rev-parse "$branch")
  [ "$candidate_sha" != "$before" ] || fail "candidate did not merge the upstream release"
  out=$(run_fork "$root" accept fork)
  assert_contains "$out" "accepted locally:" "local acceptance did not land the candidate"
  [ "$(git -C "$project" rev-parse main)" = "$candidate_sha" ] \
    || fail "accepted default branch did not reach the validated candidate"
  [ "$(git -C "$project" rev-parse origin/main)" = "$origin_sha" ] \
    || fail "backup origin moved without a separate push"
  parents=$(git -C "$project" rev-list --parents -n1 main | wc -w | tr -d ' ')
  [ "$parents" -eq 3 ] || fail "integration did not preserve a two-parent merge commit"
  pass "explicit upstream release merges in isolation and lands only after local acceptance"
}

test_registry_source_and_ordinary_default
test_upstream_pushurl_is_rejected
test_explicit_merge_and_local_acceptance
printf '%s\n' '# all maintained-fork tests passed'
