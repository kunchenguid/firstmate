#!/usr/bin/env bash
# tests/fm-backend-herdr-worktree-groups-e2e.test.sh - isolated real-Herdr E2E
# coverage for native worktree groups (docs/herdr-backend.md "Worktree groups").
# On Herdr 0.9.2 and newer every clean fresh crewmate or scout is opened as a
# linked worktree child workspace under ONE parent workspace per project, a
# reclaimed endpoint lands back in that group, a secondmate-shaped home's tasks
# group under that home's own project parents, a flat home workspace sitting in
# the project is never adopted as a parent, config/herdr-presentation-spaces
# "off" opts the home out of grouping too, and teardown removes exactly the
# children while the parents stay. Below the floor the same suite
# proves the fallback instead. It drives the REAL bin/fm-spawn.sh and
# bin/fm-teardown.sh, a real Treehouse pool, and the guarded named-session lab
# helper; every Herdr read the suite makes itself goes through that helper.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
evidence() { printf '# evidence: %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity.
herdr_forget_inherited_pane
unset FM_TEST_HERDR_WORKTREE_GROUPS

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-wtgroups.XXXXXX")
# The reclaim below relaunches onto an inert replacement harness. A pane shell
# inherits the lab server's environment, so the fake must be on PATH before the
# lab is provisioned.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
: > "$TMP_ROOT/codex-launched"
EOF
chmod +x "$FAKEBIN/codex"
export PATH="$FAKEBIN:$PATH"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-wt-groups)
export HERDR_SESSION="$HERDR_LAB_SESSION"
LAB_READY=0
# "<worktree>\t<project>" lines: every slot a spawn acquired, returned from its
# project so Treehouse resolves the right pool.
RECORDED_WORKTREES=""
cleanup_all() {
  local wt project
  while IFS=$'\t' read -r wt project; do
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    (cd "$project" && treehouse return --force "$wt") >/dev/null 2>&1 || true
  done <<EOF
$RECORDED_WORKTREES
EOF
  if [ "$LAB_READY" -eq 1 ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
    LAB_READY=0
  fi
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision the isolated Herdr lab"
LAB_READY=1
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

real_dir() { (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P); }
meta_field() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}
remember_worktree() {  # <meta> <project> -> echoes the worktree
  local wt
  wt=$(meta_field "$1" worktree)
  [ -n "$wt" ] || fail "metadata $1 did not record a worktree"
  RECORDED_WORKTREES="${RECORDED_WORKTREES}${wt}"$'\t'"$2"$'\n'
  printf '%s' "$wt"
}
workspaces() { lab workspace list | jq -c '.result.workspaces'; }
workspace_entry() {  # <workspace-id>
  workspaces | jq -c --arg ws "$1" '.[] | select(.workspace_id == $ws)'
}
workspace_present() { [ -n "$(workspace_entry "$1")" ]; }
pane_present() { lab pane get "$1" >/dev/null 2>&1; }
parent_for() {  # <project> -> the unique workspace Herdr records as that project's primary checkout
  local project_real
  project_real=$(real_dir "$1")
  workspaces | jq -r --arg real "$project_real" '
    [.[] | select((.worktree | type) == "object" and .worktree.is_linked_worktree == false and .worktree.checkout_path == $real)]
    | if length == 1 then .[0].workspace_id else "" end
  '
}
assert_child_of() {  # <case> <workspace-id> <worktree> <parent-id>
  local case_name=$1 ws=$2 wt=$3 parent=$4 entry parent_entry wt_real
  entry=$(workspace_entry "$ws")
  [ -n "$entry" ] || fail "$case_name: workspace $ws is not in the session"
  parent_entry=$(workspace_entry "$parent")
  wt_real=$(real_dir "$wt")
  printf '%s' "$entry" | jq -e --arg wt "$wt_real" --argjson parent "$parent_entry" '
    (.worktree | type) == "object"
    and .worktree.is_linked_worktree == true
    and .worktree.checkout_path == $wt
    and .worktree.repo_key == $parent.worktree.repo_key
    and .workspace_id != $parent.workspace_id
  ' >/dev/null 2>&1 || fail "$case_name: workspace $ws is not a linked worktree child of parent $parent for $wt_real: $entry"
}
assert_not_grouped() {  # <case> <workspace-id>
  local entry
  entry=$(workspace_entry "$1")
  [ -n "$entry" ] || fail "$2: workspace $1 is not in the session"
  printf '%s' "$entry" | jq -e '(.worktree | type) != "object" or .worktree.is_linked_worktree != true' >/dev/null 2>&1 \
    || fail "$2: workspace $1 unexpectedly carries linked-worktree membership: $entry"
}

make_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# Herdr worktree-group E2E fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

write_ship_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Herdr worktree-group fixture $2.

## Firstmate spec
Verify grouped workspace behavior for $2.
EOF
}

spawn_task() {  # <id> <home> <project> [extra fm-spawn args...]
  local id=$1 home=$2 project=$3
  shift 3
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'while :; do sleep 60; done'" \
    --mode no-mistakes --yolo off --backend herdr "$@"
}

teardown_task() {  # <id> <home>
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$2" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$2/state" FM_DATA_OVERRIDE="$2/data" FM_CONFIG_OVERRIDE="$2/config" \
    "$ROOT/bin/fm-teardown.sh" "$1" --force
}

HOME_DIR="$TMP_ROOT/home"
PROJECT_A="$TMP_ROOT/alpha"
PROJECT_B="$TMP_ROOT/beta"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
touch "$HOME_DIR/state/.last-watcher-beat"
for id in a1 a2 a3 b1 flat-home off-flat; do
  write_ship_brief "$HOME_DIR" "$id"
done
make_project "$PROJECT_A"
make_project "$PROJECT_B"

HERDR_VERSION=$(lab status --json | jq -r 'if .server.running then .server.version else .client.version end')
FLOOR_STATUS=$(bash -c '
  . "$0/bin/backends/herdr.sh"
  status=0
  fm_backend_herdr_worktree_group_release_supported "$1" || status=$?
  printf "%s\n" "$status"
' "$ROOT" "$HERDR_LAB_SESSION")

if [ "$FLOOR_STATUS" != 0 ]; then
  # --- below the floor: the fallback is the whole guarantee -------------------
  spawn_task a1 "$HOME_DIR" "$PROJECT_A" > "$TMP_ROOT/a1.out" 2> "$TMP_ROOT/a1.err" \
    || fail "sub-floor spawn failed: $(cat "$TMP_ROOT/a1.err")"
  remember_worktree "$HOME_DIR/state/a1.meta" "$PROJECT_A" >/dev/null
  A1_WS=$(meta_field "$HOME_DIR/state/a1.meta" herdr_workspace_id)
  assert_not_grouped "$A1_WS" "sub-floor spawn"
  [ -z "$(parent_for "$PROJECT_A")" ] || fail "a sub-floor spawn created a project parent workspace"
  grep -F 'floor for native worktree groups' "$TMP_ROOT/a1.err" >/dev/null 2>&1 \
    || fail "a sub-floor spawn did not name the native worktree-group floor once: $(cat "$TMP_ROOT/a1.err")"
  ls "$HOME_DIR/state"/.herdr-worktree-group-floor-* >/dev/null 2>&1 \
    || fail "a sub-floor spawn did not record its one-per-release floor marker"
  teardown_task a1 "$HOME_DIR" > "$TMP_ROOT/a1-td.out" 2> "$TMP_ROOT/a1-td.err" \
    || fail "sub-floor teardown failed: $(cat "$TMP_ROOT/a1-td.err")"
  pass "real herdr $HERDR_VERSION (below the 0.9.2 worktree-group floor, verdict $FLOOR_STATUS): a spawn warns once and keeps the pre-0.9.2 layout"
  exit 0
fi

# --- 1. two tasks of one project and one of another: one group per project ---

spawn_task a1 "$HOME_DIR" "$PROJECT_A" > "$TMP_ROOT/a1.out" 2> "$TMP_ROOT/a1.err" \
  || fail "spawn a1 failed: $(cat "$TMP_ROOT/a1.err")"
spawn_task a2 "$HOME_DIR" "$PROJECT_A" > "$TMP_ROOT/a2.out" 2> "$TMP_ROOT/a2.err" \
  || fail "spawn a2 failed: $(cat "$TMP_ROOT/a2.err")"
spawn_task b1 "$HOME_DIR" "$PROJECT_B" > "$TMP_ROOT/b1.out" 2> "$TMP_ROOT/b1.err" \
  || fail "spawn b1 failed: $(cat "$TMP_ROOT/b1.err")"
A1_META="$HOME_DIR/state/a1.meta"; A2_META="$HOME_DIR/state/a2.meta"; B1_META="$HOME_DIR/state/b1.meta"
A1_WT=$(remember_worktree "$A1_META" "$PROJECT_A")
A2_WT=$(remember_worktree "$A2_META" "$PROJECT_A")
B1_WT=$(remember_worktree "$B1_META" "$PROJECT_B")
A1_WS=$(meta_field "$A1_META" herdr_workspace_id); A1_PANE=$(meta_field "$A1_META" herdr_pane_id)
A2_WS=$(meta_field "$A2_META" herdr_workspace_id); A2_PANE=$(meta_field "$A2_META" herdr_pane_id)
B1_WS=$(meta_field "$B1_META" herdr_workspace_id); B1_PANE=$(meta_field "$B1_META" herdr_pane_id)
[ -n "$A1_WS" ] && [ -n "$A2_WS" ] && [ -n "$B1_WS" ] || fail "a spawn did not record a herdr workspace id"
[ "$A1_WS" != "$A2_WS" ] || fail "a1 and a2 share one workspace; each task must be its own child workspace"
[ "$(meta_field "$A1_META" herdr_session)" = "$HERDR_LAB_SESSION" ] || fail "a1 was not recorded in the lab session"
for p in "$A1_PANE" "$A2_PANE" "$B1_PANE"; do
  pane_present "$p" || fail "recorded pane $p does not exist"
done
[ "$A1_WT" != "$A2_WT" ] || fail "a1 and a2 were handed the same Treehouse slot"
[ -d "$A1_WT/.git" ] || [ -f "$A1_WT/.git" ] || fail "a1's recorded worktree is not a checkout: $A1_WT"

PARENT_A=$(parent_for "$PROJECT_A")
PARENT_B=$(parent_for "$PROJECT_B")
[ -n "$PARENT_A" ] || fail "no unique parent workspace records project A's primary checkout: $(workspaces)"
[ -n "$PARENT_B" ] || fail "no unique parent workspace records project B's primary checkout: $(workspaces)"
[ "$PARENT_A" != "$PARENT_B" ] || fail "projects A and B share one parent workspace"
assert_child_of "a1" "$A1_WS" "$A1_WT" "$PARENT_A"
assert_child_of "a2" "$A2_WS" "$A2_WT" "$PARENT_A"
assert_child_of "b1" "$B1_WS" "$B1_WT" "$PARENT_B"
[ "$(workspace_entry "$PARENT_A" | jq -r .label)" = alpha ] || fail "project A's parent is not labeled after the project: $(workspace_entry "$PARENT_A")"
[ "$(workspace_entry "$A1_WS" | jq -r .label)" = a1 ] || fail "a1's child workspace is not labeled after the task: $(workspace_entry "$A1_WS")"
[ "$(workspace_entry "$PARENT_A" | jq -r .tab_count)" = 1 ] || fail "project A's parent should hold only its own seeded tab"
workspaces | jq -e '[.[] | select(.label == "firstmate")] | length == 0' >/dev/null 2>&1 \
  || fail "a grouped spawn created the flat per-home workspace: $(workspaces)"
for ws in "$A1_WS" "$A2_WS" "$B1_WS"; do
  lab tab list --workspace "$ws" | jq -e '(.result.tabs | length) == 1 and (.result.tabs[0].label | startswith("fm-"))' >/dev/null 2>&1 \
    || fail "child workspace $ws does not hold exactly its one fm- task tab: $(lab tab list --workspace "$ws")"
done
WORKTREES_A=$(lab worktree list --workspace "$PARENT_A")
printf '%s' "$WORKTREES_A" | jq -e --arg a1 "$(real_dir "$A1_WT")" --arg a1ws "$A1_WS" --arg a2 "$(real_dir "$A2_WT")" --arg a2ws "$A2_WS" '
  (.result.worktrees | map(select(.path == $a1 and .open_workspace_id == $a1ws)) | length) == 1
  and (.result.worktrees | map(select(.path == $a2 and .open_workspace_id == $a2ws)) | length) == 1
' >/dev/null 2>&1 || fail "project A's worktree list does not show both task checkouts open in their child workspaces: $WORKTREES_A"
[ ! -e "$HOME_DIR/state/a1.herdr-presentation" ] || fail "a grouped spawn wrote a presentation journal"
evidence "herdr $HERDR_VERSION workspace list after a1, a2 (alpha) and b1 (beta): $(workspaces | jq -c '[.[] | {workspace_id, label, worktree: {checkout_path: .worktree.checkout_path, is_linked_worktree: .worktree.is_linked_worktree, repo_name: .worktree.repo_name}}]')"
evidence "worktree list --workspace $PARENT_A (alpha): $(printf '%s' "$WORKTREES_A" | jq -c '[.result.worktrees[] | {path, is_linked_worktree, open_workspace_id}]')"
pass "real herdr $HERDR_VERSION: two tasks of one project and one of another are linked worktree children under one parent workspace per project"

# --- 2. a destroyed endpoint is reclaimed back into its project group -------

lab pane close "$A1_PANE" >/dev/null || fail "could not destroy a1's pane for the reclaim"
pane_present "$A1_PANE" && fail "a1's pane survived the destroy"
workspace_present "$A1_WS" && fail "a1's child workspace survived the destroy of its only pane"
# The launch owner's --relaunch is the reclaim the control plane calls after
# its own absence proof, and runs that proof again itself: the recorded pane is
# re-read through the recorded session and only a proven-gone endpoint lets it
# mint a fresh one. It is driven directly here because these fixtures run a raw
# shell command as their harness, which bin/fm-control.sh refuses to drive.
FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" a1 --relaunch --harness codex \
  > "$TMP_ROOT/a1-relaunch.out" 2> "$TMP_ROOT/a1-relaunch.err" \
  || fail "reclaim relaunch of a1 failed: $(cat "$TMP_ROOT/a1-relaunch.out" "$TMP_ROOT/a1-relaunch.err")"
for _ in $(seq 1 50); do
  [ ! -e "$TMP_ROOT/codex-launched" ] || break
  sleep 0.2
done
[ -e "$TMP_ROOT/codex-launched" ] || fail "the reclaimed a1 did not launch its replacement harness: $(cat "$TMP_ROOT/a1-relaunch.out" "$TMP_ROOT/a1-relaunch.err")"
A1_WS2=$(meta_field "$A1_META" herdr_workspace_id); A1_PANE2=$(meta_field "$A1_META" herdr_pane_id)
[ -n "$A1_WS2" ] && [ "$A1_WS2" != "$A1_WS" ] || fail "the reclaim did not rebind a1 to a fresh workspace (old $A1_WS, new '$A1_WS2')"
[ "$(meta_field "$A1_META" worktree)" = "$A1_WT" ] || fail "the reclaim changed a1's recorded worktree"
pane_present "$A1_PANE2" || fail "a1's reclaimed pane $A1_PANE2 does not exist"
[ "$(parent_for "$PROJECT_A")" = "$PARENT_A" ] || fail "the reclaim did not reuse project A's parent workspace"
assert_child_of "a1 reclaim" "$A1_WS2" "$A1_WT" "$PARENT_A"
workspaces | jq -e '[.[] | select(.label == "firstmate")] | length == 0' >/dev/null 2>&1 \
  || fail "the reclaim fell back to the flat per-home workspace: $(workspaces)"
lab tab list --workspace "$A1_WS2" | jq -e '(.result.tabs | length) == 1 and .result.tabs[0].label == "fm-a1"' >/dev/null 2>&1 \
  || fail "a1's reclaimed child workspace does not hold exactly its fm-a1 tab"
evidence "after destroying a1's pane and relaunching: a1 is $A1_WS2 ($(workspace_entry "$A1_WS2" | jq -c '{label, worktree: {checkout_path: .worktree.checkout_path, is_linked_worktree: .worktree.is_linked_worktree}}')) under parent $PARENT_A; worktree list: $(lab worktree list --workspace "$PARENT_A" | jq -c '[.result.worktrees[] | {path, open_workspace_id}]')"
pass "real herdr $HERDR_VERSION: a reclaimed endpoint lands back in its project group, not in the home workspace"

# --- 3. a secondmate-shaped home groups under its own project parents --------

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
touch "$SM_HOME/state/.last-watcher-beat"
printf 'wtgroup-sm\n' > "$SM_HOME/.fm-secondmate-home"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$SM_HOME/.gitignore"
git -C "$SM_HOME" init -q -b main
write_ship_brief "$SM_HOME" sm1
PROJECT_SM="$SM_HOME/projects/alpha"
make_project "$PROJECT_SM"
spawn_task sm1 "$SM_HOME" "$PROJECT_SM" > "$TMP_ROOT/sm1.out" 2> "$TMP_ROOT/sm1.err" \
  || fail "secondmate-home spawn sm1 failed: $(cat "$TMP_ROOT/sm1.err")"
SM1_META="$SM_HOME/state/sm1.meta"
SM1_WT=$(remember_worktree "$SM1_META" "$PROJECT_SM")
SM1_WS=$(meta_field "$SM1_META" herdr_workspace_id)
PARENT_SM=$(parent_for "$PROJECT_SM")
[ -n "$PARENT_SM" ] || fail "no unique parent workspace records the secondmate home's alpha clone: $(workspaces)"
[ "$PARENT_SM" != "$PARENT_A" ] || fail "the secondmate home's same-named project shares the primary's parent"
assert_child_of "sm1" "$SM1_WS" "$SM1_WT" "$PARENT_SM"
[ "$(workspace_entry "$PARENT_SM" | jq -r .label)" = "2ndmate-wtgroup-sm/alpha" ] \
  || fail "the secondmate home's parent is not labeled with its home: $(workspace_entry "$PARENT_SM")"
evidence "secondmate-shaped home: sm1 is $SM1_WS under $PARENT_SM labeled '$(workspace_entry "$PARENT_SM" | jq -r .label)', distinct from the primary's alpha parent $PARENT_A"
pass "real herdr $HERDR_VERSION: a secondmate-shaped home's task groups under that home's own project parent"

# --- 4. config/herdr-presentation-spaces "off" opts the home out of grouping too ---

# The per-home flat workspace case 5 needs is the pre-0.9.2 layout, reached
# here only through the worktree-group test seam.
FM_TEST_SEAM=1 FM_TEST_HERDR_WORKTREE_GROUPS=off spawn_task flat-home "$HOME_DIR" "$PROJECT_A" \
  > "$TMP_ROOT/flat-home.out" 2> "$TMP_ROOT/flat-home.err" \
  || fail "flat home fixture spawn failed: $(cat "$TMP_ROOT/flat-home.err")"
FLAT_HOME_META="$HOME_DIR/state/flat-home.meta"
remember_worktree "$FLAT_HOME_META" "$PROJECT_A" >/dev/null
FLAT_HOME_WS=$(meta_field "$FLAT_HOME_META" herdr_workspace_id)
assert_not_grouped "$FLAT_HOME_WS" "flat home fixture spawn"
HOME_WS=$(workspaces | jq -r '[.[] | select(.label == "firstmate")] | if length == 1 then .[0].workspace_id else "" end')
[ -n "$HOME_WS" ] || fail "the flat home fixture spawn did not take the per-home layout: $(workspaces)"
[ "$FLAT_HOME_WS" = "$HOME_WS" ] || fail "the flat home fixture spawn landed in $FLAT_HOME_WS rather than the home workspace $HOME_WS"

# A home that already said off keeps its flat layout: the opted-out spawn
# lands in the home workspace as a plain tab, and the project's parent is left
# exactly as it was.
PARENT_A_TABS=$(workspace_entry "$PARENT_A" | jq -r .tab_count)
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
spawn_task off-flat "$HOME_DIR" "$PROJECT_A" > "$TMP_ROOT/off-flat.out" 2> "$TMP_ROOT/off-flat.err" \
  || fail "config-off spawn failed: $(cat "$TMP_ROOT/off-flat.err")"
rm -f "$HOME_DIR/config/herdr-presentation-spaces"
OFF_META="$HOME_DIR/state/off-flat.meta"
remember_worktree "$OFF_META" "$PROJECT_A" >/dev/null
OFF_WS=$(meta_field "$OFF_META" herdr_workspace_id)
[ "$OFF_WS" = "$HOME_WS" ] || fail "the config-off spawn landed in $OFF_WS rather than the home workspace $HOME_WS: $(workspaces)"
assert_not_grouped "$OFF_WS" "config-off spawn"
[ "$(parent_for "$PROJECT_A")" = "$PARENT_A" ] || fail "the config-off spawn disturbed project A's parent: $(workspaces)"
[ "$(workspace_entry "$PARENT_A" | jq -r .tab_count)" = "$PARENT_A_TABS" ] || fail "the config-off spawn changed project A's parent: $(workspace_entry "$PARENT_A")"
evidence "config off: off-flat is $OFF_WS, the home workspace, carrying no linked-worktree membership; project A's parent $PARENT_A still holds $PARENT_A_TABS tab(s)"
pass "real herdr $HERDR_VERSION: config/herdr-presentation-spaces off opts the home out of native worktree grouping too"

# --- 5. a flat home workspace sitting in the project is never adopted as a parent ---

spawn_task a3 "$HOME_DIR" "$PROJECT_A" > "$TMP_ROOT/a3.out" 2> "$TMP_ROOT/a3.err" \
  || fail "spawn a3 failed: $(cat "$TMP_ROOT/a3.err")"
A3_META="$HOME_DIR/state/a3.meta"
A3_WT=$(remember_worktree "$A3_META" "$PROJECT_A")
A3_WS=$(meta_field "$A3_META" herdr_workspace_id)
[ "$(parent_for "$PROJECT_A")" = "$PARENT_A" ] || fail "a3 did not reuse project A's parent while the flat home workspace sat in project A"
assert_child_of "a3" "$A3_WS" "$A3_WT" "$PARENT_A"
assert_not_grouped "$HOME_WS" "home workspace after a3"
pass "real herdr $HERDR_VERSION: the per-home workspace sitting in the project is never adopted as the group parent"

# --- 6. teardown removes exactly the children; the parents stay ---------------

for id in a1 a2 a3 b1 flat-home off-flat; do
  teardown_task "$id" "$HOME_DIR" > "$TMP_ROOT/$id-td.out" 2> "$TMP_ROOT/$id-td.err" \
    || fail "teardown $id failed: $(cat "$TMP_ROOT/$id-td.err")"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "teardown $id left its metadata"
done
teardown_task sm1 "$SM_HOME" > "$TMP_ROOT/sm1-td.out" 2> "$TMP_ROOT/sm1-td.err" \
  || fail "teardown sm1 failed: $(cat "$TMP_ROOT/sm1-td.err")"
for ws in "$A1_WS2" "$A2_WS" "$A3_WS" "$B1_WS" "$SM1_WS"; do
  workspace_present "$ws" && fail "teardown left child workspace $ws open: $(workspaces)"
done
for parent in "$PARENT_A" "$PARENT_B" "$PARENT_SM"; do
  workspace_present "$parent" || fail "teardown closed parent workspace $parent"
  [ "$(workspace_entry "$parent" | jq -r .tab_count)" = 1 ] || fail "parent $parent no longer holds exactly its own tab: $(workspace_entry "$parent")"
done
lab worktree list --workspace "$PARENT_A" | jq -e '[.result.worktrees[] | select(.is_linked_worktree == true and (.open_workspace_id // "") != "")] | length == 0' >/dev/null 2>&1 \
  || fail "project A's worktree list still shows an open task checkout after teardown"
grep -F 'workspace close' "$TMP_ROOT"/*-td.err >/dev/null 2>&1 && fail "a teardown mentioned workspace close"
evidence "after teardown of every task: $(workspaces | jq -c '[.[] | {workspace_id, label, tab_count}]')"
pass "real herdr $HERDR_VERSION: teardown closes exactly each task's child workspace and never a parent"
