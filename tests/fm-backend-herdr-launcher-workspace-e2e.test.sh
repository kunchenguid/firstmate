#!/usr/bin/env bash
# tests/fm-backend-herdr-launcher-workspace-e2e.test.sh - mandatory ISOLATED
# end-to-end real-Herdr test for worker PLACEMENT with presentation spaces
# disabled.
#
# The guarantee under test: a crewmate or scout is created in the exact Herdr
# workspace of the firstmate or secondmate process that launched it, identified
# from that process's own Herdr pane rather than from a workspace label. Herdr
# enforces no workspace-label uniqueness, so two workspaces can both be labeled
# "firstmate", and the previous label-first-match resolution put the worker in
# whichever one sorted first - visibly the wrong space whenever the launcher was
# not in it.
#
# This drives the REAL bin/fm-spawn.sh and bin/fm-teardown.sh, because the
# guarantee spans the whole spawn handoff (fm-spawn.sh's herdr arm ->
# fm_backend_herdr_container_ensure -> fm_backend_herdr_workspace_ensure ->
# fm_backend_herdr_launcher_identity) and no adapter primitive holds it alone.
# The headline duplicate-label case additionally runs fm-spawn.sh INSIDE a real
# Herdr pane, so the pane identity comes from Herdr's own injection rather than
# from an environment this test composed.
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

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-launcher-e2e.XXXXXX")
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-launcher-ws) || {
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

# Production spawn and teardown reach Herdr through this PATH shim, which drops
# only the adapter's own trailing lab-session flag, refuses any other session,
# and sends every call through the lab helper's guarded run.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
{
  printf '#!/usr/bin/env bash\nset -u\n'
  printf 'LAB_SESSION=%q LAB_HELPER=%q ORIGINAL_PATH=%q\n' "$HERDR_LAB_SESSION" "$HERDR_LAB_HELPER" "$PATH"
  cat <<'SH'
args=("$@")
last=$((${#args[@]} - 1))
if [ "$last" -ge 1 ] && [ "${args[$((last - 1))]}" = --session ] && [ "${args[$last]}" = "$LAB_SESSION" ]; then
  unset "args[$last]" "args[$((last - 1))]"
fi
set -- ${args[@]+"${args[@]}"}
for arg in "$@"; do
  case "$arg" in
    --session|--session=*) echo "lab herdr shim: refusing a call addressed outside $LAB_SESSION" >&2; exit 1 ;;
  esac
done
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "$@"
SH
} > "$FAKEBIN/herdr"
chmod +x "$FAKEBIN/herdr"

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

tab_labels_of_workspace() {  # <workspace_id>
  lab tab list --workspace "$1" 2>/dev/null \
    | jq -r '[.result.tabs[]?.label] | sort | join(",")' 2>/dev/null
}

journal_field() {  # <presentation-journal> <key>
  grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-
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
    env PATH="$FAKEBIN:$PATH" HERDR_ENV=1 HERDR_PANE_ID="$pane" HERDR_SESSION="$HERDR_LAB_SESSION" \
      HERDR_SOCKET_PATH="$LAB_SOCKET" \
      FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'echo launcher-ws-ok'" --backend herdr "$@" \
      >"$SPAWN_OUT" 2>"$SPAWN_ERR"
  else
    env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH PATH="$FAKEBIN:$PATH" HERDR_SESSION="$HERDR_LAB_SESSION" \
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

# --- scratch world ----------------------------------------------------------

# Presentation spaces are on by default, so every home that asserts the FLAT
# layout below opts out explicitly rather than depending on that default.
PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/config"
printf 'off\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
SM_ID="lwsm1"
SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin" "$SM_HOME/data"
printf 'off\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf '%s\n' "$SM_ID" > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"

SM2_ID="lwsm2"
SM2_HOME="$TMP_ROOT/secondmate-home-2"
mkdir -p "$SM2_HOME/state" "$SM2_HOME/config" "$SM2_HOME/projects" "$SM2_HOME/bin" "$SM2_HOME/data"
printf 'off\n' > "$SM2_HOME/config/herdr-presentation-spaces"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM2_HOME/AGENTS.md"
printf '%s\n' "$SM2_ID" > "$SM2_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM2_HOME/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$SM2_HOME/.gitignore"
git -C "$SM2_HOME" init -q -b main

# A third primary-shaped home that keeps presentation spaces ON through the
# historical empty opt-in file, so the default-on migration is exercised against
# real Herdr while the opted-out homes above assert the flat layout in isolation.
PRES_HOME="$TMP_ROOT/presentation-home"
mkdir -p "$PRES_HOME/state" "$PRES_HOME/config"
: > "$PRES_HOME/config/herdr-presentation-spaces"

write_ship_brief() {  # <file> <id>
  cat > "$1" <<EOF
# Task
## Captain's intent
Exercise Herdr launcher placement for $2.

## Firstmate spec
Verify the worker is placed in the correct workspace.
EOF
}

for id in uniqA uniqB dupC dupD staleF smE presU presD namedA1 namedB1 namedA2 namedB2 namedNL namedNT; do
  mkdir -p "$PRIMARY_HOME/data/$id" "$SM_HOME/data/$id" "$PRES_HOME/data/$id"
  write_ship_brief "$PRIMARY_HOME/data/$id/brief.md" "$id"
  write_ship_brief "$SM_HOME/data/$id/brief.md" "$id"
  write_ship_brief "$PRES_HOME/data/$id/brief.md" "$id"
done
mkdir -p "$PRIMARY_HOME/data/$SM2_ID"
printf 'trivial secondmate charter brief: nothing to do.\n' > "$PRIMARY_HOME/data/$SM2_ID/brief.md"

PROJ="$TMP_ROOT/scratch-project"; make_scratch_project "$PROJ"

# One unrelated workspace, kept FOCUSED throughout, so every placement result
# below is also evidence that the globally focused workspace is never the target.
read -r WS_OTHER WS_OTHER_TAB _ <<EOF
$(make_workspace captain-other)
EOF
[ -n "$WS_OTHER" ] || fail "could not create the unrelated captain workspace"
lab tab focus "$WS_OTHER_TAB" >/dev/null 2>&1 || fail "could not focus the unrelated captain workspace"

focused_workspace() {
  lab workspace list 2>/dev/null | jq -r '[.result.workspaces[]? | select(.focused == true) | .workspace_id][0] // empty' 2>/dev/null
}
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "the unrelated captain workspace did not take focus"

# --- 1. unique label, no herdr ancestry: the per-home container still works --

spawn_from_launcher "" "$PRIMARY_HOME" uniqA "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a primary-shaped spawn with no herdr parent failed"$'\n'"$(cat "$SPAWN_ERR")"
UNIQA_META="$PRIMARY_HOME/state/uniqA.meta"
record_worktree "$UNIQA_META"
UNIQA_PANE=$(grep '^herdr_pane_id=' "$UNIQA_META" | cut -d= -f2-)
[ -n "$UNIQA_PANE" ] || fail "uniqA meta is missing herdr_pane_id"
WS_PRIMARY=$(workspace_of_pane "$UNIQA_PANE")
[ -n "$WS_PRIMARY" ] || fail "could not read uniqA's workspace"
[ "$(label_of_workspace "$WS_PRIMARY")" = firstmate ] || fail "uniqA did not land in a 'firstmate' workspace"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "the spawn stole focus from the captain's workspace"
pass "real herdr E2E: with one 'firstmate' workspace and no herdr parent, a crewmate still lands in this home's own workspace without stealing focus"

# --- 2. unique label, WITH a launcher pane: same workspace, now by identity --

read -r _ _ LAUNCH_PRIMARY_PANE <<EOF
$(lab tab create --workspace "$WS_PRIMARY" --cwd "$TMP_ROOT" --label captain-shell --no-focus 2>/dev/null \
  | jq -r '["x","x", .result.root_pane.pane_id] | @tsv' | tr '\t' ' ')
EOF
[ -n "$LAUNCH_PRIMARY_PANE" ] || fail "could not create a launcher pane inside the 'firstmate' workspace"

spawn_from_launcher "$LAUNCH_PRIMARY_PANE" "$PRIMARY_HOME" uniqB "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a primary spawn from a launcher pane failed"$'\n'"$(cat "$SPAWN_ERR")"
UNIQB_META="$PRIMARY_HOME/state/uniqB.meta"
record_worktree "$UNIQB_META"
UNIQB_PANE=$(grep '^herdr_pane_id=' "$UNIQB_META" | cut -d= -f2-)
[ "$(workspace_of_pane "$UNIQB_PANE")" = "$WS_PRIMARY" ] \
  || fail "a crewmate launched from the 'firstmate' workspace must stay in it"
pass "real herdr E2E: the normal unique-label path is unchanged when the launcher's own pane identifies the workspace"

# --- 2b. presentation spaces ON: the projected child is created and bound
#         UNDER the launcher's exact workspace, not collapsed into it ---------

spawn_from_launcher "$LAUNCH_PRIMARY_PANE" "$PRES_HOME" presU "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a presentation-enabled spawn from a launcher pane failed"$'\n'"$(cat "$SPAWN_ERR")"
PRESU_META="$PRES_HOME/state/presU.meta"
record_worktree "$PRESU_META"
PRESU_PANE=$(grep '^herdr_pane_id=' "$PRESU_META" | cut -d= -f2-)
PRESU_WS=$(workspace_of_pane "$PRESU_PANE")
[ -n "$PRESU_WS" ] || fail "could not read presU's workspace"
[ "$PRESU_WS" != "$WS_PRIMARY" ] \
  || fail "a projected worker must get its own disposable workspace, not be collapsed into its parent"
case "$(label_of_workspace "$PRESU_WS")" in
  "└ "*" · p:"*) : ;;
  *) fail "presU's workspace is not a presentation projection: '$(label_of_workspace "$PRESU_WS")'" ;;
esac
PRESU_JOURNAL="$PRES_HOME/state/presU.herdr-presentation"
[ -f "$PRESU_JOURNAL" ] || fail "a projected spawn did not leave its presentation journal"
[ "$(journal_field "$PRESU_JOURNAL" version)" = 2 ] \
  || fail "the projection did not publish an exact restart binding"$'\n'"$(cat "$PRESU_JOURNAL")"
[ "$(journal_field "$PRESU_JOURNAL" parent_workspace_id)" = "$WS_PRIMARY" ] \
  || fail "the projection bound a parent other than the launcher's own workspace ($WS_PRIMARY)"
[ "$(journal_field "$PRESU_JOURNAL" workspace_id)" = "$PRESU_WS" ] \
  || fail "the projection journal does not name its own workspace"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "a projected spawn stole focus from the captain's workspace"
pass "real herdr E2E: presentation spaces still create the isolated child workspace and bind it under the launcher's exact parent, without stealing focus"

# --- 3. duplicate label, launcher in the NON-first match, driven from a real
#        Herdr pane so the identity comes from Herdr's own injection ----------

read -r WS_PRIMARY_DUP _ LAUNCH_DUP_PANE <<EOF
$(make_workspace firstmate)
EOF
[ -n "$WS_PRIMARY_DUP" ] || fail "could not create the second 'firstmate' workspace"
[ "$WS_PRIMARY_DUP" != "$WS_PRIMARY" ] || fail "the two 'firstmate' workspaces must be distinct"
DUP_COUNT=$(lab workspace list 2>/dev/null | jq -r '[.result.workspaces[]? | select(.label == "firstmate")] | length')
[ "$DUP_COUNT" = 2 ] || fail "expected exactly two 'firstmate' workspaces, got $DUP_COUNT"
WS_PRIMARY_TABS_BEFORE=$(tab_labels_of_workspace "$WS_PRIMARY")

cat > "$TMP_ROOT/spawn-in-pane.sh" <<SPAWN
#!/usr/bin/env bash
set -u
PATH="$FAKEBIN:\$PATH" FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \\
  "$ROOT/bin/fm-spawn.sh" dupC "$PROJ" "sh -c 'echo launcher-ws-ok'" --mode no-mistakes --yolo off --backend herdr \\
  > "$TMP_ROOT/dupC.out" 2> "$TMP_ROOT/dupC.err"
echo \$? > "$TMP_ROOT/dupC.rc"
SPAWN
chmod +x "$TMP_ROOT/spawn-in-pane.sh"
lab pane run "$LAUNCH_DUP_PANE" "$TMP_ROOT/spawn-in-pane.sh" >/dev/null 2>&1 \
  || fail "could not run fm-spawn.sh inside the launcher's herdr pane"
i=0
while [ ! -f "$TMP_ROOT/dupC.rc" ] && [ "$i" -lt 120 ]; do sleep 2; i=$((i + 1)); done
[ -f "$TMP_ROOT/dupC.rc" ] || fail "fm-spawn.sh never finished inside the launcher's herdr pane"
[ "$(cat "$TMP_ROOT/dupC.rc")" = 0 ] \
  || fail "the in-pane spawn failed"$'\n'"$(cat "$TMP_ROOT/dupC.err" 2>/dev/null)"

DUPC_META="$PRIMARY_HOME/state/dupC.meta"
record_worktree "$DUPC_META"
DUPC_PANE=$(grep '^herdr_pane_id=' "$DUPC_META" | cut -d= -f2-)
DUPC_WS=$(workspace_of_pane "$DUPC_PANE")
[ "$DUPC_WS" = "$WS_PRIMARY_DUP" ] \
  || fail "a worker launched from the second 'firstmate' workspace ($WS_PRIMARY_DUP) landed in '$DUPC_WS' instead"
[ "$DUPC_WS" != "$WS_PRIMARY" ] || fail "the worker was placed in the first label match, the defect under test"
[ "$DUPC_WS" != "$WS_OTHER" ] || fail "the worker was placed in the globally focused workspace"
[ "$(grep '^herdr_workspace_id=' "$DUPC_META" | cut -d= -f2-)" = "$WS_PRIMARY_DUP" ] \
  || fail "the recorded endpoint workspace does not match the launcher's workspace"
pass "real herdr E2E: with two 'firstmate' workspaces, a worker spawned from inside the second one lands in that exact workspace"

[ "$(tab_labels_of_workspace "$WS_PRIMARY")" = "$WS_PRIMARY_TABS_BEFORE" ] \
  || fail "the other same-labeled workspace's tabs changed; it must never be adopted or mutated"
[ "$(label_of_workspace "$WS_PRIMARY")" = firstmate ] \
  || fail "the other same-labeled workspace was renamed"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "the in-pane spawn stole focus from the captain's workspace"
pass "real herdr E2E: the duplicate-labeled sibling workspace is left entirely untouched and focus is preserved"

# --- 3b. presentation spaces ON with a duplicated parent label: the projection
#         still hangs off the launcher's exact workspace ---------------------

spawn_from_launcher "$LAUNCH_DUP_PANE" "$PRES_HOME" presD "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a projected spawn under a duplicated parent label failed"$'\n'"$(cat "$SPAWN_ERR")"
PRESD_META="$PRES_HOME/state/presD.meta"
record_worktree "$PRESD_META"
PRESD_PANE=$(grep '^herdr_pane_id=' "$PRESD_META" | cut -d= -f2-)
PRESD_WS=$(workspace_of_pane "$PRESD_PANE")
[ -n "$PRESD_WS" ] || fail "could not read presD's workspace"
PRESD_JOURNAL="$PRES_HOME/state/presD.herdr-presentation"
[ "$(journal_field "$PRESD_JOURNAL" version)" = 2 ] \
  || fail "the duplicate-label projection did not publish a version 2 binding"$'\n'"$(cat "$PRESD_JOURNAL" 2>/dev/null)"
[ "$(journal_field "$PRESD_JOURNAL" parent_workspace_id)" = "$WS_PRIMARY_DUP" ] \
  || fail "the duplicate-label projection journal did not bind the launcher's exact parent workspace"
[ "$PRESD_WS" != "$WS_PRIMARY" ] && [ "$PRESD_WS" != "$WS_PRIMARY_DUP" ] \
  || fail "a projected worker must not be collapsed into either same-labeled parent workspace"
PRESD_ORDER=$(lab workspace list 2>/dev/null | jq -r --arg dup "$WS_PRIMARY_DUP" --arg child "$PRESD_WS" '
  [range(0; (.result.workspaces | length)) as $i
    | {i: $i, id: .result.workspaces[$i].workspace_id}]
  | ((map(select(.id == $child)) | .[0].i) - (map(select(.id == $dup)) | .[0].i))')
[ "$PRESD_ORDER" = 1 ] \
  || fail "the projected child should sit immediately after the launcher's own workspace, offset was '$PRESD_ORDER'"
[ "$(tab_labels_of_workspace "$WS_PRIMARY")" = "$WS_PRIMARY_TABS_BEFORE" ] \
  || fail "the other same-labeled workspace was mutated by a projected spawn"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "a projected spawn stole focus from the captain's workspace"
pass "real herdr E2E: with a duplicated home label, a projected worker still hangs off the launcher's exact workspace and the sibling stays untouched"

# --- 3c. arbitrary parent labels and interleaved launches keep each block ---

read -r WS_NAMED_A _ LAUNCH_NAMED_A <<EOF
$(make_workspace project-a)
EOF
read -r WS_NAMED_B _ LAUNCH_NAMED_B <<EOF
$(make_workspace project-b)
EOF
for id in namedA1 namedB1 namedA2 namedB2; do
  case "$id" in
    namedA*) parent=$WS_NAMED_A; launcher=$LAUNCH_NAMED_A; parent_label=project-a ;;
    namedB*) parent=$WS_NAMED_B; launcher=$LAUNCH_NAMED_B; parent_label=project-b ;;
  esac
  spawn_from_launcher "$launcher" "$PRES_HOME" "$id" "$PROJ" --mode no-mistakes --yolo off
  [ "$SPAWN_RC" -eq 0 ] || fail "a projected spawn under $parent_label failed"$'\n'"$(cat "$SPAWN_ERR")"
  meta="$PRES_HOME/state/$id.meta"
  record_worktree "$meta"
  journal="$PRES_HOME/state/$id.herdr-presentation"
  [ "$(journal_field "$journal" version)" = 2 ] \
    && [ "$(journal_field "$journal" parent_workspace_id)" = "$parent" ] \
    && [ "$(journal_field "$journal" parent_label)" = "$parent_label" ] \
    || fail "a named parent must publish its exact id and actual label in the restart binding"
  child=$(workspace_of_pane "$(grep '^herdr_pane_id=' "$meta" | cut -d= -f2-)")
  case "$id" in *1) expected=1 ;; *2) expected=2 ;; esac
  lab workspace list 2>/dev/null | jq -e --arg parent "$parent" --arg child "$child" --argjson expected "$expected" '
    .result.workspaces | map(.workspace_id)
    | (index($child) - index($parent)) == $expected
  ' >/dev/null || fail "a projected child must follow its own named parent's existing block"
  [ "$(focused_workspace)" = "$WS_OTHER" ] || fail "a named-parent spawn changed the unrelated selected workspace"
done
pass "real herdr E2E: named parents retain their own contiguous children and exact bindings across interleaved launches without changing focus"

# --- 3d. a parent label with a line break cannot fit the restart journal ----

# Both an internal and a trailing-only line break; the trailing one is lost by
# a plain shell capture, so it must still be caught before any allocation.
for id in namedNL namedNT; do
  case "$id" in
    namedNL) nl_label=$'project-c\nline-two' ;;
    namedNT) nl_label=$'project-d\n' ;;
  esac
  read -r WS_NAMED_NL _ LAUNCH_NAMED_NL <<EOF
$(make_workspace "$nl_label")
EOF
  [ -n "$WS_NAMED_NL" ] || fail "could not create the line-break-labeled parent workspace for $id"
  lab workspace list 2>/dev/null | jq -e --arg id "$WS_NAMED_NL" --arg label "$nl_label" '
    [.result.workspaces[]? | select(.workspace_id == $id) | .label] == [$label]
  ' >/dev/null || fail "Herdr did not keep the exact line-break parent label $id depends on"
  NL_SPACES_BEFORE=$(lab workspace list 2>/dev/null | jq -r '.result.workspaces | length')
  spawn_from_launcher "$LAUNCH_NAMED_NL" "$PRES_HOME" "$id" "$PROJ" --mode no-mistakes --yolo off
  [ "$SPAWN_RC" -eq 0 ] || fail "a line-break parent label must fall back flat, not fail the spawn ($id)"$'\n'"$(cat "$SPAWN_ERR")"
  record_worktree "$PRES_HOME/state/$id.meta"
  assert_contains_local "$(cat "$SPAWN_ERR")" "contains a line break" "a line-break parent label must warn why it spawned flat ($id)"
  [ ! -e "$PRES_HOME/state/$id.herdr-presentation" ] || fail "a line-break parent label left a presentation journal ($id)"$'\n'"$(cat "$PRES_HOME/state/$id.herdr-presentation")"
  [ "$(lab workspace list 2>/dev/null | jq -r '.result.workspaces | length')" = "$NL_SPACES_BEFORE" ] \
    || fail "a line-break parent label still allocated a projection workspace ($id)"
  [ "$(workspace_of_pane "$(grep '^herdr_pane_id=' "$PRES_HOME/state/$id.meta" | cut -d= -f2-)")" = "$WS_NAMED_NL" ] \
    || fail "the flat fallback did not place the worker in its launcher's exact workspace ($id)"
  [ "$(focused_workspace)" = "$WS_OTHER" ] || fail "a line-break parent spawn changed the unrelated selected workspace ($id)"
done
pass "real herdr E2E: a parent label with an internal or trailing line break spawns flat in its exact workspace with no journal or projection"

# --- 4. duplicate label with NO launcher identity refuses before publishing --

spawn_from_launcher "" "$PRIMARY_HOME" dupD "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -ne 0 ] || fail "a duplicate-labeled home workspace with no herdr parent must refuse, not guess"
assert_contains_local "$(cat "$SPAWN_ERR")" "labeled 'firstmate'" \
  "the refusal did not name the duplicated home label"
[ ! -e "$PRIMARY_HOME/state/dupD.meta" ] || fail "a refused spawn must not publish task metadata"
DUP_TABS=$(lab tab list --workspace "$WS_PRIMARY" 2>/dev/null | jq -r '[.result.tabs[]? | select(.label == "fm-dupD")] | length')
DUP_TABS2=$(lab tab list --workspace "$WS_PRIMARY_DUP" 2>/dev/null | jq -r '[.result.tabs[]? | select(.label == "fm-dupD")] | length')
[ "$DUP_TABS" = 0 ] && [ "$DUP_TABS2" = 0 ] || fail "a refused spawn created a worker endpoint anyway"
pass "real herdr E2E: an ambiguous home label with no launcher identity refuses before any worker endpoint exists"

# --- 5. a STALE launcher pane refuses, even though the home label is
#        unambiguous from the launcher's own (now closed) workspace -----------
# A firstmate whose own pane was closed under it has an identity that no longer
# resolves. Guessing a workspace from the label is exactly what must not happen.

read -r _ _ STALE_PANE <<EOF
$(make_workspace stale-parent)
EOF
[ -n "$STALE_PANE" ] || fail "could not create the workspace whose pane goes stale"
lab pane close "$STALE_PANE" >/dev/null 2>&1
if lab pane get "$STALE_PANE" >/dev/null 2>&1; then
  fail "the launcher pane did not actually go away"
fi

spawn_from_launcher "$STALE_PANE" "$PRIMARY_HOME" staleF "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -ne 0 ] || fail "a launcher pane that no longer exists must refuse, not fall back to a label search"
assert_contains_local "$(cat "$SPAWN_ERR")" "$STALE_PANE" \
  "the stale-identity refusal did not name the launcher pane it could not resolve"
[ ! -e "$PRIMARY_HOME/state/staleF.meta" ] || fail "a refused spawn must not publish task metadata"
STALE_TABS=$(lab tab list --workspace "$WS_PRIMARY_DUP" 2>/dev/null | jq -r '[.result.tabs[]? | select(.label == "fm-staleF")] | length')
[ "$STALE_TABS" = 0 ] || fail "a refused spawn created a worker endpoint anyway"
pass "real herdr E2E: a launcher pane that no longer exists refuses before any worker endpoint exists"

# --- 6. a secondmate launching its own worker gets the same guarantee -------

read -r WS_SM_DECOY _ _ <<EOF
$(make_workspace "2ndmate-$SM_ID")
EOF
read -r WS_SM_LAUNCH _ LAUNCH_SM_PANE <<EOF
$(make_workspace "2ndmate-$SM_ID")
EOF
[ -n "$WS_SM_DECOY" ] && [ -n "$WS_SM_LAUNCH" ] || fail "could not create the two secondmate-labeled workspaces"
WS_SM_DECOY_TABS_BEFORE=$(tab_labels_of_workspace "$WS_SM_DECOY")

spawn_from_launcher "$LAUNCH_SM_PANE" "$SM_HOME" smE "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a secondmate-owned crewmate spawn failed"$'\n'"$(cat "$SPAWN_ERR")"
SME_META="$SM_HOME/state/smE.meta"
record_worktree "$SME_META"
SME_PANE=$(grep '^herdr_pane_id=' "$SME_META" | cut -d= -f2-)
SME_WS=$(workspace_of_pane "$SME_PANE")
[ "$SME_WS" = "$WS_SM_LAUNCH" ] \
  || fail "a secondmate's own worker must land in the secondmate's exact workspace ($WS_SM_LAUNCH), got '$SME_WS'"
[ "$(tab_labels_of_workspace "$WS_SM_DECOY")" = "$WS_SM_DECOY_TABS_BEFORE" ] \
  || fail "the duplicate secondmate-labeled workspace was mutated"
pass "real herdr E2E: a secondmate launching its own worker gets the same exact-workspace guarantee, and its same-labeled sibling is untouched"

# --- 7. a --secondmate launch is NOT collapsed into the launcher's workspace -

spawn_from_launcher "$LAUNCH_DUP_PANE" "$PRIMARY_HOME" "$SM2_ID" "$SM2_HOME" --secondmate
[ "$SPAWN_RC" -eq 0 ] || fail "the primary's --secondmate launch failed"$'\n'"$(cat "$SPAWN_ERR")"
SM2_META="$PRIMARY_HOME/state/$SM2_ID.meta"
SM2_PANE=$(grep '^herdr_pane_id=' "$SM2_META" | cut -d= -f2-)
SM2_WS=$(workspace_of_pane "$SM2_PANE")
[ "$SM2_WS" != "$WS_PRIMARY_DUP" ] \
  || fail "a --secondmate launch must stand up the secondmate's own workspace, not join the launcher's"
[ "$(label_of_workspace "$SM2_WS")" = "2ndmate-$SM2_ID" ] \
  || fail "a --secondmate launch should land in '2ndmate-$SM2_ID', got '$(label_of_workspace "$SM2_WS")'"
pass "real herdr E2E: a --secondmate launch still stands up that secondmate's own workspace instead of inheriting the launcher's"

# --- 8. teardown closes only the worker's own pane --------------------------

PATH="$FAKEBIN:$PATH" FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" \
  FM_DATA_OVERRIDE="$PRIMARY_HOME/data" FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" dupC >"$TMP_ROOT/teardown.out" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "fm-teardown.sh failed for dupC"$'\n'"$(cat "$TMP_ROOT/teardown.out")"
[ ! -f "$DUPC_META" ] || fail "fm-teardown.sh did not remove dupC's meta"
if lab pane get "$DUPC_PANE" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close dupC's own pane"
fi
lab pane get "$LAUNCH_DUP_PANE" >/dev/null 2>&1 || fail "teardown closed the launcher's own pane"
lab pane get "$UNIQB_PANE" >/dev/null 2>&1 || fail "teardown closed an unrelated worker's pane in the other same-labeled workspace"
[ "$(label_of_workspace "$WS_PRIMARY_DUP")" = firstmate ] || fail "teardown removed or renamed the launcher's workspace"
pass "real herdr E2E: teardown closes only the worker's own pane and leaves the launcher, its workspace, and the same-labeled sibling intact"

# --- 9. a restart reclaims a named parent's child; a renamed parent refuses --

NAMED_A1_JOURNAL="$PRES_HOME/state/namedA1.herdr-presentation"
NAMED_A1_WS=$(journal_field "$NAMED_A1_JOURNAL" workspace_id)
NAMED_A1_OLD_PANE=$(journal_field "$NAMED_A1_JOURNAL" pane_id)
NAMED_B1_WS=$(journal_field "$PRES_HOME/state/namedB1.herdr-presentation" workspace_id)
NAMED_B1_LABEL=$(label_of_workspace "$NAMED_B1_WS")
lab workspace rename "$WS_NAMED_B" project-b-renamed >/dev/null 2>&1 \
  || fail "could not rename the project-b parent workspace"
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail "could not stop the isolated session for restart reclaim"
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not reprovision the isolated session for restart reclaim"
RESTART_FOCUS=$(focused_workspace)

spawn_from_launcher "$LAUNCH_NAMED_A" "$PRES_HOME" namedA1 "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a restarted child under a named parent failed to relaunch"$'\n'"$(cat "$SPAWN_ERR")"
record_worktree "$PRES_HOME/state/namedA1.meta"
NAMED_A1_NEW_PANE=$(grep '^herdr_pane_id=' "$PRES_HOME/state/namedA1.meta" | cut -d= -f2-)
[ "$(workspace_of_pane "$NAMED_A1_NEW_PANE")" = "$NAMED_A1_WS" ] && [ "$NAMED_A1_NEW_PANE" != "$NAMED_A1_OLD_PANE" ] \
  || fail "a named parent's restarted child must be reclaimed in its own workspace, not spawned flat"$'\n'"$(cat "$SPAWN_ERR")"
[ "$(journal_field "$NAMED_A1_JOURNAL" pane_id)" = "$NAMED_A1_NEW_PANE" ] \
  && [ "$(journal_field "$NAMED_A1_JOURNAL" parent_label)" = project-a ] \
  || fail "restart reclaim did not advance the named parent's exact binding"
[ "$(focused_workspace)" = "$RESTART_FOCUS" ] || fail "restart reclaim changed the selected workspace"

spawn_from_launcher "$LAUNCH_NAMED_B" "$PRES_HOME" namedB1 "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a renamed parent must fall back flat, not fail the relaunch"$'\n'"$(cat "$SPAWN_ERR")"
record_worktree "$PRES_HOME/state/namedB1.meta"
assert_contains_local "$(cat "$SPAWN_ERR")" "ambiguous, renamed, foreign, or non-nested live shape" "a renamed parent must refuse restart reclaim through its live binding"
[ "$(workspace_of_pane "$(grep '^herdr_pane_id=' "$PRES_HOME/state/namedB1.meta" | cut -d= -f2-)")" != "$NAMED_B1_WS" ] \
  || fail "a renamed parent's child was reclaimed anyway"
[ "$(label_of_workspace "$NAMED_B1_WS")" = "$NAMED_B1_LABEL" ] || fail "a refused reclaim renamed or removed the old projection"
pass "real herdr E2E: after a restart a named parent's child is reclaimed in place, while a renamed parent refuses reclaim and spawns flat"

if ! cleanup_all; then
  trap - EXIT
  printf 'not ok - isolated Herdr lab teardown failed or the default fleet session changed\n' >&2
  exit 1
fi
trap - EXIT
pass "real herdr E2E: isolated lab session removed and default fleet session unchanged"
