#!/usr/bin/env bash
# tests/fm-backend-herdr-prune-safety-e2e.test.sh - isolated real-herdr
# regression test for the 2026-07-02 self-kill incident and its fix
# (bin/backends/herdr.sh's created-vs-adopted default-tab-prune gate; see
# docs/herdr-backend.md "Default-tab prune" / the incident writeup there).
#
# Reproduces the exact collision shape against a private, throwaway
# HERDR_SESSION (never the captain's default): a startup-workspace-shaped
# layout - one tab labeled "1" in a pre-existing workspace labeled
# "firstmate" - with a live long-running process in that pane, exactly as
# the captain's own live crewmate session looked at incident time. Then
# drives the real spawn-time container_ensure +
# create_task path and asserts the live pane (and its live process) survive
# untouched. Also exercises the normal happy path (a genuinely fresh
# workspace's seeded default tab gets pruned, leaving exactly one clean
# fm-<id> task tab), mirroring tests/fm-backend-herdr-smoke.test.sh's broader
# coverage but scoped tightly to this one safety property.
#
# Safety (tests/herdr-test-safety.sh): cleanup uses ONLY
# herdr_safe_stop_and_delete, never a bare/inline-prefixed `herdr server
# stop` - the exact category of unscoped destructive call that caused the
# 2026-07-02 incident in the first place.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

SESSION="fm-lab-prune-safety-e2e-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-prune-safety.XXXXXX")
cleanup_all() {
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$SCRATCH"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

fm_backend_herdr_version_check || fail "version_check failed against the real installed herdr"

# --- 1. reproduce the label-collision startup-workspace shape ---------------
# Explicitly label the startup workspace "firstmate" to create the collision
# deterministically. Herdr's unlabeled workspace-label derivation is not a
# stable test contract, while the adopted-workspace state is the behavior
# this regression must exercise. The seeded tab remains labeled "1".

LIVE_CWD="$SCRATCH/firstmate"
mkdir -p "$LIVE_CWD"

fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the isolated session's server"

CREATE_OUT=$(fm_backend_herdr_cli "$SESSION" workspace create --cwd "$LIVE_CWD" --label firstmate --no-focus) \
  || fail "could not create the label-collision startup workspace"
LIVE_WSID=$(printf '%s' "$CREATE_OUT" | jq -r '.result.workspace.workspace_id // empty')
LIVE_TAB_ID=$(printf '%s' "$CREATE_OUT" | jq -r '.result.tab.tab_id // empty')
LIVE_PANE_ID=$(printf '%s' "$CREATE_OUT" | jq -r '.result.root_pane.pane_id // empty')
if [ -z "$LIVE_WSID" ] || [ -z "$LIVE_TAB_ID" ] || [ -z "$LIVE_PANE_ID" ]; then
  fail "could not parse the startup workspace's ids from workspace create: $CREATE_OUT"
fi

LIVE_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$LIVE_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$LIVE_LABEL" = firstmate ] || fail "the startup workspace label should be 'firstmate', got '$LIVE_LABEL' - repro setup is wrong"
pass "repro setup: a pre-existing workspace labeled 'firstmate' collides with the primary home's own label"

# Simulate a live long-running agent in that pane: a heartbeat loop that
# appends to a marker file, so liveness is independently verifiable (not just
# "the pane object still exists").
MARKER="$SCRATCH/heartbeat.log"
fm_backend_herdr_cli "$SESSION" pane run "$LIVE_PANE_ID" \
  "sh -c 'while true; do date +%s >> $MARKER; sleep 1; done'" >/dev/null 2>&1 \
  || fail "could not start the live heartbeat process in the startup workspace's pane"
sleep 2
[ -s "$MARKER" ] || fail "the live heartbeat process did not start writing its marker file"
BEFORE_COUNT=$(wc -l < "$MARKER" | tr -d '[:space:]')
pass "repro setup: a live long-running process is running in the startup workspace's single tab (label '1'), heartbeating to a marker file"

# --- 2. run the real spawn-time path: container_ensure adopts the startup --
# workspace by label match; create_task must NOT prune its tab.

RAW=$(fm_backend_herdr_container_ensure "$LIVE_CWD") || fail "container_ensure failed"
CONTAINER=${RAW%%$'\t'*}
SEEDED_TAB_ID=${RAW#*$'\t'}
[ "$CONTAINER" = "$SESSION:$LIVE_WSID" ] || fail "container_ensure should have ADOPTED the pre-existing label-colliding workspace ($LIVE_WSID), got '$CONTAINER'"
[ -z "$SEEDED_TAB_ID" ] || fail "an ADOPTED workspace must report an EMPTY seeded default tab id (the created-vs-adopted gate), got '$SEEDED_TAB_ID' - this is exactly what would reproduce the 2026-07-02 self-kill"
pass "fixed: container_ensure adopts the label-colliding startup workspace and reports NO seeded default tab (never a prune candidate)"

TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" fm-prunesafety-e2e "$LIVE_CWD" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r NEW_TAB_ID NEW_PANE_ID <<EOF
$TASK_IDS
EOF
if [ -z "$NEW_TAB_ID" ] || [ -z "$NEW_PANE_ID" ]; then
  fail "create_task did not return tab/pane ids"
fi

# --- 3. assert the live pane survived untouched -----------------------------

if ! herdr pane get "$LIVE_PANE_ID" --session "$SESSION" >/dev/null 2>&1; then
  fail "REGRESSION (2026-07-02 self-kill): the live startup-workspace pane was CLOSED by create_task"
fi
sleep 2
AFTER_COUNT=$(wc -l < "$MARKER" | tr -d '[:space:]')
[ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ] \
  || fail "REGRESSION: the live heartbeat process stopped writing after create_task ran - it was killed even though its pane object survived"
pass "fixed: the live pane (and its live process) survived create_task untouched - the exact 2026-07-02 self-kill incident does not reproduce"

LIVE_TABS_AFTER=$(herdr tab list --workspace "$LIVE_WSID" --session "$SESSION" 2>&1)
printf '%s' "$LIVE_TABS_AFTER" | jq -e --arg t "$LIVE_TAB_ID" '.result.tabs[] | select(.tab_id == $t)' >/dev/null 2>&1 \
  || fail "REGRESSION: the startup workspace's original live tab is gone from tab list"
pass "fixed: the startup workspace's original live tab is still present in tab list after the spawn"

fm_backend_herdr_kill "$SESSION:$NEW_PANE_ID"
fm_backend_herdr_kill "$SESSION:$LIVE_PANE_ID"

# --- 4. happy path still works: a genuinely fresh workspace gets its seeded -
# default tab pruned, leaving exactly one clean fm-<id> task tab -------------

HAPPY_CWD="$SCRATCH/happy-project"
mkdir -p "$HAPPY_CWD"
HAPPY_RAW=$(fm_backend_herdr_container_ensure "$HAPPY_CWD") || fail "happy-path container_ensure failed"
HAPPY_CONTAINER=${HAPPY_RAW%%$'\t'*}
HAPPY_SEEDED=${HAPPY_RAW#*$'\t'}
[ -n "$HAPPY_SEEDED" ] || fail "happy path: expected a genuinely fresh workspace with a non-empty seeded default tab id"

HAPPY_TASK_IDS=$(fm_backend_herdr_create_task "$HAPPY_CONTAINER" fm-prunesafety-happy "$HAPPY_CWD" "$HAPPY_SEEDED") \
  || fail "happy-path create_task failed"
read -r _HAPPY_TAB HAPPY_PANE <<EOF
$HAPPY_TASK_IDS
EOF
[ -n "$HAPPY_PANE" ] || fail "happy-path create_task did not return a pane id"

HAPPY_WSID=${HAPPY_CONTAINER#*:}
HAPPY_TABS=$(herdr tab list --workspace "$HAPPY_WSID" --session "$SESSION" 2>&1)
HAPPY_COUNT=$(printf '%s' "$HAPPY_TABS" | jq -r '.result.tabs? // [] | length')
[ "$HAPPY_COUNT" = 1 ] || fail "happy path: expected exactly 1 tab (seeded default pruned) after the first real task tab, got $HAPPY_COUNT: $HAPPY_TABS"
printf '%s' "$HAPPY_TABS" | jq -e --arg t "$HAPPY_SEEDED" '.result.tabs[] | select(.tab_id == $t)' >/dev/null 2>&1 \
  && fail "happy path: the seeded default tab should have been pruned but is still present: $HAPPY_TABS"
pass "happy path: a genuinely fresh workspace's seeded default tab is still pruned, leaving exactly one clean fm-<id> task tab"

fm_backend_herdr_kill "$SESSION:$HAPPY_PANE"

cleanup_all
trap - EXIT
