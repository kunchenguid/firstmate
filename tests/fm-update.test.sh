#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# Build an opt-in private-distribution world with distinct public and private
# bare remotes, a clean running clone of private main, strict remote roles, and
# the local config/private-upstream declaration.
# The validation entrypoints are fixture-owned executable interfaces so the
# production updater exercises its real lint/test orchestration without running
# this repository's complete suite recursively from inside this test.
new_private_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/public.git"
  git -C "$w/public.git" symbolic-ref HEAD refs/heads/main
  git init -q --bare "$w/private.git"
  git -C "$w/private.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/public.git" "$w/public-seed" 2>/dev/null

  printf 'base\n' > "$w/public-seed/AGENTS.md"
  printf 'base\n' > "$w/public-seed/README.md"
  mkdir -p "$w/public-seed/bin"
  cat > "$w/public-seed/bin/fm-lint.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ ! -e FAIL_LINT ]
SH
  cat > "$w/public-seed/bin/fm-test-run.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = --all ]
[ ! -e FAIL_TESTS ]
SH
  chmod +x "$w/public-seed/bin/fm-lint.sh" "$w/public-seed/bin/fm-test-run.sh"
  git -C "$w/public-seed" add -A
  git -C "$w/public-seed" commit -qm base
  git -C "$w/public-seed" push -q origin main
  git -C "$w/public-seed" remote add private "$w/private.git"
  git -C "$w/public-seed" push -q private main

  git clone -q "$w/private.git" "$w/main"
  git -C "$w/main" remote add upstream "$w/public.git"
  git -C "$w/main" remote set-url --push upstream no_push://read-only
  {
    printf 'private-origin-url=%s/private.git\n' "$w"
    printf 'public-upstream=upstream/main\n'
    printf 'public-upstream-url=%s/public.git\n' "$w"
  } > "$w/home/config/private-upstream"

  printf '%s\n' "$w"
}

run_private_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_STATE_OVERRIDE="$w/home/state" FM_CONFIG_OVERRIDE="$w/home/config" \
    "$UPDATE"
}

bump_public_file() {
  local w=$1 file=$2 value=$3 message=$4
  printf '%s\n' "$value" > "$w/public-seed/$file"
  git -C "$w/public-seed" add -A
  git -C "$w/public-seed" commit -qm "$message"
  git -C "$w/public-seed" push -q origin main
}

commit_private_running() {
  local w=$1 file=$2 value=$3 message=$4
  printf '%s\n' "$value" > "$w/main/$file"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm "$message"
  git -C "$w/main" push -q origin main
}

latest_private_evidence() {
  local w=$1
  find "$w/home/state/private-update-evidence" -mindepth 1 -maxdepth 1 \
    -type d -name 'run.*' 2>/dev/null | sort | tail -1
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

# --- P1: private personal commit + public advance integrate and publish -----
test_private_update_success_preserves_personal_history() {
  local w out personal public published
  w=$(new_private_world p1)
  commit_private_running "$w" PRIVATE.md personal private-personal
  personal=$(git -C "$w/main" rev-parse HEAD)
  bump_public_file "$w" UPSTREAM.md public public-update
  public=$(git --git-dir="$w/public.git" rev-parse refs/heads/main)

  out=$(run_private_update "$w" 2>&1)
  published=$(git --git-dir="$w/private.git" rev-parse refs/heads/main)

  assert_contains "$out" "private-upstream: published " "private integration published"
  assert_contains "$out" "from upstream/main" "public source named"
  assert_contains "$out" "firstmate: updated " "running copy fast-forwarded only after publication"
  git --git-dir="$w/private.git" merge-base --is-ancestor "$personal" "$published" \
    || fail "private personal commit was not preserved"
  git --git-dir="$w/private.git" merge-base --is-ancestor "$public" "$published" \
    || fail "public upstream commit was not incorporated"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$published" ] \
    || fail "running firstmate did not fast-forward to validated private main"
  [ -z "$(latest_private_evidence "$w")" ] \
    || fail "successful disposable integration clone was not removed"
  pass "P1 private update preserves personal history, publishes, then fast-forwards running main"
}

# --- P2: upstream already contained by private main is an idempotent no-op --
test_private_update_noop() {
  local w out before
  w=$(new_private_world p2)
  before=$(git --git-dir="$w/private.git" rev-parse refs/heads/main)

  out=$(run_private_update "$w" 2>&1)

  assert_contains "$out" "private-upstream: already current at" "private no-op reported"
  assert_contains "$out" "firstmate: already current" "legacy fast-forward still runs after private no-op"
  [ "$(git --git-dir="$w/private.git" rev-parse refs/heads/main)" = "$before" ] \
    || fail "private main moved during a no-op"
  [ -z "$(latest_private_evidence "$w")" ] \
    || fail "no-op disposable clone was not removed"
  pass "P2 private update no-op leaves both private and running main unchanged"
}

# --- P3: dirty running copy stops before integration -----------------------
test_private_update_dirty_copy_stops() {
  local w out status before
  w=$(new_private_world p3)
  bump_public_file "$w" UPSTREAM.md public public-update
  before=$(git --git-dir="$w/private.git" rev-parse refs/heads/main)
  printf 'dirty\n' >> "$w/main/README.md"

  out=$(run_private_update "$w" 2>&1); status=$?

  expect_code 1 "$status" "dirty private update"
  assert_contains "$out" "running firstmate has a dirty working tree" "dirty copy refusal explained"
  grep -q '^dirty$' "$w/main/README.md" || fail "dirty running edit was lost"
  [ "$(git --git-dir="$w/private.git" rev-parse refs/heads/main)" = "$before" ] \
    || fail "dirty-copy refusal changed private main"
  pass "P3 dirty running copy stops before private integration and remains untouched"
}

# --- P4: unpushed/diverged running main is preserved and reported ----------
test_private_update_divergence_stops() {
  local w out status before running evidence
  w=$(new_private_world p4)
  bump_public_file "$w" UPSTREAM.md public public-update
  before=$(git --git-dir="$w/private.git" rev-parse refs/heads/main)
  printf 'local-only\n' > "$w/main/LOCAL.md"
  git -C "$w/main" add LOCAL.md
  git -C "$w/main" commit -qm local-unpushed
  running=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_private_update "$w" 2>&1); status=$?
  evidence=$(latest_private_evidence "$w")

  expect_code 1 "$status" "diverged private update"
  assert_contains "$out" "running main has commits not present on private origin/main" "divergence refusal explained"
  [ -d "$evidence/repo" ] || fail "divergence evidence clone was not preserved"
  [ "$(git --git-dir="$w/private.git" rev-parse refs/heads/main)" = "$before" ] \
    || fail "divergence refusal changed private main"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$running" ] \
    || fail "divergence refusal moved running main"
  pass "P4 diverged running main stops with inspectable evidence and no history change"
}

# --- P5: merge conflict preserves the disposable conflict evidence ---------
test_private_update_merge_conflict_stops() {
  local w out status before running evidence unresolved
  w=$(new_private_world p5)
  commit_private_running "$w" README.md private private-conflict-side
  running=$(git -C "$w/main" rev-parse HEAD)
  before=$(git --git-dir="$w/private.git" rev-parse refs/heads/main)
  bump_public_file "$w" README.md public public-conflict-side

  out=$(run_private_update "$w" 2>&1); status=$?
  evidence=$(latest_private_evidence "$w")
  unresolved=$(git -C "$evidence/repo" diff --name-only --diff-filter=U)

  expect_code 1 "$status" "conflicting private update"
  assert_contains "$out" "merge conflict while integrating upstream/main" "merge conflict explained"
  assert_contains "$unresolved" "README.md" "conflicted file remains inspectable"
  [ "$(git --git-dir="$w/private.git" rev-parse refs/heads/main)" = "$before" ] \
    || fail "merge conflict changed private main"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$running" ] \
    || fail "merge conflict moved running main"
  pass "P5 merge conflict preserves evidence and leaves both main refs unchanged"
}

# --- P6: failed validation blocks publication and preserves logs -----------
test_private_update_failed_validation_stops() {
  local w out status before running evidence
  w=$(new_private_world p6)
  before=$(git --git-dir="$w/private.git" rev-parse refs/heads/main)
  running=$(git -C "$w/main" rev-parse HEAD)
  bump_public_file "$w" FAIL_TESTS fail public-breaks-validation

  out=$(run_private_update "$w" 2>&1); status=$?
  evidence=$(latest_private_evidence "$w")

  expect_code 1 "$status" "validation-failing private update"
  assert_contains "$out" "test suite failed" "failed validation explained"
  [ -f "$evidence/validation.log" ] || fail "validation log was not preserved"
  [ "$(git --git-dir="$w/private.git" rev-parse refs/heads/main)" = "$before" ] \
    || fail "failed validation changed private main"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$running" ] \
    || fail "failed validation moved running main"
  pass "P6 failed validation preserves logs and blocks private publication"
}

# --- P7: swapped public/private roles fail before any network integration --
test_private_update_wrong_remote_roles_stop() {
  local w out status before out_pushable status_pushable
  w=$(new_private_world p7)
  before=$(git --git-dir="$w/private.git" rev-parse refs/heads/main)
  git -C "$w/main" remote set-url origin "$w/public.git"

  out=$(run_private_update "$w" 2>&1); status=$?

  expect_code 1 "$status" "wrong-role private update"
  assert_contains "$out" "origin fetch URL does not match private-origin-url" "wrong origin role explained"
  [ "$(git --git-dir="$w/private.git" rev-parse refs/heads/main)" = "$before" ] \
    || fail "wrong remote role changed private main"
  [ -z "$(latest_private_evidence "$w")" ] \
    || fail "wrong remote role performed network integration"

  git -C "$w/main" remote set-url origin "$w/private.git"
  git -C "$w/main" config --unset-all remote.upstream.pushurl
  out_pushable=$(run_private_update "$w" 2>&1); status_pushable=$?

  expect_code 1 "$status_pushable" "pushable-public-remote private update"
  assert_contains "$out_pushable" "upstream push URL must be no_push://read-only" \
    "pushable public upstream refusal explained"
  [ "$(git --git-dir="$w/private.git" rev-parse refs/heads/main)" = "$before" ] \
    || fail "pushable public upstream changed private main"
  [ -z "$(latest_private_evidence "$w")" ] \
    || fail "pushable public upstream performed network integration"
  pass "P7 wrong private/public roles and a pushable public remote both fail before integration"
}

# --- P8: rejected private push keeps validated result as evidence ----------
test_private_update_push_failure_stops() {
  local w out status before running evidence
  w=$(new_private_world p8)
  before=$(git --git-dir="$w/private.git" rev-parse refs/heads/main)
  running=$(git -C "$w/main" rev-parse HEAD)
  bump_public_file "$w" UPSTREAM.md public public-update
  cat > "$w/private.git/hooks/pre-receive" <<'SH'
#!/usr/bin/env bash
echo 'private push rejected for test' >&2
exit 1
SH
  chmod +x "$w/private.git/hooks/pre-receive"

  out=$(run_private_update "$w" 2>&1); status=$?
  evidence=$(latest_private_evidence "$w")

  expect_code 1 "$status" "push-failing private update"
  assert_contains "$out" "push to private origin/main failed" "push failure explained"
  assert_contains "$(cat "$evidence/push.log")" "private push rejected for test" "push evidence preserved"
  [ "$(git --git-dir="$w/private.git" rev-parse refs/heads/main)" = "$before" ] \
    || fail "rejected push changed private main"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$running" ] \
    || fail "rejected push moved running main"
  pass "P8 private push failure preserves validated evidence and leaves running main unchanged"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_private_update_success_preserves_personal_history
test_private_update_noop
test_private_update_dirty_copy_stops
test_private_update_divergence_stops
test_private_update_merge_conflict_stops
test_private_update_failed_validation_stops
test_private_update_wrong_remote_roles_stop
test_private_update_push_failure_stops

echo "# all fm-update tests passed"
