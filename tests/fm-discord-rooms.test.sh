#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/bin/fm-discord-rooms.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-discord-rooms.test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

route_case() {
  local request=$1 text=$2 expected_room=$3 expected_seat=$4 expected_job=$5
  local file="$TMP_ROOT/$request.json" out
  jq -cn --arg request "$request" --arg text "$text" \
    '{request_id:$request,platform:"discord",reply_max_chars:1900,text:$text}' > "$file"
  out=$("$SCRIPT" route "$file")
  [ "$(printf '%s' "$out" | jq -r .room_kind)" = "$expected_room" ] || fail "$request room route"
  [ "$(printf '%s' "$out" | jq -r .seat_slug)" = "$expected_seat" ] || fail "$request seat route"
  [ "$(printf '%s' "$out" | jq -r '.job_id // ""')" = "$expected_job" ] || fail "$request job route"
}

route_case req-fleet 'fleet: status for the rooms' fleet eleusis ''
route_case req-continuum 'continuum-guest: Muse, walk in through Flux' continuum-guest flux ''
route_case req-job 'job/grokbots-discord-d1/ledger: record the quota note' job ledger grokbots-discord-d1
for seat in eleusis flux spur chronicle thor qa-engineer ledger argon; do
  route_case "req-mailbox-$seat" "<@123456789> mailbox/$seat: check the evidence" mailbox "$seat" ''
done
pass 'canonical room addresses resolve to the existing eight-seat roster'

jq -cn '{request_id:"req-x",platform:"x",tweet_id:"discord:channel:message",text:"fleet: no"}' > "$TMP_ROOT/x.json"
if "$SCRIPT" route "$TMP_ROOT/x.json" >/dev/null 2>&1; then
  fail 'an explicit non-Discord platform must win over a legacy Discord id'
fi
jq -cn '{request_id:"req-unknown",platform:"discord",text:"mailbox/ninth-seat: no"}' > "$TMP_ROOT/unknown.json"
if "$SCRIPT" route "$TMP_ROOT/unknown.json" >/dev/null 2>&1; then
  fail 'unknown seats must be refused'
fi
jq -cn '{request_id:"req-empty",platform:"discord",text:"mailbox/flux:   "}' > "$TMP_ROOT/empty.json"
if "$SCRIPT" route "$TMP_ROOT/empty.json" >/dev/null 2>&1; then
  fail 'empty addressed messages must be refused'
fi
if "$SCRIPT" route "$TMP_ROOT/empty.json" extra >/dev/null 2>&1; then
  fail 'extra route arguments must be refused'
fi
pass 'routing fails closed for other platforms, unknown seats, and empty messages'

jq -n '{
  probe_id:"fixture-eight",
  seats:[
    {seat_slug:"eleusis",discord_event_ms:1000,relay_offer_ms:1010,seat_seen_ms:1020,proof:"fixture"},
    {seat_slug:"flux",discord_event_ms:2000,relay_offer_ms:2020,seat_seen_ms:2030,proof:"fixture"},
    {seat_slug:"spur",discord_event_ms:3000,relay_offer_ms:3030,seat_seen_ms:3040,proof:"fixture"},
    {seat_slug:"chronicle",discord_event_ms:4000,relay_offer_ms:4040,seat_seen_ms:4050,proof:"fixture"},
    {seat_slug:"thor",discord_event_ms:5000,relay_offer_ms:5050,seat_seen_ms:5060,proof:"fixture"},
    {seat_slug:"qa-engineer",discord_event_ms:6000,relay_offer_ms:6060,seat_seen_ms:6070,proof:"fixture"},
    {seat_slug:"ledger",discord_event_ms:7000,relay_offer_ms:7070,seat_seen_ms:7080,proof:"fixture"},
    {seat_slug:"argon",discord_event_ms:8000,relay_offer_ms:8080,seat_seen_ms:8090,proof:"fixture"}
  ]
}' > "$TMP_ROOT/latency.json"
latency=$("$SCRIPT" latency "$TMP_ROOT/latency.json")
[ "$(printf '%s' "$latency" | jq -r .proof)" = fixture ] || fail 'fixture receipt must stay labeled fixture'
[ "$(printf '%s' "$latency" | jq '.seats | length')" -eq 8 ] || fail 'latency receipt must cover eight seats'
[ "$(printf '%s' "$latency" | jq '.seats[] | select(.seat_slug == "ledger") | .discord_to_relay_ms')" -eq 70 ] \
  || fail 'latency calculator must measure Discord to Relay'
[ "$(printf '%s' "$latency" | jq '.seats[] | select(.seat_slug == "ledger") | .relay_to_seat_ms')" -eq 10 ] \
  || fail 'latency calculator must measure Relay to seat'
[ "$(printf '%s' "$latency" | jq '.seats[] | select(.seat_slug == "ledger") | .total_ms')" -eq 80 ] \
  || fail 'latency calculator must measure end to end'
pass 'latency receipts calculate both event legs without upgrading fixture proof'

jq '.seats |= .[0:7]' "$TMP_ROOT/latency.json" > "$TMP_ROOT/missing.json"
if "$SCRIPT" latency "$TMP_ROOT/missing.json" >/dev/null 2>&1; then
  fail 'missing seat receipt must be refused'
fi
jq '.seats[7].seat_slug = "ledger"' "$TMP_ROOT/latency.json" > "$TMP_ROOT/duplicate.json"
if "$SCRIPT" latency "$TMP_ROOT/duplicate.json" >/dev/null 2>&1; then
  fail 'duplicate seat receipt must be refused'
fi
jq '.seats[0].seat_seen_ms = 1005' "$TMP_ROOT/latency.json" > "$TMP_ROOT/backward.json"
if "$SCRIPT" latency "$TMP_ROOT/backward.json" >/dev/null 2>&1; then
  fail 'backward timestamp receipt must be refused'
fi
pass 'latency validation requires every seat exactly once and monotonic timestamps'
