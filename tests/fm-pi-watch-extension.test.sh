#!/usr/bin/env bash
# Tests for the generated Pi primary watcher extension and Pi secondmate wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-watch-extension)
GEN="$ROOT/bin/fm-pi-watch-extension.sh"

test_generator_writes_extension() {
  local home out file text
  home="$TMP_ROOT/home"
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$GEN")
  file="$home/state/fm-primary-pi-watch.ts"
  [ "$out" = "$file" ] || fail "generator printed '$out', expected '$file'"
  assert_present "$file" "generator did not write the Pi watch extension"
  text=$(cat "$file")
  assert_contains "$text" "fm_watch_arm_pi" "generated extension missing tool name"
  assert_contains "$text" "fm-watch-arm-pi" "generated extension missing command name"
  assert_contains "$text" "fm-watch-arm.sh" "generated extension missing watcher arm"
  assert_contains "$text" "sendUserMessage" "generated extension missing Pi wake API"
  assert_contains "$text" "deliverAs: \"followUp\"" "generated extension missing followUp delivery"
  assert_contains "$text" ".pi-watch-extension-loaded" "generated extension missing loaded marker"
  pass "Pi extension generator writes the firstmate-owned watcher bridge"
}

test_spawn_template_mentions_pi_watch_placeholder() {
  local text
  text=$(cat "$ROOT/bin/fm-spawn.sh")
  assert_contains "$text" "-e __PIWATCH__" "Pi secondmate launch template does not include the primary watch extension"
  assert_contains "$text" "fm-pi-watch-extension.sh" "fm-spawn does not generate the Pi watch extension before launch"
  assert_contains "$text" "__PIWATCH__" "fm-spawn does not replace the Pi watch extension placeholder"
  pass "Pi secondmate launch wiring includes the generated primary watcher extension"
}

test_opencode_primary_watch_plugin_static_wiring() {
  local plugin text
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  assert_present "$plugin" "OpenCode primary watch plugin missing"
  text=$(cat "$plugin")
  assert_contains "$text" "session.idle" "OpenCode plugin does not listen for session.idle"
  assert_contains "$text" "fm-watch-arm.sh" "OpenCode plugin does not spawn the watcher arm"
  assert_contains "$text" "promptAsync" "OpenCode plugin does not wake with promptAsync"
  assert_contains "$text" ".fm-secondmate-home" "OpenCode plugin does not scope out secondmate homes"
  assert_contains "$text" "rev-parse\", \"--git-dir" "OpenCode plugin does not check linked worktree scope"
  pass "OpenCode primary watcher plugin has the verified TUI wake wiring"
}

test_generator_writes_extension
test_spawn_template_mentions_pi_watch_placeholder
test_opencode_primary_watch_plugin_static_wiring
