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
# budget and then blaming shell-init latency. And a composed line can fail in
# two further ways, each its own endpoint state: left TYPED but neither
# submitted nor cleared, so the text is sitting in the input line where it would
# prefix whatever is typed there next; or typed, unsubmitted, and then CLEARED
# again, so the endpoint answered twice and holds nothing. Neither may be told
# as an unreachable endpoint, and neither may be told as the other. Both only
# EXIST on a backend that composes a text line from a literal send plus Enter
# and then tries to clear what it typed when the Enter fails, so their cases
# drive a second stub over the same shell state - `cmux`, which really does
# compose it that way - rather than asking tmux for a status its single
# `send-keys ... Enter` cannot produce.
#
# What is NOT covered here, deliberately: the gate proves the shell was reading
# input immediately before a line is typed, not that the line then ran, and the
# launch line has no proof of its own on the far side (kimi's ready signal
# aside). A literal the backend delivered which the shell's next pre-prompt cycle
# flushes out of its input queue is indistinguishable from a delivered line in
# the pane's own text, so a spawn is still reported for it. That residual window
# is a named gap in fm-spawn.sh's own contract, not a behaviour with a case here.
#
# And a marker only proves anything while nothing else can write it. /tmp is
# world-writable and a task id is an ordinary slug, so the task temp root is a
# path another local account can pre-create: one case plants a root at a laxer
# mode and asserts the spawn keeps its marker in a private directory it created
# itself while leaving that root's mode alone, because a spawn that adjusted the
# mode of a path it did not create would follow a symlink raced into place; a
# second plants a root it cannot privately write and asserts a loud refusal
# rather than a marker that proves nothing; a third plants one any local account
# CAN write and asserts the same refusal, because the entry for the marker
# directory lives in that root and whoever writes the root can replace it, with
# a companion planting the 0775 an fm-spawn from before this requirement left on
# a umask-002 host and asserting the refusal names that cause and the way out,
# because a relaunch reaches it with the task's agent already stopped; a
# fourth plants it as a SYMLINK elsewhere and asserts the refusal lands before
# the spawn's own Go build temp is created through it, because `mkdir -p`
# resolves that link and a root the spawn did not create is one its refusal
# cleanup may not reclaim. A fifth case is about that root being shared rather
# than hostile - the task id alone names it, so a second home spawning the same
# id is in the same path, and a refused spawn must leave that home's marker
# standing instead of reaping the root out from under it. A sixth pins the
# re-send cadence, which lands in the very scrollback an operator reads when a
# spawn is slow.
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

# make_shell_cmux_fake <fakebin>: a `cmux` stub over the same shell state the
# tmux stub drives, so one line discipline serves both send shapes firstmate
# has. It exists because a text line is NOT one input event on every backend:
# cmux (like zellij) composes it from `send` plus `send-key enter`, and when the
# enter fails it tries `send-key ctrl-c` to clear what it just typed. When that
# clear fails too, the line is left sitting in the surface's input buffer and the
# adapter says so with its own status 2 - the only shape in which a send can be
# typed-but-uncleared at all. tmux submits in a single `send-keys ... Enter`, so
# it has no such state and never reports one; a case that needs the stranded
# outcome has to drive a backend that really composes the line, which is this
# one. Modelled faithfully: a stranded `send-key` leaves the buffer intact.
make_shell_cmux_fake() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/cmux" <<'SH'
#!/usr/bin/env bash
set -u
S="${FM_FAKE_SHELL_STATE:?FM_FAKE_SHELL_STATE unset}"
WS=ws-fake
SF=sf-fake

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

# Which composed-send failure this run models, keyed on the buffered text so a
# case can fail one specific line and leave the rest of the sequence alone.
# `stranded`: the Enter fails and the ctrl-c that follows fails too, so the text
# stays in the buffer. `cleared`: only the Enter fails, and the ctrl-c really
# does clear the buffer - the surface answered twice and nothing is left behind.
holds() {  # <state-file> <buffered-text>
  local want
  [ -f "$S/$1" ] || return 1
  want=$(cat "$S/$1")
  [ -n "$want" ] || return 1
  case "$2" in *"$want"*) return 0 ;; esac
  return 1
}

case "${1:-}" in
  version) printf 'cmux 0.64.17 (97) [abcdef1]\n'; exit 0 ;;
  ping) printf 'PONG\n'; exit 0 ;;
  workspace)
    if [ -f "$S/workspace-title" ]; then
      printf '{"workspaces":[{"id":"%s","title":"%s"}]}\n' "$WS" "$(cat "$S/workspace-title")"
    else
      printf '{"workspaces":[]}\n'
    fi
    exit 0
    ;;
  new-workspace)
    title=
    while [ $# -gt 0 ]; do
      case "$1" in --name) title=${2:-}; shift ;; esac
      shift
    done
    printf '%s' "$title" > "$S/workspace-title"
    exit 0
    ;;
  list-panes)
    printf '{"panes":[{"selected_surface_id":"%s","surface_ids":["%s"]}]}\n' "$SF" "$SF"
    exit 0
    ;;
  read-screen)
    jq -Rs '{text: .}' < "$S/exec.out" 2>/dev/null || printf '{"text":""}\n'
    exit 0
    ;;
  send)
    # A surface that cannot be reached at all: nothing is typed, and every
    # attempt is recorded so a retry storm is visible to the test.
    if [ -f "$S/send-fails" ]; then
      printf 'attempt\n' >> "$S/send-attempts"
      printf 'cmux: no such surface: %s\n' "$SF" >&2
      exit 1
    fi
    text=
    while [ $# -gt 0 ]; do
      case "$1" in --) text=${2:-}; break ;; esac
      shift
    done
    printf '%s' "$text" >> "$S/buffer"
    exit 0
    ;;
  send-key)
    shift
    while [ $# -gt 0 ]; do
      case "$1" in --workspace|--surface) shift 2 ;; *) break ;; esac
    done
    key=${1:-}
    buffered=$(cat "$S/buffer" 2>/dev/null || true)
    case "$key" in
      enter)
        if holds stranded "$buffered" || holds cleared "$buffered"; then
          printf 'unsubmitted\t%s\n' "$buffered" >> "$S/lines.log"
          printf 'cmux: send-key enter failed\n' >&2
          exit 1
        fi
        : > "$S/buffer"
        submit_line "$buffered"
        exit 0
        ;;
      ctrl-c)
        # In the stranded case the clear of a line this stub could not submit
        # fails too, which is exactly what leaves the text sitting in the input
        # buffer. In the cleared case it succeeds and empties the buffer below,
        # so the surface has answered twice and holds nothing.
        if holds stranded "$buffered"; then
          printf 'cmux: send-key ctrl-c failed\n' >&2
          exit 1
        fi
        : > "$S/buffer"
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/cmux"
}

# make_shell_fakebin <dir> [backend] builds the fake backend trio. The tmux stub
# keeps a one-line input buffer so it can distinguish tmux's three real send
# shapes - `send-keys -t T <text> Enter`, `send-keys -t T -l <text>`, and
# `send-keys -t T Enter` - and submits exactly like a terminal does. A submitted
# line is either swallowed (the shell is not reading yet) or evaluated.
# `treehouse get` and the harness binary are the observable effects of a line
# that really ran. Passing `cmux` as the backend adds a cmux stub over the SAME
# shell state, so a case can drive the identical line discipline through the one
# other send shape firstmate supports (see make_shell_cmux_fake).
make_shell_fakebin() {
  local dir=$1 backend=${2:-tmux} fakebin
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
  # The window inventory only carries a window once it has been created, so the
  # spawn's own duplicate-name check still sees an empty session first.
  list-windows) [ -f "$S/windows" ] && cat "$S/windows"; exit 0 ;;
  new-window)
    wname=
    while [ $# -gt 0 ]; do
      case "$1" in -n) wname=${2:-}; shift ;; esac
      shift
    done
    [ -z "$wname" ] || printf '%s\n' "$wname" >> "$S/windows"
    printf '@1\n'
    exit 0
    ;;
  send-keys)
    # A SECOND home spawning this same task id, using the same /tmp/fm-<id> the
    # id alone names. Its readiness marker appears in that shared root while
    # this spawn is still typing into its pane - which is the only moment a
    # concurrent home is observable from here, and the moment that decides
    # whether this spawn's own refusal cleanup takes that marker with it.
    [ -z "${FM_FAKE_SHARED_ROOT_ENTRY:-}" ] || mkdir -p "$FM_FAKE_SHARED_ROOT_ENTRY"
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
      # tmux types and submits in this ONE call, so it has no state in which a
      # line was typed and then left unsubmitted and uncleared, and no status
      # for one. The stub models no such outcome here for that reason; the cmux
      # stub above owns it, because cmux really does compose the line.
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
  [ "$backend" != cmux ] || make_shell_cmux_fake "$fakebin"
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

# make_shell_case <name> <id> <outer-swallow> <inner-swallow> [backend]: a home,
# a project with a real worktree, and the fake backend's shell state seeded with
# the project as the starting cwd and the outer shell's swallow budget. The
# backend defaults to tmux and is carried in the record, because it decides which
# send shape the case drives - and the spawn is always told explicitly rather
# than left to detection, so one case's choice cannot leak into another's.
make_shell_case() {
  local name=$1 id=$2 outer=$3 inner=$4 backend=${5:-tmux}
  local case_dir home proj wt fakebin state
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  state="$case_dir/shell-state"
  fakebin=$(make_shell_fakebin "$case_dir/fake" "$backend")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$state"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$proj" > "$state/cwd"
  printf '%s\n' "$outer" > "$state/swallow"
  : > "$state/buffer"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$state|$inner|$backend"
}

read_shell_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR STATE_DIR INNER_SWALLOW CASE_BACKEND <<REC
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
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
    --backend "${CASE_BACKEND:-tmux}" 2>&1
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
  [ ! -d "$TASK_TMP_PATH" ] \
    || fail "a refused spawn left behind the empty per-task temp root it created"
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

# A probe the backend TYPED but could neither submit nor clear is the opposite of
# an endpoint that never answered, and it names a different repair: the probe
# text is sitting in that shell's input line, where it would prefix whatever is
# typed there next. Reporting it as a probe that "was never typed" points the
# operator at a pane state that is not the one they have, and hides the text they
# have to clear before anything else is typed there. Re-sending is wrong for the
# same reason - it would append a second probe onto the first.
test_stranded_probe_refuses_as_uncleared_input() {
  local rec id out status probes
  id=shell-ready-stranded-z9-$RUN_TAG
  use_task_tmp "$id"
  rec=$(make_shell_case shell-ready-stranded "$id" 0 0 cmux)
  read_shell_record "$rec"
  printf 'worktree-entry\n' > "$STATE_DIR/stranded"

  out=$(run_shell_spawn "$id" \
    FM_SPAWN_SHELL_READY_POLLS=4 FM_SPAWN_SHELL_READY_INTERVAL=0.05 \
    FM_SPAWN_SHELL_READY_RESEND=2)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when its probe can be neither submitted nor cleared"
  assert_contains "$out" "input could not be cleared" \
    "the refusal did not name the probe text left sitting in the endpoint shell's input line"
  assert_not_contains "$out" "was never typed" \
    "a probe that WAS typed was reported as one that was never typed"
  assert_not_contains "$out" "could not be reached" \
    "an endpoint that answered the send was reported as unreachable"
  assert_not_contains "$out" "never confirmed it was reading input" \
    "stranded probe text was misreported as a slow shell"
  assert_no_grep "$(printf 'ran\ttreehouse get')" "$STATE_DIR/lines.log" \
    "a worktree was acquired through a shell holding unsubmitted probe text"
  assert_absent "$STATE_DIR/launched.log" \
    "an agent was launched into a shell holding unsubmitted probe text"
  probes=$(grep -c 'touch ' "$STATE_DIR/lines.log" | tr -d ' ')
  [ "$probes" = 1 ] \
    || fail "the probe was sent $probes times, so a re-send was appended onto text the endpoint could not clear"
  pass "a probe that could not be submitted or cleared refuses as uncleared input"
}

# The third failure of a composed send, and the one a two-way reading gets
# backwards: the literal landed, only the Enter failed, and the ctrl-c that
# followed really did clear the line. The endpoint answered twice and its input
# line is clean - so calling it unreachable sends the operator to a dead-pane or
# dropped-server repair for a pane that is alive, and calling it uncleared input
# sends them looking for text that is not there. The whole cost lands on the
# operator: this gate also runs after the meta is published, where its refusal
# becomes the task's durable last state that the fleet reads back.
test_cleared_probe_refuses_as_neither_unreachable_nor_uncleared() {
  local rec id out status probes
  id=shell-ready-cleared-zd-$RUN_TAG
  use_task_tmp "$id"
  rec=$(make_shell_case shell-ready-cleared "$id" 0 0 cmux)
  read_shell_record "$rec"
  printf 'worktree-entry\n' > "$STATE_DIR/cleared"

  out=$(run_shell_spawn "$id" \
    FM_SPAWN_SHELL_READY_POLLS=4 FM_SPAWN_SHELL_READY_INTERVAL=0.05 \
    FM_SPAWN_SHELL_READY_RESEND=2)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when its probe was typed and then cleared"
  assert_contains "$out" "typed into" \
    "the refusal did not say the probe reached the endpoint at all"$'\n'"$out"
  assert_contains "$out" "cleared again" \
    "the refusal did not say the probe was cleared, so nothing names the state the endpoint is in"$'\n'"$out"
  assert_not_contains "$out" "could not be reached" \
    "an endpoint that answered both the send and the clear was reported as unreachable"$'\n'"$out"
  assert_not_contains "$out" "input could not be cleared" \
    "a probe the endpoint DID clear was reported as input still sitting in its input line"$'\n'"$out"
  assert_not_contains "$out" "never confirmed it was reading input" \
    "a cleared probe was misreported as a slow shell"$'\n'"$out"
  assert_no_grep "$(printf 'ran\ttreehouse get')" "$STATE_DIR/lines.log" \
    "a worktree was acquired through a shell whose probe never ran"
  assert_absent "$STATE_DIR/launched.log" \
    "an agent was launched after a probe that never ran"
  probes=$(grep -c 'touch ' "$STATE_DIR/lines.log" | tr -d ' ')
  [ "$probes" = 1 ] \
    || fail "the probe was sent $probes times, so a send that failed on its own error was retried anyway"
  pass "a probe that was typed and then cleared refuses as neither unreachable nor uncleared"
}

# The same rule on the far side of meta publication, where the spawn's callers
# read <id>.status rather than stderr: the export is sitting uncleared in the
# worktree shell's input line, so the launch command must not be appended to it
# and the task's last state must name the input to clear.
test_stranded_export_is_recorded_as_uncleared_input() {
  local rec id out status
  id=shell-ready-stranded-export-zc-$RUN_TAG
  use_task_tmp "$id"
  rec=$(make_shell_case shell-ready-stranded-export "$id" 0 0 cmux)
  read_shell_record "$rec"
  printf 'export GOTMPDIR=\n' > "$STATE_DIR/stranded"

  out=$(run_shell_spawn "$id" FM_SPAWN_SHELL_READY_INTERVAL=0.05)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the Go temp export can be neither submitted nor cleared"
  assert_contains "$out" "input could not be cleared" \
    "the refusal did not name the export text left sitting in the worktree shell's input line"
  assert_present "$HOME_DIR/state/$id.meta" \
    "a stranded export dropped the meta, leaving its live window unreapable by id"
  assert_grep "failed: the Go temp export input could not be cleared" \
    "$HOME_DIR/state/$id.status" \
    "uncleared export input was not recorded as the task's last state"
  assert_absent "$STATE_DIR/launched.log" \
    "the launch command was appended onto an export the endpoint could not clear"
  pass "an export that could not be submitted or cleared is recorded as uncleared input"
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
# Narrow on purpose: the root here already HOLDS gotmp and only then stopped
# being privately writable, which is why the spawn's own `mkdir -p <root>/gotmp`
# still returns 0 and the refusal under test is the one that fires. The wider
# case - a root with no gotmp at all, where that mkdir is what fails first - is
# the sibling case below.
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
  assert_contains "$out" "endpoint firstmate:fm-$id already exists" \
    "the refusal did not name the endpoint this spawn had already created, so the remedy does not describe a spawnable state"$'\n'"$out"
  assert_absent "$STATE_DIR/launched.log" \
    "an agent was launched without a private readiness-marker directory"
  assert_absent "$STATE_DIR/lines.log" \
    "the spawn typed into the pane before it could hold a private readiness marker"
  pass "a temp root that cannot hold a private marker refuses the spawn"
}

# The wider half of the same threat model: a temp root this account cannot write
# INTO at all, so the spawn's own `mkdir -p <root>/gotmp` is what fails, before
# any marker directory is attempted. This account OWNS the root here, which is
# what makes the case reach that guard at all - a root belonging to another
# account is refused earlier, by the identity check, at any mode. The shape
# that survives to the guard is a root this account cannot write into (planted
# at 0500 below, as a stale or externally re-moded root would be) or a /tmp
# that cannot hold it. The window already exists by then, so the failure that
# must not happen is the silent one: `set -e` ending the spawn on a bare
# `mkdir: .../gotmp: Permission denied`, which leaves the operator an orphan
# pane and a path with no stated connection to a spawn - while the marker
# refusal one line later explains itself in full.
test_temp_root_the_spawn_cannot_write_into_refuses_by_name() {
  local rec id out status
  id=shell-ready-unwritable-root-ze-$RUN_TAG
  rec=$(make_shell_case shell-ready-unwritable-root "$id" 0 0)
  read_shell_record "$rec"
  use_task_tmp "$id"
  mkdir -p "$TASK_TMP_PATH"
  chmod 500 "$TASK_TMP_PATH"

  out=$(run_shell_spawn "$id")
  status=$?
  chmod 755 "$TASK_TMP_PATH"
  [ "$status" -ne 0 ] || fail "spawn should refuse when it cannot write its own per-task temp root"
  assert_contains "$out" "could not create the per-task temp root $TASK_TMP_PATH" \
    "the refusal did not name the temp root it could not create, so the operator gets a bare mkdir error"$'\n'"$out"
  assert_contains "$out" "refusing to spawn" \
    "the refusal did not say the spawn was refused"$'\n'"$out"
  assert_contains "$out" "endpoint firstmate:fm-$id already exists" \
    "the refusal did not name the endpoint this spawn had already created, so the remedy does not describe a spawnable state"$'\n'"$out"
  assert_absent "$STATE_DIR/lines.log" \
    "the spawn typed into the pane before it had a temp root to hold its readiness marker"
  assert_absent "$STATE_DIR/launched.log" \
    "an agent was launched without a per-task temp root"
  pass "a temp root the spawn cannot write into refuses by name instead of a bare mkdir error"
}

# The other side of that cleanup, and the reason it is a `rmdir` rather than a
# `rm -rf`. /tmp/fm-<id> is named after the task id and nothing else, so every
# home on the host spawning that id shares this one path, and the per-home locks
# firstmate takes say nothing about each other. "This spawn created the root" is
# therefore not "this spawn is alone in it": a second home can adopt it moments
# later and put its own readiness marker - or a launched worker's live GOTMPDIR
# contents - inside. A refused spawn that removed the root recursively would
# take that with it, turning another home's proven-ready shell into a false
# readiness refusal or pulling a running worker's build temp out from under it.
test_refused_spawn_leaves_another_homes_marker_in_the_shared_temp_root() {
  local rec id out status foreign
  id=shell-ready-shared-root-zf-$RUN_TAG
  use_task_tmp "$id"
  foreign="$TASK_TMP_PATH/shell-ready.other-home"
  rec=$(make_shell_case shell-ready-shared-root "$id" 999 0)
  read_shell_record "$rec"

  out=$(run_shell_spawn "$id" FM_FAKE_SHARED_ROOT_ENTRY="$foreign" \
    FM_SPAWN_SHELL_READY_POLLS=4 FM_SPAWN_SHELL_READY_INTERVAL=0.1 \
    FM_SPAWN_SHELL_READY_RESEND=2)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the shell never reads input"
  [ -d "$foreign" ] \
    || fail "the refused spawn deleted another home's readiness marker from the shared temp root $TASK_TMP_PATH"
  [ -d "$TASK_TMP_PATH" ] \
    || fail "the refused spawn removed a shared temp root another home still had work in"
  pass "a refused spawn leaves another home's marker standing in the shared temp root"
}

# A marker directory is private because of the root it sits in, not only because
# of its own unguessable name: the ENTRY for it lives in that root, so an
# account that can write the root can rename it away and leave a symlink under
# the same name, after which the fixed `worktree-entry` and `launch` marker
# names are created and removed through the replacement instead. No re-check of
# the marker directory can catch that - the swap fits between any check and the
# operation it guards - so the requirement lands on the parent, where writing it
# is the one thing that has to be impossible. /tmp is world-writable and a task
# id is an ordinary predictable slug, so a root at a mode that grants that write
# is a root another local account can plant.
test_group_or_other_writable_temp_root_refuses_the_spawn() {
  local rec id out status
  id=shell-ready-lax-root-zg-$RUN_TAG
  rec=$(make_shell_case shell-ready-lax-root "$id" 0 0)
  read_shell_record "$rec"
  use_task_tmp "$id"
  mkdir -p "$TASK_TMP_PATH"
  chmod 777 "$TASK_TMP_PATH"

  out=$(run_shell_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a temp root any local account can write"
  assert_contains "$out" "per-task temp root $TASK_TMP_PATH is not private" \
    "the refusal did not name the temp root that cannot hold a trustworthy marker"$'\n'"$out"
  assert_absent "$STATE_DIR/lines.log" \
    "the spawn typed into the pane while its readiness marker could be replaced by another account"
  assert_absent "$STATE_DIR/launched.log" \
    "an agent was launched with a readiness marker another account could replace"
  [ ! -e "$TASK_TMP_PATH/gotmp" ] \
    || fail "the spawn created gotmp inside a temp root any local account can write, before establishing that root's identity"
  assert_contains "$out" "Remove $TASK_TMP_PATH" \
    "the refusal did not tell the operator how to clear a root only a write bit disqualifies"$'\n'"$out"
  assert_contains "$out" "previous agent already stopped" \
    "the refusal did not say a relaunch arrives here with nothing running"$'\n'"$out"
  [ "$(path_mode "$TASK_TMP_PATH")" = 777 ] \
    || fail "the spawn changed the mode of a temp root it did not create (now $(path_mode "$TASK_TMP_PATH"))"
  pass "a group- or other-writable temp root refuses the spawn instead of holding an unprovable marker"
}

# The one shape of that refusal an operator is expected to meet in practice, and
# the reason it carries a remedy rather than only a verdict. Roots created before
# this requirement existed came from a bare `mkdir -p` at the host umask, so a
# umask-002 host - Debian and Ubuntu's user-private-group default - left them
# 0775: owned by this account, writable by nobody else in practice, and still
# disqualified, because the group-write bit is a grant and the check cannot know
# who is in that group. The refusal must therefore name the CAUSE and the way
# out, since `bin/fm-control.sh <id> relaunch` stops the old agent before
# fm-spawn runs and this message is then the operator's only guidance. That
# remedy has to cover the endpoint too: every refusal in this class fires after
# a fresh spawn has already created the window, which is left standing for
# inspection and is exactly what the operator's next attempt collides with. Removing
# the root is the whole remedy, and it has to be the ONLY one offered: teardown
# would also clear the root, but it is the task's end-of-life path - it kills
# the endpoint and hard-resets or removes the worktree - so naming it to an
# operator who has just lost their agent invites them to destroy the task they
# were relaunching.
test_group_writable_temp_root_names_its_cause_and_remedy() {
  local rec id out status
  id=shell-ready-upgrade-root-zi-$RUN_TAG
  rec=$(make_shell_case shell-ready-upgrade-root "$id" 0 0)
  read_shell_record "$rec"
  use_task_tmp "$id"
  mkdir -p "$TASK_TMP_PATH/gotmp"
  chmod 775 "$TASK_TMP_PATH"

  out=$(run_shell_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a temp root whose group-write bit is set"
  assert_contains "$out" "its group-write bit is set, mode 775" \
    "the refusal did not name the bit that disqualified the root"$'\n'"$out"
  assert_contains "$out" "predates this requirement" \
    "the refusal did not name the likely cause of a 0775 root this account owns"$'\n'"$out"
  assert_contains "$out" "Remove $TASK_TMP_PATH" \
    "the refusal did not tell the operator how to clear the root"$'\n'"$out"
  assert_contains "$out" "previous agent already stopped" \
    "the refusal did not say a relaunch arrives here with nothing running"$'\n'"$out"
  case "$out" in
    *teardown*)
      fail "the refusal pointed the operator at teardown, which ends the task, to clear a temp root"$'\n'"$out" ;;
  esac
  assert_contains "$out" "endpoint firstmate:fm-$id already exists" \
    "the refusal did not name the endpoint this spawn had already created, so the remedy does not describe a spawnable state"$'\n'"$out"
  assert_contains "$out" "before another spawn of $id can create its own" \
    "the refusal did not say the endpoint it left standing blocks the next spawn"$'\n'"$out"
  [ "$(path_mode "$TASK_TMP_PATH")" = 775 ] \
    || fail "the spawn changed the mode of a temp root it did not create (now $(path_mode "$TASK_TMP_PATH"))"
  assert_absent "$STATE_DIR/lines.log" \
    "the spawn typed into the pane over a root whose readiness marker another account could replace"
  assert_absent "$STATE_DIR/launched.log" \
    "an agent was launched over a group-writable per-task temp root"
  pass "a group-writable temp root refuses with the cause and the remedy, not just a verdict"
}

# The same threat model one step earlier, and the reason the root's identity is
# established BEFORE anything is written into it. /tmp/fm-<id> is a predictable
# name another local account can pre-create as a SYMLINK into a directory it
# controls, and `mkdir -p <root>/gotmp` resolves that link like any other path
# component - so a spawn that created its Go build temp first and only then
# asked what the root was would already have made a directory wherever the
# planter pointed, at a path its own refusal cleanup cannot reclaim (the create
# it never won means it must not remove anything). The refusal must therefore
# land before the first write, and the planted link must be left exactly as
# found, for the same reason no mode of it is ever adjusted.
test_symlinked_temp_root_refuses_before_writing_into_it() {
  local rec id out status target
  id=shell-ready-linked-root-zh-$RUN_TAG
  rec=$(make_shell_case shell-ready-linked-root "$id" 0 0)
  read_shell_record "$rec"
  target="$TMP_ROOT/shell-ready-linked-root/planted-elsewhere"
  mkdir -p "$target"
  use_task_tmp "$id"
  ln -s "$target" "$TASK_TMP_PATH"

  out=$(run_shell_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a temp root that is a symlink to somewhere else"
  assert_contains "$out" "per-task temp root $TASK_TMP_PATH is not private" \
    "the refusal did not name the temp root whose identity it could not establish"$'\n'"$out"
  assert_contains "$out" "replaced by a symlink" \
    "the refusal did not say the root was not a plain directory"$'\n'"$out"
  [ ! -e "$target/gotmp" ] \
    || fail "the spawn created $target/gotmp through the planted symlink before establishing the root's identity"
  [ -L "$TASK_TMP_PATH" ] \
    || fail "the spawn replaced the planted symlink at $TASK_TMP_PATH instead of leaving it as found"
  case "$out" in
    *"predates this requirement"*)
      fail "the refusal blamed an upgrade-era mode on a root whose identity was never this account's"$'\n'"$out" ;;
  esac
  assert_absent "$STATE_DIR/lines.log" \
    "the spawn typed into the pane with its readiness marker pointed at another account's directory"
  assert_absent "$STATE_DIR/launched.log" \
    "an agent was launched with a symlinked per-task temp root"
  pass "a symlinked temp root refuses the spawn before anything is written through it"
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
test_stranded_probe_refuses_as_uncleared_input
test_cleared_probe_refuses_as_neither_unreachable_nor_uncleared
test_stranded_export_is_recorded_as_uncleared_input
test_unconfirmed_probe_backs_off_instead_of_flooding_the_pane
test_planted_temp_root_keeps_its_mode_and_the_marker_stays_private
test_temp_root_that_cannot_hold_a_private_marker_refuses_the_spawn
test_temp_root_the_spawn_cannot_write_into_refuses_by_name
test_group_or_other_writable_temp_root_refuses_the_spawn
test_group_writable_temp_root_names_its_cause_and_remedy
test_symlinked_temp_root_refuses_before_writing_into_it
test_refused_spawn_leaves_another_homes_marker_in_the_shared_temp_root
test_ready_shell_pays_at_most_one_poll_per_gate

echo "# all fm-spawn-shell-ready tests passed"
