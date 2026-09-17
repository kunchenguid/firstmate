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
FM_LAYOUT_DESTINATION=from-herdr-daemon FM_RESTORE_CREDENTIAL=must-not-survive \
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
    and .properties.env.type == "object"
    and .properties.label.type == ["string", "null"])
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
        "destination_env": os.environ.get("FM_LAYOUT_DESTINATION"),
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
PAYLOAD=$(printf '%s\n%s\n' "$ENV_JSON" "$COMMAND_JSON" | python3 -c '
import json
import sys
env = json.loads(sys.stdin.readline())
command = json.loads(sys.stdin.readline())
print(json.dumps({"cwd": sys.argv[1], "env": env, "command": command}, separators=(",", ":")))
' "$CWD") || fail "could not encode structural launch payload"
RESULT=$(printf '%s\n' "$PAYLOAD" | FM_LAYOUT_DESTINATION=from-invoker \
  python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
    "$SOCKET" "$WORKSPACE" "$OLD_TAB" "$OLD_PANE" \
    22222222222222222222222222222222 fm-launch-22222222222222222222222222222222 --stdin-v1) \
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
  and .destination_env == "from-herdr-daemon"
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

ANCHOR=$(lab workspace create --cwd "$CWD" --label captain-anchor --no-focus) \
  || fail "could not create the focus-preservation anchor"
ANCHOR_TAB=$(printf '%s' "$ANCHOR" | jq -r '.result.tab.tab_id // empty')
[ -n "$ANCHOR_TAB" ] || fail "focus-preservation anchor returned no tab identity"
lab tab focus "$ANCHOR_TAB" >/dev/null || fail "could not focus the restoration anchor"
FOCUS_BEFORE=$(lab workspace list | jq -r '[.result.workspaces[] | select(.focused == true) | .active_tab_id] | @tsv')
ENV_BIN=$(command -v env)
RESTORE_PAYLOAD=$(python3 - "$CWD" "$ENV_BIN" <<'PY'
import json
import sys
print(json.dumps({"cwd": sys.argv[1], "env": {}, "command": [sys.argv[2], "-i", "/bin/sh"]}, separators=(",", ":")))
PY
)
RESTORED=$(printf '%s\n' "$RESTORE_PAYLOAD" | FM_LAYOUT_DESTINATION=must-not-be-forwarded \
  python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
    "$SOCKET" "$WORKSPACE" "$NEW_TAB" "$NEW_PANE" \
    33333333333333333333333333333333 fm-restore-33333333333333333333333333333333 --stdin-v1) \
  || fail "the retained-Pi inert-shell restoration failed in the isolated lab"
RESTORED_TAB=$(printf '%s' "$RESTORED" | jq -r '.layout.tab_id // empty')
RESTORED_PANE=$(printf '%s' "$RESTORED" | jq -r '.layout.root | select(.type == "pane") | .pane_id // empty')
[ -n "$RESTORED_TAB" ] && [ -n "$RESTORED_PANE" ] || fail "inert-shell restoration returned no exact endpoint"
RESTORED_INFO=$(lab pane get "$RESTORED_PANE") || fail "restored shell pane did not re-read from the named session"
printf '%s' "$RESTORED_INFO" | jq -e \
  --arg workspace "$WORKSPACE" --arg tab "$RESTORED_TAB" --arg pane "$RESTORED_PANE" \
  '.result.pane.workspace_id == $workspace and .result.pane.tab_id == $tab and .result.pane.pane_id == $pane' \
  >/dev/null || fail "restored shell endpoint escaped its intended workspace or tab"
RESTORED_PROCESS=$(lab pane process-info --pane "$RESTORED_PANE") || fail "could not inspect the restored shell"
printf '%s' "$RESTORED_PROCESS" | jq -e '
  (.result.process_info.foreground_processes | length) == 1
  and (any(.result.process_info.foreground_processes[]?; .name == "sh" or .argv0 == "/bin/sh"))
' >/dev/null || fail "retained-Pi restoration did not converge to one inert shell"
RESTORED_ENV_PROOF="$SCRATCH/restored-shell-environment-cleared"
lab pane run "$RESTORED_PANE" \
  "if [ -z \"\${FM_LAYOUT_DESTINATION+x}\${FM_RESTORE_CREDENTIAL+x}\" ]; then : > '$RESTORED_ENV_PROOF'; fi" \
  >/dev/null || fail "could not inspect the restored shell environment"
for _ in $(seq 1 100); do
  [ -e "$RESTORED_ENV_PROOF" ] && break
  sleep 0.1
done
[ -e "$RESTORED_ENV_PROOF" ] || fail "restored inert shell retained daemon environment values"
if lab agent get "$RESTORED_PANE" >/dev/null 2>&1; then
  fail "retained-Pi restoration registered an agent in the inert shell"
fi
FOCUS_AFTER=$(lab workspace list | jq -r '[.result.workspaces[] | select(.focused == true) | .active_tab_id] | @tsv')
[ "$FOCUS_AFTER" = "$FOCUS_BEFORE" ] || fail "retained-Pi restoration changed the active workspace or tab"
lab pane close "$RESTORED_PANE" >/dev/null || fail "could not clean up the restored shell pane"
pass "live Herdr structural launch and inert-shell recovery preserve destination environment, identity, and focus"
printf '# herdr=%s protocol=%s session=%s\n' "$HERDR_VERSION" "$PROTOCOL" "$HERDR_LAB_SESSION"
