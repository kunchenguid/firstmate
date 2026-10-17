#!/usr/bin/env bash
# Isolated real-Herdr home separation through spawn and teardown.
# Primary and secondmate workers have their own task-labelled workspaces;
# the secondmate itself retains its persistent home-labelled container.
# Legacy list-live remains scoped to that container, while task recovery uses
# recorded endpoint metadata. Exact teardown must preserve sibling endpoints.
# Scratch pool lifecycle in this historical fixture is owned by its test;
# tests/fm-backend-herdr-launcher-workspace-e2e.test.sh is the pool-free current
# placement regression.
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
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- scratch world: a primary-shaped home, a secondmate-shaped home, two projects ---

# This test asserts distinct worker and secondmate workspace shapes.
# Both homes explicitly enable dedicated worker placement so the fixture remains
# valid below the default-on presentation safety floor.
PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/cm1" "$PRIMARY_HOME/config"
printf 'on\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
cat > "$PRIMARY_HOME/data/cm1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise primary-home Herdr placement.

## Firstmate spec
Verify the crewmate uses its primary home's workspace.
EOF

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/data/cm2" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf 'on\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf 'e2esm1\n' > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$SM_HOME/.gitignore"
git -C "$SM_HOME" init -q -b main
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
CM1_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM1_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM1_WS_LABEL" = "fm-cm1" ] || fail "a primary-shaped home's crewmate should have its own task-labelled workspace, got '$CM1_WS_LABEL'"
pass "real herdr E2E: the primary-shaped home's crewmate has its own task-labelled workspace"

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
CM2_PANE=$(grep '^herdr_pane_id=' "$CM2_META" | cut -d= -f2-)
[ -n "$CM2_PANE" ] || fail "cm2 meta missing herdr_pane_id"
pass "real herdr E2E: a crewmate spawns successfully FROM a secondmate-shaped home's own fm-spawn.sh process"

sleep 1
CM2_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM2_PANE" 30) || fail "capture failed on cm2's pane"
assert_contains_local "$CM2_CAPTURE" "sm-crew-ok" "cm2's raw launch command did not run in its herdr pane"

CM2_WSID=$(herdr pane get "$CM2_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM2_WSID" != "$SM_WSID" ] || fail "a crewmate must never share its secondmate's workspace"
CM2_WS_LABEL=$(herdr workspace list --session "$SESSION" | jq -r --arg ws "$CM2_WSID" '.result.workspaces[] | select(.workspace_id==$ws) | .label')
case "$CM2_WS_LABEL" in
  fm-cm2|"└ cm2 · p:"*) : ;;
  *) fail "secondmate worker lacks its own task label: '$CM2_WS_LABEL'" ;;
esac
[ "$CM2_WSID" != "$CM1_WSID" ] || fail "a crewmate spawned FROM the secondmate home must NOT land in the primary's workspace"
pass "real herdr E2E: a crewmate spawned FROM the secondmate-shaped home lands in its own task-labelled workspace, separate from the secondmate"

# --- 4. list-live recovery: each home sees only its own tabs ---------------

PRIMARY_LIVE=$(FM_HOME="$PRIMARY_HOME" fm_backend_herdr_list_live "$SESSION")
assert_not_contains_local "$PRIMARY_LIVE" "fm-cm1" "legacy container discovery must not scan dedicated worker workspaces"
assert_not_contains_local "$PRIMARY_LIVE" "fm-e2esm1" "the primary home's list_live must not see the secondmate's own task"
assert_not_contains_local "$PRIMARY_LIVE" "fm-cm2" "the primary home's list_live must not see the secondmate-owned crewmate's task"
pass "real herdr E2E: legacy list_live stays scoped to the primary home container"

SM_LIVE=$(FM_HOME="$SM_HOME" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$SM_LIVE" "fm-e2esm1" "the secondmate home's list_live did not see its own task"
assert_not_contains_local "$SM_LIVE" "fm-cm2" "legacy container discovery must not scan dedicated worker workspaces"
assert_not_contains_local "$SM_LIVE" "fm-cm1" "the secondmate home's list_live must not see the primary's task"
pass "real herdr E2E: legacy list_live sees only the secondmate home container, never dedicated workers"

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
pass "real herdr E2E: tearing down cm2 closes only its own tab - the secondmate's own workspace survives untouched"

fm_backend_herdr_kill "$SESSION:$SM_PANE"

cleanup_all
trap - EXIT
