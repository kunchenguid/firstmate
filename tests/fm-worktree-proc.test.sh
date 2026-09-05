#!/usr/bin/env bash
# Processes left running in a task's local copy: attribution, the guards that
# keep every other process on the machine out of reach, and the paths that stop
# them.
#
# The whole mechanism rests on one claim - "this process's real working
# directory is inside that exact disposable copy" - so these tests use real
# processes and real git worktrees rather than a stubbed resolver. What they
# pin:
#   1. Only a linked git worktree that is not a primary checkout, and not a
#      clone under the home's projects/, can ever be a target root.
#   2. A process in such a copy is found by working directory and stopped.
#   3. A process in a primary checkout is never a target, even when a durable
#      record names that checkout as the task's copy - the negative case that
#      matters most, because the operator's own stack lives in checkouts.
#   4. A task whose agent is alive is never touched, and neither is one whose
#      endpoint classifier says dead while its current state says otherwise.
#   5. A working directory that cannot be read leaves its process alone; an
#      unreadable state is never a default kill.
#   6. The shell the task's OWN record names as its endpoint survives a cleanup
#      that means to keep that endpoint - and a session-leader daemon that is
#      NOT that shell does not, because the process that saturated the host on
#      2026-08-27 was exactly that shape.
#   7. When the record cannot name that shell nothing is guessed: every session
#      leader is left alone AND the report says how many, so a copy that was
#      never classified is never mistaken for a clean one.
#   8. A per-task temp root gets the same home and projects/ refusals the
#      worktree root gets, so a record naming the operator's own tree as a
#      second reap root reaches nothing - and it has to BE the one path
#      fm-spawn creates for that task, so a correctly named directory anywhere
#      else on the machine is refused rather than reaped.
#   9. The reap tells the truth about its own outcome: a scan that broke BEFORE
#      anything was signalled, a scan that broke AFTER, and a process that
#      outlived the force-stop are three different answers, never one "done".
#  10. A copy whose owner could not be established keeps that label and keeps
#      refusing a cleanup even when every process in it was held back.
#  11. A recorded root the validation refuses is reported as unexamined rather
#      than quietly dropped from the scan.
#  12. A cleanup started from a shell inside the copy stops the leftovers and
#      never that shell.
#
# Every negative case is asserted beside a positive one in the same fixture, so
# a guard that started refusing everything would fail this suite rather than
# pass it quietly. Witnesses are `sleep` processes: the incident this guards
# came out of a saturated host, and nothing here needs a server to prove
# attribution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ORPHAN="$ROOT/bin/fm-orphan-reap.sh"

TMP_ROOT=$(fm_test_tmproot fm-worktree-proc)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

PRIMARY="$TMP_ROOT/primary"
COPY="$TMP_ROOT/copy"
HOME_DIR="$TMP_ROOT/home"
IN_PROJECTS="$HOME_DIR/projects/clone"
PLAIN="$TMP_ROOT/plain"

# bin/fm-spawn.sh builds each task's temp root as $FM_TASK_TMP_ROOT/fm-<id> and
# fm_wtproc_task_tmp rebuilds the same path to check a record against it. Point
# both at this suite's own tree so the binding is exercised for real instead of
# writing into the host's /tmp.
FM_TASK_TMP_ROOT="$TMP_ROOT"
export FM_TASK_TMP_ROOT

mkdir -p "$HOME_DIR/state" "$HOME_DIR/projects" "$PLAIN"
fm_git_worktree "$PRIMARY" "$COPY" task-branch
# A linked worktree that nonetheless sits under the home's projects/ tree, so
# the projects guard is proven to stand on its own rather than riding on the
# linked-worktree test.
git -C "$PRIMARY" worktree add --quiet -b in-projects "$IN_PROJECTS"

FM_HOME="$HOME_DIR"
FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_HOME FM_STATE_OVERRIDE
FM_WTPROC_GRACE=1
export FM_WTPROC_GRACE

# shellcheck source=bin/fm-worktree-proc-lib.sh
. "$ROOT/bin/fm-worktree-proc-lib.sh"

# Witnesses are started inside command substitutions, so the parent shell never
# sees an array append; the registry is a file for the same reason
# tests/lib.sh keeps its temp roots in one.
WITNESS_REGISTRY="$TMP_ROOT/.witnesses"
: > "$WITNESS_REGISTRY"
witness_cleanup() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && kill -KILL "$p" 2>/dev/null
  done < "$WITNESS_REGISTRY"
  fm_test_cleanup
}
trap witness_cleanup EXIT
trap 'witness_cleanup; exit 130' INT
trap 'witness_cleanup; exit 143' TERM

witness() {  # <cwd> -> pid
  local dir=$1 pid
  ( cd "$dir" && exec /bin/sleep 600 ) </dev/null >/dev/null 2>&1 &
  pid=$!
  disown
  printf '%s\n' "$pid" >> "$WITNESS_REGISTRY"
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || fail "witness in $dir did not start"
  printf '%s' "$pid"
}

# The shape a terminal endpoint's shell takes: its own session leader.
session_leader_witness() {  # <cwd> -> pid
  local dir=$1 pid pidfile
  pidfile="$TMP_ROOT/leader.$RANDOM.pid"
  # setsid forks, so the leader is not the pid this shell would see; the child
  # reports its own.
  # shellcheck disable=SC2016  # $$ must expand in the child, not here
  ( cd "$dir" && exec setsid /bin/sh -c 'echo $$ > "$1"; exec /bin/sleep 600' _ "$pidfile" ) \
    </dev/null >/dev/null 2>&1 &
  disown
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$pidfile" ] && break
    sleep 0.1
  done
  pid=$(cat "$pidfile" 2>/dev/null || true)
  [ -n "$pid" ] || fail "session-leader witness did not start"
  printf '%s\n' "$pid" >> "$WITNESS_REGISTRY"
  sleep 0.2
  printf '%s' "$pid"
}

alive() { kill -0 "$1" 2>/dev/null; }

contains_pid() {  # <list> <pid>
  printf '%s\n' "$1" | grep -Fxq "$2"
}

write_task_meta() {  # <id> <worktree> <window> [tasktmp]
  {
    echo "window=${3}"
    echo "endpoint_task_id=$1"
    echo "worktree=$2"
    echo "backend=tmux"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    [ -n "${4:-}" ] && echo "tasktmp=$4"
  } > "$HOME_DIR/state/$1.meta"
}

# tmux/ps stubs modelling one endpoint whose agent state is whatever
# $FAKE_AGENT_STATE says. `missing` is a session tmux cannot find; `dead` is a
# listed window whose foreground group is nothing but a shell; `alive` is the
# same window running the harness; `unreadable` is an inventory read that fails
# for some other reason, which the classifier can neither call gone nor call
# live.
make_backend_stub() {  # <dir> <window-name>
  local fb="$1/fakebin" win=$2
  mkdir -p "$fb"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
state=\$(cat "\$FAKE_AGENT_FILE" 2>/dev/null || echo missing)
case "\${1:-}" in
  list-windows)
    if [ "\$state" = missing ]; then
      echo "can't find session: fmses" >&2
      exit 1
    fi
    if [ "\$state" = unreadable ]; then
      # An inventory failure that is NOT one of the definitive missing-session
      # signals, which is what fm_backend_tmux_agent_state reads as unreadable.
      echo "tmux: synthetic inventory failure" >&2
      exit 1
    fi
    printf '%s\n' '$win'
    exit 0
    ;;
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *pane_tty*) printf '/dev/pts/424242\n'; exit 0 ;;
        *pane_pid*)
          # The endpoint's shell as the RECORD would name it: whatever the
          # fixture put in this file, or nothing when the backend cannot say.
          cat "\$FAKE_PANE_PID_FILE" 2>/dev/null || printf 'fakepane'
          printf '\n'
          exit 0 ;;
        *pane_current_command*)
          if [ "\$state" = alive ]; then printf 'claude\n'; else printf 'bash\n'; fi
          exit 0 ;;
      esac
    done
    printf 'fakepane\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
state=$(cat "$FAKE_AGENT_FILE" 2>/dev/null || echo missing)
if [ "${1:-}" = -t ] && [ "${2:-}" = pts/424242 ]; then
  if [ "$state" = alive ]; then printf '424242 424242 424242 claude\n'
  else printf '424242 424242 424242 bash\n'; fi
  exit 0
fi
exec "$FAKE_REAL_PS" "$@"
SH
  chmod +x "$fb/ps"
}

# A current-state reader whose verdict comes from a file, standing in for
# bin/fm-crew-state.sh so the disagreement case can be reproduced deterministically.
make_crew_state_stub() {  # <dir>
  cat > "$1/crew-state" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: pane · stub
' "$(cat "$FAKE_CREW_STATE_FILE" 2>/dev/null || echo unknown)"
SH
  chmod +x "$1/crew-state"
  printf 'done' > "$1/crew"
}

run_orphan() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_WTPROC_GRACE=1 \
      FM_TASK_TMP_ROOT="$FM_TASK_TMP_ROOT" \
      FAKE_AGENT_FILE="$dir/agent" FAKE_REAL_PS="$(command -v ps)" \
      FAKE_CREW_STATE_FILE="$dir/crew" FAKE_PANE_PID_FILE="$dir/panepid" \
      FM_WTPROC_CREW_STATE_BIN="$dir/crew-state" \
      "$ORPHAN" "$@" 2>&1
}

# --- 1. what may ever be a target root --------------------------------------

test_only_a_linked_worktree_is_a_disposable_copy() {
  local out rc

  out=$(fm_wtproc_disposable_worktree "$COPY" "$HOME_DIR" 2>&1) \
    || fail "disposable-copy: the task's linked worktree was refused: $out"
  [ "$out" = "$COPY" ] || fail "disposable-copy: expected $COPY, got $out"

  rc=0
  out=$(fm_wtproc_disposable_worktree "$PRIMARY" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "disposable-copy: a primary checkout was accepted as a disposable copy"
  case "$out" in
    *"is a primary checkout"*) ;;
    *) fail "disposable-copy: the primary checkout refusal did not name its cause: $out" ;;
  esac

  rc=0
  out=$(fm_wtproc_disposable_worktree "$IN_PROJECTS" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "disposable-copy: a clone under the home's projects/ was accepted"
  case "$out" in
    *"is a primary clone"*) ;;
    *) fail "disposable-copy: the projects/ refusal did not name its cause: $out" ;;
  esac

  rc=0
  out=$(fm_wtproc_disposable_worktree "$PLAIN" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "disposable-copy: a directory that is not a git worktree was accepted"

  rc=0
  out=$(fm_wtproc_disposable_worktree "$HOME" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "disposable-copy: the home directory itself was accepted"

  pass "only a linked worktree outside the home's own clones is accepted as a disposable copy"
}

# THE WALL FOLLOWS THE TREE WHEN THE TREE MOVES. FM_PROJECTS_OVERRIDE is how a
# home puts its primary clones somewhere other than $FM_HOME/projects, and every
# other script in the repo resolves them through it. A wall hardcoded to
# $FM_HOME/projects therefore missed exactly the homes that use it: a recorded
# root naming a clone under the override cleared every refusal and became a
# legal kill root. bin/fm-teardown.sh has only these shape refusals by design -
# no linked-worktree proof - so for teardown this wall is the whole protection.
test_the_projects_wall_follows_fm_projects_override() {
  local moved out rc
  moved="$TMP_ROOT/srv-code"
  mkdir -p "$moved/api-stack"

  rc=0
  out=$(FM_PROJECTS_OVERRIDE="$moved" \
    fm_wtproc_signalling_root "$moved/api-stack" "a recorded root" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] \
    || fail "projects-override: a primary clone under FM_PROJECTS_OVERRIDE was accepted as a signalling root: $out"
  case "$out" in
    *"is a primary clone"*) ;;
    *) fail "projects-override: the refusal did not name its cause: $out" ;;
  esac

  # The default location stays walled when no override is set ...
  rc=0
  out=$(fm_wtproc_signalling_root "$IN_PROJECTS" "a recorded root" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] \
    || fail "projects-override: the default projects/ tree stopped being walled: $out"

  # ... AND while one IS set. A home that adopted an override after its clones
  # were already at $FM_HOME/projects still has records naming the default tree,
  # and that tree is still on disk; the override adds a place primary clones can
  # be, it does not move the old one out of harm's way.
  rc=0
  out=$(FM_PROJECTS_OVERRIDE="$moved" \
    fm_wtproc_signalling_root "$IN_PROJECTS" "a recorded root" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] \
    || fail "projects-override: setting an override unwalled the default projects/ tree: $out"
  case "$out" in
    *"is a primary clone"*) ;;
    *) fail "projects-override: the default-tree refusal under an override did not name its cause: $out" ;;
  esac

  # And a real disposable copy is still accepted, so the wall did not simply
  # start refusing everything.
  out=$(FM_PROJECTS_OVERRIDE="$moved" \
    fm_wtproc_signalling_root "$COPY" "a recorded root" "$HOME_DIR" 2>&1) \
    || fail "projects-override: a genuine task copy was refused: $out"
  [ "$out" = "$COPY" ] || fail "projects-override: expected $COPY, got $out"

  rm -rf "$moved"
  pass "the primary-clone wall follows FM_PROJECTS_OVERRIDE instead of assuming \$FM_HOME/projects"
}

# --- 2. attribution and the reap -------------------------------------------

test_a_process_in_a_disposable_copy_is_found_and_stopped() {
  local inside outside pids
  inside=$(witness "$COPY")
  outside=$(witness "$PRIMARY")

  pids=$(fm_wtproc_pids_under "$COPY") || fail "reap: the copy could not be scanned"
  contains_pid "$pids" "$inside" \
    || fail "reap: the process in the copy was not attributed to it"
  contains_pid "$pids" "$outside" \
    && fail "reap: a process outside the copy was attributed to it"

  fm_wtproc_reap "test" none "$COPY" >/dev/null 2>&1 \
    || fail "reap: the cleanup could not be completed"
  sleep 0.3
  alive "$inside" && fail "reap: the process in the copy survived"
  alive "$outside" || fail "reap: a process outside the copy was stopped"
  kill -KILL "$outside" 2>/dev/null || true
  pass "a process is attributed to a copy by working directory and stopped there, and only there"
}

# --- 3. a primary checkout is never reachable, even when a record names it ---

test_a_primary_checkout_is_never_a_target() {
  local dir stack_pid copy_pid out rc
  dir="$TMP_ROOT/case-primary"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-stack
  make_crew_state_stub "$dir"
  printf 'missing' > "$dir/agent"

  # The operator's own stack: a live process in a checkout they work in
  # directly, recorded - wrongly - as a task's local copy, with that task's
  # agent gone. Nothing about this may reach the process.
  stack_pid=$(witness "$PRIMARY")
  write_task_meta stack "$PRIMARY" "fmses:fm-stack"
  # A real disposable copy in the same home and the same state, so the scan is
  # proven to be working rather than silently finding nothing at all.
  copy_pid=$(witness "$COPY")
  write_task_meta copyt "$COPY" "fmses:fm-stack"

  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: copyt"*) ;;
    *) fail "primary-checkout: the disposable copy was not reported, so this case proves nothing: $out" ;;
  esac
  case "$out" in
    *"LEFTOVER: stack"*) fail "primary-checkout: a checkout was reported as a task copy: $out" ;;
  esac

  rc=0
  out=$(run_orphan "$dir" reap stack) || rc=$?
  [ "$rc" != 0 ] \
    || fail "primary-checkout: an explicit cleanup of a checkout reported success: $out"
  case "$out" in
    *"was refused"*) ;;
    *) fail "primary-checkout: an explicit cleanup did not refuse the checkout: $out" ;;
  esac
  # The checkout was never examined, so the cleanup may not say anything about
  # what is or is not running in it.
  case "$out" in
    *"nothing to stop"*) fail "primary-checkout: a copy that was never read was called empty: $out" ;;
  esac
  sleep 0.3
  alive "$stack_pid" || fail "primary-checkout: a process in a checkout was stopped"

  run_orphan "$dir" reap copyt >/dev/null
  sleep 0.3
  alive "$copy_pid" && fail "primary-checkout: the disposable copy's process was not stopped"
  alive "$stack_pid" || fail "primary-checkout: the checkout's process was stopped by the copy's cleanup"

  kill -KILL "$stack_pid" 2>/dev/null || true
  rm -f "$HOME_DIR/state/stack.meta" "$HOME_DIR/state/copyt.meta"
  pass "a primary checkout is never a target, even when a durable record names it as the task's copy"
}

# --- 4. a live worker is never touched --------------------------------------

test_a_live_workers_processes_are_never_stopped() {
  local dir pid out
  dir="$TMP_ROOT/case-live"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-live
  make_crew_state_stub "$dir"
  printf 'alive' > "$dir/agent"

  pid=$(witness "$COPY")
  write_task_meta live "$COPY" "fmses:fm-live"

  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: live"*) fail "live-worker: a live worker's copy was reported as leftover: $out" ;;
  esac
  out=$(run_orphan "$dir" reap live)
  case "$out" in
    *"nothing to stop"*) ;;
    *) fail "live-worker: an explicit cleanup did not refuse a live worker: $out" ;;
  esac
  sleep 0.3
  alive "$pid" || fail "live-worker: a live worker's process was stopped"

  # Same fixture, same process, only the agent's verdict changes: the case is
  # proven to hinge on liveness and nothing else.
  printf 'dead' > "$dir/agent"
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: live"*) ;;
    *) fail "live-worker: the same copy was not reported once its agent read dead: $out" ;;
  esac
  run_orphan "$dir" reap live >/dev/null
  sleep 0.3
  alive "$pid" && fail "live-worker: the copy's process survived once its agent was gone"

  rm -f "$HOME_DIR/state/live.meta"
  pass "a task whose agent is alive is never touched, and the same copy is cleaned once that agent is gone"
}

# --- 4b. two sources have to agree ------------------------------------------
#
# Observed 2026-08-27 on the captain's host: the Herdr endpoint classifier
# reported `dead` for a worker that was running, while the current-state reader
# correctly reported it working. Acting on the first source alone would have
# stopped a live worker's processes.

test_a_disagreeing_current_state_vetoes_the_verdict() {
  local dir pid out
  dir="$TMP_ROOT/case-disagree"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-dis
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  printf 'working' > "$dir/crew"

  pid=$(witness "$COPY")
  write_task_meta dis "$COPY" "fmses:fm-dis"

  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: dis"*) fail "two-sources: a copy was called ownerless while its current state read working: $out" ;;
  esac
  out=$(run_orphan "$dir" scan --task dis)
  case "$out" in
    *"the two disagree"*) ;;
    *) fail "two-sources: the refusal did not name the disagreement: $out" ;;
  esac
  out=$(run_orphan "$dir" reap dis)
  case "$out" in
    *"nothing to stop"*) ;;
    *) fail "two-sources: an explicit cleanup did not refuse the disagreement: $out" ;;
  esac
  sleep 0.3
  alive "$pid" || fail "two-sources: a running worker's process was stopped on one source alone"

  # Only the second source changes: the case is proven to hinge on the
  # agreement and not on anything else in the fixture.
  printf 'done' > "$dir/crew"
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: dis"*) ;;
    *) fail "two-sources: the same copy was not reported once both sources agreed: $out" ;;
  esac
  run_orphan "$dir" reap dis >/dev/null
  sleep 0.3
  alive "$pid" && fail "two-sources: the copy's process survived once both sources agreed"

  rm -f "$HOME_DIR/state/dis.meta"
  pass "a current state that disagrees with the endpoint classifier vetoes the ownerless verdict"
}

# --- 5. an unreadable working directory is left alone -----------------------

test_an_unreadable_working_directory_leaves_the_process_alone() {
  local fake readable unreadable absent pids
  fake="$TMP_ROOT/fake-proc"
  rm -rf "$fake"
  readable=$(witness "$COPY")
  unreadable=$(witness "$COPY")
  absent=$(witness "$COPY")
  mkdir -p "$fake/$readable" "$fake/$unreadable" "$fake/$absent" "$fake/self"
  # The resolver only trusts a proc root that answers the cwd question about the
  # caller itself, so this synthetic root has to answer it too - otherwise the
  # case would prove the self-test rather than the parser.
  ln -s "$(pwd -P)" "$fake/self/cwd"
  ln -s "$COPY" "$fake/$readable/cwd"
  # `ls -l` renders a link whose target the caller may not read as an entry with
  # no target at all, and a process that vanished mid-scan as no entry at all.
  # Both must read as "no evidence", never as "reap it".
  printf '%s\n' "$COPY" > "$fake/$unreadable/cwd"

  FM_PROC_ROOT_OVERRIDE="$fake"
  pids=$(fm_wtproc_pids_under "$COPY") \
    || fail "unreadable-cwd: the scan failed instead of skipping what it could not read"
  contains_pid "$pids" "$readable" \
    || fail "unreadable-cwd: the readable working directory was not attributed, so this case proves nothing"
  contains_pid "$pids" "$unreadable" \
    && fail "unreadable-cwd: a process whose working directory could not be read was attributed"
  contains_pid "$pids" "$absent" \
    && fail "unreadable-cwd: a process with no working-directory entry was attributed"

  fm_wtproc_reap "test" none "$COPY" >/dev/null 2>&1 \
    || fail "unreadable-cwd: the cleanup could not be completed"
  unset FM_PROC_ROOT_OVERRIDE
  sleep 0.3
  alive "$readable" && fail "unreadable-cwd: the attributed process was not stopped"
  alive "$unreadable" || fail "unreadable-cwd: a process whose working directory could not be read was stopped"
  alive "$absent" || fail "unreadable-cwd: a process with no working-directory entry was stopped"

  kill -KILL "$unreadable" "$absent" 2>/dev/null || true
  pass "a working directory that cannot be read leaves its process alone; it is never a default kill"
}

# --- 6. the endpoint's own shell, named by the record ------------------------
#
# The process that saturated the host on 2026-08-27 was an API reparented to
# init - its own session leader. A rule that spared every session leader would
# have skipped exactly it, so the shell that IS spared has to be the one the
# task's record names and nothing else.

test_only_the_recorded_endpoint_shell_is_spared() {
  local endpoint daemon ordinary err
  err="$TMP_ROOT/spare.err"
  endpoint=$(session_leader_witness "$COPY")
  daemon=$(session_leader_witness "$COPY")
  ordinary=$(witness "$COPY")

  fm_wtproc_reap "test" "$endpoint" "$COPY" >/dev/null 2>"$err" \
    || fail "endpoint-shell: the cleanup could not be completed: $(cat "$err")"
  sleep 0.3
  alive "$ordinary" \
    && fail "endpoint-shell: an ordinary leftover survived, so this case proves nothing"
  alive "$daemon" \
    && fail "endpoint-shell: a session-leader daemon that is not the endpoint's shell survived"
  alive "$endpoint" \
    || fail "endpoint-shell: the shell the record names as this endpoint's was stopped"
  [ "$FM_WTPROC_SPARED_ENDPOINT" = "$endpoint" ] \
    || fail "endpoint-shell: the reap did not report which pid it held back"
  [ "$FM_WTPROC_SPARED_LEADERS" = 0 ] \
    || fail "endpoint-shell: leaders were held back although the endpoint's shell was named"

  kill -KILL "$endpoint" 2>/dev/null || true
  sleep 0.3
  pass "only the shell the record names as the endpoint's is spared; a session-leader daemon in the same copy is not"
}

test_an_unnameable_endpoint_shell_holds_leaders_back_and_says_how_many() {
  local unnamed ordinary err
  err="$TMP_ROOT/unknown.err"
  unnamed=$(session_leader_witness "$COPY")
  ordinary=$(witness "$COPY")

  fm_wtproc_reap "test" unknown "$COPY" >/dev/null 2>"$err" \
    || fail "unnameable-endpoint: the cleanup could not be completed: $(cat "$err")"
  sleep 0.3
  alive "$ordinary" \
    && fail "unnameable-endpoint: an ordinary leftover survived, so this case proves nothing"
  alive "$unnamed" \
    || fail "unnameable-endpoint: a session leader was stopped although the endpoint's shell could not be named"
  [ "$FM_WTPROC_SPARED_LEADERS" = 1 ] \
    || fail "unnameable-endpoint: expected 1 held-back leader, got $FM_WTPROC_SPARED_LEADERS"
  case "$(cat "$err")" in
    *"session leader(s)"*"could not be identified from the task record"*) ;;
    *) fail "unnameable-endpoint: the held-back leaders were not named: $(cat "$err")" ;;
  esac

  # And once nothing is held back at all, the same leader goes: the case hinges
  # on what the caller could name and not on the process being unkillable.
  fm_wtproc_reap "test" none "$COPY" >/dev/null 2>&1 \
    || fail "unnameable-endpoint: the unconditional cleanup could not be completed"
  sleep 0.3
  alive "$unnamed" && fail "unnameable-endpoint: a cleanup that holds nothing back spared a session leader"
  pass "an endpoint shell the record cannot name holds every session leader back and reports how many"
}

# --- 7. the same rule through the reporting path -----------------------------

test_a_copy_with_only_unclassifiable_leaders_is_never_reported_clean() {
  local dir leader out
  dir="$TMP_ROOT/case-unnameable"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-unn
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  # The backend cannot say which pid its pane runs, so nothing may be classified.
  printf 'fakepane' > "$dir/panepid"

  leader=$(session_leader_witness "$COPY")
  write_task_meta unn "$COPY" "fmses:fm-unn"

  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"UNRESOLVED: unn"*"leaders_skipped=1"*) ;;
    *) fail "unnameable-report: a copy holding an unclassifiable leader was reported as clean: $out" ;;
  esac
  out=$(run_orphan "$dir" reap unn)
  case "$out" in
    *"left alone because its endpoint shell could not be identified"*) ;;
    *) fail "unnameable-report: the explicit cleanup did not say why it stopped nothing: $out" ;;
  esac
  sleep 0.3
  alive "$leader" || fail "unnameable-report: an unclassifiable session leader was stopped"

  # Same fixture, same process: only the record's ability to name the endpoint's
  # own shell changes, and now the leader is an ordinary orphan.
  printf '%s' "$leader" > "$dir/panepid"
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: unn"*) fail "unnameable-report: the endpoint's own shell was reported as a leftover: $out" ;;
    *"UNRESOLVED: unn"*) fail "unnameable-report: the copy was still unresolved once its endpoint shell was named: $out" ;;
  esac

  # And a daemon beside it, which is not that shell, is reported and stopped.
  local daemon
  daemon=$(session_leader_witness "$COPY")
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: unn"*"$daemon"*) ;;
    *) fail "unnameable-report: an orphaned session-leader daemon was not reported: $out" ;;
  esac
  run_orphan "$dir" reap unn >/dev/null
  sleep 0.3
  alive "$daemon" && fail "unnameable-report: an orphaned session-leader daemon survived the cleanup"
  alive "$leader" || fail "unnameable-report: the recorded endpoint's own shell was stopped"

  kill -KILL "$leader" 2>/dev/null || true
  rm -f "$HOME_DIR/state/unn.meta"
  pass "a session-leader daemon is reported and stopped once the record names the endpoint's shell, and that shell never is"
}

# --- 4c. an undetermined current state is not agreement ----------------------
#
# `unknown` is the current-state reader saying it could not determine the state,
# not a second source agreeing the worker is gone. Observed 2026-08-27 on the
# captain's host: bin/fm-crew-state.sh read `unknown - backend target gone` for
# a task whose recorded copy had since been handed to a live task, so treating
# that reading as corroboration would have stopped the new owner's processes.

test_an_undetermined_current_state_never_authorises_a_stop() {
  local dir pid out
  dir="$TMP_ROOT/case-undetermined"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-und
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  printf 'unknown' > "$dir/crew"

  pid=$(witness "$COPY")
  write_task_meta und "$COPY" "fmses:fm-und"

  # The leak is still REPORTED - a torn-off worker's copy commonly reads this
  # way, and hiding it would trade one silent failure for another - but it is
  # never called ownerless and never stopped for the operator.
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: und"*) fail "undetermined: a copy was called ownerless on an undetermined current state: $out" ;;
  esac
  case "$out" in
    *"UNDETERMINED: und"*"$pid"*) ;;
    *) fail "undetermined: the copy's processes were not reported at all: $out" ;;
  esac
  out=$(run_orphan "$dir" reap und 2>&1) || true
  case "$out" in
    *"not evidence its worker is gone"*) ;;
    *) fail "undetermined: an explicit cleanup did not refuse the undetermined state: $out" ;;
  esac
  sleep 0.3
  alive "$pid" || fail "undetermined: a process was stopped although the current state could not be determined"

  # Only the second source changes: a state the reader could actually determine
  # lets the same fixture through, so this case hinges on `unknown` alone.
  printf 'done' > "$dir/crew"
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: und"*) ;;
    *) fail "undetermined: the same copy was not reported once the state was determined: $out" ;;
  esac
  run_orphan "$dir" reap und >/dev/null
  sleep 0.3
  alive "$pid" && fail "undetermined: the copy's process survived a determined agreeing state"

  rm -f "$HOME_DIR/state/und.meta"
  pass "an undetermined current state reports the leak but never authorises a stop, while a determined one does"
}

# --- 4d. an undetermined AGENT state is not a living owner -------------------
#
# The first source can decline to answer too, and `alive` is the only reading
# that means a living owner. A backend carrying no recovery classifier answers
# `unverified` for every task under it, and that used to return the copy as
# clean while the report said outright that its processes had a living owner -
# an owner the classifier had never given. The same shape reaches an ambiguous
# or unreadable tmux endpoint. Such a copy is reported, under the UNDETERMINED
# label, and a cleanup of it is refused: exactly the treatment an undetermined
# CURRENT state gets one case above, for the same reason.

test_an_undetermined_agent_state_is_never_reported_as_a_clean_copy() {
  local dir pid out rc
  dir="$TMP_ROOT/case-agent-undetermined"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-agentund
  make_crew_state_stub "$dir"
  # The second source would agree the worker is gone, so nothing but the
  # endpoint read failing can account for the outcome below.
  printf 'unreadable' > "$dir/agent"
  printf 'done' > "$dir/crew"

  pid=$(witness "$COPY")
  write_task_meta agentund "$COPY" "fmses:fm-agentund"

  rc=0
  out=$(run_orphan "$dir" scan) || rc=$?
  case "$out" in
    *"UNDETERMINED: agentund"*"$pid"*) ;;
    *) fail "agent-undetermined: a copy whose owner could not be established was not reported: $out" ;;
  esac
  case "$out" in
    *"LEFTOVER: agentund"*) fail "agent-undetermined: a copy was called ownerless on an unreadable agent state: $out" ;;
  esac
  # The classifier gave no owner, so no message may claim one. Two things make
  # this assertion able to fail rather than merely look strict: it is asked of
  # the --task path, the only one that runs with diagnostics on and so the only
  # one that can emit the sentence at all; and it matches the exact CLAIM
  # ("have a living owner and are left alone"), not the bare words "living
  # owner", which honest messages elsewhere use to say the opposite.
  out=$(run_orphan "$dir" scan --task agentund)
  case "$out" in
    *"have a living owner and are left alone"*)
      fail "agent-undetermined: the report claimed a living owner the classifier never gave: $out" ;;
  esac
  case "$out" in
    *"could not be determined"*) ;;
    *) fail "agent-undetermined: the diagnostic did not say the state could not be determined: $out" ;;
  esac

  rc=0
  out=$(run_orphan "$dir" reap agentund) || rc=$?
  [ "$rc" != 0 ] || fail "agent-undetermined: a cleanup of an unreadable agent state did not refuse: $out"
  case "$out" in
    *"not evidence its worker is gone"*) ;;
    *) fail "agent-undetermined: the refusal did not name the undetermined state: $out" ;;
  esac
  sleep 0.3
  alive "$pid" || fail "agent-undetermined: a process was stopped although the agent state could not be read"

  # Only the endpoint read changes: the same fixture, once the classifier can
  # answer, goes through - so this case hinges on the unreadable reading alone.
  printf 'dead' > "$dir/agent"
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: agentund"*) ;;
    *) fail "agent-undetermined: the same copy was not reported once its agent could be read: $out" ;;
  esac
  run_orphan "$dir" reap agentund >/dev/null
  sleep 0.3
  alive "$pid" && fail "agent-undetermined: the copy's process survived a readable, agreeing verdict"

  rm -f "$HOME_DIR/state/agentund.meta"
  pass "an agent state the classifier could not read reports the copy, refuses a stop, and never claims a living owner"
}

# --- 4f. the second source declining is not the two sources disagreeing ------
#
# Only the literal `unknown` used to be treated as the reader declining to
# answer. A reader that TIMED OUT or exited non-zero sets `unreadable`, and that
# fell to the "the two disagree" branch and returned the copy CLEAN - a leak
# hidden by a slow reader. `no-reader` is different in kind and keeps the
# quieter treatment: it means this installation carries no reader at all, so it
# answers identically for every task, live or dead, and says nothing about this
# copy.

test_a_reader_that_could_not_answer_is_not_a_disagreement() {
  local dir pid out rc
  dir="$TMP_ROOT/case-reader-unreadable"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-rdr
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"

  pid=$(witness "$COPY")
  write_task_meta rdr "$COPY" "fmses:fm-rdr"

  # A reader that is asked and fails: exactly what a timeout leaves behind.
  cat > "$dir/crew-state-failing" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/crew-state-failing"

  rc=0
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_WTPROC_GRACE=1 \
    FM_TASK_TMP_ROOT="$FM_TASK_TMP_ROOT" \
    FAKE_AGENT_FILE="$dir/agent" FAKE_REAL_PS="$(command -v ps)" \
    FAKE_CREW_STATE_FILE="$dir/crew" FAKE_PANE_PID_FILE="$dir/panepid" \
    FM_WTPROC_CREW_STATE_BIN="$dir/crew-state-failing" \
    "$ORPHAN" scan 2>&1) || rc=$?
  case "$out" in
    *"UNDETERMINED: rdr"*"$pid"*) ;;
    *) fail "reader-unreadable: a copy whose state reader could not answer was not reported: $out" ;;
  esac
  case "$out" in
    *"LEFTOVER: rdr"*) fail "reader-unreadable: a copy was called ownerless on a failed state read: $out" ;;
  esac
  alive "$pid" || fail "reader-unreadable: a process was stopped although the state reader could not answer"

  # A home with NO reader at all is the other case, and stays quiet: it answers
  # the same way for every task, so it says nothing about this one.
  rc=0
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_WTPROC_GRACE=1 \
    FM_TASK_TMP_ROOT="$FM_TASK_TMP_ROOT" \
    FAKE_AGENT_FILE="$dir/agent" FAKE_REAL_PS="$(command -v ps)" \
    FAKE_CREW_STATE_FILE="$dir/crew" FAKE_PANE_PID_FILE="$dir/panepid" \
    FM_WTPROC_CREW_STATE_BIN="$dir/no-such-reader" \
    "$ORPHAN" scan 2>&1) || rc=$?
  case "$out" in
    *rdr*) fail "reader-unreadable: a home with no state reader at all alerted on a copy it cannot judge: $out" ;;
  esac
  alive "$pid" || fail "reader-unreadable: a process was stopped on a home with no state reader"

  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$HOME_DIR/state/rdr.meta"
  pass "a state reader that could not answer reports the copy, while a home carrying no reader stays quiet"
}

# --- 4e. no classifier at all is not a suspicion about the copy --------------
#
# `unverified` is what fm_backend_agent_state answers for every backend with no
# recovery classifier, for a live worker exactly as for a dead one, so it says
# nothing about this copy. Alerting on it would put every healthy task on a
# zellij, orca, or cmux home into the report at every session start, and a
# report that cries wolf every session is one people stop reading - which costs
# the very leak this exists to surface. The two halves are independent: raise no
# alert, and still never authorise a stop.

test_a_runtime_with_no_classifier_raises_no_alert_but_still_refuses_a_stop() {
  local dir pid out rc
  dir="$TMP_ROOT/case-unverified"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-unver
  make_crew_state_stub "$dir"
  # Both sources would otherwise agree the worker is gone, so only the missing
  # classifier can account for the silence.
  printf 'dead' > "$dir/agent"
  printf 'done' > "$dir/crew"

  pid=$(witness "$COPY")
  write_task_meta unver "$COPY" "fmses:fm-unver"
  sed -i 's/^backend=tmux$/backend=zellij/' "$HOME_DIR/state/unver.meta"

  rc=0
  out=$(run_orphan "$dir" scan) || rc=$?
  case "$out" in
    *unver*) fail "unverified-runtime: a healthy-or-not copy on a runtime with no classifier was alerted on: $out" ;;
  esac
  [ "$rc" = 0 ] || fail "unverified-runtime: the sweep exited $rc over a copy it simply cannot judge"

  # ... and the stop is still refused, which is the half that must NOT relax.
  rc=0
  out=$(run_orphan "$dir" reap unver) || rc=$?
  [ "$rc" != 0 ] || fail "unverified-runtime: a cleanup was allowed although no classifier could establish the owner: $out"
  case "$out" in
    *"no agent classifier"*) ;;
    *) fail "unverified-runtime: the refusal did not name the missing classifier: $out" ;;
  esac
  sleep 0.3
  alive "$pid" || fail "unverified-runtime: a process was stopped on a runtime that cannot establish its owner"

  # Only the backend changes: the same fixture on a runtime that CAN classify is
  # reported and cleaned, so the silence above is the missing classifier alone.
  sed -i 's/^backend=zellij$/backend=tmux/' "$HOME_DIR/state/unver.meta"
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: unver"*) ;;
    *) fail "unverified-runtime: the same copy was not reported once its runtime could classify: $out" ;;
  esac
  run_orphan "$dir" reap unver >/dev/null
  sleep 0.3
  alive "$pid" && fail "unverified-runtime: the copy's process survived on a runtime that could classify it"

  rm -f "$HOME_DIR/state/unver.meta"
  pass "a runtime with no agent classifier raises no alert, still refuses a stop, and does not mask a copy its runtime can judge"
}

# --- 8. the per-task temp root is a reap root and gets the same refusals ------

test_a_temp_root_in_the_operators_tree_is_never_a_reap_root() {
  local good rc out projects_tmp home_tmp pid_in_copy pid_in_projects dir

  good="$TMP_ROOT/fm-good"
  mkdir -p "$good"
  out=$(fm_wtproc_task_tmp good "$good" "$HOME_DIR" 2>&1) \
    || fail "temp-root: a legitimate per-task temp root was refused: $out"
  [ "$out" = "$good" ] || fail "temp-root: expected $good, got $out"

  projects_tmp="$HOME_DIR/projects/fm-tmpguard"
  mkdir -p "$projects_tmp"
  rc=0
  out=$(fm_wtproc_task_tmp tmpguard "$projects_tmp" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "temp-root: a temp root under the home's projects/ was accepted"
  case "$out" in
    *"is a primary clone"*) ;;
    *) fail "temp-root: the projects/ refusal did not name its cause: $out" ;;
  esac

  # The recorded path IS the path fm-spawn would build for this task here
  # (FM_TASK_TMP_ROOT points at the home for this one call), so the path binding
  # is satisfied and only the home refusal can turn it away - and the assertion
  # names that refusal's own cause, so deleting the refusal fails this case
  # instead of passing it on a missing directory.
  home_tmp="$HOME_DIR/fm-tmphome"
  mkdir -p "$home_tmp"
  rc=0
  out=$(HOME="$HOME_DIR" FM_TASK_TMP_ROOT="$HOME_DIR" \
    fm_wtproc_task_tmp tmphome "$home_tmp" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "temp-root: a temp root sitting directly in the home directory was accepted"
  case "$out" in
    *"sits directly in the home directory"*) ;;
    *) fail "temp-root: the home-directory refusal did not name its cause: $out" ;;
  esac

  # End to end: a record naming the operator's own tree as this task's second
  # reap root reaches nothing in it, while the real copy is still cleaned.
  dir="$TMP_ROOT/case-tmproot"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-tmpguard
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  printf 'fakepane' > "$dir/panepid"
  pid_in_projects=$(witness "$projects_tmp")
  pid_in_copy=$(witness "$COPY")
  write_task_meta tmpguard "$COPY" "fmses:fm-tmpguard" "$projects_tmp"

  out=$(run_orphan "$dir" scan --task tmpguard)
  case "$out" in
    *"$pid_in_projects"*) fail "temp-root: a process under the home's projects/ was attributed to a task: $out" ;;
  esac
  run_orphan "$dir" reap tmpguard >/dev/null
  sleep 0.3
  alive "$pid_in_projects" \
    || fail "temp-root: a process under the home's projects/ was stopped by a task's cleanup"
  alive "$pid_in_copy" \
    && fail "temp-root: the task's own copy was not cleaned, so this case proves nothing"

  kill -KILL "$pid_in_projects" 2>/dev/null || true
  rm -f "$HOME_DIR/state/tmpguard.meta"
  pass "a per-task temp root pointing into the operator's own tree is refused, and nothing in it is ever signalled"
}

# --- 8b. the temp root has to be THIS task's own temp root -------------------
#
# fm-spawn creates exactly one temp root per task, at $FM_TASK_TMP_ROOT/fm-<id>.
# A name test would accept any directory on the machine whose name happens to
# end that way, so a stale or hand-edited `tasktmp=` could point a cleanup at a
# tree this task never owned.

test_a_temp_root_outside_the_recorded_path_is_refused() {
  local own elsewhere rc out dir pid_elsewhere pid_in_copy

  own="$FM_TASK_TMP_ROOT/fm-bindx"
  mkdir -p "$own"
  out=$(fm_wtproc_task_tmp bindx "$own" "$HOME_DIR" 2>&1) \
    || fail "temp-root-binding: this task's own temp root was refused: $out"
  [ "$out" = "$own" ] || fail "temp-root-binding: expected $own, got $out"

  # Correctly named for the task, clear of the home and projects/ boundaries,
  # and still not the root fm-spawn made: the only thing that differs is where
  # it sits.
  elsewhere="$TMP_ROOT/elsewhere/fm-bindx"
  mkdir -p "$elsewhere"
  rc=0
  out=$(fm_wtproc_task_tmp bindx "$elsewhere" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] \
    || fail "temp-root-binding: a correctly named temp root outside the recorded path was accepted"
  case "$out" in
    *"is not task bindx's own temp root"*) ;;
    *) fail "temp-root-binding: the refusal did not name its cause: $out" ;;
  esac

  # End to end: a record naming that impostor reaches nothing in it, while the
  # task's real copy is still cleaned.
  dir="$TMP_ROOT/case-tmpbinding"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-bindx
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  printf 'fakepane' > "$dir/panepid"
  pid_elsewhere=$(witness "$elsewhere")
  pid_in_copy=$(witness "$COPY")
  write_task_meta bindx "$COPY" "fmses:fm-bindx" "$elsewhere"

  out=$(run_orphan "$dir" scan --task bindx)
  case "$out" in
    *"$pid_elsewhere"*) fail "temp-root-binding: a process outside the task's own temp root was attributed to it: $out" ;;
  esac
  run_orphan "$dir" reap bindx >/dev/null
  sleep 0.3
  alive "$pid_elsewhere" \
    || fail "temp-root-binding: a process outside the task's own temp root was stopped"
  alive "$pid_in_copy" \
    && fail "temp-root-binding: the task's real copy was not cleaned"

  kill -KILL "$pid_elsewhere" 2>/dev/null || true
  rm -f "$HOME_DIR/state/bindx.meta"
  pass "a temp root that is not the one recorded for this task is refused, and nothing in it is reached"
}

# --- 9. the reap's account of its own outcome --------------------------------
#
# "Stopped" is what an operator acts on, so it may only be said when it is true.
# These cases drive the scan through a synthetic cwd source - the proc root is
# pointed at nothing so the lsof branch answers - because the three outcomes
# below are all about what the reap does when the machine stops answering, or
# answers that a process outlived a KILL (the uninterruptible-wait shape of the
# 2026-08-27 incident, which no test can produce on demand).

make_cwd_source_stub() {  # <dir> <pid> <cwd> <good-answers|forever>
  mkdir -p "$1/bin"
  printf '0' > "$1/count"
  cat > "$1/bin/lsof" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FAKE_LSOF_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s' "$n" > "$FAKE_LSOF_COUNT"
if [ "$FAKE_LSOF_GOOD" != forever ] && [ "$n" -gt "$FAKE_LSOF_GOOD" ]; then
  echo "lsof: synthetic failure" >&2
  exit 1
fi
printf 'p%s\nfcwd\nn%s\n' "$FAKE_LSOF_PID" "$FAKE_LSOF_DIR"
SH
  chmod +x "$1/bin/lsof"
  # A birth identity that stays put after the process is gone, so "still listed"
  # is not quietly rescued by the pid-reuse guard.
  cat > "$1/bin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "$FAKE_LSOF_PID" ]; then
  printf 'Mon Jan  1 00:00:00 2024 /bin/sleep 600\n'
  exit 0
fi
exec "$FAKE_REAL_PS_BIN" "$@"
SH
  chmod +x "$1/bin/ps"
  FAKE_LSOF_COUNT="$1/count"
  FAKE_LSOF_PID=$2
  FAKE_LSOF_DIR=$3
  FAKE_LSOF_GOOD=$4
  FAKE_REAL_PS_BIN=$(command -v ps)
  export FAKE_LSOF_COUNT FAKE_LSOF_PID FAKE_LSOF_DIR FAKE_LSOF_GOOD FAKE_REAL_PS_BIN
}

with_stubbed_cwd_source() {  # <dir> <command...>
  local dir=$1 saved_path=$PATH rc=0
  shift
  PATH="$dir/bin:$PATH"
  FM_PROC_ROOT_OVERRIDE="$dir/no-proc"
  "$@" || rc=$?
  PATH=$saved_path
  unset FM_PROC_ROOT_OVERRIDE
  return "$rc"
}

test_the_reap_distinguishes_a_scan_that_broke_before_a_signal_from_one_after() {
  local dir pid err rc

  dir="$TMP_ROOT/outcome-before"
  mkdir -p "$dir/work"
  pid=$(witness "$dir/work")
  err="$dir/before.err"
  make_cwd_source_stub "$dir" "$pid" "$dir/work" 0
  rc=0
  with_stubbed_cwd_source "$dir" fm_wtproc_reap "before" none "$dir/work" \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" = 1 ] || fail "reap-outcome: a scan that failed before any signal returned $rc, not 1"
  case "$(cat "$err")" in
    *"nothing was signalled"*) ;;
    *) fail "reap-outcome: the pre-signal failure did not say nothing was signalled: $(cat "$err")" ;;
  esac
  alive "$pid" || fail "reap-outcome: a process was signalled by a scan that never resolved"
  kill -KILL "$pid" 2>/dev/null || true

  dir="$TMP_ROOT/outcome-after"
  mkdir -p "$dir/work"
  pid=$(witness "$dir/work")
  err="$dir/after.err"
  # Two answers is exactly enough to select and signal; the recheck after the
  # grace period is the one that breaks.
  make_cwd_source_stub "$dir" "$pid" "$dir/work" 2
  rc=0
  with_stubbed_cwd_source "$dir" fm_wtproc_reap "after" none "$dir/work" \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" = 2 ] || fail "reap-outcome: a scan that failed after the signal returned $rc, not 2"
  case "$(cat "$err")" in
    *"nothing was signalled"*)
      fail "reap-outcome: a post-signal failure claimed nothing was signalled: $(cat "$err")" ;;
    *"their fate is unknown"*) ;;
    *) fail "reap-outcome: the post-signal failure did not name the uncertainty: $(cat "$err")" ;;
  esac
  case " $FM_WTPROC_REAPED " in
    *" $pid "*) ;;
    *) fail "reap-outcome: the post-signal failure did not name what it had signalled" ;;
  esac
  pass "a scan that breaks before a signal and one that breaks after it are two different answers"
}

test_a_scan_that_breaks_between_selecting_and_signalling_names_the_root() {
  local dir pid err rc
  dir="$TMP_ROOT/outcome-between"
  mkdir -p "$dir/work"
  pid=$(witness "$dir/work")
  err="$dir/between.err"
  # One good answer: enough to collect and select, so the recheck that guards
  # the TERM is the pass that breaks. A cleanup abandoned there has to name the
  # root that stopped answering, exactly as the earlier failure does.
  make_cwd_source_stub "$dir" "$pid" "$dir/work" 1
  rc=0
  with_stubbed_cwd_source "$dir" fm_wtproc_reap "between" none "$dir/work" \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" = 1 ] || fail "reap-outcome: a scan that broke before the TERM returned $rc, not 1"
  case "$(cat "$err")" in
    *"nothing was signalled"*) ;;
    *) fail "reap-outcome: the failure between selecting and signalling said nothing about what it did: $(cat "$err")" ;;
  esac
  # The root has to be named by the ABANDONMENT diagnostic itself. Asserting the
  # bare path would pass on the "stopping ... left in <roots>" line printed a
  # moment earlier on the same stream, and would go on passing with this
  # diagnostic removed entirely; only the sentence below can produce this.
  case "$(cat "$err")" in
    *"processes under $dir/work stopped being listable"*) ;;
    *) fail "reap-outcome: the abandoned cleanup did not name the root that stopped answering: $(cat "$err")" ;;
  esac
  alive "$pid" || fail "reap-outcome: a process was signalled after the scan stopped answering"
  kill -KILL "$pid" 2>/dev/null || true
  pass "a cleanup abandoned between selecting and signalling names the root it lost and says nothing was signalled"
}

test_a_process_that_outlives_the_force_stop_is_never_reported_stopped() {
  local dir pid err rc
  dir="$TMP_ROOT/outcome-survivor"
  mkdir -p "$dir/work"
  pid=$(witness "$dir/work")
  err="$dir/survivor.err"
  # The cwd source keeps answering that the process is there, its birth identity
  # keeps matching, and it keeps reading ALIVE: from the reap's side this is
  # indistinguishable from a process wedged past a KILL, which is what the real
  # thing is - an uninterruptible sleep does not die and does not stop existing.
  # The liveness answer has to be stubbed alongside the other two, because the
  # fixture's witness really does die when signalled and a wedged process does
  # not; stubbing only the listing would model a process that is gone, which is
  # a different outcome with a different status.
  make_cwd_source_stub "$dir" "$pid" "$dir/work" forever
  local real_alive
  real_alive=$(declare -f _fm_wtproc_pid_exists)
  _fm_wtproc_pid_exists() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
  rc=0
  with_stubbed_cwd_source "$dir" fm_wtproc_reap "survivor" none "$dir/work" \
    >/dev/null 2>"$err" || rc=$?
  eval "$real_alive"
  [ "$rc" = 3 ] || fail "reap-outcome: a process still listed after the force-stop returned $rc, not 3"
  [ "$FM_WTPROC_SURVIVORS" = "$pid" ] \
    || fail "reap-outcome: the survivor was not named: '$FM_WTPROC_SURVIVORS'"
  case "$(cat "$err")" in
    *"still running after being force-stopped"*) ;;
    *) fail "reap-outcome: the survivor was not reported: $(cat "$err")" ;;
  esac
  kill -KILL "$pid" 2>/dev/null || true
  pass "a process that outlives the force-stop is reported as surviving, never as stopped"
}

# --- 10. a copy the host could not look at is never reported clean -----------
#
# "I looked and found nothing" and "I could not look" are different facts, and
# the session-start digest prints the first as "(none)". A scan that folded the
# second into it would tell an operator a fleet is clean on the strength of
# never having examined it.

test_a_copy_this_host_cannot_list_is_never_reported_clean() {
  local dir pid out rc
  dir="$TMP_ROOT/case-unscannable"
  mkdir -p "$dir/fakebin"
  make_backend_stub "$dir" fm-unscan
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"

  pid=$(witness "$COPY")
  write_task_meta unscan "$COPY" "fmses:fm-unscan"

  # The same fixture on a host that CAN answer, so what follows is proven to
  # hinge on the missing cwd source and nothing else.
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: unscan"*) ;;
    *) fail "unscannable: the copy was not reported while the host could answer, so this case proves nothing: $out" ;;
  esac

  # Now no cwd source can answer at all: the proc root points at nothing and the
  # only other source refuses.
  cat > "$dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: synthetic failure" >&2
exit 1
SH
  chmod +x "$dir/fakebin/lsof"
  export FM_PROC_ROOT_OVERRIDE="$dir/no-proc"

  rc=0
  out=$(run_orphan "$dir" scan) || rc=$?
  case "$out" in
    *"UNSCANNABLE: unscan"*) ;;
    *) fail "unscannable: a copy that could not be listed was not reported: $out" ;;
  esac
  case "$out" in
    *"$COPY"*) ;;
    *) fail "unscannable: the report did not name the root it could not read: $out" ;;
  esac
  case "$out" in
    *"LEFTOVER: unscan"*) fail "unscannable: an unexamined copy was reported as leaking: $out" ;;
  esac
  [ "$rc" != 0 ] || fail "unscannable: a scan that could not look exited 0, so the digest would print (none)"

  rc=0
  out=$(run_orphan "$dir" reap unscan) || rc=$?
  [ "$rc" != 0 ] || fail "unscannable: an explicit cleanup that could not look reported success"
  case "$out" in
    *"nothing to stop"*) fail "unscannable: a copy that could not be listed was reported as having nothing to stop: $out" ;;
  esac
  case "$out" in
    *"could not be listed"*) ;;
    *) fail "unscannable: the refusal did not say the copy could not be listed: $out" ;;
  esac
  unset FM_PROC_ROOT_OVERRIDE
  rm -f "$dir/fakebin/lsof"

  sleep 0.3
  alive "$pid" || fail "unscannable: a process was stopped by a scan that could not resolve anything"
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$HOME_DIR/state/unscan.meta"
  pass "a copy this host cannot list is reported as unexamined, and never as clean or as stopped"
}

# --- 11. a caller whose own working directory is gone can still look ---------

test_a_removed_working_directory_does_not_make_the_host_unanswerable() {
  local lib gone stub pid out rc baseline
  lib="$ROOT/bin/fm-worktree-proc-lib.sh"
  baseline=$(bash -c '. "$1"; fm_wtproc_resolver' _ "$lib" 2>/dev/null || true)
  if [ "$baseline" != proc ]; then
    pass "the caller's own working directory is not this host's cwd source; nothing to prove"
    return 0
  fi

  stub="$TMP_ROOT/gone-cwd-bin"
  mkdir -p "$stub"
  # The only other source refuses, so the answer below can only have come from
  # /proc.
  cat > "$stub/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: synthetic failure" >&2
exit 1
SH
  chmod +x "$stub/lsof"

  gone="$TMP_ROOT/gone-cwd"
  mkdir -p "$gone"
  pid=$(witness "$COPY")
  rc=0
  # A shell left sitting in a directory that is then removed under it - what a
  # torn-down task copy leaves behind, and the reachable trigger for the whole
  # fleet scan reporting nothing.
  out=$(cd "$gone" && rm -rf "$gone" \
    && PATH="$stub:$PATH" bash -c '. "$1"; fm_wtproc_pids_under "$2"' _ "$lib" "$COPY" 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || fail "gone-cwd: a caller whose own working directory was removed could not answer at all"
  contains_pid "$out" "$pid" \
    || fail "gone-cwd: the process in the copy was not found from a caller with no working directory: '$out'"

  kill -KILL "$pid" 2>/dev/null || true
  pass "a caller whose own working directory was removed still resolves processes from /proc"
}

# --- 12. one listing per observation, and never one across two ---------------

test_each_collect_looks_at_the_machine_again() {
  local pid other tmp_root
  tmp_root="$TMP_ROOT/collect-roots/fm-collect"
  mkdir -p "$tmp_root"
  pid=$(witness "$COPY")
  other=$(witness "$tmp_root")

  fm_wtproc_collect "$COPY" "$tmp_root" \
    || fail "collect: a scan of two roots failed"
  contains_pid "$FM_WTPROC_PIDS" "$pid" \
    || fail "collect: the process in the first root was not attributed"
  contains_pid "$FM_WTPROC_PIDS" "$other" \
    || fail "collect: the process in the second root was not attributed, so the roots do not share one listing correctly"

  kill -KILL "$other" 2>/dev/null || true
  sleep 0.3
  fm_wtproc_collect "$COPY" "$tmp_root" \
    || fail "collect: the second scan of two roots failed"
  contains_pid "$FM_WTPROC_PIDS" "$pid" \
    || fail "collect: the surviving process was lost by the second scan"
  contains_pid "$FM_WTPROC_PIDS" "$other" \
    && fail "collect: a process that had already exited was still reported, so one observation answered another"

  kill -KILL "$pid" 2>/dev/null || true
  pass "every collect looks at the machine again; a process that has died since the last one is gone from the next"
}

# --- 13. a listing that could not be produced is not an empty machine --------
#
# The cwd LINK resolving proves the kernel exposes the working directory; it does
# not prove the listing this library reads that fact THROUGH can be produced. A
# host where it cannot has to say so, because "the listing came back with
# nothing" and "no process has a working directory here" are the same bytes and
# opposite facts - and every caller reads the second as a copy it may destroy.

test_a_listing_that_cannot_be_produced_is_never_an_empty_machine() {
  local lib stub cmd pid out rc baseline
  lib="$ROOT/bin/fm-worktree-proc-lib.sh"
  baseline=$(bash -c '. "$1"; fm_wtproc_resolver' _ "$lib" 2>/dev/null || true)
  if [ "$baseline" != proc ]; then
    pass "this host does not answer from /proc; the listing case does not apply"
    return 0
  fi

  pid=$(witness "$COPY")
  # The same fixture on an unhampered host, so what follows is proven to hinge
  # on the listing and on nothing else.
  out=$(bash -c '. "$1"; fm_wtproc_pids_under "$2"' _ "$lib" "$COPY") \
    || fail "no-listing: the baseline scan failed, so this case proves nothing"
  contains_pid "$out" "$pid" \
    || fail "no-listing: the baseline scan did not find the witness, so this case proves nothing"

  # The listing command cannot run at all, and the only other cwd source
  # refuses: nothing on this host can answer the question now.
  stub="$TMP_ROOT/no-listing-bin"
  mkdir -p "$stub"
  for cmd in ls lsof; do
    cat > "$stub/$cmd" <<SH
#!/usr/bin/env bash
echo "$cmd: synthetic failure" >&2
exit 1
SH
    chmod +x "$stub/$cmd"
  done

  rc=0
  out=$(PATH="$stub:$PATH" bash -c '. "$1"; fm_wtproc_pids_under "$2"' _ "$lib" "$COPY" 2>/dev/null) || rc=$?
  [ "$rc" != 0 ] \
    || fail "no-listing: a host that could not produce a listing answered '$out' with success, which every caller reads as a copy with nothing running in it"

  alive "$pid" || fail "no-listing: the witness was stopped by a scan that could not look at the machine"
  kill -KILL "$pid" 2>/dev/null || true
  pass "a listing that could not be produced is unanswerable, and never an empty machine"
}

# --- 14. a reap that never selects reports nothing from the copy before it ---
#
# The reap returns before the selector on two ordinary paths - a scan that
# failed, and a copy with nothing running in it - and callers quote what the
# selector sets straight into their durable record. Carried over from an earlier
# call in the same shell, those would name a previous copy's held-back shell.

test_a_reap_that_never_selects_reports_nothing_from_the_copy_before_it() {
  local empty leader
  empty="$TMP_ROOT/empty-copy"
  mkdir -p "$empty"
  leader=$(session_leader_witness "$COPY")
  # An ordinary leftover, so the reap below has something to select; the witness
  # registry owns it from here.
  witness "$COPY" >/dev/null

  # A reap that DOES select and DOES hold a named shell back, so what follows is
  # proven to clear a real previous answer rather than an initial value.
  fm_wtproc_reap "previous" "$leader" "$COPY" >/dev/null 2>&1 \
    || fail "stale-globals: the reap that names an endpoint shell could not be completed"
  [ "$FM_WTPROC_SPARED_ENDPOINT" = "$leader" ] \
    || fail "stale-globals: the first reap held no endpoint shell back, so this case proves nothing"
  [ -n "$FM_WTPROC_SELECTED" ] \
    || fail "stale-globals: the first reap selected nothing, so this case proves nothing"

  fm_wtproc_reap "empty" none "$empty" >/dev/null 2>&1 \
    || fail "stale-globals: a reap of a copy with nothing running in it failed"
  [ -z "$FM_WTPROC_SELECTED" ] \
    || fail "stale-globals: a reap that never selected anything still names '$FM_WTPROC_SELECTED' as selected"
  [ -z "$FM_WTPROC_SPARED_ENDPOINT" ] \
    || fail "stale-globals: a reap that never selected anything still names an earlier copy's held-back shell '$FM_WTPROC_SPARED_ENDPOINT'"

  # And the same for the leader count, which the relaunch journal quotes.
  witness "$COPY" >/dev/null
  fm_wtproc_reap "previous" unknown "$COPY" >/dev/null 2>&1 \
    || fail "stale-globals: the reap that holds leaders back could not be completed"
  [ "$FM_WTPROC_SPARED_LEADERS" = 1 ] \
    || fail "stale-globals: the second reap held $FM_WTPROC_SPARED_LEADERS leader(s) back, not 1, so this case proves nothing"

  fm_wtproc_reap "empty" none "$empty" >/dev/null 2>&1 \
    || fail "stale-globals: the second reap of a copy with nothing running in it failed"
  [ "$FM_WTPROC_SPARED_LEADERS" = 0 ] \
    || fail "stale-globals: a reap that never selected anything still reports $FM_WTPROC_SPARED_LEADERS leader(s) held back from an earlier copy"

  kill -KILL "$leader" 2>/dev/null || true
  pass "a reap that never reaches the selector reports nothing left over from the copy before it"
}

# --- 10. an undetermined owner keeps its label on every path -----------------
#
# The two facts are independent: whether this copy's owner could be established,
# and whether anything in it could be classified. A copy where BOTH are open -
# the current state unreadable AND the endpoint shell unnameable - must still be
# reported as undetermined and must still refuse a cleanup, because "its session
# leaders want a look by hand" and "nobody knows whether this copy has a live
# owner" send an operator to different places.

test_an_undetermined_copy_keeps_its_label_when_everything_is_held_back() {
  local dir copy leader out rc
  dir="$TMP_ROOT/case-undet-held"
  copy="$TMP_ROOT/copy-undet-held"
  mkdir -p "$dir"
  git -C "$PRIMARY" worktree add --quiet -b undet-held "$copy"
  make_backend_stub "$dir" fm-uh
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  printf 'unknown' > "$dir/crew"
  # The backend cannot name the pane's shell either, so every leader is held
  # back and the selected set comes out empty.
  printf 'fakepane' > "$dir/panepid"

  leader=$(session_leader_witness "$copy")
  write_task_meta uh "$copy" "fmses:fm-uh"

  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"UNRESOLVED: uh"*) fail "undetermined-held: an undetermined copy lost its label to the held-back leaders: $out" ;;
  esac
  case "$out" in
    *"UNDETERMINED: uh"*"leaders_skipped=1"*) ;;
    *) fail "undetermined-held: the copy was not reported as undetermined with its held-back leader: $out" ;;
  esac

  rc=0
  out=$(run_orphan "$dir" reap uh) || rc=$?
  [ "$rc" != 0 ] || fail "undetermined-held: a cleanup of an undetermined copy did not refuse: $out"
  case "$out" in
    *"not evidence its worker is gone"*) ;;
    *) fail "undetermined-held: the refusal did not name the undetermined state: $out" ;;
  esac
  sleep 0.3
  alive "$leader" || fail "undetermined-held: a held-back leader was stopped anyway"

  # Only the second source changes: with a determined state the same fixture
  # reports the ordinary unresolved copy again, so this case hinges on `unknown`.
  printf 'done' > "$dir/crew"
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"UNRESOLVED: uh"*"leaders_skipped=1"*) ;;
    *) fail "undetermined-held: a determined state did not restore the unresolved report: $out" ;;
  esac

  kill -KILL "$leader" 2>/dev/null || true
  rm -f "$HOME_DIR/state/uh.meta"
  git -C "$PRIMARY" worktree remove --force "$copy" 2>/dev/null || true
  pass "a copy whose owner could not be established says so even when every process in it was held back"
}

# --- 12b. a recorded root that is GONE is not a root that could not be read ---
#
# "I could not look" and "there is nothing there to look at" are different facts
# and send an operator to different places. A recorded temp root that no longer
# exists is the second: the scanner itself treats an absent directory as
# "nothing is running there" and returns cleanly. Reporting it as a root that
# cannot be called clean - and, worse, with an empty reason attached - fires on
# every scan for as long as the stale path stays in the record, and a report
# that raises contentless alarms is one people stop reading.

# The COPY half of the same contract the temp root already keeps. A record that
# names a local copy the shape wall refuses had nothing examined at all, yet the
# whole task vanished from the report: the fleet scan exited 0 with no line for
# it, so bin/fm-session-start.sh's digest printed "(none)" for a copy holding a
# live process, and `reap` answered "nothing to stop" - the one claim its own
# unscannable arm exists to refuse to make.
#
# An ordinary clone is the reachable shape, not a contrived one: bin/fm-teardown.sh
# deliberately supports a task copy that is a plain clone rather than a linked
# worktree, and that copy fails the linked-worktree proof used here.
test_a_recorded_copy_the_wall_refuses_is_reported_rather_than_dropped() {
  local dir clone out rc pid
  dir="$TMP_ROOT/case-refused-copy"
  clone="$TMP_ROOT/ordinary-clone"
  mkdir -p "$dir"
  git clone --quiet "$PRIMARY" "$clone" 2>/dev/null \
    || fail "refused-copy: could not build the ordinary-clone fixture"
  make_backend_stub "$dir" fm-rc
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"

  pid=$(witness "$clone")
  write_task_meta rc "$clone" "fmses:fm-rc"

  # The fleet-wide sweep, which is what the session-start digest actually runs.
  rc=0
  out=$(run_orphan "$dir" scan) || rc=$?
  case "$out" in
    *"UNSCANNABLE: rc"*"$clone"*) ;;
    *) fail "refused-copy: a refused local copy left no trace in the fleet scan: $out" ;;
  esac
  [ "$rc" = 3 ] \
    || fail "refused-copy: a scan with an unexamined copy exited $rc, so the digest would present it as a clean fleet"
  case "$out" in
    *"LEFTOVER: rc"*) fail "refused-copy: an unexamined copy was reported as leaking: $out" ;;
  esac

  rc=0
  out=$(run_orphan "$dir" reap rc) || rc=$?
  [ "$rc" != 0 ] || fail "refused-copy: a cleanup that examined nothing reported success: $out"
  case "$out" in
    *"nothing to stop"*) fail "refused-copy: a copy that was never read was reported as having nothing to stop: $out" ;;
  esac
  case "$out" in
    *"was refused"*) ;;
    *) fail "refused-copy: the refusal did not say the recorded copy was refused: $out" ;;
  esac

  sleep 0.3
  alive "$pid" || fail "refused-copy: a process in a copy that was never validated was stopped"
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$HOME_DIR/state/rc.meta"
  rm -rf "$clone"
  pass "a recorded local copy the wall refuses is reported as unexamined instead of vanishing from the report"
}

# A COPY THAT IS GONE IS NOT A COPY THAT COULD NOT BE READ. teardown removes the
# local copy several refusable steps before it removes the record, so a record
# outliving its directory is ordinary. An absent path holds no process and gives
# an operator nothing to inspect, so alerting on it put a contentless UNSCANNABLE
# line in the session-start digest at every session start for as long as the
# stale path stayed in the record - and pointed at a repair (retarget the copy)
# that cannot be carried out once the copy is gone.
test_a_recorded_copy_that_no_longer_exists_raises_no_alert() {
  local dir out rc
  dir="$TMP_ROOT/case-gone-copy"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-gc
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  write_task_meta gc "$TMP_ROOT/copy-that-was-removed" "fmses:fm-gc"

  rc=0
  out=$(run_orphan "$dir" scan) || rc=$?
  case "$out" in
    *UNSCANNABLE*) fail "gone-copy: a copy whose directory is gone raised an unexamined-root alarm: $out" ;;
  esac
  [ "$rc" = 0 ] \
    || fail "gone-copy: a scan whose only record names a removed copy exited $rc, so the digest alarms at every session start"

  rc=0
  out=$(run_orphan "$dir" reap gc) || rc=$?
  case "$out" in
    *"<path-to-the-real-copy>"*) fail "gone-copy: the cleanup told the operator to retarget a copy that no longer exists: $out" ;;
  esac
  rm -f "$HOME_DIR/state/gc.meta"
  pass "a recorded local copy whose directory is gone stays silent instead of alarming forever"
}

# EVERY LINE NAMES THE ROOT IT ACTUALLY DESCRIBES. The report used to print
# whichever root happened to be first in the collected set under a `copy=` label.
# Once a copy can be missing from that set - gone, or refused - the survivor is
# the temp root, so the digest said `copy=/tmp/fm-<id>` for a path that is not
# the task's copy at all, and an operator following it went to inspect the wrong
# directory. Position is not identity; the label has to come from which root it
# is.
test_a_report_line_names_the_root_it_describes() {
  local dir tmproot out pid
  dir="$TMP_ROOT/case-root-labels"
  tmproot="$FM_TASK_TMP_ROOT/fm-lbl"
  mkdir -p "$dir" "$tmproot"
  make_backend_stub "$dir" fm-lbl
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"

  pid=$(witness "$tmproot")
  # The copy is gone; only the temp root remains to be examined.
  write_task_meta lbl "$TMP_ROOT/copy-removed-for-labels" "fmses:fm-lbl" "$tmproot"

  out=$(run_orphan "$dir" scan --task lbl)
  case "$out" in
    *"LEFTOVER: lbl"*"$pid"*) ;;
    *) fail "root-labels: the live process in the temp root was not reported at all: $out" ;;
  esac
  # The assertion this case exists for.
  case "$out" in
    *"copy=$tmproot"*) fail "root-labels: the temp root was reported under a copy= label: $out" ;;
  esac
  case "$out" in
    *"tasktmp=$tmproot"*) ;;
    *) fail "root-labels: the temp root was not named as a temp root: $out" ;;
  esac

  out=$(run_orphan "$dir" reap lbl)
  # The sentence that says where the processes were stopped must name the root
  # they were actually in. Saying "its local copy" here described the temp root
  # as the copy - and this task no longer has a copy to speak of.
  case "$out" in
    *"process(es) left in tasktmp=$tmproot"*) ;;
    *) fail "root-labels: the cleanup did not name the root it stopped processes in: $out" ;;
  esac
  case "$out" in
    *"left in its local copy"*) fail "root-labels: the cleanup called the temp root a local copy: $out" ;;
  esac
  sleep 0.3
  alive "$pid" && fail "root-labels: the leaked process in the temp root was not stopped"

  rm -f "$HOME_DIR/state/lbl.meta"
  rm -rf "$tmproot"
  pass "a task reported on its temp root alone names it tasktmp=, never copy="
}

# "NOTHING TO STOP" IS A CLAIM ABOUT THE WHOLE TASK, so it may not be made while
# a recorded root went unexamined. The scan already refuses that claim when the
# refused root is the ONLY one; with a second, valid root the reap fell through
# to the same sentence and exited 0 - the copy was never read, and the operator
# was told the task was clean.
test_a_reap_never_reports_clean_with_an_unexamined_root() {
  local dir clone tmproot out rc
  dir="$TMP_ROOT/case-unexamined-clean"
  clone="$TMP_ROOT/clone-unexamined-clean"
  tmproot="$FM_TASK_TMP_ROOT/fm-unx"
  mkdir -p "$dir" "$tmproot"
  git clone --quiet "$PRIMARY" "$clone" 2>/dev/null \
    || fail "unexamined-clean: could not build the ordinary-clone fixture"
  make_backend_stub "$dir" fm-unx
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"

  # The copy is an ordinary clone (refused by the linked-worktree proof); the
  # temp root is valid and holds nothing at all.
  write_task_meta unx "$clone" "fmses:fm-unx" "$tmproot"

  rc=0
  out=$(run_orphan "$dir" reap unx) || rc=$?
  [ "$rc" != 0 ] \
    || fail "unexamined-clean: a cleanup that never read the copy reported success: $out"
  case "$out" in
    *"nothing to stop for unx"*) fail "unexamined-clean: a task with an unread root was reported as having nothing to stop: $out" ;;
  esac
  case "$out" in
    *"copy=$clone"*) ;;
    *) fail "unexamined-clean: the refusal did not name the root that was never examined: $out" ;;
  esac

  rm -f "$HOME_DIR/state/unx.meta"
  rm -rf "$clone" "$tmproot"
  pass "a reap whose record names a root it never examined refuses instead of reporting the task clean"
}

# TWO REFUSALS ARE TWO FACTS TOO. The copy-refusal branch used to choose the
# return status from inside itself, before the temp-root refusal had been
# recorded or printed, so a record whose BOTH roots were refused reported only
# the copy. bin/fm-session-start.sh captures this stdout for the digest, so the
# second unexamined root never reached the operator at all; they corrected the
# copy, reran, and met the temp-root refusal for the first time.
test_two_refused_roots_are_both_reported() {
  local dir clone foreign out rc
  dir="$TMP_ROOT/case-both-refused"
  clone="$TMP_ROOT/clone-both-refused"
  foreign="$FM_TASK_TMP_ROOT/fm-NOTMINE"
  mkdir -p "$dir" "$foreign"
  git clone --quiet "$PRIMARY" "$clone" 2>/dev/null \
    || fail "both-refused: could not build the ordinary-clone fixture"
  make_backend_stub "$dir" fm-br
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"

  # Copy: an ordinary clone, refused by the linked-worktree proof.
  # Temp root: exists, but is not THIS task's own, so its binding refuses it.
  write_task_meta br "$clone" "fmses:fm-br" "$foreign"

  rc=0
  out=$(run_orphan "$dir" scan --task br) || rc=$?
  [ "$rc" = 3 ] || fail "both-refused: a scan that examined nothing exited $rc: $out"
  case "$out" in
    *"UNSCANNABLE: br copy=$clone"*) ;;
    *) fail "both-refused: the refused copy was not reported: $out" ;;
  esac
  # The assertion this case exists for.
  case "$out" in
    *"UNSCANNABLE: br tasktmp=$foreign"*) ;;
    *) fail "both-refused: the second refused root never reached the report: $out" ;;
  esac

  rc=0
  out=$(run_orphan "$dir" reap br) || rc=$?
  [ "$rc" != 0 ] || fail "both-refused: a cleanup that examined nothing reported success: $out"
  case "$out" in
    *"copy=$clone"*) ;;
    *) fail "both-refused: the cleanup did not name the refused copy: $out" ;;
  esac
  case "$out" in
    *"tasktmp=$foreign"*) ;;
    *) fail "both-refused: the cleanup did not name the refused temp root: $out" ;;
  esac

  rm -f "$HOME_DIR/state/br.meta"
  rm -rf "$clone" "$foreign"
  pass "a record whose two recorded roots are both refused reports both, not just the copy"
}

# A DECISION NOT TO TOUCH WHAT WAS FOUND IS NOT AN EMPTY COPY. The living-owner
# path returns after the collect found processes, so telling the operator that
# "nothing was found in the roots that could be examined" is false - and it
# replaced the verdict that actually decided the outcome with an instruction to
# edit the record and rerun, which changes nothing about a live worker.
test_a_living_owner_is_not_reported_as_an_empty_copy() {
  local dir foreign out rc pid
  dir="$TMP_ROOT/case-alive-unexamined"
  foreign="$FM_TASK_TMP_ROOT/fm-NOTMINE-ALIVE"
  mkdir -p "$dir" "$foreign"
  make_backend_stub "$dir" fm-al
  make_crew_state_stub "$dir"
  printf 'alive' > "$dir/agent"

  pid=$(witness "$COPY")
  # A valid copy holding a live process, plus a temp root the record names and
  # validation refuses.
  write_task_meta al "$COPY" "fmses:fm-al" "$foreign"

  rc=0
  out=$(run_orphan "$dir" reap al) || rc=$?
  case "$out" in
    *"nothing was found in the roots"*) fail "alive-unexamined: a copy holding live processes was reported as empty: $out" ;;
  esac
  case "$out" in
    *"living owner"*) ;;
    *) fail "alive-unexamined: the verdict that decided the outcome was not stated: $out" ;;
  esac
  # The unexamined root is still worth saying - as a separate fact, not the cause.
  case "$out" in
    *"tasktmp=$foreign"*) ;;
    *) fail "alive-unexamined: the unexamined root stopped being reported: $out" ;;
  esac

  sleep 0.3
  alive "$pid" || fail "alive-unexamined: a live worker's process was stopped"
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$HOME_DIR/state/al.meta"
  rm -rf "$foreign"
  pass "a task left alone because its worker is alive says so, instead of claiming its roots were empty"
}

# TWO UNEXAMINED ROOTS ARE TWO FACTS. A refused copy and a temp root this host
# cannot list have different repairs - correct the record, versus inspect the
# path by hand - so a message that reported only the first sent the operator to
# fix the record and hit the second, unrelated failure on the rerun.
test_a_reap_names_every_root_it_could_not_examine() {
  local dir clone tmproot out rc pid
  dir="$TMP_ROOT/case-two-unexamined"
  clone="$TMP_ROOT/clone-two-unexamined"
  tmproot="$FM_TASK_TMP_ROOT/fm-two"
  mkdir -p "$dir/fakebin" "$tmproot"
  git clone --quiet "$PRIMARY" "$clone" 2>/dev/null \
    || fail "two-unexamined: could not build the ordinary-clone fixture"
  make_backend_stub "$dir" fm-two
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"

  pid=$(witness "$tmproot")
  write_task_meta two "$clone" "fmses:fm-two" "$tmproot"

  # The copy is refused, and no cwd source can list the temp root either.
  cat > "$dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: synthetic failure" >&2
exit 1
SH
  chmod +x "$dir/fakebin/lsof"
  export FM_PROC_ROOT_OVERRIDE="$dir/no-proc"

  rc=0
  out=$(run_orphan "$dir" reap two) || rc=$?
  [ "$rc" != 0 ] || fail "two-unexamined: a cleanup that examined nothing reported success: $out"
  case "$out" in
    *"copy=$clone"*) ;;
    *) fail "two-unexamined: the refused copy was not named: $out" ;;
  esac
  case "$out" in
    *"tasktmp=$tmproot"*) ;;
    *) fail "two-unexamined: the root the host could not list was hidden behind the copy refusal: $out" ;;
  esac

  unset FM_PROC_ROOT_OVERRIDE
  rm -f "$dir/fakebin/lsof"
  sleep 0.3
  alive "$pid" || fail "two-unexamined: a process was stopped by a cleanup that could not look"
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$HOME_DIR/state/two.meta"
  rm -rf "$clone" "$tmproot"
  pass "a reap that could not examine two roots names both, with what is wrong with each"
}

# THE ROOT A LISTING BROKE ON IS NAMED BY IDENTITY, NOT BY POSITION. The
# collect-failure line used to take `roots[0]` and call it the copy. Once a copy
# can be missing from that set - gone, or refused - the survivor is the temp
# root, so a host that cannot list anything reported `copy=/tmp/fm-<id>` for a
# task with no copy on disk at all, sending the operator to inspect a directory
# that is not what the line said it was.
test_an_unlistable_root_is_named_for_what_it_is() {
  local dir tmproot out rc pid
  dir="$TMP_ROOT/case-failed-root-label"
  tmproot="$FM_TASK_TMP_ROOT/fm-flr"
  mkdir -p "$dir/fakebin" "$tmproot"
  make_backend_stub "$dir" fm-flr
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"

  pid=$(witness "$tmproot")
  # The copy is gone, so the temp root is the only entry in the collected set.
  write_task_meta flr "$TMP_ROOT/copy-gone-for-failed-label" "fmses:fm-flr" "$tmproot"

  # Neither cwd source can answer, so the listing itself fails.
  cat > "$dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: synthetic failure" >&2
exit 1
SH
  chmod +x "$dir/fakebin/lsof"
  export FM_PROC_ROOT_OVERRIDE="$dir/no-proc"

  rc=0
  out=$(run_orphan "$dir" scan --task flr) || rc=$?
  [ "$rc" = 3 ] || fail "failed-root-label: an unlistable root did not exit 3: $out"
  case "$out" in
    *"copy=$tmproot"*) fail "failed-root-label: the temp root was reported under a copy= label: $out" ;;
  esac
  case "$out" in
    *"UNSCANNABLE: flr tasktmp=$tmproot"*) ;;
    *) fail "failed-root-label: the unlistable temp root was not named as a temp root: $out" ;;
  esac

  rc=0
  out=$(run_orphan "$dir" reap flr) || rc=$?
  [ "$rc" != 0 ] || fail "failed-root-label: a cleanup that could not look reported success: $out"
  case "$out" in
    *"tasktmp=$tmproot"*) ;;
    *) fail "failed-root-label: the cleanup refusal did not name the root it could not read: $out" ;;
  esac

  unset FM_PROC_ROOT_OVERRIDE
  rm -f "$dir/fakebin/lsof"
  sleep 0.3
  alive "$pid" || fail "failed-root-label: a process was stopped by a scan that could not resolve anything"
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$HOME_DIR/state/flr.meta"
  rm -rf "$tmproot"
  pass "the root a listing broke on is named for what it is, never as the copy by position"
}

# A REFUSAL NARROWS THE REPORT, NEVER THE SCAN - the rule the temp-root side has
# always kept, applied to the copy. A refused copy used to abandon the whole root
# set, so a temp root that passed the strictest validator in the library, and held
# a live leaked process, was never looked at: the digest gave the operator no
# signal it was leaking and the reap stopped nothing.
test_a_refused_copy_still_scans_the_temp_root() {
  local dir clone tmproot out rc pid
  dir="$TMP_ROOT/case-refused-copy-tmp"
  clone="$TMP_ROOT/clone-refused-with-tmp"
  tmproot="$FM_TASK_TMP_ROOT/fm-rct"
  mkdir -p "$dir" "$tmproot"
  git clone --quiet "$PRIMARY" "$clone" 2>/dev/null \
    || fail "refused-copy-tmp: could not build the ordinary-clone fixture"
  make_backend_stub "$dir" fm-rct
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"

  pid=$(witness "$tmproot")
  write_task_meta rct "$clone" "fmses:fm-rct" "$tmproot"

  rc=0
  out=$(run_orphan "$dir" scan --task rct) || rc=$?
  # The copy is still reported as unexamined ...
  case "$out" in
    *"UNSCANNABLE: rct"*"$clone"*) ;;
    *) fail "refused-copy-tmp: the refused copy stopped being reported: $out" ;;
  esac
  # ... and the temp root the record also names was scanned anyway.
  case "$out" in
    *"LEFTOVER: rct"*"$pid"*) ;;
    *) fail "refused-copy-tmp: a live process in a valid temp root was never found because the copy was refused: $out" ;;
  esac

  out=$(run_orphan "$dir" reap rct)
  case "$out" in
    *"recorded local copy"*"was refused"*) ;;
    *) fail "refused-copy-tmp: the cleanup did not say it had covered less than the record names: $out" ;;
  esac
  sleep 0.3
  alive "$pid" && fail "refused-copy-tmp: the leaked process in the valid temp root was not stopped"

  rm -f "$HOME_DIR/state/rct.meta"
  rm -rf "$clone" "$tmproot"
  pass "a refused local copy is reported without stopping the scan of a temp root that is valid"
}

# The other half of the split: an absence is not a refusal. A record that names
# no copy at all named nothing that went unexamined, so it must stay silent -
# alerting on it would put every such record into the digest at every session
# start, which is how a report stops being read.
test_a_record_that_names_no_copy_raises_no_alert() {
  local dir out rc
  dir="$TMP_ROOT/case-no-copy"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-nc
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  write_task_meta nc "" "fmses:fm-nc"

  rc=0
  out=$(run_orphan "$dir" scan --task nc) || rc=$?
  case "$out" in
    *UNSCANNABLE*) fail "no-copy: a record that names no local copy raised an unexamined-root alert: $out" ;;
  esac
  [ "$rc" = 0 ] || fail "no-copy: a record with no copy exited $rc rather than reporting nothing"
  rm -f "$HOME_DIR/state/nc.meta"
  pass "a record that names no local copy stays silent instead of alerting on an absence"
}

# A mistyped or unmounted FM_HOME must refuse, not be created and then reported
# as an examined, clean fleet. bin/fm-wake-lib.sh runs mkdir -p "$STATE" at
# source time, so the guard has to stand in front of the sources, not after.
test_a_missing_state_directory_refuses_instead_of_being_created() {
  local missing out rc
  missing="$TMP_ROOT/never-mounted/state"
  rm -rf "$TMP_ROOT/never-mounted"

  rc=0
  out=$(env PATH="$PATH" FM_HOME="$TMP_ROOT/never-mounted" \
    FM_STATE_OVERRIDE="$missing" "$ORPHAN" scan 2>&1) || rc=$?
  [ "$rc" != 0 ] \
    || fail "missing-state: a scan of a home that does not exist reported a clean fleet: $out"
  case "$out" in
    *"state directory"*) ;;
    *) fail "missing-state: the refusal did not name the missing state directory: $out" ;;
  esac
  [ ! -e "$missing" ] \
    || fail "missing-state: the scan created the state directory it was supposed to refuse"
  pass "a state directory that is not there refuses the scan instead of being created and called clean"
}

# $STATE/<id>.meta and $FM_TASK_TMP_ROOT/fm-<id> are both built from the task id,
# so it is checked before either is - the one input check this verb was missing
# relative to every sibling entrypoint.
test_a_task_id_that_escapes_the_home_is_refused() {
  local out rc
  rc=0
  out=$(run_orphan "$TMP_ROOT" reap "../../elsewhere/t1") || rc=$?
  [ "$rc" != 0 ] || fail "bad-id: a traversing task id was accepted: $out"
  case "$out" in
    *"invalid task id"*) ;;
    *) fail "bad-id: the refusal did not name the invalid task id: $out" ;;
  esac

  rc=0
  out=$(run_orphan "$TMP_ROOT" scan --task "../../elsewhere/t1") || rc=$?
  [ "$rc" != 0 ] || fail "bad-id: a traversing task id was accepted by scan: $out"
  case "$out" in
    *"invalid task id"*) ;;
    *) fail "bad-id: the scan refusal did not name the invalid task id: $out" ;;
  esac
  pass "a task id that would escape the home is refused before any path is built from it"
}

test_a_temp_root_that_no_longer_exists_is_not_reported_unscannable() {
  local dir copy out rc pid_in_copy gone
  dir="$TMP_ROOT/case-gone-tmp"
  copy="$TMP_ROOT/copy-gone-tmp"
  gone="$FM_TASK_TMP_ROOT/fm-gonetmp"
  mkdir -p "$dir"
  rm -rf "$gone"
  git -C "$PRIMARY" worktree add --quiet -b gone-tmp "$copy"
  make_backend_stub "$dir" fm-gonetmp
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"

  pid_in_copy=$(witness "$copy")
  # The recorded temp root is the one fm-spawn WOULD have built for this task,
  # so nothing but its absence can account for the outcome.
  write_task_meta gonetmp "$copy" "fmses:fm-gonetmp" "$gone"

  rc=0
  out=$(run_orphan "$dir" scan) || rc=$?
  case "$out" in
    *UNSCANNABLE*) fail "gone-tmp: a temp root that simply does not exist was reported as unexaminable: $out" ;;
  esac
  case "$out" in
    *"no reason was given"*) fail "gone-tmp: a report line was emitted with no reason behind it: $out" ;;
  esac
  [ "$rc" = 0 ] \
    || fail "gone-tmp: an absent temp root made the scan exit $rc, as though the fleet had gone unexamined"
  # The copy itself is still scanned and still reported, so this case cannot
  # pass by the whole task being dropped.
  case "$out" in
    *"LEFTOVER: gonetmp"*"$pid_in_copy"*) ;;
    *) fail "gone-tmp: the copy's own leftover stopped being reported: $out" ;;
  esac

  # The control: the SAME record, with that path present but not this task's
  # own, is a genuine refusal and must still be reported.
  mkdir -p "$TMP_ROOT/elsewhere-gone/fm-gonetmp"
  write_task_meta gonetmp "$copy" "fmses:fm-gonetmp" "$TMP_ROOT/elsewhere-gone/fm-gonetmp"
  rc=0
  out=$(run_orphan "$dir" scan) || rc=$?
  case "$out" in
    *"UNSCANNABLE: gonetmp"*) ;;
    *) fail "gone-tmp: a present-but-refused temp root stopped being reported: $out" ;;
  esac
  [ "$rc" = 3 ] \
    || fail "gone-tmp: a genuinely unexamined root no longer makes the scan exit 3 (got $rc)"

  kill -KILL "$pid_in_copy" 2>/dev/null || true
  rm -f "$HOME_DIR/state/gonetmp.meta"
  pass "a temp root that no longer exists is not reported as unexaminable, while a present-but-refused one still is"
}

# --- 12b2. "is it there", never "may I signal it" ----------------------------
#
# The library's own rule, stated in its header: liveness here means existence,
# because `kill -0` answers whether the caller MAY signal the process. Another
# user's process fails that probe while being very much alive, and dropping it
# would let a teardown remove a copy with a live foreign process still running
# in it. Both resolver arms ask through _fm_wtproc_pid_exists for that reason.

test_liveness_asks_whether_a_pid_exists_not_whether_it_may_be_signalled() {
  local lib out
  lib="$ROOT/bin/fm-worktree-proc-lib.sh"
  if [ "$(id -u)" = 0 ]; then
    pass "running as root, where the two probes cannot disagree; nothing to prove here"
    return 0
  fi

  # pid 1 is alive and owned by another user. Nothing is signalled: both probes
  # below are read-only questions about it.
  out=$(bash -c '
    . "$1"
    if fm_pid_alive 1; then printf "signalprobe=yes "; else printf "signalprobe=no "; fi
    if _fm_wtproc_pid_exists 1; then printf "exists=yes"; else printf "exists=no"; fi
  ' _ "$lib" 2>/dev/null || true)

  case "$out" in
    "signalprobe=no exists=yes") ;;
    "signalprobe=yes "*)
      pass "this host lets the signal probe answer for another user's process, so the two cannot be told apart here"
      return 0
      ;;
    *)
      fail "liveness-probe: a live process owned by another user was not seen as existing ($out); the scan would drop it and a teardown could remove a copy with it still running" ;;
  esac

  pass "liveness asks whether a pid exists, not whether the caller may signal it"
}

# --- 12c. the scanner never reports its own helpers as leftovers -------------
#
# A scan is itself a process tree. Taking the machine listing needs command
# substitutions, and those subshells inherit the caller's working directory, so
# a scan run from INSIDE the copy being scanned - where an operator naturally
# stands - finds its own helpers sitting in that copy and reports them as
# leftovers. They have already exited by the time anything reads the result.
# A scanner that reports its own helpers discredits every line it prints, which
# is the same disease as the false alarms removed in the previous round.
#
# The fix must be a liveness test at collection, NOT a descendant walk: a
# genuine leftover is frequently a descendant of the shell the cleanup is run
# from, and excluding by descent would hide exactly what this exists to find.

test_a_scan_from_inside_a_copy_never_reports_its_own_helpers() {
  local dir copy out rc pid
  dir="$TMP_ROOT/case-self-noise"
  copy="$TMP_ROOT/copy-self-noise"
  mkdir -p "$dir"
  git -C "$PRIMARY" worktree add --quiet -b self-noise "$copy"
  make_backend_stub "$dir" fm-selfnoise
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  printf 'done' > "$dir/crew"
  write_task_meta selfnoise "$copy" "fmses:fm-selfnoise"

  # The copy is EMPTY: anything reported for it can only have come from the
  # scanner's own process tree.
  rc=0
  out=$(cd "$copy" && run_orphan "$dir" scan --task selfnoise) || rc=$?
  case "$out" in
    *"LEFTOVER: selfnoise"*)
      fail "self-noise: a scan run from inside an empty copy reported its own helpers as leftovers: $out" ;;
  esac
  case "$out" in
    *selfnoise*)
      fail "self-noise: an empty copy was reported at all when the scan ran from inside it: $out" ;;
  esac

  # The control: a REAL leftover in that copy is still found by the same
  # inside-the-copy scan, so the fix cannot have been "report nothing".
  pid=$(witness "$copy")
  out=$(cd "$copy" && run_orphan "$dir" scan --task selfnoise)
  case "$out" in
    *"LEFTOVER: selfnoise"*"$pid"*) ;;
    *) fail "self-noise: a real leftover stopped being found by a scan run from inside the copy: $out" ;;
  esac

  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$HOME_DIR/state/selfnoise.meta"
  pass "a scan run from inside a copy reports no helpers of its own, and still finds a real leftover there"
}

# --- 12d. a correct answer is never reported as a failed scan ----------------
#
# The liveness recheck above sits at the end of the case, of the while body, and
# of the function, so writing it as `test && printf` makes a failing test the
# function's own exit status: it reports FAILURE having produced a perfectly
# correct answer. Callers do not treat that lightly - teardown refuses and
# preserves a copy it should have cleaned, and the sweep calls a copy it read
# correctly unexaminable - and the trigger is the very thing the recheck exists
# for, a process that exits between the listing and the read, so it fires
# routinely rather than rarely.
#
# Reproduced deterministically: a held snapshot keeps a listing whose LAST
# matching entry names a pid whose directory has since gone.

test_a_scan_whose_last_entry_has_exited_still_reports_success() {
  local lib out rc
  lib="$ROOT/bin/fm-worktree-proc-lib.sh"

  out=$(bash -c '
    set -u
    lib=$1; base=$2
    root="$base/proc"; copy="$base/copy"
    mkdir -p "$root/100" "$root/200" "$copy"
    # The self-test needs one resolving cwd link; `self` is not matched by the
    # listing glob, so it never becomes a scan candidate itself.
    mkdir -p "$root/self"
    ln -s "$PWD" "$root/self/cwd"
    ln -s "$copy" "$root/100/cwd"
    ln -s "$copy" "$root/200/cwd"
    export FM_PROC_ROOT_OVERRIDE="$root"
    . "$lib"
    # Hold ONE listing across both calls, so the second is answered from an
    # instant at which 200 was still there.
    fm_wtproc_snapshot_begin
    fm_wtproc_pids_under "$copy" >/dev/null || { echo "SETUP-FAILED"; exit 0; }
    # 200 sorts last among the matching entries, so its disappearance lands on
    # the final iteration - the one whose status the function returns.
    rm -rf "${root:?}/200"
    pids=$(fm_wtproc_pids_under "$copy"); rc=$?
    fm_wtproc_snapshot_end
    printf "rc=%s pids=%s" "$rc" "$(echo $pids | tr "\n" ",")"
  ' _ "$lib" "$TMP_ROOT/case-last-exited" 2>/dev/null || true)

  case "$out" in
    *SETUP-FAILED*)
      fail "last-exited: the fixture could not produce a first successful scan, so this case proves nothing" ;;
  esac
  case "$out" in
    "rc=0 pids=100"*) ;;
    *) fail "last-exited: a scan that produced a correct answer did not report success: $out" ;;
  esac

  pass "a scan whose last listed process has exited still reports success, and still returns the live one"
}

# --- 13. the resolver self-test runs once per observation, not once per root --

test_the_resolver_self_test_is_not_repeated_for_every_root() {
  local lib probe out baseline
  lib="$ROOT/bin/fm-worktree-proc-lib.sh"
  baseline=$(bash -c '. "$1"; fm_wtproc_resolver' _ "$lib" 2>/dev/null || true)
  if [ "$baseline" != proc ]; then
    pass "this host does not answer from /proc; the self-test this case counts is not the one that runs"
    return 0
  fi

  probe="$TMP_ROOT/resolver-probe.count"
  : > "$probe"
  mkdir -p "$TMP_ROOT/r1" "$TMP_ROOT/r2" "$TMP_ROOT/r3"

  # The expensive half of the resolver self-test is stubbed to COUNT its calls
  # and answer the same way it would have. One observation over three roots must
  # settle the source once; the count is the whole assertion, because a memo
  # that is discarded with a subshell is invisible in the scan's own output.
  out=$(FM_WTPROC_RESOLVER_PROBE="$probe" bash -c '
    . "$1"
    _fm_wtproc_proc_lists_cwd_entries() { echo x >> "$FM_WTPROC_RESOLVER_PROBE"; return 0; }
    fm_wtproc_collect "$2" "$3" "$4" >/dev/null 2>&1
    printf %s "${_FM_WTPROC_RESOLVER:-EMPTY}"
  ' _ "$lib" "$TMP_ROOT/r1" "$TMP_ROOT/r2" "$TMP_ROOT/r3" 2>/dev/null || true)

  [ "$out" = proc ] \
    || fail "resolver-memo: the collect left the resolver unsettled in its own shell (got '$out')"

  local count
  count=$(wc -l < "$probe" | tr -d ' ')
  [ "$count" = 1 ] \
    || fail "resolver-memo: the resolver self-test ran $count times for one observation over three roots; the memo is being discarded"

  pass "the resolver self-test runs once for a whole observation, not once per scanned root"
}

# --- 11. a recorded root the validation refuses is never silently dropped -----
#
# Refusing the root is correct; reporting on the remaining roots as though the
# record had named no other is not. The scan would then cover strictly less than
# the record claims while reading exactly like a clean copy.

test_a_refused_recorded_root_is_reported_rather_than_dropped() {
  local dir copy elsewhere out rc pid_elsewhere pid_in_copy
  dir="$TMP_ROOT/case-refused-root"
  copy="$TMP_ROOT/copy-refused-root"
  elsewhere="$TMP_ROOT/elsewhere-tmp/fm-rr"
  mkdir -p "$dir" "$elsewhere"
  git -C "$PRIMARY" worktree add --quiet -b refused-root "$copy"
  make_backend_stub "$dir" fm-rr
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"

  pid_elsewhere=$(witness "$elsewhere")
  pid_in_copy=$(witness "$copy")
  # Correctly named for this task, but not the path fm-spawn would have built
  # for it ($FM_TASK_TMP_ROOT/fm-rr), so fm_wtproc_task_tmp refuses it.
  write_task_meta rr "$copy" "fmses:fm-rr" "$elsewhere"

  rc=0
  out=$(run_orphan "$dir" scan --task rr) || rc=$?
  case "$out" in
    *"UNSCANNABLE: rr"*"$elsewhere"*) ;;
    *) fail "refused-root: a refused recorded root was dropped without a trace: $out" ;;
  esac
  # It is the TEMP root that was refused, and the line has to say so: the legend
  # this report prints tells the reader copy= is the task's local copy, and this
  # task's copy is a different path that scanned fine.
  case "$out" in
    *"copy=$elsewhere"*) fail "refused-root: the refused temp root was reported under a copy= label: $out" ;;
  esac
  case "$out" in
    *"tasktmp=$elsewhere"*) ;;
    *) fail "refused-root: the refused temp root was not named as a temp root: $out" ;;
  esac
  [ "$rc" = 3 ] \
    || fail "refused-root: a scan with an unexamined root exited $rc, so a caller reading only the status sees a clean fleet"
  case "$out" in
    *"$pid_elsewhere"*) fail "refused-root: a process under the refused root was attributed to the task: $out" ;;
  esac
  case "$out" in
    *"LEFTOVER: rr"*"$pid_in_copy"*) ;;
    *) fail "refused-root: the roots that WERE examined stopped being reported: $out" ;;
  esac

  out=$(run_orphan "$dir" reap rr)
  case "$out" in
    *"recorded temp root"*"was refused"*) ;;
    *) fail "refused-root: the cleanup did not say it had covered less than the record names: $out" ;;
  esac
  sleep 0.3
  alive "$pid_elsewhere" || fail "refused-root: a process under the refused root was stopped"
  alive "$pid_in_copy" && fail "refused-root: the examined root was not cleaned, so this case proves nothing"

  kill -KILL "$pid_elsewhere" 2>/dev/null || true
  rm -f "$HOME_DIR/state/rr.meta"
  git -C "$PRIMARY" worktree remove --force "$copy" 2>/dev/null || true
  pass "a recorded root the validation refuses is reported as unexamined instead of quietly narrowing the scan"
}

# --- 12. a cleanup never signals the shell it was started from ---------------
#
# `cd <home>/worktrees/fm-x1 && ... reap x1` is how the stuck-crewmate recovery
# reaches a wedged copy, and that shell's working directory is inside the copy
# like any leftover's. The endpoint spare names one pid, so it cannot cover a
# chain.

test_a_cleanup_never_signals_the_shell_it_was_started_from() {
  local dir copy out pane leftover
  dir="$TMP_ROOT/case-invoker"
  copy="$TMP_ROOT/copy-invoker"
  mkdir -p "$dir"
  git -C "$PRIMARY" worktree add --quiet -b invoker "$copy"
  make_backend_stub "$dir" fm-inv
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  # A real, live pid for the endpoint's own shell, so the selection runs on the
  # numeric-spare arm and the invoking shell is a different number entirely.
  pane=$(witness "$TMP_ROOT")
  printf '%s' "$pane" > "$dir/panepid"

  leftover=$(witness "$copy")
  write_task_meta inv "$copy" "fmses:fm-inv"

  # The subshell IS the invoker: its working directory is inside the copy, and
  # it only reaches the marker if it outlived the cleanup it started.
  out=$(cd "$copy" && run_orphan "$dir" reap inv && printf 'INVOKER-ALIVE\n')
  case "$out" in
    *INVOKER-ALIVE*) ;;
    *) fail "invoker: the shell the cleanup was started from did not survive it: $out" ;;
  esac
  sleep 0.3
  alive "$leftover" && fail "invoker: the leftover was not stopped, so this case proves nothing"
  alive "$pane" || fail "invoker: the recorded endpoint's own shell was stopped"

  kill -KILL "$pane" 2>/dev/null || true
  rm -f "$HOME_DIR/state/inv.meta"
  git -C "$PRIMARY" worktree remove --force "$copy" 2>/dev/null || true
  pass "a cleanup started from inside the copy stops the leftovers and never the shell that started it"
}

# --- 13. the ownerless verdict and the stop are one transaction --------------
#
# The reading that authorises a stop is taken from the record and the endpoint;
# the stop itself selects whatever is running under the roots at that moment.
# A relaunch of the same task between the two reuses those exact roots for the
# REPLACEMENT worker, so a reap that did not hold the task's lifecycle lock
# would TERM and KILL the live incarnation it exists never to touch. This holds
# the same lock bin/fm-control.sh's relaunch holds across stop-and-restart, from
# a separate live process, and pins the reap refusing rather than signalling.

test_a_lifecycle_action_in_flight_blocks_the_stop() {
  local dir pid out rc lock holder i
  dir="$TMP_ROOT/case-lifecycle-lock"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-lck
  make_crew_state_stub "$dir"
  # Every other gate open: the agent reads gone and both sources agree, so the
  # only thing that can refuse this cleanup is the contended lock.
  printf 'missing' > "$dir/agent"

  pid=$(witness "$COPY")
  write_task_meta lck "$COPY" "fmses:fm-lck"

  lock="$HOME_DIR/state/.control-lck.lock"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  i=0
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || {
    kill "$holder" 2>/dev/null || true
    fail "lifecycle-lock: could not stage a held control lock"
  }

  rc=0
  out=$(run_orphan "$dir" reap lck) || rc=$?
  if [ "$rc" = 0 ]; then
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "lifecycle-lock: the reap ran while a lifecycle action held this task's lock: $out"
  fi
  case "$out" in
    *"another lifecycle action is already running"*) ;;
    *)
      kill "$holder" 2>/dev/null || true
      wait "$holder" 2>/dev/null || true
      fail "lifecycle-lock: the refusal did not name the concurrent action: $out"
      ;;
  esac
  sleep 0.3
  alive "$pid" || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "lifecycle-lock: a process was stopped while a relaunch could have owned it"
  }

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  # Same fixture, same process: only the contention is gone, so the case is
  # proven to hinge on the lock and not on anything else in it.
  out=$(run_orphan "$dir" reap lck) \
    || fail "lifecycle-lock: the reap did not run once the lock was free: $out"
  sleep 0.3
  alive "$pid" && fail "lifecycle-lock: the leftover survived an uncontended cleanup"
  [ ! -e "$lock" ] || fail "lifecycle-lock: the reap left this task's control lock behind"

  rm -f "$HOME_DIR/state/lck.meta"
  pass "a reap refuses while another lifecycle action holds the task's control lock, and releases it afterwards"
}

test_only_a_linked_worktree_is_a_disposable_copy
test_the_projects_wall_follows_fm_projects_override
test_a_process_in_a_disposable_copy_is_found_and_stopped
test_a_primary_checkout_is_never_a_target
test_a_live_workers_processes_are_never_stopped
test_a_disagreeing_current_state_vetoes_the_verdict
test_an_undetermined_current_state_never_authorises_a_stop
test_an_undetermined_agent_state_is_never_reported_as_a_clean_copy
test_a_runtime_with_no_classifier_raises_no_alert_but_still_refuses_a_stop
test_a_reader_that_could_not_answer_is_not_a_disagreement
test_an_unreadable_working_directory_leaves_the_process_alone
test_only_the_recorded_endpoint_shell_is_spared
test_an_unnameable_endpoint_shell_holds_leaders_back_and_says_how_many
test_a_copy_with_only_unclassifiable_leaders_is_never_reported_clean
test_a_temp_root_in_the_operators_tree_is_never_a_reap_root
test_a_temp_root_outside_the_recorded_path_is_refused
test_the_reap_distinguishes_a_scan_that_broke_before_a_signal_from_one_after
test_a_scan_that_breaks_between_selecting_and_signalling_names_the_root
test_a_process_that_outlives_the_force_stop_is_never_reported_stopped
test_a_copy_this_host_cannot_list_is_never_reported_clean
test_a_removed_working_directory_does_not_make_the_host_unanswerable
test_each_collect_looks_at_the_machine_again
test_a_listing_that_cannot_be_produced_is_never_an_empty_machine
test_a_reap_that_never_selects_reports_nothing_from_the_copy_before_it
test_an_undetermined_copy_keeps_its_label_when_everything_is_held_back
test_a_refused_recorded_root_is_reported_rather_than_dropped
test_an_unlistable_root_is_named_for_what_it_is
test_a_reap_never_reports_clean_with_an_unexamined_root
test_a_reap_names_every_root_it_could_not_examine
test_two_refused_roots_are_both_reported
test_a_living_owner_is_not_reported_as_an_empty_copy
test_a_recorded_copy_the_wall_refuses_is_reported_rather_than_dropped
test_a_record_that_names_no_copy_raises_no_alert
test_a_recorded_copy_that_no_longer_exists_raises_no_alert
test_a_refused_copy_still_scans_the_temp_root
test_a_report_line_names_the_root_it_describes
test_a_missing_state_directory_refuses_instead_of_being_created
test_a_task_id_that_escapes_the_home_is_refused
test_a_temp_root_that_no_longer_exists_is_not_reported_unscannable
test_liveness_asks_whether_a_pid_exists_not_whether_it_may_be_signalled
test_a_scan_from_inside_a_copy_never_reports_its_own_helpers
test_a_scan_whose_last_entry_has_exited_still_reports_success
test_the_resolver_self_test_is_not_repeated_for_every_root
test_a_cleanup_never_signals_the_shell_it_was_started_from
test_a_lifecycle_action_in_flight_blocks_the_stop
