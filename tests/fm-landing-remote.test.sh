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
  # A second local branch tracking origin, named neither main nor master: the
  # fleet already runs projects whose default branch is something else, and
  # every branch that tracked origin must still track origin after the remap.
  git -C "$clone" branch --quiet --track trunk origin/main
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

# The gh stub records its default the way gh itself does, in the local
# `remote.<name>.gh-resolved` git config, because apply reads that key to decide
# whether the gh default is already in place without going near the network.
install_careless_stubs() {
  local fakebin=$1 log=$2
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
case "\$1 \$2 \${3:-}" in
  "repo set-default origin"|"repo set-default origin ")
    git config remote.origin.gh-resolved base
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
  local rec dir ours parent clone fakebin log origin out rc branch_head local_main worker tracked_branch
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

  # `git remote rename origin upstream` repoints every branch that tracked
  # origin at the parent, so a plain `git pull` on them would pull upstream in.
  for tracked_branch in main trunk; do
    [ "$(git -C "$clone" config --get "branch.${tracked_branch}.remote")" = origin ] \
      || fail "branch $tracked_branch now pulls from $(git -C "$clone" config --get "branch.${tracked_branch}.remote"), not origin"
  done

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

  # Every network step belongs behind a decision to change something. Once the
  # checkout is already correct, apply must succeed with the landing remote
  # gone AND with gh and no-mistakes both broken, because it must not call
  # them at all. Stubs that exit 0 would satisfy a weaker assertion no matter
  # what the real commands did.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh must not run on a no-op apply" >&2
exit 1
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
echo "no-mistakes must not run on a no-op apply" >&2
exit 1
SH
  chmod +x "$fakebin/no-mistakes"
  mv "$ours" "$ours.away"
  PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$ours" \
    --upstream "file://$parent" \
    --repo "$clone" > "$dir/apply3.out" 2>"$dir/apply3.err"
  rc=$?
  mv "$ours.away" "$ours"
  expect_code 0 "$rc" "apply should stay an offline no-op once the checkout is already correct (got: $(cat "$dir/apply3.err"))"
  [ ! -s "$dir/apply3.err" ] \
    || fail "the no-op apply reached gh or no-mistakes: $(cat "$dir/apply3.err")"

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
  # This path removes the leftover `fork` remote, and `git remote remove` deletes
  # branch.<name>.remote and branch.<name>.merge for every branch that tracked
  # it. fork names our tree, so such a branch must come out tracking origin, not
  # with no upstream at all.
  git -C "$clone" branch --quiet --track fork-tracked fork/main
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
  [ "$(git -C "$clone" config --get branch.fork-tracked.remote || true)" = origin ] \
    || fail "the fork-tracking branch lost its upstream, so git pull on it now errors"
  [ "$(git -C "$clone" config --get branch.fork-tracked.merge || true)" = refs/heads/main ] \
    || fail "the fork-tracking branch lost the branch it merges from"

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

# An unreachable or mistyped --ours must refuse before anything is written.
# When it refused after the rewrite, origin held the unreachable URL while its
# tracking refs still held the parent's tips, verify (which compares only the
# URL) called that correctly configured, and the corrected re-run hit "neither
# --ours nor --upstream; refusing to guess" and could no longer converge.
test_failed_preflight_leaves_the_remote_unchanged_and_re_appliable() {
  local rec dir ours parent clone fakebin log out rc
  local before_origin before_upstream parent_main
  rec=$(make_fork_fixture unreachable-origin)
  IFS='|' read -r dir ours parent clone <<EOF
$rec
EOF
  git -C "$clone" remote add upstream "file://$parent"
  git -C "$clone" fetch --quiet upstream
  git -C "$clone" remote remove fork
  before_origin=$(git -C "$clone" remote get-url origin)
  before_upstream=$(git -C "$clone" remote get-url upstream)
  parent_main=$(git -C "$clone" rev-parse refs/remotes/origin/main)
  fakebin=$(fm_fakebin "$dir/fake")
  log="$dir/stub.log"
  : > "$log"
  install_careless_stubs "$fakebin" "$log"

  set +e
  out=$(PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$dir/does-not-exist.git" \
    --upstream "file://$parent" \
    --repo "$clone" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "apply reported success with an unreachable landing remote"
  assert_contains "$out" "nothing was changed" \
    "apply did not tell the operator the checkout was left untouched"
  [ "$(git -C "$clone" remote get-url origin)" = "$before_origin" ] \
    || fail "refused apply still rewrote origin to the unreachable URL"
  [ "$(git -C "$clone" remote get-url upstream)" = "$before_upstream" ] \
    || fail "refused apply still rewrote upstream"
  [ "$(git -C "$clone" rev-parse refs/remotes/origin/main)" = "$parent_main" ] \
    || fail "refused apply moved origin's tracking refs"
  [ -z "$(git -C "$clone" config --get checkout.defaultRemote || true)" ] \
    || fail "refused apply still set checkout.defaultRemote"
  if grep -q 'repo set-default' "$log"; then
    fail "refused apply still pointed gh at origin"
  fi

  # The point of leaving it unchanged: the corrected run still converges.
  PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$ours" \
    --upstream "file://$parent" \
    --repo "$clone" > "$dir/apply2.out" 2>"$dir/apply2.err"
  rc=$?
  expect_code 0 "$rc" "the corrected re-run should apply cleanly after a refused apply"
  [ "$(git -C "$clone" remote get-url origin)" = "file://$ours" ] \
    || fail "the corrected re-run did not land origin on the landing remote"
  [ "$(git -C "$clone" rev-parse refs/remotes/origin/main)" != "$parent_main" ] \
    || fail "the corrected re-run left origin's tracking refs on the parent tip"
  pass "a refused apply leaves the remotes unchanged and the corrected re-run still applies"
}

# gh ranks upstream above origin when no default repo is recorded, so an apply
# that could not set the gh default has not made a flagless gh pr create land on
# ours. Exiting 0 over that is the defect this change exists to remove.
test_apply_fails_when_the_gh_default_cannot_be_set() {
  local rec dir ours parent clone fakebin log out rc
  local before_origin before_fork before_track
  rec=$(make_fork_fixture gh-default-fails)
  IFS='|' read -r dir ours parent clone <<EOF
$rec
EOF
  before_origin=$(git -C "$clone" remote get-url origin)
  before_fork=$(git -C "$clone" remote get-url fork)
  before_track=$(git -C "$clone" config --get branch.main.remote)
  fakebin=$(fm_fakebin "$dir/fake")
  log="$dir/stub.log"
  : > "$log"
  install_careless_stubs "$fakebin" "$log"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
case "\$1 \$2" in
  "repo set-default") exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"

  set +e
  out=$(PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$ours" \
    --upstream "file://$parent" \
    --repo "$clone" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "apply reported success while gh had no default repository"
  assert_contains "$out" "gh pr create" \
    "apply did not name the consequence a missing gh default has"
  assert_contains "$out" "third-party parent" \
    "apply did not say where a flagless PR would still land"

  # A half-applied checkout would let the next apply take the already-correct
  # path and no-op straight over the missing gh default, so the failed apply
  # puts everything back and the retry redoes the whole thing.
  [ "$(git -C "$clone" remote get-url origin)" = "$before_origin" ] \
    || fail "the failed apply left origin remapped, so a retry would no-op over the missing gh default"
  [ "$(git -C "$clone" remote get-url fork)" = "$before_fork" ] \
    || fail "the failed apply did not put the fork remote back"
  if git -C "$clone" remote get-url upstream >/dev/null 2>&1; then
    fail "the failed apply left the upstream remote it added"
  fi
  [ "$(git -C "$clone" config --get branch.main.remote)" = "$before_track" ] \
    || fail "the failed apply left main's tracking remote rewritten"
  [ -z "$(git -C "$clone" config --get checkout.defaultRemote || true)" ] \
    || fail "the failed apply left checkout.defaultRemote behind"

  install_careless_stubs "$fakebin" "$log"
  PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$ours" \
    --upstream "file://$parent" \
    --repo "$clone" > "$dir/retry.out" 2>"$dir/retry.err"
  rc=$?
  expect_code 0 "$rc" "the retry should apply cleanly once gh can record the default"
  [ "$(git -C "$clone" remote get-url origin)" = "file://$ours" ] \
    || fail "the retry did not land origin on the landing remote"
  pass "apply fails when the gh default cannot be set, restores the checkout, and names the consequence"
}

# origin already names ours but the parent has no `upstream` name yet and the
# leftover `fork` is still there. That is not a no-op, so apply finishes the job
# rather than reporting a checkout that is only half arranged.
test_apply_completes_a_partly_arranged_checkout() {
  local rec dir ours parent clone fakebin log rc
  rec=$(make_fork_fixture partly-arranged)
  IFS='|' read -r dir ours parent clone <<EOF
$rec
EOF
  git -C "$clone" remote set-url origin "file://$ours"
  git -C "$clone" fetch --quiet --prune origin
  git -C "$clone" branch --quiet --track fork-tracked fork/main
  fakebin=$(fm_fakebin "$dir/fake")
  log="$dir/stub.log"
  : > "$log"
  install_careless_stubs "$fakebin" "$log"

  PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$ours" \
    --upstream "file://$parent" \
    --repo "$clone" > "$dir/apply.out" 2>"$dir/apply.err"
  rc=$?
  expect_code 0 "$rc" "apply should finish a partly arranged checkout (got: $(cat "$dir/apply.err"))"
  [ "$(git -C "$clone" remote get-url upstream)" = "file://$parent" ] \
    || fail "apply did not name the parent upstream"
  if git -C "$clone" remote get-url fork >/dev/null 2>&1; then
    fail "apply left the leftover fork remote behind"
  fi
  [ "$(git -C "$clone" config --get branch.fork-tracked.remote || true)" = origin \
    ] || fail "removing the leftover fork remote left its branch with no upstream"
  [ "$(git -C "$clone" config --get checkout.defaultRemote)" = origin ] \
    || fail "apply did not set checkout.defaultRemote"
  assert_grep "repo set-default origin" "$log" \
    "apply did not record the gh default while both remotes were present"
  pass "apply completes a partly arranged checkout instead of calling it already correct"
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

# Make chosen git invocations fail inside apply and let every other one through.
# The remap is a pair of renames, so a fixture whose every command succeeds
# cannot show what the primary checkout looks like when the second one dies.
install_failing_git_stub() {  # <fakebin> <failfile> <pattern>...
  local fakebin=$1 failfile=$2 real
  shift 2
  real=$(command -v git)
  printf '%s\n' "$@" > "$failfile"
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
args="\$*"
while IFS= read -r pat; do
  [ -n "\$pat" ] || continue
  case "\$args" in
    *"\$pat"*) exit 1 ;;
  esac
done < '$failfile'
exec '$real' "\$@"
SH
  chmod +x "$fakebin/git"
}

# The mutating remap is two renames on one checkout. If the second one dies the
# primary is left with no `origin` at all, which strands git, gh, and
# no-mistakes and makes every retry refuse at the missing remote. apply must put
# the checkout back instead.
test_a_dead_rename_mid_remap_restores_the_checkout() {
  local rec dir ours parent clone fakebin log out rc
  rec=$(make_fork_fixture dead-rename)
  IFS='|' read -r dir ours parent clone <<EOF
$rec
EOF
  fakebin=$(fm_fakebin "$dir/fake")
  log="$dir/stub.log"
  : > "$log"
  install_careless_stubs "$fakebin" "$log"
  install_failing_git_stub "$fakebin" "$dir/git-fail" "remote rename fork origin"

  set +e
  out=$(PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$ours" \
    --upstream "file://$parent" \
    --repo "$clone" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "apply reported success after the second rename died"
  [ "$(git -C "$clone" remote get-url origin 2>&1)" = "file://$parent" ] \
    || fail "the dead remap left origin as '$(git -C "$clone" remote get-url origin 2>&1)', not the parent it started as"
  [ "$(git -C "$clone" remote get-url fork 2>&1)" = "file://$ours" ] \
    || fail "the dead remap did not leave the fork remote naming ours"
  if git -C "$clone" remote get-url upstream >/dev/null 2>&1; then
    fail "the dead remap left the upstream name it created"
  fi
  [ "$(git -C "$clone" config --get branch.trunk.remote || true)" = origin ] \
    || fail "the dead remap left trunk tracking a remote that no longer exists"
  [ -z "$(git -C "$clone" config --get checkout.defaultRemote || true)" ] \
    || fail "the dead remap left checkout.defaultRemote behind"
  assert_contains "$out" "checkout was restored" \
    "apply did not say the checkout was put back"

  install_careless_stubs "$fakebin" "$log"
  rm -f "$fakebin/git"
  PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$ours" \
    --upstream "file://$parent" \
    --repo "$clone" > "$dir/retry.out" 2>"$dir/retry.err"
  rc=$?
  expect_code 0 "$rc" "the retry should apply cleanly once the rename can succeed (got: $(cat "$dir/retry.err"))"
  [ "$(git -C "$clone" remote get-url origin)" = "file://$ours" ] \
    || fail "the retry did not land origin on the landing remote"
  pass "a rename that dies mid-remap restores the checkout and the retry still applies"
}

# When the restore itself cannot run, the operator has to know the remotes need
# hand repair. A message promising a restored, re-appliable checkout would send
# them straight back into an apply that refuses at the missing origin.
test_a_failed_restore_is_reported_as_needing_hand_repair() {
  local rec dir ours parent clone fakebin log out rc
  rec=$(make_fork_fixture dead-restore)
  IFS='|' read -r dir ours parent clone <<EOF
$rec
EOF
  fakebin=$(fm_fakebin "$dir/fake")
  log="$dir/stub.log"
  : > "$log"
  install_careless_stubs "$fakebin" "$log"
  install_failing_git_stub "$fakebin" "$dir/git-fail" \
    "remote rename fork origin" "remote rename upstream origin"

  set +e
  out=$(PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$ours" \
    --upstream "file://$parent" \
    --repo "$clone" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "apply reported success after both the remap and the restore died"
  assert_contains "$out" "NOT restored" \
    "apply claimed a restored checkout after the restore itself failed"
  assert_contains "$out" "repair them by hand" \
    "apply did not tell the operator to repair the remotes by hand"
  pass "a failed restore is reported as needing hand repair, not as a restored checkout"
}

# `gh repo set-default --view` prints whatever repository gh recorded, so a zero
# exit and a non-empty name prove nothing about which repository that is. Only
# `remote.origin.gh-resolved = base` means gh sends a flagless `gh pr create` to
# origin.
test_apply_fails_when_gh_records_a_different_default() {
  local rec dir ours parent clone fakebin log out rc
  rec=$(make_fork_fixture gh-wrong-default)
  IFS='|' read -r dir ours parent clone <<EOF
$rec
EOF
  fakebin=$(fm_fakebin "$dir/fake")
  log="$dir/stub.log"
  : > "$log"
  install_careless_stubs "$fakebin" "$log"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
case "\$1 \$2 \${3:-}" in
  "repo set-default origin"|"repo set-default origin ")
    git config remote.origin.gh-resolved third-party/firstmate
    exit 0
    ;;
  "repo set-default --view"|"repo set-default --view ")
    printf 'third-party/firstmate\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"

  set +e
  out=$(PATH="$fakebin:$PATH" "$LANDING" apply \
    --ours "file://$ours" \
    --upstream "file://$parent" \
    --repo "$clone" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "apply reported success while gh's default was a repository other than origin"
  assert_contains "$out" "gh pr create" \
    "apply did not name the consequence a wrong gh default has"
  [ "$(git -C "$clone" remote get-url origin)" = "file://$parent" ] \
    || fail "the failed apply left origin remapped despite gh's wrong default"
  pass "apply fails when gh records a default repository that is not origin"
}

test_careless_path_without_apply_names_parent
test_apply_makes_careless_branch_and_default_repo_land_on_ours
test_apply_with_existing_upstream_refreshes_tracking_refs
test_failed_preflight_leaves_the_remote_unchanged_and_re_appliable
test_apply_fails_when_the_gh_default_cannot_be_set
test_apply_completes_a_partly_arranged_checkout
test_apply_refuses_a_linked_worktree
test_apply_refuses_an_unrelated_origin
test_a_dead_rename_mid_remap_restores_the_checkout
test_a_failed_restore_is_reported_as_needing_hand_repair
test_apply_fails_when_gh_records_a_different_default

echo "# all fm-landing-remote tests passed"
