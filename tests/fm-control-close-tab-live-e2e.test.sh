#!/usr/bin/env bash
# Token-free native Herdr/Pi proof of idle closure and live refusal paths.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
fm_live_gate default-on FM_HERDR_CLOSE_TAB_LIVE_E2E herdr jq pi
TMP_ROOT=$(fm_test_tmproot fm-close-tab-live)
mkdir -p "$TMP_ROOT/project" "$TMP_ROOT/pi-agent"
SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name close-tab)
cleanup() {
  local rc=$?
  "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION" || fail 'lab provision failed'
lab() { "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "$@"; }
CREATE=$(lab workspace create --cwd "$TMP_ROOT/project" --label close-tab --no-focus) \
  || fail 'workspace create failed'
PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id')
WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id')
TAB=$(lab pane get "$PANE" | jq -er '.result.pane.tab_id')
"$ROOT/bin/fm-lab-home.sh" create "$TMP_ROOT/home" >/dev/null || fail 'lab home failed'
write_meta() { # <task> <pane> <workspace> <tab> <harness>
  cat > "$TMP_ROOT/home/state/$1.meta" <<EOF
window=$SESSION:$2
endpoint_task_id=$1
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$3
herdr_tab_id=$4
herdr_pane_id=$2
harness=$5
kind=scout
worktree=$TMP_ROOT/project
project=$TMP_ROOT/project
EOF
}
control() { # <task>
  env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$TMP_ROOT/home" bash "$ROOT/bin/fm-control.sh" "$1" exit --close-tab
}
new_pane() { # <label>; sets CASE_PANE, CASE_WS, CASE_TAB
  local create
  create=$(lab workspace create --cwd "$TMP_ROOT/project" --label "$1" --no-focus) \
    || fail "$1 workspace create failed"
  CASE_PANE=$(printf '%s' "$create" | jq -er '.result.root_pane.pane_id')
  CASE_WS=$(printf '%s' "$create" | jq -er '.result.workspace.workspace_id')
  CASE_TAB=$(lab pane get "$CASE_PANE" | jq -er '.result.pane.tab_id')
}
pane_process_state() {
  ( . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_pane_process_state "$SESSION" "$CASE_PANE" )
}
wait_process_state() { # <wanted>
  local i
  for ((i=0; i<40; i++)); do
    [ "$(pane_process_state)" = "$1" ] && return 0
    sleep 0.1
  done
  return 1
}
refuse_close() { # <task>
  local out rc
  out=$(control "$1" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$1 unexpectedly closed"
  [ "$rc" -ne 3 ] || fail "$1 stopped at fm-gate-refuse: $out"
  assert_contains "$out" 'idle tab close refused or unconfirmed' "$1 reached close guard"
  assert_not_contains "$out" 'error: no-mistakes gate agent' "$1 was not blocked at home boundary"
  lab pane get "$CASE_PANE" | jq -e '.result.pane.pane_id' >/dev/null \
    || fail "$1 pane disappeared after refusal"
  pass "$1: native close guard refused; pane retained"
}

# A stale idle registration cannot authorize a different foreground command.
new_pane busy-command
lab pane run "$CASE_PANE" 'sleep 120' >/dev/null || fail 'busy command launch failed'
wait_process_state other || fail 'busy foreground command did not become active'
write_meta busy-command "$CASE_PANE" "$CASE_WS" "$CASE_TAB" pi
refuse_close busy-command
lab pane report-agent "$CASE_PANE" --source pi --agent pi --state idle >/dev/null \
  || fail 'could not seed stale Pi registration'
[ "$(lab agent get "$CASE_PANE" | jq -r '.result.agent.agent_status // empty')" = idle ] \
  || fail 'stale registration did not report idle'
write_meta stale-busy "$CASE_PANE" "$CASE_WS" "$CASE_TAB" pi
refuse_close stale-busy

# A live replacement harness that differs from the task record keeps its pane.
new_pane mismatched-harness
ln -s "$(command -v sleep)" "$TMP_ROOT/agy"
lab pane run "$CASE_PANE" "$TMP_ROOT/agy 120" >/dev/null \
  || fail 'replacement harness launch failed'
wait_process_state agent || fail 'replacement harness did not become active'
( . "$ROOT/bin/backends/herdr.sh"
  fm_backend_herdr_idle_task_process_matches "$SESSION" "$CASE_PANE" agy \
    && ! fm_backend_herdr_idle_task_process_matches "$SESSION" "$CASE_PANE" pi ) \
  || fail 'replacement process identity was not agy rather than pi'
lab pane report-agent "$CASE_PANE" --source agy --agent agy --state idle >/dev/null \
  || fail 'could not report replacement harness idle'
[ "$(lab agent get "$CASE_PANE" | jq -r '.result.agent.agent // empty')" = agy ] \
  || fail 'replacement harness registration missing'
write_meta mismatched-harness "$CASE_PANE" "$CASE_WS" "$CASE_TAB" pi
refuse_close mismatched-harness

# A foreground shell with an active background child is not an idle shell.
new_pane shell-background
lab pane run "$CASE_PANE" 'sleep 120 &' >/dev/null \
  || fail 'background command launch failed'
wait_process_state shell || fail 'background case did not return to shell'
( . "$ROOT/bin/backends/herdr.sh"
  ! fm_backend_herdr_pane_idle_shell_pid "$SESSION" "$CASE_PANE" >/dev/null ) \
  || fail 'background case had no active non-shell descendant'
write_meta shell-background "$CASE_PANE" "$CASE_WS" "$CASE_TAB" pi
refuse_close shell-background

cat > "$TMP_ROOT/trust.ts" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
}
EOF
CMD=$(printf 'env PI_CODING_AGENT_DIR=%q pi -e %q --no-context-files --no-session' \
  "$TMP_ROOT/pi-agent" "$TMP_ROOT/trust.ts")
lab pane run "$PANE" "$CMD" >/dev/null || fail 'Pi launch failed'
READY=0
for _ in {1..80}; do
  STATUS=$(lab agent get "$PANE" 2>&1 | jq -r '.result.agent.agent_status // empty')
  if [ "$STATUS" = idle ]; then READY=1; break; fi
  sleep 0.25
done
[ "$READY" = 1 ] || fail 'native Pi never reached idle'
lab pane send-text "$PANE" 'unsent-guard-regression-draft' >/dev/null \
  || fail 'could not type draft without submission'
sleep 0.3
write_meta worker "$PANE" "$WS" "$TAB" pi
OUT=$(control worker) || fail "close failed: $OUT"
assert_contains "$OUT" 'tab-closed' 'real exit command confirms closure'
SNAPSHOT=$(find "$TMP_ROOT/home/state" -name 'worker.closed-tab.*' -type f)
assert_contains "$(cat "$SNAPSHOT")" 'unsent-guard-regression-draft' 'unsent draft checkpoint'
[ -f "$TMP_ROOT/home/state/worker.meta" ] || fail 'task record removed'
[ -d "$TMP_ROOT/project" ] || fail 'worktree removed'
pass 'real idle Pi with draft closes without submission, records and worktree retained'
