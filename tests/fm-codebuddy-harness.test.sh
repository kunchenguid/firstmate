#!/usr/bin/env bash
# Behavior tests for the verified CodeBuddy Code harness adapter.
#
# CodeBuddy Code (`codebuddy`, alias `cbc`) is both a verified primary and a
# verified crewmate/scout adapter. The facts pinned here are the ones a
# codebuddy release could silently change and the ones a wrong guess would make
# dangerous:
#   1. codebuddy publishes no harness-identity marker of its own, so detection
#      is ancestry alone on the anchored names `codebuddy` and `cbc`; the
#      anchored match must never claim a longer name that merely starts with
#      either, and the CODEBUDDY_* runtime variables must never be promoted to
#      an identity.
#   2. A codebuddy primary must be able to hold the fleet lock: the session-lock
#      vocabulary accepts both names (and the versioned install path), and the
#      shared liveness classifier reads them as an agent while their fragments
#      stay `other`.
#   3. Its supervision model is `autoarm`, because the tracked
#      .codebuddy/settings.json registers the same Stop pair as Claude Code,
#      including the asyncRewake auto-arm.
#   4. The rendered primary supervision protocol is codebuddy's own, never the
#      unknown fallback, and its ordinary-wake and repair lines leave continuity
#      to the Stop-owned auto-arm instead of directing a manual arm.
#   5. bin/fm-turnend-guard.sh accepts --codebuddy as an alias for its --claude
#      autoarm-cooperation mode, since CodeBuddy's Stop semantics are Claude's.
#   6. The tracked .codebuddy/settings.json mirrors the tracked Claude
#      registration - session start, the two Bash pre-tool checks, the subagent
#      guard, and the guard+auto-arm Stop pair - and stays grok-guard-free,
#      because codebuddy reads .codebuddy/settings.json and never loads the
#      Claude settings file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS FM_SUPERVISION_MODEL

# shellcheck source=/dev/null
. "$ROOT/bin/fm-session-lock-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
GUARD="$ROOT/bin/fm-turnend-guard.sh"
RENDER="$ROOT/bin/fm-supervision-instructions.sh"
SETTINGS="$ROOT/.codebuddy/settings.json"
TMP_ROOT=$(fm_test_tmproot fm-codebuddy-harness)

# A ps shim that answers the FIELD-FIRST per-pid form every ancestry walk uses
# (`ps -o comm= -p <pid>`, `ps -o args= -p <pid>`) from two variables, so a
# detection case controls the whole parent chain without a real codebuddy
# process. Every other ps query falls through to the real ps.
make_ancestry_fakebin() {  # <dir> -> echoes <fakebin>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:-$FAKE_PS_COMM}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s' "$fakebin"
}

detect_with_ancestry() {  # <comm> <args>
  local comm=$1 args=$2
  FAKE_PS_COMM="$comm" FAKE_PS_ARGS="$args" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      -u GEMINI_CLI -u FM_OMP_HARNESS \
      PATH="$ANCESTRY_FAKEBIN:$PATH" "$HARNESS"
}

test_detection_uses_anchored_ancestry_names() {
  local comm out
  for comm in codebuddy cbc /usr/local/bin/codebuddy /Users/x/.local/share/codebuddy/versions/2.150.0/codebuddy; do
    out=$(detect_with_ancestry "$comm" "$comm")
    [ "$out" = codebuddy ] || fail "a process named $comm must detect as codebuddy, got '$out'"
  done
  for comm in codebuddyish cbcf cbcx codebuddy-code codebuddyx; do
    out=$(detect_with_ancestry "$comm" "$comm")
    [ "$out" != codebuddy ] || fail "'$comm' merely borrows a codebuddy prefix and must not detect as codebuddy"
  done
  pass "fm-harness.sh: ancestry detects both anchored codebuddy names and rejects longer fragments"
}

test_codebuddy_runtime_variables_are_not_an_identity() {
  local fakebin out
  # A live codebuddy session exports CODEBUDDY_SESSION_ID, CODEBUDDY_PROJECT_DIR,
  # CODEBUDDY_HOST, CODEBUDDY_CLI_CAPABILITIES, and CODEBUDDY_CURRENT_MODEL_ID to
  # its children. None of them is an identity claim, so with the ancestry walk
  # blinded they must leave the verdict unknown rather than naming codebuddy.
  fakebin=$(fm_fakebin "$TMP_ROOT/blind")
  fm_fake_blind_ancestry "$fakebin"
  out=$(CODEBUDDY_SESSION_ID=abc CODEBUDDY_PROJECT_DIR=/x CODEBUDDY_HOST=host \
    CODEBUDDY_CLI_CAPABILITIES=caps CODEBUDDY_CURRENT_MODEL_ID=model \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != codebuddy ] || fail "CODEBUDDY_* runtime variables must never create a codebuddy identity, got '$out'"
  # Drive the hazard the other way: codebuddy does not clear an inherited
  # CLAUDECODE, so a structural codebuddy ancestor must still outrank the
  # retained marker rather than being renamed away from it.
  out=$(CLAUDECODE=1 detect_with_ancestry codebuddy codebuddy)
  [ "$out" = codebuddy ] || fail "a structural codebuddy ancestor must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: CODEBUDDY_* runtime variables are not an identity; ancestry still outranks a retained marker"
}

test_lock_identity_and_liveness_classification() {
  local got
  fm_harness_process_matches codebuddy '' || fail "session-lock identity must accept the exact codebuddy name"
  fm_harness_process_matches cbc '' || fail "session-lock identity must accept the cbc alias"
  fm_harness_process_matches /Users/x/.local/share/codebuddy/versions/2.150.0/codebuddy 'codebuddy' \
    || fail "session-lock identity must accept the versioned codebuddy install path"
  ! fm_harness_process_matches codebuddyish '' || fail "session-lock identity must not accept codebuddyish"
  ! fm_harness_process_matches cbcx '' || fail "session-lock identity must not accept cbcx"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  got=$(fm_agent_process_classify_name codebuddy)
  [ "$got" = agent ] || fail "tmux liveness must read codebuddy as an agent, got '$got'"
  got=$(fm_agent_process_classify_name cbc)
  [ "$got" = agent ] || fail "tmux liveness must read cbc as an agent, got '$got'"
  got=$(fm_agent_process_classify_name codebuddyish)
  [ "$got" = other ] || fail "tmux liveness must not read codebuddyish as an agent, got '$got'"
  pass "bin/fm-session-lock-lib.sh + bin/fm-agent-process-lib.sh: codebuddy holds the lock and reads as an agent"
}

test_supervision_model_is_autoarm() {
  local model
  # shellcheck disable=SC2016 # the quoted body expands inside the child shell
  model=$(FAKE_PS_COMM=codebuddy FAKE_PS_ARGS=codebuddy \
    env -u CLAUDECODE -u FM_SUPERVISION_MODEL PATH="$ANCESTRY_FAKEBIN:$PATH" \
    bash -c '. "$1"; fm_supervision_model' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$model" = autoarm ] || fail "a codebuddy primary must run the autoarm supervision model, got '$model'"
  # The Claude-family model is codebuddy-specific: a markerless harness with no
  # auto-arm hook pair stays persistent.
  # shellcheck disable=SC2016 # the quoted body expands inside the child shell
  model=$(FAKE_PS_COMM=codex FAKE_PS_ARGS=codex \
    env -u CLAUDECODE -u FM_SUPERVISION_MODEL PATH="$ANCESTRY_FAKEBIN:$PATH" \
    bash -c '. "$1"; fm_supervision_model' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$model" = persistent ] || fail "codex must stay on the persistent model, got '$model'"
  # An explicit override still wins over detection.
  # shellcheck disable=SC2016 # the quoted body expands inside the child shell
  model=$(FAKE_PS_COMM=codebuddy FAKE_PS_ARGS=codebuddy FM_SUPERVISION_MODEL=persistent \
    env -u CLAUDECODE PATH="$ANCESTRY_FAKEBIN:$PATH" \
    bash -c '. "$1"; fm_supervision_model' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$model" = persistent ] || fail "FM_SUPERVISION_MODEL must still override detection, got '$model'"
  pass "fm-wake-lib: codebuddy is autoarm, codex stays persistent, and the override still wins"
}

test_supervision_instructions_render_the_codebuddy_protocol() {
  local home out ordinary
  home="$TMP_ROOT/render-home"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$RENDER" --harness codebuddy)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: codebuddy" "codebuddy heading missing"
  assert_contains "$out" "Mode: CodeBuddy Stop-hook-owned supervision." "codebuddy protocol snippet missing"
  assert_not_contains "$out" "primary harness: unknown" "codebuddy fell back to the unknown protocol"
  assert_not_contains "$out" "Mode: Unknown harness fallback." "codebuddy rendered the unknown fallback snippet"
  assert_not_contains "$out" "__FM_" "codebuddy snippet left a renderer placeholder unsubstituted"
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "Stop-owned auto-arm" "codebuddy ordinary-wake line does not leave continuity to the Stop hook"
  assert_contains "$ordinary" "bin/fm-claude-stop-autoarm.sh" "codebuddy ordinary-wake line lost the auto-arm script name"
  assert_contains "$ordinary" ".codebuddy/settings.json" "codebuddy ordinary-wake line does not name its own hook file"
  assert_contains "$ordinary" "do not arm another cycle" "codebuddy ordinary-wake line does not forbid a model re-arm"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "codebuddy ordinary-wake line incorrectly calls the manual arm"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$RENDER" --harness codebuddy --repair-line)
  assert_contains "$out" "watcher supervision needs Stop-owned automatic recovery" "codebuddy repair line lost its neutral automatic-recovery guidance"
  assert_contains "$out" ".codebuddy/settings.json" "codebuddy repair line does not name the hook file to inspect"
  assert_not_contains "$out" "is broken" "codebuddy repair line claimed failure before verification"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "codebuddy repair line must not create a repeatable manual arm loop"
  pass "bin/fm-supervision-instructions.sh: codebuddy renders its own Stop-hook-owned protocol"
}

test_turnend_guard_accepts_the_codebuddy_alias() {
  local home out rc
  home="$TMP_ROOT/guard-home"
  mkdir -p "$home/state" "$home/config"
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$GUARD" --codebuddy </dev/null 2>&1) || rc=$?
  expect_code 0 "$rc" "--codebuddy must be an accepted guard mode"
  # An unknown flag is still refused, and the usage line names the new alias so
  # the registration cannot rot silently.
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$GUARD" --not-a-flag </dev/null 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown guard flag must exit 2, got $rc"
  assert_contains "$out" "--codebuddy" "guard usage line does not list the codebuddy alias"
  pass "bin/fm-turnend-guard.sh: --codebuddy is an accepted autoarm-cooperation alias"
}

test_tracked_codebuddy_settings_mirror_the_claude_registration() {
  local sessionstart pretool_bash pretool_all stop_guard stop_autoarm commands
  command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
  [ -f "$SETTINGS" ] || fail "tracked .codebuddy/settings.json is missing"
  jq -e . "$SETTINGS" >/dev/null 2>&1 || fail "tracked .codebuddy/settings.json is not valid JSON"

  sessionstart=$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$SETTINGS")
  assert_contains "$sessionstart" "fm-sessionstart-run.sh" "SessionStart must run the shared digest transport"
  # shellcheck disable=SC2016 # the literal variable name is what the command must contain
  assert_contains "$sessionstart" '$CLAUDE_PROJECT_DIR' "SessionStart must address the home through CLAUDE_PROJECT_DIR"
  [ "$(jq -r '.hooks.SessionStart[0].hooks[0].timeout // empty' "$SETTINGS")" = 180 ] \
    || fail "SessionStart must keep the shared 180s timeout"

  [ "$(jq -r '.hooks.PreToolUse[0].matcher // empty' "$SETTINGS")" = Bash ] \
    || fail "the first PreToolUse entry must match Bash"
  pretool_bash=$(jq -r '.hooks.PreToolUse[0].hooks[].command' "$SETTINGS")
  assert_contains "$pretool_bash" "fm-arm-pretool-check.sh --claude" "the Bash pre-tool check must arm-guard"
  assert_contains "$pretool_bash" "fm-cd-pretool-check.sh --claude" "the Bash pre-tool check must cd-guard"

  [ "$(jq -r '.hooks.PreToolUse[1].matcher // empty' "$SETTINGS")" = '.*' ] \
    || fail "the second PreToolUse entry must match every tool"
  pretool_all=$(jq -r '.hooks.PreToolUse[1].hooks[].command' "$SETTINGS")
  assert_contains "$pretool_all" "fm-subagent-pretool-check.sh --claude" "the subagent guard must be registered"

  stop_guard=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$SETTINGS")
  assert_contains "$stop_guard" "fm-turnend-guard.sh --codebuddy" "the Stop guard must call the codebuddy alias"
  stop_autoarm=$(jq -r '.hooks.Stop[0].hooks[1].command // empty' "$SETTINGS")
  assert_contains "$stop_autoarm" "fm-claude-stop-autoarm.sh" "the Stop pair must include the shared auto-arm"
  [ "$(jq -r '.hooks.Stop[0].hooks[1].asyncRewake // false' "$SETTINGS")" = true ] \
    || fail "the Stop auto-arm must be asyncRewake so it never blocks the turn"
  [ "$(jq -r '.hooks.Stop[0].hooks[1].timeout // empty' "$SETTINGS")" = 28800 ] \
    || fail "the Stop auto-arm must keep the shared multi-hour timeout"

  # codebuddy reads .codebuddy/settings.json only, so the Claude file's grok
  # guard would be dead noise here; pin that it was not copied across.
  commands=$(jq -r '.hooks[][].hooks[].command' "$SETTINGS")
  assert_not_contains "$commands" "GROK_AGENT" "the Claude file's grok guard must not be copied into the codebuddy settings"
  assert_not_contains "$commands" "__FM_" "a hook command left a placeholder unsubstituted"
  pass "tracked .codebuddy/settings.json mirrors the Claude hook registration on codebuddy's own settings path"
}

ANCESTRY_FAKEBIN=$(make_ancestry_fakebin "$TMP_ROOT/ancestry")

# Drive the real dispatch-profile validator (bin/fm-bootstrap.sh,
# crew_dispatch_validate) over a scratch home so the codebuddy effort vocabulary
# is pinned against the same code path an intake hits.
run_dispatch_validate() {  # <home>
  local home=$1
  FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_LOCKED=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_dispatch_validation_owns_codebuddy_efforts() {
  local home out
  command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
  home="$TMP_ROOT/dispatch-validate"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/projects"

  printf '%s\n' '{"rules":[{"when":"x","use":{"harness":"codebuddy","model":"hy3","effort":"high"}}],"default":[{"harness":"codebuddy","model":"deepseek-v4.1-flash","effort":"high"}]}' \
    > "$home/config/crew-dispatch.json"
  out=$(run_dispatch_validate "$home")
  assert_not_contains "$out" "CREW_DISPATCH" "a supported codebuddy effort must validate silently"

  printf '%s\n' '{"rules":[{"when":"x","use":{"harness":"codebuddy","model":"hy3","effort":"minimal"}}]}' \
    > "$home/config/crew-dispatch.json"
  out=$(run_dispatch_validate "$home")
  assert_contains "$out" "invalid effort: codebuddy:minimal" \
    "codebuddy must refuse the one effort its launch mapping deliberately never passes"
  pass "fm-bootstrap: dispatch validation owns the codebuddy effort vocabulary"
}

test_detection_uses_anchored_ancestry_names
test_codebuddy_runtime_variables_are_not_an_identity
test_lock_identity_and_liveness_classification
test_supervision_model_is_autoarm
test_supervision_instructions_render_the_codebuddy_protocol
test_turnend_guard_accepts_the_codebuddy_alias
test_tracked_codebuddy_settings_mirror_the_claude_registration
test_dispatch_validation_owns_codebuddy_efforts
