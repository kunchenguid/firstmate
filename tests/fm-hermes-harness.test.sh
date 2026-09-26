#!/usr/bin/env bash
# Behavior tests for the Hermes Agent harness adapter outside the plugin
# itself (tests/fm-hermes-plugin.test.sh owns the plugin): detection, the
# plugin installer's states, the spawn launch shape and its refusals, control
# mechanics, busy-state trust and launch-prompt signatures, composer delivery
# signatures, supervision rendering, and the extension-model ownership proof.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A suite run from inside another harness inherits its markers; drop them so
# each case controls the only evidence it asserts on.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI FM_OMP_HARNESS HERMES_AGENT HERMES_SESSION_ID \
  FM_HERMES_ROLE FM_HERMES_ROOT

# shellcheck source=bin/fm-hermes-lib.sh
. "$ROOT/bin/fm-hermes-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PLUGIN="$ROOT/bin/fm-hermes-plugin.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
fm_git_identity fmtest fmtest@example.invalid

# --- 1. identity ---------------------------------------------------------------

test_identity_rules() {
  fm_hermes_args_are_hermes "/Users/x/.hermes/tools/python-3.14/bin/python3 -I -c import os, re, sys\\012from hermes_cli.main import main\\012 chat -q brief" \
    || fail "the git installer's inline bootstrap (macOS ps rendering) must identify as hermes"
  fm_hermes_args_are_hermes "python3 -I -c import os, re, sys from hermes_cli.main import main chat" \
    || fail "the inline bootstrap with Linux-flattened newlines must identify as hermes"
  fm_hermes_args_are_hermes "/venv/bin/python /venv/bin/hermes chat --cli" \
    || fail "a pip/uv console script must identify as hermes"
  fm_hermes_args_are_hermes "hermes --cli" || fail "a natively named hermes launcher must identify as hermes"
  fm_hermes_args_are_hermes "/x/bin/python3 -m tui_gateway.entry" || fail "the Ink TUI's agent gateway must identify as hermes"
  if fm_hermes_args_are_hermes "/x/bin/python3 -m some_other.entry"; then
    fail "another python module must not identify as hermes"
  fi
  if fm_hermes_args_are_hermes "/usr/bin/python3 /Users/x/code/firstmate-hermes/bin/fm-mail.py"; then
    fail "a firstmate helper under a hermes-named checkout must never identify as hermes"
  fi
  if fm_hermes_args_are_hermes "python3 -I /x/hermes/run.py"; then
    fail "a script inside a hermes-named directory must not identify as hermes"
  fi
  if fm_hermes_args_are_hermes "python3 -c print('hello hermes')"; then
    fail "an inline program that merely mentions hermes must not identify as hermes"
  fi
  if fm_hermes_args_are_hermes "node /x/firstmate-hermes/y.js --hermes"; then
    fail "a node process with hermes in its arguments must not identify as hermes"
  fi
  pass "hermes identity accepts only its three structural shapes, never a hermes-named path"
}

test_identity_from_a_live_process() {
  local pid verdict
  "$PYTHON_BIN" -I -c 'import time, sys
# hermes_cli.main import main
time.sleep(30)' &
  pid=$!
  sleep 0.3
  fm_hermes_pid_is_hermes "$pid" || { kill "$pid"; fail "a live interpreter running the bootstrap needle must identify as hermes"; }
  verdict=$("$HARNESS" ancestry "$pid")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$verdict" = "args hermes" ] || fail "ancestry must report 'args hermes' for a live Hermes interpreter, got '$verdict'"
  pass "fm-harness.sh ancestry identifies a live Hermes interpreter at args strength"
}

test_marker_precedence() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/marker")
  fm_fake_blind_ancestry "$fakebin"
  out=$(PATH="$fakebin:$BASE_PATH" HERMES_AGENT=true CLAUDECODE=1 "$HARNESS")
  [ "$out" = hermes ] || fail "HERMES_AGENT must outrank an inherited CLAUDECODE, got '$out'"
  out=$(PATH="$fakebin:$BASE_PATH" HERMES_AGENT=true "$HARNESS")
  [ "$out" = hermes ] || fail "HERMES_AGENT alone must detect hermes, got '$out'"
  out=$(PATH="$fakebin:$BASE_PATH" HERMES_AGENT=1 "$HARNESS")
  [ "$out" = unknown ] || fail "only the exact HERMES_AGENT=true marker counts, got '$out'"
  out=$(PATH="$fakebin:$BASE_PATH" HERMES_AGENT=true CURSOR_AGENT=1 "$HARNESS")
  [ "$out" = cursor ] || fail "cursor's marker still outranks HERMES_AGENT, got '$out'"
  out=$(PATH="$fakebin:$BASE_PATH" FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=hermes "$HARNESS")
  [ "$out" = hermes ] || fail "the supervision-branch primary pin must accept hermes, got '$out'"
  pass "HERMES_AGENT=true detects hermes ahead of CLAUDECODE, and hermes is a valid primary pin"
}

test_process_classification() {
  local out
  out=$(fm_agent_process_classify "/opt/python3" "/opt/python3" "python3 -I -c import os from hermes_cli.main import main")
  [ "$out" = agent ] || fail "a Hermes interpreter pane must classify as agent, got '$out'"
  out=$(fm_agent_process_classify "/opt/python3" "/opt/python3" "python3 /x/firstmate-hermes/bin/fm-mail.py")
  [ "$out" = other ] || fail "an unrelated interpreter must stay other, got '$out'"
  fm_harness_process_matches "/opt/python3" "python3 -I -c from hermes_cli.main import main chat -q fix claude hooks" \
    || fail "the session lock must accept a Hermes interpreter as a harness"
  [ "$FM_HARNESS_IS_CLAUDE" = 0 ] || fail "a Hermes brief mentioning claude must not mark the lock owner as Claude"
  pass "liveness and session-lock identity accept Hermes without letting its brief text rename it"
}

# --- 2. plugin installer ----------------------------------------------------------

make_fake_hermes() {  # <fakebin> <enabled-list-file>
  cat > "$1/hermes" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$2.calls"
case "\$1 \$2" in
  'config get') cat "$2" 2>/dev/null; exit 0 ;;
  'plugins enable') printf '  - %s\n' "\$3" >> "$2"; exit 0 ;;
  'plugins disable') : > "$2"; exit 0 ;;
  'config set') exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/hermes"
}

test_plugin_installer_states() {
  local dir fakebin enabled hh out
  dir="$TMP_ROOT/installer"
  fakebin=$(fm_fakebin "$dir")
  enabled="$dir/enabled"
  hh="$dir/hermes-home"
  : > "$enabled"
  make_fake_hermes "$fakebin" "$enabled"
  out=$(PATH="$BASE_PATH" HERMES_HOME="$hh" FM_HERMES_BIN="$dir/nonexistent-hermes" "$PLUGIN" status || true)
  [ "$out" = no-hermes ] || fail "status without a hermes executable must be no-hermes, got '$out'"
  out=$(PATH="$fakebin:$BASE_PATH" HERMES_HOME="$hh" "$PLUGIN" status || true)
  [ "$out" = missing ] || fail "status before install must be missing, got '$out'"
  PATH="$fakebin:$BASE_PATH" HERMES_HOME="$hh" "$PLUGIN" install >/dev/null || fail "install must succeed"
  cmp -s "$ROOT/.hermes/plugins/firstmate/__init__.py" "$hh/plugins/firstmate/__init__.py" || fail "install did not copy the tracked loader"
  grep -Fxq "$(cd "$ROOT" && pwd -P)" "$hh/plugins/firstmate/roots" || fail "install did not register this root"
  grep -q 'plugins enable firstmate' "$enabled.calls" || fail "install did not enable through Hermes's own command"
  grep -q 'config set plugins.entries.firstmate.allow_gateway_injection true' "$enabled.calls" \
    || fail "install did not grant the TUI injection through Hermes's own command"
  out=$(PATH="$fakebin:$BASE_PATH" HERMES_HOME="$hh" "$PLUGIN" status)
  [ "$out" = ok ] || fail "status after install must be ok, got '$out'"
  PATH="$fakebin:$BASE_PATH" HERMES_HOME="$hh" "$PLUGIN" install >/dev/null || fail "a repeat install must be idempotent"
  [ "$(grep -c . "$hh/plugins/firstmate/roots")" = 1 ] || fail "a repeat install registered the root twice"
  printf '# drift\n' >> "$hh/plugins/firstmate/__init__.py"
  out=$(PATH="$fakebin:$BASE_PATH" HERMES_HOME="$hh" "$PLUGIN" status || true)
  [ "$out" = stale ] || fail "a drifted installed loader must read stale, got '$out'"
  cp "$ROOT/.hermes/plugins/firstmate/__init__.py" "$hh/plugins/firstmate/__init__.py"
  PATH="$fakebin:$BASE_PATH" HERMES_HOME="$hh" "$PLUGIN" unregister >/dev/null
  out=$(PATH="$fakebin:$BASE_PATH" HERMES_HOME="$hh" "$PLUGIN" status || true)
  [ "$out" = unregistered ] || fail "status after unregister must be unregistered, got '$out'"
  : > "$enabled"
  out=$(PATH="$fakebin:$BASE_PATH" HERMES_HOME="$hh" "$PLUGIN" status || true)
  [ "$out" = disabled ] || fail "status with the plugin not enabled must be disabled, got '$out'"
  PATH="$fakebin:$BASE_PATH" HERMES_HOME="$hh" "$PLUGIN" uninstall >/dev/null
  [ ! -e "$hh/plugins/firstmate" ] || fail "uninstall left the loader directory behind"
  pass "fm-hermes-plugin.sh reports no-hermes, missing, ok, stale, unregistered, and disabled, and installs idempotently"
}

# --- 3. spawn ------------------------------------------------------------------------

make_spawn_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  has-session|new-session|new-window|kill-window|list-windows) exit 0 ;;
  send-keys)
    literal= prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    case "$literal" in
      ". '"*"'") staged=${literal#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || literal=$(cat "$staged") ;;
    esac
    case "$literal" in *"chat --cli"*) printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG" ;; esac
    exit 0
    ;;
  capture-pane) printf '☤ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> <id> <plugin-status>
  local name=$1 id=$2 status=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  # The fake hermes answers only the enabled-list read bin/fm-hermes-plugin.sh
  # makes; the agent itself must never start during a spawn test.
  cat > "$fakebin/hermes" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "config get plugins.enabled" ]; then printf '  - firstmate\n'; exit 0; fi
echo "fake hermes must never execute during a spawn test" >&2
exit 9
SH
  chmod +x "$fakebin/hermes"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  if [ "$status" = ok ]; then
    mkdir -p "$home/.hermes/plugins/firstmate"
    cp "$ROOT/.hermes/plugins/firstmate/__init__.py" "$ROOT/.hermes/plugins/firstmate/plugin.yaml" "$home/.hermes/plugins/firstmate/"
  fi
  printf '# Task\n## Captain'"'"'s intent\nExercise Hermes dispatch.\n\n## Firstmate spec\nVerify launch.\n' > "$home/data/$id/brief.md"
  printf 'hermes\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <record> <id> [args...]
  local case_dir home proj wt fakebin id=$2
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$1
EOF
  shift 2
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness hermes --mode no-mistakes --yolo off "$@" 2>&1
}

test_spawn_launch_shape() {
  local id rec out rc launch home gen
  id="hermes-launch-$$"
  rec=$(make_spawn_case launch "$id" ok)
  out=$(run_spawn "$rec" "$id" --model anthropic/claude-sonnet-5 --effort high)
  rc=$?
  expect_code 0 "$rc" "hermes spawn should succeed: $out"
  IFS='|' read -r _ home _ _ _ <<EOF
$rec
EOF
  launch=$(cat "$TMP_ROOT/launch/launch.log")
  assert_contains "$launch" "chat --cli --yolo" "hermes launch did not pin the classic CLI with --yolo"
  assert_contains "$launch" "--model 'anthropic/claude-sonnet-5'" "hermes launch did not carry the model"
  assert_contains "$launch" "--reasoning 'high'" "hermes launch did not carry the effort as --reasoning"
  assert_contains "$launch" '-q "$(' "hermes launch did not seed the brief with -q"
  assert_contains "$launch" "encode launch-brief" "hermes launch did not encode the brief as a launch-brief"
  assert_contains "$launch" "FM_HERMES_ROLE=worker" "hermes launch did not select the plugin's worker role"
  assert_contains "$launch" "-u HERMES_AGENT" "hermes launch did not clear an inherited HERMES_AGENT"
  assert_contains "$launch" "-u CLAUDECODE" "hermes launch did not clear the inherited Claude marker"
  gen=$(cat "$home/state/$id.busy-gen")
  assert_contains "$launch" "FM_HERMES_BUSY_GEN='$gen'" "hermes launch did not hand the armed busy gen to the plugin"
  assert_contains "$launch" "FM_HERMES_TURNEND=" "hermes launch did not hand the turn-ended marker to the plugin"
  assert_contains "$launch" "FM_HERMES_TASK='$id'" "hermes launch did not name its task"
  assert_not_contains "$launch" "__HERMES" "hermes launch left a placeholder unsubstituted"
  assert_grep 'harness=hermes' "$home/state/$id.meta" "hermes meta did not record its harness"
  assert_grep 'state=busy' "$home/state/$id.busy-state" "hermes spawn did not seed the busy record"
  pass "fm-spawn: hermes launch pins the classic CLI, carries model, effort, and brief, and wires the worker plugin"
}

test_spawn_refuses_without_the_plugin() {
  local id rec out rc
  id="hermes-noplugin-$$"
  rec=$(make_spawn_case noplugin "$id" missing)
  out=$(run_spawn "$rec" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "hermes spawn without a usable plugin must refuse"
  assert_contains "$out" "bin/fm-hermes-plugin.sh install" "the refusal must name the captain's install command"
  [ ! -s "$TMP_ROOT/noplugin/launch.log" ] || fail "a refused hermes spawn still launched"
  pass "fm-spawn: hermes refuses before launch when the Firstmate plugin is not usable"
}

# --- 4. control, busy, composer ---------------------------------------------------

test_control_tables() {
  [ "$(fm_control_harness_family hermes)" = hermes ] || fail "hermes family"
  if fm_control_harness_family hermes-extra >/dev/null; then fail "hermes family must be exact"; fi
  fm_control_harness_supported hermes || fail "hermes must have verified control mechanics"
  fm_control_harness_supports_kind hermes secondmate || fail "hermes must be secondmate-capable"
  [ "$(fm_control_interrupt_key hermes)" = C-c ] || fail "hermes interrupts with Ctrl+C"
  [ "$(fm_control_interrupt_repeat hermes)" = 1 ] || fail "hermes interrupts on a single press"
  [ "$(fm_control_exit_command hermes)" = /quit ] || fail "hermes exits with /quit"
  fm_control_interrupt_exits_idle hermes || fail "hermes's idle Ctrl+C exits, so its interrupt must be busy-gated"
  if fm_control_interrupt_exits_idle claude; then fail "only adapters whose idle key exits are busy-gated"; fi
  pass "control tables: hermes interrupts on one Ctrl+C gated on a running turn and exits with /quit"
}

test_busy_trust_and_launch_prompts() {
  case " $(fm_busy_sources_for_harness hermes) " in
    *" hermes-plugin fm-spawn "*) ;;
    *) fail "hermes must trust the hermes-plugin writer and the firstmate-owned sources" ;;
  esac
  printf 'This model costs a lot.\nUse this model for this invocation? [y/N] \n' | fm_busy_launch_prompt_parked hermes \
    || fail "the paid-model confirmation must read as a parked launch prompt"
  printf 'Hermes is about to register a shell hook that will run a\nAllow this hook to run? [y/N]: \n' | fm_busy_launch_prompt_parked hermes \
    || fail "the shell-hook consent must read as a parked launch prompt"
  if printf 'Allow this hook to run? [y/N]: \n' | fm_busy_launch_prompt_parked hermes; then
    fail "the hook question alone, without its own framing line, must not match"
  fi
  pass "busy state trusts hermes-plugin and recognizes Hermes's two parked launch prompts"
}

test_composer_signatures() {
  printf '☤ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel\0' | fm_busy_lines_match hermes \
    || fail "the running-turn hint row must read busy for hermes"
  printf '❯ Plan a feature, then build it step by step\0' | fm_busy_lines_match hermes \
    && fail "an idle placeholder must not read busy"
  printf '☤ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel\0' | fm_busy_lines_match '' \
    || fail "the harness-less union must include the hermes busy hint"
  printf "What changed in this repo recently?\n" | grep -qiE "$FM_COMPOSER_IDLE_RE_DEFAULT" \
    || fail "a Hermes placeholder must be an idle placeholder"
  if printf 'fix the failing test\n' | grep -qiE "$FM_COMPOSER_IDLE_RE_DEFAULT"; then
    fail "typed text must not match the idle placeholders"
  fi
  pass "composer: the Hermes busy hint and rotating placeholders are recognized, typed text is not"
}

# --- 5. supervision ----------------------------------------------------------------

test_supervision_rendering() {
  local out
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness hermes)
  assert_contains "$out" "primary harness: hermes" "the block did not name hermes"
  assert_contains "$out" "Mode: Hermes firstmate plugin background wake." "the hermes protocol was not rendered"
  assert_contains "$out" "$ROOT/.hermes/firstmate" "the plugin path placeholder was not substituted"
  assert_not_contains "$out" "__FM_" "a placeholder survived rendering"
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness hermes --repair-line)
  assert_contains "$out" "fm_watch_arm_hermes" "the repair line did not name the Hermes repair tool"
  out=$(env -u FM_SUPERVISION_MODEL FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=hermes \
    bash -c ". '$ROOT/bin/fm-wake-lib.sh'; fm_supervision_model")
  [ "$out" = extension ] || fail "a Hermes primary must use the extension supervision model, got '$out'"
  pass "supervision block renders the Hermes protocol and repair line, and Hermes uses the extension model"
}

test_extension_ownership_proof() {
  local root state pid
  root="$TMP_ROOT/proof"
  state="$root/state"
  mkdir -p "$state" "$root/.hermes"
  cp -R "$ROOT/.hermes/firstmate" "$root/.hermes/firstmate"
  sleep 30 &
  pid=$!
  printf '%s\n' "$pid" > "$state/.lock"
  # shellcheck disable=SC2016
  bash -c '. "$1/bin/fm-wake-lib.sh"
    v1=$(fm_pi_extension_version "$2/.hermes/firstmate/fm_hermes_watch.py")
    v2=$(fm_pi_extension_version "$2/.hermes/firstmate/fm_hermes_guard.py")
    printf "%s\n%s\n" "$v1" "$4" > "$3/.hermes-watch-plugin-loaded"
    printf "%s\n%s\n" "$v2" "$4" > "$3/.hermes-turnend-plugin-loaded"' _ "$ROOT" "$root" "$state" "$pid"
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_extension_owns_supervision "$2" "$3"' _ "$ROOT" "$state" "$root" \
    || { kill "$pid"; fail "matching Hermes markers bound to the live lock owner must prove extension ownership"; }
  printf 'sha256:stale\n%s\n' "$pid" > "$state/.hermes-watch-plugin-loaded"
  if bash -c '. "$1/bin/fm-wake-lib.sh"; fm_extension_owns_supervision "$2" "$3"' _ "$ROOT" "$state" "$root"; then
    kill "$pid"; fail "a stale Hermes watch build must not prove ownership"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "the Hermes plugin pair proves extension ownership only at current builds bound to the live lock owner"
}

test_identity_rules
test_identity_from_a_live_process
test_marker_precedence
test_process_classification
test_plugin_installer_states
test_spawn_launch_shape
test_spawn_refuses_without_the_plugin
test_control_tables
test_busy_trust_and_launch_prompts
test_composer_signatures
test_supervision_rendering
test_extension_ownership_proof
