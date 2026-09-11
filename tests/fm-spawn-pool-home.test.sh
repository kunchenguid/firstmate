#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's per-home Treehouse pool root and the
# clone-membership guard on the worktree a spawn is handed (the bin/fm-spawn.sh
# header owns the contract; bin/fm-wake-lib.sh's fm_treehouse_pool_root owns
# the root).
#
# Treehouse keys a pool by the clone's directory basename plus a hash of its
# origin URL, never by the clone, so two homes holding same-named clones of one
# origin under a shared root are handed each other's worktrees. Before this
# guard, only Claude's trust pre-registration ever refused that shape, and only
# for claude: a Cursor spawn launched straight into the other home's clone.
# These cases drive the real spawn with a fake terminal and prove the
# harness-independent half. A pane settled on a worktree of another clone of
# the same origin is refused at the settle deadline naming both clones and
# publishes no task; a pane on the project's own worktree launches; and the
# text the pane actually receives carries this home's physical path as --root,
# because the pane's shell never sees the spawning process's exports.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-home)

# make_pool_fakebin <dir>: a fake tmux that records every call's argv, one per
# line, to FM_TMUX_REC, answers the pane-path query from FM_FAKE_PANE_PATH, and
# names the created window so the recorded send-keys target is stable. sleep is
# a no-op so the 60-poll settle deadline costs no wall clock.
make_pool_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TMUX_REC:?FM_TMUX_REC unset}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '%s\n' "@spawnwid"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|send-keys|set-window-option|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> [home-dirname]: one origin, two clones of it with the
# SAME directory basename under different parents (the two-homes shape), and
# one detached worktree of each. The spawning project is the first clone; the
# second clone's worktree is what a shared pool hands a colliding home.
make_case() {
  local name=$1 id=$2 home_name=${3:-home} case_dir home seed origin own other own_wt other_wt fakebin rec
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/$home_name"
  seed="$case_dir/seed"
  origin="$case_dir/origin.git"
  own="$case_dir/own/proj"
  other="$case_dir/other/proj"
  own_wt="$case_dir/pool-own/proj"
  other_wt="$case_dir/pool-other/proj"
  rec="$case_dir/tmux.rec"
  fakebin=$(make_pool_fakebin "$case_dir/fake")
  fm_git_init_commit "$seed"
  git clone --quiet --bare "$seed" "$origin"
  git clone --quiet "file://$origin" "$own"
  git clone --quiet "file://$origin" "$other"
  git -C "$own" worktree add --quiet --detach "$own_wt" HEAD
  git -C "$other" worktree add --quiet --detach "$other_wt" HEAD
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id" "Exercise the per-home pool root and clone guard for $id."
  : > "$rec"
  printf '%s\n' "$case_dir|$home|$own|$other|$own_wt|$other_wt|$fakebin|$rec"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR OWN_DIR OTHER_DIR OWN_WT OTHER_WT FAKEBIN_DIR REC <<EOF
$1
EOF
}

run_pool_spawn() {  # <id> <pane-path> [home]
  local id=$1 pane=$2 home=${3:-$HOME_DIR}
  FM_TMUX_REC="$REC" \
    fm_test_run_spawn "$home" "$pane" "$FAKEBIN_DIR" \
    "$id" "$OWN_DIR" --mode no-mistakes --yolo off
}

physical() { (cd -P -- "$1" && pwd -P); }

# The collision: the pane settles on a real, distinct, linked worktree - of the
# OTHER clone. Every older isolation check passes it. The spawn must refuse at
# the deadline, name the clone the worktree belongs to and the one it asked
# for, and publish nothing.
test_worktree_of_another_clone_is_refused() {
  local rec id out status other_common
  id=pool-home-foreign-k1
  rec=$(make_case foreign "$id")
  read_case "$rec"
  other_common=$(physical "$OTHER_DIR/.git")

  out=$(run_pool_spawn "$id" "$OTHER_WT")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a worktree of another clone"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "the refusal did not say the pane never reached an acceptable worktree"
  assert_contains "$out" "$(physical "$OTHER_WT")" \
    "the refusal did not name the worktree the pane was handed"
  assert_contains "$out" "worktree of another clone" \
    "the refusal did not say the worktree belongs to another clone"
  assert_contains "$out" "$other_common" \
    "the refusal did not name the clone the worktree actually belongs to"
  assert_contains "$out" "$(physical "$OWN_DIR/.git")" \
    "the refusal did not name the clone the spawn asked for"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_grep "treehouse get --root " "$REC" \
    "the spawn refused before it ever asked treehouse for a worktree"
  pass "a worktree of another clone of the same origin is refused at the deadline, naming both clones"
}

# The correct case: the project's own worktree launches, and the pane received
# this home's physical path as the pool root, as literal command text.
test_own_worktree_launches_with_the_home_as_pool_root() {
  local rec id out status home_phys
  id=pool-home-own-k2
  rec=$(make_case own "$id")
  read_case "$rec"
  home_phys=$(physical "$HOME_DIR")

  out=$(run_pool_spawn "$id" "$OWN_WT")
  status=$?
  expect_code 0 "$status" "spawn into the project's own worktree should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$OWN_WT" "$HOME_DIR/state/$id.meta" \
    "meta did not record the project's own worktree"
  assert_grep "send-keys -t @spawnwid treehouse get --root '$home_phys' Enter" "$REC" \
    "the pane did not receive this home's physical path as the pool root"
  assert_no_grep "send-keys -t @spawnwid treehouse get Enter" "$REC" \
    "the pane still received a rootless treehouse get"
  pass "the project's own worktree launches and the pane is told to pool under this home"
}

# FM_HOME may be spelled through a symlink; the root sent must be the physical
# home so one home never gets two pools.
test_pool_root_is_the_physical_home() {
  local rec id out status link home_phys
  id=pool-home-link-k3
  rec=$(make_case link "$id")
  read_case "$rec"
  home_phys=$(physical "$HOME_DIR")
  link="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$link"

  out=$(run_pool_spawn "$id" "$OWN_WT" "$link")
  status=$?
  expect_code 0 "$status" "spawn through a symlinked home should succeed"$'\n'"$out"
  assert_grep "treehouse get --root '$home_phys' Enter" "$REC" \
    "the pool root was not resolved to the physical home"
  assert_no_grep "treehouse get --root '$link' Enter" "$REC" \
    "the pool root kept the symlinked spelling"
  pass "the pool root is the physical home even when FM_HOME is a symlink"
}

# A quote in the home path must survive the trip into the pane as shell text.
test_pool_root_quoting_survives_a_single_quote() {
  local rec id out status home_phys expected
  id=pool-home-quote-k4
  rec=$(make_case quote "$id" "it's home")
  read_case "$rec"
  home_phys=$(physical "$HOME_DIR")
  expected="treehouse get --root '${home_phys//\'/\'\\\'\'}' Enter"

  out=$(run_pool_spawn "$id" "$OWN_WT")
  status=$?
  expect_code 0 "$status" "spawn from a home path containing a quote should succeed"$'\n'"$out"
  grep -F -- "$expected" "$REC" >/dev/null \
    || fail "the pane did not receive a correctly quoted pool root; expected: $expected"$'\n'"$(cat "$REC")"
  pass "a single quote in the home path is quoted for the pane"
}

test_worktree_of_another_clone_is_refused
test_own_worktree_launches_with_the_home_as_pool_root
test_pool_root_is_the_physical_home
test_pool_root_quoting_survives_a_single_quote

echo "# all fm-spawn-pool-home tests passed"
