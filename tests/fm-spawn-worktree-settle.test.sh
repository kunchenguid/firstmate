#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the poll loop after `treehouse get`).
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
# The loop's bound is two-phase (bin/fm-spawn.sh header, FM_SPAWN_ACQUIRE_TIMEOUT):
# `treehouse get` runs `git fetch origin` BEFORE it enters the worktree
# subshell, so the pane's path reads the project for the whole fetch exactly
# as it does after a pool-cap refusal. The fake tmux below therefore also
# answers `#{pane_current_command}` (treehouse for the first
# FM_FAKE_TREEHOUSE_READS path reads, then the shell named by
# FM_FAKE_PANE_SHELL, then nothing once the path read count passes
# FM_FAKE_PANE_SHELL_READS) and `capture-pane` (FM_FAKE_PANE_TAIL, replaced
# by FM_FAKE_PANE_TAIL_LATE once the path read count passes
# FM_FAKE_PANE_TAIL_LATE_READS, and for any one path read count by the file
# of that number under FM_FAKE_PANE_TAIL_DIR). The later cases pin that a fetch outlasting
# the old 60s budget still spawns, that an acquisition past its own bound is
# reported as still running, that a refusal fails fast with the pane's own
# reason, and that an unreadable foreground (an empty FM_FAKE_PANE_SHELL)
# stays on the settle bound with the pane text standing in: it gives up at
# 60s, an "Entered worktree" line starts the settle phase, an error line
# before any entry fails fast once two CONSECUTIVE polls agree (never on
# the one poll that can catch startup noise after the command's echo, never
# on two reads that do not follow each other, and still when the first of
# the two is the poll that reaches the settle bound), an error line after
# the entry does not, and a wait that lost its foreground reader only on
# the final poll keeps the settle refusal it earned.
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
  # The foreground view: the spawn reads it right after each path read, so
  # the path read count is the poll number. No tty is reported, so the
  # reader's process-table half is skipped and the title alone answers.
  *"#{pane_current_command}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    if [ "$n" -le "${FM_FAKE_TREEHOUSE_READS:-0}" ]; then
      printf 'treehouse\n'
    elif [ -n "${FM_FAKE_PANE_SHELL_READS:-}" ] && [ "$n" -gt "$FM_FAKE_PANE_SHELL_READS" ]; then
      printf '\n'
    else
      printf '%s\n' "${FM_FAKE_PANE_SHELL-zsh}"
    fi
    exit 0
    ;;
  *"#{pane_tty}"*) printf '\n'; exit 0 ;;
esac
case "${1:-}" in
  capture-pane)
    n=0
    [ ! -f "${FM_FAKE_PANE_COUNTFILE:-}" ] || n=$(cat "$FM_FAKE_PANE_COUNTFILE")
    if [ -n "${FM_FAKE_PANE_TAIL_DIR:-}" ] && [ -f "$FM_FAKE_PANE_TAIL_DIR/$n" ]; then
      cat "$FM_FAKE_PANE_TAIL_DIR/$n"
    elif [ -n "${FM_FAKE_PANE_TAIL_LATE_READS:-}" ] && [ "$n" -gt "$FM_FAKE_PANE_TAIL_LATE_READS" ]; then
      printf '%b' "${FM_FAKE_PANE_TAIL_LATE:-}"
    else
      printf '%b' "${FM_FAKE_PANE_TAIL:-}"
    fi
    exit 0
    ;;
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

# make_settle_case <name> <id> <stale_reads> [project] builds a home, a primary
# project with a real worktree (the eventual settled path), and a separate
# real git repo standing in for the stale path (a real checkout of something
# else entirely, distinct from both the project and the worktree - mirroring
# the live incident where the stale read was another real firstmate home).
# With `project` as the fourth argument the stale path is the project itself,
# which is what the pane reads while `treehouse get` is still fetching and
# after it has refused.
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 stale_kind=${4:-other} case_dir home proj wt stale fakebin countfile
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
  if [ "$stale_kind" = project ]; then
    stale=$proj
  else
    fm_git_init_commit "$stale"
  fi
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

# Foreground knobs for the fake pane, reset per case: how many polls report
# treehouse in the foreground, which shell name follows (empty = the
# foreground cannot be read at all), after how many path reads that shell
# name stops being readable (empty = never), the pane's rendered tail (and
# the tail that replaces it after a given number of path reads, and the
# per-read captures settle_capture_at pins for exact path read counts),
# and the acquisition bound under test.
reset_settle_knobs() {
  TREEHOUSE_READS=0
  PANE_SHELL=zsh
  PANE_SHELL_READS=
  PANE_TAIL=
  PANE_TAIL_LATE=
  PANE_TAIL_LATE_READS=
  PANE_TAIL_DIR=
  ACQUIRE_TIMEOUT=
}
reset_settle_knobs

# settle_capture_at <read-number> <capture> pins the pane's rendered text for
# exactly that path read; every other read falls back to PANE_TAIL and
# PANE_TAIL_LATE. Call it after reset_settle_knobs and read_settle_record.
settle_capture_at() {
  PANE_TAIL_DIR="$(dirname "$COUNTFILE")/captures"
  mkdir -p "$PANE_TAIL_DIR"
  printf '%b' "$2" > "$PANE_TAIL_DIR/$1"
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_TREEHOUSE_READS="$TREEHOUSE_READS" FM_FAKE_PANE_SHELL="$PANE_SHELL" \
    FM_FAKE_PANE_SHELL_READS="$PANE_SHELL_READS" \
    FM_FAKE_PANE_TAIL="$PANE_TAIL" FM_FAKE_PANE_TAIL_LATE="$PANE_TAIL_LATE" \
    FM_FAKE_PANE_TAIL_LATE_READS="$PANE_TAIL_LATE_READS" \
    FM_FAKE_PANE_TAIL_DIR="$PANE_TAIL_DIR" \
    FM_SPAWN_ACQUIRE_TIMEOUT="$ACQUIRE_TIMEOUT" \
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
# rather than waiting forever or recording the primary. Its foreground is a
# shell that was never seen running treehouse, and the refusal must say
# exactly that instead of claiming treehouse entered nothing.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status reads
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "foreground was a shell, not treehouse get" \
    "spawn did not explain that the pane's foreground was a shell"
  assert_contains "$out" "never seen running" \
    "spawn did not say treehouse get was never observed"
  assert_not_contains "$out" "did not enter" \
    "spawn claimed treehouse did not enter a worktree without evidence it ran"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -le 62 ] || fail "a shell foreground must stay under the 60s settle bound, but the spawn polled $reads times"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

# The 2026-09-11 incident: `treehouse get` fetches BEFORE it enters the
# worktree, and on a slow origin the fetch outlasted the fixed 60s budget. The
# pane reads the project path with treehouse in the foreground for 70 polls,
# then the worktree; the spawn must keep waiting and succeed. The read count
# is asserted above the old budget so the case cannot go quietly vacuous.
test_slow_fetch_past_the_old_budget_still_spawns() {
  local rec id out status reads
  id=settle-slow-fetch-z5
  rec=$(make_settle_case settle-slow-fetch "$id" 70 project)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  TREEHOUSE_READS=70

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should wait out a slow fetch while treehouse is still running"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree treehouse eventually entered"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -gt 60 ] || fail "the fetch was meant to outlast the old 60-read budget, but the spawn only polled $reads times"
  [ "$reads" -eq 72 ] || fail "expected the 70 fetching reads plus the two agreeing worktree reads, got $reads"
  pass "a fetch outlasting the old 60s budget still spawns while treehouse is running"
}

# An acquisition that never finishes is reported as exactly that: treehouse
# still running, the bound it exceeded, the foreground, and the pane's own
# last lines. It must never claim treehouse failed to enter a worktree.
test_acquisition_past_its_bound_is_reported_as_still_running() {
  local rec id out status reads
  id=settle-fetch-bound-z6
  rec=$(make_settle_case settle-fetch-bound "$id" 100000 project)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  TREEHOUSE_READS=100000
  ACQUIRE_TIMEOUT=7
  PANE_TAIL='$ treehouse get\nFetching origin...\n'

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane whose acquisition never finished"$'\n'"$out"
  assert_contains "$out" "treehouse get is still running after the 7s acquisition bound (FM_SPAWN_ACQUIRE_TIMEOUT)" \
    "spawn did not report the acquisition as still running under its bound"
  assert_contains "$out" "foreground now: treehouse" \
    "spawn did not print the pane's foreground process"
  assert_contains "$out" "| Fetching origin..." \
    "spawn did not print the pane's last lines verbatim"
  assert_not_contains "$out" "did not enter" \
    "spawn claimed treehouse did not enter a worktree while it was still running"
  assert_not_contains "$out" "exited without entering" \
    "spawn claimed treehouse exited while it was still running"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -le 9 ] || fail "the 7s acquisition bound was not honoured: the spawn polled $reads times"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an acquisition past its bound is reported as still running, with the pane's foreground and last lines"
}

# The pool-cap incident: treehouse refuses in about 3s with a one-line reason
# on the pane and the shell returns to the project directory. The spawn must
# fail as soon as the shell is back there, not after the 60s bound, and the
# refusal must carry treehouse's own line.
test_pool_cap_refusal_fails_fast_with_the_pane_reason() {
  local rec id out status reads
  id=settle-pool-cap-z7
  rec=$(make_settle_case settle-pool-cap "$id" 100000 project)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  TREEHOUSE_READS=2
  PANE_TAIL='$ treehouse get\nerror: all 16 worktrees are in use or dirty (max_trees = 16); return one with treehouse return\n$ \n\n'

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane whose treehouse get refused"$'\n'"$out"
  assert_contains "$out" "treehouse get exited without entering a worktree" \
    "spawn did not report that treehouse exited without entering"
  assert_contains "$out" "back in the spawning project '$PROJ_DIR'" \
    "spawn did not say the shell returned to the project"
  assert_contains "$out" "| error: all 16 worktrees are in use or dirty (max_trees = 16)" \
    "spawn did not relay treehouse's own refusal line from the pane"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -le 6 ] || fail "the refusal should fail fast once the shell is back in the project, but the spawn polled $reads times"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a treehouse refusal fails fast and relays the pane's own reason"
}

# A backend that cannot read the pane's foreground has no positive evidence
# that an acquisition is under way, so its path-only poll is charged to the
# 60s settle bound and never to the acquisition bound: the per-project
# Treehouse lock is held across the wait, and a blind 600s hold would block
# the pool returns that free a slot. The pane text stands in for the
# foreground, and an error line printed BEFORE the echoed command (shell
# startup noise) must not be read as treehouse's verdict. The refusal names
# the gap instead of guessing which way treehouse went.
test_unreadable_foreground_gives_up_at_the_settle_bound() {
  local rec id out status reads
  id=settle-blind-z8
  rec=$(make_primary_case settle-blind "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  PANE_SHELL=
  ACQUIRE_TIMEOUT=100
  PANE_TAIL='error: prompt plugin failed to load\n$ treehouse get\nFetching origin...\n'

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never reported a worktree"$'\n'"$out"
  assert_contains "$out" "no isolated worktree appeared within 60s" \
    "spawn did not give up at the settle bound"
  assert_contains "$out" "could not read the pane's foreground process" \
    "spawn did not say the foreground was unreadable"
  assert_contains "$out" "no 'Entered worktree' line was seen in the pane, and no refusal was confirmed on two consecutive reads" \
    "spawn did not say the pane text showed no verdict"
  assert_contains "$out" "foreground now: unreadable on backend 'tmux'" \
    "spawn did not report the unreadable foreground"
  assert_not_contains "$out" "acquisition bound" \
    "spawn charged an unreadable foreground to the acquisition bound"
  assert_not_contains "$out" "did not enter" \
    "spawn claimed treehouse did not enter a worktree without any evidence"
  assert_not_contains "$out" "reported an error" \
    "spawn read shell startup noise printed before the command as treehouse's verdict"
  reads=$(cat "$COUNTFILE")
  { [ "$reads" -ge 61 ] && [ "$reads" -le 62 ]; } \
    || fail "an unreadable foreground must give up at the 60s settle bound, but the spawn polled $reads times"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an unreadable foreground gives up at the 60s settle bound and names the gap"
}

# On a backend without a foreground reader, treehouse's own "Entered worktree"
# line is the evidence that the acquisition finished, and it starts the settle
# phase: the pane's path then has the full 60s to settle on the worktree. The
# fetch here takes 40 polls, the entry line then appears, and the path settles
# 40 polls after that (80 project reads in all, past the plain settle bound)
# under an acquisition bound too short to have carried the wait on its own.
# An error line the nested shell prints after the entry must not undo it.
test_unreadable_foreground_entered_line_starts_the_settle_phase() {
  local rec id out status reads
  id=settle-blind-entered-z9
  rec=$(make_settle_case settle-blind-entered "$id" 80 project)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  PANE_SHELL=
  ACQUIRE_TIMEOUT=20
  PANE_TAIL='$ treehouse get\nFetching origin...\n'
  PANE_TAIL_LATE_READS=40
  PANE_TAIL_LATE="\$ treehouse get\nFetching origin...\n🌳 Entered worktree at $WT_DIR. Type 'exit' to return.\nerror: prompt plugin failed to load\n"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should proceed into the settle phase once the pane shows treehouse's entry line"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree treehouse entered"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -gt 60 ] || fail "the path was meant to settle past the plain 60-read settle bound, but the spawn only polled $reads times"
  [ "$reads" -eq 82 ] || fail "expected the 80 project reads plus the two agreeing worktree reads, got $reads"
  pass "an entry line in the pane text starts the settle phase on a backend without a foreground reader"
}

# The pool-cap refusal on a backend without a foreground reader: treehouse's
# error line lands in the pane text after the echoed command, and the spawn
# must fail as soon as it appears and relay that line, instead of waiting out
# any bound. The acquisition bound here is long enough to prove that.
test_unreadable_foreground_refusal_line_fails_fast() {
  local rec id out status reads
  id=settle-blind-refused-z10
  rec=$(make_settle_case settle-blind-refused "$id" 100000 project)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  PANE_SHELL=
  ACQUIRE_TIMEOUT=100
  PANE_TAIL='$ treehouse get\n'
  PANE_TAIL_LATE_READS=2
  PANE_TAIL_LATE="\$ treehouse get\nError: all 16 worktrees are in use or dirty (max_trees = 16). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml\n\$ \n\n"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane whose treehouse get refused"$'\n'"$out"
  assert_contains "$out" "treehouse get reported an error in the pane" \
    "spawn did not report the error line treehouse printed"
  assert_contains "$out" "| Error: all 16 worktrees are in use or dirty (max_trees = 16)" \
    "spawn did not relay treehouse's own refusal line from the pane"
  assert_contains "$out" "foreground now: unreadable on backend 'tmux'" \
    "spawn did not report the unreadable foreground"
  assert_not_contains "$out" "did not enter" \
    "spawn claimed treehouse did not enter a worktree instead of relaying its error"
  assert_not_contains "$out" "exited without entering" \
    "spawn claimed to know the shell was back in the project without a foreground read"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -le 4 ] || fail "the refusal line should fail the spawn at once, but the spawn polled $reads times"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a refusal line in the pane text fails fast on a backend without a foreground reader"
}

# Once treehouse's entry line has been seen, the pane text is treehouse's
# verdict no longer: the nested shell owns the pane from then on, and on
# zellij and cmux the path probes scroll the entry line out of the capture
# window while the shell's own startup noise stays inside it. The incident
# shape: entry seen, then a capture holding only an error line, and a path
# that never settles. The spawn must give up at the settle bound naming the
# entry it saw and the last path seen, never claim treehouse reported an
# error.
test_error_line_after_entry_is_not_read_as_a_refusal() {
  local rec id out status reads
  id=settle-blind-entry-noise-z11
  rec=$(make_primary_case settle-blind-entry-noise "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  PANE_SHELL=
  ACQUIRE_TIMEOUT=100
  PANE_TAIL="\$ treehouse get\n🌳 Entered worktree at $WT_DIR. Type 'exit' to return.\n"
  PANE_TAIL_LATE_READS=5
  PANE_TAIL_LATE='error: prompt plugin failed to load\n$ \n'

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane whose path never settled"$'\n'"$out"
  assert_contains "$out" "printed its 'Entered worktree' line, but no two consecutive path reads agreed on an isolated worktree within 60s after it" \
    "spawn did not name the entry it saw and the settle bound it reached"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_not_contains "$out" "reported an error in the pane" \
    "spawn read the nested shell's startup noise as a treehouse refusal after entry"
  assert_not_contains "$out" "did not enter" \
    "spawn claimed treehouse did not enter after seeing its entry line"
  reads=$(cat "$COUNTFILE")
  { [ "$reads" -ge 61 ] && [ "$reads" -le 62 ]; } \
    || fail "after entry only the settle bound applies, but the spawn polled $reads times"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an error line after treehouse's entry is not read as a refusal"
}

# The pty echoes the typed `treehouse get` in cooked mode BEFORE the shell
# runs its rc files, so for the first second or so the capture reads: the
# kernel's echo of the command, then any rc error line, then the prompt with
# its own redraw of the command. A poll inside that window sees an error line
# after the only echo. That noise must not fail the spawn: the verdict counts
# only once two consecutive polls agree, and the prompt's redraw clears it on
# the next poll. The path here settles on the worktree after three project
# reads, so the spawn must succeed with no refusal at all.
test_startup_noise_after_the_kernel_echo_is_not_a_refusal() {
  local rec id out status reads
  id=settle-blind-echo-noise-z12
  rec=$(make_settle_case settle-blind-echo-noise "$id" 3 project)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  PANE_SHELL=
  ACQUIRE_TIMEOUT=100
  PANE_TAIL='treehouse get\nerror: prompt plugin failed to load\n'
  PANE_TAIL_LATE_READS=1
  PANE_TAIL_LATE='treehouse get\nerror: prompt plugin failed to load\n$ treehouse get\nFetching origin...\n'

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should survive shell startup noise caught between the command's echo and the prompt's redraw"$'\n'"$out"
  assert_not_contains "$out" "reported an error in the pane" \
    "spawn read the shell's startup noise after the kernel's echo as treehouse's verdict"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree the pane settled on"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 5 ] || fail "expected the three project reads plus the two agreeing worktree reads, got $reads"
  pass "startup noise between the command's echo and the prompt's redraw is not a refusal"
}

# A genuine refusal on the same backend: treehouse's line stays in the
# capture after the command's echo and nothing redraws over it, so the second
# poll agrees with the first and the spawn fails then - one poll later than a
# single-read verdict would, and no later.
test_refusal_line_fails_on_the_second_agreeing_poll() {
  local rec id out status reads
  id=settle-blind-refused-twice-z13
  rec=$(make_settle_case settle-blind-refused-twice "$id" 100000 project)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  PANE_SHELL=
  ACQUIRE_TIMEOUT=100
  PANE_TAIL='$ treehouse get\nerror: all 16 worktrees are in use or dirty (max_trees = 16); return one with treehouse return\n$ \n'

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane whose treehouse get refused"$'\n'"$out"
  assert_contains "$out" "treehouse get reported an error in the pane" \
    "spawn did not report the error line treehouse printed"
  assert_contains "$out" "| error: all 16 worktrees are in use or dirty (max_trees = 16)" \
    "spawn did not relay treehouse's own refusal line from the pane"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 2 ] || fail "a refusal line must fail the spawn on exactly the second agreeing poll, but the spawn polled $reads times"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a refusal line fails the spawn on the second agreeing poll"
}

# The `unknown` refusal belongs to a wait in which no poll ever read the
# pane's foreground. A wait that read treehouse, then a shell for sixty
# polls, and lost the reader only on the final poll has all the evidence the
# settle refusal rests on, and must say so: the shell foreground it read,
# the treehouse run it saw, and the one read that failed.
test_single_failed_final_read_keeps_the_settle_refusal() {
  local rec id out status reads
  id=settle-last-read-failed-z14
  rec=$(make_primary_case settle-last-read-failed "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  TREEHOUSE_READS=2
  PANE_SHELL_READS=62
  ACQUIRE_TIMEOUT=100

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "foreground was a shell, not treehouse get; treehouse get was seen running in the pane" \
    "spawn did not report the shell foreground it read and the treehouse run it saw"
  assert_contains "$out" "foreground now: unreadable on backend 'tmux'" \
    "spawn did not report that the final read failed"
  assert_not_contains "$out" "could not read the pane's foreground process" \
    "spawn claimed the backend could not read the foreground after sixty readable polls"
  assert_not_contains "$out" "never seen running" \
    "spawn denied the treehouse run it read on the first polls"
  assert_not_contains "$out" "did not enter" \
    "spawn claimed treehouse did not enter a worktree without evidence of an exit"
  reads=$(cat "$COUNTFILE")
  { [ "$reads" -ge 63 ] && [ "$reads" -le 64 ]; } \
    || fail "two acquiring polls and sixty settle polls must end at the settle bound on the next poll, but the spawn polled $reads times"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a single failed final read keeps the settle refusal a readable wait earned"
}

# The two-agreeing-reads rule meets the settle bound: treehouse fetches for
# the whole bound and then refuses (the two incidents in the intent
# compounded), so the poll that crosses the bound is also the first poll to
# read the refusal line. The bound must hold for one more poll, so that the
# second read confirms the refusal and the spawn relays treehouse's line,
# instead of breaking at the bound under a headline that says the pane
# printed no error above a tail that shows one.
test_first_refused_read_on_the_bound_poll_still_reports_the_refusal() {
  local rec id out status reads
  id=settle-blind-refused-at-bound-z15
  rec=$(make_settle_case settle-blind-refused-at-bound "$id" 100000 project)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  PANE_SHELL=
  ACQUIRE_TIMEOUT=100
  PANE_TAIL='$ treehouse get\nFetching origin...\n'
  PANE_TAIL_LATE_READS=60
  PANE_TAIL_LATE="\$ treehouse get\nFetching origin...\nError: all 16 worktrees are in use or dirty (max_trees = 16). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml\n\$ \n"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane whose treehouse get refused"$'\n'"$out"
  assert_contains "$out" "treehouse get reported an error in the pane" \
    "spawn did not report the refusal line its last two reads showed"
  assert_contains "$out" "| Error: all 16 worktrees are in use or dirty (max_trees = 16)" \
    "spawn did not relay treehouse's own refusal line from the pane"
  assert_not_contains "$out" "no refusal was confirmed" \
    "spawn used the unconfirmed-refusal wording while relaying the refusal line its last two reads confirmed"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 62 ] || fail "the bound must hold for exactly one more poll so the second read can confirm the refusal, but the spawn polled $reads times"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a refusal first read on the bound poll is confirmed on the next poll and relayed"
}

# The other outcome of that held poll: a shell whose startup outlasts the
# bound prints its error line right at the bound, and the next read shows
# the prompt's redraw of the command over it. The verdict clears, so the
# spawn gives up at the bound on that very poll with the unreadable
# foreground refusal - one poll late, and no later.
test_refused_read_cleared_on_the_next_poll_ends_at_the_bound() {
  local rec id out status reads
  id=settle-blind-cleared-at-bound-z16
  rec=$(make_settle_case settle-blind-cleared-at-bound "$id" 100000 project)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  PANE_SHELL=
  ACQUIRE_TIMEOUT=100
  PANE_TAIL='treehouse get\n'
  PANE_TAIL_LATE_READS=61
  PANE_TAIL_LATE='treehouse get\nerror: prompt plugin failed to load\n$ treehouse get\n'
  settle_capture_at 61 'treehouse get\nerror: prompt plugin failed to load\n'

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never reported a worktree"$'\n'"$out"
  assert_contains "$out" "no 'Entered worktree' line was seen in the pane, and no refusal was confirmed on two consecutive reads" \
    "spawn did not give up at the bound once the refused read was cleared"
  assert_not_contains "$out" "reported an error in the pane" \
    "spawn treated a single refused read that the next read cleared as a refusal"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 62 ] || fail "a cleared refused read must end the wait at the bound on the very next poll, but the spawn polled $reads times"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a refused read cleared on the next poll ends the wait at the bound"
}

# The rule is two CONSECUTIVE refused reads, not two in total: any read that
# does not say refused resets the count. Captures that alternate (refused,
# the prompt's redraw, refused again, clear) never agree twice in a row, so
# the spawn must go on to settle on the worktree. Two cumulative reads would
# break on the third poll.
test_alternating_refused_reads_never_agree() {
  local rec id out status reads
  id=settle-blind-alternating-z17
  rec=$(make_settle_case settle-blind-alternating "$id" 4 project)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  reset_settle_knobs
  PANE_SHELL=
  ACQUIRE_TIMEOUT=100
  PANE_TAIL='treehouse get\nerror: prompt plugin failed to load\n$ treehouse get\nerror: completion cache is stale\n$ treehouse get\nFetching origin...\n'
  settle_capture_at 1 'treehouse get\nerror: prompt plugin failed to load\n'
  settle_capture_at 2 'treehouse get\nerror: prompt plugin failed to load\n$ treehouse get\n'
  settle_capture_at 3 'treehouse get\nerror: prompt plugin failed to load\n$ treehouse get\nerror: completion cache is stale\n'
  settle_capture_at 4 'treehouse get\nerror: prompt plugin failed to load\n$ treehouse get\nerror: completion cache is stale\n$ treehouse get\n'

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should settle on the worktree when refused reads never agree twice in a row"$'\n'"$out"
  assert_not_contains "$out" "reported an error in the pane" \
    "spawn counted two refused reads that did not follow each other as a refusal"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree the pane settled on"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 6 ] || fail "expected the four project reads plus the two agreeing worktree reads, got $reads"
  pass "refused reads that never agree twice in a row are not a refusal"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_slow_fetch_past_the_old_budget_still_spawns
test_acquisition_past_its_bound_is_reported_as_still_running
test_pool_cap_refusal_fails_fast_with_the_pane_reason
test_unreadable_foreground_gives_up_at_the_settle_bound
test_unreadable_foreground_entered_line_starts_the_settle_phase
test_unreadable_foreground_refusal_line_fails_fast
test_error_line_after_entry_is_not_read_as_a_refusal
test_startup_noise_after_the_kernel_echo_is_not_a_refusal
test_refusal_line_fails_on_the_second_agreeing_poll
test_single_failed_final_read_keeps_the_settle_refusal
test_first_refused_read_on_the_bound_poll_still_reports_the_refusal
test_refused_read_cleared_on_the_next_poll_ends_at_the_bound
test_alternating_refused_reads_never_agree

echo "# all fm-spawn-worktree-settle tests passed"
