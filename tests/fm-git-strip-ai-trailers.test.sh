#!/usr/bin/env bash
# Behavior tests for the spawn-owned AI commit-trailer strip.
#
# Cursor injects Co-Authored-By after the typed message, so these cases assert
# the commit OBJECT, never the string passed to -m. The strip is the public
# interface; tests drive git commit with the export statement install prints,
# the same way a fleet-launched pane does.
#
# install picks one of two modes. "config" defines the strip as a config hook
# and needs a git that runs config-defined hooks. "fallback" is the read-only
# core.hooksPath directory for a git that does not; a git shim that rejects
# git hook list stands in for such a git, so fallback runs on every host.
set -u

# A fleet pane already carries the strip's GIT_CONFIG_* override. These cases
# set the override themselves, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
TMP_ROOT=$(fm_test_tmproot fm-git-strip-ai-trailers)

fm_git_identity 'Captain Tests' 'captain@example.invalid'

REAL_GIT=$(command -v git) || fail "test needs git"
OLD_GIT_BIN="$TMP_ROOT/old-git-bin"
mkdir -p "$OLD_GIT_BIN"
cat >"$OLD_GIT_BIN/git" <<SH
#!/usr/bin/env bash
# A git from before config-defined hooks: git hook list is unknown.
prev=
for arg in "\$@"; do
  if [ "\$prev" = hook ] && [ "\$arg" = list ]; then
    echo "error: unknown subcommand: \\\`list'" >&2
    exit 129
  fi
  prev=\$arg
done
exec $(printf '%q' "$REAL_GIT") "\$@"
SH
chmod 700 "$OLD_GIT_BIN/git"

# Set PATH for <mode> in the current (sub)shell.
use_mode_git() {  # <mode>
  [ "$1" = fallback ] && PATH="$OLD_GIT_BIN:$PATH"
  return 0
}

# Run install for <mode> and keep its pane statement in PANE_ENV.
pane_install() {  # <mode> <hooks-dir> <repo> [extra env assignments...]
  local mode=$1 hooks=$2 repo=$3
  shift 3
  PANE_ENV=$(use_mode_git "$mode" && env "$@" "$STRIP" install "$hooks" "$repo") ||
    fail "$mode install should succeed on a real git repo"
  [ -n "$PANE_ENV" ] || fail "$mode install printed no pane statement"
}

# Run a command the way the pane would: the mode's git plus the pane statement.
in_pane() {  # <mode> <command...>
  local mode=$1
  shift
  (
    use_mode_git "$mode"
    eval "$PANE_ENV"
    "$@"
  )
}

make_repo() {
  local dir=$1
  fm_git_init_commit "$dir"
}

stage_change() {  # <repo>
  printf 'note\n' >>"$1/README.md"
  git -C "$1" add README.md
}

write_marker_hook() {  # <path> <marker>
  cat >"$1" <<SH
#!/usr/bin/env bash
printf 'ran\n' > "\$PWD/$2.ran"
exit 0
SH
  chmod 700 "$1"
}

# True when install chose the config-hook mode for this host's own git.
CONFIG_SUPPORTED=0
probe_repo="$TMP_ROOT/probe"
make_repo "$probe_repo"
pane_install config "$TMP_ROOT/hooks-probe" "$probe_repo"
[ -e "$TMP_ROOT/hooks-probe" ] || CONFIG_SUPPORTED=1
MODES=fallback
if [ "$CONFIG_SUPPORTED" = 1 ]; then
  MODES="config fallback"
else
  echo "# skip: $("$REAL_GIT" --version) does not run config-defined hooks; config-mode cases not exercised on this host"
fi

test_cursor_trailer_does_not_reach_the_commit_object() {  # <mode>
  local mode=$1 repo hooks body author
  repo="$TMP_ROOT/$mode-cursor-object"
  make_repo "$repo"
  hooks="$TMP_ROOT/$mode-hooks-cursor"
  pane_install "$mode" "$hooks" "$repo"
  stage_change "$repo"
  in_pane "$mode" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: keep the typed message clean'
  body=$(git -C "$repo" log -1 --format=%B)
  author=$(git -C "$repo" log -1 --format='%an <%ae>')
  assert_not_contains "$body" "Co-authored-by: Cursor" "$mode: Cursor trailer reached the commit object"
  assert_not_contains "$body" "cursoragent@cursor.com" "$mode: Cursor email reached the commit object"
  assert_contains "$body" "fix: keep the typed message clean" "$mode: subject was rewritten"
  [ "$author" = "Captain Tests <captain@example.invalid>" ] || fail "$mode: author was rewritten: $author"
  pass "$mode: a Cursor --trailer commit object has no AI co-author and keeps the captain identity"
}

test_human_coauthor_is_kept() {  # <mode>
  local mode=$1 repo hooks body
  repo="$TMP_ROOT/$mode-human-coauthor"
  make_repo "$repo"
  hooks="$TMP_ROOT/$mode-hooks-human"
  pane_install "$mode" "$hooks" "$repo"
  stage_change "$repo"
  in_pane "$mode" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' --trailer 'Co-authored-by: Jane Doe <jane@example.com>' -m 'fix: mixed trailers'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "Cursor" "$mode: Cursor trailer was not stripped from a mixed message"
  assert_contains "$body" "Co-authored-by: Jane Doe <jane@example.com>" "$mode: human co-author was stripped"
  pass "$mode: a human Co-authored-by trailer survives next to a stripped Cursor trailer"
}

test_human_at_a_vendor_domain_is_kept() {  # <mode>
  local mode=$1 repo hooks body
  repo="$TMP_ROOT/$mode-vendor-human"
  make_repo "$repo"
  hooks="$TMP_ROOT/$mode-hooks-vendor-human"
  pane_install "$mode" "$hooks" "$repo"
  stage_change "$repo"
  in_pane "$mode" git -C "$repo" commit -q \
    --trailer 'Co-authored-by: Claude <noreply@anthropic.com>' \
    --trailer 'Co-authored-by: Jane Doe <jane@anthropic.com>' \
    --trailer 'Co-authored-by: Sam Roe <sam@cursor.com>' -m 'fix: vendor staff co-authors'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "noreply@anthropic.com" "$mode: the Claude bot trailer reached the commit object"
  assert_contains "$body" "Co-authored-by: Jane Doe <jane@anthropic.com>" "$mode: a human at a vendor domain was stripped"
  assert_contains "$body" "Co-authored-by: Sam Roe <sam@cursor.com>" "$mode: a human at a vendor domain was stripped"
  pass "$mode: a human co-author at a vendor domain survives; only the exact bot address is stripped"
}

test_previous_commit_msg_hook_still_runs() {  # <mode>
  local mode=$1 repo orig hooks
  repo="$TMP_ROOT/$mode-chain-hook"
  make_repo "$repo"
  orig=$(git -C "$repo" rev-parse --path-format=absolute --git-path hooks)
  mkdir -p "$orig"
  cat >"$orig/commit-msg" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' > "$(dirname "$1")/orig-commit-msg.ran"
exit 0
SH
  chmod 700 "$orig/commit-msg"
  hooks="$TMP_ROOT/$mode-hooks-chain"
  pane_install "$mode" "$hooks" "$repo"
  stage_change "$repo"
  in_pane "$mode" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: chain'
  [ -f "$repo/.git/orig-commit-msg.ran" ] || fail "$mode: the worktree's previous commit-msg hook did not run"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "$mode: Cursor trailer survived even though the previous hook ran"
  pass "$mode: the project's own commit-msg hook still runs next to the strip"
}

test_relative_project_hookspath_still_runs() {  # <mode>
  local mode=$1 repo hooks
  repo="$TMP_ROOT/$mode-husky-relative"
  make_repo "$repo"
  mkdir -p "$repo/.husky/_"
  write_marker_hook "$repo/.husky/_/pre-commit" husky-pre-commit
  git -C "$repo" config core.hooksPath .husky/_
  hooks="$TMP_ROOT/$mode-hooks-husky"
  pane_install "$mode" "$hooks" "$repo"
  stage_change "$repo"
  in_pane "$mode" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: husky relative'
  [ -f "$repo/husky-pre-commit.ran" ] || fail "$mode: the project's relative-hooksPath pre-commit hook did not run"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "$mode: Cursor trailer survived a relative-hooksPath install"
  pass "$mode: a relative project core.hooksPath resolves against the worktree and still runs"
}

test_inherited_pane_env_does_not_decide_the_chain() {  # <mode>
  local mode=$1 repo hooks parent
  repo="$TMP_ROOT/$mode-nested-spawn"
  make_repo "$repo"
  write_marker_hook "$repo/.git/hooks/pre-commit" project-pre-commit
  parent="$TMP_ROOT/$mode-parent-hooks"
  mkdir -p "$parent"
  write_marker_hook "$parent/pre-commit" parent-pre-commit
  hooks="$TMP_ROOT/$mode-hooks-nested"
  pane_install "$mode" "$hooks" "$repo" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$parent"
  stage_change "$repo"
  in_pane "$mode" git -C "$repo" commit -q -m 'fix: nested spawn'
  [ -f "$repo/project-pre-commit.ran" ] || fail "$mode: the project's own pre-commit hook did not run"
  [ -f "$repo/parent-pre-commit.ran" ] && fail "$mode: a parent spawn's hooks ran in this worktree"
  pass "$mode: an inherited parent pane override does not become this pane's hooks"
}

test_project_hook_generated_after_install_still_runs() {  # <mode>
  local mode=$1 repo hooks
  repo="$TMP_ROOT/$mode-late-husky"
  make_repo "$repo"
  git -C "$repo" config core.hooksPath .husky/_
  hooks="$TMP_ROOT/$mode-hooks-late"
  pane_install "$mode" "$hooks" "$repo"
  mkdir -p "$repo/.husky/_"
  write_marker_hook "$repo/.husky/_/pre-commit" late-pre-commit
  stage_change "$repo"
  in_pane "$mode" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: late husky'
  [ -f "$repo/late-pre-commit.ran" ] || fail "$mode: a project hook generated after the spawn did not run"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "$mode: Cursor trailer survived a late-generated project hooks directory"
  pass "$mode: a project hook that appears after install still runs for the rest of the task"
}

test_pane_env_does_not_reroute_another_repository() {  # <mode>
  local mode=$1 repo other hooks
  repo="$TMP_ROOT/$mode-task-wt"
  other="$TMP_ROOT/$mode-other-repo"
  make_repo "$repo"
  make_repo "$other"
  write_marker_hook "$other/.git/hooks/pre-commit" other-pre-commit
  write_marker_hook "$repo/.git/hooks/pre-commit" task-pre-commit
  hooks="$TMP_ROOT/$mode-hooks-pane"
  pane_install "$mode" "$hooks" "$repo"
  stage_change "$other"
  in_pane "$mode" git -C "$other" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: other repo'
  [ -f "$other/other-pre-commit.ran" ] || fail "$mode: the other repository's own pre-commit hook did not run"
  [ -f "$other/task-pre-commit.ran" ] && fail "$mode: the task worktree's pre-commit ran inside another repository"
  [ -f "$repo/task-pre-commit.ran" ] && fail "$mode: the task worktree's pre-commit ran while committing elsewhere"
  assert_not_contains "$(git -C "$other" log -1 --format=%B)" "cursoragent@cursor.com" \
    "$mode: Cursor trailer survived a commit in another repository from the pane"
  pass "$mode: the pane still runs the hooks of the repository git is actually in"
}

# A hook installer the way pre-commit (devenv git-hooks), lefthook, and husky's
# older installers behave: refuse while core.hooksPath is set, else ask git for
# the repository's hooks directory and write the managed hooks there.
write_hook_installer() {  # <path>
  cat >"$1" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "$(git config core.hooksPath || true)" ]; then
  echo "Cowardly refusing to install hooks with core.hooksPath set." >&2
  exit 1
fi
dir=$(git rev-parse --path-format=absolute --git-path hooks)
mkdir -p "$dir"
for name in pre-commit commit-msg; do
  printf '#!/usr/bin/env bash\nprintf "ran\\n" > "$(git rev-parse --path-format=absolute --git-common-dir)/managed-%s.ran"\n' "$name" >"$dir/$name"
  chmod 755 "$dir/$name"
done
printf '%s\n' "$dir"
SH
  chmod 700 "$1"
}

test_hook_installer_inside_the_pane_installs_and_runs() {
  local repo wt hooks installer target body common
  repo="$TMP_ROOT/installer-project"
  make_repo "$repo"
  wt="$TMP_ROOT/installer-wt"
  git -C "$repo" worktree add -q --detach "$wt" || fail "could not add a task worktree"
  hooks="$TMP_ROOT/installer-hooks"
  installer="$TMP_ROOT/hook-installer"
  write_hook_installer "$installer"
  pane_install config "$hooks" "$wt"
  [ -e "$hooks" ] && fail "config mode left a per-task hooks directory for installers to target"
  target=$(cd "$wt" && in_pane config "$installer") ||
    fail "a hook installer run inside the pane failed"
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)
  [ "$target" = "$common/hooks" ] || fail "the installer wrote $target, not the repository's hooks dir $common/hooks"
  stage_change "$wt"
  in_pane config git -C "$wt" commit -q \
    --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' \
    --trailer 'Co-authored-by: Jane Doe <jane@example.com>' -m 'fix: after the installer ran'
  [ -f "$common/managed-pre-commit.ran" ] || fail "the installed pre-commit hook did not run on commit"
  [ -f "$common/managed-commit-msg.ran" ] || fail "the installed commit-msg hook did not run on commit"
  body=$(git -C "$wt" log -1 --format=%B)
  assert_contains "$body" "fix: after the installer ran" "the commit did not land"
  assert_not_contains "$body" "cursoragent@cursor.com" "the AI trailer survived next to an installed commit-msg hook"
  assert_contains "$body" "Co-authored-by: Jane Doe <jane@example.com>" "a human co-author was stripped"
  pass "config: a hook installer in the pane writes the repository's hooks dir, its hooks run, and the strip still applies"
}

test_config_install_replaces_a_fallback_install() {
  local repo hooks body
  repo="$TMP_ROOT/config-over-fallback"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-config-over-fallback"
  pane_install fallback "$hooks" "$repo"
  [ -d "$hooks" ] || fail "fallback install did not create the per-task hooks dir"
  pane_install config "$hooks" "$repo"
  [ -e "$hooks" ] && fail "config install left the read-only fallback hooks dir behind"
  stage_change "$repo"
  in_pane config git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: after mode change'
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "cursoragent@cursor.com" \
    "config: Cursor trailer survived after replacing a fallback install"
  pass "config: a relaunch on a config-hook git removes a read-only fallback dir and still strips"
}

test_fallback_hook_manager_cannot_displace_the_strip() {
  local repo hooks target body
  if [ "$(id -u)" = 0 ]; then
    pass "fallback: a hook manager cannot displace the strip (skipped as root)"
    return 0
  fi
  repo="$TMP_ROOT/fallback-hook-manager"
  make_repo "$repo"
  hooks="$TMP_ROOT/fallback-hooks-manager"
  pane_install fallback "$hooks" "$repo"
  target=$(in_pane fallback git -C "$repo" rev-parse --path-format=absolute --git-path hooks)
  [ "$target" = "$(CDPATH='' cd -- "$hooks" && pwd -P)" ] ||
    fail "fallback: a hook manager in the pane would resolve $target, not the strip dir $hooks"
  mv "$target/commit-msg" "$target/commit-msg.old" 2>/dev/null &&
    fail "fallback: a hook manager could rename the strip's commit-msg aside"
  (printf '#!/bin/sh\nexit 0\n' >"$target/commit-msg") 2>/dev/null &&
    fail "fallback: a hook manager could overwrite the strip's commit-msg"
  (printf '#!/bin/sh\nexit 0\n' >"$target/post-update") 2>/dev/null &&
    fail "fallback: a hook manager could add a hook to the strip dir"
  stage_change "$repo"
  in_pane fallback git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: after a manager tried'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "fallback: Cursor trailer survived a hook manager's install attempt"
  pass "fallback: a hook manager resolving the pane hooks dir fails instead of displacing the strip"
}

test_fallback_reinstall_replaces_a_read_only_install() {
  local repo hooks body
  repo="$TMP_ROOT/fallback-reinstall"
  make_repo "$repo"
  hooks="$TMP_ROOT/fallback-hooks-reinstall"
  pane_install fallback "$hooks" "$repo"
  pane_install fallback "$hooks" "$repo"
  stage_change "$repo"
  in_pane fallback git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: after reinstall'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "fallback: Cursor trailer survived after a reinstall"
  pass "fallback: a relaunch reinstall replaces the read-only strip dir and still strips"
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

for mode in $MODES; do
  test_cursor_trailer_does_not_reach_the_commit_object "$mode"
  test_human_coauthor_is_kept "$mode"
  test_human_at_a_vendor_domain_is_kept "$mode"
  test_previous_commit_msg_hook_still_runs "$mode"
  test_relative_project_hookspath_still_runs "$mode"
  test_inherited_pane_env_does_not_decide_the_chain "$mode"
  test_project_hook_generated_after_install_still_runs "$mode"
  test_pane_env_does_not_reroute_another_repository "$mode"
done
if [ "$CONFIG_SUPPORTED" = 1 ]; then
  test_hook_installer_inside_the_pane_installs_and_runs
  test_config_install_replaces_a_fallback_install
fi
test_fallback_hook_manager_cannot_displace_the_strip
test_fallback_reinstall_replaces_a_read_only_install
test_strip_msgfile_alone_does_not_rewrite_author_fields

echo "# all fm-git-strip-ai-trailers tests passed"
