#!/usr/bin/env bash
# Behavior tests for bin/fm-landing-remote.sh.
#
# When origin names a third-party parent and a fork remote names our tree,
# git checkout -b and gh pr create both default to the parent. These tests
# drive the real helper against fixture remotes, then take the careless
# branch and default-repo path with no extra flags, and require both to
# resolve to ours. A failure names the remote that would actually receive
# the work.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LANDING="$ROOT/bin/fm-landing-remote.sh"
TMP_ROOT=$(fm_test_tmproot fm-landing-remote)
fm_git_identity

make_fork_fixture() {
  local name=$1 dir ours parent clone
  dir="$TMP_ROOT/$name"
  ours="$dir/ours.git"
  parent="$dir/parent.git"
  clone="$dir/clone"
  mkdir -p "$dir"

  fm_git_init_commit "$dir/seed"
  git -C "$dir/seed" branch -M main
  git clone --quiet --bare "$dir/seed" "$parent"
  git clone --quiet --bare "$dir/seed" "$ours"
  git clone --quiet "file://$parent" "$clone"
  git -C "$clone" remote add fork "file://$ours"
  git -C "$clone" fetch --quiet fork

  # Local main is ahead of the parent and published on ours (the fleet's
  # authoritative tree), so the two remotes disagree about what main is.
  printf 'local-authoritative\n' > "$clone/local.txt"
  git -C "$clone" add local.txt
  git -C "$clone" commit -qm 'local main is authoritative'
  git -C "$clone" push --quiet fork main
  git -C "$clone" fetch --quiet fork

  # The parent diverges with a commit that must never land in our tree.
  git clone --quiet "$parent" "$dir/parent-pub"
  printf 'third-party-only\n' > "$dir/parent-pub/upstream.txt"
  git -C "$dir/parent-pub" add upstream.txt
  git -C "$dir/parent-pub" commit -qm 'unreviewed parent commit'
  git -C "$dir/parent-pub" push --quiet origin main

  git -C "$clone" fetch --quiet origin
  printf '%s\n' "$dir|$ours|$parent|$clone"
}

# Reproduce the state a worker actually starts in: bin/fm-spawn.sh fetches
# origin and leaves the task worktree at a detached HEAD on origin's tip. The
# careless `git checkout -b` then inherits whichever repository origin names,
# which is the defect this helper exists to expose.
spawn_like_worktree() {  # <clone> <path>
  local clone=$1 path=$2 default
  git -C "$clone" fetch --quiet origin
  git -C "$clone" remote set-head origin --auto >/dev/null 2>&1 || true
  default=$(git -C "$clone" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) \
    || default=origin/main
  git -C "$clone" worktree add --quiet --detach "$path" "$default"
  printf '%s\n' "$default"
}

install_careless_stubs() {
  local fakebin=$1 log=$2
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
case "\$1 \$2 \${3:-}" in
  "repo set-default origin"|"repo set-default origin ")
    exit 0
    ;;
  "repo set-default --view"|"repo set-default --view ")
    printf 'file://landing-ours\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

test_careless_path_without_apply_names_parent() {
  local rec dir ours parent clone origin worker
  rec=$(make_fork_fixture without-apply)
  IFS='|' read -r dir ours parent clone <<EOF
$rec
EOF
  origin=$(git -C "$clone" remote get-url origin)
  case $origin in
    *parent.git*) ;;
    *) fail "fixture origin was not the parent: $origin" ;;
  esac

  # Red-before baseline for test_apply_makes_careless_branch_and_default_repo_land_on_ours:
  # with origin still naming the parent, the careless branch carries the
  # unreviewed parent commit and none of our tree.
  worker="$dir/worker"
  spawn_like_worktree "$clone" "$worker" >/dev/null
  ( cd "$worker" && git checkout -b fm/careless >/dev/null 2>&1 )
  [ -e "$worker/upstream.txt" ] \
    || fail "un-remapped careless branch did not carry the parent's unreviewed commit"
  [ ! -e "$worker/local.txt" ] \
    || fail "un-remapped careless branch already carried our tree, so the fixture proves nothing"

  if "$LANDING" verify --ours "file://$ours" --repo "$clone" >/dev/null 2>"$dir/verify.err"; then
    fail "verify succeeded while origin still named the parent"
  fi
  assert_grep "not the landing remote" "$dir/verify.err" \
    "verify did not name the wrong remote while origin still pointed at the parent"
  assert_contains "$(cat "$dir/verify.err")" "$origin" \
    "verify did not name the parent origin URL that would receive the work"
  pass "without apply, the careless path still names the parent remote"
}

test_apply_makes_careless_branch_and_default_repo_land_on_ours() {
  local rec dir ours parent clone fakebin log origin out rc branch_head local_main worker
  rec=$(make_fork_fixture with-apply)
  IFS='|' read -r dir ours parent clone <<EOF
$rec
EOF
  fakebin=$(fm_fakebin "$dir/fake")
  log="$dir/stub.log"
  : > "$log"
  install_careless_stubs "$fakebin" "$log"

  PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$ours" \
    --upstream "file://$parent" \
    --repo "$clone" > "$dir/apply.out" 2>"$dir/apply.err"
  rc=$?
  expect_code 0 "$rc" "apply should remap origin onto the landing remote"

  origin=$(git -C "$clone" remote get-url origin)
  [ "$origin" = "file://$ours" ] \
    || fail "careless origin is $origin, not the landing remote file://$ours"
  [ "$(git -C "$clone" remote get-url upstream)" = "file://$parent" ] \
    || fail "parent was not preserved as upstream"
  if git -C "$clone" remote get-url fork >/dev/null 2>&1; then
    fail "leftover fork remote still exists after apply"
  fi

  # Careless branch creation from the worker's real starting state: a detached
  # worktree on origin's tip, then `git checkout -b` with no start-point and no
  # remote flags. Which repository origin names decides the whole outcome.
  worker="$dir/worker"
  spawn_like_worktree "$clone" "$worker" >/dev/null
  ( cd "$worker" && git checkout -b fm/careless >/dev/null 2>&1 )
  branch_head=$(git -C "$worker" rev-parse HEAD)
  local_main=$(git -C "$clone" rev-parse refs/heads/main)
  [ "$branch_head" = "$local_main" ] \
    || fail "careless git checkout -b started from $branch_head, not our main $local_main"
  assert_grep 'local-authoritative' "$worker/local.txt" \
    "careless branch omitted our authoritative tree"
  [ ! -e "$worker/upstream.txt" ] \
    || fail "careless branch imported the unreviewed parent tree"

  assert_grep "repo set-default origin" "$log" \
    "apply did not point gh at origin, so gh pr create would still default elsewhere"
  assert_grep "--yes init" "$log" \
    "apply did not re-init no-mistakes without --fork-url"
  if grep -q 'fork-url' "$log"; then
    fail "no-mistakes init still passed --fork-url, so PRs would open on the parent"
  fi

  PATH="$fakebin:$PATH" "$LANDING" verify --ours "file://$ours" --repo "$clone" \
    > "$dir/verify.out" 2>"$dir/verify.err"
  rc=$?
  expect_code 0 "$rc" "verify should accept origin after apply"

  PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$ours" \
    --upstream "file://$parent" \
    --repo "$clone" > "$dir/apply2.out" 2>"$dir/apply2.err"
  rc=$?
  expect_code 0 "$rc" "apply should be idempotent once origin already lands on ours"
  [ "$(git -C "$clone" remote get-url origin)" = "file://$ours" ] \
    || fail "idempotent apply moved origin off the landing remote"

  pass "apply makes careless branch creation and default-repo targeting land on ours"
}

test_apply_refuses_a_linked_worktree() {
  local rec dir ours parent clone wt target out rc
  rec=$(make_fork_fixture worktree-refuse)
  IFS='|' read -r dir ours parent clone <<EOF
$rec
EOF
  git -C "$clone" worktree add --quiet --detach "$dir/wt"
  wt="$dir/wt"
  mkdir -p "$wt/sub/deeper"
  # The worktree top level and any depth below it share the primary's remotes,
  # so both must be refused. A guard that only looks for a `.git` file sees
  # nothing at the subdirectory and rewrites the fleet's remotes from there.
  for target in "$wt" "$wt/sub" "$wt/sub/deeper"; do
    set +e
    out=$("$LANDING" apply --ours "file://$ours" --upstream "file://$parent" --repo "$target" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "apply succeeded from linked worktree path $target"
    assert_contains "$out" "linked worktree" \
      "apply did not refuse to rewrite remotes from linked worktree path $target"
    [ "$(git -C "$clone" remote get-url origin)" = "file://$parent" ] \
      || fail "refused apply from $target still rewrote the shared remotes"
  done
  pass "apply refuses to rewrite remotes from a linked worktree at any depth"
}

# The remap branch taken when `upstream` already names the parent only changed
# origin's URL. Without a refetch, refs/remotes/origin/* still held the parent's
# tips, so the careless path kept resolving origin/main to the parent even
# though origin claimed to be ours.
test_apply_with_existing_upstream_refreshes_tracking_refs() {
  local rec dir ours parent clone fakebin log rc origin_main local_main parent_main worker
  rec=$(make_fork_fixture existing-upstream)
  IFS='|' read -r dir ours parent clone <<EOF
$rec
EOF
  git -C "$clone" remote add upstream "file://$parent"
  git -C "$clone" fetch --quiet upstream
  fakebin=$(fm_fakebin "$dir/fake")
  log="$dir/stub.log"
  : > "$log"
  install_careless_stubs "$fakebin" "$log"

  PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$ours" \
    --upstream "file://$parent" \
    --repo "$clone" > "$dir/apply.out" 2>"$dir/apply.err"
  rc=$?
  expect_code 0 "$rc" "apply should remap origin when upstream already names the parent"
  [ "$(git -C "$clone" remote get-url origin)" = "file://$ours" ] \
    || fail "origin was not remapped onto the landing remote"

  origin_main=$(git -C "$clone" rev-parse refs/remotes/origin/main)
  local_main=$(git -C "$clone" rev-parse refs/heads/main)
  parent_main=$(git -C "$clone" rev-parse refs/remotes/upstream/main)
  [ "$origin_main" != "$parent_main" ] \
    || fail "origin/main still resolves to the parent tip $parent_main after apply"
  [ "$origin_main" = "$local_main" ] \
    || fail "origin/main is $origin_main, not our published main $local_main"

  worker="$dir/worker"
  spawn_like_worktree "$clone" "$worker" >/dev/null
  ( cd "$worker" && git checkout -b fm/careless >/dev/null 2>&1 )
  [ ! -e "$worker/upstream.txt" ] \
    || fail "careless branch still imported the unreviewed parent tree after apply"
  assert_grep 'local-authoritative' "$worker/local.txt" \
    "careless branch omitted our authoritative tree after apply"
  pass "apply refetches origin so tracking refs stop naming the parent"
}

test_apply_refuses_an_unrelated_origin() {
  local rec dir ours parent clone out rc
  rec=$(make_fork_fixture unrelated-origin)
  IFS='|' read -r dir ours parent clone <<EOF
$rec
EOF
  git -C "$clone" remote set-url origin "file://$dir/somewhere-else.git"
  set +e
  out=$("$LANDING" apply --ours "file://$ours" --upstream "file://$parent" --repo "$clone" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "apply rewrote an origin that was neither ours nor upstream"
  assert_contains "$out" "refusing to guess" \
    "apply did not refuse an unrelated origin"
  pass "apply refuses an origin that is neither ours nor the named parent"
}

test_careless_path_without_apply_names_parent
test_apply_makes_careless_branch_and_default_repo_land_on_ours
test_apply_with_existing_upstream_refreshes_tracking_refs
test_apply_refuses_a_linked_worktree
test_apply_refuses_an_unrelated_origin

echo "# all fm-landing-remote tests passed"
