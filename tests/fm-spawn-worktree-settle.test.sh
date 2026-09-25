#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, spawn_await_treehouse_worktree after `treehouse get`).
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
  *"#{pane_current_command}"*)
    printf "%s\n" "${FM_FAKE_FOREGROUND:-bash}"; exit 0 ;;
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    # A pane whose `treehouse get` hangs in the project until it is interrupted
    # (and, when asked, stays hung on the retry too).
    if [ -n "${FM_FAKE_PANE_HUNG_GETS:-}" ]; then
      gets=$(grep -c 'treehouse get' "$countfile.keys" 2>/dev/null || true)
      interrupts=$(grep -c 'C-c' "$countfile.keys" 2>/dev/null || true)
      if [ "${interrupts:-0}" -lt "$FM_FAKE_PANE_HUNG_GETS" ] || [ "${gets:-0}" -le "${interrupts:-0}" ]; then
        if [ -n "${FM_FAKE_OWN_SLOT:-}" ] && [ ! -e "$countfile.own-seen" ]; then
          [ -e "$countfile.own-first" ] && touch "$countfile.own-seen" || touch "$countfile.own-first"
          printf '%s\n' "$FM_FAKE_OWN_SLOT"
          exit 0
        fi
        printf '%s\n' "$FM_FAKE_PANE_PROJECT"
        exit 0
      fi
    fi
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
  capture-pane)
    interrupts=$(grep -c C-c "$FM_FAKE_PANE_COUNTFILE.keys" 2>/dev/null || true)
    if [ "${FM_FAKE_GET_SURVIVES_INTERRUPT:-0}" != 1 ] && [ "$interrupts" -gt 0 ]; then
      probe=$(grep 'printf.*fm-idle-' "$FM_FAKE_PANE_COUNTFILE.keys" 2>/dev/null | tail -1)
      [ -z "$probe" ] || printf '%s\n' "$probe" | grep -o '[0-9]*-[0-9]*-[0-9]*' | head -1 | sed 's/^/fm-idle-/'
    fi
    exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ "${FM_FAKE_SLOT_DIR_APPEARS:-0}" = 1 ] && [[ " $* " == *' C-c '* ]]; then
      mkdir -p "$TREEHOUSE_ROOT/unregistered-slot"
    fi
    [ -z "${FM_FAKE_PANE_COUNTFILE:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_PANE_COUNTFILE.keys"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  status)
    if [ "${FM_FAKE_POOL_CHANGES:-0}" = 1 ] && grep -q C-c "$FM_FAKE_PANE_COUNTFILE.keys" 2>/dev/null; then
      printf 'new unobserved slot\n'
    else
      printf 'unchanged pool\n'
    fi ;;
  return) printf '%s\n' "$2" >> "$FM_FAKE_PANE_COUNTFILE.return"; [ "${FM_FAKE_RETURN_SKIPS:-0}" != 1 ] ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
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
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$case_dir/pool"
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
    FM_FAKE_PANE_PROJECT="$PROJ_DIR" FM_FAKE_OWN_SLOT="${HUNG_SLOT_DIR:-}" \
    TREEHOUSE_ROOT="$(dirname "$PROJ_DIR")/pool" \
    PATH="$FAKEBIN_DIR:${SETTLE_TEST_PATH:-$PATH}" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# make_hung_treehouse <fakebin> replaces the fake treehouse with one whose
# `status` never answers, standing in for a pool whose state lock another
# process holds. It uses the real sleep because the case also fakes sleep.
make_hung_treehouse() {
  local real_sleep
  real_sleep=$(command -v sleep)
  cat > "$1/treehouse" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  status)
    if grep -q 'C-c' "\$FM_FAKE_PANE_COUNTFILE.keys" 2>/dev/null; then
      exec "$real_sleep" 60
    fi
    printf '[]\n' ;;
esac
exit 0
SH
  chmod +x "$1/treehouse"
}

key_count() {  # <pattern>
  grep -c -- "$1" "$COUNTFILE.keys" 2>/dev/null || true
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

# Pool evidence: this slot belongs to the same repository, has no task claim,
# and was seen twice by the hung pane before it returned to the project.
make_hung_slot() {
  local slot
  slot="$(dirname "$STALE_DIR")/pool/1/repo"
  mkdir -p "$(dirname "$slot")"
  git -C "$PROJ_DIR" worktree add -q -b "hung-${1}" "$slot"
  printf '{"worktrees":[]}\n' > "$(dirname "$(dirname "$slot")")/treehouse-state.json"
  HUNG_SLOT_DIR=$slot
}

test_hung_get_in_project_is_interrupted_and_retried() {
  local rec id out status
  id=settle-hung-retry-z5
  rec=$(make_settle_case settle-hung-retry "$id" 0)
  read_settle_record "$rec"
  make_hung_slot "$id"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_PANE_HUNG_GETS=1 run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "observed clean slot should be returned and get retried"$'\n'"$out"
  assert_grep "$HUNG_SLOT_DIR" "$COUNTFILE.return" "observed slot was not returned"
  [ "$(key_count C-c)" -eq 1 ] || fail "expected one interrupt"
  [ "$(key_count 'treehouse get')" -eq 2 ] || fail "expected exactly two gets"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "retry did not enter new slot"
  pass "observed clean pool slot is returned before one retry"
}

test_hung_slot_with_work_is_not_destroyed() {
  local rec id out status
  id=settle-hung-work-z8
  rec=$(make_settle_case settle-hung-work "$id" 0)
  read_settle_record "$rec"
  make_hung_slot "$id"
  printf 'work\n' > "$HUNG_SLOT_DIR/uncommitted"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_PANE_HUNG_GETS=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn retried despite dirty observed slot"
  assert_contains "$out" "dirty or no longer" "missing dirty-slot refusal"
  [ ! -e "$COUNTFILE.return" ] || fail "returned dirty slot"
  [ "$(key_count 'treehouse get')" -eq 1 ] || fail "retried despite dirty slot"
  pass "dirty observed slot prevents retry"
}

test_unidentified_slot_retries_when_pool_unchanged() {
  local rec id out status
  id=settle-hung-unknown-z9
  rec=$(make_settle_case settle-hung-unknown "$id" 0)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  HUNG_SLOT_DIR=""
  out=$(FM_FAKE_PANE_HUNG_GETS=1 run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "unchanged pool should allow no-slot retry"$'\n'"$out"
  [ "$(key_count 'treehouse get')" -eq 2 ] || fail "missing no-slot retry"
  [ ! -e "$COUNTFILE.return" ] || fail "returned an unidentified slot"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "retry did not reach worktree"
  pass "unchanged pool permits one no-slot retry"
}

test_unidentified_slot_refuses_changed_pool() {
  local rec id out status
  id=settle-hung-changed-z12
  rec=$(make_settle_case settle-hung-changed "$id" 0)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  HUNG_SLOT_DIR=""
  out=$(FM_FAKE_PANE_HUNG_GETS=1 FM_FAKE_POOL_CHANGES=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn retried with changed pool"
  assert_contains "$out" 'cannot prove interrupted get created no slot' 'missing changed-pool refusal'
  [ "$(key_count 'treehouse get')" -eq 1 ] || fail "retried with changed pool"
  pass "changed pool prevents no-slot retry"
}

test_unregistered_slot_directory_refuses_retry() {
  local rec id out status
  id=settle-hung-unregistered-z13
  rec=$(make_settle_case settle-hung-unregistered "$id" 0)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  HUNG_SLOT_DIR=""
  out=$(FM_FAKE_PANE_HUNG_GETS=1 FM_FAKE_SLOT_DIR_APPEARS=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn retried after unregistered slot directory appeared"
  assert_contains "$out" 'cannot prove interrupted get created no slot' 'missing unregistered-slot refusal'
  [ "$(key_count 'treehouse get')" -eq 1 ] || fail "retried after unregistered slot appeared"
  pass "unregistered pool slot directory prevents retry"
}

test_claimed_slot_refuses_retry() {
  local rec id out status
  id=settle-hung-claimed-z11
  rec=$(make_settle_case settle-hung-claimed "$id" 0)
  read_settle_record "$rec"
  make_hung_slot "$id"
  printf 'task=another-task\nhome=elsewhere\n' > "$(dirname "$HUNG_SLOT_DIR")/.fm-slot-owner"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_PANE_HUNG_GETS=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail 'retried claimed slot'
  assert_contains "$out" 'existing task claim' 'missing claim refusal'
  [ ! -e "$COUNTFILE.return" ] || fail 'returned claimed slot'
  pass "another task's claim prevents return and retry"
}

test_get_surviving_interrupt_refuses_retry() {
  local rec id out status
  id=settle-hung-survives-z10
  rec=$(make_settle_case settle-hung-survives "$id" 0)
  read_settle_record "$rec"
  make_hung_slot "$id"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_PANE_HUNG_GETS=1 FM_FAKE_GET_SURVIVES_INTERRUPT=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail 'retried busy pane'
  assert_contains "$out" 'could not confirm an idle shell' 'missing busy-pane refusal'
  [ "$(key_count 'treehouse get')" -eq 1 ] || fail 'retried busy pane'
  pass "get surviving C-c prevents retry"
}

test_hung_get_that_hangs_again_refuses_after_one_retry() {
  local rec id out status
  id=settle-hung-twice-z6
  rec=$(make_settle_case settle-hung-twice "$id" 0)
  read_settle_record "$rec"
  make_hung_slot "$id"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_PANE_HUNG_GETS=2 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail 'accepted second hung get'
  assert_contains "$out" 'attempts: 2' 'missing retry count'
  [ "$(key_count 'treehouse get')" -eq 2 ] || fail 'retried more than once'
  [ "$(key_count C-c)" -eq 2 ] || fail 'second hang was not interrupted'
  pass "second hang refuses after exactly one retry"
}

test_hung_get_behind_a_held_pool_lock_refuses_without_retry() {
  local rec id out status
  id=settle-hung-locked-z7
  rec=$(make_settle_case settle-hung-locked "$id" 0)
  read_settle_record "$rec"
  make_hung_slot "$id"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  make_hung_treehouse "$FAKEBIN_DIR"
  out=$(FM_FAKE_PANE_HUNG_GETS=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail 'retried behind held pool lock'
  assert_contains "$out" 'treehouse status failed' 'missing status refusal'
  [ "$(key_count 'treehouse get')" -eq 1 ] || fail 'retried behind held lock'
  pass "unresponsive pool status prevents retry"
}

# make_checkout_case <name> <id> builds a Treehouse pool slot whose checkout
# is still being written, plus the script the fake pane runs to finish it.
# The state does not list a new slot until checkout finishes. The slot is
# missing a tracked file until the finish script runs.
make_checkout_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin countfile finish state
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  countfile="$case_dir/pane-call-count"
  finish="$case_dir/finish-checkout"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  wt="$case_dir/pool/1/project"
  state="$case_dir/pool/treehouse-state.json"
  mkdir -p "$case_dir/pool/1"
  fm_git_worktree "$proj" "$wt" "slot-$name"
  printf '{"worktrees":[]}\n' > "$state"
  rm "$wt/README.md"
  cat > "$finish" <<EOF
#!/usr/bin/env bash
git -C '$wt' checkout -- README.md
printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":%s}]}\n' '$wt' "\$FM_FAKE_OWNER_PID" > '$state'
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
  rec=$(make_checkout_case settle-checkout-pool "$id")
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

# A checkout that never finishes still ends in a refusal that names the cause,
# and the refusal neither claims the slot nor touches its files.
# A live checkout still in progress after the hang threshold must not be
# interrupted, returned, or retried just because its first 300 polls elapsed.
test_checkout_beyond_hang_threshold_keeps_writing() {
  local rec id out status
  id=settle-checkout-long-z12
  rec=$(make_checkout_case settle-checkout-long "$id")
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(run_checkout_spawn "$id" 310)
  status=$?
  expect_code 0 "$status" "slow checkout should finish without interruption"$'\n'"$out"
  [ "$(cat "$COUNTFILE")" -ge 310 ] || fail "adopted writing slot before checkout finished"
  [ "$(key_count C-c)" -eq 0 ] || fail "interrupted a writing checkout"
  [ "$(key_count 'treehouse get')" -eq 1 ] || fail "retried a writing checkout"
  [ ! -e "$COUNTFILE.return" ] || fail "returned a writing checkout"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "failed to acquire finished checkout"
  pass "checkout writing beyond 300 polls remains untouched and completes"
}

test_checkout_that_never_finishes_refuses_without_claiming() {
  local rec id out status
  id=settle-checkout-stuck-z7
  rec=$(make_checkout_case settle-checkout-stuck "$id")
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

test_leased_pool_slot_waits_for_handoff() {
  local rec id out status state
  id=settle-leased-pool-z9
  rec=$(make_checkout_case settle-leased-pool "$id")
  read_settle_record "$rec"
  state="$(dirname "$(dirname "$WT_DIR")")/treehouse-state.json"
  printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":%s,"leased":true,"lease_holder":"acquisition incomplete"}]}\n' "$WT_DIR" "$$" > "$state"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_checkout_spawn "$id" 5)
  status=$?
  expect_code 0 "$status" "spawn should wait for the leased slot to be handed out"$'\n'"$out"
  [ "$(cat "$COUNTFILE")" -ge 5 ] || fail "spawn adopted the leased slot before handoff"
  assert_not_contains "$out" "is not clean" "spawn adopted a leased slot mid-checkout"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "spawn did not adopt the released slot"
  pass "leased pool slot with live owner waits until handoff"
}

test_pool_slot_without_jq_refuses_immediately() {
  local rec id out status no_jq dir tool
  id=settle-no-jq-pool-z8
  rec=$(make_checkout_case settle-no-jq-pool "$id")
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
test_hung_get_in_project_is_interrupted_and_retried
test_hung_slot_with_work_is_not_destroyed
test_unidentified_slot_retries_when_pool_unchanged
test_unidentified_slot_refuses_changed_pool
test_unregistered_slot_directory_refuses_retry
test_claimed_slot_refuses_retry
test_get_surviving_interrupt_refuses_retry
test_hung_get_that_hangs_again_refuses_after_one_retry
test_hung_get_behind_a_held_pool_lock_refuses_without_retry
test_pool_slot_checkout_in_progress_is_waited_out
test_checkout_beyond_hang_threshold_keeps_writing
test_leased_pool_slot_waits_for_handoff
test_checkout_that_never_finishes_refuses_without_claiming
test_pool_slot_without_jq_refuses_immediately

echo "# all fm-spawn-worktree-settle tests passed"
