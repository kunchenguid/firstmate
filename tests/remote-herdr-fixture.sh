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
  local codex_root="$1/.nvm/versions/node/v24.19.0"
  local codex_script="$codex_root/lib/node_modules/@openai/codex/bin/codex.js"
  local codex_launcher="$codex_root/bin/codex"
  local standalone_release="$1/.codex/packages/standalone/releases/0.146.0/bin/codex"
  local standalone_current="$1/.codex/packages/standalone/current"
  local standalone_launcher="$1/.local/bin/codex"
  local lock_lib="$1/bin/fm-session-lock-lib.sh" quoted_remote_root
  mkdir -p "$remote_root/bin" "$codex_root/bin" "$(dirname "$codex_script")" \
    "$(dirname "$standalone_release")" "$(dirname "$standalone_launcher")"
  command -v node >/dev/null 2>&1 || return 1
  [ -f "$lock_lib" ] || return 1
  printf -v quoted_remote_root '%q' "$remote_root"
  printf '\nfm_codex_system_home() { printf "%%s\\n" %s; }\n' "$quoted_remote_root" >> "$lock_lib"
  cat > "$codex_script" <<'JS'
#!/usr/bin/env node
setInterval(() => {}, 1000);
JS
  chmod +x "$codex_script"
  ln -s ../lib/node_modules/@openai/codex/bin/codex.js "$codex_launcher"
  cp "$(command -v node)" "$standalone_release"
  chmod +x "$standalone_release"
  ln -s releases/0.146.0 "$standalone_current"
  ln -s "$standalone_current/bin/codex" "$standalone_launcher"
  cat > "$script" <<SH
#!/usr/bin/env bash
set -u
STATE='$state'
LOG='$log'
SEND_FAIL='$send_fail'
SOCKET='$socket'
CODEX_BIN='$standalone_launcher'
NODE_BIN='$(command -v node)'
PROCESS_MODE_FILE='$state.process-mode'
PROC_ROOT='$state.proc'
SH
  cat >> "$script" <<'SH'
printf '%s\n' "$*" >> "$LOG"
jq_state() { jq "$@" "$STATE"; }
save() { tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }
ws=""; label=""; cwd=""; pane=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
    --pane) pane=${args[$((i+1))]:-} ;;
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
    if [ "$(cat "$STATE.close-mode" 2>/dev/null || true)" = leave-agentless ]; then
      jq_state --arg p "${3:-}" \
        '.typed |= with_entries(select(.key != $p))
         | .working |= with_entries(select(.key != $p))' | save
      exit 1
    fi
    jq_state --arg p "${3:-}" \
      '.tabs |= [.[]|select(.pane_id != $p)]
       | .typed |= with_entries(select(.key != $p))
       | .working |= with_entries(select(.key != $p))' | save ;;
  "pane send-text")
    if [ -f "$SEND_FAIL" ]; then
      send_fail_mode=$(cat "$SEND_FAIL" 2>/dev/null || true)
      case "$send_fail_mode" in
        startup-brief)
          agent_pid=$(cat "$STATE.agent-pid" 2>/dev/null || true)
          ! kill -0 "$agent_pid" 2>/dev/null || exit 1
          ;;
        *) exit 1 ;;
      esac
    fi
    jq_state --arg p "${3:-}" '.typed[$p] = true' | save ;;
  "pane send-keys")
    if [ -f "$SEND_FAIL" ] && [ "$(cat "$SEND_FAIL" 2>/dev/null || true)" != startup-brief ]; then
      exit 1
    fi
    process_mode=$(cat "$PROCESS_MODE_FILE" 2>/dev/null || true)
    agent_pid_file="$STATE.agent-pid"
    agent_pid=$(cat "$agent_pid_file" 2>/dev/null || true)
    if [ "$process_mode" != generic-only ] && ! kill -0 "$agent_pid" 2>/dev/null; then
      CODEX_SESSION_ID=4d5f9e9a-0e7c-4d32-9f3a-6fd1e2eb4a54 \
        "$CODEX_BIN" -e 'setInterval(() => {}, 1000)' >/dev/null 2>&1 &
      agent_pid=$!
      printf '%s\n' "$agent_pid" > "$agent_pid_file"
      mkdir -p "$PROC_ROOT/$agent_pid"
      printf 'CODEX_SESSION_ID=4d5f9e9a-0e7c-4d32-9f3a-6fd1e2eb4a54\0' > "$PROC_ROOT/$agent_pid/environ"
      ln -s "$CODEX_BIN" "$PROC_ROOT/$agent_pid/exe"
    fi
    helper_pid_file="$STATE.helper-pid"
    helper_pid=$(cat "$helper_pid_file" 2>/dev/null || true)
    case "$process_mode" in
      generic-only|with-helper)
        if ! kill -0 "$helper_pid" 2>/dev/null; then
          CODEX_SESSION_ID=4d5f9e9a-0e7c-4d32-9f3a-6fd1e2eb4a54 \
            "$NODE_BIN" -e 'setInterval(() => {}, 1000)' codex-helper >/dev/null 2>&1 &
          helper_pid=$!
          printf '%s\n' "$helper_pid" > "$helper_pid_file"
          mkdir -p "$PROC_ROOT/$helper_pid"
          printf 'CODEX_SESSION_ID=4d5f9e9a-0e7c-4d32-9f3a-6fd1e2eb4a54\0' > "$PROC_ROOT/$helper_pid/environ"
          ln -s "$NODE_BIN" "$PROC_ROOT/$helper_pid/exe"
        fi
        ;;
    esac
    jq_state --arg p "${3:-}" '.typed[$p] = true | .working[$p] = true' | save ;;
  "pane read") printf '\n' ;;
  "pane process-info")
    pane=${pane:-${3:-}}
    process_mode=$(cat "$PROCESS_MODE_FILE" 2>/dev/null || true)
    agent_pid=$(cat "$STATE.agent-pid" 2>/dev/null || true)
    helper_pid=$(cat "$STATE.helper-pid" 2>/dev/null || true)
    if [ "$process_mode" = wrong-pane ] && kill -0 "$agent_pid" 2>/dev/null; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"wrong-pane","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"argv":["%s","-e"],"name":"node","pid":%s}]}}}\n' \
        "$agent_pid" "$agent_pid" "$CODEX_BIN" "$agent_pid"
    elif [ "$process_mode" = with-helper ] \
      && kill -0 "$agent_pid" 2>/dev/null \
      && kill -0 "$helper_pid" 2>/dev/null; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"argv":["%s","-e"],"name":"node","pid":%s},{"argv":["%s","-e"],"name":"node","pid":%s}]}}}\n' \
        "$pane" "$agent_pid" "$agent_pid" "$CODEX_BIN" "$agent_pid" "$NODE_BIN" "$helper_pid"
    elif [ "$process_mode" = generic-only ] && kill -0 "$helper_pid" 2>/dev/null; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"argv":["%s","-e"],"name":"node","pid":%s}]}}}\n' \
        "$pane" "$helper_pid" "$helper_pid" "$NODE_BIN" "$helper_pid"
    elif kill -0 "$agent_pid" 2>/dev/null; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"argv":["%s","-e"],"name":"node","pid":%s}]}}}\n' \
        "$pane" "$agent_pid" "$agent_pid" "$CODEX_BIN" "$agent_pid"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":2,"foreground_process_group_id":2,"foreground_processes":[]}}}\n' "$pane"
    fi
    ;;
  "agent get")
    pane=${3:-}
    if [ "$(jq_state -r --arg p "$pane" '.working[$p] // false')" = true ]; then
      jq_state --arg p "$pane" '.working |= with_entries(select(.key != $p))' | save
      printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    elif [ "$(jq_state -r --arg p "$pane" '.typed[$p] // false')" = true ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
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
