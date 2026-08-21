#!/usr/bin/env bash
# Deterministic addressing and latency-receipt validation for the Grokbots
# Discord room layer carried by the existing myfirstmate Relay.
#
# This script is deliberately not a Discord connector.
# It performs no network access, reads no credential, creates no Discord room,
# and does not deliver a message to a seat.
# The Relay remains the only Discord ingress and reply path.
# The active Grokbot runtime remains the owner of message-to-seat delivery.
#
# Usage:
#   fm-discord-rooms.sh route <relay-mention.json|->
#       Validate a Discord Relay mention and resolve its explicit room address.
#       The mention text, after an optional leading Discord bot mention, must be
#       one of:
#         fleet: <message>
#         continuum-guest: <message>
#         mailbox/<seat-slug>: <message>
#         job/<job-slug>/<seat-slug>: <message>
#       Output is one JSON object with room_kind, seat, seat_slug, job_id, body,
#       and request_id.
#       fleet routes to Eleusis, the roster desk; continuum-guest routes to
#       Flux; mailbox and job addresses route to the named existing seat.
#
#   fm-discord-rooms.sh latency <receipt.json|->
#       Validate one eight-seat probe receipt and calculate its two event legs:
#       Discord event -> Relay offer, then Relay offer -> seat seen.
#       The input owns no credentials and has this public-safe shape:
#         {"probe_id":"...","seats":[
#           {"seat_slug":"eleusis","discord_event_ms":1,
#            "relay_offer_ms":2,"seat_seen_ms":3,"proof":"live"}
#         ]}
#       Every canonical seat must occur exactly once, times are non-negative
#       integer epoch milliseconds in order, and proof is live or fixture.
#       Output is a JSON receipt with calculated leg and total latency values.
#       A fixture receipt can validate the calculator but never proves a live
#       Discord or seat wake.
set -u

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() {
  printf 'fm-discord-rooms: %s\n' "$1" >&2
  exit "${2:-2}"
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die 'jq is required' 1
}

read_input() {
  local source=$1
  if [ "$source" = '-' ]; then
    cat
    return
  fi
  [ -f "$source" ] && [ ! -L "$source" ] \
    || die "input must be a regular non-symlink file: $source"
  cat -- "$source"
}

seat_name() {
  case "$1" in
    eleusis) printf 'Eleusis\n' ;;
    flux) printf 'Flux\n' ;;
    spur) printf 'Spur\n' ;;
    chronicle) printf 'Chronicle\n' ;;
    thor) printf 'Thor\n' ;;
    qa-engineer) printf 'QA Engineer\n' ;;
    ledger) printf 'Ledger\n' ;;
    argon) printf 'Argon\n' ;;
    *) return 1 ;;
  esac
}

route() {
  local source=${1:-}
  local payload platform text request address room_kind seat_slug seat job_id body
  [ -n "$source" ] || die 'route requires a relay mention JSON file or -'
  payload=$(read_input "$source") || exit $?
  printf '%s' "$payload" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
    || die 'route input must be one JSON object'

  platform=$(printf '%s' "$payload" | jq -r '
    def explicit: (.platform // .reply_platform // .target_platform // .source_platform // .provider // "") | ascii_downcase;
    if explicit != "" then
      if explicit == "discord" then "discord" else "" end
    elif ((.tweet_id // "") | startswith("discord:")) then "discord"
    else ""
    end') || die 'could not read route input'
  [ "$platform" = 'discord' ] || die 'route input is not an explicit Discord Relay mention'
  request=$(printf '%s' "$payload" | jq -r '.request_id // ""') || die 'could not read request_id'
  case "$request" in
    ''|.*|*[!A-Za-z0-9._-]*) die 'route input has an unsafe or missing request_id' ;;
  esac
  text=$(printf '%s' "$payload" | jq -r '.text // ""') || die 'could not read mention text'
  [ -n "${text//[[:space:]]/}" ] || die 'route input has no message text'

  # Discord may leave the leading bot mention in text, while relay versions
  # that normalize mentions may remove it. Addressing is identical either way.
  address=$text
  if [[ "$address" =~ ^[[:space:]]*\<@!?[0-9]+\>[[:space:]]*(.*)$ ]]; then
    address=${BASH_REMATCH[1]}
  fi
  address=${address#"${address%%[![:space:]]*}"}

  room_kind=
  seat_slug=
  job_id=
  body=
  if [[ "$address" =~ ^fleet:[[:space:]]*(.*)$ ]]; then
    room_kind=fleet
    seat_slug=eleusis
    body=${BASH_REMATCH[1]}
  elif [[ "$address" =~ ^continuum-guest:[[:space:]]*(.*)$ ]]; then
    room_kind=continuum-guest
    seat_slug=flux
    body=${BASH_REMATCH[1]}
  elif [[ "$address" =~ ^mailbox/([a-z0-9-]+):[[:space:]]*(.*)$ ]]; then
    room_kind=mailbox
    seat_slug=${BASH_REMATCH[1]}
    body=${BASH_REMATCH[2]}
  elif [[ "$address" =~ ^job/([A-Za-z0-9][A-Za-z0-9._-]{0,63})/([a-z0-9-]+):[[:space:]]*(.*)$ ]]; then
    room_kind=job
    job_id=${BASH_REMATCH[1]}
    seat_slug=${BASH_REMATCH[2]}
    body=${BASH_REMATCH[3]}
  else
    die 'unrecognized address; use fleet, continuum-guest, mailbox/<seat>, or job/<job>/<seat>'
  fi

  seat=$(seat_name "$seat_slug") || die "unknown seat slug: $seat_slug"
  [ -n "${body//[[:space:]]/}" ] || die 'addressed message body is empty'
  jq -cn \
    --arg room_kind "$room_kind" \
    --arg seat "$seat" \
    --arg seat_slug "$seat_slug" \
    --arg job_id "$job_id" \
    --arg body "$body" \
    --arg request_id "$request" \
    '{room_kind:$room_kind,seat:$seat,seat_slug:$seat_slug,
      job_id:(if $job_id == "" then null else $job_id end),
      body:$body,request_id:$request_id}'
}

latency() {
  local source=${1:-}
  local payload
  [ -n "$source" ] || die 'latency requires a receipt JSON file or -'
  payload=$(read_input "$source") || exit $?
  printf '%s' "$payload" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
    || die 'latency input must be one JSON object'

  printf '%s' "$payload" | jq -e '
    def expected: ["eleusis","flux","spur","chronicle","thor","qa-engineer","ledger","argon"];
    def integer_nonnegative: type == "number" and floor == . and . >= 0;
    (.probe_id | type == "string" and length > 0)
    and (.seats | type == "array" and length == 8)
    and (([.seats[].seat_slug] | sort) == (expected | sort))
    and (all(.seats[];
      (.seat_slug | type == "string")
      and (.discord_event_ms | integer_nonnegative)
      and (.relay_offer_ms | integer_nonnegative)
      and (.seat_seen_ms | integer_nonnegative)
      and (.discord_event_ms <= .relay_offer_ms)
      and (.relay_offer_ms <= .seat_seen_ms)
      and (.proof == "live" or .proof == "fixture")))
  ' >/dev/null 2>&1 || die 'invalid latency receipt: require all eight unique seats, ordered integer times, and live|fixture proof'

  printf '%s' "$payload" | jq '
    def display:
      {"eleusis":"Eleusis","flux":"Flux","spur":"Spur",
       "chronicle":"Chronicle","thor":"Thor",
       "qa-engineer":"QA Engineer","ledger":"Ledger","argon":"Argon"}[.];
    {
      probe_id,
      proof: (if all(.seats[]; .proof == "live") then "live" else "fixture" end),
      seats: [.seats[] | {
        seat: (.seat_slug | display),
        seat_slug,
        proof,
        discord_to_relay_ms: (.relay_offer_ms - .discord_event_ms),
        relay_to_seat_ms: (.seat_seen_ms - .relay_offer_ms),
        total_ms: (.seat_seen_ms - .discord_event_ms)
      }]
    }'
}

require_jq
case "${1:-}" in
  route)
    shift
    [ "$#" -eq 1 ] || die 'route requires exactly one relay mention JSON file or -'
    route "${1:-}"
    ;;
  latency)
    shift
    [ "$#" -eq 1 ] || die 'latency requires exactly one receipt JSON file or -'
    latency "${1:-}"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
