#!/usr/bin/env bash
# Behavior tests for the verified Polytoken CLI crewmate/scout adapter.
#
# The facts pinned here are the ones a polytoken release could silently change
# and the ones a wrong guess would make dangerous:
#   1. polytoken publishes no harness-identity marker, so detection is
#      ancestry alone on the anchored process name `polytoken` (a shell tool
#      subprocess's parent IS the session daemon, verified live on 0.8.19),
#      and a structural polytoken ancestor outranks a retained CLAUDECODE.
#   2. The launch is the captain-approved TUI-pane-plus-REST hybrid: the brief
#      rides `--prompt`, the worker role contract rides the generated facet,
#      the unattended permission posture rides the generated config dir's
#      enforced `default_permission_matcher: bypass` (a project config.yaml
#      fully replaces the global config, so nothing else can carry it), and
#      `--accept-license-terms` is NEVER passed - the license dialog is a
#      blocker the readiness gate fails loudly on, not something the fleet
#      answers.
#   3. Hook handlers receive no argv (verified live), so the busy wiring is a
#      generated self-contained script; a failing hook breaks the turn
#      (verified live), so the script is failure-tolerant and always exits 0;
#      the busy open/close pair is pre_user_prompt/pre_model_turn open and
#      stop close, never post_model_turn (which fires mid-turn between tool
#      phases, verified live).
#   4. A REST-cancelled turn emits no stop hook (verified live), so the
#      control plane writes the busy close itself, and the interrupt transport
#      is REST-only: the TUI has no interrupt chord, so no interrupt key may
#      ever be improvised for polytoken.
#   5. The effort axis rides the model reference as `<model>(<effort>)` only
#      when that form is listed (record-and-omit otherwise), and an unlisted
#      base model on a reachable listing refuses the spawn.
#   6. Enter while a turn runs queues the text, so the busy-queued Enter
#      conversion applies, and the composer is the verified separated shape:
#      an idle polytoken proves an empty composer and a working one keeps the
#      strict unknown through the identity conjunction.
#   7. polytoken is a crewmate/scout adapter only: a secondmate launch is
#      refused, and a worktree that already carries a project polytoken hook
#      layer is refused rather than clobbered.
#
# The fake plumbing variables carry the PTFAKE_ prefix deliberately: the
# launch command under test clears every ORCA_*/FM_* name the pane carries,
# and the fakes must survive inside the subshell that runs that command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS FM_TASK_ID FM_TASK_INBOX

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-polytoken-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-polytoken-harness)

CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
RULE=$(printf '%.0s─' $(seq 1 24))

# ---------------------------------------------------------------------------
# Detection

test_polytoken_ancestry_detects_the_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/polytoken'; exit 0 ;;
  *"args="*) printf '%s\n' 'polytoken --config-dir /tmp/x new'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = polytoken ] \
    || fail "a natively-named polytoken command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named polytoken command"
}

test_polytoken_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FAKE_PS_COMM=mypolytokentool FAKE_PS_ARGS='mypolytokentool --serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != polytoken ] \
    || fail "an unrelated mypolytokentool command must not detect polytoken, got '$out'"
  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "echo polytoken --help"' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != polytoken ] \
    || fail "a later shell argument naming polytoken must not detect polytoken, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated polytoken mentions"
}

test_polytoken_claims_no_inherited_launcher_marker() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-claude")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' polytoken; exit 0 ;;
  *"args="*) printf '%s\n' 'polytoken --config-dir /tmp/x new'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  # AGENT=1 was observed reaching a real polytoken worker's tool subprocess
  # (verified live), so it must never promote to a polytoken identity when no
  # polytoken ancestry exists.
  out=$(AGENT=1 "$HARNESS")
  [ "$out" != polytoken ] \
    || fail "an inherited AGENT=1 with no polytoken ancestry must not claim polytoken, got '$out'"
  # A structural polytoken ancestor outranks a retained CLAUDECODE, so a
  # cleared launch boundary is defense in depth rather than the only guard.
  out=$(AGENT=1 CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = polytoken ] \
    || fail "a structural polytoken ancestor must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: no inherited launcher marker claims the polytoken identity"
}

# ---------------------------------------------------------------------------
# Control-plane tables

test_polytoken_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported polytoken || fail "polytoken must be a supported control harness"
  [ "$(fm_control_harness_family polytoken)" = polytoken ] || fail "polytoken must map to its own family"
  fm_control_harness_supports_kind polytoken scout || fail "polytoken must run scouts"
  fm_control_harness_supports_kind polytoken ship || fail "polytoken must run ships"
  fm_control_harness_supports_kind polytoken secondmate \
    && fail "polytoken must refuse secondmates" || true
  [ "$(fm_control_interrupt_transport polytoken)" = rest ] \
    || fail "polytoken's interrupt must ride the REST transport"
  [ "$(fm_control_interrupt_transport claude)" = key ] \
    || fail "the keyplane harnesses must keep the key transport"
  fm_control_interrupt_key polytoken >/dev/null 2>&1 \
    && fail "polytoken has no interrupt key, so the key table must refuse it" || true
  fm_control_interrupt_repeat polytoken >/dev/null 2>&1 \
    && fail "polytoken has no interrupt key repeat" || true
  fm_control_interrupt_clear_key polytoken >/dev/null 2>&1 \
    && fail "polytoken has no composer-clear key" || true
  [ -z "$(fm_control_interrupt_hazard_signal polytoken)" ] \
    || fail "polytoken must have no interrupt hazard surface"
  [ "$(fm_control_exit_command polytoken)" = /quit ] \
    || fail "polytoken must exit on /quit"
  pass "fm-control-lib: polytoken mechanics are REST interrupt, /quit exit, no secondmates"
}

test_polytoken_wiring_tables_cover_every_generated_artifact() {
  local wt="$TMP_ROOT/wiring-wt" state="$TMP_ROOT/wiring-state" id=polytoken-wiring
  local files dirs
  mkdir -p "$wt" "$state"
  fm_polytoken_write_facet "$wt" "$state/$id.inbox" || fail "the facet writer should succeed"
  fm_polytoken_write_hooks "$wt" "$(fm_polytoken_busy_script "$state" "$id")" \
    || fail "the hook writer should succeed"
  files=$(fm_control_harness_wiring_paths polytoken "$wt" "$state" "$id")
  dirs=$(fm_control_harness_wiring_dirs polytoken "$state" "$id")
  assert_contains "$files" "$wt/.polytoken/hooks.json" "the worktree hook layer must be retired on relaunch"
  assert_contains "$files" "$wt/.polytoken/facets/firstmate-worker.md" "the worker facet must be retired on relaunch"
  assert_contains "$files" "$state/$id.polytoken-busy.sh" "the generated busy writer must be retired on relaunch"
  assert_contains "$dirs" "$state/$id.polytoken-config" "the per-task config dir must be retired on relaunch"
  assert_contains "$dirs" "$state/$id.polytoken-sessions" "the per-task sessions root must be retired on relaunch"
  assert_contains "$dirs" "$state/$id.polytoken-sessions-v1" "the versioned sessions sibling must be retired on relaunch"
  printf '[{"name":"project-own","event":"stop","handler":{"bash":"/bin/true"}}]\n' \
    > "$wt/.polytoken/hooks.json"
  printf -- '---\nname: firstmate-worker\n---\nproject facet\n' \
    > "$wt/.polytoken/facets/firstmate-worker.md"
  files=$(fm_control_harness_wiring_paths polytoken "$wt" "$state" "$id")
  assert_not_contains "$files" "$wt/.polytoken/hooks.json" \
    "a project's own hook layer must never be named for retirement"
  assert_not_contains "$files" "$wt/.polytoken/facets/firstmate-worker.md" \
    "a facet firstmate did not generate for this task must never be named for retirement"
  assert_contains "$files" "$state/$id.polytoken-busy.sh" "the busy writer stays retirable"
  pass "fm-control-lib: polytoken wiring tables name every generated artifact and no project file"
}

test_polytoken_tmux_names_the_native_binary_an_agent() {
  local got
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  got=$(fm_agent_process_classify_name polytoken)
  [ "$got" = agent ] || fail "tmux liveness must read the polytoken binary as an agent, got '$got'"
  got=$(fm_agent_process_classify_name mypolytokentool)
  [ "$got" = other ] || fail "tmux liveness must not read mypolytokentool as an agent, got '$got'"
  got=$(fm_agent_process_classify_name bash)
  [ "$got" = shell ] || fail "tmux liveness must still read bash as a shell, got '$got'"
  pass "bin/fm-agent-process-lib.sh: polytoken is an agent, fragments are not"
}

# ---------------------------------------------------------------------------
# Busy and composer contracts

test_polytoken_busy_sources_are_the_verified_pair() {
  local trusted
  trusted=$(fm_busy_sources_for_harness polytoken)
  assert_contains "$trusted" "polytoken-hook" "polytoken must trust its hook source"
  assert_contains "$trusted" "fm-spawn" "polytoken must trust the launch seed"
  assert_contains "$trusted" "fm-interrupt" "polytoken must trust the control-written close"
  fm_busy_source_trusted polytoken polytoken-hook || fail "polytoken-hook must be trusted for polytoken"
  fm_busy_source_trusted claude polytoken-hook \
    && fail "polytoken-hook must never classify a claude task" || true
  pass "fm-busy-lib: the polytoken-hook source is scoped to polytoken tasks"
}

test_polytoken_busy_footer_needs_the_pinned_running_row() {
  printf 'Running for 3.03s\n' | fm_busy_lines_match polytoken \
    || fail "the pinned Running-for row must read busy"
  printf ' Running for 31.37s   more\n' | fm_busy_lines_match polytoken \
    || fail "the leading-space form with trailing furniture must read busy"
  printf 'Completed in 5.60s\n' | fm_busy_lines_match polytoken \
    && fail "the turn-end Completed row must not read busy" || true
  printf 'Errored after 0.04s\n' | fm_busy_lines_match polytoken \
    && fail "the error row must not read busy" || true
  printf 'Canceled after 5.03s\n' | fm_busy_lines_match polytoken \
    && fail "the canceled row must not read busy" || true
  printf 'worker output: Running for a while in my log\n' | fm_busy_lines_match polytoken \
    && fail "unanchored prose naming the token must not read busy" || true
  printf 'Running for 3.03s\n' | fm_busy_lines_match claude \
    && fail "harness=claude must never borrow polytoken's token" || true
  printf 'Running for 3.03s\n' | fm_busy_lines_match '' \
    || fail "the harness-less union must acknowledge a polytoken busy row"
  pass "fm-composer-lib: only the pinned Running-for row carries the polytoken busy verdict"
}

test_polytoken_composer_is_the_verified_separated_shape() {
  local transcript out
  transcript=$'conversation line\n'
  local pair typed footer poly_idle poly_working
  pair=$(printf '%s\n%s\n%s' "$RULE" '' "$RULE")
  typed=$(printf '%s\n%s\n%s' "$RULE" 'typed but not submitted' "$RULE")
  footer=$(printf '\n /w  facet: firstmate-worker   model: zai/glm-5.3-flash(high)   perms: bypass   97%% context left')
  poly_idle=$(printf 'polytoken\tidle')
  poly_working=$(printf 'polytoken\tworking')
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$transcript$pair$footer" 2 "$poly_idle")
  [ "$out" = empty ] || fail "an idle polytoken separated composer must read empty, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$transcript$pair$footer" 2 "$poly_working")
  [ "$out" = unknown ] || fail "a working polytoken must keep the strict unknown, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$transcript$typed" 2 "$poly_idle")
  [ "$out" = pending ] || fail "typed text in the polytoken composer must read pending, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$transcript$typed" 2 "$poly_working")
  [ "$out" = pending ] || fail "typed text mid-turn must still read pending, got '$out'"
  # The stale-shell protection: a blank separated row with no live polytoken
  # identity stays unknown, so a dead pane never fabricates an empty verdict.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$transcript$pair$footer" 2 probe-absent)
  [ "$out" = unknown ] || fail "a separated shape with no live owner must read unknown, got '$out'"
  # An unverified owner name must not borrow the separated shape.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$transcript$pair$footer" 2 "$(printf 'grok\tidle')")
  [ "$out" = unknown ] || fail "an unverified owner must not borrow the separated shape, got '$out'"
  pass "fm-composer-lib: the polytoken separated shape reads empty, pending, and unknown exactly"
}

test_polytoken_busy_queued_enter_converts_like_opencode() {
  [ "$(fm_composer_queued_enter_verdict pending busy)" = empty ] \
    || fail "a busy-submit Enter that queues the text must read empty"
  [ "$(fm_composer_queued_enter_verdict pending idle)" = pending ] \
    || fail "an idle pane that still shows the text must read pending"
  [ "$(fm_composer_queued_enter_verdict empty busy)" = empty ] \
    || fail "a proven empty composer must read empty whatever the busy state"
  pass "fm-composer-lib: the queued-Enter conversion covers polytoken's verified queue behavior"
}

# ---------------------------------------------------------------------------
# Generated wiring (the real generation, asserted on its outputs)

make_wiring_case() {  # <name>
  local name=$1
  local case_dir="$TMP_ROOT/wiring-$name"
  mkdir -p "$case_dir/home/.config/polytoken" "$case_dir/state" "$case_dir/wt"
  printf '%s\n' "$case_dir"
}

test_polytoken_write_config_enforces_the_unattended_posture() {
  local rec case_dir home cfgdir mirrored out rc
  rec=$(make_wiring_case config)
  case_dir=$rec
  home="$case_dir/home"
  cfgdir="$case_dir/state/task.polytoken-config"
  printf 'version: 4\nproviders:\n  zai:\n    auth:\n      type: static_key\n      key: k\nmodels:\n  zai/glm-5.3-flash:\n    enabled: true\ndefault_permission_matcher: standard\n' \
    > "$home/.config/polytoken/config.yaml"
  XDG_CONFIG_HOME="$home/.config" HOME="$home" fm_polytoken_write_config "$cfgdir" \
    || fail "a mirrorable global config must be mirrored"
  mirrored=$(cat "$cfgdir/config.yaml")
  assert_contains "$mirrored" "default_permission_matcher: bypass" \
    "a standard global posture must be enforced to bypass for the worker"
  assert_contains "$mirrored" "type: static_key" "the mirrored providers must survive"
  # bypass_plus is the one strictly-safer value that is preserved.
  printf 'version: 4\ndefault_permission_matcher: bypass_plus\n' > "$home/.config/polytoken/config.yaml"
  rm -rf "$cfgdir"
  XDG_CONFIG_HOME="$home/.config" HOME="$home" fm_polytoken_write_config "$cfgdir" \
    || fail "a bypass_plus global config must be mirrored"
  mirrored=$(cat "$cfgdir/config.yaml")
  assert_contains "$mirrored" "default_permission_matcher: bypass_plus" \
    "the bypass_plus posture must be preserved, not flattened to bypass"
  # Quoted and commented YAML spellings of bypass_plus are the same value.
  for spelling in '"bypass_plus"' "'bypass_plus'" 'bypass_plus # keep deny rules'; do
    printf 'version: 4\ndefault_permission_matcher: %s\n' "$spelling" > "$home/.config/polytoken/config.yaml"
    rm -rf "$cfgdir"
    XDG_CONFIG_HOME="$home/.config" HOME="$home" fm_polytoken_write_config "$cfgdir" \
      || fail "a bypass_plus global config spelled $spelling must be mirrored"
    mirrored=$(cat "$cfgdir/config.yaml")
    assert_contains "$mirrored" "default_permission_matcher: $spelling" \
      "the bypass_plus posture spelled $spelling must be preserved, not flattened to bypass"
  done
  # An absent key is appended, not silently inherited: the project layer
  # fully replaces the global config, so nothing can be inherited.
  printf 'version: 4\n' > "$home/.config/polytoken/config.yaml"
  rm -rf "$cfgdir"
  XDG_CONFIG_HOME="$home/.config" HOME="$home" fm_polytoken_write_config "$cfgdir" \
    || fail "a global config without the matcher key must still be mirrored"
  mirrored=$(cat "$cfgdir/config.yaml")
  assert_contains "$mirrored" "default_permission_matcher: bypass" \
    "an absent matcher key must be appended as bypass"
  # A missing global config refuses rather than launching a worker with no
  # providers or credentials.
  rm -rf "$home/.config/polytoken" "$cfgdir"
  out=$(XDG_CONFIG_HOME="$home/.config" HOME="$home" fm_polytoken_write_config "$cfgdir" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a missing global config must refuse the mirror"
  assert_contains "$out" "polytoken global config" "the refusal must name the missing global config"
  pass "fm-polytoken-lib: the config mirror enforces the unattended posture"
}

test_polytoken_write_facet_carries_the_role_contract_without_a_model_pin() {
  local rec case_dir facet body
  rec=$(make_wiring_case facet)
  case_dir=$rec
  fm_polytoken_write_facet "$case_dir/wt" "$case_dir/state/task.inbox" \
    || fail "the worker facet must be generated"
  facet="$case_dir/wt/.polytoken/facets/firstmate-worker.md"
  [ -f "$facet" ] || fail "the facet must exist at the project facet layer path"
  body=$(cat "$facet")
  assert_contains "$body" "name: firstmate-worker" "the facet must be the firstmate-worker facet"
  assert_contains "$body" "tools_deny: [switch_facet, subagent, message_subagent]" \
    "the facet must deny facet switching and delegation at the tool-registry level"
  assert_contains "$body" 'transclude("polytoken://system_prompts/facet.md")' \
    "the facet must transclude the shipped base prompt to keep the tool-use framing"
  assert_contains "$body" "You are a crewmate" "the facet must carry the crewmate identity"
  assert_contains "$body" "$case_dir/state/task.inbox" \
    "the facet must name this task's instruction inbox path"
  assert_contains "$body" "does not grant merge, destructive, security-sensitive" \
    "the facet must carry the task-channel trust statement's authority boundary"
  # A facet model pin outranks the launch --model, so the worker facet must
  # never carry one.
  if printf '%s\n' "$body" | grep -qE '^  model:'; then
    fail "the worker facet must not pin a model"
  fi
  pass "fm-polytoken-lib: the worker facet carries the role contract and no model pin"
}

test_polytoken_busy_writer_dispatches_without_argv_and_never_fails() {
  local rec case_dir script state_real id gen turnend out
  rec=$(make_wiring_case busywriter)
  case_dir=$rec
  state_real="$case_dir/state"
  id=task
  turnend="$state_real/$id.turn-ended"
  mkdir -p "$state_real"
  "$ROOT/bin/fm-busy-event.sh" arm "$state_real" "$id" >/dev/null || fail "the busy contract must arm"
  gen=$(fm_busy_current_gen "$state_real" "$id") || fail "the armed generation must be readable"
  fm_polytoken_write_busy_script "$ROOT" "$state_real" "$id" "$gen" "$turnend" \
    || fail "the busy writer must be generated"
  script=$(fm_polytoken_busy_script "$state_real" "$id")
  [ -f "$script" ] || fail "the busy writer must live in state, not the worktree"
  # pre_user_prompt opens the turn: the script is invoked with the event on
  # the environment and no arguments, exactly as a polytoken hook handler is.
  POLYTOKEN_HOOK_EVENT=pre_user_prompt "$script" \
    || fail "the busy writer must exit 0 on the open events"
  out=$(fm_busy_record_read "$state_real" "$id") || fail "the record must be readable after the open"
  assert_contains "$out" "busy polytoken-hook" "the open event must be recorded from polytoken-hook"
  # pre_model_turn also opens (the pair is open on both).
  POLYTOKEN_HOOK_EVENT=pre_model_turn "$script" || true
  # stop closes the turn and touches the turn-ended notification marker.
  POLYTOKEN_HOOK_EVENT=stop "$script" || fail "the busy writer must exit 0 on stop"
  out=$(fm_busy_record_read "$state_real" "$id")
  assert_contains "$out" "idle polytoken-hook" "the stop event must close the record"
  [ -f "$turnend" ] || fail "stop must touch the turn-ended notification marker"
  # The unwired events must be inert, and the writer must tolerate being run
  # with no event at all (a hook error breaks the whole turn, verified live).
  POLYTOKEN_HOOK_EVENT=post_model_turn "$script" || fail "an unwired event must still exit 0"
  POLYTOKEN_HOOK_EVENT='' "$script" || fail "an empty event must still exit 0"
  "$script" || fail "a no-event invocation must still exit 0"
  out=$(fm_busy_record_read "$state_real" "$id")
  assert_contains "$out" "idle polytoken-hook" "the unwired events must not rewrite the record"
  pass "fm-polytoken-lib: the no-argv busy writer opens, closes, and never fails"
}

test_polytoken_write_hooks_binds_the_three_events() {
  local rec case_dir hooks script out rc
  rec=$(make_wiring_case hooks)
  case_dir=$rec
  script="$case_dir/state/task.polytoken-busy.sh"
  : > "$script"
  fm_polytoken_write_hooks "$case_dir/wt" "$script" \
    || fail "the worktree hook layer must be generated"
  hooks="$case_dir/wt/.polytoken/hooks.json"
  [ -f "$hooks" ] || fail "the hook layer must exist in the worktree's .polytoken dir"
  node -e 'const j=require(process.argv[1]);if(!Array.isArray(j))process.exit(1);
const ev=j.map(h=>h.event).sort().join(",");if(ev!=="pre_model_turn,pre_user_prompt,stop")process.exit(2);
for(const h of j){if(/\s/.test(h.handler.bash))process.exit(3);
if(!h.handler.bash.startsWith("/"))process.exit(4);if(h.name.indexOf("!")===0)process.exit(5)}
console.log("ok")' "$hooks" >/dev/null \
    || fail "the hook layer must bind exactly the three verified events to the no-arg script path"
  # A project that already carries its own polytoken hook layer is refused,
  # never clobbered.
  out=$(fm_polytoken_write_hooks "$case_dir/wt" "$script" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an existing project hook layer must refuse the arm"
  assert_contains "$out" "not firstmate's to clobber" "the refusal must name the ownership boundary"
  pass "fm-polytoken-lib: the hook layer binds the three events and refuses to clobber"
}

# ---------------------------------------------------------------------------
# Model-reference validation

make_polytoken_fakebin() {  # <dir> -> the fakebin path
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/polytoken" <<SH
#!/usr/bin/env bash
set -u
log="\${PTFAKE_LOG:?}"
printf '%s\n' "\$*" >>"\$log"
subcmd=
prev=
for arg in "\$@"; do
  case "\$prev" in
    --config-dir) export PTFAKE_CFGDIR="\$arg" ;;
    --sessions-dir) export PTFAKE_SESSDIR="\$arg" ;;
  esac
  prev=\$arg
done
for arg in "\$@"; do
  case "\$arg" in
    print|new|sessions|reap) subcmd=\$arg; break ;;
    --sessions-dir)
      echo "error: unexpected argument '--sessions-dir' found" >&2
      exit 2
      ;;
  esac
done
case "\$subcmd" in
  print)
    [ "\${PTFAKE_MODELS_FAIL:-0}" = 1 ] && exit 3
    [ "\${PTFAKE_MODELS_HANG:-0}" = 1 ] && { sleep 30; exit 0; }
    printf '%s\n' 'zai/glm-5.3-flash'
    printf '%s\n' 'zai/glm-5.3-flash(none)'
    printf '%s\n' 'zai/glm-5.3-flash(low)'
    printf '%s\n' 'zai/glm-5.3-flash(high)'
    printf '%s\n' 'zai/glm-5.3-flash(max)'
    printf '%s\n' 'anthropic/claude-opus-5-5'
    exit 0
    ;;
  new)
    # Simulate the daemon's hook firing: the generated busy writer runs with
    # the event on the environment and no arguments, exactly as a real
    # handler does, unless the case pins the no-hook knob.
    if [ "\${PTFAKE_NO_HOOK:-0}" != 1 ] && [ -n "\${PTFAKE_CFGDIR:-}" ]; then
      state_dir=\$(dirname "\$PTFAKE_CFGDIR")
      task_id=\$(basename "\$PTFAKE_CFGDIR")
      task_id=\${task_id%.polytoken-config}
      writer="\$state_dir/\$task_id.polytoken-busy.sh"
      [ -f "\$writer" ] && POLYTOKEN_HOOK_EVENT=pre_user_prompt "\$writer" || true
    fi
    [ -n "\${PTFAKE_ENV_LOG:-}" ] && env >"\$PTFAKE_ENV_LOG"
    printf 'session_id=0czfake-echo port=49999\n'
    exit 0
    ;;
  sessions)
    printf '[{"session_id":"0czfake-echo","pid":12345,"port":49999,"project_path":"%s","credential_file_path":"%s","model":"zai/glm-5.3-flash"}]' \\
      "\${PTFAKE_PANE_PATH:?}" "\${PTFAKE_SESSDIR:?}-v1/0czfake-echo/credential.json"
    exit 0
    ;;
  reap)
    printf 'reaped\n'
    exit 0
    ;;
  *)
    echo "fake polytoken must never execute: \$*" >&2
    exit 9
    ;;
esac
SH
  chmod +x "$fakebin/polytoken"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

test_polytoken_model_ref_composes_and_refuses() {
  local fakebin out rc
  fakebin=$(make_polytoken_fakebin "$TMP_ROOT/models")
  export PTFAKE_LOG="$TMP_ROOT/models/polytoken.log"
  : > "$PTFAKE_LOG"
  out=$(fm_polytoken_model_ref "$fakebin/polytoken" zai/glm-5.3-flash low 2>/dev/null)
  [ "$out" = 'zai/glm-5.3-flash(low)' ] \
    || fail "a listed base with a listed effort must compose into the parenthesized ref, got '$out'"
  out=$(fm_polytoken_model_ref "$fakebin/polytoken" zai/glm-5.3-flash medium 2>/dev/null)
  [ "$out" = 'zai/glm-5.3-flash' ] \
    || fail "an effort outside the model's selectable set must be omitted from the ref, got '$out'"
  out=$(fm_polytoken_model_ref "$fakebin/polytoken" zai/glm-5.3-flash default 2>/dev/null)
  [ "$out" = 'zai/glm-5.3-flash' ] \
    || fail "a default effort axis must launch the bare model, got '$out'"
  out=$(fm_polytoken_model_ref "$fakebin/polytoken" default low 2>/dev/null)
  [ -z "$out" ] || fail "a default model axis must produce no ref, got '$out'"
  out=$(fm_polytoken_model_ref "$fakebin/polytoken" not/a-model low 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unlisted base model must refuse the spawn"
  assert_contains "$out" "not listed by 'polytoken print models'" \
    "the refusal must name the listing it checked"
  pass "fm-polytoken-lib: the model ref composes the effort axis and refuses unlisted models"
}

test_polytoken_model_ref_unreachable_listing_launches_unvalidated() {
  local fakebin out
  fakebin=$(make_polytoken_fakebin "$TMP_ROOT/models-unreachable")
  export PTFAKE_LOG="$TMP_ROOT/models-unreachable/polytoken.log"
  : > "$PTFAKE_LOG"
  out=$(PTFAKE_MODELS_FAIL=1 fm_polytoken_model_ref "$fakebin/polytoken" zai/glm-5.3-flash low 2>&1 >/dev/null)
  assert_contains "$out" "unvalidated" \
    "an unreachable listing must launch unvalidated with a notice"
  pass "fm-polytoken-lib: an unreachable listing establishes nothing and launches unvalidated"
}

# ---------------------------------------------------------------------------
# REST control core (a real local HTTP stub with typed answers)

rest_stub_start() {  # <dir> -> prints "port pid"
  local dir=$1
  cat > "$dir/stub.py" <<'PY'
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer

TURN = {"mode": os.environ.get("PTFAKE_STUB_MODE", "busy")}

class H(BaseHTTPRequestHandler):
    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _send(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _authed(self):
        return self.headers.get("Authorization") == "Bearer stub-token"

    def do_GET(self):
        if not self._authed():
            self._send(401, {"error": "unauthorized"})
            return
        if self.path == "/sync":
            turn = None if TURN["mode"] == "idle" else {"generation": 1, "phase": "starting"}
            self._send(200, {"turn": turn})
            return
        self._send(404, {"error": "no route"})

    def do_POST(self):
        if not self._authed():
            self._send(401, {"error": "unauthorized"})
            return
        if self.path == "/turn/cancel":
            self._body()
            if TURN["mode"] == "idle":
                self._send(409, {"error": "no turn in flight"})
                return
            TURN["mode"] = "idle"
            self._send(200, {"status": "cancel_requested", "generation": 1})
            return
        self._send(404, {"error": "no route"})

    def log_message(self, *args):
        pass

server = HTTPServer(("127.0.0.1", 0), H)
with open(os.environ["PTFAKE_STUB_PORT_FILE"], "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
  : > "$dir/port"
  PTFAKE_STUB_PORT_FILE="$dir/port" python3 "$dir/stub.py" &
  local pid=$!
  local i=0
  while [ ! -s "$dir/port" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$dir/port" ] || fail "the REST stub never reported its port"
  printf '%s %s\n' "$(cat "$dir/port")" "$pid"
}

test_polytoken_rest_interrupt_settles_the_turn() {
  local dir rec port pid token out rc
  rec=$(make_wiring_case rest)
  dir=$rec
  rest_stub_start "$dir" > "$dir/handle" || fail "the REST stub must start"
  read -r port pid < "$dir/handle"
  token=stub-token
  out=$(fm_polytoken_interrupt "$port" "$token" 8)
  [ "$out" = cancelled ] \
    || fail "a delivered cancel that settles the turn must report cancelled, got '$out'"
  # A second cancel with no turn in flight is the typed not-running outcome.
  out=$(fm_polytoken_interrupt "$port" "$token" 8)
  [ "$out" = not-running ] \
    || fail "a cancel with no turn in flight must report not-running, got '$out'"
  # A refused call (a bad token) must never read as delivered.
  out=$(fm_polytoken_interrupt "$port" not-the-token 2 2>/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unauthorized cancel must refuse rather than guess success"
  kill "$pid" 2>/dev/null || true
  pass "fm-polytoken-lib: the REST interrupt reports cancelled, not-running, and refuses unauthorized"
}

test_polytoken_turn_settled_reads_the_typed_sync_verdict() {
  local dir rec port pid token
  rec=$(make_wiring_case sync)
  dir=$rec
  rest_stub_start "$dir" > "$dir/handle" || fail "the REST stub must start"
  read -r port pid < "$dir/handle"
  token=stub-token
  fm_polytoken_turn_settled "$port" "$token" \
    && fail "a running turn must not read as settled" || true
  fm_polytoken_rest POST "$port" "$token" /turn/cancel '{}' \
    || fail "the cancel must be accepted"
  fm_polytoken_turn_settled "$port" "$token" \
    || fail "a cancelled turn must read as settled"
  kill "$pid" 2>/dev/null || true
  pass "fm-polytoken-lib: the typed settle postcondition follows GET /sync"
}

# ---------------------------------------------------------------------------
# The spawn flow through the real fm-spawn.sh with a fake backend

make_polytoken_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$home/.config/polytoken"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Polytoken dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'polytoken\n' > "$home/config/crew-harness"
  printf 'version: 4\nproviders:\n  zai:\n    auth:\n      type: static_key\n      key: k\nmodels:\n  zai/glm-5.3-flash:\n    enabled: true\ndefault_permission_matcher: standard\n' \
    > "$home/.config/polytoken/config.yaml"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fakebin=$(make_polytoken_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${PTFAKE_TMUX_LOG:?}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${PTFAKE_PANE_PATH:?}"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    literal=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        # The staged launch file is sourced for real, so the fake polytoken
        # actually runs, fires the generated busy writer exactly as the
        # daemon's hook would, and logs its own argv and environment for the
        # launch-content assertions. The pane shell is seeded with inherited
        # foreign markers so the launch boundary's clearing is observable.
        ". '"*)
          launch=${literal#". '"}
          launch=${launch%"'"}
          [ -f "$launch" ] || exit 0
          cat "$launch" >>"${PTFAKE_LAUNCH_LINE_LOG:?}"
          CLAUDECODE=1 ORCA_X=1 FM_FOO=1 FM_TASK_ID=seeded-task FM_TASK_INBOX=seeded-inbox \
            bash -c "$(cat "$launch")" >>"${PTFAKE_LAUNCH_STDOUT:-/dev/null}" 2>&1 || true
          ;;
      esac
      exit 0
    fi
    exit 0
    ;;
  capture-pane) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/launch-line.log"
  : > "$case_dir/tmux-calls.log"
  : > "$case_dir/launch-stdout.log"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_polytoken_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

run_polytoken_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" XDG_CONFIG_HOME="$home/.config" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PTFAKE_LOG="$case_dir/launch.log" \
    PTFAKE_TMUX_LOG="$case_dir/tmux-calls.log" \
    PTFAKE_PANE_PATH="$wt" \
    PTFAKE_LAUNCH_LINE_LOG="$case_dir/launch-line.log" \
    PTFAKE_LAUNCH_STDOUT="$case_dir/launch-stdout.log" \
    PTFAKE_ENV_LOG="$case_dir/polytoken-env.log" \
    PTFAKE_NO_HOOK="${PTFAKE_NO_HOOK:-0}" \
    FM_POLYTOKEN_READY_POLLS="${FM_POLYTOKEN_READY_POLLS:-40}" \
    FM_POLYTOKEN_POLL_INTERVAL="${FM_POLYTOKEN_POLL_INTERVAL:-0.1}" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness polytoken --mode no-mistakes --yolo off "$@" 2>&1
}

test_polytoken_launch_carries_the_hybrid_contract() {
  local id rec out rc launch raw meta cfg envlog
  id="pt-launch-z1-$$"
  rec=$(make_polytoken_spawn_case launch "$id")
  read_polytoken_spawn_record "$rec"
  out=$(run_polytoken_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model zai/glm-5.3-flash --effort low)
  rc=$?
  expect_code 0 "$rc" "polytoken spawn should succeed (output: $out)"
  # The raw launch line (what the pane shell was told to run) carries the
  # launch-boundary contract; the fake polytoken's argv (launch.log) carries
  # what the command actually received after the shell consumed the quoting.
  raw=$(cat "$CASE_DIR/launch-line.log")
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$raw" "--model 'zai/glm-5.3-flash(low)'" \
    "the launch line must carry the composed model reference"
  envlog="$CASE_DIR/polytoken-env.log"
  [ -s "$envlog" ] || fail "the fake polytoken must have recorded its launch environment"
  ! grep -q '^CLAUDECODE=' "$envlog" || fail "the launch must clear the inherited launcher marker"
  ! grep -q '^ORCA_X=' "$envlog" || fail "the launch must clear inherited ORCA_ markers"
  ! grep -q '^FM_FOO=' "$envlog" || fail "the launch must clear inherited FM_ markers"
  grep -qx 'FM_TASK_ID=seeded-task' "$envlog" || fail "the launch must keep the launch-owned FM_TASK_ID"
  grep -qx "FM_TASK_INBOX=.*/$id\.inbox" "$envlog" || fail "the launch must keep its own FM_TASK_INBOX export"
  assert_not_contains "$raw" "--accept-license-terms" \
    "the launch must never auto-accept the license terms"
  assert_not_contains "$raw" "__POLYTOKENBIN__" "the launch left its binary placeholder unsubstituted"
  assert_not_contains "$raw" "__MODELFLAG__" "the launch left its model placeholder unsubstituted"
  assert_not_contains "$raw" "__BRIEF__" "the launch left its brief placeholder unsubstituted"
  assert_contains "$launch" "--config-dir" "the launch must name the generated config dir"
  assert_contains "$launch" "$HOME_DIR/state/$id.polytoken-config" \
    "the launch must name this task's generated config dir"
  assert_contains "$launch" "--sessions-dir" "the launch must isolate the sessions root"
  assert_contains "$launch" "$HOME_DIR/state/$id.polytoken-sessions" \
    "the launch must name this task's sessions root"
  assert_contains "$launch" "new" "the launch must spawn a new daemon session"
  assert_contains "$launch" "--facet firstmate-worker" "the launch must select the worker facet"
  assert_contains "$launch" "--facets-dir" "the launch must name the worktree facets dir"
  assert_contains "$launch" "$WT_DIR/.polytoken/facets" "the facets dir must be the worktree's project layer"
  assert_contains "$launch" "--model zai/glm-5.3-flash(low)" \
    "the polytoken command must receive the composed model reference"
  assert_contains "$launch" "--prompt" "the launch must carry the brief via --prompt"
  assert_contains "$launch" "Exercise Polytoken dispatch" \
    "the brief text must ride the --prompt argument"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=polytoken' "$meta" "the meta did not record its harness"
  assert_grep 'model=zai/glm-5.3-flash' "$meta" "the meta did not record its model"
  assert_grep 'effort=low' "$meta" "the meta did not record its effort axis"
  assert_grep 'polytoken_session=0czfake-echo' "$meta" "the meta did not record the session id"
  assert_grep 'polytoken_port=49999' "$meta" "the meta did not record the port"
  assert_grep "polytoken_credential=$HOME_DIR/state/$id.polytoken-sessions-v1/0czfake-echo/credential.json" \
    "$meta" "the meta did not record the credential path"
  assert_no_grep 'polytoken_config_dir=' "$meta" \
    "the meta must bind only the session id, port, and credential"
  assert_no_grep 'polytoken_sessions_root=' "$meta" \
    "the meta must bind only the session id, port, and credential"
  # The session binding lines are exact whole lines: the sessions listing's
  # @tsv row carries a fourth field (the daemon pid) that must never be glued
  # onto the credential path the control verbs address.
  awk -F= -v want="polytoken_credential=$HOME_DIR/state/$id.polytoken-sessions-v1/0czfake-echo/credential.json" \
    '$0 == want { found=1 } END { exit !found }' "$meta" \
    || fail "the credential binding must be the exact listing path, pid-free"
  awk -F= -v want='polytoken_session=0czfake-echo' \
    '$0 == want { found=1 } END { exit !found }' "$meta" \
    || fail "the session binding must be the exact session id"
  awk -F= -v want='polytoken_port=49999' \
    '$0 == want { found=1 } END { exit !found }' "$meta" \
    || fail "the port binding must be the exact port"
  # The generated wiring landed where the launch says it did.
  [ -f "$WT_DIR/.polytoken/hooks.json" ] || fail "the worktree hook layer was not written"
  [ -f "$WT_DIR/.polytoken/facets/firstmate-worker.md" ] || fail "the worker facet was not written"
  [ -f "$HOME_DIR/state/$id.polytoken-busy.sh" ] || fail "the busy writer was not written"
  cfg=$(cat "$HOME_DIR/state/$id.polytoken-config/config.yaml")
  assert_contains "$cfg" "default_permission_matcher: bypass" \
    "the mirrored worker config must enforce the unattended posture"
  pass "fm-spawn: the polytoken launch carries the hybrid contract end to end"
}

test_polytoken_effort_recorded_but_omitted_when_unlisted() {
  local id rec out rc launch raw meta
  id="pt-xhigh-z2-$$"
  rec=$(make_polytoken_spawn_case xhigh "$id")
  read_polytoken_spawn_record "$rec"
  out=$(run_polytoken_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model zai/glm-5.3-flash --effort medium)
  rc=$?
  expect_code 0 "$rc" "a polytoken spawn with an effort outside the model's set should still succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "--model zai/glm-5.3-flash" \
    "the launch must carry the bare reference for an unlisted effort"
  assert_not_contains "$launch" "(medium)" "the launch must not pass the unlisted effort variant"
  raw=$(cat "$CASE_DIR/launch-line.log")
  assert_contains "$raw" "--model 'zai/glm-5.3-flash'" \
    "the raw launch line must carry the bare quoted reference"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=medium' "$meta" "the meta must retain the omitted effort axis"
  pass "fm-spawn: polytoken omits an unlisted effort from the launch but records it"
}

test_polytoken_unlisted_model_refuses_before_pane_creation() {
  local id rec out rc
  id="pt-badmodel-z3-$$"
  rec=$(make_polytoken_spawn_case badmodel "$id")
  read_polytoken_spawn_record "$rec"
  rc=0
  out=$(run_polytoken_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model zai/not-a-model) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unlisted polytoken model should refuse the spawn"
  assert_contains "$out" "not listed by 'polytoken print models'" \
    "the refusal must name the listing it checked"
  # The model-validation probe itself logs to the argv log, so the proof no
  # launch happened is the raw launch line: it is written only when the pane
  # actually sources the staged launch file.
  [ ! -s "$CASE_DIR/launch-line.log" ] \
    || fail "an unlisted model created a launch command"
  pass "fm-spawn: an unlisted polytoken model refuses before pane creation"
}

test_polytoken_secondmate_is_refused() {
  local id rec out rc
  id="pt-secondmate-z4-$$"
  rec=$(make_polytoken_spawn_case secondmate-refuse "$id")
  read_polytoken_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate polytoken 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a polytoken secondmate spawn should be refused"
  assert_contains "$out" "polytoken is a verified crewmate/scout adapter only" \
    "the secondmate refusal lacked its concrete reason"
  pass "fm-spawn: polytoken cannot be launched as a secondmate"
}

test_polytoken_existing_project_hook_layer_refuses() {
  local id rec out rc
  id="pt-ownhooks-z5-$$"
  rec=$(make_polytoken_spawn_case ownhooks "$id")
  read_polytoken_spawn_record "$rec"
  # A project's own hook layer is tracked content on the project's default
  # branch: the spawn freshens the pooled worktree to origin's default before
  # arming, so the layer must ride that base to be present at arm time (an
  # uncommitted or branch-local file is wiped by the refresh for every
  # harness, which is the pooled-worktree contract, not a polytoken fact).
  mkdir -p "$PROJ_DIR/.polytoken"
  printf '[{"name":"project-own","event":"stop","handler":{"bash":"/bin/true"}}]\n' \
    > "$PROJ_DIR/.polytoken/hooks.json"
  git -C "$PROJ_DIR" add .polytoken/hooks.json
  git -C "$PROJ_DIR" -c user.email=fixture@firstmate.test -c user.name=fixture \
    commit -q -m "fixture: project polytoken hook layer"
  git -C "$PROJ_DIR" push -q origin main
  rc=0
  out=$(run_polytoken_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn into a worktree with its own hook layer should refuse"
  assert_contains "$out" "not firstmate's to clobber" \
    "the refusal must name the project's own hook layer"
  assert_contains "$(cat "$WT_DIR/.polytoken/hooks.json")" "project-own" \
    "the refusal must leave the project's own hook layer untouched"
  assert_absent "$WT_DIR/.polytoken/facets/firstmate-worker.md" \
    "the refusal must not leave a generated worker facet in the worktree"
  assert_absent "$HOME_DIR/state/$id.polytoken-busy.sh" \
    "the refusal must not leave a generated busy writer in state"
  assert_absent "$HOME_DIR/state/$id.polytoken-config" \
    "the refusal must not leave a mirrored config dir in state"
  [ -z "$(git -C "$WT_DIR" status --porcelain)" ] \
    || fail "the refusal must leave the worktree clean: $(git -C "$WT_DIR" status --porcelain)"
  pass "fm-spawn: a project's own polytoken hook layer is refused, not clobbered"
}

test_polytoken_readiness_failure_fails_loudly_and_cleans_up() {
  local id rec out rc status tmux_calls
  id="pt-noready-z6-$$"
  rec=$(make_polytoken_spawn_case noready "$id")
  read_polytoken_spawn_record "$rec"
  rc=0
  out=$(PTFAKE_NO_HOOK=1 FM_POLYTOKEN_READY_POLLS=2 FM_POLYTOKEN_POLL_INTERVAL=0 \
    run_polytoken_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a launch that never starts processing its brief must fail the spawn"
  assert_contains "$out" "did not start processing its brief" \
    "the failure must name the unstarted brief"
  assert_contains "$out" "license dialog" \
    "the failure must name the one known first-start blocker"
  status=$(sed -E 's/ \[at=[0-9]+\]//' "$HOME_DIR/state/$id.status" 2>/dev/null || true)
  assert_contains "$status" "failed: polytoken did not start processing its brief" \
    "the failed readiness gate must record the failure in the task status"
  tmux_calls=$(cat "$CASE_DIR/tmux-calls.log")
  assert_contains "$tmux_calls" "kill-window" \
    "a failed readiness gate must close the endpoint it launched"
  assert_contains "$(cat "$CASE_DIR/launch.log")" "reap 0czfake-echo --force" \
    "a failed readiness gate must reap the session daemon it discovered"
  [ ! -e "$HOME_DIR/state/$id.polytoken-config" ] \
    || fail "the failed gate must retire the per-task config dir"
  [ ! -e "$HOME_DIR/state/$id.polytoken-sessions" ] \
    || fail "the failed gate must retire the sessions root"
  [ ! -e "$HOME_DIR/state/$id.polytoken-sessions-v1" ] \
    || fail "the failed gate must retire the versioned sessions sibling"
  [ ! -e "$WT_DIR/.polytoken/hooks.json" ] \
    || fail "the failed gate must retire the worktree hook layer"
  assert_not_contains "$out" "spawned $id" "a failed gate must not report a successful spawn"
  pass "fm-spawn: a failed readiness gate fails loudly, reaps, and retires its wiring"
}

test_polytoken_spawn_arms_the_busy_contract() {
  local id rec out rc statedir
  id="pt-busy-z7-$$"
  rec=$(make_polytoken_spawn_case busyarm "$id")
  read_polytoken_spawn_record "$rec"
  out=$(run_polytoken_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model zai/glm-5.3-flash)
  rc=$?
  expect_code 0 "$rc" "the busy-armed spawn should succeed"
  statedir="$HOME_DIR/state"
  [ -e "$statedir/$id.busy-gen" ] || fail "the spawn must arm a busy generation"
  out=$(fm_busy_record_read "$statedir" "$id")
  assert_contains "$out" "polytoken-hook" \
    "the launched brief's first hook event must advance the record past the seed"
  assert_contains "$out" "busy" "the record must read busy while the simulated turn runs"
  pass "fm-spawn: the polytoken busy contract arms and advances through the generated writer"
}

# ---------------------------------------------------------------------------

test_polytoken_ancestry_detects_the_native_command_name
test_polytoken_ancestry_rejects_unrelated_mentions
test_polytoken_claims_no_inherited_launcher_marker
test_polytoken_control_mechanics_are_the_verified_ones
test_polytoken_wiring_tables_cover_every_generated_artifact
test_polytoken_tmux_names_the_native_binary_an_agent
test_polytoken_busy_sources_are_the_verified_pair
test_polytoken_busy_footer_needs_the_pinned_running_row
test_polytoken_composer_is_the_verified_separated_shape
test_polytoken_busy_queued_enter_converts_like_opencode
test_polytoken_write_config_enforces_the_unattended_posture
test_polytoken_write_facet_carries_the_role_contract_without_a_model_pin
test_polytoken_busy_writer_dispatches_without_argv_and_never_fails
test_polytoken_write_hooks_binds_the_three_events
test_polytoken_model_ref_composes_and_refuses
test_polytoken_model_ref_unreachable_listing_launches_unvalidated
test_polytoken_rest_interrupt_settles_the_turn
test_polytoken_turn_settled_reads_the_typed_sync_verdict
test_polytoken_launch_carries_the_hybrid_contract
test_polytoken_effort_recorded_but_omitted_when_unlisted
test_polytoken_unlisted_model_refuses_before_pane_creation
test_polytoken_secondmate_is_refused
test_polytoken_existing_project_hook_layer_refuses
test_polytoken_readiness_failure_fails_loudly_and_cleans_up
test_polytoken_spawn_arms_the_busy_contract
