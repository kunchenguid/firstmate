#!/usr/bin/env bash
# Real-Herdr worker placement through fm-spawn: every successful ordinary
# worker gets its own task-labelled workspace, including opt-out and reclaim.
# A contended placement lock and a surviving legacy shared endpoint refuse.
# Scratch clones replace pool allocation; no shared worktree pool is touched.
# FM_WORKER_PLACEMENT_CODE_ROOT selects a baseline code export for red/green
# verification. HERDR_LAB_HELPER may select the supervising home's guard.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
CODE_ROOT=${FM_WORKER_PLACEMENT_CODE_ROOT:-$ROOT}
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
HERDR_LAB_HELPER=$(cd "$(dirname "$HERDR_LAB_HELPER")" && pwd -P)/$(basename "$HERDR_LAB_HELPER")
command -v herdr >/dev/null || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null || { echo 'skip: jq not found'; exit 0; }
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-worker-placement.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name worker-placement)
export HERDR_LAB_SESSION HERDR_LAB_HELPER
REAL_PATH=$PATH
export REAL_PATH
PREPARED=0
cleanup() {
  local status=$? cleanup_status=0
  trap - EXIT
  "$LAB_HOME_HELPER" teardown "$TMP_ROOT/home" || cleanup_status=$?
  if [ "$PREPARED" = 1 ]; then
    env PATH="$REAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || cleanup_status=$?
  fi
  # Spawn's exact task hooks are deliberately read-only until task teardown.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} +
  if [ "$cleanup_status" = 0 ]; then
    rm -rf "$TMP_ROOT"
  else
    printf 'not ok - guarded lab cleanup failed; retained evidence at %s session=%s\n' "$TMP_ROOT" "$HERDR_LAB_SESSION" >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
"$LAB_HOME_HELPER" create "$TMP_ROOT/home" >/dev/null
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
PREPARED=1
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# Every adapter command passes through the named-session helper. The only
# substituted operation is pool acquisition: the real pane changes directory
# into the already-created scratch clone instead of calling Treehouse.
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/herdr" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
last=$((${#args[@]} - 1))
previous=$((last - 1))
if [ "$last" -ge 1 ] && [ "${args[$previous]}" = --session ]; then
  [ "${args[$last]}" = "$HERDR_LAB_SESSION" ] || exit 90
  unset 'args[last]' 'args[previous]'
fi
if [ "${args[0]:-} ${args[1]:-}" = 'pane run' ] && [ "${args[3]:-}" = 'treehouse get' ]; then
  args[3]="cd -- '${FIXTURE_WT:?}'"
fi
exec env PATH="$REAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
WRAPPER
chmod +x "$TMP_ROOT/bin/herdr"
export PATH="$TMP_ROOT/bin:$PATH"
export HERDR_SESSION="$HERDR_LAB_SESSION"
export FM_HOME="$TMP_ROOT/home"
printf 'frontdesk\n' > "$FM_HOME/.fm-secondmate-home"
# This test drives successful dedicated worker placement on every supported
# real-Herdr release, including releases below the default-on safety floor.
printf 'on\n' > "$FM_HOME/config/herdr-presentation-spaces"

PROJ="$TMP_ROOT/project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
echo scratch > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=Tests -c user.email=tests@example.invalid commit -qm initial
make_task() {
  local id=$1
  mkdir -p "$FM_HOME/data/$id"
  cat > "$FM_HOME/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Verify accurate worker placement.

## Firstmate spec
Use only the isolated lab.

Delivery contract: mode=no-mistakes
Ship branch: fm/$id
EOF
  git clone -q "$PROJ" "$TMP_ROOT/$id-worker"
  git -C "$TMP_ROOT/$id-worker" remote remove origin
  FIXTURE_WT="$TMP_ROOT/$id-worker"
  export FIXTURE_WT
}
spawn_task() {
  local id=$1
  shift
  local -a args=("$id")
  if [ "${1:-}" = --relaunch ]; then
    args+=("$@" --harness "sh -c 'echo fixture'")
  else
    args+=("$PROJ" "sh -c 'echo fixture'" --backend herdr --mode no-mistakes --yolo off "$@")
  fi
  FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$CODE_ROOT" \
    "$CODE_ROOT/bin/fm-spawn.sh" "${args[@]}" \
    > "$TMP_ROOT/$id.out" 2> "$TMP_ROOT/$id.err"
}
field() { sed -n "s/^$2=//p" "$FM_HOME/state/$1.meta"; }
label_of() {
  lab workspace list | jq -r --arg id "$1" '.result.workspaces[] | select(.workspace_id==$id) | .label'
}
assert_worker() {
  local id=$1 ws label
  ws=$(field "$id" herdr_workspace_id)
  label=$(label_of "$ws")
  [ "$ws" != "$PARENT_WS" ] || fail "$id was placed in its secondmate's workspace"
  case "$label" in
    "fm-$id"|"└ ${id#fm-} · p:"*) ;;
    *) fail "$id workspace has the wrong identity: $label" ;;
  esac
  [ "$(field "$id" worktree)" = "$TMP_ROOT/$id-worker" ] || fail "$id did not use the exact scratch clone"
  lab tab list --workspace "$ws" | jq -e --arg tab "$(field "$id" herdr_tab_id)" --arg label "fm-$id" \
    '.result.tabs | length==1 and .[0].tab_id==$tab and .[0].label==$label' >/dev/null \
    || fail "$id workspace contains something other than its own task"
}

parent=$(lab workspace create --cwd "$FM_HOME" --label 2ndmate-frontdesk --no-focus)
PARENT_WS=$(printf '%s' "$parent" | jq -r '.result.workspace.workspace_id')
export HERDR_ENV=1
HERDR_PANE_ID=$(printf '%s' "$parent" | jq -r '.result.root_pane.pane_id')
HERDR_TAB_ID=$(printf '%s' "$parent" | jq -r '.result.tab.tab_id')
export HERDR_WORKSPACE_ID="$PARENT_WS"
HERDR_SOCKET_PATH=$(lab session list --json | jq -r --arg s "$HERDR_LAB_SESSION" '.sessions[] | select(.name==$s) | .socket_path')
export HERDR_PANE_ID HERDR_TAB_ID HERDR_SOCKET_PATH
# shellcheck source=/dev/null
. "$CODE_ROOT/bin/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=/dev/null
. "$CODE_ROOT/bin/fm-wake-lib.sh"

# The baseline succeeds here and puts the worker in the secondmate workspace.
# The fix refuses before creating any worker or journal under contention.
make_task contended
LOCK=$(fm_backend_herdr_presentation_session_lock_path "$HERDR_LAB_SESSION")
fm_lock_try_acquire "$LOCK" || fail 'could not hold the lab placement lock'
before=$(lab workspace list | jq -c '.result.workspaces')
if spawn_task contended; then
  fm_lock_release "$LOCK"
  assert_worker contended
  fail 'a contended placement unexpectedly succeeded'
fi
fm_lock_release "$LOCK"
grep -F 'worker placement lock unavailable' "$TMP_ROOT/contended.err" >/dev/null \
  || fail "contention refused for an unrelated reason: $(cat "$TMP_ROOT/contended.err")"
[ ! -e "$FM_HOME/state/contended.meta" ] || fail 'contention published a task endpoint'
[ ! -e "$FM_HOME/state/contended.herdr-presentation" ] || fail 'contention published a projection journal'
[ "$(lab workspace list | jq -c '.result.workspaces')" = "$before" ] || fail 'contention mutated the workspace layout'
pass 'real Herdr: lock contention refuses without creating a worker under the secondmate identity'

spawn_task contended || fail "uncontended retry failed: $(cat "$TMP_ROOT/contended.err")"
assert_worker contended
pass 'real Herdr: releasing the same lock lets the retry create its own correctly labelled workspace'

make_task fm-prefixed
spawn_task fm-prefixed || fail "prefixed projected spawn failed: $(cat "$TMP_ROOT/fm-prefixed.err")"
assert_worker fm-prefixed
prefixed_endpoint=$(field fm-prefixed window)
spawn_task fm-prefixed --relaunch || fail "prefixed projected relaunch failed: $(cat "$TMP_ROOT/fm-prefixed.err")"
assert_worker fm-prefixed
[ "$(field fm-prefixed window)" = "$prefixed_endpoint" ] || fail 'prefixed projected relaunch relocated the worker'
pass 'real Herdr: a task ID already prefixed fm- preserves its concise projected title and endpoint on relaunch'

make_task ungrouped
spawn_task ungrouped || fail "dedicated worker spawn failed: $(cat "$TMP_ROOT/ungrouped.err")"
assert_worker ungrouped
case "$(label_of "$(field ungrouped herdr_workspace_id)")" in
  fm-ungrouped|"└ ungrouped · p:"*) : ;;
  *) fail 'ungrouped worker has a parent title' ;;
esac
pass 'real Herdr: every worker gets its own task-labelled workspace'

# Drive one launch from the real parent pane, using Herdr's own injected
# identity rather than only the API-derived identity of this driver.
make_task in-pane
DRIVER="$TMP_ROOT/in-pane.sh"
{
  printf '#!/usr/bin/env bash\nset -u\n'
  for name in PATH CODE_ROOT FM_HOME PROJ FIXTURE_WT HERDR_LAB_SESSION HERDR_LAB_HELPER REAL_PATH; do
    printf 'export %s=%q\n' "$name" "${!name}"
  done
  # shellcheck disable=SC2016 # Expand the fixture variables in the pane driver.
  printf 'FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$CODE_ROOT" "$CODE_ROOT/bin/fm-spawn.sh" in-pane "$PROJ" %q --backend herdr --mode no-mistakes --yolo off > %q 2> %q\n' "sh -c 'echo fixture'" "$TMP_ROOT/in-pane.out" "$TMP_ROOT/in-pane.err"
  printf 'printf "%%s\\n" "$?" > %q\n' "$TMP_ROOT/in-pane.rc"
} > "$DRIVER"
lab pane run "$HERDR_PANE_ID" "bash '$DRIVER'" >/dev/null
# Retain the former in-pane fixture's launch budget (120 polls, 2 seconds).
for ((attempt=0; attempt<120; attempt++)); do
  [ ! -f "$TMP_ROOT/in-pane.rc" ] || break
  sleep 2
done
[ -f "$TMP_ROOT/in-pane.rc" ] || fail 'the actual in-pane spawn never returned'
[ "$(cat "$TMP_ROOT/in-pane.rc")" = 0 ] || fail "actual in-pane spawn failed: $(cat "$TMP_ROOT/in-pane.err")"
assert_worker in-pane
pass 'real Herdr: an actual secondmate-pane caller creates a dedicated worker using its injected launcher identity'

# A surviving, correct shell endpoint keeps its exact address on relaunch.
original=$(field ungrouped window)
spawn_task ungrouped --relaunch \
  || fail "surviving-worker relaunch failed: $(cat "$TMP_ROOT/ungrouped.err")"
assert_worker ungrouped
[ "$(field ungrouped window)" = "$original" ] || fail 'relaunch relocated an existing correct worker endpoint'
pass 'real Herdr: relaunch preserves a surviving dedicated worker endpoint'

# Prove gone, then reclaim in the recorded session into a new dedicated space.
lab pane close "$(field ungrouped herdr_pane_id)" >/dev/null
spawn_task ungrouped --relaunch \
  || fail "gone-worker reclaim failed: $(cat "$TMP_ROOT/ungrouped.err")"
assert_worker ungrouped
[ "$(field ungrouped window)" != "$original" ] || fail 'reclaim did not bind its replacement endpoint'
pass 'real Herdr: proved-gone reclaim creates a dedicated replacement, never a parent tab'

# Refuse old shared topology read-only rather than silently moving it.
make_task legacy
legacy=$(lab tab create --workspace "$PARENT_WS" --cwd "$FIXTURE_WT" --label fm-legacy --no-focus)
legacy_tab=$(printf '%s' "$legacy" | jq -r '.result.tab.tab_id')
legacy_pane=$(printf '%s' "$legacy" | jq -r '.result.root_pane.pane_id')
cat > "$FM_HOME/state/legacy.meta" <<EOF
window=$HERDR_LAB_SESSION:$legacy_pane
endpoint_task_id=legacy
worktree=$FIXTURE_WT
project=$PROJ
harness=sh
kind=ship
mode=no-mistakes
yolo=off
branch=fm/legacy
backend=herdr
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$PARENT_WS
herdr_tab_id=$legacy_tab
herdr_pane_id=$legacy_pane
EOF
cp "$FM_HOME/state/legacy.meta" "$TMP_ROOT/legacy-before.meta"
if spawn_task legacy --relaunch; then
  fail 'legacy shared endpoint relaunched under the secondmate identity'
fi
grep -F 'surviving herdr endpoint is not its own correctly labelled workspace' "$TMP_ROOT/legacy.err" >/dev/null \
  || fail "legacy endpoint refused for an unrelated reason: $(cat "$TMP_ROOT/legacy.err")"
cmp -s "$TMP_ROOT/legacy-before.meta" "$FM_HOME/state/legacy.meta" || fail 'legacy refusal changed endpoint metadata'
lab pane get "$legacy_pane" >/dev/null || fail 'legacy refusal closed its surviving pane'
[ "$(label_of "$PARENT_WS")" = 2ndmate-frontdesk ] || fail 'worker placement changed the parent label'
pass 'real Herdr: a legacy shared endpoint refuses relaunch without moving or closing it'

# Cold external primary has no launcher and no existing home workspace.
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
rm "$FM_HOME/.fm-secondmate-home"
make_task external
spawn_task external || fail "external-primary spawn failed: $(cat "$TMP_ROOT/external.err")"
assert_worker external
pass 'real Herdr: a primary outside Herdr also creates a dedicated worker workspace'

# A secondmate still gets its home-labelled workspace, not a worker title.
SM_HOME="$TMP_ROOT/secondmate-home"
git clone -q "$PROJ" "$SM_HOME"
printf 'nested\n' > "$SM_HOME/.fm-secondmate-home"
mkdir -p "$SM_HOME/data" "$SM_HOME/state" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin" "$FM_HOME/data/nested"
printf 'on\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf 'Isolated charter.\n' > "$SM_HOME/data/charter.md"
printf 'Isolated secondmate instructions.\n' > "$SM_HOME/AGENTS.md"
printf 'Isolated launch brief.\n' > "$FM_HOME/data/nested/brief.md"
FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$CODE_ROOT" \
  "$CODE_ROOT/bin/fm-spawn.sh" nested "$SM_HOME" "sh -c 'echo fixture'" --secondmate --backend herdr \
  > "$TMP_ROOT/nested.out" 2> "$TMP_ROOT/nested.err" \
  || fail "secondmate spawn failed: $(cat "$TMP_ROOT/nested.err")"
[ "$(label_of "$(field nested herdr_workspace_id)")" = 2ndmate-nested ] || fail 'secondmate lost its home identity'
pass 'real Herdr: secondmate launch retains its own home-labelled workspace'

# Exercise the exact-pane cleanup primitive used by ungrouped task teardown.
# It must remove only the dedicated worker, leaving the old parent and legacy
# pane intact and preserving the active workspace/tab pair.
focus_before=$(lab workspace list | jq -c '[.result.workspaces[] | select(.focused) | [.workspace_id,.active_tab_id]]')
cleanup_target="$HERDR_LAB_SESSION:$(field ungrouped herdr_pane_id)"
fm_backend_herdr_kill "$cleanup_target"
fm_backend_herdr_endpoint_confirmed_gone "$cleanup_target" || fail 'worker cleanup did not confirm its exact pane gone'
lab pane get "$legacy_pane" >/dev/null || fail 'worker cleanup closed the legacy parent pane'
[ "$(label_of "$PARENT_WS")" = 2ndmate-frontdesk ] || fail 'worker cleanup changed the parent workspace'
[ "$(lab workspace list | jq -c '[.result.workspaces[] | select(.focused) | [.workspace_id,.active_tab_id]]')" = "$focus_before" ] || fail 'worker cleanup changed the active workspace/tab'
pass 'real Herdr: exact worker cleanup preserves the parent, sibling pane, and active focus'
printf 'evidence: Herdr %s, isolated session %s\n' "$(lab status --json | jq -r '.server.version')" "$HERDR_LAB_SESSION"
