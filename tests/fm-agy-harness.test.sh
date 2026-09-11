#!/usr/bin/env bash
# Portable AGY worker adapter behavior: exact process identity, isolated spawn,
# model preflight, generation/workspace/conversation-bound hooks, and composer.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agy-lib.sh
. "$ROOT/bin/fm-agy-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

mkdir -p "$TMP_ROOT/named"
for name in agy agyd; do ln -s /bin/bash "$TMP_ROOT/named/$name"; done
for name in agy agyd; do
  # shellcheck disable=SC2016
  out=$(env -u PI_CODING_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI \
    CLAUDECODE=1 FM_AGY_HARNESS=agy "$TMP_ROOT/named/$name" -c '"$1"; :' _ "$ROOT/bin/fm-harness.sh")
  if [ "$name" = agy ]; then
    [ "$out" = agy ] || fail "real agy ancestry and marker must win: $out"
  else
    [ "$out" = claude ] || fail "a leaked marker cannot claim unrelated agyd: $out"
  fi
done
# shellcheck disable=SC2016
out=$(env -u PI_CODING_AGENT -u CLAUDECODE -u GEMINI_CLI -u GROK_AGENT \
  -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI \
  -u FM_AGY_HARNESS "$TMP_ROOT/named/agy" -c '"$1"; :' _ "$ROOT/bin/fm-harness.sh")
[ "$out" = agy ] || fail "agy ancestry must survive loss of its launch marker"
pass 'AGY exact process ancestry and marker diverge safely'

fm_control_harness_supports_kind agy ship || fail ship
fm_control_harness_supports_kind agy scout || fail scout
! fm_control_harness_supports_kind agy secondmate || fail secondmate
! fm_control_harness_supports_kind agy primary || fail primary
[ "$(fm_control_interrupt_key agy)" = Escape ] || fail interrupt
[ "$(fm_control_interrupt_repeat agy)" = 1 ] || fail repeat
[ "$(fm_control_exit_command agy)" = /exit ] || fail exit
[ "$(fm_control_interrupt_ack_source agy)" = none ] || fail 'do not fabricate cancellation proof'
! "$ROOT/bin/fm-supervision-instructions.sh" --harness agy >/dev/null 2>&1 || fail 'primary protocol must refuse AGY'
fm_agy_backend_check tmux || fail tmux
fm_agy_backend_check herdr || fail herdr
for backend in zellij orca cmux codex-app unknown; do
  ! fm_agy_backend_check "$backend" 2>/dev/null || fail "unverified AGY backend accepted: $backend"
done
pass 'AGY control supports only ordinary workers'

case_dir="$TMP_ROOT/spawn"
home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --help) printf '%s\n' '  --new-project  Create project' '  --add-dir  Add workspace' '  --prompt-interactive  Prompt' '  --model  Model' '  --effort  Effort' '  --dangerously-skip-permissions  Approve' ;;
  models) printf 'gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\n' ;;
  *) printf '%s\0' "$@" > "$FM_AGY_ARGV_LOG" ;;
esac
SH
chmod +x "$fakebin/agy"
fm_agy_preflight "$fakebin/agy" gemini-3.8-flash-low low || fail preflight
! fm_agy_preflight "$fakebin/agy" gemini-unknown low 2>/dev/null || fail 'absent model accepted'
! fm_agy_preflight "$fakebin/agy" default low 2>/dev/null || fail 'unpinned model accepted'
! fm_agy_preflight "$fakebin/agy" gemini-3.8-flash-low high 2>/dev/null || fail 'effort silently switched model'
fm_test_spawn_home "$home" agy
fm_git_worktree "$proj" "$wt" agy-test
fm_test_spawn_brief "$home" agy-test
out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" fm_test_run_spawn "$home" "$wt" "$fakebin" agy-test "$proj" --scout --harness agy --model gemini-3.8-flash-low --effort low)
expect_code 0 "$?" "AGY spawn: $out"
launch=$(<"$case_dir/launch.log")
assert_contains "$launch" "--new-project --add-dir '$wt'" 'AGY tool workspace must be bound, not shared scratch'
assert_contains "$launch" "--add-dir '$home/state/agy-test.agy-hook'" 'missing isolated hook workspace'
assert_contains "$launch" "--model 'gemini-3.8-flash-low' --effort 'low'" 'model and effort flags'
assert_contains "$launch" 'AGY_CLI_DISABLE_AUTO_UPDATE=true' 'AGY must not self-update workers'
assert_contains "$launch" '--prompt-interactive "$(' 'prompt must be one quoted argument'
assert_contains "$launch" 'encode launch-brief' 'typed envelope lost'
FM_AGY_ARGV_LOG="$case_dir/argv" bash -c "$launch" || fail 'emitted launch command did not execute'
python3 - "$case_dir/argv" "$wt" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().decode().split('\0')[:-1]
assert args[args.index('--add-dir') + 1] == sys.argv[2], args
index = args.index('--prompt-interactive')
assert index == len(args) - 2, 'the complete instruction envelope must be one final argument'
assert 'FIRSTMATE_OP:' in args[index + 1], 'routing marker missing from prompt argument'
assert 'Captain' in args[index + 1], 'brief contents missing from prompt argument'
PY
expect_code 0 "$?" 'AGY argv boundary must survive shell expansion'
pass 'AGY spawn pins project, hooks, prompt boundary and model without global configuration edits'

state="$home/state"
gen=$(fm_busy_current_gen "$state" agy-test)
hooks="$state/agy-test.agy-hook/.agents/hooks.json"
pre=$(jq -r '."firstmate-worker".PreInvocation[0].command' "$hooks")
stop=$(jq -r '."firstmate-worker".Stop[0].command' "$hooks")
payload=$(jq -nc --arg wt "$wt" '{conversationId:"main-1",workspacePaths:[$wt],fullyIdle:true}')
printf '%s' "$payload" | bash -c "$pre" >/dev/null
[ "$(fm_busy_record_read "$state" agy-test | cut -d' ' -f1-2)" = 'busy agy-hook' ] || fail 'PreInvocation not busy'
for value in false '"true"' null; do
  printf '%s' "$payload" | jq --argjson value "$value" '.fullyIdle=$value' | bash -c "$stop" >/dev/null
  [ ! -e "$state/agy-test.turn-ended" ] || fail 'only boolean true with no background work may close turn'
done
printf '%s' "$payload" | jq '.conversationId="child-1"' | bash -c "$stop" >/dev/null
[ ! -e "$state/agy-test.turn-ended" ] || fail 'subagent must not close parent'
printf '%s' "$payload" | jq '.workspacePaths=["/unrelated"]' | bash -c "$stop" >/dev/null
[ ! -e "$state/agy-test.turn-ended" ] || fail 'other workspace must not close parent'
printf '%s' "$payload" | bash -c "$stop" >/dev/null
[ "$(fm_busy_record_read "$state" agy-test | cut -d' ' -f1-2)" = 'idle agy-hook' ] || fail 'Stop not idle'
[ -f "$state/agy-test.turn-ended" ] || fail 'missing completion notification'
new_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" agy-test)
[ "$new_gen" != "$gen" ] || fail 'generation did not change'
rm "$state/agy-test.turn-ended"
printf '%s' "$payload" | bash -c "$stop" >/dev/null
[ ! -e "$state/agy-test.turn-ended" ] || fail 'stale Stop emitted completion'
[ "$(fm_busy_record_read "$state" agy-test | cut -d' ' -f1-2)" = 'busy fm-spawn' ] || fail 'stale hook overwrote new turn'
# Keep the retired binding deliberately: an in-flight old hook may finish
# after cleanup. Its generation-specific file must not poison the replacement.
printf '%s' "$payload" | jq '.conversationId="replacement-1"' | \
  "$ROOT/bin/fm-agy-hook.sh" PreInvocation "$state" agy-test "$new_gen" "$wt" >/dev/null
[ "$(fm_busy_record_read "$state" agy-test | cut -d' ' -f1-2)" = 'busy agy-hook' ] || fail 'old conversation binding poisoned replacement'
paths=$(fm_control_harness_wiring_paths agy "$wt" "$state" agy-test)
assert_contains "$paths" "$state/agy-test.agy-hook/$gen.conversation" 'retired binding cleanup missing'
assert_contains "$paths" "$state/agy-test.agy-hook/$new_gen.conversation" 'current binding cleanup missing'
pass 'AGY hook closes only the exact generation, workspace and parent conversation with fullyIdle true'

screen=$(printf '──────────────\n> \n──────────────\n? for shortcuts Gemini 3.8 Flash · low\n')
caps=$(printf 'styled=0\ncursor=1\nidentity=1\n')
[ "$(fm_composer_classify_screen "$caps" "$screen" 1 $'agy\tidle')" = empty ] || fail 'AGY empty composer'
[ "$(fm_composer_classify_screen "$caps" "$screen" 1 probe-absent)" = unknown ] || fail 'stale shell must not be empty'
[ "$(fm_composer_classify_screen "$caps" "$screen" 1 $'agy\tworking')" = unknown ] || fail 'busy cannot prove safe empty composer'
screen=$(printf '──────────────\n> pending instruction\n──────────────\n? for shortcuts\n')
[ "$(fm_composer_classify_screen "$caps" "$screen" 1 $'agy\tidle')" = pending ] || fail 'AGY pending composer'
pass 'AGY separator composer requires live identity; pending text and dead shells remain protected'
