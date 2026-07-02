#!/usr/bin/env bash
# Behavior tests for the crewmate-pane PWD re-export (fm-spawn PWD fix).
#
# treehouse get's subshell has been observed to chdir() a crewmate's pane into
# its worktree correctly while leaving the pane's $PWD environment variable
# stale (e.g. literally "."). Every child process the pane spawns inherits that
# broken $PWD verbatim, including git push's post-receive hook chain, where
# no-mistakes' gate hook calls bare `pwd` (logical mode) and trusts $PWD without
# verifying it. fm-spawn now re-exports PWD from `pwd -P` (which ignores $PWD
# and resolves the real physical cwd) into the pane right after GOTMPDIR, for
# ship/scout launches only - secondmate panes never run treehouse get, since
# tmux's own -c sets their cwd directly at process start.
#
# This is a structural test: it asserts the contract lines are present in the
# source, in the right order and guarded correctly, matching the style of
# tests/fm-gotmp.test.sh rather than driving a live tmux session.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

test_pwd_export_present_and_guarded() {
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source strings
  grep -F 'export PWD="$(pwd -P)"' "$SPAWN" >/dev/null \
    || fail "fm-spawn PWD re-export must resolve via pwd -P, not bare pwd or \$PWD"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string
  grep -F 'spawn_send_text_line "$T" '\''export PWD="$(pwd -P)"'\''' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: PWD re-export sent into pane via spawn_send_text_line"
  pass "fm-spawn re-exports PWD via pwd -P into the pane"
}

test_pwd_export_ordered_after_gotmpdir_before_launch() {
  local gotmpdir_line pwd_line launch_line
  gotmpdir_line=$(grep -n 'export GOTMPDIR=' "$SPAWN" | head -1 | cut -d: -f1)
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source strings
  pwd_line=$(grep -n 'export PWD="\$(pwd -P)"' "$SPAWN" | head -1 | cut -d: -f1)
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string
  launch_line=$(grep -n 'spawn_send_literal "\$T" "\$LAUNCH"' "$SPAWN" | head -1 | cut -d: -f1)
  [ -n "$gotmpdir_line" ] || fail "could not locate GOTMPDIR export line"
  [ -n "$pwd_line" ] || fail "could not locate PWD re-export line"
  [ -n "$launch_line" ] || fail "could not locate LAUNCH send-keys line"
  [ "$gotmpdir_line" -lt "$pwd_line" ] \
    || fail "PWD re-export must come after GOTMPDIR export (gotmpdir=$gotmpdir_line pwd=$pwd_line)"
  [ "$pwd_line" -lt "$launch_line" ] \
    || fail "PWD re-export must land in the pane before the agent launch command (pwd=$pwd_line launch=$launch_line)"
  pass "fm-spawn sends PWD re-export after GOTMPDIR and before the agent launch"
}

test_pwd_export_scoped_to_non_secondmate() {
  # The PWD fix is scoped to ship/scout launches (which run treehouse get);
  # secondmate panes get their cwd from tmux's own -c flag, not a subshell, so
  # the export must be guarded by `[ "$KIND" != secondmate ]`.
  local guard_line pwd_line
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string
  guard_line=$(grep -n 'if \[ "\$KIND" != secondmate \]; then' "$SPAWN" | tail -1 | cut -d: -f1)
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source strings
  pwd_line=$(grep -n 'export PWD="\$(pwd -P)"' "$SPAWN" | head -1 | cut -d: -f1)
  [ -n "$guard_line" ] || fail "could not locate a KIND != secondmate guard near the PWD export"
  [ -n "$pwd_line" ] || fail "could not locate PWD re-export line"
  [ "$guard_line" -lt "$pwd_line" ] \
    || fail "PWD re-export must be inside a KIND != secondmate guard (guard=$guard_line pwd=$pwd_line)"
  pass "fm-spawn scopes the PWD re-export to non-secondmate (ship/scout) launches"
}

test_pwd_export_present_and_guarded
test_pwd_export_ordered_after_gotmpdir_before_launch
test_pwd_export_scoped_to_non_secondmate
