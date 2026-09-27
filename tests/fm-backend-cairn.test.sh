#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state" "$tmp/home"
printf '{"pid":%s}\n' "$$" >"$tmp/state/control.json"

cat >"$tmp/cairnctl" <<'CLIENT'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == --state-dir && $3 == call ]]
method=$4
printf '%s\n' "$method" >>"$CAIRN_FAKE_LOG"
case "$method" in
  api/ping) printf '{"result":{"nonce":"firstmate"}}\n' ;;
  workspaces/list)
    if [[ ${CAIRN_FAKE_EXISTING:-0} == 1 ]]; then
      printf '{"result":{"workspaces":[{"id":"11111111-1111-1111-1111-111111111111","target":"local","running":true,"firstMateHome":"%s","firstMateTaskId":"task-1"}]}}\n' "$CAIRN_FAKE_HOME"
    else
      printf '{"result":{"workspaces":[{"id":"11111111-1111-1111-1111-111111111111","target":"local","running":true}]}}\n'
    fi
    ;;
  workspaces/spawn)
    printf '{"result":{"workspaceId":"11111111-1111-1111-1111-111111111111","paneId":"22222222-2222-2222-2222-222222222222"}}\n'
    ;;
  firstmate/endpoint/inspect)
    printf '{"result":{"endpointState":"%s","directory":"/tmp/worktree","paneCount":%s,"shellPid":100}}\n' "${CAIRN_FAKE_STATE:-present}" "${CAIRN_FAKE_PANES:-1}"
    ;;
  firstmate/endpoint/capture|firstmate/endpoint/visible)
    printf '{"result":{"text":"line one\\nline two"}}\n'
    ;;
  firstmate/endpoint/text|firstmate/endpoint/key)
    printf '{"result":{"sent":true}}\n'
    ;;
  firstmate/endpoint/stop)
    printf '{"result":{"stopped":true}}\n'
    ;;
  *) exit 1 ;;
esac
CLIENT
chmod +x "$tmp/cairnctl"
cat >"$tmp/ps" <<'PS'
#!/usr/bin/env bash
printf '%s\n' "${CAIRN_FAKE_PS:-100 1 zsh}"
PS
chmod +x "$tmp/ps"

export PATH="$tmp:$PATH"
export CAIRNCTL="$tmp/cairnctl"
export CAIRN_FAKE_LOG="$tmp/calls"
export CAIRN_FAKE_HOME="$tmp/home"
export CAIRN_INSTANCE_STATE_DIR="$tmp/state"
export CAIRN_WORKSPACE_ID=11111111-1111-1111-1111-111111111111
export FM_HOME="$tmp/home"
. "$root/bin/fm-backend.sh"

[[ $(fm_backend_detect) == cairn ]]
[[ $(TMUX=nested fm_backend_detect) == tmux ]]
[[ $(HERDR_ENV=1 fm_backend_detect) == herdr ]]
fm_backend_source cairn
target=$(fm_backend_cairn_create_task fm-task-1 /tmp/project)
[[ $target == "$tmp/state|$tmp/home|task-1|11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222" ]]
[[ $(fm_backend_capture cairn "$target" 2) == $'line one\nline two' ]]
[[ $(fm_backend_visible_capture cairn "$target") == $'line one\nline two' ]]
[[ $(fm_backend_cairn_current_path "$target") == /tmp/worktree ]]
[[ $(fm_backend_agent_state cairn "$target") == dead ]]
. "$root/bin/fm-control-lib.sh"
fm_control_backend_state_verified cairn
[[ $(fm_control_endpoint_absence_verdict cairn "$target") == dead$'\t' ]]
CAIRN_FAKE_PS=$'100 1 zsh\n101 100 codex'
export CAIRN_FAKE_PS
[[ $(fm_backend_agent_state cairn "$target") == alive ]]
CAIRN_FAKE_STATE=unreadable
export CAIRN_FAKE_STATE
[[ $(fm_backend_agent_state cairn "$target") == unreadable ]]
[[ $(fm_control_endpoint_absence_verdict cairn "$target") == unproven$'\t'* ]]
unset CAIRN_FAKE_STATE
CAIRN_FAKE_PANES=2
export CAIRN_FAKE_PANES
if fm_backend_cairn_stop_preflight "$target"; then exit 1; fi
CAIRN_FAKE_PANES=1
export CAIRN_FAKE_PANES
fm_backend_cairn_stop_preflight "$target"
fm_backend_cairn_send_literal "$target" 'literal text'
fm_backend_cairn_send_key "$target" Enter
fm_backend_kill cairn "$target"
CAIRN_FAKE_EXISTING=1
export CAIRN_FAKE_EXISTING
if fm_backend_cairn_create_task fm-task-1 /tmp/project 2>/dev/null; then exit 1; fi
unset CAIRN_FAKE_EXISTING
mkdir -p "$tmp/mate-home"
mate_target=$(fm_backend_cairn_create_task fm-mate-1 "$tmp/mate-home" "$tmp/mate-home")
[[ $mate_target == "$tmp/state|$tmp/mate-home|mate-1|"* ]]

cat >"$tmp/home/task-1.meta" <<EOF
window=$target
endpoint_task_id=task-1
worktree=/tmp/worktree
project=/tmp/project
backend=cairn
cairn_instance_state_dir=$tmp/state
cairn_instance_pid=$$
cairn_home=$tmp/home
cairn_workspace_id=11111111-1111-1111-1111-111111111111
cairn_pane_id=22222222-2222-2222-2222-222222222222
EOF
fm_backend_validate_task_endpoint "$tmp/home/task-1.meta" task-1
[[ $FM_BACKEND_VALIDATED_TARGET == "$target" ]]
sed -i '' 's/cairn_pane_id=2222/cairn_pane_id=3333/' "$tmp/home/task-1.meta"
if fm_backend_validate_task_endpoint "$tmp/home/task-1.meta" task-1 2>/dev/null; then exit 1; fi
printf 'cairn backend test: OK\n'
