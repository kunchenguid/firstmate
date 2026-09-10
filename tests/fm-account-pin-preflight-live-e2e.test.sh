#!/usr/bin/env bash
# Default-on live guard for the spawn-time account-pin preflight
# (bin/fm-account-pin-lib.sh).
#
# The preflight's verdict comes from what two vendor checks emit: Pi's
# `pi auth check --json` and quota-axi's `auth --json` row for Claude. A fake
# can only repeat the answer written into it, so this runs the real tools
# against throwaway roots and checks the verdict each root must get:
#   - an empty Pi root refuses, and still refuses when the caller carries
#     ANTHROPIC_API_KEY, which real Pi counts as a credential for any root;
#   - a Pi root holding an API-key credential in its auth.json passes;
#   - an empty Claude root refuses;
#   - a Claude root holding an unexpired OAuth credentials file passes.
# Raw Pi is also asked under the caller's key, so the scrubbed case cannot pass
# vacuously if a Pi release stops reading that variable.
#
# No credential is real and no prompt is submitted, so the shared live gate
# runs it by default wherever pi, quota-axi, and jq are installed. Run it after
# a Pi or quota-axi upgrade, and before refreshing
# docs/verification/dispatch-auth.md "Account-pin preflight".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_ACCOUNT_PIN_LIVE pi quota-axi jq

TMP_ROOT=$(fm_test_tmproot fm-account-pin-preflight-live)
PI_VERSION="pi $(pi --version 2>&1 | head -1)"
QUOTA_VERSION="quota-axi $(quota-axi --version 2>&1 | head -1)"
FAKE_KEY=sk-ant-fm-account-pin-guard-not-a-real-key

preflight() {  # <harness> <root> -> the lib's verdict and exit status
  bash -c '. "$1/bin/fm-account-pin-lib.sh"; fm_account_pin_preflight "$2" "$3" "$2"' _ "$ROOT" "$@" 2>&1
}

pi_root() {  # <name> -> a Pi root whose default provider is anthropic
  local root="$TMP_ROOT/$1"
  mkdir -p "$root"
  printf '{"defaultProvider":"anthropic"}\n' > "$root/settings.json"
  printf '%s\n' "$root"
}

test_pi_roots() {
  local empty keyed out status
  empty=$(pi_root pi-empty)
  keyed=$(pi_root pi-keyed)
  printf '{"anthropic":{"type":"api_key","key":"%s"}}\n' "$FAKE_KEY" > "$keyed/auth.json"
  chmod 600 "$keyed/auth.json"

  out=$(preflight pi "$empty"); status=$?
  expect_code 1 "$status" "$PI_VERSION: an empty Pi root must refuse: $out"
  assert_contains "$out" "not_ready anthropic" "$PI_VERSION: an empty Pi root refused for an unexpected reason"

  out=$(env -i HOME="$HOME" PATH="$PATH" ANTHROPIC_API_KEY="$FAKE_KEY" PI_CODING_AGENT_DIR="$empty" \
    pi auth check --provider anthropic --json --no-refresh 2>/dev/null)
  [ "$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)" = ready ] \
    || fail "$PI_VERSION: raw Pi no longer counts ANTHROPIC_API_KEY for an empty root ($out); the scrubbed case below proves nothing until this guard is revisited"
  out=$(ANTHROPIC_API_KEY="$FAKE_KEY" preflight pi "$empty"); status=$?
  expect_code 1 "$status" "$PI_VERSION: a caller's ANTHROPIC_API_KEY vouched for an empty Pi root: $out"

  out=$(ANTHROPIC_API_KEY='' preflight pi "$keyed"); status=$?
  expect_code 0 "$status" "$PI_VERSION: a Pi root holding a credential must pass: $out"
  pass "$PI_VERSION: the Pi preflight refuses an empty root, even under a caller's key, and passes a credentialed one"
}

test_claude_roots() {
  local empty filed out status expires
  empty="$TMP_ROOT/claude-empty"
  filed="$TMP_ROOT/claude-filed"
  mkdir -p "$empty" "$filed"
  expires=$(( ($(date +%s) + 86400) * 1000 ))
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-%s","refreshToken":"sk-ant-ort01-%s","expiresAt":%s,"scopes":["user:inference"]}}\n' \
    "$FAKE_KEY" "$FAKE_KEY" "$expires" > "$filed/.credentials.json"
  chmod 600 "$filed/.credentials.json"

  out=$(preflight claude "$empty"); status=$?
  expect_code 1 "$status" "$QUOTA_VERSION: an empty Claude root must refuse: $out"
  assert_contains "$out" "oauth-file=missing" "$QUOTA_VERSION: an empty Claude root refused for an unexpected reason"

  out=$(preflight claude "$filed"); status=$?
  expect_code 0 "$status" "$QUOTA_VERSION: a Claude root holding an unexpired credentials file must pass: $out"
  pass "$QUOTA_VERSION: the Claude preflight refuses an empty root and passes a credentialed one"
}

test_pi_roots
test_claude_roots
