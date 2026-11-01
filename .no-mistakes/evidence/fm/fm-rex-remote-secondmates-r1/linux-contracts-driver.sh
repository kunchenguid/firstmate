#!/bin/bash
set -euo pipefail
cd /work
export HOME=/work/.test-live/account
export PATH=/work/.test-live/linux-bin:/work/.test-live/tools/node_modules/.bin:$PATH
export SHELL=/bin/bash TERM=xterm-256color XDG_RUNTIME_DIR=/tmp/fm-rex-runtime NO_MISTAKES_GATE=1
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
CODE=/work/.test-live/code
MATE=/work/.test-live/mate
control() { FM_HOME="$MATE" FM_ROOT_OVERRIDE="$CODE" "$CODE/bin/fm-remote-secondmate-control.sh" "$@"; }
cleanup() {
  set +e
  rex --autostart=false server stop
  if [ -f "$HOME/.firstmate/remote-job/worker.pid" ]; then
    . /work/bin/fm-remote-job-lib.sh
    fm_remote_job_stop_worker_tree "$(cat "$HOME/.firstmate/remote-job/worker.pid")"
  fi
}
trap cleanup EXIT
rex version; codex --version; uname -a
rex server start
rex session new fm-lab-codex --cwd "$MATE" --shell none --json -- /work/.test-live/tools/node_modules/.bin/codex > /work/.test-live/session.json
session=$(jq -r .session_id /work/.test-live/session.json)
window=$(jq -r '.initial_windows[0].window_id' /work/.test-live/session.json)
block=$(jq -r '.initial_windows[0].block_ids[0]' /work/.test-live/session.json)
endpoint=$(rex --autostart=false server status --json | jq -r .endpoint)
mkdir -p "$MATE/state/parent-route"
meta="$MATE/state/parent-route/ios.meta"
cat > "$meta" <<EOF
backend=rex
endpoint_task_id=ios
window=${session#session:}:${block#block:}
rex_session_id=$session
rex_window_id=$window
rex_block_id=$block
rex_server=$endpoint
worktree=$MATE
project=$MATE
kind=secondmate
harness=codex
home=$MATE
EOF
printf '\n=== Read actual Linux Codex endpoint through remote control ===\n'
sleep 4
control route ios
state=$(control state ios); printf 'live state=%s\n' "$state"; [ "$state" = alive ]
control capture ios 35
printf '\n=== Existing-live launch is idempotent ===\n'
control launch ios codex - - rex
printf '\n=== Mismatched backend and nonlocal metadata refuse ===\n'
if control launch ios codex - - herdr > /work/.test-live/refusal.log 2>&1; then exit 20; fi
cat /work/.test-live/refusal.log
grep -q "expected 'herdr'" /work/.test-live/refusal.log
cp "$meta" /work/.test-live/good.meta
sed -i 's|^rex_server=.*|rex_server=tcp://127.0.0.1:7299|' "$meta"
state=$(control state ios); printf 'nonlocal state=%s\n' "$state"; [ "$state" = unverified ]
cp /work/.test-live/good.meta "$meta"
printf '\n=== Stopped-server state and launch probes must NOT autostart ===\n'
rex server stop
state=$(control state ios); printf 'stopped state=%s\n' "$state"; [ "$state" = unreadable ]
if control launch ios codex - - rex > /work/.test-live/refusal.log 2>&1; then exit 21; fi
cat /work/.test-live/refusal.log
grep -q 'state is unreadable' /work/.test-live/refusal.log
if rex --autostart=false server status --json > /work/.test-live/stopped-status.json 2>&1; then exit 22; fi
cat /work/.test-live/stopped-status.json
printf '\n=== Doctor --fix starts only the missing persistent server ===\n'
set +e
FM_HOME="$CODE" FM_ROOT_OVERRIDE="$CODE" "$CODE/bin/fm-remote-doctor.sh" --backend rex --fix > /work/.test-live/doctor-start.log 2>&1
rc=$?
set -e
cat /work/.test-live/doctor-start.log
printf 'doctor overall exit=%s (other required tools intentionally absent)\n' "$rc"
grep -q 'check rex-server=ok: persistent rex server' /work/.test-live/doctor-start.log
rex --autostart=false server status --json > /work/.test-live/persistent.json
cat /work/.test-live/persistent.json
jq -e '.exit_empty == false' /work/.test-live/persistent.json >/dev/null
state=$(control state ios); printf 'restored state=%s\n' "$state"; [ "$state" = dead ]
printf '\n=== Full recovery and key routing hit gate safety, not bypassed ===\n'
set +e
control launch ios codex - - rex > /work/.test-live/recovery.log 2>&1
recovery_rc=$?
control key ios Escape > /work/.test-live/key.log 2>&1
key_rc=$?
set -e
cat /work/.test-live/recovery.log; printf 'recovery exit=%s\n' "$recovery_rc"
cat /work/.test-live/key.log; printf 'key exit=%s\n' "$key_rc"
[ "$recovery_rc" -ne 0 ]; [ "$key_rc" -ne 0 ]
printf '\n=== Doctor must preserve an answering exit-empty server and sibling ===\n'
rex server stop
rex ls >/dev/null
rex session new fm-lab-sibling --shell none --json -- /bin/sleep 300 > /work/.test-live/sibling.json
rex --autostart=false server status --json > /work/.test-live/before.json
jq -e '.exit_empty == true' /work/.test-live/before.json >/dev/null
sibling_s=$(jq -r .session_id /work/.test-live/sibling.json)
sibling_b=$(jq -r '.initial_windows[0].block_ids[0]' /work/.test-live/sibling.json)
rex block call -s "$sibling_s" -b "$sibling_b" process > /work/.test-live/process-before.json
set +e
FM_HOME="$CODE" FM_ROOT_OVERRIDE="$CODE" "$CODE/bin/fm-remote-doctor.sh" --backend rex --fix > /work/.test-live/doctor-preserve.log 2>&1
rc=$?
set -e
cat /work/.test-live/doctor-preserve.log
printf 'exit-empty doctor exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
grep -q 'check rex-server=human:' /work/.test-live/doctor-preserve.log
rex --autostart=false server status --json > /work/.test-live/after.json
rex block call -s "$sibling_s" -b "$sibling_b" process > /work/.test-live/process-after.json
cat /work/.test-live/process-before.json /work/.test-live/process-after.json
[ "$(jq -r .instance_id /work/.test-live/before.json)" = "$(jq -r .instance_id /work/.test-live/after.json)" ]
cmp /work/.test-live/process-before.json /work/.test-live/process-after.json
printf 'Same Rex instance and identical live sibling process before/after repair.\n'
printf '\n=== Completed all live read-only and server safety assertions ===\n'
