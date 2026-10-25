#!/usr/bin/env bash
# Live proof journey for the service, never applying it: the unit's own command (fleet-serve) on a spare loopback port against the real
# home, then curl for the fleet and the old Tickets and Needs routes, plus install.sh's dry-run and rollback dry-run. FM_HOME and LOOKOUT_DIR as run-proof.sh.
set -Eeuo pipefail
: "${FM_HOME:?}" "${LOOKOUT_DIR:?}" "${DONE_DONE_EVIDENCE_ROOT:?}"
here=$(cd "$(dirname "$0")" && pwd)
ev=$DONE_DONE_EVIDENCE_ROOT
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
"$here/fleet-serve" --port "$port" >"$ev/serve.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 100); do curl -fs "http://127.0.0.1:$port/api/fleet" -o "$ev/fleet.json" && break; sleep 0.3; done
{
  python3 -c 'import json; f = json.load(open("'"$ev"'/fleet.json"))["fleet"]; print("Lookout answers with", f["name"], "-", len(f["lanes"]), "lanes,", len(f["homes"]), "homes,", len(f["quota"]), "quota windows")'
  for r in tickets needs backlog measure overview; do curl -s -o /dev/null -w "/$r -> %{http_code} %{redirect_url}\n" "http://127.0.0.1:$port/$r"; done
  curl -s "http://127.0.0.1:$port/" | grep -o '<title>[^<]*'
} >"$ev/spare-port-check.txt"
export CHROME_DEVTOOLS_AXI_SESSION=lookout-service-proof-$$
chrome-devtools-axi open "http://127.0.0.1:$port/?theme=light#/overview" >/dev/null
chrome-devtools-axi resize 390 844 >/dev/null
chrome-devtools-axi wait updated >/dev/null; sleep 1
chrome-devtools-axi screenshot "$ev/spare-port-overview-390.png" >/dev/null
chrome-devtools-axi stop >/dev/null
{ LOOKOUT_DIR=$LOOKOUT_DIR "$here/install.sh" --dry-run; echo; "$here/install.sh" --rollback --dry-run; } >"$ev/install-dry-run.txt" 2>&1
python3 - "$(git -C "$here" rev-parse HEAD)" >"$ev/steps.json" <<'P'
import json, sys
print(json.dumps({'target': {'version': sys.argv[1]}, 'start': 'the real home, read only; the old dashboard still serving; nothing installed',
  'steps': ['serve the new dashboard command on a spare port', 'fetch the fleet and the old Tickets and Needs routes', 'print the install and rollback plans without applying them'],
  'result': 'the spare port serves the real fleet through Lookout, the old routes redirect to sign-off with no token, and the dry runs list the swap and the rollback'}, indent=2))
P
