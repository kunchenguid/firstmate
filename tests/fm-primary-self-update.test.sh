#!/usr/bin/env bash
# Behavior tests for the CADENCE trigger of the automatic primary-checkout
# self-update: bin/fm-bootstrap.sh calling bin/fm-ff-lib.sh's
# primary_self_update() on every non-detect-only bootstrap run. The EVENT
# trigger - bin/fm-pr-merge.sh calling the identical function once,
# immediately after a firstmate-repo merge - is covered separately in
# tests/fm-pr-merge-self-update.test.sh; both call the same function, so
# these cases pin its behavior regardless of which caller is exercised.
#
# Firstmate's board and other locally-served surfaces are regenerated from
# the primary firstmate home. Before this guard, a merged firstmate PR only
# reached that home when the captain remembered to run /updatefirstmate by
# hand, so a merged re-skin (or any other change) could keep being served
# stale indefinitely with no signal. primary_self_update() attempts the
# exact same fast-forward /updatefirstmate performs (fm-ff-lib.sh's
# ff_target, base_mode "origin"), and reports a durable, captain-visible
# SELF_UPDATE_BLOCKED line rather than silently declining when the checkout
# cannot be advanced - never forcing, stashing, or resetting. These cases
# pin: a clean checkout fast-forwards; an instruction-surface change asks
# the agent to re-read AGENTS.md; a dirty or diverged checkout is left
# untouched and reported; a secondmate-shaped detached HEAD, and a
# standalone-clone secondmate marked with .fm-secondmate-home, are both
# silently left to their own existing convergence paths; and detect-only
# mode never fetches or mutates. All hermetic over temporary git repos.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-self-update)
fm_git_identity fmtest fmtest@example.invalid

# --- fixture builders --------------------------------------------------------

# A fresh git repo on `main` with one commit, gitignoring the same
# operational directories the real firstmate repo does (.gitignore: projects/,
# state/, data/, config/) so bootstrap's own benign housekeeping writes (e.g.
# materializing config/startup-memory-budget) can never dirty the fixture the
# way they never dirty a real firstmate checkout. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  printf 'projects/\nstate/\ndata/\nconfig/\n' > "$dir/.gitignore"
  git -C "$dir" add .gitignore
  git -C "$dir" commit -q -m init
  printf '%s\n' "$dir"
}

run_bootstrap() {
  # No projects/ or state/ under the home keeps fleet sync and the secondmate
  # sweeps inert, so the only mutating sweep that can act on the fixture is
  # primary_self_update; grep isolates the lines each case cares about.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

run_bootstrap_detect_only() {
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

# seed -> bare "origin" -> tracked clone, with origin already advanced one
# commit past tracked. Echoes "<bare> <tracked>".
make_advanced_fixture() {
  local label=$1 seed bare tracked origin_work
  seed="$TMP_ROOT/$label-seed"
  make_repo "$seed" >/dev/null
  bare="$TMP_ROOT/$label-origin.git"
  git clone --quiet --bare "$seed" "$bare" >/dev/null
  tracked="$TMP_ROOT/$label-tracked"
  git clone --quiet "$bare" "$tracked" >/dev/null
  origin_work="$TMP_ROOT/$label-origin-work"
  git clone --quiet "$bare" "$origin_work" >/dev/null
  git -C "$origin_work" commit -q --allow-empty -m "upstream fix"
  git -C "$origin_work" push --quiet origin main
  printf '%s %s\n' "$bare" "$tracked"
}

# --- clean, behind: fast-forwards silently when instructions did not change --

test_clean_behind_fast_forwards_silently() {
  local fixture bare tracked origin_tip local_before out
  fixture=$(make_advanced_fixture ff-silent)
  bare=${fixture% *}
  tracked=${fixture#* }
  origin_tip=$(git -C "$bare" rev-parse main)
  local_before=$(git -C "$tracked" rev-parse HEAD)
  [ "$local_before" != "$origin_tip" ] || fail "fixture is not actually behind origin"

  out=$(run_bootstrap "$tracked")
  assert_not_contains "$out" "SELF_UPDATE:" "clean fast-forward with no instruction change should stay silent"
  assert_not_contains "$out" "SELF_UPDATE_BLOCKED:" "clean fast-forward should never report blocked"
  [ "$(git -C "$tracked" rev-parse HEAD)" = "$origin_tip" ] \
    || fail "tracked checkout did not fast-forward to the merged origin tip"

  # A second run with nothing new upstream is current - still silent.
  out=$(run_bootstrap "$tracked")
  assert_not_contains "$out" "SELF_UPDATE" "an already-current checkout should stay silent"

  pass "primary_self_update: a clean, behind primary checkout fast-forwards silently and lands exactly on the merged origin commit"
}

# --- clean, behind, instructions changed: reports and asks for a re-read ----

test_instruction_change_reports_reread() {
  local seed bare tracked origin_work origin_tip out
  seed="$TMP_ROOT/instr-seed"
  make_repo "$seed" >/dev/null
  bare="$TMP_ROOT/instr-origin.git"
  git clone --quiet --bare "$seed" "$bare" >/dev/null
  tracked="$TMP_ROOT/instr-tracked"
  git clone --quiet "$bare" "$tracked" >/dev/null
  origin_work="$TMP_ROOT/instr-origin-work"
  git clone --quiet "$bare" "$origin_work" >/dev/null
  printf 'updated instructions\n' > "$origin_work/AGENTS.md"
  git -C "$origin_work" add AGENTS.md
  git -C "$origin_work" commit -q -m "update AGENTS.md"
  git -C "$origin_work" push --quiet origin main
  origin_tip=$(git -C "$bare" rev-parse main)

  out=$(run_bootstrap "$tracked")
  assert_contains "$out" "SELF_UPDATE:" "an instruction-surface change did not report SELF_UPDATE"
  assert_contains "$out" "AGENTS.md" "SELF_UPDATE line did not name the changed instruction surface"
  assert_contains "$out" "re-read AGENTS.md now" "SELF_UPDATE line did not ask the running agent to re-read AGENTS.md"
  [ "$(git -C "$tracked" rev-parse HEAD)" = "$origin_tip" ] \
    || fail "tracked checkout did not fast-forward to the merged origin tip"

  pass "primary_self_update: a fast-forward that changes AGENTS.md/bin/.agents/skills reports SELF_UPDATE and asks the agent to re-read AGENTS.md"
}

# --- dirty: refused, untouched, and durably reported ------------------------

test_dirty_checkout_refuses_and_reports() {
  local fixture bare tracked local_before out
  fixture=$(make_advanced_fixture dirty)
  bare=${fixture% *}
  tracked=${fixture#* }
  local_before=$(git -C "$tracked" rev-parse HEAD)

  printf 'stray\n' > "$tracked/dirty.txt"
  [ -n "$(git -C "$tracked" status --porcelain)" ] || fail "dirty fixture is not actually dirty"

  out=$(run_bootstrap "$tracked")
  assert_contains "$out" "SELF_UPDATE_BLOCKED:" "a dirty checkout did not report SELF_UPDATE_BLOCKED"
  assert_contains "$out" "dirty working tree" "SELF_UPDATE_BLOCKED line did not name the dirty tree as the reason"
  assert_contains "$out" "stale code" "SELF_UPDATE_BLOCKED line did not warn that locally-served surfaces may be stale"
  [ "$(git -C "$tracked" rev-parse HEAD)" = "$local_before" ] \
    || fail "dirty checkout advanced despite being refused"
  [ -n "$(git -C "$tracked" status --porcelain)" ] \
    || fail "dirty checkout's uncommitted change was lost"

  pass "primary_self_update: a dirty primary checkout is left untouched and durably reports SELF_UPDATE_BLOCKED"
}

# --- diverged: refused, untouched, and durably reported ---------------------

test_diverged_checkout_refuses_and_reports() {
  local fixture bare tracked local_before out
  fixture=$(make_advanced_fixture diverged)
  bare=${fixture% *}
  tracked=${fixture#* }
  git -C "$tracked" commit -q --allow-empty -m "local-only fix, landed directly"
  local_before=$(git -C "$tracked" rev-parse HEAD)

  out=$(run_bootstrap "$tracked")
  assert_contains "$out" "SELF_UPDATE_BLOCKED:" "a diverged checkout did not report SELF_UPDATE_BLOCKED"
  assert_contains "$out" "diverged from origin/main" "SELF_UPDATE_BLOCKED line did not name the divergence as the reason"
  [ "$(git -C "$tracked" rev-parse HEAD)" = "$local_before" ] \
    || fail "diverged checkout was forced, merged, or reset despite being refused"

  pass "primary_self_update: a diverged primary checkout is left untouched and durably reports SELF_UPDATE_BLOCKED"
}

# --- secondmate-shaped detached HEAD: left alone, no competing mechanism ----

test_detached_head_is_left_to_its_own_convergence_path() {
  local fixture bare tracked home local_before out
  fixture=$(make_advanced_fixture detached)
  bare=${fixture% *}
  tracked=${fixture#* }
  home="$TMP_ROOT/detached-home"
  git -C "$tracked" worktree add --quiet --detach "$home" main >/dev/null 2>&1
  local_before=$(git -C "$home" rev-parse HEAD)

  out=$(run_bootstrap "$home")
  assert_not_contains "$out" "SELF_UPDATE" "a detached-HEAD secondmate-shaped home should never be reported on by the primary self-update path"
  [ "$(git -C "$home" rev-parse HEAD)" = "$local_before" ] \
    || fail "detached-HEAD home was advanced by the primary self-update path instead of its own secondmate convergence"

  pass "primary_self_update: a secondmate-shaped detached HEAD stays silent and untouched, converging only through its own existing path"
}

# --- standalone-clone secondmate: left to fm-update.sh's own sweep ----------

test_standalone_clone_secondmate_is_left_to_its_own_convergence_path() {
  local fixture bare tracked local_before out
  fixture=$(make_advanced_fixture standalone-secondmate)
  bare=${fixture% *}
  tracked=${fixture#* }
  : > "$tracked/.fm-secondmate-home"
  local_before=$(git -C "$tracked" rev-parse HEAD)

  out=$(run_bootstrap "$tracked")
  assert_not_contains "$out" "SELF_UPDATE" "a standalone-clone secondmate home (marked, clean, on main, with origin) must never be advanced by the primary-only self-update path"
  [ "$(git -C "$tracked" rev-parse HEAD)" = "$local_before" ] \
    || fail "standalone-clone secondmate home was fetched and fast-forwarded from origin by the primary self-update path; that convergence belongs to bin/fm-update.sh's own secondmate sweep, not here"

  pass "primary_self_update: a standalone-clone secondmate home (not detached, so it would otherwise pass ff_target's own branch check) is kept out by the .fm-secondmate-home marker, leaving its origin convergence to fm-update.sh alone"
}

# --- detect-only: never fetches, never mutates, never reports ---------------

test_detect_only_never_fetches_or_mutates() {
  local fixture bare tracked local_before out
  fixture=$(make_advanced_fixture detect-only)
  bare=${fixture% *}
  tracked=${fixture#* }
  local_before=$(git -C "$tracked" rev-parse HEAD)

  out=$(run_bootstrap_detect_only "$tracked")
  assert_not_contains "$out" "SELF_UPDATE" "detect-only mode must never attempt or report the fetching self-update"
  [ "$(git -C "$tracked" rev-parse HEAD)" = "$local_before" ] \
    || fail "detect-only bootstrap mutated the checkout"

  pass "primary_self_update: detect-only bootstrap never fetches or mutates the primary checkout"
}

test_clean_behind_fast_forwards_silently
test_instruction_change_reports_reread
test_dirty_checkout_refuses_and_reports
test_diverged_checkout_refuses_and_reports
test_detached_head_is_left_to_its_own_convergence_path
test_standalone_clone_secondmate_is_left_to_its_own_convergence_path
test_detect_only_never_fetches_or_mutates
