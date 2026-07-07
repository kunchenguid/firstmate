#!/usr/bin/env bash
# tests/fm-spawn-codex-app.test.sh - codex-app spawn and teardown behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-codex-app-tests)

make_fake_bridge() {  # <dir> -> echoes fake bridge path
  local bridge="$1/fm-codex-bridge"
  cat > "$bridge" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_FAKE_BRIDGE_LOG:?}"
verb=${1:-}
shift || true
{
  printf 'gotmpdir\x1f%s\x1f%s\n' "$verb" "${GOTMPDIR-}"
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
    printf '{"ok":true,"thread_id":"%s","cwd":"%s","thread":{"id":"%s","status":{"type":"idle"}}}\n' "${FM_FAKE_BRIDGE_THREAD_ID:-thread-spawn-123}" "${FM_FAKE_BRIDGE_CWD:-$cwd}" "${FM_FAKE_BRIDGE_THREAD_ID:-thread-spawn-123}"
    ;;
  send-turn)
    prompt=$(arg_value --prompt-file "$@" || true)
    cwd=$(arg_value --cwd "$@" || true)
    if [ "${FM_FAKE_BRIDGE_WRITE_UNTRACKED:-0}" = 1 ] && [ -n "$cwd" ]; then
      printf 'startup work\n' > "$cwd/startup-untracked.txt"
    fi
    if [ "${FM_FAKE_BRIDGE_WRITE_STATUS:-0}" = 1 ]; then
      printf 'working: Codex thread started\n' >> "${FM_FAKE_BRIDGE_STATUS_FILE:?}"
    fi
    if [ "${FM_FAKE_BRIDGE_WRITE_OTHER_STATUS:-0}" = 1 ]; then
      printf 'working: wrong startup line\n' >> "${FM_FAKE_BRIDGE_STATUS_FILE:?}"
    fi
    if [ -n "${FM_FAKE_BRIDGE_WRITE_STATUS_AFTER_SLEEP:-}" ]; then
      (
        sleep "$FM_FAKE_BRIDGE_WRITE_STATUS_AFTER_SLEEP"
        printf 'working: Codex thread started\n' >> "${FM_FAKE_BRIDGE_STATUS_FILE:?}"
      ) >/dev/null 2>&1 &
    fi
    if [ -n "$prompt" ]; then
      printf 'prompt-file\x1f%s\n' "$prompt" >> "$LOG"
      sed -n '1,220p' "$prompt" > "$LOG.prompt"
    fi
    printf '{"ok":true,"thread_id":"%s","turn":{"id":"turn-spawn-123","status":"inProgress"}}\n' "${FM_FAKE_BRIDGE_THREAD_ID:-thread-spawn-123}"
    ;;
  archive-thread)
    if [ -n "${FM_FAKE_BRIDGE_ARCHIVE_CHECK_PATH:-}" ]; then
      if [ -d "$FM_FAKE_BRIDGE_ARCHIVE_CHECK_PATH" ]; then
        printf 'archive-worktree-present\n' >> "$LOG"
      else
        printf 'archive-worktree-missing\n' >> "$LOG"
      fi
    fi
    if [ "${FM_FAKE_BRIDGE_ARCHIVE_FAIL:-0}" = 1 ]; then
      printf '{"ok":false,"error":"archive failed"}\n'
      exit 9
    fi
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

run_send_case() {  # <case-dir> <id> <message...>
  local case_dir=$1 id=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_CONFIG_OVERRIDE="$case_dir/home/config" \
  FM_CODEX_BRIDGE="$case_dir/fm-codex-bridge" \
  FM_FAKE_BRIDGE_LOG="$case_dir/bridge.log" \
  FM_SEND_SETTLE=0 \
    "$SEND" "fm-$id" "$@"
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" | tail -1 | cut -d= -f2- || true
}

test_spawn_codex_app_records_thread_and_worktree() {
  local id case_dir out status meta wt project log prompt branch base_head
  id=codex-ok-x1
  case_dir=$(make_case spawn-ok "$id")
  base_head=$(git -C "$case_dir/home/projects/app" rev-parse HEAD)
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
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  [ "$branch" = HEAD ] || fail "codex-app spawn should create the startup worktree detached, got branch '$branch'"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$base_head" ] || fail "codex-app spawn should start from the default-branch commit"
  ! git -C "$project" show-ref --verify --quiet "refs/heads/fm/$id" || fail "codex-app spawn should let the brief create fm/$id instead of precreating it"
  [ "$(meta_value "$meta" codex_cwd)" = "$wt" ] || fail "codex_cwd should match the worktree"
  log=$(cat "$case_dir/bridge.log")
  assert_contains "$log" "ensure-running" "spawn should verify the bridge before starting"
  assert_contains "$log" $'start-thread\x1f--cwd\x1f' "spawn should call start-thread with a cwd"
  assert_contains "$log" $'send-turn\x1f--thread-id\x1fthread-spawn-123' "spawn should start the prompt turn after thread validation"
  assert_contains "$log" $'gotmpdir\x1fstart-thread\x1f/tmp/fm-codex-ok-x1/gotmp' "spawn should pass GOTMPDIR to the start-thread bridge call"
  assert_contains "$log" $'gotmpdir\x1fsend-turn\x1f/tmp/fm-codex-ok-x1/gotmp' "spawn should pass GOTMPDIR to the initial send-turn bridge call"
  assert_contains "$log" $'--wait-status-file\x1f' "spawn should keep the bridge alive for return-channel verification"
  prompt="$case_dir/bridge.log.prompt"
  assert_grep "working: Codex thread started" "$prompt" "spawn prompt should include the return-channel line"
  assert_contains "$out" "spawned $id harness=codex kind=ship" "spawn output should keep the normal summary shape"
  pass "fm-spawn.sh --backend codex-app: creates an isolated git worktree, starts a Codex thread, verifies status, and records metadata"
}

test_spawn_codex_app_uses_default_branch_when_project_on_feature() {
  local id case_dir project default_branch default_head feature_head out status meta wt
  id=codex-feature-base-x11
  case_dir=$(make_case feature-base "$id")
  project="$case_dir/home/projects/app"
  default_branch=$(git -C "$project" symbolic-ref --short HEAD)
  printf 'default work\n' > "$project/default.txt"
  git -C "$project" add default.txt
  git -C "$project" commit -q -m default-work
  default_head=$(git -C "$project" rev-parse HEAD)
  git -C "$project" checkout -q -b feature/wip
  printf 'feature work\n' > "$project/feature.txt"
  git -C "$project" add feature.txt
  git -C "$project" commit -q -m feature-work
  feature_head=$(git -C "$project" rev-parse HEAD)

  out=$(FM_FAKE_BRIDGE_WRITE_STATUS=1 run_spawn_case "$case_dir" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app spawn should use default branch while project is on feature: $out"
  meta="$case_dir/home/state/$id.meta"
  wt=$(meta_value "$meta" worktree)
  [ "$(git -C "$wt" rev-parse HEAD)" = "$default_head" ] || fail "codex-app worktree should start from $default_branch, not feature HEAD"
  [ "$(git -C "$wt" rev-parse HEAD)" != "$feature_head" ] || fail "codex-app worktree stacked on feature HEAD"
  assert_absent "$wt/feature.txt" "codex-app worktree should not include feature-only files"
  pass "fm-spawn.sh --backend codex-app: uses the default branch commit instead of feature HEAD"
}

test_spawn_codex_app_refuses_without_verifiable_default_branch() {
  local id case_dir project out status wt
  id=codex-no-default-x12
  case_dir=$(make_case no-default "$id")
  project="$case_dir/home/projects/app"
  git -C "$project" branch -m feature-only
  git -C "$project" checkout -q --detach HEAD

  out=$(FM_FAKE_BRIDGE_WRITE_STATUS=1 run_spawn_case "$case_dir" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "codex-app spawn should refuse without a verifiable default branch"
  assert_contains "$out" "cannot determine default branch for codex-app task $id" "refusal should explain missing default branch"
  assert_not_contains "$(cat "$case_dir/bridge.log" 2>/dev/null || true)" "start-thread" "spawn should not launch Codex without a verified default base"
  wt="$case_dir/home/projects/.firstmate-worktrees/$id"
  assert_absent "$wt" "spawn should not create a codex-app worktree without a verified default base"
  pass "fm-spawn.sh --backend codex-app: refuses detached projects without a verifiable default branch"
}

test_send_codex_app_uses_recorded_task_gotmpdir() {
  local id case_dir out status log
  id=codex-send-x8
  case_dir=$(make_case send-gotmp "$id")
  out=$(FM_FAKE_BRIDGE_WRITE_STATUS=1 run_spawn_case "$case_dir" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app spawn should succeed before send GOTMPDIR verification: $out"
  : > "$case_dir/bridge.log"

  out=$(run_send_case "$case_dir" "$id" "Run go test." 2>&1)
  status=$?
  expect_code 0 "$status" "fm-send should submit to codex-app task: $out"
  log=$(cat "$case_dir/bridge.log")
  assert_contains "$log" $'gotmpdir\x1fsend-turn\x1f/tmp/fm-codex-send-x8/gotmp' "fm-send should pass the recorded GOTMPDIR to codex-app turns"
  pass "fm-send.sh: codex-app turns inherit the task GOTMPDIR"
}

test_send_codex_app_uses_recorded_task_cwd() {
  local id case_dir out status log meta wt
  id=codex-send-cwd-x9
  case_dir=$(make_case send-cwd "$id")
  out=$(FM_FAKE_BRIDGE_WRITE_STATUS=1 run_spawn_case "$case_dir" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app spawn should succeed before send cwd verification: $out"
  meta="$case_dir/home/state/$id.meta"
  wt=$(meta_value "$meta" worktree)
  : > "$case_dir/bridge.log"

  out=$(run_send_case "$case_dir" "$id" "Run pwd." 2>&1)
  status=$?
  expect_code 0 "$status" "fm-send should submit with recorded cwd to codex-app task: $out"
  log=$(cat "$case_dir/bridge.log")
  assert_contains "$log" $'send-turn\x1f--thread-id\x1fthread-spawn-123' "fm-send should call bridge send-turn"
  assert_contains "$log" $'--cwd\x1f'"$wt" "fm-send should pass the recorded codex-app cwd"
  pass "fm-send.sh: codex-app turns inherit the task cwd"
}

test_send_codex_app_uses_recorded_task_model_and_effort() {
  local id case_dir out status log
  id=codex-send-profile-x10
  case_dir=$(make_case send-profile "$id")
  out=$(FM_FAKE_BRIDGE_WRITE_STATUS=1 run_spawn_case "$case_dir" "$id" --model gpt-5.5 --effort xhigh 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app spawn should succeed before send model/effort verification: $out"
  : > "$case_dir/bridge.log"

  out=$(run_send_case "$case_dir" "$id" "Use the recorded profile." 2>&1)
  status=$?
  expect_code 0 "$status" "fm-send should submit with recorded model/effort to codex-app task: $out"
  log=$(cat "$case_dir/bridge.log")
  assert_contains "$log" $'send-turn\x1f--thread-id\x1fthread-spawn-123' "fm-send should call bridge send-turn"
  assert_contains "$log" $'--model\x1fgpt-5.5' "fm-send should pass the recorded codex-app model"
  assert_contains "$log" $'--effort\x1fxhigh' "fm-send should pass the recorded codex-app effort"
  pass "fm-send.sh: codex-app turns inherit the task model and effort"
}

test_spawn_codex_app_waits_past_old_return_channel_window() {
  local id case_dir out status meta
  id=codex-delayed-x5
  case_dir=$(make_case delayed-status "$id")
  out=$(FM_FAKE_BRIDGE_WRITE_STATUS_AFTER_SLEEP=6 run_spawn_case "$case_dir" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app spawn should tolerate a delayed status handshake: $out"
  meta="$case_dir/home/state/$id.meta"
  assert_present "$meta" "delayed handshake spawn should write meta"
  assert_grep "working: Codex thread started" "$case_dir/home/state/$id.status" "delayed handshake should be accepted"
  pass "fm-spawn.sh --backend codex-app: waits past the old five-second return-channel window"
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
  local id case_dir project out status wt log
  id=codex-primary-x2
  case_dir=$(make_case primary-cwd "$id")
  project="$case_dir/home/projects/app"
  out=$(FM_FAKE_BRIDGE_WRITE_STATUS=1 FM_FAKE_BRIDGE_CWD="$project" run_spawn_case "$case_dir" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when Codex returns the primary checkout cwd"
  assert_contains "$out" "Codex thread thread-spawn-123 started in '$project'" "primary cwd refusal should name the returned cwd"
  wt="$case_dir/home/projects/.firstmate-worktrees/$id"
  assert_absent "$wt" "primary cwd refusal should remove the git worktree"
  git -C "$project" worktree list --porcelain | grep -F "worktree $wt" >/dev/null \
    && fail "primary cwd refusal should unregister the git worktree"
  ! git -C "$project" show-ref --verify --quiet "refs/heads/fm/$id" || fail "primary cwd refusal should leave no task branch"
  assert_absent "$case_dir/home/state/$id.meta" "primary cwd refusal should not leave task metadata"
  log=$(cat "$case_dir/bridge.log")
  assert_contains "$log" $'archive-thread\x1f--thread-id\x1fthread-spawn-123' "primary cwd refusal should archive the Codex thread"
  assert_not_contains "$log" "send-turn" "primary cwd refusal should not start the prompt turn before cwd validation"
  pass "fm-spawn.sh --backend codex-app: refuses when Codex reports the primary checkout cwd"
}

test_spawn_codex_app_requires_return_channel_status() {
  local id case_dir out status wt project log
  id=codex-no-status-x3
  case_dir=$(make_case no-status "$id")
  project="$case_dir/home/projects/app"
  out=$(FM_CODEX_APP_RETURN_CHANNEL_POLLS=2 FM_CODEX_APP_RETURN_CHANNEL_SLEEP=0.01 run_spawn_case "$case_dir" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail without the Codex status handshake"
  assert_contains "$out" "did not write return-channel status" "missing handshake refusal should explain the missing status line"
  wt="$case_dir/home/projects/.firstmate-worktrees/$id"
  assert_absent "$wt" "missing handshake refusal should remove the git worktree"
  git -C "$project" worktree list --porcelain | grep -F "worktree $wt" >/dev/null \
    && fail "missing handshake refusal should unregister the git worktree"
  ! git -C "$project" show-ref --verify --quiet "refs/heads/fm/$id" || fail "missing handshake refusal should leave no task branch"
  assert_absent "$case_dir/home/state/$id.meta" "missing handshake refusal should not leave task metadata"
  log=$(cat "$case_dir/bridge.log")
  assert_contains "$log" $'send-turn\x1f--thread-id\x1fthread-spawn-123' "missing handshake test should start the prompt turn before waiting"
  assert_contains "$log" $'archive-thread\x1f--thread-id\x1fthread-spawn-123' "missing handshake refusal should archive the Codex thread"
  pass "fm-spawn.sh --backend codex-app: refuses when the Codex thread does not verify the status return channel"
}

test_spawn_codex_app_preserves_startup_state_when_archive_fails() {
  local id case_dir out status wt logical_wt project meta log status_file
  id=codex-startup-archive-fail-x7
  case_dir=$(make_case startup-archive-fail "$id")
  project="$case_dir/home/projects/app"
  status_file="$case_dir/home/state/$id.status"
  out=$(FM_FAKE_BRIDGE_WRITE_OTHER_STATUS=1 FM_FAKE_BRIDGE_ARCHIVE_FAIL=1 FM_CODEX_APP_RETURN_CHANNEL_POLLS=2 FM_CODEX_APP_RETURN_CHANNEL_SLEEP=0.01 run_spawn_case "$case_dir" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail when the status handshake is missing and archive also fails"
  assert_contains "$out" "startup cleanup failed to archive thread thread-spawn-123" "archive failure should explain preserved startup resources"
  logical_wt="$case_dir/home/projects/.firstmate-worktrees/$id"
  meta="$case_dir/home/state/$id.meta"
  assert_present "$logical_wt" "archive failure should preserve the startup git worktree"
  wt=$(cd "$logical_wt" && pwd -P)
  git -C "$project" worktree list --porcelain | grep -F "worktree $wt" >/dev/null \
    || fail "archive failure should preserve the project worktree registration"
  ! git -C "$project" show-ref --verify --quiet "refs/heads/fm/$id" \
    || fail "archive failure before brief execution should not create the task branch"
  assert_present "$meta" "archive failure should write recovery metadata"
  [ "$(meta_value "$meta" thread_id)" = thread-spawn-123 ] || fail "recovery meta should retain thread_id"
  assert_present "$status_file" "archive failure should preserve the startup status file"
  assert_grep "working: wrong startup line" "$status_file" "archive failure should leave existing status content intact"
  log=$(cat "$case_dir/bridge.log")
  assert_contains "$log" $'archive-thread\x1f--thread-id\x1fthread-spawn-123' "startup cleanup should try to archive the Codex thread"
  pass "fm-spawn.sh --backend codex-app: preserves startup resources when archive fails"
}

test_spawn_codex_app_preserves_dirty_startup_worktree() {
  local id case_dir out status logical_wt wt project meta log
  id=codex-startup-dirty-x10
  case_dir=$(make_case startup-dirty "$id")
  project="$case_dir/home/projects/app"
  out=$(FM_FAKE_BRIDGE_WRITE_UNTRACKED=1 FM_CODEX_APP_RETURN_CHANNEL_POLLS=2 FM_CODEX_APP_RETURN_CHANNEL_SLEEP=0.01 run_spawn_case "$case_dir" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail when the status handshake is missing after startup worktree changes"
  assert_contains "$out" "preserving worktree and state for manual recovery" "dirty startup cleanup should explain preserved resources"
  logical_wt="$case_dir/home/projects/.firstmate-worktrees/$id"
  meta="$case_dir/home/state/$id.meta"
  assert_present "$logical_wt" "dirty startup cleanup should preserve the git worktree"
  assert_present "$logical_wt/startup-untracked.txt" "dirty startup cleanup should preserve untracked work"
  wt=$(cd "$logical_wt" && pwd -P)
  git -C "$project" worktree list --porcelain | grep -F "worktree $wt" >/dev/null \
    || fail "dirty startup cleanup should preserve the project worktree registration"
  assert_present "$meta" "dirty startup cleanup should write recovery metadata"
  [ "$(meta_value "$meta" thread_id)" = thread-spawn-123 ] || fail "dirty recovery meta should retain thread_id"
  log=$(cat "$case_dir/bridge.log")
  assert_contains "$log" $'archive-thread\x1f--thread-id\x1fthread-spawn-123' "dirty startup cleanup should still try to archive the Codex thread"
  pass "fm-spawn.sh --backend codex-app: preserves dirty startup worktrees"
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

  out=$(FM_FAKE_BRIDGE_ARCHIVE_CHECK_PATH="$wt" run_teardown_case "$case_dir" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app teardown should succeed for scout with report: $out"
  log=$(cat "$case_dir/bridge.log")
  assert_contains "$log" $'archive-thread\x1f--thread-id\x1fthread-spawn-123' "teardown should archive the Codex thread"
  assert_contains "$log" "archive-worktree-present" "teardown should archive before removing the git worktree"
  git -C "$project" worktree list --porcelain | grep -F "worktree $wt" >/dev/null \
    && fail "teardown should remove the git worktree from the project worktree list"
  assert_absent "$case_dir/home/state/$id.meta" "teardown should remove task meta"
  pass "fm-teardown.sh: codex-app archives the thread and removes a git-worktree-backed scout task"
}

test_teardown_codex_app_refuses_to_remove_worktree_when_archive_fails() {
  local id case_dir out status meta wt project log
  id=codex-archive-fail-x6
  case_dir=$(make_case teardown-archive-fail "$id")
  out=$(FM_FAKE_BRIDGE_WRITE_STATUS=1 run_spawn_case "$case_dir" "$id" --scout 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app scout spawn should succeed before archive-failure teardown: $out"
  meta="$case_dir/home/state/$id.meta"
  wt=$(meta_value "$meta" worktree)
  project=$(meta_value "$meta" project)
  printf 'Scout report.\n' > "$case_dir/home/data/$id/report.md"
  : > "$case_dir/bridge.log"

  out=$(FM_FAKE_BRIDGE_ARCHIVE_FAIL=1 FM_FAKE_BRIDGE_ARCHIVE_CHECK_PATH="$wt" run_teardown_case "$case_dir" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "codex-app teardown should fail when thread archive fails"
  assert_contains "$out" "failed to remove codex-app endpoint thread-spawn-123" "archive failure should explain the preserved endpoint"
  log=$(cat "$case_dir/bridge.log")
  assert_contains "$log" $'archive-thread\x1f--thread-id\x1fthread-spawn-123' "archive-failure teardown should try to archive"
  assert_contains "$log" "archive-worktree-present" "archive failure should happen before worktree removal"
  git -C "$project" worktree list --porcelain | grep -F "worktree $wt" >/dev/null \
    || fail "archive failure should preserve the project worktree registration"
  assert_present "$wt" "archive failure should preserve the git worktree"
  assert_present "$meta" "archive failure should preserve task meta"
  pass "fm-teardown.sh: codex-app preserves worktree and metadata when archive fails"
}

test_spawn_codex_app_records_thread_and_worktree
test_spawn_codex_app_uses_default_branch_when_project_on_feature
test_spawn_codex_app_refuses_without_verifiable_default_branch
test_send_codex_app_uses_recorded_task_gotmpdir
test_send_codex_app_uses_recorded_task_cwd
test_send_codex_app_uses_recorded_task_model_and_effort
test_spawn_codex_app_waits_past_old_return_channel_window
test_spawn_codex_app_refuses_secondmate
test_spawn_codex_app_refuses_primary_cwd_from_bridge
test_spawn_codex_app_requires_return_channel_status
test_spawn_codex_app_preserves_startup_state_when_archive_fails
test_spawn_codex_app_preserves_dirty_startup_worktree
test_teardown_codex_app_archives_and_removes_git_worktree
test_teardown_codex_app_refuses_to_remove_worktree_when_archive_fails
