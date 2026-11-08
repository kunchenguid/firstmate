#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M6DN8XWZK886JNCEVABDTY9C
export LIVE_ROOT="$ROOT" LIVE_ORIGINAL_HOME="$HOME" LIVE_ORIGINAL_PATH="$PATH"
export LIVE_HERDR_SESSION=fm-lab-owner-proof-94057-3797
export FM_HERDR_LAB_STATE_DIR="$ROOT/.test-lab-state"
REX="$ROOT/.test-validation/rex-bin/rex"
export HOME="$ROOT/.test-validation/account" FM_HOME="$ROOT/.test-validation/lab-home"
export REX_RUNTIME_DIR="$ROOT/.r"
export FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_STATE_ROOT="$HOME/.firstmate/remote-job"
export PATH="$ROOT/.test-validation/rex-bin:$PATH"
cleanup() {
  set +e
  if [ -n "${server_pid:-}" ]; then kill "$server_pid" 2>/dev/null; wait "$server_pid"; fi
  "$REX" --autostart=false server stop >> "$EVIDENCE/live-rex.log" 2>&1
  if [ -f "$FM_REMOTE_JOB_STATE_ROOT/worker.pid" ]; then
    pid=$(<"$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
    case "$pid" in ''|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null; for i in {1..30}; do kill -0 "$pid" 2>/dev/null || break; sleep .1; done ;; esac
  fi
}
trap cleanup EXIT
mkdir -p "$REX_RUNTIME_DIR" "$HOME/.firstmate" "$HOME/.local/bin"
chmod 700 "$HOME/.firstmate"
ln -sf "$REX" "$HOME/.local/bin/rex"
ln -sf "$(command -v tasks-axi)" "$HOME/.local/bin/tasks-axi"
ln -sf "$(command -v node)" "$HOME/.local/bin/node"
{
  echo 'REAL HERDR: original lab panes'
  "$ROOT/.test-validation/herdr-lab-cli" pane list
  echo 'Run actual launch-agent guard without takeover authorization against the running lab'
  "$ROOT/bin/fm-remote-herdr-guard.sh" "$ROOT/.test-validation/herdr-lab-cli" "$LIVE_HERDR_SESSION"
  echo 'REAL HERDR: retained lab panes'
  "$ROOT/.test-validation/herdr-lab-cli" pane list
} > "$EVIDENCE/live-herdr-guard.log" 2>&1
{
  echo 'Real downloaded Rex binary, verified against release SHA-256'
  "$REX" version
  echo 'Initial missing-server probe (must fail)'
  if "$REX" --autostart=false api call server.status; then exit 1; fi
  echo 'Doctor automatic repair with absent private server'
  rc=0
  "$ROOT/bin/fm-remote-doctor.sh" --fix --automatic --backend rex || rc=$?
  echo "doctor_exit=$rc"
  [ "$rc" -eq 0 ]
  echo 'Persisted real server state'
  "$REX" --autostart=false whoami --json
  "$REX" --autostart=false api call server.status
  "$REX" --autostart=false whoami --json | jq -e '.exit_empty == false'
  "$REX" --autostart=false server stop
  echo 'Start a real answering exit-empty server on the same private socket'
  "$REX" server run --exit-empty --state-dir "$HOME/rex-ephemeral" > "$EVIDENCE/rex-ephemeral-server.log" 2>&1 &
  server_pid=$!
  for i in {1..30}; do "$REX" --autostart=false api call server.status >/dev/null 2>&1 && break; sleep .1; done
  "$REX" --autostart=false session new readiness-sentinel --cwd "$ROOT" --shell none --json -- /bin/sleep 120 > "$EVIDENCE/rex-session-before.json"
  "$REX" --autostart=false whoami --json
  rc=0
  "$ROOT/bin/fm-remote-doctor.sh" --fix --automatic --backend rex || rc=$?
  echo "exit_empty_doctor_exit=$rc (expected nonzero with operator action)"
  "$REX" --autostart=false whoami --json
  "$REX" --autostart=false whoami --json | jq -e '.exit_empty == true'
  "$REX" --autostart=false session ls --json
  kill -0 "$server_pid"
  echo "Original server pid $server_pid remains alive; existing session retained"
  "$REX" --autostart=false server stop
  wait "$server_pid"
  unset server_pid
} > "$EVIDENCE/live-rex.log" 2>&1
