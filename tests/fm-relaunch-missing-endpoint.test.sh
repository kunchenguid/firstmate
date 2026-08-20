#!/usr/bin/env bash
# fm-relaunch-missing-endpoint: relaunch recovery when the runtime endpoint was
# destroyed outside teardown, and the teardown worktree collision guard.
#
# Tests:
#   1. fm-spawn --relaunch accepts a provably absent (missing) endpoint and
#      creates a replacement, in the worktree the task's own record names
#      rather than in the project.
#   2. fm-spawn --relaunch still refuses an unreadable endpoint (mutation check:
#      treating "I could not check" as "it is gone" must fail).
#   3. fm-control.sh exit still refuses a missing endpoint when called standalone.
#   4. fm-teardown.sh refuses when another task's metadata claims the same worktree.
#   5. fm-control.sh relaunch reads its readiness postcondition from the
#      endpoint the replacement was actually launched at, and reports an
#      unfinished start as one rather than as a failure. These run on a herdr
#      stub because the defect needs a backend whose endpoints carry their own
#      identity: a tmux replacement window is created under the same
#      session:fm-<id> name the retired one had, so the stale handle happens to
#      still resolve and the bug cannot appear there at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-relaunch-missing)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap relaunch_cleanup EXIT

# The same lifecycle-modelling tmux stub as the existing relaunch tests.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          ;;
        *'encode launch-brief'*)
          cat "$D/becomes" > "$D/command"
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-window)
    # -c is the created window's starting directory, and a real tmux window
    # reports it as pane_current_path from then on. Recording it is what keeps
    # the pane_current_path answer below a consequence of the request rather
    # than a fixture that would agree with any request at all.
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-c" ]; then
        printf '%s' "$a" >> "$D/new-window-cwd"
        printf '%s' "$a" > "$D/cwd"
        break
      fi
      prev=$a
    done
    printf 'fakepane\n'
    exit 0 ;;
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  set-option) exit 0 ;;
  set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  # Stub treehouse to report the worktree path.
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get) printf '%s\n' "$FM_FAKE_CWD_OVERRIDE" ;;
  return) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/treehouse"
}

new_case() {  # <name> <id>
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/new-window-cwd"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

add_ship_task() {  # <case-dir> <id> [harness]
  local dir=$1 id=$2 harness=${3:-claude}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n\nDo the thing.\n' "$id" > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_FAKE_CWD_OVERRIDE="$dir/wt" \
    "$SPAWN" "$@" 2>&1
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_FAKE_CWD_OVERRIDE="$dir/wt" \
    "$CONTROL" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

# --- 1. fm-spawn --relaunch accepts a provably absent endpoint ---------------

test_spawn_relaunch_accepts_missing_endpoint() {
  local dir out rc
  dir=$(new_case missing-ok rl-m1)
  add_ship_task "$dir" rl-m1 claude
  # Make the endpoint provably absent: the window is NOT in the tmux session's
  # window list. The tmux agent_state classifier returns 'missing' for this.
  printf '' > "$dir/fake/windows"
  # The agent is not running (command is zsh, not claude).
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl-m1 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch with a provably absent endpoint should succeed"
  assert_contains "$out" "provably absent" "the output should mention the endpoint was provably absent"
  # The meta file must exist and point at the task.
  [ -f "$dir/home/state/rl-m1.meta" ] \
    || fail "relaunch with missing endpoint should publish a replacement meta"
  [ "$(meta_field "$dir" rl-m1 endpoint_task_id)" = rl-m1 ] \
    || fail "the replacement meta must preserve the task id"
  [ "$(meta_field "$dir" rl-m1 harness)" = claude ] \
    || fail "the replacement meta must record the harness"
  # A replacement endpoint is CREATED, so unlike an adopted one it starts
  # wherever it was created. Created in the project, it starts in the project,
  # and the worktree assertion below refuses it - which is what made recovery
  # unreachable for exactly the case it exists for. It must be created in the
  # worktree the task's own record already names, and must never acquire
  # another one.
  [ "$(cat "$dir/fake/new-window-cwd")" = "$dir/wt" ] \
    || fail "the replacement window was created in '$(cat "$dir/fake/new-window-cwd")', not the recorded worktree '$dir/wt'"
  assert_not_contains "$out" "refusing to relaunch an agent outside" \
    "the worktree assertion must have nothing left to refuse"
  assert_not_contains "$(cat "$dir/fake/keys")" "treehouse get" \
    "a relaunch must enter the recorded worktree, never acquire another one"
  pass "fm-spawn --relaunch: accepts a provably absent endpoint and creates a replacement"
}

# --- 2. Mutation check: unreadable endpoint must NOT be treated as missing ----

test_spawn_relaunch_refuses_unreadable_endpoint() {
  local dir out rc
  dir=$(new_case unreadable rl-m2)
  add_ship_task "$dir" rl-m2 claude
  # Make the tmux stub return a non-zero exit code with an UNRECOGNIZED error
  # message, so the classifier returns 'unreadable' rather than 'missing'.
  # Override the tmux stub to produce an unreadable result.
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    echo "error: unexpected internal failure" >&2
    exit 42
    ;;
  display-message)
    printf 'fakepane\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  out=$(run_spawn "$dir" rl-m2 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunch with an unreadable endpoint must refuse"
  assert_contains "$out" "unreadable" "the refusal should name the unreadable state"
  pass "fm-spawn --relaunch: refuses an unreadable endpoint (mutation check passed)"
}

# --- 3. fm-control.sh exit still refuses a missing endpoint -------------------

test_control_exit_refuses_missing_endpoint() {
  local dir out rc
  dir=$(new_case exit-missing rl-m3)
  add_ship_task "$dir" rl-m3 claude
  # Make the endpoint provably absent.
  printf '' > "$dir/fake/windows"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_control "$dir" rl-m3 exit); rc=$?
  expect_code 1 "$rc" "standalone exit with a missing endpoint should refuse"
  assert_contains "$out" "recorded endpoint is gone" "the exit refusal should explain the endpoint is gone"
  assert_contains "$out" "reconcile" "the exit refusal should suggest reconciliation"
  pass "fm-control.sh exit: still refuses when the endpoint is missing"
}

# --- 4. Teardown worktree collision guard ------------------------------------

test_teardown_skips_reap_on_worktree_collision() {
  local dir out rc id1=td-c1 id2=td-c2
  dir=$(new_case teardown-collision "$id1")
  add_ship_task "$dir" "$id1" claude
  local wt
  wt=$(meta_field "$dir" "$id1" worktree)
  # Create a second task's meta that claims the SAME worktree.
  {
    echo "window=fmses:fm-$id2"
    echo "endpoint_task_id=$id2"
    echo "worktree=$wt"
    echo "project=$dir/proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
  } > "$dir/home/state/$id2.meta"
  # Make the first task's endpoint dead (so exit checks pass).
  printf 'zsh' > "$dir/fake/command"
  # Push a commit so landed-work checks pass in --force mode.
  (cd "$dir/wt" && git add -A && git -c user.name='Test' -c user.email='t@t' commit -qm work && git push -q origin HEAD 2>/dev/null) || true
  # Attempt teardown of the first task - should succeed but skip the CWD reap.
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 FM_TEARDOWN_GUARD_DONE=1 \
    "$TEARDOWN" "$id1" 2>&1); rc=$?
  # Teardown should succeed (exit 0), not refuse.
  expect_code 0 "$rc" "teardown should succeed when a sibling claims the same worktree"
  assert_contains "$out" "$id2" "the warning should name the colliding task"
  assert_contains "$out" "skipping CWD-based process reap" "the warning should explain the reap was skipped"
  pass "fm-teardown.sh: skips CWD-based process reap when another task claims the same worktree"
}


# --- 5. relaunch readiness is read from the replacement's own endpoint --------
#
# On herdr the endpoint identity is the PANE. When the recorded pane is
# provably gone, fm-spawn creates a replacement pane with a NEW id and
# publishes it. fm-control resolved its endpoint handle once, at startup, from
# the record the PREVIOUS agent was running under - so its readiness poll used
# to watch the retired pane, which is authoritatively absent and classifies
# 'missing' forever. The relaunch then reported that a healthy replacement had
# failed to start, and named the preserved worktree, which reads as work
# stranded. Raising the wait cannot help: no amount of waiting makes a
# destroyed pane come back.

HERDR_SES=fm-test-herdr
DEAD_PANE=w2:p1
NEW_PANE=w2:p9

# make_herdr_case: a task recorded on herdr whose pane is provably gone, plus a
# herdr stub that creates the replacement under a DIFFERENT pane id - the whole
# point of the case. <agent-state> is what `agent get` reports for the
# replacement pane: "live" (registered) or "absent" (still starting).
make_herdr_case() {  # <name> <id> <agent-state>
  local name=$1 id=$2 agent=$3 dir
  dir="$TMP_ROOT/$name-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/fakebin" "$dir/fake"
  fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
  printf '# brief for %s\n\nDo the thing.\n' "$id" > "$dir/home/data/$id/brief.md"
  {
    echo "window=$HERDR_SES:$DEAD_PANE"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/wt"
    echo "project=$dir/proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=direct-PR"
    echo "yolo=off"
    echo "backend=herdr"
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=w2"
    echo "herdr_tab_id=w2:t1"
    echo "herdr_pane_id=$DEAD_PANE"
    echo "model=default"
    echo "effort=default"
  } > "$dir/home/state/$id.meta"
  cat > "$dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}-\${2:-}" in
  status---json)
    printf '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true}}\n' ;;
  session-list)
    printf '{"sessions":[{"name":"$HERDR_SES","running":true,"socket_path":"/tmp/fm-test-herdr.sock"}]}\n' ;;
  pane-get)
    if [ "\${3:-}" = "$DEAD_PANE" ]; then
      # The endpoint the previous agent ran in. Destroyed, and it stays
      # destroyed - this is what the readiness poll used to watch.
      printf '{"error":{"code":"pane_not_found","message":"pane gone"}}\n'
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w2:t9","workspace_id":"w2","cwd":"$dir/wt","foreground_cwd":"$dir/wt"}}}\n' "\${3:-}" ;;
  agent-get)
    if [ "\${3:-}" = "$NEW_PANE" ] && [ "$agent" = live ]; then
      printf '{"result":{"agent":{"agent_status":"working"}}}\n'
      exit 0
    fi
    printf '{"error":{"code":"agent_not_found","message":"none"}}\n' ;;
  workspace-list)
    printf '{"result":{"workspaces":[{"workspace_id":"w2","label":"firstmate"}]}}\n' ;;
  tab-list)
    printf '{"result":{"tabs":[]}}\n' ;;
  tab-create)
    printf '{"result":{"tab":{"tab_id":"w2:t9"},"root_pane":{"pane_id":"$NEW_PANE"}}}\n' ;;
  tab-get)
    printf '{"result":{"tab":{"tab_id":"w2:t9","panes":[{"pane_id":"$NEW_PANE"}]}}}\n' ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/herdr"
  fm_fake_treehouse "$dir/fakebin"
  printf '%s\n' "$dir"
}

run_herdr_control() {  # <case-dir> <args...>
  local dir=$1; shift
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_SPAWN_NO_GUARD=1 \
    HERDR_SESSION="$HERDR_SES" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

test_relaunch_readiness_follows_the_replacement_endpoint() {
  local dir out rc id=rl-m5
  dir=$(make_herdr_case readiness-follows "$id" live)
  out=$(run_herdr_control "$dir" "$id" relaunch --note 'nothing was in flight'); rc=$?
  expect_code 0 "$rc" "a relaunch whose replacement is running must not report failure"
  assert_not_contains "$out" "did not come up" \
    "the readiness poll must not report a running replacement as one that never started"
  assert_not_contains "$out" "no running agent could be confirmed" \
    "a healthy recovery must never be reported as unconfirmed work"
  assert_contains "$out" "ready=confirmed" "a registered agent must be reported as confirmed"
  assert_contains "$out" "endpoint=$HERDR_SES:$NEW_PANE" \
    "the outcome must name the endpoint the replacement was launched at"
  assert_not_contains "$out" "endpoint=$HERDR_SES:$DEAD_PANE" \
    "the outcome must not name the retired endpoint"
  pass "fm-control.sh relaunch: reads readiness from the replacement's own endpoint, not the retired one"
}

test_a_replacement_still_starting_is_not_a_failure() {
  local dir out rc id=rl-m6
  # The same case, except no agent has registered in the replacement yet -
  # exactly what a harness that has not finished coming up looks like.
  dir=$(make_herdr_case still-starting "$id" absent)
  out=$(run_herdr_control "$dir" "$id" relaunch --note 'nothing was in flight'); rc=$?
  expect_code 0 "$rc" "a replacement that is in place but still starting is not a failed relaunch"
  assert_contains "$out" "ready=starting" "an unfinished start must be reported as one"
  assert_not_contains "$out" "ready=confirmed" \
    "an unregistered agent must never be reported as a confirmed one"
  assert_contains "$out" "had not finished starting" \
    "the operator must be told the replacement is still coming up"
  assert_not_contains "$out" "no running agent could be confirmed" \
    "a placed replacement must not be described as unconfirmed work"
  assert_contains "$out" "rather than relaunching it again or tearing it down" \
    "the message must steer away from the actions a false failure provokes"
  pass "fm-control.sh relaunch: reports a replacement that is still starting as starting, not as failed"
}

test_a_replacement_that_is_gone_is_still_a_failure() {
  local dir out rc id=rl-m7
  dir=$(make_herdr_case replacement-gone "$id" absent)
  # Mutation check: the fix must not buy a quiet success by accepting anything.
  # Every pane read now answers pane_not_found, so the endpoint the replacement
  # was launched at is authoritatively gone once it was published.
  cat > "$dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}-\${2:-}" in
  status---json)
    printf '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true}}\n' ;;
  session-list)
    printf '{"sessions":[{"name":"$HERDR_SES","running":true,"socket_path":"/tmp/fm-test-herdr.sock"}]}\n' ;;
  pane-get)
    if [ -f "$dir/fake/published" ]; then
      printf '{"error":{"code":"pane_not_found","message":"pane gone"}}\n'
      exit 1
    fi
    if [ "\${3:-}" = "$DEAD_PANE" ]; then
      printf '{"error":{"code":"pane_not_found","message":"pane gone"}}\n'
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w2:t9","workspace_id":"w2","cwd":"$dir/wt","foreground_cwd":"$dir/wt"}}}\n' "\${3:-}" ;;
  agent-get)
    printf '{"error":{"code":"agent_not_found","message":"none"}}\n' ;;
  workspace-list)
    printf '{"result":{"workspaces":[{"workspace_id":"w2","label":"firstmate"}]}}\n' ;;
  tab-list)
    printf '{"result":{"tabs":[]}}\n' ;;
  tab-create)
    printf '{"result":{"tab":{"tab_id":"w2:t9"},"root_pane":{"pane_id":"$NEW_PANE"}}}\n' ;;
  tab-get)
    printf '{"result":{"tab":{"tab_id":"w2:t9","panes":[{"pane_id":"$NEW_PANE"}]}}}\n' ;;
  pane-send-text|pane-send-keys)
    # The launch command reached the pane and the pane then died under it.
    : > "$dir/fake/published" ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/herdr"
  out=$(run_herdr_control "$dir" "$id" relaunch --note 'nothing was in flight'); rc=$?
  expect_code 1 "$rc" "a replacement whose endpoint is gone must still fail"
  assert_contains "$out" "not at the endpoint it was launched at" \
    "the failure must name the endpoint the replacement was launched at"
  assert_not_contains "$out" "ready=confirmed" \
    "a vanished replacement must never be reported as confirmed"
  pass "fm-control.sh relaunch: still fails when the replacement's own endpoint is gone (mutation check passed)"
}

# --- run all tests -----------------------------------------------------------

test_spawn_relaunch_accepts_missing_endpoint
test_spawn_relaunch_refuses_unreadable_endpoint
test_control_exit_refuses_missing_endpoint
test_teardown_skips_reap_on_worktree_collision
test_relaunch_readiness_follows_the_replacement_endpoint
test_a_replacement_still_starting_is_not_a_failure
test_a_replacement_that_is_gone_is_still_a_failure

echo "all tests passed"
