#!/usr/bin/env bash
# Regression test for the fm-spawn.sh wait for a task pane to enter the
# worktree its spawn leased (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop
# after `treehouse get --lease` and the `cd` into that worktree).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree. That stale path is a real git
# checkout, just the wrong one, so the wait accepts only the exact leased path,
# and only once two consecutive reads both report it.
# This test simulates transient-then-settled pane_current_path sequences with a
# fake tmux and asserts the recorded worktree is the leased one, never the stale
# read, including a linked spawning home whose pane transiently reports the
# repository's primary checkout. A pane that never settles refuses at the
# deadline and returns the lease, as does a leased path that is not isolated.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
# Every typed line is appended to FM_FAKE_TREEHOUSE_LOG, so its order against
# the treehouse calls is visible. With FM_FAKE_PANE_FOLLOW_CD=1 a typed
# `cd -- <dir>` moves the pane, and later reads report <dir>.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
cwdfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}.cwd"
case "$*" in
  *"#{pane_current_path}"*)
    countfile="$FM_FAKE_PANE_COUNTFILE"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ -f "$cwdfile" ]; then
      cat "$cwdfile"
    elif [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
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
    text=${4:-}
    [ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf 'send-keys %s\n' "$text" >> "$FM_FAKE_TREEHOUSE_LOG"
    if [ "${FM_FAKE_PANE_FOLLOW_CD:-0}" = 1 ] && [ "${text#cd -- }" != "$text" ]; then
      eval "dest=${text#cd -- }"
      printf '%s\n' "$dest" > "$cwdfile"
    fi
    exit 0
    ;;
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
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_TREEHOUSE_LOG="$COUNTFILE.treehouse" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop keeps polling until the pane reports the leased worktree.
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

# A pane that reports the leased worktree from the very first read costs that
# read, the one confirming read, and the launch-boundary cwd check - no extra
# polling cycle. Counting
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
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads - expected the first read, one confirming read, and the launch-boundary cwd check"
  grep -qxF "get --lease --lease-holder fm-task:$id" "$COUNTFILE.treehouse" \
    || fail "the spawn did not lease its worktree under its task holder: $(cat "$COUNTFILE.treehouse")"
  pass "an already-settled pane is accepted after one confirming read of the leased worktree"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. That path
# is not the spawning project, so it must be waited out rather than adopted. The
# leased path is a second linked worktree of the same repository.
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

# The pane reports the repository primary for the first reads, then settles
# into the leased slot. The primary must never be adopted as the worktree.
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
# rather than waiting forever or recording the primary, and it returns the
# lease it took so the slot is not stranded without a task.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter its leased worktree" \
    "spawn did not explain that the pane never reached its leased worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  grep -qxF "return --force --if-lease-holder fm-task:$id $WT_DIR" "$COUNTFILE.treehouse" \
    || fail "the aborted spawn did not return its leased worktree: $(cat "$COUNTFILE.treehouse")"
  pass "a pane stuck on the primary checkout fails loudly at the deadline and returns its lease"
}

# A leased path that is not an isolated worktree - here the spawning project
# itself - is refused before the pane is moved, and the lease is returned.
test_leased_path_that_is_not_isolated_is_refused() {
  local rec id out status
  id=settle-lease-not-isolated-z5
  rec=$(make_settle_case settle-lease-not-isolated "$id" 0)
  read_settle_record "$rec"

  out=$(FM_FAKE_LEASE_PATH="$PROJ_DIR" run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a leased path that is the project itself"$'\n'"$out"
  assert_contains "$out" "treehouse leased '$PROJ_DIR'" \
    "the refusal did not name the leased path"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  grep -qxF "return --force --if-lease-holder fm-task:$id $PROJ_DIR" "$COUNTFILE.treehouse" \
    || fail "the refused spawn did not return its lease: $(cat "$COUNTFILE.treehouse")"
  pass "a leased path that is not an isolated worktree is refused and its lease returned"
}

# A spawn that aborts after its pane entered the leased worktree, but before any
# agent launched, moves the pane's shell back to the project before it returns
# the lease, so the return cannot kill the window the error names or leave a
# stray shell in the slot. Here the slot is dirty, so the base refresh refuses.
test_aborted_spawn_moves_pane_out_before_returning_lease() {
  local rec id out status log cd_back
  id=settle-abort-cd-back-z6
  rec=$(make_settle_case settle-abort-cd-back "$id" 0)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  touch "$WT_DIR/uncommitted-work"

  out=$(FM_FAKE_PANE_FOLLOW_CD=1 FM_FAKE_PANE_PATH="$PROJ_DIR" FM_FAKE_LEASE_PATH="$WT_DIR" run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a dirty pooled worktree"$'\n'"$out"
  assert_contains "$out" "is not clean" "spawn did not refuse the dirty slot"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  log=$(cat "$COUNTFILE.treehouse")
  cd_back=$(grep -nxF "send-keys cd -- '$PROJ_DIR'" "$COUNTFILE.treehouse" | cut -d: -f1 | tail -n1)
  [ -n "$cd_back" ] || fail "the aborted spawn did not move its pane back to the project: $log"
  grep -nxF "return --force --if-lease-holder fm-task:$id $WT_DIR" "$COUNTFILE.treehouse" | cut -d: -f1 |
    awk -v after="$cd_back" '$1 > after { found = 1 } END { exit !found }' ||
    fail "the aborted spawn did not return its lease after moving its pane out: $log"
  [ "$(cat "$COUNTFILE.cwd")" = "$PROJ_DIR" ] || fail "the pane did not end in the project"
  pass "an aborted spawn moves its pane back to the project before returning the lease"
}

# A pane that does not leave the leased worktree when told to keeps the lease:
# returning it would kill the pane's shell or hand the slot on with it inside.
test_aborted_spawn_keeps_lease_when_pane_stays_in_worktree() {
  local rec id out status
  id=settle-abort-pane-stays-z7
  rec=$(make_settle_case settle-abort-pane-stays "$id" 0)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  touch "$WT_DIR/uncommitted-work"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a dirty pooled worktree"$'\n'"$out"
  grep -qxF "send-keys cd -- '$PROJ_DIR'" "$COUNTFILE.treehouse" ||
    fail "the aborted spawn did not try to move its pane back to the project: $(cat "$COUNTFILE.treehouse")"
  ! grep -q "^return " "$COUNTFILE.treehouse" ||
    fail "the aborted spawn returned the lease while its pane stayed in the worktree: $(cat "$COUNTFILE.treehouse")"
  assert_contains "$out" "treehouse return --force $WT_DIR" \
    "the warning did not name the manual lease return"
  pass "an aborted spawn whose pane stays in the worktree keeps the lease and names the manual return"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_leased_path_that_is_not_isolated_is_refused
test_aborted_spawn_moves_pane_out_before_returning_lease
test_aborted_spawn_keeps_lease_when_pane_stays_in_worktree

echo "# all fm-spawn-worktree-settle tests passed"
