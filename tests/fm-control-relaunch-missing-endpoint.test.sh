#!/usr/bin/env bash
# fm-control.sh relaunch against a tmux endpoint that is authoritatively
# MISSING: the shared tmux server died, or the exact recorded window was
# killed. docs/tmux-backend.md says `dead` and `missing` both authorize
# recovery; this file pins that the relaunch path implements it for tmux.
#
# Unlike tests/fm-control-relaunch.test.sh, which fakes tmux, these cases run
# a REAL tmux server on a private socket (`-L`), because the recreate path
# exercises tmux's own session and window creation and the liveness probe's
# own `missing` verdict. The host's real tmux server is never touched.
#
#   (a) a killed window is recreated in the recorded worktree, in the recorded
#       session, and the relaunch proceeds to a running replacement with the
#       uncommitted work still in place;
#   (b) a server that is gone entirely gets its session AND window recreated;
#   (c) a recorded worktree that is missing, or is not a git work tree, refuses
#       with a message naming that requirement;
#   (d) a worktree another task's record also claims refuses, naming both;
#   (e) an `unreadable` endpoint still refuses (never recreated);
#   (f) a record whose session is not the one the container resolves to
#       refuses rather than silently landing the window elsewhere;
#   (g) `interrupt` and `exit` keep refusing on `missing`;
#   (h) a window renamed away from fm-<id> that still hosts a live agent in
#       the recorded worktree reads `missing` yet refuses, naming the pane,
#       so a second fm-<id> window (and a second agent) is never created;
#   (i) a relaunch run from inside the recorded worktree after the server
#       died still succeeds: the recreated session's own first window is an
#       idle shell rooted there, and a dead shell is not a second agent;
#   (j) a pane inventory that cannot be read refuses rather than recreating.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }
[ -x /bin/bash ] || { echo "skip: /bin/bash not found"; exit 0; }

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-relaunch-missing-$$"
# fm_test_tmproot registers the root in lib.sh's `$$`-keyed cleanup registry;
# this file's own EXIT trap below replaces lib.sh's, so it calls
# fm_test_cleanup last to reap that registry (and the root) itself.
LAB=$(fm_test_tmproot fm-relaunch-missing) || fail "could not create the lab root"
TASK_TMPS=()

cleanup_all() {
  local d
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  fm_test_cleanup
}
trap cleanup_all EXIT

# A `tmux` shim on PATH so every bare `tmux` call from bin/backends/tmux.sh
# reaches the private socket. The config it carries makes every pane a plain
# non-login bash with no rc files, so the pane's PATH is exactly the one the
# server was started with (this shim directory first) on macOS and Linux alike.
# When FM_FAKE_TMUX_UNREADABLE names an existing file, the shim turns every
# window inventory into an error tmux does not emit for an absent session, which
# is exactly the `unreadable` verdict case (e); FM_FAKE_TMUX_PANES_UNREADABLE
# does the same for the pane inventory alone, so the window inventory (and the
# `missing` verdict) stays intact while the occupied-pane guard cannot read (j).
mkdir -p "$LAB/shim" "$LAB/agentbin"
cat > "$LAB/tmux.conf" <<'CONF'
set -g default-shell /bin/bash
set -g default-command "/bin/bash --noprofile --norc"
CONF
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_FAKE_TMUX_UNREADABLE:-}" ] && [ -e "\$FM_FAKE_TMUX_UNREADABLE" ] \\
   && [ "\${1:-}" = list-windows ]; then
  echo "injected inventory failure" >&2
  exit 1
fi
if [ -n "\${FM_FAKE_TMUX_PANES_UNREADABLE:-}" ] && [ -e "\$FM_FAKE_TMUX_PANES_UNREADABLE" ] \\
   && [ "\${1:-}" = list-panes ]; then
  echo "injected pane inventory failure" >&2
  exit 1
fi
exec "$REAL_TMUX" -L "$SOCKET" -f "$LAB/tmux.conf" "\$@"
SH
chmod +x "$LAB/shim/tmux"

# A stand-in `claude`: the launch command fm-spawn types into the recreated
# pane runs this script, which execs a long-running process whose kernel-
# recorded executable identity is `claude` (a symlink to a real binary, never a
# copy: a copied platform binary fails code-signing on macOS arm64). That is
# the exact signal bin/backends/tmux.sh's liveness probe reads for `alive`.
ln -s "$SLEEP_BIN" "$LAB/agentbin/claude"
cat > "$LAB/shim/claude" <<SH
#!/usr/bin/env bash
exec "$LAB/agentbin/claude" 900
SH
chmod +x "$LAB/shim/claude"

PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

private_tmux() {
  "$REAL_TMUX" -L "$SOCKET" -f "$LAB/tmux.conf" "$@"
}

# new_case <name> <id> [session] -> echoes a case dir holding a ship task whose
# record names <session>:fm-<id> (default: firstmate, the session the
# container-ensure resolves to outside tmux) and a real git worktree carrying
# one uncommitted file.
new_case() {
  local name=$1 id=$2 session=${3:-firstmate} dir home proj wt
  dir="$LAB/$name"
  home="$dir/home"
  proj="$dir/proj"
  wt="$dir/wt"
  mkdir -p "$home/state" "$home/data/$id" "$home/config"
  fm_git_worktree "$proj" "$wt" "task-$id"
  printf 'unlanded work for %s\n' "$id" > "$wt/unlanded.txt"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise endpoint recreation for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=$session:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  TASK_TMPS+=("/tmp/fm-$id")
  printf '%s\n' "$dir"
}

# run_env <case-dir> <cmd...>: the control plane against the case home, with
# TMUX unset so the container-ensure resolves to the detached `firstmate`
# session on the private socket rather than to whatever session this test
# itself happens to run in. A claude launch pre-registers workspace trust in
# the launching user's own store, so HOME is a throwaway.
run_env() {
  local dir=$1; shift
  mkdir -p "$dir/user-home"
  env -u TMUX -u TMUX_PANE FM_HOME="$dir/home" HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=1 FM_CONTROL_LAUNCH_WAIT=30 \
    FM_FAKE_TMUX_UNREADABLE="${FM_FAKE_TMUX_UNREADABLE:-}" \
    FM_FAKE_TMUX_PANES_UNREADABLE="${FM_FAKE_TMUX_PANES_UNREADABLE:-}" \
    "$@" 2>&1
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  run_env "$dir" "$CONTROL" "$@"
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  run_env "$dir" "$SPAWN" "$@"
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

journal_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.control-relaunch" | tail -1 | cut -d= -f2-
}

# stop_server: kill the private server and wait until it is actually gone.
# `kill-server` returns as soon as the server acknowledges; the server then
# reaps its panes (a recreated window hosts the stand-in agent) and closes its
# listening socket a moment later, while the socket file itself stays behind.
# A client that connects during that window reaches the dying server and fails
# with "server exited unexpectedly" instead of starting a fresh one, so wait
# until a client can no longer connect at all before returning. `list-sessions`
# never starts a server of its own, so it is a pure probe.
stop_server() {
  local _ probe=''
  private_tmux kill-server >/dev/null 2>&1 || true
  for _ in $(seq 1 100); do
    if probe=$(private_tmux list-sessions 2>&1 >/dev/null); then
      sleep 0.1
      continue
    fi
    case $probe in
      *"no server running on "*|*"error connecting to "*) return 0 ;;
    esac
    sleep 0.1
  done
  fail "the private tmux server did not exit after kill-server: $probe"
}

# start_server: a fresh private server whose only session is `firstmate` with
# one idle window, so a recorded fm-<id> window is authoritatively absent.
start_server() {
  stop_server
  private_tmux new-session -d -s firstmate -n idle -c "$LAB" \
    || fail "could not start the private tmux server"
}

pane_path() {  # <target>
  private_tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

real_path() {  # <path>
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

assert_relaunched_into_recorded_worktree() {  # <case-dir> <id> <out>
  local dir=$1 id=$2 out=$3 target seen
  target="firstmate:fm-$id"
  assert_contains "$out" "relaunched $id harness=claude from=claude" "the outcome should name the transition"
  [ "$(meta_field "$dir" "$id" window)" = "$target" ] \
    || fail "the recorded endpoint must be reused byte-exact, got '$(meta_field "$dir" "$id" window)'"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/wt" ] \
    || fail "the recorded worktree must be reused, got '$(meta_field "$dir" "$id" worktree)'"
  [ "$(journal_field "$dir" "$id" phase)" = complete ] \
    || fail "the transaction journal should end complete, got '$(journal_field "$dir" "$id" phase)'"
  [ "$(journal_field "$dir" "$id" exit_result)" = endpoint-missing ] \
    || fail "the stop step should have recorded the endpoint as missing, got '$(journal_field "$dir" "$id" exit_result)'"
  private_tmux list-windows -t firstmate -F '#{window_name}' | grep -qx "fm-$id" \
    || fail "the recorded window fm-$id must exist again in the firstmate session"
  seen=$(pane_path "$target")
  [ "$(real_path "$seen")" = "$(real_path "$dir/wt")" ] \
    || fail "the recreated window must sit in the recorded worktree, got '$seen'"
  [ "$(fm_backend_agent_state tmux "$target")" = alive ] \
    || fail "the replacement agent should read alive in the recreated window"
  grep -qx "unlanded work for $id" "$dir/wt/unlanded.txt" 2>/dev/null \
    || fail "the uncommitted work in the recorded worktree must survive the relaunch"
}

# --- (a) killed window -------------------------------------------------------

test_relaunch_recreates_a_killed_window() {
  local dir out rc
  start_server
  dir=$(new_case killed-window mw1)
  [ "$(fm_backend_agent_state tmux firstmate:fm-mw1)" = missing ] \
    || fail "precondition: the recorded window must read missing before the relaunch"
  out=$(run_control "$dir" mw1 relaunch --note "server hiccup"); rc=$?
  expect_code 0 "$rc" "a relaunch against a killed tmux window should succeed"$'\n'"$out"
  assert_relaunched_into_recorded_worktree "$dir" mw1 "$out"
  pass "fm-control relaunch: a killed tmux window is recreated in the recorded worktree and the relaunch proceeds"
}

# --- (b) server gone --------------------------------------------------------

test_relaunch_recreates_session_and_window_after_server_death() {
  local dir out rc
  stop_server
  dir=$(new_case server-gone mw2)
  [ "$(fm_backend_agent_state tmux firstmate:fm-mw2)" = missing ] \
    || fail "precondition: a stopped server must read missing before the relaunch"
  out=$(run_control "$dir" mw2 relaunch --note "server died"); rc=$?
  expect_code 0 "$rc" "a relaunch after the tmux server died should succeed"$'\n'"$out"
  private_tmux has-session -t firstmate 2>/dev/null \
    || fail "the firstmate session must have been recreated"
  assert_relaunched_into_recorded_worktree "$dir" mw2 "$out"
  pass "fm-control relaunch: a dead tmux server gets its session and window recreated"
}

# --- (c) worktree missing or not a git work tree -----------------------------

test_relaunch_refuses_when_the_recorded_worktree_is_missing() {
  local dir out rc
  start_server
  dir=$(new_case wt-missing mw3)
  rm -rf "$dir/wt"
  out=$(run_control "$dir" mw3 relaunch --note "server hiccup"); rc=$?
  expect_code 1 "$rc" "a relaunch must refuse when the recorded worktree is missing"
  assert_contains "$out" "recorded worktree $dir/wt is missing" "the refusal should name the missing worktree"
  private_tmux list-windows -t firstmate -F '#{window_name}' | grep -qx fm-mw3 \
    && fail "no window may be recreated for a task whose worktree is missing"
  pass "fm-control relaunch: a missing recorded worktree refuses before any endpoint is recreated"
}

test_spawn_relaunch_refuses_when_the_recorded_worktree_is_not_a_git_work_tree() {
  local dir out rc
  start_server
  dir=$(new_case wt-not-git mw4)
  rm -rf "$dir/wt"
  mkdir -p "$dir/wt"
  out=$(run_spawn "$dir" mw4 --relaunch); rc=$?
  expect_code 1 "$rc" "fm-spawn --relaunch must refuse a recorded worktree that is not a git work tree"
  assert_contains "$out" "recorded worktree '$dir/wt' is not a git work tree" "the refusal should name the git-work-tree requirement"
  private_tmux list-windows -t firstmate -F '#{window_name}' | grep -qx fm-mw4 \
    && fail "no window may be recreated over a directory that is not a git work tree"
  pass "fm-spawn --relaunch: a recorded worktree that is not a git work tree refuses before any endpoint is recreated"
}

# --- (d) worktree collision --------------------------------------------------

test_relaunch_refuses_a_worktree_two_tasks_record() {
  local dir out rc
  start_server
  dir=$(new_case wt-collision mw5)
  sed 's/^endpoint_task_id=mw5$/endpoint_task_id=mw5b/; s/^window=firstmate:fm-mw5$/window=firstmate:fm-mw5b/; s#^tasktmp=/tmp/fm-mw5$#tasktmp=/tmp/fm-mw5b#' \
    "$dir/home/state/mw5.meta" > "$dir/home/state/mw5b.meta"
  TASK_TMPS+=(/tmp/fm-mw5b)
  out=$(run_control "$dir" mw5 relaunch --note "server hiccup"); rc=$?
  expect_code 1 "$rc" "a relaunch must refuse when another task records the same worktree"
  assert_contains "$out" "recorded worktree '$dir/wt' is also recorded by task mw5b" "the refusal should name the colliding task"
  assert_contains "$out" "reconcile mw5 and mw5b first" "the refusal should name both tasks"
  private_tmux list-windows -t firstmate -F '#{window_name}' | grep -qx fm-mw5 \
    && fail "no window may be recreated over a worktree two tasks claim"
  pass "fm-control relaunch: a worktree collision with another task's record refuses and names both tasks"
}

# --- (e) unreadable ----------------------------------------------------------

test_relaunch_still_refuses_an_unreadable_endpoint() {
  local dir out rc
  start_server
  dir=$(new_case unreadable mw6)
  : > "$dir/unreadable.flag"
  [ "$(FM_FAKE_TMUX_UNREADABLE="$dir/unreadable.flag" fm_backend_agent_state tmux firstmate:fm-mw6)" = unreadable ] \
    || fail "precondition: the injected inventory failure must read unreadable"
  out=$(FM_FAKE_TMUX_UNREADABLE="$dir/unreadable.flag" run_control "$dir" mw6 relaunch --note "server hiccup"); rc=$?
  expect_code 1 "$rc" "a relaunch must refuse an unreadable endpoint"
  assert_contains "$out" "reads 'unreadable' rather than a positively classified state" "the refusal should name the unreadable verdict"
  out=$(FM_FAKE_TMUX_UNREADABLE="$dir/unreadable.flag" run_spawn "$dir" mw6 --relaunch); rc=$?
  expect_code 1 "$rc" "fm-spawn --relaunch must refuse an unreadable endpoint on its own"
  assert_contains "$out" "endpoint reads 'unreadable'" "the launch owner's refusal should name the unreadable verdict"
  rm -f "$dir/unreadable.flag"
  private_tmux list-windows -t firstmate -F '#{window_name}' | grep -qx fm-mw6 \
    && fail "an unreadable endpoint must never be recreated"
  pass "fm-control relaunch: an unreadable tmux endpoint still refuses and is never recreated"
}

# --- (f) record in a different session ---------------------------------------

test_relaunch_refuses_a_record_in_another_session() {
  local dir out rc
  start_server
  dir=$(new_case other-session mw7 elsewhere)
  out=$(run_control "$dir" mw7 relaunch --note "server hiccup"); rc=$?
  expect_code 1 "$rc" "a relaunch must refuse a record whose session is not the one the container resolves to"
  assert_contains "$out" "records endpoint 'elsewhere:fm-mw7', but this home's tmux container resolves to session 'firstmate'" \
    "the refusal should name both the recorded and the resolved session"
  private_tmux list-windows -t firstmate -F '#{window_name}' | grep -qx fm-mw7 \
    && fail "a record in another session must never be recreated under the container's session"
  [ "$(meta_field "$dir" mw7 window)" = "elsewhere:fm-mw7" ] \
    || fail "the record must not be rewritten to the container's session"
  pass "fm-control relaunch: a record in a different session refuses rather than silently renaming"
}

# --- (g) interrupt and exit keep refusing on missing -------------------------

test_interrupt_and_exit_keep_refusing_on_missing() {
  local dir out rc
  start_server
  dir=$(new_case no-agent mw8)
  out=$(run_control "$dir" mw8 interrupt); rc=$?
  expect_code 1 "$rc" "interrupt must refuse a missing endpoint"
  assert_contains "$out" "no agent is running at task mw8's recorded endpoint (state: missing)" "interrupt should name the missing endpoint"
  out=$(run_control "$dir" mw8 exit); rc=$?
  expect_code 1 "$rc" "exit must refuse a missing endpoint"
  assert_contains "$out" "recorded endpoint is gone, so there is no agent to stop" "exit should name the missing endpoint"
  private_tmux list-windows -t firstmate -F '#{window_name}' | grep -qx fm-mw8 \
    && fail "neither interrupt nor exit may recreate an endpoint"
  pass "fm-control: interrupt and exit keep refusing on a missing tmux endpoint"
}

# --- (h) renamed window still hosting the agent ------------------------------

# wait_state <target> <state>: poll the liveness probe until it reads <state>.
wait_state() {
  local _
  for _ in $(seq 1 50); do
    [ "$(fm_backend_agent_state tmux "$1")" = "$2" ] && return 0
    sleep 0.2
  done
  return 1
}

test_relaunch_refuses_when_a_renamed_pane_still_sits_in_the_worktree() {
  local dir out rc alive_windows
  start_server
  dir=$(new_case renamed-window mw9)
  private_tmux new-window -d -t firstmate: -n fm-mw9 -c "$dir/wt" \
    || fail "could not create the recorded window in the recorded worktree"
  private_tmux send-keys -t firstmate:fm-mw9 'claude' Enter
  wait_state firstmate:fm-mw9 alive \
    || fail "precondition: the stand-in agent must read alive in the recorded window"
  private_tmux rename-window -t firstmate:fm-mw9 detached-name \
    || fail "could not rename the recorded window away"
  [ "$(fm_backend_agent_state tmux firstmate:fm-mw9)" = missing ] \
    || fail "precondition: the recorded name must read missing once the window is renamed away"
  out=$(run_control "$dir" mw9 relaunch --note "server hiccup"); rc=$?
  expect_code 1 "$rc" "a relaunch must refuse while a pane still sits in the recorded worktree"$'\n'"$out"
  assert_contains "$out" "pane firstmate:detached-name.0 already sits in its recorded worktree '$dir/wt' and reads 'alive'" \
    "the refusal should name the occupying pane, the worktree, and the pane's verdict"
  private_tmux list-windows -t firstmate -F '#{window_name}' | grep -qx fm-mw9 \
    && fail "no second fm-mw9 window may be created beside the renamed one"
  [ "$(private_tmux list-windows -t firstmate -F '#{window_name}' | wc -l | tr -d ' ')" = 2 ] \
    || fail "the session must still hold exactly the idle and renamed windows"
  alive_windows=$(private_tmux list-windows -t firstmate -F '#{window_name}' | while read -r w; do
    [ "$(fm_backend_agent_state tmux "firstmate:$w")" = alive ] && printf '%s\n' "$w"
  done)
  [ "$alive_windows" = detached-name ] \
    || fail "exactly the renamed window may host an agent after the refusal, got '$alive_windows'"
  [ "$(meta_field "$dir" mw9 window)" = "firstmate:fm-mw9" ] \
    || fail "the record must be left untouched by the refusal"
  pass "fm-control relaunch: a window renamed away from fm-<id> that still sits in the worktree refuses, naming the pane"
}

# --- (i) relaunch run from inside the worktree after server death -----------

test_relaunch_from_inside_the_worktree_after_server_death() {
  local dir out rc first_window first_path
  stop_server
  dir=$(new_case from-worktree mwa)
  out=$(cd "$dir/wt" && run_control "$dir" mwa relaunch --note "server died"); rc=$?
  expect_code 0 "$rc" "a relaunch run from inside the recorded worktree must succeed after the server died"$'\n'"$out"
  first_window=$(private_tmux list-windows -t firstmate -F '#{window_name}' | head -1)
  first_path=$(pane_path "firstmate:$first_window")
  [ "$(real_path "$first_path")" = "$(real_path "$dir/wt")" ] \
    || fail "precondition: the recreated session's first window must be rooted in the caller's cwd, the worktree, got '$first_path'"
  [ "$(fm_backend_agent_state tmux "firstmate:$first_window")" = dead ] \
    || fail "precondition: the recreated session's first window must be an idle shell"
  assert_relaunched_into_recorded_worktree "$dir" mwa "$out"
  pass "fm-control relaunch: an idle shell in the worktree (the recreated session's own first window) never blocks the recreate"
}

# --- (j) pane inventory unreadable ------------------------------------------

test_relaunch_refuses_when_the_pane_inventory_cannot_be_read() {
  local dir out rc
  start_server
  dir=$(new_case panes-unreadable mwb)
  : > "$dir/panes-unreadable.flag"
  [ "$(FM_FAKE_TMUX_PANES_UNREADABLE="$dir/panes-unreadable.flag" fm_backend_agent_state tmux firstmate:fm-mwb)" = missing ] \
    || fail "precondition: the window inventory must still read missing while only the pane inventory fails"
  out=$(FM_FAKE_TMUX_PANES_UNREADABLE="$dir/panes-unreadable.flag" run_control "$dir" mwb relaunch --note "server hiccup"); rc=$?
  expect_code 1 "$rc" "a relaunch must refuse when the pane inventory cannot be read"$'\n'"$out"
  assert_contains "$out" "could not inventory panes of session firstmate" "the refusal should name the unreadable pane inventory"
  rm -f "$dir/panes-unreadable.flag"
  private_tmux list-windows -t firstmate -F '#{window_name}' | grep -qx fm-mwb \
    && fail "an unreadable pane inventory must never license a recreate"
  pass "fm-control relaunch: an unreadable pane inventory refuses rather than recreating"
}

test_relaunch_recreates_a_killed_window
test_relaunch_recreates_session_and_window_after_server_death
test_relaunch_refuses_when_the_recorded_worktree_is_missing
test_spawn_relaunch_refuses_when_the_recorded_worktree_is_not_a_git_work_tree
test_relaunch_refuses_a_worktree_two_tasks_record
test_relaunch_still_refuses_an_unreadable_endpoint
test_relaunch_refuses_a_record_in_another_session
test_interrupt_and_exit_keep_refusing_on_missing
test_relaunch_refuses_when_a_renamed_pane_still_sits_in_the_worktree
test_relaunch_from_inside_the_worktree_after_server_death
test_relaunch_refuses_when_the_pane_inventory_cannot_be_read
