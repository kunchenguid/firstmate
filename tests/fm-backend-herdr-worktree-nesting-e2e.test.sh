#!/usr/bin/env bash
# tests/fm-backend-herdr-worktree-nesting-e2e.test.sh - ISOLATED real-Herdr
# end-to-end test for opt-in config/herdr-worktree-nesting: a task moves into a
# Herdr worktree workspace bound to its exact launcher workspace, the recorded
# endpoint follows the move, a launcher that is not the project repository
# workspace falls back to the flat tab, and teardown removes the child.
# Every lifecycle operation goes through bin/fm-herdr-lab.sh (tests/herdr-test-safety.sh).
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

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-nesting-e2e.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-nesting) || {
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
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
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

workspace_of_pane() {  # <pane_id>
  lab pane get "$1" 2>/dev/null | jq -r '.result.pane.workspace_id // empty' 2>/dev/null
}

label_of_workspace() {  # <workspace_id>
  lab workspace list 2>/dev/null \
    | jq -r --arg id "$1" '.result.workspaces[]? | select(.workspace_id == $id) | .label' 2>/dev/null
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
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'echo launcher-ws-ok'" --backend herdr "$@" \
      >"$SPAWN_OUT" 2>"$SPAWN_ERR"
  else
    env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
      FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'echo launcher-ws-ok'" --backend herdr "$@" \
      >"$SPAWN_OUT" 2>"$SPAWN_ERR"
  fi
  SPAWN_RC=$?
  return 0
}

record_worktree() {  # <meta>
  local wt
  wt=$(grep '^worktree=' "$1" 2>/dev/null | cut -d= -f2-)
  [ -n "$wt" ] && WORKTREES+=("$wt")
  return 0
}


LAB_SOCKET=$(lab session list --json 2>/dev/null \
  | jq -r --arg s "$HERDR_LAB_SESSION" '.sessions[]? | select(.name == $s) | .socket_path' 2>/dev/null)
[ -n "$LAB_SOCKET" ] || fail "could not read the isolated lab session's socket path"

worktree_path_of_workspace() {  # <workspace_id>
  lab workspace get "$1" 2>/dev/null | jq -r '.result.workspace.worktree.checkout_path // empty' 2>/dev/null
}
linked_of_workspace() {  # <workspace_id>
  lab workspace get "$1" 2>/dev/null | jq -r '.result.workspace.worktree.is_linked_worktree // empty' 2>/dev/null
}
focused_workspace() {
  lab workspace list 2>/dev/null | jq -r '[.result.workspaces[]? | select(.focused == true) | .workspace_id][0] // empty' 2>/dev/null
}
real() { (cd "$1" 2>/dev/null && pwd -P); }

write_ship_brief() {  # <file> <id>
  cat > "$1" <<BRIEF
# Task
## Captain's intent
Exercise Herdr worktree nesting for $2.

## Firstmate spec
Verify the worker is shown as a Herdr worktree child of its launcher.
BRIEF
}

NEST_HOME="$TMP_ROOT/nest-home"
mkdir -p "$NEST_HOME/state" "$NEST_HOME/config"
printf 'off\n' > "$NEST_HOME/config/herdr-presentation-spaces"
printf 'on\n' > "$NEST_HOME/config/herdr-worktree-nesting"
for id in nestA flatB; do mkdir -p "$NEST_HOME/data/$id"; write_ship_brief "$NEST_HOME/data/$id/brief.md" "$id"; done

PROJ="$TMP_ROOT/scratch-project"; make_scratch_project "$PROJ"

# The captain's unrelated workspace keeps focus throughout.
read -r WS_OTHER WS_OTHER_TAB _ <<IDS
$(make_workspace captain-other)
IDS
lab tab focus "$WS_OTHER_TAB" >/dev/null 2>&1 || fail "could not focus the unrelated captain workspace"

# --- 1. launcher workspace rooted at the project: the task nests under it ---

LAUNCH_OUT=$(lab workspace create --cwd "$PROJ" --label "FM-X operations" --no-focus 2>/dev/null)
WS_PARENT=$(printf '%s' "$LAUNCH_OUT" | jq -r .result.workspace.workspace_id)
LAUNCH_PANE=$(printf '%s' "$LAUNCH_OUT" | jq -r .result.root_pane.pane_id)
[ -n "$WS_PARENT" ] && [ -n "$LAUNCH_PANE" ] || fail "could not create the project-rooted launcher workspace"

spawn_from_launcher "$LAUNCH_PANE" "$NEST_HOME" nestA "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a nesting spawn failed"$'\n'"$(cat "$SPAWN_ERR")"
NESTA_META="$NEST_HOME/state/nestA.meta"
record_worktree "$NESTA_META"
NESTA_WT=$(grep '^worktree=' "$NESTA_META" | cut -d= -f2-)
NESTA_PANE=$(grep '^herdr_pane_id=' "$NESTA_META" | cut -d= -f2-)
NESTA_WS_META=$(grep '^herdr_workspace_id=' "$NESTA_META" | cut -d= -f2-)
NESTA_WS=$(workspace_of_pane "$NESTA_PANE")
[ -n "$NESTA_WS" ] || fail "nestA's recorded pane $NESTA_PANE does not resolve; meta was not updated after the move"$'\n'"$(cat "$SPAWN_ERR")"
[ "$NESTA_WS" = "$NESTA_WS_META" ] || fail "nestA meta records workspace $NESTA_WS_META but its pane is in $NESTA_WS"
[ "$NESTA_WS" != "$WS_PARENT" ] || fail "nestA stayed flat in the launcher workspace"$'\n'"$(cat "$SPAWN_ERR")"
[ "$(real "$(worktree_path_of_workspace "$NESTA_WS")")" = "$(real "$NESTA_WT")" ] \
  || fail "nestA's workspace is not the Herdr worktree workspace for its task worktree"
[ "$(linked_of_workspace "$NESTA_WS")" = true ] || fail "nestA's workspace is not a linked-worktree child"
[ "$(real "$(worktree_path_of_workspace "$WS_PARENT")")" = "$(real "$PROJ")" ] \
  || fail "the launcher workspace was not bound as the repository parent"
[ "$(label_of_workspace "$WS_PARENT")" = "FM-X operations" ] || fail "nesting relabeled the launcher workspace"
[ "$(label_of_workspace "$NESTA_WS")" = fm-nestA ] || fail "the child workspace is not labeled with the task label"
[ "$(lab workspace get "$NESTA_WS" | jq -r .result.workspace.tab_count)" = 1 ] \
  || fail "the child's seeded shell tab was not closed"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "nesting stole focus from the captain's workspace"
pass "real herdr E2E: with nesting on, the task becomes a Herdr worktree child of its exact launcher workspace, meta follows the moved pane, focus is kept"

# --- 2. launcher workspace NOT rooted at the project: flat fallback --------

read -r WS_FLAT _ FLAT_PANE <<IDS
$(make_workspace "FM-Y operations")
IDS
spawn_from_launcher "$FLAT_PANE" "$NEST_HOME" flatB "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a failed nesting must fall back, not fail the spawn"$'\n'"$(cat "$SPAWN_ERR")"
FLATB_META="$NEST_HOME/state/flatB.meta"
record_worktree "$FLATB_META"
FLATB_PANE=$(grep '^herdr_pane_id=' "$FLATB_META" | cut -d= -f2-)
[ "$(workspace_of_pane "$FLATB_PANE")" = "$WS_FLAT" ] || fail "fallback did not keep the flat task tab in the launcher workspace"
assert_contains_local "$(cat "$SPAWN_ERR")" "herdr worktree nesting unavailable for flatB" "fallback did not warn"
pass "real herdr E2E: when the launcher is not the project's repository workspace, nesting falls back to the flat tab and the spawn still succeeds"

# --- 3. teardown removes the child workspace with the task ------------------

FM_HOME="$NEST_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$NEST_HOME/state" FM_DATA_OVERRIDE="$NEST_HOME/data" \
  FM_CONFIG_OVERRIDE="$NEST_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" nestA >"$TMP_ROOT/teardown.out" 2>&1 \
  || fail "fm-teardown.sh failed for nestA"$'\n'"$(cat "$TMP_ROOT/teardown.out")"
[ ! -f "$NESTA_META" ] || fail "teardown did not remove nestA meta"
if lab pane get "$NESTA_PANE" >/dev/null 2>&1; then fail "teardown did not close nestA's moved pane"; fi
if lab workspace get "$NESTA_WS" >/dev/null 2>&1; then fail "the emptied child workspace survived teardown"; fi
lab pane get "$LAUNCH_PANE" >/dev/null 2>&1 || fail "teardown closed the launcher pane"
[ "$(label_of_workspace "$WS_PARENT")" = "FM-X operations" ] || fail "teardown removed or renamed the launcher workspace"
pass "real herdr E2E: teardown closes the moved task pane, its child workspace disappears, and the launcher is untouched"

if ! cleanup_all; then
  trap - EXIT
  printf 'not ok - isolated Herdr lab teardown failed or the default fleet session changed\n' >&2
  exit 1
fi
trap - EXIT
pass "real herdr E2E: isolated lab session removed and default fleet session unchanged"
