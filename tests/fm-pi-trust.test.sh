#!/usr/bin/env bash
# Behavior tests for bin/fm-pi-trust.sh and its Pi spawn integration.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-trust)
TRUST="$ROOT/bin/fm-pi-trust.sh"

make_case() {
  local name=$1 case_dir=$TMP_ROOT/$1
  CASE_DIR=$case_dir
  PROJ=$case_dir/project
  WT=$case_dir/wt
  AGENT=$case_dir/pi-agent
  mkdir -p "$AGENT"
  fm_git_worktree "$PROJ" "$WT" "wt-$name"
}

run_trust() {
  PI_CODING_AGENT_DIR="$AGENT" HOME="$CASE_DIR/home" "$TRUST" "$WT" "$PROJ" 2>&1
}

assert_trusted() {
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.exit(j[process.argv[2]]===true?0:1)' "$1" "$2" \
    || fail "$3"
}

assert_value() {
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));const value=j[process.argv[2]];if(JSON.stringify(value)!==process.argv[3])process.exit(1)' "$1" "$2" "$3" \
    || fail "$4"
}

test_fresh_worktree_is_trusted() {
  local out
  make_case fresh
  out=$(run_trust)
  expect_code 0 $? "a fresh worktree must be trusted: $out"
  assert_trusted "$AGENT/trust.json" "$WT" "the exact canonical worktree was not trusted"
  pass "fm-pi-trust.sh: trusts the exact worktree"
}

test_existing_decisions_are_preserved() {
  local out
  make_case preserve
  cat > "$AGENT/trust.json" <<JSON
{"$CASE_DIR/other":false,"$CASE_DIR/parent":null}
JSON
  out=$(run_trust)
  expect_code 0 $? "an existing trust store must remain usable: $out"
  assert_trusted "$AGENT/trust.json" "$WT" "the worktree was not trusted in an existing store"
  assert_value "$AGENT/trust.json" "$CASE_DIR/other" false "an existing false decision was changed"
  assert_value "$AGENT/trust.json" "$CASE_DIR/parent" null "an existing null decision was changed"
  pass "fm-pi-trust.sh: preserves existing decisions"
}

test_primary_checkout_is_refused() {
  local out
  make_case primary
  out=$(PI_CODING_AGENT_DIR="$AGENT" HOME="$CASE_DIR/home" "$TRUST" "$PROJ" "$PROJ" 2>&1)
  expect_code 1 $? "the primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "the refusal did not identify the primary checkout"
  [ ! -e "$AGENT/trust.json" ] || fail "the primary checkout was trusted"
  pass "fm-pi-trust.sh: refuses the primary checkout"
}

test_pi_spawn_pretrusts_before_launch_and_only_submits_shell_command() {
  local out fakebin events launch_log
  make_case spawn
  events="$CASE_DIR/events.log"
  launch_log="$CASE_DIR/launch.log"
  fakebin=$(make_spawn_fakebin "$CASE_DIR/fake" pi)
  fm_test_write_active_treehouse_fake "$fakebin" "$WT"
  fm_test_spawn_home "$CASE_DIR/home" pi
  fm_test_spawn_brief "$CASE_DIR/home" trustspawn
  out=$(PI_CODING_AGENT_DIR="$AGENT" \
    FM_FAKE_EVENT_LOG="$events" FM_FAKE_LAUNCH_LOG="$launch_log" \
    FM_FAKE_LAUNCH_TOKEN='FM_PI_HARNESS=pi' \
    FM_FAKE_TRUST_STORE="$AGENT/trust.json" FM_FAKE_TRUST_PATH="$WT" \
    fm_test_run_spawn "$CASE_DIR/home" "$WT" "$fakebin" trustspawn "$PROJ" pi \
    --mode direct-PR --yolo off)
  expect_code 0 $? "the Pi spawn must succeed: $out"
  assert_trusted "$AGENT/trust.json" "$WT" "the Pi spawn did not pre-register its worktree"
  assert_contains "$(cat "$events")" "launch-trust-present" \
    "the launch payload was accepted before its trust entry existed"
  assert_contains "$(cat "$launch_log")" "PI_CODING_AGENT_DIR='$AGENT'" \
    "the launch did not carry the same Pi config directory"
  assert_contains "$(cat "$launch_log")" "FM_PI_HARNESS=pi" \
    "the launch was not the Pi command"
  [ "$(grep -Fc 'launch-submit:Enter' "$events" 2>/dev/null || true)" = 1 ] \
    || fail "the pre-trusted launch sent an unexpected dialog-answer key"
  pass "fm-spawn.sh: pre-trusts Pi before launch without a dialog-answer key"
}

test_fresh_worktree_is_trusted
test_existing_decisions_are_preserved
test_primary_checkout_is_refused
test_pi_spawn_pretrusts_before_launch_and_only_submits_shell_command
