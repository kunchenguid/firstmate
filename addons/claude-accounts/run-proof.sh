#!/usr/bin/env bash
# run-proof.sh: the Claude accounts proof for done-done. Runs the real reader against the real muxr
# registry (folder paths go to quota-axi; nothing inside a login folder is opened) into a throwaway
# home, serves the real dashboard from that home and captures the Overview at phone width with
# `done-done look`, plus the fixture test. FM_BIN names a Firstmate checkout's bin/ (the dashboard's helpers).
# The captured reading keeps account names and percentages only, never a folder.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
export FM_BIN=${FM_BIN:?set FM_BIN to a Firstmate checkout bin/}
work=$(mktemp -d)
pid=
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null; rm -rf -- "$work"' EXIT
mkdir -p "$evidence" "$work/home/state"
export FM_HOME=$work/home

bash "$repo/claude-accounts/tests/claude-accounts.test.sh" >"$evidence/test.txt" 2>&1
"$repo/claude-accounts/bin/claude-accounts-quota.sh" >/dev/null
jq 'del(.accounts[].folder)' "$FM_HOME/state/claude-accounts.json" >"$evidence/reading.json"

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
bash "$repo/fleet-dashboard/fm-dashboard.sh" serve --bind 127.0.0.1 --port "$port" >"$work/serve.log" 2>&1 &
pid=$!
until curl -sf "http://127.0.0.1:$port/" >/dev/null; do sleep 1; done
done-done look "http://127.0.0.1:$port/#/overview" --out "$evidence/overview-390.png"
# The look step only sees the first screen; the whole Overview at the same width shows the card itself.
chrome=${DONE_DONE_CHROME:-$(command -v chromium || command -v google-chrome-stable)}
"$chrome" --headless --no-sandbox --user-data-dir="$work/chrome" --window-size=390,2600 --virtual-time-budget=4000 \
  --screenshot="$evidence/overview-full-390.png" "http://127.0.0.1:$port/#/overview" >/dev/null 2>&1
echo "run-proof: reading, test output and the 390px Overview are in $evidence"
