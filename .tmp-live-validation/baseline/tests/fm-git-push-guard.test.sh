#!/usr/bin/env bash
# Behavior tests for bin/fm-git-push-guard.sh, the forge=external pre-push guard.
# Every case pushes with real git through a hooks directory installed by
# bin/fm-git-strip-ai-trailers.sh --push-guard, the way a fleet pane does, and
# asserts both the exit status and which ref the bare remote ended up holding.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath. These cases set that
# override themselves, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-git-push-guard.sh"
STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
TMP_ROOT=$(fm_test_tmproot fm-git-push-guard)
fm_git_identity fmtest fmtest@example.invalid

with_hooks() {  # <hooks-dir> <command...>
  local hooks=$1
  shift
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks "$@"
}

# fixture <name> <task-prefix> [backup]: a project with a bare origin, an
# optional bare backup remote, a worktree on <task-prefix>t1 with one commit,
# and the hooks dir installed with the guard. Sets FX_WT, FX_HOOKS, FX_ORIGIN,
# FX_BACKUP, FX_BRANCH.
fixture() {
  local name=$1 prefix=$2 backup=${3:-} dir guard
  dir="$TMP_ROOT/$name"
  FX_BRANCH="${prefix}t1"
  fm_git_worktree "$dir/repo" "$dir/wt" "$FX_BRANCH"
  FX_WT="$dir/wt"
  FX_ORIGIN="$dir/repo.origin.git"
  FX_BACKUP=
  git -C "$FX_WT" commit -q --allow-empty -m 'the task change'
  guard="$dir/guard"
  if [ -n "$backup" ]; then
    FX_BACKUP="$dir/backup.git"
    git init -q --bare "$FX_BACKUP"
    git -C "$FX_WT" remote add backup "file://$FX_BACKUP"
    "$GUARD" write "$guard" "$FX_WT" "$FX_BRANCH" "$prefix" backup backup/ || fail "guard write failed"
  else
    "$GUARD" write "$guard" "$FX_WT" "$FX_BRANCH" "$prefix" || fail "guard write failed"
  fi
  FX_HOOKS="$dir/hooks"
  "$STRIP" install --push-guard "$guard" "$FX_HOOKS" "$FX_WT" || fail "install --push-guard failed"
}

push() {  # <args...>; sets PUSH_OUT and PUSH_RC
  PUSH_OUT=$(with_hooks "$FX_HOOKS" git -C "$FX_WT" push "$@" 2>&1)
  PUSH_RC=$?
}

refused() {  # <label> <needle> <bare-repo> <ref>
  [ "$PUSH_RC" -ne 0 ] || fail "$1 was accepted"
  assert_contains "$PUSH_OUT" "fm-git-push-guard: refused:" "$1 was refused without the guard naming itself"
  assert_contains "$PUSH_OUT" "$2" "$1 was refused without naming its rule"
  if git -C "$3" rev-parse --verify --quiet "$4" >/dev/null; then
    fail "$1 still reached the remote as $4"
  fi
}

test_origin_pushes_are_refused() {
  fixture origin fm/
  push origin "HEAD:refs/heads/$FX_BRANCH"
  refused "the task branch pushed to origin" "nothing is ever pushed to origin" "$FX_ORIGIN" "refs/heads/$FX_BRANCH"
  push origin HEAD:refs/heads/other
  refused "another branch pushed to origin" "nothing is ever pushed to origin" "$FX_ORIGIN" refs/heads/other
  push "file://$FX_ORIGIN" HEAD:refs/heads/by-url
  refused "a push to origin's URL" "shared origin" "$FX_ORIGIN" refs/heads/by-url
  # git resolves a local path without its .git suffix, so this alias reaches
  # the same bare repository origin names with one.
  git -C "$FX_WT" remote add alias "file://${FX_ORIGIN%.git}"
  push alias HEAD:refs/heads/alias-dotgit
  refused "a remote aliasing origin without its trailing .git" "shared origin" "$FX_ORIGIN" refs/heads/alias-dotgit
  git -C "$FX_WT" remote set-url alias "file://$FX_ORIGIN/"
  push alias HEAD:refs/heads/alias-slash
  refused "a remote aliasing origin with a trailing slash" "shared origin" "$FX_ORIGIN" refs/heads/alias-slash
  pass "push guard: origin, origin's URL, and a remote aliasing origin's URL are all refused"
}

test_backup_namespace_rules() {
  fixture backup fm/ backup
  push backup "HEAD:refs/heads/$FX_BRANCH"
  refused "the task branch pushed to the backup remote" "your task branch" "$FX_BACKUP" "refs/heads/$FX_BRANCH"
  push backup HEAD:refs/heads/fm/other
  refused "a task-prefixed branch pushed to the backup remote" "task branch prefix fm/" "$FX_BACKUP" refs/heads/fm/other
  push backup HEAD:refs/heads/elsewhere
  refused "a ref outside the backup prefix" "outside refs/heads/backup/" "$FX_BACKUP" refs/heads/elsewhere
  push backup HEAD:refs/heads/backup/t1
  [ "$PUSH_RC" -eq 0 ] || fail "the durable copy to backup/t1 was refused: $PUSH_OUT"
  assert_equals "$(git -C "$FX_WT" rev-parse HEAD)" "$(git -C "$FX_BACKUP" rev-parse refs/heads/backup/t1)" \
    "the durable copy did not land on the backup remote"
  git -C "$FX_WT" rev-parse --verify --quiet refs/remotes/backup/backup/t1 >/dev/null \
    || fail "the durable copy left no remote-tracking ref for the done gate to read"
  pass "push guard: the backup remote takes only backup/<id>, never the task branch or prefix"
}

test_empty_prefix_still_refuses_the_task_branch() {
  local other
  fixture bare-prefix ''
  other="$TMP_ROOT/bare-prefix/other.git"
  git init -q --bare "$other"
  git -C "$FX_WT" remote add other "file://$other"
  push other "HEAD:refs/heads/$FX_BRANCH"
  refused "the bare task branch pushed with an empty prefix" "your task branch" "$other" "refs/heads/$FX_BRANCH"
  push other HEAD:refs/heads/unrelated
  [ "$PUSH_RC" -eq 0 ] || fail "an unrelated branch to a non-shared remote was refused: $PUSH_OUT"
  pass "push guard: with an empty task prefix the bare task branch is still refused anywhere"
}

test_repository_pre_push_still_chains() {
  local hooks_dir marker
  fixture chain fm/ backup
  hooks_dir=$(git -C "$FX_WT" rev-parse --path-format=absolute --git-path hooks)
  mkdir -p "$hooks_dir"
  marker="$TMP_ROOT/chain/pre-push-ran"
  cat >"$hooks_dir/pre-push" <<EOF
#!/usr/bin/env bash
cat >"$marker"
[ ! -e "$TMP_ROOT/chain/block" ]
EOF
  chmod +x "$hooks_dir/pre-push"
  push backup HEAD:refs/heads/backup/t1
  [ "$PUSH_RC" -eq 0 ] || fail "a passing guard did not let the push through: $PUSH_OUT"
  assert_contains "$(cat "$marker")" "refs/heads/backup/t1" "the repository pre-push hook did not receive git's ref lines"
  rm -f "$marker"
  : >"$TMP_ROOT/chain/block"
  git -C "$FX_WT" commit -q --allow-empty -m 'second change'
  push backup HEAD:refs/heads/backup/t1
  [ "$PUSH_RC" -ne 0 ] || fail "a failing repository pre-push hook no longer blocks the push"
  assert_present "$marker" "the repository pre-push hook did not run after the guard passed"
  rm -f "$marker"
  push origin HEAD:refs/heads/x
  [ "$PUSH_RC" -ne 0 ] || fail "origin push was accepted"
  assert_absent "$marker" "the repository pre-push hook ran even though the guard refused"
  pass "push guard: the repository's own pre-push hook runs after the guard passes and still blocks"
}

test_unreadable_guard_refuses_everything() {
  local out rc
  out=$(printf 'refs/heads/a 1 refs/heads/a 0\n' | "$GUARD" "$TMP_ROOT/no-such-guard" other https://example.test/x 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a missing guard file let a push through"
  assert_contains "$out" "unreadable" "a missing guard file was refused without saying why"
  pass "push guard: an unreadable guard file refuses every push"
}

test_origin_pushes_are_refused
test_backup_namespace_rules
test_empty_prefix_still_refuses_the_task_branch
test_repository_pre_push_still_chains
test_unreadable_guard_refuses_everything

echo "# all fm-git-push-guard tests passed"
