#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's opt-in links to gitignored local project files.
#
# A link-local spawn may expose only an existing, gitignored relative project path
# in its disposable worktree. The linked path remains ignored, so teardown's dirty
# worktree check stays meaningful. This suite drives both real scripts and an
# actual git worktree removal to prove that teardown removes the link, not its
# primary-checkout target.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-link-local)

make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" "$id" $'You are a crewmate.\n\nDelivery contract: mode=no-mistakes'
  fm_git_worktree "$project" "$worktree" "fm/$id"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" claude)
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {  # <id> <extra args...>
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WORKTREE_DIR" TMUX=fake,1,0 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off "$@" 2>&1
}

test_help_documents_the_secret_exposure_warning() {
  local out
  out=$("$SPAWN" --help)
  assert_contains "$out" "--link-local <relative-path>" \
    "spawn help did not document the link-local flag"
  assert_contains "$out" "This deliberately makes local secrets reachable" \
    "spawn help did not warn that the flag exposes local secrets"
  assert_contains "$out" "from a disposable worktree" \
    "spawn help did not warn that the flag exposes local secrets"
  pass "fm-spawn: help documents link-local and its disposable-worktree secret warning"
}

test_linked_ignored_file_is_available_recorded_and_removed_by_teardown() {
  local rec id out target_content token_content
  id=link-local-live-a1
  rec=$(make_case live "$id")
  read_case "$rec"
  printf 'config/\nsecrets/\n' > "$PROJECT_DIR/.gitignore"
  git -C "$PROJECT_DIR" add .gitignore
  git -C "$PROJECT_DIR" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -qm 'ignore local config'
  git -C "$PROJECT_DIR" push -q origin HEAD
  mkdir -p "$PROJECT_DIR/config"
  mkdir -p "$PROJECT_DIR/secrets"
  target_content='db-url-and-api-key'
  token_content='write-token'
  printf '%s\n' "$target_content" > "$PROJECT_DIR/config/config.yaml"
  printf '%s\n' "$token_content" > "$PROJECT_DIR/secrets/token"

  out=$(run_spawn "$id" --link-local config/config.yaml --link-local secrets/token)
  expect_code 0 $? "link-local spawn should succeed for an ignored existing file"$'\n'"$out"
  [ -L "$WORKTREE_DIR/config/config.yaml" ] \
    || fail "linked worktree path is not a symlink"
  [ "$(cat "$WORKTREE_DIR/config/config.yaml")" = "$target_content" ] \
    || fail "linked worktree path does not resolve to the primary file"
  [ -L "$WORKTREE_DIR/secrets/token" ] \
    || fail "second linked worktree path is not a symlink"
  [ "$(cat "$WORKTREE_DIR/secrets/token")" = "$token_content" ] \
    || fail "second linked worktree path does not resolve to the primary file"
  assert_grep 'link_local=config/config.yaml' "$HOME_DIR/state/$id.meta" \
    "task metadata did not record the linked local path"
  assert_grep 'link_local=secrets/token' "$HOME_DIR/state/$id.meta" \
    "task metadata did not record the second linked local path"
  [ -z "$(git -C "$WORKTREE_DIR" status --porcelain)" ] \
    || fail "the ignored symlink made the task worktree dirty"

  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = return ] && [ "${2:-}" = --force ]; then
  git -C "${FM_TEST_PROJECT:?FM_TEST_PROJECT unset}" worktree remove --force "${3:?worktree unset}"
fi
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_TEST_PROJECT="$PROJECT_DIR" PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" > "$CASE_DIR/teardown.out" 2>&1
  expect_code 0 $? "teardown should remove the clean linked worktree"$'\n'"$(cat "$CASE_DIR/teardown.out")"
  assert_absent "$WORKTREE_DIR" "teardown did not remove the task worktree"
  [ -f "$PROJECT_DIR/config/config.yaml" ] \
    || fail "teardown removed the primary checkout's linked local target"
  [ "$(cat "$PROJECT_DIR/config/config.yaml")" = "$target_content" ] \
    || fail "teardown changed the primary checkout's linked local target"
  [ -f "$PROJECT_DIR/secrets/token" ] \
    || fail "teardown removed the second primary checkout linked local target"
  [ "$(cat "$PROJECT_DIR/secrets/token")" = "$token_content" ] \
    || fail "teardown changed the second primary checkout linked local target"
  pass "fm-spawn: teardown removes a linked worktree path without touching its ignored primary target"
}

test_link_local_refuses_unsafe_or_unavailable_paths() {
  local rec id out status label path expect n=0
  while IFS='|' read -r label path expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="link-local-refusal-$n"
    rec=$(make_case "$id" "$id")
    read_case "$rec"
    mkdir -p "$PROJECT_DIR/config"
    printf 'local\n' > "$PROJECT_DIR/config/local.yaml"
    printf 'config/local.yaml\n' > "$PROJECT_DIR/.gitignore"
    out=$(run_spawn "$id" --link-local "$path")
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected link-local spawn to refuse"
    assert_contains "$out" "$expect" "$label: refusal did not name the reason"
    assert_absent "$HOME_DIR/state/$id.meta" "$label: refused spawn published metadata"
  done <<'ROWS'
tracked path|README.md|gitignored
missing path|config/missing.yaml|does not exist
absolute path|/tmp/local.yaml|must be a relative project path
parent escape|../local.yaml|must not contain '..'
ROWS
  pass "fm-spawn: link-local rejects tracked, missing, absolute, and parent-escaping paths"
}

test_link_local_refuses_conflicting_paths_before_linking() {
  local rec id out status label args expect n=0
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="link-local-conflict-$n"
    rec=$(make_case "$id" "$id")
    read_case "$rec"
    mkdir -p "$PROJECT_DIR/config"
    printf 'local\n' > "$PROJECT_DIR/config/a.yaml"
    printf 'config/\n' > "$PROJECT_DIR/.gitignore"
    # shellcheck disable=SC2086
    out=$(run_spawn "$id" $args)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected link-local spawn to refuse"
    assert_contains "$out" "$expect" "$label: refusal did not name the reason"
    assert_absent "$HOME_DIR/state/$id.meta" "$label: refused spawn published metadata"
    [ ! -e "$WORKTREE_DIR/config" ] && [ ! -L "$WORKTREE_DIR/config" ] \
      || fail "$label: refused spawn still left a link-local symlink in the task worktree"
  done <<'ROWS'
repeated path|--link-local config/a.yaml --link-local config/a.yaml|repeated
ancestor before descendant|--link-local config --link-local config/a.yaml|conflict, one is nested in the other
descendant before ancestor|--link-local config/a.yaml --link-local config|conflict, one is nested in the other
ROWS
  pass "fm-spawn: link-local refuses a repeated or nested path before creating any symlink"
}

test_link_local_does_not_mask_real_uncommitted_work() {
  local rec id out status
  id=link-local-dirty-b2
  rec=$(make_case dirty "$id")
  read_case "$rec"
  printf 'config/\n' > "$PROJECT_DIR/.gitignore"
  git -C "$PROJECT_DIR" add .gitignore
  git -C "$PROJECT_DIR" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -qm 'ignore local config'
  git -C "$PROJECT_DIR" push -q origin HEAD
  mkdir -p "$PROJECT_DIR/config"
  printf 'local credential\n' > "$PROJECT_DIR/config/config.yaml"

  out=$(run_spawn "$id" --link-local config/config.yaml)
  expect_code 0 $? "link-local spawn should succeed before the dirty-worktree check"$'\n'"$out"
  printf 'uncommitted worker change\n' > "$WORKTREE_DIR/worker-change.txt"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$FAKEBIN_DIR:$PATH" "$TEARDOWN" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "teardown accepted real uncommitted work in a linked worktree"
  assert_contains "$out" "uncommitted changes" \
    "teardown did not name the real uncommitted work it refused"
  [ "$(cat "$PROJECT_DIR/config/config.yaml")" = 'local credential' ] \
    || fail "the refusal changed the primary checkout's linked local target"
  pass "fm-spawn: a link-local path stays ignored while real worker changes still refuse teardown"
}

test_help_documents_the_secret_exposure_warning
test_linked_ignored_file_is_available_recorded_and_removed_by_teardown
test_link_local_refuses_unsafe_or_unavailable_paths
test_link_local_refuses_conflicting_paths_before_linking
test_link_local_does_not_mask_real_uncommitted_work

echo "# all fm-spawn-link-local tests passed"
