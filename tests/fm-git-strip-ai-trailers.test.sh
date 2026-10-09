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

# The incident PR's squash footer carried the fleet's own identity, so the
# message layer must know that exact identity - and only that identity, never a
# human whose name merely contains "firstmate".
test_fleet_identity_trailer_is_stripped() {
  local repo hooks body
  repo="$TMP_ROOT/fleet-identity"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-fleet-identity"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q \
    --trailer 'Co-authored-by: firstmate-worker <worker@firstmate.local>' \
    --trailer 'Co-authored-by: Firstmate Consulting <jane@partner.example>' \
    -m 'fix: fleet identity'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "worker@firstmate.local" "the fleet worker address survived the strip"
  assert_not_contains "$body" "firstmate-worker" "the fleet worker name survived the strip"
  assert_contains "$body" "Co-authored-by: Firstmate Consulting <jane@partner.example>" \
    "a human co-author whose name merely contains firstmate was stripped"
  assert_contains "$body" "fix: fleet identity" "subject was rewritten"
  pass "the fleet's firstmate-worker trailer is stripped while a human firstmate-named co-author survives"
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
  hooks="$TMP_ROOT/hooks-unresolvable"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  # Set after install: install writes the worktree binding, and git versions
  # differ on whether any config read or write survives an unexpandable value.
  # This case is about the commit-time lookup, which must refuse.
  git -C "$repo" config core.hooksPath '~fm-no-such-user-6171/hooks'
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
  for label in env param env+param child-env child-param; do
    rm -f "$marker"
    case "$label" in
    env) with_hooks_env "$hooks" git -C "$repo" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    param) git -C "$repo" -c core.hooksPath="$hooks" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    env+param) with_hooks_env "$hooks" git -C "$repo" -c core.hooksPath="$hooks" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    child-env) with_hooks_env "$hooks" sh -c "$child_push" _ "$repo" "$label" 2>/dev/null ;;
    child-param) git -C "$repo" -c core.hooksPath="$hooks" -c "alias.guarded-push=!git push -q origin HEAD:refs/heads/$label" guarded-push 2>/dev/null ;;
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

test_strip_msgfile_alone_does_not_rewrite_author_fields() {
  local msg
  msg="$TMP_ROOT/msg.txt"
  printf '%s\n' 'fix: subject' '' 'Co-authored-by: Cursor <cursoragent@cursor.com>' >"$msg"
  "$STRIP" "$msg" || fail "strip should succeed"
  assert_not_contains "$(cat "$msg")" "Cursor" "strip left the Cursor trailer in the file"
  assert_contains "$(cat "$msg")" "fix: subject" "strip dropped the subject"
  pass "commit-msg file mode strips the trailer and keeps the subject"
}

# The pane-side GIT_CONFIG_* override reaches only processes descended from the
# launch. The no-mistakes pipeline commits from a shared daemon started outside
# any pane, so these cases deliberately run git with no GIT_CONFIG_* at all and
# still require a clean commit object.
test_commit_outside_the_pane_environment_is_still_stripped() {
  local repo wt hooks body
  repo="$TMP_ROOT/daemon-repo"
  wt="$TMP_ROOT/daemon-wt"
  hooks="$TMP_ROOT/hooks-daemon"
  make_repo "$repo"
  git -C "$repo" worktree add -q "$wt" -b task
  "$STRIP" install "$hooks" "$wt" || fail "install should succeed on a linked worktree"
  printf 'note\n' >>"$wt/README.md"
  git -C "$wt" add README.md
  git -C "$wt" commit -q --trailer 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>' \
    -m 'no-mistakes(review): pipeline fix'
  body=$(git -C "$wt" log -1 --format=%B)
  assert_not_contains "$body" "noreply@anthropic.com" "a commit made without the pane environment kept the AI trailer"
  pass "a commit made without the pane environment is still stripped"
}

test_full_branch_history_carries_no_ai_trailer() {
  local repo wt hooks found
  repo="$TMP_ROOT/history-repo"
  wt="$TMP_ROOT/history-wt"
  hooks="$TMP_ROOT/hooks-history"
  make_repo "$repo"
  git -C "$repo" worktree add -q "$wt" -b task
  "$STRIP" install "$hooks" "$wt" || fail "install should succeed"
  # Thirteen commits, alternating the two casings and both launch paths, so the
  # assertion below is a full-history scan rather than a shallow tip check.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
    printf 'line %s\n' "$i" >>"$wt/README.md"
    git -C "$wt" add README.md
    if [ $((i % 2)) -eq 0 ]; then
      with_hooks_env "$hooks" git -C "$wt" commit -q \
        --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m "feat: pane commit $i"
    else
      git -C "$wt" commit -q \
        --trailer 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>' -m "no-mistakes(review): daemon commit $i"
    fi
  done
  assert_equals 13 "$(git -C "$wt" rev-list --count main..task)" "the fixture should carry thirteen branch commits"
  found=$(git -C "$wt" log --format=%B main..task | grep -ci 'co-authored-by' || true)
  assert_equals 0 "$found" "the pushed branch history still carries an AI trailer"
  pass "no AI trailer survives anywhere in the branch history"
}

test_binding_does_not_reach_the_primary_checkout() {
  local repo wt hooks body
  repo="$TMP_ROOT/isolation-repo"
  wt="$TMP_ROOT/isolation-wt"
  hooks="$TMP_ROOT/hooks-isolation"
  make_repo "$repo"
  git -C "$repo" worktree add -q "$wt" -b task
  "$STRIP" install "$hooks" "$wt" || fail "install should succeed"
  assert_equals "" "$(git -C "$repo" config --get core.hooksPath)" "the task binding leaked into the primary checkout"
  printf 'primary\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q --trailer 'Co-authored-by: Mike Sewell <maikunari@protonmail.com>' -m 'fix: primary work'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_contains "$body" "maikunari@protonmail.com" "the primary checkout lost a human co-author"
  pass "the worktree binding does not reach the primary checkout"
}

test_unbind_releases_the_worktree_binding() {
  local repo wt hooks successor
  repo="$TMP_ROOT/unbind-repo"
  wt="$TMP_ROOT/unbind-wt"
  hooks="$TMP_ROOT/hooks-unbind"
  successor="$TMP_ROOT/hooks-successor"
  make_repo "$repo"
  git -C "$repo" worktree add -q "$wt" -b task
  "$STRIP" install "$hooks" "$wt" || fail "install should succeed"
  assert_equals "$hooks" "$(git -C "$wt" config --get core.hooksPath)" "install did not bind the worktree"
  "$STRIP" unbind "$wt" "$hooks" || fail "unbind should succeed"
  assert_equals "" "$(git -C "$wt" config --get core.hooksPath)" "unbind left the worktree pointing at the strip directory"
  "$STRIP" unbind "$wt" "$hooks" || fail "unbind should be idempotent"
  # A successor spawn has rebound the slot to its own directory: releasing
  # this task's directory must leave that binding alone, and a binding for a
  # directory this caller never owned is never released either.
  "$STRIP" install "$hooks" "$wt" || fail "reinstall should succeed"
  "$STRIP" install "$successor" "$wt" || fail "installing a successor's directory should succeed"
  "$STRIP" unbind "$wt" "$hooks" || fail "unbind of another directory should succeed"
  assert_equals "$successor" "$(git -C "$wt" config --get core.hooksPath)" \
    "unbind released a binding that names a different directory"
  "$STRIP" unbind "$wt" "$TMP_ROOT/hooks-never-created" || fail "unbind of a missing directory should succeed"
  assert_equals "$successor" "$(git -C "$wt" config --get core.hooksPath)" \
    "unbind released a binding for a hooks directory that does not exist"
  "$STRIP" unbind "$wt" "$successor" || fail "unbind should succeed"
  assert_equals "" "$(git -C "$wt" config --get core.hooksPath)" \
    "unbind did not release the binding naming its argument"
  "$STRIP" unbind "$TMP_ROOT/no-such-worktree" "$hooks" || fail "unbind of a missing worktree should be a silent no-op"
  pass "unbind releases only the binding naming its hooks directory, silently otherwise"
}

test_release_unbinds_then_deletes_the_hooks_dir() {
  local repo wt hooks
  repo="$TMP_ROOT/release-repo"
  wt="$TMP_ROOT/release-wt"
  hooks="$TMP_ROOT/hooks-release"
  make_repo "$repo"
  git -C "$repo" worktree add -q "$wt" -b task
  "$STRIP" install "$hooks" "$wt" || fail "install should succeed"
  assert_equals "$hooks" "$(git -C "$wt" config --get core.hooksPath)" "install did not bind the worktree"
  "$STRIP" release "$wt" "$hooks" || fail "release should succeed"
  assert_equals "" "$(git -C "$wt" config --get core.hooksPath)" \
    "release left the worktree bound to the directory it deleted"
  [ ! -e "$hooks" ] || fail "release did not delete the hooks directory"
  "$STRIP" release "$wt" "$hooks" || fail "release of an already-released directory should be a no-op"
  pass "release unbinds the binding that names the directory, then deletes it"
}

test_plain_clone_worktree_is_bound_too() {
  local repo hooks body
  repo="$TMP_ROOT/clone-repo"
  hooks="$TMP_ROOT/hooks-clone"
  make_repo "$repo"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed on a main worktree"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: secondmate home commit'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "a secondmate home clone kept the AI trailer"
  pass "a plain clone is bound the same way a linked worktree is"
}

# --- no-mistakes mirror delivery -------------------------------------------
#
# The pipeline commits its fix rounds in run worktrees whose worktree-scoped
# core.hooksPath points at the mirror hooks directory, so these cases build
# exactly that shape: a bare mirror carrying live pre-receive and post-receive
# push-authorization hooks, a linked run worktree bound worktree-scoped to that
# directory, and git run with no GIT_CONFIG_* at all - the daemon's
# environment, not a pane's.

# One "<entry> <hash>" line per entry of a hooks directory, sorted, so a case
# can prove an install left every pre-existing file byte-identical.
snapshot_dir() {
  local dir=$1 entry
  for entry in "$dir"/*; do
    [ -e "$entry" ] || continue
    if [ -f "$entry" ]; then
      printf '%s %s\n' "${entry##*/}" "$(git hash-object -- "$entry")"
    else
      printf '%s other\n' "${entry##*/}"
    fi
  done | sort
}

make_nm_shape() {  # <root> [mirror] [seed] [run-worktree]: echoes the mirror hooks dir
  local root=$1 mirror=${2:-"$1/mirror.git"} seed=${3:-"$1/seed"} wt=${4:-"$1/run-wt"}
  [ -d "$seed" ] || make_repo "$seed"
  git clone -q --bare "$seed" "$mirror"
  printf '#!/bin/sh\nexit 0\n' >"$mirror/hooks/pre-receive"
  printf '#!/bin/sh\nexit 0\n' >"$mirror/hooks/post-receive"
  chmod 500 "$mirror/hooks/pre-receive" "$mirror/hooks/post-receive"
  # The daemon's own gate isolation, mirrored exactly: worktree config on, the
  # bare's hooks dir pinned in its per-worktree config, and core.bare relocated
  # out of shared scope. Without that last move git leaks core.bare=true into
  # linked worktrees and refuses to run in them at all.
  git -C "$mirror" config extensions.worktreeConfig true
  git -C "$mirror" config --worktree core.hookspath "$mirror/hooks"
  git -C "$mirror" config --worktree core.bare true
  git -C "$mirror" config --local --unset core.bare
  git -C "$mirror" worktree add -q "$wt" -b task
  git -C "$wt" config --worktree core.hooksPath "$mirror/hooks"
  printf '%s' "$mirror/hooks"
}

nm_shape_commit() {  # <worktree> <subject> <trailer>
  printf 'note\n' >>"$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q --trailer "$3" -m "$2"
}

test_mirror_commit_msg_covers_a_pipeline_commit() {
  local root hooks wt before after line body
  root="$TMP_ROOT/mirror-strip"
  hooks=$(make_nm_shape "$root") || fail "could not build the no-mistakes-shaped fixture"
  wt="$root/run-wt"
  before=$(snapshot_dir "$hooks")
  "$STRIP" install-mirror "$hooks" || fail "install-mirror should succeed on a live mirror hooks directory"
  [ -x "$hooks/commit-msg" ] || fail "install-mirror did not write an executable commit-msg"
  after=$(snapshot_dir "$hooks")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    assert_contains "$after" "$line" "install-mirror changed a pre-existing mirror entry: $line"
  done <<<"$before"
  # A second install must write nothing at all: with the directory read-only
  # any write attempt fails the install outright, and the snapshot below catches
  # a rewrite of what is already there.
  chmod u-w "$hooks"
  "$STRIP" install-mirror "$hooks" || fail "a second install-mirror should succeed without writing"
  chmod u+w "$hooks"
  assert_equals "$after" "$(snapshot_dir "$hooks")" "a second install changed the mirror hooks directory"
  nm_shape_commit "$wt" 'no-mistakes(review): fix round' \
    'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>' ||
    fail "the pipeline-shaped commit should succeed"
  body=$(git -C "$wt" log -1 --format=%B)
  assert_not_contains "$body" "noreply@anthropic.com" "the AI trailer reached the pipeline commit object"
  assert_contains "$body" "no-mistakes(review): fix round" "the subject was rewritten"
  nm_shape_commit "$wt" 'no-mistakes(review): human co-author' \
    'Co-authored-by: Jane Doe <jane@example.com>' || fail "the human co-author commit should succeed"
  body=$(git -C "$wt" log -1 --format=%B)
  assert_contains "$body" "Co-authored-by: Jane Doe <jane@example.com>" "a human co-author was stripped"
  pass "a commit in a no-mistakes run worktree is stripped through the mirror commit-msg"
}

test_mirror_commit_msg_fails_open_for_a_broken_strip() {
  local root hooks wt strip_copy body
  root="$TMP_ROOT/mirror-failopen"
  hooks=$(make_nm_shape "$root") || fail "could not build the no-mistakes-shaped fixture"
  wt="$root/run-wt"
  strip_copy="$root/strip-copy.sh"
  cp "$STRIP" "$strip_copy"
  chmod 500 "$strip_copy"
  "$strip_copy" install-mirror "$hooks" || fail "install-mirror should succeed from a copy of the script"
  rm -f "$strip_copy"
  printf '#!/bin/sh\nexit 1\n' >"$strip_copy"
  chmod 500 "$strip_copy"
  nm_shape_commit "$wt" 'no-mistakes(review): strip errors' \
    'Co-authored-by: Cursor <cursoragent@cursor.com>' ||
    fail "a strip that errors must not block the pipeline commit"
  body=$(git -C "$wt" log -1 --format=%B)
  assert_contains "$body" "cursoragent@cursor.com" "an erroring strip changed the message"
  rm -f "$strip_copy"
  nm_shape_commit "$wt" 'no-mistakes(review): strip missing' \
    'Co-authored-by: Cursor <cursoragent@cursor.com>' ||
    fail "a missing strip must not block the pipeline commit"
  body=$(git -C "$wt" log -1 --format=%B)
  assert_contains "$body" "cursoragent@cursor.com" "a missing strip changed the message"
  pass "the mirror commit-msg fails open when the strip errors or is missing"
}

test_mirror_commit_msg_chains_the_prior_hook() {
  local root hooks wt body
  root="$TMP_ROOT/mirror-chain"
  hooks=$(make_nm_shape "$root") || fail "could not build the no-mistakes-shaped fixture"
  wt="$root/run-wt"
  cat >"$hooks/commit-msg" <<SH
#!/bin/sh
printf 'ran\\n' > "$root/prior.ran"
exit 0
SH
  chmod 500 "$hooks/commit-msg"
  "$STRIP" install-mirror "$hooks" || fail "install-mirror should chain an existing commit-msg"
  [ -f "$hooks/commit-msg.fm-prev" ] || fail "the prior hook was not parked as the chained copy"
  chmod u-w "$hooks"
  "$STRIP" install-mirror "$hooks" || fail "a second install-mirror with a chain should succeed without writing"
  chmod u+w "$hooks"
  nm_shape_commit "$wt" 'no-mistakes(review): chained' \
    'Co-authored-by: Cursor <cursoragent@cursor.com>' || fail "the chained commit should succeed"
  [ -f "$root/prior.ran" ] || fail "the mirror's prior commit-msg hook did not run"
  body=$(git -C "$wt" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "the AI trailer survived a chained install"
  pass "install-mirror chains the prior hook so it still runs after the strip"
}

test_install_mirror_refuses_an_unchainable_hook() {
  local root hooks rc
  root="$TMP_ROOT/mirror-refuse"
  hooks=$(make_nm_shape "$root") || fail "could not build the no-mistakes-shaped fixture"
  printf '#!/bin/sh\nexit 0\n' >"$hooks/side-target"
  chmod 500 "$hooks/side-target"
  ln -s "$hooks/side-target" "$hooks/commit-msg"
  rc=0
  "$STRIP" install-mirror "$hooks" 2>/dev/null || rc=$?
  assert_equals 1 "$rc" "install-mirror must refuse a commit-msg it cannot chain safely"
  [ -L "$hooks/commit-msg" ] || fail "install-mirror replaced the unchainable commit-msg"
  assert_equals "$hooks/side-target" "$(readlink "$hooks/commit-msg")" "the unchainable commit-msg was rewritten"
  [ ! -e "$hooks/commit-msg.fm-prev" ] || fail "install-mirror parked a hook it refused to chain"
  pass "install-mirror refuses an unchainable commit-msg instead of overwriting it"
}

# A Firstmate copy can move - a re-seeded home - so an installed hook must
# repair itself rather than keep pointing at a strip that no longer exists,
# which fail-open would otherwise turn into silent non-coverage.
test_install_mirror_refreshes_a_stale_strip_path() {
  local root hooks wt first second body
  root="$TMP_ROOT/mirror-refresh"
  hooks=$(make_nm_shape "$root") || fail "could not build the no-mistakes-shaped fixture"
  wt="$root/run-wt"
  first="$root/strip-first.sh"
  second="$root/strip-second.sh"
  cp "$STRIP" "$first"
  chmod 500 "$first"
  "$first" install-mirror "$hooks" || fail "the first install should succeed"
  cp "$STRIP" "$second"
  chmod 500 "$second"
  rm -f "$first"
  "$second" install-mirror "$hooks" || fail "the refreshing install should succeed"
  nm_shape_commit "$wt" 'no-mistakes(review): refreshed' \
    'Co-authored-by: Cursor <cursoragent@cursor.com>' || fail "the refreshed commit should succeed"
  body=$(git -C "$wt" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "the hook still pointed at the moved strip copy"
  pass "an install from a moved Firstmate copy repairs the installed mirror hook"
}

# Every fleet delivery for a mirror converges on this one writer, and several
# crew-state processes poll the same repository at once: without the lock, two
# deliveries that both saw a foreign commit-msg park it and then park each
# other's hook over it, destroying the foreign hook silently.
test_concurrent_install_mirror_keeps_the_foreign_hook() {
  local root hooks wt marker round i pid body
  local -a pids
  root="$TMP_ROOT/mirror-concurrent"
  hooks=$(make_nm_shape "$root") || fail "could not build the no-mistakes-shaped fixture"
  wt="$root/run-wt"
  marker="$root/foreign.ran"
  for round in 1 2 3 4 5; do
    rm -f "$marker" "$hooks/commit-msg" "$hooks/commit-msg.fm-prev"
    printf '#!/bin/sh\nprintf foreign > "%s"\nexit 0\n' "$marker" >"$hooks/commit-msg"
    chmod 500 "$hooks/commit-msg"
    pids=()
    for i in 1 2 3 4 5 6; do
      "$STRIP" install-mirror "$hooks" &
      pids+=("$!")
    done
    for pid in "${pids[@]}"; do
      wait "$pid" || fail "round $round: a concurrent install-mirror failed"
    done
    nm_shape_commit "$wt" "no-mistakes(review): round $round" \
      'Co-authored-by: Cursor <cursoragent@cursor.com>' ||
      fail "round $round: the commit should succeed"
    [ -f "$marker" ] || fail "round $round: concurrent deliveries lost the foreign commit-msg"
    body=$(git -C "$wt" log -1 --format=%B)
    assert_not_contains "$body" "cursoragent@cursor.com" \
      "round $round: the AI trailer survived a concurrent install"
  done
  pass "concurrent install-mirror deliveries keep the foreign commit-msg and the strip"
}

# A pre-existing lock is never stolen, whatever its age - an age-based steal
# is not owner-checked and could let two deliveries double-park the foreign
# commit-msg - and a delivery that completes leaves no lock at process exit.
test_mirror_install_lock_skips_at_any_age() {
  local root hooks lock wt body
  root="$TMP_ROOT/mirror-lock"
  hooks=$(make_nm_shape "$root") || fail "could not build the no-mistakes-shaped fixture"
  wt="$root/run-wt"
  lock="${hooks}.fm-install.lock"
  mkdir "$lock" || fail "could not seed a live install lock"
  "$STRIP" install-mirror "$hooks" || fail "a live lock must still return success"
  [ ! -e "$hooks/commit-msg" ] || fail "delivery installed while another process held the lock"
  touch -t 202001010000 "$lock" || fail "could not age the lock"
  "$STRIP" install-mirror "$hooks" || fail "an old lock must still return success"
  [ -d "$lock" ] || fail "delivery stole a pre-existing lock instead of skipping"
  [ ! -e "$hooks/commit-msg" ] || fail "delivery installed despite a pre-existing lock"
  rm -rf "$lock"
  "$STRIP" install-mirror "$hooks" || fail "delivery should run once the lock is gone"
  [ -x "$hooks/commit-msg" ] || fail "delivery never ran once the lock was gone"
  [ ! -d "$lock" ] || fail "a completed delivery left its lock behind"
  nm_shape_commit "$wt" 'no-mistakes(review): after release' \
    'Co-authored-by: Cursor <cursoragent@cursor.com>' || fail "the commit after release should succeed"
  body=$(git -C "$wt" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "the released lock left no strip in place"
  pass "the install lock is skipped at any age and leaves nothing behind after delivery"
}

# The traps are the adopted remedy for a signal-terminated delivery: once the
# lock is held, TERM and INT must both release it. A grep shim widens the
# window inside the critical section so the signal lands while the lock is
# held, and the exit status proves the trap path ran rather than a normal
# completion.
test_mirror_install_lock_is_released_by_signals() {
  local root hooks lock fakebin real_grep pid rc waited sig expected
  root="$TMP_ROOT/mirror-signals"
  hooks=$(make_nm_shape "$root") || fail "could not build the no-mistakes-shaped fixture"
  lock="${hooks}.fm-install.lock"
  printf '#!/bin/sh\nexit 0\n' >"$hooks/commit-msg"
  chmod 500 "$hooks/commit-msg"
  real_grep=$(command -v grep) || fail "grep is required for this test"
  fakebin="$root/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nsleep 2\nexec %s "$@"\n' "$real_grep" >"$fakebin/grep"
  chmod +x "$fakebin/grep"
  # Monitor mode: without it a non-interactive shell starts background jobs
  # with SIGINT already ignored, and an ignored signal cannot be trapped, so
  # the INT case could never reach its trap.
  set -m
  for sig in TERM INT; do
    case "$sig" in
    TERM) expected=143 ;;
    INT) expected=130 ;;
    esac
    PATH="$fakebin:$PATH" "$STRIP" install-mirror "$hooks" &
    pid=$!
    waited=0
    while [ ! -d "$lock" ] && [ "$waited" -lt 60 ]; do
      sleep 0.05
      waited=$((waited + 1))
    done
    [ -d "$lock" ] || fail "$sig: the delivery never took the lock"
    kill "-$sig" "$pid" || fail "$sig: could not signal the delivery"
    rc=0
    wait "$pid" || rc=$?
    [ ! -d "$lock" ] || fail "$sig: the trap did not release the install lock"
    assert_equals "$expected" "$rc" "$sig: the delivery did not exit through its trap"
  done
  set +m
  pass "the install lock is released when a delivery is terminated by TERM or INT"
}

# The delivery boundary itself: bin/fm-nm-run-lib.sh resolves the mirror from
# the repository the run is for, so these drive the library's own entry point
# against a state.sqlite it owns, then require the stripped commit object.
test_nm_run_lib_delivers_the_strip_to_the_mirror() {
  local root clone other nm mirror hooks wt line body rc before after
  root="$TMP_ROOT/nm-lib-delivery"
  clone="$root/task-repo"
  make_repo "$clone"
  other="$root/other-repo"
  make_repo "$other"
  nm="$root/nm-home"
  mirror="$nm/repos/repo1234abcd.git"
  mkdir -p "$nm/repos"
  python3 - "$nm/state.sqlite" "$(cd "$clone" && pwd -P)" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as db:
    db.execute("CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE)")
    db.execute("INSERT INTO repos VALUES (?, ?)", ("repo1234abcd", sys.argv[2]))
PY
  wt="$root/run-wt"
  hooks=$(make_nm_shape "$root" "$mirror" "$clone") ||
    fail "could not build the no-mistakes-shaped fixture"
  before=$(snapshot_dir "$hooks")
  export NM_HOME="$nm"
  # shellcheck source=bin/fm-nm-run-lib.sh
  . "$ROOT/bin/fm-nm-run-lib.sh"
  fm_nm_ensure_mirror_commit_msg "$clone" ||
    fail "fm_nm_ensure_mirror_commit_msg should succeed for a registered repository"
  [ -x "$hooks/commit-msg" ] || fail "the library did not deliver the mirror commit-msg"
  after=$(snapshot_dir "$hooks")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    assert_contains "$after" "$line" "delivery changed a pre-existing mirror entry: $line"
  done <<<"$before"
  nm_shape_commit "$wt" 'no-mistakes(review): delivered by the library' \
    'Co-authored-by: Cursor <cursoragent@cursor.com>' || fail "the delivered commit should succeed"
  body=$(git -C "$wt" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "the AI trailer survived the library delivery"
  rc=0
  fm_nm_ensure_mirror_commit_msg "$root/not-a-repo" || rc=$?
  assert_equals 0 "$rc" "a path that is not a repository must not fail the caller"
  rm -f "$nm/state.sqlite"
  rc=0
  fm_nm_ensure_mirror_commit_msg "$other" || rc=$?
  assert_equals 0 "$rc" "an unreadable runs database must not fail the caller"
  [ -x "$hooks/commit-msg" ] || fail "a failed lookup removed the delivered hook"
  unset NM_HOME
  pass "fm-nm-run-lib.sh delivers the strip to the registered mirror and fails open"
}

# no-mistakes answers "which repo does this run belong to" by looking the
# worktree's own top-level path up FIRST and falling back to the main root
# (its findRepo), and every run persists the repo_id that lookup chose. A
# linked worktree carrying its own repos row must therefore receive the strip
# in its own mirror: delivering to the main clone's mirror instead leaves the
# run worktrees this worktree's runs actually commit in uncovered.
test_delivery_follows_the_linked_worktree_own_repo_row() {
  local root clone slot nm slot_mirror main_mirror wt body
  root="$TMP_ROOT/nm-lib-precedence"
  clone="$root/main-clone"
  make_repo "$clone"
  slot="$root/slot"
  git -C "$clone" worktree add -q "$slot" -b slotwork
  nm="$root/nm-home"
  mkdir -p "$nm/repos"
  slot_mirror="$nm/repos/slotmirror0001.git"
  main_mirror="$nm/repos/mainclone0001.git"
  python3 - "$nm/state.sqlite" "$(cd "$clone" && pwd -P)" "$(cd "$slot" && pwd -P)" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as db:
    db.execute("CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE)")
    db.execute("INSERT INTO repos VALUES (?, ?)", ("mainclone0001", sys.argv[2]))
    db.execute("INSERT INTO repos VALUES (?, ?)", ("slotmirror0001", sys.argv[3]))
PY
  make_nm_shape "$root" "$slot_mirror" "$clone" "$root/slot-run-wt" >/dev/null ||
    fail "could not build the linked worktree's mirror fixture"
  make_nm_shape "$root" "$main_mirror" "$clone" "$root/main-run-wt" >/dev/null ||
    fail "could not build the main clone's mirror fixture"
  export NM_HOME="$nm"
  # shellcheck source=bin/fm-nm-run-lib.sh
  . "$ROOT/bin/fm-nm-run-lib.sh"
  fm_nm_ensure_mirror_commit_msg "$slot" ||
    fail "delivering for a linked worktree that carries its own repo row should succeed"
  [ -x "$slot_mirror/hooks/commit-msg" ] ||
    fail "the linked worktree's own repo row did not receive the mirror commit-msg"
  [ ! -e "$main_mirror/hooks/commit-msg" ] ||
    fail "delivery went to the main clone's mirror instead of the linked worktree's own"
  wt="$root/slot-run-wt"
  nm_shape_commit "$wt" 'no-mistakes(review): slot mirror delivery' \
    'Co-authored-by: Cursor <cursoragent@cursor.com>' ||
    fail "a commit in the linked worktree's own run worktree should succeed"
  body=$(git -C "$wt" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" \
    "the commit in the linked worktree's own mirror kept the AI trailer"
  unset NM_HOME
  pass "delivery follows the linked worktree's own repos row, not its main clone's"
}

test_cursor_trailer_does_not_reach_the_commit_object
test_human_coauthor_is_kept
test_human_at_a_vendor_domain_is_kept
test_fleet_identity_trailer_is_stripped
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
test_strip_msgfile_alone_does_not_rewrite_author_fields
test_commit_outside_the_pane_environment_is_still_stripped
test_full_branch_history_carries_no_ai_trailer
test_binding_does_not_reach_the_primary_checkout
test_unbind_releases_the_worktree_binding
test_release_unbinds_then_deletes_the_hooks_dir
test_plain_clone_worktree_is_bound_too
test_mirror_commit_msg_covers_a_pipeline_commit
test_mirror_commit_msg_fails_open_for_a_broken_strip
test_mirror_commit_msg_chains_the_prior_hook
test_install_mirror_refuses_an_unchainable_hook
test_install_mirror_refreshes_a_stale_strip_path
test_concurrent_install_mirror_keeps_the_foreign_hook
test_mirror_install_lock_skips_at_any_age
test_mirror_install_lock_is_released_by_signals
test_nm_run_lib_delivers_the_strip_to_the_mirror
test_delivery_follows_the_linked_worktree_own_repo_row

echo "# all fm-git-strip-ai-trailers tests passed"
