#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      if [ "${4:-}" = "-l" ]; then
        printf '%s\n' "${5:-}" >> "$FM_FAKE_LAUNCH_LOG"
      else
        printf '%s\n' "${4:-}" >> "$FM_FAKE_LAUNCH_LOG"
      fi
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # The stub advertises the pinned build's --root option, which a home owning its
  # own pool requires; the older-Treehouse case re-stubs it with --no-root.
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

# make_secondmate_pool_case <name> <id> builds a real linked Firstmate home and
# matching project clones whose worktree common dirs are intentionally distinct.
make_secondmate_pool_case() {
  local name=$1 id=$2 case_dir code_root home source origin project primary_project
  local primary_wt home_wt fakebin countfile launchlog
  case_dir="$TMP_ROOT/$name"
  code_root="$case_dir/code-root"
  home="$case_dir/secondmate-home"
  source="$case_dir/project-source"
  origin="$case_dir/project-origin.git"
  project="$home/projects/widget"
  primary_project="$case_dir/primary-project"
  primary_wt="$case_dir/primary-pool-worktree"
  home_wt="$case_dir/secondmate-pool-worktree"
  countfile="$case_dir/pane-call-count"
  launchlog="$case_dir/launch.log"

  git clone --quiet --local "$ROOT" "$code_root"
  git -C "$code_root" worktree add --quiet --detach "$home" HEAD
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the secondmate-specific Treehouse pool root for $id.

## Firstmate spec
Use the active home's own project pool.
EOF
  touch "$home/state/.last-watcher-beat"

  fm_git_init_commit "$source"
  git -C "$source" branch -M main
  fm_git_add_origin "$source" "$origin"
  git clone --quiet "file://$origin" "$project"
  git clone --quiet "file://$origin" "$primary_project"
  git -C "$primary_project" worktree add --quiet --detach "$primary_wt" HEAD
  git -C "$project" worktree add --quiet --detach "$home_wt" HEAD

  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_fake_exit0 "$fakebin" codex
  printf '%s\n' "$case_dir|$code_root|$home|$project|$primary_wt|$home_wt|$fakebin|$countfile|$launchlog"
}

read_secondmate_pool_record() {
  IFS='|' read -r SECOND_CASE SECOND_CODE_ROOT SECOND_HOME SECOND_PROJECT \
    SECOND_PRIMARY_WT SECOND_HOME_WT SECOND_FAKEBIN SECOND_COUNTFILE SECOND_LAUNCHLOG <<EOF
$1
EOF
}

run_secondmate_pool_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE="$SECOND_CODE_ROOT" FM_HOME="$SECOND_HOME" \
    FM_STATE_OVERRIDE="$SECOND_HOME/state" FM_DATA_OVERRIDE="$SECOND_HOME/data" \
    FM_PROJECTS_OVERRIDE="$SECOND_HOME/projects" FM_CONFIG_OVERRIDE="$SECOND_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$SECOND_HOME_WT" FM_FAKE_PANE_STALE_READS=0 \
    FM_FAKE_PANE_COUNTFILE="$SECOND_COUNTFILE" FM_FAKE_LAUNCH_LOG="$SECOND_LAUNCHLOG" \
    PATH="$SECOND_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$SECOND_PROJECT" --mode no-mistakes --yolo off 2>&1
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

test_secondmate_home_uses_own_treehouse_pool() {
  local rec id out status trust_home
  id=settle-secondmate-pool-z3
  rec=$(make_secondmate_pool_case settle-secondmate-pool "$id")
  read_secondmate_pool_record "$rec"
  trust_home="$SECOND_CASE/claude-home"
  mkdir -p "$trust_home"

  if HOME="$trust_home" CLAUDE_CONFIG_DIR='' \
    "$ROOT/bin/fm-claude-trust.sh" "$SECOND_PRIMARY_WT" "$SECOND_PROJECT" >/dev/null 2>&1; then
    fail "Claude trust accepted a worktree from the primary project clone for a secondmate project"
  fi
  HOME="$trust_home" CLAUDE_CONFIG_DIR='' \
    "$ROOT/bin/fm-claude-trust.sh" "$SECOND_HOME_WT" "$SECOND_PROJECT" >/dev/null \
    || fail "Claude trust rejected the secondmate project's own worktree"

  out=$(run_secondmate_pool_spawn "$id")
  status=$?
  expect_code 0 "$status" "secondmate-home spawn should succeed with its own pooled worktree"
  assert_contains "$out" "spawned $id" "secondmate-home spawn did not report success"
  assert_grep "treehouse get --root $SECOND_HOME/config" "$SECOND_LAUNCHLOG" \
    "secondmate-home spawn did not type the home-specific Treehouse root"
  assert_grep "worktree=$SECOND_HOME_WT" "$SECOND_HOME/state/$id.meta" \
    "secondmate-home spawn did not record the worktree from its own pool"
  pass "a linked secondmate home scopes Treehouse get to its own project pool and passes Claude trust"
}

test_secondmate_home_refuses_treehouse_without_root_option() {
  local rec id out status
  id=settle-secondmate-pool-oldth-z4
  rec=$(make_secondmate_pool_case settle-secondmate-pool-oldth "$id")
  read_secondmate_pool_record "$rec"
  # Treehouse before v2.2.0 has no --root and ignores TREEHOUSE_ROOT too, so the
  # pool identity would silently resolve to whichever clone shares this remote -
  # the primary home's. Refusing is the only safe outcome.
  fm_fake_treehouse "$SECOND_FAKEBIN" --no-root

  out=$(run_secondmate_pool_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when treehouse cannot scope the pool to this home"
  assert_contains "$out" "no --root option" \
    "the refusal did not name the missing Treehouse option"
  assert_absent "$SECOND_HOME/state/$id.meta" \
    "a refused spawn must not record task metadata"
  # The refusal lands before anything is typed, so the log usually does not exist
  # at all; guard the read so the case still states the invariant that matters.
  [ ! -f "$SECOND_LAUNCHLOG" ] || assert_no_grep "treehouse get" "$SECOND_LAUNCHLOG" \
    "a refused spawn must not type an unscoped Treehouse acquisition"
  pass "a secondmate home refuses to acquire a worktree when treehouse cannot scope the pool to it"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_secondmate_home_uses_own_treehouse_pool
test_secondmate_home_refuses_treehouse_without_root_option

echo "# all fm-spawn-worktree-settle tests passed"
