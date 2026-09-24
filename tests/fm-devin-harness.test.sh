#!/usr/bin/env bash
# Portable Devin worker adapter regression. Vendor facts are refreshed by
# fm-devin-signals-live-e2e.test.sh; this suite needs no Devin credentials.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-devin-harness)
HARNESS="$ROOT/bin/fm-harness.sh"
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI

mkdir -p "$TMP_ROOT/names"
for name in devin devin-helper; do ln -s /bin/bash "$TMP_ROOT/names/$name"; done
# shellcheck disable=SC2016
out=$(CLAUDECODE=1 "$TMP_ROOT/names/devin" -c '"$1"; :' _ "$HARNESS")
[ "$out" = devin ] || fail "native Devin ancestry must beat foreign CLAUDECODE: $out"
# The negative ancestry probe must run under a fabricated process table: the
# verdict is the NEAREST harness ancestor, so a suite executed inside a real
# Devin session sees the true devin.exe ancestor and this case can never be
# negative. The fake ps dies on -o exactly like Git Bash/MSYS and answers
# `ps -l` with a fixed WINPID; the fake powershell prints a table whose chain
# is devin-helper.exe -> bash.exe -> explorer.exe, with no devin row - so the
# verdict can only come from the helper's own name, which is what this case
# isolates.
fakebin=$(fm_fakebin "$TMP_ROOT/devin-helper-bin")
cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  -l|-l\ -p\ *)
    printf '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND\n'
    printf '   %s       1    %s    %s  ?         1000 00:00:00 bash\n' "${FM_TEST_CYGPID:?}" "${FM_TEST_CYGPID:?}" "${FM_TEST_OWN_WINPID:?}"
    ;;
  *) echo "ps: unknown option" >&2; exit 1 ;;
esac
SH
cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_WIN32_TABLE"
SH
chmod +x "$fakebin/ps" "$fakebin/powershell.exe"
win32_table=$(printf '%s\t%s\t%s\t%s\t%s\n' \
  500 600 devin-helper.exe 'C:\Tmp\devin-helper.exe' 'devin-helper.exe -c x' \
  600 700 bash.exe 'C:\Program Files\Git\bin\bash.exe' 'bash.exe' \
  700 0 explorer.exe 'C:\Windows\explorer.exe' explorer.exe)
# shellcheck disable=SC2016
out=$(FM_TEST_OWN_WINPID=500 FM_TEST_WIN32_TABLE="$win32_table" PATH="$fakebin:$PATH" \
  "$TMP_ROOT/names/devin-helper" -c 'export FM_TEST_CYGPID=$$; "$1" ancestry "$$"; :' _ "$HARNESS")
[ "$out" != 'comm devin' ] || fail "unrelated devin-helper claimed the adapter"
[ "$(fm_agent_process_classify_name /opt/bin/devin)" = agent ] || fail "liveness lost Devin"
[ "$(fm_agent_process_classify_name devin-helper)" = other ] || fail "liveness claims unrelated executable"
pass "Devin native identity; anchored liveness"

[ "$(fm_control_interrupt_key devin)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat devin)" = 2 ] || fail 'Devin needs double Escape'
[ -z "$(fm_control_interrupt_clear_key devin)" ] || fail 'Devin must not erase a composer draft'
[ "$(fm_control_exit_command devin)" = /quit ] || fail 'wrong exit command'
fm_control_harness_supports_kind devin ship || fail 'ship refused'
fm_control_harness_supports_kind devin scout || fail 'scout refused'
! fm_control_harness_supports_kind devin secondmate || fail 'secondmate accepted'
pass "worker-only resolution and lifecycle capabilities"

[ "$(fm_composer_classify_content 1 '❭ Ask Devin to build features, fix bugs, or work on your code' "$FM_COMPOSER_IDLE_RE_DEFAULT" sensitive '' 1 0)" = empty ] || fail 'idle placeholder not empty'
[ "$(fm_composer_classify_content 1 '❭ unsubmitted draft')" = pending ] || fail 'typed draft not preserved'
[ "$(fm_composer_classify_content 0 '❭')" = empty ] || fail 'Devin glyph not recognized'
for signal in 'Thinking · 5s (esc twice to interrupt)' '❭ Guide Devin while it works'; do
  printf '%s\n' "$signal" | fm_busy_lines_match devin || fail "independent delivery signal lost: $signal"
done
! printf '❭ unsubmitted draft\n' | fm_busy_lines_match devin || fail 'draft read busy'
! printf 'esc to cancel\n' | fm_busy_lines_match devin || fail 'borrowed another harness signal'
pass "composer draft safety and independent delivery signals"

state="$TMP_ROOT/hook state"
mkdir -p "$state"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker)
printf '%s\n' '{"agent":{"model":"swe-2-high"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}' > "$TMP_ROOT/user.json"
"$ROOT/bin/fm-devin-config.sh" "$state" worker "$gen" "$TMP_ROOT/user.json" || fail 'config writer failed'
config="$state/worker.devin-config.json"
jq -e '.agent.model == "swe-2-high" and (.hooks.Stop | length) == 2' "$config" >/dev/null || fail 'user settings/hooks lost'
run_hook() { bash -c "$(jq -r --arg event "$1" '.hooks[$event][-1].hooks[0].command' "$config")"; }
run_hook UserPromptSubmit
[ "$(fm_busy_classify tmux fake:w devin worker "$state")" = 'busy devin-hook' ] || fail 'submit did not open busy'
run_hook Stop
[ "$(fm_busy_classify tmux fake:w devin worker "$state")" = 'idle devin-hook' ] || fail 'Stop did not settle'
assert_present "$state/worker.turn-ended" 'Stop notification absent'
run_hook UserPromptSubmit
run_hook SessionEnd
[ "$(fm_busy_classify tmux fake:w devin worker "$state")" = 'idle devin-hook' ] || fail 'SessionEnd did not settle'
"$ROOT/bin/fm-busy-event.sh" arm "$state" worker >/dev/null
rm "$state/worker.turn-ended"
run_hook Stop
[ "$(fm_busy_classify tmux fake:w devin worker "$state")" = 'busy fm-spawn' ] || fail 'stale Stop cleared replacement'
assert_absent "$state/worker.turn-ended" 'stale Stop woke replacement'
[ "$(fm_control_harness_wiring_paths devin /unused "$state" worker)" = "$config" ] || fail 'config retirement missing'
printf 'broken' > "$TMP_ROOT/invalid.json"
! "$ROOT/bin/fm-devin-config.sh" "$state" worker "$gen" "$TMP_ROOT/invalid.json" 2>/dev/null || fail 'invalid source accepted'
jq -e . "$config" >/dev/null || fail 'failed write replaced valid config'
pass "private config preserves user hooks; lifecycle and stale-generation rejection"

# A user config that opts into both must still produce a worker config with no
# commit attribution and no imported Claude Code hooks; other import choices
# the user made survive.
printf '%s\n' '{"attribution":true,"read_config_from":{"claude":true,"cursor":false}}' > "$TMP_ROOT/opted-in.json"
"$ROOT/bin/fm-devin-config.sh" "$state" worker "$gen" "$TMP_ROOT/opted-in.json" || fail 'config writer failed'
jq -e '.attribution == false' "$config" >/dev/null \
  || fail 'worker config keeps Devin commit attribution (Co-Authored-By: Devin trailer)'
jq -e '.read_config_from.claude == false and .read_config_from.cursor == false' "$config" >/dev/null \
  || fail 'worker config imports Claude Code hooks or dropped a user import choice'
"$ROOT/bin/fm-devin-config.sh" "$state" worker "$gen" /nonexistent/config.json || fail 'absent source refused'
jq -e '.attribution == false and .read_config_from.claude == false' "$config" >/dev/null \
  || fail 'an absent user config must still disable attribution and Claude hook import'
pass "worker config forces attribution off and Claude Code hook import off"

case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
fm_fake_exit0 "$fakebin" devin
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home" devin
fm_git_worktree "$proj" "$wt" devin-test
fm_test_spawn_brief "$home" devin-worker
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch" fm_test_run_spawn "$home" "$wt" "$fakebin" devin-worker "$proj" --scout --harness devin --model fusion-claude-fable-5-1-high-sidekick-swe-2-medium --effort xhigh 2>&1)
then fail "spawn failed: $out"; fi
launch=$(cat "$case_dir/launch")
assert_contains "$launch" '--permission-mode dangerous --respect-workspace-trust false' 'autonomy/trust flags missing'
assert_contains "$launch" "--config '$home/state/devin-worker.devin-config.json'" 'private config missing'
assert_contains "$launch" "--model 'fusion-claude-fable-5-1-high-sidekick-swe-2-medium'" 'Fusion model lost'
assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
case "$launch" in *--effort*|*--thinking*) fail 'independent effort reached Devin argv' ;; esac
assert_grep 'effort=xhigh' "$home/state/devin-worker.meta" 'effort not recorded'
assert_present "$home/state/devin-worker.devin-config.json" 'spawn did not wire hooks'
[ "$(fm_busy_classify tmux fake:w devin devin-worker "$home/state")" = 'busy fm-spawn' ] || fail 'launch not armed'
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" devin-sm "$proj" --secondmate --harness devin 2>&1)
then fail 'Devin secondmate launch accepted'; fi
assert_contains "$out" 'crewmate/scout adapter only' 'wrong secondmate refusal'
pass "scout launch carries Fusion, autonomy, typed brief and hooks; effort recorded only"
