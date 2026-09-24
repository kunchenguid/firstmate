#!/usr/bin/env bash
# Serialize heavy validation gates, k3d resets/baselines, and image builds: one
# heavy operation per test host, with one explicit writer for a shared cluster.
# The lock is a kernel flock on a stable host-local file, never a PID record;
# process death releases it automatically. See docs/test-host-gates.md.
# Usage: fm-gate-lock.sh run [--host <ssh-alias|local>] [--name <lock-name>]
#          [--holder <task-id>] [--timeout <seconds>] [--cwd <dir>] -- <command...>
#        fm-gate-lock.sh status [--host <alias|local>] [--name <name>]
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ENTRY="$SCRIPT_DIR/fm-gate-lock-entry.py"
mode=${1:-}
case "$mode" in
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# //'; exit 0 ;;
esac
[ -n "$mode" ] || { echo "usage: $0 run|status [options]" >&2; exit 2; }
shift
host=local name=heavy holder='' timeout=3600 cwd='' command=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) [ "$#" -ge 2 ] || { echo "error: --host needs a value" >&2; exit 2; }; host=$2; shift 2 ;;
    --name) [ "$#" -ge 2 ] || { echo "error: --name needs a value" >&2; exit 2; }; name=$2; shift 2 ;;
    --holder) [ "$#" -ge 2 ] || { echo "error: --holder needs a value" >&2; exit 2; }; holder=$2; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || { echo "error: --timeout needs a value" >&2; exit 2; }; timeout=$2; shift 2 ;;
    --cwd) [ "$#" -ge 2 ] || { echo "error: --cwd needs a value" >&2; exit 2; }; cwd=$2; shift 2 ;;
    --) shift; command=("$@"); break ;;
    *) echo "error: unexpected argument: $1" >&2; exit 2 ;;
  esac
done
case "$host" in local) ;; ''|-*|*[!A-Za-z0-9._-]*) echo "error: invalid SSH alias: $host" >&2; exit 2 ;; esac
case "$timeout" in ''|*[!0-9]*) echo "error: timeout must be a non-negative integer" >&2; exit 2 ;; esac
[ "$mode" = run ] || [ "$mode" = status ] || { echo "error: expected run or status" >&2; exit 2; }
[ "$mode" != run ] || [ "${#command[@]}" -gt 0 ] || { echo "error: run requires -- <command...>" >&2; exit 2; }
[ "$mode" != status ] || [ "${#command[@]}" -eq 0 ] || { echo "error: status does not accept a command" >&2; exit 2; }
exec python3 "$ENTRY" "$mode" "$(python3 - "$host" "$name" "$holder" "$timeout" "$cwd" "${command[@]}" <<'PY'
import base64, json, sys
host, name, holder, timeout, cwd, *command = sys.argv[1:]
print(base64.b64encode(json.dumps({"host":host,"name":name,"holder":holder,"timeout":int(timeout),"cwd":cwd or None,"command":command}).encode()).decode())
PY
)"
