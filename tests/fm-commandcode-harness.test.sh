#!/usr/bin/env bash
# Portable Command Code worker adapter regression. Vendor facts are refreshed by
# fm-commandcode-signals-live-e2e.test.sh; this suite needs no Command Code
# install and no credentials.
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
TMP_ROOT=$(fm_test_tmproot fm-commandcode-harness)
HARNESS="$ROOT/bin/fm-harness.sh"
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI

mkdir -p "$TMP_ROOT/names"
for name in command-code command-code-helper; do ln -s /bin/bash "$TMP_ROOT/names/$name"; done
# shellcheck disable=SC2016
out=$(CLAUDECODE=1 "$TMP_ROOT/names/command-code" -c '"$1"; :' _ "$HARNESS")
[ "$out" = commandcode ] || fail "native Command Code ancestry must beat foreign CLAUDECODE: $out"
# shellcheck disable=SC2016
out=$("$TMP_ROOT/names/command-code-helper" -c '"$1" ancestry "$$"; :' _ "$HARNESS")
[ "$out" != 'comm commandcode' ] || fail "unrelated command-code-helper claimed the adapter"
[ "$(fm_agent_process_classify_name /usr/bin/command-code)" = agent ] || fail "liveness lost Command Code"
[ "$(fm_agent_process_classify_name command-code-helper)" = other ] || fail "liveness claims unrelated executable"
pass "Command Code native identity; anchored liveness"

[ "$(fm_control_interrupt_key commandcode)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat commandcode)" = 1 ] || fail 'a second Escape opens the rewind picker'
[ -z "$(fm_control_interrupt_arm_signal commandcode)" ] || fail 'a single press needs no arm proof'
[ -z "$(fm_control_interrupt_clear_key commandcode)" ] || fail 'Command Code must not erase a composer draft'
[ "$(fm_control_exit_command commandcode)" = /quit ] || fail 'wrong exit command'
hazard=$(fm_control_interrupt_hazard_signal commandcode)
for row in 'Select a checkpoint to restore your session' 'Press Enter to select · Esc to cancel'; do
  printf '%s\n' "$row" | grep -Eq -- "$hazard" || fail "rewind picker row not recognized: $row"
done
! printf '❯ Ask your question...\n' | grep -Eq -- "$hazard" || fail 'idle composer read as the rewind picker'
[ "$(fm_control_harness_family commandcode)" = commandcode ] || fail 'recorded family lost'
fm_control_harness_supports_kind commandcode ship || fail 'ship refused'
fm_control_harness_supports_kind commandcode scout || fail 'scout refused'
! fm_control_harness_supports_kind commandcode secondmate || fail 'secondmate accepted'
[ -z "$(fm_control_harness_wiring_paths commandcode /wt /st id)" ] || fail 'the tracked mod leaves no per-task wiring file'
pass "worker-only resolution, single-press interrupt, rewind-picker hazard, and lifecycle capabilities"

# The composer rows Command Code 1.74.1 renders under COLORTERM=truecolor: a
# default-foreground `❯`, a reverse-video cursor cell, and the rest of the
# placeholder in 38;2;138;148;168 between two rules.
esc=$(printf '\033')
rule=$(printf '─%.0s' $(seq 1 60))
screen() {  # <styled composer row>
  printf '%s\n' "  ⠶ done" "" "${esc}[38;2;138;148;168m$rule" "$1" "${esc}[38;2;138;148;168m$rule" \
    "${esc}[39m  » permission bypass on [shift+tab]" "  ? for shortcuts · taste on"
}
idle_row="${esc}[39m❯ ${esc}[7mA${esc}[0m${esc}[38;2;138;148;168msk your question...${esc}[39m"
caps=$'styled=1\ncursor=0\nidentity=1'
idle=$(screen "$idle_row")
[ "$(fm_composer_classify_screen "$caps" "$idle")" = need-identity ] || fail 'the separated shape must ask for identity'
[ "$(fm_composer_classify_screen "$caps" "$idle" '' $'commandcode\tidle')" = empty ] || fail 'idle placeholder not empty for the tmux identity'
[ "$(fm_composer_classify_screen "$caps" "$idle" '' $'cmd\tidle')" = empty ] || fail 'idle placeholder not empty for the Herdr identity'
# The divergence that keeps this case honest: without a Command Code identity
# the same placeholder survives the fleet-wide ghost ceiling and reads pending.
[ "$(fm_composer_classify_screen "$caps" "$idle" '' probe-absent)" = pending ] \
  || fail 'the fleet-wide ceiling must not strip Command Code placeholder text on its own'
[ "$(fm_composer_classify_screen "$caps" "$idle" '' $'claude\tidle')" = pending ] || fail 'another identity borrowed the Command Code ceiling'
for typed in 'unsubmitted draft' 'Ask your question...'; do
  draft=$(screen "${esc}[39m❯ $typed${esc}[7m ${esc}[0m")
  [ "$(fm_composer_classify_screen "$caps" "$draft" '' $'commandcode\tidle')" = pending ] \
    || fail "typed default-foreground text must stay pending: $typed"
done
for signal in ' ○ Contemplificating…  esc to interrupt • 2s • ↓ 41' ' ☆ Brewing…  • 12s • ↓ 1.4k' ' ⌘ Choreographing…  • 1m 30s • ↓ 1.4k' 'esc to interrupt'; do
  printf '%s\n' "$signal" | fm_busy_lines_match commandcode || fail "independent delivery signal lost: $signal"
done
! printf '❯ Ask your question...\n  ? for shortcuts · taste on\n✻ Worked for 33s\n' | fm_busy_lines_match commandcode || fail 'idle footer read busy'
! printf 'esc to cancel\n' | fm_busy_lines_match commandcode || fail 'borrowed another harness signal'
pass "composer placeholder, draft safety, identity-scoped ceiling, and independent delivery signals"

drive_mod() {  # <event> <stopReason|-> [option-overrides-json]
  MOD="$ROOT/bin/fm-commandcode-mod.ts" EVENT="$1" STOP="$2" OPTS="${3:-}" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.MOD).href);
const flags = {};
const handlers = {};
const hooks = [];
const values = JSON.parse(process.env.OPTS || "{}");
mod.default({
  addFlag: (name, spec) => { flags[name] = spec.default; },
  getFlag: (name) => (name in values ? values[name] : flags[name]),
  on: (name, fn) => { handlers[name] = fn; },
  hooks: (h) => { hooks.push(h); },
});
switch (process.env.EVENT) {
  case "list": console.log([...Object.keys(handlers), ...hooks.flatMap((h) => Object.keys(h))].sort().join(" ")); break;
  case "run_start": handlers.run_start({ type: "run_start" }); break;
  case "run_end": handlers.run_end({ type: "run_end", result: { stopReason: process.env.STOP } }); break;
  case "session_end": for (const h of hooks) if (h.onSessionEnd) await h.onSessionEnd({ reason: "shutdown" }); break;
  default: throw new Error("unknown event " + process.env.EVENT);
}
EOF
}
if ! command -v node >/dev/null 2>&1 || ! drive_mod list - >/dev/null 2>&1; then
  printf 'skip: no node that loads TypeScript for the busy-mod cases\n'
else
  state="$TMP_ROOT/mod state"
  mkdir -p "$state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker)
  opts=$(jq -cn --arg w "$ROOT/bin/fm-busy-event.sh" --arg s "$state" --arg g "$gen" '{fmWriter: $w, fmState: $s, fmId: "worker", fmGen: $g}')
  [ "$(drive_mod list -)" = 'onSessionEnd run_end run_start' ] || fail "mod registers the wrong lifecycle: $(drive_mod list -)"
  drive_mod run_start - "$opts" >/dev/null || fail 'run_start drive failed'
  [ "$(fm_busy_classify tmux fake:w commandcode worker "$state")" = 'busy commandcode-mod' ] || fail 'run_start did not open busy'
  drive_mod run_end end_turn "$opts" >/dev/null || fail 'run_end drive failed'
  [ "$(fm_busy_classify tmux fake:w commandcode worker "$state")" = 'idle commandcode-mod' ] || fail 'run_end did not settle'
  assert_present "$state/worker.turn-ended" 'run_end notification absent'
  rm "$state/worker.turn-ended"
  drive_mod run_start - "$opts" >/dev/null
  drive_mod run_end interrupted "$opts" >/dev/null
  [ "$(fm_busy_classify tmux fake:w commandcode worker "$state")" = 'idle commandcode-mod' ] || fail 'an interrupted run did not settle'
  assert_absent "$state/worker.turn-ended" 'an interrupted run must not raise the turn-end notification'
  drive_mod run_start - "$opts" >/dev/null
  drive_mod session_end - "$opts" >/dev/null
  [ "$(fm_busy_classify tmux fake:w commandcode worker "$state")" = 'idle commandcode-mod' ] || fail 'session end did not settle'
  "$ROOT/bin/fm-busy-event.sh" arm "$state" worker >/dev/null
  drive_mod run_end end_turn "$opts" >/dev/null
  [ "$(fm_busy_classify tmux fake:w commandcode worker "$state")" = 'busy fm-spawn' ] || fail 'stale run_end cleared replacement'
  assert_absent "$state/worker.turn-ended" 'stale run_end woke replacement'
  # A relaunch can arm a replacement right after the old run_end's idle write
  # passed its generation check; this writer accepts the write and then arms
  # one, so a notification the mod raised on its own would wake the replacement.
  racing="$TMP_ROOT/racing-writer"
  printf '#!/bin/sh\n%s arm "$2" "$3" >/dev/null\n' "'$ROOT/bin/fm-busy-event.sh'" > "$racing"
  chmod +x "$racing"
  drive_mod run_end end_turn "$(jq -c --arg w "$racing" '.fmWriter = $w' <<<"$opts")" >/dev/null
  assert_absent "$state/worker.turn-ended" 'the turn-end notification escaped the writer generation check'
  drive_mod run_end end_turn '{}' >/dev/null
  [ "$(fm_busy_classify tmux fake:w commandcode worker "$state")" = 'busy fm-spawn' ] || fail 'an unconfigured mod wrote a record'
  fm_busy_source_trusted commandcode commandcode-mod || fail 'commandcode must trust its mod'
  ! fm_busy_source_trusted commandcode devin-hook || fail 'commandcode trusted another writer'
  pass "busy mod: run_start busy, run_end and session end idle, stale and unconfigured writes refused"
fi

case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
fm_fake_exit0 "$fakebin" commandcode
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home" commandcode
fm_git_worktree "$proj" "$wt" commandcode-test
spawn_case() {  # <id> <model> <effort>
  fm_test_spawn_brief "$home" "$1"
  FM_FAKE_LAUNCH_LOG="$case_dir/$1.launch" fm_test_run_spawn "$home" "$wt" "$fakebin" "$1" "$proj" \
    --scout --harness commandcode --model "$2" --effort "$3" 2>&1
}
out=$(spawn_case cc-low deepseek/deepseek-v4.1-flash low) || fail "spawn failed: $out"
launch=$(cat "$case_dir/cc-low.launch")
gen=$(cat "$home/state/cc-low.busy-gen")
assert_contains "$launch" '--yolo --trust --skip-onboarding --no-auto-update' 'autonomy/trust flags missing'
assert_contains "$launch" "--model 'deepseek/deepseek-v4.1-flash' --effort 'low' " 'model or verified effort lost'
assert_contains "$launch" "--mod '$ROOT/bin/fm-commandcode-mod.ts'" 'busy mod not loaded'
assert_contains "$launch" "--mod-option 'fmState=$home/state' --mod-option 'fmId=cc-low' --mod-option 'fmGen=$gen' " 'mod options lost'
assert_contains "$launch" '-u NO_COLOR COLORTERM=truecolor' 'placeholder styling not pinned'
# shellcheck disable=SC2016 # the literal command substitution in the template
assert_contains "$launch" '-- "$(' 'typed launch envelope must follow --'
assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
[ "$(fm_busy_classify tmux fake:w commandcode cc-low "$home/state")" = 'busy fm-spawn' ] || fail 'launch not armed'
[ ! -e "$wt/.commandcode" ] || fail 'spawn wrote project Command Code settings'
mkdir -p "$wt/.commandcode/taste" && : > "$wt/.commandcode/taste/taste.md"
[ -z "$(git -C "$wt" status --porcelain -- .commandcode)" ] || fail 'Command Code taste state is visible to git'
rm -rf "$wt/.commandcode"
out=$(spawn_case cc-xhigh deepseek/deepseek-v4.1-flash xhigh) || fail "spawn failed: $out"
case "$(cat "$case_dir/cc-xhigh.launch")" in *--effort*) fail 'an unaccepted effort reached argv' ;; esac
assert_grep 'effort=xhigh' "$home/state/cc-xhigh.meta" 'effort not recorded'
out=$(spawn_case cc-other moonshotai/kimi-k3 low) || fail "spawn failed: $out"
case "$(cat "$case_dir/cc-other.launch")" in *--effort*) fail 'an unverified model received an effort flag' ;; esac
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" cc-sm "$proj" --secondmate --harness commandcode 2>&1)
then fail 'Command Code secondmate launch accepted'; fi
assert_contains "$out" 'crewmate/scout adapter only' 'wrong secondmate refusal'
pass "scout launch carries model, verified effort only, autonomy, typed brief, and the per-process mod"

# Only tmux and Herdr supply the Command Code identity that lets its idle
# placeholder read empty, so every other spawn-capable backend is refused
# before any endpoint, worktree, or busy record exists.
cat > "$fakebin/orca" <<'EOF'
#!/bin/sh
printf '%s\n' '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}'
EOF
chmod +x "$fakebin/orca"
for backend in zellij cmux orca; do
  fm_test_spawn_brief "$home" "cc-$backend"
  if out=$(FM_FAKE_LAUNCH_LOG="$case_dir/cc-$backend.launch" fm_test_run_spawn "$home" "$wt" "$fakebin" "cc-$backend" "$proj" \
    --scout --harness commandcode --backend "$backend" 2>&1)
  then fail "Command Code launch accepted on backend=$backend"; fi
  assert_contains "$out" "commandcode is verified on the tmux and herdr backends only; backend=$backend" "wrong refusal on $backend: $out"
  assert_absent "$case_dir/cc-$backend.launch" "Command Code launched on $backend"
  assert_absent "$home/state/cc-$backend.meta" "refused $backend spawn left a task record"
  assert_absent "$home/state/cc-$backend.busy-gen" "refused $backend spawn armed busy state"
done
pass "Command Code launches are refused on zellij, cmux, and orca"
