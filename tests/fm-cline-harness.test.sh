#!/usr/bin/env bash
# Behavior tests for the verified Cline CLI crewmate/scout adapter.
#
# The facts pinned here are the ones a cline release could silently change and
# the ones a wrong guess would make dangerous:
#   1. cline publishes no harness-identity marker, so detection is ancestry
#      alone: the anchored live process name `.cline`, with the node wrapper's
#      anchored script-path fragments `/bin/cline` and `@cline/cli` as backup.
#   2. The anchored match must never claim unrelated commands containing the
#      fragment, and a structural `.cline` ancestor must outrank a retained
#      CLAUDECODE.
#   3. cline is a crewmate/scout adapter only: control tables refuse a
#      secondmate target and expose the verified interrupt, exit, and wiring.
#   4. Busy state is a trusted semantic source (cline-hook); the rendered
#      `(esc to cancel)` token is a delivery-guard signature only and never
#      crosses harnesses.
#   5. The live process name is classified as an agent by backend liveness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry; drop the
# ambient markers so the asserted verdict does not depend on the launching
# harness.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-cline-harness)

test_cline_ancestry_detects_the_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/home/azureuser/.npm-global/lib/node_modules/cline/bin/.cline'; exit 0 ;;
  *"args="*) printf '%s\n' '.cline -i -c /work'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = cline ] \
    || fail "the native .cline command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects the native .cline command"
}

test_cline_ancestry_detects_the_node_wrapper() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-node")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' node; exit 0 ;;
  *"args="*) printf '%s\n' 'node /home/azureuser/.npm-global/bin/cline -i'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = cline ] \
    || fail "the node cline wrapper must be detected by its script path, got '$out'"
  pass "fm-harness.sh: ancestry detects the node cline wrapper"
}

test_cline_ancestry_rejects_unrelated_mentions() {
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

  out=$(FAKE_PS_COMM=mycline FAKE_PS_ARGS='mycline --serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != cline ] \
    || fail "an unrelated mycline command must not detect cline, got '$out'"

  out=$(FAKE_PS_COMM=node FAKE_PS_ARGS='node /opt/decline/index.js' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != cline ] \
    || fail "a node script merely containing cline must not detect cline, got '$out'"

  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "echo cline --help"' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != cline ] \
    || fail "a later shell argument naming cline must not detect cline, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated cline mentions"
}

test_cline_structural_ancestor_outranks_a_retained_marker() {
  local fakebin out
  # cline does not clear an inherited CLAUDECODE, so a structural .cline
  # ancestor must still outrank the retained marker rather than being renamed
  # away from it.
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-claude")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' .cline; exit 0 ;;
  *"args="*) printf '%s\n' '.cline -i'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = cline ] \
    || fail "a structural .cline ancestor must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: a structural .cline ancestor outranks a retained marker"
}

test_cline_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported cline || fail "cline must be a supported control harness"
  [ "$(fm_control_harness_family cline)" = cline ] || fail "cline must map to its own family"
  fm_control_harness_supports_kind cline scout || fail "cline must run scouts"
  fm_control_harness_supports_kind cline ship || fail "cline must run ships"
  fm_control_harness_supports_kind cline secondmate \
    && fail "cline must refuse secondmates" || true
  [ "$(fm_control_interrupt_key cline)" = Escape ] || fail "cline must interrupt on Escape"
  [ "$(fm_control_interrupt_repeat cline)" = 1 ] || fail "cline must interrupt on a single press"
  [ -z "$(fm_control_interrupt_clear_key cline)" ] || fail "cline must need no clear key"
  [ "$(fm_control_interrupt_ack_source cline)" = none ] || fail "cline must have no ack source"
  [ "$(fm_control_exit_command cline)" = /exit ] || fail "cline must exit on /exit"
  pass "fm-control-lib: cline mechanics are Escape once, no clear key, and /exit"
}

test_cline_wiring_paths_are_the_workspace_hooks() {
  local got
  got=$(fm_control_harness_wiring_paths cline /wt /state task1)
  local want
  want=$(printf '%s\n' \
    '/wt/.cline/hooks/TaskStart' \
    '/wt/.cline/hooks/TaskComplete' \
    '/wt/.cline/hooks/TaskCancel' \
    '/wt/.cline/hooks/TaskError' \
    '/wt/.cline/hooks/SessionShutdown')
  [ "$got" = "$want" ] || fail "cline wiring paths were not the workspace hook files, got '$got'"
  pass "fm-control-lib: cline wiring paths are the workspace hook files"
}

test_cline_busy_source_is_trusted() {
  local sources
  sources=$(fm_busy_sources_for_harness cline)
  case " $sources " in
    *" cline-hook "*) ;;
    *) fail "cline's busy source list must include cline-hook, got '$sources'" ;;
  esac
  fm_busy_source_trusted cline cline-hook \
    || fail "cline-hook must be trusted for a cline task"
  fm_busy_source_trusted cline gemini-hook \
    && fail "cline must never trust another adapter's busy source" || true
  pass "fm-busy-lib: cline trusts only its own cline-hook source"
}

test_cline_delivery_signature_is_harness_scoped() {
  printf '(esc to cancel)\n' | fm_busy_lines_match cline \
    || fail "harness=cline must match its esc-to-cancel token"
  printf '(esc to cancel)\n' | fm_busy_lines_match agy \
    || fail "harness=agy keeps its own esc-to-cancel token"
  printf '(esc to cancel)\n' | fm_busy_lines_match grok \
    && fail "harness=grok must never borrow the cline token" || true
  printf 'Ctrl+c:cancel\n' | fm_busy_lines_match cline \
    && fail "harness=cline must never borrow grok's token" || true
  printf '(esc to cancel)\n' | fm_busy_lines_match spaceship \
    && fail "an unverified harness must match nothing" || true
  pass "fm-composer-lib: cline delivery signature never crosses harnesses"
}

test_cline_tmux_names_the_native_binary_an_agent() {
  local got
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  got=$(fm_agent_process_classify_name .cline)
  [ "$got" = agent ] || fail "tmux liveness must read .cline as an agent, got '$got'"
  got=$(fm_agent_process_classify_name cline)
  [ "$got" = agent ] || fail "tmux liveness must read cline as an agent, got '$got'"
  got=$(fm_agent_process_classify_name mycline)
  [ "$got" = other ] || fail "tmux liveness must not read mycline as an agent, got '$got'"
  got=$(fm_agent_process_classify_name bash)
  [ "$got" = shell ] || fail "tmux liveness must still read bash as a shell, got '$got'"
  pass "bin/fm-agent-process-lib.sh: .cline is an agent, fragments are not"
}

test_cline_ancestry_detects_the_native_command_name
test_cline_ancestry_detects_the_node_wrapper
test_cline_ancestry_rejects_unrelated_mentions
test_cline_structural_ancestor_outranks_a_retained_marker
test_cline_control_mechanics_are_the_verified_ones
test_cline_wiring_paths_are_the_workspace_hooks
test_cline_busy_source_is_trusted
test_cline_delivery_signature_is_harness_scoped
test_cline_tmux_names_the_native_binary_an_agent
