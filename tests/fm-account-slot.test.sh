#!/usr/bin/env bash
# Public-interface behavior tests for home-local account slots.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-account-slot-tests)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
CALLS="$TMP_ROOT/calls"
mkdir -p "$HOME_DIR/config" "$FAKEBIN" "$HOME_DIR/profiles/claude-a" "$HOME_DIR/profiles/claude-b" \
  "$HOME_DIR/profiles/codex-a" "$HOME_DIR/profiles/codex-b"
chmod 700 "$HOME_DIR/config" "$HOME_DIR/profiles" "$HOME_DIR/profiles/"*
for credential in \
  "$HOME_DIR/profiles/claude-a/.credentials.json" \
  "$HOME_DIR/profiles/claude-b/.credentials.json" \
  "$HOME_DIR/profiles/codex-a/auth.json" \
  "$HOME_DIR/profiles/codex-b/auth.json"; do
  printf '{}\n' > "$credential"
  chmod 600 "$credential"
done

write_registry() {
  cat > "$HOME_DIR/config/account-slots.json" <<JSON
{
  "version": 1,
  "slots": {
    "claude-a": {"harness":"claude","storePath":"$HOME_DIR/profiles/claude-a","expectedAccountId":"claude-account-a"},
    "claude-b": {"harness":"claude","storePath":"$HOME_DIR/profiles/claude-b","expectedAccountId":"claude-account-b"},
    "codex-a": {"harness":"codex","storePath":"$HOME_DIR/profiles/codex-a","expectedAccountId":"codex-account-a"},
    "codex-b": {"harness":"codex","storePath":"$HOME_DIR/profiles/codex-b","expectedAccountId":"codex-account-b"}
  }
}
JSON
  chmod 600 "$HOME_DIR/config/account-slots.json"
}

write_dispatch() {
  cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{"default":[
  {"harness":"claude","model":"sonnet","effort":"high","accountSlots":["claude-a","claude-b"]},
  {"harness":"codex","model":"gpt","effort":"high","accountSlots":["codex-a","codex-b"]}
]}
JSON
  chmod 600 "$HOME_DIR/config/crew-dispatch.json"
}

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  advertised=
  for flag in --provider --full --json --no-credential-refresh; do
    [ "$flag" != "${FAKE_OMIT_FLAG:-}" ] || continue
    advertised="${advertised:+$advertised }$flag"
  done
  case "${FAKE_HELP_SHAPE:-list}" in
    synopsis)
      bracketed=
      for flag in $advertised; do bracketed="${bracketed:+$bracketed }[$flag]"; done
      printf '%s\n' "usage: quota-axi $bracketed"
      ;;
    alternation) printf '%s\n' "quota-axi (${advertised// /|})" ;;
    indented) printf '%s\n' "options:"; for flag in $advertised; do printf '  %s=VALUE\n' "$flag"; done ;;
    longer) printf '%s\n' "flags: ${advertised//--json/--json-lines}" ;;
    *) printf '%s\n' "flags: $advertised" ;;
  esac
  exit 0
fi
if [ "${1:-}" = --version ]; then printf '%s\n' 'quota-axi 0.1.42'; exit 0; fi
printf 'argv=%s|claude=%s|codex=%s|anthropic=%s|openai=%s\n' "$*" "${CLAUDE_CONFIG_DIR-}" "${CODEX_HOME-}" "${ANTHROPIC_API_KEY-}" "${OPENAI_API_KEY-}" >> "${FAKE_CALLS:?}"
provider=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --provider ]; then provider=$2; shift 2; else shift; fi
done
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# The published producer stamps generatedAt with milliseconds.
[ -z "${FAKE_SUBSECOND_GENERATED_AT:-}" ] || now=${now%Z}.579Z
case "$provider" in
  claude)
    account=claude-account-a
    email=private@example.invalid
    case "${CLAUDE_CONFIG_DIR-}" in *claude-b) account=claude-account-b ;; esac
    attempt=${FAKE_ATTEMPT_SOURCE:-oauth-file}
    ;;
  codex)
    account=codex-account-a
    case "${CODEX_HOME-}" in *codex-b) account=codex-account-b ;; esac
    attempt=oauth
    ;;
esac
selected_store=${CLAUDE_CONFIG_DIR:-${CODEX_HOME:-}}
if [ -n "${FAKE_UNAVAILABLE_SLOT:-}" ]; then
  case "$selected_store" in *"$FAKE_UNAVAILABLE_SLOT") FAKE_MODE=mismatch ;; esac
fi
case "${FAKE_MODE:-ok}" in
  mismatch) account=wrong-account ;;
  wrong-source) attempt=pi ;;
  stale) stale=true ;;
esac
stale=${stale:-false}
status=fresh
[ "$stale" = false ] || status=stale
valid_account=$account
attempts=${FAKE_ATTEMPTS:-"[{\"source\":\"$attempt\",\"status\":\"success\",\"path\":\"/private/credential\"}]"}
emit_document() {
local identity="\"accountId\":\"$account\","
case "${FAKE_MODE:-ok}" in
  no-account-id) identity= ;;
  numeric-account-id) identity='"accountId":42,' ;;
esac
cat <<JSON
{"generatedAt":"$now","schemaVersion":5,"providers":[{"provider":"$provider","account":{$identity"email":"${email:-private@example.invalid}","organization":"private","identityStatus":"verified"},"attempts":$attempts,"state":{"status":"$status","stale":$stale},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":75,"runway":{"status":"through_reset"},"selection":{"status":"known","spendPriority":-0.25}}]}}]}
JSON
}
if [ "${FAKE_MODE:-ok}" = invalid-then-valid ]; then
  account=wrong-account
  emit_document
  account=$valid_account
  emit_document
else
  emit_document
fi
SH
chmod +x "$FAKEBIN/quota-axi"

# Claude names its keychain item after the store it was signed in under. This
# stub answers only for the service FAKE_KEYCHAIN_STORE hashes to, so a lookup
# that fell back to the ambient unsuffixed item finds nothing.
cat > "$FAKEBIN/security" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_KEYCHAIN_STORE:-}" ] || exit 44
service=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -w) exit 1 ;;
    -s) service=$2; shift 2 ;;
    *) shift ;;
  esac
done
digest=$(printf '%s' "$FAKE_KEYCHAIN_STORE" | shasum -a 256)
[ "$service" = "Claude Code-credentials-${digest:0:8}" ] || exit 44
exit 0
SH
chmod +x "$FAKEBIN/security"

write_registry
write_dispatch
: > "$CALLS"

PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" validate >/dev/null || fail "valid four-slot registry and dispatch were refused"
pass "validates a strict four-slot registry and dispatch cross-references"

# Only one rule matches at intake, so the same profile reappearing in an
# unrelated rule never produces a two-candidate choice. Ambiguity is a repeated
# effective tuple inside one candidate set: one rule's own `use` array, or
# `default`.
cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{"rules":[
  {"when":"big feature","use":{"harness":"claude","model":"sonnet","effort":"high","accountSlots":["claude-a","claude-b"]}},
  {"when":"risky refactor","use":{"harness":"claude","model":"sonnet","effort":"high","accountSlots":["claude-a","claude-b"]}}
],"default":[{"harness":"claude","model":"sonnet","effort":"high","accountSlots":["claude-a","claude-b"]}]}
JSON
chmod 600 "$HOME_DIR/config/crew-dispatch.json"
PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" validate >/dev/null \
  || fail "the same slotted profile in two unrelated rules was reported as an ambiguous duplicate"

cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{"rules":[{"when":"big feature","use":[
  {"harness":"claude","model":"sonnet","effort":"high","accountSlots":["claude-a","claude-b"]},
  {"harness":"claude","model":"sonnet","effort":"high","accountSlots":["claude-a"]}
]}]}
JSON
chmod 600 "$HOME_DIR/config/crew-dispatch.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/one-set-duplicate.err"; then
  fail "one candidate set offering claude-a twice was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/one-set-duplicate.err")" "duplicate effective dispatch tuple: claude|sonnet|high|claude-a" \
  "within-candidate-set duplicate refusal was unclear"
write_dispatch
pass "duplicate effective tuples are ambiguous within one candidate set, not across unrelated rules"

out=$(PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" ANTHROPIC_API_KEY=hostile CODEX_HOME=/hostile \
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" probe claude-a) \
  || fail "valid Claude slot probe failed"
assert_contains "$out" '"accountSlot":"claude-a"' "sanitized output omitted the logical slot"
assert_contains "$out" '"spendPriority":-0.25' "sanitized output omitted quota ranking evidence"
assert_not_contains "$out" 'claude-account-a' "sanitized output leaked account identity"
assert_not_contains "$out" 'private@example.invalid' "sanitized output leaked email"
assert_not_contains "$out" '/private/credential' "sanitized output leaked a credential path"
call=$(cat "$CALLS")
assert_contains "$call" 'argv=--provider claude --full --json --no-credential-refresh' "probe argv did not request single-provider full JSON without refresh"
assert_contains "$call" "claude=$HOME_DIR/profiles/claude-a|codex=|anthropic=|openai=" "Claude probe did not isolate the selected store and clear competing selectors"
pass "probes Claude through one isolated profile and emits only sanitized quota evidence"

: > "$CALLS"
PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" CLAUDE_CONFIG_DIR=/hostile OPENAI_API_KEY=hostile \
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" probe codex-a >/dev/null \
  || fail "valid Codex slot probe failed"
call=$(cat "$CALLS")
assert_contains "$call" "claude=|codex=$HOME_DIR/profiles/codex-a|anthropic=|openai=" "Codex probe did not isolate the selected store and clear competing selectors"
pass "probes Codex through one isolated profile"

PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" probe claude-b >/dev/null \
  || fail "second Claude slot probe failed"
PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" probe claude-a >/dev/null \
  || fail "first Claude slot probe failed"
pass "matches each slot against its own configured expectedAccountId"

# Regression: quota-axi stamps generatedAt with milliseconds
# ("2026-09-16T02:08:27.579Z"). Before the freshness gate normalized that, every
# real document was read as stale and every slot dropped out of routing.
out=$(PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_SUBSECOND_GENERATED_AT=1 \
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" probe-all claude-a codex-a) \
  || fail "slots were refused for a millisecond generatedAt the real producer always emits"
assert_contains "$out" '"accountSlot":"claude-a"' "Claude slot dropped out on a millisecond generatedAt"
assert_contains "$out" '"accountSlot":"codex-a"' "Codex slot dropped out on a millisecond generatedAt"
assert_not_contains "$out" '"status":"unavailable"' "a fresh millisecond-stamped document was reported unavailable"
pass "accepts the millisecond generatedAt the published producer emits"

mv "$HOME_DIR/profiles/claude-b/.credentials.json" "$TMP_ROOT/keychain-only-credential"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-account-slot.sh" probe claude-b >/dev/null 2>"$TMP_ROOT/no-credential.err"; then
  fail "a Claude slot with no credential anywhere was treated as available"
fi
assert_contains "$(cat "$TMP_ROOT/no-credential.err")" "no vendor-managed credential" "absent-credential refusal was unclear"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_KEYCHAIN_STORE="$HOME_DIR/profiles/claude-a" \
    FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" probe claude-b >/dev/null 2>&1; then
  fail "claude-b accepted another store's keychain item"
fi
: > "$CALLS"
out=$(PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_ATTEMPT_SOURCE=keychain \
  FAKE_KEYCHAIN_STORE="$HOME_DIR/profiles/claude-b" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" probe claude-b) \
  || fail "a Claude slot signed in to its own store-scoped keychain item was reported unavailable"
assert_contains "$out" '"accountSlot":"claude-b"' "keychain-backed slot emitted no sanitized evidence"
assert_contains "$(cat "$CALLS")" "claude=$HOME_DIR/profiles/claude-b" "keychain-backed probe did not isolate the selected store"
mv "$TMP_ROOT/keychain-only-credential" "$HOME_DIR/profiles/claude-b/.credentials.json"
chmod 600 "$HOME_DIR/profiles/claude-b/.credentials.json"
pass "a Claude slot is available through its own store-scoped keychain item, never the ambient one"

if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-account-slot.sh" probe-all >/dev/null 2>"$TMP_ROOT/probe-all-noargs.err"; then
  fail "probe-all without slot IDs was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/probe-all-noargs.err")" "usage: fm-account-slot.sh probe-all <slot>..." \
  "probe-all did not require the slot IDs the decision references"
pass "probe-all probes only the slots it is asked for"

mv "$HOME_DIR/profiles/codex-b/auth.json" "$TMP_ROOT/signed-out-credential"
PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" validate >/dev/null \
  || fail "one signed-out slot invalidated the whole registry"
PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" probe claude-a >/dev/null \
  || fail "one signed-out slot blocked an unrelated healthy slot"
: > "$CALLS"
out=$(PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" probe-all codex-b codex-a) \
  || fail "a signed-out slot stopped probe-all"
printf '%s' "$out" | jq -e '
  .slots | length == 2 and
  .[0].accountSlot == "codex-b" and .[0].availability.status == "unavailable" and
  (.[0].availability.reason | test("no vendor-managed credential")) and
  .[1].accountSlot == "codex-a"
' >/dev/null || fail "a signed-out slot was not reported as that slot being unavailable with a stated reason"
assert_equals 1 "$(wc -l < "$CALLS" | tr -d ' ')" "probe-all probed a slot with no vendor credential"
mv "$TMP_ROOT/signed-out-credential" "$HOME_DIR/profiles/codex-b/auth.json"
chmod 600 "$HOME_DIR/profiles/codex-b/auth.json"
pass "treats a missing vendor credential as one unavailable slot, not an invalid registry"

chmod 644 "$HOME_DIR/profiles/codex-b/auth.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/insecure-credential.err"; then
  fail "a group/world-readable vendor credential was accepted as valid configuration"
fi
assert_contains "$(cat "$TMP_ROOT/insecure-credential.err")" "slot 'codex-b' credential file" "insecure credential refusal did not name the offending slot"
assert_contains "$(cat "$TMP_ROOT/insecure-credential.err")" "no group or world permissions" "insecure credential refusal did not name the permission problem"
: > "$CALLS"
if out=$(PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-account-slot.sh" probe-all codex-b codex-a 2>"$TMP_ROOT/insecure-probe-all.err"); then
  fail "probe-all hid an insecure vendor credential behind per-slot unavailability: $out"
fi
assert_contains "$(cat "$TMP_ROOT/insecure-probe-all.err")" "slot 'codex-b' credential file" "probe-all refusal did not name the misconfigured credential"
assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" "probe-all probed a provider before refusing insecure credential configuration"
chmod 600 "$HOME_DIR/profiles/codex-b/auth.json"
pass "reports a present but insecure vendor credential as configuration, not silent unavailability"

jq '.slots["codex-trailing-"]=.slots["codex-b"] | del(.slots["codex-b"])' "$HOME_DIR/config/account-slots.json" > "$TMP_ROOT/trailing-registry"
mv "$TMP_ROOT/trailing-registry" "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"
jq '.default[1].accountSlots=["codex-a","codex-trailing-"]' "$HOME_DIR/config/crew-dispatch.json" > "$TMP_ROOT/trailing-dispatch"
mv "$TMP_ROOT/trailing-dispatch" "$HOME_DIR/config/crew-dispatch.json"
chmod 600 "$HOME_DIR/config/crew-dispatch.json"
PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" validate >/dev/null \
  || fail "the registry validator rejected a slot ID its own slug rule accepts"
out=$(PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" probe-all codex-trailing-) \
  || fail "a slot ID the validator accepts could not be probed"
printf '%s' "$out" | jq -e '.slots | length == 1 and .[0].accountSlot == "codex-trailing-" and .[0].providers[0].provider == "codex"' \
  >/dev/null || fail "a healthy slot was dropped from routing by a second slug rule"
write_registry
write_dispatch
pass "one slug rule governs every configured slot ID"

: > "$CALLS"
PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" probe-all claude-a claude-a codex-a >/dev/null \
  || fail "deduplicated probe-all failed"
assert_equals 2 "$(wc -l < "$CALLS" | tr -d ' ')" "probe-all did not invoke each distinct slot exactly once"
pass "deduplicates slot probes within one decision"

: > "$CALLS"
out=$(PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_UNAVAILABLE_SLOT=claude-a FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" probe-all claude-a codex-a) \
  || fail "one unavailable slot prevented later healthy probes"
assert_equals 2 "$(wc -l < "$CALLS" | tr -d ' ')" "mixed probe-all did not probe every selected slot"
printf '%s' "$out" | jq -e '
  .slots | length == 2 and
  .[0].accountSlot == "claude-a" and .[0].availability.status == "unavailable" and
  (.[0].availability.reason | type) == "string" and (.[0].availability.reason | length) > 0 and
  (.[0] | has("providers") | not) and
  .[1].accountSlot == "codex-a" and .[1].providers[0].provider == "codex"
' >/dev/null || fail "mixed probe-all did not emit sanitized unavailable evidence beside the healthy result"
if printf '%s' "$out" | jq -e 'any(.. | objects; has("account") or has("attempts") or has("source") or has("storePath"))' >/dev/null; then
  fail "mixed probe-all leaked a forbidden private field"
fi
reason=$(printf '%s' "$out" | jq -r '.slots[0].availability.reason')
assert_contains "$reason" "claude-a" "unavailable evidence did not name the slot its reason belongs to"
for secret in claude-account-a wrong-account private@example.invalid "$HOME_DIR/profiles/claude-a" /private/credential; do
  assert_not_contains "$reason" "$secret" "unavailable reason leaked private probe detail"
done
printf '%s\n' '{"forbidden":{"source":"private"},"later":{}}' | jq -e 'any(.. | objects; has("account") or has("attempts") or has("source") or has("storePath"))' >/dev/null \
  || fail "forbidden-field privacy predicate missed a nested field"
pass "continues after an unavailable slot and emits one privacy verdict"

for mode in mismatch wrong-source stale; do
  if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_MODE="$mode" FM_HOME="$HOME_DIR" \
      "$ROOT/bin/fm-account-slot.sh" probe claude-a >/dev/null 2>"$TMP_ROOT/$mode.err"; then
    fail "$mode quota evidence was accepted"
  fi
done
for mode in wrong-source stale; do
  assert_contains "$(cat "$TMP_ROOT/$mode.err")" "stale, mismatched, or malformed quota evidence" "$mode refusal was not concrete"
done
pass "rejects stale, wrong-source, and mismatched-account evidence"

# A mistyped expectedAccountId and a stale document are different operator
# problems - edit the registry versus refresh or reinstall the producer - so
# they must not share one reason. Both still name only the logical slot.
identity_reason=$(cat "$TMP_ROOT/mismatch.err")
stale_reason=$(cat "$TMP_ROOT/stale.err")
assert_contains "$identity_reason" "expectedAccountId" "an identity mismatch did not name the setting the operator must correct"
assert_not_contains "$identity_reason" "stale, mismatched, or malformed quota evidence" "an identity mismatch was reported as stale or malformed evidence"
[ "$identity_reason" != "$stale_reason" ] \
  || fail "an identity mismatch and a stale document produced the same reason"
for secret in claude-account-a claude-account-b wrong-account private@example.invalid "$HOME_DIR/profiles/claude-a" /private/credential; do
  assert_not_contains "$identity_reason" "$secret" "identity mismatch refusal leaked an account identity or credential path"
done
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
    FAKE_ATTEMPTS='[{"source":"oauth-file","status":"success","accountId":"claude-account-b"}]' \
    "$ROOT/bin/fm-account-slot.sh" probe claude-a >/dev/null 2>"$TMP_ROOT/attempt-identity.err"; then
  fail "a successful attempt naming another account was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/attempt-identity.err")" "expectedAccountId" "a cross-account attempt was not reported as an identity mismatch"
pass "reports an identity mismatch as its own reason, never as stale or malformed evidence"

# A document whose account object carries no usable accountId is producer drift,
# not a mistyped registry value, so it must point at the evidence and never send
# the operator off to edit a correct expectedAccountId.
for mode in no-account-id numeric-account-id; do
  if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_MODE="$mode" FM_HOME="$HOME_DIR" \
      "$ROOT/bin/fm-account-slot.sh" probe claude-a >/dev/null 2>"$TMP_ROOT/$mode.err"; then
    fail "quota evidence with a $mode account identity was accepted"
  fi
  drift_reason=$(cat "$TMP_ROOT/$mode.err")
  assert_contains "$drift_reason" "stale, mismatched, or malformed quota evidence" "a $mode account identity was not reported as malformed producer evidence"
  assert_not_contains "$drift_reason" "expectedAccountId" "a $mode account identity was blamed on the operator's configured expectedAccountId"
done
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
    FAKE_ATTEMPTS='[{"source":"oauth-file","status":"success","accountId":42}]' \
    "$ROOT/bin/fm-account-slot.sh" probe claude-a >/dev/null 2>"$TMP_ROOT/attempt-drift.err"; then
  fail "a successful attempt carrying a non-string accountId was accepted"
fi
assert_not_contains "$(cat "$TMP_ROOT/attempt-drift.err")" "expectedAccountId" "a drifted attempt identity was blamed on the operator's configured expectedAccountId"
pass "classifies a missing or non-string account identity as producer drift, not an identity mismatch"

: > "$CALLS"
PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  FAKE_ATTEMPTS='[{"source":"oauth","status":"success"},{"source":"cli-rpc","status":"failure"}]' \
  "$ROOT/bin/fm-account-slot.sh" probe codex-a >/dev/null \
  || fail "a failed fallback attempt beside a successful isolated source made a healthy Codex slot unavailable"
PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  FAKE_ATTEMPTS='[{"source":"oauth-file","status":"success"},{"source":"keychain","status":"success"}]' \
  "$ROOT/bin/fm-account-slot.sh" probe claude-a >/dev/null \
  || fail "a store holding both a credential file and its keychain item was reported unavailable"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
    FAKE_ATTEMPTS='[{"source":"oauth","status":"failure"},{"source":"cli-rpc","status":"failure"}]' \
    "$ROOT/bin/fm-account-slot.sh" probe codex-a >/dev/null 2>&1; then
  fail "evidence with no successful attempt was accepted"
fi
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
    FAKE_ATTEMPTS='[{"source":"oauth-file","status":"success","accountId":"claude-account-b"}]' \
    "$ROOT/bin/fm-account-slot.sh" probe claude-a >/dev/null 2>&1; then
  fail "a successful attempt naming another account was accepted"
fi
pass "provenance reads successful attempts only and refuses zero-success or cross-account evidence"

# Regression: the Codex quota document spells its CODEX_HOME-scoped credential
# source "oauth", not the "auth-json" the separate `quota-axi auth` report uses.
# Against the real producer that mismatch dropped both Codex subscriptions out
# of routing. The ambient fallback the producer reaches for when the slot store
# holds no credential is "pi:openai-codex", which must still be refused.
: > "$CALLS"
out=$(PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  FAKE_ATTEMPTS='[{"source":"oauth","status":"success"}]' \
  "$ROOT/bin/fm-account-slot.sh" probe-all codex-a) \
  || fail "the Codex source spelling the real producer emits dropped the slot out of routing"
printf '%s' "$out" | jq -e '.slots | length == 1 and .[0].accountSlot == "codex-a" and .[0].providers[0].provider == "codex"' \
  >/dev/null || fail "a Codex slot the real producer reports as its own was not routable"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
    FAKE_ATTEMPTS='[{"source":"oauth","status":"skipped","error":"credentials_missing"},{"source":"pi:openai-codex","status":"success"}]' \
    "$ROOT/bin/fm-account-slot.sh" probe codex-a >/dev/null 2>&1; then
  fail "a Codex slot served by the ambient Pi credential instead of its own store was accepted"
fi
pass "reads the Codex source vocabulary the quota document itself uses, and still refuses the ambient one"

if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_MODE=invalid-then-valid FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-account-slot.sh" probe claude-a >"$TMP_ROOT/multi-document.out" 2>"$TMP_ROOT/multi-document.err"; then
  fail "multiple quota JSON roots were accepted"
fi
assert_contains "$(cat "$TMP_ROOT/multi-document.err")" "malformed quota evidence" "multiple-root refusal was unclear"
assert_equals "" "$(cat "$TMP_ROOT/multi-document.out")" "multiple-root refusal emitted sanitized evidence"
pass "requires exactly one JSON root from every quota probe"

PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_OMIT_FLAG=--full FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" validate >/dev/null \
  || fail "a missing quota-axi capability was reported as invalid slot configuration"
for missing in --provider --full --json --no-credential-refresh; do
  : > "$CALLS"
  if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_OMIT_FLAG="$missing" FM_HOME="$HOME_DIR" \
      "$ROOT/bin/fm-account-slot.sh" probe-all claude-a >/dev/null 2>"$TMP_ROOT/capability.err"; then
    fail "automatic slot ranking accepted quota-axi without $missing"
  fi
  assert_contains "$(cat "$TMP_ROOT/capability.err")" "$missing" "missing capability refusal did not name the absent flag"
  assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" "probe-all sent $missing to a quota-axi that does not advertise it"
  : > "$CALLS"
  if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_OMIT_FLAG="$missing" FM_HOME="$HOME_DIR" \
      "$ROOT/bin/fm-account-slot.sh" probe claude-a >/dev/null 2>"$TMP_ROOT/capability-single.err"; then
    fail "single-slot probe accepted quota-axi without $missing"
  fi
  assert_contains "$(cat "$TMP_ROOT/capability-single.err")" "$missing" "single-slot capability refusal did not name the absent flag"
done
pass "gates automatic quota ranking on every flag the probe sends and names the missing one"

for shape in list synopsis alternation indented; do
  : > "$CALLS"
  PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_HELP_SHAPE="$shape" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-account-slot.sh" probe-all claude-a >/dev/null 2>"$TMP_ROOT/shape-$shape.err" \
    || fail "a capable quota-axi whose help renders flags as '$shape' was refused: $(cat "$TMP_ROOT/shape-$shape.err")"
  assert_equals 1 "$(wc -l < "$CALLS" | tr -d ' ')" "the '$shape' help shape did not reach a quota probe"
done
: > "$CALLS"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_HELP_SHAPE=longer FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-account-slot.sh" probe-all claude-a >/dev/null 2>"$TMP_ROOT/shape-longer.err"; then
  fail "a quota-axi advertising only --json-lines satisfied the --json prerequisite"
fi
assert_contains "$(cat "$TMP_ROOT/shape-longer.err")" "--json" "longer-flag refusal did not name the absent flag"
assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" "probe-all probed a quota-axi that never advertised --json"
pass "reads a flag from any usual help rendering without accepting a longer flag that merely starts with it"

cp "$HOME_DIR/config/account-slots.json" "$TMP_ROOT/valid-registry"
cp "$HOME_DIR/config/crew-dispatch.json" "$TMP_ROOT/valid-dispatch"
jq '.slots.default=.slots["claude-a"]' "$TMP_ROOT/valid-registry" > "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/default-registry.err"; then
  fail "reserved default registry slot was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/default-registry.err")" "default is reserved" "reserved registry slot refusal was unclear"
cp "$TMP_ROOT/valid-registry" "$HOME_DIR/config/account-slots.json"
jq '.default[0].accountSlots=["default"]' "$TMP_ROOT/valid-dispatch" > "$HOME_DIR/config/crew-dispatch.json"
chmod 600 "$HOME_DIR/config/account-slots.json" "$HOME_DIR/config/crew-dispatch.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/default-dispatch.err"; then
  fail "reserved default dispatch slot was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/default-dispatch.err")" "default is reserved" "reserved dispatch slot refusal was unclear"
: > "$CALLS"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" probe-all claude-a codex-a >/dev/null 2>"$TMP_ROOT/default-probe-all.err"; then
  fail "probe-all converted malformed dispatch configuration into per-slot unavailability"
fi
assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" "probe-all reached provider probes before refusing malformed dispatch configuration"
cp "$TMP_ROOT/valid-dispatch" "$HOME_DIR/config/crew-dispatch.json"
chmod 600 "$HOME_DIR/config/crew-dispatch.json"
pass "reserves default as the account-slot clear sentinel"

printf '{bad\n' > "$HOME_DIR/config/crew-dispatch.json"
chmod 600 "$HOME_DIR/config/crew-dispatch.json"
: > "$CALLS"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" probe-all claude-a >/dev/null 2>"$TMP_ROOT/malformed-dispatch.err"; then
  fail "malformed dispatch JSON was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/malformed-dispatch.err")" "cannot be inspected for accountSlots" "malformed dispatch refusal was unclear"
assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" "malformed dispatch reached a quota probe"
cp "$TMP_ROOT/valid-dispatch" "$HOME_DIR/config/crew-dispatch.json"
chmod 600 "$HOME_DIR/config/crew-dispatch.json"
pass "rejects malformed dispatch JSON before any quota probe"

printf '{bad\n' > "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>&1; then
  fail "malformed registry JSON was accepted"
fi
: > "$CALLS"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" probe-all claude-a >/dev/null 2>"$TMP_ROOT/malformed-probe-all.err"; then
  fail "probe-all converted a malformed registry into per-slot unavailability"
fi
assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" "probe-all reached provider probes before refusing a malformed registry"
cp "$TMP_ROOT/valid-registry" "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"
jq --arg path "$HOME_DIR/profiles/claude-a" '.slots["claude-b"].storePath=$path' \
  "$HOME_DIR/config/account-slots.json" > "$TMP_ROOT/duplicate"
mv "$TMP_ROOT/duplicate" "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/duplicate.err"; then
  fail "duplicate canonical profile path was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/duplicate.err")" "duplicates another slot" "duplicate path refusal was unclear"
pass "rejects malformed registries and duplicate canonical profile paths"

cp "$TMP_ROOT/valid-registry" "$HOME_DIR/config/account-slots.json"
chmod 644 "$HOME_DIR/config/account-slots.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/file-mode.err"; then
  fail "group/world-readable registry was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/file-mode.err")" "no group or world permissions" "registry mode refusal was unclear"
chmod 600 "$HOME_DIR/config/account-slots.json"

mv "$HOME_DIR/config/account-slots.json" "$TMP_ROOT/registry-target"
ln -s "$TMP_ROOT/registry-target" "$HOME_DIR/config/account-slots.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/file-symlink.err"; then
  fail "symlinked registry was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/file-symlink.err")" "non-symlink regular file" "registry symlink refusal was unclear"
rm "$HOME_DIR/config/account-slots.json"
mv "$TMP_ROOT/registry-target" "$HOME_DIR/config/account-slots.json"

ln "$HOME_DIR/config/account-slots.json" "$TMP_ROOT/registry-hardlink"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/file-hardlink.err"; then
  fail "hardlinked registry was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/file-hardlink.err")" "must not be hardlinked" "registry hardlink refusal was unclear"
rm "$TMP_ROOT/registry-hardlink"

chmod 755 "$HOME_DIR/profiles/claude-a"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/dir-mode.err"; then
  fail "group/world-accessible profile directory was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/dir-mode.err")" "no group or world permissions" "profile directory mode refusal was unclear"
chmod 700 "$HOME_DIR/profiles/claude-a"

ln -s "$HOME_DIR/profiles/claude-a" "$HOME_DIR/profiles/claude-link"
jq --arg path "$HOME_DIR/profiles/claude-link" '.slots["claude-a"].storePath=$path' \
  "$HOME_DIR/config/account-slots.json" > "$TMP_ROOT/symlinked-store-registry"
mv "$TMP_ROOT/symlinked-store-registry" "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/dir-symlink.err"; then
  fail "symlinked profile directory was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/dir-symlink.err")" "existing non-symlink directory" "profile directory symlink refusal was unclear"
rm "$HOME_DIR/profiles/claude-link"
cp "$TMP_ROOT/valid-registry" "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"

OWNERBIN="$TMP_ROOT/ownerbin"
mkdir -p "$OWNERBIN"
cat > "$OWNERBIN/id" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -u ]; then
  actual=$("${FM_REAL_ID:?}" -u)
  printf '%s\n' "$((actual + 1))"
  exit 0
fi
exec "${FM_REAL_ID:?}" "$@"
SH
chmod +x "$OWNERBIN/id"
if PATH="$OWNERBIN:$FAKEBIN:$PATH" FM_REAL_ID="$(command -v id)" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/owner.err"; then
  fail "registry owner mismatch was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/owner.err")" "owned by the current user" "owner mismatch refusal was unclear"
pass "rejects unsafe owner, mode, symlink, and hardlink states through the public validator"

printf 'all fm-account-slot tests passed\n'
