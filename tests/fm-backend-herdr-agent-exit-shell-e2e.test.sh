#!/usr/bin/env bash
# Real-Herdr regression: `herdr agent get` (not `pane get` `.agent_status`)
# distinguishes a Pi that exited to a leftover shell from a live idle Pi, so
# the recovery classifier maps the leftover shell to no-agent/dead
# (relaunch-allowed) and keeps the live idle pane alive.
#
# Do not launch Pi with `exec`: the pane shell must survive when the agent
# exits. That is the #4115 shape.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_HERDR_AGENT_EXIT_SHELL_E2E herdr jq pi

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-herdr-agent-exit-shell-e2e)
FAKEBIN="$TMP_ROOT/fakebin"
PROJECT="$TMP_ROOT/project"
PI_DIR="$TMP_ROOT/pi-agent"
mkdir -p "$FAKEBIN" "$PROJECT" "$PI_DIR"
printf '# Isolated herdr agent-exit lab\n' > "$PROJECT/AGENTS.md"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-agent-exit-shell)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH

cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

classify_pane() {  # <pane_id>
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '
    set -u
    . "$1/bin/backends/herdr.sh"
    fm_backend_herdr_pane_agent_state "$2" "$3"
  ' _ "$ROOT" "$HERDR_LAB_SESSION" "$1"
}

classify_recovery() {  # <pane_id>
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '
    set -u
    . "$1/bin/backends/herdr.sh"
    fm_backend_herdr_agent_state "$2:$3"
  ' _ "$ROOT" "$HERDR_LAB_SESSION" "$1"
}

agent_get_code() {  # <pane_id>
  local out
  out=$(lab agent get "$1" 2>&1) || true
  printf '%s' "$out" | jq -r '.error.code // empty'
}

agent_get_status() {  # <pane_id>
  local out
  out=$(lab agent get "$1" 2>&1) || true
  printf '%s' "$out" | jq -r '.result.agent.agent_status // empty'
}

agent_get_kind() {  # <pane_id>
  local out
  out=$(lab agent get "$1" 2>&1) || true
  printf '%s' "$out" | jq -r '.result.agent.agent // empty'
}

pane_present() {  # <pane_id>
  lab pane get "$1" >/dev/null 2>&1
}

pane_agent_status_field() {  # <pane_id>
  lab pane get "$1" 2>/dev/null | jq -r '.result.pane.agent_status // empty'
}

wait_until() {  # <pane_id> <idle|gone> [attempts]
  local pane=$1 want=$2 attempts=${3:-90} code status
  for _ in $(seq 1 "$attempts"); do
    code=$(agent_get_code "$pane")
    status=$(agent_get_status "$pane")
    case "$want" in
      idle)
        case "$status" in idle|done|blocked) return 0 ;; esac
        ;;
      gone)
        [ "$code" = agent_not_found ] && return 0
        ;;
    esac
    sleep 0.5
  done
  return 1
}

assert_live_idle() {  # <pane_id> <label>
  local pane=$1 label=$2 kind status pane_state recov pane_field
  pane_present "$pane" || fail "$label: pane disappeared while the agent should still be live"
  kind=$(agent_get_kind "$pane")
  status=$(agent_get_status "$pane")
  [ "$kind" = pi ] || fail "$label: agent get kind was '$kind', want pi"
  [ "$status" = idle ] || fail "$label: agent get status was '$status', want idle (authority is agent get, not pane get)"
  pane_state=$(classify_pane "$pane")
  recov=$(classify_recovery "$pane")
  [ "$pane_state" = live ] || fail "$label: pane classifier was '$pane_state', want live"
  [ "$recov" = alive ] || fail "$label: recovery classifier was '$recov', want alive (must not reclaim a live idle agent)"
  pane_field=$(pane_agent_status_field "$pane")
  : "$pane_field"
}

assert_exited_to_shell() {  # <pane_id> <label>
  local pane=$1 label=$2 code pane_state recov pane_field
  pane_present "$pane" || fail "$label: pane was reaped; launch used exec or the shell did not survive"
  code=$(agent_get_code "$pane")
  [ "$code" = agent_not_found ] || fail "$label: agent get code was '$code', want agent_not_found"
  pane_state=$(classify_pane "$pane")
  recov=$(classify_recovery "$pane")
  [ "$pane_state" = no-agent ] || fail "$label: pane classifier was '$pane_state', want no-agent"
  [ "$recov" = dead ] || fail "$label: recovery classifier was '$recov', want dead (relaunch-allowed), not alive"
  # pane get .agent_status may still read idle after the occupant is gone.
  # Liveness comes from agent get; a lagged idle field must not keep the pane alive.
  pane_field=$(pane_agent_status_field "$pane")
  case "$pane_field" in
    idle|done|blocked|working)
      [ "$recov" = dead ] || fail "$label: pane get agent_status=$pane_field lagged but recovery was '$recov'"
      ;;
  esac
}

TRUST="$TMP_ROOT/trust.ts"
cat > "$TRUST" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
}
EOF

# Child of the pane shell, never exec, so /quit and SIGKILL return to zsh.
PI_CMD=$(printf 'env PI_CODING_AGENT_DIR=%q pi -e %q --no-context-files --no-session' "$PI_DIR" "$TRUST")

CREATE=$(lab workspace create --cwd "$PROJECT" --label 'agent-exit-shell' --no-focus) \
  || fail 'could not create the lab workspace'
P_LIVE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail 'could not read the live pane id'
WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id') \
  || fail 'could not read the workspace id'

QUIT_TAB=$(lab tab create --workspace "$WS" --cwd "$PROJECT" --label quit-to-shell --no-focus) \
  || fail 'could not create the /quit tab'
P_QUIT=$(printf '%s' "$QUIT_TAB" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id') \
  || fail 'could not read the /quit pane id'
KILL_TAB=$(lab tab create --workspace "$WS" --cwd "$PROJECT" --label kill-to-shell --no-focus) \
  || fail 'could not create the SIGKILL tab'
P_KILL=$(printf '%s' "$KILL_TAB" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id') \
  || fail 'could not read the SIGKILL pane id'

lab pane run "$P_LIVE" "$PI_CMD" >/dev/null || fail 'could not launch live-idle Pi'
lab pane run "$P_QUIT" "$PI_CMD" >/dev/null || fail 'could not launch /quit Pi'
lab pane run "$P_KILL" "$PI_CMD" >/dev/null || fail 'could not launch SIGKILL Pi'

wait_until "$P_LIVE" idle || fail 'live-idle Pi never became idle on agent get'
wait_until "$P_QUIT" idle || fail '/quit Pi never became idle on agent get'
wait_until "$P_KILL" idle || fail 'SIGKILL Pi never became idle on agent get'

assert_live_idle "$P_LIVE" 'before-exit live-idle'

lab pane run "$P_QUIT" '/quit' >/dev/null || fail 'could not send /quit'

KILL_PID=$(lab pane process-info --pane "$P_KILL" | jq -r '
  .result.process_info.foreground_processes[]?
  | select((.name // "") == "pi" or ((.argv0 // "") == "pi"))
  | .pid
' | head -1)
[ -n "$KILL_PID" ] && [ "$KILL_PID" != null ] \
  || fail 'SIGKILL pane had no pi pid in process-info'
kill -KILL "$KILL_PID" || fail "kill -KILL $KILL_PID failed"

wait_until "$P_QUIT" gone || fail '/quit pane never dropped off agent get'
wait_until "$P_KILL" gone || fail 'SIGKILL pane never dropped off agent get'

assert_exited_to_shell "$P_QUIT" '/quit leftover shell'
assert_exited_to_shell "$P_KILL" 'SIGKILL leftover shell'
assert_live_idle "$P_LIVE" 'sibling live-idle after exits'

pass 'agent get distinguishes leftover-shell (dead/no-agent) from live idle Pi'
pass 'pane get agent_status lag cannot keep an exited occupant classified alive'
