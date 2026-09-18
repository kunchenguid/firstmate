#!/usr/bin/env bash
# Behavior tests for bin/fm-bootstrap.sh's CLAUDE_PRIMARY_AUTO_MODE diagnostic
# (docs/configuration.md "Claude permission mode for the primary session").
#
# Every case runs the REAL bin/fm-bootstrap.sh as a child of a REAL process
# comm-named "claude" (a renamed copy of the ambient bash, the same technique
# tests/fm-claude-primary-permission-mode.test.sh validates for
# bin/fm-harness.sh's claude-permission-mode subcommand), so this pins the
# actual wiring - detect_claude_primary_permission calling out to
# bin/fm-harness.sh and grepping FM_ROOT's own .claude/settings.local.json -
# rather than a stubbed answer. No installed harness is required: the ps
# facts this depends on come from the shell itself.
#
# The four-case matrix this diagnostic exists to satisfy:
#   auto mode, no allow-rule pack   -> exactly one CLAUDE_PRIMARY_AUTO_MODE line
#   auto mode, allow-rule pack present -> silent
#   any other confirmed mode       -> silent
#   undeterminable mode            -> silent
# Plus the "one-shot" contract: printed once with the fleet lock held, then
# never again regardless of whether the operator acts on it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE HERDR_ENV HERDR_PANE_ID TMUX TMUX_PANE PI_CODING_AGENT \
  FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS 2>/dev/null || true

BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-primary-auto-mode)

# A real process comm-named "claude": see the sibling permission-mode suite
# for why this must be a COPY of the ambient bash (ad-hoc signed, so it can
# run from an arbitrary path) rather than a symlink or a shebang script.
claude_bin() {
  local dir=$1
  mkdir -p "$dir"
  cp "$(command -v bash)" "$dir/claude"
  printf '%s\n' "$dir/claude"
}

# make_home <dir>: a minimal scratch FM_HOME/FM_ROOT that lets fm-bootstrap.sh
# run its full detect pass without noise this suite cares about - manual
# backlog backend skips the tasks-axi requirement, and a pinned tmux backend
# keeps the resolved backend deterministic regardless of the host's own
# ambient runtime markers (already unset above, pinned again for the child).
make_home() {
  local dir=$1
  mkdir -p "$dir/config" "$dir/state" "$dir/data"
  printf 'manual\n' > "$dir/config/backlog-backend"
  printf 'tmux\n' > "$dir/config/backend"
  printf '%s\n' "$dir"
}

# Run bin/fm-bootstrap.sh as a child of a real claude-comm'd process, with the
# given extra argv appended to that process's OWN command line (so
# bin/fm-harness.sh's ancestry walk can read them the way it reads a real
# claude launch's flags), and print bootstrap's stdout+stderr.
#
# The script body runs the real bootstrap as a NON-final command (`; true`
# after it) so bash never tail-exec-replaces the "claude"-named process's own
# image into bootstrap's - which would lose the "claude" comm identity for
# the ancestry walk to find. FM_BOOTSTRAP_NETWORK=skip keeps this hermetic
# (no gh auth, no secondmate/fleet-sync network calls); FM_CLAUDE_CONFIG_DIR
# is deliberately a NONEXISTENT directory unless a case supplies its own, so
# the host's own real ~/.claude/settings.json can never leak into a case that
# means to test the undeterminable path.
run_bootstrap_under_claude() {  # <home> <claude-config-dir> [extra claude argv...]
  local home=$1 cfg=$2 dir out
  shift 2
  dir="$TMP_ROOT/proc-$RANDOM-$RANDOM"
  local bin outfile
  bin=$(claude_bin "$dir")
  outfile="$dir/out"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_NETWORK=skip \
    FM_BOOTSTRAP_DETECT_ONLY="${FM_TEST_DETECT_ONLY:-0}" \
    CLAUDE_CONFIG_DIR="$cfg" \
    "$bin" -c '"$1" > "$2" 2>&1; true' claude-wrapper "$BOOTSTRAP" "$outfile" "$@" &
  local pid=$!
  wait "$pid"
  cat "$outfile"
}

test_auto_mode_without_rules_prints_one_line() {
  local home out
  home=$(make_home "$TMP_ROOT/auto-no-rules")
  out=$(run_bootstrap_under_claude "$home" "$TMP_ROOT/no-such-config" --permission-mode auto)
  assert_contains "$out" "CLAUDE_PRIMARY_AUTO_MODE:" \
    "auto mode with no allow-rule pack must print the diagnostic"
  [ "$(printf '%s\n' "$out" | grep -c CLAUDE_PRIMARY_AUTO_MODE)" = 1 ] \
    || fail "the diagnostic must print exactly once, got: $out"
  pass "auto mode with no allow-rule pack prints exactly one CLAUDE_PRIMARY_AUTO_MODE line"
}

test_auto_mode_with_rules_present_is_silent() {
  local home out
  home=$(make_home "$TMP_ROOT/auto-with-rules")
  mkdir -p "$home/.claude"
  printf '%s' '{"permissions":{"allow":["Bash(bin/fm-merge-local.sh:*)"]}}' \
    > "$home/.claude/settings.local.json"
  out=$(run_bootstrap_under_claude "$home" "$TMP_ROOT/no-such-config" --permission-mode auto)
  assert_not_contains "$out" "CLAUDE_PRIMARY_AUTO_MODE:" \
    "auto mode with the allow-rule pack already present must stay silent"
  pass "auto mode with the allow-rule pack present is silent"
}

test_other_confirmed_mode_is_silent() {
  local home out
  home=$(make_home "$TMP_ROOT/bypass-mode")
  out=$(run_bootstrap_under_claude "$home" "$TMP_ROOT/no-such-config" --dangerously-skip-permissions)
  assert_not_contains "$out" "CLAUDE_PRIMARY_AUTO_MODE:" \
    "a confirmed bypass mode is not auto and must stay silent"
  pass "a confirmed non-auto mode (bypass) is silent"
}

test_undeterminable_mode_is_silent() {
  local home out
  home=$(make_home "$TMP_ROOT/undeterminable")
  # No --permission-mode/--dangerously-skip-permissions flag AND no matching
  # user-settings defaultMode: bin/fm-harness.sh's claude-permission-mode
  # confirms nothing here, by construction (see its own portable suite).
  out=$(run_bootstrap_under_claude "$home" "$TMP_ROOT/no-such-config")
  assert_not_contains "$out" "CLAUDE_PRIMARY_AUTO_MODE:" \
    "an undeterminable mode must never be treated as auto"
  pass "an undeterminable permission mode is silent"
}

test_one_shot_marker_suppresses_a_second_run() {
  local home out1 out2
  home=$(make_home "$TMP_ROOT/one-shot")
  out1=$(FM_TEST_DETECT_ONLY=0 run_bootstrap_under_claude "$home" "$TMP_ROOT/no-such-config" --permission-mode auto)
  assert_contains "$out1" "CLAUDE_PRIMARY_AUTO_MODE:" "the first locked run must print the diagnostic"
  assert_present "$home/state/.claude-primary-auto-mode-notified" \
    "a locked run must persist the one-shot marker"
  out2=$(FM_TEST_DETECT_ONLY=0 run_bootstrap_under_claude "$home" "$TMP_ROOT/no-such-config" --permission-mode auto)
  assert_not_contains "$out2" "CLAUDE_PRIMARY_AUTO_MODE:" \
    "a second run after the marker was written must stay silent, even though auto mode and the missing rules are unchanged"
  pass "the diagnostic is one-shot: a second locked run stays silent after the marker is written"
}

test_lock_refused_run_reprints_without_persisting() {
  # A lock-refused session (FM_BOOTSTRAP_DETECT_ONLY=1 with no
  # FM_BOOTSTRAP_LOCKED=1) must not durably mutate this home's state, so it
  # reprints the line every time rather than writing the marker - the same
  # convention the TANGLE line's read-only wording follows.
  local home out1 out2
  home=$(make_home "$TMP_ROOT/lock-refused")
  out1=$(FM_TEST_DETECT_ONLY=1 run_bootstrap_under_claude "$home" "$TMP_ROOT/no-such-config" --permission-mode auto)
  assert_contains "$out1" "CLAUDE_PRIMARY_AUTO_MODE:" "a lock-refused run must still surface the diagnostic"
  assert_absent "$home/state/.claude-primary-auto-mode-notified" \
    "a lock-refused run must not write the durable one-shot marker"
  out2=$(FM_TEST_DETECT_ONLY=1 run_bootstrap_under_claude "$home" "$TMP_ROOT/no-such-config" --permission-mode auto)
  assert_contains "$out2" "CLAUDE_PRIMARY_AUTO_MODE:" \
    "a second lock-refused run must reprint, since nothing was persisted"
  pass "a lock-refused run reprints the diagnostic every time instead of persisting the marker"
}

test_auto_mode_without_rules_prints_one_line
test_auto_mode_with_rules_present_is_silent
test_other_confirmed_mode_is_silent
test_undeterminable_mode_is_silent
test_one_shot_marker_suppresses_a_second_run
test_lock_refused_run_reprints_without_persisting
