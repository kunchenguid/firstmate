#!/usr/bin/env bash
# Behavior tests for fm-spawn's CONTINUE/RESUME provisioning mode
# (bin/fm-spawn.sh --resume-worktree, authenticated by
# bin/fm-worktree-identity.sh and honoured by bin/fm-teardown.sh).
#
# The mode dispatches a fresh worker into an existing worktree firstmate did not
# create, for work whose value is the state already sitting there. So the whole
# suite is organised around one question: does a resume AUTHENTICATE that
# workspace and leave it alone, or does it PROVISION over it?
#
# Two choices are worth explaining up front.
#
# The `git` shim. Case 10 has to prove that no reset, clean, stash, rebase,
# checkout, pull, merge or worktree mutation happens. Asserting only on end
# state would pass a path that ran `git reset --hard` onto an identical commit,
# or that raced one in and out. So every case runs the real spawn with a git
# wrapper first on PATH that records the resolved subcommand of each invocation
# and then execs the real git. The assertion is over what was ISSUED.
#
# The fingerprint as a measuring instrument. Cases 15 and 16 need "this
# directory is byte-for-byte what it was". bin/fm-worktree-identity.sh already
# computes exactly that digest over HEAD, staged, unstaged and untracked state,
# through its public CLI, so the suite reuses it rather than rolling a weaker
# comparison of its own.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
IDENTITY="$ROOT/bin/fm-worktree-identity.sh"
GUARD="$ROOT/bin/fm-subagent-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-resume-worktree)

GIT_REAL=$(command -v git) || fail "the suite needs a real git on PATH"

# Every git write verb a resume must never issue. `worktree` covers add, remove
# and prune together, which is what the contract forbids as a group.
FORBIDDEN_GIT_VERBS='reset clean stash rebase checkout switch pull merge branch worktree commit apply restore am cherry-pick revert'

# make_git_shim <fakebin>
# Records the RESOLVED subcommand of each git call (one per line) to FM_GIT_LOG,
# then execs the real git. Resolving the subcommand rather than grepping raw
# argv is deliberate: a worktree path containing the word "reset" would make a
# raw-argv assertion lie in the direction that hides a real failure.
make_git_shim() {
  local fakebin=$1
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
set -u
args=("\$@")
i=0
sub=
while [ "\$i" -lt "\${#args[@]}" ]; do
  case "\${args[\$i]}" in
    -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix) i=\$((i + 2)); continue ;;
    --*) i=\$((i + 1)); continue ;;
    *) sub=\${args[\$i]}; break ;;
  esac
done
printf '%s\n' "\${sub:-<none>}" >> "\${FM_GIT_LOG:-/dev/null}"
exec "$GIT_REAL" "\$@"
SH
  chmod +x "$fakebin/git"
}

git_fixture() { # commit/branch operations that must NOT reach FM_GIT_LOG
  "$GIT_REAL" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"
}

fingerprint_of() { # <worktree>
  "$IDENTITY" fingerprint "$1"
}

fact_of() { # <worktree> <key>
  "$IDENTITY" facts "$1" | sed -n "s/^$2=//p"
}

# assert_no_forbidden_git <label>
# The whole recorded log must carry no write verb at all. The resume path is
# supposed to issue none, so this is a property assertion, not a filtered one.
assert_no_forbidden_git() {
  local label=$1 verb found
  [ -f "$GIT_LOG" ] || fail "$label: no git invocations were recorded at all, so the shim was bypassed"
  for verb in $FORBIDDEN_GIT_VERBS; do
    found=$(grep -c "^${verb}$" "$GIT_LOG" 2>/dev/null || true)
    [ "${found:-0}" = 0 ] || fail "$label: the resume path issued 'git $verb' $found time(s)"$'\n'"--- recorded git subcommands ---"$'\n'"$(sort -u "$GIT_LOG")"
  done
}

# make_case <name> <id> -> record
# A project primary checkout, two linked worktrees of it (the resume target and
# a sibling for the substitution case), an ordinary non-git directory, and a
# firstmate home.
make_case() {
  local name=$1 id=$2 case_dir home project existing sibling plain fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  existing="$case_dir/existing"
  sibling="$case_dir/sibling"
  plain="$case_dir/plain"

  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  mkdir -p "$plain"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git_fixture -C "$project" add README.md
  git_fixture -C "$project" commit -qm initial
  git_fixture -C "$project" worktree add --quiet --detach "$existing" HEAD
  git_fixture -C "$project" worktree add --quiet --detach "$sibling" HEAD

  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  make_git_shim "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"

  printf '%s\n' "$case_dir|$home|$project|$existing|$sibling|$plain|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR EXISTING_DIR SIBLING_DIR PLAIN_DIR FAKEBIN_DIR <<EOF
$1
EOF
  GIT_LOG="$CASE_DIR/git.log"
  : > "$GIT_LOG"
}

# run_resume <id> <pane-path> [extra fm-spawn args...]
run_resume() {
  local id=$1 pane=$2
  shift 2
  FM_GIT_LOG="$GIT_LOG" fm_test_run_spawn "$HOME_DIR" "$pane" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" --resume-worktree "$EXISTING_DIR" "$@"
}

dirty_the_worktree() { # <worktree>: one staged, one unstaged, one untracked change
  printf 'staged change\n' > "$1/staged.txt"
  git_fixture -C "$1" add staged.txt
  printf 'unstaged change\n' >> "$1/README.md"
  printf 'untracked change\n' > "$1/untracked.txt"
}

# --- 1. resume a clean existing worktree ------------------------------------

test_resume_clean_existing_worktree() {
  local rec id out status
  id=resume-clean-a1
  rec=$(make_case resume-clean "$id")
  read_case "$rec"

  out=$(run_resume "$id" "$EXISTING_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "a clean existing worktree should be resumable"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the resume did not report a successful dispatch"
  assert_contains "$out" "provision=resume" \
    "the success line did not name the continuation provisioning mode"
  assert_grep "worktree=$EXISTING_DIR" "$HOME_DIR/state/$id.meta" \
    "the task record does not name the authenticated worktree"
  assert_grep "provision=resume" "$HOME_DIR/state/$id.meta" \
    "the task record does not record resume provenance"
  assert_grep "resume_dirty=0" "$HOME_DIR/state/$id.meta" \
    "a clean worktree was not recorded as clean"
  assert_no_forbidden_git "resuming a clean worktree"
  pass "a clean existing worktree is resumed without provisioning anything"
}

# --- 2. resume a dirty existing worktree ------------------------------------
# --- 3/4/5. staged, unstaged and untracked content all survive --------------

test_resume_dirty_existing_worktree_preserves_every_change() {
  local rec id out status before after
  id=resume-dirty-b2
  rec=$(make_case resume-dirty "$id")
  read_case "$rec"
  dirty_the_worktree "$EXISTING_DIR"
  before=$(fingerprint_of "$EXISTING_DIR")

  out=$(run_resume "$id" "$EXISTING_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" \
    "a dirty existing worktree must be resumable: hot remediation depends on intentional uncommitted work"$'\n'"$out"
  assert_grep "resume_dirty=1" "$HOME_DIR/state/$id.meta" \
    "the dirty pre-dispatch state was not recorded as provenance"

  # 3. staged changes survive, still staged.
  "$GIT_REAL" -C "$EXISTING_DIR" diff --cached --name-only | grep -qx 'staged.txt' \
    || fail "the resume lost the staged change"
  # 4. unstaged changes survive, still unstaged.
  "$GIT_REAL" -C "$EXISTING_DIR" diff --name-only | grep -qx 'README.md' \
    || fail "the resume lost the unstaged change"
  # 5. untracked files survive, still untracked.
  [ -f "$EXISTING_DIR/untracked.txt" ] || fail "the resume deleted the untracked file"
  "$GIT_REAL" -C "$EXISTING_DIR" ls-files --others --exclude-standard | grep -qx 'untracked.txt' \
    || fail "the resume stopped the untracked file being untracked"

  after=$(fingerprint_of "$EXISTING_DIR")
  [ "$before" = "$after" ] || fail "the resume changed the worktree it was supposed to continue"
  assert_no_forbidden_git "resuming a dirty worktree"
  pass "a dirty existing worktree is resumed with staged, unstaged and untracked state intact"
}

# --- 6. reject a nonexistent path -------------------------------------------

test_reject_nonexistent_path() {
  local rec id out status
  id=resume-missing-c3
  rec=$(make_case resume-missing "$id")
  read_case "$rec"
  EXISTING_DIR="$CASE_DIR/not-here"

  out=$(run_resume "$id" "$CASE_DIR/not-here" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn resumed a path that does not exist"$'\n'"$out"
  assert_contains "$out" "does not exist" "the refusal did not say the path is absent"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused resume still published a task record"
  pass "a nonexistent resume path is refused before anything is provisioned"
}

# --- 7. reject an ordinary directory that is not a git worktree -------------

test_reject_directory_that_is_not_a_worktree() {
  local rec id out status
  id=resume-plain-d4
  rec=$(make_case resume-plain "$id")
  read_case "$rec"
  EXISTING_DIR=$PLAIN_DIR

  out=$(run_resume "$id" "$PLAIN_DIR" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn resumed an ordinary directory"$'\n'"$out"
  assert_contains "$out" "not inside a git worktree" \
    "the refusal did not say the directory is not a git worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused resume still published a task record"
  pass "an ordinary directory that is not a git worktree is refused"
}

# --- 8. reject sibling-worktree substitution --------------------------------
# Sharing a repository, and sharing a branch, must never make two worktrees
# interchangeable. Here the pane lands in the SIBLING while the authorization
# names the target, and the dispatch must refuse rather than adopt it.

test_reject_sibling_worktree_substitution() {
  local rec id out status target_before sibling_before
  id=resume-sibling-e5
  rec=$(make_case resume-sibling "$id")
  read_case "$rec"
  target_before=$(fingerprint_of "$EXISTING_DIR")
  sibling_before=$(fingerprint_of "$SIBLING_DIR")

  # Same repository, same commit, same detached HEAD - and still not the same
  # workspace, because identity is the worktree's own git dir.
  [ "$(fact_of "$EXISTING_DIR" head_commit)" = "$(fact_of "$SIBLING_DIR" head_commit)" ] \
    || fail "the fixture siblings should share a commit, or this case proves nothing"
  [ "$(fact_of "$EXISTING_DIR" repo_common_dir)" = "$(fact_of "$SIBLING_DIR" repo_common_dir)" ] \
    || fail "the fixture siblings should share a repository, or this case proves nothing"
  [ "$(fact_of "$EXISTING_DIR" worktree_git_dir)" != "$(fact_of "$SIBLING_DIR" worktree_git_dir)" ] \
    || fail "two worktrees of one repository must not share an identity"

  out=$(run_resume "$id" "$SIBLING_DIR" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a sibling worktree it was not authorized for"$'\n'"$out"
  assert_contains "$out" "not the authenticated worktree" \
    "the refusal did not say the endpoint was outside the authorized workspace"
  [ "$(fingerprint_of "$EXISTING_DIR")" = "$target_before" ] \
    || fail "the refused substitution changed the authorized worktree"
  [ "$(fingerprint_of "$SIBLING_DIR")" = "$sibling_before" ] \
    || fail "the refused substitution changed the sibling worktree"
  assert_no_forbidden_git "a refused sibling substitution"
  pass "a sibling worktree of the same repository and branch is never substituted for the authorized one"
}

# --- 9. reject an identity change between authentication and dispatch -------
# The window this closes: the path is authenticated before any endpoint exists,
# and the agent starts later. Here the directory at that path is swapped for a
# different worktree in between, which is the rebinding the second fingerprint
# read is for.

test_reject_identity_change_before_launch() {
  local rec id out status swap
  id=resume-rebind-f6
  rec=$(make_case resume-rebind "$id")
  read_case "$rec"

  # Fire from the pane's own launch-time export, which lands after placement has
  # settled and before the pre-launch re-read.
  swap="$CASE_DIR/swap.sh"
  cat > "$swap" <<SH
#!/usr/bin/env bash
mv "$EXISTING_DIR" "$CASE_DIR/authorized-moved-aside"
mv "$SIBLING_DIR" "$EXISTING_DIR"
SH
  chmod +x "$swap"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"export FM_TASK_ID"*) [ -d "$EXISTING_DIR/.git" ] || [ -f "$EXISTING_DIR/.git" ] && "$swap" || true ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/tmux"

  out=$(run_resume "$id" "$EXISTING_DIR" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched after the authorized path was rebound to another worktree"$'\n'"$out"
  assert_contains "$out" "no longer the worktree this spawn authenticated" \
    "the refusal did not identify a rebinding"$'\n'"$out"
  assert_grep "failed:" "$HOME_DIR/state/$id.status" \
    "the rebinding refusal left no durable failure event for firstmate to reconcile"
  assert_no_forbidden_git "a refused rebinding"
  pass "a path rebound to a different worktree between authorization and launch is refused"
}

# --- 10. no reset/clean/stash/rebase/checkout is ever issued -----------------
# Asserted on what was ISSUED, not on end state, so a write that happened to be
# a no-op still fails this case.

test_no_git_write_command_is_issued() {
  local rec id out status verb
  id=resume-nowrite-g7
  rec=$(make_case resume-nowrite "$id")
  read_case "$rec"
  dirty_the_worktree "$EXISTING_DIR"

  out=$(run_resume "$id" "$EXISTING_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "the resume should have launched"$'\n'"$out"

  # The shim must have seen real traffic, or the case is vacuous.
  [ "$(wc -l < "$GIT_LOG")" -gt 0 ] || fail "no git invocation was recorded, so this case proves nothing"
  for verb in $FORBIDDEN_GIT_VERBS; do
    assert_no_grep "$verb" "$GIT_LOG" "the resume path issued the forbidden 'git $verb'"
  done
  # And prove the shim can see a write at all, so the absence above is evidence.
  git_fixture -C "$EXISTING_DIR" status --porcelain >/dev/null
  printf 'reset\n' >> "$GIT_LOG"
  assert_grep "reset" "$GIT_LOG" "the log cannot record a write verb, so case 10 is not measuring anything"
  pass "a resume issues no reset, clean, stash, rebase, checkout, pull, merge or worktree command"
}

# --- 11. the resumed worker is an ordinary supervised task ------------------

test_resumed_worker_is_ordinary_fleet_work() {
  local rec id out status key meta
  id=resume-fleet-h8
  rec=$(make_case resume-fleet "$id")
  read_case "$rec"

  out=$(run_resume "$id" "$EXISTING_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "the resume should have launched"$'\n'"$out"
  meta="$HOME_DIR/state/$id.meta"

  # The record the watcher, wake queue, crew-state reconciliation and teardown
  # all read. A resumed worker that skipped any of these would be a side-agent.
  for key in window endpoint_task_id worktree project harness kind spawn_gen; do
    assert_grep "$key=" "$meta" "the resumed task record is missing $key=, which normal supervision reads"
  done
  assert_grep "endpoint_task_id=$id" "$meta" "the resumed task does not own its endpoint under its own id"
  assert_grep "kind=ship" "$meta" "the resumed task did not record an ordinary ship kind"
  assert_present "$HOME_DIR/data/$id/brief.md" "the resumed task has no brief"
  assert_present "$HOME_DIR/data/$id/launch-brief.md" \
    "the resumed task did not get the ordinary launch-brief overlay"

  # And it reconciles through the ordinary current-state reader.
  local state_line
  state_line=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" "$id" 2>&1) || true
  assert_contains "$state_line" "state:" \
    "the resumed task is not readable by the ordinary crew-state reconciliation"
  pass "a resumed worker participates in normal task supervision rather than becoming a side-agent"
}

# --- 12. provenance distinguishes SPAWN from RESUME -------------------------

test_provenance_distinguishes_spawn_from_resume() {
  local rec id out status fresh_id pool
  id=resume-prov-i9
  rec=$(make_case resume-prov "$id")
  read_case "$rec"

  out=$(run_resume "$id" "$EXISTING_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "the resume should have launched"$'\n'"$out"
  assert_grep "provision=resume" "$HOME_DIR/state/$id.meta" "a resume did not record resume provenance"
  assert_grep "resume_fingerprint=" "$HOME_DIR/state/$id.meta" "a resume recorded no workspace fingerprint"
  assert_grep "resume_head=$(fact_of "$EXISTING_DIR" head_commit)" "$HOME_DIR/state/$id.meta" \
    "a resume did not record the HEAD commit it was authorized against"

  # An ordinary fresh spawn into a pool-shaped worktree must still record
  # nothing, because an ABSENT provision= line is what "spawn" means. That is
  # also what keeps every record written before this mode existed valid.
  fresh_id=fresh-prov-i9
  fm_test_spawn_brief "$HOME_DIR" "$fresh_id"
  pool="$CASE_DIR/pool"
  git_fixture -C "$PROJECT_DIR" worktree add --quiet --detach "$pool" HEAD
  out=$(FM_GIT_LOG="$GIT_LOG" fm_test_run_spawn "$HOME_DIR" "$pool" "$FAKEBIN_DIR" \
    "$fresh_id" "$PROJECT_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "the ordinary fresh spawn should still work"$'\n'"$out"
  assert_no_grep "provision=" "$HOME_DIR/state/$fresh_id.meta" \
    "a fresh spawn recorded a provisioning line; absent must keep meaning spawn"
  assert_not_contains "$out" "provision=resume" \
    "a fresh spawn reported itself as a continuation"
  pass "task provenance tells a fresh spawn apart from a governed resume, with absence meaning spawn"
}

# --- 13/14. the primary-dispatch guard ---------------------------------------
# 13: a governed resume is dispatch through the fleet, so it must not need the
#     delegation escape hatch. 14: arbitrary delegation stays blocked.

test_primary_dispatch_guard_accepts_resume_and_still_blocks_delegation() {
  local rec id out status guard_out guard_status
  id=resume-guard-j1
  rec=$(make_case resume-guard "$id")
  read_case "$rec"

  # 13. The resume runs with the escape hatch explicitly cleared. If the mode
  # needed FM_ALLOW_SUBAGENT to work, this dispatch would not complete.
  out=$(FM_ALLOW_SUBAGENT= run_resume "$id" "$EXISTING_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" \
    "a governed resume must dispatch without the delegation escape hatch"$'\n'"$out"
  assert_grep "provision=resume" "$HOME_DIR/state/$id.meta" "the governed resume did not complete"

  # The guard is only live in a genuine primary home, so both halves below run
  # against one, not against this suite's own linked worktree where it is inert.
  local primary="$CASE_DIR/primary"
  mkdir -p "$primary/bin" "$primary/state"
  printf '# fixture\n' > "$primary/AGENTS.md"
  "$GIT_REAL" -C "$primary" init -q

  guard_out=$(FM_ROOT_OVERRIDE="$primary" FM_HOME="$primary" FM_STATE_OVERRIDE="$primary/state" \
    FM_ALLOW_SUBAGENT= "$GUARD" --tool Bash 2>&1)
  guard_status=$?
  expect_code 0 "$guard_status" \
    "the dispatch guard blocked the tool shape a governed resume actually uses"$'\n'"$guard_out"

  # 14. Arbitrary direct delegation is still refused in that same primary home.
  guard_out=$(FM_ROOT_OVERRIDE="$primary" FM_HOME="$primary" FM_STATE_OVERRIDE="$primary/state" \
    FM_ALLOW_SUBAGENT= "$GUARD" --tool Task 2>&1)
  guard_status=$?
  expect_code 2 "$guard_status" \
    "arbitrary direct subagent dispatch is no longer blocked"$'\n'"$guard_out"
  assert_contains "$guard_out" "subagent-dispatch" "the delegation refusal lost its marker"
  pass "the primary-dispatch guard accepts governed resume while still blocking arbitrary delegation"
}

# --- 15. least privilege stays bounded to the authorized workspace ----------

test_least_privilege_scope_stays_bounded() {
  local rec id out status project_before sibling_before parent_before
  id=resume-scope-k2
  rec=$(make_case resume-scope "$id")
  read_case "$rec"
  dirty_the_worktree "$EXISTING_DIR"
  project_before=$(fingerprint_of "$PROJECT_DIR")
  sibling_before=$(fingerprint_of "$SIBLING_DIR")
  parent_before=$(ls -A "$CASE_DIR" | LC_ALL=C sort)

  out=$(run_resume "$id" "$EXISTING_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "the resume should have launched"$'\n'"$out"

  [ "$(fingerprint_of "$PROJECT_DIR")" = "$project_before" ] \
    || fail "resume authority over one worktree reached the repository primary checkout"
  [ "$(fingerprint_of "$SIBLING_DIR")" = "$sibling_before" ] \
    || fail "resume authority over one worktree reached a sibling worktree"
  [ "$(ls -A "$CASE_DIR" | LC_ALL=C sort)" = "$parent_before" ] \
    || fail "the resume changed the parent folder holding the authorized workspace"
  pass "resume authority stays bounded to the authorized workspace"
}

# --- 16. a failed resume leaves the target worktree unchanged ---------------

test_failed_resume_leaves_the_worktree_unchanged() {
  local rec id out status before after listing_before listing_after
  id=resume-failclosed-l3
  rec=$(make_case resume-failclosed "$id")
  read_case "$rec"
  dirty_the_worktree "$EXISTING_DIR"
  before=$(fingerprint_of "$EXISTING_DIR")
  listing_before=$(cd "$EXISTING_DIR" && ls -A | LC_ALL=C sort)

  # A ship resume still owes its delivery contract, so this refuses after the
  # path has been named but before anything is provisioned.
  out=$(run_resume "$id" "$EXISTING_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "a ship resume without a delivery contract was accepted"$'\n'"$out"

  # And a refusal at the far end of the path - the endpoint outside the
  # authorized workspace - must leave it equally untouched.
  out=$(run_resume "$id" "$SIBLING_DIR" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a resume whose endpoint left the authorized workspace was accepted"$'\n'"$out"

  after=$(fingerprint_of "$EXISTING_DIR")
  listing_after=$(cd "$EXISTING_DIR" && ls -A | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "a failed resume changed the target worktree"
  [ "$listing_before" = "$listing_after" ] || fail "a failed resume added or removed files in the target worktree"
  assert_no_forbidden_git "a failed resume"
  pass "a failed resume leaves the target worktree exactly as it found it"
}

# --- mode mutual exclusion ---------------------------------------------------

test_resume_is_refused_alongside_the_other_provisioning_modes() {
  local rec id out status
  id=resume-exclusive-m4
  rec=$(make_case resume-exclusive "$id")
  read_case "$rec"

  out=$(fm_test_run_spawn "$HOME_DIR" "$EXISTING_DIR" "$FAKEBIN_DIR" \
    "$id" --relaunch --resume-worktree "$EXISTING_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "--resume-worktree was accepted alongside --relaunch"$'\n'"$out"
  assert_contains "$out" "--relaunch already reuses" "the refusal did not explain the mode conflict"

  out=$(fm_test_run_spawn "$HOME_DIR" "$EXISTING_DIR" "$FAKEBIN_DIR" \
    "$id" --secondmate --resume-worktree "$EXISTING_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "--resume-worktree was accepted alongside --secondmate"$'\n'"$out"
  assert_contains "$out" "only to ship and scout" "the refusal did not explain the secondmate conflict"

  out=$(fm_test_run_spawn "$HOME_DIR" "$EXISTING_DIR" "$FAKEBIN_DIR" \
    "a=$PROJECT_DIR" "b=$PROJECT_DIR" --resume-worktree "$EXISTING_DIR" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "--resume-worktree was accepted for a batch"$'\n'"$out"
  assert_contains "$out" "single-task only" "the refusal did not explain the batch conflict"

  out=$(fm_test_run_spawn "$HOME_DIR" "$EXISTING_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" --resume-worktree ../relative --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "--resume-worktree accepted a relative path"$'\n'"$out"
  assert_contains "$out" "absolute path" "the refusal did not require an absolute path"
  pass "--resume-worktree is refused alongside relaunch, secondmate, batch pairs and relative paths"
}

# --- teardown: a continued worktree is never returned, removed or reset -----
# The captain named this the highest-risk integration point, because
# bin/fm-teardown.sh's ordinary path kills every process under the task
# worktree, detaches HEAD, deletes the task branch, hard-resets the tree and
# returns the slot to the pool. Run against a workspace firstmate was merely
# given, that path destroys exactly the state this mode exists to protect.

# make_teardown_case <name> <id> -> record
# A project clone with an origin, a linked worktree standing in for the
# continued workspace, and a fakebin whose treehouse records every invocation so
# the suite can prove a return was never even attempted.
make_teardown_case() {
  local name=$1 id=$2 case_dir fakebin project wt
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  project="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$fakebin"
  touch "$case_dir/state/.last-watcher-beat"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:-/dev/null}"
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/no-mistakes"

  "$GIT_REAL" init -q --bare "$case_dir/origin.git"
  "$GIT_REAL" -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  "$GIT_REAL" clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'baseline\n' > "$case_dir/_seed/README.md"
  git_fixture -C "$case_dir/_seed" add README.md
  git_fixture -C "$case_dir/_seed" commit -qm baseline
  git_fixture -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  "$GIT_REAL" clone -q "$case_dir/origin.git" "$project"
  "$GIT_REAL" -C "$project" remote set-head origin main 2>/dev/null || true
  git_fixture -C "$project" worktree add -q -b fm/continued "$wt" main

  fm_write_meta "$case_dir/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$project" \
    "kind=ship" \
    "mode=local-only" \
    "provision=resume" \
    "resume_fingerprint=$(fingerprint_of "$wt")" \
    "resume_head=$("$GIT_REAL" -C "$wt" rev-parse HEAD)" \
    "resume_dirty=0" \
    "spawn_gen=resume-teardown-$id"

  printf '%s\n' "$case_dir|$project|$wt|$fakebin"
}

read_teardown_case() {
  IFS='|' read -r TD_CASE_DIR TD_PROJECT TD_WT TD_FAKEBIN <<EOF
$1
EOF
  TREEHOUSE_LOG="$TD_CASE_DIR/treehouse.log"
  : > "$TREEHOUSE_LOG"
}

run_teardown() { # <id> [args...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT"     FM_STATE_OVERRIDE="$TD_CASE_DIR/state"     FM_DATA_OVERRIDE="$TD_CASE_DIR/data"     FM_CONFIG_OVERRIDE="$TD_CASE_DIR/config"     FM_TREEHOUSE_LOG="$TREEHOUSE_LOG"     PATH="$TD_FAKEBIN:$PATH"     "$ROOT/bin/fm-teardown.sh" "$id" "$@" 2>&1
}

test_teardown_never_returns_a_continued_worktree() {
  local rec id out status before branch_before
  id=resume-teardown-n5
  rec=$(make_teardown_case resume-teardown "$id")
  read_teardown_case "$rec"
  before=$(fingerprint_of "$TD_WT")
  branch_before=$("$GIT_REAL" -C "$TD_WT" rev-parse --abbrev-ref HEAD)

  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "teardown of a landed continued task should complete"$'\n'"$out"
  assert_contains "$out" "left in place"     "teardown did not say the continued worktree was left alone"

  # The worktree survives, intact, still on its own branch.
  [ -d "$TD_WT" ] || fail "teardown removed a continued worktree it never created"
  [ -f "$TD_WT/README.md" ] || fail "teardown emptied a continued worktree"
  [ "$(fingerprint_of "$TD_WT")" = "$before" ]     || fail "teardown reset or cleaned a continued worktree"
  [ "$("$GIT_REAL" -C "$TD_WT" rev-parse --abbrev-ref HEAD)" = "$branch_before" ]     || fail "teardown detached HEAD or deleted the branch of a continued worktree"
  # And no pool return was even attempted.
  [ ! -s "$TREEHOUSE_LOG" ]     || fail "teardown called treehouse against a continued worktree:"$'\n'"$(cat "$TREEHOUSE_LOG")"
  # The task itself is still retired, so nothing is stranded in the fleet.
  assert_absent "$TD_CASE_DIR/state/$id.meta" "teardown left the retired task's record behind"

  # Control: the identical fixture WITHOUT the provisioning provenance must take
  # the ordinary destructive path. Without this the case above could pass for the
  # wrong reason - a fixture teardown never reaches - and prove nothing.
  local control_id=resume-teardown-control-n5
  rec=$(make_teardown_case resume-teardown-control "$control_id")
  read_teardown_case "$rec"
  grep -v '^provision=' "$TD_CASE_DIR/state/$control_id.meta" > "$TD_CASE_DIR/control.meta"
  mv "$TD_CASE_DIR/control.meta" "$TD_CASE_DIR/state/$control_id.meta"
  out=$(run_teardown "$control_id")
  status=$?
  expect_code 0 "$status" "the control teardown should complete"$'\n'"$out"
  assert_grep "return" "$TREEHOUSE_LOG"     "an ordinary task's teardown no longer returns its worktree, so the resume case proves nothing"
  pass "teardown retires a continued task without returning, removing or resetting its worktree"
}

test_teardown_still_refuses_unlanded_work_in_a_continued_worktree() {
  local rec id out status before
  id=resume-teardown-dirty-o6
  rec=$(make_teardown_case resume-teardown-dirty "$id")
  read_teardown_case "$rec"
  printf 'uncommitted remediation\n' >> "$TD_WT/README.md"
  before=$(fingerprint_of "$TD_WT")

  out=$(run_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "teardown discarded uncommitted work in a continued worktree"$'\n'"$out"
  [ "$(fingerprint_of "$TD_WT")" = "$before" ]     || fail "a refused teardown still changed the continued worktree"
  assert_present "$TD_CASE_DIR/state/$id.meta"     "a refused teardown removed the task record anyway"
  pass "teardown's unlanded-work refusal still holds for a continued worktree"
}

# --- firstmate's own per-task wiring never overwrites the operator's ---------
# Arming turn-end and busy-state signals writes one file into the worktree. In
# a fresh pool slot nothing can be at that path; in a continued workspace the
# operator's own file can be, and replacing it would destroy exactly the kind of
# state this mode protects.

test_resume_refuses_to_overwrite_existing_harness_wiring() {
  local rec id out status before
  id=resume-wiring-p7
  rec=$(make_case resume-wiring "$id")
  read_case "$rec"
  mkdir -p "$EXISTING_DIR/.claude"
  printf '{"operator":"settings"}\n' > "$EXISTING_DIR/.claude/settings.local.json"
  before=$(cat "$EXISTING_DIR/.claude/settings.local.json")

  out=$(run_resume "$id" "$EXISTING_DIR" --harness claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a claude resume overwrote the operator's own settings file"$'\n'"$out"
  assert_contains "$out" "already contains" "the refusal did not name the conflicting file"
  [ "$(cat "$EXISTING_DIR/.claude/settings.local.json")" = "$before" ]     || fail "the refused resume still changed the operator's settings file"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused resume still published a task record"

  # A harness whose per-task wiring lives outside the worktree is unaffected by
  # the same file, so the refusal is scoped to a real conflict rather than to
  # the presence of a common filename.
  out=$(run_resume "$id" "$EXISTING_DIR" --harness codex --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status"     "a harness that writes no worktree wiring should still resume this workspace"$'\n'"$out"
  pass "a resume refuses to overwrite per-task wiring it did not write, and only where a conflict is real"
}

test_resume_clean_existing_worktree
test_resume_dirty_existing_worktree_preserves_every_change
test_reject_nonexistent_path
test_reject_directory_that_is_not_a_worktree
test_reject_sibling_worktree_substitution
test_reject_identity_change_before_launch
test_no_git_write_command_is_issued
test_resumed_worker_is_ordinary_fleet_work
test_provenance_distinguishes_spawn_from_resume
test_primary_dispatch_guard_accepts_resume_and_still_blocks_delegation
test_least_privilege_scope_stays_bounded
test_failed_resume_leaves_the_worktree_unchanged
test_resume_is_refused_alongside_the_other_provisioning_modes
test_teardown_never_returns_a_continued_worktree
test_teardown_still_refuses_unlanded_work_in_a_continued_worktree
test_resume_refuses_to_overwrite_existing_harness_wiring

echo "# all fm-spawn-resume-worktree tests passed"
