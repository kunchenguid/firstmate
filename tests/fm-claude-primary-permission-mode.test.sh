#!/usr/bin/env bash
# Behavior tests for bin/fm-harness.sh's `claude-permission-mode` subcommand:
# the ps-based detector behind the "primary Claude Code session left in auto
# mode" bootstrap diagnostic (docs/configuration.md "Claude permission mode
# for the primary session").
#
# Every case drives a REAL process (a renamed copy of the ambient bash, kept
# alive with a builtin-only loop so bash never tail-exec-replaces itself into
# its last external command) so the walk exercises actual `ps` output rather
# than a stubbed answer - the same technique tests/fm-harness-precedence.test.sh
# uses for its own real-process cases. No installed harness is required.
#
# The facts pinned here are exactly the ones the brief and the fetched Claude
# Code docs called out as easy to get wrong:
#   1. `--permission-mode <mode>` (space form) and `--permission-mode=<mode>`
#      (equals form) both name the mode directly, and `--dangerously-skip-
#      permissions` means "bypass" even with no --permission-mode flag.
#   2. With NEITHER CLI flag present, the only other place Claude Code takes
#      "auto" or "bypassPermissions" from is the USER settings file - never a
#      project's .claude/settings.json or .claude/settings.local.json, which
#      the docs say those two specific values are silently ignored from.
#   3. Every other permission mode value (acceptEdits, manual, dontAsk, plan)
#      still applies from any settings file, so a project-level acceptEdits is
#      irrelevant to this detector regardless - it only ever prints "auto" or
#      "bypass" (see the bootstrap diagnostic; nothing else is actionable).
#   4. The detector must never guess: with no claude ancestor found, no flag,
#      and no matching user setting, it prints NOTHING, not a "default" token -
#      the caller (bin/fm-bootstrap.sh) fails quiet on that silence rather than
#      acting on an unconfirmed mode.
#   5. A launcher's own free-form text (a crewmate's brief, appended via
#      --append-system-prompt) must never be misread as a flag: the search is
#      bounded to the command-line prefix before that argument.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-primary-permission-mode)

# A real process comm-named "claude": a copy (not a symlink) of the ambient
# bash, which fm-harness-precedence.test.sh's own named_bin() already relies
# on being ad-hoc signed and runnable from an arbitrary path. Kept alive with
# `while :; do :; done` - a builtin-only loop, so bash never exec-replaces
# itself into its last external command the way it would for a simple `-c
# 'sleep N'` script, which would leave `sleep` and not `claude` as the comm.
claude_bin() {
  local dir=$1
  mkdir -p "$dir"
  cp "$(command -v bash)" "$dir/claude"
  printf '%s\n' "$dir/claude"
}

# Launch a background process under the fake claude binary, with the given
# extra argv, and set LAUNCHED_PID. A plain function call (never `$(...)`),
# so `$!` and the later `kill`/`wait` in reap() see a direct child of the
# CALLING test function's own shell - not an orphan left behind by a command
# substitution subshell that already exited, which `wait` cannot reap and
# which would otherwise keep this script's own stdout/stderr open forever.
LAUNCHED_PID=
launch() {  # <bin> [argv...]
  local bin=$1
  shift
  "$bin" -c 'while :; do :; done' "$@" &
  LAUNCHED_PID=$!
}

reap() {  # <pid>
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

test_space_form_permission_mode() {
  local bin pid got
  bin=$(claude_bin "$TMP_ROOT/space")
  launch "$bin" --permission-mode auto
  pid=$LAUNCHED_PID
  sleep 0.3
  got=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/no-such-config" "$HARNESS" claude-permission-mode "$pid")
  reap "$pid"
  assert_equals auto "$got" "space-form --permission-mode auto must report auto"
  pass "space-form --permission-mode auto reports auto"
}

test_equals_form_permission_mode() {
  local bin pid got
  bin=$(claude_bin "$TMP_ROOT/equals")
  launch "$bin" --permission-mode=acceptEdits
  pid=$LAUNCHED_PID
  sleep 0.3
  got=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/no-such-config" "$HARNESS" claude-permission-mode "$pid")
  reap "$pid"
  assert_equals acceptEdits "$got" "equals-form --permission-mode=acceptEdits must report acceptEdits"
  pass "equals-form --permission-mode=acceptEdits reports acceptEdits"
}

test_dangerously_skip_permissions_is_bypass() {
  local bin pid got
  bin=$(claude_bin "$TMP_ROOT/bypass")
  launch "$bin" --dangerously-skip-permissions
  pid=$LAUNCHED_PID
  sleep 0.3
  got=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/no-such-config" "$HARNESS" claude-permission-mode "$pid")
  reap "$pid"
  assert_equals bypass "$got" "--dangerously-skip-permissions must report bypass"
  pass "--dangerously-skip-permissions reports bypass"
}

test_no_flag_no_settings_is_silent() {
  local bin pid got
  bin=$(claude_bin "$TMP_ROOT/silent")
  launch "$bin"
  pid=$LAUNCHED_PID
  sleep 0.3
  got=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/no-such-config" "$HARNESS" claude-permission-mode "$pid")
  reap "$pid"
  assert_equals '' "$got" "no CLI flag and no matching user setting must print nothing, never a guessed default"
  pass "no CLI flag and no user setting reports nothing"
}

test_user_settings_auto_fallback() {
  local bin pid got cfg
  bin=$(claude_bin "$TMP_ROOT/settings-auto")
  cfg="$TMP_ROOT/settings-auto-cfg"
  mkdir -p "$cfg"
  printf '%s' '{"permissions":{"defaultMode":"auto"}}' > "$cfg/settings.json"
  launch "$bin"
  pid=$LAUNCHED_PID
  sleep 0.3
  got=$(CLAUDE_CONFIG_DIR="$cfg" "$HARNESS" claude-permission-mode "$pid")
  reap "$pid"
  assert_equals auto "$got" "a user-settings permissions.defaultMode of auto must be read with no CLI flag present"
  pass "user settings permissions.defaultMode=auto is read as a fallback with no CLI flag"
}

test_user_settings_accept_edits_is_not_actionable_but_still_silent_correctly() {
  # acceptEdits is one of the "applies from any settings file" values per the
  # docs, but this detector only ever confirms auto/bypassPermissions from a
  # settings file (the two values a PROJECT file can't set), so a project- or
  # user-level acceptEdits with no CLI flag must stay silent here rather than
  # be misreported as some other mode.
  local bin pid got cfg
  bin=$(claude_bin "$TMP_ROOT/settings-accept")
  cfg="$TMP_ROOT/settings-accept-cfg"
  mkdir -p "$cfg"
  printf '%s' '{"permissions":{"defaultMode":"acceptEdits"}}' > "$cfg/settings.json"
  launch "$bin"
  pid=$LAUNCHED_PID
  sleep 0.3
  got=$(CLAUDE_CONFIG_DIR="$cfg" "$HARNESS" claude-permission-mode "$pid")
  reap "$pid"
  assert_equals '' "$got" "a settings-file acceptEdits value must not be reported by this auto/bypass-only detector"
  pass "user settings permissions.defaultMode=acceptEdits is not reported (not auto/bypassPermissions)"
}

test_brief_text_after_append_system_prompt_is_never_matched() {
  # The real risk this pins: fm-spawn.sh's own launch template carries a
  # crewmate's brief through --append-system-prompt as the LAST argument, and
  # that text is untrusted, model-readable content. A brief that happens to
  # contain the literal string "--permission-mode auto" must never be read as
  # the session's actual mode.
  local bin pid got
  bin=$(claude_bin "$TMP_ROOT/brief")
  launch "$bin" --dangerously-skip-permissions --append-system-prompt \
    'a brief that mentions --permission-mode auto and --permission-mode=plan in prose'
  pid=$LAUNCHED_PID
  sleep 0.3
  got=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/no-such-config" "$HARNESS" claude-permission-mode "$pid")
  reap "$pid"
  assert_equals bypass "$got" \
    "the real --dangerously-skip-permissions flag before --append-system-prompt must still win over brief-text noise after it"
  pass "flag text inside a brief after --append-system-prompt is never mistaken for a real flag"
}

test_brief_only_text_with_no_real_flag_is_silent() {
  local bin pid got
  bin=$(claude_bin "$TMP_ROOT/brief-only")
  launch "$bin" --append-system-prompt \
    'a brief that mentions --permission-mode auto in prose with no real flag before it'
  pid=$LAUNCHED_PID
  sleep 0.3
  got=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/no-such-config" "$HARNESS" claude-permission-mode "$pid")
  reap "$pid"
  assert_equals '' "$got" \
    "with no real flag before --append-system-prompt and no user setting, the brief text alone must not be read as a flag"
  pass "brief text alone, with no real flag before it, reports nothing"
}

test_space_form_permission_mode
test_equals_form_permission_mode
test_dangerously_skip_permissions_is_bypass
test_no_flag_no_settings_is_silent
test_user_settings_auto_fallback
test_user_settings_accept_edits_is_not_actionable_but_still_silent_correctly
test_brief_text_after_append_system_prompt_is_never_matched
test_brief_only_text_with_no_real_flag_is_silent
