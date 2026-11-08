#!/usr/bin/env bash
set -euo pipefail
export LIVE_ROOT="$PWD" LIVE_ACCOUNT_HOME="$HOME"
export FM_HERDR_LAB_STATE_DIR="$PWD/.test-live/lab-state"
export LIVE_CALLS="$PWD/.test-live/calls.log"
export LIVE_SESSION
LIVE_SESSION=$(bin/fm-herdr-lab.sh name ownership)
LAB_HELPER="$PWD/bin/fm-herdr-lab.sh"
cleanup() {
  local rc=$?
  trap - EXIT
  "$LAB_HELPER" teardown "$LIVE_SESSION" || rc=1
  exit "$rc"
}
# provision performs prepare internally for a new session.
trap cleanup EXIT
"$LAB_HELPER" provision "$LIVE_SESSION"
echo "LAB=$LIVE_SESSION"
"$LAB_HELPER" run "$LIVE_SESSION" status --json
created=$("$LAB_HELPER" run "$LIVE_SESSION" workspace create --cwd "$PWD" --label safety-proof --no-focus)
printf 'created=%s\n' "$created"
pane=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id')
"$LAB_HELPER" run "$LIVE_SESSION" pane list
mkdir -p "$PWD/.test-live/account/.firstmate"
marker="$PWD/.test-live/account/.firstmate/remote-herdr-takeover-$LIVE_SESSION"
before=$("$LAB_HELPER" run "$LIVE_SESSION" status --json | jq -r '.server.socket')
for scenario in unattended dead-authorizer reused-pid; do
  echo "SCENARIO=$scenario"
  : > "$LIVE_CALLS"
  case "$scenario" in
    unattended) rm -f "$marker" ;;
    dead-authorizer)
      bash -c 'exit 0' & dead=$!; wait "$dead"
      printf '%s\n%s\n' "$dead" 'finished-process' > "$marker" ;;
    reused-pid) printf '%s\n%s\n' "$$" 'intentionally-wrong-start-identity' > "$marker" ;;
  esac
  HOME="$PWD/.test-live/account" bin/fm-remote-herdr-guard.sh "$PWD/.test-live/herdr-route" "$LIVE_SESSION"
  [ ! -e "$marker" ]
  after=$("$LAB_HELPER" run "$LIVE_SESSION" status --json)
  printf 'after=%s\n' "$after"
  [ "$(printf '%s' "$after" | jq -r '.server.socket')" = "$before" ]
  printf '%s' "$after" | jq -e '.server.running == true' >/dev/null
  panes=$("$LAB_HELPER" run "$LIVE_SESSION" pane list)
  printf 'panes=%s\n' "$panes"
  printf '%s' "$panes" | jq -e --arg pane "$pane" '.result.panes | any(.pane_id == $pane)' >/dev/null
  "${LAB_HELPER}" run "$LIVE_SESSION" pane read "$pane" --source visible
  echo 'Guard CLI calls:'
  cat "$LIVE_CALLS"
  [ "$(wc -l < "$LIVE_CALLS" | tr -d ' ')" = 1 ]
  grep -q '^herdr status --json --session ' "$LIVE_CALLS"
  echo "RESULT=$scenario passed: existing pane still readable; guard issued status only"
done
