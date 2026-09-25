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
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

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
test_strip_msgfile_alone_does_not_rewrite_author_fields

echo "# all fm-git-strip-ai-trailers tests passed"
