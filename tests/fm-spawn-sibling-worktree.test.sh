#!/usr/bin/env bash
# Regression test for fm-spawn.sh's live-sibling worktree guard
# (validate_worktree_free_of_live_sibling, reached from validate_spawn_worktree).
#
# The worktree pool decides a slot is in use by looking for live processes whose
# working directory sits inside it, so an agent that is thinking, waiting on the
# network, or idle between commands reads as absent and the next `treehouse get`
# hands its slot to the following spawn - which then resets it to a clean
# detached HEAD, destroying the running agent's branch checkout. Firstmate holds
# the record the pool cannot see: every task writes worktree= into
# state/<id>.meta. These cases drive that record directly rather than trying to
# race a real pool, because the live bug needs an IDLE agent to reproduce and a
# test built around a raceable, non-idle worker would pass for the wrong reason.
#
# The fake tmux below is what makes each liveness verdict reachable: window
# inventory and foreground command name are the two signals
# fm_backend_tmux_agent_state reads, so listing or omitting the sibling's window
# and naming an agent or a shell as its foreground command selects `alive`,
# `missing`, or `unreadable` deterministically.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-sibling-worktree)

# make_sibling_fakebin <dir> builds a fake tmux driven entirely by environment:
#   FM_FAKE_PANE_PATH        the pane cwd `treehouse get` settles into
#   FM_FAKE_WINDOWS          newline-separated window names `list-windows -t`
#                            reports (empty = the session has no windows)
#   FM_FAKE_LIST_FAIL        when non-empty, `list-windows -t` fails printing
#                            this text - an inventory read that neither names
#                            the window nor proves the session gone
#   FM_FAKE_PANE_COMMAND     what `#{pane_current_command}` reports
#   FM_FAKE_TMUX_LOG         file every invocation is appended to
# pane_tty is deliberately answered empty so the foreground process-group half
# of the liveness probe reports nothing and the verdict rests on the two signals
# this fake can actually control.
make_sibling_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_tty}"*) exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-zsh}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_LIST_FAIL:-}" ]; then
      printf '%s\n' "$FM_FAKE_LIST_FAIL" >&2
      exit 1
    fi
    [ -z "${FM_FAKE_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_WINDOWS"
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> builds a home, a project with one real worktree standing in
# for the pooled slot, and the fake tmux. The worktree is the path every case
# below makes the spawn land on.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_DIR="$case_dir"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  LOG_FILE="$case_dir/tmux.log"
  FAKE_WINDOWS=''
  FAKE_LIST_FAIL=''
  FAKE_PANE_COMMAND=zsh
  FAKEBIN_DIR=$(make_sibling_fakebin "$case_dir/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  touch "$HOME_DIR/state/.last-watcher-beat"
  # The diagnostic reports the physically resolved worktree, and on macOS the
  # temp root is itself a symlinked, double-slashed spelling of that directory.
  WT_REAL=$(cd "$WT_DIR" && pwd -P)
  : > "$LOG_FILE"
}

seed_brief() {
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
}

# write_sibling <id> <worktree-path> [window-name]: the durable record one other
# task in this home left behind, exactly as fm-spawn writes it.
write_sibling() {
  local id=$1 worktree=$2 window=${3:-}
  # Default the window inside the body, not in the `local` word list: every word
  # of a `local` command is expanded before the builtin runs, so ${3:-...$id}
  # would interpolate the CALLER's `id`, quietly pointing the record at the
  # spawning task's own endpoint and making the collision unreachable.
  [ -n "$window" ] || window="firstmate:fm-$id"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$worktree" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=crewmate" \
    "mode=no-mistakes" \
    "yolo=off"
}

run_spawn() {
  local id=$1
  seed_brief "$id"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_WINDOWS="${FAKE_WINDOWS:-}" \
    FM_FAKE_LIST_FAIL="${FAKE_LIST_FAIL:-}" \
    FM_FAKE_PANE_COMMAND="${FAKE_PANE_COMMAND:-zsh}" \
    FM_FAKE_TMUX_LOG="$LOG_FILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# assert_no_agent_launched: the refusal has to land before the incoming agent is
# started, which is what keeps a collision recoverable at zero cost - the new
# worker never reaches `git checkout -b` because it never runs at all. The pane
# is allowed to have run `treehouse get` (that is how the collision is
# discovered); it must not have been handed a harness launch command.
assert_no_agent_launched() {
  local msg=$1
  assert_grep 'treehouse get' "$LOG_FILE" "the spawn never reached worktree acquisition"
  assert_no_grep 'codex' "$LOG_FILE" "$msg"
}

# A worktree no other record claims still spawns normally. The sibling here is
# real and live; it simply sits in a different slot, so the guard must ignore it
# rather than refusing every spawn that finds any live task in the home.
test_clean_spawn_still_succeeds() {
  local id=sibling-clean-a1 out status other_wt
  make_case sibling-clean
  other_wt="$CASE_DIR/other-wt"
  git -C "$PROJ_DIR" worktree add --quiet -b other-slot "$other_wt"
  write_sibling sibling-live-elsewhere "$other_wt"
  FAKE_WINDOWS='fm-sibling-live-elsewhere'
  FAKE_PANE_COMMAND=claude
  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when no record claims this worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the acquired worktree"
  pass "a worktree claimed by nobody still spawns"
}

# The bug itself: the pool hands over a slot whose owner is idle. The owner's
# record is what proves the claim, and its endpoint is alive.
test_live_sibling_refuses() {
  local id=sibling-collide-a2 out status
  make_case sibling-collide
  write_sibling sibling-idle-worker "$WT_DIR"
  FAKE_WINDOWS='fm-sibling-idle-worker'
  FAKE_PANE_COMMAND=claude
  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded onto a live sibling's worktree"
  assert_contains "$out" "sibling-idle-worker" "the refusal did not name the offending task"
  assert_contains "$out" "$WT_REAL" "the refusal did not name the shared worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "the refused spawn still recorded metadata"
  assert_no_agent_launched "the refused spawn still launched an agent onto the shared worktree"
  pass "a worktree recorded by a live sibling refuses the spawn"
}

# Stale metadata outlives its agent and worktrees are pooled, so a record whose
# endpoint is authoritatively gone must not poison the slot forever. The session
# inventory here is readable and simply does not contain the recorded window.
test_dead_sibling_still_spawns() {
  local id=sibling-dead-a3 out status
  make_case sibling-dead
  write_sibling sibling-finished-worker "$WT_DIR"
  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "a dead sibling's stale record must not block reuse"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the reused worktree"
  pass "a dead sibling's recorded worktree is reusable"
}

# Recovery re-seats the same task id into the worktree its own record already
# names. An alive own endpoint is unreachable here - the window-name collision
# check refuses that spawn earlier, before this guard runs - so the construction
# that actually exercises the exclusion is an inventory read that fails without
# proving the session gone. That verdict is `unreadable`, which this guard
# refuses, and only the $ID exclusion lets the relaunch through.
test_own_record_does_not_refuse_itself() {
  local id=sibling-relaunch-a4 out status
  make_case sibling-relaunch
  write_sibling "$id" "$WT_DIR"
  FAKE_LIST_FAIL='connection to server timed out'
  FAKE_PANE_COMMAND=claude
  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "a relaunch must not refuse against its own recorded worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  pass "a task's own recorded worktree never refuses its relaunch"
}

# The divergence that keeps the case above from passing vacuously: the identical
# unreadable-inventory construction, differing only in which id owns the record,
# must refuse. Without that, the previous test would also pass if the guard
# simply never fired on an unreadable endpoint.
test_unreadable_sibling_refuses() {
  local id=sibling-unreadable-a5 out status
  make_case sibling-unreadable
  write_sibling sibling-unknown-worker "$WT_DIR"
  FAKE_LIST_FAIL='connection to server timed out'
  FAKE_PANE_COMMAND=claude
  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded onto a sibling whose liveness could not be read"
  assert_contains "$out" "sibling-unknown-worker" "the refusal did not name the offending task"
  assert_contains "$out" "unreadable" "the refusal did not report the endpoint verdict"
  assert_no_agent_launched "the refused spawn still launched an agent onto the shared worktree"
  pass "an unreadable sibling endpoint refuses rather than releasing the claim"
}

# A record written through a symlinked prefix and with a trailing slash spells
# the same directory the pool just handed over. Raw string comparison would miss
# it; both sides resolve physically, exactly as the isolation check already does.
test_differently_spelled_path_is_caught() {
  local id=sibling-spelling-a6 out status link
  make_case sibling-spelling
  link="$CASE_DIR/wt-link"
  ln -s "$WT_DIR" "$link"
  write_sibling sibling-symlinked-worker "$link/"
  FAKE_WINDOWS='fm-sibling-symlinked-worker'
  FAKE_PANE_COMMAND=claude
  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded onto a differently-spelled path for a live sibling's worktree"
  assert_contains "$out" "sibling-symlinked-worker" "the refusal did not name the offending task"
  assert_no_agent_launched "the refused spawn still launched an agent onto the shared worktree"
  pass "a symlinked, trailing-slash spelling of the same worktree is still caught"
}

test_clean_spawn_still_succeeds
test_live_sibling_refuses
test_dead_sibling_still_spawns
test_own_record_does_not_refuse_itself
test_unreadable_sibling_refuses
test_differently_spelled_path_is_caught

echo "# all fm-spawn-sibling-worktree tests passed"
