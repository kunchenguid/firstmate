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
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

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
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
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

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

# make_two_clone_case <name> builds two Firstmate homes that each clone one
# origin under the same repository name, the shape a root home and a secondmate
# home take, plus one Treehouse-layout pool those clones share (Treehouse names a
# pool by repository name and origin). Slot 1 is a linked worktree of the first
# clone and slot 2 one of the second. The second home is the one that spawns.
make_two_clone_case() {
  local name=$1 case_dir seed origin pool
  case_dir="$TMP_ROOT/$name"
  seed="$case_dir/seed"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool/bodl-abc123"
  fm_git_init_commit "$seed"
  git clone --quiet --bare "$seed" "$origin"
  TWO_CLONE_MAIN_HOME="$case_dir/main-home"
  TWO_CLONE_MATE_HOME="$case_dir/mate-home"
  fm_test_spawn_home "$TWO_CLONE_MAIN_HOME" codex
  fm_test_spawn_home "$TWO_CLONE_MATE_HOME" codex
  TWO_CLONE_MAIN="$TWO_CLONE_MAIN_HOME/projects/bodl"
  TWO_CLONE_MATE="$TWO_CLONE_MATE_HOME/projects/bodl"
  git clone --quiet "file://$origin" "$TWO_CLONE_MAIN"
  git clone --quiet "file://$origin" "$TWO_CLONE_MATE"
  mkdir -p "$pool/1" "$pool/2"
  printf '{"worktrees":[]}\n' > "$pool/treehouse-state.json"
  git -C "$TWO_CLONE_MAIN" worktree add --quiet --detach "$pool/1/bodl"
  git -C "$TWO_CLONE_MATE" worktree add --quiet --detach "$pool/2/bodl"
  TWO_CLONE_MAIN_SLOT="$pool/1/bodl"
  TWO_CLONE_MATE_SLOT="$pool/2/bodl"
  TWO_CLONE_FAKEBIN=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_sleep_noop "$TWO_CLONE_FAKEBIN"
}

common_dir_of() {
  (cd "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)
}

# The incident: Treehouse before 3.0.0 hands the second clone's spawn a free
# slot that is a worktree of the FIRST clone. That slot is never the task's own
# copy, so the spawn refuses it and says why, instead of launching there or
# failing later on a guard that says nothing about Treehouse.
test_pool_slot_of_another_clone_is_refused() {
  local id=pool-foreign-clone-z5 out status
  make_two_clone_case pool-foreign-clone
  fm_test_spawn_brief "$TWO_CLONE_MATE_HOME" "$id"

  out=$(fm_test_run_spawn "$TWO_CLONE_MATE_HOME" "$TWO_CLONE_MAIN_SLOT" "$TWO_CLONE_FAKEBIN" \
    "$id" "$TWO_CLONE_MATE" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched in a pool slot of another clone"$'\n'"$out"
  assert_contains "$out" "belongs to another clone" \
    "the refusal did not say the slot belongs to another clone"$'\n'"$out"
  assert_contains "$out" "Treehouse to 3.0.0 or later" \
    "the refusal did not name the Treehouse requirement"
  [ ! -e "$TWO_CLONE_MATE_HOME/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ ! -e "$(dirname "$TWO_CLONE_MAIN_SLOT")/.fm-slot-owner" ] ||
    fail "refused spawn claimed another clone's pool slot"
  pass "a pool slot of another clone of the same origin is refused with its cause"
}

# The same shared pool, but the slot handed out is a worktree of the spawning
# clone: the spawn records and claims it.
test_pool_slot_of_the_spawning_clone_is_accepted() {
  local id=pool-own-clone-z6 out status
  make_two_clone_case pool-own-clone
  fm_test_spawn_brief "$TWO_CLONE_MATE_HOME" "$id"

  out=$(fm_test_run_spawn "$TWO_CLONE_MATE_HOME" "$TWO_CLONE_MATE_SLOT" "$TWO_CLONE_FAKEBIN" \
    "$id" "$TWO_CLONE_MATE" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should accept its own clone's pool slot"$'\n'"$out"
  assert_grep "worktree=$TWO_CLONE_MATE_SLOT" "$TWO_CLONE_MATE_HOME/state/$id.meta" \
    "meta did not record the spawning clone's slot"
  assert_grep "task=$id" "$(dirname "$TWO_CLONE_MATE_SLOT")/.fm-slot-owner" \
    "spawn did not claim its own clone's pool slot"
  pass "a pool slot of the spawning clone is recorded and claimed"
}

# Real Treehouse, when 3.0.0 or later is installed: with a free slot of the first
# clone already in the shared pool, `treehouse get` from the second clone yields
# a slot of the second clone, and the spawn launches in it. Runs in a throwaway
# HOME so the pool, and any user config, stay out of the developer's own.
test_real_treehouse_gives_the_spawning_clone_its_own_slot() {
  local id=pool-real-treehouse-z7 out status th_home version main_slot mate_slot
  if ! command -v treehouse >/dev/null 2>&1; then
    echo "# skipped real-Treehouse case: treehouse is not installed"
    return 0
  fi
  version=$(treehouse --version 2>/dev/null | head -n 1)
  case "${version#v}" in
    [0-2].*|'')
      echo "# skipped real-Treehouse case: installed treehouse '${version:-unknown}' is older than 3.0.0"
      return 0
      ;;
  esac
  make_two_clone_case pool-real-treehouse
  fm_test_spawn_brief "$TWO_CLONE_MATE_HOME" "$id"
  th_home="$TMP_ROOT/pool-real-treehouse/treehouse-home"
  mkdir -p "$th_home"

  main_slot=$(cd "$TWO_CLONE_MAIN" && env -u TREEHOUSE_ROOT HOME="$th_home" \
    TREEHOUSE_NO_UPDATE_CHECK=1 treehouse get --lease 2>/dev/null) ||
    fail "real treehouse could not lease a slot for the first clone"
  (cd "$TWO_CLONE_MAIN" && env -u TREEHOUSE_ROOT HOME="$th_home" \
    TREEHOUSE_NO_UPDATE_CHECK=1 treehouse return --force "$main_slot" >/dev/null 2>&1) ||
    fail "real treehouse could not return the first clone's slot"
  mate_slot=$(cd "$TWO_CLONE_MATE" && env -u TREEHOUSE_ROOT HOME="$th_home" \
    TREEHOUSE_NO_UPDATE_CHECK=1 treehouse get --lease 2>/dev/null) ||
    fail "real treehouse could not lease a slot for the second clone"
  [ "$(common_dir_of "$mate_slot")" = "$(common_dir_of "$TWO_CLONE_MATE")" ] ||
    fail "real treehouse $version handed the second clone '$mate_slot', a slot of another clone"

  out=$(fm_test_run_spawn "$TWO_CLONE_MATE_HOME" "$mate_slot" "$TWO_CLONE_FAKEBIN" \
    "$id" "$TWO_CLONE_MATE" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should launch in the slot real treehouse gave its clone"$'\n'"$out"
  assert_grep "worktree=$mate_slot" "$TWO_CLONE_MATE_HOME/state/$id.meta" \
    "meta did not record the real treehouse slot"
  pass "real treehouse $version gives the second clone its own slot, and the spawn launches there"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_pool_slot_of_another_clone_is_refused
test_pool_slot_of_the_spawning_clone_is_accepted
test_real_treehouse_gives_the_spawning_clone_its_own_slot
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline

echo "# all fm-spawn-worktree-settle tests passed"
