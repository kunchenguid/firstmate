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
# is the answer, no network is involved, and the remote field says "-" so the
# caller reads the local ref instead of trying to fetch from a remote that is not
# there.
test_no_remote_uses_the_local_default() {
  local rec out
  rec=$(make_case no-remote)
  read_case "$rec"
  git -C "$PROJ" remote remove origin

  out=$(resolve "$PROJ")
  [ "$out" = "main local-default -" ] \
    || fail "expected the clone's own default branch and no remote, got: $out"
  pass "a project with no remote resolves to its own local default branch"
}

# A remote-less clone declaring base= names a branch, not a remote to fetch it
# from, so the remote field must be "-" here too. Reporting a remote that does not
# exist is what made this combination unable to spawn at all.
test_no_remote_declared_override_reports_no_remote() {
  local rec out
  rec=$(make_case no-remote-declared)
  read_case "$rec"
  add_branch "$BARE" "$CASE_DIR/upstream.work" release
  git -C "$PROJ" fetch -q origin release:refs/heads/release
  git -C "$PROJ" remote remove origin
  register '- project [local-only base=release] - fixture (added 2026-08-02)'

  out=$(resolve "$PROJ")
  [ "$out" = "release project-override -" ] \
    || fail "expected the declared branch with no remote to fetch it from, got: $out"
  pass "a remote-less project's declared base branch reports no remote to fetch from"
}

# The clone the fleet cuts worktrees from can be sitting anywhere. Resolving from
# the checked-out HEAD would hand every worker whatever stray branch the clone was
# left on; bin/fm-ff-lib.sh's default_branch guards against exactly that.
test_no_remote_stranded_on_a_feature_branch_still_resolves_the_default() {
  local rec out
  rec=$(make_case no-remote-stranded)
  read_case "$rec"
  git -C "$PROJ" remote remove origin
  git -C "$PROJ" checkout -q -b someones-feature-branch

  out=$(resolve "$PROJ")
  [ "$out" = "main local-default -" ] \
    || fail "expected the clone's default branch, not whatever it was left on, got: $out"
  pass "a remote-less clone stranded on a feature branch still resolves its default branch"
}

# "none" is reserved for a clone that names no default branch anywhere: no remote,
# no surviving default-branch ref, and no main/master. A detached HEAD alone is not
# that case - the test above proves a detached or stranded clone still resolves its
# default branch and the worker is placed there.
test_no_resolvable_default_reports_none() {
  local rec out
  rec=$(make_case no-remote-no-default)
  read_case "$rec"
  git -C "$PROJ" remote remove origin
  git -C "$PROJ" checkout -q --detach HEAD
  git -C "$PROJ" branch -qm main trunk

  out=$(resolve "$PROJ")
  [ "$out" = "- none -" ] || fail "expected a three-field none result, got: $out"
  pass "a remote-less clone with no resolvable default reports none rather than inventing one"
}

# An unresponsive remote is the failure mode an unreachable one is not: nothing
# refuses, nothing succeeds, the spawn just stops. The bound turns it back into
# the same loud refusal. git's ext:: transport runs the named command AS the
# transport, so this hangs with no network involved at all.
test_unresponsive_remote_is_bounded_and_refuses() {
  local rec out status started elapsed
  rec=$(make_case unresponsive)
  read_case "$rec"
  git -C "$PROJ" config protocol.ext.allow always
  git -C "$PROJ" remote set-url origin "ext::sleep 10"

  started=$(date +%s)
  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_GIT_NET_TIMEOUT=1 "$RESOLVE" "$PROJ" 2>&1)
  status=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] || fail "an unresponsive remote must refuse rather than resolve"
  [ "$elapsed" -lt 10 ] || fail "the default-branch read was not bounded (took ${elapsed}s)"
  assert_contains "$out" "did not answer within 1s" "refusal did not say the read timed out"
  assert_not_contains "$out" "main remote-default" "a timeout must not fall back to the stale cached default"

  # The declared-override read is a second network call and is bounded too.
  register '- project [no-mistakes base=release] - fixture (added 2026-08-02)'
  started=$(date +%s)
  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_GIT_NET_TIMEOUT=1 "$RESOLVE" "$PROJ" 2>&1)
  status=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] || fail "an unresponsive remote must refuse the declared-branch check too"
  [ "$elapsed" -lt 10 ] || fail "the declared-branch check was not bounded (took ${elapsed}s)"
  assert_contains "$out" "did not answer within 1s" "declared-branch refusal did not say the read timed out"
  assert_not_contains "$out" "release project-override" "a timeout must not resolve the declared branch unverified"
  pass "an unresponsive remote is bounded and refuses loudly instead of hanging the spawn"
}

# A repository that configures remotes but not the one being resolved against is a
# misconfiguration, not a remote-less project. Falling through to the local path
# would read the cached refs/remotes/origin/HEAD this script exists to distrust and
# report it as authoritative.
test_misconfigured_remote_name_refuses() {
  local rec out status
  rec=$(make_case misconfigured-remote)
  read_case "$rec"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_BASE_BRANCH_REMOTE=upstrem "$RESOLVE" "$PROJ" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a remote name the repository does not configure must refuse"
  assert_contains "$out" 'project "project"' "refusal did not name the project"
  assert_contains "$out" "upstrem" "refusal did not name the missing remote"
  assert_contains "$out" "origin" "refusal did not name the remotes the repository does configure"
  assert_not_contains "$out" "local-default" "a misconfigured remote must not resolve from the local cache"
  pass "a remote name the repository does not configure refuses instead of silently resolving locally"
}

# The bounded runner must never report a command that did not complete as success.
# A signal-killed `git fetch` reported as exit 0 would send bin/fm-spawn.sh on to
# `checkout --detach FETCH_HEAD`, and a pooled worktree still holds FETCH_HEAD from
# some earlier task's fetch - the silent wrong-code placement this branch exists to
# eliminate. Nothing here touches the network.
test_bounded_run_reports_signal_deaths_as_failure() {
  local status out
  set +e
  ( . "$ROOT/bin/fm-git-net-lib.sh"; fm_git_net_run bash -c 'kill -TERM $$; sleep 30' )
  status=$?
  set -e
  [ "$status" -eq 143 ] \
    || fail "a signal-killed bounded command must report 128+signal, got: $status"

  # The perl watchdog is the branch stock macOS actually takes, so it is exercised
  # explicitly rather than only where coreutils happens to be absent.
  set +e
  ( . "$ROOT/bin/fm-git-net-lib.sh"
    FM_GIT_NET_FORCE_FALLBACK=1 fm_git_net_run bash -c 'kill -TERM $$; sleep 30' )
  status=$?
  set -e
  [ "$status" -eq 143 ] \
    || fail "the perl watchdog must report a signal death as failure, got: $status"

  out=$( . "$ROOT/bin/fm-git-net-lib.sh"; fm_git_net_reason 143 )
  assert_contains "$out" "killed by signal 15" "the refusal reason did not name the signal"
  pass "a bounded command killed by a signal is reported as a failure, not as success"
}

# The deadline itself, on every branch, with no remote involved at all.
test_bounded_run_deadline_is_hard_on_every_branch() {
  local status out
  set +e
  ( . "$ROOT/bin/fm-git-net-lib.sh"; FM_GIT_NET_TIMEOUT=1 fm_git_net_run sleep 30 )
  status=$?
  set -e
  [ "$status" -eq 124 ] || fail "the deadline must report 124, got: $status"

  # A command that ignores SIGTERM must still be killed at the deadline rather
  # than left to hang past it.
  set +e
  ( . "$ROOT/bin/fm-git-net-lib.sh"
    FM_GIT_NET_TIMEOUT=1 fm_git_net_run bash -c 'trap "" TERM; sleep 30' )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a SIGTERM-ignoring command must not be reported as success"

  set +e
  ( . "$ROOT/bin/fm-git-net-lib.sh"
    FM_GIT_NET_TIMEOUT=1 FM_GIT_NET_FORCE_FALLBACK=1 fm_git_net_run sleep 30 )
  status=$?
  set -e
  [ "$status" -eq 124 ] || fail "the perl watchdog must report the deadline as 124, got: $status"

  out=$( . "$ROOT/bin/fm-git-net-lib.sh"; FM_GIT_NET_TIMEOUT=1 fm_git_net_reason 124 )
  assert_contains "$out" "did not answer within 1s" "the deadline reason did not name the bound"
  out=$( . "$ROOT/bin/fm-git-net-lib.sh"; fm_git_net_reason 125 )
  assert_not_contains "$out" "could not start" \
    "GNU timeout's own 125 must not be reported as a missing watchdog"
  pass "the deadline is hard on every watchdog branch and each refusal reason is distinct"
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
test_unresponsive_remote_is_bounded_and_refuses
test_no_remote_uses_the_local_default
test_no_remote_declared_override_reports_no_remote
test_no_remote_stranded_on_a_feature_branch_still_resolves_the_default
test_no_resolvable_default_reports_none
test_misconfigured_remote_name_refuses
test_bounded_run_reports_signal_deaths_as_failure
test_bounded_run_deadline_is_hard_on_every_branch
test_name_override_selects_the_registry_entry

echo "# all fm-base-branch tests passed"
