#!/usr/bin/env bash
# Default-on live guard for the spawn-time account-pin preflight
# (bin/fm-account-pin-lib.sh).
#
# The preflight's verdict comes from what two vendor checks emit: Pi's
# `pi auth check --json`, Pi's `--list-models`, and quota-axi's `auth --json`
# row for Claude. A fake can only repeat the answer written into it, so this
# runs the real tools against throwaway roots and checks the verdict each root
# must get:
#   - an empty Pi root refuses, and still refuses when the caller carries
#     ANTHROPIC_API_KEY, which real Pi counts as a credential for any root;
#   - a Pi root holding an API-key credential in its auth.json passes;
#   - a Pi launch naming no provider refuses, because one root can hold several
#     accounts and the root's defaultProvider must not pick between them;
#   - a provider only an extension registers passes when the root serves its
#     models and refuses when it does not, which is the one case `pi auth check`
#     cannot answer for at all;
#   - an empty Claude root refuses;
#   - a Claude root holding an unexpired OAuth credentials file passes.
# Raw Pi is also asked under the caller's key, so the scrubbed case cannot pass
# vacuously if a Pi release stops reading that variable, and raw Pi's own
# provider_not_found answer is asserted so the extension case cannot pass
# through a path the library never takes.
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

preflight() {  # <harness> <root> [<model>] -> the lib's verdict and exit status
  bash -c '. "$1/bin/fm-account-pin-lib.sh"; fm_account_pin_preflight "$2" "$3" "$2" "${4:-}"' _ "$ROOT" "$@" 2>&1
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

  out=$(preflight pi "$empty" anthropic/claude-haiku-4-5); status=$?
  expect_code 1 "$status" "$PI_VERSION: an empty Pi root must refuse: $out"
  assert_contains "$out" "not_ready anthropic" "$PI_VERSION: an empty Pi root refused for an unexpected reason"

  out=$(env -i HOME="$HOME" PATH="$PATH" ANTHROPIC_API_KEY="$FAKE_KEY" PI_CODING_AGENT_DIR="$empty" \
    pi auth check --provider anthropic --json --no-refresh 2>/dev/null)
  [ "$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)" = ready ] \
    || fail "$PI_VERSION: raw Pi no longer counts ANTHROPIC_API_KEY for an empty root ($out); the scrubbed case below proves nothing until this guard is revisited"
  out=$(ANTHROPIC_API_KEY="$FAKE_KEY" preflight pi "$empty" anthropic/claude-haiku-4-5); status=$?
  expect_code 1 "$status" "$PI_VERSION: a caller's ANTHROPIC_API_KEY vouched for an empty Pi root: $out"

  out=$(ANTHROPIC_API_KEY='' preflight pi "$keyed" anthropic/claude-haiku-4-5); status=$?
  expect_code 0 "$status" "$PI_VERSION: a Pi root holding a credential must pass: $out"

  # One root can hold several accounts, so the provider has to come from the
  # model. The root's own defaultProvider must not stand in for it.
  out=$(ANTHROPIC_API_KEY='' preflight pi "$keyed"); status=$?
  expect_code 1 "$status" "$PI_VERSION: a Pi launch naming no provider must refuse even under a credentialed root: $out"
  assert_contains "$out" "names no provider" "$PI_VERSION: the no-provider refusal did not say what was missing"
  out=$(ANTHROPIC_API_KEY='' preflight pi "$keyed" claude-haiku-4-5); status=$?
  expect_code 1 "$status" "$PI_VERSION: an unqualified Pi model must refuse: $out"
  pass "$PI_VERSION: the Pi preflight refuses an empty root, even under a caller's key, passes a credentialed one, and refuses a launch that names no provider"
}

# `pi auth check` loads no extensions, so it answers provider_not_found for a
# provider an extension registers - the one answer that falls through to
# `pi --list-models`, which does load them. Both readings are exercised against
# real Pi, because a fake could only repeat whichever answer was written into it,
# and the listing is a table this library parses by column.
test_pi_second_reading() {
  local keyed empty out status listed
  keyed=$(pi_root pi-listed)
  empty=$(pi_root pi-unlisted)
  printf '{"anthropic":{"type":"api_key","key":"%s"}}\n' "$FAKE_KEY" > "$keyed/auth.json"
  chmod 600 "$keyed/auth.json"

  out=$(env -i HOME="$HOME" PATH="$PATH" PI_CODING_AGENT_DIR="$keyed" \
    pi auth check --provider fm-not-a-provider --json --no-refresh 2>/dev/null)
  [ "$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null)" = provider_not_found ] \
    || fail "$PI_VERSION: raw Pi no longer answers provider_not_found for a provider it cannot see ($out); the fall-through the preflight depends on has changed"
  out=$(env -i HOME="$HOME" PATH="$PATH" PI_CODING_AGENT_DIR="$empty" \
    pi auth check --provider anthropic --json --no-refresh 2>/dev/null)
  [ "$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null)" = credentials_not_configured ] \
    || fail "$PI_VERSION: raw Pi no longer separates a logged-out known provider from an unseen one ($out); a logged-out provider would start reaching the second reading"

  listed=$(env -i HOME="$HOME" PATH="$PATH" PI_CODING_AGENT_DIR="$keyed" \
    pi --list-models anthropic 2>/dev/null | awk 'NR > 1 && $1 == "anthropic" { print $2; exit }')
  [ -n "$listed" ] \
    || fail "$PI_VERSION: raw Pi lists no models for a credentialed provider under this root; the second reading proves nothing until this guard is revisited"

  listed_check() {  # <root> <model> -> the library's second reading
    bash -c '. "$1/bin/fm-account-pin-lib.sh"; fm_account_pin_pi_model_listed "$2" pi "${3%%/*}" "$3" \
      env -i "HOME=$HOME" "PATH=$PATH"' _ "$ROOT" "$@"
  }

  listed_check "$keyed" "anthropic/$listed"; status=$?
  expect_code 0 "$status" "$PI_VERSION: the second reading must confirm a model this root lists"

  # The search is fuzzy, so a near-miss comes back in the same listing; only an
  # exact provider and model column may pass.
  listed_check "$keyed" "anthropic/$listed-fm-not-a-model"; status=$?
  expect_code 1 "$status" "$PI_VERSION: a fuzzily matched neighbour passed as the requested model"
  listed_check "$keyed" "fm-not-a-provider/$listed"; status=$?
  expect_code 1 "$status" "$PI_VERSION: a model listed under another provider passed for this one"

  # Without a credential the provider's rows disappear, which is what makes a
  # listing evidence of a usable login rather than of a registered provider.
  listed_check "$empty" "anthropic/$listed"; status=$?
  expect_code 1 "$status" "$PI_VERSION: a root holding no credential still listed the provider's models"
  pass "$PI_VERSION: pi auth check still routes an unseen provider to the second reading, and --list-models still answers by exact provider and model column"
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
  expect_code 1 "$status" "$QUOTA_VERSION: an empty Claude root must refuse: $out
    Known on 0.1.41: the keychain source answers skipped/keychain_presence_check_failed with
    credentialPresent true, which the library counts as ready. See the dated readings in
    docs/verification/dispatch-auth.md under \"quota-axi keychain reporting on 0.1.41\"."
  assert_contains "$out" "oauth-file=missing" "$QUOTA_VERSION: an empty Claude root refused for an unexpected reason"

  out=$(preflight claude "$filed"); status=$?
  expect_code 0 "$status" "$QUOTA_VERSION: a Claude root holding an unexpired credentials file must pass: $out"
  pass "$QUOTA_VERSION: the Claude preflight refuses an empty root and passes a credentialed one"
}

test_pi_roots
test_pi_second_reading
test_claude_roots
