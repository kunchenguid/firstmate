#!/usr/bin/env bash
# Isolated real-Herdr E2E coverage for launch-argv persistence across a server
# restart.
#
# A crewmate is launched by typing its command into a pane's shell, so Herdr
# never receives the launch argv and has nothing to replay when it rebuilds the
# pane. This test pins the difference between the two creation paths against a
# real Herdr server, a real named-session lab, and a real stop/start cycle.
#
# COVERAGE LIMIT, deliberate and load-bearing to understand:
# this asserts that Herdr RECORDS the launch argv and that the record SURVIVES a
# real server restart. It does not assert that the restored process materialises
# carrying those flags. A headless restart rebuilds the pane without respawning
# the agent at all - the relaunch that strips flags in production is driven by a
# client attach or a server-global live handoff, and both are outside what the
# guarded lab session can reach. bin/fm-crew-state.sh's launch-drift detector is
# the runtime cover for that final step.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v claude >/dev/null 2>&1 || { echo "skip: claude not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }
if herdr agent start --help 2>/dev/null | grep -q -- '--pane <ID>'; then
  echo "skip: installed Herdr agent start no longer exposes the persisted launch-argv creation path"
  exit 0
fi

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-launch-argv) || fail "could not generate a lab session name"
LAB_CWD=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-launch-argv.XXXXXX")
STATE_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/sessions/$HERDR_LAB_SESSION/session.json"

# The marker keeps this test's process and persisted record distinguishable from
# any other Herdr session on the machine, including the operator's live fleet.
MARKER="$LAB_CWD/marker-treatment"
CONTROL_MARKER="$LAB_CWD/marker-control"
mkdir -p "$MARKER" "$CONTROL_MARKER"
EXPECTED_ARGV="claude --dangerously-skip-permissions --model opus --effort high --add-dir $MARKER"
CONTROL_ARGV="claude --dangerously-skip-permissions --model opus --effort high --add-dir $CONTROL_MARKER"

cleanup() {
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
  rm -rf "$LAB_CWD"
}
trap cleanup EXIT

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

recorded_argv() {  # <label>
  jq -r --arg label "$1" '
    [.workspaces[].tabs[].panes[] | select(.label == $label) | (.launch_argv // [] | join(" "))]
    | first // "ABSENT"
  ' "$STATE_JSON" 2>/dev/null
}

recorded_cwd() {  # <label>
  jq -r --arg label "$1" '
    [.workspaces[].tabs[].panes[] | select(.label == $label) | (.cwd // "")]
    | first // "ABSENT"
  ' "$STATE_JSON" 2>/dev/null
}

marker_process_present() {
  # shellcheck disable=SC2009 # Portable argv-substring probe for this E2E marker.
  ps -eo command | grep -Fq -- "--add-dir $MARKER"
}

# Read through the lab helper, never a bare herdr call: the helper is the only
# path that guarantees an explicit --session scope.
session_running() {
  lab session list --json 2>/dev/null \
    | jq -r --arg s "$HERDR_LAB_SESSION" '[.sessions[]|select(.name==$s)|.running]|first // "absent"'
}

# Once the lab server is down the helper can no longer reach that session at all,
# so a stopped server reads as either "false" or an unreachable "absent". Both
# mean not running; only a live "true" means the server is still up.
wait_for_session_stopped() {  # <seconds>
  local waited=0
  while [ "$waited" -lt "$1" ]; do
    [ "$(session_running)" = true ] || return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

wait_for_session_running() {  # <seconds>
  local waited=0
  while [ "$waited" -lt "$1" ]; do
    [ "$(session_running)" = true ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null 2>&1 \
  || fail "could not provision the isolated lab session"

WS=$(lab workspace create --cwd "$LAB_CWD" --label argvlab --no-focus 2>/dev/null \
  | jq -r '.result.workspace.id // .result.workspace.workspace_id // empty')
[ -n "$WS" ] || fail "lab workspace was not created"

# Control: the path firstmate uses today - create a plain tab, then type the
# launch command into its shell.
CONTROL=$(lab tab create --workspace "$WS" --cwd "$LAB_CWD" --label argvcontrol --no-focus 2>/dev/null)
CONTROL_PANE=$(printf '%s' "$CONTROL" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$CONTROL_PANE" ] || fail "control tab did not return a pane id"
lab pane run "$CONTROL_PANE" "$CONTROL_ARGV" >/dev/null 2>&1 \
  || fail "control pane did not accept the typed launch command"

# Treatment: hand Herdr the argv it is able to persist.
lab agent start argvtreatment --cwd "$LAB_CWD" --workspace "$WS" --no-focus \
  -- claude --dangerously-skip-permissions --model opus --effort high --add-dir "$MARKER" \
  >/dev/null 2>&1 || fail "agent start with an explicit argv was rejected"

# Let both panes reach a steady state and the server flush its snapshot.
sleep "${FM_HERDR_ARGV_SETTLE:-25}"

marker_process_present \
  || fail "the treatment agent never started; nothing to persist"

[ "$(recorded_argv argvcontrol)" = "ABSENT" ] \
  || fail "typed-command pane unexpectedly recorded a launch argv; the control no longer reproduces the defect"

BEFORE=$(recorded_argv argvtreatment)
[ "$BEFORE" = "$EXPECTED_ARGV" ] \
  || fail "agent start did not record the launch argv verbatim: got '$BEFORE'"

# A restored worker that keeps its flags but loses its working directory is still
# broken, and lands in the project checkout the workspace was created from, so the
# recorded cwd is held to the same standard as the argv.
BEFORE_CWD=$(recorded_cwd argvtreatment)
[ "$BEFORE_CWD" = "$LAB_CWD" ] \
  || fail "agent start did not record the launch cwd: expected '$LAB_CWD', got '$BEFORE_CWD'"
pass "herdr launch-argv: agent start records the full launch command and cwd, a typed command records no argv"

# A real stop and a real start, not a reload: the second provision is a fresh
# server process that has only the persisted snapshot to work from.
#
# The gate is the server going down, not the agent process dying. A stopped Herdr
# server orphans its agent processes rather than reaping them - verified live -
# so asserting on process death would be testing Herdr's teardown behaviour and
# would be flaky besides.
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null 2>&1 \
  || fail "guarded lab stop failed"
wait_for_session_stopped "${FM_HERDR_ARGV_STOP_TIMEOUT:-30}" \
  || fail "the lab server did not actually stop; this would not be a real restart"

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null 2>&1 \
  || fail "could not restart the lab session server"
wait_for_session_running "${FM_HERDR_ARGV_START_TIMEOUT:-30}" \
  || fail "the lab server did not come back up after the restart"
sleep "${FM_HERDR_ARGV_RESTART_SETTLE:-10}"

AFTER=$(recorded_argv argvtreatment)
[ "$AFTER" = "$EXPECTED_ARGV" ] \
  || fail "launch argv did not survive a real server restart: got '$AFTER'"
AFTER_CWD=$(recorded_cwd argvtreatment)
[ "$AFTER_CWD" = "$LAB_CWD" ] \
  || fail "launch cwd did not survive a real server restart: expected '$LAB_CWD', got '$AFTER_CWD'"
[ "$(recorded_argv argvcontrol)" = "ABSENT" ] \
  || fail "typed-command pane gained a launch argv across the restart"
pass "herdr launch-argv: the recorded launch command and cwd survive a real server restart"
