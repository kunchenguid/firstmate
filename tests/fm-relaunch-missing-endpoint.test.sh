#!/usr/bin/env bash
# fm-spawn/fm-control relaunch recovery: what happens when the recorded
# endpoint was destroyed outside teardown.
#
# Three fork passes over this one path are ported here as a single behavior
# suite, hermetically (stubbed tmux, canned herdr CLI, no real agent):
#   1. A provably absent (missing) endpoint is accepted for --relaunch, and
#      the replacement is CREATED in the task's own recorded worktree - never
#      in the project, never by acquiring a second worktree (#16, #31).
#   2. An unreadable endpoint is still refused: "I could not check" is never
#      "it is gone" (#16's provably-absent boundary).
#   3. A standalone `exit` on a missing endpoint still refuses with the
#      original message; only the relaunch path treats it as already stopped.
#   4. Readiness is read from the replacement's OWN published endpoint, and an
#      endpoint that is present but has no agent yet reports ready=starting,
#      not a failure; only a gone replacement endpoint fails (#41).
#   5. Herdr placement recovery: when the launcher pane died with the endpoint,
#      the recorded workspace id - verified present exactly once in the same
#      session while the pane reads provably absent - is the one path out of
#      the launcher-identity refusal, and it stays refused for every weaker
#      evidence shape (#23, re-derived against the rewritten herdr adapter).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-relaunch-missing-endpoint)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

relaunch_missing_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap relaunch_missing_cleanup EXIT

# The lifecycle-modelling tmux stub from tests/fm-control-relaunch.test.sh,
# extended with endpoint creation: new-window records the directory it was
# asked to start in ($D/created_cwd) and joins the inventory, so a test can
# prove WHERE a replacement was created, not just that one exists. The pane's
# reported cwd answers from the cwd actually requested, which is what makes a
# project-started replacement fail the worktree assertion below.
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
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  new-window)
    shift
    name= cwd=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=$2; shift 2 ;;
        -c) cwd=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s' "$cwd" > "$D/created_cwd"
    if [ -z "${FM_FAKE_NEW_WINDOW_VANISHES:-}" ]; then
      printf '%s\n' "$name" >> "$D/windows"
    fi
    printf '@99\n'
    exit 0 ;;
  set-window-option) exit 0 ;;
  has-session) exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf 'mock\n'; exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_LIST_WINDOWS_FAIL:-}" ]; then
      printf 'weird transport error\n'
      exit 1
    fi
    [ -f "$D/windows" ] && cat "$D/windows"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> [id] -> echoes a case dir with a live claude ship task.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [harness]
add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise missing-endpoint relaunch recovery for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
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

# destroy_recorded_endpoint <case-dir>: the pane is gone from the backend's
# inventory, while the record still names it - the production shape this
# suite exists for.
destroy_recorded_endpoint() {
  : > "$1/fake/windows"
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_REAL_GIT="${FM_REAL_GIT:-}" \
    "$CONTROL" "$@" 2>&1
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

# --- 1. missing is accepted; the replacement is created in the worktree -----

test_missing_endpoint_creates_replacement_in_recorded_worktree() {
  local dir out rc
  dir=$(new_case missing m1)
  add_ship_task "$dir" m1 claude
  destroy_recorded_endpoint "$dir"
  out=$(run_spawn "$dir" m1 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "a provably absent endpoint should relaunch"$'\n'"$out"
  assert_contains "$out" "provably absent" "the launch should announce the recovery"
  [ -f "$dir/fake/created_cwd" ] || fail "a missing endpoint must create a replacement endpoint, not adopt the gone one"
  [ "$(cat "$dir/fake/created_cwd")" = "$dir/wt" ] \
    || fail "the replacement must be created in the recorded worktree '$dir/wt', got '$(cat "$dir/fake/created_cwd")'"
  [ "$(meta_field "$dir" m1 worktree)" = "$dir/wt" ] \
    || fail "the worktree must be reused, not reallocated"
  assert_grep "encode launch-brief" "$dir/fake/literal" "the replacement should have been launched"
  pass "fm-spawn --relaunch: a missing endpoint creates its replacement in the task's recorded worktree"
}

# --- 2. unreadable is still refused ------------------------------------------

test_unreadable_endpoint_still_refuses() {
  local dir out rc
  dir=$(new_case unreadable m2)
  add_ship_task "$dir" m2 claude
  out=$(FM_FAKE_LIST_WINDOWS_FAIL=1 run_spawn "$dir" m2 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "an unreadable endpoint should refuse"
  assert_contains "$out" "provably absent" "the refusal should name the boundary it could not prove"
  [ ! -f "$dir/fake/created_cwd" ] || fail "a refused relaunch must create no endpoint anywhere"
  pass "fm-spawn --relaunch: an unreadable endpoint refuses rather than being read as absent"
}

# --- 3. standalone exit on a missing endpoint still refuses ------------------

test_standalone_exit_on_missing_endpoint_still_refuses() {
  local dir out rc
  dir=$(new_case exitgone m3)
  add_ship_task "$dir" m3 claude
  destroy_recorded_endpoint "$dir"
  out=$(run_control "$dir" m3 exit); rc=$?
  expect_code 1 "$rc" "a standalone exit on a gone endpoint should refuse"
  assert_contains "$out" "recorded endpoint is gone" "the refusal should keep its original message"
  pass "fm-control exit: a missing endpoint still refuses outside a relaunch"
}

# --- 4. readiness comes from the replacement's own endpoint ------------------

test_relaunch_reports_starting_when_replacement_has_no_agent_yet() {
  local dir out rc
  dir=$(new_case starting m4)
  add_ship_task "$dir" m4 claude
  destroy_recorded_endpoint "$dir"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_control "$dir" m4 relaunch --note "endpoint destroyed out of band"); rc=$?
  expect_code 0 "$rc" "an unfinished start is a successful relaunch, not a failure"$'\n'"$out"
  assert_contains "$out" "ready=starting" "the outcome should report the replacement as starting"
  assert_contains "$out" "rather than relaunching it again or tearing it down" "the outcome should warn against a second relaunch"
  [ "$(grep -c '^phase=complete$' "$dir/home/state/m4.control-relaunch")" = 1 ] \
    || fail "the transaction journal should end complete"
  pass "fm-control relaunch: a placed-but-starting replacement reports ready=starting"
}

test_relaunch_confirms_running_replacement() {
  local dir out rc
  dir=$(new_case confirmed m5)
  add_ship_task "$dir" m5 claude
  destroy_recorded_endpoint "$dir"
  out=$(run_control "$dir" m5 relaunch --note "endpoint destroyed out of band"); rc=$?
  expect_code 0 "$rc" "a running replacement should relaunch cleanly"$'\n'"$out"
  assert_contains "$out" "ready=confirmed" "the outcome should report the replacement as confirmed"
  pass "fm-control relaunch: readiness is read from the replacement's own endpoint"
}

test_relaunch_fails_when_replacement_endpoint_is_gone() {
  local dir out rc
  dir=$(new_case vanished m6)
  add_ship_task "$dir" m6 claude
  destroy_recorded_endpoint "$dir"
  out=$(FM_FAKE_NEW_WINDOW_VANISHES=1 run_control "$dir" m6 relaunch --note "endpoint destroyed out of band"); rc=$?
  expect_code 1 "$rc" "a replacement whose own endpoint is gone should fail"
  assert_contains "$out" "not at the endpoint it was launched at" "the failure should name the replacement's endpoint, not the retired one"
  pass "fm-control relaunch: a gone replacement endpoint is the failure, not a timeout"
}

# --- 5. herdr placement recovery, re-derived ----------------------------------
#
# Each case runs the real adapter function in a subshell with a canned
# fm_backend_herdr_cli: pane reads answer from FM_HERDR_CLI_PANE_MODE,
# workspace-list reads answer from FM_HERDR_CLI_WS_MODE.

# Bodies are bash -c sources, so their single-quoted $ expansions are
# deliberate (SC2016).
# shellcheck disable=SC2016
herdr_placement_run() {  # <session> <pane> <recorded-session> <recorded-ws> -> stdout; rc is the verdict
  local session=$1 pane=$2 rec_session=$3 rec_ws=$4
  env -i PATH="$PATH" HOME="$HOME" ROOT="$ROOT" \
    FM_HOME="$TMP_ROOT/herdr-home" HERDR_SESSION="$session" HERDR_PANE_ID="$pane" \
    FM_HERDR_CLI_PANE_MODE="${FM_HERDR_CLI_PANE_MODE:-gone}" \
    FM_HERDR_CLI_WS_MODE="${FM_HERDR_CLI_WS_MODE:-present-once}" \
    FM_BACKEND_HERDR_RELAUNCH_SESSION="$rec_session" \
    FM_BACKEND_HERDR_RELAUNCH_WORKSPACE_ID="$rec_ws" \
    bash -c '
      . "$ROOT/bin/backends/herdr.sh"
      fm_backend_herdr_cli() {
        case "$2 $3 $4" in
          "pane get "*)
            case "$FM_HERDR_CLI_PANE_MODE" in
              gone) printf "{\"error\":{\"code\":\"pane_not_found\"}}\n" ;;
              present) printf "{\"result\":{\"pane\":{\"pane_id\":\"%s\"}}}\n" "$4" ;;
              *) printf "{\"error\":{\"code\":\"timeout\"}}\n" ;;
            esac
            ;;
          "workspace list"*)
            case "$FM_HERDR_CLI_WS_MODE" in
              present-once) printf "{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\"}]}}\n" ;;
              absent) printf "{\"result\":{\"workspaces\":[]}}\n" ;;
              duplicated) printf "{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\"},{\"workspace_id\":\"w7\"}]}}\n" ;;
              *) printf "not json\n" ;;
            esac
            ;;
          *) printf "{}\n" ;;
        esac
        return 0
      }
      fm_backend_herdr_relaunch_placement "$0" "$1" "$2" "$3"
    ' "$session" "$pane" "$rec_session" "$rec_ws" 2>&1
}

test_herdr_placement_recovers_to_verified_recorded_workspace() {
  local out rc
  mkdir -p "$TMP_ROOT/herdr-home"
  out=$(herdr_placement_run s1 w9:p9 s1 w7); rc=$?
  expect_code 0 "$rc" "a provably gone pane with a present-once recorded workspace should recover"
  assert_contains "$out" "recorded workspace 'w7'" "the recovery should be announced, never silent"
  pass "herdr relaunch placement: a verified recorded workspace is the path out of the refusal"
}

test_herdr_placement_refuses_a_live_pane() {
  mkdir -p "$TMP_ROOT/herdr-home"
  FM_HERDR_CLI_PANE_MODE=present herdr_placement_run s1 w9:p9 s1 w7 >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a pane that still reads keeps the normal resolution"
  pass "herdr relaunch placement: a live pane keeps the normal resolution"
}

test_herdr_placement_refuses_an_unreadable_pane() {
  mkdir -p "$TMP_ROOT/herdr-home"
  FM_HERDR_CLI_PANE_MODE=broken herdr_placement_run s1 w9:p9 s1 w7 >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "'I could not check' is never 'it is gone'"
  pass "herdr relaunch placement: an unreadable pane keeps the refusal"
}

test_herdr_placement_refuses_a_cross_session_workspace() {
  mkdir -p "$TMP_ROOT/herdr-home"
  herdr_placement_run s1 w9:p9 s2 w7 >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "workspace ids repeat across sessions, so a recorded id from another session proves nothing"
  pass "herdr relaunch placement: a cross-session workspace id proves nothing"
}

test_herdr_placement_refuses_a_closed_or_ambiguous_workspace() {
  mkdir -p "$TMP_ROOT/herdr-home"
  FM_HERDR_CLI_WS_MODE=absent herdr_placement_run s1 w9:p9 s1 w7 >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a workspace closed with its panes leaves nothing to recover to"
  FM_HERDR_CLI_WS_MODE=duplicated herdr_placement_run s1 w9:p9 s1 w7 >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "an ambiguous workspace read keeps the refusal"
  pass "herdr relaunch placement: a closed or ambiguous workspace keeps the refusal"
}

test_herdr_placement_is_opt_in_only() {
  local out rc
  mkdir -p "$TMP_ROOT/herdr-home"
  # No recorded session/workspace passed: a fresh spawn keeps the refusal.
  out=$(herdr_placement_run s1 w9:p9 "" ""); rc=$?
  expect_code 1 "$rc" "without relaunch opt-in the refusal stands"
  [ -z "$out" ] || fail "a refused placement should stay quiet, got: $out"
  pass "herdr relaunch placement: without relaunch opt-in the refusal stands"
}

# Single-quoted body is a bash -c source; its $ expansions are deliberate (SC2016).
# shellcheck disable=SC2016
test_herdr_workspace_ensure_recovers_through_recorded_placement() {
  local out rc
  mkdir -p "$TMP_ROOT/herdr-home"
  # HERDR_SOCKET_PATH unset makes the launcher read fail closed (claimed but
  # unverifiable) while HERDR_PANE_ID set keeps it from degrading to the
  # no-ancestry fallback - the exact refusal the recovery is the only path
  # out of.
  out=$(env -i PATH="$PATH" HOME="$HOME" ROOT="$ROOT" \
    FM_HOME="$TMP_ROOT/herdr-home" HERDR_SESSION=s1 HERDR_PANE_ID=w9:p9 \
    FM_HERDR_CLI_PANE_MODE=gone FM_HERDR_CLI_WS_MODE=present-once \
    FM_BACKEND_HERDR_RELAUNCH_SESSION=s1 \
    FM_BACKEND_HERDR_RELAUNCH_WORKSPACE_ID=w7 \
    bash -c '
      . "$ROOT/bin/backends/herdr.sh"
      fm_backend_herdr_cli() {
        case "$2 $3 $4" in
          "pane get "*) printf "{\"error\":{\"code\":\"pane_not_found\"}}\n" ;;
          "workspace list"*) printf "{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\"}]}}\n" ;;
          *) printf "{}\n" ;;
        esac
        return 0
      }
      fm_backend_herdr_workspace_ensure s1 /tmp
    ' 2>/dev/null); rc=$?
  expect_code 0 "$rc" "workspace_ensure should recover through the recorded placement"
  [ "$out" = w7 ] || fail "the recovered workspace should be the recorded one, got '$out'"
  pass "herdr workspace_ensure: relaunch recovers through the recorded placement"
}

test_missing_endpoint_creates_replacement_in_recorded_worktree
test_unreadable_endpoint_still_refuses
test_standalone_exit_on_missing_endpoint_still_refuses
test_relaunch_reports_starting_when_replacement_has_no_agent_yet
test_relaunch_confirms_running_replacement
test_relaunch_fails_when_replacement_endpoint_is_gone
test_herdr_placement_recovers_to_verified_recorded_workspace
test_herdr_placement_refuses_a_live_pane
test_herdr_placement_refuses_an_unreadable_pane
test_herdr_placement_refuses_a_cross_session_workspace
test_herdr_placement_refuses_a_closed_or_ambiguous_workspace
test_herdr_placement_is_opt_in_only
test_herdr_workspace_ensure_recovers_through_recorded_placement
