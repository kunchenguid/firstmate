#!/usr/bin/env bash
# Proof journey: render the real Insights "Why work waits now" card at 390px from real fleet data.
# DASH_HOME is a Firstmate home to read; FLOW_JSON is a saved real `fm-flow.sh --json --capacity` run of it
# (a saved run keeps the proof repeatable while the live records move); FM_BIN is a Firstmate bin/.
set -euo pipefail
: "${DASH_HOME:?}" "${FLOW_JSON:?}" "${FM_BIN:?}" "${DONE_DONE_EVIDENCE_ROOT:?}"
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
for f in "$FM_BIN"/*; do ln -s "$f" "$tmp/${f##*/}"; done
rm -- "$tmp/fm-flow.sh"
printf '#!/bin/bash\ncat %q\n' "$FLOW_JSON" >"$tmp/fm-flow.sh"
export FM_BIN=$tmp FM_HOME=$DASH_HOME
bash "$here/fm-dashboard.sh" build >/dev/null
timeout 240 bash "$here/fm-dashboard.sh" serve --port 0 >"$tmp/serve.log" 2>&1 &
url=
for _ in $(seq 50); do
  url=$(sed -n 's|^serving \(http[^ ]*\)|\1|p' "$tmp/serve.log")
  [ -z "$url" ] || break
  sleep 0.2
done
[ -n "$url" ] || { cat "$tmp/serve.log" >&2; exit 1; }
chrome-devtools-axi open "${url}#/insights" >/dev/null
chrome-devtools-axi resize 390 2500 >/dev/null
sleep 4
chrome-devtools-axi eval '(() => { const h = [...document.querySelectorAll("h2")].find(e => e.textContent.includes("Why work waits")); return JSON.stringify({ open: document.querySelectorAll(".i-stat")[4].innerText, card: h.parentElement.innerText }) })()' >"$DONE_DONE_EVIDENCE_ROOT/card.txt"
chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/after.png" >/dev/null
chrome-devtools-axi stop >/dev/null
