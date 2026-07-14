#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --base, the one owner of a task's declared base.
#
# state/<id>.meta is the single source of truth for a task's base: fm-spawn.sh writes base=
# straight from its own flag, and nothing else records a base anywhere. There is no sidecar
# to promote, so there is no link in the chain that could silently disarm fm-pr-check.sh's
# guard by failing to hand the branch name along.
#
# The spawn asks ONE question about a base, and only of a NEW declaration: is that branch on
# origin? A branch that is not there is almost always a typo, and catching it costs a command
# rather than a whole crewmate run. It asks nothing further - whether a base has merged, been
# squash-merged, or been abandoned is not decidable from git without a guess, and this design
# does not guess: bin/fm-pr-check.sh hands an unverifiable base to a human at the merge gate.
#
# Matrix:
#   (a) --base <branch> on a base that is on origin -> meta records base=<branch>
#   (b) no --base (the common case) -> meta records no base= line at all
#   (c) an invalid branch name -> loud refusal, raised before any window or worktree exists
#   (d) an accepted spawn does create both, so (c)'s assertions are live
#   (e) --base is rejected for a scout and for a secondmate
#   (f) a declared base origin does not have -> the same early, loud refusal
#   (g) --base is rejected in a batch spawn, where it could not name one task
#   (h) a respawn without --base carries the recorded base= forward, because meta is
#       rewritten wholesale and a base lost on recovery is a task unguarded
#   (i) --base is rejected for a local-only project, whose merge path has no guard
#   (j) a respawn RE-SUPPLYING the same base whose branch has since been deleted from origin
#       is accepted, declaration intact. The base merging and its branch being deleted is the
#       normal end-state of a stacked PR, and it is exactly when a stuck crewmate gets
#       relaunched; re-probing origin there would dead-end the recovery of a task whose PR
#       fm-pr-check.sh may well pass
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-base)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  # Logs every invocation to $FM_TEST_TMUX_LOG so a test can assert what the spawn
  # actually created. The window is a tmux new-window, and the worktree lease is a
  # `treehouse get` typed into the pane via send-keys, so both are visible here.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TEST_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TEST_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Build a spawn case: an isolated firstmate home, a real project + git worktree, and a brief
# for the task.
#
# The project gets a real origin carrying the base branch, because a NEW declaration is
# probed against origin before the spawn is allowed. origin_base names the branch actually
# created there, so a case can declare a base origin does NOT have.
make_spawn_case() {
  local name=$1 id=$2 origin_base=${3:-feature/base} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  make_project_origin "$case_dir" "$proj" "$origin_base"
  touch "$home/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

# Give the project clone a real origin carrying <origin_base>, so `git ls-remote` in
# the spawn resolves a tip for it. Pass an empty origin_base for an origin with no
# feature branch at all.
#
# origin/HEAD and the bare repo's own HEAD are pinned to main the way a real `git clone`
# would leave them, so the default branch resolves to main whatever the local
# init.defaultBranch happens to be.
make_project_origin() {
  local case_dir=$1 proj=$2 origin_base=$3 origin
  origin="$case_dir/origin.git"
  git init -q --bare "$origin"
  git -C "$proj" remote add origin "$origin"
  git -C "$proj" push -q origin HEAD:refs/heads/main
  [ -z "$origin_base" ] || git -C "$proj" push -q origin "HEAD:refs/heads/$origin_base"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git -C "$proj" fetch -q origin
  git -C "$proj" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

# A scratch clone of the case's origin, so origin-side history (a commit on the base, a
# merge into main, a deleted branch) can be built without touching the project clone or
# its attached worktree.
origin_scratch() {  # <case_dir>
  local case_dir=$1 scratch="$1/origin-scratch"
  [ -d "$scratch" ] || git clone -q "$case_dir/origin.git" "$scratch"
  printf '%s\n' "$scratch"
}

git_commit() {  # <dir> <message>
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "$2"
}




delete_origin_base() {  # <case_dir> <branch>
  local case_dir=$1 branch=$2 scratch
  scratch=$(origin_scratch "$case_dir")
  git -C "$scratch" push -q origin --delete "$branch"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_TEST_TMUX_LOG="${FM_TEST_TMUX_LOG:-}" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_base_flag_is_recorded_in_meta() {
  local rec id out status
  id=spawn-base-b1
  rec=$(make_spawn_case record "$id" feature/admin-dashboard)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/admin-dashboard)
  status=$?
  expect_code 0 "$status" "record: a spawn with --base should succeed"$'\n'"$out"
  assert_grep "base=feature/admin-dashboard" "$HOME_DIR/state/$id.meta" \
    "record: the declared base never reached meta, so fm-pr-check would skip the wrong-base guard"
  pass "fm-spawn --base records base= in meta, the single source of truth for a task's base"
}

# A base origin does not have is almost always a typo, and this is the cheapest possible
# place to catch it: before a crewmate spends a whole run on it, and before any window or
# worktree exists to strand.
test_base_missing_from_origin_refuses_before_creating_anything() {
  local rec id out status log
  id=spawn-base-b6
  rec=$(make_spawn_case nosuchbase "$id" feature/base)
  read_case_record "$rec"
  log="$CASE_DIR/tmux.log"
  : > "$log"

  out=$(FM_TEST_TMUX_LOG="$log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/typo)
  status=$?
  expect_code 1 "$status" "nosuchbase: a base that does not exist on origin must refuse, not spawn with an unverifiable base"
  assert_contains "$out" "no such branch exists on origin" "nosuchbase: refusal did not explain the missing base branch"
  assert_absent "$HOME_DIR/state/$id.meta" "nosuchbase: refusal should happen before meta is written"
  assert_no_grep "new-window" "$log" \
    "nosuchbase: the refusal created a backend window it then abandoned, with no meta to reconcile it"
  assert_no_grep "treehouse get" "$log" \
    "nosuchbase: the refusal leased a task worktree it then abandoned, with no meta to release it"
  pass "fm-spawn refuses a declared base origin does not have, before any window or worktree exists"
}

test_no_base_writes_no_base_key() {
  local rec id out status
  id=spawn-base-b2
  rec=$(make_spawn_case nobase "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "nobase: an ordinary spawn should succeed"$'\n'"$out"
  # Fixed-string, unanchored: assert_no_grep is grep -F, so a "^base=" pattern
  # would search for a literal caret and pass no matter what meta holds. No other
  # meta key contains "base=" as a substring, so this is both live and precise.
  assert_no_grep "base=" "$HOME_DIR/state/$id.meta" \
    "nobase: a task with no declared base must not gain a base= line"
  pass "fm-spawn writes no base= for the common no-declared-base task"
}

# The base reaches git as a refspec, where a leading dash is read as an option and
# --upload-pack=<cmd> is an arbitrary-command vector. The refusal is fail-closed, so
# it must also be cheap: it has to fire BEFORE the backend window and the treehouse
# worktree lease are acquired. Refusing after them - but before meta is written -
# strands both with no state/<id>.meta, and every reconciliation path (recovery,
# fm-teardown.sh) keys off meta, so nothing could ever clean them up but a human.
test_invalid_base_refuses_before_creating_anything() {
  local rec id out status log
  id=spawn-base-b3
  rec=$(make_spawn_case badname "$id")
  read_case_record "$rec"
  log="$CASE_DIR/tmux.log"
  : > "$log"

  out=$(FM_TEST_TMUX_LOG="$log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base=--upload-pack=touch)
  status=$?
  expect_code 1 "$status" "badname: a base git would read as an option must refuse, not spawn"
  assert_contains "$out" "not a valid git branch name" "badname: refusal did not explain the invalid branch name"
  assert_absent "$HOME_DIR/state/$id.meta" "badname: refusal should happen before meta is written"
  assert_no_grep "new-window" "$log" \
    "badname: the refusal created a backend window it then abandoned, with no meta to reconcile it"
  assert_no_grep "treehouse get" "$log" \
    "badname: the refusal leased a task worktree it then abandoned, with no meta to release it"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base=)
  status=$?
  expect_code 1 "$status" "badname: an empty --base must refuse"
  assert_contains "$out" "non-empty branch name" "badname: refusal did not explain the empty value"
  pass "fm-spawn refuses an unusable --base before any window or worktree exists (nothing stranded)"
}

# The same spawn path, with a base that resolves, must still create the window and
# take the lease - so the assertions above are pinning the refusal, not an inert log.
test_a_good_spawn_does_create_the_window_and_worktree() {
  local rec id out status log
  id=spawn-base-b5
  rec=$(make_spawn_case createscheck "$id" feature/x)
  read_case_record "$rec"
  log="$CASE_DIR/tmux.log"
  : > "$log"

  out=$(FM_TEST_TMUX_LOG="$log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/x)
  status=$?
  expect_code 0 "$status" "createscheck: a well-formed based spawn should succeed"$'\n'"$out"
  assert_grep "new-window" "$log" "createscheck: the spawn never created a window, so the refusal test proves nothing"
  assert_grep "treehouse get" "$log" "createscheck: the spawn never leased a worktree, so the refusal test proves nothing"
  pass "fm-spawn does create the window and worktree on an accepted spawn (the leak assertions are live)"
}

# A base only means something for a ship task's PR. A scout raises none, and a
# secondmate is a persistent supervisor rather than a task at all.
test_base_rejected_for_scout_and_secondmate() {
  local rec id out status home
  id=spawn-base-sm4
  rec=$(make_spawn_case scoutsm "$id" feature/x)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout --base feature/x)
  status=$?
  expect_code 1 "$status" "scoutsm: --base must be rejected for a scout, which raises no PR"
  assert_contains "$out" "applies only to ship tasks" "scoutsm: refusal did not explain the scope"
  assert_absent "$HOME_DIR/state/$id.meta" "scoutsm: a rejected --base must not spawn"

  home="$CASE_DIR/sm-home"
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$home" --secondmate --base feature/x)
  status=$?
  expect_code 1 "$status" "scoutsm: --base must be rejected for a secondmate, which has no task base"
  assert_contains "$out" "applies only to ship tasks" "scoutsm: refusal did not explain the scope"
  pass "fm-spawn rejects --base for scouts and secondmates"
}

# state/<id>.meta is rewritten wholesale on every spawn, so a respawn (recovery, a
# relaunch after a stuck crewmate) that does not re-supply --base would silently drop
# the declaration - and fm-pr-check.sh, finding no base=, would skip the guard entirely
# and record pr= for a wrong-based PR with no diagnostic. That is the exact fail-open
# this whole design exists to make impossible, so a respawn must carry the recorded
# declaration forward, tip and all. Retiring a base stays a deliberate meta edit.
test_respawn_without_base_carries_the_declaration_forward() {
  local rec id out status
  id=spawn-base-b8
  rec=$(make_spawn_case respawn "$id" feature/keepme)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/keepme)
  status=$?
  expect_code 0 "$status" "respawn: the first (based) spawn should succeed"$'\n'"$out"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "respawn: a respawn without --base should succeed"$'\n'"$out"
  assert_grep "base=feature/keepme" "$HOME_DIR/state/$id.meta" \
    "respawn: a respawn without --base dropped the declared base, leaving the task unguarded at merge"
  assert_contains "$out" "carrying it forward" "respawn: the carried-forward base should be said out loud"
  pass "fm-spawn carries a declared base forward across a respawn that omits --base"
}

# A base is a fact about a PR's target. local-only has neither remote nor PR: its work
# reaches main through bin/fm-merge-local.sh, which has no base guard at all. Recording
# a base there would leave the one delivery mode where a wrong-based branch merges
# unchecked - the 2026-07-07 incident, in the mode the guard does not cover. fm-brief.sh
# refuses it too, but this script owns the durable record, so it must enforce its own rule.
test_base_rejected_for_a_local_only_project() {
  local rec id out status log
  id=spawn-base-b9
  rec=$(make_spawn_case localonly "$id" feature/x)
  read_case_record "$rec"
  log="$CASE_DIR/tmux.log"
  : > "$log"
  printf -- '- %s [local-only] - test project (added 2026-07-14)\n' "$(basename "$PROJ_DIR")" \
    > "$HOME_DIR/data/projects.md"

  out=$(FM_TEST_TMUX_LOG="$log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/x)
  status=$?
  expect_code 1 "$status" "localonly: --base must be refused for a local-only project, whose merge path has no guard"
  assert_contains "$out" "ships local-only" "localonly: refusal did not explain why a local-only project cannot carry a base"
  assert_absent "$HOME_DIR/state/$id.meta" "localonly: a refused --base must not record a base it cannot guard"
  assert_no_grep "new-window" "$log" \
    "localonly: the refusal created a backend window it then abandoned, with no meta to reconcile it"
  assert_no_grep "treehouse get" "$log" \
    "localonly: the refusal leased a task worktree it then abandoned, with no meta to release it"
  pass "fm-spawn refuses --base for a local-only project, before any window or worktree exists"
}

# The base branch merging and being deleted is the NORMAL end-state of a stacked PR - GitHub
# deletes the head branch on merge by default - and it is exactly when a stuck crewmate gets
# relaunched. Re-probing origin on a respawn would refuse the documented invocation (--base
# to both fm-brief.sh and fm-spawn.sh) and dead-end a task whose PR may be perfectly
# mergeable, so a respawn that re-supplies the base it already declares skips the probe and
# keeps the declaration. Nothing comes back unguarded either way.
test_respawn_with_base_after_the_base_was_deleted_from_origin() {
  local rec id out status
  id=spawn-base-b10
  rec=$(make_spawn_case basegone "$id" feature/merged)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/merged)
  status=$?
  expect_code 0 "$status" "basegone: the first (based) spawn should succeed"$'\n'"$out"

  delete_origin_base "$CASE_DIR" feature/merged

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/merged)
  status=$?
  expect_code 0 "$status" "basegone: a respawn re-supplying its already-declared base must not dead-end on that branch being gone"$'\n'"$out"
  assert_grep "base=feature/merged" "$HOME_DIR/state/$id.meta" \
    "basegone: the respawn dropped the declared base, leaving the task unguarded at merge"
  pass "fm-spawn accepts a respawn re-supplying its declared base after that branch left origin"
}






# A base is a fact about ONE task. Shared across a batch it would silently guard
# every pair against a base only one of them declared.
test_base_rejected_in_a_batch() {
  local rec id out status
  id=spawn-base-b7
  rec=$(make_spawn_case batch "$id" feature/x)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id=$PROJ_DIR" --base feature/x)
  status=$?
  expect_code 1 "$status" "batch: --base must be rejected in a batch spawn, where it cannot name one task"
  assert_contains "$out" "per-task" "batch: refusal did not explain why a batch cannot share a base"
  assert_absent "$HOME_DIR/state/$id.meta" "batch: a rejected batch --base must not spawn"
  pass "fm-spawn rejects --base in a batch spawn"
}

test_base_flag_is_recorded_in_meta
test_no_base_writes_no_base_key
test_invalid_base_refuses_before_creating_anything
test_base_missing_from_origin_refuses_before_creating_anything
test_a_good_spawn_does_create_the_window_and_worktree
test_base_rejected_for_scout_and_secondmate
test_respawn_without_base_carries_the_declaration_forward
test_respawn_with_base_after_the_base_was_deleted_from_origin
test_base_rejected_for_a_local_only_project
test_base_rejected_in_a_batch
