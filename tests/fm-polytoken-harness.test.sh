#!/usr/bin/env bash
# Portable Polytoken worker adapter regression. Vendor facts are refreshed by
# fm-polytoken-signals-live-e2e.test.sh; this suite needs no Polytoken install
# and replays the real 0.8.14 frames in tests/captures/polytoken-0.8.14/.
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
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-polytoken-lib.sh
. "$ROOT/bin/fm-polytoken-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-polytoken-harness)
HARNESS="$ROOT/bin/fm-harness.sh"
CAPTURES="$ROOT/tests/captures/polytoken-0.8.14"
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI

mkdir -p "$TMP_ROOT/names"
for name in polytoken polytoken-helper; do ln -s /bin/bash "$TMP_ROOT/names/$name"; done
# shellcheck disable=SC2016
out=$(CLAUDECODE=1 "$TMP_ROOT/names/polytoken" -c '"$1"; :' _ "$HARNESS")
[ "$out" = polytoken ] || fail "a polytoken ancestor must beat a foreign CLAUDECODE: $out"
# shellcheck disable=SC2016
# The helper's own name must never claim the adapter BY NAME. A full ancestry
# walk is the wrong vantage here: under a genuine Polytoken primary it
# legitimately finds that real daemon, so ask the helper process itself.
out=$("$TMP_ROOT/names/polytoken-helper" -c '. "$1" >/dev/null 2>&1; harness_process_verdict "$$"; :' _ "$HARNESS")
[ -z "$out" ] || fail "unrelated polytoken-helper claimed the adapter by name: $out"
[ "$(fm_agent_process_classify_name /opt/bin/polytoken)" = agent ] || fail "liveness lost the Polytoken TUI"
[ "$(fm_agent_process_classify_name polytoken-helper)" = other ] || fail "liveness claims an unrelated executable"
pass "Polytoken native ancestry identity; anchored liveness"

[ "$(fm_control_interrupt_key polytoken)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat polytoken)" = 1 ] || fail 'Polytoken cancels on one Escape; a second opens its rewind picker'
[ -z "$(fm_control_interrupt_clear_key polytoken)" ] || fail 'Polytoken restores no cancelled prompt to clear'
[ "$(fm_control_exit_command polytoken)" = /quit ] || fail 'wrong exit command'
fm_control_interrupt_invalidates_busy polytoken || fail 'a Polytoken interrupt must invalidate busy state'
fm_control_harness_supports_kind polytoken ship || fail 'ship refused'
fm_control_harness_supports_kind polytoken scout || fail 'scout refused'
! fm_control_harness_supports_kind polytoken secondmate || fail 'secondmate accepted'
[ "$(fm_control_harness_family polytoken)" = polytoken ] || fail 'recorded harness did not resolve'
! fm_control_harness_family polytoken-helper >/dev/null || fail 'an unrelated name joined the family'
hazard=$(fm_control_interrupt_hazard_signal polytoken)
plain() { fm_composer_strip_ansi < "$CAPTURES/$1"; }
plain rewind-picker.ansi | grep -Eq -- "$hazard" || fail 'the real rewind picker is not recognized'
for frame in idle primed busy cancelled draft; do
  ! plain "$frame.ansi" | grep -Eq -- "$hazard" || fail "the $frame frame was read as the rewind picker"
done
pass "worker-only lifecycle capabilities; the rewind picker and nothing else is the hazard"

caps=$(printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n')
verdict() { fm_composer_classify_screen "$caps" "$(cat "$CAPTURES/$1")" 27 "${2-}"; }
[ "$(verdict idle.ansi)" = need-identity ] || fail 'an unidentified separated composer must ask for identity'
[ "$(verdict idle.ansi "$(printf 'polytoken\tidle')")" = empty ] || fail 'an idle Polytoken composer did not read empty'
[ "$(verdict cancelled.ansi "$(printf 'polytoken\tidle')")" = empty ] || fail 'a cancelled turn left no empty composer'
[ "$(verdict draft.ansi "$(printf 'polytoken\tidle')")" = pending ] || fail 'a two-row draft was not preserved as pending'
[ "$(verdict busy.ansi "$(printf 'polytoken\tworking')")" = unknown ] || fail 'a working Polytoken composer must not read empty'
[ "$(verdict idle.ansi probe-absent)" = unknown ] || fail 'a pane with no live Polytoken must not read empty'
[ "$(verdict idle.ansi "$(printf 'claude\tidle')")" = unknown ] || fail 'another harness identity proved a Polytoken composer'
pass "separated composer is proven only by a Polytoken identity; drafts stay pending"

plain busy.ansi | fm_busy_lines_match polytoken || fail 'the Running for row was not a delivery signal'
plain busy.ansi | fm_busy_lines_match '' || fail 'the harness-less union lost the Running for row'
for frame in idle cancelled primed draft; do
  ! plain "$frame.ansi" | fm_busy_lines_match polytoken || fail "the finished $frame frame read busy"
done
! printf 'the log says Running for 3s\n' | fm_busy_lines_match polytoken || fail 'a mid-line quotation read busy'
! printf 'esc to cancel\n' | fm_busy_lines_match polytoken || fail 'borrowed another harness signal'
pass "delivery busy signal is the anchored Running for row only"

state="$TMP_ROOT/hook state"
wt="$TMP_ROOT/overlay-wt"
fm_git_init_commit "$wt"
mkdir -p "$state"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker)
fm_polytoken_write_overlay "$wt" "$state" worker "$gen" "$state/worker.turn-ended" "$ROOT" || fail 'overlay writer failed'
jq -e 'length == 2 and ([.[].event] | sort) == ["pre_user_prompt", "stop"]' "$wt/.polytoken/hooks.json" >/dev/null \
  || fail 'hooks.json does not carry exactly the open and close hooks'
config_body=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$wt/.polytoken/config.yaml")
[ "$(printf '%s\n' "$config_body" | wc -l | tr -d ' ')" = 1 ] || fail 'config.yaml must hold exactly one setting'
[ "${config_body%%:*}" = default_permission_matcher ] || fail 'config.yaml sets a key other than default_permission_matcher'
config_value=${config_body#*:}
config_value=${config_value#"${config_value%%[![:space:]]*}"}
[ "$config_value" = bypass ] || fail 'worker would stop on approvals'
run_hook() {  # <event> -> runs its handler as Polytoken does, and fails on any stdout
  local cmd hook_out
  cmd=$(jq -r --arg e "$1" '.[] | select(.event == $e) | .handler.bash' "$wt/.polytoken/hooks.json")
  hook_out=$(printf '{"event":"%s"}' "$1" | bash -c "$cmd") || fail "$1 handler exited nonzero"
  [ -z "$hook_out" ] || fail "$1 handler printed '$hook_out', which Polytoken reads as its decision"
}
run_hook pre_user_prompt
[ "$(fm_busy_classify tmux fake:w polytoken worker "$state")" = 'busy polytoken-hook' ] || fail 'pre_user_prompt did not open busy'
run_hook stop
[ "$(fm_busy_classify tmux fake:w polytoken worker "$state")" = 'idle polytoken-hook' ] || fail 'stop did not settle'
assert_present "$state/worker.turn-ended" 'stop notification absent'
run_hook pre_user_prompt
run_hook pre_user_prompt
[ "$(fm_busy_classify tmux fake:w polytoken worker "$state")" = 'busy polytoken-hook' ] || fail 'a queued follow-up prompt broke the open turn'
"$ROOT/bin/fm-busy-event.sh" arm "$state" worker >/dev/null
rm "$state/worker.turn-ended"
run_hook stop
[ "$(fm_busy_classify tmux fake:w polytoken worker "$state")" = 'busy fm-spawn' ] || fail 'a stale stop cleared the replacement'
assert_absent "$state/worker.turn-ended" 'a stale stop woke the replacement'
[ "$(fm_busy_classify tmux fake:w polytoken worker "$state" "$(plain license.ansi)")" = 'unknown launch-prompt' ] \
  || fail 'a launch parked on the license gate read busy'
[ "$(fm_busy_classify tmux fake:w polytoken worker "$state" "$(printf 'I read the License Agreement section.\n')")" = 'busy fm-spawn' ] \
  || fail 'prose naming the license gate read as the gate'
pass "hook overlay opens and closes turns silently; stale generations and the license gate never read idle or busy"

fm_polytoken_write_overlay "$wt" "$state" worker "$gen" "$state/worker.turn-ended" "$ROOT" || fail 'an owned overlay was not replaced'
printf '[{"name":"project-hook","event":"stop","handler":{"bash":"true"}}]\n' > "$wt/.polytoken/hooks.json"
! fm_polytoken_write_overlay "$wt" "$state" worker "$gen" "$state/worker.turn-ended" "$ROOT" 2>/dev/null \
  || fail "the project's own hooks.json was overwritten"
fm_polytoken_remove_overlay "$wt"
assert_present "$wt/.polytoken/hooks.json" "cleanup deleted the project's own hooks.json"
assert_absent "$wt/.polytoken/config.yaml" 'cleanup left the owned config.yaml'
rm "$wt/.polytoken/hooks.json"
printf 'models: {}\n' > "$wt/.polytoken/config.toml"
! fm_polytoken_write_overlay "$wt" "$state" worker "$gen" "$state/worker.turn-ended" "$ROOT" 2>/dev/null \
  || fail 'a second config file was added beside config.toml'
rm "$wt/.polytoken/config.toml"
mkdir -p "$wt/.polytoken"
printf '[]\n' > "$wt/.polytoken/hooks.json"
git -C "$wt" add .polytoken/hooks.json
git -C "$wt" -c user.email=t@t -c user.name=t commit -qm 'project hooks'
rm "$wt/.polytoken/hooks.json"
! fm_polytoken_write_overlay "$wt" "$state" worker "$gen" "$state/worker.turn-ended" "$ROOT" 2>/dev/null \
  || fail 'a tracked hooks.json path was written'
pass "overlay replaces only its own files and refuses project-owned or tracked configuration"

fakebin="$TMP_ROOT/poly-fake"
mkdir -p "$fakebin"
cat > "$fakebin/polytoken" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-} ${3:-}" in
  'models --format json')
    [ -z "${FM_FAKE_POLYTOKEN_MODELS_FAIL:-}" ] || exit 3
    cat "$FM_FAKE_POLYTOKEN_CATALOG"
    ;;
  'sessions --format json')
    [ -z "${FM_FAKE_POLYTOKEN_SESSIONS_FAIL:-}" ] || exit 3
    if [ -s "${FM_FAKE_POLYTOKEN_SESSIONS:-}" ]; then cat "$FM_FAKE_POLYTOKEN_SESSIONS"; else printf '[]\n'; fi
    ;;
esac
exit 0
SH
chmod +x "$fakebin/polytoken"
catalog="$TMP_ROOT/catalog.json"
cat > "$catalog" <<'JSON'
{"default_model":"codex/gpt-6-luna","models":[
 {"name":"codex/gpt-6-luna","reasoning":{"type":"effort","levels":["low","medium","high","xhigh","max"],"default_level":"high"},
  "selectable":["codex/gpt-6-luna","codex/gpt-6-luna(none)","codex/gpt-6-luna(low)","codex/gpt-6-luna(medium)","codex/gpt-6-luna(high)","codex/gpt-6-luna(xhigh)","codex/gpt-6-luna(max)"]},
 {"name":"ogo/glm-5.3","reasoning":{"type":"effort","levels":["low","high","max"],"default_level":"high"},
  "selectable":["ogo/glm-5.3","ogo/glm-5.3(none)","ogo/glm-5.3(low)","ogo/glm-5.3(high)","ogo/glm-5.3(max)"]},
 {"name":"minimax/MiniMax-M3","reasoning":{"type":"thinking","can_disable":true},
  "selectable":["minimax/MiniMax-M3","minimax/MiniMax-M3(t)","minimax/MiniMax-M3(none)"]}]}
JSON
export FM_FAKE_POLYTOKEN_CATALOG=$catalog
pbin="$fakebin/polytoken"
resolve() { fm_polytoken_model_arg "$pbin" "$1" "$2" 2>"$TMP_ROOT/resolve.err"; }
[ "$(resolve codex/gpt-6-luna high)" = 'codex/gpt-6-luna(high)' ] || fail 'a listed effort did not become the variant'
[ "$(resolve '' low)" = 'codex/gpt-6-luna(low)' ] || fail 'effort alone did not apply to the default model'
[ "$(resolve ogo/glm-5.3 xhigh)" = ogo/glm-5.3 ] || fail 'an unlisted level reached argv'
assert_grep 'recorded but not applied' "$TMP_ROOT/resolve.err" 'omitted effort was silent'
[ "$(resolve minimax/MiniMax-M3 high)" = minimax/MiniMax-M3 ] || fail 'a thinking-only model received an effort variant'
[ "$(resolve 'codex/gpt-6-luna(low)' high)" = 'codex/gpt-6-luna(low)' ] || fail 'an explicit variant was replaced'
! resolve 'mg:polytoken:plan' '' >/dev/null || fail 'an unlisted model group was accepted'
[ -z "$(resolve '' '')" ] || fail 'no axes must keep the configured default'
! resolve gpt-6-luna '' >/dev/null || fail 'an unqualified model name was accepted'
! resolve 'codex/gpt-6-luna(bogus)' '' >/dev/null || fail 'an unlisted variant was accepted'
! resolve nonexistent/model high >/dev/null || fail 'an unlisted model was accepted'
[ "$(FM_FAKE_POLYTOKEN_MODELS_FAIL=1 resolve codex/gpt-6-luna high)" = codex/gpt-6-luna ] \
  || fail 'an unreadable listing must pass the model unvalidated and omit effort'
assert_grep 'without model validation' "$TMP_ROOT/resolve.err" 'unvalidated launch was silent'
pass "model and effort resolve against the listing; unlisted values refuse before launch"

anchor="$TMP_ROOT/anchored"
mkdir -p "$anchor"
anchor_phys=$(cd "$anchor" && pwd -P)
jq -n --arg p "$anchor_phys" '[{session_id:"0c0abc-test",pid:4242,project_path:$p},{session_id:"0c0def-other",pid:4343,project_path:"/elsewhere"}]' \
  > "$TMP_ROOT/sessions.json"
FM_FAKE_POLYTOKEN_SESSIONS="$TMP_ROOT/sessions.json" fm_polytoken_live_sessions "$pbin" "$anchor" > "$TMP_ROOT/live" \
  || fail 'the live listing could not be read'
[ "$(cat "$TMP_ROOT/live")" = '0c0abc-test 4242' ] || fail "the anchored session was not isolated: $(cat "$TMP_ROOT/live")"
if FM_FAKE_POLYTOKEN_SESSIONS="$TMP_ROOT/sessions.json" fm_polytoken_wait_no_live_session "$pbin" "$anchor" 0 2>"$TMP_ROOT/guard.err"; then
  fail 'a live daemon anchored at the worktree did not refuse the launch'
fi
assert_grep '0c0abc-test' "$TMP_ROOT/guard.err" 'the refusal did not name the live session'
fm_polytoken_wait_no_live_session "$pbin" "$TMP_ROOT/names" 0 || fail 'an unanchored directory was refused'
! FM_FAKE_POLYTOKEN_SESSIONS_FAIL=1 fm_polytoken_wait_no_live_session "$pbin" "$anchor" 0 2>/dev/null \
  || fail 'an unreadable listing proved the worktree agent-free'
pass "a detached daemon anchored at the worktree, or an unreadable listing, refuses another agent"

case_dir="$TMP_ROOT/spawn"
spawn_fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
cp "$pbin" "$spawn_fakebin/polytoken"
home="$case_dir/home"
proj="$case_dir/project"
swt="$case_dir/wt"
fm_test_spawn_home "$home" polytoken
fm_git_worktree "$proj" "$swt" polytoken-test
fm_test_spawn_brief "$home" polytoken-worker
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch" fm_test_run_spawn "$home" "$swt" "$spawn_fakebin" polytoken-worker "$proj" --scout --harness polytoken --model codex/gpt-6-luna --effort high 2>&1)
then fail "spawn failed: $out"; fi
launch=$(cat "$case_dir/launch")
assert_contains "$launch" "polytoken' new --model 'codex/gpt-6-luna(high)' --prompt" 'model variant or new --prompt shape lost'
assert_contains "$launch" 'POLYTOKEN_SKIP_UPDATE_CHECK=1' 'the launch could park on the update prompt'
assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
assert_contains "$launch" '-u CLAUDECODE' 'foreign markers reached the worker'
assert_grep 'effort=high' "$home/state/polytoken-worker.meta" 'effort not recorded'
assert_grep 'harness=polytoken' "$home/state/polytoken-worker.meta" 'harness not recorded'
assert_present "$swt/.polytoken/hooks.json" 'spawn did not wire hooks'
assert_present "$swt/.polytoken/config.yaml" 'spawn did not wire bypass permissions'
[ -z "$(git -C "$swt" status --porcelain)" ] || fail "the overlay is visible to git: $(git -C "$swt" status --porcelain)"
[ "$(fm_busy_classify tmux fake:w polytoken polytoken-worker "$home/state")" = 'busy fm-spawn' ] || fail 'launch not armed'
if out=$(fm_test_run_spawn "$home" "$swt" "$spawn_fakebin" polytoken-sm "$proj" --secondmate --harness polytoken 2>&1)
then fail 'Polytoken secondmate launch accepted'; fi
assert_contains "$out" 'crewmate/scout adapter only' 'wrong secondmate refusal'
if out=$(fm_test_run_spawn "$home" "$swt" "$spawn_fakebin" polytoken-bad "$proj" --scout --harness polytoken --model gpt-6-luna 2>&1)
then fail 'an unlisted model launched'; fi
assert_contains "$out" "is not listed by 'polytoken models'" 'wrong model refusal'
pass "scout launch carries the model variant, typed brief, hidden overlay, and armed hooks; secondmate and bad models refuse"

case_dir="$TMP_ROOT/spawn-live"
spawn_fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
cp "$pbin" "$spawn_fakebin/polytoken"
home="$case_dir/home"
proj="$case_dir/project"
swt="$case_dir/wt"
fm_test_spawn_home "$home" polytoken
fm_git_worktree "$proj" "$swt" polytoken-live-test
fm_test_spawn_brief "$home" polytoken-guarded
swt_phys=$(cd "$swt" && pwd -P)
jq -n --arg p "$swt_phys" '[{session_id:"0c0live-left",pid:5151,project_path:$p}]' > "$case_dir/sessions.json"
if out=$(FM_POLYTOKEN_SESSION_DRAIN_WAIT=0 FM_FAKE_POLYTOKEN_SESSIONS="$case_dir/sessions.json" FM_FAKE_LAUNCH_LOG="$case_dir/launch" \
    fm_test_run_spawn "$home" "$swt" "$spawn_fakebin" polytoken-guarded "$proj" --scout --harness polytoken 2>&1)
then fail 'a launch beside a live detached daemon was accepted'; fi
assert_contains "$out" '0c0live-left' 'the refusal did not name the live session'
[ ! -s "$case_dir/launch" ] || fail "the refused spawn still launched: $(cat "$case_dir/launch")"
pass "spawn refuses a worktree a live Polytoken daemon is still anchored at"
