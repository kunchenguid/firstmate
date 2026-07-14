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

# TMP_ROOT is physically resolved (mktemp -d "$(pwd -P)"-relative) for the same
# low-noise scratch fixture shape used by
# tests/fm-backend-autodetect-smoke.test.sh.
# fm-spawn no longer needs this as a symlink workaround: fm-spawn-symlink-guard-s8
# canonicalized project and backend cwd comparisons in the worktree-discovery
# poll.
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-e2e.XXXXXX")
SESSION="fm-lab-herdr-e2e-$$"
export HERDR_SESSION="$SESSION"
WT1=; WT2=; WT3=
cleanup_all() {
  [ -n "$WT1" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT1" >/dev/null 2>&1
  [ -n "$WT2" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT2" >/dev/null 2>&1
  [ -n "$WT3" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT3" >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- scratch world: two independent primary homes, a secondmate home, three projects ---

PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/cm1" "$PRIMARY_HOME/config"
printf 'trivial e2e primary crewmate brief: nothing to do.\n' > "$PRIMARY_HOME/data/cm1/brief.md"

# A SECOND, independent primary home - no secondmate marker either, exactly like
# a captain running two separate firstmate installations (e.g. ~/code/firstmate
# and ~/code/firstmate-herdr) against the one machine-global herdr session. Both
# homes' labels used to be the bare constant "firstmate", so workspace_find
# adopted whichever space already existed and the two fleets' tabs commingled.
PRIMARY_HOME_B="$TMP_ROOT/primary-home-b"
mkdir -p "$PRIMARY_HOME_B/state" "$PRIMARY_HOME_B/data/cm3" "$PRIMARY_HOME_B/config"
printf 'trivial e2e second-primary crewmate brief: nothing to do.\n' > "$PRIMARY_HOME_B/data/cm3/brief.md"

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/data/cm2" "$SM_HOME/config" "$SM_HOME/projects"
# A real secondmate home is a worktree of the firstmate repo, so its own bin/
# holds the same scripts as the primary and its FM_ROOT is its own home. Model
# that faithfully with a bin symlink, so section 3 below can run the
# secondmate's own crewmate spawn out of the secondmate's own root ($SM_HOME,
# not the primary repo), exactly as the live secondmate would.
ln -s "$ROOT/bin" "$SM_HOME/bin"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf 'e2esm1\n' > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"
printf 'trivial e2e secondmate-owned crewmate brief: nothing to do.\n' > "$SM_HOME/data/cm2/brief.md"

# Expected home-tag workspace labels (bin/fm-backend-hometag-lib.sh), computed
# rather than hardcoded since each carries a path hash. Each is the hash of the
# home FM_HOME names - $PRIMARY_HOME for cm1, and the secondmate's OWN home for
# the secondmate workspace, which is what BOTH the primary's --secondmate spawn
# (shadowing FM_HOME to the secondmate home) and the secondmate's own crewmate
# spawn (its FM_HOME IS that home) resolve to.
EXPECTED_CM1_LABEL=$(FM_HOME="$PRIMARY_HOME" fm_backend_hometag)
EXPECTED_CM3_LABEL=$(FM_HOME="$PRIMARY_HOME_B" fm_backend_hometag)
EXPECTED_SM_LABEL=$(FM_HOME="$SM_HOME" fm_backend_hometag)

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
PROJ3="$TMP_ROOT/scratch-project-3"; make_scratch_project "$PROJ3"

# --- 1. primary-shaped home: a crewmate spawns into the "firstmate" space ---

CM1_OUT="$TMP_ROOT/cm1.out"; CM1_ERR="$TMP_ROOT/cm1.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm1 "$PROJ1" "sh -c 'echo primary-crew-ok'" --backend herdr \
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

sleep 1
CM1_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM1_PANE" 30) || fail "capture failed on cm1's pane"
assert_contains_local "$CM1_CAPTURE" "primary-crew-ok" "cm1's raw launch command did not run in its herdr pane"

CM1_WSID=$(herdr pane get "$CM1_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM1_WSID" ] || fail "could not read cm1's pane workspace_id"
CM1_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM1_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
case "$EXPECTED_CM1_LABEL" in firstmate-*) : ;; *) fail "test setup: the primary home-tag should be 'firstmate-<hash>', got '$EXPECTED_CM1_LABEL'" ;; esac
[ "$CM1_WS_LABEL" = "$EXPECTED_CM1_LABEL" ] || fail "a primary-shaped home's crewmate should land in the primary home-tag workspace ('$EXPECTED_CM1_LABEL'), got '$CM1_WS_LABEL'"
pass "real herdr E2E: the primary-shaped home's crewmate landed in its own 'firstmate-<hash>' workspace"

# --- 1b. a SECOND independent primary home: its crewmate lands in a DISTINCT
# workspace, not the first primary's (the multi-primary collision fix) --------

CM3_OUT="$TMP_ROOT/cm3.out"; CM3_ERR="$TMP_ROOT/cm3.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME_B" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm3 "$PROJ3" "sh -c 'echo primary-b-crew-ok'" --backend herdr \
  >"$CM3_OUT" 2>"$CM3_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the second primary home's crewmate spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM3_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM3_ERR")"

CM3_META="$PRIMARY_HOME_B/state/cm3.meta"
[ -f "$CM3_META" ] || fail "no meta written for cm3 (recorded in the SECOND primary's own state dir)"
WT3=$(grep '^worktree=' "$CM3_META" | cut -d= -f2-)
CM3_PANE=$(grep '^herdr_pane_id=' "$CM3_META" | cut -d= -f2-)
[ -n "$CM3_PANE" ] || fail "cm3 meta missing herdr_pane_id"

CM3_WSID=$(herdr pane get "$CM3_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM3_WSID" ] || fail "could not read cm3's pane workspace_id"
CM3_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM3_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
case "$EXPECTED_CM3_LABEL" in firstmate-*) : ;; *) fail "test setup: the second primary's home-tag should be 'firstmate-<hash>', got '$EXPECTED_CM3_LABEL'" ;; esac
[ "$EXPECTED_CM3_LABEL" != "$EXPECTED_CM1_LABEL" ] || fail "test setup: the two primary homes should hash to different tags"
[ "$CM3_WS_LABEL" = "$EXPECTED_CM3_LABEL" ] || fail "the second primary's crewmate should land in ITS OWN home-tag workspace ('$EXPECTED_CM3_LABEL'), got '$CM3_WS_LABEL'"
[ "$CM3_WSID" != "$CM1_WSID" ] || fail "two independent primary homes must not collapse into one shared workspace, but both tasks sit in $CM1_WSID"
pass "real herdr E2E: a SECOND independent primary home's crewmate lands in its own distinct 'firstmate-<hash>' workspace, not the first primary's"

# --- 2. the PRIMARY spawns a secondmate: its tab lands in the SECONDMATE's own space ---
# (fm-spawn.sh's herdr case arm shadows FM_HOME to the secondmate's home for
# exactly this call - AGENTS.md task herdr-sm-spaces-k4, requirement 3.)

SM_OUT="$TMP_ROOT/sm.out"; SM_ERR="$TMP_ROOT/sm.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
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
case "$EXPECTED_SM_LABEL" in 2ndmate-e2esm1-*) : ;; *) fail "test setup: the secondmate home-tag should be '2ndmate-e2esm1-<hash>', got '$EXPECTED_SM_LABEL'" ;; esac
[ "$SM_WS_LABEL" = "$EXPECTED_SM_LABEL" ] || fail "a --secondmate spawn should land in the secondmate home-tag workspace ('$EXPECTED_SM_LABEL'), got '$SM_WS_LABEL'"
pass "real herdr E2E: a --secondmate spawn by the PRIMARY lands in the SECONDMATE's own '2ndmate-<id>-<hash>' workspace, distinct from the primary's"

# --- 3. a crewmate spawned FROM the secondmate-shaped home lands in the SAME
# secondmate workspace (this exact path has never run before this test) -----

# FM_ROOT_OVERRIDE is the SECONDMATE's own home here, not $ROOT: a real
# secondmate runs its own fm-spawn.sh from its own home worktree, so its
# FM_ROOT IS its home. The bin symlink created above lets the real fm-spawn.sh
# script still resolve its helpers ($FM_ROOT/bin/*). cm2's workspace home-tag
# is the hash of the home FM_HOME names ($SM_HOME) - the same one the primary's
# --secondmate spawn computed when it shadowed FM_HOME to that home - so cm2
# adopts the SAME workspace instead of minting a second one.
CM2_OUT="$TMP_ROOT/cm2.out"; CM2_ERR="$TMP_ROOT/cm2.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$SM_HOME" FM_ROOT_OVERRIDE="$SM_HOME" \
  "$ROOT/bin/fm-spawn.sh" cm2 "$PROJ2" "sh -c 'echo sm-crew-ok'" --backend herdr \
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
assert_not_contains_local "$PRIMARY_LIVE" "fm-cm3" "the primary home's list_live must not see the OTHER primary home's task"
pass "real herdr E2E: list_live from the primary's own context sees only the primary's own task"

# The other half of the multi-primary fix: recovery in each primary home sees
# only its own fleet, where a shared bare-"firstmate" workspace would have shown
# each primary the other's tasks as if they were its own.
PRIMARY_B_LIVE=$(FM_HOME="$PRIMARY_HOME_B" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$PRIMARY_B_LIVE" "fm-cm3" "the second primary home's list_live did not see its own task"
assert_not_contains_local "$PRIMARY_B_LIVE" "fm-cm1" "the second primary home's list_live must not see the first primary's task"
assert_not_contains_local "$PRIMARY_B_LIVE" "fm-cm2" "the second primary home's list_live must not see the secondmate-owned crewmate's task"
pass "real herdr E2E: list_live from the second primary's own context sees only its own task, never the first primary's"

# FM_ROOT is the secondmate's own home here too (as its own recovery process
# would have it), and FM_HOME is what derives the home-tag: list_live resolves
# the SAME label the secondmate's workspace was created under, hashed over
# $SM_HOME.
SM_LIVE=$(FM_HOME="$SM_HOME" FM_ROOT="$SM_HOME" fm_backend_herdr_list_live "$SESSION")
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
if ! herdr pane get "$CM3_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed the OTHER primary home's pane (wrong tab closed)"
fi
WT1=
pass "real herdr E2E: tearing down cm1 closes only its own tab - the secondmate's, cm2's, and the other primary's tabs survive untouched"

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

TD3_OUT="$TMP_ROOT/td3.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME_B/state" FM_DATA_OVERRIDE="$PRIMARY_HOME_B/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME_B/config" \
  "$ROOT/bin/fm-teardown.sh" cm3 >"$TD3_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for the second primary home's crewmate cm3"$'\n'"$(cat "$TD3_OUT")"
if herdr pane get "$CM3_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close cm3's pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm3 must not have closed the secondmate's own pane (wrong tab closed)"
fi
WT3=
pass "real herdr E2E: tearing down cm3 from the second primary home closes only its own tab"

fm_backend_herdr_kill "$SESSION:$SM_PANE"

cleanup_all
trap - EXIT
