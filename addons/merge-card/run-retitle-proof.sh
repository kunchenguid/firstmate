#!/usr/bin/env bash
# Seed an isolated sign-off board and drive the retitle command through sign-off-axi.
set -euo pipefail

: "${DONE_DONE_EVIDENCE_ROOT:?done-done must provide its run evidence folder}"
command -v sign-off-axi >/dev/null || { echo 'sign-off-axi is required' >&2; exit 1; }
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }
fixture=$DONE_DONE_EVIDENCE_ROOT/retitle-board
mkdir -p "$fixture/.sign-off"
(
  cd "$fixture"
  SIGN_OFF_HOME="$fixture/.sign-off" sign-off-axi init >/dev/null
)
board=$fixture/.sign-off/decisions.json
message=$fixture/legacy-card.json
jq -n '{contract:1,kind:"evidence",schema:1,key:"merge-acme-retitle-demo-pull-17",title:"Internal change passed its checks",about:"Seeded legacy card",link:"https://github.com/acme/retitle-demo/pull/17",run:{run_id:"20261023T000000Z-retitle01",commit:"0123456789012345678901234567890123456789",outcome:"The fixture title changes",repro:"Run the fixture journey",proof:"done-done run merge-card-retitle",evidence:"seeded fixture"}}' >"$message"
sign-off-axi post "$board" --kind evidence --from "$message" --filer firstmate-merge >/dev/null

dry=$(bash "$(dirname "$0")/retitle-old-cards" "$board")
[[ "$dry" == *'retitle-demo #17: internal change passed its checks'* ]]
[[ $(sign-off-axi list "$board" --json --full | jq '[.decisions[] | select(.title == "Internal change passed its checks" and .dismissed != true)] | length') == 1 ]]

applied=$(bash "$(dirname "$0")/retitle-old-cards" --apply "$board")
[[ "$applied" == *'retitled 1 card(s); skipped 0'* ]]
sign-off-axi list "$board" --json --full | jq -e '
  ([.decisions[] | select(.title == "Internal change passed its checks" and .dismissed == true)] | length) == 1
  and ([.decisions[] | select(.title == "retitle-demo #17: internal change passed its checks" and .dismissed != true and .evidence.run_id == "20261023T000000Z-retitle01")] | length) == 1
' >/dev/null

again=$(bash "$(dirname "$0")/retitle-old-cards" --apply "$board")
[[ "$again" == 'retitled 0 card(s); skipped 0' ]]
jq -n --arg version "$(sign-off-axi --version | head -n 1)" \
  '{target:{version:$version},start:"A seeded sign-off board has one legacy generic evidence card.",steps:["Create an isolated board with sign-off-axi.","Run the retitle command without --apply and confirm it previews the repository and pull request.","Run with --apply and inspect the active and archived cards through sign-off-axi.","Run with --apply again and confirm no new card is added."],result:"The active evidence card names retitle-demo and pull request 17, its proof record remains attached, and the second apply changes nothing."}' >"$DONE_DONE_EVIDENCE_ROOT/steps.json"
printf '%s\n' 'real sign-off-axi retitle journey passed'
