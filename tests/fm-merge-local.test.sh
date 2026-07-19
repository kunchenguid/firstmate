#!/usr/bin/env bash
# Regression tests for bin/fm-merge-local.sh's guarded local-only landing.
#
# The legacy path lands only on the checked-out default branch.
# An explicit --target path lands only on the named clean, checked-out local
# branch, and every refusal leaves all local branch refs and working state intact.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST

make_case() {
  local name=$1 target=${2:-main} mode=${3:-local-only}
  local case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fm-root/bin" "$case_dir/project"

  cat > "$case_dir/fm-root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fm-root/bin/fm-guard.sh"

  git -C "$case_dir/project" init -q
  git -C "$case_dir/project" symbolic-ref HEAD refs/heads/main
  printf '%s\n' baseline > "$case_dir/project/README.md"
  git -C "$case_dir/project" add README.md
  git -C "$case_dir/project" commit -qm baseline

  if [ "$target" != main ]; then
    git -C "$case_dir/project" branch "$target"
    git -C "$case_dir/project" checkout -q "$target"
  fi

  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/task-wt" "$target"
  printf '%s\n' task > "$case_dir/task-wt/task.txt"
  git -C "$case_dir/task-wt" add task.txt
  git -C "$case_dir/task-wt" commit -qm 'task change'

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/task-wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=$mode" \
    "sentinel=preserved"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

run_merge() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$case_dir/fm-root" \
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" "$@"
}

snapshot_repo() {
  local case_dir=$1 output=$2
  {
    git -C "$case_dir/project" for-each-ref \
      --format='%(refname) %(objectname)' | sort
    printf 'HEAD %s\n' "$(git -C "$case_dir/project" symbolic-ref --quiet --short HEAD 2>/dev/null || printf detached)"
    git -C "$case_dir/project" status --porcelain=v1 --untracked-files=all
  } > "$output"
}

assert_refusal_without_mutation() {
  local case_dir=$1 label=$2 rc
  shift 2
  snapshot_repo "$case_dir" "$case_dir/$label.before"
  set +e
  run_merge "$case_dir" "$@" > "$case_dir/$label.stdout" 2> "$case_dir/$label.stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$label: command unexpectedly succeeded"
  snapshot_repo "$case_dir" "$case_dir/$label.after"
  cmp -s "$case_dir/$label.before" "$case_dir/$label.after" \
    || fail "$label: refusal mutated local refs, checkout, or working state"
}

test_legacy_default_target() {
  local case_dir main_before task_head main_after
  case_dir=$(make_case legacy-default main)
  main_before=$(git -C "$case_dir/project" rev-parse refs/heads/main)
  task_head=$(git -C "$case_dir/project" rev-parse refs/heads/fm/task-x1)

  run_merge "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "legacy-default: guarded landing failed"
  main_after=$(git -C "$case_dir/project" rev-parse refs/heads/main)

  [ "$main_before" != "$main_after" ] || fail "legacy-default: main did not move"
  [ "$main_after" = "$task_head" ] || fail "legacy-default: main did not fast-forward to the task branch"
  assert_grep 'local target main' "$case_dir/stdout" \
    "legacy-default: success output did not name main"
  assert_grep 'local_merge_target=main' "$case_dir/state/task-x1.meta" \
    "legacy-default: successful landing did not record main"
  assert_grep 'sentinel=preserved' "$case_dir/state/task-x1.meta" \
    "legacy-default: successful landing did not preserve existing metadata"
  pass "fm-merge-local preserves the no-option default-branch fast-forward"
}

test_explicit_feature_target() {
  local case_dir main_before feature_before task_head
  case_dir=$(make_case explicit-feature feature/for-you-feed)
  main_before=$(git -C "$case_dir/project" rev-parse refs/heads/main)
  feature_before=$(git -C "$case_dir/project" rev-parse refs/heads/feature/for-you-feed)
  task_head=$(git -C "$case_dir/project" rev-parse refs/heads/fm/task-x1)
  printf '%s\n' 'local_merge_target=stale-target' >> "$case_dir/state/task-x1.meta"

  run_merge "$case_dir" task-x1 --target feature/for-you-feed \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "explicit-feature: guarded landing failed"

  [ "$(git -C "$case_dir/project" rev-parse refs/heads/main)" = "$main_before" ] \
    || fail "explicit-feature: main changed"
  [ "$(git -C "$case_dir/project" rev-parse refs/heads/feature/for-you-feed)" = "$task_head" ] \
    || fail "explicit-feature: feature target did not fast-forward to the task branch"
  [ "$feature_before" != "$task_head" ] || fail "explicit-feature: fixture did not require a fast-forward"
  assert_grep 'local target feature/for-you-feed' "$case_dir/stdout" \
    "explicit-feature: success output did not name the actual target"
  assert_grep 'local_merge_target=feature/for-you-feed' "$case_dir/state/task-x1.meta" \
    "explicit-feature: successful landing did not record the actual target"
  assert_grep 'sentinel=preserved' "$case_dir/state/task-x1.meta" \
    "explicit-feature: successful landing did not preserve existing metadata"
  [ "$(grep -c '^local_merge_target=' "$case_dir/state/task-x1.meta")" = 1 ] \
    || fail "explicit-feature: successful landing did not canonicalize target metadata"
  pass "fm-merge-local fast-forwards an explicitly requested clean feature target without changing main"
}

test_wrong_checked_out_branch_refuses() {
  local case_dir
  case_dir=$(make_case wrong-checkout feature/for-you-feed)
  git -C "$case_dir/project" checkout -q main
  assert_refusal_without_mutation "$case_dir" wrong-checkout \
    task-x1 --target feature/for-you-feed
  assert_grep "expected target branch 'feature/for-you-feed'" "$case_dir/wrong-checkout.stderr" \
    "wrong-checkout: refusal did not name the requested target"
  pass "fm-merge-local refuses when the main local copy is checked out on another branch"
}

test_dirty_target_refuses() {
  local case_dir
  case_dir=$(make_case dirty-target feature/for-you-feed)
  printf '%s\n' dirty > "$case_dir/project/untracked.txt"
  assert_refusal_without_mutation "$case_dir" dirty-target \
    task-x1 --target feature/for-you-feed
  assert_grep "target 'feature/for-you-feed'" "$case_dir/dirty-target.stderr" \
    "dirty-target: refusal did not name the requested target"
  pass "fm-merge-local refuses a dirty explicit target without mutation"
}

test_nonexistent_target_refuses() {
  local case_dir task_head
  case_dir=$(make_case nonexistent-target main)
  task_head=$(git -C "$case_dir/project" rev-parse refs/heads/fm/task-x1)
  git -C "$case_dir/project" update-ref refs/remotes/origin/feature/remote-only "$task_head"

  assert_refusal_without_mutation "$case_dir" nonexistent-target \
    task-x1 --target feature/missing
  assert_grep "target branch 'feature/missing' does not exist locally" "$case_dir/nonexistent-target.stderr" \
    "nonexistent-target: refusal did not identify the missing local branch"

  assert_refusal_without_mutation "$case_dir" remote-only-target \
    task-x1 --target feature/remote-only
  assert_grep "target branch 'feature/remote-only' does not exist locally" "$case_dir/remote-only-target.stderr" \
    "remote-only-target: a remote-tracking ref satisfied the local target guard"
  pass "fm-merge-local refuses nonexistent and remote-only explicit targets without mutation"
}

test_invalid_and_injection_targets_refuse() {
  local case_dir marker
  case_dir=$(make_case invalid-targets main)
  marker="$case_dir/injected"

  assert_refusal_without_mutation "$case_dir" invalid-ref \
    task-x1 --target bad..branch
  assert_grep "invalid target branch 'bad..branch'" "$case_dir/invalid-ref.stderr" \
    "invalid-ref: refusal did not identify the invalid target"

  assert_refusal_without_mutation "$case_dir" injection-target \
    task-x1 --target "feature/\$(touch $marker)"
  assert_grep 'unsafe or option-like target branch' "$case_dir/injection-target.stderr" \
    "injection-target: refusal did not identify unsafe input"
  assert_absent "$marker" "injection-target: target input was evaluated"
  pass "fm-merge-local rejects invalid and shell-injection-shaped targets without evaluation or mutation"
}

test_injection_shaped_default_target_refuses() {
  local case_dir target marker
  case_dir=$(make_case injection-default main)
  marker="$case_dir/state/injected"
  # shellcheck disable=SC2016 # Deliberately preserve the injection payload literally.
  target='release$(touch${IFS}$FM_STATE_OVERRIDE/injected)'
  git -C "$case_dir/project" branch -m "$target"
  git -C "$case_dir/project" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$target"

  assert_refusal_without_mutation "$case_dir" injection-default task-x1
  assert_grep 'unsafe or option-like target branch' "$case_dir/injection-default.stderr" \
    "injection-default: refusal did not identify the unsafe derived target"
  assert_absent "$marker" "injection-default: derived target was evaluated"
  pass "fm-merge-local rejects an injection-shaped default target without mutation"
}

test_task_branch_as_target_refuses() {
  local case_dir
  case_dir=$(make_case task-as-target main)
  assert_refusal_without_mutation "$case_dir" task-as-target \
    task-x1 --target fm/task-x1
  assert_grep "target branch 'fm/task-x1' is the task branch" "$case_dir/task-as-target.stderr" \
    "task-as-target: refusal did not identify the self-target"
  pass "fm-merge-local refuses the task branch as its own target without mutation"
}

test_diverged_target_refuses() {
  local case_dir
  case_dir=$(make_case diverged-target feature/for-you-feed)
  printf '%s\n' target > "$case_dir/project/target.txt"
  git -C "$case_dir/project" add target.txt
  git -C "$case_dir/project" commit -qm 'target divergence'

  assert_refusal_without_mutation "$case_dir" diverged-target \
    task-x1 --target feature/for-you-feed
  assert_grep "not a fast-forward of target 'feature/for-you-feed'" "$case_dir/diverged-target.stderr" \
    "diverged-target: refusal did not name the diverged target"
  pass "fm-merge-local refuses a diverged explicit target without mutation"
}

test_missing_task_branch_refuses() {
  local case_dir
  case_dir=$(make_case missing-task feature/for-you-feed)
  git -C "$case_dir/project" worktree remove --force "$case_dir/task-wt"
  git -C "$case_dir/project" branch -D fm/task-x1 >/dev/null

  assert_refusal_without_mutation "$case_dir" missing-task \
    task-x1 --target feature/for-you-feed
  assert_grep "task branch 'fm/task-x1' does not exist" "$case_dir/missing-task.stderr" \
    "missing-task: refusal did not identify the missing task branch"
  assert_grep "target 'feature/for-you-feed' was not changed" "$case_dir/missing-task.stderr" \
    "missing-task: refusal did not name the unchanged target"
  pass "fm-merge-local refuses a missing task branch without mutation"
}

test_non_local_only_mode_refuses() {
  local case_dir
  case_dir=$(make_case wrong-mode feature/for-you-feed no-mistakes)
  assert_refusal_without_mutation "$case_dir" wrong-mode \
    task-x1 --target feature/for-you-feed
  assert_grep 'not local-only' "$case_dir/wrong-mode.stderr" \
    "wrong-mode: refusal did not enforce local-only mode"
  pass "fm-merge-local preserves the local-only mode guard without mutation"
}

test_option_parsing_refuses() {
  local case_dir
  case_dir=$(make_case option-parsing main)

  assert_refusal_without_mutation "$case_dir" missing-target-value task-x1 --target
  assert_grep '--target requires a local branch name' "$case_dir/missing-target-value.stderr" \
    "missing-target-value: refusal did not explain the missing value"

  assert_refusal_without_mutation "$case_dir" empty-target-value task-x1 --target ''
  assert_grep '--target requires a non-empty local branch name' "$case_dir/empty-target-value.stderr" \
    "empty-target-value: refusal did not explain the empty value"

  assert_refusal_without_mutation "$case_dir" unknown-option task-x1 --bogus
  assert_grep "unknown option '--bogus'" "$case_dir/unknown-option.stderr" \
    "unknown-option: refusal did not identify the option"

  assert_refusal_without_mutation "$case_dir" extra-positional task-x1 extra
  assert_grep "unexpected positional argument 'extra'" "$case_dir/extra-positional.stderr" \
    "extra-positional: refusal did not identify the extra argument"

  assert_refusal_without_mutation "$case_dir" extra-after-target \
    task-x1 --target main extra
  assert_grep "unexpected extra argument 'extra'" "$case_dir/extra-after-target.stderr" \
    "extra-after-target: refusal did not identify the extra argument"

  assert_refusal_without_mutation "$case_dir" option-like-target \
    task-x1 --target --feature
  assert_grep "unsafe or option-like target branch '--feature'" "$case_dir/option-like-target.stderr" \
    "option-like-target: refusal did not identify the option-like branch"
  pass "fm-merge-local rejects malformed option shapes without mutation"
}

test_unsafe_task_metadata_refuses() {
  local case_dir linked_meta original_meta
  case_dir=$(make_case unsafe-meta-symlink main)
  linked_meta="$case_dir/linked.meta"
  mv "$case_dir/state/task-x1.meta" "$linked_meta"
  original_meta=$(cat "$linked_meta")
  ln -s "$linked_meta" "$case_dir/state/task-x1.meta"
  assert_refusal_without_mutation "$case_dir" symlink-meta task-x1
  [ "$(cat "$linked_meta")" = "$original_meta" ] \
    || fail "symlink-meta: landing wrote through linked task metadata"

  case_dir=$(make_case unsafe-meta-hardlink main)
  linked_meta="$case_dir/linked.meta"
  ln "$case_dir/state/task-x1.meta" "$linked_meta"
  original_meta=$(cat "$linked_meta")
  assert_refusal_without_mutation "$case_dir" hardlink-meta task-x1
  [ "$(cat "$linked_meta")" = "$original_meta" ] \
    || fail "hardlink-meta: landing changed multiply linked task metadata"
  pass "fm-merge-local refuses symlinked and multiply linked task metadata without mutation"
}

test_concurrent_metadata_update_is_preserved() {
  local case_dir fakebin rc task_head
  case_dir=$(make_case concurrent-meta main)
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" merge --ff-only "*) printf '%s\n' 'concurrent=preserved' >> "${FM_TEST_META:?}" ;;
esac
exec "${REAL_GIT_FOR_TEST:?}" "$@"
SH
  chmod +x "$fakebin/git"
  task_head=$(git -C "$case_dir/project" rev-parse refs/heads/fm/task-x1)

  set +e
  PATH="$fakebin:$PATH" FM_TEST_META="$case_dir/state/task-x1.meta" \
    run_merge "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "concurrent-meta: landing silently replaced changed metadata"
  assert_grep 'task metadata changed during local merge' "$case_dir/stderr" \
    "concurrent-meta: landing did not report the concurrent metadata update"
  assert_grep 'concurrent=preserved' "$case_dir/state/task-x1.meta" \
    "concurrent-meta: landing discarded the concurrent metadata update"
  assert_no_grep '^local_merge_target=' "$case_dir/state/task-x1.meta" \
    "concurrent-meta: landing replaced metadata after detecting an update"
  [ "$(git -C "$case_dir/project" rev-parse refs/heads/main)" = "$task_head" ] \
    || fail "concurrent-meta: fixture did not reach the post-merge metadata guard"
  pass "fm-merge-local preserves concurrent in-place metadata updates"
}

test_unsafe_task_id_refuses() {
  local case_dir
  case_dir=$(make_case unsafe-task-id main)
  assert_refusal_without_mutation "$case_dir" unsafe-task-id ../task-x1
  assert_grep 'invalid task id' "$case_dir/unsafe-task-id.stderr" \
    "unsafe-task-id: refusal did not identify the invalid task id"
  pass "fm-merge-local rejects path-unsafe task ids without mutation"
}

test_legacy_default_target
test_explicit_feature_target
test_wrong_checked_out_branch_refuses
test_dirty_target_refuses
test_nonexistent_target_refuses
test_invalid_and_injection_targets_refuse
test_injection_shaped_default_target_refuses
test_task_branch_as_target_refuses
test_diverged_target_refuses
test_missing_task_branch_refuses
test_non_local_only_mode_refuses
test_option_parsing_refuses
test_unsafe_task_metadata_refuses
test_concurrent_metadata_update_is_preserved
test_unsafe_task_id_refuses
