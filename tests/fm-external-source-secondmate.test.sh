#!/usr/bin/env bash
# Public no-clone secondmate seed and linked-worktree workflow.
set -u

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-external-source-secondmate)

test_external_source_seed_and_identity() {
  local parent=$TMP_ROOT/parent home=$TMP_ROOT/home source=$TMP_ROOT/kneron-mlir
  local other=$TMP_ROOT/other-source err=$TMP_ROOT/identity.err before source_gitdir
  mkdir -p "$parent/data" "$parent/state"
  mark_firstmate_home "$home"
  fm_git_init_commit "$source"
  fm_git_init_commit "$other"
  source_gitdir=$(git -C "$source" rev-parse --absolute-git-dir)

  FM_HOME="$parent" FM_SECONDMATE_CHARTER='Own all kneron-mlir tasks.' \
    FM_SECONDMATE_SCOPE='All kneron-mlir work, including local-only tasks.' \
    "$ROOT/bin/fm-home-seed.sh" mlir "$home" --source-repo "$source" >/dev/null \
    || fail "no-clone seed failed"
  assert_grep "path=$source" "$home/data/external-source" "source path was not recorded"
  assert_grep "gitdir=$source_gitdir" "$home/data/external-source" "Git identity was not recorded"
  assert_grep "External source repository: $source" "$home/data/charter.md" "charter lost source path"
  assert_grep 'fm-spawn.sh' "$home/data/charter.md" "charter does not route through fm-spawn"
  [ -z "$(ls -A "$home/projects")" ] || fail "no-clone seed populated projects/"
  [ -z "$(git -C "$source" status --porcelain)" ] || fail "seed modified source checkout"
  FM_HOME="$parent" FM_SECONDMATE_CHARTER='Own all kneron-mlir tasks.' \
    "$ROOT/bin/fm-home-seed.sh" mlir "$home" --source-repo "$source" >/dev/null \
    || fail "matching source reseed failed"

  before=$(cat "$home/data/external-source")
  if FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mlir "$home" --source-repo "$other" >/dev/null 2>"$err"; then
    fail "existing home accepted a different source"
  fi
  assert_grep 'different external source identity' "$err" "source mismatch was not explained"
  [ "$(cat "$home/data/external-source")" = "$before" ] || fail "source mismatch changed the binding"
  if FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mlir "$home" --no-projects >/dev/null 2>"$err"; then
    fail "source home converted to project-less mode"
  fi
  pass "no-clone seed records canonical source identity and validates existing homes"
}

test_external_source_failure_rollback() {
  local parent=$TMP_ROOT/rollback-parent home=$TMP_ROOT/rollback-home source=$TMP_ROOT/rollback-repo
  mkdir -p "$parent/data" "$parent/state"
  fm_git_init_commit "$source"
  if FM_HOME="$parent" FM_SECONDMATE_CHARTER='   ' \
    "$ROOT/bin/fm-home-seed.sh" mlir "$home" --source-repo "$source" >/dev/null 2>&1; then
    fail "empty charter unexpectedly seeded an external source home"
  fi
  assert_absent "$home" "failed seed left a new home"
  assert_absent "$parent/data/mlir/brief.md" "failed seed left its generated charter"
  assert_absent "$parent/data/secondmates.md" "failed seed left a route"
  [ -z "$(git -C "$source" status --porcelain)" ] || fail "failed seed modified source checkout"
  pass "no-clone seed rolls back without touching the source repository"
}

test_external_source_rejects_nonprimary_and_overlap() {
  local parent=$TMP_ROOT/reject-parent source=$TMP_ROOT/reject-source linked=$TMP_ROOT/reject-linked
  local err=$TMP_ROOT/reject.err
  mkdir -p "$parent/data" "$parent/state"
  fm_git_init_commit "$source"
  git -C "$source" worktree add --quiet -b linked "$linked"
  if FM_HOME="$parent" FM_SECONDMATE_CHARTER='External work.' \
    "$ROOT/bin/fm-home-seed.sh" mlir "$TMP_ROOT/reject-home" --source-repo "$linked" >/dev/null 2>"$err"; then
    fail "source accepted a linked worktree instead of the primary checkout"
  fi
  assert_grep 'primary checkout' "$err" "linked-worktree refusal was not precise"
  if FM_HOME="$parent" FM_SECONDMATE_CHARTER='External work.' \
    "$ROOT/bin/fm-home-seed.sh" mlir "$source/nested-home" --source-repo "$source" >/dev/null 2>"$err"; then
    fail "seed wrote a home inside the source checkout"
  fi
  assert_absent "$source/nested-home" "overlap refusal wrote inside source"
  local spaced="$TMP_ROOT/spaced source"
  fm_git_init_commit "$spaced"
  if FM_HOME="$parent" FM_SECONDMATE_CHARTER='External work.' \
    "$ROOT/bin/fm-home-seed.sh" mlir "$TMP_ROOT/spaced-home" --source-repo "$spaced" >/dev/null 2>"$err"; then
    fail "source with whitespace in its name was accepted"
  fi
  assert_grep 'whitespace' "$err" "whitespace refusal was not precise"
  mkdir -p "$parent/data/slash"
  FM_HOME="$parent" FM_SECONDMATE_CHARTER='External work.' \
    "$ROOT/bin/fm-brief.sh" slash --secondmate --source-repo "$source/" >/dev/null || fail "trailing-slash scaffold failed"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" slash "$TMP_ROOT/slash-home" --source-repo "$source" >/dev/null 2>"$err" \
    || fail "trailing-slash charter conflicted with canonical seed: $(cat "$err")"
  pass "source validation rejects linked worktrees, whitespace names, and home overlap"
}

test_external_source_linked_worktree_and_retirement() {
  local parent=$TMP_ROOT/work-parent home=$TMP_ROOT/work-home source=$TMP_ROOT/work-source
  local linked=$TMP_ROOT/work-linked other=$TMP_ROOT/work-other fakebin=$TMP_ROOT/work-fake log=$TMP_ROOT/work-fake.log
  local task=mlir-task err=$TMP_ROOT/teardown.err
  mkdir -p "$parent/data" "$parent/state" "$fakebin"
  mark_firstmate_home "$home"
  fm_git_init_commit "$source"
  fm_git_add_origin "$source" "$source.origin.git"
  FM_HOME="$parent" FM_SECONDMATE_CHARTER='Own MLIR work.' \
    "$ROOT/bin/fm-home-seed.sh" mlir "$home" --source-repo "$source" >/dev/null \
    || fail "external source seed failed before child spawn"
  mkdir -p "$home/data/$task"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$task" "$(basename "$source")" --mode local-only >/dev/null
  sed 's/{TASK}/Implement the requested MLIR change./; s/{FIRSTMATE_SPEC}/Use the external source repository./' \
    "$home/data/$task/brief.md" > "$home/data/$task/brief.tmp"
  mv "$home/data/$task/brief.tmp" "$home/data/$task/brief.md"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
prev=
for a in "$@"; do
  [ "$prev" != -c ] || printf '%s\n' "$a" > "$FM_FAKE_PANE_DIR"
  prev=$a
done
if [ "${1:-}" = send-keys ]; then
  printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
  case "$*" in
    *'treehouse get'*) git -C "$(cat "$FM_FAKE_PANE_DIR")" worktree add --quiet -b linked-task "$FM_FAKE_CHILD_WT" ;;
  esac
fi
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_CHILD_WT" ;;
  *'#{cursor_y}'*) printf '0\n' ;;
  *) case "${1:-}" in display-message) printf 'firstmate\n' ;; esac ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  if ! PATH="$fakebin:$PATH" FM_HOME="$home" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_CHILD_WT="$linked" FM_FAKE_TREEHOUSE_LOG="$log" FM_FAKE_PANE_DIR="$TMP_ROOT/work-pane" TMUX='fake,1,0' \
    "$ROOT/bin/fm-spawn.sh" "$task" "$source" --mode local-only --yolo off --harness codex >/dev/null 2>"$err"; then
    fail "child spawn from external source failed: $(cat "$err")"
  fi
  assert_grep "project=$source" "$home/state/$task.meta" "spawn used another repository"
  assert_grep "worktree=$linked" "$home/state/$task.meta" "spawn did not record linked worktree"
  assert_grep 'get' "$log" "spawn did not ask Treehouse for a worktree"
  [ "$(cat "$TMP_ROOT/work-pane")" = "$source" ] || fail "spawn did not start the pane in the recorded source"
  git -C "$source" worktree list --porcelain | grep -Fx "worktree $linked" >/dev/null \
    || fail "linked task copy is absent from the source repository worktree list"
  fm_git_init_commit "$other"
  mkdir -p "$home/data/wrong-source"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" wrong-source "$(basename "$other")" --mode local-only >/dev/null
  sed 's/{TASK}/Check source binding./; s/{FIRSTMATE_SPEC}/Use the recorded source./' \
    "$home/data/wrong-source/brief.md" > "$home/data/wrong-source/brief.tmp"
  mv "$home/data/wrong-source/brief.tmp" "$home/data/wrong-source/brief.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_CHILD_WT="$linked" FM_FAKE_TREEHOUSE_LOG="$log" TMUX='fake,1,0' \
    "$ROOT/bin/fm-spawn.sh" wrong-source "$other" --mode local-only --yolo off --harness codex >/dev/null 2>"$err"; then
    fail "external-source home spawned from a different repository"
  fi
  assert_grep 'does not match this home' "$err" "wrong-source spawn did not explain its refusal"
  assert_absent "$home/state/wrong-source.meta" "wrong-source spawn wrote task metadata"
  if FM_HOME="$home" "$ROOT/bin/fm-brief.sh" feature-task "$(basename "$source")" \
    --mode local-only --base-branch feat/review >/dev/null 2>"$err"; then
    fail "local-only task accepted an unsupported feature-branch target"
  fi
  assert_grep 'base branch cannot ship mode=local-only' "$err" "feature-branch refusal was not precise"
  git -C "$linked" checkout -q -b "fm/$task"
  printf 'unlanded\n' >> "$linked/README.md"
  git -C "$linked" add README.md
  git -C "$linked" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm unlanded
  git -C "$source" checkout -q -b feat/review
  if FM_HOME="$home" "$ROOT/bin/fm-merge-local.sh" "$task" >/dev/null 2>"$err"; then
    fail "local landing moved a source checkout on a feature branch"
  fi
  assert_grep "expected default branch 'main'" "$err" "feature-branch landing did not give a precise refusal"
  git -C "$linked" show-ref --verify --quiet "refs/heads/fm/$task" \
    || fail "feature-branch landing refusal lost the task branch"
  fm_write_secondmate_meta "$parent/state/mlir.meta" "$home"
  if PATH="$fakebin:$PATH" FM_HOME="$parent" FM_BACKEND=tmux \
    "$ROOT/bin/fm-teardown.sh" mlir >/dev/null 2>"$err"; then
    fail "retirement discarded a child with unlanded work"
  fi
  assert_grep 'still has in-flight work' "$err" "retirement did not reach the child-work guard"
  assert_present "$home/state/$task.meta" "retirement removed the unlanded child record"
  assert_present "$linked/README.md" "retirement removed the unlanded worktree"
  assert_present "$parent/data/secondmates.md" "retirement lost the route"
  pass "external child uses a linked source worktree and retirement preserves unlanded work"
}

test_external_source_seed_and_identity
test_external_source_failure_rollback
test_external_source_rejects_nonprimary_and_overlap
test_external_source_linked_worktree_and_retirement
