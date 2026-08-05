#!/usr/bin/env bash
# Behavior tests for the primary-checkout origin-divergence guard.
#
# Firstmate's self-update path (/updatefirstmate, bin/fm-update.sh) is
# fast-forward ONLY: it advances the primary checkout's local default branch to
# origin/<default> and silently skips the moment the local branch is not an
# ancestor of origin. The failure mode this guard surfaces is a shared fix
# landing directly on the local default branch instead of through the normal PR
# path, which diverges it from origin and leaves every later self-update quietly
# doing nothing with no alarm. These cases pin: the shared lib's divergence
# classification (healthy/behind, diverged, ahead-only, no origin, no
# origin/<default> ref), its primary-only scoping over the shared refs every
# linked worktree can also read, and the fm-bootstrap.sh MAIN_DIVERGED problem
# line - including its detect-only split, mirroring TANGLE's own read-only
# advisory wording for a session that did not get the fleet lock - all
# hermetic over temp git repos.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-main-divergence-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-main-divergence)
fm_git_identity fmtest fmtest@example.invalid

# --- fixture builders --------------------------------------------------------

# A fresh git repo on `main` with one commit. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# --- shared lib: divergence classification -----------------------------------

test_lib_classification() {
  local seed bare tracked out

  # Case: no origin remote at all - silent, never fetches, never errors.
  tracked="$TMP_ROOT/no-origin"
  make_repo "$tracked" >/dev/null
  out=$(fm_primary_diverged_branch "$tracked" || true)
  [ -z "$out" ] || fail "no-origin repo wrongly reported diverged: '$out'"

  # Case: origin remote configured but never fetched, so origin/<default> does
  # not exist locally yet - silent.
  git -C "$tracked" remote add origin "$TMP_ROOT/nonexistent.git"
  out=$(fm_primary_diverged_branch "$tracked" || true)
  [ -z "$out" ] || fail "unfetched origin remote wrongly reported diverged: '$out'"

  # Build a real origin: seed -> bare "origin" -> a clone that tracks it.
  seed="$TMP_ROOT/seed"
  make_repo "$seed" >/dev/null
  bare="$TMP_ROOT/origin.git"
  git clone --quiet --bare "$seed" "$bare" >/dev/null
  tracked="$TMP_ROOT/tracked"
  git clone --quiet "$bare" "$tracked" >/dev/null

  # Case: local == origin/<default> (a fresh clone) - healthy, silent.
  out=$(fm_primary_diverged_branch "$tracked" || true)
  [ -z "$out" ] || fail "freshly cloned repo (equal to origin) wrongly reported diverged: '$out'"

  # Case: local behind origin (origin advanced, local did not) - healthy, silent.
  local origin_work="$TMP_ROOT/origin-work"
  git clone --quiet "$bare" "$origin_work" >/dev/null
  git -C "$origin_work" commit -q --allow-empty -m "upstream fix"
  git -C "$origin_work" push --quiet origin main
  git -C "$tracked" fetch --quiet origin
  out=$(fm_primary_diverged_branch "$tracked" || true)
  [ -z "$out" ] || fail "local behind origin wrongly reported diverged: '$out'"

  # Case: true divergence - local has a commit origin does not, AND origin has
  # since advanced past their common ancestor. Must flag.
  git -C "$tracked" commit -q --allow-empty -m "local-only fix, landed directly"
  out=$(fm_primary_diverged_branch "$tracked" || true)
  [ "$out" = "main" ] || fail "diverged repo did not flag: got '$out'"

  # Case: local strictly ahead of origin (origin never advanced past the shared
  # base) - still flags, since it means a fix landed locally that origin never
  # received.
  local ahead="$TMP_ROOT/ahead"
  git clone --quiet "$bare" "$ahead" >/dev/null
  git -C "$ahead" commit -q --allow-empty -m "local-only fix, origin untouched"
  out=$(fm_primary_diverged_branch "$ahead" || true)
  [ "$out" = "main" ] || fail "ahead-of-origin repo did not flag: got '$out'"

  pass "fm_primary_diverged_branch: behind/equal stay silent; diverged and ahead-only both flag; no origin or unfetched origin/<default> stay silent"
}

# --- shared lib: primary-only scoping ----------------------------------------
#
# refs/heads/<default> and refs/remotes/origin/<default> live in the shared
# common git dir, so every linked worktree of a diverged repo reads the exact
# refs the check compares. Only the primary checkout sitting on its default
# branch may raise the alarm; a detached-HEAD linked worktree (the shape of a
# crewmate worktree or secondmate home) and a named non-default branch (the
# tangled primary, which TANGLE owns) must stay silent over that same repo.

test_lib_primary_scoping() {
  local seed bare tracked home feature out

  seed="$TMP_ROOT/scope-seed"
  make_repo "$seed" >/dev/null
  bare="$TMP_ROOT/scope-origin.git"
  git clone --quiet --bare "$seed" "$bare" >/dev/null
  tracked="$TMP_ROOT/scope-tracked"
  git clone --quiet "$bare" "$tracked" >/dev/null
  git -C "$tracked" commit -q --allow-empty -m "local-only fix, landed directly"

  # Premise: this repo really is diverged, and the primary still flags.
  out=$(fm_primary_diverged_branch "$tracked" || true)
  [ "$out" = "main" ] || fail "scoping fixture is not diverged at the primary: got '$out'"

  # A detached-HEAD linked worktree of that same diverged repo - the secondmate
  # home / crewmate worktree shape - must stay silent even though it resolves
  # the identical shared refs.
  home="$TMP_ROOT/scope-secondmate-home"
  git -C "$tracked" worktree add --quiet --detach "$home" main >/dev/null 2>&1
  [ -n "$(git -C "$home" rev-parse --verify --quiet refs/remotes/origin/main)" ] \
    || fail "linked worktree cannot see refs/remotes/origin/main, so silence would prove nothing"
  [ -z "$(git -C "$home" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
    || fail "linked worktree fixture is not at detached HEAD"
  out=$(fm_primary_diverged_branch "$home" || true)
  [ -z "$out" ] || fail "detached-HEAD linked worktree of a diverged repo wrongly reported diverged: '$out'"

  # A named non-default branch is the tangled state: silent here, and TANGLE
  # still owns and reports it.
  feature="$TMP_ROOT/scope-feature"
  git clone --quiet "$bare" "$feature" >/dev/null
  git -C "$feature" checkout -q -b fm/some-task
  git -C "$feature" commit -q --allow-empty -m "local-only fix on a feature branch"
  git -C "$feature" branch -q -f main HEAD
  [ -n "$(git -C "$feature" rev-parse --verify --quiet refs/remotes/origin/main)" ] \
    || fail "feature-branch fixture cannot see refs/remotes/origin/main"
  git -C "$feature" merge-base --is-ancestor refs/heads/main refs/remotes/origin/main 2>/dev/null \
    && fail "feature-branch fixture's local main is not diverged, so silence would prove nothing"
  out=$(fm_primary_diverged_branch "$feature" || true)
  [ -z "$out" ] || fail "named non-default branch wrongly reported diverged: '$out'"
  out=$(fm_primary_tangle_branch "$feature" || true)
  [ "$out" = "fm/some-task" ] || fail "tangled checkout is unowned: TANGLE did not flag it either: got '$out'"

  pass "fm_primary_diverged_branch: scoped to the primary on its default branch - a detached-HEAD linked worktree and a tangled feature branch over the same diverged refs both stay silent"
}

# --- fm-bootstrap.sh MAIN_DIVERGED problem line ------------------------------

run_bootstrap() {
  # No projects/ under the home keeps fleet sync inert; grep isolates the line.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local seed bare tracked origin_work out

  seed="$TMP_ROOT/boot-seed"
  make_repo "$seed" >/dev/null
  bare="$TMP_ROOT/boot-origin.git"
  git clone --quiet --bare "$seed" "$bare" >/dev/null
  tracked="$TMP_ROOT/boot-tracked"
  git clone --quiet "$bare" "$tracked" >/dev/null

  out=$(run_bootstrap "$tracked" | grep '^MAIN_DIVERGED:' || true)
  [ -z "$out" ] || fail "bootstrap emitted MAIN_DIVERGED while equal to origin: $out"

  origin_work="$TMP_ROOT/boot-origin-work"
  git clone --quiet "$bare" "$origin_work" >/dev/null
  git -C "$origin_work" commit -q --allow-empty -m "upstream fix"
  git -C "$origin_work" push --quiet origin main
  git -C "$tracked" fetch --quiet origin
  out=$(run_bootstrap "$tracked" | grep '^MAIN_DIVERGED:' || true)
  [ -z "$out" ] || fail "bootstrap emitted MAIN_DIVERGED while merely behind origin: $out"

  git -C "$tracked" commit -q --allow-empty -m "local-only fix, landed directly"
  out=$(run_bootstrap "$tracked" | grep '^MAIN_DIVERGED:' || true)
  assert_contains "$out" "MAIN_DIVERGED:" "bootstrap did not report a diverged primary checkout"
  assert_contains "$out" "main" "MAIN_DIVERGED line did not name the default branch"
  assert_contains "$out" "/updatefirstmate" "MAIN_DIVERGED line did not point at the self-update path"
  # The check never fetches, so the remediation must send the reader to refresh
  # the possibly-stale tracking ref before acting on it.
  assert_contains "$out" "fetch origin" "MAIN_DIVERGED line did not tell the reader to fetch first"

  # Detect-only mode is read-only for every other check (TANGLE drops its
  # state-changing checkout command there); this guard's check function never
  # mutates in either mode, but its printed remediation does instruct a fetch,
  # so - like TANGLE - detect-only mode must keep the alarm while dropping that
  # fetch instruction rather than reporting byte-identically.
  out=$(FM_ROOT_OVERRIDE="$tracked" FM_HOME="$tracked" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^MAIN_DIVERGED:' || true)
  assert_contains "$out" "MAIN_DIVERGED:" "detect-only bootstrap did not report a diverged primary checkout"
  assert_contains "$out" "main" "detect-only MAIN_DIVERGED line did not name the default branch"
  assert_not_contains "$out" "fetch origin" "detect-only MAIN_DIVERGED line printed a state-changing fetch instruction"

  pass "fm-bootstrap: MAIN_DIVERGED problem line fires only once local diverges from origin; normal mode instructs a fetch first, detect-only mode stays advisory-only with no such command"
}

test_lib_classification
test_lib_primary_scoping
test_bootstrap_line
