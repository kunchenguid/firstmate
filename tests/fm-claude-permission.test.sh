#!/usr/bin/env bash
# Claude permission-request events through the busy writer and durable watcher.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-permission)
EV="$ROOT/bin/fm-busy-event.sh"
PAYLOAD='{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"cat example"}}'

request() {
  printf '%s' "$PAYLOAD" | "$EV" permission-request "$1" t1 --gen "$2"
}

watch_checkpoint() {
  local state=$1 fakebin=$2
  PATH="$fakebin:$PATH" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" \
    FM_BACKEND=tmux FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 8
}

test_request_is_durable_and_idempotent() {
  local dir state fakebin gen output before key delivered
  dir=$(make_case permission)
  state="$dir/state"; fakebin="$dir/fakebin"
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host-off"
  gen=$("$EV" arm "$state" t1) || fail 'arm failed'
  before=$(cat "$state/t1.busy-state")
  output=$(request "$state" "$gen") || fail 'permission request failed'
  [ -z "$output" ] || fail 'permission request returned a decision to Claude'
  request "$state" "$gen" || fail 'duplicate request failed'
  [ "$(wc -l < "$state/t1.status" | tr -d ' ')" = 1 ] || fail 'duplicate request wrote a second status'
  [ "$(cat "$state/t1.busy-state")" = "$before" ] || fail 'request changed busy state'
  grep -q 'needs-decision .*Claude permission prompt for Bash.*never answer with keys' "$state/t1.status" \
    || fail 'request did not route the security decision'
  output=$(watch_checkpoint "$state" "$fakebin") || fail "watcher did not surface the request: $output"
  assert_contains "$output" "signal: $state/t1.status" 'request did not use the signal path'
  grep -q "$(printf '\tsignal\tt1.status\tneeds-decision:')" "$state/.wake-queue" \
    || fail 'request did not retain decision routing in the durable queue'
  key=$(sed -n 's/.*\[key=\([^]]*\)\].*/\1/p' "$state/t1.status")
  printf 'resolved [at=%s] [key=%s]: test decision recorded\n' "$(date +%s)" "$key" >> "$state/t1.status"
  cp "$state/t1.status" "$dir/expected.status"
  request "$state" "$gen" || fail 'repeated handled event failed'
  cmp -s "$state/t1.status" "$dir/expected.status" || fail 'handled event reopened the decision'
  delivered=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_print_deduped "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.wake-queue")
  [ "$(printf '%s\n' "$delivered" | awk -F '\t' '$3 == "signal" && $4 == "t1.status" { n++ } END { print n+0 }')" = 1 ] \
    || fail "duplicate request delivered a second wake: $delivered"
  pass 'one permission request produces one durable decision signal without answering or changing busy state'
}

test_request_identity_and_generation() {
  local dir state gen next payload
  dir=$(make_case identities); state="$dir/state"
  gen=$("$EV" arm "$state" t1)
  printf 'first request\n' > "$dir/transcript"
  payload=$(jq -cn --arg transcript "$dir/transcript" '{hook_event_name:"PermissionRequest",session_id:"s1",tool_name:"Bash",tool_input:{command:"same"},transcript_path:$transcript}')
  printf '%s' "$payload" | "$EV" permission-request "$state" t1 --gen "$gen" || fail 'first request failed'
  printf 'second request\n' >> "$dir/transcript"
  printf '%s' "$payload" | "$EV" permission-request "$state" t1 --gen "$gen" || fail 'next request failed'
  [ "$(wc -l < "$state/t1.status" | tr -d ' ')" = 2 ] || fail 'a later identical tool request was suppressed'
  next=$("$EV" arm "$state" t1)
  if request "$state" "$gen" 2>/dev/null; then fail 'old incarnation was accepted'; fi
  [ "$(wc -l < "$state/t1.status" | tr -d ' ')" = 2 ] || fail 'old incarnation wrote a decision'
  request "$state" "$next" || fail 'replacement incarnation was suppressed'
  if printf '{}' | "$EV" permission-request "$state" t1 --gen "$next" 2>/dev/null; then
    fail 'malformed permission event was accepted'
  fi
  [ "$(wc -l < "$state/t1.status" | tr -d ' ')" = 3 ] || fail 'invalid event changed status'
  pass 'later requests and replacement incarnations remain distinct; stale and malformed events are refused'
}

test_request_is_durable_and_idempotent
test_request_identity_and_generation
