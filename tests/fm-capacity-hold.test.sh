#!/usr/bin/env bash
# Tests for the treehouse pool capacity hold: bin/fm-spawn.sh detecting
# treehouse's exact "all N worktrees are in use" refusal during the
# treehouse-get wait, holding the still-Queued item instead of silently
# waiting 60 seconds, and bin/fm-teardown.sh releasing the oldest hold for
# the same pool once a worktree is returned to it
# (bin/fm-capacity-lib.sh owns the reason contract).
#
# Spawn side: a fake pane never leaves the project directory and renders the
# refusal wrapped across narrow lines, so the flattened capture match is proven
# against real wrapping; the pool identity comes from a fake
# `treehouse status --json` answering one worktree under a scratch pool root.
# A manual-backend home proves the refusal still exits 2 without inventing a
# hold it cannot record.
#
# Teardown side: a landed local-only worktree under <pool>/7/wt is torn down
# through the real script, and the release must unhold exactly the oldest
# capacity hold recorded for that pool, leaving a same-pool newer hold, a
# different-pool hold, and a non-capacity hold all in place.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-capacity-hold)

# --- spawn side --------------------------------------------------------------

# A fake tmux whose pane never leaves the project (treehouse get refused) and
# whose capture serves the wrapped refusal from a file, plus a fake treehouse
# whose `status --json` names one worktree under the scratch pool.
make_spawn_fakebin() {  # <dir> <refusal-file>
  local dir=$1 refusal=$2 fakebin pool
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  pool="$dir/pool"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"\#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in
  capture-pane)
    if [ -n "\${FM_FAKE_PANE_TEXT_FILE:-}" ] && [ -f "\$FM_FAKE_PANE_TEXT_FILE" ]; then
      cat "\$FM_FAKE_PANE_TEXT_FILE"
    fi
    exit 0
    ;;
  display-message)
    case "\$*" in
      *'#{pane_id}'*)
        # A killed window is gone: the presence probe for it must fail, unless
        # the fake is standing in for a kill that returned 0 without closing.
        if [ -s "\${FM_FAKE_TMUX_KILL_LOG:-/dev/null}" ] \
           && [ -z "\${FM_FAKE_TMUX_KILL_REFUSED:-}" ]; then
          exit 1
        fi
        printf '%%1\n'
        exit 0
        ;;
    esac
    printf 'firstmate\n'
    exit 0
    ;;
  list-windows) exit 0 ;;
  kill-window)
    printf '%s\n' "\$*" >> "\${FM_FAKE_TMUX_KILL_LOG:-/dev/null}"
    exit 0
    ;;
  has-session|new-session|new-window|set-window-option) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "status --json")
    printf '[{"name":"7","path":"$pool/7/project","status":"in-use","flavor":"git","lease_id":"","lease_holder":"","leased_at":null,"processes":[]}]'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# The refusal, wrapped the way a narrow pane would wrap it, so the flattened
# match cannot depend on where the line breaks fall.
write_refusal() {  # <file>
  cat > "$1" <<'EOF'
$ treehouse get
all 3 worktrees are in use or dirty
(max_trees = 4). Run 'treehouse
status' to see details, or increase
max_trees in treehouse.toml
EOF
}

# Build the spawn fixture: home with a seeded markdown backlog, project repo,
# brief, and the pool-full pane. Echoes "<case>|<home>|<proj>|<fakebin>".
make_spawn_case() {  # <name> <manual 0|1>
  local name=$1 manual=$2 case_dir home proj fakebin refusal spawn_home
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  if [ "$manual" = 1 ]; then
    printf 'manual\n' > "$home/config/backlog-backend"
  else
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    tasks-axi add cap-x1 "capacity fixture task" --kind ship \
      --file "$home/data/backlog.md" >/dev/null
  fi
  mkdir -p "$home/data/cap-x1"
  cat > "$home/data/cap-x1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the pool-full capacity hold.

## Firstmate spec
Detect the treehouse refusal and hold the item.
EOF
  fm_git_worktree "$proj" "$case_dir/wt" "wt-$name" >/dev/null 2>&1
  refusal="$case_dir/refusal.txt"
  write_refusal "$refusal"
  fakebin=$(make_spawn_fakebin "$case_dir" "$refusal")
  printf '%s\n' "$case_dir|$home|$proj|$fakebin"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR FAKEBIN <<EOF
$1
EOF
}

run_capacity_spawn() {  # [fm-spawn args...]
  local spawn_home="$HOME_DIR/user-home"
  mkdir -p "$spawn_home"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$spawn_home" \
    CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$PROJ_DIR" \
    FM_FAKE_TMUX_KILL_LOG="$CASE_DIR/tmux-kill.log" \
    FM_FAKE_PANE_TEXT_FILE="$CASE_DIR/refusal.txt" TMUX="fake,1,0" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_pool_full_refusal_holds_and_exits_two() {
  local rec out rc pool
  rec=$(make_spawn_case hold-z1 0)
  read_spawn_record "$rec"
  pool="$CASE_DIR/pool"
  out=$(run_capacity_spawn cap-x1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  rc=$?
  expect_code 2 "$rc" "pool-full spawn must exit 2, got $rc"
  assert_contains "$out" "held: cap-x1 - pool $pool full 3/4; item left queued" \
    "the one hold line must name the item, pool, and counts"
  # The endpoint this path created is closed here, so the redispatch after a
  # release can create it again instead of colliding with a stale one.
  assert_contains "$(cat "$CASE_DIR/tmux-kill.log" 2>/dev/null)" "fm-cap-x1" \
    "the refusal must close the endpoint it created for the held task"
  assert_contains "$out" "endpoint firstmate:fm-cap-x1 closed" \
    "the hold line must state that the endpoint was closed"
  assert_not_contains "$out" "STILL OPEN" \
    "a proven-closed endpoint must not warn about a manual close"
  local show
  show=$(tasks-axi show cap-x1 --file "$HOME_DIR/data/backlog.md" 2>/dev/null)
  assert_contains "$show" "state: queued" "held item must stay queued, not in flight"
  assert_contains "$show" "held: yes" "item must be held"
  assert_contains "$show" "hold_kind: load" "capacity hold uses the load kind"
  assert_contains "$show" "hold_reason: pool $pool full 3/4" \
    "hold reason must carry the exact pool identity and counts"
  [ ! -e "$HOME_DIR/state/cap-x1.meta" ] || fail "pool-full spawn published a task record"
  pass "a full pool holds the queued item with a load-kind capacity reason and exits 2"
}

test_pool_full_refusal_on_manual_home_exits_two_without_hold() {
  local rec out rc
  rec=$(make_spawn_case manual-z2 1)
  read_spawn_record "$rec"
  out=$(run_capacity_spawn cap-x1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  rc=$?
  expect_code 2 "$rc" "manual-home pool-full spawn must exit 2, got $rc"
  assert_contains "$out" "refused: cap-x1 - pool $CASE_DIR/pool full 3/4" \
    "manual-home refusal must name the pool-full reason"
  assert_contains "$out" "record the hold by hand" \
    "manual-home refusal must say the hold is the operator's to record"
  assert_not_contains "$out" "held: cap-x1" "manual home must not claim a recorded hold"
  assert_contains "$(cat "$CASE_DIR/tmux-kill.log" 2>/dev/null)" "fm-cap-x1" \
    "a manual-home refusal must close its endpoint too"
  [ ! -e "$HOME_DIR/data/backlog.md" ] || fail "manual home unexpectedly owns a backlog file"
  [ ! -e "$HOME_DIR/state/cap-x1.meta" ] || fail "manual-home pool-full spawn published a task record"
  pass "a full pool on a manual-backend home still exits 2 and records no phantom hold"
}

# Backend closes are best effort and some refuse while still returning 0, so
# the refusal reads the endpoint back and reports what the read proved. An
# endpoint still standing is the operator's to close: the redispatch after the
# hold is released cannot create a second endpoint for the same task.
test_pool_full_refusal_reports_an_endpoint_it_could_not_close() {
  local rec out rc pool
  rec=$(make_spawn_case refused-z3 0)
  read_spawn_record "$rec"
  pool="$CASE_DIR/pool"
  out=$(FM_FAKE_TMUX_KILL_REFUSED=1 run_capacity_spawn cap-x1 "$PROJ_DIR" \
    --mode no-mistakes --yolo off 2>&1)
  rc=$?
  expect_code 2 "$rc" "a refused endpoint close must still exit 2, got $rc"
  assert_contains "$out" "held: cap-x1 - pool $pool full 3/4; item left queued" \
    "the hold is still recorded when the endpoint could not be closed"
  assert_contains "$out" "endpoint firstmate:fm-cap-x1 IS STILL OPEN" \
    "the line must say the endpoint is still open, never claim it closed"
  assert_contains "$out" "warning: the capacity refusal could not close endpoint" \
    "an unclosed endpoint must be reported loudly enough to act on"
  assert_not_contains "$out" "closed so the redispatch can create it again" \
    "the refusal must not claim a close it could not prove"
  pass "an endpoint the refusal could not close is reported, never claimed closed"
}

# --- teardown side -----------------------------------------------------------

make_teardown_case() {  # <name> [fallback-pool-identity]
  local name=$1 fallback=${2:-} case_dir fakebin pool a_reason b_reason
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  pool="$case_dir/pool"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin" "$pool"

  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "status --json")
    printf '[{"name":"7","path":"$pool/7/wt","status":"in-use","flavor":"git","lease_id":"","lease_holder":"","leased_at":null,"processes":[]}]'
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
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
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi) shift; case "${1:-}" in status) shift; printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;; esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  # A landed local-only task: worktree under the scratch pool, branch pushed to
  # a fork remote, so teardown's landed-work gate passes.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$pool/7/wt" main
  git -C "$pool/7/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "wt work"
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  git -C "$pool/7/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork

  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$pool/7/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=capacity-test-task-x1"

  # The backlog: the torn-down task In flight, plus four held rows. Without a
  # fallback identity, task-a and task-b carry this pool's capacity reason:
  #   task-a: oldest capacity hold for THIS pool   -> must be released
  #   task-b: newer capacity hold for this pool    -> must stay held
  #   task-c: capacity hold for a DIFFERENT pool   -> must stay held
  #   task-d: non-capacity external hold           -> must stay held
  # With a fallback identity, task-a and task-b carry that identity instead
  # (spawn's project-root fallback when treehouse could not answer), so the
  # worktree-derived scan matches nothing and the fallback scan must release
  # task-a, the oldest fallback-identity hold.
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/data/backlog.md"
  local backlog="$case_dir/data/backlog.md"
  a_reason="pool $pool full 3/4"
  b_reason="pool $pool full 3/4"
  if [ -n "$fallback" ]; then
    a_reason="pool $fallback full 3/4"
    b_reason="pool $fallback full 2/4"
  fi
  tasks-axi add task-x1 "teardown fixture task" --kind ship --file "$backlog" >/dev/null
  tasks-axi start task-x1 --file "$backlog" >/dev/null
  tasks-axi add task-a "oldest held" --kind ship --file "$backlog" >/dev/null
  tasks-axi add task-b "newer held" --kind ship --file "$backlog" >/dev/null
  tasks-axi add task-c "other pool" --kind ship --file "$backlog" >/dev/null
  tasks-axi add task-d "external" --kind ship --file "$backlog" >/dev/null
  tasks-axi hold task-a --reason "$a_reason" --kind load --file "$backlog" >/dev/null
  tasks-axi hold task-b --reason "$b_reason" --kind load --file "$backlog" >/dev/null
  tasks-axi hold task-c --reason "pool /some/other-pool full 1/2" --kind load --file "$backlog" >/dev/null
  tasks-axi hold task-d --reason "awaiting captain" --kind external --file "$backlog" >/dev/null
  printf '%s\n' "$case_dir"
}

held_field() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  held: *//p' | head -1
}

test_teardown_releases_oldest_capacity_hold_for_the_pool() {
  local case_dir rc pool
  case_dir=$(make_teardown_case release-z3)
  pool="$case_dir/pool"
  set +e
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "landed task teardown should succeed (stderr: $(cat "$case_dir/stderr"))"
  assert_contains "$(cat "$case_dir/stdout")" "ready: task-a - capacity hold released for pool $pool" \
    "teardown must print which item became ready"
  [ "$(held_field "$case_dir" task-a)" = no ] || fail "oldest same-pool hold was not released"
  [ "$(held_field "$case_dir" task-b)" = yes ] || fail "newer same-pool hold was wrongly released"
  [ "$(held_field "$case_dir" task-c)" = yes ] || fail "different-pool hold was wrongly released"
  [ "$(held_field "$case_dir" task-d)" = yes ] || fail "non-capacity hold was wrongly released"
  [ "$(tasks-axi show task-a --file "$case_dir/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = queued ] \
    || fail "released hold did not return its item to queued"
  pass "returning a worktree releases exactly the oldest capacity hold for that pool"
}

test_teardown_releases_fallback_identity_hold_when_pool_scan_matches_nothing() {
  local case_dir rc proj_canon name=fb-z4
  mkdir -p "$TMP_ROOT/$name"
  proj_canon=$(cd "$TMP_ROOT/$name" && pwd -P)/project
  case_dir=$(make_teardown_case "$name" "$proj_canon")
  set +e
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "landed task teardown should succeed (stderr: $(cat "$case_dir/stderr"))"
  assert_contains "$(cat "$case_dir/stdout")" "ready: task-a - capacity hold released for pool $proj_canon" \
    "the fallback scan must name the fallback pool identity it released"
  [ "$(held_field "$case_dir" task-a)" = no ] || fail "fallback-identity hold was not released"
  [ "$(held_field "$case_dir" task-b)" = yes ] || fail "newer fallback-identity hold was wrongly released"
  [ "$(held_field "$case_dir" task-c)" = yes ] || fail "different-pool hold was wrongly released"
  [ "$(held_field "$case_dir" task-d)" = yes ] || fail "non-capacity hold was wrongly released"
  [ "$(tasks-axi show task-a --file "$case_dir/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = queued ] \
    || fail "fallback release did not return its item to queued"
  pass "a hold recorded under the project-root fallback identity is released when the worktree-derived pool matches nothing"
}

test_pool_full_refusal_holds_and_exits_two
test_pool_full_refusal_on_manual_home_exits_two_without_hold
test_pool_full_refusal_reports_an_endpoint_it_could_not_close
test_teardown_releases_oldest_capacity_hold_for_the_pool
test_teardown_releases_fallback_identity_hold_when_pool_scan_matches_nothing

echo "# all fm-capacity-hold tests passed"
