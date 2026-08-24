#!/usr/bin/env bash
# tests/fm-watch-close-exited-panes-optin.test.sh - the watcher's automatic
# exited-pane retirement (bin/fm-watch.sh: close_finished_exited_pane) is
# gated behind an explicit captain opt-in (VISION.md: "autonomy exists only
# as an explicit grant, never as a default"), so upgrading the watcher never
# starts closing panes on its own. close_exited_panes_enabled() is the real,
# unmodified gate function; these tests call it directly (bin/fm-watch.sh is
# safe to source for unit tests - see its own header note).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-close-exited-panes-optin)

gate_result() {  # <home> [env-assignment...] -> "0" (enabled) or "1" (disabled)
  local home=$1
  shift
  # shellcheck disable=SC2016 # inner bash -c body expands via its own positional params, not this shell
  env "$@" FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" bash -c '
    SCRIPT_DIR="$1"
    STATE="$2"
    FM_HOME="$3"
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/fm-watch.sh"
    close_exited_panes_enabled
    printf "%d\n" "$?"
  ' _ "$ROOT/bin" "$home/state" "$home"
}

test_disabled_by_default() {
  local home rc
  home="$TMP_ROOT/default"
  mkdir -p "$home/state" "$home/config"
  rc=$(gate_result "$home")
  [ "$rc" -eq 1 ] || fail "automatic pane close must be disabled with no config and no env var, got rc=$rc"
  pass "close_exited_panes_enabled: disabled by default (no config, no env var)"
}

test_enabled_by_config_file_presence() {
  local home rc
  home="$TMP_ROOT/config-present"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/close-exited-panes"
  rc=$(gate_result "$home")
  [ "$rc" -eq 0 ] || fail "an existing config/close-exited-panes must enable automatic close, got rc=$rc"
  pass "close_exited_panes_enabled: enabled once config/close-exited-panes exists"
}

test_enabled_by_env_override() {
  local home rc
  home="$TMP_ROOT/env-on"
  mkdir -p "$home/state" "$home/config"
  rc=$(gate_result "$home" FM_CLOSE_EXITED_PANES=1)
  [ "$rc" -eq 0 ] || fail "FM_CLOSE_EXITED_PANES=1 must enable automatic close, got rc=$rc"
  pass "close_exited_panes_enabled: FM_CLOSE_EXITED_PANES=1 enables it"
}

test_env_override_forces_off_even_with_config() {
  local home rc
  home="$TMP_ROOT/env-off"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/close-exited-panes"
  rc=$(gate_result "$home" FM_CLOSE_EXITED_PANES=0)
  [ "$rc" -eq 1 ] || fail "FM_CLOSE_EXITED_PANES=0 must force automatic close off, got rc=$rc"
  pass "close_exited_panes_enabled: FM_CLOSE_EXITED_PANES=0 overrides an existing config file"
}

test_disabled_by_default
test_enabled_by_config_file_presence
test_enabled_by_env_override
test_env_override_forces_off_even_with_config
