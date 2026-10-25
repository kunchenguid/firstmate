#!/usr/bin/env bash
# tests/fm-model-allowlist.test.sh - per-provider model limits through the real
# executables: the command refuses, edits, watches, and installs its fleet check, and
# bin/fm-spawn.sh refuses an off-list pick before anything is provisioned.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TOOL="$ROOT/bin/fm-model-allowlist.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-allowlist)
HOME_DIR="$TMP_ROOT/home"
LIST="$HOME_DIR/config/model-allow-list.json"
fm_test_spawn_home "$HOME_DIR"

# run_tool [args...]: sets CODE, OUT, and ERR from the real command.
run_tool() {
  FM_HOME="$HOME_DIR" "$TOOL" "$@" >"$TMP_ROOT/tool.out" 2>"$TMP_ROOT/tool.err"
  CODE=$?
  OUT=$(cat "$TMP_ROOT/tool.out")
  ERR=$(cat "$TMP_ROOT/tool.err")
}

# --- check: the one refusal line, the allowed pick, the unreadable list -----
printf '%s\n' '{"codex":["gpt-5.6-sol"],"claude":["sonnet"]}' >"$LIST"
run_tool check codex gpt-5.6-sol
expect_code 0 "$CODE" "a listed model is allowed"
assert_equals '' "$ERR" "an allowed pick says nothing"
run_tool check codex gpt-5.6-sol:1017
expect_code 0 "$CODE" "a pinned tag of a listed model is allowed"
run_tool check gemini gemini-3-pro
expect_code 0 "$CODE" "a provider the file does not name is not limited"
run_tool check claude fable
expect_code 1 "$CODE" "an off-list model is refused"
assert_contains "$ERR" 'claude model fable is not allowed (allowed: sonnet); allow it with bin/fm-model-allowlist.sh allow claude fable' "one line names the provider, the model, the allowed models, and the way to allow it"
[ "$(printf '%s\n' "$ERR" | grep -c .)" -eq 1 ] || fail "the refusal must be exactly one line"
run_tool allow claude fable
run_tool check claude fable
expect_code 0 "$CODE" "following the printed advice allows the model it names"
printf 'not json\n' >"$LIST"
run_tool check codex gpt-5.6-sol
expect_code 1 "$CODE" "an unreadable list refuses instead of lifting the limit"
assert_contains "$ERR" 'cannot be read' "it says the check could not run"
pass "check allows a listed model, a pinned tag and an unnamed provider, and refuses an off-list model in one line"

# --- view and edit ---------------------------------------------------------
printf '%s\n' '{"codex":["gpt-5.6-sol"]}' >"$LIST"
run_tool allow codex gpt-5.6-sol-lite
assert_equals '{"codex":["gpt-5.6-sol","gpt-5.6-sol-lite"]}' "$(jq -cS . "$LIST")" "allow adds models to one provider's list"
run_tool allow codex gpt-5.6-sol-lite
assert_equals '{"codex":["gpt-5.6-sol","gpt-5.6-sol-lite"]}' "$(jq -cS . "$LIST")" "allowing twice is one entry"
run_tool deny codex gpt-5.6-sol gpt-5.6-sol-lite
assert_contains "$OUT" 'codex: none' "a provider left with no models still shows, so it refuses everything"
pass "list, allow, and deny edit the one file; an emptied provider stays named"

# --- watch: the backstop for a model that starts anyway, and its fleet check ---
printf '%s\n' '{"codex":["gpt-5.6-sol"]}' >"$LIST"
printf '%s\t%s\t%s\t%s\n' 1800000000 codex gpt-5.6-sol high >"$HOME_DIR/state/live-task.models"
printf '%s\t%s\t%s\t%s\n' 1800000001 codex gpt-9-nope high >>"$HOME_DIR/state/live-task.models"
run_tool watch
assert_contains "$OUT" 'model-allowlist: codex ran model gpt-9-nope although codex allows gpt-5.6-sol; allow it with bin/fm-model-allowlist.sh allow codex gpt-9-nope' "an off-list launch is reported with the way to allow it"
assert_not_contains "$OUT" 'gpt-5.6-sol although' "an allowed launch is not reported"
run_tool watch
assert_equals '' "$OUT" "an already reported model is never reported twice"
run_tool install
[ -f "$HOME_DIR/state/model-allowlist.check-trust" ] || fail "install must bind the check with fm-check-register.sh"
rm -f "$HOME_DIR/state/.model-allowlist.seen"
assert_contains "$(FM_HOME="$HOME_DIR" "$HOME_DIR/state/model-allowlist.check.sh")" 'gpt-9-nope' "the installed check reports the off-list launch through the watcher path"
run_tool uninstall
assert_absent "$HOME_DIR/state/model-allowlist.check.sh" "uninstall retires the check"
assert_contains "$(cat "$LIST")" 'codex' "uninstall never touches the list"
pass "watch reports a launched off-list model once, and install and uninstall manage its fleet check"

# --- the launch gate: a real refusal, then a real allowed spawn ------------
case_dir="$TMP_ROOT/spawn"
project="$case_dir/project"
worktree="$case_dir/wt"
launchlog="$case_dir/launch.log"
fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
fm_git_worktree "$project" "$worktree" wt-model-allowlist
fm_test_spawn_brief "$HOME_DIR" t-refused
fm_test_spawn_brief "$HOME_DIR" t-allowed
: >"$launchlog"
out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$case_dir/pane.log" \
  fm_test_run_spawn "$HOME_DIR" "$worktree" "$fakebin" t-refused "$project" --mode direct-PR --yolo off --harness codex --model codex/gpt-9-nope)
status=$?
expect_code 1 "$status" "an off-list spawn must be refused: $out"
assert_contains "$out" 'codex model gpt-9-nope is not allowed (allowed: gpt-5.6-sol); allow it with bin/fm-model-allowlist.sh allow codex gpt-9-nope' "the refusal is one line naming the provider, the model and the way to allow it"
assert_absent "$HOME_DIR/state/t-refused.meta" "a refused pick creates no task record"
assert_equals '' "$(cat "$launchlog")" "a refused pick launches nothing"
out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$case_dir/pane.log" \
  fm_test_run_spawn "$HOME_DIR" "$worktree" "$fakebin" t-allowed "$project" --mode direct-PR --yolo off --harness codex --model codex/gpt-5.6-sol)
status=$?
expect_code 0 "$status" "the same spawn with a listed model must succeed: $out"
assert_contains "$(cat "$launchlog")" 'gpt-5.6-sol' "the allowed model reaches the launch"
assert_contains "$(cat "$HOME_DIR/state/t-allowed.models")" 'codex	codex/gpt-5.6-sol' "the allowed launch is recorded for the watch"
pass "an off-list pick is refused before anything is provisioned and the allowed one launches"

printf '# all fm-model-allowlist tests passed\n'
