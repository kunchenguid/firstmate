#!/usr/bin/env bash
# Regression test for fm-spawn.sh's shell-readiness gate (bin/fm-spawn.sh,
# spawn_wait_shell_ready and its two call sites).
#
# A pane's shell is not reading its pty the instant the pane exists. Anything
# typed before its line editor is up is swallowed - seen live on 2026-08-25
# spawning onto a project whose .envrc loads direnv plus devenv, where the
# echoed `treehouse get` sat above direnv's own loading line in the scrollback
# and never ran. Every spawn onto such a project failed. The pty echoes those
# swallowed keystrokes, so the pane's own text is not proof a command executed;
# only a side effect is.
#
# The fake backend here is a shell, not a stub: it models a pty line discipline
# with a swallow budget, discarding the first N submitted lines and EXECUTING
# every line after that. `treehouse get` therefore only moves the pane when it
# was actually delivered, and the agent only launches when its line was. Both
# spawn-time send stages are covered, because the pane's inner shell after
# `treehouse get` has its own startup and its own swallow window.
#
# The stub can also refuse a send outright, which is a DIFFERENT failure: a pane
# that cannot be reached at all is not a shell that is slow to start, and the
# spawn must attribute it that way instead of waiting out the whole readiness
# budget and then blaming shell-init latency.
#
# And a marker only proves anything while nothing else can write it. /tmp is
# world-writable and a task id is an ordinary slug, so the task temp root is a
# path another local account can pre-create: one case plants a root at a laxer
# mode and asserts the spawn keeps its marker in a private directory it created
# itself while leaving that root's mode alone, because a spawn that adjusted the
# mode of a path it did not create would follow a symlink raced into place; a
# second plants a root it cannot privately write and asserts a loud refusal
# rather than a marker that proves nothing. A third case pins the re-send
# cadence, which lands in the very scrollback an operator reads when a spawn is
# slow.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-shell-ready)
# Task ids carry this run's own token, because a task id is what names the
# per-task temp root under the shared real /tmp. Several worktrees of this repo
# run their gate on one host at the same time, so a fixed id would make two runs
# share - and reap - each other's roots mid-spawn. The mktemp suffix on this
# run's temp root is already unique to it, so it is the token.
RUN_TAG=${TMP_ROOT##*.}

path_mode() {  # <path>
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

path_owner() {  # <path>
  if [ "$(uname)" = Darwin ]; then stat -f %u "$1"; else stat -c %u "$1"; fi
}

# Privacy is owner plus the absence of group/other write, never one permission
# value: a setgid or default-ACL parent adds bits that grant nobody write, and
# a marker directory this account owns is private with them set.
path_group_or_other_writable() {  # <path>
  local perms
  perms=$(path_mode "$1")
  while [ "${#perms}" -lt 3 ]; do perms="0$perms"; done
  perms=${perms#"${perms%???}"}
  [ $(( ${perms:1:1} & 2 )) -ne 0 ] || [ $(( ${perms:2:1} & 2 )) -ne 0 ]
}

# The spawn writes its per-task temp root under real /tmp, because that path is
# the firstmate convention fm-teardown cleans up, so each case registers its own
# for reaping. Publishes TASK_TMP_PATH rather than echoing it: a command
# substitution would append to the cleanup list in a subshell that dies with it.
TASK_TMP_PATH=
use_task_tmp() {  # <id>
  TASK_TMP_PATH="/tmp/fm-$1"
  FM_TEST_CLEANUP_DIRS+=("$TASK_TMP_PATH")
}

# make_shell_fakebin <dir> builds the fake backend trio. The tmux stub keeps a
# one-line input buffer so it can distinguish tmux's three real send shapes -
# `send-keys -t T <text> Enter`, `send-keys -t T -l <text>`, and `send-keys -t T
# Enter` - and submits exactly like a terminal does. A submitted line is either
# swallowed (the shell is not reading yet) or evaluated. `treehouse get` and the
# harness binary are the observable effects of a line that really ran.
make_shell_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
S="${FM_FAKE_SHELL_STATE:?FM_FAKE_SHELL_STATE unset}"

submit_line() {
  local text=$1 budget=0
  [ -f "$S/swallow" ] && budget=$(cat "$S/swallow")
  if [ "$budget" -gt 0 ]; then
    printf '%s\n' "$((budget - 1))" > "$S/swallow"
    printf 'swallowed\t%s\n' "$text" >> "$S/lines.log"
    return 0
  fi
  printf 'ran\t%s\n' "$text" >> "$S/lines.log"
  (
    cd "$(cat "$S/cwd")" 2>/dev/null || true
    eval "$text"
  ) >> "$S/exec.out" 2>&1 || true
}

case "$*" in
  *"#{pane_current_path}"*) cat "$S/cwd"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    # A pane that is gone: the backend itself refuses to deliver, loudly, and
    # every attempt is recorded so a retry storm is visible to the test.
    if [ -f "$S/send-fails" ]; then
      printf 'attempt\n' >> "$S/send-attempts"
      printf "can't find pane: %s\n" "${3:-}" >&2
      exit 1
    fi
    if [ "${4:-}" = -l ]; then
      # A pane that dies in the gap between answering the readiness probe and
      # being typed into: only the literal send fails, so the gates themselves
      # still confirm exactly as they do against a healthy pane.
      if [ -f "$S/literal-fails" ]; then
        printf "can't find pane: %s\n" "${3:-}" >&2
        exit 1
      fi
      printf '%s' "${5:-}" >> "$S/buffer"
      exit 0
    fi
    if [ "${4:-}" = Enter ]; then
      buffered=$(cat "$S/buffer" 2>/dev/null || true)
      : > "$S/buffer"
      submit_line "$buffered"
      exit 0
    fi
    if [ "${5:-}" = Enter ]; then
      : > "$S/buffer"
      submit_line "${4:-}"
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
S="${FM_FAKE_SHELL_STATE:?FM_FAKE_SHELL_STATE unset}"
[ "${1:-}" = get ] || exit 0
# The pane moves into the worktree, and the worktree's own shell starts with
# its own startup window in which it is not yet reading input.
printf '%s\n' "${FM_FAKE_WT:?FM_FAKE_WT unset}" > "$S/cwd"
printf '%s\n' "${FM_FAKE_INNER_SWALLOW:-0}" > "$S/swallow"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
set -u
S="${FM_FAKE_SHELL_STATE:?FM_FAKE_SHELL_STATE unset}"
printf 'launched\n' >> "$S/launched.log"
exit 0
SH
  chmod +x "$fakebin/codex"
  printf '%s\n' "$fakebin"
}

# make_shell_case <name> <id> <outer-swallow> <inner-swallow>: a home, a project
# with a real worktree, and the fake backend's shell state seeded with the
# project as the starting cwd and the outer shell's swallow budget.
make_shell_case() {
  local name=$1 id=$2 outer=$3 inner=$4 case_dir home proj wt fakebin state
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  state="$case_dir/shell-state"
  fakebin=$(make_shell_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$state"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$proj" > "$state/cwd"
  printf '%s\n' "$outer" > "$state/swallow"
  : > "$state/buffer"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$state|$inner"
}

read_shell_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR STATE_DIR INNER_SWALLOW <<REC
$1
REC
}

run_shell_spawn() {
  local id=$1
  shift
  env "$@" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_SHELL_STATE="$STATE_DIR" FM_FAKE_WT="$WT_DIR" \
    FM_FAKE_INNER_SWALLOW="$INNER_SWALLOW" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# The reported defect: the pane's shell swallows the first sends, so a
# fire-and-forget `treehouse get` is lost and the spawn never enters a worktree.
# The shortened poll interval buys only wall clock: the swallow budget is spent
# per submitted line and the re-send cadence is counted in POLLS, so the same
# probe answers at the same poll number as it would at the shipped interval.
test_swallowed_worktree_entry_still_enters_the_worktree() {
  local rec id out status
  id=shell-ready-outer-z1-$RUN_TAG
  use_task_tmp "$id"
  rec=$(make_shell_case shell-ready-outer "$id" 3 0)
  read_shell_record "$rec"

  out=$(run_shell_spawn "$id" FM_SPAWN_SHELL_READY_INTERVAL=0.05)
  status=$?
  expect_code 0 "$status" "spawn should succeed once the shell starts reading input"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree treehouse get entered"
  assert_grep "$(printf 'ran\ttreehouse get')" "$STATE_DIR/lines.log" \
    "treehouse get was never executed by the pane's shell"
  assert_grep swallowed "$STATE_DIR/lines.log" \
    "the case did not actually exercise a shell that swallows input"
  pass "a shell that swallows its first sends still enters the worktree"
}

# The sibling half: the worktree's own shell has its own startup window, so the
# launch command is exposed to exactly the same swallow.
test_swallowed_launch_still_starts_the_agent() {
  local rec id out status
  id=shell-ready-inner-z2-$RUN_TAG
  use_task_tmp "$id"
  rec=$(make_shell_case shell-ready-inner "$id" 0 2)
  read_shell_record "$rec"

  out=$(run_shell_spawn "$id" FM_SPAWN_SHELL_READY_INTERVAL=0.05)
  status=$?
  expect_code 0 "$status" "spawn should succeed once the worktree shell starts reading input"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_present "$STATE_DIR/launched.log" \
    "the agent launch command was swallowed and never executed"
  assert_grep "export GOTMPDIR=" "$STATE_DIR/lines.log" \
    "the environment export never reached the worktree shell"
  assert_grep swallowed "$STATE_DIR/lines.log" \
    "the case did not actually exercise a worktree shell that swallows input"
  pass "a worktree shell that swallows its first sends still starts the agent"
}

# Bounded and loud: a shell that never reads input must refuse the spawn with a
# diagnostic naming what was not confirmed, not launch into a dead pane.
test_shell_that_never_reads_refuses_loudly() {
  local rec id out status
  id=shell-ready-never-z3-$RUN_TAG
  use_task_tmp "$id"
  rec=$(make_shell_case shell-ready-never "$id" 999 0)
  read_shell_record "$rec"

  out=$(run_shell_spawn "$id" \
    FM_SPAWN_SHELL_READY_POLLS=4 FM_SPAWN_SHELL_READY_INTERVAL=0.1 \
    FM_SPAWN_SHELL_READY_RESEND=2)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the shell never reads input"
  assert_contains "$out" "never confirmed it was reading input" \
    "the refusal did not name the unconfirmed readiness"
  assert_not_contains "$out" "spawned $id" "a refused spawn reported success"
  assert_absent "$STATE_DIR/launched.log" \
    "an agent was launched into a shell that is not reading input"
  pass "a shell that never reads input refuses the spawn with a bounded, loud diagnostic"
}

# The sibling gate refuses on the far side of meta publication, so the task
# record already exists and the window and worktree are real. The fleet reads
# <id>.status for a task's last state, and a spawn started in the background or
# by bootstrap discards the refusal on stderr - so without a durable record that
# task reads as spawned normally, with no agent and no reason.
test_launch_gate_refusal_is_recorded_as_the_tasks_last_state() {
  local rec id status
  id=shell-ready-launch-refusal-za-$RUN_TAG
  use_task_tmp "$id"
  rec=$(make_shell_case shell-ready-launch-refusal "$id" 0 999)
  read_shell_record "$rec"

  run_shell_spawn "$id" \
    FM_SPAWN_SHELL_READY_POLLS=4 FM_SPAWN_SHELL_READY_INTERVAL=0.05 \
    FM_SPAWN_SHELL_READY_RESEND=2 >/dev/null
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the worktree shell never reads input"
  assert_present "$HOME_DIR/state/$id.meta" \
    "a refused launch dropped the meta, leaving its live window unreapable by id"
  assert_grep "failed: task $id's endpoint shell never confirmed it was reading input" \
    "$HOME_DIR/state/$id.status" \
    "the post-meta launch refusal was not recorded as the task's last state"
  assert_absent "$STATE_DIR/launched.log" \
    "an agent was launched into a worktree shell that is not reading input"
  pass "a launch refusal after meta publication is recorded as the task's last state"
}

# The gate proves the shell is reading; it cannot promise the endpoint survives
# the moment after. A send that fails once the meta is published is the same
# half-published task as a refused gate - a real window and worktree with no
# agent - so it has to be reported the same way, not left to `set -e` aborting
# on the backend's own status with nothing recorded anywhere.
test_lost_launch_send_after_meta_is_recorded_as_the_tasks_last_state() {
  local rec id status
  id=shell-ready-lost-launch-zb-$RUN_TAG
  use_task_tmp "$id"
  rec=$(make_shell_case shell-ready-lost-launch "$id" 0 0)
  read_shell_record "$rec"
  : > "$STATE_DIR/literal-fails"

  run_shell_spawn "$id" \
    FM_SPAWN_SHELL_READY_POLLS=4 FM_SPAWN_SHELL_READY_INTERVAL=0.05 >/dev/null
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the launch command cannot be typed"
  assert_present "$HOME_DIR/state/$id.meta" \
    "a lost launch send dropped the meta, leaving its live window unreapable by id"
  assert_grep "failed: the agent launch command could not be typed into" \
    "$HOME_DIR/state/$id.status" \
    "a send that failed after meta publication was not recorded as the task's last state"
  assert_absent "$STATE_DIR/launched.log" \
    "an agent started even though its launch command was never delivered"
  pass "a launch send lost after meta publication is recorded as the task's last state"
}

# An endpoint that cannot be reached at all is a different failure from a shell
# that is slow to start, and it must be reported as itself. The regression this
# guards: a swallowed send status turned a dead pane into a full readiness
# budget of silent retries followed by the wrong diagnosis, which the spawn's
# synchronous callers pay in full. Attempt count, not wall clock, is the
# evidence - one refused send ends the wait.
test_unreachable_endpoint_refuses_with_the_backend_error() {
  local rec id out status attempts
  id=shell-ready-unreachable-z5-$RUN_TAG
  use_task_tmp "$id"
  rec=$(make_shell_case shell-ready-unreachable "$id" 0 0)
  read_shell_record "$rec"
  : > "$STATE_DIR/send-fails"

  out=$(run_shell_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the endpoint cannot be reached"
  assert_contains "$out" "could not be reached" \
    "the refusal did not name the unreachable endpoint"
  assert_contains "$out" "can't find pane" \
    "the backend's own diagnostic was swallowed"
  assert_not_contains "$out" "never confirmed it was reading input" \
    "an unreachable endpoint was misreported as a slow shell"
  assert_absent "$STATE_DIR/launched.log" \
    "an agent was launched into an endpoint that could not be reached"
  attempts=$(wc -l < "$STATE_DIR/send-attempts" | tr -d ' ')
  [ "$attempts" = 1 ] || fail "a refused send was retried $attempts times instead of refusing at once"
  pass "an unreachable endpoint refuses at once with the backend's own error"
}

# The probe is a typed line, so every re-send lands in the pane's scrollback and
# in its interactive shell history - the very scrollback an operator reads when a
# spawn is slow, which is the case this gate exists for. So re-sends back off
# instead of repeating at a flat cadence: still enough attempts to survive a
# shell that is not reading yet (the two swallow cases above prove that half),
# but a handful of lines over the whole budget rather than one per gap. Counted
# against the poll count, which is what a flat cadence would track.
test_unconfirmed_probe_backs_off_instead_of_flooding_the_pane() {
  local rec id out status probes polls=60
  id=shell-ready-backoff-z8-$RUN_TAG
  use_task_tmp "$id"
  rec=$(make_shell_case shell-ready-backoff "$id" 999 0)
  read_shell_record "$rec"

  out=$(run_shell_spawn "$id" \
    FM_SPAWN_SHELL_READY_POLLS="$polls" FM_SPAWN_SHELL_READY_INTERVAL=0.05 \
    FM_SPAWN_SHELL_READY_RESEND=2)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the shell never reads input"
  probes=$(grep -c 'touch ' "$STATE_DIR/lines.log" | tr -d ' ')
  [ "$probes" -ge 3 ] \
    || fail "the probe was sent only $probes time(s) over $polls polls, so a shell that starts reading late would never be probed again"
  [ "$probes" -le 10 ] \
    || fail "the probe was sent $probes times over $polls polls, so re-sends are not backing off and flood the pane an operator reads"
  pass "an unconfirmed probe backs off instead of flooding the pane"
}

# The marker is only proof while nothing else can write it, and /tmp/fm-<id> is a
# path another local account can pre-create at any mode it likes. The spawn's
# answer is a marker directory it creates ITSELF, atomically, inside that root -
# so this case plants the root world-readable and asserts two things at once:
# the marker really does live in a private directory the spawn created, and the
# planted root's own mode is left exactly as found. The second half is the point.
# A spawn that "tightened" a root it did not create would be chmod-ing a path
# whose identity it never established, and a local account can race a symlink
# into that path between the look and the chmod, redirecting the mode change onto
# any file this account owns.
test_planted_temp_root_keeps_its_mode_and_the_marker_stays_private() {
  local rec id out status marker_root
  id=shell-ready-planted-z6-$RUN_TAG
  rec=$(make_shell_case shell-ready-planted "$id" 0 0)
  read_shell_record "$rec"
  use_task_tmp "$id"
  mkdir -p "$TASK_TMP_PATH"
  chmod 755 "$TASK_TMP_PATH"

  out=$(run_shell_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed against a temp root it can write"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ "$(path_mode "$TASK_TMP_PATH")" = 755 ] \
    || fail "the spawn changed the mode of a temp root it did not create (now $(path_mode "$TASK_TMP_PATH"))"
  marker_root=$(find "$TASK_TMP_PATH" -maxdepth 1 -type d -name 'shell-ready.*' 2>/dev/null | head -n 1)
  [ -n "$marker_root" ] || fail "no readiness-marker directory was created under the temp root"
  if path_group_or_other_writable "$marker_root"; then
    fail "the readiness-marker directory is group- or other-writable (mode $(path_mode "$marker_root"))"
  fi
  [ "$(path_owner "$marker_root")" = "$(id -u)" ] \
    || fail "the readiness-marker directory is not owned by this account"
  pass "a planted temp root keeps its mode and the readiness marker stays private"
}

# The other half of the same rule: when a private marker directory cannot be
# created at all, the spawn has no way to prove the endpoint shell ran anything,
# so it must refuse loudly BEFORE typing a command it cannot afford to lose -
# rather than fall back to a shared path or push on unproven.
#
# Deliberately narrow: the root here already HOLDS gotmp and only then stopped
# being privately writable, which is why the spawn's own `mkdir -p <root>/gotmp`
# still returns 0 and the refusal under test is the one that fires. A genuinely
# foreign-planted root has no gotmp; there that mkdir fails first, `set -e` ends
# the spawn on a bare permission error, and none of this explanation reaches the
# operator. That wider case is NOT covered here and is tracked separately.
test_temp_root_that_cannot_hold_a_private_marker_refuses_the_spawn() {
  local rec id out status
  id=shell-ready-unwritable-z7-$RUN_TAG
  rec=$(make_shell_case shell-ready-unwritable "$id" 0 0)
  read_shell_record "$rec"
  use_task_tmp "$id"
  mkdir -p "$TASK_TMP_PATH/gotmp"
  chmod 500 "$TASK_TMP_PATH"

  out=$(run_shell_spawn "$id")
  status=$?
  chmod 755 "$TASK_TMP_PATH"
  [ "$status" -ne 0 ] || fail "spawn should refuse when it cannot create a private marker directory"
  assert_contains "$out" "could not create a private readiness-marker directory" \
    "the refusal did not name the marker directory it could not create"
  assert_absent "$STATE_DIR/launched.log" \
    "an agent was launched without a private readiness-marker directory"
  assert_absent "$STATE_DIR/lines.log" \
    "the spawn typed into the pane before it could hold a private readiness marker"
  pass "a temp root that cannot hold a private marker refuses the spawn"
}

# No behaviour change for a pane whose shell is already reading: every spawn
# pays this gate, so each gate must confirm on its FIRST poll rather than
# looping. Proven STRUCTURALLY, by handing each gate a budget of exactly one
# poll: a gate that confirms on that poll succeeds, and a gate that needs a
# second one runs out of budget, sets its refusal and exits non-zero, which the
# spawn's own status already fails this case on. Timing the same spawn twice at
# two poll intervals cannot prove that, because the difference bounds only the
# SUM across both gates - one gate polling twice fits inside the slack the other
# gate leaves, so it would pass while claiming a per-gate guarantee it never
# checked. The interval stays long enough that a shell which really is reading
# answers well inside the single poll.
READY_SLOW_INTERVAL=2
READY_SLOW_POLLS=1

run_ready_shell_spawn() {  # <case-name> <id> <interval> <polls>
  local name=$1 id=$2 interval=$3 polls=$4 rec out status
  use_task_tmp "$id"
  rec=$(make_shell_case "$name" "$id" 0 0)
  read_shell_record "$rec"
  out=$(run_shell_spawn "$id" FM_SPAWN_SHELL_READY_INTERVAL="$interval" \
    FM_SPAWN_SHELL_READY_POLLS="$polls")
  status=$?
  expect_code 0 "$status" "spawn should succeed against an already-reading shell"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_no_grep swallowed "$STATE_DIR/lines.log" \
    "the ready-shell case wrongly swallowed a send"
}

test_ready_shell_pays_at_most_one_poll_per_gate() {
  run_ready_shell_spawn shell-ready-one-poll "shell-ready-one-poll-z4-$RUN_TAG" \
    "$READY_SLOW_INTERVAL" "$READY_SLOW_POLLS"
  pass "an already-reading shell pays at most one readiness poll per gate"
}

test_swallowed_worktree_entry_still_enters_the_worktree
test_swallowed_launch_still_starts_the_agent
test_shell_that_never_reads_refuses_loudly
test_launch_gate_refusal_is_recorded_as_the_tasks_last_state
test_lost_launch_send_after_meta_is_recorded_as_the_tasks_last_state
test_unreachable_endpoint_refuses_with_the_backend_error
test_unconfirmed_probe_backs_off_instead_of_flooding_the_pane
test_planted_temp_root_keeps_its_mode_and_the_marker_stays_private
test_temp_root_that_cannot_hold_a_private_marker_refuses_the_spawn
test_ready_shell_pays_at_most_one_poll_per_gate

echo "# all fm-spawn-shell-ready tests passed"
