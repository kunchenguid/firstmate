#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
export FM_HC_BIN="$ROOT/.live-hc/bin/herdr-core" FM_HC_LAB_DIR="$ROOT/.live-hc/labs" FM_HC_LAB_SOCK_DIR=.s
LAB="$ROOT/bin/fm-hc-lab.sh"
SES=fm-hclab-claude
cleanup() {
 rc=$?; trap - EXIT
 "$LAB" teardown "$SES" || rc=1
 rm -rf "$ROOT/.live-hc/claude-home"
 echo "real harness teardown exit=$rc"; exit "$rc"
}
trap cleanup EXIT
"$LAB" provision "$SES"
D="$FM_HC_LAB_DIR/$SES"
export XDG_STATE_HOME="$D/env/xdg-state" XDG_CONFIG_HOME="$D/env/xdg-config" XDG_DATA_HOME="$D/env/xdg-data"
"$ROOT/bin/fm-lab-home.sh" create "$ROOT/.live-hc/claude-home"
export FM_HOME="$ROOT/.live-hc/claude-home" FM_ROOT_OVERRIDE="$ROOT/.live-hc/claude-home"
export HC_SESSION="$SES" FM_HC_SOCKET="$("$LAB" socket "$SES")" DISABLE_AUTOUPDATER=1
mkdir -p "$ROOT/.live-hc/claude-wt"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc
CLAUDE=$(command -v claude)
echo "real harness binary=$CLAUDE version=$($CLAUDE --version)"
ADDR=$("$LAB" run "$SES" run --bg --json --no-parent --outlive-parent --no-notify --cwd "$ROOT/.live-hc/claude-wt" \
 --label "firstmate.home=$(fm_backend_hometag)" --label firstmate.task=fm-claude \
 -- env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
 FM_HOME="$FM_HOME" DISABLE_AUTOUPDATER=1 "$CLAUDE" | jq -r '.address')
T="$SES:$ADDR"
for ((i=0;i<150;i++)); do
 state=$(fm_backend_agent_state hc "$T")
 [ "$state" != alive ] || break
 sleep .2
done
# Let the actual TUI boot, not just its launcher; no prompt or model request is sent.
sleep 8
state=$(fm_backend_agent_state hc "$T")
echo "real Claude liveness=$state"
"$LAB" run "$SES" get --json "$ADDR"
"$LAB" run "$SES" read --lines 50 "$ADDR"
[ "$state" = alive ]
fm_backend_kill hc "$T" '' fm-claude
[ "$(fm_backend_agent_state hc "$T")" = missing ]
echo 'real Claude terminal closed and removed; liveness=missing'
