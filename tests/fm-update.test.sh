#!/usr/bin/env bash
# Tests for bin/fm-update.sh: per-home self-update of a running firstmate repo
# and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - The absent/default policy remains fast-forward-only: a dirty, diverged,
#     offline, or wrong-branch target is skipped and reported unchanged.
#   - An exact home's explicit remote-authoritative policy may replace dirty or
#     diverged tracked code only after a successful origin/default fetch, while
#     preserving ignored/private paths and unrelated untracked files.
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
REMOTE_CONTROL="$ROOT/bin/fm-remote-secondmate-control.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  cat > "$w/seed/.gitignore" <<'EOF'
projects/
state/
data/
.no-mistakes/
.env
config/
.fm-secondmate-home
EOF
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

add_remote_home() {
  local w=$1 id=$2
  git clone -q "$w/origin.git" "$w/remote-$id"
  git -C "$w/remote-$id" checkout -q --detach HEAD
  printf '%s\n' "$id" > "$w/remote-$id/.fm-secondmate-home"
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

run_update_root_home() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/main" "$UPDATE" 2>/dev/null
}

enable_remote_authoritative() {
  local home=$1
  mkdir -p "$home/config"
  printf 'remote-authoritative\n' > "$home/config/self-update-policy"
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

# --- Explicit per-home remote-authoritative policy --------------------------

test_default_diverged_firstmate_is_skipped() {
  local w out before
  w=$(new_world t12)
  printf 'local-only\n' > "$w/main/AGENTS.md"
  git -C "$w/main" add AGENTS.md
  git -C "$w/main" commit -qm local-only
  before=$(git -C "$w/main" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: diverged from origin/main" "default diverged firstmate skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "default diverged firstmate HEAD moved"
  [ "$(cat "$w/main/AGENTS.md")" = "local-only" ] || fail "default diverged firstmate content changed"
  pass "T12 absent policy preserves the diverged firstmate"
}

test_opted_diverged_firstmate_is_replaced() {
  local w out remote_head local_head
  w=$(new_world t13)
  printf 'local-only\n' > "$w/main/AGENTS.md"
  git -C "$w/main" add AGENTS.md
  git -C "$w/main" commit -qm local-only
  local_head=$(git -C "$w/main" rev-parse HEAD)
  bump_origin "$w" instr
  remote_head=$(git -C "$w/seed" rev-parse HEAD)
  enable_remote_authoritative "$w/home"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: replaced " "opted diverged firstmate replacement is distinct"
  assert_contains "$out" "remote-authoritative" "replacement reports its policy"
  assert_contains "$out" "reread-firstmate: yes" "replacement of instructions triggers reread"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$remote_head" ] || fail "opted firstmate did not reset exactly to origin"
  ! git -C "$w/main" merge-base --is-ancestor "$local_head" HEAD 2>/dev/null \
    || fail "discarded local-only commit remained in opted firstmate history"
  [ "$(cat "$w/main/AGENTS.md")" = "v2" ] || fail "remote instruction content did not replace local commit"
  pass "T13 opted diverged firstmate resets exactly to origin"
}

test_opted_dirty_and_obstructed_replacement_preserves_private_files() {
  local w out remote_head
  w=$(new_world t14)
  enable_remote_authoritative "$w/main"
  mkdir -p "$w/main/data" "$w/main/state" "$w/main/projects/repo" "$w/main/.no-mistakes"
  printf 'secret\n' > "$w/main/.env"
  printf 'policy-private\n' > "$w/main/config/private"
  printf 'durable\n' > "$w/main/data/private"
  printf 'volatile\n' > "$w/main/state/private"
  printf 'project-data\n' > "$w/main/projects/repo/private"
  printf 'evidence\n' > "$w/main/.no-mistakes/private"
  printf 'local dirty instruction\n' > "$w/main/AGENTS.md"
  printf 'unrelated\n' > "$w/main/local-note.txt"

  bump_origin "$w" instr
  printf 'remote tool\n' > "$w/seed/bin/new-tool"
  git -C "$w/seed" add bin/new-tool
  git -C "$w/seed" commit -qm add-new-tool
  git -C "$w/seed" push -q origin main
  remote_head=$(git -C "$w/seed" rev-parse HEAD)
  printf 'obstructing local file\n' > "$w/main/bin/new-tool"

  out=$(run_update_root_home "$w")

  assert_contains "$out" "firstmate: replaced " "dirty opted firstmate replaced"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$remote_head" ] || fail "dirty opted target did not reach origin"
  [ "$(cat "$w/main/AGENTS.md")" = "v2" ] || fail "dirty tracked instruction survived replacement"
  [ "$(cat "$w/main/bin/new-tool")" = "remote tool" ] || fail "obstructing untracked file was not replaced"
  [ "$(cat "$w/main/local-note.txt")" = "unrelated" ] || fail "unrelated non-ignored untracked file was deleted"
  [ "$(cat "$w/main/.env")" = "secret" ] || fail ".env was not preserved"
  [ "$(cat "$w/main/config/self-update-policy")" = "remote-authoritative" ] || fail "policy file was not preserved"
  [ "$(cat "$w/main/config/private")" = "policy-private" ] || fail "private config was not preserved"
  [ "$(cat "$w/main/data/private")" = "durable" ] || fail "data was not preserved"
  [ "$(cat "$w/main/state/private")" = "volatile" ] || fail "state was not preserved"
  [ "$(cat "$w/main/projects/repo/private")" = "project-data" ] || fail "project repository surface was touched"
  [ "$(cat "$w/main/.no-mistakes/private")" = "evidence" ] || fail "no-mistakes evidence was not preserved"
  pass "T14 opted dirty replacement handles obstruction and preserves every private surface"
}

test_ignored_obstruction_is_never_deleted() {
  local w out before
  w=$(new_world t15)
  enable_remote_authoritative "$w/main"
  printf 'generated\n' >> "$w/main/.gitignore"
  printf 'ignored private obstruction\n' > "$w/main/generated"
  before=$(git -C "$w/main" rev-parse HEAD)

  mkdir -p "$w/seed/generated"
  printf 'remote tracked file\n' > "$w/seed/generated/tool"
  git -C "$w/seed" add -f generated/tool
  git -C "$w/seed" commit -qm add-generated-tool
  git -C "$w/seed" push -q origin main

  out=$(run_update_root_home "$w")

  assert_contains "$out" "firstmate: skipped: ignored path obstructs remote-authoritative replacement" \
    "ignored obstruction is reported before reset"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "ignored obstruction moved HEAD"
  [ "$(cat "$w/main/generated")" = "ignored private obstruction" ] || fail "ignored obstruction was deleted"
  grep -qx generated "$w/main/.gitignore" || fail "tracked ignore rule was discarded"
  pass "T15 ignored obstruction is preserved rather than reset away"
}

test_opted_fetch_failure_discards_nothing() {
  local w out before
  w=$(new_world t18)
  enable_remote_authoritative "$w/main"
  printf 'dirty local instruction\n' > "$w/main/AGENTS.md"
  before=$(git -C "$w/main" rev-parse HEAD)
  git -C "$w/main" remote set-url origin "$w/missing-origin.git"

  out=$(run_update_root_home "$w")

  assert_contains "$out" "firstmate: skipped: fetch failed" "fetch failure is reported"
  assert_contains "$out" "reread-firstmate: no" "failed fetch does not trigger reread"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "fetch failure moved HEAD"
  [ "$(cat "$w/main/AGENTS.md")" = "dirty local instruction" ] || fail "fetch failure discarded tracked work"
  pass "T18 remote failure discards nothing"
}

test_primary_opt_in_does_not_flow_to_secondmate() {
  local w out sm_before
  w=$(new_world t16)
  add_sm "$w" sm1
  printf 'secondmate local commit\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add AGENTS.md
  git -C "$w/sm1" commit -qm secondmate-local
  sm_before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr
  enable_remote_authoritative "$w/home"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: replaced " "primary used its own opt-in"
  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "non-opted secondmate remains guarded"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$sm_before" ] || fail "primary opt-in moved non-opted secondmate"
  [ "$(cat "$w/sm1/AGENTS.md")" = "secondmate local commit" ] || fail "primary opt-in discarded secondmate content"
  pass "T16 primary opt-in does not flow to a secondmate"
}

test_remote_secondmate_policy_is_independent() {
  local w out rc before remote_head
  w=$(new_world t19)
  add_remote_home "$w" rem
  printf 'remote-home local commit\n' > "$w/remote-rem/AGENTS.md"
  git -C "$w/remote-rem" add AGENTS.md
  git -C "$w/remote-rem" commit -qm remote-home-local
  before=$(git -C "$w/remote-rem" rev-parse HEAD)
  bump_origin "$w" instr

  set +e
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/remote-rem" "$REMOTE_CONTROL" update rem 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "non-opted remote secondmate unexpectedly accepted replacement"
  assert_contains "$out" "not a fast-forward" "non-opted remote secondmate remains guarded"
  [ "$(git -C "$w/remote-rem" rev-parse HEAD)" = "$before" ] || fail "non-opted remote secondmate HEAD moved"

  enable_remote_authoritative "$w/remote-rem"
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/remote-rem" "$REMOTE_CONTROL" update rem 2>&1)
  remote_head=$(git -C "$w/seed" rev-parse HEAD)
  assert_contains "$out" "replaced: $remote_head" "remote secondmate own opt-in is honored"
  [ "$(git -C "$w/remote-rem" rev-parse HEAD)" = "$remote_head" ] || fail "opted remote secondmate did not reach origin"
  pass "T19 remote secondmate policy is independent and default-safe"
}

test_secondmate_independent_opt_in_is_honored() {
  local w out remote_head
  w=$(new_world t17)
  add_sm "$w" sm1
  printf 'secondmate local commit\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add AGENTS.md
  git -C "$w/sm1" commit -qm secondmate-local
  bump_origin "$w" instr
  remote_head=$(git -C "$w/seed" rev-parse HEAD)
  enable_remote_authoritative "$w/sm1"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: replaced " "secondmate own opt-in is honored"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "replaced live secondmate is nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$remote_head" ] || fail "opted secondmate did not reach origin"
  pass "T17 a secondmate opts in independently"
}

# --- Existing unsafe-home guard --------------------------------------------

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

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_default_diverged_firstmate_is_skipped
test_opted_diverged_firstmate_is_replaced
test_opted_dirty_and_obstructed_replacement_preserves_private_files
test_ignored_obstruction_is_never_deleted
test_opted_fetch_failure_discards_nothing
test_primary_opt_in_does_not_flow_to_secondmate
test_remote_secondmate_policy_is_independent
test_secondmate_independent_opt_in_is_honored
test_unsafe_secondmate_home_skipped_before_git_update

echo "# all fm-update tests passed"
