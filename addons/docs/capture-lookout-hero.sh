#!/usr/bin/env bash
# Capture Lookout Overview for the README hero with real lane/merge history.
# Either:
#   LOOKOUT_URL=http://host:4390  (already-running Lookout with a live fleet), or
#   FM_HOME + LOOKOUT_DIR         (serve lookout-adapter into a Lookout clone).
# Always requires DONE_DONE_EVIDENCE_ROOT. Refuses Sample fleet and empty history.
set -Eeuo pipefail
: "${DONE_DONE_EVIDENCE_ROOT:?}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

export CHROME_DEVTOOLS_AXI_SESSION="readme-lookout-hero-$$"
tmp=$(mktemp -d)
pids=()
base=
cleanup() {
  chrome-devtools-axi stop >/dev/null 2>&1 || true
  for p in "${pids[@]+"${pids[@]}"}"; do kill "$p" 2>/dev/null || true; done
  rm -rf -- "$tmp"
}
trap cleanup EXIT

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

if [ -n "${LOOKOUT_URL:-}" ]; then
  base=${LOOKOUT_URL%/}
else
  : "${FM_HOME:?set FM_HOME or LOOKOUT_URL}" "${LOOKOUT_DIR:?set LOOKOUT_DIR or LOOKOUT_URL}"
  adapter=$root/lookout-adapter/lookout-firstmate
  [ -x "$adapter" ] || { echo "capture-lookout-hero: missing $adapter" >&2; exit 1; }
  [ -f "$LOOKOUT_DIR/bin/lookout.js" ] || { echo "capture-lookout-hero: LOOKOUT_DIR has no bin/lookout.js: $LOOKOUT_DIR" >&2; exit 1; }
  ap=$(free_port); lp=$(free_port)
  "$adapter" --home "$FM_HOME" --serve --port "$ap" >"$tmp/adapter.log" 2>&1 & pids+=("$!")
  (cd "$LOOKOUT_DIR" && exec node bin/lookout.js serve --adapter "http://127.0.0.1:$ap/fleet.json" --port "$lp" >"$tmp/lookout.log" 2>&1) & pids+=("$!")
  base="http://127.0.0.1:$lp"
fi

for _ in $(seq 80); do
  curl -fs "$base/api/fleet" -o "$tmp/api.json" && break
  sleep 0.25
done
[ -s "$tmp/api.json" ] || { echo "capture-lookout-hero: Lookout never answered at $base" >&2; exit 1; }

python3 - "$tmp/api.json" "$DONE_DONE_EVIDENCE_ROOT/document.txt" <<'PY'
import json, sys
fleet = json.load(open(sys.argv[1]))["fleet"]
name = fleet.get("name") or ""
lists = {k: len(v) for k, v in fleet.items() if isinstance(v, list)}
open(sys.argv[2], "w").write(
    f"{name} | lists: " + ", ".join(f"{k} {n}" for k, n in lists.items()) + "\n"
)
assert name and name != "Sample fleet", f"expected a live fleet name, got {name!r}"
assert lists.get("lanes", 0) >= 1, "expected lanes"
assert lists.get("history", 0) >= 10, f"expected real lane history (>=10), got {lists.get('history', 0)}"
assert lists.get("merges", 0) >= 10, f"expected real merges (>=10), got {lists.get('merges', 0)}"
PY

chrome-devtools-axi selectpage 1 >/dev/null 2>&1 || true
for theme in light dark; do
  for width in 390 1280; do
    chrome-devtools-axi open "$base/?theme=$theme#/overview" >/dev/null
    chrome-devtools-axi resize "$width" 844 >/dev/null
    chrome-devtools-axi wait updated >/dev/null
    sleep 1.5
    chrome-devtools-axi eval 'document.body.innerText' >"$DONE_DONE_EVIDENCE_ROOT/hero-$width-$theme.txt"
    if grep -qF 'Sample fleet' "$DONE_DONE_EVIDENCE_ROOT/hero-$width-$theme.txt"; then
      echo "capture-lookout-hero: Sample fleet on Overview at ${width} ${theme}" >&2
      exit 1
    fi
    if grep -qF 'This source sends no lane history' "$DONE_DONE_EVIDENCE_ROOT/hero-$width-$theme.txt"; then
      echo "capture-lookout-hero: empty lane history on Overview at ${width} ${theme}" >&2
      exit 1
    fi
    chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/hero-$width-$theme.png" >/dev/null
  done
done

python3 - "$(git -C "$root" rev-parse HEAD)" "${LOOKOUT_URL:-local-serve}" >"$DONE_DONE_EVIDENCE_ROOT/steps.json" <<'PY'
import json, sys
print(json.dumps({
    "target": {"version": sys.argv[1]},
    "start": f"Lookout Overview at {sys.argv[2]} with a live Firstmate fleet (real history and merges).",
    "steps": [
        "Open Lookout Overview in light and dark at 390 and 1280.",
        "Confirm the fleet is not Sample fleet and lane history is present.",
        "Capture Overview frames for the README hero."
    ],
    "result": "Overview shows live lanes, merge charts, and quota with real history; captures are hero-*-{light,dark}.png."
}, indent=2))
PY
