#!/usr/bin/env bash
# Opt-in real completed-window cleanup and copy-preservation guard. Every Herdr invocation goes
# through the named-lab helper, including backend probes. No live fleet tasks.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_SHORT_HERDR_E2E herdr node jq treehouse tasks-axi
[ "$(uname -s)" = Linux ] || { echo "skip: operation identity requires Linux /proc"; exit 0; }
HERDR_LAB_HELPER=${FM_SHORT_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name "${FM_SHORT_HERDR_LAB_LABEL:-short-operations}")
export FM_SHORT_TEST_BASE_PATH=$PATH
cleanup_lab() {
  local rc=$?
  PATH="$FM_SHORT_TEST_BASE_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=$?
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_lab EXIT
export HERDR_LAB_HELPER HERDR_LAB_SESSION
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
LAB=${FM_SHORT_HERDR_EVIDENCE:-$(fm_test_tmproot fm-short-operation-herdr)}
mkdir -p "$LAB"
mkdir -p "$LAB/idle" "$LAB/herdrbin"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json > "$LAB/herdr-status.json"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$LAB/idle" --label short-cleanup-lab --no-focus > "$LAB/workspace.json"
WS=$(jq -r '.result.workspace.workspace_id' "$LAB/workspace.json")
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab create --workspace "$WS" --cwd "$LAB/idle" --label fm-cleanup-one --no-focus > "$LAB/tab.json"
PANE=$(jq -r '.result.root_pane.pane_id' "$LAB/tab.json")
TAB=$(jq -r '.result.tab.tab_id' "$LAB/tab.json")
jq -n --arg session "$HERDR_LAB_SESSION" --arg workspace "$WS" --arg pane "$PANE" --arg tab "$TAB" '{session:$session,workspace:$workspace,pane:$pane,tab:$tab}' > "$LAB/cleanup-target.json"
export FM_SHORT_TEST_BASE_PATH=$PATH
cat > "$LAB/herdrbin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "${2:-}" = "$HERDR_LAB_SESSION" ] || exit 70
    shift 2
  else
    args+=("$1");shift
  fi
done
# Even the backend's session-independent client status probe goes to this lab.
PATH="$FM_SHORT_TEST_BASE_PATH" exec "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
SH
chmod +x "$LAB/herdrbin/herdr"
export PATH="$LAB/herdrbin:$PATH" HERDR_SESSION="$HERDR_LAB_SESSION" FM_SHORT_CLEANUP_TARGET="$LAB/cleanup-target.json"
node "$ROOT/tests/fm-short-operations-cases.mjs" "$ROOT" "$LAB" > "$LAB/result.log" 2>&1 || { cat "$LAB/result.log"; exit 1; }
cat "$LAB/result.log"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane list --workspace "$WS" > "$LAB/after.json"
jq -e --arg pane "$PANE" 'all(.result.panes[]; .pane_id != $pane)' "$LAB/after.json"
printf 'cleanup-evidence=%s\n' "$LAB"
pass 'short cleanup closes completed windows, releases landed copies and retains unsafe copies and unrelated resources'
