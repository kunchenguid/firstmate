#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --base, the one owner of a task's declared base.
#
# state/<id>.meta is the single source of truth for a task's base: fm-spawn.sh
# writes base= and base_sha= straight from its own flag, and nothing else records
# a base anywhere. There is no sidecar to promote, so there is no link in the chain
# that could silently disarm fm-pr-check.sh's guard by failing to hand the branch
# name along.
#
# Matrix:
#   (a) --base <branch> -> meta records base=<branch> and base_sha=<origin tip>
#   (b) no --base (the common case) -> meta records no base= line at all
#   (c) an invalid branch name -> loud refusal, raised before any window or worktree exists
#   (d) an accepted spawn does create both, so (c)'s assertions are live
#   (e) --base is rejected for a scout and for a secondmate
#   (f) a declared base origin does not have -> the same early, loud refusal
#   (g) --base is rejected in a batch spawn, where it could not name one task
#
# base_sha= is the base's tip on origin at spawn time, resolved while the base
# necessarily still exists. That is the fact fm-pr-check.sh needs once the branch is
# deleted from origin, where absence alone cannot say whether the base merged
# (harmless) or was abandoned (its unmerged commits replayed on the PR head).
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
make_project_origin() {
  local case_dir=$1 proj=$2 origin_base=$3 origin
  origin="$case_dir/origin.git"
  git init -q --bare "$origin"
  git -C "$proj" remote add origin "$origin"
  git -C "$proj" push -q origin HEAD:refs/heads/main
  [ -z "$origin_base" ] || git -C "$proj" push -q origin "HEAD:refs/heads/$origin_base"
  git -C "$proj" fetch -q origin
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
test_base_rejected_in_a_batch
