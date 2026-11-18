#!/usr/bin/env bash
# tests/ak47-agent-reclaim.test.sh - the reclaim stops only agents nobody uses.
#
# Every agent here is a real process named like a harness (a copy of sleep or
# bash called `pi`), working in a fake worktree of a fake home. The census is
# scoped to this sandbox with AK47_RECLAIM_SCOPE, so the box's real agents are
# never seen. Each test proves both halves: what must stop stops, and what must
# live - a chair, a working agent, a recent task, every *.check.sh monitor -
# is left exactly as it was.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
GUARD="$ROOT/ak47/guards/agent-reclaim.sh"
export AK47_CLASSIFY_LIB=$ROOT/bin/fm-classify-lib.sh

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SANDBOX=
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]}"; do { kill -KILL "$p"; wait "$p"; } 2>/dev/null; done
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}
trap cleanup EXIT
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ak47-reclaim-tests.XXXXXX")
SANDBOX=$(cd "$SANDBOX" && pwd -P)

export AK47_STATE=$SANDBOX/ak47state
export AK47_CACHE=$SANDBOX/cache
export AK47_CONFIG=$SANDBOX/config
export AK47_RECLAIM_SCOPE=$SANDBOX
export AK47_INBOX_CLASS=health
BIN=$SANDBOX/bin
WT=$SANDBOX/wt
mkdir -p "$BIN" "$WT"
cp "$(command -v sleep)" "$BIN/pi"
cp "$(command -v bash)" "$BIN/pi-signed"   # a harness name that can run a script
CONTROL_LOG=$SANDBOX/control.log
cat >"$BIN/fake-fm-control" <<EOF
#!/usr/bin/env bash
# Records the exit request and does not stop anything, so the guard's own
# SIGTERM fallback is what ends the agent, as it does for Orca.
printf '%s %s\n' "\$FM_HOME" "\$*" >>"$CONTROL_LOG"
exit 0
EOF
chmod +x "$BIN/fake-fm-control"
export AK47_FM_CONTROL=$BIN/fake-fm-control
# A fake no-mistakes: `runs` prints the worktree's .nm-out and exits with its
# .nm-rc, so each test repository states its own validation history. Extra
# arguments such as --limit are accepted, as the real CLI accepts them.
cat >"$BIN/fake-no-mistakes" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = runs ] || exit 2
shift
cat .nm-out 2>/dev/null
exit "$(cat .nm-rc 2>/dev/null || echo 0)"
EOF
chmod +x "$BIN/fake-no-mistakes"
export AK47_NO_MISTAKES=$BIN/fake-no-mistakes
# A fake fm-leave-stopped: `mark` writes the marker the watchdog honours in the
# home FM_HOME names, as the real script does, and logs the call.
MARK_LOG=$SANDBOX/mark.log
cat >"$BIN/fake-leave-stopped" <<EOF
#!/usr/bin/env bash
printf '%s %s %s\n' "\$FM_HOME" "\$1" "\$2" >>"$MARK_LOG"
[ "\$2" = mark ] || exit 2
printf 'schema=fm-leave-stopped.v1\nreason=%s\n' "\$4" >"\$FM_HOME/state/\$1.stopped"
EOF
chmod +x "$BIN/fake-leave-stopped"
export AK47_LEAVE_STOPPED=$BIN/fake-leave-stopped
# A fake gh: `pr view <url>` prints the state stored for that PR number under
# $SANDBOX/gh, and fails when none is stored, as an unreachable gh does.
GH_LOG=$SANDBOX/gh.log
cat >"$BIN/fake-gh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$GH_LOG"
n=\${3##*/}
[ -f "$SANDBOX/gh/\$n" ] || exit 1
cat "$SANDBOX/gh/\$n"
EOF
chmod +x "$BIN/fake-gh"
export AK47_GH=$BIN/fake-gh

reset() {
  local p
  for p in "${PIDS[@]}"; do { kill -KILL "$p"; wait "$p"; } 2>/dev/null; done
  PIDS=()
  rm -rf "$AK47_STATE" "$AK47_CONFIG" "$SANDBOX/homes" "$WT" "$CONTROL_LOG" "$MARK_LOG" "$GH_LOG" "$SANDBOX/gh"
  mkdir -p "$SANDBOX/gh"
  mkdir -p "$AK47_STATE" "$AK47_CONFIG" "$WT"
  cat >"$AK47_CONFIG/devops.conf" <<EOF
reclaim_orphan_min=0
reclaim_idle_min=1440
reclaim_cap_idle_min=360
reclaim_sample_secs=1
reclaim_busy_ticks=5
reclaim_term_wait=5
reclaim_worktree_roots=$WT
EOF
  export FM_HOME=$SANDBOX/homes/main
  make_home main
  : >"$FM_HOME/data/secondmates.md"
}

make_home() {  # <name>
  mkdir -p "$SANDBOX/homes/$1/state" "$SANDBOX/homes/$1/data" "$SANDBOX/homes/$1/config"
}
register_secondmate() {  # <name>
  make_home "$1"
  printf -- '- %s: test home (home: %s; scope: tests)\n' "$1" "$SANDBOX/homes/$1" >>"$FM_HOME/data/secondmates.md"
}

# spawn_agent <dir> [mode] -> sets AGENT to the pid of a process named pi
# working in <dir>. It sets a global rather than printing, because a command
# substitution would wait on the agent's inherited stdout and lose PIDS.
#   idle     sleeps (no children, no CPU)
#   child    runs a child process, like an agent mid-tool-call
#   cpu      burns CPU with no child, like an agent mid-inference
spawn_agent() {
  local dir=$1 mode=${2:-idle} pid
  mkdir -p "$dir"
  case "$mode" in
    idle) (cd "$dir" && exec "$BIN/pi" 600) </dev/null >/dev/null 2>&1 & pid=$! ;;
    child) (cd "$dir" && exec "$BIN/pi-signed" -c 'sleep 600 & wait') </dev/null >/dev/null 2>&1 & pid=$! ;;
    cpu) (cd "$dir" && exec "$BIN/pi-signed" -c 'while :; do :; done') </dev/null >/dev/null 2>&1 & pid=$! ;;
  esac
  PIDS+=("$pid")
  # Wait for the exec, so the census sees the harness name and not a subshell.
  local _
  for _ in $(seq 1 50); do
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in pi|pi-signed) break ;; esac
    sleep 0.05
  done
  [ "$mode" = child ] && sleep 0.2
  AGENT=$pid
}

# add_task <home> <id> <status-age> [backend] -> a task record whose worktree
# is $WT/<id>; status-age is a touch -d offset such as '-30 hours'.
add_task() {
  local h=$SANDBOX/homes/$1 id=$2 age=$3 backend=${4:-}
  {
    echo "worktree=$WT/$id"
    echo "kind=ship"
    [ -n "$backend" ] && echo "backend=$backend"
  } >"$h/state/$id.meta"
  echo "working: test" >"$h/state/$id.status"
  touch -d "$age" "$h/state/$id.status"
  mkdir -p "$WT/$id"
}

# git_task <id> <branch> <runs-output> [rc] -> the task's worktree becomes a
# repository on <branch> whose no-mistakes runs read prints <runs-output>.
git_task() {
  local d=$WT/$1
  git -C "$d" init -q -b "$2" 2>/dev/null || { git -C "$d" init -q && git -C "$d" checkout -q -b "$2"; }
  printf '%s\n' "$3" >"$d/.nm-out"
  echo "${4:-0}" >"$d/.nm-rc"
}

# commit_task <id> [pushed] -> the task's worktree becomes a repository with one
# commit, which a remote-tracking ref covers when pushed is given.
commit_task() {
  local d=$WT/$1
  git -C "$d" init -q
  echo x >"$d/f"
  git -C "$d" add f
  git -C "$d" -c user.name=t -c user.email=t@t commit -q -m one
  [ -n "${2:-}" ] && git -C "$d" update-ref refs/remotes/origin/main HEAD
  return 0
}

alive() { kill -0 "$1" 2>/dev/null && [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" != Z ]; }
run() { "$GUARD" "$@" >"$SANDBOX/out" 2>&1; echo $? >"$SANDBOX/rc"; }

# ---------------------------------------------------------------------------
test_orphan_is_stopped_and_live_task_is_not() {
  reset
  add_task main live-task '-10 minutes'
  local orphan live
  spawn_agent "$WT/fm-gone-task"; orphan=$AGENT
  spawn_agent "$WT/live-task"; live=$AGENT
  run --apply
  [ "$(cat "$SANDBOX/rc")" = 0 ] || fail "orphan run exited $(cat "$SANDBOX/rc"): $(cat "$SANDBOX/out")"
  sleep 0.3
  alive "$orphan" && fail "an agent with no task record in any home was not stopped"
  alive "$live" || fail "an agent of a live, recently reporting task was stopped"
  grep -q "orphan-term pid=$orphan" "$AK47_STATE/reap.log" || fail "orphan stop not recorded with its revert"
  grep -q 'revert:' "$AK47_STATE/reap.log" || fail "reap line carries no revert"
  pass "an orphan agent is stopped and a live task's agent is not"
}

test_dry_run_touches_nothing() {
  reset
  add_task main idle-task '-30 hours'
  local orphan idle
  spawn_agent "$WT/fm-gone-task"; orphan=$AGENT
  spawn_agent "$WT/idle-task"; idle=$AGENT
  echo "done: old" >"$FM_HOME/state/gone.status"
  touch -d '-5 hours' "$FM_HOME/state/gone.status"
  run
  alive "$orphan" || fail "dry run stopped an orphan"
  alive "$idle" || fail "dry run stopped an idle task"
  [ -f "$FM_HOME/state/gone.status" ] || fail "dry run archived a status log"
  [ ! -s "$CONTROL_LOG" ] || fail "dry run called fm-control"
  grep -q 'mode=dry-run' "$AK47_STATE/agent-reclaim.log" || fail "dry run wrote no log line"
  grep -q 'stops=would-2' "$AK47_STATE/agent-reclaim.log" || fail "dry run did not report its two planned stops: $(cat "$AK47_STATE/agent-reclaim.log")"
  pass "the default dry run reports and changes nothing"
}

test_idle_task_stops_through_fm_control_in_its_home() {
  reset
  register_secondmate sm
  add_task sm idle-task '-30 hours'
  add_task sm orca-task '-30 hours' orca
  local idle orca
  spawn_agent "$WT/idle-task"; idle=$AGENT
  spawn_agent "$WT/orca-task"; orca=$AGENT
  run --apply
  sleep 0.3
  grep -q "^$SANDBOX/homes/sm idle-task exit\$" "$CONTROL_LOG" || fail "idle task was not asked to exit through fm-control in its own home: $(cat "$CONTROL_LOG" 2>/dev/null)"
  grep -q orca-task "$CONTROL_LOG" && fail "an Orca task was sent the exit keys Orca cannot deliver"
  alive "$idle" && fail "idle task agent still running after exit and fallback"
  alive "$orca" && fail "Orca idle task agent was not stopped by its SIGTERM fallback"
  [ -f "$SANDBOX/homes/sm/state/idle-task.meta" ] || fail "stopping an idle agent removed its task record"
  [ -d "$WT/idle-task" ] || fail "stopping an idle agent removed its worktree"
  grep -q 'task-stop .*task=orca-task .*how=sigterm' "$AK47_STATE/reap.log" || fail "Orca stop not recorded as sigterm"
  pass "an idle task stops through fm-control in its home, Orca through SIGTERM, record and worktree kept"
}

test_working_agent_is_never_stopped() {
  reset
  add_task main busy-child '-30 hours'
  add_task main busy-cpu '-30 hours'
  local child cpu orphan_working
  spawn_agent "$WT/busy-child" child; child=$AGENT
  spawn_agent "$WT/busy-cpu" cpu; cpu=$AGENT
  spawn_agent "$WT/fm-gone-but-busy" child; orphan_working=$AGENT
  run --apply
  alive "$child" || fail "a day-quiet agent running a tool was stopped"
  alive "$cpu" || fail "a day-quiet agent burning CPU was stopped"
  alive "$orphan_working" || fail "a working agent with no task record was stopped"
  grep -q 'working_kept=3' "$AK47_STATE/agent-reclaim.log" || fail "working agents not counted as kept: $(cat "$AK47_STATE/agent-reclaim.log")"
  [ ! -s "$CONTROL_LOG" ] || fail "fm-control was called for a working agent"
  pass "a working agent - tool child, CPU, or unowned - is never stopped"
}

test_busy_state_and_keep_list_veto() {
  reset
  add_task main busy-state-task '-30 hours'
  add_task main kept-lane '-30 hours'
  add_task main kept-by-meta '-30 hours'
  echo 'v1 gen=g1 seq=1 state=busy source=pi-ext event=agent-start' >"$FM_HOME/state/busy-state-task.busy-state"
  echo 'kept-lane  # monitor lane' >"$AK47_CONFIG/reclaim-keep"
  echo 'reclaim=keep' >>"$FM_HOME/state/kept-by-meta.meta"
  local a b c
  spawn_agent "$WT/busy-state-task"; a=$AGENT
  spawn_agent "$WT/kept-lane"; b=$AGENT
  spawn_agent "$WT/kept-by-meta"; c=$AGENT
  run --apply
  alive "$a" || fail "a task whose busy-state reads busy was stopped"
  alive "$b" || fail "a task on the reclaim-keep list was stopped"
  alive "$c" || fail "a task carrying reclaim=keep was stopped"
  pass "busy-state, the keep list, and reclaim=keep each veto a stop"
}

test_unread_steering_and_running_validation_veto() {
  reset
  local t
  declare -A A=()
  for t in steered validating validated stale unreadable unmanaged; do add_task main "$t" '-30 hours'; done
  mkdir -p "$FM_HOME/state/steered.inbox"
  printf 'schema=fm-task-inbox.v1\n--\nplease rebase\n' >"$FM_HOME/state/steered.inbox/001.msg"
  git_task validating fm/validating '  running      fm/validating 5e9a9c97  2026-11-17 09:15'
  git_task validated fm/validated "  completed    fm/validated 3532408f  2026-11-17 10:48  https://x/pull/1
  running      fm/someone-else 1111111  2026-11-17 10:00"
  git_task stale fm/stale "  completed    fm/stale 3532408f  2026-11-17 10:48  https://x/pull/2
  running      fm/stale 5e9a9c97  2026-11-16 09:15"
  git_task unreadable fm/unreadable 'daemon not reachable' 1
  git_task unmanaged fm/unmanaged "repo not initialized (run 'no-mistakes init' first)" 1
  for t in steered validating validated stale unreadable unmanaged; do spawn_agent "$WT/$t"; A[$t]=$AGENT; done
  run --apply
  sleep 0.3
  alive "${A[steered]}" || fail "a task with an unread steering message was stopped"
  alive "${A[validating]}" || fail "a task whose branch has a running validation was stopped"
  alive "${A[unreadable]}" || fail "a task whose validation state could not be read was stopped"
  alive "${A[validated]}" && fail "a task whose own validation finished was kept because another branch's run is active"
  alive "${A[stale]}" && fail "a task was kept by an old running row below its branch's completed newest row"
  alive "${A[unmanaged]}" && fail "a task in a repository without no-mistakes was kept as if validating"
  for t in steered validating unreadable; do
    grep -q "task=$t " "$AK47_STATE/reap.log" 2>/dev/null && fail "$t has a stop recorded"
  done
  [ -f "$FM_HOME/state/steered.inbox/001.msg" ] || fail "the unread steering message was touched"
  grep -q 'unread steering message' "$AK47_STATE/agent-reclaim-latest.md" || fail "report does not name the steering veto"
  grep -q 'validation running' "$AK47_STATE/agent-reclaim-latest.md" || fail "report does not name the validation veto"
  pass "an unread steering message or an unfinished validation on the task's own branch vetoes a stop"
}

test_over_cap_home_stops_oldest_idle_first() {
  reset
  register_secondmate capped
  echo 1 >"$SANDBOX/homes/capped/config/child-cap"
  add_task capped oldest '-20 hours'
  add_task capped older '-10 hours'
  add_task capped recent '-1 hour'
  add_task capped working '-23 hours'
  local p_oldest p_older p_recent p_working
  spawn_agent "$WT/oldest"; p_oldest=$AGENT
  spawn_agent "$WT/older"; p_older=$AGENT
  spawn_agent "$WT/recent"; p_recent=$AGENT
  spawn_agent "$WT/working" child; p_working=$AGENT
  run --apply
  sleep 0.3
  alive "$p_oldest" && fail "the oldest idle child of an over-cap home was not stopped"
  alive "$p_older" && fail "the next-oldest idle child of an over-cap home was not stopped"
  alive "$p_recent" || fail "a child that reported an hour ago was stopped for the cap"
  alive "$p_working" || fail "a working child was stopped for the cap"
  grep -q 'over_cap=capped:4/1' "$AK47_STATE/agent-reclaim.log" || fail "over-cap home not reported: $(cat "$AK47_STATE/agent-reclaim.log")"
  grep -q 'reclaim-cap-capped-[0-9]* .*holds 2 resident child agents against a cap of 1' "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "a home still over cap after the run filed no finding: $(cat "$AK47_STATE/findings.log" 2>/dev/null)"
  pass "an over-cap home loses its oldest idle children, never a recent or working one, and the rest is a finding"
}

test_box_cap_reads_budget() {
  reset
  add_task main a '-10 hours'
  add_task main b '-8 hours'
  add_task main c '-7 hours'
  local pa pb pc
  spawn_agent "$WT/a"; pa=$AGENT; spawn_agent "$WT/b"; pb=$AGENT; spawn_agent "$WT/c"; pc=$AGENT
  local budget=$SANDBOX/budget.conf
  sed 's/^agent_count|[0-9]*|/agent_count|2|/' "$ROOT/ak47/budget.conf" >"$budget"
  AK47_BUDGET=$budget run --apply
  sleep 0.3
  alive "$pa" && fail "box over its budget cap kept its oldest idle task"
  alive "$pb" || fail "box cap stopped more than it needed"
  alive "$pc" || fail "box cap stopped more than it needed"
  grep -q 'cap=2 ' "$AK47_STATE/agent-reclaim.log" || fail "box cap not read from budget.conf"
  pass "the box-wide cap comes from budget.conf and stops only the oldest excess"
}

test_chairs_and_check_monitors_are_never_touched() {
  reset
  register_secondmate sm
  add_task main old-task '-30 hours'
  # The main chair: a live harness holding the session lock, idle for days.
  local chair sm_chair monitor
  spawn_agent "$FM_HOME"; chair=$AGENT
  echo "$chair" >"$FM_HOME/state/.lock"
  # The secondmate's own agent, recorded in the main home as kind=secondmate.
  printf 'worktree=%s\nkind=secondmate\n' "$SANDBOX/homes/sm" >"$FM_HOME/state/sm.meta"
  spawn_agent "$SANDBOX/homes/sm"; sm_chair=$AGENT
  # Monitors: check scripts, their trust bindings, and a running poll.
  printf '#!/bin/sh\nexit 0\n' >"$FM_HOME/state/x-watch.check.sh"
  printf '#!/bin/sh\nsleep 600\n' >"$FM_HOME/state/old-task.check.sh"
  chmod 700 "$FM_HOME/state/x-watch.check.sh" "$FM_HOME/state/old-task.check.sh"
  echo binding >"$FM_HOME/state/x-watch.check-trust"
  touch -d '-3 days' "$FM_HOME/state/x-watch.check.sh" "$FM_HOME/state/old-task.check.sh" "$FM_HOME/state/x-watch.check-trust"
  (cd "$FM_HOME/state" && exec sh ./old-task.check.sh) </dev/null >/dev/null 2>&1 & monitor=$!
  PIDS+=("$monitor")
  local before
  before=$(cd "$FM_HOME/state" && sha256sum ./*.check.sh ./*.check-trust && stat -c '%n %Y' ./*.check.sh ./*.check-trust)
  run --apply
  alive "$chair" || fail "the main home's chair was stopped"
  alive "$sm_chair" || fail "a secondmate's own agent was stopped"
  alive "$monitor" || fail "a running *.check.sh monitor was stopped"
  [ "$(cd "$FM_HOME/state" && sha256sum ./*.check.sh ./*.check-trust && stat -c '%n %Y' ./*.check.sh ./*.check-trust)" = "$before" ] \
    || fail "a *.check.sh monitor or its trust binding was changed, moved, or removed"
  grep -q 'chairs=2' "$AK47_STATE/agent-reclaim.log" || fail "chairs not counted: $(cat "$AK47_STATE/agent-reclaim.log")"
  pass "chairs, secondmate agents, and every *.check.sh monitor are left exactly as they were"
}

test_orphan_status_logs_move_to_archive() {
  reset
  add_task main kept '-5 hours'
  echo "done: old" >"$FM_HOME/state/gone.status"
  echo "done: cleanup pending" >"$FM_HOME/state/closing.status"
  : >"$FM_HOME/state/closing.backlog-close"
  echo "working: new" >"$FM_HOME/state/fresh.status"
  touch -d '-5 hours' "$FM_HOME/state/gone.status" "$FM_HOME/state/closing.status"
  sed -i 's/^reclaim_orphan_min=.*/reclaim_orphan_min=120/' "$AK47_CONFIG/devops.conf"
  run --apply
  local day
  day=$(date -u +%F)
  [ -f "$FM_HOME/data/orphan-status-archive-$day/gone.status" ] || fail "orphan status log was not archived"
  [ ! -e "$FM_HOME/state/gone.status" ] || fail "orphan status log still tailed in state/"
  [ -f "$FM_HOME/state/kept.status" ] || fail "a live task's status log was archived"
  [ -f "$FM_HOME/state/closing.status" ] || fail "a status log an interrupted cleanup still needs was archived"
  [ -f "$FM_HOME/state/fresh.status" ] || fail "a fresh status log was archived"
  grep -q "status-archive .*task=gone revert: mv" "$AK47_STATE/reap.log" || fail "archive not recorded with its revert"
  pass "orphan status logs move to a dated archive; live, fresh, and closing ones stay"
}

# A fake watcher whose lock records the identity firstmate's own lock writer
# would record, so the guard's identity check is the real one.
make_watcher_lock() {  # <home> <pid>
  local h=$1 pid=$2 lock=$1/state/.watch.lock
  mkdir -p "$lock"
  echo "$pid" >"$lock/pid"
  echo "$h" >"$lock/fm-home"
  echo "$h/bin/fm-watch.sh" >"$lock/watcher-path"
  (
    # shellcheck source=/dev/null # production module, resolved at runtime from $ROOT.
    . "$ROOT/bin/fm-wake-lib.sh" >/dev/null 2>&1
    fm_pid_identity "$pid"
  ) >"$lock/pid-identity"
}

test_dead_chair_watcher_stops_only_after_two_runs() {
  reset
  register_secondmate deadhome
  local h=$SANDBOX/homes/deadhome watcher dead
  sleep 600 >/dev/null 2>&1 & watcher=$!
  PIDS+=("$watcher")
  sleep 0.1
  true & dead=$!; wait "$dead"
  echo "$dead" >"$h/state/.lock"
  make_watcher_lock "$h" "$watcher"
  [ -s "$h/state/.watch.lock/pid-identity" ] || fail "could not record a watcher identity"
  run --apply
  alive "$watcher" || fail "a dead home's watcher was stopped on the first sighting"
  grep -q 'dead_chairs=.*deadhome' "$AK47_STATE/agent-reclaim.log" || fail "dead chair not reported"
  local mark
  mark=$(find "$AK47_STATE/reclaim-chair-dead" -type f 2>/dev/null | head -1)
  [ -n "$mark" ] || fail "first sighting of a dead chair left no mark"
  touch -d '-11 minutes' "$mark"
  run --apply
  sleep 0.3
  alive "$watcher" && fail "a dead home's watcher was not stopped on the second sighting: $(tail -n 2 "$AK47_STATE/agent-reclaim.log"; cat "$SANDBOX/out")"
  grep -q "watcher-stop home=$h pid=$watcher" "$AK47_STATE/reap.log" || fail "watcher stop not recorded"
  pass "a dead home's watcher stops by its recorded pid, only after two sightings ten minutes apart"
}

test_live_chair_watcher_is_never_stopped() {
  reset
  register_secondmate livehome
  local h=$SANDBOX/homes/livehome chair watcher
  spawn_agent "$h"; chair=$AGENT
  echo "$chair" >"$h/state/.lock"
  sleep 600 >/dev/null 2>&1 & watcher=$!
  PIDS+=("$watcher")
  sleep 0.1
  make_watcher_lock "$h" "$watcher"
  mkdir -p "$AK47_STATE/reclaim-chair-dead"
  run --apply
  run --apply
  alive "$watcher" || fail "a live home's watcher was stopped"
  if "$GUARD" --stop-watcher "$h" --apply >"$SANDBOX/out" 2>&1; then
    fail "--stop-watcher stopped the watcher of a home whose chair is alive"
  fi
  alive "$watcher" || fail "--stop-watcher killed a live home's watcher"
  pass "a home whose chair is alive keeps its watcher, from the timer and from --stop-watcher"
}

test_stop_watcher_refuses_mismatched_identity() {
  reset
  register_secondmate deadhome
  local h=$SANDBOX/homes/deadhome watcher other
  sleep 600 >/dev/null 2>&1 & watcher=$!
  sleep 601 >/dev/null 2>&1 & other=$!   # a different process: its identity differs
  PIDS+=("$watcher" "$other")
  sleep 0.1
  echo 999999 >"$h/state/.lock"
  make_watcher_lock "$h" "$other"
  echo "$watcher" >"$h/state/.watch.lock/pid"   # a pid that is not the recorded process
  "$GUARD" --stop-watcher "$h" --apply >"$SANDBOX/out" 2>&1 && fail "--stop-watcher accepted a pid that does not match its recorded identity"
  alive "$watcher" || fail "--stop-watcher killed a process that is not the recorded watcher"
  make_watcher_lock "$h" "$watcher"
  "$GUARD" --stop-watcher "$h" --apply >"$SANDBOX/out" 2>&1 || fail "--stop-watcher refused a dead home's real watcher: $(cat "$SANDBOX/out")"
  sleep 0.3
  alive "$watcher" && fail "--stop-watcher did not stop a dead home's watcher"
  alive "$other" || fail "--stop-watcher stopped a second process"
  "$GUARD" --stop-watcher "$SANDBOX" --apply >/dev/null 2>&1
  [ $? = 2 ] || fail "--stop-watcher accepted a directory that is not a registered home"
  pass "--stop-watcher stops only a registered dead home's watcher whose identity matches"
}

test_health_line_and_children_metric() {
  reset
  register_secondmate sm
  add_task sm one '-1 hour'
  add_task sm two '-1 hour'
  spawn_agent "$WT/one"; spawn_agent "$WT/two"
  printf 'VERDICT: test\nreclaim mode=stale\n' >"$AK47_STATE/health-latest.md"
  run
  [ "$(grep -c '^reclaim ' "$AK47_STATE/health-latest.md")" = 1 ] || fail "health-latest.md does not carry exactly one reclaim line"
  grep -q '^reclaim mode=dry-run' "$AK47_STATE/health-latest.md" || fail "health line not refreshed"
  grep -q '^VERDICT: test' "$AK47_STATE/health-latest.md" || fail "health-latest.md lost its other lines"
  [ "$(cat "$AK47_STATE/agent-reclaim.children")" = 2 ] || fail "children metric not written"
  (
    # shellcheck source=/dev/null # production module, resolved at runtime from $ROOT.
    . "$ROOT/ak47/lib/common.sh"
    [ "$(ak47_metric home_children)" = 2 ] || exit 1
  ) || fail "the home_children budget metric does not read the reclaim's count"
  pass "the run leaves one line in health-latest.md and feeds the home_children budget metric"
}

test_stops_are_marked_left_stopped() {
  reset
  add_task main idle-task '-30 hours'
  local p
  spawn_agent "$WT/idle-task"; p=$AGENT
  run --apply
  sleep 0.3
  alive "$p" && fail "idle task agent still running"
  grep -q "^$FM_HOME idle-task mark\$" "$MARK_LOG" || fail "the stop was not marked left stopped in its own home: $(cat "$MARK_LOG" 2>/dev/null)"
  [ -f "$FM_HOME/state/idle-task.stopped" ] || fail "no state/<id>.stopped marker for the watchdog to honour"
  grep -q 'task-stop .*task=idle-task .*marked=yes .*revert: .*idle-task clear; .*idle-task relaunch' "$AK47_STATE/reap.log" \
    || fail "reap line does not record the mark and its two-step revert: $(tail -n 1 "$AK47_STATE/reap.log")"

  reset
  add_task main idle-task '-30 hours'
  spawn_agent "$WT/idle-task"; p=$AGENT
  AK47_LEAVE_STOPPED=$SANDBOX/missing run --apply
  sleep 0.3
  alive "$p" || fail "a task was stopped although it could not be marked left stopped"
  [ ! -s "$CONTROL_LOG" ] || fail "fm-control was asked to exit a task that could not be marked"
  grep -q 'reclaim-no-leave-stopped' "$AK47_STATE/findings.log" || fail "the missing mark script is not a finding"
  pass "every task stop is marked left stopped so the watchdog never relaunches it, and none happens without the mark"
}

test_unfinished_work_vetoes_a_stop() {
  reset
  local t s
  declare -A A=()
  local kept="open-decision unkeyed-open last-waiting awaits-review ready-to-merge needs-review pending-approval waiting-pr-merge ready-to-be-merged captain-approval pr-open pr-unreadable pr-gitlab unpushed dirty"
  local unreadable=
  local stopped="resolved-decision captain-held-stopped pr-merged already-merged ready-and-merged pushed"
  for t in $kept $stopped; do add_task main "$t" '-30 hours'; done
  s=$FM_HOME/state
  printf 'needs-decision [key=k1]: keep both cards or hide one\nworking: waiting meanwhile\n' >"$s/open-decision.status"
  printf 'needs-decision: pick API shape\nworking: wiring it up\n' >"$s/unkeyed-open.status"
  printf 'needs-decision [key=k2]: which copy\nresolved [key=k2]: copy chosen\ndone: copy shipped\n' >"$s/resolved-decision.status"
  printf 'needs-decision [key=held]: choose\ncaptain-held [key=held]: tracked by hold:1\n' >"$s/captain-held-stopped.status"
  printf 'waiting: a human answer\n' >"$s/last-waiting.status"
  printf 'done: renders ready, awaiting your review\n' >"$s/awaits-review.status"
  printf 'done: PR ready to merge\n' >"$s/ready-to-merge.status"
  printf 'done: needs review\n' >"$s/needs-review.status"
  printf 'done: pending approval\n' >"$s/pending-approval.status"
  printf 'done: waiting on the PR to merge\n' >"$s/waiting-pr-merge.status"
  printf 'done: ready to be merged\n' >"$s/ready-to-be-merged.status"
  printf 'done: already merged\n' >"$s/already-merged.status"
  printf "done: waiting for the captain's approval\n" >"$s/captain-approval.status"
  printf 'done: PR ready and merged\n' >"$s/ready-and-merged.status"
  if [ "$(id -u)" != 0 ]; then
    add_task main status-unreadable '-30 hours'
    printf 'needs-decision [key=secret]: choose\n' >"$s/status-unreadable.status"
    chmod 000 "$s/status-unreadable.status"
    unreadable=status-unreadable
    kept="$kept $unreadable"
  fi
  echo 'pr=https://github.com/o/r/pull/1' >>"$s/pr-open.meta"; echo OPEN >"$SANDBOX/gh/1"
  echo 'pr=https://github.com/o/r/pull/2' >>"$s/pr-merged.meta"; echo MERGED >"$SANDBOX/gh/2"
  echo 'pr=https://gitlab.example.com/group/proj/-/merge_requests/7' >>"$s/pr-gitlab.meta"
  printf 'done: PR https://github.com/o/r/pull/3\n' >"$s/pr-unreadable.status"
  commit_task unpushed
  commit_task pr-merged
  commit_task pushed yes
  commit_task dirty yes; echo y >>"$WT/dirty/f"
  for t in $kept $stopped; do touch -d '-30 hours' "$s/$t.status"; spawn_agent "$WT/$t"; A[$t]=$AGENT; done
  run --apply
  sleep 0.3
  for t in $kept; do
    alive "${A[$t]}" || fail "$t holds unfinished work but was stopped"
    [ -e "$s/$t.stopped" ] && fail "$t was marked left stopped"
  done
  for t in $stopped; do
    alive "${A[$t]}" && fail "$t holds no unfinished work but was kept: $(grep " $t " "$AK47_STATE/agent-reclaim-latest.md")"
  done
  if [ -n "$unreadable" ]; then
    grep -qF 'status unreadable' "$AK47_STATE/agent-reclaim-latest.md" || fail "report does not name the unreadable status veto"
  fi
  grep -q gitlab "$GH_LOG" && fail "a GitLab merge request was handed to gh"
  for r in 'open decision k1' 'open decision default' 'last status waiting' 'awaits review' 'PR open' 'PR state unreadable' 'PR on a forge the reclaim cannot read' 'commit(s) on no pushed branch' 'uncommitted changes'; do
    grep -qF "$r" "$AK47_STATE/agent-reclaim-latest.md" || fail "report does not name the veto '$r'"
  done
  pass "an open decision, a waiting or review-bound last status, an open or unreadable PR, and unpushed or uncommitted work each veto a stop"
}

test_missing_classify_lib_keeps_tasks() {
  reset
  add_task main missing-classify '-30 hours'
  spawn_agent "$WT/missing-classify"; local p=$AGENT
  AK47_CLASSIFY_LIB=$SANDBOX/missing run --apply
  [ "$(cat "$SANDBOX/rc")" = 0 ] || fail "missing classify lib run exited $(cat "$SANDBOX/rc"): $(cat "$SANDBOX/out")"
  sleep 0.3
  alive "$p" || fail "a task was stopped without a readable decision classifier"
  grep -qF 'decision state unreadable' "$AK47_STATE/agent-reclaim-latest.md" || fail "report does not name the unreadable decision state"
  pass "a missing status classifier keeps every task"
}

test_every_pr_a_task_names_vetoes_a_stop() {
  reset
  local t s=$FM_HOME/state
  declare -A A=()
  local kept="status-open status-second-open status-unreadable"
  local stopped="all-merged"
  for t in $kept $stopped; do add_task main "$t" '-30 hours'; done
  # 2026-11-17 encore-collab-verify-c2: the record names a merged PR while the
  # live open one is named only in the last status line.
  echo 'pr=https://github.com/o/r/pull/11' >>"$s/status-open.meta"; echo MERGED >"$SANDBOX/gh/11"
  printf 'working: fixes\ndone: PR https://github.com/o/r/pull/12\n' >"$s/status-open.status"
  echo OPEN >"$SANDBOX/gh/12"
  # An open PR second in a line of several counts too, not only the first.
  echo 'pr=https://github.com/o/r/pull/21' >>"$s/status-second-open.meta"; echo MERGED >"$SANDBOX/gh/21"
  printf 'done: PR https://github.com/o/r/pull/22 then https://github.com/o/r/pull/23\n' >"$s/status-second-open.status"
  echo MERGED >"$SANDBOX/gh/22"; echo OPEN >"$SANDBOX/gh/23"
  # A named PR with no readable state keeps the task as well.
  echo 'pr=https://github.com/o/r/pull/31' >>"$s/status-unreadable.meta"; echo MERGED >"$SANDBOX/gh/31"
  printf 'done: PR https://github.com/o/r/pull/32\n' >"$s/status-unreadable.status"
  # Nothing open anywhere: the task holds no unfinished work.
  echo 'pr=https://github.com/o/r/pull/41' >>"$s/all-merged.meta"; echo MERGED >"$SANDBOX/gh/41"
  printf 'done: PR https://github.com/o/r/pull/41\n' >"$s/all-merged.status"
  for t in $kept $stopped; do touch -d '-30 hours' "$s/$t.status"; spawn_agent "$WT/$t"; A[$t]=$AGENT; done
  run --apply
  sleep 0.3
  for t in $kept; do
    alive "${A[$t]}" || fail "$t names an open or unreadable PR but was stopped"
  done
  for t in $stopped; do
    alive "${A[$t]}" && fail "$t names only merged PRs but was kept: $(grep " $t " "$AK47_STATE/agent-reclaim-latest.md")"
  done
  for u in 'PR open, awaiting review: https://github.com/o/r/pull/12' \
           'PR open, awaiting review: https://github.com/o/r/pull/23' \
           'PR state unreadable: https://github.com/o/r/pull/32'; do
    grep -qF "$u" "$AK47_STATE/agent-reclaim-latest.md" || fail "the report does not name the veto '$u'"
  done
  pass "every PR a task names counts: a record's merged pr= does not hide an open one in its last status, and each veto names its URL"
}

test_armed_check_vetoes_and_finished_work_goes_first() {
  reset
  register_secondmate capped
  echo 1 >"$SANDBOX/homes/capped/config/child-cap"
  add_task capped monitored '-30 hours'
  add_task capped quiet-lane '-20 hours'
  add_task capped finished '-8 hours'
  echo "done: PR merged" >>"$SANDBOX/homes/capped/state/finished.status"
  touch -d '-8 hours' "$SANDBOX/homes/capped/state/finished.status"
  printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/homes/capped/state/monitored.check.sh"
  chmod 700 "$SANDBOX/homes/capped/state/monitored.check.sh"
  local p_mon p_quiet p_fin
  spawn_agent "$WT/monitored"; p_mon=$AGENT
  spawn_agent "$WT/quiet-lane"; p_quiet=$AGENT
  spawn_agent "$WT/finished"; p_fin=$AGENT
  echo 'reclaim_max_stops=1' >>"$AK47_CONFIG/devops.conf"
  run --apply
  sleep 0.3
  alive "$p_mon" || fail "a day-quiet task with an armed check was stopped"
  [ -f "$SANDBOX/homes/capped/state/monitored.check.sh" ] || fail "the armed check was touched"
  alive "$p_fin" && fail "a finished task was not the first cap stop"
  alive "$p_quiet" || fail "a quiet live lane was stopped before finished work"
  pass "an armed check vetoes a stop, and cap stops take finished work before quiet live lanes"
}

test_orphan_status_logs_move_to_archive
test_orphan_is_stopped_and_live_task_is_not
test_dry_run_touches_nothing
test_idle_task_stops_through_fm_control_in_its_home
test_working_agent_is_never_stopped
test_busy_state_and_keep_list_veto
test_unread_steering_and_running_validation_veto
test_stops_are_marked_left_stopped
test_unfinished_work_vetoes_a_stop
test_over_cap_home_stops_oldest_idle_first
test_box_cap_reads_budget
test_missing_classify_lib_keeps_tasks
test_every_pr_a_task_names_vetoes_a_stop
test_armed_check_vetoes_and_finished_work_goes_first
test_chairs_and_check_monitors_are_never_touched
test_dead_chair_watcher_stops_only_after_two_runs
test_live_chair_watcher_is_never_stopped
test_stop_watcher_refuses_mismatched_identity
test_health_line_and_children_metric
