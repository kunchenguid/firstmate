#!/usr/bin/env bash
# tests/fm-backend-herdr-project-workspaces-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for project-grouped task containers
# (docs/herdr-backend.md "Project workspaces").
#
# The requirement under test is a placement and cleanup contract that only
# exists across fm-spawn.sh, the adapter's project record, and herdr's own
# workspace removal, so the canned and stateful fake CLIs in
# tests/fm-backend-herdr.test.sh cannot reach it: the fakes do not model herdr
# removing a workspace when its last tab closes, which is exactly the shape a
# reused project workspace has to survive.
#
# Covers:
#   - two tasks of ONE project landing in one shared workspace labeled by the
#     project name, each in its own ordinary fm-<id> tab
#   - a second project getting its own workspace
#   - tearing down one task leaving the project workspace and its sibling tab
#   - tearing down the project's LAST task removing the project workspace
#     while the focused workspace stays exactly where it was
#   - the next task of that project minting a fresh workspace and rebinding the
#     record, rather than placing a worker in a workspace that is gone
#   - a reclaim of a destroyed endpoint rejoining its project's still-live
#     workspace instead of being stranded in the flat per-home one
#
# Safety: every herdr call routes through tests/herdr-test-safety.sh's
# compatibility wrappers over bin/fm-herdr-lab.sh, which owns isolation,
# refuse-default, and the before/after fleet tripwire. The captain's own
# `default` session is never addressed.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; trap - EXIT; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-projgroups.XXXXXX")
SESSION="fm-lab-herdr-projgroups-$$"
export HERDR_SESSION="$SESSION"
WT_A1=; WT_A2=; WT_A3=; WT_B1=; WT_B2=
cleanup_all() {
  local wt
  for wt in "$WT_A1" "$WT_A2" "$WT_A3" "$WT_B1" "$WT_B2"; do
    [ -n "$wt" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$wt" >/dev/null 2>&1
  done
  herdr_safe_stop_and_delete "$SESSION"
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# The reclaim case relaunches onto an inert harness, and the replacement pane
# inherits the lab server's environment, so this has to be on PATH before the
# server is started below.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
: > "$TMP_ROOT/codex-launched"
EOF
chmod +x "$FAKEBIN/codex"
PATH="$FAKEBIN:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- scratch world ----------------------------------------------------------

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" \
  "$HOME_DIR/data/pga1" "$HOME_DIR/data/pga2" "$HOME_DIR/data/pga3" \
  "$HOME_DIR/data/pgb1" "$HOME_DIR/data/pgb2"
# Asserted explicitly rather than relying on the unconfigured default, so this
# suite keeps testing the project-grouped shape on a release whose floor
# verdict would otherwise decide it (tests/fm-backend-herdr.test.sh pins that
# default against fake releases).
printf 'project\n' > "$HOME_DIR/config/herdr-presentation-spaces"
for id in pga1 pga2 pga3 pgb1 pgb2; do
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise project-grouped Herdr placement for $id.

## Firstmate spec
Verify the task tab lands in its project's own workspace.
EOF
done

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

# Project names the labels are derived from.
PROJ_A="$TMP_ROOT/alpha"; make_scratch_project "$PROJ_A"
PROJ_B="$TMP_ROOT/beta"; make_scratch_project "$PROJ_B"
LABEL_A="└ alpha"
LABEL_B="└ beta"

# A focus anchor: the FIRST workspace in a brand-new Herdr session is focused
# whatever --no-focus says, so without one the project workspace under test
# would be the focused one and "cleanup never steals focus" could not be
# asserted at all.
fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the isolated lab server"
fm_herdr_lab_cli "$SESSION" workspace create --label captain-anchor --cwd "$TMP_ROOT" >/dev/null \
  || fail "could not create the focus anchor workspace"
ANCHOR=$(fm_backend_herdr_projection_focus_snapshot "$SESSION") \
  || fail "could not read the lab session's focused workspace"
ANCHOR_WS=${ANCHOR%%$'\t'*}
[ -n "$ANCHOR_WS" ] || fail "the focus anchor resolved to no workspace"

assert_focus_unchanged() {  # <what>
  local now
  now=$(fm_backend_herdr_projection_focus_snapshot "$SESSION") \
    || fail "could not read the focused workspace after $1"
  [ "${now%%$'\t'*}" = "$ANCHOR_WS" ] \
    || fail "$1 moved the focused workspace from '$ANCHOR_WS' to '${now%%$'\t'*}'"
}

spawn_task() {  # <id> <project-dir> -> 0/1
  FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$2" "sh -c 'echo $1-ok'" \
    --mode no-mistakes --yolo off --backend herdr \
    >"$TMP_ROOT/$1.out" 2>"$TMP_ROOT/$1.err"
}

meta_field() {  # <id> <key>
  sed -n "s/^$2=//p" "$HOME_DIR/state/$1.meta" | tail -1
}

pane_workspace() {  # <pane-id>
  fm_herdr_lab_cli "$SESSION" pane get "$1" 2>/dev/null \
    | jq -r '.result.pane.workspace_id // empty'
}

workspace_label() {  # <workspace-id>
  fm_herdr_lab_cli "$SESSION" workspace list 2>/dev/null \
    | jq -r --arg id "$1" '.result.workspaces[]? | select(.workspace_id == $id) | .label'
}

workspace_present() {  # <workspace-id>
  fm_herdr_lab_cli "$SESSION" workspace list 2>/dev/null \
    | jq -e --arg id "$1" '[.result.workspaces[]? | select(.workspace_id == $id)] | length == 1' \
      >/dev/null 2>&1
}

workspace_tab_labels() {  # <workspace-id>
  fm_herdr_lab_cli "$SESSION" tab list --workspace "$1" 2>/dev/null \
    | jq -r '[.result.tabs[]?.label] | sort | join(",")'
}

project_record() {  # <project-name>
  find "$HOME_DIR/state" -maxdepth 1 -name ".herdr-project-workspace-$1-*" | head -1
}

teardown_task() {  # <id>
  # FM_HOME must name this suite's scratch home like spawn_task does: teardown
  # derives the shared Treehouse project lock from the root home it resolves
  # from FM_HOME, so inheriting an ambient one would both fail to resolve here
  # and anchor the lock outside the home under test.
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-teardown.sh" "$1" >"$TMP_ROOT/$1.teardown.out" 2>&1
}

# --- 1. two tasks of one project share that project's workspace -------------

spawn_task pga1 "$PROJ_A" \
  || fail "the first task of project A failed to spawn"$'\n'"$(cat "$TMP_ROOT/pga1.err")"
WT_A1=$(meta_field pga1 worktree)
PANE_A1=$(meta_field pga1 herdr_pane_id)
[ -n "$PANE_A1" ] || fail "pga1 recorded no herdr pane"

spawn_task pga2 "$PROJ_A" \
  || fail "the second task of project A failed to spawn"$'\n'"$(cat "$TMP_ROOT/pga2.err")"
WT_A2=$(meta_field pga2 worktree)
PANE_A2=$(meta_field pga2 herdr_pane_id)
[ -n "$PANE_A2" ] || fail "pga2 recorded no herdr pane"

WS_A=$(pane_workspace "$PANE_A1")
[ -n "$WS_A" ] || fail "could not read pga1's workspace"
[ "$(pane_workspace "$PANE_A2")" = "$WS_A" ] \
  || fail "two tasks of one project must share one workspace; pga2 landed in '$(pane_workspace "$PANE_A2")' not '$WS_A'"
[ "$(workspace_label "$WS_A")" = "$LABEL_A" ] \
  || fail "the project workspace must be labeled by its project name, got '$(workspace_label "$WS_A")'"
[ "$(meta_field pga1 herdr_workspace_id)" = "$WS_A" ] \
  || fail "pga1's recorded workspace id does not match where its pane actually is"
[ "$(workspace_tab_labels "$WS_A")" = "fm-pga1,fm-pga2" ] \
  || fail "the project workspace must hold exactly both ordinary task tabs, got '$(workspace_tab_labels "$WS_A")'"
assert_focus_unchanged "spawning two tasks of one project"
pass "real herdr E2E: two tasks of one project share one workspace labeled by the project, each in its own fm-<id> tab, with no focus change"

# --- 2. a second project gets its own workspace -----------------------------

spawn_task pgb1 "$PROJ_B" \
  || fail "the task of project B failed to spawn"$'\n'"$(cat "$TMP_ROOT/pgb1.err")"
WT_B1=$(meta_field pgb1 worktree)
PANE_B1=$(meta_field pgb1 herdr_pane_id)
WS_B=$(pane_workspace "$PANE_B1")
[ -n "$WS_B" ] || fail "could not read pgb1's workspace"
[ "$WS_B" != "$WS_A" ] || fail "a different project must not share project A's workspace"
[ "$(workspace_label "$WS_B")" = "$LABEL_B" ] \
  || fail "project B's workspace must carry its own project label, got '$(workspace_label "$WS_B")'"
assert_focus_unchanged "spawning a second project's task"
pass "real herdr E2E: a second project gets its own labeled workspace"

# --- 3. tearing down one task keeps the project workspace and its sibling ---

teardown_task pga1 || fail "tearing down pga1 failed"$'\n'"$(cat "$TMP_ROOT/pga1.teardown.out")"
WT_A1=
[ ! -f "$HOME_DIR/state/pga1.meta" ] || fail "tearing down pga1 left its record behind"
workspace_present "$WS_A" || fail "tearing down one task must not remove the shared project workspace"
[ "$(workspace_tab_labels "$WS_A")" = "fm-pga2" ] \
  || fail "tearing down pga1 must close exactly its own tab, leaving '$(workspace_tab_labels "$WS_A")'"
workspace_present "$WS_B" || fail "tearing down pga1 must not touch another project's workspace"
assert_focus_unchanged "tearing down one of two tasks"
pass "real herdr E2E: tearing down one task closes only its own tab and keeps the project workspace alive for its sibling"

# --- 4. tearing down the LAST task removes the workspace, focus intact ------

teardown_task pga2 || fail "tearing down pga2 failed"$'\n'"$(cat "$TMP_ROOT/pga2.teardown.out")"
WT_A2=
if workspace_present "$WS_A"; then
  fail "closing the project's last tab must leave no project workspace behind, '$WS_A' is still present"
fi
workspace_present "$WS_B" || fail "the last-tab cleanup removed another project's workspace"
assert_focus_unchanged "tearing down the project's last task"
pass "real herdr E2E: closing a project's last task tab removes its workspace without moving the focused workspace"

# --- 5. the next task of that project rebinds to a fresh workspace ----------

RECORD_A=$(project_record alpha)
[ -n "$RECORD_A" ] || fail "project A published no workspace record"
grep -qx "workspace_id=$WS_A" "$RECORD_A" \
  || fail "project A's record does not name the workspace it created"

spawn_task pga3 "$PROJ_A" \
  || fail "the next task of project A failed to spawn after its workspace was removed"$'\n'"$(cat "$TMP_ROOT/pga3.err")"
WT_A3=$(meta_field pga3 worktree)
PANE_A3=$(meta_field pga3 herdr_pane_id)
WS_A3=$(pane_workspace "$PANE_A3")
[ -n "$WS_A3" ] || fail "could not read pga3's workspace"
[ "$WS_A3" != "$WS_A" ] || fail "a removed workspace must never be reported as reused"
[ "$(workspace_label "$WS_A3")" = "$LABEL_A" ] \
  || fail "the rebound project workspace must carry the same project label, got '$(workspace_label "$WS_A3")'"
grep -qx "workspace_id=$WS_A3" "$RECORD_A" \
  || fail "project A's record did not rebind to the freshly created workspace"
assert_focus_unchanged "rebinding project A to a fresh workspace"
pass "real herdr E2E: after its workspace is gone the next task of that project mints a fresh one and the record rebinds"

# --- 6. a reclaimed endpoint rejoins its project's workspace ----------------
#
# Project B needs a second live task first: destroying pgb1's endpoint would
# otherwise close its project's last tab and remove the workspace, which is
# case 5's rebind rather than the reclaim under test here.

spawn_task pgb2 "$PROJ_B" \
  || fail "the second task of project B failed to spawn"$'\n'"$(cat "$TMP_ROOT/pgb2.err")"
WT_B2=$(meta_field pgb2 worktree)
PANE_B2=$(meta_field pgb2 herdr_pane_id)
[ "$(pane_workspace "$PANE_B2")" = "$WS_B" ] \
  || fail "project B's second task must share its project workspace '$WS_B', got '$(pane_workspace "$PANE_B2")'"

fm_herdr_lab_cli "$SESSION" pane close "$PANE_B1" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  [ -n "$(pane_workspace "$PANE_B1")" ] || break
  sleep 0.1
done
[ -z "$(pane_workspace "$PANE_B1")" ] || fail "could not destroy pgb1's endpoint for the reclaim case"
workspace_present "$WS_B" \
  || fail "project B's workspace must survive pgb1's destroyed endpoint, since pgb2 still holds a tab in it"

RECLAIM_OUT=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" pgb1 --relaunch --harness codex 2>&1) \
  || fail "reclaiming pgb1's destroyed endpoint failed"$'\n'"$RECLAIM_OUT"
PANE_B1_NEW=$(meta_field pgb1 herdr_pane_id)
[ -n "$PANE_B1_NEW" ] || fail "the reclaim recorded no replacement pane"
[ "$PANE_B1_NEW" != "$PANE_B1" ] || fail "the reclaim must mint a replacement pane, not re-record the destroyed one"
[ "$(pane_workspace "$PANE_B1_NEW")" = "$WS_B" ] \
  || fail "a reclaimed task must rejoin its own project's workspace '$WS_B', got '$(pane_workspace "$PANE_B1_NEW")'"
[ "$(workspace_tab_labels "$WS_B")" = "fm-pgb1,fm-pgb2" ] \
  || fail "the reclaimed tab must sit beside its project sibling, got '$(workspace_tab_labels "$WS_B")'"
[ "$(meta_field pgb1 herdr_workspace_id)" = "$WS_B" ] \
  || fail "the reclaim recorded a workspace other than the project's own"
if fm_herdr_lab_cli "$SESSION" workspace list 2>/dev/null \
  | jq -e '[.result.workspaces[]? | select(.label == "firstmate")] | length > 0' >/dev/null 2>&1; then
  fail "a reclaim under project grouping must not fall back to the flat per-home workspace"
fi
assert_focus_unchanged "reclaiming a destroyed endpoint"
pass "real herdr E2E: a reclaim of a destroyed endpoint rejoins its project's recorded workspace instead of the flat per-home one"

teardown_task pgb1 || fail "tearing down pgb1 failed"$'\n'"$(cat "$TMP_ROOT/pgb1.teardown.out")"
WT_B1=
teardown_task pgb2 || fail "tearing down pgb2 failed"$'\n'"$(cat "$TMP_ROOT/pgb2.teardown.out")"
WT_B2=
teardown_task pga3 || fail "tearing down pga3 failed"$'\n'"$(cat "$TMP_ROOT/pga3.teardown.out")"
WT_A3=

cleanup_all
trap - EXIT
