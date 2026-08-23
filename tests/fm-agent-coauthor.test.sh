#!/usr/bin/env bash
# Regression for the worker Git commit path installed by bin/fm-spawn.sh.
#
# A fake Codex worker performs the reproduced `git commit --amend` path after
# fm-spawn launches it through a fake tmux pane.  The resulting commit must
# remove recognized agent co-authors without changing the committed tree,
# parent, identities, subject, body, or legitimate trailers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/treehouse-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/treehouse-helpers.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-agent-coauthor)
TASK_TMP_ROOTS=()

cleanup_task_tmps() {
  local task_tmp
  for task_tmp in "${TASK_TMP_ROOTS[@]}"; do
    rm -rf "$task_tmp"
  done
}
trap 'cleanup_task_tmps; fm_test_cleanup' EXIT

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u

case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac

case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  capture-pane)
    if [ "${FM_FAKE_KIMI_SCREEN:-0}" = 1 ]; then
      printf 'context: 1%%\n│ > │\n'
    fi
    exit 0
    ;;
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    literal=
    previous=
    for arg in "$@"; do
      if [ "$previous" = -l ]; then
        literal=$arg
        break
      fi
      previous=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        export\ *) : ;;
        *) printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_FILE" ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        [ "${FM_FAKE_KIMI_SCREEN:-0}" = 1 ] && exit 0
        if [ -s "$FM_FAKE_LAUNCH_FILE" ]; then
          (cd "$FM_FAKE_PANE_PATH" && bash -c "$(cat "$FM_FAKE_LAUNCH_FILE")")
        fi
        ;;
    esac
    exit 0
    ;;
esac

exit 0
SH
cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
set -eu

[ "${FM_FAKE_COMMIT:-0}" = 1 ] || exit 0
if [ -n "${FM_FAKE_ACTIVE_HOOKS_PATH:-}" ]; then
  git -C "$FM_FAKE_COMMIT_WORKTREE" config --get core.hooksPath > "$FM_FAKE_ACTIVE_HOOKS_PATH"
fi
cat > "$FM_FAKE_COMMIT_MESSAGE" <<'EOF'
Keep subject

Keep body.

Reviewed-by: Reviewer <reviewer@example.invalid>
Co-authored-by: Ada Human <ada@example.invalid>
Co-authored-by: Cursor <cursoragent@cursor.com>
Co-authored-by: Codex <codex@openai.com>
EOF
GIT_AUTHOR_NAME='Author Example' GIT_AUTHOR_EMAIL='author@example.invalid' \
  GIT_COMMITTER_NAME='Committer Example' GIT_COMMITTER_EMAIL='committer@example.invalid' \
  git -C "$FM_FAKE_COMMIT_WORKTREE" commit --amend -q -F "$FM_FAKE_COMMIT_MESSAGE"
SH
  chmod +x "$fakebin/tmux" "$fakebin/codex"
  fm_test_write_active_treehouse_fake "$fakebin"
  fm_fake_quota_axi "$fakebin"
  fm_fake_exit0 "$fakebin" gh-axi gh claude opencode pi pi-signed grok kimi cursor-agent
  printf '%s\n' "$fakebin"
}

test_worker_amend_removes_only_agent_coauthors() {
  local case_dir="$TMP_ROOT/amend" home proj wt fakebin id out initial_out initial_status status \
    expected_tree expected_parent expected_committer expected_author expected actual hook hook_out hook_log project_message task_tmp
  id="agent-coauthor-z1"
  TASK_TMP_ROOTS+=("/tmp/fm-$id")
  rm -rf "/tmp/fm-$id"
  case_dir="$TMP_ROOT/amend"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/worktree"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for %s\nDelivery contract: mode=no-mistakes\n' "$id" > "$home/data/$id/brief.md"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$wt" config user.name 'Committer Example'
  git -C "$wt" config user.email 'committer@example.invalid'
  printf 'worker content\n' > "$wt/worker.txt"
  git -C "$wt" add worker.txt
  GIT_AUTHOR_NAME='Author Example' GIT_AUTHOR_EMAIL='author@example.invalid' \
    GIT_COMMITTER_NAME='Committer Example' GIT_COMMITTER_EMAIL='committer@example.invalid' \
    git -C "$wt" commit -q -m 'worker change'
  expected_tree=$(git -C "$wt" rev-parse 'HEAD^{tree}')
  expected_parent=$(git -C "$wt" rev-parse HEAD^)
  expected_author=$(git -C "$wt" show -s --format='%an <%ae>' HEAD)
  expected_committer='Committer Example <committer@example.invalid>'
  hook_log="$case_dir/project-hooks.log"
  project_message="$case_dir/project-message"
  task_tmp="/tmp/fm-$id"
  rm -f "$hook_log" "$project_message" "$case_dir/active-hooks"
  mkdir -p "$wt/.project-hooks"
  # Launch once, then leave an executable obsolete relay behind to model same-task recovery.
  : > "$case_dir/launch"
  initial_out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_FILE="$case_dir/launch" \
    FM_FAKE_COMMIT=0 FM_FAKE_ACTIVE_HOOKS_PATH="$case_dir/active-hooks" \
    FM_FAKE_COMMIT_MESSAGE="$case_dir/message" FM_FAKE_COMMIT_WORKTREE="$wt" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
  initial_status=$?
  expect_code 0 "$initial_status" "initial worker launch should complete: $initial_out"
  cat > "/tmp/fm-$id/git-hooks/obsolete-relay" <<'EOF'
#!/usr/bin/env bash
exit 97
EOF
  chmod 700 "/tmp/fm-$id/git-hooks/obsolete-relay"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf "printf '%%s\\n' pre-commit >> %q\\n" "$hook_log"
  } > "$wt/.project-hooks/pre-commit"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf "if [ -f \"\$1\" ]; then cat \"\$1\" > %q; fi\n" "$project_message"
  } > "$wt/.project-hooks/commit-msg"
  chmod +x "$wt/.project-hooks/pre-commit" "$wt/.project-hooks/commit-msg"
  git -C "$wt" config core.hooksPath .project-hooks

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_FILE="$case_dir/launch" \
    FM_FAKE_COMMIT=1 FM_FAKE_ACTIVE_HOOKS_PATH="$case_dir/active-hooks" \
    FM_FAKE_COMMIT_MESSAGE="$case_dir/message" FM_FAKE_COMMIT_WORKTREE="$wt" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "spawned worker amend should complete: $out"
  assert_absent "$task_tmp/git-hooks/obsolete-relay" \
    "same-task recovery retained an obsolete executable relay"
  assert_contains "$(cat "$case_dir/active-hooks")" "/tmp/fm-$id/git-hooks" \
    "the worker amend did not use the task-local sanitizer hook path"
  assert_present "$task_tmp/git-hooks/pre-commit" \
    "the project pre-commit hook was not composed into the task relay"
  assert_present "$task_tmp/git-hooks/commit-msg" \
    "the project commit-msg hook was not composed into the task relay"

  assert_not_contains "$(git -C "$wt" show -s --format=%B HEAD)" \
    'Cursor <cursoragent@cursor.com>' "Cursor agent trailer survived the worker amend"
  assert_not_contains "$(git -C "$wt" show -s --format=%B HEAD)" \
    'Codex <codex@openai.com>' "Codex agent trailer survived the worker amend"
  expected=$(cat <<'EOF'
Keep subject

Keep body.

Reviewed-by: Reviewer <reviewer@example.invalid>
Co-authored-by: Ada Human <ada@example.invalid>
EOF
)
  actual=$(git -C "$wt" show -s --format=%B HEAD)
  [ "$actual" = "$expected" ] || fail "worker amend changed the retained message content: $actual"
  [ "$(git -C "$wt" rev-parse 'HEAD^{tree}')" = "$expected_tree" ] ||
    fail "worker amend changed the committed tree"
  [ "$(git -C "$wt" rev-parse HEAD^)" = "$expected_parent" ] ||
    fail "worker amend changed the parent"
  [ "$(git -C "$wt" show -s --format='%an <%ae>' HEAD)" = "$expected_author" ] ||
    fail "worker amend changed the author identity"
  [ "$(git -C "$wt" show -s --format='%cn <%ce>' HEAD)" = "$expected_committer" ] ||
    fail "worker amend changed the committer identity"
  assert_contains "$(cat "$hook_log")" pre-commit \
    "the project pre-commit hook did not run through the sanitizer relay"
  actual=$(cat "$project_message")
  assert_contains "$actual" 'Cursor <cursoragent@cursor.com>' \
    "the project commit-msg hook did not receive its original message"
  hook="$task_tmp/git-hooks/commit-msg"
  hook_out=$("$hook" "$case_dir/missing-message" 2>&1)
  status=$?
  expect_code 1 "$status" "a sanitizer runtime failure must refuse the commit"
  assert_contains "$hook_out" 'error: agent co-author sanitizer runtime failed; refusing commit' \
    "runtime sanitizer failure did not state its fail-closed delivery consequence"
  rm -rf "$task_tmp"
  pass "worker amend composes project hooks and strips recognized agent co-authors"
}

test_commit_msg_composition_without_precommit_relay() {
  local case_dir="$TMP_ROOT/commit-msg-only" home proj wt fakebin id out status project_message
  id="agent-coauthor-commit-msg-only"
  TASK_TMP_ROOTS+=("/tmp/fm-$id")
  rm -rf "/tmp/fm-$id"
  case_dir="$TMP_ROOT/commit-msg-only"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/worktree"
  project_message="$case_dir/project-message"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for %s\nDelivery contract: mode=no-mistakes\n' "$id" > "$home/data/$id/brief.md"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$wt" config user.name 'Committer Example'
  git -C "$wt" config user.email 'committer@example.invalid'
  printf 'worker content\n' > "$wt/worker.txt"
  git -C "$wt" add worker.txt
  GIT_AUTHOR_NAME='Author Example' GIT_AUTHOR_EMAIL='author@example.invalid' \
    GIT_COMMITTER_NAME='Committer Example' GIT_COMMITTER_EMAIL='committer@example.invalid' \
    git -C "$wt" commit -q -m 'worker change'
  mkdir -p "$wt/.project-hooks"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 23' > "$wt/.project-hooks/pre-commit"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    # shellcheck disable=SC2016
    # Write the hook's literal positional parameter.
    printf 'if [ -f "$1" ]; then cat "$1" > %q; fi\n' "$project_message"
  } > "$wt/.project-hooks/commit-msg"
  chmod 700 "$wt/.project-hooks/pre-commit" "$wt/.project-hooks/commit-msg"
  # Disable only the project pre-commit relay; commit-msg composition remains under test.
  chmod 600 "$wt/.project-hooks/pre-commit"
  git -C "$wt" config core.hooksPath .project-hooks
  rm -f "$project_message"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_FILE="$case_dir/launch" \
    FM_FAKE_COMMIT=0 FM_FAKE_COMMIT_MESSAGE="$case_dir/message" \
    FM_FAKE_COMMIT_WORKTREE="$wt" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "commit-msg-only composition fixture should complete: $out"
  cat > "$case_dir/message" <<'EOF'
Subject

Co-authored-by: Cursor <cursoragent@cursor.com>
EOF
  hook_out=$("/tmp/fm-$id/git-hooks/commit-msg" "$case_dir/message" 2>&1)
  status=$?
  expect_code 0 "$status" "task commit-msg relay should complete: $hook_out"
  assert_contains "$(cat "$project_message")" 'Cursor <cursoragent@cursor.com>' \
    "project commit-msg hook was not composed into the task relay"
  assert_not_contains "$(cat "$case_dir/message")" \
    'Cursor <cursoragent@cursor.com>' "sanitizer did not execute after project commit-msg composition"
  pass "project commit-msg composition is independently distinguished"
}

test_installation_failure_refuses_worker_launch() {
  local case_dir="$TMP_ROOT/install-failure" home proj wt fakebin id out status
  id="agent-coauthor-install-failure"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/worktree"
  fakebin=$(make_fakebin "$case_dir/fake")
  cat > "$fakebin/mkdir" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */git-hooks) exit 1 ;;
  esac
done
exec /bin/mkdir "$@"
SH
  chmod +x "$fakebin/mkdir"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for %s\nDelivery contract: mode=no-mistakes\n' "$id" > "$home/data/$id/brief.md"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_FILE="$case_dir/launch" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "sanitizer installation failure must refuse worker launch"
  assert_contains "$out" 'error: agent co-author sanitizer installation failed; refusing worker launch' \
    "installation failure did not report its refusal"
  assert_absent "$case_dir/launch" "worker launch continued after sanitizer installation failure"
  pass "sanitizer installation failure refuses worker launch"
}

test_every_verified_harness_reaches_task_local_sanitizer() {
  local case_dir="$TMP_ROOT/harness-reach" home proj wt fakebin harness id out status launch hook
  case_dir="$TMP_ROOT/harness-reach"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/worktree"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$case_dir/agent-home"
  mkdir -p "$case_dir/agent-home/.kimi-code"
  printf 'default_model = "test"\n' > "$case_dir/agent-home/.kimi-code/config.toml"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" 'fm/agent-coauthor-harness-reach'

  for harness in claude codex opencode pi pi-signed grok kimi cursor-agent; do
    id="agent-coauthor-${harness}-z2"
    TASK_TMP_ROOTS+=("/tmp/fm-$id")
    rm -rf "/tmp/fm-$id"
    mkdir -p "$home/data/$id"
    printf 'brief for %s\nDelivery contract: mode=no-mistakes\n' "$id" > "$home/data/$id/brief.md"
    printf '%s\n' "$harness" > "$home/config/crew-harness"
    : > "$case_dir/launch"
    out=$(HOME="$case_dir/agent-home" FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
      FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
      FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_FILE="$case_dir/launch" FM_FAKE_KIMI_SCREEN=1 \
      FM_KIMI_READY_POLLS=1 FM_KIMI_DELIVERY_POLLS=1 FM_KIMI_POLL_INTERVAL=0 PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
    status=$?
    expect_code 0 "$status" "$harness must receive the ordinary worker sanitizer path: $out"
    hook="/tmp/fm-$id/git-hooks/commit-msg"
    assert_present "$hook" "$harness did not receive a task-local commit-msg sanitizer"
    launch=$(cat "$case_dir/launch")
    assert_contains "$launch" 'core.hooksPath' "$harness launch did not select the sanitizer relay"
    rm -rf "/tmp/fm-$id"
  done
  pass "every verified worker harness receives the same task-local sanitizer path"
}

test_sanitizer_catalog_removes_all_documented_agent_coauthors() {
  local case_dir="$TMP_ROOT/catalog" message actual
  case_dir="$TMP_ROOT/catalog"
  mkdir -p "$case_dir"
  message="$case_dir/message"
  cat > "$message" <<'EOF'
Subject

Co-authored-by: Cursor <cursoragent@cursor.com>
Co-authored-by: Codex <codex@openai.com>
Co-authored-by: Claude Code <claude-code@anthropic.com>
Co-authored-by: Kimi Code <kimi-code@moonshot.cn>
Co-authored-by: Grok Code <grok-code@x.ai>
Co-authored-by: OpenCode <opencode@sst.dev>
Co-authored-by: Cursor <human@example.invalid>
Co-authored-by: CursorX <cursoragent@cursor.com>
Co-authored-by: Claude Code <reviewer@example.invalid>
Co-authored-by: Human Reviewer <human@example.invalid>
EOF
  "$ROOT/bin/fm-commit-msg-sanitize.sh" "$message"
  actual=$(cat "$message")
  for trailer in \
    'Cursor <cursoragent@cursor.com>' \
    'Codex <codex@openai.com>' \
    'Claude Code <claude-code@anthropic.com>' \
    'Kimi Code <kimi-code@moonshot.cn>' \
    'Grok Code <grok-code@x.ai>' \
    'OpenCode <opencode@sst.dev>'; do
    assert_not_contains "$actual" "$trailer" \
      "documented agent identity survived sanitizer: $trailer"
  done
  for trailer in \
    'Cursor <human@example.invalid>' \
    'CursorX <cursoragent@cursor.com>' \
    'Claude Code <reviewer@example.invalid>' \
    'Human Reviewer <human@example.invalid>'; do
    assert_contains "$actual" "$trailer" \
      "human or lookalike control was removed: $trailer"
  done
  pass "sanitizer removes all documented identities and preserves human lookalikes"
}

test_installation_failure_refuses_worker_launch
test_commit_msg_composition_without_precommit_relay
test_worker_amend_removes_only_agent_coauthors
test_sanitizer_catalog_removes_all_documented_agent_coauthors
test_every_verified_harness_reaches_task_local_sanitizer

echo "# all fm-agent-coauthor tests passed"
