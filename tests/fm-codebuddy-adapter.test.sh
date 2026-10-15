#!/usr/bin/env bash
# tests/fm-codebuddy-adapter.test.sh - portable regression for the CodeBuddy adapter.
# Pins detection, ancestry precedence, process classification, control mechanics,
# busy/composer delivery signatures, and launch flags for Tencent CodeBuddy CLI.
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

TMP_ROOT=$(fm_test_tmproot fm-codebuddy-adapter)
HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI CODEBUDDY_SESSION_ID

# --- 1. Detection and Ancestry in bin/fm-harness.sh -------------------------

# 1a & 1b: Marker layer tests need blinded ancestry so the harness running this
# test suite does not outrank the environment marker.
blind_fakebin=$(fm_fakebin "$TMP_ROOT/blind-ancestry")
fm_fake_blind_ancestry "$blind_fakebin"

# 1a. Child environment marker
out=$(CODEBUDDY_SESSION_ID="sess-123" PATH="$blind_fakebin:$PATH" "$HARNESS")
[ "$out" = codebuddy ] || fail "CODEBUDDY_SESSION_ID must detect codebuddy, got: $out"

# 1b. CODEBUDDY_SESSION_ID outranks an inherited CLAUDECODE
out=$(CODEBUDDY_SESSION_ID="sess-123" CLAUDECODE=1 PATH="$blind_fakebin:$PATH" "$HARNESS")
[ "$out" = codebuddy ] || fail "CODEBUDDY_SESSION_ID must beat inherited CLAUDECODE, got: $out"

# 1c. Comm ancestry: an anchored process named codebuddy
mkdir -p "$TMP_ROOT/names"
for name in codebuddy codebuddy-helper notcodebuddy; do
  ln -s /bin/bash "$TMP_ROOT/names/$name"
done

# shellcheck disable=SC2016
out=$("$TMP_ROOT/names/codebuddy" -c '"$1" ancestry "$$"; :' _ "$HARNESS")
[ "$out" = "comm codebuddy" ] || fail "native codebuddy comm ancestry failed: $out"

# shellcheck disable=SC2016
out=$("$TMP_ROOT/names/codebuddy-helper" -c '"$1" ancestry "$$"; :' _ "$HARNESS")
[ "$out" != "comm codebuddy" ] || fail "unrelated codebuddy-helper must not match as comm codebuddy"

# shellcheck disable=SC2016
out=$("$TMP_ROOT/names/notcodebuddy" -c '"$1" ancestry "$$"; :' _ "$HARNESS")
[ "$out" != "comm codebuddy" ] || fail "unrelated notcodebuddy must not match as comm codebuddy"

# 1d. Script path in node args
# When comm is node and args contains codebuddy:
# We test with a helper script that names itself node
ln -s /bin/bash "$TMP_ROOT/names/node"
# shellcheck disable=SC2016
out=$("$TMP_ROOT/names/node" -c '
  # Run a background process whose command line contains codebuddy
  (
    # Set argv[0] to node and pass script containing codebuddy
    exec -a node /bin/bash -c "sleep 2" /path/to/codebuddy/cli.js
  ) &
  bg_pid=$!
  trap "kill $bg_pid 2>/dev/null || true" EXIT
  "$1" ancestry "$bg_pid"
' _ "$HARNESS")
[ "$out" = "args codebuddy" ] || fail "node process with codebuddy script in args must yield 'args codebuddy', got: $out"

pass "fm-harness: CODEBUDDY_SESSION_ID marker, precedence over CLAUDECODE, and anchored ancestry"

# --- 2. Process Classification in bin/fm-agent-process-lib.sh --------------

[ "$(fm_agent_process_classify_name codebuddy)" = agent ] \
  || fail "fm_agent_process_classify_name must identify codebuddy as agent"
[ "$(fm_agent_process_classify_name codebuddy-helper)" = other ] \
  || fail "fm_agent_process_classify_name must identify codebuddy-helper as other"
[ "$(fm_agent_process_classify_name /usr/local/bin/codebuddy)" = agent ] \
  || fail "fm_agent_process_classify_name must identify path to codebuddy as agent"

[ "$(fm_agent_process_classify node node "node /home/user/.hermes/node/bin/codebuddy -y")" = agent ] \
  || fail "fm_agent_process_classify must identify node with codebuddy args as agent"
[ "$(fm_agent_process_classify MainThread node "node /home/user/.hermes/node/bin/codebuddy -y")" = agent ] \
  || fail "fm_agent_process_classify must identify MainThread with codebuddy args as agent"
[ "$(fm_agent_process_classify cat cat "cat codebuddy.md")" = other ] \
  || fail "fm_agent_process_classify must not classify cat codebuddy.md as agent"

pass "fm-agent-process-lib: codebuddy process name and node-bundle args classified as agent"

# --- 3. Control Mechanics in bin/fm-control-lib.sh -------------------------

fm_control_harness_supported codebuddy \
  || fail "codebuddy must be in fm_control_harnesses"
[ "$(fm_control_harness_family codebuddy)" = codebuddy ] \
  || fail "family of codebuddy must be codebuddy"
[ "$(fm_control_harness_family codebuddy-2.164.0)" = codebuddy ] \
  || fail "prefixed codebuddy must resolve to codebuddy family"

fm_control_harness_supports_kind codebuddy ship \
  || fail "codebuddy must support ship tasks"
fm_control_harness_supports_kind codebuddy scout \
  || fail "codebuddy must support scout tasks"
! fm_control_harness_supports_kind codebuddy secondmate \
  || fail "codebuddy must refuse secondmate tasks"

[ "$(fm_control_interrupt_key codebuddy)" = Escape ] \
  || fail "codebuddy interrupt key must be Escape"
[ "$(fm_control_interrupt_repeat codebuddy)" = 1 ] \
  || fail "codebuddy interrupt repeat must be 1"
[ -z "$(fm_control_interrupt_clear_key codebuddy)" ] \
  || fail "codebuddy must not need an interrupt clear key"
[ "$(fm_control_exit_command codebuddy)" = /exit ] \
  || fail "codebuddy exit command must be /exit"
[ -z "$(fm_control_relaunch_resume_flag codebuddy codebuddy)" ] \
  || fail "codebuddy must have no resume flag"

pass "fm-control-lib: codebuddy control mechanics (Escape, 1 press, /exit, crew/scout only)"

# --- 4. Busy and Delivery Signatures ---------------------------------------

# 4a. fm_busy_codebuddy_tail_busy
printf '✶ Waking… (0s · waiting for model)\n' | fm_busy_codebuddy_tail_busy \
  || fail "tail busy must match initial spinner frame"
printf '✹ Cleaning… (8s · waiting for model · ↑ 34 tokens)\n' | fm_busy_codebuddy_tail_busy \
  || fail "tail busy must match active spinner frame with tokens"
printf '✺ Reporting… (11m · writing Bash · ↓ 125 tokens)\n' | fm_busy_codebuddy_tail_busy \
  || fail "tail busy must match minutes duration"

! printf '✔ Worked for 12s\n' | fm_busy_codebuddy_tail_busy \
  || fail "completed turn must not read as busy"
! printf 'esc to cancel\n' | fm_busy_codebuddy_tail_busy \
  || fail "must not borrow agy busy signature"
! printf 'Working...\n' | fm_busy_codebuddy_tail_busy \
  || fail "must not borrow pi busy signature"

# 4b. fm_busy_classify
fake_state="$TMP_ROOT/busy-state"
mkdir -p "$fake_state"
pane_busy="Some preliminary output
✶ Waking… (0s · waiting for model)"
pane_idle="Some preliminary output
✔ Worked for 5s
> "

[ "$(fm_busy_classify tmux fake:w codebuddy worker "$fake_state" "$pane_busy")" = 'busy codebuddy-regex' ] \
  || fail "pane with spinner must classify as 'busy codebuddy-regex'"
[ "$(fm_busy_classify tmux fake:w codebuddy worker "$fake_state" "$pane_idle")" = 'unknown codebuddy-regex' ] \
  || fail "pane without spinner must classify as 'unknown codebuddy-regex'"

# 4c. fm_busy_lines_match (composer delivery signature)
printf '✶ Waking… (0s · waiting for model)\n' | fm_busy_lines_match codebuddy \
  || fail "codebuddy delivery regex must match spinner line"
! printf 'esc to cancel\n' | fm_busy_lines_match codebuddy \
  || fail "codebuddy delivery regex must not match foreign signature"

pass "fm-busy-lib and fm-composer-lib: codebuddy spinner busy and delivery signatures"

# --- 5. Spawn Flags and Refusals in bin/fm-spawn.sh -------------------------

# Extract spawn helpers
eval "$(sed -n '/^shell_quote() {/,/^}/p' "$SPAWN")"
eval "$(sed -n '/^model_flag_for_harness() {/,/^}/p' "$SPAWN")"
eval "$(sed -n '/^effort_flag_for_harness() {/,/^}/p' "$SPAWN")"
eval "$(sed -n '/^launch_template() {/,/^}/p' "$SPAWN")"

# 5a. Model flag
[ "$(model_flag_for_harness codebuddy gpt-5)" = "--model 'gpt-5' " ] \
  || fail "model flag for codebuddy should format --model 'gpt-5'"
[ "$(model_flag_for_harness codebuddy default)" = "" ] \
  || fail "default model should produce no flag"

# 5b. Effort flag
for effort in low medium high xhigh max; do
  got=$(effort_flag_for_harness codebuddy "$effort")
  expected="--effort '$effort' "
  [ "$got" = "$expected" ] || fail "effort $effort should produce $expected, got: $got"
done
[ "$(effort_flag_for_harness codebuddy ultra)" = "" ] \
  || fail "ultra effort must be omitted for codebuddy"

# 5c. Launch template
template=$(launch_template codebuddy)
assert_contains "$template" "__CODEBUDDYBIN__ -y --settings '{\"trustAll\":true}'" \
  "codebuddy launch template must include autonomy flag -y and trustAll settings"
assert_contains "$template" "env -u CLAUDECODE" \
  "codebuddy launch template must clear foreign primary markers"

# 5d. Secondmate refusal
fake_home="$TMP_ROOT/fake-home"
mkdir -p "$fake_home/state" "$fake_home/data" "$fake_home/projects" "$fake_home/config"
out=$(HOME="$fake_home" FM_ROOT_OVERRIDE='' FM_HOME="$fake_home" \
  FM_STATE_OVERRIDE="$fake_home/state" FM_DATA_OVERRIDE="$fake_home/data" \
  FM_PROJECTS_OVERRIDE="$fake_home/projects" FM_CONFIG_OVERRIDE="$fake_home/config" \
  FM_SPAWN_NO_GUARD=1 "$SPAWN" test-id --secondmate codebuddy 2>&1 || true)
assert_contains "$out" "codebuddy is a verified crewmate/scout adapter only and cannot run a secondmate" \
  "codebuddy secondmate launch must be refused"

# 5e. Missing executable refusal
out=$(PATH="/usr/bin:/bin" HOME="$fake_home" FM_ROOT_OVERRIDE='' FM_HOME="$fake_home" \
  FM_STATE_OVERRIDE="$fake_home/state" FM_DATA_OVERRIDE="$fake_home/data" \
  FM_PROJECTS_OVERRIDE="$fake_home/projects" FM_CONFIG_OVERRIDE="$fake_home/config" \
  FM_SPAWN_NO_GUARD=1 "$SPAWN" test-id "$fake_home/projects" --scout --harness codebuddy 2>&1 || true)
assert_contains "$out" "codebuddy executable not found on PATH" \
  "missing codebuddy executable must be diagnosed loudly"

pass "fm-spawn: model/effort flags, launch template, secondmate refusal, and missing executable check"
