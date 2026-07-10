#!/usr/bin/env bash
# tests/fm-secondmate-safety.test.sh - secondmate home safety invariants:
# the path-boundary matrices (seed/spawn/teardown), registry/charter/origin
# validation, treehouse lease handling, no-mistakes initialization of new
# clones, child-worktree protection, and backlog-handoff safety. The happy-path
# operator flow lives in fm-secondmate-lifecycle-e2e.test.sh; this file keeps the
# destructive-invariant coverage that an e2e run cannot deterministically reach.
set -u

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-safety)
export FM_BACKEND=tmux


test_fm_home_parameterization() {
  local brief home_one home_two out
  home_one="$TMP_ROOT/home one"
  home_two="$TMP_ROOT/home-two"
  mkdir -p "$home_one/data" "$home_one/state" "$home_two/data" "$home_two/state"
  printf '%s\n' '- app [local-only +yolo] - test app (added 2026-06-22)' > "$home_one/data/projects.md"

  out=$(FM_HOME="$home_one" "$ROOT/bin/fm-project-mode.sh" app)
  [ "$out" = "local-only on" ] || fail "fm-project-mode did not read projects.md from FM_HOME"
  out=$(FM_HOME="$home_two" "$ROOT/bin/fm-project-mode.sh" app 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "fm-project-mode did not isolate missing registry by home"

  FM_HOME="$home_one" "$ROOT/bin/fm-brief.sh" task-a app >/dev/null || fail "brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-a/brief.md"
  [ -f "$brief" ] || fail "brief was not written under FM_HOME/data"
  grep -F ">> '$home_one/state/task-a.status'" "$brief" >/dev/null || fail "brief did not shell-quote FM_HOME state path"

  FM_HOME="$home_one" "$ROOT/bin/fm-brief.sh" task-b app --scout >/dev/null || fail "scout brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-b/brief.md"
  grep -F ">> '$home_one/state/task-b.status'" "$brief" >/dev/null || fail "scout brief did not shell-quote FM_HOME state path"

  FM_HOME="$home_one" FM_SECONDMATE_CHARTER='ops domain' "$ROOT/bin/fm-brief.sh" task-c --secondmate app >/dev/null \
    || fail "secondmate brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-c/brief.md"
  grep -F ">> '$home_one/state/task-c.status'" "$brief" >/dev/null || fail "secondmate brief did not shell-quote FM_HOME state path"

  printf 'project=x\n' > "$home_one/state/task-a.meta"
  FM_HOME="$home_one" FM_GUARD_GRACE=999999 "$ROOT/bin/fm-pr-check.sh" task-a https://github.com/example/repo/pull/1 >/dev/null 2>/dev/null \
    || fail "fm-pr-check failed under FM_HOME"
  [ -f "$home_one/state/task-a.check.sh" ] || fail "pr check was not written under FM_HOME/state"
  [ ! -e "$home_two/state/task-a.check.sh" ] || fail "pr check leaked into another home"
  pass "FM_HOME parameterizes data and state paths"
}

test_lock_status_is_per_home() {
  local home_one home_two out
  home_one="$TMP_ROOT/lock-one"
  home_two="$TMP_ROOT/lock-two"
  mkdir -p "$home_one/state" "$home_two/state"
  printf '999999\n' > "$home_one/state/.lock"
  out=$(FM_HOME="$home_one" "$ROOT/bin/fm-lock.sh" status)
  printf '%s\n' "$out" | grep -F 'lock: stale' >/dev/null || fail "home one lock status did not read its own lock"
  out=$(FM_HOME="$home_two" "$ROOT/bin/fm-lock.sh" status)
  [ "$out" = "lock: free" ] || fail "home two lock status was affected by home one"
  pass "fm-lock status is scoped per home"
}

test_seed_allows_overlapping_clones_and_drops_owner() {
  # A project may appear in several secondmates' (non-exclusive) clone lists; the
  # registry never uses the legacy owns: field, and the removed `owner` subcommand
  # stays gone. The full happy seed - charter copied, clones+origins, no-mistakes
  # init, modes preserved - is asserted by fm-secondmate-lifecycle-e2e.
  local home design other
  home="$TMP_ROOT/overlap-main"
  design="$TMP_ROOT/overlap-design"
  other="$TMP_ROOT/overlap-other"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_init_commit "$home/projects/beta"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/seed-overlap-alpha.git"
  fm_git_add_origin "$home/projects/beta" "$TMP_ROOT/remotes/seed-overlap-beta.git"
  cat > "$home/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
EOF

  FM_HOME="$home" FM_SECONDMATE_CHARTER='feature design for alpha beta' \
    FM_SECONDMATE_SCOPE='feature design for alpha beta' \
    "$ROOT/bin/fm-home-seed.sh" design "$design" alpha beta >/dev/null \
    || fail "initial seed failed"
  assert_grep '- design - feature design for alpha beta' "$home/data/secondmates.md" "design registry line missing"
  assert_grep 'projects: alpha, beta' "$home/data/secondmates.md" "design project clone list missing"
  assert_no_grep 'owns:' "$home/data/secondmates.md" "registry used the legacy owns field"

  # beta is shared with a second secondmate of a different scope (overlap allowed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='issue triage for beta' \
    FM_SECONDMATE_SCOPE='issue triage for beta' \
    "$ROOT/bin/fm-home-seed.sh" other "$other" beta >/dev/null 2>&1 \
    || fail "seed refused overlapping project clones across different scopes"
  assert_grep '- other - issue triage for beta' "$home/data/secondmates.md" "overlapping registry line missing"
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "registry validation rejected overlapping clones"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" owner alpha >/dev/null 2>&1; then
    fail "owner subcommand still succeeded after routing moved to scopes"
  fi
  pass "seed allows overlapping project clone lists and drops the owns/owner routing"
}

test_home_seed_validate_rejects_duplicate_homes() {
  local home subhome subhome_abs err
  home="$TMP_ROOT/duplicate-home"
  subhome="$TMP_ROOT/duplicate-subhome"
  err="$TMP_ROOT/duplicate-home.err"
  mkdir -p "$home/data" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
- design - design domain mentions home: $TMP_ROOT/ignored-summary-home (home: $subhome_abs; scope: design work mentions home: $TMP_ROOT/ignored-scope-home; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $subhome_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two secondmates with the same home"
  fi
  grep -F 'duplicate secondmate home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate home assignment"
  pass "home seed validation rejects duplicate home routes"
}

test_home_seed_validate_rejects_duplicate_ids() {
  local home first second first_abs second_abs err
  home="$TMP_ROOT/duplicate-id-home"
  first="$TMP_ROOT/duplicate-id-first"
  second="$TMP_ROOT/duplicate-id-second"
  err="$TMP_ROOT/duplicate-id.err"
  mkdir -p "$home/data" "$first" "$second"
  first_abs=$(cd "$first" && pwd -P)
  second_abs=$(cd "$second" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
- design - design domain (home: $first_abs; scope: design work; projects: alpha; added 2026-06-22)
- design - design domain (home: $second_abs; scope: design work; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two homes for the same secondmate id"
  fi
  grep -F 'duplicate secondmate id assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate id assignment"
  pass "home seed validation rejects duplicate id routes"
}

test_home_seed_validate_rejects_nested_homes() {
  local home ancestor descendant ancestor_abs descendant_abs err
  home="$TMP_ROOT/nested-home"
  ancestor="$TMP_ROOT/nested-domain-a"
  descendant="$ancestor/domain-b"
  err="$TMP_ROOT/nested-home.err"
  mkdir -p "$home/data" "$ancestor" "$descendant"
  ancestor_abs=$(cd "$ancestor" && pwd -P)
  descendant_abs=$(cd "$descendant" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
- design - design domain (home: $ancestor_abs; scope: design work; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $descendant_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted nested secondmate homes"
  fi
  grep -F 'overlapping secondmate home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain nested home assignment"
  pass "home seed validation rejects nested home routes"
}

test_home_seed_uses_treehouse_acquired_home() {
  local home acquired acquired_abs fakebin log lease out
  home="$TMP_ROOT/dash-home"
  acquired="$TMP_ROOT/dash-acquired-home"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-fake")
  log="$TMP_ROOT/dash-fake/tmux.log"
  lease="$TMP_ROOT/dash-fake/lease"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha) \
    || fail "seed failed for a treehouse-acquired home"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$acquired_abs" >/dev/null || fail "seed did not report acquired home"
  grep -F 'treehouse get --lease --lease-holder dash' "$log" >/dev/null || fail "seed did not durably lease a home under the secondmate id"
  [ -f "$lease" ] || fail "seed did not record a treehouse lease"
  [ "$(cat "$lease")" = dash ] || fail "seed did not set the lease holder to the secondmate id"
  [ -f "$acquired/.fm-secondmate-home" ] || fail "seed did not mark acquired home"
  [ "$(cat "$acquired/.fm-secondmate-home")" = dash ] || fail "seed wrote wrong acquired-home marker"
  [ -d "$acquired/projects/alpha/.git" ] || fail "seed did not clone project into acquired home"
  grep -F "home: $acquired_abs" "$home/data/secondmates.md" >/dev/null || fail "registry did not record acquired home"
  pass "home seeding durably leases treehouse-acquired dash homes under the secondmate id"
}

test_home_seed_returns_treehouse_acquired_home_on_assignment_failure() {
  local home acquired acquired_abs fakebin log err
  home="$TMP_ROOT/dash-fail-home"
  acquired="$TMP_ROOT/dash-fail-acquired-home"
  err="$TMP_ROOT/dash-fail.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-fail-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf 'other\n' > "$acquired/.fm-secondmate-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-fail-fake")
  log="$TMP_ROOT/dash-fail-fake/tmux.log"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home marked for another secondmate"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain acquired marked-home rejection"
  grep -F "treehouse return --force $acquired_abs" "$log" >/dev/null \
    || fail "failed acquired seed did not return the home through treehouse"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- dash ' "$home/data/secondmates.md" >/dev/null; then
    fail "failed acquired seed left a registry route"
  fi
  pass "home seeding returns rejected acquired homes through treehouse"
}

test_home_seed_warns_when_acquired_home_return_fails() {
  local home acquired acquired_abs fakebin log err lease
  home="$TMP_ROOT/dash-return-fail-home"
  acquired="$TMP_ROOT/dash-return-fail-acquired-home"
  err="$TMP_ROOT/dash-return-fail.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-return-fail-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf 'other\n' > "$acquired/.fm-secondmate-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-return-fail-fake")
  log="$TMP_ROOT/dash-return-fail-fake/tmux.log"
  lease="$TMP_ROOT/dash-return-fail-fake/lease"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home after return failure setup"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not report original acquired-home rejection"
  grep -F "warning: failed to return treehouse-acquired home $acquired_abs during seed rollback" "$err" >/dev/null \
    || fail "seed rollback did not warn when treehouse return failed"
  [ -f "$lease" ] || fail "failed rollback return did not preserve lease evidence"
  grep -F "treehouse return --force $acquired_abs" "$log" >/dev/null \
    || fail "failed rollback did not attempt to return the acquired home"
  pass "home seed rollback warns when treehouse-acquired return fails"
}

test_home_seed_does_not_return_unsafe_acquired_home() {
  local home descendant fakebin log err
  home="$TMP_ROOT/dash-active-home"
  descendant="$home/data/dash-descendant-home"
  err="$TMP_ROOT/dash-active.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-active-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-active-fake")
  log="$TMP_ROOT/dash-active-fake/tmux.log"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted an acquired home matching the active firstmate home"
  fi
  grep -F 'secondmate home cannot be the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active acquired-home rejection"
  grep -F "treehouse return --force" "$log" >/dev/null \
    && fail "seed returned an unsafe acquired active home through treehouse"
  [ -d "$home/projects/alpha" ] || fail "unsafe acquired-home rollback removed the active home"

  : > "$log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$descendant" FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted an acquired home inside the active firstmate home"
  fi
  grep -F 'secondmate home cannot be inside the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active descendant acquired-home rejection"
  grep -F "treehouse return --force" "$log" >/dev/null \
    && fail "seed returned an unsafe acquired active descendant through treehouse"
  [ -d "$descendant" ] || fail "unsafe acquired-home rollback removed the active descendant"
  pass "home seeding leaves unsafe acquired active homes untouched"
}

test_home_seed_rolls_back_failed_clone() {
  local home subhome err missing_remote
  home="$TMP_ROOT/rollback-home"
  subhome="$TMP_ROOT/rollback-subhome"
  err="$TMP_ROOT/rollback-home.err"
  missing_remote="$TMP_ROOT/remotes/missing-beta.git"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_init_commit "$home/projects/beta"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/rollback-alpha.git"
  git -C "$home/projects/beta" remote add origin "file://$missing_remote"
  cat > "$home/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
EOF

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='rollback scope' FM_SECONDMATE_SCOPE='rollback scope' \
    "$ROOT/bin/fm-home-seed.sh" rollback "$subhome" alpha beta >/dev/null 2>"$err"; then
    fail "seed succeeded even though the second project clone failed"
  fi
  grep -F 'does not appear to be a git repository' "$err" >/dev/null \
    || grep -F 'repository' "$err" >/dev/null \
    || fail "seed failure did not include the clone error"
  [ ! -e "$subhome" ] || fail "failed seed left the newly created secondmate home behind"
  [ ! -e "$subhome/.fm-secondmate-home" ] || fail "failed seed left a subhome marker"
  [ ! -e "$subhome/projects/alpha" ] || fail "failed seed left a previously cloned project"
  [ ! -e "$home/data/rollback/brief.md" ] || fail "failed seed left a generated charter brief"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- rollback ' "$home/data/secondmates.md" >/dev/null; then
    fail "failed seed left a registry route"
  fi
  pass "home seeding rolls back failed clone attempts without residue"
}

test_home_seed_refuses_missing_filled_charter() {
  local home subhome err
  home="$TMP_ROOT/missing-charter-home"
  subhome="$TMP_ROOT/missing-charter-subhome"
  err="$TMP_ROOT/missing-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/missing-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a direct seed without a filled charter"
  fi
  grep -F 'no filled secondmate charter brief' "$err" >/dev/null \
    || fail "seed did not explain missing filled charter refusal"
  [ ! -e "$subhome" ] || fail "missing charter seed left a generated subhome"
  [ ! -e "$home/data/design/brief.md" ] || fail "missing charter seed generated a placeholder charter"
  pass "home seeding refuses direct seed without filled charter text"
}

test_home_seed_refuses_placeholder_charter() {
  local home subhome err
  home="$TMP_ROOT/placeholder-charter-home"
  subhome="$TMP_ROOT/placeholder-charter-subhome"
  err="$TMP_ROOT/placeholder-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/placeholder-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" design --secondmate alpha >/dev/null \
    || fail "placeholder charter scaffold failed"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted an unfilled placeholder charter"
  fi
  grep -F 'still contains {TASK}' "$err" >/dev/null \
    || fail "seed did not explain placeholder charter refusal"
  [ ! -e "$subhome" ] || fail "placeholder charter seed left a generated subhome"
  [ ! -e "$subhome/projects/alpha" ] || fail "placeholder charter seed cloned before refusing"
  pass "home seeding refuses unfilled placeholder charters"
}

test_home_seed_refuses_empty_charter_fields() {
  local home subhome err
  home="$TMP_ROOT/empty-charter-home"
  subhome="$TMP_ROOT/empty-charter-subhome"
  err="$TMP_ROOT/empty-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/empty-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='   ' "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a whitespace-only charter"
  fi
  grep -F 'empty Charter section' "$err" >/dev/null \
    || fail "seed did not explain empty charter refusal"
  [ ! -e "$subhome" ] || fail "empty charter seed left a generated subhome"

  rm -rf "$home/data/design" "$subhome" "$err"
  FM_SECONDMATE_SCOPE='   ' scaffold_secondmate_charter "$home" design 'filled charter' alpha \
    || fail "empty scope fixture scaffold failed"
  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted an empty routing scope"
  fi
  grep -F 'empty Routing scope section' "$err" >/dev/null \
    || fail "seed did not explain empty routing scope refusal"
  [ ! -e "$subhome" ] || fail "empty routing scope seed left a generated subhome"
  pass "home seeding refuses empty normalized charter fields"
}

test_home_seed_no_projects_end_to_end() {
  # A domain whose subject is the firstmate repo itself needs no project clones:
  # the deliberate --no-projects signal scaffolds, seeds, registers, and spawns a
  # project-less home end to end with no placeholder clone.
  local home sub sub_abs fakebin log meta proj_val out
  home="$TMP_ROOT/no-projects-seed-home"
  sub="$TMP_ROOT/no-projects-seed-subhome"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fakebin=$(make_fake_tmux "$TMP_ROOT/no-projects-fake")
  log="$TMP_ROOT/no-projects-fake/tmux.log"

  out=$(FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects) \
    || fail "project-less seed failed"
  sub_abs=$(cd "$sub" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$sub_abs" >/dev/null || fail "seed did not report the project-less subhome"

  # Registered with an empty projects field, marked, charter copied, no clones.
  assert_grep '- fdev - firstmate self-development' "$home/data/secondmates.md" "project-less registry line missing"
  assert_grep 'scope: firstmate repo work' "$home/data/secondmates.md" "project-less registry scope missing"
  assert_grep 'projects: ;' "$home/data/secondmates.md" "project-less registry did not render an empty projects field"
  [ "$(cat "$sub/.fm-secondmate-home")" = fdev ] || fail "project-less seed did not mark the subhome"
  assert_present "$sub/data/charter.md" "project-less seed did not copy the charter"
  [ -z "$(ls -A "$sub/projects" 2>/dev/null)" ] || fail "project-less seed cloned a project"
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "registry validation failed after project-less seed"

  # Spawn tolerates the empty projects field: the home resolves from the registry
  # and the projects meta is recorded empty rather than breaking the launch.
  : > "$log"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/no-projects-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" fdev "$sub" codex --secondmate >/dev/null 2>&1 \
    || fail "project-less secondmate spawn failed"
  meta="$home/state/fdev.meta"
  assert_grep 'kind=secondmate' "$meta" "project-less spawn meta lost kind=secondmate"
  assert_grep "home=$sub_abs" "$meta" "project-less spawn meta lost the subhome"
  proj_val=$(grep '^projects=' "$meta" | head -1 | cut -d= -f2-)
  [ -z "$proj_val" ] || fail "project-less spawn recorded a non-empty projects meta: '$proj_val'"
  pass "home seeding scaffolds, registers, and spawns a project-less home end to end"
}

test_home_seed_refuses_projectful_reused_charter_for_projectless_home() {
  local home reusable_sub stale_sub stale_brief stale_brief_before err
  home="$TMP_ROOT/no-projects-reused-charter-home"
  reusable_sub="$TMP_ROOT/no-projects-reused-charter-valid-subhome"
  stale_sub="$TMP_ROOT/no-projects-reused-charter-stale-subhome"
  stale_brief="$home/data/stale/brief.md"
  stale_brief_before="$TMP_ROOT/no-projects-reused-charter.before"
  err="$TMP_ROOT/no-projects-reused-charter.err"
  mkdir -p "$home/data" "$home/state" "$reusable_sub/data" "$stale_sub/data"
  mark_firstmate_home "$reusable_sub"
  mark_firstmate_home "$stale_sub"

  scaffold_secondmate_charter "$home" reusable 'firstmate self-development' --no-projects \
    || fail "project-less charter scaffold failed"
  printf '\n# Custom note\nThe projects above are local clones for work you supervise.\n' >> "$home/data/reusable/brief.md"
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" reusable "$reusable_sub" --no-projects >/dev/null \
    || fail "project-less seed rejected a reused project-less charter"
  assert_grep 'None. This is a project-less domain' "$reusable_sub/data/charter.md" \
    "reused project-less charter was not copied"

  scaffold_secondmate_charter "$home" stale 'firstmate self-development. None. This is a project-less domain.' alpha \
    || fail "projectful charter scaffold failed"
  sed 's/The projects above are local clones for work you supervise; they are not an exclusive ownership claim./Project clone details are customized for this domain./' \
    "$stale_brief" > "$stale_brief_before"
  mv "$stale_brief_before" "$stale_brief"
  cp "$stale_brief" "$stale_brief_before"
  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" stale "$stale_sub" --no-projects >/dev/null 2>"$err"; then
    fail "project-less seed accepted a reused charter with project clones"
  fi
  grep -F 'existing charter brief' "$err" >/dev/null \
    || fail "project-less charter refusal did not name the stale charter conflict"
  grep -F 'fm-brief.sh stale --secondmate --no-projects' "$err" >/dev/null \
    || fail "project-less charter refusal did not explain how to re-scaffold"
  cmp -s "$stale_brief_before" "$stale_brief" \
    || fail "project-less charter refusal changed the reused charter"
  assert_absent "$stale_sub/.fm-secondmate-home" "project-less charter refusal wrote a home marker"
  assert_absent "$stale_sub/data/charter.md" "project-less charter refusal copied a charter"
  assert_absent "$stale_sub/projects" "project-less charter refusal created a projects directory"
  if grep -F -- '- stale ' "$home/data/secondmates.md" >/dev/null; then
    fail "project-less charter refusal wrote a parent registry route"
  fi
  pass "home seeding validates reused project-less charters before mutation"
}

test_home_seed_refuses_projectless_conversion_of_populated_home() {
  local home sub err registry_before
  home="$TMP_ROOT/no-projects-conversion-home"
  sub="$TMP_ROOT/no-projects-conversion-subhome"
  err="$TMP_ROOT/no-projects-conversion.err"
  mkdir -p "$home/data" "$home/state" "$sub/data" "$sub/projects/existing-clone"
  mark_firstmate_home "$sub"
  fm_git_init_commit "$sub/projects/existing-clone"
  cat > "$sub/data/projects.md" <<EOF
- registry-only [direct-PR] - retained project entry (added 2026-06-22)
EOF
  registry_before=$(cat "$sub/data/projects.md")

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    fail "project-less seed converted a populated secondmate home"
  fi
  grep -F 'existing-clone' "$err" >/dev/null \
    || fail "project-less conversion refusal did not name the existing clone"
  grep -F 'registry-only' "$err" >/dev/null \
    || fail "project-less conversion refusal did not name the registry entry"
  grep -F 'retire or clean this home first' "$err" >/dev/null \
    || fail "project-less conversion refusal did not explain the required cleanup"
  assert_present "$sub/projects/existing-clone/.git" "project-less conversion refusal removed the existing clone"
  [ "$registry_before" = "$(cat "$sub/data/projects.md")" ] \
    || fail "project-less conversion refusal changed the project registry"
  assert_absent "$sub/.fm-secondmate-home" "project-less conversion refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less conversion refusal copied a charter"
  assert_absent "$sub/state" "project-less conversion refusal left an operational directory"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- fdev ' "$home/data/secondmates.md" >/dev/null; then
    fail "project-less conversion refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less conversion of a populated home"
}

test_home_seed_refuses_projectless_home_with_uninspectable_projects() {
  local home sub err
  home="$TMP_ROOT/no-projects-uninspectable-home"
  sub="$TMP_ROOT/no-projects-uninspectable-subhome"
  err="$TMP_ROOT/no-projects-uninspectable.err"
  mkdir -p "$home/data" "$home/state" "$sub/data" "$sub/projects/hidden-clone"
  mark_firstmate_home "$sub"
  fm_git_init_commit "$sub/projects/hidden-clone"
  chmod 311 "$sub/projects"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    chmod 700 "$sub/projects"
    fail "project-less seed accepted a home whose projects directory could not be inspected"
  fi
  chmod 700 "$sub/projects"
  grep -F 'cannot inspect existing projects directory' "$err" >/dev/null \
    || fail "project-less seed did not explain the projects inspection failure"
  grep -F 'resolve its access permissions or retire or clean this home' "$err" >/dev/null \
    || fail "project-less seed did not explain how to resolve the inspection failure"
  assert_present "$sub/projects/hidden-clone/.git" "project-less inspection refusal removed the existing clone"
  assert_absent "$sub/.fm-secondmate-home" "project-less inspection refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less inspection refusal copied a charter"
  assert_absent "$sub/state" "project-less inspection refusal left an operational directory"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- fdev ' "$home/data/secondmates.md" >/dev/null; then
    fail "project-less inspection refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less homes whose projects directory cannot be inspected"
}

test_home_seed_refuses_projectless_home_with_symlinked_projects() {
  local home sub target err
  home="$TMP_ROOT/no-projects-symlinked-projects-home"
  sub="$TMP_ROOT/no-projects-symlinked-projects-subhome"
  target="$sub/retained-projects"
  err="$TMP_ROOT/no-projects-symlinked-projects.err"
  mkdir -p "$home/data" "$home/state" "$sub/data" "$target/hidden-clone"
  mark_firstmate_home "$sub"
  fm_git_init_commit "$target/hidden-clone"
  ln -s "$target" "$sub/projects"
  chmod 311 "$target"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    chmod 700 "$target"
    fail "project-less seed accepted a home whose projects directory is a symlink"
  fi
  chmod 700 "$target"
  grep -F 'projects directory' "$err" >/dev/null \
    || fail "project-less seed did not identify the symlinked projects directory"
  grep -F 'it is a symlink' "$err" >/dev/null \
    || fail "project-less seed did not explain the symlinked projects directory refusal"
  assert_present "$target/hidden-clone/.git" "project-less symlink refusal removed the target clone"
  [ -L "$sub/projects" ] || fail "project-less symlink refusal changed the projects symlink"
  [ "$(readlink "$sub/projects")" = "$target" ] \
    || fail "project-less symlink refusal retargeted the projects symlink"
  assert_absent "$sub/.fm-secondmate-home" "project-less symlink refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less symlink refusal copied a charter"
  assert_absent "$sub/state" "project-less symlink refusal left an operational directory"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- fdev ' "$home/data/secondmates.md" >/dev/null; then
    fail "project-less symlink refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less homes with symlinked projects directories"
}

test_home_seed_refuses_projectless_home_with_non_directory_projects() {
  local home sub err projects_before
  home="$TMP_ROOT/no-projects-nondirectory-projects-home"
  sub="$TMP_ROOT/no-projects-nondirectory-projects-subhome"
  err="$TMP_ROOT/no-projects-nondirectory-projects.err"
  mkdir -p "$home/data" "$home/state" "$sub/data"
  mark_firstmate_home "$sub"
  printf '%s\n' 'retained project path' > "$sub/projects"
  projects_before=$(cat "$sub/projects")

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    fail "project-less seed accepted a home whose projects path is not a directory"
  fi
  grep -F 'projects directory' "$err" >/dev/null \
    || fail "project-less seed did not identify the non-directory projects path"
  grep -F 'it is not a directory' "$err" >/dev/null \
    || fail "project-less seed did not explain the non-directory projects path refusal"
  [ "$projects_before" = "$(cat "$sub/projects")" ] \
    || fail "project-less non-directory refusal changed the projects path"
  assert_absent "$sub/.fm-secondmate-home" "project-less non-directory refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less non-directory refusal copied a charter"
  assert_absent "$sub/state" "project-less non-directory refusal left an operational directory"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- fdev ' "$home/data/secondmates.md" >/dev/null; then
    fail "project-less non-directory refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less homes with non-directory projects paths"
}

test_home_seed_refuses_projectless_home_with_uninspectable_registry() {
  local home sub err registry_before
  home="$TMP_ROOT/no-projects-uninspectable-registry-home"
  sub="$TMP_ROOT/no-projects-uninspectable-registry-subhome"
  err="$TMP_ROOT/no-projects-uninspectable-registry.err"
  mkdir -p "$home/data" "$home/state" "$sub/data"
  mark_firstmate_home "$sub"
  printf '%s\n' '- hidden-registry [direct-PR] - retained project entry (added 2026-06-22)' > "$sub/data/projects.md"
  registry_before=$(cat "$sub/data/projects.md")
  chmod 000 "$sub/data/projects.md"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    chmod 600 "$sub/data/projects.md"
    fail "project-less seed accepted a home whose project registry could not be inspected"
  fi
  chmod 600 "$sub/data/projects.md"
  grep -F 'cannot inspect existing project registry' "$err" >/dev/null \
    || fail "project-less seed did not explain the project registry inspection failure"
  grep -F 'resolve its access permissions or retire or clean this home' "$err" >/dev/null \
    || fail "project-less seed did not explain how to resolve the project registry inspection failure"
  [ "$registry_before" = "$(cat "$sub/data/projects.md")" ] \
    || fail "project-less inspection refusal changed the project registry"
  assert_absent "$sub/.fm-secondmate-home" "project-less registry inspection refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less registry inspection refusal copied a charter"
  assert_absent "$sub/state" "project-less registry inspection refusal left an operational directory"
  assert_absent "$sub/projects" "project-less registry inspection refusal created a projects directory"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- fdev ' "$home/data/secondmates.md" >/dev/null; then
    fail "project-less registry inspection refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less homes whose project registry cannot be inspected"
}

test_home_seed_refuses_missing_projects_without_signal() {
  # Accidental omission of the project list, with no deliberate --no-projects
  # signal, must fail loudly and leave nothing behind, so a forgotten argument is
  # never mistaken for an intentional project-less seed.
  local home sub err
  home="$TMP_ROOT/missing-projects-home"
  sub="$TMP_ROOT/missing-projects-subhome"
  err="$TMP_ROOT/missing-projects.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='some scope' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" >/dev/null 2>"$err"; then
    fail "seed accepted a project-less home without the deliberate --no-projects signal"
  fi
  assert_absent "$sub" "loud-failure seed created a subhome"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- fdev ' "$home/data/secondmates.md" >/dev/null; then
    fail "loud-failure seed left a registry route"
  fi

  # The deliberate signal is mutually exclusive with a project list.
  if FM_HOME="$home" FM_SECONDMATE_CHARTER='some scope' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects alpha >/dev/null 2>"$err"; then
    fail "seed accepted --no-projects combined with a project list"
  fi
  grep -F 'cannot be combined with a project list' "$err" >/dev/null \
    || fail "seed did not explain the --no-projects mutual-exclusion rejection"
  pass "home seeding fails loudly on accidental project omission and rejects mixed --no-projects"
}

test_home_seed_refuses_local_only_project() {
  local home subhome err
  home="$TMP_ROOT/local-only-seed-home"
  subhome="$TMP_ROOT/local-only-seed-subhome"
  err="$TMP_ROOT/local-only-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  printf '%s\n' '- alpha [local-only] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed allowed a local-only project into a secondmate home"
  fi
  grep -F 'project alpha is local-only; secondmate routes support only no-mistakes and direct-PR projects' "$err" >/dev/null \
    || fail "seed did not explain local-only project rejection"
  [ ! -e "$subhome" ] || fail "seed created a subhome before rejecting a local-only project"
  pass "home seeding refuses local-only projects"
}

test_home_seed_refuses_registry_delimiter_home() {
  local home subhome err
  home="$TMP_ROOT/delimiter-home"
  subhome="$TMP_ROOT/delimiter)subhome"
  err="$TMP_ROOT/delimiter-home.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/delimiter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='delimiter charter' "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home path with registry delimiters"
  fi
  grep -F 'secondmate home path contains registry delimiters' "$err" >/dev/null \
    || fail "seed did not explain delimiter home refusal"
  [ ! -e "$subhome/.fm-secondmate-home" ] || fail "delimiter home seed wrote a marker"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- design ' "$home/data/secondmates.md" >/dev/null; then
    fail "delimiter home seed wrote a registry route"
  fi
  pass "home seeding refuses registry delimiter home paths"
}

test_home_seed_refuses_active_home_and_root() {
  local home err active_ancestor active_descendant root_clone root_descendant root_ancestor root_inside
  active_ancestor="$TMP_ROOT/active-seed-ancestor"
  home="$active_ancestor/main-home"
  err="$TMP_ROOT/active-seed.err"
  active_descendant="$home/nested/design-home"
  root_clone="$TMP_ROOT/active-seed-root"
  root_descendant="$root_clone/tmp/design-home"
  root_ancestor="$TMP_ROOT/active-seed-root-ancestor"
  root_inside="$root_ancestor/nested-root"
  git clone --quiet "$ROOT" "$active_ancestor"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/active-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for active-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$home" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home to reuse active FM_HOME"
  fi
  grep -F 'secondmate home cannot be the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME rejection"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$active_descendant" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home inside active FM_HOME"
  fi
  grep -F 'secondmate home cannot be inside the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME descendant rejection"
  [ ! -e "$home/nested" ] || fail "seed created a directory inside active FM_HOME before descendant rejection"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$active_ancestor" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home to contain active FM_HOME"
  fi
  grep -F 'secondmate home cannot be an ancestor of the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME ancestor rejection"
  [ ! -f "$active_ancestor/.fm-secondmate-home" ] || fail "seed marked an ancestor of active FM_HOME"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$ROOT" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home to reuse FM_ROOT"
  fi
  grep -F 'secondmate home cannot be the firstmate repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT rejection"

  git clone --quiet "$ROOT" "$root_clone"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$root_clone" "$ROOT/bin/fm-home-seed.sh" design "$root_descendant" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home inside FM_ROOT"
  fi
  grep -F 'secondmate home cannot be inside the firstmate repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT descendant rejection"
  [ ! -e "$root_clone/tmp" ] || fail "seed created a directory inside FM_ROOT before descendant rejection"

  git clone --quiet "$ROOT" "$root_ancestor"
  git clone --quiet "$ROOT" "$root_inside"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$root_inside" "$ROOT/bin/fm-home-seed.sh" design "$root_ancestor" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home to contain FM_ROOT"
  fi
  grep -F 'secondmate home cannot be an ancestor of the firstmate repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT ancestor rejection"
  [ ! -f "$root_ancestor/.fm-secondmate-home" ] || fail "seed marked an ancestor of FM_ROOT"
  pass "home seeding refuses active home and repo root"
}

test_home_seed_refuses_home_marked_for_another_id() {
  local home subhome err
  home="$TMP_ROOT/marked-seed-home"
  subhome="$TMP_ROOT/marked-seed-subhome"
  err="$TMP_ROOT/marked-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/marked-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  printf 'other\n' > "$subhome/.fm-secondmate-home"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for marked-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home marked for another secondmate"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain marked-home rejection"
  [ "$(cat "$subhome/.fm-secondmate-home")" = "other" ] || fail "seed overwrote another secondmate marker"
  pass "home seeding refuses homes marked for another id"
}

test_home_seed_refuses_home_registered_to_another_id() {
  local home subhome subhome_abs err
  home="$TMP_ROOT/registered-seed-home"
  subhome="$TMP_ROOT/registered-seed-subhome"
  err="$TMP_ROOT/registered-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/registered-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  printf '%s\n' '- other - other domain (home: '"$subhome_abs"'; scope: other domain; projects: beta; added 2026-06-22)' > "$home/data/secondmates.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for registered-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home registered to another secondmate"
  fi
  grep -F 'already registered to other' "$err" >/dev/null || fail "seed did not explain registered-home rejection"
  [ ! -e "$subhome/.fm-secondmate-home" ] || fail "seed wrote a marker before rejecting a registered home"
  pass "home seeding refuses homes registered to another id"
}

test_home_seed_refuses_reassigning_existing_id_to_different_home() {
  local home first second first_abs second_abs err
  home="$TMP_ROOT/reassign-id-home"
  first="$TMP_ROOT/reassign-id-first"
  second="$TMP_ROOT/reassign-id-second"
  err="$TMP_ROOT/reassign-id.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/reassign-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='design domain' FM_SECONDMATE_SCOPE='design domain' \
    "$ROOT/bin/fm-home-seed.sh" design "$first" alpha >/dev/null \
    || fail "initial seed failed for reassigning-id test"
  first_abs=$(cd "$first" && pwd -P)

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='design domain' FM_SECONDMATE_SCOPE='design domain' \
    "$ROOT/bin/fm-home-seed.sh" design "$second" alpha >/dev/null 2>"$err"; then
    fail "seed reassigned an existing secondmate id to a different home"
  fi
  grep -F "secondmate id design is already registered to home $first_abs" "$err" >/dev/null \
    || fail "seed did not explain same-id different-home rejection"
  [ ! -e "$second" ] || fail "failed id reassignment created the new subhome"
  [ "$(cat "$first/.fm-secondmate-home")" = design ] || fail "failed id reassignment changed the original marker"
  grep -F "home: $first_abs" "$home/data/secondmates.md" >/dev/null \
    || fail "failed id reassignment did not preserve the original registry route"
  second_abs=$(cd "$(dirname "$second")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$second")")
  grep -F "home: $second_abs" "$home/data/secondmates.md" >/dev/null \
    && fail "failed id reassignment recorded the rejected home"
  pass "home seeding refuses same-id reassignment to a different home"
}

test_home_seed_refuses_home_overlapping_registered_home() {
  local home registered_parent registered_child nested parent err
  home="$TMP_ROOT/overlap-seed-home"
  registered_parent="$TMP_ROOT/overlap-registered-parent"
  registered_child="$TMP_ROOT/overlap-registered-child-parent/child"
  nested="$registered_parent/nested"
  parent="$TMP_ROOT/overlap-registered-child-parent"
  err="$TMP_ROOT/overlap-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/overlap-alpha.git"
  git clone --quiet "$ROOT" "$registered_parent"
  git clone --quiet "$ROOT" "$registered_child"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  cat > "$home/data/secondmates.md" <<EOF
- parent - parent domain (home: $registered_parent; scope: parent domain; projects: beta; added 2026-06-22)
- child - child domain (home: $registered_child; scope: child domain; projects: gamma; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$nested" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home inside a registered secondmate home"
  fi
  grep -F 'overlaps registered secondmate home' "$err" >/dev/null \
    || fail "seed did not explain registered ancestor overlap"
  [ ! -e "$nested" ] || fail "seed created a nested home inside a registered home"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$parent" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home containing a registered secondmate home"
  fi
  grep -F 'overlaps registered secondmate home' "$err" >/dev/null \
    || fail "seed did not explain registered descendant overlap"
  [ ! -f "$parent/.fm-secondmate-home" ] || fail "seed marked a home containing a registered home"
  pass "home seeding refuses registered home overlaps"
}

test_home_seed_refuses_remote_backed_project_without_origin() {
  local home subhome err
  home="$TMP_ROOT/no-origin-home"
  subhome="$TMP_ROOT/no-origin-subhome"
  err="$TMP_ROOT/no-origin.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for no-origin seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed allowed remote-backed project without origin"
  fi
  grep -F 'project alpha is direct-PR but has no origin remote' "$err" >/dev/null || fail "seed did not explain missing origin for remote-backed project"
  pass "remote-backed subhome seeding requires a source origin"
}

test_home_seed_refuses_existing_remote_backed_project_with_wrong_origin() {
  local home subhome subhome_abs err expected
  home="$TMP_ROOT/wrong-origin-home"
  subhome="$TMP_ROOT/wrong-origin-subhome"
  err="$TMP_ROOT/wrong-origin.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/wrong-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  mkdir -p "$subhome/projects"
  git clone --quiet "$home/projects/alpha" "$subhome/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for wrong-origin seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted existing remote-backed project with wrong origin"
  fi
  expected=$(git -C "$home/projects/alpha" remote get-url origin)
  grep -F "seeded project alpha at $subhome_abs/projects/alpha has origin" "$err" >/dev/null \
    || fail "seed did not identify wrong origin for existing remote-backed project"
  grep -F "expected $expected" "$err" >/dev/null \
    || fail "seed did not report expected origin for existing remote-backed project"
  pass "remote-backed subhome seeding validates existing destination origins"
}

test_home_seed_resolves_relative_source_origins() {
  local home subhome subhome_abs expected out actual
  home="$TMP_ROOT/relative-origin-home"
  subhome="$TMP_ROOT/relative-origin-subhome"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$home/remotes"
  fm_git_init_commit "$home/projects/alpha"
  git clone --quiet --bare "$home/projects/alpha" "$home/remotes/relative-alpha.git"
  git -C "$home/projects/alpha" remote add origin ../../remotes/relative-alpha.git
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for relative origin seed test"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha)
  subhome_abs=$(cd "$subhome" && pwd -P)
  expected=$(cd "$home/remotes/relative-alpha.git" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$subhome_abs" >/dev/null || fail "seed did not report relative-origin subhome"
  [ -d "$subhome/projects/alpha/.git" ] || fail "relative source origin was not cloned"
  actual=$(git -C "$subhome/projects/alpha" remote get-url origin)
  [ "$actual" = "$expected" ] || fail "relative source origin was not cloned through the resolved path"
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null \
    || fail "relative source origin did not compare equal on reseed"
  pass "home seeding resolves relative source origins against the source project"
}

test_home_seed_skips_initialized_existing_no_mistakes_projects() {
  local home subhome err fakebin log origin
  home="$TMP_ROOT/existing-initialized-home"
  subhome="$TMP_ROOT/existing-initialized-subhome"
  err="$TMP_ROOT/existing-initialized.err"
  log="$TMP_ROOT/existing-initialized-no-mistakes.log"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_init_commit "$home/projects/beta"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/existing-alpha.git"
  fm_git_add_origin "$home/projects/beta" "$TMP_ROOT/remotes/existing-beta.git"
  git clone --quiet "$ROOT" "$subhome"
  mkdir -p "$subhome/projects"
  origin=$(git -C "$home/projects/alpha" remote get-url origin)
  git clone --quiet "$origin" "$subhome/projects/alpha"
  git -C "$subhome/projects/alpha" remote add no-mistakes "$TMP_ROOT/no-mistakes-alpha.git"
  printf '%s\n' '- alpha - alpha project (added 2026-06-22)' '- beta - beta project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_recording_no_mistakes "$TMP_ROOT/existing-initialized-fake")
  : > "$log"

  if PATH="$fakebin:$PATH" FM_FAKE_NO_MISTAKES_LOG="$log" FM_FAKE_NO_MISTAKES_FAIL_PROJECT=beta \
    FM_HOME="$home" FM_SECONDMATE_CHARTER='existing init rollback scope' FM_SECONDMATE_SCOPE='existing init rollback scope' \
    "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha beta >/dev/null 2>"$err"; then
    fail "seed succeeded even though later no-mistakes initialization failed"
  fi
  grep -F 'failed to initialize no-mistakes for beta' "$err" >/dev/null \
    || fail "seed did not explain later no-mistakes initialization failure"
  grep -F "$subhome/projects/alpha" "$log" >/dev/null \
    && fail "seed ran no-mistakes against an initialized existing clone"
  [ ! -f "$subhome/projects/alpha/.no-mistakes-init" ] || fail "seed mutated initialized existing clone with no-mistakes init"
  [ ! -f "$subhome/projects/alpha/.no-mistakes-doctor" ] || fail "seed mutated initialized existing clone with no-mistakes doctor"
  [ ! -e "$subhome/projects/beta" ] || fail "failed seed left a newly cloned project after no-mistakes failure"
  pass "home seeding skips initialized existing no-mistakes clones"
}

test_home_seed_refuses_uninitialized_existing_no_mistakes_project() {
  local home subhome err fakebin log origin
  home="$TMP_ROOT/existing-uninitialized-home"
  subhome="$TMP_ROOT/existing-uninitialized-subhome"
  err="$TMP_ROOT/existing-uninitialized.err"
  log="$TMP_ROOT/existing-uninitialized-no-mistakes.log"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/uninitialized-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  mkdir -p "$subhome/projects"
  origin=$(git -C "$home/projects/alpha" remote get-url origin)
  git clone --quiet "$origin" "$subhome/projects/alpha"
  printf '%s\n' '- alpha - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_recording_no_mistakes "$TMP_ROOT/existing-uninitialized-fake")
  : > "$log"

  if PATH="$fakebin:$PATH" FM_FAKE_NO_MISTAKES_LOG="$log" \
    FM_HOME="$home" FM_SECONDMATE_CHARTER='existing uninitialized scope' \
    "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed initialized a preexisting no-mistakes clone"
  fi
  grep -F 'refusing to mutate preexisting clone' "$err" >/dev/null \
    || fail "seed did not explain uninitialized existing no-mistakes clone refusal"
  [ ! -s "$log" ] || fail "seed ran no-mistakes before refusing an uninitialized existing clone"
  [ ! -f "$subhome/projects/alpha/.no-mistakes-init" ] || fail "seed mutated uninitialized existing clone"
  pass "home seeding refuses uninitialized existing no-mistakes clones"
}

test_home_seed_refuses_project_destinations_outside_subhome() {
  local home subhome sink err
  home="$TMP_ROOT/symlink-project-home"
  subhome="$TMP_ROOT/symlink-project-subhome"
  sink="$home/data/symlink-projects"
  err="$TMP_ROOT/symlink-project.err"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$sink"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  rm -rf "$subhome/projects"
  ln -s "$sink" "$subhome/projects"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink destination seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed followed a subhome projects symlink outside the subhome"
  fi
  grep -F 'secondmate projects directory must resolve inside the secondmate home' "$err" >/dev/null \
    || fail "seed did not explain unsafe project destination rejection"
  [ ! -e "$sink/alpha" ] || fail "seed cloned a project through an unsafe projects symlink"
  [ ! -f "$subhome/.fm-secondmate-home" ] || fail "seed marked subhome after unsafe project destination rejection"
  pass "home seeding refuses project destinations outside the subhome"
}

test_home_seed_refuses_operational_dirs_outside_subhome() {
  local home subhome sink err opdir
  home="$TMP_ROOT/symlink-opdir-home"
  err="$TMP_ROOT/symlink-opdir.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-opdir-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink operational dir seed test"

  for opdir in data state config; do
    subhome="$TMP_ROOT/symlink-opdir-subhome-$opdir"
    sink="$home/data/symlink-opdir-$opdir"
    rm -rf "$subhome" "$sink"
    git clone --quiet "$ROOT" "$subhome"
    mkdir -p "$sink"
    rm -rf "${subhome:?}/${opdir:?}"
    ln -s "$sink" "$subhome/$opdir"
    if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
      fail "seed accepted a subhome with $opdir symlinked outside the subhome"
    fi
    grep -F "secondmate $opdir directory must resolve inside the secondmate home" "$err" >/dev/null \
      || fail "seed did not explain unsafe $opdir directory rejection"
    [ ! -f "$subhome/.fm-secondmate-home" ] || fail "seed marked subhome after unsafe $opdir directory rejection"
  done
  pass "home seeding refuses operational directories outside the subhome"
}

test_home_seed_refuses_symlinked_leaf_files() {
  local home subhome sink err leaf target expected
  home="$TMP_ROOT/symlink-leaf-home"
  err="$TMP_ROOT/symlink-leaf.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-leaf-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink leaf seed test"

  for leaf in data/projects.md data/charter.md .fm-secondmate-home; do
    subhome="$TMP_ROOT/symlink-leaf-subhome-${leaf//\//-}"
    sink="$home/data/symlink-leaf-${leaf//\//-}"
    rm -rf "$subhome" "$sink"
    git clone --quiet "$ROOT" "$subhome"
    mkdir -p "$(dirname "$subhome/$leaf")" "$(dirname "$sink")"
    expected=outside
    if [ "$leaf" = ".fm-secondmate-home" ]; then
      expected=design
    fi
    printf '%s\n' "$expected" > "$sink"
    ln -s "$sink" "$subhome/$leaf"
    if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
      fail "seed accepted symlinked leaf file $leaf"
    fi
    grep -F 'secondmate leaf file must not be a symlink:' "$err" >/dev/null \
      || fail "seed did not explain symlinked leaf refusal for $leaf"
    target=$(cat "$sink")
    [ "$target" = "$expected" ] || fail "seed overwrote outside symlink target for $leaf"
    [ ! -f "$subhome/.fm-secondmate-home" ] || [ "$leaf" = ".fm-secondmate-home" ] || fail "seed marked subhome after symlinked leaf refusal"
  done
  pass "home seeding refuses symlinked leaf files"
}

test_secondmate_spawn_requires_seeded_matching_home() {
  local home subhome wronghome marker_only active_descendant active_ancestor ancestor_active_home fakeroot root_descendant root_ancestor root_inside fakebin log err
  home="$TMP_ROOT/spawn-validate-home"
  subhome="$TMP_ROOT/spawn-validate-subhome"
  wronghome="$TMP_ROOT/spawn-validate-wronghome"
  marker_only="$TMP_ROOT/spawn-validate-marker-only"
  active_descendant="$home/data/spawn-descendant-home"
  active_ancestor="$TMP_ROOT/spawn-active-ancestor"
  ancestor_active_home="$active_ancestor/main-home"
  fakeroot="$TMP_ROOT/spawn-validate-root"
  root_descendant="$fakeroot/tmp/spawn-descendant-home"
  root_ancestor="$TMP_ROOT/spawn-root-ancestor"
  root_inside="$root_ancestor/repo"
  mkdir -p "$home/data" "$home/state" "$subhome/data" "$wronghome/data" "$marker_only/data" "$active_descendant/data" "$root_descendant/data" "$fakeroot/bin"
  cat > "$fakeroot/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakeroot/bin/fm-guard.sh"
  mkdir -p "$ancestor_active_home/data" "$ancestor_active_home/state" "$active_ancestor/data" "$root_ancestor/data" "$root_inside/bin"
  cat > "$root_inside/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root_inside/bin/fm-guard.sh"
  fakebin=$(make_fake_tmux "$TMP_ROOT/spawn-validate-fake")
  log="$TMP_ROOT/spawn-validate-fake/tmux.log"
  err="$TMP_ROOT/spawn-validate.err"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$subhome" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted an unseeded home"
  fi
  grep -F 'not a seeded secondmate home' "$err" >/dev/null || fail "spawn did not explain missing seed marker"
  # Canonical ordering proof: validation runs before any tmux side-effect. Every rejection
  # reason below shares this one linear pre-launch path, so they each assert only their own
  # refusal message rather than re-proving "no window created before validation" each time.
  grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before validation"

  printf 'other\n' > "$wronghome/.fm-secondmate-home"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$wronghome" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home marked for another secondmate"
  fi
  grep -F 'marked for secondmate other, expected domain' "$err" >/dev/null || fail "spawn did not explain marker mismatch"

  printf 'domain\n' > "$marker_only/.fm-secondmate-home"
  printf 'charter\n' > "$marker_only/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$marker_only" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a marked home missing AGENTS.md"
  fi
  grep -F 'not a firstmate home (missing AGENTS.md)' "$err" >/dev/null || fail "spawn did not explain missing AGENTS.md"

  printf '# Firstmate\n' > "$marker_only/AGENTS.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$marker_only" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a marked home missing bin"
  fi
  grep -F 'not a firstmate home (missing bin/)' "$err" >/dev/null || fail "spawn did not explain missing bin"

  printf 'domain\n' > "$home/.fm-secondmate-home"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$home" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted the active home"
  fi
  grep -F 'secondmate home cannot be the active firstmate home' "$err" >/dev/null || fail "spawn did not reject active home"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$ROOT" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted the firstmate repo root"
  fi
  grep -F 'secondmate home cannot be the firstmate repo' "$err" >/dev/null || fail "spawn did not reject firstmate repo root"

  printf 'domain\n' > "$active_descendant/.fm-secondmate-home"
  printf 'charter\n' > "$active_descendant/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$active_descendant" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home inside the active firstmate home"
  fi
  grep -F 'secondmate home cannot be inside the active firstmate home' "$err" >/dev/null || fail "spawn did not reject active home descendant"

  printf 'domain\n' > "$active_ancestor/.fm-secondmate-home"
  printf 'charter\n' > "$active_ancestor/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$ancestor_active_home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$active_ancestor" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home containing the active firstmate home"
  fi
  grep -F 'secondmate home cannot be an ancestor of the active firstmate home' "$err" >/dev/null || fail "spawn did not reject active home ancestor"

  printf 'domain\n' > "$root_descendant/.fm-secondmate-home"
  printf 'charter\n' > "$root_descendant/data/charter.md"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$root_descendant" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home inside the firstmate repo"
  fi
  grep -F 'secondmate home cannot be inside the firstmate repo' "$err" >/dev/null || fail "spawn did not reject repo root descendant"

  printf 'domain\n' > "$root_ancestor/.fm-secondmate-home"
  printf 'charter\n' > "$root_ancestor/data/charter.md"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root_inside" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$root_ancestor" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home containing the firstmate repo"
  fi
  grep -F 'secondmate home cannot be an ancestor of the firstmate repo' "$err" >/dev/null || fail "spawn did not reject repo ancestor"

  pass "secondmate spawn validates homes before launch"
}

test_secondmate_spawn_refuses_operational_dirs_outside_subhome() {
  local home subhome sink fakebin log err opdir
  home="$TMP_ROOT/spawn-opdir-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/spawn-opdir-fake")
  log="$TMP_ROOT/spawn-opdir-fake/tmux.log"
  err="$TMP_ROOT/spawn-opdir.err"
  mkdir -p "$home/data" "$home/state"

  for opdir in data state config projects; do
    subhome="$TMP_ROOT/spawn-opdir-subhome-$opdir"
    sink="$home/data/spawn-opdir-$opdir"
    rm -rf "$subhome" "$sink"
    mkdir -p "$subhome/data" "$subhome/state" "$subhome/config" "$subhome/projects" "$sink"
    printf 'domain\n' > "$subhome/.fm-secondmate-home"
    printf 'charter\n' > "$subhome/data/charter.md"
    rm -rf "${subhome:?}/${opdir:?}"
    ln -s "$sink" "$subhome/$opdir"
    if [ "$opdir" = data ]; then
      printf 'charter\n' > "$sink/charter.md"
    fi
    : > "$log"
    if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-opdir-fake/pane.txt" \
      "$ROOT/bin/fm-spawn.sh" domain "$subhome" codex --secondmate >/dev/null 2>"$err"; then
      fail "secondmate spawn accepted a subhome with $opdir symlinked outside the subhome"
    fi
    grep -F "secondmate $opdir directory must resolve inside the secondmate home" "$err" >/dev/null \
      || fail "spawn did not explain unsafe $opdir directory rejection"
    grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before unsafe $opdir directory validation"
  done
  pass "secondmate spawn refuses operational directories outside the subhome"
}

test_fm_send_refuses_bare_window_without_home_meta() {
  # The happy path (a bare fm-<id> resolves the window recorded in THIS home's
  # meta and never a foreign same-named window) is asserted in the lifecycle e2e.
  # Here: with NO meta for the id, send must refuse rather than fall back to a
  # foreign same-named window that list-windows happens to return.
  local home fakebin log err
  home="$TMP_ROOT/send-home"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  fakebin=$(make_fake_tmux "$TMP_ROOT/send-fake")
  log="$TMP_ROOT/send-fake/tmux.log"
  err="$TMP_ROOT/send-fake/send.err"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="other-session:fm-missing" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/send-fake/pane.txt" \
    "$ROOT/bin/fm-send.sh" fm-missing 'wrong home' >/dev/null 2>"$err"; then
    fail "fm-send sent to a bare firstmate window without home metadata"
  fi
  grep -F "no metadata for fm-missing in $home/state" "$err" >/dev/null \
    || fail "fm-send did not explain missing home metadata"
  grep -F 'send-keys -t other-session:fm-missing' "$log" >/dev/null \
    && fail "fm-send fell back to a foreign same-name window"
  pass "fm-send refuses a bare firstmate window with no metadata in this home"
}

test_secondmate_teardown_retires_empty_home() {
  local home subhome subhome_abs fakebin log lease fmroot
  home="$TMP_ROOT/teardown-home"
  subhome="$TMP_ROOT/teardown-subhome"
  fmroot="$TMP_ROOT/teardown-fmroot"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-fake")
  log="$TMP_ROOT/teardown-fake/tmux.log"
  lease="$TMP_ROOT/teardown-fake/lease"
  printf 'domain\n' > "$lease"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-fake/pane.txt" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>/dev/null \
    || fail "teardown failed for empty secondmate home"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null || fail "teardown did not release the secondmate home lease via treehouse return"
  [ ! -e "$lease" ] || fail "teardown left the secondmate home lease held after retirement"
  [ ! -d "$subhome" ] || fail "teardown did not remove the retired secondmate home"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null && fail "teardown did not remove secondmate registry route"
  pass "secondmate teardown retires empty homes and releases routing"
}

test_secondmate_teardown_refuses_failed_leased_home_return() {
  local home subhome subhome_abs fakebin log fmroot err rc
  home="$TMP_ROOT/teardown-return-fail-home"
  subhome="$TMP_ROOT/teardown-return-fail-subhome"
  fmroot="$TMP_ROOT/teardown-return-fail-fmroot"
  err="$TMP_ROOT/teardown-return-fail.err"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-return-fail-fake")
  log="$TMP_ROOT/teardown-return-fail-fake/tmux.log"

  set +e
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-return-fail-fake/pane.txt" \
    FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "teardown succeeded despite failed treehouse return"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null || fail "teardown did not try to return the leased home"
  grep -F 'treehouse return failed for secondmate home' "$err" >/dev/null || fail "teardown did not report failed leased home return"
  [ -d "$subhome" ] || fail "teardown removed a leased home after return failed"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared meta after leased home return failed"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null || fail "teardown removed registry route after leased home return failed"
  pass "secondmate teardown refuses to hide failed leased-home return"
}

test_secondmate_teardown_removes_plain_clone_home_without_treehouse_return() {
  local home subhome subhome_abs fakebin log
  home="$TMP_ROOT/plain-clone-teardown-home"
  subhome="$TMP_ROOT/plain-clone-teardown-subhome"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  mark_firstmate_home "$subhome"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/plain-clone-teardown-fake")
  log="$TMP_ROOT/plain-clone-teardown-fake/tmux.log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/plain-clone-teardown-fake/pane.txt" \
    FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>/dev/null \
    || fail "teardown failed for plain-clone secondmate home"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null && fail "teardown tried to return a plain-clone home through treehouse"
  [ ! -d "$subhome" ] || fail "teardown did not remove the plain-clone secondmate home"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta for plain-clone home"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null && fail "teardown did not remove plain-clone registry route"
  pass "secondmate teardown raw-removes plain-clone homes"
}

test_secondmate_force_teardown_discards_child_work() {
  local home subhome childproj childwt fakebin log
  home="$TMP_ROOT/force-teardown-home"
  subhome="$TMP_ROOT/force-teardown-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/force-child-worktree"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  fm_git_worktree "$childproj" "$childwt" force-child
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/force-teardown-fake")
  log="$TMP_ROOT/force-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/force-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>&1; then
    fail "teardown allowed a secondmate with in-flight child work"
  fi
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/force-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>/dev/null \
    || fail "force teardown failed to discard child work"
  [ ! -d "$subhome" ] || fail "force teardown did not remove the retired secondmate home"
  [ ! -d "$childwt" ] || fail "force teardown did not remove child worktree"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null && fail "force teardown did not remove secondmate registry route"
  grep -F 'kill-window -t firstmate:fm-child' "$log" >/dev/null || fail "force teardown did not kill child window"
  grep -F 'kill-window -t firstmate:fm-domain' "$log" >/dev/null || fail "force teardown did not kill parent window"
  pass "secondmate force teardown discards child work"
}

test_secondmate_force_teardown_preserves_child_on_unproven_lock() {
  local home subhome childproj childwt fakebin log err rc lock
  home="$TMP_ROOT/force-lock-home"
  subhome="$TMP_ROOT/force-lock-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/force-lock-child-worktree"
  err="$TMP_ROOT/force-lock-child.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  fm_git_worktree "$childproj" "$childwt" force-child-lock
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/force-lock-child-fake")
  log="$TMP_ROOT/force-lock-child-fake/tmux.log"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  return)
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        *) target=$1 ;;
      esac
      shift
    done
    lock=$(git -C "$target" rev-parse --git-path index.lock 2>/dev/null || true)
    if [ -n "$lock" ] && [ -e "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      exit 128
    fi
    [ -n "$target" ] && rm -rf -- "$target"
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/lsof"
  lock=$(git -C "$childwt" rev-parse --git-path index.lock)
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/force-lock-child-fake/pane.txt" \
    FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "force teardown succeeded after child treehouse refused an unproven lock"
  [ -d "$childwt" ] || fail "force teardown raw-removed child worktree after unproven lock refusal"
  [ -e "$lock" ] || fail "force teardown removed unproven child index.lock"
  [ -d "$subhome" ] || fail "force teardown removed subhome after child lock refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after child lock refusal"
  grep -F 'not provably stale' "$err" >/dev/null || fail "force teardown did not explain unproven child lock refusal"
  pass "secondmate force teardown preserves child worktree after unproven lock refusal"
}

test_secondmate_force_teardown_allows_operational_dir_symlinks_inside_home() {
  local opdir home subhome target fakebin err log
  for opdir in data state config projects; do
    home="$TMP_ROOT/symlink-inside-teardown-home-$opdir"
    subhome="$TMP_ROOT/symlink-inside-teardown-subhome-$opdir"
    target="$subhome/internal-$opdir"
    err="$TMP_ROOT/symlink-inside-teardown-$opdir.err"
    rm -rf "$home" "$subhome"
    mkdir -p "$home/state" "$home/data" "$subhome" "$target"
    printf 'domain\n' > "$subhome/.fm-secondmate-home"
    ln -s "$target" "$subhome/$opdir"
    cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
    printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
    fakebin=$(make_fake_tmux "$TMP_ROOT/symlink-inside-teardown-fake-$opdir")
    log="$TMP_ROOT/symlink-inside-teardown-fake-$opdir/tmux.log"
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/symlink-inside-teardown-fake-$opdir/pane.txt" \
      "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err" \
      || fail "force teardown refused $opdir symlinked inside the secondmate home"
    [ ! -e "$subhome" ] || fail "force teardown did not remove subhome with inside $opdir symlink"
    [ ! -e "$home/state/domain.meta" ] || fail "force teardown did not clear parent meta for inside $opdir symlink"
    grep -F 'kill-window -t firstmate:fm-domain' "$log" >/dev/null || fail "force teardown did not kill parent window for inside $opdir symlink"
  done
  pass "force teardown allows operational directory symlinks inside the subhome"
}

test_secondmate_force_teardown_refuses_operational_dir_symlink_outside_home() {
  local home subhome external_state fakebin err log
  home="$TMP_ROOT/symlink-state-teardown-home"
  subhome="$TMP_ROOT/symlink-state-teardown-subhome"
  external_state="$home/data/external-state"
  err="$TMP_ROOT/symlink-state-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome" "$external_state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  ln -s "$external_state" "$subhome/state"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/symlink-state-teardown-fake")
  log="$TMP_ROOT/symlink-state-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/symlink-state-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown accepted a symlinked secondmate state directory"
  fi
  [ -d "$subhome" ] || fail "force teardown removed subhome after symlinked state refusal"
  [ -d "$external_state" ] || fail "force teardown removed external symlink target"
  grep -F 'state directory' "$err" >/dev/null || fail "teardown did not explain symlinked state refusal"
  grep -F 'resolves outside the secondmate home' "$err" >/dev/null || fail "teardown did not identify unsafe state symlink"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before symlinked state refusal"
  pass "force teardown refuses operational directory symlinks outside the subhome"
}

test_secondmate_teardown_path_boundary_matrix() {
  # The teardown path-boundary matrix: a secondmate home is refused (and left
  # fully intact, with no window killed before validation) when it is unmarked,
  # an ancestor of the active firstmate home, inside the active firstmate home,
  # or inside the firstmate repo. One row per hazard, one shared assertion block.
  local row base home subhome fmroot fakebin log err expect tid
  while IFS='|' read -r row expect; do
    [ -n "$row" ] || continue
    base="$TMP_ROOT/td-pb-$row"
    fmroot="$ROOT"   # real firstmate repo unless a row overrides it
    tid=domain
    case "$row" in
      unmarked)
        home="$base/main"; subhome="$base/sub"
        mkdir -p "$home/state" "$home/data" "$subhome/state"
        # No .fm-secondmate-home marker on purpose.
        ;;
      ancestor)
        # The home being torn down is an ANCESTOR of the active firstmate home.
        subhome="$base/anc"; home="$subhome/main-home"
        mkdir -p "$home/state" "$home/data" "$subhome/state"
        printf 'domain\n' > "$subhome/.fm-secondmate-home"
        ;;
      active-descendant)
        home="$base/desc"; subhome="$home/data/domain-home"
        mkdir -p "$home/state" "$home/data" "$subhome/state"
        printf 'domain\n' > "$subhome/.fm-secondmate-home"
        ;;
      repo-descendant)
        home="$base/home"; fmroot="$base/root"; subhome="$fmroot/tmp/domain-home"; tid='repo-domain'
        mkdir -p "$home/state" "$home/data" "$subhome/state" "$fmroot/bin"
        cat > "$fmroot/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
        chmod +x "$fmroot/bin/fm-guard.sh"
        printf 'repo-domain\n' > "$subhome/.fm-secondmate-home"
        ;;
    esac
    fm_write_secondmate_meta "$home/state/$tid.meta" "$subhome"
    printf -- '- %s - design domain (home: %s; scope: design domain; projects: alpha; added 2026-06-22)\n' \
      "$tid" "$subhome" > "$home/data/secondmates.md"
    fakebin=$(make_fake_tmux "$base/fake")
    log="$base/fake/tmux.log"
    err="$base/teardown.err"
    if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" \
      FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$base/fake/pane.txt" \
      "$ROOT/bin/fm-teardown.sh" "$tid" >/dev/null 2>"$err"; then
      fail "teardown ($row) accepted a hazardous secondmate home"
    fi
    grep -F "$expect" "$err" >/dev/null || fail "teardown ($row) did not explain the refusal (expected '$expect'): $(cat "$err")"
    [ -d "$subhome" ] || fail "teardown ($row) removed the protected home after refusal"
    [ -e "$home/state/$tid.meta" ] || fail "teardown ($row) cleared the parent meta after refusal"
    grep -F -- "- $tid " "$home/data/secondmates.md" >/dev/null || fail "teardown ($row) removed the registry route after refusal"
    grep -F 'kill-window' "$log" >/dev/null && fail "teardown ($row) killed a window before validation"
  done <<'ROWS'
unmarked|not a seeded secondmate home
ancestor|ancestor of the active firstmate home
active-descendant|inside the active firstmate home
repo-descendant|inside the firstmate repo
ROWS
  pass "secondmate teardown path-boundary matrix refuses unmarked/ancestor/active-descendant/repo-descendant homes"
}

test_secondmate_teardown_refuses_registered_nested_home() {
  local home subhome nested fakebin err log
  home="$TMP_ROOT/nested-teardown-home"
  subhome="$TMP_ROOT/nested-teardown-subhome"
  nested="$subhome/nested-domain"
  err="$TMP_ROOT/nested-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$nested/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  printf 'nested\n' > "$nested/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  cat > "$home/state/nested.meta" <<EOF
window=firstmate:fm-nested
worktree=$nested
project=$nested
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$nested
projects=beta
EOF
  cat > "$home/data/secondmates.md" <<EOF
- domain - design domain (home: $subhome; scope: design domain; projects: alpha; added 2026-06-22)
- nested - nested domain mentions home: $TMP_ROOT/ignored-summary-home (home: $nested; scope: nested domain mentions home: $TMP_ROOT/ignored-scope-home; projects: beta; added 2026-06-22)
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/nested-teardown-fake")
  log="$TMP_ROOT/nested-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/nested-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed a home containing another registered secondmate home"
  fi
  [ -d "$subhome" ] || fail "teardown removed registered ancestor home after refusal"
  [ -d "$nested" ] || fail "teardown removed registered nested home after refusal"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared ancestor meta after nested-home refusal"
  [ -e "$home/state/nested.meta" ] || fail "teardown cleared nested meta after nested-home refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before nested-home refusal"
  grep -F 'contains registered secondmate home' "$err" >/dev/null || fail "teardown did not explain registered nested-home refusal"
  pass "secondmate teardown refuses homes containing registered nested homes"
}

test_secondmate_teardown_refuses_child_registry_nested_home() {
  local home subhome nested fakebin err log
  home="$TMP_ROOT/child-registry-teardown-home"
  subhome="$TMP_ROOT/child-registry-teardown-subhome"
  nested="$subhome/nested-domain"
  err="$TMP_ROOT/child-registry-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/data" "$nested/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  printf 'nested\n' > "$nested/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  printf '%s\n' '- nested - nested domain (home: '"$nested"'; scope: nested domain; projects: beta; added 2026-06-22)' > "$subhome/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/child-registry-teardown-fake")
  log="$TMP_ROOT/child-registry-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/child-registry-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed a home containing a child-registry secondmate home"
  fi
  [ -d "$subhome" ] || fail "teardown removed ancestor home after child-registry refusal"
  [ -d "$nested" ] || fail "teardown removed child-registry nested home after refusal"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared parent meta after child-registry refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before child-registry refusal"
  grep -F 'contains registered secondmate home' "$err" >/dev/null || fail "teardown did not explain child-registry nested-home refusal"
  pass "secondmate teardown refuses nested homes from the child registry"
}

test_secondmate_force_teardown_prevalidates_before_child_cleanup() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/prevalidate-teardown-home"
  subhome="$TMP_ROOT/prevalidate-teardown-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/prevalidate-child-worktree"
  err="$TMP_ROOT/prevalidate-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj" "$childwt"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/prevalidate-teardown-fake")
  log="$TMP_ROOT/prevalidate-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/prevalidate-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown discarded child work before validating subhome"
  fi
  [ -d "$subhome" ] || fail "force teardown removed unmarked subhome after refusal"
  [ -d "$childwt" ] || fail "force teardown removed child worktree before validation"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta before validation"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta before validation"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before subhome validation"
  grep -F 'not a seeded secondmate home' "$err" >/dev/null || fail "force teardown did not explain missing seed marker"
  pass "force teardown validates subhome before child cleanup"
}

test_secondmate_force_teardown_refuses_child_active_home_descendant() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/child-active-descendant-home"
  subhome="$TMP_ROOT/child-active-descendant-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$home/data"
  err="$TMP_ROOT/child-active-descendant.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/child-active-descendant-fake")
  log="$TMP_ROOT/child-active-descendant-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/child-active-descendant-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed a child worktree inside active FM_HOME"
  fi
  [ -d "$home/data" ] || fail "force teardown removed active home data"
  [ -d "$subhome" ] || fail "force teardown removed subhome after child validation refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after child validation refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after child validation refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before child validation refusal"
  grep -F 'inside the active firstmate home' "$err" >/dev/null || fail "force teardown did not explain active home descendant rejection"
  pass "force teardown refuses child worktrees inside the active home"
}

test_secondmate_force_teardown_refuses_child_repo_descendant() {
  local home subhome childproj childwt fakeroot fakebin err log
  home="$TMP_ROOT/child-repo-descendant-home"
  subhome="$TMP_ROOT/child-repo-descendant-subhome"
  childproj="$subhome/projects/alpha"
  fakeroot="$TMP_ROOT/child-repo-descendant-root"
  childwt="$fakeroot/data"
  err="$TMP_ROOT/child-repo-descendant.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj" "$childwt" "$fakeroot/bin"
  cat > "$fakeroot/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakeroot/bin/fm-guard.sh"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/child-repo-descendant-fake")
  log="$TMP_ROOT/child-repo-descendant-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/child-repo-descendant-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed a child worktree inside FM_ROOT"
  fi
  [ -d "$childwt" ] || fail "force teardown removed repo descendant worktree"
  [ -d "$subhome" ] || fail "force teardown removed subhome after repo child validation refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after repo child validation refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after repo child validation refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before repo child validation refusal"
  grep -F 'inside the firstmate repo' "$err" >/dev/null || fail "force teardown did not explain repo descendant rejection"
  pass "force teardown refuses child worktrees inside the firstmate repo"
}

test_secondmate_force_teardown_refuses_unregistered_child_worktree() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/unregistered-child-home"
  subhome="$TMP_ROOT/unregistered-child-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/unregistered-child-worktree"
  err="$TMP_ROOT/unregistered-child.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj" "$childwt"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/unregistered-child-fake")
  log="$TMP_ROOT/unregistered-child-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/unregistered-child-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed an unregistered child worktree"
  fi
  [ -d "$childwt" ] || fail "force teardown removed unregistered child worktree"
  [ -d "$subhome" ] || fail "force teardown removed subhome after unregistered child refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after unregistered child refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after unregistered child refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before unregistered child refusal"
  grep -F 'is not a git worktree for' "$err" >/dev/null || fail "force teardown did not explain unregistered child rejection"
  pass "force teardown refuses unregistered child worktree paths"
}

test_secondmate_idle_pane_is_not_stale() {
  local home fakebin out pid window
  home="$TMP_ROOT/watch-home"
  mkdir -p "$home/state"
  window="firstmate:fm-domain"
  cat > "$home/state/domain.meta" <<EOF
window=$window
worktree=$TMP_ROOT/watch-subhome
project=$TMP_ROOT/watch-subhome
harness=echo
kind=secondmate
home=$TMP_ROOT/watch-subhome
projects=alpha
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/watch-fake")
  out="$TMP_ROOT/watch-fake/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_LOG="$TMP_ROOT/watch-fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/watch-fake/pane.txt" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  if ! wait_live "$pid" 25; then
    wait "$pid" || true
    grep -F "stale: $window" "$out" >/dev/null && fail "idle secondmate pane triggered stale wake"
    fail "watcher exited unexpectedly while supervising idle secondmate"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -F "stale: $window" "$out" >/dev/null && fail "idle secondmate pane triggered stale wake"
  pass "idle kind=secondmate pane is healthy and not stale"
}

test_secondmate_charter_brief_is_idle_by_default() {
  local home brief
  home="$TMP_ROOT/idle-charter-home"
  mkdir -p "$home/data" "$home/state"
  scaffold_secondmate_charter "$home" idle-sm 'feature work for alpha' alpha
  brief="$home/data/idle-sm/brief.md"
  [ -f "$brief" ] || fail "secondmate charter brief was not scaffolded"
  # Idle contract: waits for routed work, never self-initiates.
  grep -F 'go idle and wait silently for the main firstmate' "$brief" >/dev/null \
    || fail "charter brief does not tell the secondmate to go idle and wait for routed work"
  grep -F 'Act only on tasks the main firstmate routes to you' "$brief" >/dev/null \
    || fail "charter brief does not restrict work to routed tasks"
  grep -F 'never spawn a survey, audit, or any self-directed' "$brief" >/dev/null \
    || fail "charter brief does not forbid self-initiated survey/audit work"
  # Reconcile-on-startup must remain: bootstrap and recovery still run, scoped to own work.
  grep -F 'run normal firstmate bootstrap and recovery' "$brief" >/dev/null \
    || fail "charter brief dropped the bootstrap/recovery reconciliation step"
  grep -F 'only to RECONCILE work that is already yours' "$brief" >/dev/null \
    || fail "charter brief does not scope startup work to reconciling existing work"
  # Regression guard: the over-broad phrasing that got misread as "go find work" is gone.
  if grep -F 'then supervise work that matches your scope' "$brief" >/dev/null; then
    fail "charter brief still uses the over-broad 'supervise work that matches your scope' phrasing"
  fi
  pass "secondmate charter brief is idle by default and does not self-initiate work"
}

test_backlog_handoff_aborts_safely() {
  # The happy move (verbatim into the Queued section, out-of-scope left alone,
  # idempotent re-run) is asserted in the lifecycle e2e. Here: every refusal path
  # aborts atomically and mutates neither backlog.
  local home subhome subhome_abs before
  home="$TMP_ROOT/handoff-main"
  subhome="$TMP_ROOT/handoff-sub"
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$subhome" design
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-06-22)\n' "$subhome_abs" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] live-task - active work (repo: alpha, since 2026-06-20)

## Queued
- [ ] bug-z - fix bug z (repo: gamma)

## Done
- [x] old-task - shipped thing - local main (merged 2026-06-19)
EOF

  # A key matching neither backlog aborts atomically: nothing moves.
  before=$(cat "$home/data/backlog.md")
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design bug-z no-such-key >/dev/null 2>&1; then
    fail "handoff succeeded despite an unmatched key"
  fi
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "handoff with an unmatched key still mutated the main backlog"
  grep -F 'bug-z' "$home/data/backlog.md" >/dev/null || fail "atomic abort lost the valid bug-z item"

  # An in-flight item is refused (active ownership lives in tmux + state too).
  before=$(cat "$home/data/backlog.md")
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design live-task >/dev/null 2>&1; then
    fail "handoff accepted an in-flight backlog item"
  fi
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "handoff with an in-flight key mutated the main backlog"
  grep -F 'live-task' "$home/data/backlog.md" >/dev/null || fail "in-flight refusal lost the live task"
  [ ! -e "$subhome/data/backlog.md" ] || ! grep -F 'live-task' "$subhome/data/backlog.md" >/dev/null     || fail "in-flight refusal copied the live task into the secondmate backlog"

  # An unregistered secondmate id is refused.
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" ghost bug-z >/dev/null 2>&1; then
    fail "handoff accepted an unregistered secondmate id"
  fi
  pass "fm-backlog-handoff aborts atomically on unmatched, in-flight, and unregistered targets"
}

test_backlog_handoff_creates_absent_section_and_refuses_non_secondmate_home() {
  local home subhome subhome_abs projhome projhome_abs markerhome markerhome_abs symlinkhome symlinkhome_abs outside
  home="$TMP_ROOT/handoff-safety-main"
  subhome="$TMP_ROOT/handoff-safety-sub"
  projhome="$TMP_ROOT/handoff-safety-proj"
  markerhome="$TMP_ROOT/handoff-safety-marker"
  symlinkhome="$TMP_ROOT/handoff-safety-symlink"
  outside="$TMP_ROOT/handoff-safety-outside"
  mkdir -p "$home/data" "$home/state"

  # A Done item handed into a secondmate backlog lacking a Done section gets one.
  seed_secondmate_home_marker "$subhome" archive
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '## Queued\n- [ ] keep-me - stays (repo: alpha)\n' > "$subhome/data/backlog.md"
  printf -- '- archive - archival (home: %s; scope: archival; projects: alpha; added 2026-06-22)\n' "$subhome_abs" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Done
- [x] shipped-task - shipped thing - local main (merged 2026-06-19)
EOF
  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" archive shipped-task >/dev/null \
    || fail "handoff of a Done item failed"
  grep -F '## Done' "$subhome/data/backlog.md" >/dev/null \
    || fail "handoff did not create the missing Done section in the secondmate backlog"
  awk '/^## Done/{d=1;next} /^## /{d=0} d && /shipped-task/{found=1} END{exit found?0:1}' "$subhome/data/backlog.md" \
    || fail "Done item did not land under the created Done section"
  grep -F 'keep-me' "$subhome/data/backlog.md" >/dev/null || fail "handoff clobbered the existing secondmate backlog content"

  # A registered home that is not a seeded secondmate home (e.g. a project clone)
  # is refused, and nothing is written into it.
  fm_git_init_commit "$projhome"
  projhome_abs=$(cd "$projhome" && pwd -P)
  printf -- '- proj-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$projhome_abs" >> "$home/data/secondmates.md"
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" proj-sm shipped-task >/dev/null 2>&1; then
    fail "handoff wrote into a destination that is not a seeded secondmate home"
  fi
  [ ! -e "$projhome/data/backlog.md" ] || fail "handoff created a backlog inside a non-secondmate home"

  mkdir -p "$markerhome/data"
  markerhome_abs=$(cd "$markerhome" && pwd -P)
  printf 'marker-sm\n' > "$markerhome/.fm-secondmate-home"
  printf -- '- marker-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$markerhome_abs" >> "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] marker-task - should not move (repo: alpha)
EOF
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" marker-sm marker-task >/dev/null 2>&1; then
    fail "handoff accepted a marker-only directory as a secondmate home"
  fi
  [ ! -e "$markerhome/data/backlog.md" ] || fail "handoff wrote into a marker-only directory"
  grep -F 'marker-task' "$home/data/backlog.md" >/dev/null || fail "marker-only refusal lost the main backlog item"

  seed_secondmate_home_marker "$symlinkhome" symlink-sm
  symlinkhome_abs=$(cd "$symlinkhome" && pwd -P)
  mkdir -p "$outside"
  rm -rf "$symlinkhome/data"
  ln -s "$outside" "$symlinkhome/data"
  printf -- '- symlink-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$symlinkhome_abs" >> "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] symlink-task - should not move (repo: alpha)
EOF
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" symlink-sm symlink-task >/dev/null 2>&1; then
    fail "handoff accepted a secondmate home with data outside the home"
  fi
  [ ! -e "$outside/backlog.md" ] || fail "handoff wrote through a symlinked secondmate data directory"
  grep -F 'symlink-task' "$home/data/backlog.md" >/dev/null || fail "symlink refusal lost the main backlog item"
  pass "fm-backlog-handoff creates absent sections and refuses unsafe homes"
}

test_fm_home_parameterization
test_lock_status_is_per_home
test_seed_allows_overlapping_clones_and_drops_owner
test_home_seed_validate_rejects_duplicate_homes
test_home_seed_validate_rejects_duplicate_ids
test_home_seed_validate_rejects_nested_homes
test_home_seed_uses_treehouse_acquired_home
test_home_seed_returns_treehouse_acquired_home_on_assignment_failure
test_home_seed_warns_when_acquired_home_return_fails
test_home_seed_does_not_return_unsafe_acquired_home
test_home_seed_rolls_back_failed_clone
test_home_seed_refuses_missing_filled_charter
test_home_seed_refuses_placeholder_charter
test_home_seed_refuses_empty_charter_fields
test_home_seed_no_projects_end_to_end
test_home_seed_refuses_projectful_reused_charter_for_projectless_home
test_home_seed_refuses_projectless_conversion_of_populated_home
test_home_seed_refuses_projectless_home_with_uninspectable_projects
test_home_seed_refuses_projectless_home_with_symlinked_projects
test_home_seed_refuses_projectless_home_with_non_directory_projects
test_home_seed_refuses_projectless_home_with_uninspectable_registry
test_home_seed_refuses_missing_projects_without_signal
test_home_seed_refuses_local_only_project
test_home_seed_refuses_registry_delimiter_home
test_home_seed_refuses_active_home_and_root
test_home_seed_refuses_home_marked_for_another_id
test_home_seed_refuses_home_registered_to_another_id
test_home_seed_refuses_reassigning_existing_id_to_different_home
test_home_seed_refuses_home_overlapping_registered_home
test_home_seed_refuses_remote_backed_project_without_origin
test_home_seed_refuses_existing_remote_backed_project_with_wrong_origin
test_home_seed_resolves_relative_source_origins
test_home_seed_skips_initialized_existing_no_mistakes_projects
test_home_seed_refuses_uninitialized_existing_no_mistakes_project
test_home_seed_refuses_project_destinations_outside_subhome
test_home_seed_refuses_operational_dirs_outside_subhome
test_home_seed_refuses_symlinked_leaf_files
test_secondmate_spawn_requires_seeded_matching_home
test_secondmate_spawn_refuses_operational_dirs_outside_subhome
test_fm_send_refuses_bare_window_without_home_meta
test_secondmate_teardown_retires_empty_home
test_secondmate_teardown_refuses_failed_leased_home_return
test_secondmate_teardown_removes_plain_clone_home_without_treehouse_return
test_secondmate_force_teardown_discards_child_work
test_secondmate_force_teardown_preserves_child_on_unproven_lock
test_secondmate_force_teardown_allows_operational_dir_symlinks_inside_home
test_secondmate_force_teardown_refuses_operational_dir_symlink_outside_home
test_secondmate_teardown_refuses_registered_nested_home
test_secondmate_teardown_refuses_child_registry_nested_home
test_secondmate_force_teardown_prevalidates_before_child_cleanup
test_secondmate_force_teardown_refuses_child_active_home_descendant
test_secondmate_force_teardown_refuses_child_repo_descendant
test_secondmate_force_teardown_refuses_unregistered_child_worktree
test_secondmate_teardown_path_boundary_matrix
test_secondmate_idle_pane_is_not_stale
test_secondmate_charter_brief_is_idle_by_default
test_backlog_handoff_aborts_safely
test_backlog_handoff_creates_absent_section_and_refuses_non_secondmate_home
