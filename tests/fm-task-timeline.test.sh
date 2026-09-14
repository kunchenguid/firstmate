#!/usr/bin/env bash
# tests/fm-task-timeline.test.sh - the durable per-task timeline record
# (bin/fm_task_timeline.py, bin/fm-task-timeline.sh) and its two lifecycle
# checkpoints in bin/fm-spawn.sh and bin/fm-teardown.sh.
#
# Three layers:
#   1. tests/fm-task-timeline-lib.test.py - stdlib unittest over the record
#      schema, the phase arithmetic (a no-mistakes task's phases sum to its
#      elapsed time within the stated tolerance and name the biggest cost, a
#      direct-PR task says it has no pipeline run, a missing record says so),
#      the checkpoint writers, and the live-task path.
#   2. A real bin/fm-spawn.sh launch against a scratch home with a fake tmux
#      (the same fake-pane shape tests/fm-trace-context-spawn.test.sh uses), so
#      no agent process ever starts, asserting the dispatch checkpoint lands
#      after the launch and that an unwritable data/<id>/ only warns.
#   3. A real bin/fm-teardown.sh run against a scratch home and a real
#      throwaway git worktree (the same sandbox shape tests/fm-teardown.test.sh
#      uses), with fake treehouse/tmux/gh/no-mistakes on PATH and a fake Claude
#      session log under a throwaway HOME, asserting the cleanup checkpoint
#      captures the status events, the run id matched to the worktree, the
#      session log path, and the PR before the status log is removed - and that
#      an unwritable data/<id>/ warns without changing the teardown's outcome.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TIMELINE="$ROOT/bin/fm-task-timeline.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-timeline)

cleanup() {
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- 1. unit layer -------------------------------------------------------------

if ! python3 "$ROOT/tests/fm-task-timeline-lib.test.py" 2>&1; then
  fail "fm-task-timeline-lib.test.py failed (see unittest output above)"
fi
pass "fm_task_timeline.py: fixtures for no-mistakes, direct-PR, missing, partial, and live tasks pass under plain python3"

out=$("$TIMELINE" --help) || fail "fm-task-timeline.sh --help failed"
case "$out" in *"checkpoint dispatch"*"checkpoint cleanup"*"build"*) ;; *) fail "help did not list the three commands: $out" ;; esac
pass "fm-task-timeline.sh --help lists the checkpoint and build commands"

# --- 2. spawn dispatch checkpoint ----------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name>; echoes home|proj|wt|fakebin|id
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/user-home"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s off\n' "$$" > "$home/state/.trace-context-effective"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-t1
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the timeline dispatch checkpoint for $id.

## Firstmate spec
Nothing runs; the tmux pane is fake.
EOF
  printf '%s\n' "$home|$proj|$wt|$fakebin|$id"
}

run_spawn() {  # <home> <wt> <fakebin> <id> <proj>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode direct-PR --yolo off 2>&1
}

IFS='|' read -r S_HOME S_PROJ S_WT S_FAKE S_ID <<EOF
$(make_spawn_case dispatch)
EOF
out=$(run_spawn "$S_HOME" "$S_WT" "$S_FAKE" "$S_ID" "$S_PROJ") || fail "spawn failed: $out"
case "$out" in *"spawned $S_ID "*) ;; *) fail "spawn did not report success: $out" ;; esac
case "$out" in *"warning: timeline"*) fail "spawn warned about the timeline checkpoint on the success path: $out" ;; esac
RECORD="$S_HOME/data/$S_ID/timeline.json"
[ -f "$RECORD" ] || fail "dispatch checkpoint did not write $RECORD"
jq -e --arg id "$S_ID" --arg wt "$S_WT" '
  .schema == "fm-task-timeline.v1"
  and .task_id == $id
  and .kind == "ship"
  and .mode == "direct-PR"
  and .yolo == "off"
  and .cleanup == null
  and (.dispatches | length) == 1
  and .dispatches[0].relaunch == false
  and .dispatches[0].harness == "claude"
  and .dispatches[0].backend == "tmux"
  and .dispatches[0].worktree == $wt
  and (.dispatches[0].spawn_gen | startswith("s"))
  and (.dispatches[0].at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
' "$RECORD" >/dev/null || { cat "$RECORD" >&2; fail "dispatch record fields were wrong"; }
pass "fm-spawn.sh writes the dispatch checkpoint after the launch, with the task's mode, harness, and worktree"

# Unwritable record: a directory squatting on data/<id>/timeline.json makes the
# atomic rename fail (spawn renders its launch brief into the same directory,
# so the directory itself must stay writable). The launch still succeeds and
# the checkpoint only warns.
IFS='|' read -r S_HOME S_PROJ S_WT S_FAKE S_ID <<EOF
$(make_spawn_case nowrite)
EOF
mkdir -p "$S_HOME/data/$S_ID/timeline.json/occupied"
out=$(run_spawn "$S_HOME" "$S_WT" "$S_FAKE" "$S_ID" "$S_PROJ") || fail "spawn must not fail when the timeline record cannot be written: $out"
case "$out" in *"spawned $S_ID "*) ;; *) fail "spawn did not report success with an unwritable record: $out" ;; esac
case "$out" in *"warning: timeline dispatch checkpoint for $S_ID not written"*) ;; *) fail "spawn did not warn about the unwritten checkpoint: $out" ;; esac
[ -d "$S_HOME/data/$S_ID/timeline.json" ] || fail "the squatting directory was replaced"
pass "fm-spawn.sh warns and still launches when the timeline record cannot be written"

# --- 3. teardown cleanup checkpoint --------------------------------------------

RUN_ID=$(python3 - <<'PY'
import datetime as dt
A = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
ms = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000) - 600000
chars = []
for _ in range(10):
    chars.append(A[ms % 32]); ms //= 32
print("".join(reversed(chars)) + "0" * 16)
PY
)

make_teardown_case() {  # <name>; echoes case dir
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/td-$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$case_dir/user-home" "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse tmux
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  # `axi status` in the worktree answers a completed run on the task branch;
  # every other call (abort, runs, --run) answers nothing so the pre-teardown
  # run-abort step stays a no-op.
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = axi ] && [ "\${2:-}" = status ] && [ -z "\${3:-}" ]; then
  [ -z "\${FM_FAKE_NM_STATUS_LOG:-}" ] || printf '%s\n' "\$PWD" >> "\$FM_FAKE_NM_STATUS_LOG"
  cat <<'EOF'
current_run:
  id: "$RUN_ID"
  branch: fm/task-x1
  status: completed
  head_sha: 0123456789abcdef0123456789abcdef01234567
  steps[3]{step,status,findings,duration_ms}:
    review,completed,0,90000
    test,completed,0,30000
    ci,skipped,0,0
outcome: passed
EOF
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  touch "$case_dir/state/.last-watcher-beat"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off" \
    "model=default" \
    "effort=default" \
    "spawn_gen=s$(date +%s).1.1" \
    "pr=https://github.com/example/repo/pull/7"
  # Landed work: the task branch's commit is reachable from the project's main.
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "merged work"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  printf 'working: setup done\ndone: PR https://github.com/example/repo/pull/7\n' > "$case_dir/state/task-x1.status"
  printf '%s\n' "$case_dir"
}

write_claude_log() {  # <case dir>
  local case_dir=$1 dir
  # Same path mangling as claude_dir_for_path in bin/fm_bridge_snapshot.py.
  dir="$case_dir/user-home/.claude/projects/$(printf '%s' "$case_dir/wt" | sed 's#/#-#g; s#\.#-#g')"
  mkdir -p "$dir"
  cat > "$dir/session.jsonl" <<'EOF'
{"timestamp":"2026-09-13T00:00:02Z","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"output_tokens":7}}}
{"timestamp":"2026-09-13T00:00:03Z","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40,"output_tokens":8}}}
EOF
  printf '%s\n' "$dir/session.jsonl"
}

run_teardown() {  # <case dir> [args]
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  HOME="$case_dir/user-home" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

case_dir=$(make_teardown_case captures)
LOG_PATH=$(write_claude_log "$case_dir")
export FM_FAKE_NM_STATUS_LOG="$case_dir/nm-status.log"
# The dispatch checkpoint a real spawn would have written.
FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
  "$TIMELINE" checkpoint dispatch task-x1 >/dev/null || fail "dispatch checkpoint failed in the teardown sandbox"
rc=0
run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
[ "$rc" -eq 0 ] || { cat "$case_dir/stderr" >&2; fail "teardown should succeed for landed local-only work (rc=$rc)"; }
! grep -q 'warning: timeline' "$case_dir/stderr" || { cat "$case_dir/stderr" >&2; fail "teardown warned about the timeline checkpoint on the success path"; }
RECORD="$case_dir/data/task-x1/timeline.json"
[ -f "$RECORD" ] || fail "cleanup checkpoint record missing at $RECORD after teardown"
[ ! -e "$case_dir/state/task-x1.status" ] || fail "teardown left the status log, so this test no longer proves the record outlives it"
[ ! -e "$case_dir/state/task-x1.meta" ] || fail "teardown left the task record"
grep -Fxq "$case_dir/wt" "$FM_FAKE_NM_STATUS_LOG" || fail "cleanup checkpoint did not query no-mistakes in the worktree"
jq -e --arg run "$RUN_ID" --arg log "$LOG_PATH" '
  (.dispatches | length) == 1
  and .cleanup != null
  and (.cleanup.at | test("Z$"))
  and .cleanup.status_log.present == true
  and (.cleanup.status_log.events | map(.state)) == ["working", "done"]
  and .cleanup.status_log.events[1].note == "PR https://github.com/example/repo/pull/7"
  and .cleanup.status_log.last_modified != null
  and .cleanup.no_mistakes.queried == true
  and .cleanup.no_mistakes.branch == "fm/task-x1"
  and (.cleanup.no_mistakes.runs | length) == 1
  and .cleanup.no_mistakes.runs[0].run_id == $run
  and .cleanup.no_mistakes.runs[0].outcome == "passed"
  and (.cleanup.session_logs | length) == 1
  and .cleanup.session_logs[0].harness == "claude"
  and .cleanup.session_logs[0].path == $log
  and .cleanup.pr == "https://github.com/example/repo/pull/7"
' "$RECORD" >/dev/null || { cat "$RECORD" >&2; fail "cleanup record fields were wrong"; }
pass "fm-teardown.sh writes the cleanup checkpoint (status events, matched run id, session log, PR) before removing the status log"

# The finished record renders through the same builder the console uses, with
# the run's step durations read back by id from (fake) no-mistakes.
view=$(FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
  HOME="$case_dir/user-home" PATH="$case_dir/fakebin:$PATH" "$TIMELINE" build task-x1) || fail "build failed after teardown"
case "$view" in *"task-x1 (ship, local-only) - finished"*) ;; *) fail "build did not report a finished task: $view" ;; esac
case "$view" in *"status events"*"2. done: PR https://github.com/example/repo/pull/7"*) ;; *) fail "build did not list the captured status events: $view" ;; esac
case "$view" in *"claude session 1: 2 turns, 15 output tokens"*) ;; *) fail "build did not read the captured session log: $view" ;; esac
case "$view" in *"step durations unavailable"*) ;; *) fail "the fake answers nothing for --run, so the view must say durations are unavailable: $view" ;; esac
pass "fm-task-timeline.sh build renders the finished task from the record after cleanup"

# Unwritable data/<id>/: the teardown outcome is unchanged and the checkpoint only warns.
if [ "$(id -u)" = 0 ]; then
  pass "skip: unwritable data/<id>/ teardown case needs a non-root user"
else
  case_dir=$(make_teardown_case nowrite)
  mkdir -p "$case_dir/data/task-x1"
  chmod 555 "$case_dir/data/task-x1"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  chmod 755 "$case_dir/data/task-x1"
  [ "$rc" -eq 0 ] || { cat "$case_dir/stderr" >&2; fail "teardown must not fail on an unwritable timeline dir (rc=$rc)"; }
  grep -q 'warning: timeline cleanup checkpoint for task-x1 not written' "$case_dir/stderr" \
    || { cat "$case_dir/stderr" >&2; fail "teardown did not warn about the unwritten cleanup checkpoint"; }
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "teardown outcome changed: task record retained"
  pass "fm-teardown.sh warns and completes when the timeline record cannot be written"
fi
