#!/usr/bin/env bash
# Portable GitHub Copilot CLI worker adapter regression. Vendor facts are
# recorded in docs/verification/copilot.md; this suite needs no GitHub account.
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
TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)
HARNESS="$ROOT/bin/fm-harness.sh"
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI HERDR_ENV HERDR_PANE_ID HERDR_BIN_PATH

# Copilot's kernel process name is its thread name `MainThread`; only argv[0]
# says `copilot`. `exec -a` reproduces that split: comm stays bash, argv[0] is
# the name under test.
# shellcheck disable=SC2016
out=$(CLAUDECODE=1 bash -c 'exec -a copilot bash -c '"'"'"$1"; :'"'"' _ "$1"' _ "$HARNESS")
[ "$out" = copilot ] || fail "native Copilot ancestry must beat foreign CLAUDECODE: $out"
# shellcheck disable=SC2016
out=$(bash -c 'exec -a /home/u/.local/bin/copilot bash -c '"'"'"$1"; :'"'"' _ "$1"' _ "$HARNESS")
[ "$out" = copilot ] || fail "an installed Copilot path must identify the adapter: $out"
# The negative cases must not see a real Copilot higher in the parent chain
# (this suite may itself run inside one). A ps wrapper keeps every real field of
# the process under test but ends the parent walk there.
real_ps=$(command -v ps)
mkdir -p "$TMP_ROOT/stopps"
cat > "$TMP_ROOT/stopps/ps" <<SH
#!/usr/bin/env bash
case "\$*" in *ppid=*) printf '1\n' ;; *) exec "$real_ps" "\$@" ;; esac
SH
chmod +x "$TMP_ROOT/stopps/ps"
# shellcheck disable=SC2016
out=$(PATH="$TMP_ROOT/stopps:$PATH" bash -c 'exec -a copilot-language-server bash -c '"'"'"$1" ancestry "$$"; :'"'"' _ "$1"' _ "$HARNESS")
[ "$out" != 'comm copilot' ] || fail "unrelated copilot-language-server claimed the adapter"
# shellcheck disable=SC2016
out=$(PATH="$TMP_ROOT/stopps:$PATH" bash -c 'exec -a editor bash -c '"'"'"$1" ancestry "$$"; :'"'"' _ "$1" copilot' _ "$HARNESS")
[ "$out" != 'comm copilot' ] || fail "a later argument named copilot claimed the adapter"
# shellcheck disable=SC2016
out=$(PATH="$TMP_ROOT/stopps:$PATH" FM_COPILOT_HARNESS=copilot bash -c '"$1"' _ "$HARNESS")
[ "$out" = copilot ] || fail "the digest's marker must name Copilot when ancestry cannot reach it: $out"
[ "$(fm_agent_process_classify MainThread copilot 'copilot --no-auto-update')" = agent ] || fail "liveness lost Copilot"
[ "$(fm_agent_process_classify MainThread /home/u/.local/bin/copilot 'copilot')" = agent ] || fail "liveness lost an installed Copilot"
# tmux's foreground reading passes an empty path with only argv[0].
[ "$(fm_agent_process_classify_name '' copilot)" = agent ] || fail "tmux path-less reading lost Copilot"
[ "$(fm_agent_process_classify_name '' /home/u/.local/bin/copilot)" = agent ] || fail "tmux path-less installed Copilot lost"
[ "$(fm_agent_process_classify_name '' copilot-language-server)" = other ] || fail "tmux path-less lookalike claimed"
[ "$(fm_agent_process_classify MainThread '' 'copilot')" = other ] || fail "liveness read a nameless MainThread as Copilot"
[ "$(fm_agent_process_classify MainThread copilot-language-server 'copilot-language-server')" = other ] || fail "liveness claims unrelated executable"
pass "Copilot argv[0] identity beats foreign markers; anchored liveness"

[ "$(fm_control_harness_family copilot)" = copilot ] || fail 'copilot family not exact'
! fm_control_harness_family copilot-helper >/dev/null || fail 'copilot-helper resolved into the family'
[ "$(fm_control_interrupt_key copilot)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat copilot)" = 2 ] || fail 'Copilot interrupts on a double Escape'
[ "$(fm_control_interrupt_arm_signal copilot)" = 'again to interrupt' ] || fail 'second Escape must wait for the armed proof'
# The armed footer lives about half a second on a real Herdr pane, so the second
# press must follow the proof almost at once.
awk -v g="$(fm_control_interrupt_press_gap copilot)" 'BEGIN{exit !(g <= 0.1)}' || fail 'Copilot press gap outlives its armed footer'
printf ' ◉ Working · 824 B esc again to interrupt\n' | grep -Eq "$(fm_control_interrupt_arm_signal copilot)" || fail 'real armed footer not recognized'
[ -n "$(fm_control_interrupt_hazard_signal copilot)" ] || fail 'rewind picker hazard missing'
[ -z "$(fm_control_interrupt_clear_key copilot)" ] || fail 'Copilot must not erase a composer draft'
[ "$(fm_control_interrupt_ack_source copilot)" = copilot-transcript-abort ] || fail 'the transcript abort event is the interrupt acknowledgement'
[ "$(fm_control_exit_command copilot)" = /exit ] || fail 'wrong exit command'
fm_control_harness_supports_kind copilot ship || fail 'ship refused'
fm_control_harness_supports_kind copilot scout || fail 'scout refused'
fm_control_harness_supports_kind copilot secondmate || fail 'secondmate refused'
hazard=$(fm_control_interrupt_hazard_signal copilot)
printf ' Rewind to a previous point\n  ↑↓ Navigate · Enter Select · Esc Cancel\n' | grep -Eq "$hazard" || fail 'rewind picker not recognized'
pass "resolution and lifecycle capabilities for every task kind"

# Captured from a copilot 1.0.105 pty session: one `❯` row between two full-width
# rules, a single footer row below, and the same shape while a turn is running.
rule=$(printf '─%.0s' $(seq 1 120))
screen() {  # <composer-rows...>: transcript, rules around the rows, footer
  local rows=("$@")
  printf '%s\n' ' ❯ Reply with the single word PONG                                       22:51' ' ● PONG' '' \
    ' ~/repo [⎇ main] +0 -0                  Plan: 735/7,000 (10% used) · Session: 0.45 AIC used · YOLO' "$rule"
  printf '%s\n' "${rows[@]}"
  printf '%s\n' "$rule" ' ← open sidebar · Interactive · Allow All · / commands · ? help        GPT-6 Luna · Medium · (18%)'
}
caps=$'styled=0\ncursor=0\nidentity=0'
export FM_COMPOSER_HARNESS=copilot
[ "$(fm_composer_classify_screen "$caps" "$(screen '❯')")" = empty ] || fail 'idle composer not empty'
[ "$(fm_composer_classify_screen "$caps" "$(screen '❯ ')")" = empty ] || fail 'idle composer with trailing space not empty'
[ "$(fm_composer_classify_screen "$caps" "$(screen '❯ half typed draft')")" = pending ] || fail 'typed draft not preserved'
[ "$(fm_composer_classify_screen "$caps" "$(screen '❯ first line' '  second line')")" = pending ] || fail 'multi-line draft not preserved'
busy=$(screen '❯' | sed '$d'; printf '%s\n' ' ◎ Working esc esc interrupt                                    GPT-6 Luna · Medium · (18%)')
[ "$(fm_composer_classify_screen "$caps" "$busy")" = empty ] || fail 'composer of a working turn not empty'
picker=$(printf '%s\n' ' Rewind to a previous point' '' '   ❯ Reply with the single word PONG' '' ' ↑↓ Navigate · Enter Select · Esc Cancel')
[ "$(fm_composer_classify_screen "$caps" "$picker")" = unknown ] || fail 'rewind picker read as a composer'
[ "$(fm_composer_classify_screen "$caps" "$(printf '%s\n' 'ordinary shell output' '$ ')")" = unknown ] || fail 'a shell read as a composer'
# Real captures from a live Herdr pane (tests/captures/copilot-1.0.105-herdr):
# the block-glyph box, with no `❯`, that a real pane draws.
cap="$ROOT/tests/captures/copilot-1.0.105-herdr"
for locale_name in C C.UTF-8; do
  [ "$(LC_ALL=$locale_name fm_composer_classify_screen "$caps" "$(cat "$cap/idle.pane")")" = empty ] || fail "real idle composer not empty under LC_ALL=$locale_name"
  [ "$(LC_ALL=$locale_name fm_composer_classify_screen "$caps" "$(cat "$cap/busy-empty.pane")")" = empty ] || fail "real working composer not empty under LC_ALL=$locale_name"
  [ "$(LC_ALL=$locale_name fm_composer_classify_screen "$caps" "$(cat "$cap/busy-draft.pane")")" = pending ] || fail "real draft not preserved under LC_ALL=$locale_name"
done
# Real captures from a live tmux pane (tests/captures/copilot-1.0.105-tmux): the
# plain rule-bounded `❯` composer at 200 columns, with a status row above it.
tcap="$ROOT/tests/captures/copilot-1.0.105-tmux"
for locale_name in C C.UTF-8; do
  for pane in idle busy-empty after-interrupt idle-after-relaunch; do
    [ "$(LC_ALL=$locale_name fm_composer_classify_screen "$caps" "$(cat "$tcap/$pane.pane")")" = empty ] || fail "real tmux $pane composer not empty under LC_ALL=$locale_name"
  done
  [ "$(LC_ALL=$locale_name fm_composer_classify_screen "$caps" "$(cat "$tcap/idle-draft.pane")")" = pending ] || fail "real tmux draft not preserved under LC_ALL=$locale_name"
done
# Real captures from a live tmux pane on Copilot 1.0.109 (tests/captures/copilot-1.0.109-tmux):
# the composer shape is unchanged, the busy footer reads `Working · <n> B ctrl+c interrupt`
# (1.0.105 read `esc esc interrupt`), and both footers must keep reading busy.
ncap="$ROOT/tests/captures/copilot-1.0.109-tmux"
for locale_name in C C.UTF-8; do
  for pane in idle busy-empty interrupt-armed after-interrupt; do
    [ "$(LC_ALL=$locale_name fm_composer_classify_screen "$caps" "$(cat "$ncap/$pane.pane")")" = empty ] || fail "1.0.109 $pane composer not empty under LC_ALL=$locale_name"
  done
  [ "$(LC_ALL=$locale_name fm_composer_classify_screen "$caps" "$(cat "$ncap/idle-draft.pane")")" = pending ] || fail "1.0.109 draft not preserved under LC_ALL=$locale_name"
  [ "$(LC_ALL=$locale_name fm_composer_classify_screen "$caps" "$(cat "$ncap/rewind-picker.pane")")" = unknown ] || fail "1.0.109 rewind picker read as a composer under LC_ALL=$locale_name"
done
for pane in busy-empty interrupt-armed; do
  fm_busy_lines_match copilot < "$ncap/$pane.pane" || fail "1.0.109 $pane footer not read busy"
done
for pane in idle after-interrupt idle-draft; do
  ! fm_busy_lines_match copilot < "$ncap/$pane.pane" || fail "1.0.109 $pane read busy"
done
for pane in "$tcap/busy-empty.pane" "$cap/busy-empty.pane"; do
  fm_busy_lines_match copilot < "$pane" || fail "1.0.105 busy footer lost: $pane"
done
grep -Eq "$(fm_control_interrupt_arm_signal copilot)" "$ncap/interrupt-armed.pane" || fail '1.0.109 armed footer not recognized'
grep -Eq "$(fm_control_interrupt_hazard_signal copilot)" "$ncap/rewind-picker.pane" || fail '1.0.109 rewind picker hazard not recognized'
# A byte-based awk (mawk, or LC_ALL=C) must still match a normal-width rule.
export FM_COMPOSER_HARNESS=copilot
for awk_locale in C C.UTF-8; do
  [ "$(LC_ALL=$awk_locale fm_composer_classify_screen "$caps" "$(screen '❯')")" = empty ] || fail "120-column rule unreadable under LC_ALL=$awk_locale"
  [ "$(LC_ALL=$awk_locale fm_composer_classify_screen "$caps" "$(screen '❯ draft')")" = pending ] || fail "draft unreadable under LC_ALL=$awk_locale"
done
if command -v mawk >/dev/null 2>&1; then
  mawkbin="$TMP_ROOT/mawkbin"; mkdir -p "$mawkbin"; ln -sf "$(command -v mawk)" "$mawkbin/awk"
  [ "$(PATH="$mawkbin:$PATH" fm_composer_classify_screen "$caps" "$(screen '❯')")" = empty ] || fail 'rule unreadable under mawk'
fi
# The shape is proof only for a pane whose recorded harness is copilot.
unset FM_COMPOSER_HARNESS
case "$(fm_composer_classify_screen "$caps" "$(screen '❯ half typed draft')")" in
  pending|unknown|pending-unproven) ;;
  *) fail 'unscoped read changed verdict class' ;;
esac
pass "composer shape, draft safety, and picker refusal"

state="$TMP_ROOT/hook state"
mkdir -p "$state"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker)
"$ROOT/bin/fm-copilot-plugin.sh" "$state" worker "$gen" || fail 'plugin writer failed'
plugin="$state/worker.copilot-plugin"
jq -e '.name == "firstmate-worker"' "$plugin/plugin.json" >/dev/null || fail 'manifest missing'
hooks="$plugin/hooks/hooks.json"
jq -e '.version == 1' "$hooks" >/dev/null || fail 'hooks file version missing'
for event in userPromptSubmitted agentStop sessionEnd; do
  jq -e --arg e "$event" '.hooks[$e][0].type == "command" and (.hooks[$e][0].bash | length) > 0' "$hooks" >/dev/null \
    || fail "$event hook missing"
done
[ "$(stat -c %a "$plugin" 2>/dev/null || stat -f %Lp "$plugin")" = 700 ] || fail 'plugin dir is not private'
run_hook() { printf '%s' "${2:-}" | bash -c "$(jq -r --arg event "$1" '.hooks[$event][0].bash' "$hooks")"; }
run_hook userPromptSubmitted
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'busy copilot-hook' ] || fail 'submit did not open busy'
run_hook agentStop
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'idle copilot-hook' ] || fail 'agentStop did not settle'
assert_present "$state/worker.turn-ended" 'agentStop notification absent'
run_hook userPromptSubmitted
# A subagent's own stop (parentAgentId present) must neither close the parent's turn nor wake the supervisor.
rm -f "$state/worker.turn-ended"
sub_payload='{"sessionId":"s1","agentId":"a1","agentType":"task","parentAgentId":"s0","stopReason":"end_turn"}'
run_hook agentStop "$sub_payload"
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'busy copilot-hook' ] || fail 'subagent stop closed the parent turn'
assert_absent "$state/worker.turn-ended" 'subagent stop raised a false turn end'
run_hook agentStop '{"sessionId":"s0","prompt":"mentions \"parentAgentId\":\"x\"","stopReason":"end_turn"}'
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'idle copilot-hook' ] || fail 'prompt text naming parentAgentId blocked the real stop'
run_hook userPromptSubmitted
run_hook userPromptSubmitted "$sub_payload"
run_hook sessionEnd
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'idle copilot-hook' ] || fail 'sessionEnd did not settle'
"$ROOT/bin/fm-busy-event.sh" arm "$state" worker >/dev/null
rm "$state/worker.turn-ended"
run_hook agentStop
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'busy fm-spawn' ] || fail 'stale agentStop cleared replacement'
assert_absent "$state/worker.turn-ended" 'stale agentStop woke replacement'
stop_command=$(jq -r '.hooks.agentStop[0].bash' "$hooks")
case "$stop_command" in
  *' --turn-ended '*) ;;
  *) fail 'agentStop hook does not raise the turn-end notification under the apply lock' ;;
esac
case "$stop_command" in
  *touch*) fail 'agentStop hook touches the turn-end marker outside the apply lock' ;;
esac
wiring=$(fm_control_harness_wiring_paths copilot /unused "$state" worker)
case "$wiring" in *"$hooks"*"$plugin/plugin.json"*) ;; *) fail "plugin retirement paths missing: $wiring" ;; esac
! "$ROOT/bin/fm-copilot-plugin.sh" "$state" 'bad id' "$gen" 2>/dev/null || fail 'invalid task id accepted'
jq -e . "$hooks" >/dev/null || fail 'failed write replaced a valid plugin'
wt_home="$TMP_ROOT/trusted wt"
mkdir -p "$wt_home"
"$ROOT/bin/fm-copilot-plugin.sh" "$state" worker "$gen" "$wt_home" || fail 'home seeding failed'
cop_home="$state/worker.copilot-home"
[ "$(stat -c %a "$cop_home" 2>/dev/null || stat -f %Lp "$cop_home")" = 700 ] || fail 'copilot home is not private'
jq -e --arg wt "$(cd "$wt_home" && pwd -P)" '.trustedFolders == [$wt]' "$cop_home/config.json" >/dev/null || fail 'seed does not trust only the worktree'
# Copilot rewrites config.json with a comment header and its own keys; a relaunch must keep them and still trust the worktree.
printf '// managed\n{"trustedFolders":["/elsewhere"],"firstLaunchAt":"x"}\n' > "$cop_home/config.json"
"$ROOT/bin/fm-copilot-plugin.sh" "$state" worker "$gen" "$wt_home" || fail 'home reseed failed'
jq -e --arg wt "$(cd "$wt_home" && pwd -P)" '.firstLaunchAt == "x" and .trustedFolders == [$wt]' "$cop_home/config.json" >/dev/null || fail 'reseed lost keys or kept a stale trust entry'
# Login carry: only the three login keys are copied from the real config.json, never printed.
login_src="$TMP_ROOT/login-src"
mkdir -p "$login_src"
printf '// managed\n{"authTokens":{"https://github.com:u":"fake-auth"},"copilotTokens":{"https://github.com:u":"fake-token"},"loggedInUsers":[{"host":"https://github.com","login":"u"}],"lastLoggedInUser":{"host":"https://github.com","login":"u"},"model":"x","trustedFolders":["/elsewhere"]}\n' > "$login_src/config.json"
rm -rf "$state/login.copilot-home"
COPILOT_HOME="$login_src" "$ROOT/bin/fm-copilot-plugin.sh" "$state" login "$gen" "$wt_home" > "$TMP_ROOT/login.out" 2>&1 || fail 'login seeding failed'
lc="$state/login.copilot-home/config.json"
jq -e --arg wt "$(cd "$wt_home" && pwd -P)" '.authTokens["https://github.com:u"] == "fake-auth" and .copilotTokens["https://github.com:u"] == "fake-token" and .loggedInUsers[0].login == "u" and .lastLoggedInUser.login == "u" and .trustedFolders == [$wt] and (keys | sort) == ["authTokens","copilotTokens","lastLoggedInUser","loggedInUsers","trustedFolders"]' "$lc" >/dev/null || fail 'login keys not carried alone'
[ "$(stat -c %a "$lc" 2>/dev/null || stat -f %Lp "$lc")" = 600 ] || fail 'task config is not mode 600'
! grep -q fake-token "$TMP_ROOT/login.out" || fail 'token value printed'
printf '{"model":"x"}\n' > "$login_src/config.json"
# Re-seed over the earlier login copy: a source without a login must clear it.
COPILOT_HOME="$login_src" "$ROOT/bin/fm-copilot-plugin.sh" "$state" login "$gen" "$wt_home" || fail 'seeding without login keys failed'
jq -e '(keys | sort) == ["trustedFolders"]' "$lc" >/dev/null || fail 'a source without a login kept or added login keys'
printf '{ not json' > "$login_src/config.json"
rm -rf "$state/login.copilot-home"
COPILOT_HOME="$login_src" "$ROOT/bin/fm-copilot-plugin.sh" "$state" login "$gen" "$wt_home" || fail 'unparsable source not tolerated'
jq -e '(keys | sort) == ["trustedFolders"]' "$lc" >/dev/null || fail 'unparsable source changed the seed'
rm -rf "$state/login.copilot-home"
COPILOT_HOME="$TMP_ROOT/absent" "$ROOT/bin/fm-copilot-plugin.sh" "$state" login "$gen" "$wt_home" || fail 'missing source not tolerated'
jq -e '(keys | sort) == ["trustedFolders"]' "$lc" >/dev/null || fail 'missing source changed the seed'
pass "private plugin, trusted home, lifecycle and stale-generation rejection"

for v in 'GitHub Copilot CLI 1.0.105.' 'GitHub Copilot CLI 1.0.109.'; do
  fm_copilot_version_verified "$v" || fail "verified version warned: $v"
done
for v in '' 'garbage' 'GitHub Copilot CLI 1.0.104.' 'GitHub Copilot CLI 1.0.110.' 'GitHub Copilot CLI 1.0.1099.' 'GitHub Copilot CLI 1.1.105.' 'GitHub Copilot CLI 2.0.105.'; do
  ! fm_copilot_version_verified "$v" || fail "unverified version accepted: $v"
done
pass "verified Copilot version range"

case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
fm_fake_exit0 "$fakebin" copilot
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home" copilot
fm_git_worktree "$proj" "$wt" copilot-test
fm_test_spawn_brief "$home" copilot-worker
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch" fm_test_run_spawn "$home" "$wt" "$fakebin" copilot-worker "$proj" --scout --harness copilot --model claude-sonnet-5.5 --effort xhigh 2>&1)
then fail "spawn failed: $out"; fi
assert_contains "$out" 'copilot version unknown is outside the verified range' 'unverified version not warned'
launch=$(cat "$case_dir/launch")
assert_contains "$launch" '--allow-all' 'autonomy flag missing'
assert_contains "$launch" "COPILOT_HOME='$home/state/copilot-worker.copilot-home'" 'per-task Copilot home missing'
case "$launch" in *COPILOT_ALLOW_ALL*) fail 'launch trusts every directory through COPILOT_ALLOW_ALL' ;; esac
jq -e --arg wt "$(cd "$wt" && pwd -P)" '.trustedFolders == [$wt]' "$home/state/copilot-worker.copilot-home/config.json" >/dev/null \
  || fail 'per-task home does not trust exactly the worktree'
assert_contains "$launch" '--no-ask-user' 'ask_user tool not disabled'
assert_contains "$launch" '--no-auto-update' 'auto-update not disabled'
assert_contains "$launch" "--plugin-dir '$home/state/copilot-worker.copilot-plugin'" 'private plugin missing'
assert_contains "$launch" "--model 'claude-sonnet-5.5'" 'model lost'
assert_contains "$launch" "--reasoning-effort 'xhigh'" 'effort lost'
assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
assert_contains "$launch" 'env -u CLAUDECODE' 'CLAUDECODE not cleared before launch'
# shellcheck disable=SC2016
assert_contains "$launch" ' -i "$(' 'interactive prompt flag missing'
assert_present "$home/state/copilot-worker.copilot-plugin/hooks/hooks.json" 'spawn did not wire hooks'
[ "$(fm_busy_classify tmux fake:w copilot copilot-worker "$home/state")" = 'busy fm-spawn' ] || fail 'launch not armed'
assert_grep 'harness=copilot' "$home/state/copilot-worker.meta" 'harness not recorded'
sm_home="$case_dir/sm-home"
mkdir -p "$sm_home/bin" "$sm_home/data" "$sm_home/.github/hooks"
printf '# Firstmate\n' > "$sm_home/AGENTS.md"
printf 'copilot-sm\n' > "$sm_home/.fm-secondmate-home"
printf 'charter\n' > "$sm_home/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' > "$sm_home/.gitignore"
git -C "$sm_home" init -q -b main
fm_test_spawn_brief "$home" copilot-sm
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch-sm" fm_test_run_spawn "$home" "$sm_home" "$fakebin" copilot-sm "$sm_home" --secondmate --harness copilot 2>&1)
then fail "Copilot secondmate spawn failed: $out"; fi
sm_launch=$(cat "$case_dir/launch-sm")
assert_contains "$sm_launch" "COPILOT_HOME='$home/state/copilot-sm.copilot-home'" 'secondmate per-task Copilot home missing'
assert_contains "$sm_launch" "--plugin-dir '$home/state/copilot-sm.copilot-plugin'" 'secondmate busy plugin missing'
assert_contains "$sm_launch" "FM_HOME='$sm_home'" 'secondmate launch is not scoped to its own home'
jq -e --arg wt "$(cd "$sm_home" && pwd -P)" '.trustedFolders == [$wt]' "$home/state/copilot-sm.copilot-home/config.json" >/dev/null \
  || fail 'secondmate Copilot home does not trust exactly the secondmate home'
[ "$(fm_busy_classify tmux fake:w copilot copilot-sm "$home/state")" = 'busy fm-spawn' ] || fail 'secondmate launch not armed'
assert_grep 'harness=copilot' "$home/state/copilot-sm.meta" 'secondmate harness not recorded'
proj2="$case_dir/project2"
wt2="$case_dir/wt2"
fm_git_worktree "$proj2" "$wt2" copilot-low
fm_test_spawn_brief "$home" copilot-low
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch-low" fm_test_run_spawn "$home" "$wt2" "$fakebin" copilot-low "$proj2" --scout --harness copilot --effort low 2>&1)
then fail "low-effort spawn failed: $out"; fi
case "$(cat "$case_dir/launch-low")" in *"--model"*) fail 'a model flag appeared with no model requested' ;; esac
assert_contains "$(cat "$case_dir/launch-low")" "--reasoning-effort 'low'" 'low effort lost'
# Teardown retires the whole per-task home and plugin directory with the rest of the task records.
[ -d "$home/state/copilot-worker.copilot-home" ] || fail 'spawn did not create the per-task home'
mkdir -p "$home/state/copilot-worker.copilot-home/session-state"
if ! out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' PATH="$fakebin:$PATH" \
  "$ROOT/bin/fm-teardown.sh" copilot-worker --force 2>&1); then fail "teardown failed: $out"; fi
assert_absent "$home/state/copilot-worker.copilot-home" 'teardown left the per-task Copilot home'
assert_absent "$home/state/copilot-worker.copilot-plugin" 'teardown left the plugin directory'
pass "scout launch carries autonomy, trusted home, plugin, typed brief and hooks; secondmate launch is scoped to its own home"

# The composer and interrupt reads are proven only on tmux and Herdr, so every
# other spawn-capable backend is refused before any endpoint, worktree, or busy
# record exists.
cat > "$fakebin/orca" <<'EOF2'
#!/bin/sh
printf '%s\n' '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}'
EOF2
chmod +x "$fakebin/orca"
for backend in zellij cmux orca; do
  fm_test_spawn_brief "$home" "copilot-$backend"
  if out=$(FM_FAKE_LAUNCH_LOG="$case_dir/copilot-$backend.launch" fm_test_run_spawn "$home" "$wt" "$fakebin" "copilot-$backend" "$proj" \
    --scout --harness copilot --backend "$backend" 2>&1)
  then fail "Copilot launch accepted on backend=$backend"; fi
  assert_contains "$out" "copilot is enabled only on tmux and herdr; backend=$backend has no verified Copilot pane" "wrong refusal on $backend: $out"
  assert_absent "$case_dir/copilot-$backend.launch" "Copilot launched on $backend"
  assert_absent "$home/state/copilot-$backend.meta" "refused $backend spawn left a task record"
  assert_absent "$home/state/copilot-$backend.busy-gen" "refused $backend spawn armed busy state"
done
pass "Copilot launches are refused on zellij, cmux, and orca"

# Backend level: a shell-led pane (job control off) whose foreground group holds
# MainThread with argv[0] copilot must read alive through the real tmux probe.
(
  FM_BACKEND_LIB_DIR="$ROOT/bin"
  # shellcheck source=bin/backends/tmux.sh
  . "$ROOT/bin/backends/tmux.sh"
  fm_backend_tmux_window_inventory() { printf 'w\n'; }
  fm_backend_tmux_foreground_comms() { printf 'bash\nMainThread\n'; }
  fm_backend_tmux_foreground_argv0s() { printf 'bash\ncopilot\n'; }
  fm_backend_tmux_foreground_pids() { :; }
  fm_backend_tmux_foreground_args() { :; }
  fm_backend_tmux_current_command() { printf 'bash'; }
  [ "$(fm_backend_tmux_agent_state s:w)" = alive ] || exit 1
  fm_backend_tmux_foreground_argv0s() { printf 'bash\ncopilot-language-server\n'; }
  [ "$(fm_backend_tmux_agent_state s:w)" != alive ] || exit 2
) || fail "tmux probe misread a shell-led Copilot pane (exit $?)"
pass "tmux probe reads a shell-led Copilot pane alive and a lookalike not alive"
