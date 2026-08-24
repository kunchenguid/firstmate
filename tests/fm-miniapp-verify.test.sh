#!/usr/bin/env bash
# tests/fm-miniapp-verify.test.sh - the Telegram Mini App initData check
# (bin/fm-telegram-verify.py), driven through its CLI only.
#
# Every case builds a payload with the signing helper below and runs the REAL
# script over it, asserting the exit code and the reason it prints. Nothing here
# inspects the script's source.
#
# The signing helper lives in this file on purpose. It produces correctly signed
# initData without Telegram, which is exactly what makes it useful for testing
# and exactly what must not ship: a copy of it in bin/ would be a ready recipe
# for forging decisions the moment a token leaked anywhere.
#
# Two cases are worth naming, because they are the failures a real phone found
# and hand-built fixtures did not. Bot API 8.0 added a `signature` field, and
# whether it belongs inside the hash chain is Telegram's call: with-signature
# and without-signature are both accepted, while a forgery is rejected under
# both readings. And the owner check is not redundant with the signature check -
# case "stranger accepted without owner check" is the counter-proof that a
# stranger holding a valid signature of the same bot gets through without it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-telegram-verify.py"
TMP_ROOT=$(fm_test_tmproot fm-miniapp-verify-tests)

TOKEN='123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
OTHER_TOKEN='654321:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
OWNER_ID=6038767113
STRANGER_ID=4711

# --- the signing helper -----------------------------------------------------
#
# build <token> <exclude-signature-from-chain: 0|1> <json-object-of-fields>
# Echoes a urlencoded initData string with a matching hash appended.
BUILDER="$TMP_ROOT/build_init_data.py"
cat >"$BUILDER" <<'PY'
import hashlib
import hmac
import json
import sys
import urllib.parse

token = sys.argv[1]
exclude_signature = sys.argv[2] == "1"
fields = json.loads(sys.argv[3])
# A nested object (user) must go in as the JSON string Telegram sends,
# not as Python's repr of a dict.
fields = {
    k: (json.dumps(v, separators=(",", ":")) if isinstance(v, (dict, list)) else str(v))
    for k, v in fields.items()
}

chain_fields = dict(fields)
if exclude_signature:
    chain_fields.pop("signature", None)
chain = "\n".join(f"{k}={chain_fields[k]}" for k in sorted(chain_fields))
secret = hmac.new(b"WebAppData", token.encode(), hashlib.sha256).digest()
fields["hash"] = hmac.new(secret, chain.encode(), hashlib.sha256).hexdigest()
sys.stdout.write(urllib.parse.urlencode(fields))
PY

build() {  # <token> <exclude-signature> <fields-json>
  python3 "$BUILDER" "$1" "$2" "$3"
}

now_epoch() { date +%s; }

user_json() {  # <id>
  printf '{"id":%s,"first_name":"Captain","language_code":"de"}' "$1"
}

# --- runners ----------------------------------------------------------------
#
# Both call the real CLI. run_verify captures stdout, run_reject captures the
# reason from stderr, so a case asserts what an operator would actually see.

run_verify() {  # <init-data> [extra args...]
  local data=$1
  shift
  FM_TELEGRAM_BOT_TOKEN="$TOKEN" python3 "$VERIFY" --init-data "$data" "$@" 2>"$TMP_ROOT/err"
}

expect_accepted() {  # <label> <init-data> [extra args...]
  local label=$1 data=$2
  shift 2
  local out
  if ! out=$(run_verify "$data" "$@"); then
    fail "$label: expected acceptance, got rejection: $(cat "$TMP_ROOT/err")"
  fi
  printf '%s' "$out"
}

expect_rejected() {  # <label> <expected-reason-substring> <init-data> [extra args...]
  local label=$1 want=$2 data=$3
  shift 3
  local out rc=0
  out=$(run_verify "$data" "$@") || rc=$?
  [ "$rc" -eq 3 ] \
    || fail "$label: expected exit 3 (rejected), got $rc with stdout '$out'"
  grep -q -- "$want" "$TMP_ROOT/err" \
    || fail "$label: reason mismatch: want '$want', got '$(cat "$TMP_ROOT/err")'"
  # A rejection must never hand back accepted fields.
  [ -z "$out" ] || fail "$label: rejection still printed a payload: $out"
}

NOW=$(now_epoch)

# --- 1. a genuine, fresh payload from the owner is accepted -----------------

genuine=$(build "$TOKEN" 0 "{\"auth_date\":$NOW,\"query_id\":\"AAEJRvBnAgAAAAlG8GfqUba-\",\"user\":$(user_json "$OWNER_ID")}")
out=$(expect_accepted "genuine owner payload" "$genuine" --owner-id "$OWNER_ID") || exit 1
printf '%s' "$out" | grep -q '"query_id": "AAEJRvBnAgAAAAlG8GfqUba-"' \
  || fail "genuine owner payload: accepted fields did not carry query_id: $out"
printf '%s' "$out" | grep -q '"_reading"' \
  || fail "genuine owner payload: no reading reported: $out"
pass "a genuine, fresh payload from the owner is accepted"

# --- 2. a field changed after signing breaks the hash -----------------------

tampered=${genuine/AAEJRvBnAgAAAAlG8GfqUba-/AAEJRvBnAgAAAAlG8GfqXXX-}
[ "$tampered" != "$genuine" ] || fail "tampered payload: fixture did not change"
expect_rejected "tampered field" "signature does not match" "$tampered" --owner-id "$OWNER_ID"
pass "a field changed after signing breaks the hash"

# --- 3. a payload signed with a different bot token is rejected -------------

foreign=$(build "$OTHER_TOKEN" 0 "{\"auth_date\":$NOW,\"query_id\":\"Q\",\"user\":$(user_json "$OWNER_ID")}")
expect_rejected "foreign bot token" "signature does not match" "$foreign" --owner-id "$OWNER_ID"
pass "a payload signed with a different bot token is rejected"

# --- 4. a payload without a hash is rejected --------------------------------

nohash="auth_date=$NOW&query_id=Q"
expect_rejected "hash missing" "hash missing" "$nohash" --owner-id "$OWNER_ID"
pass "a payload without a hash is rejected"

# --- 5. a made-up payload is rejected ---------------------------------------

invented="auth_date=$NOW&query_id=Q&user=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$(user_json "$OWNER_ID")")&hash=$(printf 'a%.0s' $(seq 64))"
expect_rejected "invented payload" "signature does not match" "$invented" --owner-id "$OWNER_ID"
pass "a made-up payload is rejected"

# --- 6. an old payload is rejected even though it is correctly signed -------

old=$(build "$TOKEN" 0 "{\"auth_date\":$((NOW - 4000)),\"query_id\":\"Q\",\"user\":$(user_json "$OWNER_ID")}")
expect_rejected "stale payload" "s old (limit" "$old" --owner-id "$OWNER_ID"
pass "an old payload is rejected even though it is correctly signed"

# --- 7. an auth_date in the future is rejected ------------------------------

future=$(build "$TOKEN" 0 "{\"auth_date\":$((NOW + 4000)),\"query_id\":\"Q\",\"user\":$(user_json "$OWNER_ID")}")
expect_rejected "future payload" "lies in the future" "$future" --owner-id "$OWNER_ID"
pass "an auth_date in the future is rejected"

# --- 8. a stranger of the same bot is rejected ------------------------------

stranger=$(build "$TOKEN" 0 "{\"auth_date\":$NOW,\"query_id\":\"Q\",\"user\":$(user_json "$STRANGER_ID")}")
expect_rejected "stranger" "sender is not the owner" "$stranger" --owner-id "$OWNER_ID"
pass "a stranger of the same bot is rejected"

# --- 9. counter-proof: without the owner check that stranger gets through ---

out=$(expect_accepted "stranger without owner check" "$stranger") || exit 1
printf '%s' "$out" | grep -q "$STRANGER_ID" \
  || fail "stranger without owner check: expected the stranger's id in the output: $out"
pass "the owner check is not redundant: without it the same stranger is accepted"

# --- 10/11. both readings of the signature field are accepted ---------------

with_sig=$(build "$TOKEN" 0 "{\"auth_date\":$NOW,\"query_id\":\"Q\",\"signature\":\"ed25519-part\",\"user\":$(user_json "$OWNER_ID")}")
out=$(expect_accepted "signature inside the chain" "$with_sig" --owner-id "$OWNER_ID") || exit 1
printf '%s' "$out" | grep -q '"_reading": "with-signature"' \
  || fail "signature inside the chain: wrong reading reported: $out"
pass "a payload that signs the signature field is accepted"

without_sig=$(build "$TOKEN" 1 "{\"auth_date\":$NOW,\"query_id\":\"Q\",\"signature\":\"ed25519-part\",\"user\":$(user_json "$OWNER_ID")}")
out=$(expect_accepted "signature outside the chain" "$without_sig" --owner-id "$OWNER_ID") || exit 1
printf '%s' "$out" | grep -q '"_reading": "without-signature"' \
  || fail "signature outside the chain: wrong reading reported: $out"
pass "a payload that leaves the signature field out of the chain is accepted"

# --- 12. the second reading rescues no forgery ------------------------------

forged_sig=$(build "$OTHER_TOKEN" 1 "{\"auth_date\":$NOW,\"query_id\":\"Q\",\"signature\":\"ed25519-part\",\"user\":$(user_json "$OWNER_ID")}")
expect_rejected "forgery with signature field" "signature does not match" "$forged_sig" --owner-id "$OWNER_ID"
pass "trying both readings rescues no forgery"

# --- 13. the accepted fields are not polluted by the reading ----------------

out=$(expect_accepted "signature survives acceptance" "$without_sig" --owner-id "$OWNER_ID") || exit 1
printf '%s' "$out" | grep -q '"signature": "ed25519-part"' \
  || fail "signature survives acceptance: the field was dropped from the result: $out"
printf '%s' "$out" | grep -q '"hash"' \
  && fail "signature survives acceptance: the hash leaked into the result: $out"
pass "the accepted fields keep the signature field and drop the hash"

# --- 14. a duplicated field is refused rather than guessed ------------------

dup="${genuine}&query_id=second"
expect_rejected "duplicate field" "duplicate fields" "$dup" --owner-id "$OWNER_ID"
pass "a duplicated field is refused rather than guessed"

# --- 15. an empty payload is rejected ---------------------------------------

expect_rejected "empty payload" "initData missing" "" --owner-id "$OWNER_ID"
pass "an empty payload is rejected"

# --- 16. a blank-valued field stays inside the chain ------------------------
#
# parse_qsl drops blank values unless told otherwise; dropping them computes a
# different chain than Telegram signed and rejects a valid payload.

blank=$(build "$TOKEN" 0 "{\"auth_date\":$NOW,\"query_id\":\"Q\",\"start_param\":\"\",\"user\":$(user_json "$OWNER_ID")}")
expect_accepted "blank-valued field" "$blank" --owner-id "$OWNER_ID" >/dev/null
pass "a blank-valued field stays inside the chain"

# --- 17. a rejection names the field names but never their values -----------

expect_rejected "reason hygiene" "signature does not match" "$tampered" --owner-id "$OWNER_ID"
grep -q 'fields: auth_date,hash,query_id,user' "$TMP_ROOT/err" \
  || fail "reason hygiene: expected the field names in the diagnostics: $(cat "$TMP_ROOT/err")"
grep -q 'Captain' "$TMP_ROOT/err" \
  && fail "reason hygiene: a field value leaked into the diagnostics: $(cat "$TMP_ROOT/err")"
pass "a rejection names the field names but never their values"

# --- 18. a missing token refuses instead of accepting anything --------------

rc=0
FM_TELEGRAM_BOT_TOKEN='' python3 "$VERIFY" --init-data "$genuine" --owner-id "$OWNER_ID" >/dev/null 2>"$TMP_ROOT/err" || rc=$?
[ "$rc" -eq 2 ] || fail "missing token: expected usage exit 2, got $rc"
grep -q 'FM_TELEGRAM_BOT_TOKEN' "$TMP_ROOT/err" \
  || fail "missing token: the reason did not name the missing variable: $(cat "$TMP_ROOT/err")"
pass "a missing token refuses instead of accepting anything"
