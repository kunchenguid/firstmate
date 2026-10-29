#!/usr/bin/env bash
# Portable MiniMax Code (mcode) worker adapter regression. Vendor facts are
# refreshed by fm-mcode-signals-live-e2e.test.sh; this suite needs no mcode
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
TMP_ROOT=$(fm_test_tmproot fm-mcode-harness)
HARNESS="$ROOT/bin/fm-harness.sh"
CONFIG_TOOL="$ROOT/bin/fm-mcode-config.sh"
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI
unset MINIMAX_DATA_DIR MAVIS_DATA_DIR

mkdir -p "$TMP_ROOT/names"
for name in minimax-code minimax-code-helper; do ln -s /bin/bash "$TMP_ROOT/names/$name"; done
# shellcheck disable=SC2016
out=$(CLAUDECODE=1 "$TMP_ROOT/names/minimax-code" -c '"$1"; :' _ "$HARNESS")
[ "$out" = mcode ] || fail "native mcode ancestry must beat foreign CLAUDECODE: $out"
# shellcheck disable=SC2016
out=$("$TMP_ROOT/names/minimax-code-helper" -c '"$1" ancestry "$$"; :' _ "$HARNESS")
[ "$out" != 'comm mcode' ] || fail "unrelated minimax-code-helper claimed the adapter"
[ "$(fm_agent_process_classify_name /usr/bin/minimax-code)" = agent ] || fail "liveness lost mcode"
[ "$(fm_agent_process_classify_name minimax-code-helper)" = other ] || fail "liveness claims unrelated executable"
pass "mcode native identity; anchored liveness"

[ "$(fm_control_interrupt_key mcode)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat mcode)" = 1 ] || fail 'a second fast Escape opens the edit-message mode'
[ -z "$(fm_control_interrupt_arm_signal mcode)" ] || fail 'a single press needs no arm proof'
[ "$(fm_control_interrupt_clear_key mcode)" = C-u ] || fail 'mcode restores a cancelled prompt that must be cleared'
[ "$(fm_control_exit_command mcode)" = /quit ] || fail 'wrong exit command'
hazard=$(fm_control_interrupt_hazard_signal mcode)
for row in '    Editing the selected message' '    Enter replace and regenerate · Esc cancel'; do
  printf '%s\n' "$row" | grep -Eq -- "$hazard" || fail "edit-message mode not recognized: $row"
done
for row in '    Press Esc again to edit the latest message' '  ›  Ask Mcode to do anything'; do
  ! printf '%s\n' "$row" | grep -Eq -- "$hazard" || fail "harmless row read as the edit-message mode: $row"
done
[ "$(fm_control_harness_family mcode)" = mcode ] || fail 'recorded family lost'
fm_control_harness_supports_kind mcode ship || fail 'ship refused'
fm_control_harness_supports_kind mcode scout || fail 'scout refused'
! fm_control_harness_supports_kind mcode secondmate || fail 'secondmate accepted'
[ -z "$(fm_control_harness_wiring_paths mcode /wt /st id)" ] || fail 'mcode loads no per-task wiring file'
pass "worker-only resolution, single-press interrupt with clear, edit-message hazard, and lifecycle capabilities"

# The composer rows mcode 0.7.1 renders (captured live): the header row, a
# bold 38;2;104;192;255 `›`, a reverse-video cursor cell, and the placeholder or
# next-message suggestion in 38;2;173;173;173, between two 38;2;102;102;102 rules.
esc=$(printf '\033')
rule=$(printf '─%.0s' $(seq 1 60))
glyph="${esc}[1m${esc}[38;2;104;192;255m›${esc}[0m"
screen() {  # <header> <styled composer row>
  printf '%s\n' "  ● done" "    └ Completed in 3s" \
    "  ${esc}[1m${esc}[38;2;104;192;255m$1${esc}[0m${esc}[38;2;102;102;102m · ${esc}[1m${esc}[38;2;214;214;214mEnter${esc}[0m${esc}[38;2;173;173;173m send" \
    "  ${esc}[38;2;102;102;102m  $rule" "  $2" "  ${esc}[38;2;102;102;102m  $rule" "" \
    "  ${esc}[38;2;173;173;173m…/wt${esc}[38;2;102;102;102m │ Full access │ ✦ M3.1-Flash · Effort default"
}
ghost() { printf '%s' "$glyph ${esc}[7m${esc}[38;2;173;173;173m${1:0:1}${esc}[0m${esc}[38;2;173;173;173m${1:1}${esc}[39m"; }
idle=$(screen Message "$(ghost 'Ask Mcode to do anything')")
suggest=$(screen 'Suggested next message' "$(ghost 'Verify that notes.txt contains alpha.')")
draft=$(screen Prompt "$glyph typed draft text${esc}[7m ${esc}[0m")
slash=$(screen Command "$glyph ${esc}[1m${esc}[38;2;104;192;255m/quit${esc}[0;7m ${esc}[0m")
caps=$'styled=1\ncursor=1\nidentity=1'
cursorless=$'styled=1\ncursor=0\nidentity=1'
for shot in idle suggest; do
  [ "$(fm_composer_classify_screen "$caps" "${!shot}" 4 $'mcode\tidle')" = empty ] || fail "$shot not empty for the tmux identity"
  [ "$(fm_composer_classify_screen "$cursorless" "${!shot}" '' $'mcode\tunknown')" = empty ] || fail "$shot not empty for the Herdr registration"
  # The divergence that keeps the case honest: without an mcode identity the
  # same ghost text is bright enough to read as typed input.
  [ "$(fm_composer_classify_screen "$caps" "${!shot}" 4 probe-absent)" = pending ] || fail "$shot read empty without the mcode identity"
  [ "$(fm_composer_classify_screen "$caps" "${!shot}" 4 $'claude\tidle')" = pending ] || fail "another identity borrowed the mcode ghost colour on $shot"
done
for shot in draft slash; do
  [ "$(fm_composer_classify_screen "$caps" "${!shot}" 4 $'mcode\tidle')" = pending ] || fail "typed $shot must stay pending"
  [ "$(fm_composer_classify_screen "$cursorless" "${!shot}" '' $'mcode\tunknown')" = pending ] || fail "typed $shot must stay pending cursorless"
done
# A typed slash command is drawn bold in luminance ~172.9, just under the
# placeholder's 173, so no luminance ceiling can strip one and keep the other;
# only the exact colour does.
[ "$(FM_COMPOSER_GHOST_LUMA_MAX=174 fm_composer_classify_screen "$caps" "$slash" 4 probe-absent)" != pending ] \
  || fail 'the luminance trap the exact colour avoids has vanished; re-check the mcode ghost rule'
# Negative paths: a placeholder in a colour this adapter never recorded (a
# theme or release change) stays typed text, and mcode's approval modal, whose
# options lead with `›`, is never a free composer.
other=$(screen Message "$glyph ${esc}[7m${esc}[38;2;200;200;200mA${esc}[0m${esc}[38;2;200;200;200msk Mcode to do anything${esc}[39m")
[ "$(fm_composer_classify_screen "$caps" "$other" 4 $'mcode\tidle')" = pending ] || fail 'an unrecorded placeholder colour read empty'
modal=$(printf '%s\n' '  ● Running' '  ╭─ ◆ Approval required ──────────────────── Bash ─╮' '  │ Run this command?                             │' \
  '  │ › › 1 Allow for this conversation             │' '  │   2 Always allow matching actions             │' '  │   3 Deny and guide MCode                      │' \
  '  ├───────────────────────────────────────────────┤' '  │ ↑/↓ choose · Enter confirm · Esc deny · Ctrl+C stop │' '  ╰───────────────────────────────────────────────╯')
for cy in 3 7; do
  [ "$(fm_composer_classify_screen "$caps" "$modal" "$cy" $'mcode\tidle')" != empty ] || fail "the approval modal read empty at row $cy"
done
[ "$(fm_composer_classify_screen "$cursorless" "$modal" '' $'mcode\tunknown')" != empty ] || fail 'the approval modal read empty cursorless'
asked=$'styled=1\ncursor=0\nidentity=1\nmcode=ask'
[ "$(fm_composer_classify_screen "$asked" "$idle")" = need-identity ] || fail 'a non-empty bare › read must ask for the mcode identity'
[ "$(fm_composer_classify_screen "$asked" "$idle" '' $'mcode\tunknown')" = empty ] || fail 'the mcode identity answer was not applied'
plain_box=$(printf '%s\n' '╭────╮' '│    │' '╰────╯')
[ "$(fm_composer_classify_screen "$asked" "$plain_box")" = empty ] || fail 'an empty read paid for an mcode identity probe'
# Replay the real panes (tests/captures/mcode-0.7.1/README.md owns their
# provenance and cursor rows): verdict with the tmux identity, without it, and
# cursorless with the Herdr registration, then the slot-anchored spinner read.
caps_dir="$ROOT/tests/captures/mcode-0.7.1"
while read -r shot cy with without herdr spin; do
  pane=$(cat "$caps_dir/$shot.ansi")
  [ "$(fm_composer_classify_screen "$caps" "$pane" "$cy" $'mcode\tidle')" = "$with" ] || fail "real $shot pane with the mcode identity is not $with"
  [ "$(fm_composer_classify_screen "$caps" "$pane" "$cy" probe-absent)" = "$without" ] || fail "real $shot pane without the identity is not $without"
  [ "$(fm_composer_classify_screen "$cursorless" "$pane" '' $'mcode\tunknown')" = "$herdr" ] || fail "real $shot pane cursorless is not $herdr"
  if printf '%s\n' "$pane" | fm_composer_strip_ansi | fm_composer_mcode_spinner_live; then got=busy; else got=idle; fi
  [ "$got" = "$spin" ] || fail "real $shot pane spinner read is $got, not $spin"
done <<'ROWS'
idle 32 empty pending empty idle
busy 30 empty pending empty busy
typed-draft 32 pending pending pending idle
typed-slash 45 unknown unknown pending idle
suggestion 46 empty pending empty idle
ROWS
pass "composer placeholder and suggestion, draft and slash safety, exact-colour identity scoping, and the lazy Herdr probe, replayed on real panes"

[ "$(fm_busy_mcode_title_state 'Working | wt (mvs_7422) | MCode')" = busy ] || fail 'busy title misread'
for title in 'Ready | wt (mvs_7422) | MCode' 'Done | Run sleep 8 | MCode' 'Stopped | Run sleep 8 | MCode' 'Failed | x | MCode' 'Error | x | MCode'; do
  [ "$(fm_busy_mcode_title_state "$title")" = settled ] || fail "settled title misread: $title"
done
for title in 'Needs approval | x | MCode' 'Needs input | x | MCode' 'Needs login | x | MCode'; do
  [ "$(fm_busy_mcode_title_state "$title")" = parked ] || fail "parked title misread: $title"
done
for title in 'Working | x' 'zsh' '' 'Working on it | MCode tips'; do
  [ "$(fm_busy_mcode_title_state "$title")" = unknown ] || fail "foreign title claimed: $title"
done
# The bottom of a live mcode pane: the slot row above the composer's top
# rule holds the spinner while a turn runs and the `Message` header when idle.
bottom() {  # <slot row> [transcript row]
  printf '%s\n' "${2:-  ● done}" "$1" "    $rule" '  ›  Ask Mcode to do anything' "    $rule" '' \
    '  …/wt │ ⎇ main │ Full access │ ✦ M3.1-Flash · Effort default'
}
spinner='  ⠼ Running 27s · Option+Enter queue · Enter steer · Ctrl+O details · Esc stop'
header='    Message · Enter send · Ctrl+J newline'
busy_tail=$(bottom "$spinner")
idle_tail=$(bottom "$header")
# Transcript text quoting the spinner row renders above the slot, never in it.
echo_tail=$(bottom "$header" "  ● The status row reads: $spinner")
# Drive the two signals apart through the classifier's own backend seams.
FAKE_TITLE=
FAKE_TAIL=
fm_backend_mcode_title() { [ -n "$FAKE_TITLE" ] && printf '%s' "$FAKE_TITLE"; }
fm_backend_capture() { printf '%s\n' "$FAKE_TAIL"; }
fm_backend_busy_state() { printf 'unknown'; }
classify() { FAKE_TITLE=$1 FAKE_TAIL=$2; fm_busy_classify tmux fake:w mcode worker "$TMP_ROOT/no-state"; }
[ "$(classify 'Working | wt | MCode' "$idle_tail")" = 'busy mcode-title' ] || fail 'the title alone must prove busy'
[ "$(classify 'Done | wt | MCode' "$busy_tail")" = 'busy mcode-regex' ] || fail 'the spinner row alone must prove busy'
[ "$(classify '' "$busy_tail")" = 'busy mcode-regex' ] || fail 'a missing title must not hide the spinner row'
[ "$(classify 'Done | wt | MCode' "$idle_tail")" = 'idle mcode-title' ] || fail 'a settled title with no spinner must read idle'
[ "$(classify 'Done | wt | MCode' "$echo_tail")" = 'idle mcode-title' ] || fail 'quoted spinner text in the transcript faked a running turn'
[ "$(classify '' "$idle_tail")" = 'unknown mcode-title' ] || fail 'no title must never read idle'
[ "$(classify 'Needs approval | wt | MCode' "$idle_tail")" = 'unknown mcode-title' ] || fail 'a parked worker must not read idle'
# An unreadable pane leaves only the title: busy still proves busy, and a
# settled title alone is not enough to claim idle without the tail.
fm_backend_capture() { return 1; }
[ "$(classify 'Working | wt | MCode' '')" = 'busy mcode-title' ] || fail 'an unreadable pane hid the busy title'
[ "$(classify 'Done | wt | MCode' '')" = 'unknown capture-failed' ] || fail 'an unreadable pane claimed idle'
unset -f fm_backend_mcode_title fm_backend_capture fm_backend_busy_state
printf '%s\n' "$busy_tail" | fm_busy_lines_match mcode || fail 'mcode delivery signal lost'
for slot in '  ⠏ Loading · Option+Enter queue · Enter steer · Ctrl+O de' '    ⠏ Loading 4min37s · Option+Enter queue · Enter steer · Ctrl+O details · Esc stop'; do
  bottom "$slot" | fm_busy_lines_match mcode || fail "spinner row variant lost: $slot"
done
! printf '%s\n' "$idle_tail" | fm_busy_lines_match mcode || fail 'idle header read busy'
# A pending composer with quoted spinner text must not convert to delivered.
! printf '%s\n' "$echo_tail" | fm_busy_lines_match mcode || fail 'quoted spinner text confirmed a delivery'
[ "$(fm_composer_queued_enter_verdict pending idle)" != empty ] || fail 'an idle pane converted a pending composer to delivered'
! printf '%s\n' "$spinner" | fm_busy_lines_match mcode || fail 'a spinner row outside its slot read busy'
# Drift shapes: another verb in the same row still reads busy, while a row that
# lost its queue and steer hints does not (the title still carries busy).
bottom '  ⠙ Compacting 3s · Option+Enter queue · Enter steer · Ctrl+O details' | fm_busy_lines_match mcode || fail 'a new spinner verb lost the row'
! bottom '  ⠙ Running 3s · Esc stop' | fm_busy_lines_match mcode || fail 'a reshaped row was claimed without its hints'
! printf '%s\n' "$busy_tail" | fm_busy_lines_match || fail 'the harness-less union must not carry the mcode row'
! printf 'esc to cancel\n' | fm_busy_lines_match mcode || fail 'borrowed another harness signal'
pass "busy state: title and slot-anchored spinner row each prove busy, quoted text fakes neither busy nor delivery, idle only from a settled title"

data="$TMP_ROOT/minimax"
mkdir -p "$data"
write_config() {  # <permission line or empty>
  {
    printf 'logLevel: info\nprovider:\n  minimax:\n    name: MiniMax\n    models:\n'
    printf '      MiniMax-M3:\n        name: M3\n      "MiniMax-M3.1-Flash":\n        name: M3.1-Flash\n'
    printf '    model_order:\n      - MiniMax-M3.1-Flash\ndefaultModel: minimax/MiniMax-M3.1-Flash\n'
    [ -z "$1" ] || printf '%s\n' "$1"
  } > "$data/config.yaml"
}
preflight() { MINIMAX_DATA_DIR=$data "$CONFIG_TOOL" preflight "$@" 2>&1; }
write_config ''
out=$(preflight) && fail 'an unset permission mode was accepted'
assert_contains "$out" '/permission full' 'refusal must name the fix'
write_config 'permissionMode: auto'
out=$(preflight) && fail 'Auto mode was accepted'
write_config "permissionMode: 'bypassPermissions'"
out=$(preflight) || fail "Full access refused: $out"
out=$(preflight minimax/MiniMax-M3.1-Flash) || fail "a configured quoted model refused: $out"
out=$(preflight minimax/MiniMax-M3) || fail "a configured model refused: $out"
out=$(preflight minimax/MiniMax-Bogus-9) && fail 'an unknown model was accepted although mcode would silently run its default'
assert_contains "$out" 'minimax/MiniMax-M3, minimax/MiniMax-M3.1-Flash' 'refusal must list the configured ids'
out=$(preflight other/thing) && fail 'a provider the config does not define was accepted although mcode would silently run its default'
assert_contains "$out" 'configured: minimax' 'refusal must list the configured providers'
out=$(preflight MiniMax-M3) && fail 'a model without its provider was accepted'
out=$(MINIMAX_DATA_DIR="$TMP_ROOT/absent" "$CONFIG_TOOL" preflight 2>&1) && fail 'an unreadable config was accepted'
# The one directory checked is printed for the launch to pin, resolved the way
# mcode resolves it, and a relative override is refused.
[ "$(MINIMAX_DATA_DIR=$data "$CONFIG_TOOL" preflight 2>/dev/null)" = "$data" ] || fail 'the checked data directory was not printed'
[ "$(MINIMAX_DATA_DIR="  $data  " "$CONFIG_TOOL" preflight 2>/dev/null)" = "$data" ] || fail 'a padded override was not trimmed as mcode trims it'
[ "$(MAVIS_DATA_DIR=$data "$CONFIG_TOOL" preflight 2>/dev/null)" = "$data" ] || fail 'the MAVIS_DATA_DIR fallback was not honored'
[ "$(MINIMAX_DATA_DIR=$data MAVIS_DATA_DIR="$TMP_ROOT/absent" "$CONFIG_TOOL" preflight 2>/dev/null)" = "$data" ] || fail 'MINIMAX_DATA_DIR must outrank MAVIS_DATA_DIR'
out=$(MINIMAX_DATA_DIR=minimax "$CONFIG_TOOL" preflight 2>&1) && fail 'a relative data directory was accepted'
assert_contains "$out" relative 'the relative refusal must say why'
# mcode writes two-space block YAML, but any consistent indentation, quoted
# keys, and a commented quoted mode parse alike; a flow-style models map cannot
# be read and launches unvalidated.
wide="$TMP_ROOT/minimax-wide"
mkdir -p "$wide"
printf '%s\n' 'permissionMode: "bypassPermissions"  # set by /permission full' 'provider:' '    minimax:' '        models:' \
  "            'MiniMax-M3.1-Flash':" '                name: M3.1-Flash' '    flow:' '        models: {a: 1}' > "$wide/config.yaml"
out=$(MINIMAX_DATA_DIR=$wide "$CONFIG_TOOL" preflight minimax/MiniMax-M3.1-Flash 2>&1) || fail "four-space indentation refused: $out"
out=$(MINIMAX_DATA_DIR=$wide "$CONFIG_TOOL" preflight minimax/MiniMax-M3 2>&1) && fail 'an unlisted model passed under four-space indentation'
out=$(MINIMAX_DATA_DIR=$wide "$CONFIG_TOOL" preflight flow/a 2>&1) || fail "a flow-style models map refused: $out"
assert_contains "$out" unvalidated 'an unreadable models map must be announced'
pass "launch preflight: Full access required, configured providers and models only, one absolute data directory printed"

case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
# A drifted install: the version is read into the task record and named in a
# readiness refusal.
# shellcheck disable=SC2016 # $1 expands in the generated fake binary
printf '#!/bin/sh\n[ "${1:-}" = --version ] && echo 0.8.0\nexit 0\n' > "$fakebin/mcode"
chmod +x "$fakebin/mcode"
# The spawn readiness gate reads the pane: serve a chosen mcode screen and
# delegate every other call to the fixture's fake tmux.
mv "$fakebin/tmux" "$fakebin/tmux-base"
cat > "$fakebin/tmux" <<'EOF'
#!/bin/sh
if [ "${1:-}" = capture-pane ] && [ -n "${FM_FAKE_MCODE_SCREEN:-}" ]; then
  printf '%s\n' "$FM_FAKE_MCODE_SCREEN"
  exit 0
fi
exec "$(dirname "$0")/tmux-base" "$@"
EOF
chmod +x "$fakebin/tmux"
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home" mcode
fm_git_worktree "$proj" "$wt" mcode-test
spawn_case() {  # <id> [fm-spawn args...]
  local id=$1
  shift
  fm_test_spawn_brief "$home" "$id"
  MINIMAX_DATA_DIR=$data FM_MCODE_READY_POLLS=3 FM_MCODE_POLL_INTERVAL=0 \
    FM_FAKE_MCODE_SCREEN=${FM_FAKE_MCODE_SCREEN-$busy_tail} \
    FM_FAKE_LAUNCH_LOG="$case_dir/$id.launch" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout --harness mcode "$@" 2>&1
}
out=$(spawn_case mc-high --model minimax/MiniMax-M3.1-Flash --effort high) || fail "spawn failed: $out"
launch=$(cat "$case_dir/mc-high.launch")
assert_contains "$launch" "$fakebin/mcode' --model 'minimax/MiniMax-M3.1-Flash' " 'resolved binary or model lost'
assert_contains "$launch" '-u NO_COLOR -u MAVIS_DATA_DIR COLORTERM=truecolor' 'placeholder styling not pinned or MAVIS_DATA_DIR kept'
assert_contains "$launch" "MINIMAX_DATA_DIR='$data' " 'the worker does not read the configuration the preflight checked'
assert_contains "$launch" 'env -u CLAUDECODE' 'foreign launcher marker not cleared'
assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
case "$launch" in *--effort*|*__*) fail "effort reached argv or a placeholder survived: $launch" ;; esac
assert_grep 'harness=mcode' "$home/state/mc-high.meta" 'harness not recorded'
assert_grep 'effort=high' "$home/state/mc-high.meta" 'effort not recorded'
assert_absent "$home/state/mc-high.busy-gen" 'mcode has no semantic writer, so nothing may be armed'
assert_grep 'mcode_version=0.8.0' "$home/state/mc-high.meta" 'the launched mcode version was not recorded'
pass "scout launch carries the model, records and omits effort, pins colour, and arms nothing"

out=$(FM_FAKE_MCODE_SCREEN="$idle_tail" spawn_case mc-stuck) && fail 'a launch that never showed a busy turn reported success'
assert_contains "$out" 'mcode 0.8.0 did not start processing its brief' "the readiness failure must name the drifted version: $out"
assert_contains "$out" 'verified on mcode 0.7.1' "the readiness failure must name the verified version: $out"
assert_grep 'did not start processing its brief' "$home/state/mc-stuck.status" 'readiness failure not recorded'
# The fake tmux records the task window on new-window and clears it on
# kill-window, so an empty record proves the failed launch's endpoint was closed.
[ ! -s "$fakebin/.spawn-window" ] || fail "a failed readiness gate left its endpoint open: $(cat "$fakebin/.spawn-window")"
pass "readiness gate requires a busy turn before the spawn reports success"

refuse_case() {  # <id> <expected> [fm-spawn args...]
  local id=$1 expected=$2 refusal
  shift 2
  refusal=$(spawn_case "$id" "$@") && fail "$id was launched"
  assert_contains "$refusal" "$expected" "wrong refusal for $id: $refusal"
  assert_absent "$case_dir/$id.launch" "$id launched"
  assert_absent "$home/state/$id.meta" "refused $id left a task record"
}
refuse_case mc-bogus 'is not configured' --model minimax/MiniMax-Bogus-9
write_config 'permissionMode: auto'
refuse_case mc-auto '/permission full'
write_config 'permissionMode: bypassPermissions'
cat > "$fakebin/orca" <<'EOF'
#!/bin/sh
printf '%s\n' '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}'
EOF
chmod +x "$fakebin/orca"
for backend in zellij cmux orca; do
  refuse_case "mc-$backend" "mcode is verified on the tmux and herdr backends only; backend=$backend" --backend "$backend"
done
if out=$(MINIMAX_DATA_DIR=$data fm_test_run_spawn "$home" "$wt" "$fakebin" mc-sm "$proj" --secondmate --harness mcode 2>&1)
then fail 'mcode secondmate launch accepted'; fi
assert_contains "$out" 'crewmate/scout adapter only' 'wrong secondmate refusal'
pass "refusals before any record: unknown model, missing Full access, unverified backends, secondmate"
