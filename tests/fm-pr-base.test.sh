#!/usr/bin/env bash
# Behavior tests for pull-request base targeting.
#
# THE FAILURE THESE PIN
# Three firstmate pull requests in three days opened on the shared UPSTREAM
# instead of this fleet's fork, and the two that were re-raised on the fork
# arrived as 26-commit, 140-file diffs for six-commit changes. One root cause,
# two axes:
#
#   target repo - the process that opens the pull request does not run in the
#                 project checkout. The no-mistakes pipeline builds a worktree
#                 of a bare mirror whose only remote is the upstream, so it
#                 resolves the upstream and opens there.
#   base branch - the worktree pool resets every worktree to
#                 refs/remotes/origin/HEAD, the UPSTREAM default branch, so a
#                 branch cut there drags along every commit separating the two
#                 repositories.
#
# The happy path passed throughout all three incidents, so every case below is
# built from a WRONG starting state and asserts the wrong state is corrected or
# refused. The fixtures use a fictional owner ("acme") specifically so a fix
# that hardcoded this fleet's fork owner would fail them.
#
# Seams asserted (all caller-visible, none internal):
#   bin/fm-pr-check.sh   exit status + stderr + whether it recorded/armed anything
#   bin/fm-worktree-base.sh  the worktree's resulting HEAD
#   bin/fm-pr-base.sh    the gate mirror's resulting git configuration
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_BASE="$ROOT/bin/fm-pr-base.sh"
WT_BASE="$ROOT/bin/fm-worktree-base.sh"

TMP=$(fm_test_tmproot fm-pr-base)
fm_git_identity fmtest fmtest@example.invalid

UPSTREAM_URL=https://github.com/acme/widget
FORK_URL=https://github.com/acme-fleet/widget.git

# --- fixtures ---------------------------------------------------------------
#
# Reproduce the real topology: one repository with an upstream `origin` and a
# `fork` remote declared as the pull-request base via gh-resolved, whose two
# default branches have DIVERGED - the fork carries fleet commits the upstream
# lacks, and the upstream carries commits the fork lacks. That divergence is
# what turns a wrong branch point into a 26-commit pull request.

# make_fleet <root> -> echoes the checkout path.
# Leaves refs/remotes/origin/main and refs/remotes/fork/main diverged by 2 and 3
# commits respectively, and the checkout's HEAD detached on origin/main - exactly
# what the worktree pool hands a crewmate.
make_fleet() {
  local root=$1 seed="$1/seed" up="$1/upstream.git" fk="$1/fork.git" co="$1/checkout"
  mkdir -p "$root"
  git init -q --bare -b main "$up"
  git init -q --bare -b main "$fk"
  git init -q -b main "$seed"
  git -C "$seed" commit -q --allow-empty -m shared
  git -C "$seed" push -q "$up" main
  git -C "$seed" push -q "$fk" main
  # The fork gains this fleet's own commits.
  git -C "$seed" commit -q --allow-empty -m fleet-1
  git -C "$seed" commit -q --allow-empty -m fleet-2
  git -C "$seed" commit -q --allow-empty -m fleet-3
  git -C "$seed" push -q "$fk" main
  # The upstream moves on separately, so the two default branches diverge.
  git -C "$seed" reset -q --hard HEAD~3
  git -C "$seed" commit -q --allow-empty -m upstream-1
  git -C "$seed" commit -q --allow-empty -m upstream-2
  git -C "$seed" push -q "$up" main

  git clone -q "$up" "$co"
  git -C "$co" remote set-url origin "$UPSTREAM_URL"
  git -C "$co" remote add fork "$FORK_URL"
  # A real clone has origin's refs; give it the fork's without a network by
  # fetching the local bare repo under the fork remote's refspec.
  git -C "$co" fetch -q "$fk" '+refs/heads/*:refs/remotes/fork/*'
  git -C "$co" symbolic-ref refs/remotes/fork/HEAD refs/remotes/fork/main
  git -C "$co" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  # `gh repo set-default acme-fleet/widget`: the fleet ships to the fork.
  git -C "$co" config remote.fork.gh-resolved base
  git -C "$co" checkout -q --detach refs/remotes/origin/main
  printf '%s\n' "$co"
}

# make_gate <root> <checkout>: build the no-mistakes gate topology - a bare
# mirror whose ONLY remote is the upstream and which carries no base-repository
# record, registered on the checkout as the `no-mistakes` remote.
make_gate() {
  local root=$1 co=$2 gate="$1/gate.git"
  git init -q --bare "$gate"
  git -C "$gate" remote add origin "$UPSTREAM_URL"
  git -C "$co" remote add no-mistakes "$gate"
  printf '%s\n' "$gate"
}

# task_state <root> <id> <worktree>: minimal FM_HOME with a task meta pointing
# at <worktree>, which is what fm-pr-check reads the expectation from.
task_state() {
  local root=$1 id=$2 wt=$3 home="$1/home"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=widget" "harness=echo" "kind=crew" "mode=no-mistakes" "yolo=off"
  chmod 0600 "$home/state/$id.meta"
  printf '%s\n' "$home"
}

run_pr_check() {  # <home> <id> <url> -> sets OUT/CODE
  local home=$1 id=$2 url=$3
  set +e
  OUT=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PR_CHECK" "$id" "$url" 2>&1)
  CODE=$?
  set -e
}

# --- axis 1: a pull request opened on the wrong repository ------------------
#
# The regression case. The task's project ships to acme-fleet/widget; the
# pipeline opened the pull request on acme/widget, exactly as it did three times
# for real.

fleet=$(make_fleet "$TMP/a")
home=$(task_state "$TMP/a" wrongrepo "$fleet")
run_pr_check "$home" wrongrepo "https://github.com/acme/widget/pull/1218"

expect_code 1 "$CODE" "wrong-repository pull request must be refused"
assert_contains "$OUT" "acme/widget" "refusal names the wrong repository"
assert_contains "$OUT" "acme-fleet/widget" "refusal names the expected fork"
[ -f "$TMP/a/home/state/wrongrepo.check.sh" ] \
  && fail "wrong-repository pull request armed a watch"
assert_not_contains "$(cat "$TMP/a/home/state/wrongrepo.meta")" "pr=" \
  "wrong-repository pull request was recorded in the task's durable record"
pass "a pull request on the upstream is refused, names both repositories, and records nothing"

# The same refusal must not fire on the repository the project really ships to.
run_pr_check "$home" wrongrepo "https://github.com/acme-fleet/widget/pull/7"
assert_not_contains "$OUT" "close it and re-open it there" \
  "a pull request on the fork was refused as wrong-repository"
pass "a pull request on the fork clears the repository check"

# --- axis 2: a branch cut from the wrong default branch ---------------------
#
# Right repository, wrong branch point: the branch was cut from the upstream's
# default branch, so it carries the upstream's commits on top of its own work.
# This is the 26-commits-for-six-commits case.

fleet2=$(make_fleet "$TMP/b")
git -C "$fleet2" checkout -q -b fm/task refs/remotes/origin/main
git -C "$fleet2" commit -q --allow-empty -m "the actual change"
home2=$(task_state "$TMP/b" wrongbase "$fleet2")
run_pr_check "$home2" wrongbase "https://github.com/acme-fleet/widget/pull/15"

expect_code 1 "$CODE" "branch cut from the wrong default branch must be refused"
assert_contains "$OUT" "not this task's work" "refusal explains the extra commits"
assert_contains "$OUT" "acme/widget" "refusal names the repository the branch was cut from"
[ -f "$TMP/b/home/state/wrongbase.check.sh" ] \
  && fail "wrongly based pull request armed a watch"
pass "a branch cut from the upstream's default branch is refused with the commit count"

# Cut from the fork's default branch instead: same repository, same work, allowed.
fleet3=$(make_fleet "$TMP/c")
git -C "$fleet3" checkout -q -b fm/task refs/remotes/fork/main
git -C "$fleet3" commit -q --allow-empty -m "the actual change"
home3=$(task_state "$TMP/c" rightbase "$fleet3")
run_pr_check "$home3" rightbase "https://github.com/acme-fleet/widget/pull/16"
assert_not_contains "$OUT" "not this task's work" \
  "a correctly based branch was refused as wrongly based"
pass "the same work cut from the fork's default branch clears the base check"

# Cut from the fork's default branch and then DELIBERATELY merging the upstream
# in - how a fork ingests upstream - legitimately carries the upstream's commits.
# The discriminator is containment, so this must not be mistaken for a bad cut.
fleet3b=$(make_fleet "$TMP/c2")
git -C "$fleet3b" checkout -q -b fm/ingest refs/remotes/fork/main
git -C "$fleet3b" merge -q --no-edit -m "merge upstream into the fork" refs/remotes/origin/main
home3b=$(task_state "$TMP/c2" ingest "$fleet3b")
run_pr_check "$home3b" ingest "https://github.com/acme-fleet/widget/pull/17"
assert_not_contains "$OUT" "not this task's work" \
  "a deliberate upstream-ingest merge was refused as a bad branch point"
pass "a branch that deliberately merges the upstream in is not mistaken for a bad cut"

# --- the cause, axis 2: the worktree pool's starting commit -----------------
#
# What a worktree pool hands over: detached on the UPSTREAM default branch,
# which is where all three real branches were cut from.

fleet4=$(make_fleet "$TMP/d")
before=$(git -C "$fleet4" rev-parse HEAD)
[ "$before" = "$(git -C "$fleet4" rev-parse refs/remotes/origin/main)" ] \
  || fail "fixture should start on the upstream default branch"
out=$("$WT_BASE" "$fleet4" "$fleet4" 2>&1) || fail "alignment failed: $out"
[ "$(git -C "$fleet4" rev-parse HEAD)" = "$(git -C "$fleet4" rev-parse refs/remotes/fork/main)" ] \
  || fail "worktree was not moved onto the branch the project ships to"
assert_contains "$out" "acme-fleet/widget" "alignment reports the repository it aligned to"
pass "a pool worktree starting on the upstream is moved onto the fork's default branch"

# Idempotent: a second run changes nothing and says nothing.
out=$("$WT_BASE" "$fleet4" "$fleet4" 2>&1) || fail "second alignment failed: $out"
[ -z "$out" ] || fail "already-aligned worktree produced output: $out"
pass "aligning an already-aligned worktree is a silent no-op"

# A worktree carrying work is never moved, whatever its base.
fleet5=$(make_fleet "$TMP/e")
printf 'work\n' > "$fleet5/uncommitted.txt"
git -C "$fleet5" add uncommitted.txt
set +e
out=$("$WT_BASE" "$fleet5" "$fleet5" 2>&1); code=$?
set -e
expect_code 1 "$code" "a worktree with uncommitted work must not be moved"
[ "$(git -C "$fleet5" rev-parse HEAD)" = "$(git -C "$fleet5" rev-parse refs/remotes/origin/main)" ] \
  || fail "a worktree with uncommitted work was moved anyway"
assert_contains "$out" "uncommitted" "refusal explains why the worktree was left alone"
pass "a worktree with unlanded work is refused, not rebased"

# An ordinary project - one origin, which IS the base - must be untouched.
plain="$TMP/f/plain"
fm_git_init_commit "$plain"
fm_git_add_origin "$plain" "$TMP/f/origin.git"
git -C "$plain" remote set-url origin https://github.com/acme/plain.git
out=$("$WT_BASE" "$plain" "$plain" 2>&1) || fail "plain project alignment failed: $out"
[ -z "$out" ] || fail "plain project produced output: $out"
pass "a project that ships to its own origin is left completely alone"

# --- the cause, axis 1: the validation pipeline's own checkout --------------

fleet6=$(make_fleet "$TMP/g")
gate=$(make_gate "$TMP/g" "$fleet6")

out=$("$PR_BASE" check "$fleet6" 2>&1)
assert_contains "$out" "PR_BASE:" "check must report a gate that resolves the wrong repository"
assert_contains "$out" "acme-fleet/widget" "check names the repository the pipeline should target"
[ "$(git -C "$gate" config --get remote.origin.url)" = "$UPSTREAM_URL" ] \
  || fail "check mutated the gate mirror"
pass "check reports a validation pipeline pointed at the upstream without changing it"

out=$("$PR_BASE" repair "$fleet6" 2>&1)
assert_contains "$out" "BOOTSTRAP_INFO:" "repair reports what it converged"
[ "$(git -C "$gate" config --get remote.origin.url)" = "$FORK_URL" ] \
  || fail "repair did not point the pipeline's checkout at the fork"
[ "$(git -C "$gate" config --get remote.origin.gh-resolved)" = "acme-fleet/widget" ] \
  || fail "repair did not record the base repository the pipeline resolves"
pass "repair points the validation pipeline's own checkout at the fork, on both keys"

out=$("$PR_BASE" repair "$fleet6" 2>&1)
[ -z "$out" ] || fail "repair is not idempotent: $out"
out=$("$PR_BASE" check "$fleet6" 2>&1)
[ -z "$out" ] || fail "check still reports a problem after repair: $out"
pass "repair is idempotent and check goes silent once converged"

# An ordinary project's gate must never be rewritten.
plain2="$TMP/h/plain"
fm_git_init_commit "$plain2"
fm_git_add_origin "$plain2" "$TMP/h/origin.git"
git -C "$plain2" remote set-url origin https://github.com/acme/plain.git
git init -q --bare "$TMP/h/gate.git"
git -C "$TMP/h/gate.git" remote add origin https://github.com/acme/plain.git
git -C "$plain2" remote add no-mistakes "$TMP/h/gate.git"
out=$("$PR_BASE" repair "$plain2" 2>&1)
[ -z "$out" ] || fail "plain project repair produced output: $out"
[ -z "$(git -C "$TMP/h/gate.git" config --get remote.origin.gh-resolved || true)" ] \
  || fail "plain project's gate was rewritten"
pass "a project that ships to its own origin has its gate left alone"

# --- derivation, not hardcoding ---------------------------------------------
#
# Re-point the SAME fixture at a third repository purely through configuration.
# A fix that hardcoded an owner cannot follow this.

fleet7=$(make_fleet "$TMP/i")
git -C "$fleet7" config --unset remote.fork.gh-resolved
git -C "$fleet7" remote add other https://github.com/third-party/widget.git
git -C "$fleet7" config remote.other.gh-resolved base
home7=$(task_state "$TMP/i" derived "$fleet7")
run_pr_check "$home7" derived "https://github.com/acme-fleet/widget/pull/1"
expect_code 1 "$CODE" "expectation must follow the configured base repository"
assert_contains "$OUT" "third-party/widget" "expectation is read from configuration"
pass "the expected repository follows configuration, not a hardcoded owner"

# --- an unresolvable expectation cannot refuse, and says so -----------------

home8=$(task_state "$TMP/j" gonewt "$TMP/j/missing-worktree")
run_pr_check "$home8" gonewt "https://github.com/acme/widget/pull/2"
assert_contains "$OUT" "cannot confirm" "a missing local copy must be reported, not passed silently"
pass "a task whose local copy is gone reports that the target could not be confirmed"
