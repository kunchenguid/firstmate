#!/usr/bin/env bash
# Behavior tests for the spawn-owned AI commit-trailer strip.
#
# Cursor injects Co-Authored-By after the typed message, so these cases assert
# the commit OBJECT, never the string passed to -m. The strip is the public
# interface; tests drive git commit through the installed hooksPath the same
# way a fleet-launched pane does.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath. These cases set that
# override themselves, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
TMP_ROOT=$(fm_test_tmproot fm-git-strip-ai-trailers)

fm_git_identity 'Captain Tests' 'captain@example.invalid'

with_hooks_env() {  # <hooks-dir> <command...>
  local hooks=$1
  shift
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks "$@"
}

with_launch_env() {
  local hooks=$1 repo=$2 launch
  shift 2
  launch=$("$STRIP" launch-env "$hooks" "$repo") || fail "could not prepare the pane Git environment"
  (eval "$launch"; "$@")
}

supports_config_hooks() {
  git -C "$1" -c hook.fm-test.event=commit-msg -c hook.fm-test.command=true \
    hook list commit-msg >/dev/null 2>&1
}

make_repo() {
  local dir=$1
  fm_git_init_commit "$dir"
}

test_cursor_trailer_does_not_reach_the_commit_object() {
  local repo hooks body author
  repo="$TMP_ROOT/cursor-object"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-cursor"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed on a real git repo"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: keep the typed message clean'
  body=$(git -C "$repo" log -1 --format=%B)
  author=$(git -C "$repo" log -1 --format='%an <%ae>')
  assert_not_contains "$body" "Co-authored-by: Cursor" "Cursor trailer reached the commit object"
  assert_not_contains "$body" "cursoragent@cursor.com" "Cursor email reached the commit object"
  assert_contains "$body" "fix: keep the typed message clean" "subject was rewritten"
  [ "$author" = "Captain Tests <captain@example.invalid>" ] || fail "author was rewritten: $author"
  pass "a Cursor --trailer commit object has no AI co-author and keeps the captain identity"
}


test_human_coauthor_is_kept() {
  local repo hooks body
  repo="$TMP_ROOT/human-coauthor"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-human"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' --trailer 'Co-authored-by: Jane Doe <jane@example.com>' -m 'fix: mixed trailers'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "Cursor" "Cursor trailer was not stripped from a mixed message"
  assert_contains "$body" "Co-authored-by: Jane Doe <jane@example.com>" "human co-author was stripped"
  pass "a human Co-authored-by trailer survives next to a stripped Cursor trailer"
}

test_human_at_a_vendor_domain_is_kept() {
  local repo hooks body
  repo="$TMP_ROOT/vendor-human"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-vendor-human"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q \
    --trailer 'Co-authored-by: Claude <noreply@anthropic.com>' \
    --trailer 'Co-authored-by: Jane Doe <jane@anthropic.com>' \
    --trailer 'Co-authored-by: Sam Roe <sam@cursor.com>' -m 'fix: vendor staff co-authors'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "noreply@anthropic.com" "the Claude bot trailer reached the commit object"
  assert_contains "$body" "Co-authored-by: Jane Doe <jane@anthropic.com>" "a human at a vendor domain was stripped"
  assert_contains "$body" "Co-authored-by: Sam Roe <sam@cursor.com>" "a human at a vendor domain was stripped"
  pass "a human co-author at a vendor domain survives; only the exact bot address is stripped"
}

test_hook_manager_cannot_displace_the_strip() {
  local repo hooks target body
  if [ "$(id -u)" = 0 ]; then
    pass "a hook manager cannot displace the strip (skipped as root)"
    return 0
  fi
  repo="$TMP_ROOT/hook-manager"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-manager"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  target=$(with_hooks_env "$hooks" git -C "$repo" rev-parse --path-format=absolute --git-path hooks)
  [ "$target" = "$hooks" ] || fail "a hook manager in the pane would resolve $target, not the strip dir $hooks"
  mv "$target/commit-msg" "$target/commit-msg.old" 2>/dev/null &&
    fail "a hook manager could rename the strip's commit-msg aside"
  (printf '#!/bin/sh\nexit 0\n' >"$target/commit-msg") 2>/dev/null &&
    fail "a hook manager could overwrite the strip's commit-msg"
  (printf '#!/bin/sh\nexit 0\n' >"$target/post-update") 2>/dev/null &&
    fail "a hook manager could add a hook to the strip dir"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: after a manager tried'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "Cursor trailer survived a hook manager's install attempt"
  pass "a hook manager resolving the pane hooks dir fails instead of displacing the strip"
}

test_reinstall_replaces_a_read_only_install() {
  local repo hooks body
  repo="$TMP_ROOT/reinstall"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-reinstall"
  "$STRIP" install "$hooks" "$repo" || fail "first install should succeed"
  "$STRIP" install "$hooks" "$repo" || fail "a relaunch reinstall over the read-only install failed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: after reinstall'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "Cursor trailer survived after a reinstall"
  pass "a relaunch reinstall replaces the read-only strip dir and still strips"
}

test_previous_commit_msg_hook_still_runs() {
  local repo orig hooks
  repo="$TMP_ROOT/chain-hook"
  make_repo "$repo"
  orig=$(git -C "$repo" rev-parse --git-path hooks)
  case "$orig" in
  /*) ;;
  *) orig="$repo/$orig" ;;
  esac
  mkdir -p "$orig"
  cat >"$orig/commit-msg" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' > "$(dirname "$1")/orig-commit-msg.ran"
exit 0
SH
  chmod 700 "$orig/commit-msg"
  hooks="$TMP_ROOT/hooks-chain"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: chain'
  [ -f "$repo/.git/orig-commit-msg.ran" ] || fail "the worktree's previous commit-msg hook did not run"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived even though the previous hook ran"
  pass "install chains the previous commit-msg hook after stripping"
}

write_marker_hook() {  # <path> <marker>
  cat >"$1" <<SH
#!/usr/bin/env bash
printf 'ran\n' > "\$PWD/$2.ran"
exit 0
SH
  chmod 700 "$1"
}

test_relative_project_hookspath_still_runs() {
  local repo hooks
  repo="$TMP_ROOT/husky-relative"
  make_repo "$repo"
  mkdir -p "$repo/.husky/_"
  write_marker_hook "$repo/.husky/_/pre-commit" husky-pre-commit
  git -C "$repo" config core.hooksPath .husky/_
  hooks="$TMP_ROOT/hooks-husky"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed with a relative core.hooksPath"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: husky relative'
  [ -f "$repo/husky-pre-commit.ran" ] || fail "the project's relative-hooksPath pre-commit hook did not run"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived a relative-hooksPath install"
  pass "a relative project core.hooksPath resolves against the worktree and still runs"
}

test_inherited_hookspath_env_does_not_decide_the_chain() {
  local repo hooks parent
  repo="$TMP_ROOT/nested-spawn"
  make_repo "$repo"
  write_marker_hook "$repo/.git/hooks/pre-commit" project-pre-commit
  parent="$TMP_ROOT/parent-hooks"
  mkdir -p "$parent"
  write_marker_hook "$parent/pre-commit" parent-pre-commit
  hooks="$TMP_ROOT/hooks-nested"
  with_hooks_env "$parent" "$STRIP" install "$hooks" "$repo" ||
    fail "install should succeed with an inherited GIT_CONFIG hooksPath"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q -m 'fix: nested spawn'
  [ -f "$repo/project-pre-commit.ran" ] || fail "the project's own pre-commit hook was not chained"
  [ -f "$repo/parent-pre-commit.ran" ] && fail "a parent spawn's hooks were chained into this worktree"
  pass "an inherited GIT_CONFIG hooksPath does not become the chained previous hooks"
}

test_project_hook_generated_after_install_still_runs() {
  local repo hooks
  repo="$TMP_ROOT/late-husky"
  make_repo "$repo"
  git -C "$repo" config core.hooksPath .husky/_
  hooks="$TMP_ROOT/hooks-late"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed before the project's hooks exist"
  mkdir -p "$repo/.husky/_"
  write_marker_hook "$repo/.husky/_/pre-commit" late-pre-commit
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: late husky'
  [ -f "$repo/late-pre-commit.ran" ] || fail "a project hook generated after the spawn did not run"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived a late-generated project hooks directory"
  pass "a project hook that appears after install still runs for the rest of the task"
}

test_pane_hookspath_does_not_reroute_another_repository() {
  local repo other hooks
  repo="$TMP_ROOT/task-wt"
  other="$TMP_ROOT/other-repo"
  make_repo "$repo"
  make_repo "$other"
  write_marker_hook "$other/.git/hooks/pre-commit" other-pre-commit
  write_marker_hook "$repo/.git/hooks/pre-commit" task-pre-commit
  hooks="$TMP_ROOT/hooks-pane"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$other/README.md"
  git -C "$other" add README.md
  with_hooks_env "$hooks" git -C "$other" commit -q -m 'fix: other repo'
  [ -f "$other/other-pre-commit.ran" ] || fail "the other repository's own pre-commit hook did not run"
  [ -f "$other/task-pre-commit.ran" ] && fail "the task worktree's pre-commit ran inside another repository"
  [ -f "$repo/task-pre-commit.ran" ] && fail "the task worktree's pre-commit ran while committing elsewhere"
  pass "a pane GIT_CONFIG hooksPath still chains the repository git is actually in"
}

test_empty_project_hookspath_runs_no_repository_hook() {
  local repo hooks err
  repo="$TMP_ROOT/empty-hookspath"
  make_repo "$repo"
  write_marker_hook "$repo/.git/hooks/pre-commit" default-pre-commit
  git -C "$repo" config core.hooksPath ''
  hooks="$TMP_ROOT/hooks-empty"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed with an empty core.hooksPath"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  err=$(with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: empty hooksPath' 2>&1) ||
    fail "a commit in a repo with an empty core.hooksPath was refused: $err"
  assert_equals "" "$err" "an empty core.hooksPath commit printed errors"
  [ -f "$repo/default-pre-commit.ran" ] && fail "a repository hook ran although core.hooksPath is empty"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived an empty-hooksPath commit"
  pass "an empty project core.hooksPath runs no repository hook and still strips the trailer"
}

test_unresolvable_project_hookspath_still_refuses() {
  local repo hooks head err
  repo="$TMP_ROOT/unresolvable-hookspath"
  make_repo "$repo"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" config core.hooksPath '~fm-no-such-user-6171/hooks'
  hooks="$TMP_ROOT/hooks-unresolvable"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed with an unresolvable core.hooksPath"
  head=$(git -C "$repo" rev-parse HEAD)
  err=$(with_hooks_env "$hooks" git -C "$repo" commit -q -m 'fix: unresolvable hooksPath' 2>&1) &&
    fail "a commit succeeded although the repository's hooks directory cannot be resolved"
  assert_contains "$err" "refusing to skip its pre-commit hook" "the refusal did not name the skipped hook"
  assert_equals 1 "$(printf '%s\n' "$err" | grep -c 'failed to expand user dir')" "git's lookup error was not shown exactly once"
  assert_equals "$head" "$(git -C "$repo" rev-parse HEAD)" "a refused commit still moved HEAD"
  pass "an unresolvable project core.hooksPath still refuses the commit"
}

test_valueless_project_hookspath_still_refuses() {
  local repo hooks head err
  repo="$TMP_ROOT/valueless-hookspath"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-valueless"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed before the valueless key is written"
  head=$(git -C "$repo" rev-parse HEAD)
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  printf '[core]\n\thooksPath\n' >>"$repo/.git/config"
  err=$(with_hooks_env "$hooks" git -C "$repo" commit -q -m 'fix: valueless hooksPath' 2>&1) &&
    fail "a commit succeeded although core.hooksPath has no value"
  assert_contains "$err" "refusing to skip its pre-commit hook" "the refusal did not name the skipped hook"
  assert_equals 1 "$(printf '%s\n' "$err" | grep -c "missing value for 'core.hookspath'")" "git's lookup error was not shown exactly once"
  assert_equals "$head" "$(git -C "$repo" -c core.hooksPath=x rev-parse HEAD)" "a refused commit still moved HEAD"
  pass "a valueless project core.hooksPath still refuses the commit"
}

write_refusing_pre_push() {  # <path> <marker>
  cat >"$1" <<SH
#!/usr/bin/env bash
printf 'ran\n' >> "$2"
exit 1
SH
  chmod 700 "$1"
}

# A publish guard installed as the repository's pre-push must run however the
# pane's hooksPath reaches git: the pane export, git -c (GIT_CONFIG_PARAMETERS),
# or a child process that inherits either one.
test_repository_pre_push_runs_on_every_override_channel() {
  local repo remote hooks marker label child_push
  # shellcheck disable=SC2016 # the child shell expands its own positional args
  child_push='git -C "$1" push -q origin "HEAD:refs/heads/$2"'
  repo="$TMP_ROOT/guarded-push"
  remote="$TMP_ROOT/guarded-remote.git"
  make_repo "$repo"
  git init -q --bare "$remote"
  git -C "$repo" remote add origin "$remote"
  marker="$TMP_ROOT/guarded-push.pre-push"
  write_refusing_pre_push "$repo/.git/hooks/pre-push" "$marker"
  hooks="$TMP_ROOT/hooks-guarded"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  for label in env param env+param child-env child-param config-env config-child config-param; do
    rm -f "$marker"
    case "$label" in
    env) with_hooks_env "$hooks" git -C "$repo" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    param) git -C "$repo" -c core.hooksPath="$hooks" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    env+param) with_hooks_env "$hooks" git -C "$repo" -c core.hooksPath="$hooks" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    child-env) with_hooks_env "$hooks" sh -c "$child_push" _ "$repo" "$label" 2>/dev/null ;;
    child-param) git -C "$repo" -c core.hooksPath="$hooks" -c "alias.guarded-push=!git push -q origin HEAD:refs/heads/$label" guarded-push 2>/dev/null ;;
    config-env) with_launch_env "$hooks" "$repo" git -C "$repo" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    config-child) with_launch_env "$hooks" "$repo" sh -c "$child_push" _ "$repo" "$label" 2>/dev/null ;;
    config-param) with_launch_env "$hooks" "$repo" git -C "$repo" -c "alias.guarded-push=!git push -q origin HEAD:refs/heads/$label" guarded-push 2>/dev/null ;;
    esac && fail "push via $label succeeded past the repository's refusing pre-push hook"
    [ -f "$marker" ] || fail "the repository's pre-push hook did not run via $label"
    git -C "$remote" rev-parse -q --verify "refs/heads/$label" >/dev/null &&
      fail "push via $label reached the remote despite the refusing pre-push hook"
  done
  pass "the repository's pre-push runs and can refuse under every hooksPath override channel"
}

test_git_c_override_still_strips_and_chains_commit_hooks() {
  local repo hooks
  repo="$TMP_ROOT/param-commit"
  make_repo "$repo"
  write_marker_hook "$repo/.git/hooks/pre-commit" param-pre-commit
  hooks="$TMP_ROOT/hooks-param-commit"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c core.hooksPath="$hooks" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: git -c override'
  [ -f "$repo/param-pre-commit.ran" ] || fail "the project's pre-commit hook did not run under git -c core.hooksPath"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived a git -c core.hooksPath commit"
  pass "a git -c hooksPath override still strips the trailer and chains the project's hooks"
}

test_plain_canonical_hook_check_and_validation() {
  local repo hooks project_hooks variant launch rc head body
  for variant in default relative absolute late; do
    repo="$TMP_ROOT/canonical-$variant"
    make_repo "$repo"
    if ! supports_config_hooks "$repo"; then
      pass "plain canonical hook checks (skipped: Git lacks config hooks)"
      return
    fi
    case "$variant" in
    default) project_hooks="$repo/.git/hooks" ;;
    relative | late)
      project_hooks="$repo/project-hooks"
      git -C "$repo" config core.hooksPath project-hooks
      ;;
    absolute)
      project_hooks="$TMP_ROOT/absolute-project-hooks"
      git -C "$repo" config core.hooksPath "$project_hooks"
      ;;
    esac
    hooks="$TMP_ROOT/hooks-canonical-$variant"
    launch=$("$STRIP" launch-env "$hooks" "$repo" 2>"$repo/launch.stderr") || fail "could not prepare $variant launch"
    assert_equals "" "$(cat "$repo/launch.stderr")" "$variant native launch warned unexpectedly"
    [ ! -e "$hooks" ] || fail "config-hook launch installed legacy wrappers"
    mkdir -p "$project_hooks"
    cat >"$repo/health-check" <<'EOF'
#!/usr/bin/env bash
set -eu
actual=$(git rev-parse --path-format=absolute --git-path hooks/pre-commit)
[ -x "$actual" ] && [ "$actual" = "$EXPECTED_PRE_COMMIT" ] || exit 42
exit "${CHECK_EXIT:-0}"
EOF
    chmod +x "$repo/health-check"
    cat >"$project_hooks/pre-commit" <<'EOF'
#!/bin/sh
./health-check || exit $?
printf 'pre-commit\n' >> hook-order
EOF
    cat >"$project_hooks/prepare-commit-msg" <<'EOF'
#!/bin/sh
printf 'prepare-commit-msg\n' >> hook-order
printf '\nCo-authored-by: Claude <noreply@anthropic.com>\n' >> "$1"
EOF
    cat >"$project_hooks/commit-msg" <<'EOF'
#!/bin/sh
printf 'commit-msg\n' >> hook-order
cp "$1" project-message
exit "${PROJECT_HOOK_EXIT:-0}"
EOF
    cat >"$project_hooks/post-commit" <<'EOF'
#!/bin/sh
printf 'post-commit\n' >> hook-order
EOF
    chmod +x "$project_hooks/"{pre-commit,prepare-commit-msg,commit-msg,post-commit}
    git -C "$repo" config hook.project.event commit-msg
    git -C "$repo" config hook.project.command "printf 'config-commit-msg\\n' >> hook-order"
    git -C "$repo" config hook.firstmate-strip-ai-trailers.enabled false
    export EXPECTED_PRE_COMMIT="$project_hooks/pre-commit"
    (cd "$repo" && eval "$launch"; ./health-check && sh -c './health-check' &&
      git -c 'alias.health=!./health-check' health) || fail "$variant plain canonical hook check failed"
    head=$(git -C "$repo" rev-parse HEAD)
    (cd "$repo" && eval "$launch"; CHECK_EXIT=23 ./health-check && git commit -q --allow-empty -m unexpected)
    rc=$?
    expect_code 23 "$rc" "$variant validation must propagate health-check failure"
    assert_equals "$head" "$(git -C "$repo" rev-parse HEAD)" "failed validation created a commit"
    (cd "$repo" && eval "$launch"; ./health-check && git commit -q --allow-empty \
      --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' \
      --trailer 'Co-authored-by: Jane Doe <jane@example.com>' -m 'fix: ordinary validation') ||
      fail "$variant ordinary validation failed"
    body=$(git -C "$repo" log -1 --format=%B)
    assert_not_contains "$body" "cursoragent@cursor.com" "$variant lost Cursor stripping"
    assert_not_contains "$body" "noreply@anthropic.com" "$variant lost prepare-commit-msg stripping"
    assert_contains "$body" 'Jane Doe <jane@example.com>' "$variant lost human attribution"
    assert_equals "$body" "$(cat "$repo/project-message")" "project commit-msg did not see the stripped message"
    assert_equals $'pre-commit\nprepare-commit-msg\nconfig-commit-msg\ncommit-msg\npost-commit' \
      "$(cat "$repo/hook-order")" "$variant project hooks ran out of order or more than once"
    head=$(git -C "$repo" rev-parse HEAD)
    (cd "$repo" && eval "$launch"; PROJECT_HOOK_EXIT=7 git commit -q --allow-empty -m refused) &&
      fail "$variant project commit-msg refusal was ignored"
    assert_equals "$head" "$(git -C "$repo" rev-parse HEAD)" "project refusal moved HEAD"
  done
  unset EXPECTED_PRE_COMMIT
  pass "plain canonical checks and validation preserve project hooks, ordering, failures, and stripping"
}

test_config_hook_respects_repository_and_command_hookspath() {
  local repo other hooks launch effective body
  repo="$TMP_ROOT/config-task"
  other="$TMP_ROOT/config-other"
  make_repo "$repo"
  make_repo "$other"
  if ! supports_config_hooks "$repo"; then
    pass "config hook repository selection (skipped: Git lacks config hooks)"
    return
  fi
  hooks="$TMP_ROOT/hooks-config-other"
  launch=$("$STRIP" launch-env "$hooks" "$repo") || fail "could not prepare launch"
  write_marker_hook "$repo/.git/hooks/pre-commit" task-pre-commit
  write_marker_hook "$other/.git/hooks/pre-commit" other-pre-commit
  effective=$(eval "$launch"; git -C "$other" rev-parse --path-format=absolute --git-path hooks/pre-commit)
  assert_equals "$other/.git/hooks/pre-commit" "$effective" "git -C lost the other repository's canonical hook"
  (eval "$launch"; git -C "$other" -c "alias.commit-test=!git commit -q --allow-empty --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: other repo'" commit-test) ||
    fail "child commit in another repository failed"
  [ -f "$other/other-pre-commit.ran" ] || fail "other repository's hook did not run"
  [ ! -f "$repo/task-pre-commit.ran" ] || fail "task repository's hook ran in another repository"
  mkdir -p "$other/custom-hooks"
  write_marker_hook "$other/custom-hooks/pre-commit" command-pre-commit
  (eval "$launch"; git -C "$other" -c core.hooksPath=custom-hooks commit -q --allow-empty \
    --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: command hooks') || fail "git -c commit failed"
  [ -f "$other/command-pre-commit.ran" ] || fail "command-scoped project hook did not run"
  rm -f "$other/other-pre-commit.ran" "$other/command-pre-commit.ran"
  git -C "$other" config core.hooksPath ''
  (eval "$launch"; git -C "$other" commit -q --allow-empty \
    --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: disabled project hooks') || fail "empty hooksPath commit failed"
  [ ! -f "$other/other-pre-commit.ran" ] && [ ! -f "$other/command-pre-commit.ran" ] ||
    fail "empty hooksPath ran a project hook"
  body=$(git -C "$other" log -3 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "git -C, child, or command-scoped commit lost stripping"
  pass "config stripping preserves git -C, child Git configuration, and command-scoped or disabled project hooks"
}

test_launch_env_quotes_the_strip_command() {
  local repo copy launch
  repo="$TMP_ROOT/quoted-command"
  make_repo "$repo"
  copy="$TMP_ROOT/strip 'quoted' directory/strip.sh"
  mkdir -p "$(dirname "$copy")"
  cp "$STRIP" "$copy"
  "$copy" install "$TMP_ROOT/hooks-quoted" "$repo" || fail "quoted strip hook setup failed"
  launch=$("$copy" launch-env "$TMP_ROOT/hooks-quoted" "$repo") || fail "quoted strip launch preparation failed"
  (eval "$launch"; git -C "$repo" commit -q --allow-empty \
    --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: quoted strip path') || fail "quoted strip command failed"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "cursoragent@cursor.com" "quoted strip path lost stripping"
  pass "pane configuration executes the strip from paths containing spaces and apostrophes"
}

test_launch_env_falls_back_without_config_hooks() {
  local repo hooks fakebin real_git launch effective
  repo="$TMP_ROOT/legacy-launch"
  hooks="$TMP_ROOT/hooks-legacy-launch"
  make_repo "$repo"
  write_marker_hook "$repo/.git/hooks/pre-commit" legacy-project-pre-commit
  real_git=$(command -v git)
  fakebin=$(fm_fakebin "$TMP_ROOT/legacy-git")
  cat >"$fakebin/git" <<EOF
#!/bin/sh
case " \$* " in *' hook list commit-msg '*) exit 129 ;; esac
exec '$real_git' "\$@"
EOF
  chmod +x "$fakebin/git"
  "$STRIP" install "$hooks" "$repo" || fail "legacy hook setup failed"
  launch=$(PATH="$fakebin:$PATH" "$STRIP" launch-env "$hooks" "$repo" 2>"$repo/launch.stderr") || fail "legacy launch preparation failed"
  assert_contains "$(cat "$repo/launch.stderr")" "using legacy core.hooksPath wrappers" "legacy launch did not warn about its hook override"
  assert_contains "$(cat "$repo/launch.stderr")" "canonical project-hook checks may fail" "legacy warning omitted the compatibility limit"
  assert_equals 1 "$(grep -c '^warning:' "$repo/launch.stderr")" "legacy launch must warn exactly once"
  effective=$(eval "$launch"; git -C "$repo" rev-parse --path-format=absolute --git-path hooks)
  assert_equals "$hooks" "$effective" "unsupported Git did not receive legacy wrappers"
  (eval "$launch"; git -C "$repo" commit -q --allow-empty \
    --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: legacy fallback') || fail "legacy commit failed"
  [ -f "$repo/legacy-project-pre-commit.ran" ] || fail "legacy project hook was not chained"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "cursoragent@cursor.com" "legacy fallback lost stripping"
  pass "Git without config hooks receives working strip-and-chain wrappers"
}

test_strip_msgfile_alone_does_not_rewrite_author_fields() {
  local msg
  msg="$TMP_ROOT/msg.txt"
  printf '%s\n' 'fix: subject' '' 'Co-authored-by: Cursor <cursoragent@cursor.com>' >"$msg"
  "$STRIP" "$msg" || fail "strip should succeed"
  assert_not_contains "$(cat "$msg")" "Cursor" "strip left the Cursor trailer in the file"
  assert_contains "$(cat "$msg")" "fix: subject" "strip dropped the subject"
  pass "commit-msg file mode strips the trailer and keeps the subject"
}

test_cursor_trailer_does_not_reach_the_commit_object
test_human_coauthor_is_kept
test_human_at_a_vendor_domain_is_kept
test_hook_manager_cannot_displace_the_strip
test_reinstall_replaces_a_read_only_install
test_previous_commit_msg_hook_still_runs
test_relative_project_hookspath_still_runs
test_inherited_hookspath_env_does_not_decide_the_chain
test_project_hook_generated_after_install_still_runs
test_pane_hookspath_does_not_reroute_another_repository
test_empty_project_hookspath_runs_no_repository_hook
test_unresolvable_project_hookspath_still_refuses
test_valueless_project_hookspath_still_refuses
test_repository_pre_push_runs_on_every_override_channel
test_git_c_override_still_strips_and_chains_commit_hooks
test_plain_canonical_hook_check_and_validation
test_config_hook_respects_repository_and_command_hookspath
test_launch_env_quotes_the_strip_command
test_launch_env_falls_back_without_config_hooks
test_strip_msgfile_alone_does_not_rewrite_author_fields

echo "# all fm-git-strip-ai-trailers tests passed"
