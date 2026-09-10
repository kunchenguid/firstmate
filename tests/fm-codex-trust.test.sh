#!/usr/bin/env bash
# Behavior tests for bin/fm-codex-trust.sh and the Codex spawn that calls it.
#
# These cases exercise only executable interfaces. They prove fresh recording,
# repeat idempotence, scope refusal, byte-preserving edits of an unrelated TOML
# fixture, an owned value update, and spawn-time integration.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-trust)
TRUST="$ROOT/bin/fm-codex-trust.sh"

make_case() {
  local name=$1 case_dir proj wt home
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  home="$case_dir/home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$home"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT HOME_DIR <<EOF
$1
EOF
}

run_trust() {
  HOME=$1 "$TRUST" "$2" "$3" 2>&1
}

assert_trusted() {
  local store=$1 path=$2 msg=$3
  node - "$store" "$path" <<'NODE' || fail "$msg"
const fs = require("node:fs");
const [store, path] = process.argv.slice(2);
const text = fs.readFileSync(store, "utf8");
const escaped = path.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
const lines = text.split(/\r?\n/);
const header = `[projects."${escaped}"]`;
const index = lines.indexOf(header);
process.exit(index >= 0 && lines[index + 1] === 'trust_level = "trusted"' ? 0 : 1);
NODE
}

test_fresh_worktree_is_recorded() {
  local rec out store
  rec=$(make_case fresh)
  read_case "$rec"
  store="$HOME_DIR/.codex/config.toml"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a fresh linked worktree must be recorded: $out"
  assert_contains "$out" "recorded: $WT" "success was not based on the read-back result"
  assert_trusted "$store" "$WT" "the worktree was not recorded as trusted"
  [ -z "$(find "$HOME_DIR/.codex" -maxdepth 1 -name '.config.toml.fm-trust.*' -print -quit)" ] \
    || fail "a temporary Codex config was left behind"
  pass "fm-codex-trust.sh: records a fresh task worktree"
}

test_already_trusted_worktree_is_idempotent() {
  local rec out store before
  rec=$(make_case idempotent)
  read_case "$rec"
  store="$HOME_DIR/.codex/config.toml"
  before="$CASE_DIR/before"
  run_trust "$HOME_DIR" "$WT" "$PROJ" >/dev/null || fail "initial registration failed"
  cp "$store" "$before"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "an already-trusted worktree must succeed: $out"
  assert_contains "$out" "recorded: $WT" "idempotent success was not verified by read-back"
  cmp -s "$before" "$store" || fail "repeat registration changed an already-trusted store"
  pass "fm-codex-trust.sh: repeat registration is byte-idempotent"
}

test_primary_checkout_is_refused() {
  local rec out store
  rec=$(make_case primary)
  read_case "$rec"
  store="$HOME_DIR/.codex/config.toml"
  out=$(run_trust "$HOME_DIR" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  [ ! -e "$store" ] || fail "a refusal wrote the Codex config"
  pass "fm-codex-trust.sh: refuses the primary checkout"
}

test_foreign_project_worktree_is_refused() {
  local rec out other other_wt store
  rec=$(make_case foreign)
  read_case "$rec"
  other="$CASE_DIR/other-project"
  other_wt="$CASE_DIR/other-wt"
  store="$HOME_DIR/.codex/config.toml"
  fm_git_worktree "$other" "$other_wt" wt-other
  out=$(run_trust "$HOME_DIR" "$other_wt" "$PROJ")
  expect_code 1 $? "a foreign project's worktree must be refused: $out"
  assert_contains "$out" "is not a worktree of project" "the refusal did not name the project mismatch"
  [ ! -e "$store" ] || fail "a foreign-worktree refusal wrote the Codex config"
  pass "fm-codex-trust.sh: refuses a worktree from another project"
}

test_unrelated_toml_bytes_are_preserved() {
  local rec store expected
  rec=$(make_case preserve)
  read_case "$rec"
  store="$HOME_DIR/.codex/config.toml"
  expected="$CASE_DIR/expected.toml"
  mkdir -p "$HOME_DIR/.codex"
  cat > "$store" <<'TOML'
# operator comment and formatting stay byte-for-byte
model = "gpt-test"

[features]
web_search = true # keep this spacing

[projects."/another/worktree"]
trust_level = "trusted"

[mcp_servers.fixture]
command = "printf"
args = ["one", "two"]
TOML
  cp "$store" "$expected"
  printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$WT" >> "$expected"
  run_trust "$HOME_DIR" "$WT" "$PROJ" >/dev/null || fail "registration against an existing TOML store failed"
  cmp -s "$expected" "$store" \
    || fail "registration changed bytes outside the one appended project entry"
  assert_trusted "$store" "$WT" "the appended worktree was not recorded as trusted"
  pass "fm-codex-trust.sh: preserves every unrelated TOML byte"
}

test_owned_untrusted_value_is_updated_in_place() {
  local rec store expected
  rec=$(make_case update)
  read_case "$rec"
  store="$HOME_DIR/.codex/config.toml"
  expected="$CASE_DIR/expected.toml"
  mkdir -p "$HOME_DIR/.codex"
  printf '[projects."%s"]\ntrust_level = "untrusted" # owned value\n\n[features]\nweb_search = false\n' "$WT" > "$store"
  printf '[projects."%s"]\ntrust_level = "trusted" # owned value\n\n[features]\nweb_search = false\n' "$WT" > "$expected"
  run_trust "$HOME_DIR" "$WT" "$PROJ" >/dev/null || fail "updating an existing worktree entry failed"
  cmp -s "$expected" "$store" || fail "the update changed bytes beyond the owned trust value"
  pass "fm-codex-trust.sh: updates only the owned trust value"
}

test_codex_spawn_pretrusts_before_launch() {
  local case_dir home proj wt fakebin launch_log out store
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launch_log="$case_dir/launch.log"
  store="$home/user-home/.codex/config.toml"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" codex)
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" wt-spawn
  fm_test_spawn_brief "$home" trustspawn
  out=$(FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" trustspawn "$proj" codex \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "the Codex spawn must succeed after pre-registration: $out"
  assert_trusted "$store" "$wt" "the Codex spawn did not pre-register its worktree"
  assert_present "$launch_log" "the Codex spawn sent no launch command"
  assert_grep 'codex --dangerously-bypass-approvals-and-sandbox' "$launch_log" \
    "the launch command was not the Codex worker launch"
  assert_grep "$home/data/trustspawn/launch-brief.md" "$launch_log" \
    "the Codex launch did not carry the brief"
  pass "fm-spawn.sh: a Codex spawn pre-trusts its worktree before launch"
}

test_fresh_worktree_is_recorded
test_already_trusted_worktree_is_idempotent
test_primary_checkout_is_refused
test_foreign_project_worktree_is_refused
test_unrelated_toml_bytes_are_preserved
test_owned_untrusted_value_is_updated_in_place
test_codex_spawn_pretrusts_before_launch
