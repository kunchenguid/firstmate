#!/usr/bin/env bash
# tests/fm-backend-herdr-pane-placement-e2e.test.sh - mandatory ISOLATED
# end-to-end real-Herdr test for the pane crew placement
# (docs/herdr-backend.md "Crew placement").
#
# The guarantees under test, none of which a fake CLI can establish because
# they are Herdr's own behavior:
#   - `pane split` really creates the worker's terminal inside the launching
#     agent's exact tab and workspace, in the task's project directory.
#   - `pane rename` really attaches the fm-<id> label the discovery paths read,
#     and `pane list` reports it.
#   - `--no-focus` really leaves both the globally focused workspace and the
#     launcher tab's focused pane alone.
#   - Closing the worker pane removes exactly that pane, including when its tab
#     is the ACTIVE tab, which is the normal case for this placement and the
#     one shape the tab topology never produces.
#   - An absent config/herdr-crew-placement still produces the tab topology.
#
# This drives the REAL bin/fm-spawn.sh and bin/fm-teardown.sh, because the
# guarantee spans the whole handoff (fm-spawn.sh's herdr arm ->
# fm_backend_herdr_crew_placement -> fm_backend_herdr_split_capable ->
# fm_backend_herdr_launcher_identity -> fm_backend_herdr_split_task, then
# fm-teardown.sh -> fm_backend_herdr_kill -> fm_backend_herdr_kill_serialized).
# Deterministic parsing, refusal wording, and rollback bounds are covered
# without a real binary in tests/fm-backend-herdr.test.sh.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): every lifecycle
# operation goes through bin/fm-herdr-lab.sh, which appends the named session
# flag and verifies the default fleet session is unchanged after teardown.
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

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# Every spawn below states its own launcher identity, so a pane inherited from
# the terminal this suite was started in must not leak into any of them.
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-pane-placement-e2e.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-pane-place) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"

WORKTREES=()
CLEANED=0
# Idempotent: fail() cleans up before exiting and the EXIT trap fires after it,
# so a second teardown would otherwise report the already-consumed fleet-state
# tripwire as if the lab had gone wrong.
cleanup_all() {
  local wt status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
    [ -n "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done
  WORKTREES=()
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# --- helpers ----------------------------------------------------------------

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

# make_workspace <label> -> "<workspace_id> <tab_id> <root_pane_id>"
make_workspace() {  # <label>
  local out
  out=$(lab workspace create --cwd "$TMP_ROOT" --label "$1" --no-focus 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '
    [.result.workspace.workspace_id, .result.tab.tab_id, .result.root_pane.pane_id] | @tsv
  ' 2>/dev/null | tr '\t' ' '
}

# jq's `//` treats a literal false as unset, so a boolean field like `focused`
# must be read positionally rather than with an alternative operator.
pane_field() {  # <pane_id> <field>
  lab pane get "$1" 2>/dev/null \
    | jq -r --arg f "$2" '.result.pane | if has($f) then (.[$f] | tostring) else "" end' 2>/dev/null
}

panes_in_tab() {  # <workspace_id> <tab_id> -> sorted pane ids, one per line
  lab pane list --workspace "$1" 2>/dev/null \
    | jq -r --arg tab "$2" '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null | LC_ALL=C sort
}

# The pane a tab would hand keystrokes to. Read from the tab's own layout,
# because a pane's `focused` flag is global: every pane in a workspace that does
# not hold session focus reports false, however the tab itself is arranged.
tab_focused_pane() {  # <any-pane-id-in-the-tab>
  lab pane layout --pane "$1" 2>/dev/null | jq -r '.result.layout.focused_pane_id // empty' 2>/dev/null
}

# pane_rect <any-pane-in-tab> <target-pane> -> "x y width height" read off the
# tab's own layout, so the right-half stacking rule (bin/backends/herdr.sh
# fm_backend_herdr_split_placement) can be checked against Herdr's own
# geometry rather than assumed from spawn order.
pane_rect() {  # <any-pane-in-tab> <target-pane>
  lab pane layout --pane "$1" 2>/dev/null \
    | jq -r --arg p "$2" '.result.layout.panes[]? | select(.pane_id == $p) | "\(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height)"' 2>/dev/null
}
rect_field() {  # "<x> <y> <w> <h>" <1|2|3|4>
  printf '%s' "$1" | awk -v i="$2" '{print $i}'
}

pane_count_in_tab() {  # <workspace_id> <tab_id>
  panes_in_tab "$1" "$2" | grep -c '[^[:space:]]' || true
}

tab_exists() {  # <workspace_id> <tab_id>
  lab tab list --workspace "$1" 2>/dev/null \
    | jq -e --arg tab "$2" 'any(.result.tabs[]?; .tab_id == $tab)' >/dev/null 2>&1
}

focused_workspace() {
  lab workspace list 2>/dev/null \
    | jq -r '[.result.workspaces[]? | select(.focused == true) | .workspace_id][0] // empty' 2>/dev/null
}

meta_field() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-
}

record_worktree() {  # <meta>
  local wt
  wt=$(meta_field "$1" worktree)
  [ -n "$wt" ] && WORKTREES+=("$wt")
  return 0
}

# spawn_from_launcher <launcher-pane|""> <home> <task-id> <project> [extra fm-spawn args...]
# Composes exactly the Herdr identity Herdr itself injects into a pane's
# processes. An empty launcher pane means "this firstmate is not running inside
# Herdr at all".
SPAWN_OUT=; SPAWN_ERR=; SPAWN_RC=
spawn_from_launcher() {
  local pane=$1 home=$2 id=$3 proj=$4
  shift 4
  SPAWN_OUT="$TMP_ROOT/$id.out"; SPAWN_ERR="$TMP_ROOT/$id.err"
  if [ -n "$pane" ]; then
    env HERDR_ENV=1 HERDR_PANE_ID="$pane" HERDR_SESSION="$HERDR_LAB_SESSION" \
      HERDR_SOCKET_PATH="$LAB_SOCKET" \
      FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'echo pane-placement-ok'" --backend herdr "$@" \
      >"$SPAWN_OUT" 2>"$SPAWN_ERR"
  else
    env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
      FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'echo pane-placement-ok'" --backend herdr "$@" \
      >"$SPAWN_OUT" 2>"$SPAWN_ERR"
  fi
  SPAWN_RC=$?
  return 0
}

teardown_task() {  # <home> <task-id>
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_CONFIG_OVERRIDE="$1/config" \
    "$ROOT/bin/fm-teardown.sh" "$2" >"$TMP_ROOT/$2.teardown.out" 2>&1
}

LAB_SOCKET=$(lab session list --json 2>/dev/null \
  | jq -r --arg s "$HERDR_LAB_SESSION" '.sessions[]? | select(.name == $s) | .socket_path' 2>/dev/null)
[ -n "$LAB_SOCKET" ] || fail "could not read the isolated lab session's socket path"

# --- scratch world ----------------------------------------------------------

# The pane-placement home. Presentation spaces are opted out explicitly so this
# suite exercises placement alone; the deliberate on+pane conflict has its own
# home below.
PANE_HOME="$TMP_ROOT/pane-home"
mkdir -p "$PANE_HOME/state" "$PANE_HOME/config"
printf 'off\n' > "$PANE_HOME/config/herdr-presentation-spaces"
printf 'pane\n' > "$PANE_HOME/config/herdr-crew-placement"

# The regression home: no placement file at all, so it must keep the tab
# topology byte for byte.
TAB_HOME="$TMP_ROOT/tab-home"
mkdir -p "$TAB_HOME/state" "$TAB_HOME/config"
printf 'off\n' > "$TAB_HOME/config/herdr-presentation-spaces"

# The conflict home: two explicit, contradictory answers to where a worker's
# terminal lives.
CONFLICT_HOME="$TMP_ROOT/conflict-home"
mkdir -p "$CONFLICT_HOME/state" "$CONFLICT_HOME/config"
printf 'on\n' > "$CONFLICT_HOME/config/herdr-presentation-spaces"
printf 'pane\n' > "$CONFLICT_HOME/config/herdr-crew-placement"

for id in paneA paneB tabC noLauncherD conflictE; do
  for home in "$PANE_HOME" "$TAB_HOME" "$CONFLICT_HOME"; do
    mkdir -p "$home/data/$id"
    printf 'trivial pane-placement brief: nothing to do.\n' > "$home/data/$id/brief.md"
  done
done

PROJ="$TMP_ROOT/scratch-project"; make_scratch_project "$PROJ"

# One unrelated workspace, kept FOCUSED throughout the placement cases, so every
# result below is also evidence that --no-focus holds against the real binary.
read -r WS_OTHER WS_OTHER_TAB _ <<EOF
$(make_workspace captain-other)
EOF
[ -n "$WS_OTHER" ] || fail "could not create the unrelated captain workspace"
lab tab focus "$WS_OTHER_TAB" >/dev/null 2>&1 || fail "could not focus the unrelated captain workspace"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "the unrelated captain workspace did not take focus"

# The launcher: a real Herdr workspace, tab, and pane standing in for the
# firstmate agent's own terminal.
read -r WS_LAUNCH TAB_LAUNCH PANE_LAUNCH <<EOF
$(make_workspace firstmate)
EOF
[ -n "$PANE_LAUNCH" ] || fail "could not create the launcher workspace and pane"
[ "$(pane_count_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = 1 ] \
  || fail "the launcher tab should start with exactly its own pane"

# --- 1. a pane-placed worker lands in the launcher's exact tab --------------

spawn_from_launcher "$PANE_LAUNCH" "$PANE_HOME" paneA "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a pane-placed spawn failed"$'\n'"$(cat "$SPAWN_ERR")"
META_A="$PANE_HOME/state/paneA.meta"
record_worktree "$META_A"
PANE_A=$(meta_field "$META_A" herdr_pane_id)
[ -n "$PANE_A" ] || fail "paneA meta is missing herdr_pane_id"
[ "$PANE_A" != "$PANE_LAUNCH" ] || fail "the worker endpoint must be a new pane, not the launcher's own"
[ "$(pane_field "$PANE_A" tab_id)" = "$TAB_LAUNCH" ] \
  || fail "the worker pane is not in the launcher's tab ($TAB_LAUNCH), got '$(pane_field "$PANE_A" tab_id)'"
[ "$(pane_field "$PANE_A" workspace_id)" = "$WS_LAUNCH" ] \
  || fail "the worker pane is not in the launcher's workspace ($WS_LAUNCH)"
[ "$(meta_field "$META_A" herdr_tab_id)" = "$TAB_LAUNCH" ] \
  || fail "the recorded endpoint tab is not the launcher's own tab"
[ "$(meta_field "$META_A" herdr_workspace_id)" = "$WS_LAUNCH" ] \
  || fail "the recorded endpoint workspace is not the launcher's own workspace"
[ "$(meta_field "$META_A" window)" = "$HERDR_LAB_SESSION:$PANE_A" ] \
  || fail "the recorded endpoint is not the exact session:pane form"
[ "$(pane_count_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = 2 ] \
  || fail "the launcher tab should now hold the launcher's pane and exactly one worker pane"
[ ! -f "$PANE_HOME/state/paneA.herdr-presentation" ] \
  || fail "pane placement must not publish a presentation journal"
pass "real herdr E2E: a pane-placed worker is created as a new pane inside the launching agent's exact tab and workspace"

# --- 1b. the first worker lands strictly right of the untouched launcher ---

LAUNCHER_RECT_1=$(pane_rect "$PANE_LAUNCH" "$PANE_LAUNCH")
[ -n "$LAUNCHER_RECT_1" ] || fail "could not read the launcher pane's own rect"
PANE_A_RECT=$(pane_rect "$PANE_LAUNCH" "$PANE_A")
[ -n "$PANE_A_RECT" ] || fail "could not read the first worker pane's rect"
[ "$(rect_field "$PANE_A_RECT" 1)" -gt "$(rect_field "$LAUNCHER_RECT_1" 1)" ] \
  || fail "the first worker must land strictly right of the launcher pane, launcher=$LAUNCHER_RECT_1 worker=$PANE_A_RECT"
pass "real herdr E2E: the first worker takes the right half while the launcher keeps the left"

# --- 2. the worker pane really carries the fm-<id> label -------------------

[ "$(pane_field "$PANE_A" label)" = "fm-paneA" ] \
  || fail "the worker pane is not labeled fm-paneA, got '$(pane_field "$PANE_A" label)'"
LISTED=$(lab pane list --workspace "$WS_LAUNCH" 2>/dev/null \
  | jq -r --arg p "$PANE_A" '.result.panes[]? | select(.pane_id == $p) | .label' 2>/dev/null)
[ "$LISTED" = "fm-paneA" ] \
  || fail "pane list does not report the fm-<id> label the discovery paths read, got '$LISTED'"
LIVE=$(FM_HOME="$PANE_HOME" FM_ROOT_OVERRIDE="$ROOT" bash -c '
  . "$0/bin/backends/herdr.sh"; fm_backend_herdr_list_live "$1"' "$ROOT" "$HERDR_LAB_SESSION")
assert_contains_local "$LIVE" "$HERDR_LAB_SESSION:$PANE_A	fm-paneA" \
  "list-live did not discover the pane-placed worker by its own label"
pass "real herdr E2E: the worker pane carries its fm-<id> label and list-live discovers it there"

# --- 3. --no-focus really holds, for the workspace and inside the tab -------

[ "$(focused_workspace)" = "$WS_OTHER" ] \
  || fail "a pane-placed spawn stole focus from the captain's workspace"
[ "$(pane_field "$PANE_A" focused)" = false ] \
  || fail "the new worker pane took focus inside the launcher's tab"
[ "$(tab_focused_pane "$PANE_LAUNCH")" = "$PANE_LAUNCH" ] \
  || fail "the launcher's own pane lost its tab's focus to the new worker pane"
pass "real herdr E2E: the split leaves both the focused workspace and the launcher tab's own focused pane alone"

# --- 4. a second worker joins the RIGHT half, below the first, never --------
#        re-splitting the launcher's own pane.

spawn_from_launcher "$PANE_LAUNCH" "$PANE_HOME" paneB "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a second pane-placed spawn failed"$'\n'"$(cat "$SPAWN_ERR")"
META_B="$PANE_HOME/state/paneB.meta"
record_worktree "$META_B"
PANE_B=$(meta_field "$META_B" herdr_pane_id)
[ -n "$PANE_B" ] && [ "$PANE_B" != "$PANE_A" ] || fail "the second worker did not get its own pane"
[ "$(pane_field "$PANE_B" tab_id)" = "$TAB_LAUNCH" ] \
  || fail "the second worker pane is not in the launcher's tab"
[ "$(pane_count_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = 3 ] \
  || fail "the launcher tab should now hold the launcher's pane and two worker panes"
lab pane get "$PANE_A" >/dev/null 2>&1 || fail "the second spawn disturbed the first worker's pane"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "the second pane-placed spawn stole focus"
[ "$(tab_focused_pane "$PANE_LAUNCH")" = "$PANE_LAUNCH" ] \
  || fail "the second split moved the launcher tab's focus off the launching agent's pane"
LAUNCHER_RECT_2=$(pane_rect "$PANE_LAUNCH" "$PANE_LAUNCH")
[ "$LAUNCHER_RECT_2" = "$LAUNCHER_RECT_1" ] \
  || fail "the second worker must never re-split the launcher's own pane, was=$LAUNCHER_RECT_1 now=$LAUNCHER_RECT_2"
PANE_A_RECT_2=$(pane_rect "$PANE_LAUNCH" "$PANE_A")
PANE_B_RECT=$(pane_rect "$PANE_LAUNCH" "$PANE_B")
[ "$(rect_field "$PANE_B_RECT" 1)" = "$(rect_field "$PANE_A_RECT_2" 1)" ] \
  || fail "the second worker must share the first worker's right-hand column, A=$PANE_A_RECT_2 B=$PANE_B_RECT"
[ "$(rect_field "$PANE_B_RECT" 2)" -gt "$(rect_field "$PANE_A_RECT_2" 2)" ] \
  || fail "the second worker must sit BELOW the first (top-right/bottom-right), A=$PANE_A_RECT_2 B=$PANE_B_RECT"
pass "real herdr E2E: the second worker splits within the right half below the first, and the launcher pane is never touched again"

# --- 4b. a third worker stacks below the current bottom of the right column

D_BRIEF_DIR="$PANE_HOME/data/paneD"; mkdir -p "$D_BRIEF_DIR"
printf 'trivial pane-placement brief: nothing to do.\n' > "$D_BRIEF_DIR/brief.md"
spawn_from_launcher "$PANE_LAUNCH" "$PANE_HOME" paneD "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a third pane-placed spawn failed"$'\n'"$(cat "$SPAWN_ERR")"
META_D="$PANE_HOME/state/paneD.meta"
record_worktree "$META_D"
PANE_D=$(meta_field "$META_D" herdr_pane_id)
[ -n "$PANE_D" ] && [ "$PANE_D" != "$PANE_A" ] && [ "$PANE_D" != "$PANE_B" ] \
  || fail "the third worker did not get its own pane"
[ "$(pane_count_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = 4 ] \
  || fail "the launcher tab should now hold the launcher's pane and three worker panes"
LAUNCHER_RECT_3=$(pane_rect "$PANE_LAUNCH" "$PANE_LAUNCH")
[ "$LAUNCHER_RECT_3" = "$LAUNCHER_RECT_1" ] \
  || fail "the third worker must never re-split the launcher's own pane, was=$LAUNCHER_RECT_1 now=$LAUNCHER_RECT_3"
PANE_B_RECT_3=$(pane_rect "$PANE_LAUNCH" "$PANE_B")
PANE_D_RECT=$(pane_rect "$PANE_LAUNCH" "$PANE_D")
[ "$(rect_field "$PANE_D_RECT" 1)" = "$(rect_field "$PANE_B_RECT_3" 1)" ] \
  || fail "the third worker must stay in the same right-hand column, B=$PANE_B_RECT_3 D=$PANE_D_RECT"
[ "$(rect_field "$PANE_D_RECT" 2)" -gt "$(rect_field "$PANE_B_RECT_3" 2)" ] \
  || fail "the third worker must land below the current bottom of the right-hand stack, B=$PANE_B_RECT_3 D=$PANE_D_RECT"
pass "real herdr E2E: a third worker splits the bottom-most pane of the right-hand stack, keeping the launcher and the higher worker panes untouched"

# --- 5. an absent config keeps the tab topology unchanged ------------------

spawn_from_launcher "$PANE_LAUNCH" "$TAB_HOME" tabC "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a default-placement spawn failed"$'\n'"$(cat "$SPAWN_ERR")"
META_C="$TAB_HOME/state/tabC.meta"
record_worktree "$META_C"
PANE_C=$(meta_field "$META_C" herdr_pane_id)
[ "$(pane_field "$PANE_C" workspace_id)" = "$WS_LAUNCH" ] \
  || fail "the default placement should still use the launcher's workspace"
[ "$(pane_field "$PANE_C" tab_id)" != "$TAB_LAUNCH" ] \
  || fail "with no placement configured, the worker must get its own tab, not join the launcher's"
[ "$(meta_field "$META_C" herdr_tab_id)" = "$(pane_field "$PANE_C" tab_id)" ] \
  || fail "the default placement recorded a tab other than the one it created"
[ "$(pane_count_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = 4 ] \
  || fail "a default-placement spawn added a pane to the launcher's own tab"
pass "real herdr E2E: an absent config/herdr-crew-placement still produces one task tab per worker"

# --- 6. teardown of the bottom-most worker retargets the next spawn onto ---
#        the new bottom-most SURVIVING worker pane (never a stale slot, never
#        the launcher).

teardown_task "$PANE_HOME" paneD || fail "fm-teardown.sh failed for paneD"$'\n'"$(cat "$TMP_ROOT/paneD.teardown.out")"
[ ! -f "$META_D" ] || fail "fm-teardown.sh did not remove paneD's durable record"
if lab pane get "$PANE_D" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close paneD's own pane"
fi
lab pane get "$PANE_LAUNCH" >/dev/null 2>&1 || fail "cleanup closed the launching agent's own pane"
lab pane get "$PANE_A" >/dev/null 2>&1 || fail "cleanup closed a surviving worker's pane (A)"
lab pane get "$PANE_B" >/dev/null 2>&1 || fail "cleanup closed a surviving worker's pane (B)"
tab_exists "$WS_LAUNCH" "$TAB_LAUNCH" || fail "cleanup closed the shared tab"
[ "$(pane_count_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = 3 ] \
  || fail "cleanup removed more than the one worker pane"

R1_BRIEF_DIR="$PANE_HOME/data/paneRespawn1"; mkdir -p "$R1_BRIEF_DIR"
printf 'trivial pane-placement brief: nothing to do.\n' > "$R1_BRIEF_DIR/brief.md"
spawn_from_launcher "$PANE_LAUNCH" "$PANE_HOME" paneRespawn1 "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a respawn after teardown of the bottom-most worker failed"$'\n'"$(cat "$SPAWN_ERR")"
META_R1="$PANE_HOME/state/paneRespawn1.meta"
record_worktree "$META_R1"
PANE_R1=$(meta_field "$META_R1" herdr_pane_id)
[ -n "$PANE_R1" ] || fail "paneRespawn1 meta is missing herdr_pane_id"
[ "$(pane_count_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = 4 ] \
  || fail "the respawn should have added exactly one pane back to the launcher's tab"
LAUNCHER_RECT_4=$(pane_rect "$PANE_LAUNCH" "$PANE_LAUNCH")
[ "$LAUNCHER_RECT_4" = "$LAUNCHER_RECT_1" ] \
  || fail "a respawn must never re-split the launcher's own pane, was=$LAUNCHER_RECT_1 now=$LAUNCHER_RECT_4"
PANE_B_RECT_4=$(pane_rect "$PANE_LAUNCH" "$PANE_B")
PANE_R1_RECT=$(pane_rect "$PANE_LAUNCH" "$PANE_R1")
[ "$(rect_field "$PANE_R1_RECT" 1)" = "$(rect_field "$PANE_B_RECT_4" 1)" ] \
  || fail "the respawn must stay in the right-hand column, B=$PANE_B_RECT_4 respawn=$PANE_R1_RECT"
[ "$(rect_field "$PANE_R1_RECT" 2)" -gt "$(rect_field "$PANE_B_RECT_4" 2)" ] \
  || fail "the respawn must land below B, the new bottom-most SURVIVOR (not D's old slot), B=$PANE_B_RECT_4 respawn=$PANE_R1_RECT"
pass "real herdr E2E: tearing down the bottom-most worker retargets the next spawn onto the new bottom-most surviving worker pane"

# --- 7. the same close path holds when the worker's tab is the ACTIVE tab --
# This is the shape the tab topology never produces and the reason the
# focus-safe emptying plan is inapplicable rather than skipped here. Draining
# every worker pane down to none, then spawning once more, also proves the
# "no survivor" fallback: the next worker takes the right half exactly like
# the very first one did.

lab tab focus "$TAB_LAUNCH" >/dev/null 2>&1 || fail "could not focus the launcher's own tab"
[ "$(focused_workspace)" = "$WS_LAUNCH" ] || fail "the launcher's workspace did not take focus"
teardown_task "$PANE_HOME" paneRespawn1 || fail "fm-teardown.sh failed for paneRespawn1 in the active tab"$'\n'"$(cat "$TMP_ROOT/paneRespawn1.teardown.out")"
[ ! -f "$META_R1" ] || fail "fm-teardown.sh did not remove paneRespawn1's durable record"
if lab pane get "$PANE_R1" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close paneRespawn1's own pane in the active tab"
fi
lab pane get "$PANE_LAUNCH" >/dev/null 2>&1 || fail "an active-tab cleanup closed the launching agent's own pane"
tab_exists "$WS_LAUNCH" "$TAB_LAUNCH" || fail "an active-tab cleanup closed the shared tab"
lab workspace list 2>/dev/null | jq -e --arg w "$WS_LAUNCH" 'any(.result.workspaces[]?; .workspace_id == $w)' >/dev/null 2>&1 \
  || fail "an active-tab cleanup removed the launcher's workspace"
[ "$(pane_count_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = 3 ] \
  || fail "closing paneRespawn1 should leave exactly the launcher, A, and B"
pass "real herdr E2E: closing a worker that shares the captain's ACTIVE tab removes only that pane and never the launcher, tab, or workspace"

teardown_task "$PANE_HOME" paneB || fail "fm-teardown.sh failed draining paneB"$'\n'"$(cat "$TMP_ROOT/paneB.teardown.out")"
teardown_task "$PANE_HOME" paneA || fail "fm-teardown.sh failed draining paneA"$'\n'"$(cat "$TMP_ROOT/paneA.teardown.out")"
[ "$(pane_count_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = 1 ] \
  || fail "the launcher's tab should be back to exactly the launcher's own pane once every worker is gone"

R2_BRIEF_DIR="$PANE_HOME/data/paneRespawn2"; mkdir -p "$R2_BRIEF_DIR"
printf 'trivial pane-placement brief: nothing to do.\n' > "$R2_BRIEF_DIR/brief.md"
spawn_from_launcher "$PANE_LAUNCH" "$PANE_HOME" paneRespawn2 "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a respawn with no surviving worker failed"$'\n'"$(cat "$SPAWN_ERR")"
META_R2="$PANE_HOME/state/paneRespawn2.meta"
record_worktree "$META_R2"
PANE_R2=$(meta_field "$META_R2" herdr_pane_id)
[ -n "$PANE_R2" ] || fail "paneRespawn2 meta is missing herdr_pane_id"
[ "$(pane_count_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = 2 ] \
  || fail "the respawn with no survivor should have added exactly one pane"
LAUNCHER_RECT_5=$(pane_rect "$PANE_LAUNCH" "$PANE_LAUNCH")
[ "$LAUNCHER_RECT_5" = "$LAUNCHER_RECT_1" ] \
  || fail "a respawn with no survivor must still keep the launcher's own pane exactly as it started, was=$LAUNCHER_RECT_1 now=$LAUNCHER_RECT_5"
PANE_R2_RECT=$(pane_rect "$PANE_LAUNCH" "$PANE_R2")
[ "$(rect_field "$PANE_R2_RECT" 1)" -gt "$(rect_field "$LAUNCHER_RECT_5" 1)" ] \
  || fail "with no worker pane surviving, the next spawn must behave like the first worker and land right of the launcher, launcher=$LAUNCHER_RECT_5 respawn=$PANE_R2_RECT"
pass "real herdr E2E: once every worker pane is gone, the next spawn falls back to the first-worker case and takes the right half again"

teardown_task "$PANE_HOME" paneRespawn2 || fail "fm-teardown.sh failed draining paneRespawn2"$'\n'"$(cat "$TMP_ROOT/paneRespawn2.teardown.out")"
[ "$(pane_count_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = 1 ] \
  || fail "the launcher's tab should be back to exactly the launcher's own pane before the refusal cases"

lab tab focus "$WS_OTHER_TAB" >/dev/null 2>&1 || fail "could not restore focus to the captain's workspace"

# --- 8. refusals happen before any endpoint exists ------------------------

PANES_BEFORE=$(panes_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")

spawn_from_launcher "" "$PANE_HOME" noLauncherD "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -ne 0 ] || fail "pane placement without a launcher pane must refuse, not fall back to a tab"
assert_contains_local "$(cat "$SPAWN_ERR")" "not running inside one" \
  "the refusal did not report the missing launcher pane"
[ ! -e "$PANE_HOME/state/noLauncherD.meta" ] || fail "a refused spawn published task metadata"
[ "$(panes_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = "$PANES_BEFORE" ] \
  || fail "a refused spawn changed the launcher's tab"

spawn_from_launcher "$PANE_LAUNCH" "$CONFLICT_HOME" conflictE "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -ne 0 ] || fail "pane placement with presentation spaces explicitly on must refuse"
assert_contains_local "$(cat "$SPAWN_ERR")" "cannot both share the launcher's tab" \
  "the conflict refusal did not name the contradiction"
[ ! -e "$CONFLICT_HOME/state/conflictE.meta" ] || fail "a refused conflict spawn published task metadata"
[ ! -e "$CONFLICT_HOME/state/conflictE.herdr-presentation" ] \
  || fail "a refused conflict spawn published a presentation journal"
[ "$(panes_in_tab "$WS_LAUNCH" "$TAB_LAUNCH")" = "$PANES_BEFORE" ] \
  || fail "a refused conflict spawn changed the launcher's tab"
pass "real herdr E2E: a missing launcher pane and an explicit placement/projection conflict both refuse before any worker endpoint exists"

if ! cleanup_all; then
  trap - EXIT
  printf 'not ok - isolated Herdr lab teardown failed or the default fleet session changed\n' >&2
  exit 1
fi
trap - EXIT
pass "real herdr E2E: isolated lab session removed and default fleet session unchanged"
