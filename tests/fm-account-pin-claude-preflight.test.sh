#!/usr/bin/env bash
# Hermetic coverage for the Claude branch of the account-pin preflight
# (bin/fm-account-pin-lib.sh) against quota-axi 0.1.41's recorded answer for a
# root whose keychain presence check did not complete: skipped with
# credentialPresent true, given to an empty root and a logged-in root alike.
# That answer must refuse an empty root and pass a root whose .claude.json
# records a login. The live guard tests/fm-account-pin-preflight-live-e2e.test.sh
# covers what the installed quota-axi actually emits.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-account-pin-claude-preflight)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '{"auth":[{"provider":"claude","sources":[{"source":"oauth-file","status":"missing"},{"source":"keychain","status":"skipped","error":"keychain_presence_check_failed","credentialPresent":true}]}]}\n'
SH
chmod +x "$FAKEBIN/quota-axi"

preflight() {  # <root> -> the lib's verdict and exit status
  PATH="$FAKEBIN:$PATH" bash -c '. "$1/bin/fm-account-pin-lib.sh"; fm_account_pin_preflight claude "$2" claude' _ "$ROOT" "$1" 2>&1
}

empty="$TMP_ROOT/empty"
unlogged="$TMP_ROOT/unlogged"
logged="$TMP_ROOT/logged"
mkdir -p "$empty" "$unlogged" "$logged"
printf '{"numStartups":1}\n' > "$unlogged/.claude.json"
printf '{"oauthAccount":{"emailAddress":"fm@example.invalid"}}\n' > "$logged/.claude.json"

out=$(preflight "$empty"); status=$?
expect_code 1 "$status" "an empty Claude root passed on a skipped keychain answer: $out"
assert_contains "$out" "keychain=skipped" "an empty Claude root refused for an unexpected reason"

out=$(preflight "$unlogged"); status=$?
expect_code 1 "$status" "a Claude root with no recorded login passed on a skipped keychain answer: $out"

out=$(preflight "$logged"); status=$?
expect_code 0 "$status" "a Claude root with a recorded login refused on a skipped keychain answer: $out"
pass "a skipped keychain answer passes only a Claude root whose .claude.json records a login"
