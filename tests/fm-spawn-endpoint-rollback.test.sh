#!/usr/bin/env bash
# Regression test for the fm-spawn.sh transactional endpoint rollback
# (bin/fm-spawn.sh, spawn_endpoint_abort_rollback: the abort trap closes
# the endpoint a fresh spawn created but never recorded).
#
# The fm-dos-qwus2 incident: Treehouse returned the spawning project with every
# pool copy in use or dirty, so `treehouse get` never moved the pane into an
# isolated worktree, the isolation wait refused at its deadline, and the window
# fm_backend_tmux_create_task had just created survived as an unrecorded idle
# endpoint. No task record named it, so nothing else could ever close it, and
# the clean retry refused on "window <session>:fm-<id> already exists".
#
# These cases drive the REAL fm-spawn.sh end to end against a stateful fake
# tmux that models the window lifecycle (create, read, kill) and assert:
#   - the refused spawn's own window is rolled back, no task record is left,
#     and the retry then spawns cleanly into a real worktree;
#   - a window that no longer answers as this spawn's own endpoint (a
#     pre-existing or externally replaced one) is never closed;
#   - a partial task record blocks the rollback (a record owns the endpoint);
#   - a pane whose foreground classifies as a live agent is never torn down.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-endpoint-rollback)

# make_rollback_fakebin <dir> builds the stateful fake tmux. Window state
# lives in <dir>/window-state/{windows,next-id}; every kill-window appends
# "kill-window<TAB>target" to FM_FAKE_TMUX_KILL_LOG.
#
# Env knobs:
#   FM_FAKE_PANE_PATH          pane cwd for every #{pane_current_path} read
#   FM_FAKE_PANE_COMMAND       #{pane_current_command} (default bash)
#   FM_FAKE_WINDOW_NAME_OVERRIDE  #{window_name} answers this instead of the
#                              recorded name - models a window id that no
#                              longer belongs to the name create_task pinned
#   FM_FAKE_PLANT_PARTIAL_META  path planted (window= line only) on the first
#                              send-keys - the partial record case
#   FM_FAKE_LAUNCH_LOG         send-keys -l payloads appended one per line
make_rollback_fakebin() {
  local dir=$1 fakebin statedir
  fakebin=$(fm_fakebin "$dir")
  statedir="$dir/window-state"
  mkdir -p "$statedir"
  printf '1\n' > "$statedir/next-id"
  : > "$statedir/windows"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
statedir="@STATEDIR@"
windows="$statedir/windows"
nextid="$statedir/next-id"

field() {  # <line> <n> -> field n (tab-separated)
  printf '%s' "$1" | cut -f"$2"
}

lookup() {  # <id-or-name> -> prints "id<TAB>name<TAB>cwd", 1 when absent
  local key=$1 line
  while IFS= read -r line; do
    if [ "$(field "$line" 1)" = "$key" ] || [ "$(field "$line" 2)" = "$key" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < "$windows"
  return 1
}

resolve_target() {  # <target> -> window key (id or name)
  local t=${1#=}
  t=${t#firstmate:=}
  t=${t#firstmate:}
  printf '%s' "$t"
}

cmd=${1:-}
shift || true
case "$cmd" in
  has-session|new-session)
    exit 0 ;;
  set-window-option)
    exit 0 ;;
  new-window)
    name= cwd=
    while [ $# -gt 0 ]; do
      case $1 in
        -n) name=$2; shift 2 ;;
        -c) cwd=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    n=$(cat "$nextid")
    printf '%s\n' $((n + 1)) > "$nextid"
    printf '@%s\t%s\t%s\n' "$n" "$name" "$cwd" >> "$windows"
    printf '@%s\n' "$n"
    exit 0 ;;
  kill-window)
    target=
    while [ $# -gt 0 ]; do
      case $1 in
        -t) target=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'kill-window\t%s\n' "$target" >> "${FM_FAKE_TMUX_KILL_LOG:?FM_FAKE_TMUX_KILL_LOG unset}"
    key=$(resolve_target "$target")
    tmp="$statedir/windows.tmp"
    : > "$tmp"
    while IFS= read -r line; do
      if [ "$(field "$line" 1)" = "$key" ] || [ "$(field "$line" 2)" = "$key" ]; then
        continue
      fi
      printf '%s\n' "$line" >> "$tmp"
    done < "$windows"
    mv -f "$tmp" "$windows"
    exit 0 ;;
  list-windows)
    cut -f2 "$windows"
    exit 0 ;;
  display-message)
    target= fmt=
    while [ $# -gt 0 ]; do
      case $1 in
        -t) target=$2; shift 2 ;;
        *'#'*) fmt=$1; shift ;;
        *) shift ;;
      esac
    done
    if [ -z "$target" ]; then
      # container-ensure's '#S' read: firstmate always exists here.
      printf 'firstmate\n'
      exit 0
    fi
    key=$(resolve_target "$target")
    line=$(lookup "$key") || exit 1
    name=$(field "$line" 2)
    case "$fmt" in
      *window_name*)
        printf '%s\n' "${FM_FAKE_WINDOW_NAME_OVERRIDE:-$name}" ;;
      *pane_current_path*)
        printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
      *pane_current_command*)
        printf '%s\n' "${FM_FAKE_PANE_COMMAND:-bash}" ;;
      *pane_tty*)
        printf '%s\n' "/dev/fm-fake-pts9" ;;
      *cursor_y*)
        printf '1\n' ;;
      *pane_id*)
        printf '%%1\n' ;;
      *) exit 1 ;;
    esac
    exit 0 ;;
  capture-pane)
    printf '%s' "${FM_FAKE_CAPTURE:-}"
    exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_PLANT_PARTIAL_META:-}" ] && [ ! -e "$FM_FAKE_PLANT_PARTIAL_META" ]; then
      printf 'window=firstmate:fm-fm-partial-meta-x3\n' > "$FM_FAKE_PLANT_PARTIAL_META"
    fi
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0 ;;
esac
exit 0
SH
  sed "s|@STATEDIR@|$statedir|g" "$fakebin/tmux" > "$fakebin/tmux.tmp"
  mv "$fakebin/tmux.tmp" "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  fm_test_fake_sleep_noop "$fakebin"
  fm_test_fake_no_mistakes "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_rollback_case <name> <id> builds the home, the project with a real
# worktree (the retry's settled path), and the fake tmux. Prints a
# pipe-delimited record describing the case.
make_rollback_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_rollback_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id" "Exercise the endpoint rollback for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_rollback_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_rollback_spawn() {  # <id> [extra env as NAME=VALUE...]
  local id=$1
  shift
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$@" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# The incident shape: the pane never leaves the project, so the isolation wait
# refuses at its deadline. The abort trap must then close exactly the window
# this spawn created - the retry must not inherit an unowned
# "window <session>:fm-<id> already exists".
test_refused_isolation_rolls_back_window_and_retry_succeeds() {
  local rec id kill_log out status retry_out retry_status
  id=fm-rollback-retry-x1
  rec=$(make_rollback_case rollback-retry "$id")
  read_rollback_record "$rec"
  kill_log="$CASE_DIR/kill.log"

  out=$(FM_FAKE_PANE_PATH="$PROJ_DIR" FM_FAKE_TMUX_KILL_LOG="$kill_log" \
    run_rollback_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the pane never reaches an isolated worktree"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "the refusal did not name the isolation deadline"
  assert_grep "kill-window" "$kill_log" \
    "the refused spawn did not roll back its own window"
  assert_no_grep "leaving endpoint" "$out" \
    "the rollback refused a proof it should have passed"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn published a task record"

  # The clean retry: the same task id, pane now settling into a real worktree.
  # This is the flow the incident blocked with "window already exists".
  retry_out=$(FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_TMUX_KILL_LOG="$kill_log" \
    run_rollback_spawn "$id")
  retry_status=$?
  expect_code 0 "$retry_status" "the retry should spawn cleanly once its window is gone"$'\n'"$retry_out"
  assert_contains "$retry_out" "spawned $id" "the retry did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "the retry did not record the settled worktree"
  pass "a refused isolation rolls back its own window and the retry spawns cleanly"
}

# A window id that no longer answers as the name this spawn pinned is someone
# else's endpoint (pre-existing or replaced): the rollback must leave it open.
test_preexisting_window_is_never_closed() {
  local rec id kill_log out status
  id=fm-preexisting-x2
  rec=$(make_rollback_case preexisting "$id")
  read_rollback_record "$rec"
  kill_log="$CASE_DIR/kill.log"

  out=$(FM_FAKE_PANE_PATH="$PROJ_DIR" FM_FAKE_TMUX_KILL_LOG="$kill_log" \
    FM_FAKE_WINDOW_NAME_OVERRIDE="fm-someone-else" \
    run_rollback_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the pane never reaches an isolated worktree"$'\n'"$out"
  assert_contains "$out" "no longer answers as fm-$id" \
    "the rollback did not name the identity failure"
  assert_absent "$kill_log" \
    "the rollback closed a window that was not this spawn's own"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn published a task record"
  pass "a pre-existing or replaced window is never closed by the rollback"
}

# A partial task record means some record owns the endpoint: the rollback
# steps aside instead of closing a window a record may describe.
test_partial_metadata_blocks_rollback() {
  local rec id kill_log out status planted
  id=fm-partial-meta-x3
  rec=$(make_rollback_case partial-meta "$id")
  read_rollback_record "$rec"
  kill_log="$CASE_DIR/kill.log"
  planted="$HOME_DIR/state/$id.meta"

  out=$(FM_FAKE_PANE_PATH="$PROJ_DIR" FM_FAKE_TMUX_KILL_LOG="$kill_log" \
    FM_FAKE_PLANT_PARTIAL_META="$planted" \
    run_rollback_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the pane never reaches an isolated worktree"$'\n'"$out"
  assert_contains "$out" "a task record exists" \
    "the rollback did not name the task record as the reason"
  assert_absent "$kill_log" \
    "the rollback closed an endpoint a partial record owns"
  assert_present "$planted" "the planted partial record must survive untouched"
  pass "a partial task record blocks the rollback"
}

# A pane whose foreground classifies as a live agent is never torn down, even
# though every other proof (identity, record, copy) would pass.
test_live_agent_blocks_rollback() {
  local rec id kill_log out status
  id=fm-live-agent-x4
  rec=$(make_rollback_case live-agent "$id")
  read_rollback_record "$rec"
  kill_log="$CASE_DIR/kill.log"

  out=$(FM_FAKE_PANE_PATH="$PROJ_DIR" FM_FAKE_TMUX_KILL_LOG="$kill_log" \
    FM_FAKE_PANE_COMMAND="claude" \
    run_rollback_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the pane never reaches an isolated worktree"$'\n'"$out"
  assert_contains "$out" "not provably agent-free" \
    "the rollback did not name the live agent as the reason"
  assert_absent "$kill_log" \
    "the rollback closed a pane holding a live agent"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn published a task record"
  pass "a live agent blocks the rollback"
}

test_refused_isolation_rolls_back_window_and_retry_succeeds
test_preexisting_window_is_never_closed
test_partial_metadata_blocks_rollback
test_live_agent_blocks_rollback

echo "# all fm-spawn-endpoint-rollback tests passed"
