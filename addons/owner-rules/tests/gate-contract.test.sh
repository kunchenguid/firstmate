#!/usr/bin/env bash
# Contract test: sign-off-axi's real board writer preserves the merge-card commit consumed by the gate.
set -eu
if ! command -v sign-off-axi >/dev/null 2>&1; then echo 'SKIP gate contract: sign-off-axi is not installed'; exit 0; fi
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
home=$work/home
board=$work/board/.sign-off/decisions.json
mkdir -p "$work/board" "$home/config" "$home/data/lane/.done-done/runs" "$work/bin"
sign-off-axi init "$work/board" --agent pi >/dev/null 2>&1 || :
[ -s "$board" ] || printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$board"
head=$(git -C "$here/../.." rev-parse HEAD)
pr=https://github.com/owner/repo/pull/9
key=merge-owner-repo-pull-9
printf '{"schema":1,"exit":0,"dirty":false,"commit":"%s","files":["proof.png"],"run_id":"contract-run"}\n' "$head" > "$home/data/lane/.done-done/runs/run.json"
printf 't\t%s\t%s\tpass\tok\n' "$pr" "$head" > "$home/data/checks-gate.log"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/gh"
chmod +x "$work/bin/gh"
"$(dirname "$here")/install.sh" "$home" >/dev/null
# Ask the installed CLI to write a normal evidence item, then overlay the same run shape merge-card posts.
# Real sign-off-axi validates and writes the merge-card-shaped evidence contract to this private board.
jq -n --arg k "$key" --arg c "$head" '{contract:1,schema:1,kind:"evidence",key:$k,title:"Contract proof",about:"Gate commit contract.",link:"https://github.com/owner/repo/pull/9",run:{run_id:"contract-run",commit:$c,outcome:"Contract proof",repro:"see the merge note",proof:"done-done run contract-run",evidence:"proof.png"}}' > "$work/card.json"
sign-off-axi post "$board" --kind evidence --from "$work/card.json" --filer firstmate-merge
if ! jq -e --arg k "$key" --arg c "$head" 'any(.items[]; .key==$k and .kind=="evidence" and .evidence.commit==$c)' "$board" >/dev/null; then echo 'FAIL: sign-off-axi card lost merge-card run.commit'; exit 1; fi
run_gate() {
  printf '{"schema":1,"exit":0,"dirty":false,"commit":"%s","files":["proof.png"],"run_id":"contract-run"}\n' "$1" > "$home/data/lane/.done-done/runs/run.json"
  printf 't\t%s\t%s\tpass\tok\n' "$pr" "$1" > "$home/data/checks-gate.log"
  PATH="$work/bin:$PATH" FM_HOME="$home" FM_FLEET_BOARD="$board" "$home/config/merge-gate" lane - "$1" "$pr"
}
run_gate "$head" || { echo 'FAIL: gate refused matching sign-off card commit'; exit 1; }
if run_gate 0000000000000000000000000000000000000000 >/dev/null 2>&1; then echo 'FAIL: gate accepted mismatched commit'; exit 1; fi
echo 'PASS: gate reads real sign-off-axi Evidence card commit'
# A canary list restricts this new refusal to the named home; a future waiver disables it until expiry.
printf '%s\n' "$work/not-this-home" > "$home/config/owner-rules-canary"
run_gate 0000000000000000000000000000000000000000 >/dev/null || { echo 'FAIL: non-canary behavior changed'; exit 1; }
printf '%s\n' "$home" > "$home/config/owner-rules-canary"
printf '2999-01-01T00:00Z\n' > "$home/config/owner-rules-canary-waiver"
run_gate 0000000000000000000000000000000000000000 >/dev/null || { echo 'FAIL: active waiver did not apply'; exit 1; }
echo 'PASS: canary and expiring waiver'
