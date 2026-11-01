#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6BJAH05EHPA0HFEHDG4N4WY
export FM_HC_BIN="$ROOT/.test-tools/herdr-core" FM_HC_LAB_DIR="$ROOT/.test-tools/labs" FM_HC_LAB_SOCK_DIR="$E/s"
S=fm-hclab-g
APID=
cleanup() {
  rc=$?; trap - EXIT
  if [ -n "$APID" ]; then kill "$APID"; wait "$APID" || true; fi
  bin/fm-hc-lab.sh teardown "$S" || rc=1
  rm -f "$E/a/herdr-app.sock"
  exit "$rc"
}
trap cleanup EXIT
bin/fm-hc-lab.sh provision "$S"
export HC_SESSION=$S FM_HC_SOCKET="$(bin/fm-hc-lab.sh socket "$S")"
export XDG_STATE_HOME="$FM_HC_LAB_DIR/$S/env/xdg-state" XDG_CONFIG_HOME="$FM_HC_LAB_DIR/$S/env/xdg-config" XDG_DATA_HOME="$FM_HC_LAB_DIR/$S/env/xdg-data"
export HERDR_APP_HOME="$E/a" FM_BACKEND_CONFIG_DIR="$ROOT/.test-tools/empty-config"
export FM_CONFIG_OVERRIDE="$FM_BACKEND_CONFIG_DIR"
mkdir -p "$HERDR_APP_HOME" "$FM_BACKEND_CONFIG_DIR"
rm -f "$HERDR_APP_HOME/herdr-app.sock" "$FM_BACKEND_CONFIG_DIR/backend"
mkdir -p "$ROOT/.test-tools/no-jq"
for tool in dirname python3 uname ps tr; do ln -sf "$(command -v "$tool")" "$ROOT/.test-tools/no-jq/$tool"; done
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION CMUX_WORKSPACE_ID __CFBundleIdentifier TERM_PROGRAM REX_BLOCK REX_SESSION PASEO_AGENT_ID FM_BACKEND FM_SUPERVISOR_BACKEND FM_SUPERVISOR_TARGET HC_TERMINAL_ID HC_TERMINAL_SOCKET
T=$(bin/fm-hc-lab.sh run "$S" run --bg --no-parent --label herdr.space=lab --label herdr.tab=guard | jq -r .address)
U=$(bin/fm-hc-lab.sh run "$S" run --bg --no-parent | jq -r .address)
export HC_TERMINAL_ID=$T HC_TERMINAL_SOCKET=$FM_HC_SOCKET
resolve() { bash -c '. "$1/bin/fm-backend.sh"; fm_backend_resolve; printf "backend=%s signal=%s\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"' _ "$ROOT"; }
check() { local expected=$1; shift; local out; out=$("$@"); printf '%s\n' "$out"; [ "$out" = "$expected" ]; }
printf '\nLABELED REAL CORE TERMINAL\n'
check 'backend=hc signal=app-terminal' resolve
printf '\nUNLABELED REAL CORE TERMINAL\n'
check 'backend=tmux signal=' env HC_TERMINAL_ID="$U" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_resolve; printf "backend=%s signal=%s\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"' _ "$ROOT"
printf '\nWRONG SPAWN SOCKET / DEAD SOCKET / BARE ID\n'
for variant in wrong dead bare; do
  case $variant in
    wrong) args=(FM_HC_SOCKET="$E/s/absent.sock");;
    dead) args=(FM_HC_SOCKET="$E/s/dead.sock" HC_TERMINAL_SOCKET="$E/s/dead.sock");;
    bare) args=(HC_TERMINAL_SOCKET=);;
  esac
  check 'backend=tmux signal=' env "${args[@]}" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_resolve; printf "backend=%s signal=%s\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"' _ "$ROOT"
done
[ ! -e "$E/s/dead.sock" ] && [ ! -e "$E/s/absent.sock" ]
printf '\nTERMINAL TOOLCHAIN: ACTUAL HC 0.1.13 AND MISSING BINARY\n'
for bin in "$ROOT/.test-tools/old/herdr-core" "$ROOT/.test-tools/no-hc"; do
  [ ! -x "$bin" ] || "$bin" --version
  check 'backend=tmux signal=app-terminal-unusable' env FM_HC_BIN="$bin" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_resolve; printf "backend=%s signal=%s\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"' _ "$ROOT"
done
printf '\nMISSING JQ WITH REAL CORE TERMINAL\n'
check 'backend=tmux signal=app-terminal-unusable' env PATH="$ROOT/.test-tools/no-jq" /bin/bash -c '. "$1/bin/fm-backend.sh"; fm_backend_resolve; printf "backend=%s signal=%s\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"' _ "$ROOT"
printf '\nEARLIER SURFACES AND EXPLICIT OVERRIDES\n'
for pair in 'TMUX=lab tmux TMUX' 'HERDR_ENV=1 herdr HERDR_ENV' 'CMUX_WORKSPACE_ID=lab cmux CMUX_WORKSPACE_ID'; do
  read -r setting expected signal <<< "$pair"
  check "backend=$expected signal=$signal" env "$setting" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_resolve; printf "backend=%s signal=%s\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"' _ "$ROOT"
done
check 'backend=tmux signal=' env FM_BACKEND=tmux bash -c '. "$1/bin/fm-backend.sh"; fm_backend_resolve; printf "backend=%s signal=%s\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"' _ "$ROOT"
printf 'tmux\n' > "$FM_BACKEND_CONFIG_DIR/backend"
check 'backend=tmux signal=' resolve
rm "$FM_BACKEND_CONFIG_DIR/backend"
printf '\nWINDOW SYNTHETIC SOCKET: REAL CORE, OLD BINARY, AND ABSENT CORE\n'
python3 - "$HERDR_APP_HOME/herdr-app.sock" <<'PY' &
import socket, sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(32)
while True:
    c,_=s.accept(); c.close()
PY
APID=$!
sleep .2
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET
check 'backend=hc signal=app-window' resolve
check 'backend=tmux signal=app-window-unusable' env PATH="$ROOT/.test-tools/no-jq" /bin/bash -c '. "$1/bin/fm-backend.sh"; fm_backend_resolve; printf "backend=%s signal=%s\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"' _ "$ROOT"
check 'backend=tmux signal=app-window-unusable' env FM_HC_BIN="$ROOT/.test-tools/old/herdr-core" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_resolve; printf "backend=%s signal=%s\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"' _ "$ROOT"
check 'backend=tmux signal=app-window-no-core' env FM_HC_SOCKET="$E/s/absent.sock" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_resolve; printf "backend=%s signal=%s\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"' _ "$ROOT"
[ ! -e "$E/s/absent.sock" ]
kill "$APID"; wait "$APID" || true; APID=
printf '\nSTALE WINDOW AND HEADLESS DEFAULT\n'
check 'backend=tmux signal=' resolve
rm "$HERDR_APP_HOME/herdr-app.sock"
check 'backend=tmux signal=' resolve
printf '\nAWAY DAEMON FROM ACTUAL CORE TERMINAL\n'
bin/fm-lab-home.sh create "$ROOT/.test-tools/away-home"
cat > "$ROOT/.test-tools/away-probe.sh" <<'SH'
#!/usr/bin/env bash
ROOT=$1; E=$2
export FM_HOME="$ROOT/.test-tools/away-home"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID TERM_PROGRAM REX_SESSION REX_BLOCK FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
{
  . "$ROOT/bin/fm-supervisor-target-lib.sh"
  printf 'HC_SESSION=%s HC_TERMINAL_ID=%s HC_TERMINAL_SOCKET=%s\n' "$HC_SESSION" "$HC_TERMINAL_ID" "$HC_TERMINAL_SOCKET"
  printf 'target='; discover_supervisor_target; printf '\nbackend='; discover_supervisor_backend; printf '\n'
  bash "$ROOT/bin/fm-supervise-daemon.sh"
  printf 'daemon_exit=%s\n' "$?"
} > "$E/away-live.log" 2>&1
SH
bin/fm-hc-lab.sh run "$S" run --bg --no-parent --cwd "$ROOT" -- bash "$ROOT/.test-tools/away-probe.sh" "$ROOT" "$E"
for i in {1..50}; do [ ! -f "$E/away-live.log" ] || grep -q '^daemon_exit=' "$E/away-live.log" && break; sleep .1; done
cat "$E/away-live.log"
grep -q '^backend=hc$' "$E/away-live.log"
grep -q 'does not support supervisor backend '\''hc' "$E/away-live.log"
grep -q '^daemon_exit=1$' "$E/away-live.log"
printf '\nAll focused live CLI guards completed.\n'
