#!/usr/bin/env bash
# Executable-interface regressions for fm-reconcile-identical-squash.sh.
# Every repository and remote is isolated under one temporary root.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fm-reconcile-tests fm-reconcile-tests@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-reconcile-identical-squash-tests)
HELPER="$ROOT/bin/fm-reconcile-identical-squash.sh"
CASE_N=0
RUN_RC=0
RUN_OUT=
RUN_ERR=

new_case_root() {
  CASE_N=$((CASE_N + 1))
  CASE_ROOT="$TMP_ROOT/case-$CASE_N-$1"
  mkdir -p "$CASE_ROOT"
}

commit_file() {
  local repo=$1 path=$2 content=$3 message=$4
  mkdir -p "$(dirname "$repo/$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit -qm "$message"
}

commit_same_tree_child() {
  local repo=$1 parent=$2 message=$3 tree
  tree=$(git -C "$repo" rev-parse "$parent^{tree}")
  printf '%s\n' "$message" | git -C "$repo" commit-tree "$tree" -p "$parent"
}

new_base_fixture() {
  local name=$1 remote_abs
  new_case_root "$name"
  SEED="$CASE_ROOT/seed"
  REMOTE="$CASE_ROOT/origin.git"
  REPO="$CASE_ROOT/repo"
  git init -q "$SEED"
  git -C "$SEED" symbolic-ref HEAD refs/heads/main
  commit_file "$SEED" tracked.txt stable base
  git clone --quiet --bare "$SEED" "$REMOTE"
  remote_abs=$(cd "$REMOTE" && pwd -P)
  git clone --quiet "file://$remote_abs" "$REPO"
  BASE_OID=$(git -C "$REPO" rev-parse HEAD)
}

# Create two child histories from BASE_OID. Each history adds and then removes a
# private file, so LOCAL_OLD and REMOTE_NEW genuinely diverge with one merge base
# while their exact root trees equal BASE_OID's tree.
make_divergent_identical() {
  commit_file "$REPO" local-only.txt local local-add
  rm "$REPO/local-only.txt"
  git -C "$REPO" add -u
  git -C "$REPO" commit -qm local-remove
  LOCAL_OLD=$(git -C "$REPO" rev-parse HEAD)

  commit_file "$SEED" remote-only.txt remote remote-add
  rm "$SEED/remote-only.txt"
  git -C "$SEED" add -u
  git -C "$SEED" commit -qm remote-remove
  REMOTE_NEW=$(git -C "$SEED" rev-parse HEAD)
  git -C "$SEED" push -q "file://$REMOTE" main
  PRESERVE_REF="refs/firstmate/identical-squash/6d61696e/$LOCAL_OLD"
}

new_divergent_fixture() {
  new_base_fixture "$1"
  make_divergent_identical
}

new_fast_forward_fixture() {
  new_base_fixture "$1"
  LOCAL_OLD=$(git -C "$REPO" rev-parse HEAD)
  commit_file "$SEED" remote.txt remote remote-ahead
  REMOTE_NEW=$(git -C "$SEED" rev-parse HEAD)
  git -C "$SEED" push -q "file://$REMOTE" main
  PRESERVE_REF="refs/firstmate/identical-squash/6d61696e/$LOCAL_OLD"
}

run_helper() {
  local repo=$1
  shift
  RUN_OUT="$CASE_ROOT/run.out"
  RUN_ERR="$CASE_ROOT/run.err"
  set +e
  "$@" "$HELPER" "$repo" > "$RUN_OUT" 2> "$RUN_ERR"
  RUN_RC=$?
  set -e
}

run_helper_plain() {
  run_helper "$1" env
}

assert_direct_ref() {
  local repo=$1 ref=$2 expected=$3 label=$4
  ! git -C "$repo" symbolic-ref -q "$ref" >/dev/null 2>&1 \
    || fail "$label: $ref is symbolic"
  [ "$(git -C "$repo" rev-parse --verify "$ref")" = "$expected" ] \
    || fail "$label: $ref does not name $expected"
}

assert_no_preservation_namespace() {
  local repo=$1 label=$2
  [ -z "$(git -C "$repo" for-each-ref --format='%(refname)' refs/firstmate/identical-squash)" ] \
    || fail "$label: helper created an unauthorized preservation ref"
}

assert_refused_without_move() {
  local repo=$1 before=$2 label=$3
  [ "$RUN_RC" -ne 0 ] || fail "$label: expected refusal"
  [ "$(git -C "$repo" rev-parse HEAD)" = "$before" ] \
    || fail "$label: checked-out branch moved"
  assert_no_preservation_namespace "$repo" "$label"
}

snapshot_refs() {
  git -C "$1" for-each-ref --format='%(refname)%09%(objectname)%09%(symref)' > "$2"
}

# The main success regression also proves the empirically selected source-only
# fetch surface: configured destination refspecs, FETCH_HEAD, tags, and unrelated
# refs remain untouched while the exact source-backed remote object is acquired.
test_divergent_identical_succeeds_and_repeats() {
  local old_tracking old_fetch_hash unrelated_oid local_tag_oid refs_before_second refs_after_second
  new_divergent_fixture success

  printf 'FETCH_HEAD sentinel\n' > "$REPO/.git/FETCH_HEAD"
  old_fetch_hash=$(git hash-object "$REPO/.git/FETCH_HEAD")
  old_tracking=$(git -C "$REPO" rev-parse refs/remotes/origin/main)
  git -C "$REPO" update-ref refs/unrelated/keep "$BASE_OID"
  unrelated_oid=$(git -C "$REPO" rev-parse refs/unrelated/keep)
  git -C "$REPO" tag local-keep "$LOCAL_OLD"
  local_tag_oid=$(git -C "$REPO" rev-parse refs/tags/local-keep)
  git --git-dir="$REMOTE" tag remote-must-not-follow "$REMOTE_NEW"

  run_helper_plain "$REPO"

  expect_code 0 "$RUN_RC" "identical divergent histories"
  assert_grep "committed: moved refs/heads/main from $LOCAL_OLD to $REMOTE_NEW" "$RUN_OUT" \
    "success did not report the exact branch movement"
  assert_grep "repeat invocation will converge without mutation" "$RUN_OUT" \
    "success did not report repeat-run convergence"
  assert_direct_ref "$REPO" refs/heads/main "$REMOTE_NEW" "success branch"
  assert_direct_ref "$REPO" "$PRESERVE_REF" "$LOCAL_OLD" "success preservation"
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$REMOTE_NEW" ] \
    || fail "success: HEAD did not follow the moved default branch"
  [ "$(git -C "$REPO" rev-parse "$LOCAL_OLD^{tree}")" = "$(git -C "$REPO" rev-parse "$REMOTE_NEW^{tree}")" ] \
    || fail "success fixture does not have identical exact root trees"
  [ "$(git hash-object "$REPO/.git/FETCH_HEAD")" = "$old_fetch_hash" ] \
    || fail "success: FETCH_HEAD bytes changed"
  [ "$(git -C "$REPO" rev-parse refs/remotes/origin/main)" = "$old_tracking" ] \
    || fail "success: configured remote-tracking ref changed"
  [ "$(git -C "$REPO" rev-parse refs/unrelated/keep)" = "$unrelated_oid" ] \
    || fail "success: unrelated ref changed"
  [ "$(git -C "$REPO" rev-parse refs/tags/local-keep)" = "$local_tag_oid" ] \
    || fail "success: local tag changed"
  ! git -C "$REPO" show-ref --verify --quiet refs/tags/remote-must-not-follow \
    || fail "success: remote tag was fetched"
  [ -z "$(git -C "$REPO" status --porcelain=v1)" ] || fail "success: repository is not clean"

  refs_before_second="$CASE_ROOT/refs.before-second"
  refs_after_second="$CASE_ROOT/refs.after-second"
  snapshot_refs "$REPO" "$refs_before_second"
  run_helper_plain "$REPO"
  expect_code 0 "$RUN_RC" "repeat invocation"
  assert_grep "already reconciled" "$RUN_OUT" "repeat invocation did not converge"
  snapshot_refs "$REPO" "$refs_after_second"
  cmp -s "$refs_before_second" "$refs_after_second" \
    || fail "repeat invocation changed refs"
  [ "$(git hash-object "$REPO/.git/FETCH_HEAD")" = "$old_fetch_hash" ] \
    || fail "repeat invocation changed FETCH_HEAD"
  pass "divergent identical trees reconcile atomically, preserve all unrelated state, and repeat safely"
}

# Even when repository config requests recursive submodule fetches, the helper's
# public behavior must leave an uninitialized submodule untouched.
test_submodules_are_not_fetched() {
  local sub_work sub_remote sub_oid module_url
  new_base_fixture no-submodules
  sub_work="$CASE_ROOT/sub-work"
  sub_remote="$CASE_ROOT/sub.git"
  git init -q "$sub_work"
  git -C "$sub_work" symbolic-ref HEAD refs/heads/main
  commit_file "$sub_work" payload.txt submodule sub-base
  sub_oid=$(git -C "$sub_work" rev-parse HEAD)
  git clone --quiet --bare "$sub_work" "$sub_remote"
  module_url="file://$(cd "$sub_remote" && pwd -P)"

  printf '[submodule "deps/sub"]\n\tpath = deps/sub\n\turl = %s\n' "$module_url" > "$REPO/.gitmodules"
  git -C "$REPO" add .gitmodules
  git -C "$REPO" update-index --add --cacheinfo "160000,$sub_oid,deps/sub"
  git -C "$REPO" commit -qm local-submodule-tree
  LOCAL_OLD=$(git -C "$REPO" rev-parse HEAD)
  mkdir -p "$REPO/deps/sub"

  cp "$REPO/.gitmodules" "$SEED/.gitmodules"
  git -C "$SEED" add .gitmodules
  git -C "$SEED" update-index --add --cacheinfo "160000,$sub_oid,deps/sub"
  git -C "$SEED" commit -qm remote-submodule-tree
  REMOTE_NEW=$(git -C "$SEED" rev-parse HEAD)
  git -C "$SEED" push -q "file://$REMOTE" main
  git -C "$REPO" config fetch.recurseSubmodules true

  run_helper_plain "$REPO"

  expect_code 0 "$RUN_RC" "no submodule recursion"
  [ ! -e "$REPO/.git/modules/deps/sub" ] \
    || fail "submodule repository was fetched despite --no-recurse-submodules"
  [ ! -e "$REPO/deps/sub/.git" ] \
    || fail "submodule worktree was initialized"
  assert_direct_ref "$REPO" refs/heads/main "$REMOTE_NEW" "submodule success branch"
  pass "configured recursive submodule fetching is suppressed"
}

test_configured_pruning_is_suppressed() {
  local local_tag_oid
  new_divergent_fixture configured-pruning
  git -C "$REPO" tag local-must-not-prune "$LOCAL_OLD"
  local_tag_oid=$(git -C "$REPO" rev-parse refs/tags/local-must-not-prune)
  git --git-dir="$REMOTE" tag remote-must-not-fetch "$REMOTE_NEW"
  git -C "$REPO" config fetch.prune true
  git -C "$REPO" config fetch.pruneTags true
  git -C "$REPO" config remote.origin.prune true
  git -C "$REPO" config remote.origin.pruneTags true

  run_helper_plain "$REPO"

  expect_code 0 "$RUN_RC" "configured pruning"
  assert_direct_ref "$REPO" refs/heads/main "$REMOTE_NEW" "configured pruning branch"
  [ "$(git -C "$REPO" rev-parse refs/tags/local-must-not-prune)" = "$local_tag_oid" ] \
    || fail "configured pruning changed or deleted a local tag"
  ! git -C "$REPO" show-ref --verify --quiet refs/tags/remote-must-not-fetch \
    || fail "configured pruning fetched a remote tag"
  pass "configured branch and tag pruning are suppressed"
}

test_ambient_git_overrides_refuse() {
  local name
  new_divergent_fixture ambient-git-overrides
  for name in \
    GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_CONFIG \
    GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_COUNT \
    GIT_DIR \
    GIT_WORK_TREE \
    GIT_IMPLICIT_WORK_TREE \
    GIT_COMMON_DIR \
    GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY \
    GIT_GRAFT_FILE \
    GIT_SHALLOW_FILE \
    GIT_NO_REPLACE_OBJECTS \
    GIT_REPLACE_REF_BASE \
    GIT_NAMESPACE \
    GIT_QUARANTINE_PATH
  do
    run_helper "$REPO" env "$name=$CASE_ROOT/ambient-override"
    assert_refused_without_move "$REPO" "$LOCAL_OLD" "ambient $name"
    assert_grep "ambient Git environment override $name must be unset" "$RUN_ERR" \
      "ambient $name refusal did not precede repository resolution"
  done
  pass "ambient repository, object, index, and graph overrides refuse before resolution"
}

test_virtual_or_incomplete_history_refuses() {
  new_divergent_fixture shallow-history
  printf '%s\n' "$BASE_OID" > "$REPO/.git/shallow"
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" shallow-history
  assert_grep "repository history is shallow" "$RUN_ERR" "shallow-history refusal was not actionable"

  new_divergent_fixture graft-history
  printf '%s %s\n' "$LOCAL_OLD" "$BASE_OID" > "$REPO/.git/info/grafts"
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" graft-history
  assert_grep "legacy graft history is present" "$RUN_ERR" "graft-history refusal was not actionable"

  new_divergent_fixture replacement-history
  git -C "$REPO" replace "$LOCAL_OLD" "$BASE_OID"
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" replacement-history
  assert_grep "replacement object history is present" "$RUN_ERR" \
    "replacement-history refusal was not actionable"
  pass "shallow, grafted, and replacement-overlaid histories refuse"
}

test_dirty_refuses() {
  new_divergent_fixture dirty
  printf 'staged dirty\n' >> "$REPO/tracked.txt"
  git -C "$REPO" add tracked.txt
  printf 'unstaged dirty\n' >> "$REPO/tracked.txt"
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" dirty
  assert_grep "worktree or index is not clean" "$RUN_ERR" "dirty refusal was not actionable"
  pass "dirty worktree and index refuse without ref mutation"
}

test_detached_refuses() {
  new_divergent_fixture detached
  git -C "$REPO" checkout --detach --quiet
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" detached
  assert_grep "HEAD is detached" "$RUN_ERR" "detached refusal was not actionable"
  pass "detached HEAD refuses without ref mutation"
}

test_off_default_refuses() {
  new_divergent_fixture off-default
  git -C "$REPO" switch -q -c feature
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" off-default
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = feature ] \
    || fail "off-default refusal changed the checked-out branch"
  assert_grep "not origin's source-backed default branch" "$RUN_ERR" \
    "off-default refusal was not actionable"
  pass "off-default branch refuses without ref mutation"
}

test_active_operation_refuses() {
  local merge_head_path
  new_divergent_fixture active-operation
  merge_head_path=$(git -C "$REPO" rev-parse --git-path MERGE_HEAD)
  printf '%s\n' "$BASE_OID" > "$REPO/$merge_head_path"
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" active-operation
  assert_grep "active Git operation or lock" "$RUN_ERR" "active-operation refusal was not actionable"
  pass "active Git operation refuses without ref mutation"
}

test_multiple_worktrees_refuse() {
  new_divergent_fixture multiple-worktrees
  git -C "$REPO" worktree add --quiet --detach "$CASE_ROOT/other-worktree" "$BASE_OID"
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" multiple-worktrees
  assert_grep "exactly one is required" "$RUN_ERR" "multi-worktree refusal was not actionable"
  pass "multiple registered worktrees refuse without ref mutation"
}

test_symbolic_local_ref_refuses() {
  new_divergent_fixture symbolic-local
  git -C "$REPO" update-ref refs/heads/direct-local "$LOCAL_OLD"
  git -C "$REPO" symbolic-ref refs/heads/main refs/heads/direct-local
  run_helper_plain "$REPO"
  [ "$RUN_RC" -ne 0 ] || fail "symbolic local ref: expected refusal"
  [ "$(git -C "$REPO" symbolic-ref refs/heads/main)" = refs/heads/direct-local ] \
    || fail "symbolic local ref was rewritten"
  assert_no_preservation_namespace "$REPO" "symbolic local ref"
  assert_grep "local branch ref is symbolic" "$RUN_ERR" "symbolic-local refusal was not actionable"
  pass "symbolic local default ref refuses without write-through"
}

test_symbolic_remote_tracking_ref_refuses() {
  new_divergent_fixture symbolic-remote-tracking
  git -C "$REPO" update-ref refs/remotes/origin/direct-target "$BASE_OID"
  git -C "$REPO" symbolic-ref refs/remotes/origin/main refs/remotes/origin/direct-target
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" symbolic-remote-tracking
  [ "$(git -C "$REPO" symbolic-ref refs/remotes/origin/main)" = refs/remotes/origin/direct-target ] \
    || fail "symbolic remote-tracking ref was rewritten"
  assert_grep "remote-tracking default ref is symbolic" "$RUN_ERR" \
    "symbolic remote-tracking refusal was not actionable"
  pass "symbolic remote-tracking default ref refuses without mutation"
}

test_existing_exact_preservation_ref_is_reused() {
  new_divergent_fixture existing-exact-preservation
  git -C "$REPO" update-ref "$PRESERVE_REF" "$LOCAL_OLD"
  run_helper_plain "$REPO"
  expect_code 0 "$RUN_RC" "existing exact preservation"
  assert_direct_ref "$REPO" refs/heads/main "$REMOTE_NEW" "existing preservation branch"
  assert_direct_ref "$REPO" "$PRESERVE_REF" "$LOCAL_OLD" "existing preservation"
  pass "existing exact direct preservation ref is reused idempotently"
}

test_conflicting_preservation_ref_refuses() {
  new_divergent_fixture conflicting-preservation
  git -C "$REPO" update-ref "$PRESERVE_REF" "$BASE_OID"
  run_helper_plain "$REPO"
  [ "$RUN_RC" -ne 0 ] || fail "conflicting preservation: expected refusal"
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$LOCAL_OLD" ] \
    || fail "conflicting preservation moved the branch"
  assert_direct_ref "$REPO" "$PRESERVE_REF" "$BASE_OID" "conflicting preservation"
  assert_grep "conflicting preservation ref" "$RUN_ERR" \
    "conflicting preservation refusal was not actionable"
  pass "conflicting deterministic preservation ref is never overwritten"
}

test_symbolic_preservation_ref_refuses() {
  new_divergent_fixture symbolic-preservation
  git -C "$REPO" update-ref refs/heads/preserved-target "$LOCAL_OLD"
  git -C "$REPO" symbolic-ref "$PRESERVE_REF" refs/heads/preserved-target
  run_helper_plain "$REPO"
  [ "$RUN_RC" -ne 0 ] || fail "symbolic preservation: expected refusal"
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$LOCAL_OLD" ] \
    || fail "symbolic preservation moved the branch"
  [ "$(git -C "$REPO" symbolic-ref "$PRESERVE_REF")" = refs/heads/preserved-target ] \
    || fail "symbolic preservation ref was rewritten"
  assert_grep "symbolic preservation ref" "$RUN_ERR" \
    "symbolic preservation refusal was not actionable"
  pass "symbolic preservation ref refuses without write-through"
}

test_fast_forward_refuses() {
  new_fast_forward_fixture fast-forward
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" fast-forward
  assert_grep "ordinary fast-forward" "$RUN_ERR" "fast-forward refusal was not actionable"
  pass "ordinary fast-forward case refuses without branch movement"
}

test_ahead_only_refuses() {
  new_base_fixture ahead-only
  commit_file "$REPO" local.txt ahead local-ahead
  LOCAL_OLD=$(git -C "$REPO" rev-parse HEAD)
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" ahead-only
  assert_grep "ahead of origin" "$RUN_ERR" "ahead-only refusal was not actionable"
  pass "ahead-only case refuses without branch movement"
}

test_unequal_tree_refuses() {
  new_divergent_fixture unequal-tree
  commit_file "$SEED" unequal.txt unequal unequal-tree
  REMOTE_NEW=$(git -C "$SEED" rev-parse HEAD)
  git -C "$SEED" push -q "file://$REMOTE" main
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" unequal-tree
  assert_grep "root trees are not identical" "$RUN_ERR" "unequal-tree refusal was not actionable"
  pass "divergent unequal trees refuse without ref mutation"
}

test_unrelated_identical_tree_refuses() {
  local tree unrelated
  new_divergent_fixture unrelated
  tree=$(git -C "$REPO" rev-parse "$LOCAL_OLD^{tree}")
  unrelated=$(printf 'unrelated root\n' | git --git-dir="$REMOTE" commit-tree "$tree")
  git --git-dir="$REMOTE" update-ref refs/heads/main "$unrelated" "$REMOTE_NEW"
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" unrelated
  assert_grep "histories are unrelated" "$RUN_ERR" "unrelated-history refusal was not actionable"
  pass "unrelated histories with identical trees refuse without ref mutation"
}

test_ambiguous_merge_base_refuses() {
  local tree a b local_merge remote_merge
  new_base_fixture ambiguous-base
  tree=$(git -C "$REPO" rev-parse "$BASE_OID^{tree}")
  a=$(printf 'side A\n' | git -C "$REPO" commit-tree "$tree" -p "$BASE_OID")
  b=$(printf 'side B\n' | git -C "$REPO" commit-tree "$tree" -p "$BASE_OID")
  local_merge=$(printf 'local criss-cross merge\n' | git -C "$REPO" commit-tree "$tree" -p "$a" -p "$b")
  remote_merge=$(printf 'remote criss-cross merge\n' | git -C "$REPO" commit-tree "$tree" -p "$b" -p "$a")
  git -C "$REPO" update-ref refs/heads/main "$local_merge" "$BASE_OID"
  git -C "$REPO" push -q "file://$REMOTE" "$remote_merge:refs/heads/main"
  LOCAL_OLD=$local_merge

  [ "$(git -C "$REPO" merge-base --all "$local_merge" "$remote_merge" | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "ambiguous fixture did not produce two merge bases"
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" ambiguous-base
  assert_grep "ambiguous merge-base set" "$RUN_ERR" "ambiguous-base refusal was not actionable"
  pass "ambiguous merge-base set refuses without ref mutation"
}

test_missing_remote_ref_refuses() {
  new_divergent_fixture missing-remote-ref
  git --git-dir="$REMOTE" update-ref -d refs/heads/main "$REMOTE_NEW"
  run_helper_plain "$REPO"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" missing-remote-ref
  assert_grep "cannot confidently resolve origin's source-backed default branch" "$RUN_ERR" \
    "missing-remote-ref refusal was not actionable"
  pass "missing authoritative remote default ref refuses without ref mutation"
}

test_fetch_failure_refuses() {
  local fakebin real_git
  new_divergent_fixture fetch-failure
  fakebin="$CASE_ROOT/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = fetch ]; then
    printf 'simulated credential-bearing transport failure is intentionally hidden\n' >&2
    exit 19
  fi
done
exec "${REAL_GIT_FOR_TEST:?}" "$@"
SH
  chmod +x "$fakebin/git"

  run_helper "$REPO" env PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$real_git"
  assert_refused_without_move "$REPO" "$LOCAL_OLD" fetch-failure
  assert_grep "source-only fetch from origin failed" "$RUN_ERR" "fetch failure was not actionable"
  assert_no_grep "credential-bearing" "$RUN_ERR" "fetch diagnostic exposed transport details"
  pass "fetch failure refuses without mutation or credential-bearing diagnostics"
}

test_source_advancement_is_bounded() {
  local fakebin real_git tree next parent sequence counter i
  new_divergent_fixture advancing-source
  fakebin="$CASE_ROOT/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  tree=$(git --git-dir="$REMOTE" rev-parse "$REMOTE_NEW^{tree}")
  sequence="$CASE_ROOT/advance-sequence"
  : > "$sequence"
  parent=$REMOTE_NEW
  i=1
  while [ "$i" -le 3 ]; do
    next=$(printf 'remote advance %s\n' "$i" | git --git-dir="$REMOTE" commit-tree "$tree" -p "$parent")
    printf '%s\n' "$next" >> "$sequence"
    parent=$next
    i=$((i + 1))
  done
  counter="$CASE_ROOT/fetch-count"
  printf '0\n' > "$counter"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
is_fetch=0
for arg in "$@"; do [ "$arg" = fetch ] && is_fetch=1; done
if [ "$is_fetch" -eq 1 ]; then
  "${REAL_GIT_FOR_TEST:?}" "$@" || exit $?
  n=$(cat "${ADVANCE_COUNTER:?}")
  n=$((n + 1))
  printf '%s\n' "$n" > "$ADVANCE_COUNTER"
  next=$(sed -n "${n}p" "${ADVANCE_SEQUENCE:?}")
  [ -n "$next" ] || exit 97
  "${REAL_GIT_FOR_TEST:?}" --git-dir="${ADVANCE_REMOTE:?}" \
    update-ref refs/heads/main "$next"
  exit 0
fi
exec "${REAL_GIT_FOR_TEST:?}" "$@"
SH
  chmod +x "$fakebin/git"

  run_helper "$REPO" env PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$real_git" \
    ADVANCE_COUNTER="$counter" ADVANCE_SEQUENCE="$sequence" ADVANCE_REMOTE="$REMOTE"

  assert_refused_without_move "$REPO" "$LOCAL_OLD" advancing-source
  [ "$(cat "$counter")" -eq 3 ] || fail "advancing source was not bounded to three fetch attempts"
  assert_grep "advanced beyond the fetched object in 3 attempts" "$RUN_ERR" \
    "bounded source-advance refusal was not actionable"
  pass "source advancement retries to a fixed bound and then refuses"
}

test_expected_old_race_is_atomic() {
  local fakebin real_git race_oid
  new_divergent_fixture expected-old-race
  fakebin="$CASE_ROOT/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  race_oid=$(commit_same_tree_child "$REPO" "$LOCAL_OLD" external-claimant)
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
is_update=0
for arg in "$@"; do [ "$arg" = update-ref ] && is_update=1; done
if [ "$is_update" -eq 1 ] && [ "${RACE_INNER:-0}" != 1 ]; then
  RACE_INNER=1 "${REAL_GIT_FOR_TEST:?}" -C "${RACE_REPO:?}" \
    update-ref refs/heads/main "${RACE_OID:?}" "${RACE_OLD:?}" || exit $?
fi
exec "${REAL_GIT_FOR_TEST:?}" "$@"
SH
  chmod +x "$fakebin/git"

  run_helper "$REPO" env PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$real_git" \
    RACE_REPO="$REPO" RACE_OID="$race_oid" RACE_OLD="$LOCAL_OLD"

  [ "$RUN_RC" -ne 0 ] || fail "expected-old race: expected refusal"
  [ "$(git -C "$REPO" rev-parse refs/heads/main)" = "$race_oid" ] \
    || fail "expected-old race overwrote the external claimant"
  [ "$(git -C "$REPO" rev-parse refs/heads/main)" != "$REMOTE_NEW" ] \
    || fail "expected-old race moved the branch to the remote target"
  assert_no_preservation_namespace "$REPO" "expected-old race"
  assert_grep "atomic ref transaction was rejected" "$RUN_ERR" \
    "expected-old race refusal was not actionable"
  pass "expected-old race commits neither branch movement nor preservation ref"
}

test_symbolic_branch_race_is_atomic() {
  local fakebin real_git claimant_ref
  new_divergent_fixture symbolic-branch-race
  fakebin="$CASE_ROOT/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  claimant_ref=refs/heads/direct-claimant
  git -C "$REPO" update-ref "$claimant_ref" "$LOCAL_OLD"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
is_update=0
for arg in "$@"; do [ "$arg" = update-ref ] && is_update=1; done
if [ "$is_update" -eq 1 ] && [ "${RACE_INNER:-0}" != 1 ]; then
  RACE_INNER=1 "${REAL_GIT_FOR_TEST:?}" -C "${RACE_REPO:?}" \
    symbolic-ref refs/heads/main "${RACE_CLAIMANT_REF:?}" || exit $?
fi
exec "${REAL_GIT_FOR_TEST:?}" "$@"
SH
  chmod +x "$fakebin/git"

  run_helper "$REPO" env PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$real_git" \
    RACE_REPO="$REPO" RACE_CLAIMANT_REF="$claimant_ref"

  expect_code 0 "$RUN_RC" "symbolic branch race"
  assert_direct_ref "$REPO" refs/heads/main "$REMOTE_NEW" "symbolic branch race branch"
  assert_direct_ref "$REPO" "$claimant_ref" "$LOCAL_OLD" "symbolic branch race claimant"
  assert_direct_ref "$REPO" "$PRESERVE_REF" "$LOCAL_OLD" "symbolic branch race preservation"
  pass "symbolic branch race cannot write through to its claimant"
}

test_post_commit_claimant_is_never_rolled_back() {
  local fakebin real_git claimant
  new_divergent_fixture post-commit-claimant
  fakebin="$CASE_ROOT/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  claimant=$(commit_same_tree_child "$REPO" "$LOCAL_OLD" post-commit-claimant)
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
is_update=0
for arg in "$@"; do [ "$arg" = update-ref ] && is_update=1; done
if [ "$is_update" -eq 1 ] && [ "${POST_INNER:-0}" != 1 ]; then
  "${REAL_GIT_FOR_TEST:?}" "$@" || exit $?
  POST_INNER=1 "${REAL_GIT_FOR_TEST:?}" -C "${POST_REPO:?}" \
    update-ref refs/heads/main "${POST_CLAIMANT:?}" "${POST_REMOTE:?}" || exit $?
  exit 0
fi
exec "${REAL_GIT_FOR_TEST:?}" "$@"
SH
  chmod +x "$fakebin/git"

  run_helper "$REPO" env PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$real_git" \
    POST_REPO="$REPO" POST_CLAIMANT="$claimant" POST_REMOTE="$REMOTE_NEW"

  [ "$RUN_RC" -ne 0 ] || fail "post-commit claimant: expected evidence-change failure"
  [ "$(git -C "$REPO" rev-parse refs/heads/main)" = "$claimant" ] \
    || fail "post-commit claimant was rolled back or overwritten"
  assert_direct_ref "$REPO" "$PRESERVE_REF" "$LOCAL_OLD" "post-commit preservation"
  assert_grep "committed: moved refs/heads/main from $LOCAL_OLD to $REMOTE_NEW" "$RUN_OUT" \
    "post-commit change did not retain committed outcome"
  assert_grep "committed outcome: refs/heads/main moved from $LOCAL_OLD to $REMOTE_NEW" "$RUN_ERR" \
    "post-commit diagnostic omitted exact committed state"
  assert_grep "current branch ref is $claimant" "$RUN_ERR" \
    "post-commit diagnostic omitted the new claimant"
  assert_grep "no rollback was attempted" "$RUN_ERR" \
    "post-commit diagnostic did not state the no-rollback boundary"
  pass "post-commit claimant is reported with exact evidence and never rolled back"
}

test_non_repository_refuses() {
  new_case_root non-repository
  REPO="$CASE_ROOT/not-a-repo"
  mkdir -p "$REPO"
  run_helper_plain "$REPO"
  [ "$RUN_RC" -ne 0 ] || fail "non-repository: expected refusal"
  assert_grep "not an existing Git worktree" "$RUN_ERR" "non-repository refusal was not actionable"
  pass "non-repository target refuses"
}

test_divergent_identical_succeeds_and_repeats
test_submodules_are_not_fetched
test_configured_pruning_is_suppressed
test_ambient_git_overrides_refuse
test_virtual_or_incomplete_history_refuses
test_dirty_refuses
test_detached_refuses
test_off_default_refuses
test_active_operation_refuses
test_multiple_worktrees_refuse
test_symbolic_local_ref_refuses
test_symbolic_remote_tracking_ref_refuses
test_existing_exact_preservation_ref_is_reused
test_conflicting_preservation_ref_refuses
test_symbolic_preservation_ref_refuses
test_fast_forward_refuses
test_ahead_only_refuses
test_unequal_tree_refuses
test_unrelated_identical_tree_refuses
test_ambiguous_merge_base_refuses
test_missing_remote_ref_refuses
test_fetch_failure_refuses
test_source_advancement_is_bounded
test_expected_old_race_is_atomic
test_symbolic_branch_race_is_atomic
test_post_commit_claimant_is_never_rolled_back
test_non_repository_refuses
