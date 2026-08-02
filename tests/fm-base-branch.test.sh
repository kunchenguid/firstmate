#!/usr/bin/env bash
# Behavior tests for base-branch resolution (bin/fm-base-branch.sh) and the
# registry override it reads through bin/fm-project-mode.sh --base.
#
# The defect these cover: a clone records the remote's default branch once, at
# clone time, in refs/remotes/<remote>/HEAD, and nothing ever refreshes it. When
# the project later changes its default branch, the clone keeps reporting the old
# one and every worker cut from it reads code nobody works on any more. Every
# fixture below therefore builds a clone whose cached default is genuinely stale
# and asserts resolution comes from the remote's own current state instead.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVE="$ROOT/bin/fm-base-branch.sh"
MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-base-branch)
fm_git_identity

git_c() {
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "${@:2}"
}

commit_file() {  # <repo> <file> <message>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git_c "$1" commit -qm "$3"
}

# make_case <name> builds, under $TMP_ROOT/<name>:
#   upstream.work  a working repo with main and develop
#   upstream.git   the bare remote, default branch develop
#   project        a clone taken BEFORE develop existed, so its cached
#                  refs/remotes/origin/HEAD still says main and it sits on main
#   home           a firstmate home with an empty registry
# develop carries RemoteConfig.txt, which main does not have - the stand-in for
# the subsystem an audit once declared unshipped because it read the wrong branch.
make_case() {
  local name=$1 case_dir work bare proj home
  case_dir="$TMP_ROOT/$name"
  work="$case_dir/upstream.work"
  bare="$case_dir/upstream.git"
  proj="$case_dir/project"
  home="$case_dir/home"
  mkdir -p "$case_dir" "$home/data"
  : > "$home/data/projects.md"

  fm_git_init_commit "$work"
  git -C "$work" branch -qM main
  git clone -q --bare "$work" "$bare"
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  git clone -q "$bare" "$proj"

  git -C "$work" checkout -q -b develop
  commit_file "$work" RemoteConfig.txt "remote config sources"
  git -C "$work" push -q "$bare" develop
  git -C "$bare" symbolic-ref HEAD refs/heads/develop

  printf '%s|%s|%s|%s\n' "$case_dir" "$bare" "$proj" "$home"
}

read_case() {
  IFS='|' read -r CASE_DIR BARE PROJ HOME_DIR <<EOF
$1
EOF
}

add_branch() {  # <case-bare> <work> <branch>
  git -C "$2" checkout -q -b "$3"
  commit_file "$2" "$3.txt" "$3 branch content"
  git -C "$2" push -q "$1" "$3"
}

resolve() {  # <project-dir> [extra args...]
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$RESOLVE" "$@" 2>&1
}

register() {  # <line>
  printf '%s\n' "$1" > "$HOME_DIR/data/projects.md"
}

# The core regression: no override anywhere, a clone whose cached default is
# stale, and resolution must still name the remote's current default.
test_stale_cached_default_is_not_trusted() {
  local rec out cached
  rec=$(make_case stale-cache)
  read_case "$rec"

  cached=$(git -C "$PROJ" symbolic-ref refs/remotes/origin/HEAD)
  [ "$cached" = "refs/remotes/origin/main" ] \
    || fail "fixture did not produce a stale cached default (got $cached)"
  [ "$(git -C "$PROJ" rev-parse --abbrev-ref HEAD)" = main ] \
    || fail "fixture clone should be sitting on the stale default branch"

  out=$(resolve "$PROJ")
  [ "$out" = "develop remote-default $(printf origin)" ] \
    || fail "expected the remote's current default branch, got: $out"
  pass "a stale cached refs/remotes/origin/HEAD is not trusted; the remote's own default wins"
}

# The escape hatch: a project whose development branch is genuinely not the
# remote default declares it, and the declaration beats the remote default.
test_declared_override_wins_over_remote_default() {
  local rec out
  rec=$(make_case declared)
  read_case "$rec"
  add_branch "$BARE" "$CASE_DIR/upstream.work" release
  register '- project [no-mistakes base=release] - fixture (added 2026-08-02)'

  out=$(resolve "$PROJ")
  [ "$out" = "release project-override origin" ] \
    || fail "expected the declared override to win, got: $out"
  pass "a declared base= override beats the remote's default branch"
}

# The override is orthogonal to mode and +yolo, in any token order, and never
# disturbs the delivery mode a pre-existing entry already resolved to.
test_override_is_orthogonal_to_mode_and_yolo() {
  local rec out
  rec=$(make_case orthogonal)
  read_case "$rec"
  add_branch "$BARE" "$CASE_DIR/upstream.work" release

  register '- project [direct-PR +yolo base=release] - fixture (added 2026-08-02)'
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$MODE" project)
  [ "$out" = "direct-PR on" ] || fail "base= disturbed mode/yolo parsing, got: $out"

  register '- project [direct-PR base=release +yolo] - fixture (added 2026-08-02)'
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$MODE" project)
  [ "$out" = "direct-PR on" ] || fail "bracket token order changed mode/yolo, got: $out"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$MODE" --base project)
  [ "$out" = release ] || fail "bracket token order changed the base branch, got: $out"
  pass "base= is order-independent and leaves mode and +yolo untouched"
}

# An entry with no override, and a registry with no entry at all, must both
# report no override rather than inventing one.
test_undeclared_reports_no_override() {
  local rec out
  rec=$(make_case undeclared)
  read_case "$rec"

  register '- project [no-mistakes] - fixture (added 2026-08-02)'
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$MODE" --base project)
  [ -z "$out" ] || fail "a legacy entry should declare no base branch, got: $out"

  : > "$HOME_DIR/data/projects.md"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$MODE" --base project)
  [ -z "$out" ] || fail "an unregistered project should declare no base branch, got: $out"
  pass "an entry without base=, and an unregistered project, declare no override"
}

# A declared branch the remote does not have must refuse, naming both the project
# and the missing branch. Silently falling back is the entire defect.
test_declared_branch_missing_on_remote_refuses() {
  local rec out status
  rec=$(make_case missing-branch)
  read_case "$rec"
  register '- project [no-mistakes base=no-such-branch] - fixture (added 2026-08-02)'

  set +e
  out=$(resolve "$PROJ")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a declared branch missing from the remote must not resolve"
  assert_contains "$out" 'project "project"' "refusal did not name the project"
  assert_contains "$out" 'no-such-branch' "refusal did not name the missing branch"
  assert_not_contains "$out" "develop" "refusal must not quietly offer the remote default instead"
  pass "a declared base branch missing from the remote refuses, naming project and branch"
}

# A registry typo that leaves base= without a usable branch is a hard error too.
test_malformed_declaration_refuses() {
  local rec out status
  rec=$(make_case malformed)
  read_case "$rec"
  register '- project [no-mistakes base=] - fixture (added 2026-08-02)'

  set +e
  out=$(resolve "$PROJ")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "an empty base= declaration must not resolve"
  assert_contains "$out" "project" "malformed-declaration refusal did not name the project"
  pass "a malformed base= declaration refuses instead of falling back"
}

# An unreachable remote is a refusal, not an excuse to reuse the stale cache.
test_unreachable_remote_refuses() {
  local rec out status
  rec=$(make_case unreachable)
  read_case "$rec"
  rm -rf "$BARE"

  set +e
  out=$(resolve "$PROJ")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "an unreachable remote must refuse rather than fall back"
  assert_contains "$out" "project" "unreachable-remote refusal did not name the project"
  assert_not_contains "$out" "main remote-default" "refusal must not emit the stale cached default"
  pass "an unreachable remote refuses rather than falling back to the stale local cache"
}

# A project with no remote has nothing to be stale against; its own default branch
# is the answer, and no network is involved.
test_no_remote_uses_the_local_default() {
  local rec out
  rec=$(make_case no-remote)
  read_case "$rec"
  git -C "$PROJ" remote remove origin

  out=$(resolve "$PROJ")
  [ "$out" = "main local-default origin" ] \
    || fail "expected the clone's own default branch, got: $out"
  pass "a project with no remote resolves to its own local default branch"
}

# A remote-less clone on a detached HEAD names no default branch at all. Reporting
# "none" keeps the caller's pre-existing behavior instead of inventing a branch.
test_no_remote_detached_reports_none() {
  local rec out
  rec=$(make_case no-remote-detached)
  read_case "$rec"
  git -C "$PROJ" remote remove origin
  git -C "$PROJ" checkout -q --detach HEAD

  out=$(resolve "$PROJ")
  [ "$out" = "- none -" ] || fail "expected a three-field none result, got: $out"
  pass "a remote-less detached clone reports none rather than inventing a base branch"
}

# The registry name is the clone's basename by default and --name overrides it,
# so a clone directory named differently from its registry entry still resolves.
test_name_override_selects_the_registry_entry() {
  local rec out
  rec=$(make_case named)
  read_case "$rec"
  add_branch "$BARE" "$CASE_DIR/upstream.work" release
  register '- AscendApp [no-mistakes base=release] - fixture (added 2026-08-02)'

  out=$(resolve "$PROJ")
  [ "$out" = "develop remote-default origin" ] \
    || fail "an entry for another project name must not apply, got: $out"

  out=$(resolve "$PROJ" --name AscendApp)
  [ "$out" = "release project-override origin" ] \
    || fail "--name did not select the registry entry, got: $out"
  pass "--name selects the registry entry when the clone directory is named differently"
}

test_stale_cached_default_is_not_trusted
test_declared_override_wins_over_remote_default
test_override_is_orthogonal_to_mode_and_yolo
test_undeclared_reports_no_override
test_declared_branch_missing_on_remote_refuses
test_malformed_declaration_refuses
test_unreachable_remote_refuses
test_no_remote_uses_the_local_default
test_no_remote_detached_reports_none
test_name_override_selects_the_registry_entry

echo "# all fm-base-branch tests passed"
