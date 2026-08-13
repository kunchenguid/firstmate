#!/usr/bin/env bash
# Real-Herdr behavioral coverage for the optional passive validation observer.
# Every Herdr operation uses the guarded named lab helper, never default.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-herdr-no-mistakes-observer)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name nm-observer-layout-n4) || exit 1
STATE="$TMP_ROOT/home/state"
CONFIG="$TMP_ROOT/home/config"
FAKEBIN="$TMP_ROOT/fakebin"
NM_STATUS="$TMP_ROOT/nm-status"
NM_LOG="$TMP_ROOT/nm.log"
mkdir -p "$STATE" "$CONFIG" "$FAKEBIN"

cleanup() {
  local status=0
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  return "$status"
}
trap cleanup EXIT

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi) [ "${2:-}" = status ] && cat "${FM_FAKE_NM_STATUS:?}" ;;
  attach) printf '%s\n' "$*" >> "${FM_FAKE_NM_LOG:?}"; sleep 30 ;;
esac
SH
chmod +x "$FAKEBIN/no-mistakes"

PATH="$FAKEBIN:$PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision isolated Herdr lab'
workspace=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --label observer-test --no-focus | jq -r '.result.workspace.workspace_id')
tab=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list --workspace "$workspace" | jq -r '.result.tabs[0].tab_id')
task_pane=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane list --workspace "$workspace" | jq -r '.result.panes[0].pane_id')
[ -n "$workspace" ] && [ -n "$tab" ] && [ -n "$task_pane" ] || fail 'could not create task pane in isolated lab'

branch=$(git -C "$ROOT" symbolic-ref --quiet --short HEAD) || fail 'test requires a branch worktree'
head=$(git -C "$ROOT" rev-parse HEAD) || fail 'could not read test worktree head'
cat > "$NM_STATUS" <<EOF
run:
  id: "run-live"
  branch: $branch
  status: running
  head: "$head"
EOF

write_meta() { # <id> <backend>
  local id=$1 backend=$2
  cat > "$STATE/$id.meta" <<EOF
window=$HERDR_LAB_SESSION:$task_pane
worktree=$ROOT
project=$ROOT
kind=ship
endpoint_task_id=$id
backend=$backend
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$workspace
herdr_tab_id=$tab
herdr_pane_id=$task_pane
EOF
}

run_observer() { # <action> <id>
  PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_NM_STATUS="$NM_STATUS" FM_FAKE_NM_LOG="$NM_LOG" \
    "$ROOT/bin/fm-herdr-no-mistakes-observer.sh" "$1" "$2"
}

pane_count() {
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane list --workspace "$workspace" | jq '.result.panes | length'
}

write_meta task herdr
before_focus=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list | jq -r '[.result.workspaces[] | select(.focused == true) | .workspace_id, .active_tab_id] | @tsv')
: > "$CONFIG/herdr-no-mistakes-observer-panes"
run_observer reconcile task || fail 'enabled observer reconcile failed'
sidecar="$STATE/task.herdr-no-mistakes-observer"
[ -f "$sidecar" ] || fail 'enabled matching run did not publish its observer sidecar'
observer_pane=$(sed -n 's/^observer_pane=//p' "$sidecar")
[ -n "$observer_pane" ] && [ "$observer_pane" != "$task_pane" ] || fail 'sidecar did not bind a distinct observer pane'
[ "$(pane_count)" = 2 ] || fail 'enabled matching run did not create exactly one adjacent pane'
[ "$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$observer_pane" | jq -r '.result.pane.focused')" = false ] || fail 'observer pane was focused after no-focus split'
after_focus=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list | jq -r '[.result.workspaces[] | select(.focused == true) | .workspace_id, .active_tab_id] | @tsv')
[ "$before_focus" = "$after_focus" ] || fail 'observer split changed focus'
sleep 0.2
pass 'enabled matching Herdr run creates one unfocused passive observer with an exact sidecar'

run_observer reconcile task || fail 'repeat observer reconcile failed'
[ "$(pane_count)" = 2 ] || fail 'repeat ensure created a duplicate observer'
pass 'observer creation is idempotent for the complete live binding'

sed -i.bak 's/^run_id=.*/run_id=old-run/' "$sidecar" && rm -f "$sidecar.bak"
run_observer reconcile task || fail 'stale observer reconcile failed'
[ "$(pane_count)" = 2 ] || fail 'stale sidecar authorized a duplicate observer'
[ -f "$sidecar" ] || fail 'stale sidecar was unexpectedly retired while run remains active'
pass 'stale sidecar refuses duplicate creation and remains quarantined'

run_observer retire task || fail 'stale observer retire failed'
[ "$(pane_count)" = 2 ] || fail 'stale sidecar authorized observer closure'
[ -f "$sidecar" ] || fail 'stale sidecar was retired by cleanup'
[ "$($HERDR_LAB_HELPER run "$HERDR_LAB_SESSION" pane get "$task_pane" | jq -r '.result.pane.pane_id')" = "$task_pane" ] || fail 'stale cleanup touched the task pane'
pass 'stale cleanup never closes the task or observer pane'

sed -i.bak 's/^run_id=.*/run_id=run-live/' "$sidecar" && rm -f "$sidecar.bak"
cat > "$NM_STATUS" <<EOF
run:
  id: "run-live"
  branch: $branch
  status: completed
  head: "$head"
  outcome: checks-passed
EOF
run_observer reconcile task || fail 'terminal observer reconcile failed'
if "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$observer_pane" >/dev/null 2>&1; then fail 'terminal run did not close the exact observer pane'; fi
[ ! -e "$sidecar" ] || fail 'terminal run did not retire a confirmed observer sidecar'
[ "$($HERDR_LAB_HELPER run "$HERDR_LAB_SESSION" pane get "$task_pane" | jq -r '.result.pane.pane_id')" = "$task_pane" ] || fail 'terminal cleanup resized or closed the task pane'
pass 'terminal matching run closes only the exact observer pane and preserves the task pane'

rm -f "$CONFIG/herdr-no-mistakes-observer-panes"
cat > "$NM_STATUS" <<EOF
run:
  id: "run-disabled"
  branch: $branch
  status: running
  head: "$head"
EOF
run_observer reconcile task || fail 'disabled observer reconcile failed'
[ "$(pane_count)" = 1 ] || fail 'disabled preference created an observer pane'
write_meta nonherdr tmux
run_observer reconcile nonherdr || fail 'non-Herdr observer reconcile failed'
[ ! -e "$STATE/nonherdr.herdr-no-mistakes-observer" ] || fail 'non-Herdr metadata created an observer sidecar'
pass 'disabled preference and non-Herdr task are inert'

echo 'all fm-herdr-no-mistakes-observer tests passed'
