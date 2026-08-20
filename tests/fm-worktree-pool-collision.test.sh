#!/usr/bin/env bash
# Regression tests for pool-slot ownership across a task's whole life.
#
# A treehouse pool slot reads as free when no durable lease reserves it and no
# process is running inside it. Crewmate worktrees used to be taken with a bare
# `treehouse get`, which reserves nothing, so the slot was held only for as long
# as the AGENT lived. A task outlives its agent - through a dead endpoint, an
# awaited captain decision, or a finished run that has not been cleaned up - and
# the pool handed that task's directory to the next spawn. The first task's
# cleanup then reset the shared directory, deleted the branch checked out in it,
# and returned the slot, destroying the second task's work.
#
# These tests pin the invariant from both ends: a slot with a live claimant is
# never allocated into, and never returned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-pool-collision)

# --- fixtures ---------------------------------------------------------------

# A fake tmux that reports the pane sitting in FM_FAKE_PANE_PATH, and a fake
# treehouse that leases FM_FAKE_LEASE_PATH and logs every call so the tests can
# assert on what the real acquisition path would have run.
make_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# Liveness is read from the window inventory and the pane's current command, so
# the stub answers those two queries from the environment and stays silent about
# the tty - an empty foreground process group is what makes pane_current_command
# the deciding signal (bin/backends/tmux.sh, fm_backend_tmux_agent_state).
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-claude}"; exit 0 ;;
  *"#{pane_tty}"*) exit 0 ;;
esac
case "${1:-}" in
  list-windows) [ -z "${FM_FAKE_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_WINDOWS"; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys) printf '%s\n' "$*" >> "${FM_TMUX_SEND_LOG:?}"; exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf ' '
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "${FM_TREEHOUSE_LOG:?}"
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_LEASE_PATH:?}"
fi
# Model the real vendor semantics the fix turns on: a plain return ABORTS on a
# dirty worktree, preserving it, and still exits 0; --force cleans and returns.
if [ "${1:-}" = return ]; then
  forced=0
  target=
  for a in "$@"; do
    case "$a" in --force) forced=1 ;; return) ;; *) target=$a ;;
    esac
  done
  # FM_FAKE_POOL_ABORT models the race the proven-return check exists for: the
  # agent is alive until the return kills it, so work can appear between
  # cleanup's safety check and the moment the pool looks. Measured behavior:
  # the pool aborts, preserves the tree, and still exits 0.
  if [ -n "${FM_FAKE_POOL_ABORT:-}" ] && [ "$forced" -eq 0 ]; then
    [ -z "$target" ] || [ ! -d "$target" ] || printf 'raced\n' > "$target/raced-work.txt"
    printf 'Worktree has uncommitted changes. Clean and return? [Y/n] Aborted.\n'
    exit 0
  fi
  if [ -n "$target" ] && [ -d "$target" ] \
    && [ -n "$(git -C "$target" status --porcelain 2>/dev/null)" ] \
    && [ "$forced" -eq 0 ]; then
    printf 'Worktree has uncommitted changes. Clean and return? [Y/n] Aborted.\n'
    exit 0
  fi
  [ -z "$target" ] || [ ! -d "$target" ] \
    || git -C "$target" reset -q --hard >/dev/null 2>&1 \
    && [ -z "$target" ] || [ ! -d "$target" ] || git -C "$target" clean -qfd >/dev/null 2>&1
  printf 'Worktree returned to pool.\n'
fi
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# Build a home with a project, a pool directory laid out the way treehouse lays
# one out (<pool>/<slot>/<repo>), and a brief for <id>.
make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project origin pool slot fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  slot="$case_dir/pool/3"
  pool="$slot/project"
  fakebin=$(make_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$slot"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin"
}

read_case() {  # <record>
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR <<EOF
$1
EOF
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  SEND_LOG="$CASE_DIR/send-keys.log"
  : > "$TREEHOUSE_LOG"
  : > "$SEND_LOG"
  FM_FAKE_WINDOWS=""
}

run_spawn() {  # <id> [args...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="${FM_FAKE_PANE_PATH_OVERRIDE:-$POOL_DIR}" \
    FM_FAKE_LEASE_PATH="$POOL_DIR" \
    FM_FAKE_WINDOWS="${FM_FAKE_WINDOWS:-}" \
    FM_TREEHOUSE_LOG="$TREEHOUSE_LOG" FM_TMUX_SEND_LOG="$SEND_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" "$@" 2>&1
}

run_teardown() {  # <id> [args...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_FAKE_WINDOWS="${FM_FAKE_WINDOWS:-}" FM_FAKE_PANE_PATH="$POOL_DIR" \
    FM_TREEHOUSE_LOG="$TREEHOUSE_LOG" FM_TMUX_SEND_LOG="$SEND_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" "$@" 2>&1
}

# Record a task that owns POOL_DIR. <window> decides whether the fake tmux can
# still find its endpoint, which is what liveness turns on.
claim_worktree() {  # <id> <window> [extra-meta...]
  local id=$1 window=$2
  shift 2
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=$window" "worktree=$POOL_DIR" "project=$PROJECT_DIR" \
    "backend=tmux" "kind=ship" "$@"
  # The window must exist in the fake inventory for the endpoint to read as live.
  FM_FAKE_WINDOWS="${FM_FAKE_WINDOWS:+$FM_FAKE_WINDOWS
}${window#*:}"
}

# --- containment 1: allocation ----------------------------------------------

test_allocation_refuses_a_slot_a_live_task_claims() {
  local rec out status
  rec=$(make_case alloc-live 'pool-collision-second')
  read_case "$rec"

  # The first task still owns this slot. Its agent is gone - which is exactly
  # what made the pool offer the slot again - but the task and its work remain.
  claim_worktree 'pool-collision-first' 'firstmate:fm-pool-collision-first'

  set +e
  out=$(run_spawn 'pool-collision-second' --mode direct-PR --yolo off)
  status=$?
  set -e

  expect_code 1 "$status" "spawn allocated a slot another live task claims"
  assert_contains "$out" 'refusing to allocate an occupied slot' \
    "spawn did not refuse the occupied slot"
  assert_contains "$out" 'pool-collision-first' \
    "the refusal did not name the task that still owns the slot"
  assert_absent "$HOME_DIR/state/pool-collision-second.meta" \
    "the refused spawn still recorded a second claim on the same worktree"
  printf '%s\n' "$out" | tail -3
}

# The 2026-08-19 loss involved a task that had reported `done`, which made
# `done` look like the trigger. It is not: allocation never reads task status at
# all. A `done` claimant and a `working` claimant are refused identically, and
# what actually frees a slot is the agent going away.
test_allocation_refusal_does_not_depend_on_task_status() {
  local rec out status state_line
  for state_line in 'done' 'working'; do
    rec=$(make_case "alloc-status-$state_line" 'pool-collision-second')
    read_case "$rec"
    claim_worktree 'pool-collision-first' 'firstmate:fm-pool-collision-first'
    printf '%s: reported by the first task\n' "$state_line" \
      > "$HOME_DIR/state/pool-collision-first.status"

    set +e
    out=$(run_spawn 'pool-collision-second' --mode direct-PR --yolo off)
    status=$?
    set -e
    expect_code 1 "$status" "a '$state_line' claimant did not stop allocation"
    assert_contains "$out" 'refusing to allocate an occupied slot' \
      "a '$state_line' claimant was allocated over"
  done
}

# No false positives: a claim whose endpoint the backend proves is gone must not
# wedge the pool forever.
test_allocation_proceeds_when_no_live_task_claims_the_slot() {
  local rec out status
  rec=$(make_case alloc-free 'pool-free-second')
  read_case "$rec"

  set +e
  out=$(run_spawn 'pool-free-second' --mode direct-PR --yolo off)
  status=$?
  set -e

  expect_code 0 "$status" "spawn refused an unclaimed slot: $out"
  assert_contains "$out" 'spawned pool-free-second' "spawn did not report success"
}

# The structural half: the slot is leased for the life of the task, so the pool
# itself stops offering it once the agent is gone.
test_spawn_leases_the_slot_for_the_life_of_the_task() {
  local rec out
  rec=$(make_case lease 'pool-lease-task')
  read_case "$rec"

  out=$(run_spawn 'pool-lease-task' --mode direct-PR --yolo off)
  assert_contains "$out" 'spawned pool-lease-task' "spawn did not succeed: $out"
  assert_grep 'get --lease --lease-holder fm-pool-lease-task' "$TREEHOUSE_LOG" \
    "spawn did not durably lease the pool slot"
  # firstmate takes the lease itself; the pane is then sent into that exact slot,
  # so the agent still works inside a treehouse subshell in the leased worktree.
  assert_grep 'treehouse enter 3' "$SEND_LOG" \
    "the pane was not sent into the leased pool slot"
  printf '# treehouse calls: '; tr '\n' '|' < "$TREEHOUSE_LOG"; printf '\n'
  printf '# pane instruction: '; grep -F 'treehouse enter' "$SEND_LOG" | head -1
}

# --- containment 2: teardown ------------------------------------------------

test_teardown_refuses_to_return_a_slot_a_live_task_claims() {
  local rec out status
  rec=$(make_case teardown-live 'pool-done-first')
  read_case "$rec"

  # The finishing task and a live sibling both name this worktree. Returning it
  # would reset the directory and delete the branch the sibling is working on.
  claim_worktree 'pool-done-first' 'firstmate:fm-pool-done-first'
  claim_worktree 'pool-live-second' 'firstmate:fm-pool-live-second'
  git -C "$POOL_DIR" checkout --quiet -b fm/pool-live-second

  set +e
  out=$(run_teardown 'pool-done-first')
  status=$?
  set -e

  expect_code 1 "$status" "teardown returned a slot a live task still claims"
  assert_contains "$out" 'REFUSED' "teardown did not refuse"
  assert_contains "$out" 'pool-live-second' \
    "the refusal did not name the live task that owns the worktree"
  assert_no_grep 'return' "$TREEHOUSE_LOG" \
    "teardown returned the worktree to the pool despite the live claim"
  # The sibling's branch and worktree must be untouched.
  [ "$(git -C "$POOL_DIR" rev-parse --abbrev-ref HEAD)" = 'fm/pool-live-second' ] \
    || fail "teardown moved the live sibling off its branch before refusing"
  assert_present "$HOME_DIR/state/pool-live-second.meta" \
    "teardown removed the live sibling's record"
  printf '%s\n' "$out" | tail -4
}

# The guard must not fire on the supported pattern of several tasks sharing one
# directory when the other records are provably gone.
test_teardown_proceeds_when_the_other_claim_is_provably_gone() {
  local rec out status
  rec=$(make_case teardown-gone 'pool-gone-first')
  read_case "$rec"

  claim_worktree 'pool-gone-first' 'firstmate:fm-pool-gone-first'
  # An empty window is an authoritatively absent endpoint for the fake backend.
  fm_write_meta "$HOME_DIR/state/pool-gone-second.meta" \
    "worktree=$POOL_DIR" "project=$PROJECT_DIR" "backend=tmux" "kind=ship"

  set +e
  out=$(run_teardown 'pool-gone-first' --force)
  status=$?
  set -e
  expect_code 0 "$status" "teardown refused despite no live claimant: $out"
}

# --force stays the captain's explicit discard authority, exactly as it is for
# every other unlanded-work refusal in cleanup.
test_force_overrides_the_live_claim_refusal() {
  local rec out status
  rec=$(make_case teardown-force 'pool-force-first')
  read_case "$rec"

  claim_worktree 'pool-force-first' 'firstmate:fm-pool-force-first'
  claim_worktree 'pool-force-second' 'firstmate:fm-pool-force-second'

  set +e
  out=$(run_teardown 'pool-force-first' --force)
  status=$?
  set -e
  expect_code 0 "$status" "--force did not override the live-claim refusal: $out"
  assert_grep 'return' "$TREEHOUSE_LOG" "--force did not reach the worktree return"
}

# --- the vendor facts the fix rests on ---------------------------------------
#
# The lease is only structural if treehouse really keeps a leased slot out of a
# later `get` with no process inside it, and really releases it on `return`.
# Both are vendor behavior, so they are proved against the real binary rather
# than assumed. Self-skips where treehouse is absent (CI has no pool).
test_real_treehouse_lease_outlives_the_agent() {
  local dir repo first second
  if ! command -v treehouse >/dev/null 2>&1; then
    printf 'skip - treehouse not found; pool lease semantics unverified here\n'
    return 0
  fi
  dir="$TMP_ROOT/real-lease"
  repo="$dir/repo"
  mkdir -p "$repo"
  git init --quiet -b main "$repo"
  printf 'base\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  # Keep the pool inside the temp root; never touch the operator's real pool.
  printf 'max_trees = 4\nroot = "./"\n' > "$repo/treehouse.toml"

  first=$( cd "$repo" && treehouse get --lease --lease-holder fm-first 2>/dev/null ) \
    || fail "real treehouse could not lease a worktree"
  [ -n "$first" ] && [ -d "$first" ] || fail "treehouse get --lease printed no usable path"

  # No process is left inside it: this is exactly the state a dead or finished
  # agent leaves behind, and the state that used to free the slot.
  second=$( cd "$repo" && treehouse get --lease --lease-holder fm-second 2>/dev/null ) \
    || fail "real treehouse could not lease a second worktree"
  [ "$second" != "$first" ] \
    || fail "treehouse handed out a LEASED slot with no process inside it"

  # Cleanup's existing `treehouse return` is the release point.
  ( cd "$repo" && treehouse return --force "$first" ) >/dev/null 2>&1 \
    || fail "treehouse return did not release the lease"
  [ "$( cd "$repo" && treehouse get --lease --lease-holder fm-third 2>/dev/null )" = "$first" ] \
    || fail "a returned slot was not offered again"
  printf '# real treehouse: leased slot held with 0 processes, released on return\n'
}

test_allocation_refuses_a_slot_a_live_task_claims
pass 'allocation refuses a slot a live task record still claims'
test_allocation_refusal_does_not_depend_on_task_status
pass 'allocation refusal turns on liveness, not on a done status'
test_allocation_proceeds_when_no_live_task_claims_the_slot
pass 'allocation proceeds when no live task claims the slot'
test_spawn_leases_the_slot_for_the_life_of_the_task
pass 'spawn leases the pool slot for the life of the task'
test_teardown_refuses_to_return_a_slot_a_live_task_claims
pass 'teardown refuses to return a slot a live task record still claims'
test_teardown_proceeds_when_the_other_claim_is_provably_gone
pass 'teardown proceeds when the other claim is provably gone'
test_force_overrides_the_live_claim_refusal
pass '--force overrides the live-claim refusal'
# The pool return is forced only under the captain's discard authority. Without
# it, uncommitted work that appeared after the safety check - the agent is alive
# until the return kills it - is preserved by the pool instead of discarded, and
# cleanup must not report success for a return that silently aborted.
test_unforced_return_preserves_uncommitted_work() {
  local rec out status
  rec=$(make_case return-unforced 'pool-dirty-task')
  read_case "$rec"
  claim_worktree 'pool-dirty-task' 'firstmate:fm-pool-dirty-task'
  printf 'work that appeared after the safety check\n' > "$POOL_DIR/late-work.txt"

  set +e
  out=$(run_teardown 'pool-dirty-task' --force)
  status=$?
  set -e
  # --force is the captain's discard authority: the slot really is returned.
  expect_code 0 "$status" "--force did not return the slot: $out"
  [ ! -f "$POOL_DIR/late-work.txt" ] \
    || fail "--force did not discard the work the captain authorized discarding"
  printf '# with --force: slot returned, work discarded as authorized\n'
}

test_unforced_return_refuses_rather_than_reporting_a_phantom_return() {
  local rec out status
  rec=$(make_case return-phantom 'pool-phantom-task')
  read_case "$rec"
  claim_worktree 'pool-phantom-task' 'firstmate:fm-pool-phantom-task'

  # The worktree is CLEAN here, so cleanup's landed-work refusal passes and the
  # run really does reach the pool return - which then aborts.
  set +e
  out=$(FM_FAKE_POOL_ABORT=1 run_teardown 'pool-phantom-task')
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "cleanup reported success for a return that aborted: $out"
  assert_present "$POOL_DIR/raced-work.txt" \
    "the aborted return did not preserve the raced work"
  # Not vacuous: the refusal must come from the PROVEN-RETURN check, not from an
  # earlier landed-work refusal that never reached the pool at all.
  assert_contains "$out" 'declined to return' \
    "the refusal did not come from the proven-return check"
  printf '%s\n' "$out" | grep -F 'declined to return' | head -1
}

# Leasing must not move where a spawn aborts when the pane ends up somewhere
# that is not a worktree. The Herdr presentation E2E arms exactly this case to
# exercise post-create cleanup ordering, and it keys off this failure, so the
# abort has to stay at the worktree validation rather than moving earlier.
test_pane_outside_a_worktree_still_aborts_at_worktree_validation() {
  local rec out status stray
  rec=$(make_case pane-not-a-worktree 'pool-stray-task')
  read_case "$rec"
  # The lease succeeds and hands back a real directory; the pane settles
  # somewhere else entirely, which is not a git worktree at all.
  stray="$CASE_DIR/not-a-worktree"
  mkdir -p "$stray"

  set +e
  out=$(FM_FAKE_PANE_PATH_OVERRIDE="$stray" run_spawn 'pool-stray-task' --mode direct-PR --yolo off)
  status=$?
  set -e
  expect_code 1 "$status" "a pane outside any worktree was accepted"
  assert_contains "$out" 'did not yield an isolated worktree' \
    "the abort moved off the worktree validation that the Herdr E2E arms"
  printf '%s\n' "$out" | grep -F 'did not yield an isolated worktree' | head -1
}

test_real_treehouse_lease_outlives_the_agent
pass 'a real leased pool slot outlives its agent and is freed only by return'
# A scout worktree is declared scratch and its deliverable is the report outside
# the worktree, so its return stays forced. Without this, every ordinary scout
# cleanup would strand on exactly the debris a scout is expected to leave.
test_scout_return_stays_forced() {
  local rec out status
  rec=$(make_case return-scout 'pool-scout-task')
  read_case "$rec"
  fm_write_meta "$HOME_DIR/state/pool-scout-task.meta" \
    "window=firstmate:fm-pool-scout-task" "worktree=$POOL_DIR" "project=$PROJECT_DIR" \
    "backend=tmux" "kind=scout"
  FM_FAKE_WINDOWS="fm-pool-scout-task"
  mkdir -p "$HOME_DIR/data/pool-scout-task"
  printf 'findings\n' > "$HOME_DIR/data/pool-scout-task/report.md"
  printf 'scratch debris a scout is expected to leave\n' > "$POOL_DIR/debris.txt"
  # Satisfy the separate unresolved-decision completion gate so this test
  # exercises the return policy rather than that gate.
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-decision-hold.sh" complete 'pool-scout-task' --none >/dev/null 2>&1 \
    || fail "could not clear the unresolved-decision gate for the scout fixture"

  set +e
  out=$(run_teardown 'pool-scout-task')
  status=$?
  set -e
  expect_code 0 "$status" "an ordinary scout cleanup was stranded on its own scratch: $out"
  assert_grep 'return --force' "$TREEHOUSE_LOG" "the scout return was not forced"
  printf '# scout return: '; grep -F 'return' "$TREEHOUSE_LOG" | head -1
}

test_unforced_return_preserves_uncommitted_work
pass 'the captain-authorized forced return still discards and returns'
test_unforced_return_refuses_rather_than_reporting_a_phantom_return
pass 'an aborted pool return is reported as a failure, not a phantom success'
test_scout_return_stays_forced
pass 'a declared-scratch scout worktree is still returned with force'

test_pane_outside_a_worktree_still_aborts_at_worktree_validation
pass 'a pane outside any worktree still aborts at the worktree validation'
