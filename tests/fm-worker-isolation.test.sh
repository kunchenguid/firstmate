#!/usr/bin/env bash
# Regression tests for task-worker isolation: the launched-agent home
# declaration, the refusals that depend on it, /proc as the method of record for
# an agent's working directory, pooled-slot ownership, and the resume-time
# re-assertion sweep.
#
# The defects these pin (all observed live, 2026-07-24/25):
#   - an audit worker inherited the primary's FM_HOME and took the primary's own
#     session-owner record, locking the real primary out of its home;
#   - a restore resumed every recorded agent session but resolved 17 of 17
#     worktrees back onto their origin repository, four into the primary
#     checkout, so the spawn-time isolation assertion did not survive;
#   - ten pooled slots were recorded by more than one task, and releasing one
#     task's lease reissued a slot a still-live paused task also held;
#   - a pane cwd field named the wrong process and reported an isolated worker
#     as living in the primary checkout.
#
# Kimi's launch declaration is asserted in tests/fm-kimi-harness.test.sh, which
# owns that adapter's readiness and delivery gates; the five adapters that need
# no readiness gate are driven end to end here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
LOCK="$ROOT/bin/fm-lock.sh"
SWEEP="$ROOT/bin/fm-isolation-sweep.sh"
NUDGE="$ROOT/bin/fm-sessionstart-nudge.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-isolation)

# Fixture agents are real long-lived processes, and the code under test finds
# them by scanning /proc for a declaration marker. Two hygiene rules follow.
#
# Every fixture id carries RUN_TAG, so a process leaked by an earlier run - a
# run killed outright, before its trap could fire - can never be mistaken for
# this run's agent. Without it a stale `sleep` answers a later lookup and the
# suite fails for a reason that is not in the diff.
#
# Every fixture process also carries FM_AGENT_TEST_RUN, so cleanup can find them
# all by marker rather than by bookkeeping. Recorded pids alone are not enough:
# a fixture started inside a command substitution registers its pid in a
# subshell that is already gone, and a parent/child fixture leaves the child
# behind when only the parent is signalled.
RUN_TAG=$$
BG_PIDS=()
worker_isolation_cleanup() {
  local pid entry marker
  for pid in "${BG_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  for entry in /proc/[0-9]*; do
    [ -d "$entry" ] || continue
    pid=${entry#/proc/}
    marker=$( { tr '\0' '\n' < "$entry/environ"; } 2>/dev/null \
      | sed -n 's/^FM_AGENT_TEST_RUN=//p' | head -1)
    [ "$marker" = "$RUN_TAG" ] || continue
    kill -9 "$pid" 2>/dev/null
  done
  fm_test_cleanup
}
trap worker_isolation_cleanup EXIT

# start_declared_agent <cwd> <task-id> <home> [role]: start a live process that
# carries the declaration bin/fm-spawn.sh injects, from <cwd>. Echoes its pid.
# The agent's own descriptors are detached from this function's stdout: a
# long-lived background process that inherits the write end of a caller's
# command substitution keeps that substitution blocked until the process exits.
start_declared_agent() {
  local cwd=$1 id=$2 home=$3 role=${4:-crewmate} pid
  ( cd "$cwd" \
    && FM_AGENT_ROLE="$role" FM_AGENT_TASK="$id" FM_AGENT_OWNER_HOME="$home" \
       FM_AGENT_TEST_RUN="$RUN_TAG" \
       exec sleep 300 ) >/dev/null 2>&1 </dev/null &
  pid=$!
  BG_PIDS+=("$pid")
  # Wait for the exec'd process to actually be in place before it is inspected.
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -e "/proc/$pid/cwd" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  printf '%s\n' "$pid"
}

require_procfs() {
  [ -d /proc ] && [ -L "/proc/$$/cwd" ]
}

# --- A. the home declaration itself -----------------------------------------

test_crewmate_declaration_clears_every_inherited_home() {
  local prefix
  prefix=$( . "$ROOT/bin/fm-worker-isolation-lib.sh" \
    && fm_worker_launch_env_prefix crewmate task-a1 /home/cap/firstmate )
  [ "$prefix" = "FM_HOME= FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_AGENT_ROLE=crewmate FM_AGENT_TASK='task-a1' FM_AGENT_OWNER_HOME='/home/cap/firstmate' " ] \
    || fail "crewmate declaration changed: $prefix"
  pass "a crewmate declaration clears every operational-home variable and names its owner"
}

test_secondmate_declaration_pins_only_its_own_home() {
  local prefix
  prefix=$( . "$ROOT/bin/fm-worker-isolation-lib.sh" \
    && fm_worker_launch_env_prefix secondmate dom-b2 /home/cap/homes/dom )
  [ "$prefix" = "FM_HOME='/home/cap/homes/dom' FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_AGENT_ROLE=secondmate FM_AGENT_TASK='dom-b2' FM_AGENT_OWNER_HOME='/home/cap/homes/dom' " ] \
    || fail "secondmate declaration changed: $prefix"
  pass "a secondmate declaration pins its own home and clears every inherited override"
}

test_declaration_refuses_rather_than_emitting_a_partial_prefix() {
  local out status
  out=$( . "$ROOT/bin/fm-worker-isolation-lib.sh" \
    && fm_worker_launch_env_prefix auditor task-a3 /home/cap/firstmate 2>&1 )
  status=$?
  expect_code 1 "$status" "an unknown role must refuse"
  assert_contains "$out" "unknown agent role" "unknown role refusal lost its reason"

  out=$( . "$ROOT/bin/fm-worker-isolation-lib.sh" \
    && fm_worker_launch_env_prefix crewmate '' /home/cap/firstmate 2>&1 )
  status=$?
  expect_code 1 "$status" "an empty task id must refuse"

  out=$( . "$ROOT/bin/fm-worker-isolation-lib.sh" \
    && fm_worker_launch_env_prefix crewmate task-a3 relative/home 2>&1 )
  status=$?
  expect_code 1 "$status" "a relative owning home must refuse"
  assert_contains "$out" "absolute owning home" "relative-home refusal lost its reason"
  pass "an unbuildable declaration refuses instead of emitting a partial prefix"
}

# --- B. every verified harness launches with the declaration ----------------

make_launch_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_pid}"*) printf '%s\n' "${FM_FAKE_PANE_PID:-}"; exit 0 ;;
esac
case "${1:-}" in
  # The stable-window-id enumeration. The duplicate-name check spawn runs first
  # asks for '#{window_name}' alone and must still answer nothing, or spawn
  # would refuse the launch as a duplicate.
  list-windows)
    case "$*" in
      *"#{window_id}"*) printf '%s %s\n' "${FM_FAKE_WINDOW_ID:-@1}" "${FM_FAKE_WINDOW_NAME:-}" ;;
    esac
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"; break; fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_launch_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_launch_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_launch_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_every_verified_harness_launches_with_its_home_declaration() {
  local harness id rec out status launch expected home_real
  for harness in claude codex opencode pi grok; do
    id="declared-$harness-b1"
    rec=$(make_launch_case "launch-$harness" "$id")
    read_launch_record "$rec"
    out=$(HOME="$HOME_DIR" GROK_HOME="$HOME_DIR/.grok" \
      FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
      FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
      PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --harness "$harness" 2>&1)
    status=$?
    expect_code 0 "$status" "$harness spawn should succeed"$'\n'"$out"
    launch=$(cat "$CASE_DIR/launch.log")
    home_real=$(cd "$HOME_DIR" && pwd -P)
    expected=$(fm_worker_env_prefix crewmate "$id" "$home_real")
    case "$launch" in
      "$expected"*) : ;;
      *) fail "$harness launch did not begin with the home declaration"$'\n'"expected prefix: $expected"$'\n'"actual: $launch" ;;
    esac
    assert_contains "$launch" "FM_HOME= " "$harness launch let the worker inherit FM_HOME"
  done
  pass "claude, codex, opencode, pi, and grok all launch with the crewmate home declaration"
}

test_secondmate_child_receives_only_its_own_home() {
  local expected
  expected=$(fm_worker_env_prefix secondmate dom-b5 /homes/dom)
  case "$expected" in
    "FM_HOME='/homes/dom' "*) : ;;
    *) fail "secondmate declaration did not pin its own home first: $expected" ;;
  esac
  assert_not_contains "$expected" "FM_ROOT_OVERRIDE='" \
    "secondmate declaration passed an inherited root override through"
  pass "a secondmate child receives its own home and no inherited override"
}

# --- C. a declared worker is inert and refused -------------------------------

make_primary_home() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/data" "$dir/config"
  fm_git_init_commit "$dir"
  printf '# agents\n' > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

test_declared_worker_is_never_a_primary_scope_match() {
  # Named primary_home, not home: the sourced libraries carry their own `home`
  # local, and reusing the name here makes shellcheck read the two as one.
  local primary_home out
  primary_home=$(make_primary_home "$TMP_ROOT/scope-home")
  out=$( . "$ROOT/bin/fm-primary-scope-lib.sh" \
    && fm_primary_scope_matches "$primary_home" "$primary_home/state" && printf 'primary' || printf 'not-primary' )
  [ "$out" = primary ] || fail "the fixture is not recognized as a genuine primary at all"
  out=$( export FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w1 FM_AGENT_OWNER_HOME="$primary_home"
    . "$ROOT/bin/fm-primary-scope-lib.sh" \
    && fm_primary_scope_matches "$primary_home" "$primary_home/state" && printf 'primary' || printf 'not-primary' )
  [ "$out" = not-primary ] \
    || fail "a declared crewmate matched primary scope inside a genuine primary checkout"
  pass "a declared crewmate is never a primary-scope match, even in a real primary checkout"
}

test_project_local_startup_adapter_stays_inert_for_a_worker() {
  local out
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ROOT" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w2 FM_AGENT_OWNER_HOME="$ROOT" \
    "$NUDGE" 2>&1)
  [ -z "$out" ] || fail "the session-start nudge fired for a declared task worker: $out"
  pass "the tracked session-start adapter stays inert for a declared task worker"
}

test_worker_cannot_take_the_session_owner_record() {
  local home before out status
  home=$(make_primary_home "$TMP_ROOT/lock-home")
  printf '424242\n' > "$home/state/.lock"
  before=$(cat "$home/state/.lock")

  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w3 FM_AGENT_OWNER_HOME="$home" \
    "$LOCK" 2>&1)
  status=$?
  expect_code 1 "$status" "a declared task worker must not acquire the session lock"
  assert_contains "$out" "task worker" "the lock refusal did not name the worker declaration"
  [ "$(cat "$home/state/.lock")" = "$before" ] \
    || fail "the session owner record was rewritten by a task worker"

  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w3 FM_AGENT_OWNER_HOME="$home" \
    "$LOCK" status 2>&1)
  status=$?
  expect_code 0 "$status" "read-only lock status must stay available to a worker"
  pass "a declared task worker is refused the session owner record and never rewrites it"
}

test_worker_cannot_spawn_or_tear_down() {
  local home out status
  home=$(make_primary_home "$TMP_ROOT/refuse-home")
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w4 FM_AGENT_OWNER_HOME="$home" \
    "$SPAWN" some-task "$home" 2>&1)
  status=$?
  expect_code 1 "$status" "a declared task worker must not spawn"
  assert_contains "$out" "spawn refused" "the spawn refusal did not name the operation"

  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w4 FM_AGENT_OWNER_HOME="$home" \
    "$TEARDOWN" some-task 2>&1)
  status=$?
  expect_code 1 "$status" "a declared task worker must not tear down"
  assert_contains "$out" "teardown refused" "the teardown refusal did not name the operation"
  pass "a declared task worker is refused both dispatch and teardown"
}

# --- D. /proc is the method of record ---------------------------------------

test_proc_cwd_is_read_from_the_live_process() {
  local dir pid cwd
  require_procfs || { pass "skip: this host has no readable procfs for cwd proof"; return 0; }
  dir="$TMP_ROOT/proc-cwd"
  mkdir -p "$dir"
  pid=$(start_declared_agent "$dir" "proc-d1-$RUN_TAG" "$TMP_ROOT/proc-home")
  cwd=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" && fm_agent_proc_cwd "$pid" )
  [ "$cwd" = "$(cd "$dir" && pwd -P)" ] \
    || fail "the process cwd was not read from /proc: $cwd"
  pass "an agent's working directory is read from the live process, not a record"
}

test_declared_agent_lookup_returns_the_root_most_process() {
  # Named root_pid, not root: the sourced library carries its own `root` local.
  local dir out root_pid child id
  require_procfs || { pass "skip: this host has no readable procfs for declaration lookup"; return 0; }
  dir="$TMP_ROOT/proc-root"
  id="proc-d2-$RUN_TAG"
  mkdir -p "$dir"
  ( cd "$dir" && FM_AGENT_ROLE=crewmate FM_AGENT_TASK="$id" \
      FM_AGENT_OWNER_HOME="$TMP_ROOT/proc-home" FM_AGENT_TEST_RUN="$RUN_TAG" \
      sh -c 'sleep 300' ) >/dev/null 2>&1 </dev/null &
  root_pid=$!
  BG_PIDS+=("$root_pid")
  sleep 0.5
  out=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" && fm_agent_pid_for_task "$id" )
  [ -n "$out" ] || fail "the declared agent process was not found at all"
  child=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" && fm_agent_pids_for_task "$id" | wc -l )
  [ "$child" -ge 2 ] || fail "the fixture did not produce a declared parent and child"
  [ "$out" = "$root_pid" ] \
    || fail "the lookup returned $out, not the root-most declared process $root_pid"
  pass "the declared-agent lookup returns the agent itself, not one of its subprocesses"
}

test_provider_process_id_matrix_is_explicit() {
  local out
  out=$( . "$ROOT/bin/fm-agent-cwd-lib.sh"
    for backend in herdr zellij cmux orca unknown; do
      if fm_agent_backend_shell_pid "$backend" "session:pane" >/dev/null 2>&1; then
        printf '%s-exposes-a-pid\n' "$backend"
      fi
    done )
  [ -z "$out" ] || fail "a provider with no verified per-pane process id claimed one: $out"
  out=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" \
    && fm_agent_cwd_verdict '' herdr 'ses:pane' )
  case "$out" in
    unknown*) : ;;
    *) fail "a provider without a process id must report unknown, not a pane value: $out" ;;
  esac
  pass "providers with no verified per-pane process id report unknown instead of a pane value"
}

make_window_id_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    case "$*" in
      *"#{window_id}"*) printf '@7 fm-live\n' ;;
    esac
    exit 0
    ;;
  display-message)
    case "$*" in
      # The one honest answer: the pane of the window actually asked for.
      *"-t @7 "*) printf '4242\n' ;;
      # What real tmux does with a target it cannot resolve - it answers for the
      # ACTIVE CLIENT's window, which is firstmate's own pane.
      *) printf '9999\n' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# agent_cwd_call <fakebin> <function> [args...]: call one bin/fm-agent-cwd-lib.sh
# function with <fakebin> ahead of PATH, in a child shell so the fake provider
# never leaks into the rest of the suite.
agent_cwd_call() {
  local fakebin=$1
  shift
  PATH="$fakebin:$PATH" bash -c '. "$1/bin/fm-agent-cwd-lib.sh" || exit 1; shift; "$@"' \
    _ "$ROOT" "$@"
}

test_tmux_pane_pid_comes_from_the_stable_window_id() {
  local fakebin out
  fakebin=$(make_window_id_fakebin "$TMP_ROOT/window-id")
  out=$(agent_cwd_call "$fakebin" fm_agent_backend_shell_pid tmux 'firstmate:fm-live')
  [ "$out" = 4242 ] \
    || fail "the pane pid was not read through the window's stable id: $out"
  pass "a tmux pane pid is read through the window's stable id, not its name"
}

test_a_lost_window_name_never_answers_with_firstmates_own_pane() {
  local fakebin out status
  fakebin=$(make_window_id_fakebin "$TMP_ROOT/window-lost")
  out=$(agent_cwd_call "$fakebin" fm_agent_backend_shell_pid tmux 'firstmate:fm-renamed-away')
  status=$?
  expect_code 1 "$status" "a window name that resolves to nothing must not yield a pid"
  [ -z "$out" ] || fail "a lost window name answered with another window's pane pid: $out"
  out=$(agent_cwd_call "$fakebin" fm_agent_cwd_verdict '' tmux 'firstmate:fm-renamed-away')
  case "$out" in
    unknown*) : ;;
    *) fail "a lost window name produced a verdict instead of unknown: $out" ;;
  esac
  pass "a lost or renamed window reports unknown instead of firstmate's own pane"
}

test_one_proc_walk_answers_every_task_in_a_sweep() {
  local dir dir_real index one two out
  require_procfs || { pass "skip: this host has no readable procfs for the process index"; return 0; }
  dir="$TMP_ROOT/proc-index"
  mkdir -p "$dir"
  dir_real=$(cd "$dir" && pwd -P)
  one="index-one-d6-$RUN_TAG"
  two="index-two-d6-$RUN_TAG"
  start_declared_agent "$dir" "$one" "$TMP_ROOT/proc-home" >/dev/null
  start_declared_agent "$dir" "$two" "$TMP_ROOT/proc-home" >/dev/null
  index=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" && fm_agent_task_pid_index )
  assert_contains "$index" "$one" "the single process walk missed a declared task"
  assert_contains "$index" "$two" "the single process walk missed a declared task"
  out=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" \
    && fm_agent_cwd_verdict "$two" '' '' "$index" )
  case "$out" in
    proc*"$dir_real") : ;;
    *) fail "a verdict taken from the shared index did not prove the process cwd: $out" ;;
  esac
  # An index with no entry for the task is a real answer, not a missing
  # argument: it must not silently fall back to a fresh walk that finds one.
  out=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" \
    && fm_agent_cwd_verdict "$two" '' '' '' )
  case "$out" in
    unknown*) : ;;
    *) fail "an empty shared index was treated as no index at all: $out" ;;
  esac
  pass "one /proc walk answers every task in a sweep, and an empty index is a real answer"
}

test_spawn_settles_on_proc_evidence_over_a_lying_pane_path() {
  local rec id out status lying pid
  require_procfs || { pass "skip: this host has no readable procfs for spawn settle proof"; return 0; }
  id="settle-proc-d4-$RUN_TAG"
  rec=$(make_launch_case settle-proc "$id")
  read_launch_record "$rec"
  lying="$CASE_DIR/other-real-checkout"
  fm_git_init_commit "$lying"
  pid=$(start_declared_agent "$WT_DIR" "$id-shell" "$HOME_DIR")

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$lying" FM_FAKE_PANE_PID="$pid" \
    FM_FAKE_WINDOW_NAME="fm-$id" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness claude 2>&1)
  status=$?
  expect_code 0 "$status" "spawn should settle on the process evidence"$'\n'"$out"
  assert_grep "worktree=$(cd "$WT_DIR" && pwd -P)" "$HOME_DIR/state/$id.meta" \
    "spawn did not record the worktree proved by the agent process"
  assert_no_grep "worktree=$lying" "$HOME_DIR/state/$id.meta" \
    "spawn recorded the lying pane path as the worktree"
  pass "spawn settles on the process's own working directory, not a pane field that names another process"
}

# --- E. pooled-slot ownership -----------------------------------------------

make_slot_world() {
  local name=$1 world proj wt other
  world="$TMP_ROOT/$name"
  proj="$world/project"
  wt="$world/wt"
  other="$world/wt-other"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config"
  fm_git_worktree "$proj" "$wt" "slot-$name"
  git -C "$proj" worktree add --quiet -b "slot-$name-other" "$other"
  printf '%s\n' "$world|$proj|$wt|$other"
}

read_slot_world() {
  IFS='|' read -r WORLD PROJ_DIR WT_DIR OTHER_WT <<EOF
$1
EOF
}

slot_verdict() {  # <state> <id> <wt> <home>
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_disposal_verdict "$@" )
}

test_slot_stamp_records_ownership_and_never_stamps_a_plain_checkout() {
  local rec task
  rec=$(make_slot_world slot-stamp)
  read_slot_world "$rec"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-e1 "$WORLD/home" ) \
    || fail "a linked worktree could not be stamped"
  task=$( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_stamp_field "$WT_DIR" task )
  [ "$task" = task-e1 ] || fail "the slot stamp did not record its task: $task"
  [ -z "$(git -C "$WT_DIR" status --porcelain)" ] \
    || fail "the slot stamp dirtied the working tree"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$PROJ_DIR" task-e1 "$WORLD/home" ) 2>/dev/null \
    && fail "a plain checkout was stamped as a disposable slot"
  pass "slot ownership is stamped invisibly in a linked worktree and refused for a plain checkout"
}

test_clean_ownership_disposes() {
  local rec verdict
  rec=$(make_slot_world slot-clean)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/task-e2.meta" \
    "window=firstmate:fm-task-e2" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  # A busy home is the normal case: another task holding a DIFFERENT slot must
  # not retain this one, or the gate would leak every lease it ever inspects.
  fm_write_meta "$WORLD/home/state/neighbour-e2.meta" \
    "window=firstmate:fm-neighbour-e2" "worktree=$OTHER_WT" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-e2 "$WORLD/home" )
  verdict=$(slot_verdict "$WORLD/home/state" task-e2 "$WT_DIR" "$WORLD/home")
  [ "$verdict" = dispose ] || fail "clean ownership did not dispose: $verdict"
  pass "a slot this task alone records and stamps disposes normally"
}

test_a_second_recorded_task_retains_the_slot() {
  local rec verdict
  rec=$(make_slot_world slot-shared)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/task-e3.meta" \
    "window=firstmate:fm-task-e3" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  fm_write_meta "$WORLD/home/state/paused-e3.meta" \
    "window=firstmate:fm-paused-e3" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  verdict=$(slot_verdict "$WORLD/home/state" task-e3 "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot is also recorded by task(s) paused-e3"*) : ;;
    *) fail "a slot recorded by a second task did not retain: $verdict" ;;
  esac
  pass "a slot still recorded by another task - live, paused, or quarantined - retains its lease"
}

test_a_stamp_naming_another_task_retains_the_slot() {
  local rec verdict
  rec=$(make_slot_world slot-stale)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/task-e4.meta" \
    "window=firstmate:fm-task-e4" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" reissued-e4 "$WORLD/home" )
  verdict=$(slot_verdict "$WORLD/home/state" task-e4 "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot ownership stamp names task reissued-e4"*) : ;;
    *) fail "stale metadata pointing at a reissued slot did not retain: $verdict" ;;
  esac
  pass "metadata pointing at a slot that was reissued is recognized as stale and retains the lease"
}

test_a_live_agent_of_another_task_retains_the_slot() {
  local rec verdict occupant
  require_procfs || { pass "skip: this host has no readable procfs for occupancy proof"; return 0; }
  rec=$(make_slot_world slot-occupied)
  read_slot_world "$rec"
  occupant="occupant-e5-$RUN_TAG"
  fm_write_meta "$WORLD/home/state/task-e5.meta" \
    "window=firstmate:fm-task-e5" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  start_declared_agent "$WT_DIR" "$occupant" "$WORLD/home" >/dev/null
  verdict=$(slot_verdict "$WORLD/home/state" task-e5 "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: a live agent for task(s) $occupant"*) : ;;
    *) fail "a slot occupied by another task's live agent did not retain: $verdict" ;;
  esac
  pass "a slot occupied by another task's live agent retains its lease"
}

test_a_relinquished_slot_is_releasable_by_its_remaining_holder() {
  # The exact reported leak sequence. B is the stamped true owner and paused A's
  # stale metadata also names the slot, so B retains and its own metadata goes.
  # If B's stamp outlived it, A's later teardown would retain on the stamp with
  # nothing left referencing the slot, and the pool would lose it forever.
  local rec verdict stamp
  rec=$(make_slot_world slot-relinquish)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/owner-e7.meta" \
    "window=firstmate:fm-owner-e7" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  fm_write_meta "$WORLD/home/state/paused-e7.meta" \
    "window=firstmate:fm-paused-e7" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" owner-e7 "$WORLD/home" )

  verdict=$(slot_verdict "$WORLD/home/state" owner-e7 "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot is also recorded by task(s) paused-e7"*) : ;;
    *) fail "the stamped owner did not retain against the paused task's record: $verdict" ;;
  esac
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_relinquish "$WT_DIR" owner-e7 "$verdict" )
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf 'none' )
  [ "$stamp" = none ] \
    || fail "the retiring owner's own stamp outlived it and still names $stamp"
  rm -f "$WORLD/home/state/owner-e7.meta"

  verdict=$(slot_verdict "$WORLD/home/state" paused-e7 "$WT_DIR" "$WORLD/home")
  [ "$verdict" = dispose ] \
    || fail "the last holder could not release a slot nothing else references: $verdict"
  pass "a retiring owner gives up its own stamp so the remaining holder can still release the slot"
}

test_a_stamp_naming_another_task_survives_a_retain_and_still_blocks() {
  # The complementary case, and the reason the clear above is narrow. Here the
  # stamp names a THIRD task, so it is positive evidence the slot was reissued.
  # Clearing it would let the stale task dispose of a slot whose real occupant
  # merely has no live process right now - destroying preserved work.
  local rec verdict stamp
  rec=$(make_slot_world slot-preserve)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/stale-e8.meta" \
    "window=firstmate:fm-stale-e8" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  fm_write_meta "$WORLD/home/state/other-e8.meta" \
    "window=firstmate:fm-other-e8" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" reissued-e8 "$WORLD/home" )

  verdict=$(slot_verdict "$WORLD/home/state" stale-e8 "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot is also recorded by task(s) other-e8"*) : ;;
    *) fail "the metadata conflict was not the retain reason under test: $verdict" ;;
  esac
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_relinquish "$WT_DIR" stale-e8 "$verdict" )
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf 'none' )
  [ "$stamp" = reissued-e8 ] \
    || fail "a stamp naming another task was cleared on retain: $stamp"
  rm -f "$WORLD/home/state/stale-e8.meta" "$WORLD/home/state/other-e8.meta"

  verdict=$(slot_verdict "$WORLD/home/state" stale-e8 "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot ownership stamp names task reissued-e8"*) : ;;
    *) fail "a preserved stamp stopped blocking disposal for a stale task: $verdict" ;;
  esac
  pass "a stamp naming another task survives a retain and still blocks that slot's disposal"
}

test_teardown_retires_a_contested_lease_even_with_force() {
  local rec fakebin out status stamp
  rec=$(make_slot_world slot-teardown)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" tmux gh-axi gh
  : > "$WORLD/treehouse.log"
  fm_write_meta "$WORLD/home/state/task-e6.meta" \
    "window=firstmate:fm-task-e6" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off"
  fm_write_meta "$WORLD/home/state/quarantined-e6.meta" \
    "window=firstmate:fm-quarantined-e6" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-e6 "$WORLD/home" ) \
    || fail "the contested-slot fixture could not be stamped"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
    FM_STATE_OVERRIDE="$WORLD/home/state" FM_DATA_OVERRIDE="$WORLD/home/data" \
    FM_CONFIG_OVERRIDE="$WORLD/home/config" \
    FM_FAKE_TREEHOUSE_LOG="$WORLD/treehouse.log" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" task-e6 --force 2>&1)
  status=$?
  expect_code 0 "$status" "teardown should complete while retiring the contested lease"$'\n'"$out"
  assert_contains "$out" "lease RETAINED" "teardown did not report the retained lease"
  assert_contains "$out" "quarantined-e6" "teardown did not name the other holder"
  assert_contains "$out" "retained on disk" "the completion line did not report the retained slot"
  [ ! -s "$WORLD/treehouse.log" ] \
    || fail "teardown returned a contested slot to the pool: $(cat "$WORLD/treehouse.log")"
  assert_present "$WT_DIR" "teardown removed a contested worktree"
  [ "$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)" = "slot-slot-teardown" ] \
    || fail "teardown moved a contested worktree off its branch"
  assert_absent "$WORLD/home/state/task-e6.meta" "teardown did not clear its own records"
  assert_present "$WORLD/home/state/quarantined-e6.meta" "teardown cleared the other holder's record"
  # This path DID complete and delete its own records, so its stamp must not
  # outlive it, or the slot could never be released again.
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf 'none' )
  [ "$stamp" = none ] \
    || fail "a completed teardown left its own ownership stamp behind: $stamp"
  pass "teardown retires a contested lease, leaves the slot untouched, and --force does not waive it"
}

# --- F. restore-time re-assertion -------------------------------------------

make_sweep_home() {
  local name=$1 world
  world="$TMP_ROOT/$name"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config"
  fm_git_worktree "$world/project" "$world/wt" "sweep-$name"
  printf '%s\n' "$world"
}

run_sweep() {  # <world>
  FM_ROOT_OVERRIDE="$1/project" FM_HOME="$1/home" \
    FM_STATE_OVERRIDE="$1/home/state" "$SWEEP" 2>&1
}

test_sweep_reports_a_worktree_that_collapsed_onto_the_primary_checkout() {
  local world out id
  require_procfs || { pass "skip: this host has no readable procfs for the resume sweep"; return 0; }
  world=$(make_sweep_home sweep-collapsed)
  id="task-f1-$RUN_TAG"
  fm_write_meta "$world/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  start_declared_agent "$world/project" "$id" "$world/home" >/dev/null
  out=$(run_sweep "$world")
  assert_contains "$out" "ISOLATION: task $id collapsed onto the primary checkout" \
    "the resume sweep did not report a collapsed worktree"
  pass "the resume sweep re-asserts isolation and reports a worktree that collapsed onto the primary checkout"
}

test_sweep_is_silent_for_a_correctly_isolated_worker() {
  local world out id
  require_procfs || { pass "skip: this host has no readable procfs for the resume sweep"; return 0; }
  world=$(make_sweep_home sweep-isolated)
  id="task-f2-$RUN_TAG"
  fm_write_meta "$world/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  start_declared_agent "$world/wt" "$id" "$world/home" >/dev/null
  # Captured with stderr folded in: the sweep scans every process on the host,
  # and a /proc entry it may not read must stay silent rather than surfacing a
  # permission error as if it were a finding.
  out=$(run_sweep "$world")
  [ -z "$out" ] || fail "the resume sweep reported a correctly isolated worker: $out"
  pass "the resume sweep stays silent for a worker that is genuinely in its worktree"
}

test_sweep_never_promotes_a_pane_path_to_evidence() {
  local world out
  world=$(make_sweep_home sweep-hint)
  fm_write_meta "$world/home/state/task-f3.meta" \
    "window=firstmate:fm-task-f3" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  out=$(run_sweep "$world")
  [ -z "$out" ] || fail "the resume sweep reported a violation with no live process to prove it: $out"
  out=$(FM_ISOLATION_VERBOSE=1 run_sweep "$world")
  assert_contains "$out" "BOOTSTRAP_INFO: isolation for task-f3 is unproven" \
    "an unprovable task was not reported as unproven under verbose facts"
  pass "an unprovable task is never reported as a violation from a pane path alone"
}

test_sweep_reports_an_agent_declared_for_another_home() {
  local world out id
  require_procfs || { pass "skip: this host has no readable procfs for the resume sweep"; return 0; }
  world=$(make_sweep_home sweep-foreign)
  id="task-f4-$RUN_TAG"
  fm_write_meta "$world/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  mkdir -p "$world/other-home"
  start_declared_agent "$world/wt" "$id" "$world/other-home" >/dev/null
  out=$(run_sweep "$world")
  assert_contains "$out" "ISOLATION: task $id is running as a worker of home" \
    "the resume sweep did not report an agent declared for another home"
  pass "the resume sweep reports an agent that declares another home as its owner"
}

test_sweep_is_silent_for_a_healthy_secondmate() {
  # A secondmate is deliberately launched declaring its OWN home while its
  # record lives in the launching primary's state directory. Judging that
  # declaration against the sweeping home would print an actionable, wrong
  # "stop this worker" line on every session start in any fleet that has one.
  local world out id sub_home
  require_procfs || { pass "skip: this host has no readable procfs for the resume sweep"; return 0; }
  world=$(make_sweep_home sweep-secondmate)
  id="dom-f5-$RUN_TAG"
  sub_home="$world/secondmate-home"
  mkdir -p "$sub_home/state"
  fm_write_secondmate_meta "$world/home/state/$id.meta" "$sub_home" "firstmate:fm-$id"
  start_declared_agent "$sub_home" "$id" "$sub_home" secondmate >/dev/null
  out=$(run_sweep "$world")
  [ -z "$out" ] || fail "the resume sweep reported a healthy live secondmate: $out"
  pass "the resume sweep stays silent for a secondmate that declares its own home"
}

test_sweep_still_reports_a_secondmate_running_for_a_foreign_home() {
  local world out id sub_home
  require_procfs || { pass "skip: this host has no readable procfs for the resume sweep"; return 0; }
  world=$(make_sweep_home sweep-secondmate-foreign)
  id="dom-f6-$RUN_TAG"
  sub_home="$world/secondmate-home"
  mkdir -p "$sub_home/state" "$world/other-home"
  fm_write_secondmate_meta "$world/home/state/$id.meta" "$sub_home" "firstmate:fm-$id"
  start_declared_agent "$sub_home" "$id" "$world/other-home" secondmate >/dev/null
  out=$(run_sweep "$world")
  assert_contains "$out" "ISOLATION: task $id is running as a worker of home" \
    "the resume sweep excused a secondmate declaring a home its record does not name"
  pass "the resume sweep still reports a secondmate whose declared home is not the one it owns"
}

test_crewmate_declaration_clears_every_inherited_home
test_secondmate_declaration_pins_only_its_own_home
test_declaration_refuses_rather_than_emitting_a_partial_prefix
test_every_verified_harness_launches_with_its_home_declaration
test_secondmate_child_receives_only_its_own_home
test_declared_worker_is_never_a_primary_scope_match
test_project_local_startup_adapter_stays_inert_for_a_worker
test_worker_cannot_take_the_session_owner_record
test_worker_cannot_spawn_or_tear_down
test_proc_cwd_is_read_from_the_live_process
test_declared_agent_lookup_returns_the_root_most_process
test_provider_process_id_matrix_is_explicit
test_tmux_pane_pid_comes_from_the_stable_window_id
test_a_lost_window_name_never_answers_with_firstmates_own_pane
test_one_proc_walk_answers_every_task_in_a_sweep
test_spawn_settles_on_proc_evidence_over_a_lying_pane_path
test_slot_stamp_records_ownership_and_never_stamps_a_plain_checkout
test_clean_ownership_disposes
test_a_second_recorded_task_retains_the_slot
test_a_stamp_naming_another_task_retains_the_slot
test_a_live_agent_of_another_task_retains_the_slot
test_a_relinquished_slot_is_releasable_by_its_remaining_holder
test_a_stamp_naming_another_task_survives_a_retain_and_still_blocks
test_teardown_retires_a_contested_lease_even_with_force
test_sweep_reports_a_worktree_that_collapsed_onto_the_primary_checkout
test_sweep_is_silent_for_a_correctly_isolated_worker
test_sweep_never_promotes_a_pane_path_to_evidence
test_sweep_reports_an_agent_declared_for_another_home
test_sweep_is_silent_for_a_healthy_secondmate
test_sweep_still_reports_a_secondmate_running_for_a_foreign_home

echo "# all fm-worker-isolation tests passed"
