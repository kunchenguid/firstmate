#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the wait loop after `treehouse get`).
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
#
# The third transient is a checkout still being written. While `git worktree
# add` populates a new slot, its `.git` link already exists and its `git reset
# --hard` child runs inside the slot, so a pane reporting its foreground cwd
# reads the slot as an isolated worktree from the first poll, and `git status`
# lists every file not yet written. Adopting it then refused the launch as "not
# clean", and on a checkout slower than the wait the abort interrupted git and
# left a partial slot folder behind. The last cases cover a checkout that
# finishes, one that outlasts the ordinary wait, and one that never finishes.
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
    if [ "$n" = "${FM_FAKE_SETTLE_AT:-}" ]; then
      "${FM_FAKE_SETTLE_CMD:?FM_FAKE_SETTLE_CMD unset}"
    fi
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
    PATH="$FAKEBIN_DIR:${SETTLE_TEST_PATH:-$PATH}" \
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
  [ "$reads" -eq 2 ] || fail "already-settled pane took $reads reads to confirm - expected the first read plus one confirmation"
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

# make_checkout_case <name> <id> <shape> builds a slot whose checkout is still
# being written, plus the script the fake pane runs to finish it. Shape `pool`
# lays the slot out as a Treehouse pool slot that the pool state does not list
# yet, which is how `treehouse get` leaves a new slot until its checkout is
# done; shape `plain` is a linked worktree outside any pool carrying git's own
# `initializing` lock. Either way the slot is missing a tracked file until the
# finish script runs, so a spawn that adopts it early sees uncommitted work.
make_checkout_case() {
  local name=$1 id=$2 shape=$3 case_dir home proj wt fakebin countfile finish gitdir state=
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  countfile="$case_dir/pane-call-count"
  finish="$case_dir/finish-checkout"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  case "$shape" in
    pool)
      wt="$case_dir/pool/1/project"
      state="$case_dir/pool/treehouse-state.json"
      mkdir -p "$case_dir/pool/1"
      fm_git_worktree "$proj" "$wt" "slot-$name"
      printf '{"worktrees":[]}\n' > "$state"
      ;;
    plain)
      wt="$case_dir/wt"
      fm_git_worktree "$proj" "$wt" "wt-$name"
      gitdir=$(git -C "$wt" rev-parse --absolute-git-dir)
      printf 'initializing\n' > "$gitdir/locked"
      ;;
  esac
  rm "$wt/README.md"
  cat > "$finish" <<EOF
#!/usr/bin/env bash
git -C '$wt' checkout -- README.md
rm -f "\$(git -C '$wt' rev-parse --absolute-git-dir)/locked"
if [ -n '$state' ]; then
  printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":%s}]}\n' '$wt' "\$FM_FAKE_OWNER_PID" > '$state'
fi
EOF
  chmod +x "$finish"
  fm_test_spawn_brief "$home" "$id" "Exercise checkout-in-progress detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$finish|$fakebin|$countfile|0"
}

run_checkout_spawn() {
  local id=$1 settle_at=$2
  FM_FAKE_SETTLE_AT="$settle_at" FM_FAKE_SETTLE_CMD="$STALE_DIR" FM_FAKE_OWNER_PID=$$ \
    run_settle_spawn "$id"
}

# The incident: the pane reads the new pool slot while its checkout is still
# being written, for longer than the ordinary wait. The spawn must keep waiting
# until Treehouse has recorded the slot as handed out, then launch from the
# finished checkout rather than refusing it as uncommitted work.
test_pool_slot_checkout_in_progress_is_waited_out() {
  local rec id out status claim
  id=settle-checkout-pool-z5
  rec=$(make_checkout_case settle-checkout-pool "$id" pool)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_checkout_spawn "$id" 75)
  status=$?
  expect_code 0 "$status" "spawn should launch once the slot checkout finishes"$'\n'"$out"
  assert_not_contains "$out" "is not clean" \
    "spawn misread a checkout still being written as uncommitted work"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the finished slot"
  claim="$(dirname "$WT_DIR")/.fm-slot-owner"
  grep -Fxq -- "task=$id" "$claim" 2>/dev/null \
    || fail "the finished slot was not claimed for the task"
  [ "$(cat "$COUNTFILE")" -gt 75 ] \
    || fail "spawn adopted the slot before its checkout finished"
  pass "a pool slot whose checkout is still being written is waited out, past the ordinary wait"
}

# Outside a pool the same transient is recognised from git's own marker: a
# linked worktree `git worktree add` is still checking out is locked as
# initializing.
test_initializing_worktree_is_waited_out() {
  local rec id out status
  id=settle-checkout-plain-z6
  rec=$(make_checkout_case settle-checkout-plain "$id" plain)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_checkout_spawn "$id" 5)
  status=$?
  expect_code 0 "$status" "spawn should launch once git finishes initializing the worktree"$'\n'"$out"
  assert_not_contains "$out" "is not clean" \
    "spawn misread an initializing worktree as uncommitted work"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the initialized worktree"
  pass "a worktree git is still initializing is waited out"
}

# A checkout that never finishes still ends in a refusal that names the cause,
# and the refusal neither claims the slot nor touches its files.
test_checkout_that_never_finishes_refuses_without_claiming() {
  local rec id out status
  id=settle-checkout-stuck-z7
  rec=$(make_checkout_case settle-checkout-stuck "$id" pool)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_checkout_spawn "$id" 0)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot whose checkout never finished"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not report the unfinished acquisition"
  assert_contains "$out" "still being written" \
    "the refusal did not say the slot checkout was still in progress"
  assert_not_contains "$out" "is not clean" \
    "spawn misread an unfinished checkout as uncommitted work"
  [ ! -e "$(dirname "$WT_DIR")/.fm-slot-owner" ] || fail "refused spawn claimed the unfinished slot"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ ! -e "$WT_DIR/README.md" ] || fail "refused spawn changed the unfinished checkout"
  pass "a checkout that never finishes is refused by name, unclaimed and untouched"
}

test_pool_slot_without_jq_refuses_immediately() {
  local rec id out status no_jq dir tool
  id=settle-no-jq-pool-z8
  rec=$(make_checkout_case settle-no-jq-pool "$id" pool)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  no_jq="$TMP_ROOT/no-jq-bin"
  mkdir -p "$no_jq"
  local -a dirs
  IFS=: read -r -a dirs <<< "$PATH"
  for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || continue
    for tool in "$dir"/*; do
      [ -x "$tool" ] && [ ! -d "$tool" ] || continue
      [ "${tool##*/}" = jq ] && continue
      [ -e "$no_jq/${tool##*/}" ] || ln -s "$tool" "$no_jq/${tool##*/}"
    done
  done
  out=$(SETTLE_TEST_PATH="$no_jq" run_checkout_spawn "$id" 0)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched without jq on a pool slot"
  assert_contains "$out" 'jq is required' "missing jq refusal did not name the requirement"
  [ "$(cat "$COUNTFILE")" -lt 3 ] || fail "spawn waited instead of refusing promptly without jq"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ ! -e "$(dirname "$WT_DIR")/.fm-slot-owner" ] || fail "refused spawn claimed the slot"
  pass "missing jq refuses a Treehouse pool slot promptly without publishing or claiming"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_pool_slot_checkout_in_progress_is_waited_out
test_initializing_worktree_is_waited_out
test_checkout_that_never_finishes_refuses_without_claiming
test_pool_slot_without_jq_refuses_immediately

echo "# all fm-spawn-worktree-settle tests passed"
