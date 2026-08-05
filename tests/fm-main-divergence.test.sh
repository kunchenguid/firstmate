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
# origin/<default> ref) and the fm-bootstrap.sh MAIN_DIVERGED problem line -
# all hermetic over temp git repos.
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

  # Detect-only mode is read-only for every other check; this guard never
  # mutates, so it must report identically there too.
  out=$(FM_ROOT_OVERRIDE="$tracked" FM_HOME="$tracked" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^MAIN_DIVERGED:' || true)
  assert_contains "$out" "MAIN_DIVERGED:" "detect-only bootstrap did not report a diverged primary checkout"

  pass "fm-bootstrap: MAIN_DIVERGED problem line fires only once local diverges from origin, identically in detect-only mode"
}

test_lib_classification
test_bootstrap_line
