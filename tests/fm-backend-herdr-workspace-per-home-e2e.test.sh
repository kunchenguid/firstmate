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
WT1=; WT2=
cleanup_all() {
  [ -n "$WT1" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT1" >/dev/null 2>&1
  [ -n "$WT2" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT2" >/dev/null 2>&1
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
# The primary home opts in to human-readable task-tab labels, so its own
# crewmate (cm1) gets a "<short title> (<id>)" label and the flag inherits into
# the secondmate home at spawn convergence (primary-authoritative, so a local
# secondmate-home copy is not the way to opt a secondmate in).
PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/cm1" "$PRIMARY_HOME/config"
printf 'off\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
printf '' > "$PRIMARY_HOME/config/herdr-task-titles"
cat > "$PRIMARY_HOME/data/cm1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise primary-home Herdr placement.

## Firstmate spec
Verify the crewmate uses its primary home's workspace.
EOF

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/data/cm2" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf 'off\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf 'e2esm1\n' > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"
cat > "$SM_HOME/data/cm2/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise secondmate-owned Herdr placement.

## Firstmate spec
Verify the crewmate uses its secondmate home's workspace.
EOF

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

PROJ1="$TMP_ROOT/scratch-project-1"; make_scratch_project "$PROJ1"
PROJ2="$TMP_ROOT/scratch-project-2"; make_scratch_project "$PROJ2"

# --- 1. primary-shaped home: a crewmate spawns into the "firstmate" space ---

CM1_OUT="$TMP_ROOT/cm1.out"; CM1_ERR="$TMP_ROOT/cm1.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
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

sleep 1
CM1_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM1_PANE" 30) || fail "capture failed on cm1's pane"
assert_contains_local "$CM1_CAPTURE" "primary-crew-ok" "cm1's raw launch command did not run in its herdr pane"

CM1_WSID=$(herdr pane get "$CM1_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM1_WSID" ] || fail "could not read cm1's pane workspace_id"
CM1_TAB=$(grep '^herdr_tab_id=' "$CM1_META" | cut -d= -f2-)
[ -n "$CM1_TAB" ] || fail "cm1 meta missing herdr_tab_id"
CM1_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM1_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM1_WS_LABEL" = "firstmate" ] || fail "a primary-shaped home's crewmate should land in the 'firstmate' workspace, got '$CM1_WS_LABEL'"
pass "real herdr E2E: the primary-shaped home's crewmate landed in the 'firstmate' workspace"

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
SM_TAB=$(grep '^herdr_tab_id=' "$SM_META" | cut -d= -f2-)
[ -n "$SM_TAB" ] || fail "e2esm1 meta missing herdr_tab_id"
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
  "$ROOT/bin/fm-spawn.sh" cm2 "$PROJ2" "sh -c 'echo sm-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM2_OUT" 2>"$CM2_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "a crewmate spawned FROM the secondmate-shaped home failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM2_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM2_ERR")"

CM2_META="$SM_HOME/state/cm2.meta"
[ -f "$CM2_META" ] || fail "no meta written for cm2 (recorded in the SECONDMATE's own state dir - it did its own spawning)"
assert_contains_local "$(cat "$CM2_META")" "backend=herdr" "cm2 meta missing backend=herdr"
WT2=$(grep '^worktree=' "$CM2_META" | cut -d= -f2-)
CM2_TAB=$(grep '^herdr_tab_id=' "$CM2_META" | cut -d= -f2-)
[ -n "$CM2_TAB" ] || fail "cm2 meta missing herdr_tab_id"
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

# Labels follow the home that owns each endpoint: the opted-in primary labels
# its own crewmate with a human-readable title, the secondmate spawn inherits
# that opt-in into its own home (so its endpoint and its crewmate get human
# labels too), and standing the primary back down returns new workers to the
# historical fm-<id> default. Verify the real labels before adding explicit
# legacy-label fixtures for the compatibility checks below.
CM1_LABEL=$(herdr tab list --workspace "$CM1_WSID" --session "$SESSION" 2>/dev/null \
  | jq -r --arg tab "$CM1_TAB" '.result.tabs[]? | select(.tab_id == $tab) | .label')
SM_LABEL=$(herdr tab list --workspace "$SM_WSID" --session "$SESSION" 2>/dev/null \
  | jq -r --arg tab "$SM_TAB" '.result.tabs[]? | select(.tab_id == $tab) | .label')
CM2_LABEL=$(herdr tab list --workspace "$CM2_WSID" --session "$SESSION" 2>/dev/null \
  | jq -r --arg tab "$CM2_TAB" '.result.tabs[]? | select(.tab_id == $tab) | .label')
assert_contains_local "$CM1_LABEL" " (cm1)" "the opted-in primary home did not give its own worker a human-readable task label"
assert_not_contains_local "$CM1_LABEL" "fm-cm1" "the opted-in primary home's worker kept the legacy task label"
[ -f "$SM_HOME/config/herdr-task-titles" ] \
  || fail "the secondmate spawn did not inherit the primary's task-title opt-in before creating its endpoint"
assert_contains_local "$SM_LABEL" " (e2esm1)" "the inherited opt-in did not give the secondmate's own worker a human-readable task label"
assert_not_contains_local "$SM_LABEL" "fm-e2esm1" "the inherited opt-in still left the secondmate's own worker on the legacy task label"
assert_contains_local "$CM2_LABEL" " (cm2)" "the secondmate-owned crewmate did not receive a human-readable task label"
assert_not_contains_local "$CM2_LABEL" "fm-cm2" "the secondmate-owned crewmate kept the legacy task label"
pass "real herdr E2E: new workers on opted-in homes use human-readable labels with their exact task ids, and the opt-in inherits through the spawn"

# Standing the opt-in down returns new workers to the historical fm-<id>
# default without touching any live tab.
rm -f "$PRIMARY_HOME/config/herdr-task-titles"
mkdir -p "$PRIMARY_HOME/data/cm3"
cat > "$PRIMARY_HOME/data/cm3/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the stood-down label default.

## Firstmate spec
Verify the crewmate keeps the historical fm-<id> label.
EOF
CM3_OUT="$TMP_ROOT/cm3.out"; CM3_ERR="$TMP_ROOT/cm3.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm3 "$PROJ1" "sh -c 'echo primary-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM3_OUT" 2>"$CM3_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the stood-down default crewmate cm3 failed to spawn"$'\n'"--- stdout ---"$'\n'"$(cat "$CM3_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM3_ERR")"
CM3_META="$PRIMARY_HOME/state/cm3.meta"
[ -f "$CM3_META" ] || fail "no meta written for cm3"
CM3_PANE=$(grep '^herdr_pane_id=' "$CM3_META" | cut -d= -f2-)
[ -n "$CM3_PANE" ] || fail "cm3 meta missing herdr_pane_id"
CM3_TAB=$(grep '^herdr_tab_id=' "$CM3_META" | cut -d= -f2-)
[ -n "$CM3_TAB" ] || fail "cm3 meta missing herdr_tab_id"
CM3_WSID=$(herdr pane get "$CM3_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM3_WSID" = "$CM1_WSID" ] || fail "cm3 did not land in the primary's own workspace"
CM3_LABEL=$(herdr tab list --workspace "$CM3_WSID" --session "$SESSION" 2>/dev/null \
  | jq -r --arg tab "$CM3_TAB" '.result.tabs[]? | select(.tab_id == $tab) | .label')
[ "$CM3_LABEL" = "fm-cm3" ] \
  || fail "a stood-down home's new worker kept the historical fm-<id> default, got '$CM3_LABEL'"
CM1_LABEL_AFTER=$(herdr tab list --workspace "$CM1_WSID" --session "$SESSION" 2>/dev/null \
  | jq -r --arg tab "$CM1_TAB" '.result.tabs[]? | select(.tab_id == $tab) | .label')
[ "$CM1_LABEL_AFTER" = "$CM1_LABEL" ] \
  || fail "standing the opt-in down rewrote a live worker's task label"
pass "real herdr E2E: standing the task-title opt-in down restores the fm-<id> default for new workers and never renames live tabs"

# --- 4. list-live recovery: each home sees only its own tabs ---------------

# The primary's cm3 tab already wears the legacy fm-<id> label (its home stood
# the opt-in down), and these historical fixtures add one more legacy label to
# each home's workspace without renaming any newly-created worker pane.
herdr tab create --workspace "$CM1_WSID" --cwd "$TMP_ROOT" --label fm-cm1 --no-focus --session "$SESSION" >/dev/null \
  || fail "could not create the primary home's legacy list_live fixture"
herdr tab create --workspace "$SM_WSID" --cwd "$TMP_ROOT" --label fm-e2esm1 --no-focus --session "$SESSION" >/dev/null \
  || fail "could not create the secondmate home's first legacy list_live fixture"
herdr tab create --workspace "$SM_WSID" --cwd "$TMP_ROOT" --label fm-cm2 --no-focus --session "$SESSION" >/dev/null \
  || fail "could not create the secondmate home's second legacy list_live fixture"

PRIMARY_LIVE=$(FM_HOME="$PRIMARY_HOME" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$PRIMARY_LIVE" "$CM1_LABEL" "the primary home's list_live did not see its human-labeled task"
assert_contains_local "$PRIMARY_LIVE" "fm-cm3" "the primary home's list_live did not see its stood-down legacy task"
assert_contains_local "$PRIMARY_LIVE" "fm-cm1" "the primary home's list_live did not see its legacy fixture"
assert_not_contains_local "$PRIMARY_LIVE" "fm-e2esm1" "the primary home's list_live must not see the secondmate's own task"
assert_not_contains_local "$PRIMARY_LIVE" "fm-cm2" "the primary home's list_live must not see the secondmate-owned crewmate's task"
pass "real herdr E2E: list_live from the primary's own context sees only the primary's own task"

SM_LIVE=$(FM_HOME="$SM_HOME" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$SM_LIVE" "$SM_LABEL" "the secondmate home's list_live did not see its human-readable task"
assert_contains_local "$SM_LIVE" "$CM2_LABEL" "the secondmate home's list_live did not see its human-readable child task"
assert_contains_local "$SM_LIVE" "fm-e2esm1" "the secondmate home's list_live did not see its own task"
assert_contains_local "$SM_LIVE" "fm-cm2" "the secondmate home's list_live did not see the crewmate spawned from it"
assert_not_contains_local "$SM_LIVE" "fm-cm1" "the secondmate home's list_live must not see the primary's task"
assert_not_contains_local "$SM_LIVE" "fm-cm3" "the secondmate home's list_live must not see the primary's stood-down task"
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

TD3_OUT="$TMP_ROOT/td3.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" FM_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" cm3 >"$TD3_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for the stood-down crewmate cm3"$'\n'"$(cat "$TD3_OUT")"
[ -f "$CM3_META" ] && fail "fm-teardown.sh did not remove cm3's meta"
if herdr pane get "$CM3_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close cm3's pane"
fi
WT1=
pass "real herdr E2E: tearing down cm3 closes its own fm-<id> labeled tab"

fm_backend_herdr_kill "$SESSION:$SM_PANE"

cleanup_all
trap - EXIT
