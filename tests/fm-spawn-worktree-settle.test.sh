#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop and allocator lifetime bound in bin/fm-spawn.sh.
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

# Execute the actual allocation line delivered to the pane, under an outer
# fixture watchdog. Before the fix, unbounded treehouse get hits that watchdog;
# after the fix, the inner production bound returns and reaps its child tree.
make_allocator_fakebin() {
  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -f "$FM_ALLOC_CWD" ]; then cat "$FM_ALLOC_CWD"; else printf '%s\n' "$FM_ALLOC_PROJECT"; fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  send-keys)
    for arg in "$@"; do
      case "$arg" in
        'treehouse get'|fm_allocated=*)
          . "$FM_ALLOC_TIMEOUT_LIB"
          cd "$FM_ALLOC_PROJECT" || exit 1
          rc=0
          fm_run_timed 10 bash -c "$arg; pwd -P > \"\$FM_ALLOC_CWD\"; printf 'completed\\n' > \"\$FM_ALLOC_COMPLETED\"" || rc=$?
          printf '%s\n' "$rc" > "$FM_ALLOC_RESULT"
          ;;
      esac
    done
    ;;
esac
exit 0
SH
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_ALLOC_PID"
if [ "$FM_ALLOC_CASE" = success ]; then
  [ "$*" = "get --lease --lease-holder allocator-success" ] || exit 1
  printf '%s\n' "$FM_ALLOC_WORKTREE"
  exit 0
fi
# A fetch descendant ignores TERM, testing escalation independently of the
# allocator's response to TERM. A real Git HTTP helper stays in this group.
bash -c 'trap "" TERM; echo $$ > "$1"; while :; do sleep 1; done' _ "$FM_ALLOC_CHILD" &
case "$FM_ALLOC_CASE" in
  stall) wait ;;
  trickle) while :; do printf '.' >&2; sleep 0.1; done ;;
  prompt)
    printf 'Credentials: ' >&2
    read -r answer || true
    printf 'prompt-read\n' > "$FM_ALLOC_PROMPT"
    wait
    ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/treehouse"
}

allocator_pid_running() {
  local state
  kill -0 "$1" 2>/dev/null || return 1
  state=$(ps -o stat= -p "$1" 2>/dev/null || true)
  case "$state" in ''|*Z*) return 1 ;; esac
}

test_allocator_bound() {
  local behavior=$1 rec id out status parent child unrelated i result
  id="allocator-$behavior"
  rec=$(make_primary_case "$id" "$id" 100000)
  read_settle_record "$rec"
  make_allocator_fakebin
  printf 'unlanded work\n' > "$WT_DIR/keep-me.txt"
  sleep 300 &
  unrelated=$!
  out=$(FM_SPAWN_ALLOCATOR_TIMEOUT=2 FM_SPAWN_ISOLATION_TIMEOUT=6 \
    FM_ALLOC_PROJECT="$PROJ_DIR" FM_ALLOC_CWD="$HOME_DIR/cwd" FM_ALLOC_CASE="$behavior" \
    FM_ALLOC_TIMEOUT_LIB="$ROOT/bin/fm-timeout-lib.sh" \
    FM_ALLOC_COMPLETED="$HOME_DIR/completed" FM_ALLOC_RESULT="$HOME_DIR/result" FM_ALLOC_PID="$HOME_DIR/allocator.pid" \
    FM_ALLOC_CHILD="$HOME_DIR/child.pid" FM_ALLOC_PROMPT="$HOME_DIR/prompt" \
    run_settle_spawn "$id")
  status=$?
  # Clean the unrelated fixture before asserting, including on pre-fix failure.
  result=0
  kill -0 "$unrelated" 2>/dev/null || result=1
  kill "$unrelated" 2>/dev/null || true
  wait "$unrelated" 2>/dev/null || true
  [ "$result" -eq 0 ] || fail "allocator timeout killed an unrelated process"
  [ "$status" -ne 0 ] || fail "stalled allocator unexpectedly launched a worker"
  [ -f "$HOME_DIR/result" ] || fail "the pane never executed its allocator command"
  [ "$(cat "$HOME_DIR/result")" -ne 124 ] \
    || fail "allocator outlived the isolation budget and hit the outer fixture watchdog"
  [ -f "$HOME_DIR/completed" ] || fail "allocator command never returned before the fixture watchdog"
  assert_contains "$out" "within 6s" "spawn did not retain its isolation deadline"
  parent=$(cat "$HOME_DIR/allocator.pid")
  child=$(cat "$HOME_DIR/child.pid")
  for i in $(seq 1 50); do
    if ! allocator_pid_running "$parent" && ! allocator_pid_running "$child"; then break; fi
    sleep 0.1
  done
  ! allocator_pid_running "$parent" || fail "allocator survived its deadline"
  ! allocator_pid_running "$child" || fail "allocator-owned fetch child survived its deadline"
  [ "$behavior" != prompt ] || [ -f "$HOME_DIR/prompt" ] \
    || fail "credential prompt did not receive detached stdin"
  assert_grep 'unlanded work' "$WT_DIR/keep-me.txt" "timeout discarded unlanded work"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused allocation published task metadata"
  pass "$behavior allocation is bounded and only its process group is stopped"
}

test_allocator_success_with_unset_defaults() {
  local rec id out status
  id=allocator-success
  rec=$(make_primary_case "$id" "$id" 0)
  read_settle_record "$rec"
  make_allocator_fakebin
  out=$(FM_ALLOC_PROJECT="$PROJ_DIR" FM_ALLOC_WORKTREE="$WT_DIR" \
    FM_ALLOC_CWD="$HOME_DIR/cwd" FM_ALLOC_CASE=success \
    FM_ALLOC_TIMEOUT_LIB="$ROOT/bin/fm-timeout-lib.sh" \
    FM_ALLOC_COMPLETED="$HOME_DIR/completed" FM_ALLOC_RESULT="$HOME_DIR/result" \
    FM_ALLOC_PID="$HOME_DIR/allocator.pid" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "bounded allocator should hand off a successful lease"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "spawn did not adopt the allocated lease"
  [ -f "$HOME_DIR/completed" ] || fail "successful allocation did not return before worker launch"
  pass "unset timeout defaults allocate a durable lease and hand off the worker cwd"
}

test_timeout_ordering_refuses_before_allocation() {
  local rec id out status spec alloc isolation
  for spec in '5 6' '6 6' '7 6' '0 6' '02 6' 'x 6' '2 0'; do
    read -r alloc isolation <<EOF
$spec
EOF
    id="allocator-invalid-$alloc-$isolation"
    rec=$(make_primary_case "$id" "$id" 0)
    read_settle_record "$rec"
    make_allocator_fakebin
    out=$(FM_SPAWN_ALLOCATOR_TIMEOUT="$alloc" FM_SPAWN_ISOLATION_TIMEOUT="$isolation" \
      run_settle_spawn "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "spawn accepted invalid allocator/isolation ordering: $spec"
    case "$spec" in
      '5 6'|'6 6'|'7 6') assert_contains "$out" 'must be below' "invalid ordering was not explained" ;;
      *) assert_contains "$out" 'spawn timeouts must be positive integers' "invalid bounds were not explained" ;;
    esac
    [ ! -e "$COUNTFILE" ] || fail "invalid timeout configuration reached pane polling"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "invalid timeout configuration published metadata"
  done
  pass "invalid bounds and allocator/grace ordering refuse before allocation"
}

# Existing successful spawn cases also cover defaults under set -u.
unset FM_SPAWN_ALLOCATOR_TIMEOUT FM_SPAWN_ISOLATION_TIMEOUT
test_allocator_success_with_unset_defaults
test_timeout_ordering_refuses_before_allocation
test_allocator_bound stall
test_allocator_bound trickle
test_allocator_bound prompt

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline

echo "# all fm-spawn-worktree-settle tests passed"
