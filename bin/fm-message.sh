#!/usr/bin/env bash
# Read/validate the shared message contract, or send through the existing owner.
# Usage: fm-message.sh read <inbox-record>
#        fm-message.sh validate <message-json-file>
#        fm-message.sh receive  (own inbox, ordered JSONL {name,message})
#        fm-message.sh ack <numeric-record-name>  (own inbox, idempotent)
#        fm-message.sh stats  (bounded last-24-hour JSON summary, with completeness)
#        fm-message.sh service register|deregister <name> <parent-pid>
#        fm-message.sh send <recipients> [--thread <name>] [--kind <kind>]
#                           [--ref <request-id>] <text>
#        fm-message.sh send --reply <request-id> <text>
#        fm-message.sh send --retry <message-id> --thread <name>
# read returns fm-message.v1 JSON and refuses unstructured legacy records;
# their byte-preserving reader remains fm_task_inbox_body. Services consume
# this same shape behind their adapter port, not a second inbox format.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
help() {
  printf '%s\n' \
    'Usage: fm-message.sh <command> [options]' \
    '  send TO[,TO...] TEXT        Send same-home data. Example: send peer-a,peer-b --kind request --thread review "check the API"' \
    '    TEXT                     One nonempty printable line, at most 4096 characters. Put long content behind a file pointer in that line.' \
    '    --kind KIND              request|reply|note|needs-decision. Example: send peer-a --kind note "ready"' \
    '    --thread NAME            Use or create a named conversation. Example: send peer-a --thread review "ready"' \
    '    --ref MESSAGE_ID         Correlate a reply. Example: send peer-a --kind reply --ref msg-<32-hex> "checked"' \
    '    --reply MESSAGE_ID       Reply to all other thread members. Example: send --reply msg-<32-hex> "checked"' \
    '    --retry MESSAGE_ID       Resume a partial fan-out, never replace its text. Example: send --retry msg-<32-hex> --thread review' \
    '    --                       End flags before literal text. Example: send peer-a -- "-h is data"' \
    '  receive                    Read the own inbox as ordered JSONL without acknowledgement. Example: receive' \
    '  ack NAME                   Move one own numeric record to handled/. Example: ack 001.msg' \
    '  read FILE                  Decode one structured inbox record. Example: read state/peer-a.inbox/001.msg' \
    '  validate FILE              Validate one fm-message.v1 JSON object. Example: validate message.json' \
    '  stats                      Print the bounded rolling 24-hour telemetry summary. Example: stats' \
    '    Reads at most 1 MiB across today/yesterday; complete=false means partial counts. No arguments.' \
    '  service register NAME PID  Register the calling service process. Example: service register fm-moiras "$$"' \
    '  service deregister NAME PID  Remove its registration, preserving inbox data. Example: service deregister fm-moiras "$$"' \
    '  -h, --help                 Show help for any command without side effects. Example: send --help' \
    'FM_HOME selects the operational home; tasks inherit FM_TASK_ID; services use their registered FM_SERVICE_ID.' \
    'Service hints are bound to the registered live process ancestry, never accepted as a free sender label.' \
    'Send/receive/ack bind a task or registered service; only the supervisor requires cwd=FM_HOME.' \
    'Persistent homes use their parent FM_HOME and own FM_TASK_ID from the recorded home; home/parent identity is verified.' \
    'The underlying fm-send.sh retains supervisor-only --key KEY, --resolve-key KEY, and --fire-and-forget ID:' \
    '  --key KEY                  Send a runtime key. Example: fm-send.sh peer-a --key Enter' \
    '  --resolve-key KEY          Answer an open approval key. Example: fm-send.sh peer-a --resolve-key choice "use option A"' \
    '  --fire-and-forget ID       Delivery without reply tracking on a supported route. Example: fm-send.sh domain --fire-and-forget 0123456789abcdef "noted"'
}
for arg in "$@"; do
  [ "$arg" != -- ] || break
  case "$arg" in -h|--help) help; exit 0 ;; esac
done
case "${1:-}" in
  send) shift; exec "$SCRIPT_DIR/fm-send.sh" "$@" ;;
  receive|ack|service)
    verb=$1; shift
    [ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] || exit 1
    STATE="$FM_HOME/state"
    [ "$(cd "${FM_STATE_OVERRIDE:-$STATE}" && pwd -P)" = "$(cd "$STATE" && pwd -P)" ] || exit 1
    # shellcheck source=bin/fm-task-inbox-lib.sh
    . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
    # shellcheck source=bin/fm-peer-message-lib.sh
    . "$SCRIPT_DIR/fm-peer-message-lib.sh"
    if [ "$verb" = service ]; then
      [ "$#" -eq 3 ] || { echo 'error: expected service register|deregister NAME PID' >&2; exit 1; }
      fm_service_manage "$STATE" "$@"; exit $?
    fi
    actor=$(fm_peer_sender "$STATE" "${FM_TASK_ID:-}") || exit 1
    lock=$(fm_meta_lock_path "$STATE/$actor.meta")
    fm_task_inbox_lock_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    [ "$(fm_peer_sender "$STATE" "${FM_TASK_ID:-}")" = "$actor" ] || exit 1
    if [ "$actor" = supervisor ]; then
      [ ! -e "$STATE/supervisor.meta" ] && [ ! -L "$STATE/supervisor.meta" ] &&
      [ ! -e "$STATE/services/supervisor.json" ] && [ ! -L "$STATE/services/supervisor.json" ] || exit 1
    fi
    if [ "$verb" = receive ]; then
      [ "$#" -eq 0 ] || exit 1
      fm_task_inbox_receive "$STATE" "$actor"
    else
      [ "$#" -eq 1 ] || exit 1
      fm_task_inbox_ack "$STATE" "$actor" "$1"
    fi ;;
  stats)
    [ "$#" -eq 1 ] && [ -n "${FM_HOME:-}" ] || { echo 'error: stats requires FM_HOME and no arguments' >&2; exit 1; }
    # shellcheck source=bin/fm-message-telemetry-lib.sh
    . "$SCRIPT_DIR/fm-message-telemetry-lib.sh"
    fm_message_stats "${FM_STATE_OVERRIDE:-$FM_HOME/state}" ;;
  read|validate)
    verb=$1; shift
    [ "$#" -eq 1 ] || { echo 'error: expected one record file' >&2; exit 1; }
    # shellcheck source=bin/fm-task-inbox-lib.sh
    . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
    if [ "$verb" = read ]; then fm_task_inbox_message "$1"
    else fm_message_validate < "$1"; fi ;;
  *) echo 'usage: fm-message.sh read|validate <file> | receive | ack <name> | stats | service register|deregister <name> <pid> | send <recipients> [options] <text>' >&2; exit 1 ;;
esac
