#!/usr/bin/env bash
# Behavior tests for bin/fm-pi-trust.sh and the pi/pi-signed task spawns that
# call it before launching a worker into a fresh linked worktree.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-trust)
TRUST="$ROOT/bin/fm-pi-trust.sh"

make_case() {
  local name=$1 case_dir proj wt home agent
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  home="$case_dir/home"
  agent="$case_dir/agent"
  mkdir -p "$home" "$agent"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$home" "$agent"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT HOME_DIR AGENT_DIR <<EOF
$1
EOF
}

run_trust() {
  local agent=$1 home=$2 wt=$3 proj=$4
  PI_CODING_AGENT_DIR="$agent" HOME="$home" "$TRUST" "$wt" "$proj" 2>&1
}

store_value() {
  local store=$1 key=$2
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify(j[process.argv[2]]));' "$store" "$key"
}

assert_store_value() {
  local store=$1 key=$2 expected=$3 msg=$4 actual
  actual=$(store_value "$store" "$key")
  [ "$actual" = "$expected" ] || fail "$msg (expected $expected, got $actual)"
}

assert_trusted() {
  local store=$1 path=$2 msg=$3
  assert_store_value "$store" "$path" true "$msg"
}

assert_not_trusted() {
  local store=$1 path=$2 msg=$3
  if [ -f "$store" ] && [ "$(store_value "$store" "$path")" = true ]; then
    fail "$msg"
  fi
}

inode_of() {
  node -e 'console.log(require("node:fs").statSync(process.argv[1]).ino)' "$1"
}

test_registration_preserves_entries_and_replaces_atomically() {
  local rec store before_inode after_inode out
  rec=$(make_case fresh)
  read_case "$rec"
  store="$AGENT_DIR/trust.json"
  cat > "$store" <<'JSON'
{
  "/another/project": false,
  "/kept/null": null,
  "/kept/trusted": true
}
JSON
  before_inode=$(inode_of "$store")
  out=$(run_trust "$AGENT_DIR" "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a fresh linked worktree must be trusted: $out"
  assert_contains "$out" "trusted: $WT" "registration did not report the resolved worktree"
  assert_trusted "$store" "$WT" "the worktree was not recorded as trusted"
  assert_store_value "$store" /another/project false "an unrelated refusal was changed"
  assert_store_value "$store" /kept/null null "an unrelated null entry was changed"
  assert_store_value "$store" /kept/trusted true "an unrelated trusted entry was changed"
  after_inode=$(inode_of "$store")
  [ "$before_inode" != "$after_inode" ] || fail "the store was edited in place instead of replaced atomically"
  [ -z "$(find "$AGENT_DIR" -maxdepth 1 -name '.trust.json.fm-trust.*' -print -quit)" ] \
    || fail "the atomic replacement left a temporary trust file behind"
  pass "fm-pi-trust.sh: preserves unrelated entries and atomically records a fresh worktree"
}

test_registration_is_idempotent() {
  local rec out
  rec=$(make_case idempotent)
  read_case "$rec"
  run_trust "$AGENT_DIR" "$HOME_DIR" "$WT" "$PROJ" >/dev/null || fail "initial registration failed"
  out=$(run_trust "$AGENT_DIR" "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a repeated registration must succeed: $out"
  assert_trusted "$AGENT_DIR/trust.json" "$WT" "repeat registration lost trust"
  pass "fm-pi-trust.sh: repeat registration is idempotent"
}

test_primary_checkout_is_refused() {
  local rec out
  rec=$(make_case primary)
  read_case "$rec"
  out=$(run_trust "$AGENT_DIR" "$HOME_DIR" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$AGENT_DIR/trust.json" "$PROJ" "the primary checkout was trusted"
  pass "fm-pi-trust.sh: refuses a primary checkout"
}

test_foreign_worktree_is_refused() {
  local rec other other_wt out
  rec=$(make_case foreign)
  read_case "$rec"
  other="$CASE_DIR/other-project"
  other_wt="$CASE_DIR/other-wt"
  fm_git_worktree "$other" "$other_wt" other-wt
  out=$(run_trust "$AGENT_DIR" "$HOME_DIR" "$other_wt" "$PROJ")
  expect_code 1 $? "an unrelated repo's worktree must be refused: $out"
  assert_contains "$out" "is not a worktree of project" "the refusal did not name the repository mismatch"
  assert_not_trusted "$AGENT_DIR/trust.json" "$other_wt" "the unrelated worktree was trusted"
  pass "fm-pi-trust.sh: refuses an unrelated repository's worktree"
}

test_worktree_subdirectory_is_refused() {
  local rec sub out
  rec=$(make_case subdirectory)
  read_case "$rec"
  sub="$WT/sub"
  mkdir -p "$sub"
  out=$(run_trust "$AGENT_DIR" "$HOME_DIR" "$sub" "$PROJ")
  expect_code 1 $? "a worktree subdirectory must be refused: $out"
  assert_contains "$out" "is not a worktree root" "the refusal did not name the subdirectory"
  assert_not_trusted "$AGENT_DIR/trust.json" "$sub" "the subdirectory was trusted"
  pass "fm-pi-trust.sh: refuses a worktree subdirectory"
}

test_plain_directory_is_refused() {
  local rec plain out
  rec=$(make_case plain)
  read_case "$rec"
  plain="$CASE_DIR/plain"
  mkdir -p "$plain"
  out=$(run_trust "$AGENT_DIR" "$HOME_DIR" "$plain" "$PROJ")
  expect_code 1 $? "a plain directory must be refused: $out"
  assert_contains "$out" "not inside a git repository" "the refusal did not name the missing repository"
  assert_not_trusted "$AGENT_DIR/trust.json" "$plain" "the plain directory was trusted"
  pass "fm-pi-trust.sh: refuses a plain directory"
}

test_home_directory_is_refused_even_when_linked() {
  local rec home_wt out
  rec=$(make_case home)
  read_case "$rec"
  home_wt="$CASE_DIR/user-home-worktree"
  git -C "$PROJ" worktree add --quiet -b home-wt "$home_wt"
  out=$(run_trust "$AGENT_DIR" "$home_wt" "$home_wt" "$PROJ")
  expect_code 1 $? "HOME must be refused even when it is a valid linked worktree: $out"
  assert_contains "$out" "home directory" "the refusal did not name HOME"
  assert_not_trusted "$AGENT_DIR/trust.json" "$home_wt" "HOME was trusted"
  pass "fm-pi-trust.sh: refuses the launching user's home directory"
}

test_git_environment_cannot_defeat_scope() {
  local rec out code
  rec=$(make_case git-env)
  read_case "$rec"
  GIT_DIR=$(git -C "$WT" rev-parse --absolute-git-dir)
  GIT_WORK_TREE=$PROJ
  export GIT_DIR GIT_WORK_TREE
  out=$(run_trust "$AGENT_DIR" "$HOME_DIR" "$PROJ" "$PROJ")
  code=$?
  unset GIT_DIR GIT_WORK_TREE
  expect_code 1 "$code" "git environment overrides must not admit the primary checkout: $out"
  assert_contains "$out" "primary checkout" "the override-safe refusal did not identify the primary checkout"
  pass "fm-pi-trust.sh: inherited git overrides cannot defeat its scope test"
}

test_agent_dir_override_is_respected_and_relative_values_refuse() {
  local rec override out
  rec=$(make_case override)
  read_case "$rec"
  override="$CASE_DIR/alternate-agent"
  out=$(run_trust "$override" "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "an absolute PI_CODING_AGENT_DIR must work: $out"
  assert_trusted "$override/trust.json" "$WT" "trust did not land in PI_CODING_AGENT_DIR"

  out=$(cd "$CASE_DIR" && PI_CODING_AGENT_DIR=relative-agent HOME="$HOME_DIR" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a relative PI_CODING_AGENT_DIR must refuse: $out"
  assert_contains "$out" "relative path" "the refusal did not explain the ambiguous override"
  [ ! -e "$CASE_DIR/relative-agent/trust.json" ] || fail "a relative override wrote a store from the helper's cwd"
  [ ! -e "$WT/relative-agent/trust.json" ] || fail "a relative override wrote a store into project content"
  pass "fm-pi-trust.sh: honors a safe agent-dir override and refuses a relative one"
}

test_corrupt_or_foreign_store_is_refused() {
  local rec store out
  rec=$(make_case bad-store)
  read_case "$rec"
  store="$AGENT_DIR/trust.json"
  printf 'not json\n' > "$store"
  out=$(run_trust "$AGENT_DIR" "$HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "an unparseable store must refuse: $out"
  assert_grep 'not json' "$store" "the unparseable store was overwritten"

  if [ "$(id -u)" != 0 ]; then
    rm -f "$store"
    ln -s /etc/passwd "$store"
    out=$(run_trust "$AGENT_DIR" "$HOME_DIR" "$WT" "$PROJ")
    expect_code 1 $? "a store owned by another uid must refuse: $out"
    assert_contains "$out" "not owned by this user" "the refusal did not name the ownership problem"
  fi
  pass "fm-pi-trust.sh: refuses corrupt and foreign-owned stores"
}

spawn_pi_case() {
  local harness=$1 case_dir home proj wt agent fakebin launch_log out id
  case_dir="$TMP_ROOT/spawn-$harness"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  agent="$case_dir/pi-agent"
  launch_log="$case_dir/launch.log"
  id="trust-${harness}"
  mkdir -p "$agent"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" "$harness")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$harness"
  fm_test_spawn_brief "$home" "$id"
  out=$(FM_TEST_PI_CODING_AGENT_DIR="$agent" FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$harness" \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "the $harness task spawn must succeed: $out"
  assert_trusted "$agent/trust.json" "$wt" "$harness spawn did not pre-register its worktree"
  assert_present "$launch_log" "$harness spawn sent no launch command"
  assert_grep "$home/data/$id/launch-brief.md" "$launch_log" "$harness launch did not carry its brief"
  assert_grep "PI_CODING_AGENT_DIR='$agent'" "$launch_log" "$harness launch did not inherit the store it registered"
  pass "fm-spawn.sh: $harness pre-trusts a task worktree and launches with its brief"
}

test_refused_pi_spawn_leaves_no_task_state() {
  local case_dir home proj wt agent fakebin out id
  case_dir="$TMP_ROOT/spawn-refusal"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  agent="$case_dir/pi-agent"
  id="pi-refused-$$"
  mkdir -p "$agent"
  printf 'not json\n' > "$agent/trust.json"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi)
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" refused-wt
  fm_test_spawn_brief "$home" "$id"
  out=$(FM_TEST_PI_CODING_AGENT_DIR="$agent" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" pi \
    --mode no-mistakes --yolo off)
  expect_code 1 $? "a pi spawn must refuse when trust cannot be recorded: $out"
  assert_contains "$out" "could not pre-register Pi project trust" "the spawn did not name the trust failure"
  assert_absent "$home/state/$id.meta" "a refused pi spawn published task metadata"
  assert_absent "$home/state/$id.busy-gen" "a refused pi spawn left a busy generation"
  [ ! -e "/tmp/fm-$id" ] || { rm -rf "/tmp/fm-$id"; fail "a refused pi spawn stranded its temp root"; }
  pass "fm-spawn.sh: a Pi trust failure refuses before task state is created"
}

test_registration_preserves_entries_and_replaces_atomically
test_registration_is_idempotent
test_primary_checkout_is_refused
test_foreign_worktree_is_refused
test_worktree_subdirectory_is_refused
test_plain_directory_is_refused
test_home_directory_is_refused_even_when_linked
test_git_environment_cannot_defeat_scope
test_agent_dir_override_is_respected_and_relative_values_refuse
test_corrupt_or_foreign_store_is_refused
spawn_pi_case pi
spawn_pi_case pi-signed
test_refused_pi_spawn_leaves_no_task_state
