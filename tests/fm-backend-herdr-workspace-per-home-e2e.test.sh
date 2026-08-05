#!/usr/bin/env bash
# tests/fm-backend-herdr-workspace-per-home-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for the P3 "workspace-per-home" pass (AGENTS.md
# task herdr-sm-spaces-k4). Drives the REAL bin/fm-spawn.sh and
# bin/fm-teardown.sh (not just adapter primitives), because the requirement
# under test - a --secondmate spawn's tab landing in the secondmate's OWN
# herdr workspace, and a crewmate spawned FROM a secondmate home landing there
# too - only exists at fm-spawn.sh's own home-shadowing logic (the herdr case
# arm) and at fm_backend_herdr_workspace_label's FM_HOME read; neither is
# exercised by the adapter-primitive smoke test.
#
# Mirrors tests/fm-backend-autodetect-smoke.test.sh's isolated-session
# convention: a private throwaway HERDR_SESSION (never the captain's
# default), scratch FM_HOME(s), and scratch local-only projects.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): cleanup uses
# ONLY herdr_safe_stop_and_delete, never a bare/inline-prefixed `herdr server
# stop`.
#
# Covers, at minimum (per the task brief):
#   - a primary-shaped home (no .fm-secondmate-home marker) spawning a
#     crewmate into the "firstmate" workspace
#   - a secondmate-shaped home (with .fm-secondmate-home) getting its own
#     labeled workspace when the PRIMARY spawns it (fm-spawn.sh's FM_HOME
#     shadow for --secondmate)
#   - a crewmate spawned FROM that secondmate-shaped home (the secondmate
#     running its OWN fm-spawn.sh) landing in the secondmate's own workspace -
#     this exact path has never run before this test
#   - teardown closing the right tab (and no other)
#   - list-live recovery seeing only its own home's tabs, for both homes
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}
assert_not_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

# TMP_ROOT is physically resolved (mktemp -d "$(pwd -P)"-relative) for the same
# low-noise scratch fixture shape used by
# tests/fm-backend-autodetect-smoke.test.sh.
# fm-spawn no longer needs this as a symlink workaround: fm-spawn-symlink-guard-s8
# canonicalized project and backend cwd comparisons in the worktree-discovery
# poll.
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-e2e.XXXXXX")
SESSION="fm-lab-herdr-e2e-$$"
export HERDR_SESSION="$SESSION"
WT1=; WT2=; WT3=; WT4=; WT5=; WT6=
cleanup_all() {
  local wt
  for wt in "$WT1" "$WT2" "$WT3" "$WT4" "$WT5" "$WT6"; do
    [ -n "$wt" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$wt" >/dev/null 2>&1
  done
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- scratch world: a primary-shaped home, a secondmate-shaped home, two projects ---

# This test asserts the per-home FLAT workspace shape, so both homes opt out of
# the default-on presentation projection rather than depending on that default.
PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/cm1" "$PRIMARY_HOME/config"
printf 'off\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
printf 'trivial e2e primary crewmate brief: nothing to do.\n' > "$PRIMARY_HOME/data/cm1/brief.md"

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/data/cm2" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf 'off\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf 'e2esm1\n' > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"
printf 'trivial e2e secondmate-owned crewmate brief: nothing to do.\n' > "$SM_HOME/data/cm2/brief.md"

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

PROJ1="$TMP_ROOT/scratch-project-1"; make_scratch_project "$PROJ1"
PROJ2="$TMP_ROOT/scratch-project-2"; make_scratch_project "$PROJ2"

# --- 1. primary-shaped home: a crewmate spawns into the "firstmate" space ---

CM1_OUT="$TMP_ROOT/cm1.out"; CM1_ERR="$TMP_ROOT/cm1.err"
# This spawn's raw launch command is not an agent herdr can register, so the
# display-naming touch has nothing to name. Its bounded readiness wait is cut
# short here so the suite does not pay for it three times over; the fail-open
# behavior it exercises is asserted right after the spawn.
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_BACKEND_HERDR_AGENT_NAME_POLLS=2 FM_BACKEND_HERDR_AGENT_NAME_INTERVAL=0.05 \
  "$ROOT/bin/fm-spawn.sh" cm1 "$PROJ1" "sh -c 'echo primary-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM1_OUT" 2>"$CM1_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "primary-shaped crewmate spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM1_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM1_ERR")"

CM1_META="$PRIMARY_HOME/state/cm1.meta"
[ -f "$CM1_META" ] || fail "no meta written for cm1"
assert_contains_local "$(cat "$CM1_META")" "backend=herdr" "cm1 meta missing backend=herdr"
WT1=$(grep '^worktree=' "$CM1_META" | cut -d= -f2-)
CM1_PANE=$(grep '^herdr_pane_id=' "$CM1_META" | cut -d= -f2-)
[ -n "$CM1_PANE" ] || fail "cm1 meta missing herdr_pane_id"
pass "real herdr E2E: a primary-shaped home spawns a crewmate on the herdr backend"

# Display naming is presentation only: a launch herdr never registers as an
# agent cannot be named, and that must cost the spawn nothing.
assert_contains_local "$(cat "$CM1_ERR")" "registered no agent" \
  "an unnameable launch should say so on stderr rather than silently doing nothing"
assert_not_contains_local "$(cat "$CM1_META")" "agent_name=" \
  "no agent_name may be recorded when no name was actually assigned"
pass "real herdr E2E: a launch herdr cannot name still spawns successfully, warns, and records no agent_name"

sleep 1
CM1_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM1_PANE" 30) || fail "capture failed on cm1's pane"
assert_contains_local "$CM1_CAPTURE" "primary-crew-ok" "cm1's raw launch command did not run in its herdr pane"

CM1_WSID=$(herdr pane get "$CM1_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM1_WSID" ] || fail "could not read cm1's pane workspace_id"
CM1_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM1_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM1_WS_LABEL" = "firstmate" ] || fail "a primary-shaped home's crewmate should land in the 'firstmate' workspace, got '$CM1_WS_LABEL'"
pass "real herdr E2E: the primary-shaped home's crewmate landed in the 'firstmate' workspace"

# --- 2. the PRIMARY spawns a secondmate: its tab lands in the SECONDMATE's own space ---
# (fm-spawn.sh's herdr case arm shadows FM_HOME to the secondmate's home for
# exactly this call - AGENTS.md task herdr-sm-spaces-k4, requirement 3.)

SM_OUT="$TMP_ROOT/sm.out"; SM_ERR="$TMP_ROOT/sm.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_BACKEND_HERDR_AGENT_NAME_POLLS=2 FM_BACKEND_HERDR_AGENT_NAME_INTERVAL=0.05 \
  "$ROOT/bin/fm-spawn.sh" e2esm1 "$SM_HOME" "sh -c 'echo secondmate-launch-ok'" --secondmate --backend herdr \
  >"$SM_OUT" 2>"$SM_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the primary's --secondmate spawn of e2esm1 failed"$'\n'"--- stdout ---"$'\n'"$(cat "$SM_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$SM_ERR")"

SM_META="$PRIMARY_HOME/state/e2esm1.meta"
[ -f "$SM_META" ] || fail "no meta written for e2esm1 (recorded in the PRIMARY's own state dir, since the primary did the spawning)"
assert_contains_local "$(cat "$SM_META")" "kind=secondmate" "e2esm1 meta missing kind=secondmate"
assert_contains_local "$(cat "$SM_META")" "backend=herdr" "e2esm1 meta missing backend=herdr"
assert_contains_local "$(cat "$SM_META")" "home=$SM_HOME" "e2esm1 meta does not record its own home"
SM_PANE=$(grep '^herdr_pane_id=' "$SM_META" | cut -d= -f2-)
[ -n "$SM_PANE" ] || fail "e2esm1 meta missing herdr_pane_id"
pass "real herdr E2E: the primary spawns a --secondmate task on the herdr backend"

SM_WSID=$(herdr pane get "$SM_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$SM_WSID" ] || fail "could not read e2esm1's pane workspace_id"
[ "$SM_WSID" != "$CM1_WSID" ] || fail "the secondmate's tab must NOT land in the primary's workspace, but it shares $CM1_WSID"
SM_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$SM_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$SM_WS_LABEL" = "2ndmate-e2esm1" ] || fail "a --secondmate spawn should land in '2ndmate-<id>', got '$SM_WS_LABEL'"
pass "real herdr E2E: a --secondmate spawn by the PRIMARY lands in the SECONDMATE's own labeled workspace, distinct from the primary's"

# --- 3. a crewmate spawned FROM the secondmate-shaped home lands in the SAME
# secondmate workspace (this exact path has never run before this test) -----

CM2_OUT="$TMP_ROOT/cm2.out"; CM2_ERR="$TMP_ROOT/cm2.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$SM_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_BACKEND_HERDR_AGENT_NAME_POLLS=2 FM_BACKEND_HERDR_AGENT_NAME_INTERVAL=0.05 \
  "$ROOT/bin/fm-spawn.sh" cm2 "$PROJ2" "sh -c 'echo sm-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM2_OUT" 2>"$CM2_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "a crewmate spawned FROM the secondmate-shaped home failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM2_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM2_ERR")"

CM2_META="$SM_HOME/state/cm2.meta"
[ -f "$CM2_META" ] || fail "no meta written for cm2 (recorded in the SECONDMATE's own state dir - it did its own spawning)"
assert_contains_local "$(cat "$CM2_META")" "backend=herdr" "cm2 meta missing backend=herdr"
WT2=$(grep '^worktree=' "$CM2_META" | cut -d= -f2-)
CM2_PANE=$(grep '^herdr_pane_id=' "$CM2_META" | cut -d= -f2-)
[ -n "$CM2_PANE" ] || fail "cm2 meta missing herdr_pane_id"
pass "real herdr E2E: a crewmate spawns successfully FROM a secondmate-shaped home's own fm-spawn.sh process"

sleep 1
CM2_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM2_PANE" 30) || fail "capture failed on cm2's pane"
assert_contains_local "$CM2_CAPTURE" "sm-crew-ok" "cm2's raw launch command did not run in its herdr pane"

CM2_WSID=$(herdr pane get "$CM2_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM2_WSID" = "$SM_WSID" ] || fail "a crewmate spawned FROM the secondmate home should land in the SAME workspace as the secondmate's own task ($SM_WSID), got '$CM2_WSID'"
[ "$CM2_WSID" != "$CM1_WSID" ] || fail "a crewmate spawned FROM the secondmate home must NOT land in the primary's workspace"
pass "real herdr E2E: a crewmate spawned FROM the secondmate-shaped home lands in the secondmate's OWN workspace - falls out of per-home resolution, no glue needed"

# --- 4. list-live recovery: each home sees only its own tabs ---------------

PRIMARY_LIVE=$(FM_HOME="$PRIMARY_HOME" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$PRIMARY_LIVE" "fm-cm1" "the primary home's list_live did not see its own task"
assert_not_contains_local "$PRIMARY_LIVE" "fm-e2esm1" "the primary home's list_live must not see the secondmate's own task"
assert_not_contains_local "$PRIMARY_LIVE" "fm-cm2" "the primary home's list_live must not see the secondmate-owned crewmate's task"
pass "real herdr E2E: list_live from the primary's own context sees only the primary's own task"

SM_LIVE=$(FM_HOME="$SM_HOME" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$SM_LIVE" "fm-e2esm1" "the secondmate home's list_live did not see its own task"
assert_contains_local "$SM_LIVE" "fm-cm2" "the secondmate home's list_live did not see the crewmate spawned from it"
assert_not_contains_local "$SM_LIVE" "fm-cm1" "the secondmate home's list_live must not see the primary's task"
pass "real herdr E2E: list_live from the secondmate's own context sees only tasks in the secondmate's own workspace (both its own tab and its crewmate's)"

# --- 5. teardown closes the RIGHT tab, and no other ------------------------

TD1_OUT="$TMP_ROOT/td1.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" FM_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" cm1 >"$TD1_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for the primary-shaped crewmate cm1"$'\n'"$(cat "$TD1_OUT")"
[ -f "$CM1_META" ] && fail "fm-teardown.sh did not remove cm1's meta"
if herdr pane get "$CM1_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close cm1's pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed the secondmate's OWN pane (wrong tab closed)"
fi
if ! herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed cm2's pane (wrong tab closed)"
fi
WT1=
pass "real herdr E2E: tearing down cm1 closes only its own tab - the secondmate's and cm2's tabs survive untouched"

TD2_OUT="$TMP_ROOT/td2.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$SM_HOME/state" FM_DATA_OVERRIDE="$SM_HOME/data" \
  FM_CONFIG_OVERRIDE="$SM_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" cm2 >"$TD2_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for the secondmate-owned crewmate cm2"$'\n'"$(cat "$TD2_OUT")"
[ -f "$CM2_META" ] && fail "fm-teardown.sh did not remove cm2's meta"
if herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close cm2's pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm2 must not have closed the secondmate's OWN pane (wrong tab closed)"
fi
WT2=
pass "real herdr E2E: tearing down cm2 closes only its own tab - the secondmate's own tab (same workspace) survives untouched"

fm_backend_herdr_kill "$SESSION:$SM_PANE"

# --- 6. agent display names, end to end through the real fm-spawn.sh --------
#
# The captain's ask is that two workers stop reading as the same sidebar entry,
# so the assertion that matters is on two REAL spawns: each carries a distinct
# roster name herdr itself reports back, and each records that name in its own
# durable metadata.
#
# The launch command is a stub whose command line herdr's own agent detection
# recognizes, so the naming path runs for real without spending a live harness.
# If a future herdr stops registering it, the guard below fails loudly naming
# the version rather than passing over an unexercised path.

STUB_BIN="$TMP_ROOT/stubbin"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nsleep 600\n' > "$STUB_BIN/claude"
chmod +x "$STUB_BIN/claude"

spawn_named_crewmate() {  # <id> -> echoes "<pane>|<agent_name>"
  local id=$1 out err rc meta pane name
  mkdir -p "$PRIMARY_HOME/data/$id"
  printf 'trivial e2e naming brief: nothing to do.\n' > "$PRIMARY_HOME/data/$id/brief.md"
  out="$TMP_ROOT/$id.out"; err="$TMP_ROOT/$id.err"
  FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ1" "sh -c '$STUB_BIN/claude'" \
    --mode no-mistakes --yolo off --backend herdr >"$out" 2>"$err"
  rc=$?
  [ "$rc" -eq 0 ] || fail "naming-scenario spawn $id failed"$'\n'"--- stdout ---"$'\n'"$(cat "$out")"$'\n'"--- stderr ---"$'\n'"$(cat "$err")"
  meta="$PRIMARY_HOME/state/$id.meta"
  pane=$(grep '^herdr_pane_id=' "$meta" | cut -d= -f2-)
  name=$(grep '^agent_name=' "$meta" | cut -d= -f2-)
  if [ -z "$name" ]; then
    fail "spawn $id recorded no agent_name= (herdr $(herdr --version 2>/dev/null | head -n 1) did not register the stub agent this test depends on, or naming regressed)"$'\n'"--- stderr ---"$'\n'"$(cat "$err")"
  fi
  printf '%s|%s' "$pane" "$name"
}

NAMED3=$(spawn_named_crewmate cm3)
CM3_PANE=${NAMED3%%|*}; CM3_NAME=${NAMED3##*|}
WT3=$(grep '^worktree=' "$PRIMARY_HOME/state/cm3.meta" | cut -d= -f2-)
CM3_LIVE_NAME=$(herdr agent get "$CM3_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.name // empty')
[ "$CM3_LIVE_NAME" = "$CM3_NAME" ] \
  || fail "herdr reports '$CM3_LIVE_NAME' for cm3's pane but its metadata records '$CM3_NAME'"
pass "real herdr E2E: a spawned crewmate carries the roster name '$CM3_NAME' in herdr and in its own metadata"

NAMED4=$(spawn_named_crewmate cm4)
CM4_PANE=${NAMED4%%|*}; CM4_NAME=${NAMED4##*|}
WT4=$(grep '^worktree=' "$PRIMARY_HOME/state/cm4.meta" | cut -d= -f2-)
CM4_LIVE_NAME=$(herdr agent get "$CM4_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.name // empty')
[ "$CM4_LIVE_NAME" = "$CM4_NAME" ] \
  || fail "herdr reports '$CM4_LIVE_NAME' for cm4's pane but its metadata records '$CM4_NAME'"
[ "$CM4_NAME" != "$CM3_NAME" ] \
  || fail "two live spawns must not share a display name, both got '$CM3_NAME'"
pass "real herdr E2E: a second spawn gets a different name ('$CM3_NAME' and '$CM4_NAME'), so the captain can tell workers apart"

fm_backend_herdr_kill "$SESSION:$CM3_PANE"
fm_backend_herdr_kill "$SESSION:$CM4_PANE"

# --- 7. a configured blank workspace label, end to end ----------------------
#
# The primary label is a placement resolver, so a captain who renamed that
# workspace has to be able to tell Firstmate what it is now - including a blank
# label, chosen so the sidebar's emphasis falls on the agent names beside it.
# What must hold is that workers land in THAT workspace and a second spawn
# reuses it rather than minting another.

BLANK_HOME="$TMP_ROOT/blank-label-home"
mkdir -p "$BLANK_HOME/state" "$BLANK_HOME/data/cm5" "$BLANK_HOME/data/cm6" "$BLANK_HOME/config"
printf 'off\n' > "$BLANK_HOME/config/herdr-presentation-spaces"
printf ' \n' > "$BLANK_HOME/config/herdr-workspace-label"
printf 'trivial e2e blank-label brief: nothing to do.\n' > "$BLANK_HOME/data/cm5/brief.md"
printf 'trivial e2e blank-label brief: nothing to do.\n' > "$BLANK_HOME/data/cm6/brief.md"

spawn_blank_label_crewmate() {  # <id> -> echoes the pane id
  local id=$1 out err rc
  out="$TMP_ROOT/$id.out"; err="$TMP_ROOT/$id.err"
  FM_SPAWN_NO_GUARD=1 FM_HOME="$BLANK_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BACKEND_HERDR_AGENT_NAME_POLLS=2 FM_BACKEND_HERDR_AGENT_NAME_INTERVAL=0.05 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ1" "sh -c 'echo blank-label-ok'" \
    --mode no-mistakes --yolo off --backend herdr >"$out" 2>"$err"
  rc=$?
  [ "$rc" -eq 0 ] || fail "blank-label spawn $id failed"$'\n'"--- stdout ---"$'\n'"$(cat "$out")"$'\n'"--- stderr ---"$'\n'"$(cat "$err")"
  grep '^herdr_pane_id=' "$BLANK_HOME/state/$id.meta" | cut -d= -f2-
}

CM5_PANE=$(spawn_blank_label_crewmate cm5)
WT5=$(grep '^worktree=' "$BLANK_HOME/state/cm5.meta" | cut -d= -f2-)
CM5_WSID=$(herdr pane get "$CM5_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM5_WSID" ] || fail "could not read cm5's pane workspace_id"
CM5_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM5_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM5_WS_LABEL" = " " ] || fail "a home configured with a blank label should use exactly that label, got '$CM5_WS_LABEL'"
[ "$CM5_WSID" != "$CM1_WSID" ] || fail "the blank-labeled workspace must be distinct from the default 'firstmate' one"
pass "real herdr E2E: a home configured with a blank workspace label creates and uses exactly that workspace"

CM6_PANE=$(spawn_blank_label_crewmate cm6)
WT6=$(grep '^worktree=' "$BLANK_HOME/state/cm6.meta" | cut -d= -f2-)
CM6_WSID=$(herdr pane get "$CM6_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM6_WSID" = "$CM5_WSID" ] \
  || fail "a second spawn must resolve the same blank-labeled workspace ($CM5_WSID), not mint another, got '$CM6_WSID'"
BLANK_WS_COUNT=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r '[.result.workspaces[]? | select(.label == " ")] | length')
[ "$BLANK_WS_COUNT" = 1 ] || fail "exactly one blank-labeled workspace should exist, got $BLANK_WS_COUNT"
pass "real herdr E2E: a second spawn reuses the blank-labeled workspace instead of creating a duplicate"

fm_backend_herdr_kill "$SESSION:$CM5_PANE"
fm_backend_herdr_kill "$SESSION:$CM6_PANE"

cleanup_all
trap - EXIT
