#!/usr/bin/env bash
# tests/fm-spawn-codex-app.test.sh - codex-app spawn and teardown behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-codex-app-tests)

make_fake_bridge() {  # <dir> -> echoes fake bridge path
  local dir=$1 bridge="$1/fm-codex-bridge"
  cat > "$bridge" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_FAKE_BRIDGE_LOG:?}"
verb=${1:-}
shift || true
{
  printf '%s' "$verb"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
arg_value() {
  local want=$1 prev=
  shift
  for a in "$@"; do
    if [ "$prev" = "$want" ]; then
      printf '%s\n' "$a"
      return 0
    fi
    prev=$a
  done
  return 1
}
case "$verb" in
  ensure-running)
    printf '{"ok":true,"mode":"fake"}\n'
    ;;
  start-thread)
    cwd=$(arg_value --cwd "$@" || true)
    prompt=$(arg_value --prompt-file "$@" || true)
    if [ "${FM_FAKE_BRIDGE_WRITE_STATUS:-0}" = 1 ]; then
      printf 'working: Codex thread started\n' >> "${FM_FAKE_BRIDGE_STATUS_FILE:?}"
    fi
    if [ -n "$prompt" ]; then
      printf 'prompt-file\x1f%s\n' "$prompt" >> "$LOG"
      sed -n '1,220p' "$prompt" > "$LOG.prompt"
    fi
    printf '{"ok":true,"thread_id":"%s","cwd":"%s","thread":{"id":"%s","status":{"type":"idle"}}}\n' "${FM_FAKE_BRIDGE_THREAD_ID:-thread-spawn-123}" "${FM_FAKE_BRIDGE_CWD:-$cwd}" "${FM_FAKE_BRIDGE_THREAD_ID:-thread-spawn-123}"
    ;;
  archive-thread)
    printf '{"ok":true,"archived":true}\n'
    ;;
  thread-status)
    printf '{"ok":true,"status":"idle","thread":{"id":"%s","status":{"type":"idle"}}}\n' "${FM_FAKE_BRIDGE_THREAD_ID:-thread-spawn-123}"
    ;;
  *)
    printf '{"ok":true}\n'
    ;;
esac
SH
  chmod +x "$bridge"
  printf '%s\n' "$bridge"
}

make_case() {  # <name> <id> -> echoes case dir
  local name=$1 id=$2 case_dir project
  case_dir="$TMP_ROOT/$name"
  project="$case_dir/home/projects/app"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data/$id" "$case_dir/home/config" "$project"
  git -C "$project" init -q
  printf '# app\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" commit -q -m initial
  printf 'Build the requested change.\n' > "$case_dir/home/data/$id/brief.md"
  touch "$case_dir/home/state/.last-watcher-beat"
  make_fake_bridge "$case_dir" >/dev/null
  printf '%s\n' "$case_dir"
}

run_spawn_case() {  # <case-dir> <id> [extra args...]
  local case_dir=$1 id=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_PROJECTS_OVERRIDE="$case_dir/home/projects" \
  FM_CONFIG_OVERRIDE="$case_dir/home/config" \
  FM_CODEX_BRIDGE="$case_dir/fm-codex-bridge" \
  FM_FAKE_BRIDGE_LOG="$case_dir/bridge.log" \
  FM_FAKE_BRIDGE_STATUS_FILE="$case_dir/home/state/$id.status" \
  FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" projects/app codex --backend codex-app "$@"
}

run_teardown_case() {  # <case-dir> <id> [extra args...]
  local case_dir=$1 id=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_CONFIG_OVERRIDE="$case_dir/home/config" \
  FM_CODEX_BRIDGE="$case_dir/fm-codex-bridge" \
  FM_FAKE_BRIDGE_LOG="$case_dir/bridge.log" \
    "$TEARDOWN" "$id" "$@"
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" | tail -1 | cut -d= -f2- || true
}

test_spawn_codex_app_records_thread_and_worktree() {
  local id case_dir out status meta wt project log prompt
  id=codex-ok-x1
  case_dir=$(make_case spawn-ok "$id")
  out=$(FM_FAKE_BRIDGE_WRITE_STATUS=1 run_spawn_case "$case_dir" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app spawn should succeed: $out"
  meta="$case_dir/home/state/$id.meta"
  assert_present "$meta" "codex-app spawn should write meta"
  [ "$(meta_value "$meta" backend)" = codex-app ] || fail "meta should record backend=codex-app"
  [ "$(meta_value "$meta" thread_id)" = thread-spawn-123 ] || fail "meta should record thread_id"
  [ "$(meta_value "$meta" window)" = thread-spawn-123 ] || fail "window should be the Codex thread id"
  [ "$(meta_value "$meta" harness)" = codex ] || fail "codex-app spawn should record harness=codex"
  [ "$(meta_value "$meta" worktree_provider)" = git-worktree ] || fail "spawn should record git-worktree provider"
  wt=$(meta_value "$meta" worktree)
  project=$(meta_value "$meta" project)
  assert_present "$wt" "codex-app spawn should create a git worktree"
  git -C "$project" worktree list --porcelain | grep -F "worktree $wt" >/dev/null \
    || fail "project git worktree list should include codex-app worktree"
  [ "$(meta_value "$meta" codex_cwd)" = "$wt" ] || fail "codex_cwd should match the worktree"
  log=$(cat "$case_dir/bridge.log")
  assert_contains "$log" "ensure-running" "spawn should verify the bridge before starting"
  assert_contains "$log" $'start-thread\x1f--cwd\x1f' "spawn should call start-thread with a cwd"
  prompt="$case_dir/bridge.log.prompt"
  assert_grep "working: Codex thread started" "$prompt" "spawn prompt should include the return-channel line"
  assert_contains "$out" "spawned $id harness=codex kind=ship" "spawn output should keep the normal summary shape"
  pass "fm-spawn.sh --backend codex-app: creates an isolated git worktree, starts a Codex thread, verifies status, and records metadata"
}

test_spawn_codex_app_refuses_secondmate() {
  local case_dir out status
  case_dir="$TMP_ROOT/secondmate-refusal"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config"
  make_fake_bridge "$case_dir" >/dev/null
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/home/state" FM_DATA_OVERRIDE="$case_dir/home/data" FM_CONFIG_OVERRIDE="$case_dir/home/config" FM_CODEX_BRIDGE="$case_dir/fm-codex-bridge" FM_FAKE_BRIDGE_LOG="$case_dir/bridge.log" FM_SPAWN_NO_GUARD=1 "$SPAWN" sm-codex --secondmate --backend codex-app 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "codex-app should refuse --secondmate"
  assert_contains "$out" "backend=codex-app does not support --secondmate" "secondmate refusal should name codex-app"
  pass "fm-spawn.sh --backend codex-app: refuses --secondmate"
}

test_spawn_codex_app_refuses_primary_cwd_from_bridge() {
  local id case_dir project out status
  id=codex-primary-x2
  case_dir=$(make_case primary-cwd "$id")
  project="$case_dir/home/projects/app"
  out=$(FM_FAKE_BRIDGE_WRITE_STATUS=1 FM_FAKE_BRIDGE_CWD="$project" run_spawn_case "$case_dir" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when Codex returns the primary checkout cwd"
  assert_contains "$out" "Codex thread thread-spawn-123 started in '$project'" "primary cwd refusal should name the returned cwd"
  pass "fm-spawn.sh --backend codex-app: refuses when Codex reports the primary checkout cwd"
}

test_spawn_codex_app_requires_return_channel_status() {
  local id case_dir out status
  id=codex-no-status-x3
  case_dir=$(make_case no-status "$id")
  out=$(run_spawn_case "$case_dir" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail without the Codex status handshake"
  assert_contains "$out" "did not write return-channel status" "missing handshake refusal should explain the missing status line"
  pass "fm-spawn.sh --backend codex-app: refuses when the Codex thread does not verify the status return channel"
}

test_teardown_codex_app_archives_and_removes_git_worktree() {
  local id case_dir out status meta wt project log
  id=codex-teardown-x4
  case_dir=$(make_case teardown "$id")
  out=$(FM_FAKE_BRIDGE_WRITE_STATUS=1 run_spawn_case "$case_dir" "$id" --scout 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app scout spawn should succeed before teardown: $out"
  meta="$case_dir/home/state/$id.meta"
  wt=$(meta_value "$meta" worktree)
  project=$(meta_value "$meta" project)
  printf 'Scout report.\n' > "$case_dir/home/data/$id/report.md"
  : > "$case_dir/bridge.log"

  out=$(run_teardown_case "$case_dir" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app teardown should succeed for scout with report: $out"
  log=$(cat "$case_dir/bridge.log")
  assert_contains "$log" $'archive-thread\x1f--thread-id\x1fthread-spawn-123' "teardown should archive the Codex thread"
  git -C "$project" worktree list --porcelain | grep -F "worktree $wt" >/dev/null \
    && fail "teardown should remove the git worktree from the project worktree list"
  assert_absent "$case_dir/home/state/$id.meta" "teardown should remove task meta"
  pass "fm-teardown.sh: codex-app archives the thread and removes a git-worktree-backed scout task"
}

test_spawn_codex_app_records_thread_and_worktree
test_spawn_codex_app_refuses_secondmate
test_spawn_codex_app_refuses_primary_cwd_from_bridge
test_spawn_codex_app_requires_return_channel_status
test_teardown_codex_app_archives_and_removes_git_worktree
