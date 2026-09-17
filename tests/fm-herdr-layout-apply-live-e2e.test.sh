#!/usr/bin/env bash
# Zero-token live guard for protocol-20 structural plain-Pi launch in Herdr.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_HERDR_LAYOUT_APPLY_LIVE_E2E herdr jq python3

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable: $HERDR_LAB_HELPER"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name herdr-blesh-launch)
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not provision the isolated Herdr structural-launch lab"

lab() {
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

STATUS=$(lab status --json) || fail "could not read the isolated lab protocol"
PROTOCOL=$(printf '%s' "$STATUS" | jq -r '[.client.protocol,.server.protocol] | map(tostring) | join("/")')
HERDR_VERSION=$(printf '%s' "$STATUS" | jq -r '.client.version // "unknown"')
if [ "$PROTOCOL" != 20/20 ]; then
  echo "skip: Herdr structural launch requires protocol 20 (lab reports $PROTOCOL)"
  exit 0
fi
SCHEMA=$(lab api schema --json) || fail "could not read the isolated lab schema"
printf '%s' "$SCHEMA" | jq -e '
  any(.schemas.request.oneOf[]?; .properties.method.const == "layout.apply")
  and .schemas.request["$defs"].LayoutApplyParams.required == ["root"]
  and (.schemas.request["$defs"].LayoutNode.oneOf[]?
    | select(.properties.type.const == "pane")
    | .properties.command.type == ["array", "null"]
    and .properties.cwd.type == ["string", "null"]
    and .properties.env.type == "object")
' >/dev/null || fail "protocol 20 does not expose the pinned layout.apply pane schema"

SCRATCH=$(fm_test_tmproot fm-herdr-layout-live)
CWD="$SCRATCH/cwd"
BIN="$SCRATCH/bin"
RECORD="$SCRATCH/fake-pi.json"
STALE_MARKER="$SCRATCH/stale-shell-text-ran"
mkdir -p "$CWD" "$BIN"
cat > "$BIN/fake-pi.py" <<'PY'
import json
import os
import sys
import time
with open(os.environ["FM_FAKE_PI_RECORD"], "w", encoding="utf-8") as stream:
    json.dump({
        "argv": sys.argv[1:],
        "cwd": os.getcwd(),
        "probe_env": os.environ.get("FM_LAYOUT_PROBE"),
        "herdr_session": os.environ.get("HERDR_SESSION"),
        "herdr_pane": os.environ.get("HERDR_PANE_ID"),
    }, stream, separators=(",", ":"))
time.sleep(60)
PY
cat > "$BIN/pi" <<EOF
#!/usr/bin/env bash
exec -a pi python3 '$BIN/fake-pi.py' "\$@"
EOF
chmod +x "$BIN/pi"

CREATE=$(lab workspace create --cwd "$CWD" --label fm-layout-live) \
  || fail "could not create the isolated structural-launch workspace"
WORKSPACE=$(printf '%s' "$CREATE" | jq -r '.result.workspace.workspace_id // empty')
OLD_TAB=$(printf '%s' "$CREATE" | jq -r '.result.tab.tab_id // empty')
OLD_PANE=$(printf '%s' "$CREATE" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$WORKSPACE" ] && [ -n "$OLD_TAB" ] && [ -n "$OLD_PANE" ] \
  || fail "workspace creation returned incomplete exact identities"

# This text must die with the replaced shell. It is deliberately never
# submitted, cleared, or interpreted by the fake Pi command.
lab pane send-text "$OLD_PANE" "touch '$STALE_MARKER'" >/dev/null \
  || fail "could not seed stale shell text in the isolated pane"
SOCKET=$(lab session list --json | jq -er --arg session "$HERDR_LAB_SESSION" '
  [.sessions[] | select(.name == $session and .running == true) | .socket_path]
  | if length == 1 then .[0] else empty end') \
  || fail "could not bind the isolated named session to one socket"
ENV_JSON=$(python3 - "$RECORD" <<'PY'
import json
import sys
print(json.dumps({
    "FM_FAKE_PI_RECORD": sys.argv[1],
    "FM_LAYOUT_PROBE": "exact-value",
}, separators=(",", ":")))
PY
)
COMMAND_JSON=$(python3 - "$BIN/pi" <<'PY'
import json
import sys
print(json.dumps([sys.argv[1], "alpha", "two words"], separators=(",", ":")))
PY
)
RESULT=$(python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
  "$SOCKET" "$WORKSPACE" "$OLD_TAB" "$OLD_PANE" "$CWD" "$ENV_JSON" "$COMMAND_JSON") \
  || fail "the structural layout request failed in the isolated lab"
NEW_TAB=$(printf '%s' "$RESULT" | jq -r '.layout.tab_id // empty')
NEW_PANE=$(printf '%s' "$RESULT" | jq -r '.layout.root | select(.type == "pane") | .pane_id // empty')
[ -n "$NEW_TAB" ] && [ -n "$NEW_PANE" ] || fail "layout.apply returned no replacement identities"

TAB=$(lab tab get "$NEW_TAB") || fail "the returned tab did not re-read from the isolated session"
PANE=$(lab pane get "$NEW_PANE") || fail "the returned pane did not re-read from the isolated session"
printf '%s' "$TAB" | jq -e --arg workspace "$WORKSPACE" --arg tab "$NEW_TAB" \
  '.result.tab.workspace_id == $workspace and .result.tab.tab_id == $tab' >/dev/null \
  || fail "the returned tab belongs to another container"
printf '%s' "$PANE" | jq -e --arg workspace "$WORKSPACE" --arg tab "$NEW_TAB" --arg pane "$NEW_PANE" \
  '.result.pane.workspace_id == $workspace and .result.pane.tab_id == $tab and .result.pane.pane_id == $pane' >/dev/null \
  || fail "the returned pane belongs to another container"

for _ in $(seq 1 100); do
  [ -s "$RECORD" ] && break
  sleep 0.1
done
[ -s "$RECORD" ] || fail "the fake Pi process did not start"
jq -e --arg cwd "$CWD" --arg session "$HERDR_LAB_SESSION" --arg pane "$NEW_PANE" '
  .argv == ["alpha", "two words"]
  and .cwd == $cwd
  and .probe_env == "exact-value"
  and .herdr_session == $session
  and .herdr_pane == $pane
' "$RECORD" >/dev/null || fail "fake Pi did not receive exact argv, cwd, environment, and returned pane identity"
[ ! -e "$STALE_MARKER" ] || fail "stale shell text executed during structural replacement"

PROCESS=$(lab pane process-info --pane "$NEW_PANE") || fail "could not read the replacement process"
printf '%s' "$PROCESS" | jq -e '
  any(.result.process_info.foreground_processes[]?;
    .name == "pi" or .argv0 == "pi" or ((.argv // [])[0] == "pi"))
' >/dev/null || fail "the replacement pane did not expose the fake Pi process identity"
lab pane report-agent "$NEW_PANE" --source firstmate-layout-live --agent pi --state working >/dev/null \
  || fail "could not register confirmed fake Pi in Herdr inventory"
AGENT=$(lab agent get "$NEW_PANE") || fail "registered fake Pi is absent from Herdr inventory"
printf '%s' "$AGENT" | jq -e --arg pane "$NEW_PANE" '
  .result.agent.pane_id == $pane and .result.agent.agent == "pi"
' >/dev/null || fail "Herdr inventory did not bind Pi to the returned replacement pane"

lab pane close "$NEW_PANE" >/dev/null || fail "could not clean up the replacement pane"
pass "live Herdr protocol-20 layout.apply replaced stale shell input and kept exact fake Pi visible and manageable"
printf '# herdr=%s protocol=%s session=%s\n' "$HERDR_VERSION" "$PROTOCOL" "$HERDR_LAB_SESSION"
