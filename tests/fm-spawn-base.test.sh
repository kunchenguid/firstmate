#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --base, the one owner of a task's declared base.
#
# state/<id>.meta is the single source of truth for a task's base: fm-spawn.sh
# writes base= and base_sha= straight from its own flag, and nothing else records
# a base anywhere. There is no sidecar to promote, so there is no link in the chain
# that could silently disarm fm-pr-check.sh's guard by failing to hand the branch
# name along.
#
# The spawn decides on the SAME question fm-pr-check.sh and fm-review-diff.sh decide on -
# has the base's work LANDED in the default branch (bin/fm-base-lib.sh's
# fm_base_resolve_state) - never on whether the branch happens to exist. What a spawn does
# with each answer turns on one thing only this script knows: whether the task is meeting
# the base for the FIRST time, or coming back to a base it already declared.
#
# Matrix:
#   (a) --base <branch> on a LIVE base -> meta records base=<branch> and base_sha=<origin tip>
#   (b) no --base (the common case) -> meta records no base= line at all
#   (c) an invalid branch name -> loud refusal, raised before any window or worktree exists
#   (d) an accepted spawn does create both, so (c)'s assertions are live
#   (e) --base is rejected for a scout and for a secondmate
#   (f) a declared base origin does not have -> the same early, loud refusal
#   (g) --base is rejected in a batch spawn, where it could not name one task
#   (h) a respawn without --base carries the recorded base=/base_sha= forward, because
#       meta is rewritten wholesale and a base lost on recovery is a task unguarded
#   (i) --base is rejected for a local-only project, whose merge path has no guard
#   (j) a respawn whose base MERGED and was deleted from origin is accepted, declaration
#       intact - the normal end-state of a stacked PR, not a reason to dead-end recovery
#   (k) a respawn whose base was deleted from origin WITHOUT merging is refused by name,
#       whether the base is supplied again or carried forward
#   (l) a FIRST spawn against a base that has already MERGED (branch still on origin -
#       GitHub's delete-on-merge is off by default) is refused BY NAME. There is nothing
#       left to stack on, and the brief would send the crewmate to root its branch on the
#       base's pre-merge commits - a whole run that fm-pr-check.sh is guaranteed to refuse.
#       Deciding on the branch's mere existence would have waved this through
#   (m) a RESPAWN whose base merged but was NOT deleted is accepted, declaration intact -
#       the same landedness, a different question, because the branch already exists and
#       fm-pr-check.sh decides that PR on its own merits
#
# base_sha= is the base's tip on origin at spawn time, resolved while the base
# necessarily still exists. That is the fact fm-pr-check.sh needs once the branch is
# deleted from origin, where absence alone cannot say whether the base merged
# (harmless) or was abandoned (its unmerged commits replayed on the PR head) - and it is
# the same fact this script decides (j) through (m) with.
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

# Build a spawn case: an isolated firstmate home, a real project + git worktree, and
# a brief for the task.
#
# The project gets a real origin with a feature/base branch on it, because a based
# spawn resolves the base's tip from origin and records it as base_sha= - the durable
# fact fm-pr-check.sh needs to tell a merged base from an abandoned one once the
# branch itself is deleted. origin_base names the branch actually created on origin,
# so a case can declare a base origin does NOT have.
#
# That base is given a commit of its OWN, so it is LIVE - it carries unmerged work. A base
# sitting at the default branch's own tip carries none, which reads (correctly) as already
# landed, and the spawn refuses to launch a first task against a base there is nothing left
# to stack on. Every case that expects an accepted based spawn therefore needs a base that
# is genuinely live, and this is where it gets one.
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
  [ -z "$origin_base" ] || advance_origin_base "$case_dir" "$proj" "$origin_base"
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
# init.defaultBranch happens to be - the spawn reads it to decide whether a base that is
# gone from origin merged or was abandoned.
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

# Put a commit of the base's OWN on the base branch, so "has this base's work landed in
# the default branch" is a real question rather than trivially true. The project clone
# then fetches it, exactly as a fleet sync or the crewmate's own `git fetch origin
# <base>` would: the base's commits reach its object store, which is what keeps the
# landed/abandoned question answerable once the branch itself is gone from origin.
advance_origin_base() {  # <case_dir> <proj> <branch>
  local case_dir=$1 proj=$2 branch=$3 scratch
  scratch=$(origin_scratch "$case_dir")
  git -C "$scratch" checkout -q -B "$branch" "origin/$branch"
  printf 'base work\n' > "$scratch/base-work.txt"
  git -C "$scratch" add base-work.txt
  git_commit "$scratch" "base work"
  git -C "$scratch" push -q origin "$branch"
  git -C "$proj" fetch -q origin
}

merge_origin_base_into_main() {  # <case_dir> <branch>
  local case_dir=$1 branch=$2 scratch
  scratch=$(origin_scratch "$case_dir")
  git -C "$scratch" checkout -q -B main origin/main
  git -C "$scratch" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    merge -q --no-ff -m "merge $branch" "origin/$branch"
  git -C "$scratch" push -q origin main
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
  local rec id out status origin_sha
  id=spawn-base-b1
  rec=$(make_spawn_case record "$id" feature/admin-dashboard)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/admin-dashboard)
  status=$?
  expect_code 0 "$status" "record: a spawn with --base should succeed"$'\n'"$out"
  assert_grep "base=feature/admin-dashboard" "$HOME_DIR/state/$id.meta" \
    "record: the declared base never reached meta, so fm-pr-check would skip the wrong-base guard"
  origin_sha=$(git -C "$CASE_DIR/origin.git" rev-parse refs/heads/feature/admin-dashboard)
  assert_grep "base_sha=$origin_sha" "$HOME_DIR/state/$id.meta" \
    "record: the base's tip on origin was not recorded, so a base later deleted from origin could not be told merged from abandoned"
  pass "fm-spawn --base records base= and the base's spawn-time tip as base_sha="
}

# base_sha= is what makes the absent-base decision SOUND rather than a guess, so the
# spawn must refuse a base origin does not have instead of recording base= with no
# tip to verify against later. It is also the cheapest possible place to catch a
# mistyped base: before a crewmate spends a run on it.
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
  local rec id out status origin_sha
  id=spawn-base-b8
  rec=$(make_spawn_case respawn "$id" feature/keepme)
  read_case_record "$rec"
  origin_sha=$(git -C "$CASE_DIR/origin.git" rev-parse refs/heads/feature/keepme)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/keepme)
  status=$?
  expect_code 0 "$status" "respawn: the first (based) spawn should succeed"$'\n'"$out"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "respawn: a respawn without --base should succeed"$'\n'"$out"
  assert_grep "base=feature/keepme" "$HOME_DIR/state/$id.meta" \
    "respawn: a respawn without --base dropped the declared base, leaving the task unguarded at merge"
  assert_grep "base_sha=$origin_sha" "$HOME_DIR/state/$id.meta" \
    "respawn: the recorded base tip was dropped, so a base later deleted from origin could not be told merged from abandoned"
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

# The base branch merging and being deleted is the NORMAL end-state of a stacked PR -
# GitHub deletes the head branch on merge by default - and it is exactly when a stuck
# crewmate gets relaunched. Deciding on the branch's EXISTENCE would refuse that respawn
# on the documented invocation (--base to both fm-brief.sh and fm-spawn.sh) and dead-end
# a task whose PR is perfectly mergeable. The question is landedness: the base's work is
# in the default branch, so nothing is left to stack on and nothing can be dragged
# anywhere. Keep the declaration, and let the spawn through.
test_respawn_with_base_after_the_base_merged_and_was_deleted() {
  local rec id out status base_sha
  id=spawn-base-b10
  rec=$(make_spawn_case basemerged "$id" feature/merged)
  read_case_record "$rec"
  base_sha=$(git -C "$CASE_DIR/origin.git" rev-parse refs/heads/feature/merged)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/merged)
  status=$?
  expect_code 0 "$status" "basemerged: the first (based) spawn should succeed"$'\n'"$out"
  assert_grep "base_sha=$base_sha" "$HOME_DIR/state/$id.meta" \
    "basemerged: the first spawn did not record the base's tip, so the respawn below would have no fact to decide with"

  merge_origin_base_into_main "$CASE_DIR" feature/merged
  delete_origin_base "$CASE_DIR" feature/merged

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/merged)
  status=$?
  expect_code 0 "$status" "basemerged: a respawn with --base after the base merged and was deleted must succeed, not dead-end on the branch being gone"$'\n'"$out"
  assert_contains "$out" "has since merged" \
    "basemerged: the spawn should say out loud that the base merged, not just proceed"
  assert_contains "$out" "deleted from origin" \
    "basemerged: the spawn should say the branch is gone as well, so the operator is not left guessing why"
  assert_grep "base=feature/merged" "$HOME_DIR/state/$id.meta" \
    "basemerged: the respawn dropped the declared base, leaving the task unguarded at merge"
  assert_grep "base_sha=$base_sha" "$HOME_DIR/state/$id.meta" \
    "basemerged: the respawn dropped the recorded base tip, so fm-pr-check could no longer tell that base merged"
  pass "fm-spawn accepts a respawn whose declared base merged and was deleted from origin"
}

# The other half of the same question, and the one the guard exists for: a base branch
# deleted WITHOUT merging is ABANDONED. Its commits never reached the default branch, so
# a task stacked on it is stacked on history that will never land, and fm-pr-check.sh
# would refuse its PR before merge. Absence looks identical to `git ls-remote` in both
# cases, so the recorded tip is what tells them apart - and this refusal must fire on the
# respawn that omits --base too, since the carried-forward declaration means the same
# thing as the supplied one.
test_respawn_after_the_base_was_abandoned_refuses() {
  local rec id out status log
  id=spawn-base-b11
  rec=$(make_spawn_case baseabandoned "$id" feature/abandoned)
  read_case_record "$rec"
  log="$CASE_DIR/tmux.log"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/abandoned)
  status=$?
  expect_code 0 "$status" "baseabandoned: the first (based) spawn should succeed"$'\n'"$out"

  delete_origin_base "$CASE_DIR" feature/abandoned
  : > "$log"

  out=$(FM_TEST_TMUX_LOG="$log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/abandoned)
  status=$?
  expect_code 1 "$status" "baseabandoned: a base deleted from origin WITHOUT merging must refuse the respawn, not be waved through as merged"
  assert_contains "$out" "WITHOUT merging" "baseabandoned: refusal did not name the abandoned base"
  assert_no_grep "new-window" "$log" \
    "baseabandoned: the refusal created a backend window it then abandoned, with no meta to reconcile it"
  assert_no_grep "treehouse get" "$log" \
    "baseabandoned: the refusal leased a task worktree it then abandoned, with no meta to release it"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "baseabandoned: the carried-forward base must be held to the same rule as the supplied one"
  assert_contains "$out" "WITHOUT merging" "baseabandoned: the carry-forward refusal did not name the abandoned base"
  pass "fm-spawn refuses a respawn whose declared base was deleted from origin without merging"
}

# GitHub's delete-on-merge is OFF by default, so "merged, branch kept" is at least as
# ordinary an end-state as the deleted one - and firstmate's queued/blocked-by flow
# dispatches a stacked task exactly when its base has just merged. Deciding on the
# branch's EXISTENCE would wave that first spawn straight through: the brief would send the
# crewmate to fetch the base and root fm/<id> on the base's pre-squash commits, and
# fm-pr-check.sh would then refuse the finished PR and demand a rebase onto the default
# branch. A whole run, doomed at launch. Landedness is the question, so the spawn refuses
# it here, by name, and says the one thing that actually resolves it.
test_first_spawn_against_an_already_merged_base_refuses() {
  local rec id out status log
  id=spawn-base-b12
  rec=$(make_spawn_case basealreadymerged "$id" feature/done)
  read_case_record "$rec"
  log="$CASE_DIR/tmux.log"
  : > "$log"

  # feature/done merges into main and origin KEEPS the branch.
  merge_origin_base_into_main "$CASE_DIR" feature/done

  out=$(FM_TEST_TMUX_LOG="$log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/done)
  status=$?
  expect_code 1 "$status" "basealreadymerged: a first spawn against a base whose work has already merged must refuse, not launch a doomed run"
  assert_contains "$out" "ALREADY MERGED" \
    "basealreadymerged: the refusal did not say the base has already merged"
  assert_contains "$out" "re-run WITHOUT --base" \
    "basealreadymerged: the refusal did not name the one recovery that resolves it"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "basealreadymerged: a refused base must not be recorded"
  assert_no_grep "new-window" "$log" \
    "basealreadymerged: the refusal created a backend window it then abandoned, with no meta to reconcile it"
  assert_no_grep "treehouse get" "$log" \
    "basealreadymerged: the refusal leased a task worktree it then abandoned, with no meta to release it"
  pass "fm-spawn refuses a first spawn against a base whose work has already merged"
}

# The mirror of the case above, and the reason existence is not the question in EITHER
# direction: the same landed base, but the task already declared it and its branch already
# exists. Refusing here would dead-end the recovery of a task whose PR fm-pr-check.sh may
# well pass - it stands its guard down for a head that now sits on the default branch. So
# the declaration is kept and the respawn goes through.
test_respawn_after_the_base_merged_without_being_deleted() {
  local rec id out status base_sha
  id=spawn-base-b13
  rec=$(make_spawn_case basemergedkept "$id" feature/kept)
  read_case_record "$rec"
  base_sha=$(git -C "$CASE_DIR/origin.git" rev-parse refs/heads/feature/kept)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/kept)
  status=$?
  expect_code 0 "$status" "basemergedkept: the first (based) spawn should succeed while the base is still live"$'\n'"$out"

  # feature/kept merges into main; origin KEEPS the branch (GitHub's default).
  merge_origin_base_into_main "$CASE_DIR" feature/kept

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/kept)
  status=$?
  expect_code 0 "$status" "basemergedkept: a respawn whose base merged mid-flight must not dead-end recovery"$'\n'"$out"
  assert_contains "$out" "has since merged" \
    "basemergedkept: the spawn should say out loud that the base merged rather than quietly proceeding"
  assert_grep "base=feature/kept" "$HOME_DIR/state/$id.meta" \
    "basemergedkept: the respawn dropped the declared base, leaving the task unguarded at merge"
  assert_grep "base_sha=$base_sha" "$HOME_DIR/state/$id.meta" \
    "basemergedkept: the respawn dropped the recorded spawn-time tip, so fm-pr-check could no longer tell that base merged"
  pass "fm-spawn accepts a respawn whose declared base merged without being deleted"
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
test_respawn_with_base_after_the_base_merged_and_was_deleted
test_respawn_after_the_base_was_abandoned_refuses
test_first_spawn_against_an_already_merged_base_refuses
test_respawn_after_the_base_merged_without_being_deleted
test_base_rejected_for_a_local_only_project
test_base_rejected_in_a_batch
