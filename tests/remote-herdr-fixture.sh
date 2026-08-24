#!/usr/bin/env bash
# tests/remote-herdr-fixture.sh - the stateful herdr CLI fixture the remote
# second-mate suites install on their fake remote host.
#
# A remote second mate always launches on the Herdr backend
# (docs/remote-secondmates.md), so a remote-route test needs a herdr CLI on the
# remote code root's own bin directory. This fixture models the workspace, tab,
# pane, and agent facts bin/backends/herdr.sh actually reads, backed by a JSON
# state file mutated with real jq, using the same verified herdr behaviors as
# tests/fm-backend-herdr.test.sh's stateful fake: workspace create seeds one
# default tab and returns its tab and root pane in the same response, closing a
# tab's only pane closes the tab, and agent get reports agent_not_found for a
# pane no agent has registered on.
#
# Beyond that it models the pane IO a real launch performs. A pane reports a
# registered agent once anything has been typed into it, and submitting starts
# one turn: the next agent read reports working and the pane settles back to
# idle, which is the native transition the adapter confirms a submit with.
#
# A registration is reported the way a real host reports it: `agent get` names
# the registered agent executable, and `pane process-info` reports that same
# executable holding the pane's foreground process group, which is the
# agreement the lifecycle liveness proof reads before calling a pane alive. A
# pane nothing was ever launched into reports its own lone login shell instead.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"
#   install_remote_herdr_fixture <remote-root> <state-file> <log-file> \
#     <send-fail-flag> <socket-path>
#
# Every invocation is appended verbatim to <log-file>, so a test reads back what
# the remote pane received. Creating <send-fail-flag> makes every pane write
# fail, which is how a test simulates an endpoint that cannot be reached.

install_remote_herdr_fixture() { # <remote-root> <state> <log> <send-fail> <socket>
  local remote_root=$1 state=$2 log=$3 send_fail=$4 socket=$5 script="$1/bin/herdr"
  mkdir -p "$remote_root/bin"
  cat > "$script" <<SH
#!/usr/bin/env bash
set -u
STATE='$state'
LOG='$log'
SEND_FAIL='$send_fail'
SOCKET='$socket'
SH
  cat >> "$script" <<'SH'
printf '%s\n' "$*" >> "$LOG"
jq_state() { jq "$@" "$STATE"; }
save() { tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }
# The one agent executable this fake host runs. `agent get` registers it and
# `pane process-info` reports the same name in the pane's foreground process
# group, which is the registry/process-table agreement a real Herdr host shows
# for a running agent (docs/verification/runtime-backends.md).
FIXTURE_AGENT=codex
# Deterministic per-pane pids derived from the pane id, so repeated reads of
# the same pane agree with each other the way a real host's do.
pane_pids() {  # <pane-id> -> SHELL_PID, AGENT_PID
  local n=${1##*p}
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  SHELL_PID=$((4000 + n * 2))
  AGENT_PID=$((SHELL_PID + 1))
}
ws=""; label=""; cwd=""; pane_opt=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
    --pane) pane_opt=${args[$((i+1))]:-} ;;
  esac
done
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  "server "*|"server") : ;;
  "workspace list") jq_state '{result:{workspaces:.workspaces}}' ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" --arg cwd "$cwd" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel, cwd:$cwd}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list") jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}' ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg cwd "$cwd" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid, cwd:$cwd}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "tab close")
    jq_state --arg t "${3:-}" '.tabs |= [.[]|select(.tab_id != $t)]' | save ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}' ;;
  "pane get")
    pane=${3:-}
    if [ "$(jq_state -r --arg p "$pane" '[.tabs[]|select(.pane_id==$p)]|length')" = 0 ]; then
      printf '{"error":{"code":"pane_not_found","message":"%s"}}\n' "$pane"
    else
      printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$pane"
    fi
    ;;
  "pane close")
    jq_state --arg p "${3:-}" \
      '.tabs |= [.[]|select(.pane_id != $p)]
       | .typed |= with_entries(select(.key != $p))
       | .working |= with_entries(select(.key != $p))' | save ;;
  "pane send-text")
    [ ! -f "$SEND_FAIL" ] || exit 1
    jq_state --arg p "${3:-}" '.typed[$p] = true' | save ;;
  "pane send-keys")
    [ ! -f "$SEND_FAIL" ] || exit 1
    jq_state --arg p "${3:-}" '.typed[$p] = true | .working[$p] = true' | save ;;
  "pane read") printf '\n' ;;
  "pane process-info")
    pane=${pane_opt:-${3:-}}
    if [ "$(jq_state -r --arg p "$pane" '[.tabs[]|select(.pane_id==$p)]|length')" = 0 ]; then
      printf '{"error":{"code":"pane_not_found","message":"%s"}}\n' "$pane"
    elif [ "$(jq_state -r --arg p "$pane" '.typed[$p] // false')" = true ]; then
      # A launched pane: its login shell is still the pane's shell, while the
      # registered agent executable holds the foreground process group. This is
      # the shape bin/backends/herdr.sh's liveness proof reads, and the agent
      # name matches what `agent get` registers for the same pane.
      pane_pids "$pane"
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"%s","argv0":"%s"}]}}}\n' \
        "$pane" "$SHELL_PID" "$AGENT_PID" "$AGENT_PID" "$FIXTURE_AGENT" "$FIXTURE_AGENT"
    else
      # Nothing was ever launched here: the pane sits at its own login shell.
      pane_pids "$pane"
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"bash","argv0":"-bash"}]}}}\n' \
        "$pane" "$SHELL_PID" "$SHELL_PID" "$SHELL_PID"
    fi
    ;;
  "agent get")
    pane=${3:-}
    if [ "$(jq_state -r --arg p "$pane" '.working[$p] // false')" = true ]; then
      jq_state --arg p "$pane" '.working |= with_entries(select(.key != $p))' | save
      printf '{"result":{"agent":{"agent":"%s","agent_status":"working"}}}\n' "$FIXTURE_AGENT"
    elif [ "$(jq_state -r --arg p "$pane" '.typed[$p] // false')" = true ]; then
      printf '{"result":{"agent":{"agent":"%s","agent_status":"idle"}}}\n' "$FIXTURE_AGENT"
    else
      printf '{"error":{"code":"agent_not_found","message":"%s"}}\n' "$pane"
    fi
    ;;
  "session list"*)
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s"},{"name":"fm-remote","running":true,"socket_path":"%s"}]}\n' "$SOCKET" "$SOCKET" ;;
esac
exit 0
SH
  chmod +x "$script"
  reset_remote_herdr_fixture "$state"
}

# reset_remote_herdr_fixture <state>: return the fake host to "no workspaces,
# tabs, or panes", which is what a test means by "the previous endpoint is gone".
reset_remote_herdr_fixture() { # <state>
  printf '{"next":1,"workspaces":[],"tabs":[],"typed":{},"working":{}}\n' > "$1"
}
