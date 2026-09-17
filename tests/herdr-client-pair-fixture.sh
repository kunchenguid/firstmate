#!/usr/bin/env bash
# tests/herdr-client-pair-fixture.sh - two herdr CLI fakes modeling one host
# that carries a stale client next to a compatible one.
#
# A self-updated ~/.local/bin copy next to a package-managed herdr is a real
# host shape, and Firstmate's fixed remote-job PATH resolves ~/.local/bin first
# (bin/fm-remote-job-lib.sh). A client older than the running server answers
# every command except `status` with error code protocol_mismatch on stderr
# and exit 1 (verified: herdr 0.8.2, protocol 20, against a 0.9.0 server,
# protocol 22). bin/backends/herdr.sh "client selection" owns how the adapter
# steps around that; these fakes exist so its suites can reproduce the shape.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/herdr-client-pair-fixture.sh"
#   make_herdr_client_pair <dir> [<stale-version> <stale-protocol> <current-version> <current-protocol>]
#
# Installs <dir>/stale/herdr (default 0.8.2, protocol 20, refused by the
# protocol-22 server) and <dir>/current/herdr (default 0.9.0, protocol 22)
# whose pane and agent reads model one live claude agent at fm-remote:wCY:p2,
# plus <dir>/tools/jq so a PATH made of only these directories still parses
# JSON. Each fake appends its argv to <dir>/stale.log or <dir>/current.log;
# callers export FM_HERDR_PAIR_DIR=<dir>.

make_herdr_client_pair() {  # <dir> [stale-version stale-protocol current-version current-protocol]
  local dir=$1 stale_version=${2:-0.8.2} stale_protocol=${3:-20} current_version=${4:-0.9.0} current_protocol=${5:-22}
  mkdir -p "$dir/stale" "$dir/current" "$dir/tools"
  ln -sf "$(command -v jq)" "$dir/tools/jq"
  cat > "$dir/stale/herdr" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "\${FM_HERDR_PAIR_DIR:?}/stale.log"
case "\${1:-} \${2:-}" in
  "status --json")
    printf '{"client":{"version":"$stale_version","channel":"stable","protocol":$stale_protocol},"server":{"status":"running","running":true,"version":"$current_version","protocol":$current_protocol,"compatible":false,"session":"fm-remote","restart_needed":true}}\\n'
    exit 0 ;;
esac
printf '{"id":"cli:%s:%s","error":{"code":"protocol_mismatch","message":"client protocol $stale_protocol is older than server protocol $current_protocol; upgrade the Herdr client before using this command"}}\\n' "\${1:-}" "\${2:-}" >&2
exit 1
SH
  cat > "$dir/current/herdr" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "\${FM_HERDR_PAIR_DIR:?}/current.log"
case "\${1:-} \${2:-}" in
  "status --json")
    printf '{"client":{"version":"$current_version","channel":"stable","protocol":$current_protocol},"server":{"status":"running","running":true,"version":"$current_version","protocol":$current_protocol,"compatible":true,"session":"fm-remote","restart_needed":false}}\\n' ;;
SH
  cat >> "$dir/current/herdr" <<'SH'
  "pane get")
    if [ "${3:-}" = wCY:p2 ]; then
      printf '{"id":"cli:pane:get","result":{"pane":{"agent":"claude","agent_status":"idle","pane_id":"wCY:p2","tab_id":"wCY:t2","workspace_id":"wCY"},"type":"pane_info"}}\n'
    else
      printf '{"id":"cli:pane:get","error":{"code":"pane_not_found","message":"no such pane"}}\n' >&2; exit 1
    fi ;;
  "agent get")
    printf '{"id":"cli:agent:get","result":{"agent":{"agent":"claude","agent_status":"idle","pane_id":"wCY:p2"},"type":"agent_info"}}\n' ;;
  "pane process-info")
    # The registration above is only trusted once a live harness process backs
    # it (issue #4115), so the compatible client also serves the process view.
    printf '{"id":"cli:pane:process_info","result":{"process_info":{"pane_id":"wCY:p2","shell_pid":4242,"foreground_process_group_id":4243,"foreground_processes":[{"pid":4243,"name":"claude","argv0":"claude","argv":["claude"],"cmdline":"claude"}]},"type":"pane_process_info"}}\n' ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$dir/stale/herdr" "$dir/current/herdr"
}
