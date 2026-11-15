#!/usr/bin/env bash
# Credentialed Hermes idle-gateway coexistence guard. Opt in with
# FM_HERMES_GATEWAY_LIVE=1, FM_HERMES_LIVE_HOME=<throwaway-root>
# and FM_HERMES_LIVE_PROFILE=<name> (default worker). Starts a real native gateway for the
# throwaway profile with an isolated HOME, state and host-lock directory, so it
# cannot attach to any other gateway. The profile must configure no messaging
# platform; the guard refuses one. It then runs the TUI worker guard beside the
# idle gateway and checks the session store, memory and gateway afterward.
# The profile's config is restored after it temporarily sets gateway.standalone.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_HERMES_GATEWAY_LIVE hermes tmux jq python3
: "${FM_HERMES_LIVE_HOME:?provide a configured throwaway Hermes root}"
PROFILE=${FM_HERMES_LIVE_PROFILE:-worker}
HERMES_BIN=$(command -v hermes)
PROFILE_HOME="$FM_HERMES_LIVE_HOME/profiles/$PROFILE"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/hm-gateway.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SOCKET="$LAB/gateway.sock"
mkdir -p "$LAB/home" "$LAB/state" "$LAB/locks"
[ -f "$PROFILE_HOME/config.yaml" ] || fail "throwaway profile $PROFILE_HOME is not prepared"
cp -p "$PROFILE_HOME/config.yaml" "$LAB/config.yaml"
cleanup() {
  tmux -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  cp -p "$LAB/config.yaml" "$PROFILE_HOME/config.yaml"
  rm -rf "$LAB"
}
trap cleanup EXIT
for file in "$FM_HERMES_LIVE_HOME/.env" "$PROFILE_HOME/.env"; do
  [ ! -s "$file" ] || fail "$file may configure a messaging platform; use a profile without one"
done
HERMES_HOME="$FM_HERMES_LIVE_HOME" "$HERMES_BIN" -p "$PROFILE" config get platforms --json > "$LAB/platforms.json" 2>/dev/null || echo null > "$LAB/platforms.json"
jq -e '. == null or . == {} or ([.[]? | objects | select(.enabled == true)] | length == 0)' "$LAB/platforms.json" >/dev/null \
  || fail 'throwaway profile configures a messaging platform'
snapshot() {
  python3 -I - "$PROFILE_HOME" "$1" <<'PY'
import hashlib, json, sqlite3, sys
from pathlib import Path
home, out = Path(sys.argv[1]), Path(sys.argv[2])
conn = sqlite3.connect(f"file:{home / 'state.db'}?mode=ro", uri=True)
ok = conn.execute('pragma integrity_check').fetchone()[0]
sessions = {sid: count for sid, count in conn.execute(
    'select s.id, count(m.id) from sessions s left join messages m on m.session_id = s.id group by s.id')}
conn.close()
memory = home / 'memories' / 'MEMORY.md'
digest = hashlib.sha256(memory.read_bytes()).hexdigest() if memory.exists() else None
out.write_text(json.dumps({'integrity': ok, 'sessions': sessions, 'memory': digest}))
PY
}
# Native Hermes runs a profile-owned gateway only in its standalone mode, the
# shape of an operator profile whose own gateway serves only itself.
HERMES_HOME="$FM_HERMES_LIVE_HOME" "$HERMES_BIN" -p "$PROFILE" config set gateway.standalone true >/dev/null \
  || fail 'could not mark the throwaway profile gateway standalone'
gateway_state() { jq -c '{pid, gateway_state, active_agents, active_work, updated_at, session_store}' "$PROFILE_HOME/gateway_state.json"; }
# The gateway's environment, HOME and state are private, so no inherited
# platform credential, operator Hermes root, or per-user host rendezvous is
# visible to it.
printf 'exec env -i PATH=%q TERM=xterm-256color HOME=%q XDG_STATE_HOME=%q HERMES_GATEWAY_LOCK_DIR=%q HERMES_HOME=%q %q -p %q gateway run\n' \
  "$PATH" "$LAB/home" "$LAB/state" "$LAB/locks" "$FM_HERMES_LIVE_HOME" "$HERMES_BIN" "$PROFILE" > "$LAB/gateway.sh"
snapshot "$LAB/before.json" || fail 'could not snapshot the throwaway session store'
tmux -S "$SOCKET" new-session -d -s gateway -x 160 -y 50 "bash '$LAB/gateway.sh'; sleep 600" || fail 'gateway launch failed'
for _ in $(seq 1 240); do
  # A previous run leaves its state file behind; wait for a live writer.
  [ -f "$PROFILE_HOME/gateway_state.json" ] && [ "$(jq -r '.gateway_state + ":" + (.active_agents|tostring)' "$PROFILE_HOME/gateway_state.json" 2>/dev/null)" = running:0 ] \
    && kill -0 "$(jq -r .pid "$PROFILE_HOME/gateway_state.json" 2>/dev/null)" 2>/dev/null && break
  sleep 0.5
done
GATEWAY_PID=$(jq -r .pid "$PROFILE_HOME/gateway_state.json" 2>/dev/null)
if [ "$(jq -r .gateway_state "$PROFILE_HOME/gateway_state.json" 2>/dev/null)" != running ] || ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
  fail "native gateway did not reach running: $(tmux -S "$SOCKET" capture-pane -p -t gateway | tail -20)"
fi
printf 'idle gateway before: %s\n' "$(gateway_state)"
# shellcheck source=bin/fm-hermes-lib.sh
. "$ROOT/bin/fm-hermes-lib.sh"
HERMES_GATEWAY_LOCK_DIR="$LAB/locks" fm_hermes_gateway_check "$PROFILE_HOME" "$PROFILE" || fail 'idle own gateway refused'
pass 'real idle profile gateway accepted by the read-only preflight'
FM_HERMES_SIGNALS_LIVE=1 HERMES_GATEWAY_LOCK_DIR="$LAB/locks" \
  bash "$ROOT/tests/fm-hermes-signals-live-e2e.test.sh" || fail 'TUI worker guard failed beside the idle gateway'
before_stamp=$(jq -r .updated_at "$PROFILE_HOME/gateway_state.json")
for _ in $(seq 1 150); do
  [ "$(jq -r .updated_at "$PROFILE_HOME/gateway_state.json")" != "$before_stamp" ] && break
  sleep 1
done
printf 'idle gateway after: %s\n' "$(gateway_state)"
kill -0 "$GATEWAY_PID" 2>/dev/null || fail 'gateway exited during the worker task'
[ "$(jq -r .pid "$PROFILE_HOME/gateway_state.json")" = "$GATEWAY_PID" ] || fail 'gateway was replaced during the worker task'
jq -e '.gateway_state == "running" and .active_agents == 0 and .session_store.status == "ok"' "$PROFILE_HOME/gateway_state.json" >/dev/null \
  || fail 'gateway is no longer idle-serving with a healthy session store'
[ "$(jq -r .updated_at "$PROFILE_HOME/gateway_state.json")" != "$before_stamp" ] || fail 'gateway heartbeat stopped after the worker task'
HOME="$LAB/home" XDG_STATE_HOME="$LAB/state" HERMES_GATEWAY_LOCK_DIR="$LAB/locks" HERMES_HOME="$FM_HERMES_LIVE_HOME" \
  "$HERMES_BIN" -p "$PROFILE" gateway status > "$LAB/status.txt" 2>&1 || true
printf 'native gateway status: %s\n' "$(grep -iE 'running|stopped' "$LAB/status.txt" | head -1)"
grep -qi 'running' "$LAB/status.txt" || fail "native gateway status did not report running: $(cat "$LAB/status.txt")"
snapshot "$LAB/after.json" || fail 'could not snapshot the session store afterward'
jq -e --slurpfile b "$LAB/before.json" '. as $a | .integrity == "ok" and .memory == $b[0].memory and ([$b[0].sessions | to_entries[] | select(.value != $a.sessions[.key])] | length == 0) and (.sessions | length > ($b[0].sessions | length))' \
  "$LAB/after.json" >/dev/null || fail "session store or memory changed unexpectedly: before $(cat "$LAB/before.json") after $(cat "$LAB/after.json")"
printf 'session store: integrity ok, %s prior sessions and their messages retained, %s new worker sessions; memory unchanged\n' \
  "$(jq '.sessions | length' "$LAB/before.json")" "$(jq --slurpfile b "$LAB/before.json" '(.sessions | length) - ($b[0].sessions | length)' "$LAB/after.json")"
pass "$("$HERMES_BIN" --version 2>/dev/null | head -1): TUI worker completed beside a real idle gateway; gateway, session store and memory intact"
