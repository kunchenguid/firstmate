#!/usr/bin/env bash
# Spawn behavior for a task marked external, whose Claude worker launches inside
# the external worker sandbox (bin/fm-external-sandbox-lib.sh owns the settings
# block, bin/fm-project-mode.sh the registry token, docs/configuration.md
# "External workers" the contract). These drive the real spawn path with a fake
# terminal: a marked task gets the sandbox settings file and the recorded mark,
# an unmarked task launches exactly as before, and every mark the launch cannot
# honor refuses before a task record exists.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-external-sandbox)

# make_case <name> <id> <registry-tokens> [<harness>]: a home whose registry
# holds the tokens, a project with a pooled worktree, and a filled ship brief.
# Sets CASE_DIR, HOME_DIR, PROJECT_DIR, POOL_DIR, FAKEBIN_DIR, LAUNCH_LOG.
make_case() {
  local name=$1 id=$2 tokens=$3 harness=${4:-claude} content
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  POOL_DIR="$CASE_DIR/pool"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
  printf -- '- project [%s] - fixture (added 2026-01-01)\n' "$tokens" > "$HOME_DIR/data/projects.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
  : > "$LAUNCH_LOG"
  git init --quiet -b main "$PROJECT_DIR"
  printf 'base\n' > "$PROJECT_DIR/README.md"
  git -C "$PROJECT_DIR" add README.md
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" "$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  FM_HOME="$HOME_DIR" "$BRIEF" "$id" project --mode no-mistakes >/dev/null \
    || fail "the brief for $id should scaffold"
  content=$(cat "$HOME_DIR/data/$id/brief.md")
  content=${content//'{TASK}'/Work on a third-party repository.}
  content=${content//'{FIRSTMATE_SPEC}'/Exercise the spawn path.}
  printf '%s\n' "$content" > "$HOME_DIR/data/$id/brief.md"
}

run_spawn() {  # <id> <args...>
  local id=$1
  shift
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off "$@"
}

launch_text() {
  fm_test_launch_unframe "$(cat "$LAUNCH_LOG")"
}

# assert_contained <id>: the launch passes the task's settings file, the file
# carries the sandbox and the worker's busy hooks, and the record carries the
# mark.
assert_contained() {
  local id=$1 state_real settings launch common admin wt_real root_real tmp_real
  state_real=$(cd "$HOME_DIR/state" && pwd -P)
  settings="$state_real/$id.claude-settings.json"
  launch=$(launch_text)
  assert_contains "$launch" "--settings '$settings' " "the external launch did not pass its settings file"
  assert_contains "$launch" " --strict-mcp-config --setting-sources user --append-system-prompt " \
    "the external launch must load no MCP server and no project or local settings"
  [ -f "$settings" ] || fail "the external launch wrote no settings file"
  jq -e '
    .feedbackDrafts == "off"
    and .attribution == {"commit": "", "pr": "", "sessionUrl": false}
    and .disableClaudeAiConnectors == true
    and .sandbox.enabled == true
    and .sandbox.failIfUnavailable == true
    and .sandbox.allowUnsandboxedCommands == false
    and .sandbox.network.strictAllowlist == true
    and .permissions.blockWritesOutsideWorkingDirectories == true
    and (.permissions.deny | index("WebFetch") != null)
    and (.permissions.deny | index("WebSearch") != null)
    and (.permissions.deny | index("Read(//**/.env)") != null)
    and (.permissions.deny | index("Read(//**/.env.*)") != null)
    and (.permissions.deny | index("Read(~/.config/gh/**)") != null)
    and (.sandbox.network.allowedDomains == ["github.com", "api.github.com", "*.githubusercontent.com"])
  ' "$settings" >/dev/null || fail "the external settings file lacks the sandbox block"$'\n'"$(cat "$settings")"
  jq -e '(.hooks.UserPromptSubmit | length) == 1 and (.hooks.Stop | length) == 1 and (.hooks.SessionEnd | length) == 1' "$settings" >/dev/null \
    || fail "the external worker's busy hooks must ride its settings file"$'\n'"$(cat "$settings")"
  wt_real=$(cd "$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")" && pwd -P)
  [ ! -e "$wt_real/.claude/settings.local.json" ] || fail "the external worker's hooks landed in a worktree settings file it does not load"
  common=$(cd "$PROJECT_DIR/.git" && pwd -P)
  admin=$(cd "$(sed -n 's/^gitdir: //p' "$wt_real/.git")" && pwd -P)
  case "$admin" in "$common/worktrees/"*) ;; *) fail "the fixture worktree is not linked into $common: $admin" ;; esac
  tmp_real=$(cd "/tmp/fm-$id" && pwd -P)
  jq -e --arg status "$state_real/$id.status" --arg tmp "$tmp_real" --arg common "$common" --arg admin "$admin" '
    .sandbox.filesystem.allowWrite == [$status, $tmp, "\($common)/objects", "\($common)/refs", "\($common)/logs",
      "\($common)/packed-refs", "\($common)/packed-refs.lock", $admin]
  ' "$settings" >/dev/null \
    || fail "beyond the task channels the sandbox must write only the status file, the task temp root, the shared objects, refs, reflogs, and packed refs, and this worktree's own admin directory"$'\n'"$(cat "$settings")"
  root_real=$(cd "$ROOT" && pwd -P)
  jq -e --arg skills "$root_real/.agents/skills" --arg wt "$wt_real" --arg common "$common" --arg admin "$admin" '
    .sandbox.filesystem.denyWrite == [$skills, "\($wt)/.claude/settings.json", "\($wt)/.claude/settings.local.json",
      "\($wt)/.git", "\($common)/commondir", "\($common)/config", "\($common)/config.worktree", "\($common)/hooks",
      "\($common)/modules", "\($admin)/commondir", "\($admin)/gitdir", "\($admin)/config.worktree"]
    and ([.sandbox.filesystem.denyWrite[] | "Edit(/\(.))", "Edit(/\(.)/**)"] - .permissions.deny) == []
  ' "$settings" >/dev/null \
    || fail "the skills, the worktree Claude settings, and every git link, config, and hooks path must stay unwritable for every tool"$'\n'"$(cat "$settings")"
  jq -e '.sandbox.network | has("allowUnixSockets") | not' "$settings" >/dev/null \
    || fail "a worktree with no local gate must allow no Unix socket"$'\n'"$(cat "$settings")"
  grep -qx 'trust=external' "$HOME_DIR/state/$id.meta" || fail "the task record lacks the external mark"
}

test_registered_external_project_launches_contained() {
  local id=ext-reg out status
  make_case registered "$id" "no-mistakes trust=external"
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "a trust=external project should launch"$'\n'"$out"
  assert_contained "$id"
  pass "fm-spawn: a project registered trust=external launches its worker inside the sandbox"
}

test_external_flag_marks_one_task_on_an_unmarked_project() {
  local id=ext-flag out status
  make_case flag "$id" "no-mistakes"
  out=$(run_spawn "$id" --external); status=$?
  expect_code 0 "$status" "--external should launch"$'\n'"$out"
  assert_contained "$id"
  pass "fm-spawn: --external marks one task on a project that is not marked"
}

test_local_gate_opens_the_gate_and_its_daemon_only() {
  local id=ext-gate out status settings gate
  make_case gate "$id" "no-mistakes trust=external"
  git init --quiet --bare "$CASE_DIR/nm-home/repos/gate.git"
  git -C "$PROJECT_DIR" remote add no-mistakes "$CASE_DIR/nm-home/repos/gate.git"
  out=$(NM_HOME="$CASE_DIR/nm-home" run_spawn "$id"); status=$?
  expect_code 0 "$status" "an external spawn with a local gate should launch"$'\n'"$out"
  settings="$(cd "$HOME_DIR/state" && pwd -P)/$id.claude-settings.json"
  gate=$(cd "$CASE_DIR/nm-home/repos/gate.git" && pwd -P)
  jq -e --arg gate "$gate" '
    (.sandbox.filesystem.allowWrite | .[-5:]) == ["\($gate)/objects", "\($gate)/refs", "\($gate)/logs",
      "\($gate)/packed-refs", "\($gate)/packed-refs.lock"]
  ' "$settings" >/dev/null \
    || fail "a push to a local gate repository needs exactly its objects, refs, reflogs, and packed refs"$'\n'"$(cat "$settings")"
  jq -e --arg gate "$gate" '
    (.sandbox.filesystem.denyWrite | .[-4:]) == ["\($gate)/commondir", "\($gate)/config", "\($gate)/hooks", "\($gate)/worktrees"]
    and (.permissions.deny | index("Edit(/\($gate)/hooks/**)") != null)
  ' "$settings" >/dev/null \
    || fail "a local gate repository must keep its links, config, hooks, and worktrees unwritable"$'\n'"$(cat "$settings")"
  jq -e --arg sock "$CASE_DIR/nm-home/socket" '.sandbox.network.allowUnixSockets == [$sock]' "$settings" >/dev/null \
    || fail "a local gate must open exactly the no-mistakes daemon socket"$'\n'"$(cat "$settings")"
  pass "fm-spawn: a worktree with a local gate opens that gate and the daemon socket, and nothing else"
}

test_batch_dispatch_keeps_the_external_flag() {
  local id=ext-batch out status
  make_case batch "$id" "no-mistakes"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id=$PROJECT_DIR" --mode no-mistakes --yolo off --external); status=$?
  expect_code 0 "$status" "a batch --external spawn should launch"$'\n'"$out"
  assert_contained "$id"
  pass "fm-spawn: batch dispatch passes --external to every pair"
}

test_unmarked_task_launches_unchanged() {
  local id=ext-none out status launch
  make_case unmarked "$id" "no-mistakes"
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "an unmarked spawn should launch"$'\n'"$out"
  launch=$(launch_text)
  assert_contains "$launch" "--settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}' " \
    "an unmarked worker must keep its inline session settings"
  [ ! -e "$HOME_DIR/state/$id.claude-settings.json" ] || fail "an unmarked worker got a settings file"
  assert_not_contains "$launch" "--strict-mcp-config" "an unmarked worker must keep its MCP servers"
  assert_not_contains "$launch" "--setting-sources" "an unmarked worker must keep its project and local settings"
  jq -e '.hooks.UserPromptSubmit' "$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")/.claude/settings.local.json" >/dev/null \
    || fail "an unmarked worker must keep its busy hooks in the worktree settings file"
  ! grep -q '^trust=' "$HOME_DIR/state/$id.meta" || fail "an unmarked task recorded a trust mark"
  pass "fm-spawn: an unmarked task launches exactly as before"
}

# assert_refused <id> <output> <status> <needle> <why>
assert_refused() {
  [ "$3" -ne 0 ] || fail "$5 launched"$'\n'"$2"
  assert_contains "$2" "$4" "the refusal for $5 did not name its cause"
  [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "the refused spawn for $5 still published a task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "the refused spawn for $5 still sent a launch"
}

test_marks_the_launch_cannot_honor_refuse_before_any_record() {
  local id out status
  id=ext-typo
  make_case typo "$id" "no-mistakes trust=extrenal"
  out=$(run_spawn "$id"); status=$?
  assert_refused "$id" "$out" "$status" 'unknown trust binding "trust=extrenal"' "an unknown trust value"

  id=ext-codex
  make_case codex "$id" "no-mistakes trust=external" codex
  out=$(run_spawn "$id"); status=$?
  assert_refused "$id" "$out" "$status" "the codex runtime has no verified external worker sandbox" "a non-Claude external worker"
  pass "fm-spawn: an unknown mark and a runtime without the sandbox refuse before any record"
}

test_external_flag_is_refused_on_a_secondmate() {
  local out status
  out=$("$ROOT/bin/fm-spawn.sh" mate-x "$TMP_ROOT" --secondmate --external 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "--external was accepted on a secondmate"$'\n'"$out"
  assert_contains "$out" "--external applies to ships and scouts" "the refusal did not explain the scope"
  pass "fm-spawn: --external is refused on a secondmate"
}

test_backend_that_starts_its_own_agent_is_refused() {
  local out status
  out=$(bash -c '. "$1/bin/fm-external-sandbox-lib.sh"; fm_external_check claude 0 t3code' _ "$ROOT" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "an external launch on backend=t3code was accepted"
  assert_contains "$out" "backend=t3code starts the agent itself" "the t3code refusal did not name its cause"
  out=$(bash -c '. "$1/bin/fm-external-sandbox-lib.sh"; fm_external_check claude 0 tmux' _ "$ROOT" 2>&1); status=$?
  expect_code 0 "$status" "an external claude launch on tmux should be accepted"$'\n'"$out"
  pass "fm-external-sandbox-lib: a backend that starts its own agent refuses the external mark"
}

test_registered_external_project_launches_contained
test_backend_that_starts_its_own_agent_is_refused
test_external_flag_marks_one_task_on_an_unmarked_project
test_unmarked_task_launches_unchanged
test_batch_dispatch_keeps_the_external_flag
test_local_gate_opens_the_gate_and_its_daemon_only
test_marks_the_launch_cannot_honor_refuse_before_any_record
test_external_flag_is_refused_on_a_secondmate

echo "# all fm-spawn-external-sandbox tests passed"
