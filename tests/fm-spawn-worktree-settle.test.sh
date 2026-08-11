#!/usr/bin/env bash
# Regression test for fm-spawn.sh's leased-worktree detection settle loop
# (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after pane entry).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the leased worktree it was sent into. That stale
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
    [ -n "${FM_FAKE_SEND_LOG:-}" ] && printf '%s\n' "${4:-}" >> "$FM_FAKE_SEND_LOG"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse_lease "$fakebin"
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
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
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
    FM_FAKE_SEND_LOG="${FM_FAKE_SEND_LOG:-}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# proc_cwd <pid>: that process's own working directory, however this platform
# exposes it. fm-teardown.sh reads the same fact through lsof to decide which
# processes belong to a worktree, so a test that wants to prove a shell is NOT
# selected by that scan has to read the identical property.
proc_cwd() {
  local pid=$1 out
  if [ -r "/proc/$pid/cwd" ] && out=$(readlink "/proc/$pid/cwd" 2>/dev/null) \
     && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    out=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  return 1
}

physical() { ( cd "$1" 2>/dev/null && pwd -P ); }

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

# A pool with nothing left to hand out must refuse the launch carrying
# treehouse's OWN reason.
#
# Under leases this stopped being a theoretical branch: every live task holds a
# slot until it is torn down, so "all N worktrees are in use" is a real
# operating condition rather than a corrupt-tool signal, and the number and the
# remedy live only in treehouse's stderr. Swallowing it leaves a bare "the pool
# returned no path" that no operator can act on.
test_exhausted_pool_refuses_with_the_vendor_reason() {
  local rec id out status reason
  id=settle-exhausted-z8
  reason="all 3 worktrees are in use or dirty (max_trees = 3). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml"
  rec=$(make_settle_case settle-exhausted "$id" 0)
  read_settle_record "$rec"
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = get ]; then
  # The vendor writes progress and the refusal to stderr and nothing to stdout.
  echo "setting up worktree..." >&2
  echo "$reason" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 1 "$status" "an exhausted pool must refuse the launch"
  assert_contains "$out" "$reason" \
    "the refusal dropped treehouse's own reason, leaving no way to tell an exhausted pool from a broken one"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused launch must publish no task record"
  pass "an exhausted pool refuses the launch and carries treehouse's own reason"
}

# The command that enters the copy must leave the pane's OWN top-level shell
# outside it, with real processes rather than by inspecting the text.
#
# fm-teardown.sh selects a task's leftover processes by cwd under the worktree
# and terminates them before returning the copy to the pool. A pane whose
# top-level shell sits inside the copy is therefore selected by its own
# teardown and killed along with the agent, which ends the pane before the
# steps that follow - the exact focus-preserving close and the presentation
# journal retirement - can confirm it. `treehouse get`, run in the pane, used
# to supply that topology implicitly by opening its own subshell; now that
# firstmate leases the copy and enters the pane itself, the entry command has
# to supply it. This case takes the exact line fm-spawn sends, runs it in a
# real shell started in the project directory, and proves the parent stayed
# put while a child moved into the copy.
test_entry_command_keeps_the_pane_shell_out_of_the_copy() {
  local rec id case_dir sendlog line fifo pane_pid waited inner parent
  id=settle-topology-z9
  case_dir="$TMP_ROOT/settle-topology"
  rec=$(make_settle_case settle-topology "$id" 0)
  read_settle_record "$rec"

  sendlog="$case_dir/send.log"
  : > "$sendlog"
  FM_FAKE_SEND_LOG="$sendlog" run_settle_spawn "$id" >/dev/null 2>&1 \
    || fail "spawn should succeed with an already-settled pane"

  line=$(grep -F -- "$WT_DIR" "$sendlog" | head -1)
  [ -n "$line" ] || fail "fm-spawn sent the pane nothing naming the leased copy"

  # Drive the real line through a real shell. SHELL is unset deliberately so the
  # command takes its documented /bin/sh fallback, which exists everywhere.
  fifo="$case_dir/pane-in"
  mkfifo "$fifo" || fail "could not create the pane fifo"
  ( cd "$PROJ_DIR" && exec env -u SHELL bash --norc -s ) \
    < "$fifo" > "$case_dir/pane.out" 2>&1 &
  pane_pid=$!
  exec 9> "$fifo"

  printf '%s\n' "$line" >&9
  printf 'pwd -P > %s\n' "$case_dir/inner-pwd" >&9

  waited=0
  while [ ! -s "$case_dir/inner-pwd" ] && [ "$waited" -lt 50 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  inner=$(cat "$case_dir/inner-pwd" 2>/dev/null || true)
  parent=$(proc_cwd "$pane_pid") \
    || { exec 9>&-; fail "cannot read a process's cwd on this platform (no /proc, no lsof), so the topology is unverifiable"; }

  exec 9>&-
  wait "$pane_pid" 2>/dev/null || true

  [ "$inner" = "$(physical "$WT_DIR")" ] \
    || fail "the entry command did not put a shell inside the leased copy (landed on '$inner', expected $(physical "$WT_DIR"))"
  [ "$(physical "$parent")" = "$(physical "$PROJ_DIR")" ] \
    || fail "the pane's own shell moved into the leased copy ('$parent'), where teardown's leftover-process scan would kill it and take the pane with it"
  pass "the copy is entered by a child shell; the pane's own shell stays outside it"
}

test_claimed_pooled_worktree_is_not_reallocated() {
  local rec id old_id out status
  id=settle-new-task-z3
  old_id=settle-old-task-z3
  rec=$(make_settle_case settle-claimed-worktree "$id" 0)
  read_settle_record "$rec"
  fm_write_meta "$HOME_DIR/state/$old_id.meta" \
    "window=firstmate:fm-$old_id" \
    "endpoint_task_id=$old_id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "kind=ship" \
    "mode=no-mistakes"

  set +e
  out=$(run_settle_spawn "$id")
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "claimed-worktree: spawn allocated a worktree still claimed by $old_id"
  assert_contains "$out" "still claimed by task $old_id" \
    "claimed-worktree: spawn did not identify the existing owner"
  assert_present "$HOME_DIR/state/$old_id.meta" \
    "claimed-worktree: spawn changed the existing task record"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "claimed-worktree: spawn published a second owner for the pooled worktree"
  pass "a pooled worktree claimed by another live task is refused before a new task record is published"
}

# --- real Treehouse pool: the copy a live task owns is durably reserved -------
#
# The settle cases above answer the pool with a fixed path, so they cannot say
# anything about WHICH copy the pool hands out next. These do, against the real
# treehouse binary and a pane that actually follows the `cd` it is sent.
#
# The mechanism they pin: a pooled copy used to be reserved only for the life of
# the shell that ran `treehouse get`, while the claim recorded in
# state/<id>.meta is durable. With no live shell in a copy - which is exactly
# what a pane-less fake, a session restart, or a crashed worker leaves behind -
# the pool considered it free and handed it to the next task. The home-scoped
# ownership check cannot catch that across homes, because the pool is shared by
# every home while that check can only read one home's state/.

# make_pool_fakebin <dir> <cwdfile>: a fake tmux whose pane really follows the
# `cd <path>` it is sent, so the real pool - not the fake - chooses every path.
make_pool_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
cwdfile="${FM_FAKE_PANE_CWD_FILE:?FM_FAKE_PANE_CWD_FILE unset}"
case "$*" in
  *"#{pane_current_path}"*)
    [ -f "$cwdfile" ] && cat "$cwdfile"
    exit 0
    ;;
esac
if [ "${1:-}" = send-keys ]; then
  text=${4:-}
  # Follow only the nested-shell entry form. A bare `cd` would move the pane's
  # own shell into the copy, which teardown then kills along with the agent, so
  # the fake refuses to model a topology firstmate must never send.
  case "$text" in
    "( cd "*" && exec "*)
      inner=${text#( cd }
      inner=${inner%% && exec *}
      eval "set -- $inner"
      printf '%s\n' "$1" > "$cwdfile"
      ;;
  esac
  exit 0
fi
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# make_pool_home <case-dir> <name>: one isolated firstmate home.
make_pool_home() {
  local case_dir=$1 name=$2 home="$1/$2"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

# run_pool_spawn <home> <project> <id> <case-dir>: spawn <id> in <home> with a
# pane that follows its `cd`, and print the spawn's own output.
run_pool_spawn() {
  local home=$1 proj=$2 id=$3 case_dir=$4 fakebin cwdfile
  cwdfile="$case_dir/pane-cwd-$id"
  printf '%s\n' "$proj" > "$cwdfile"
  fakebin=$(make_pool_fakebin "$case_dir/fake-$id")
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_CWD_FILE="$cwdfile" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

pool_meta_worktree() {  # <home> <id>
  sed -n 's/^worktree=//p' "$1/state/$2.meta" | head -1
}

# make_pool_case <name> <max-trees>: a real repo whose pool is capped and rooted
# inside the fixture, so a slot only frees up when it is genuinely returned.
make_pool_case() {
  local name=$1 max_trees=$2 case_dir proj
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  mkdir -p "$case_dir/pool-root"
  fm_git_init_commit "$proj"
  printf 'max_trees = %s\nroot = "%s"\n' "$max_trees" "$case_dir/pool-root" > "$proj/treehouse.toml"
  git -C "$proj" add treehouse.toml
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'pool config'
  printf '%s\n' "$case_dir"
}

test_live_task_copy_is_never_reoffered_across_homes() {
  local case_dir proj home_a home_b out wt_a wt_b wt_c wt_reused
  case_dir=$(make_pool_case pool-cross-home 3)
  proj="$case_dir/project"
  home_a=$(make_pool_home "$case_dir" home-a)
  home_b=$(make_pool_home "$case_dir" home-b)

  out=$(run_pool_spawn "$home_a" "$proj" pool-a-z4 "$case_dir")
  assert_contains "$out" "spawned pool-a-z4" "pool: first spawn failed: $out"
  wt_a=$(pool_meta_worktree "$home_a" pool-a-z4)
  [ -n "$wt_a" ] || fail "pool: first spawn recorded no worktree"

  # No process is left in wt_a - the only thing keeping it out of the pool is
  # the durable reservation firstmate took. A second home cannot see home-a's
  # records at all, so nothing else can stop it being handed the same copy.
  out=$(run_pool_spawn "$home_b" "$proj" pool-b-z4 "$case_dir")
  assert_contains "$out" "spawned pool-b-z4" "pool: cross-home spawn failed: $out"
  wt_b=$(pool_meta_worktree "$home_b" pool-b-z4)
  [ "$wt_b" != "$wt_a" ] \
    || fail "pool: a second home was handed the copy task pool-a-z4 still owns ($wt_a)"
  pass "a copy a live task owns is never re-offered, including to a task in another home"

  # Relaunching the same id without naming a copy allocates a fresh one, so the
  # superseded copy has to go back to the pool - otherwise it is reserved with
  # no record left that would ever return it.
  out=$(run_pool_spawn "$home_a" "$proj" pool-a-z4 "$case_dir")
  assert_contains "$out" "spawned pool-a-z4" "pool: relaunch failed: $out"
  wt_c=$(pool_meta_worktree "$home_a" pool-a-z4)
  [ "$wt_c" != "$wt_a" ] && [ "$wt_c" != "$wt_b" ] \
    || fail "pool: relaunch did not take a fresh copy (got $wt_c)"

  # The cap is 3 and two are held, so the only copy left to hand out is the one
  # the relaunch gave up. Getting it back is the proof it was really released.
  out=$(run_pool_spawn "$home_b" "$proj" pool-d-z4 "$case_dir")
  assert_contains "$out" "spawned pool-d-z4" "pool: fourth spawn failed: $out"
  wt_reused=$(pool_meta_worktree "$home_b" pool-d-z4)
  [ "$wt_reused" = "$wt_a" ] \
    || fail "pool: the superseded copy $wt_a was not returned (next allocation got $wt_reused)"
  pass "a relaunch that allocates a fresh copy returns the superseded one to the pool"
}

test_superseded_copy_with_unlanded_work_is_kept() {
  local case_dir proj home out wt_first wt_second
  case_dir=$(make_pool_case pool-unlanded 3)
  proj="$case_dir/project"
  home=$(make_pool_home "$case_dir" home-a)

  out=$(run_pool_spawn "$home" "$proj" pool-keep-z5 "$case_dir")
  assert_contains "$out" "spawned pool-keep-z5" "pool: first spawn failed: $out"
  wt_first=$(pool_meta_worktree "$home" pool-keep-z5)
  [ -n "$wt_first" ] || fail "pool: first spawn recorded no worktree"
  printf 'unlanded work\n' > "$wt_first/unlanded.txt"

  out=$(run_pool_spawn "$home" "$proj" pool-keep-z5 "$case_dir")
  assert_contains "$out" "spawned pool-keep-z5" "pool: relaunch failed: $out"
  wt_second=$(pool_meta_worktree "$home" pool-keep-z5)
  [ "$wt_second" != "$wt_first" ] || fail "pool: relaunch reused the superseded copy"
  assert_contains "$out" "$wt_first stays leased" \
    "pool: relaunch did not report keeping the superseded copy with unlanded work"
  assert_present "$wt_first/unlanded.txt" \
    "pool: relaunch discarded unlanded work in the superseded copy"
  pass "a superseded copy holding unlanded work stays reserved and is reported, never cleaned"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_exhausted_pool_refuses_with_the_vendor_reason
test_entry_command_keeps_the_pane_shell_out_of_the_copy
test_claimed_pooled_worktree_is_not_reallocated
if command -v treehouse >/dev/null 2>&1; then
  test_live_task_copy_is_never_reoffered_across_homes
  test_superseded_copy_with_unlanded_work_is_kept
else
  echo "# skip: treehouse not found; real pool reservation cases not run"
fi

echo "# all fm-spawn-worktree-settle tests passed"
