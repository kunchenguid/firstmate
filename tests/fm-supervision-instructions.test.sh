#!/usr/bin/env bash
# Tests for harness-aware supervision instruction rendering.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-instructions)
RENDER="$ROOT/bin/fm-supervision-instructions.sh"

test_selected_harness_block_only() {
  local out
  out=$("$RENDER" --harness codex)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: codex" "codex heading missing"
  assert_contains "$out" "Mode: Codex foreground checkpoint." "codex snippet missing"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex checkpoint helper missing"
  assert_not_contains "$out" "Mode: Claude Stop-hook-owned supervision." "renderer printed the claude snippet too"
  assert_not_contains "$out" "Mode: Pi extension background wake." "renderer printed the pi snippet too"
  pass "renderer prints exactly the selected harness block"
}

test_unknown_fallback() {
  local out
  out=$("$RENDER" --harness not-real)
  assert_contains "$out" "primary harness: unknown" "unknown heading missing"
  assert_contains "$out" "Mode: Unknown harness fallback." "unknown fallback snippet missing"
  pass "renderer falls back to unknown.md for unverified harness names"
}

test_conditional_stanzas() {
  local home config out
  home="$TMP_ROOT/conditional-home"
  config="$TMP_ROOT/conditional-config"
  mkdir -p "$home/state" "$home/config" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex --read-only 1 --afk 1 --x-mode 1)
  assert_contains "$out" "- Lock: read-only" "read-only stanza missing"
  assert_contains "$out" "- Away mode: active" "afk stanza missing"
  assert_contains "$out" "- X mode: active" "x-mode stanza missing"
  assert_contains "$out" "$config/x-mode.env" "x-mode stanza did not render the effective config path"
  assert_contains "$out" 'Mode: non-owned lock state (LIVE_OTHER) - supervision withheld.' "read-only render lost the withheld mode line"
  assert_not_contains "$out" 'Mode: Codex foreground checkpoint.' "read-only render still emitted the codex mutation protocol"
  assert_not_contains "$out" "load /afk and keep normal harness supervision paused" "read-only afk stanza still instructed daemon ownership actions"
  assert_not_contains "$out" "before launching any watcher process" "read-only x-mode stanza still instructed launching a watcher"
  pass "renderer includes read-only, afk, and effective x-mode current-state stanzas without mutation instructions"
}

test_non_owned_states_withhold_mutation_instructions() {
  local out state
  for state in LIVE_OTHER STALE_RECLAIMABLE IDENTITY_UNAVAILABLE RECLAIM_BUSY; do
    out=$("$RENDER" --harness claude --lock-state "$state")
    assert_contains "$out" "Mode: non-owned lock state ($state) - supervision withheld." \
      "$state render lost the withheld mode line"
    assert_contains "$out" "no non-owned lock state may mutate fleet state" \
      "$state render lost the no-mutation contract line"
    assert_contains "$out" "- Ordinary wake: none; this session does not own the fleet lock" \
      "$state render kept an ordinary-wake mutation instruction"
    assert_not_contains "$out" "Mode: Claude background-notify supervision." \
      "$state render still emitted the claude mutation protocol"
    assert_not_contains "$out" "bin/fm-watch-arm.sh" \
      "$state render still instructed arming the watcher"
    assert_not_contains "$out" "bin/fm-wake-drain.sh" \
      "$state render still instructed draining the wake queue"
  done

  out=$("$RENDER" --harness claude --lock-state STALE_RECLAIMABLE)
  assert_contains "$out" "bin/fm-lock.sh reclaim --expected <recorded-owner>" \
    "stale render did not offer the atomic reclaim"
  assert_contains "$out" "re-run bin/fm-session-start.sh" \
    "stale render did not point back to the owned continuation"
  assert_contains "$out" "The one permitted mutation is the atomic lock reclaim itself" \
    "stale render did not scope the permitted mutation to the reclaim"

  out=$("$RENDER" --harness claude --lock-state RECLAIM_BUSY)
  assert_contains "$out" "The reclaim mutex is temporarily held" \
    "busy render lost temporary-contention guidance"
  assert_contains "$out" "not an identity failure" \
    "busy render did not separate contention from identity failure"
  assert_contains "$out" "Retry bin/fm-lock.sh" \
    "busy render did not offer a short retry"
  assert_not_contains "$out" "Restore identity evidence" \
    "busy render pointed at identity recovery instead of retry"

  out=$("$RENDER" --harness claude --lock-state LIVE_OTHER)
  assert_not_contains "$out" "reclaim --expected" \
    "live-other render offered a reclaim against a proven live owner"

  out=$("$RENDER" --harness claude --lock-state IDENTITY_UNAVAILABLE)
  assert_not_contains "$out" "reclaim --expected <recorded-owner>" \
    "identity-unavailable render offered an unconditional reclaim"
  assert_contains "$out" "Neither a live rival nor a stale owner is proven" \
    "identity-unavailable render lost its no-rival-claim line"
  assert_contains "$out" "--confirmed-closed" \
    "identity-unavailable render lost the captain-confirmed codex-thread path"

  out=$("$RENDER" --harness claude --lock-state OWNED)
  assert_contains "$out" "Mode: Claude background-notify supervision." \
    "owned render lost the normal claude protocol"
  assert_not_contains "$out" "supervision withheld" \
    "owned render incorrectly withheld supervision"
  pass "non-owned lock states withhold mutation instructions while keeping the reclaim path"
}

test_repair_lines() {
  local home out
  home="$TMP_ROOT/repair-home"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "codex repair line did not use checkpoint helper and env override"

  out=$(FM_HOME="$home" "$RENDER" --harness claude --queue-pending 1 --repair-line)
  assert_contains "$out" "After draining queued wakes" "queue-pending prefix missing"
  assert_contains "$out" "Claude Code background task" "claude repair line missing background-task mechanism"

  : > "$home/config/x-mode.env"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --x-mode 1 --repair-line)
  assert_contains "$out" "source '$home/config/x-mode.env' first" "x-mode repair line did not source the effective cadence config"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "x-mode codex repair line lost the checkpoint helper"

  out=$(FM_HOME="$home" "$RENDER" --harness opencode --read-only 1 --repair-line)
  assert_contains "$out" "session holding the fleet lock" "read-only repair line missing"

  out=$(FM_HOME="$home" "$RENDER" --harness pi --repair-line)
  assert_contains "$out" "Pi tool fm_watch_arm_pi" "pi repair line does not direct the model to the extension-owned tool"
  assert_not_contains "$out" "extension command /fm-watch-arm-pi" "pi repair line still directs the model to the human slash command"
  pass "renderer repair-line mode is harness-aware and honors conditional state"
}

test_cross_harness_ordinary_continuation_and_repair_matrix() {
  local ordinary out

  out=$("$RENDER" --harness pi)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "Pi extension already owns watcher continuity" "pi ordinary-wake line does not leave continuity to the extension"
  assert_not_contains "$ordinary" "fm_watch_arm_pi" "pi ordinary-wake line incorrectly calls the recovery tool"
  out=$("$RENDER" --harness pi --repair-line)
  assert_contains "$out" "fm_watch_arm_pi" "pi recovery line lost the extension-owned repair tool"

  out=$("$RENDER" --harness opencode)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "plugin already owns watcher continuity" "opencode ordinary-wake line does not leave continuity to the plugin"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "opencode ordinary-wake line incorrectly calls the recovery probe"
  out=$("$RENDER" --harness opencode --repair-line)
  assert_contains "$out" "manual recovery probe" "opencode recovery line lost its manual probe"

  out=$("$RENDER" --harness claude)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "Stop-owned auto-arm" "claude ordinary-wake line does not leave continuity to the Stop hook"
  assert_contains "$ordinary" "bin/fm-claude-stop-autoarm.sh" "claude ordinary-wake line lost the auto-arm script name"
  assert_contains "$ordinary" "do not arm another cycle" "claude ordinary-wake line does not forbid a model re-arm"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "claude ordinary-wake line incorrectly calls the manual arm"
  out=$("$RENDER" --harness claude --repair-line)
  assert_contains "$out" "Claude Code background task" "claude recovery line lost its tracked background repair"
  assert_contains "$out" "bin/fm-watch-arm.sh" "claude recovery line lost the arm command"

  out=$("$RENDER" --harness grok)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "re-arm" "grok ordinary-wake line does not tell the model to re-arm"
  assert_contains "$ordinary" "Grok tracked background task" "grok ordinary-wake line lost tracked background ownership"
  assert_contains "$ordinary" "bin/fm-watch-arm.sh" "grok ordinary-wake line lost the background arm command"
  out=$("$RENDER" --harness grok --repair-line)
  assert_contains "$out" "Grok tracked background task" "grok recovery line lost its tracked background repair"
  assert_contains "$out" "bin/fm-watch-arm.sh" "grok recovery line lost the arm command"

  out=$("$RENDER" --harness codex)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "next foreground" "codex ordinary-wake line lost its foreground checkpoint"
  assert_contains "$ordinary" "bin/fm-watch-checkpoint.sh" "codex ordinary-wake line lost the checkpoint command"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "codex ordinary-wake line incorrectly uses a background arm"
  out=$("$RENDER" --harness codex --repair-line)
  assert_contains "$out" "foreground checkpoint" "codex recovery line lost its checkpoint repair"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex recovery line lost the checkpoint command"

  pass "renderer preserves every harness ordinary-continuation and missing-cycle repair path"
}

test_grok_is_background_notify() {
  local out
  out=$("$RENDER" --harness grok)
  assert_contains "$out" "Mode: Grok background-notify supervision." "grok snippet missing background-notify mode"
  assert_contains "$out" "background: true" "grok snippet missing tracked background tool instruction"
  assert_contains "$out" "synthetic_reason: task_completed" "grok snippet missing auto-wake synthetic prompt detail"
  assert_contains "$out" "bin/fm-watch-arm.sh" "grok snippet missing watcher arm"
  assert_not_contains "$out" "__FM_X_MODE_ENV" "renderer leaked an x-mode path placeholder"
  assert_not_contains "$out" "foreground checkpoint" "grok snippet must not be Codex-style foreground checkpoint"
  out=$("$RENDER" --harness grok --repair-line)
  assert_contains "$out" "Grok tracked background task" "grok repair line is not background-notify shaped"
  pass "grok supervision is Claude-shaped background notify with passive Stop-hook backstop"
}

test_grok_command_sources_effective_config() {
  local home config out
  home="$TMP_ROOT/grok-home"
  config="$TMP_ROOT/grok-config"
  mkdir -p "$home/state" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok --x-mode 1)
  assert_contains "$out" "[ -f '$config/x-mode.env' ] && . '$config/x-mode.env'; exec bin/fm-watch-arm.sh" "grok arm command did not use the effective x-mode config path"
  pass "grok rendered command sources the effective x-mode config"
}

test_pi_snippet_uses_effective_extension_path() {
  local home out turnend watch
  home="$TMP_ROOT/pi-home"
  turnend="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  watch="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$RENDER" --harness pi)
  assert_contains "$out" "-e $turnend -e $watch" "pi snippet did not render both effective extension launch paths"
  assert_contains "$out" "The turn-end guard extension lives at \`$turnend\`" "pi snippet did not render the turn-end guard extension path"
  assert_contains "$out" "The watcher extension lives at \`$watch\`" "pi snippet did not render the watcher extension path"
  assert_not_contains "$out" "__FM_PI_EXT__" "renderer leaked the Pi extension path placeholder"
  assert_not_contains "$out" "__FM_PI_TURNEND_EXT__" "renderer leaked the Pi turn-end extension path placeholder"
  assert_not_contains "$out" "state/fm-primary-pi-watch.ts" "pi snippet kept the old generated state-relative extension path"
  pass "pi supervision snippet renders the effective extension path"
}

test_selected_harness_block_only
test_unknown_fallback
test_conditional_stanzas
test_non_owned_states_withhold_mutation_instructions
test_repair_lines
test_cross_harness_ordinary_continuation_and_repair_matrix
test_grok_is_background_notify
test_grok_command_sources_effective_config
test_pi_snippet_uses_effective_extension_path
