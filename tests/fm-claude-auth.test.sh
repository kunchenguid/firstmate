#!/usr/bin/env bash
# Behavior tests for Claude profile auth preflight.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-auth)
AUTH="$ROOT/bin/fm-claude-auth.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    printf '%s (Claude Code)\n' "${FM_FAKE_CLAUDE_VERSION:-2.1.276}"
    exit 0
    ;;
  auth)
    if [ "${2:-}" = status ]; then
      [ -z "${FM_FAKE_CLAUDE_ENV_LOG:-}" ] || printf '%s\n' "${CLAUDE_CONFIG_DIR-<unset>}" >> "$FM_FAKE_CLAUDE_ENV_LOG"
      status=${FM_FAKE_CLAUDE_STATUS:-}
      if [ -z "$status" ]; then
        case "${CLAUDE_CONFIG_DIR:-}" in */b|*/a-empty) status=unauthenticated ;; *) status=authenticated ;; esac
      fi
      case "$status" in
        authenticated) printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai"\n}\n'; exit 0 ;;
        unauthenticated) printf '{\n  "loggedIn": false,\n  "authMethod": "none"\n}\n'; exit 1 ;;
        garbage) printf 'session maybe\n' ;;
      esac
      exit 0
    fi
    ;;
esac
exit 2
SH
chmod +x "$FAKEBIN/claude"

REAL_UNAME=$(command -v uname)
cat > "$FAKEBIN/uname" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_FAKE_UNAME:-}" ] && [ "\${1:-}" = -s ]; then
  printf '%s\\n' "\$FM_FAKE_UNAME"
  exit 0
fi
exec "$REAL_UNAME" "\$@"
SH
chmod +x "$FAKEBIN/uname"

write_creds() {
  local dir=$1 secret=${2:-secret-value}
  mkdir -p "$dir"
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"refresh-secret"}}\n' "$secret" > "$dir/.credentials.json"
  fm_test_onboard_claude_store "$dir"
}

make_home() {
  local dir=$1
  mkdir -p "$dir/config"
}

case_dir="$TMP_ROOT/authenticated"
make_home "$case_dir/home"
write_creds "$case_dir/a" "top-secret-token"
fm_test_attest_claude_pool "$case_dir/a"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 0 "$status" "authenticated profile should pass: $out"
assert_contains "$out" 'profile=claude-max-a auth=authenticated setup=absent' "auth evidence missing"
assert_not_contains "$out" 'top-secret-token' "secret access token leaked"
assert_not_contains "$out" 'refresh-secret' "secret refresh token leaked"
pass "fm-claude-auth: authenticated Claude profile proceeds without printing secrets"

case_dir="$TMP_ROOT/unauthenticated"
make_home "$case_dir/home"
mkdir -p "$case_dir/a-empty"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a-empty","setup_token_file":"$case_dir/setup-token"}]}
EOF
printf 'setup-token-secret\n' > "$case_dir/setup-token"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 1 "$status" "unauthenticated profile should fail"
assert_contains "$out" 'auth=unauthenticated:vendor-probe setup=available:file' "setup availability should be reported"
assert_contains "$out" 'run the credential installer' "available setup material should be actionable"
assert_not_contains "$out" 'setup-token-secret' "setup token value leaked"
pass "fm-claude-auth: unauthenticated profile is rejected and setup material is value-redacted"

case_dir="$TMP_ROOT/two-pools"
make_home "$case_dir/home"
write_creds "$case_dir/a"
fm_test_attest_claude_pool "$case_dir/a"
mkdir -p "$case_dir/b"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a"},{"id":"claude-max-b","config_dir":"$case_dir/b"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" evidence 2>&1) || fail "evidence failed: $out"
assert_contains "$out" 'profile=claude-max-a auth=authenticated' "pool a missing"
assert_contains "$out" 'profile=claude-max-b auth=unauthenticated:vendor-probe' "pool b missing"
pass "fm-claude-auth: both Claude pools are represented in auth evidence"

case_dir="$TMP_ROOT/no-setup"
make_home "$case_dir/home"
mkdir -p "$case_dir/a"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_FAKE_CLAUDE_STATUS=unauthenticated FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 1 "$status" "unauthenticated profile without setup should fail"
assert_contains "$out" 'setup=absent' "absent setup should be reported"
assert_contains "$out" 'add setup_token_file' "absent setup should be actionable"
pass "fm-claude-auth: absent setup-token material reports an actionable setup need"

case_dir="$TMP_ROOT/pools-only"
make_home "$case_dir/home"
write_creds "$case_dir/a"
fm_test_attest_claude_pool "$case_dir/a"
mkdir -p "$case_dir/b" "$case_dir/ambient"
write_creds "$case_dir/ambient"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a"},{"id":"claude-max-b","config_dir":"$case_dir/b"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="$case_dir/ambient" FM_HOME="$case_dir/home" "$AUTH" check --profile default 2>&1); status=$?
expect_code 0 "$status" "a pools-only config must still answer the default profile: $out"
assert_contains "$out" "profile=default auth=authenticated setup=absent config_dir=$case_dir/ambient" "the synthesized default should use the ambient store"
out=$(PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="$case_dir/ambient" FM_HOME="$case_dir/home" "$AUTH" evidence 2>&1) || fail "evidence failed: $out"
assert_contains "$out" 'profile=claude-max-a auth=authenticated' "named pool a should still be listed"
assert_contains "$out" 'profile=claude-max-b auth=unauthenticated:vendor-probe' "named pool b should still be listed"
assert_contains "$out" "profile=default auth=authenticated setup=absent config_dir=$case_dir/ambient" "the synthesized default should appear alongside the pools"
pass "fm-claude-auth: a pools-only config keeps answering the default profile"

case_dir="$TMP_ROOT/explicit-default"
make_home "$case_dir/home"
write_creds "$case_dir/chosen"
mkdir -p "$case_dir/ambient"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"default","config_dir":"$case_dir/chosen"},{"id":"claude-max-a","config_dir":"$case_dir/a"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="$case_dir/ambient" FM_HOME="$case_dir/home" "$AUTH" check --profile default 2>&1); status=$?
expect_code 0 "$status" "an explicit default entry should resolve: $out"
assert_contains "$out" "config_dir=$case_dir/chosen" "an explicit default entry must override the synthesized one"
assert_not_contains "$out" "$case_dir/ambient" "the ambient store must not reach an explicitly configured default"
out=$(PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="$case_dir/ambient" FM_HOME="$case_dir/home" "$AUTH" evidence 2>&1) || fail "evidence failed: $out"
assert_equals 2 "$(printf '%s\n' "$out" | grep -c '^profile=')" "an explicit default must not be duplicated by the synthesized one"
pass "fm-claude-auth: an explicit default entry overrides the synthesized one"

case_dir="$TMP_ROOT/first-run-onboarding"
make_home "$case_dir/home"
write_creds "$case_dir/ambient"
printf '%s\n' '{"hasCompletedOnboarding":null}' > "$case_dir/ambient/.claude.json"
mkdir -p "$case_dir/user-home"
out=$(PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="$case_dir/ambient" FM_HOME="$case_dir/home" "$AUTH" check --profile default 2>&1); status=$?
expect_code 1 "$status" "a logged-in store that has not finished first-run onboarding must not pass: $out"
assert_contains "$out" "profile=default auth=unonboarded:first-run-onboarding-incomplete setup=absent config_dir=$case_dir/ambient" "onboarding verdict missing"
assert_contains "$out" "first-run onboarding" "the refusal should route to finishing onboarding"
rm -f "$case_dir/ambient/.claude.json"
printf '%s\n' '{"hasCompletedOnboarding":true}' > "$case_dir/user-home/.claude.json"
out=$(PATH="$FAKEBIN:$PATH" HOME="$case_dir/user-home" CLAUDE_CONFIG_DIR='' FM_HOME="$case_dir/home" "$AUTH" check --profile default 2>&1); status=$?
expect_code 0 "$status" "an ambient default reads onboarding from \$HOME/.claude.json: $out"
rm -f "$case_dir/user-home/.claude.json"
out=$(PATH="$FAKEBIN:$PATH" HOME="$case_dir/user-home" CLAUDE_CONFIG_DIR='' FM_HOME="$case_dir/home" "$AUTH" check --profile default 2>&1); status=$?
expect_code 1 "$status" "an ambient default without \$HOME/.claude.json has never onboarded: $out"
assert_contains "$out" "auth=unonboarded:first-run-onboarding-incomplete" "ambient onboarding verdict missing"
pass "fm-claude-auth: a logged-in profile that has not finished first-run onboarding is refused"

case_dir="$TMP_ROOT/missing-config-dir"
make_home "$case_dir/home"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/never-created"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_FAKE_CLAUDE_STATUS=authenticated FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 1 "$status" "an unattested pool store must refuse even when the probe says authenticated"
assert_not_contains "$out" 'auth=unauthenticated' "the filesystem must never produce an authentication verdict"
assert_contains "$out" 'auth=unattested:setup-not-attested' "a store with no attestation must refuse on that, not on a made-up login state"
out=$(PATH="$FAKEBIN:$PATH" FM_FAKE_CLAUDE_STATUS=unauthenticated FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 1 "$status" "an unauthenticated probe over a missing config directory should still refuse"
assert_contains "$out" 'auth=unauthenticated:vendor-probe' "the refusal must name the probe as its source"
pass "fm-claude-auth: a missing config directory is probed rather than assumed unauthenticated"

case_dir="$TMP_ROOT/indeterminate"
make_home "$case_dir/home"
mkdir -p "$case_dir/a"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_FAKE_CLAUDE_STATUS=garbage FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 1 "$status" "an unclassifiable probe result must still refuse"
assert_contains "$out" 'auth=indeterminate:vendor-probe' "the unclassifiable state should be reported as indeterminate"
assert_contains "$out" 'could not be verified' "an indeterminate probe should say the state was never established"
assert_not_contains "$out" 'authenticate Claude interactively' "an indeterminate probe must not send the operator to re-login"
pass "fm-claude-auth: an indeterminate probe refuses without claiming the profile is logged out"

case_dir="$TMP_ROOT/unverified-platform"
make_home "$case_dir/home"
write_creds "$case_dir/a"
fm_test_attest_claude_pool "$case_dir/a"
mkdir -p "$case_dir/ambient"
write_creds "$case_dir/ambient"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_FAKE_UNAME=Darwin CLAUDE_CONFIG_DIR="$case_dir/ambient" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 1 "$status" "a named pool must refuse where account separation is unverified"
assert_contains "$out" 'auth=unsupported:pool-separation-unverified' "the platform limit should be reported as its own state"
assert_contains "$out" 'verified first-hand only on Linux' "the refusal should name the verified platform"
assert_not_contains "$out" 'auth=authenticated' "an unverified platform must not yield an authenticated verdict"
out=$(PATH="$FAKEBIN:$PATH" FM_FAKE_UNAME=Darwin CLAUDE_CONFIG_DIR="$case_dir/ambient" FM_HOME="$case_dir/home" "$AUTH" check --profile default 2>&1); status=$?
expect_code 0 "$status" "the default profile must keep working on every platform: $out"
assert_contains "$out" 'profile=default auth=authenticated' "the ambient default profile should still be probed normally"
out=$(PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="$case_dir/ambient" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 0 "$status" "a named pool must still work on the verified platform: $out"
assert_contains "$out" 'auth=authenticated' "the verified platform should still probe named pools"
pass "fm-claude-auth: named pools are refused where CLAUDE_CONFIG_DIR account separation is unverified"

case_dir="$TMP_ROOT/ambient-default"
make_home "$case_dir/home"
fm_test_onboard_claude_store "$case_dir/user-home"
out=$(env -u CLAUDE_CONFIG_DIR PATH="$FAKEBIN:$PATH" HOME="$case_dir/user-home" FM_FAKE_CLAUDE_ENV_LOG="$case_dir/env.log" FM_HOME="$case_dir/home" "$AUTH" check --profile default 2>&1); status=$?
expect_code 0 "$status" "the ambient default should pass: $out"
assert_contains "$out" "profile=default auth=authenticated setup=absent config_dir=" "the ambient default should report its row"
case "$out" in *"config_dir=$case_dir"*|*'config_dir=/'*) fail "the ambient default must report no config dir when CLAUDE_CONFIG_DIR is unset: $out" ;; esac
assert_equals '<unset>' "$(cat "$case_dir/env.log")" "the ambient default must be probed with CLAUDE_CONFIG_DIR unset"
pass "fm-claude-auth: with CLAUDE_CONFIG_DIR unset the default profile is ambient and probed unset"

case_dir="$TMP_ROOT/named-without-config-dir"
make_home "$case_dir/home"
mkdir -p "$case_dir/a"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a"},{"id":"claude-max-b"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" evidence 2>&1); status=$?
expect_code 2 "$status" "a named pool without config_dir must make the profile file invalid"
assert_contains "$out" 'named profile claude-max-b needs its own config_dir' "the diagnostic should name the offending pool"
assert_not_contains "$out" 'profile=claude-max-b' "a named pool without its own store must never be rendered as a pool"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-b 2>&1); status=$?
expect_code 2 "$status" "checking the aliased pool must fail as a configuration error"
assert_not_contains "$out" 'auth=authenticated' "an aliased pool must not be reported as independently authenticated"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 2 "$status" "one malformed pool invalidates the whole per-home file rather than being selected around"
pass "fm-claude-auth: a named pool without its own config_dir is rejected instead of aliasing the default account"

case_dir="$TMP_ROOT/pool-attestation"
make_home "$case_dir/home"
write_creds "$case_dir/a"
mkdir -p "$case_dir/ambient"
write_creds "$case_dir/ambient"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/a"}]}
EOF
run_auth() { PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="$case_dir/ambient" FM_HOME="$case_dir/home" "$AUTH" "$@" 2>&1; }

out=$(run_auth check --profile claude-max-a); status=$?
expect_code 1 "$status" "a logged-in pool whose first-run setup is unattested must refuse"
assert_contains "$out" 'auth=unattested:setup-not-attested' "the unattested pool should report its own state, not an auth state"
assert_contains "$out" 'attest --profile claude-max-a --confirm-setup-complete' "the refusal should name the command that clears it"
assert_contains "$out" 'external-CLAUDE.md-import' "the refusal should name the consent it cannot verify"

out=$(run_auth check --profile default); status=$?
expect_code 0 "$status" "the ambient default must never require a pool attestation: $out"

out=$(run_auth attest --profile claude-max-a); status=$?
expect_code 2 "$status" "attest must refuse without the explicit operator confirmation"
assert_contains "$out" '--confirm-setup-complete' "attest should name the confirmation it requires"
[ ! -e "$case_dir/a/.fm-pool-ready" ] || fail "an unconfirmed attest must not write an attestation"

out=$(run_auth attest --profile default --confirm-setup-complete); status=$?
expect_code 2 "$status" "the ambient default carries no per-pool attestation"

out=$(FM_FAKE_CLAUDE_STATUS=unauthenticated run_auth attest --profile claude-max-a --confirm-setup-complete); status=$?
expect_code 2 "$status" "a pool that does not probe authenticated cannot have completed its interactive setup"
[ ! -e "$case_dir/a/.fm-pool-ready" ] || fail "attest must not record a pool it could not verify as logged in"

out=$(run_auth attest --profile claude-max-a --confirm-setup-complete); status=$?
expect_code 0 "$status" "attest should record a logged-in pool: $out"
assert_contains "$out" "attested profile=claude-max-a config_dir=$(cd -P -- "$case_dir/a" && pwd -P) contract=1" "attest should report the store and contract it recorded"
out=$(run_auth check --profile claude-max-a); status=$?
expect_code 0 "$status" "an attested pool should pass: $out"
assert_contains "$out" 'auth=authenticated' "an attested pool is launch-ready"

out=$(FM_FAKE_CLAUDE_VERSION=2.1.277 run_auth check --profile claude-max-a); status=$?
expect_code 0 "$status" "an ordinary claude patch update must not take an attested pool out of service: $out"
assert_contains "$out" 'auth=authenticated' "a vendor update changes no consent held in the store"
out=$(FM_FAKE_CLAUDE_VERSION=3.0.0 run_auth check --profile claude-max-a); status=$?
expect_code 0 "$status" "no claude version is a launch gate for an attested pool: $out"

sed -i.bak 's/^contract=.*/contract=0/' "$case_dir/a/.fm-pool-ready"
out=$(run_auth check --profile claude-max-a); status=$?
expect_code 1 "$status" "an attestation predating the current firstmate setup contract must ask for renewed confirmation"
assert_contains "$out" 'auth=unattested:contract-0-superseded' "the stale state should name the superseded contract"
assert_contains "$out" 'needs renewed confirmation' "the refusal should say the attested steps themselves changed"
assert_contains "$out" 'attest --profile claude-max-a --confirm-setup-complete' "the refusal should name the command that renews it"
out=$(run_auth attest --profile claude-max-a --confirm-setup-complete); status=$?
expect_code 0 "$status" "renewing the attestation should clear a superseded contract: $out"
out=$(run_auth check --profile claude-max-a); status=$?
expect_code 0 "$status" "a renewed attestation is launch-ready again: $out"

mkdir -p "$case_dir/moved"
sed -i.bak "s|^config_dir=.*|config_dir=$case_dir/moved|" "$case_dir/a/.fm-pool-ready"
out=$(run_auth check --profile claude-max-a); status=$?
expect_code 1 "$status" "an attestation naming another store must not clear this pool"
assert_contains "$out" 'auth=unattested:attested-for-another-store' "a transplanted attestation should be named as such"

rm -rf "$case_dir/link-target" "$case_dir/linked"
mkdir -p "$case_dir/link-target" "$case_dir/other-target"
fm_test_onboard_claude_store "$case_dir/link-target"
ln -s "$case_dir/link-target" "$case_dir/linked"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/linked"}]}
EOF
out=$(run_auth attest --profile claude-max-a --confirm-setup-complete); status=$?
expect_code 0 "$status" "a pool reached through a symlink should attest: $out"
out=$(run_auth check --profile claude-max-a); status=$?
expect_code 0 "$status" "the symlinked pool should be launch-ready: $out"
ln -sfn "$case_dir/other-target" "$case_dir/linked"
out=$(run_auth check --profile claude-max-a); status=$?
expect_code 1 "$status" "repointing the store at another directory must invalidate the attestation"
assert_contains "$out" 'auth=unattested:' "a repointed store must not stay launch-ready"
pass "fm-claude-auth: a named pool stays ready across vendor updates and refuses on a changed store or a superseded setup contract"

case_dir="$TMP_ROOT/aliased-stores"
make_home "$case_dir/home"
write_creds "$case_dir/shared"
fm_test_attest_claude_pool "$case_dir/shared"
cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/shared"},{"id":"claude-max-b","config_dir":"$case_dir/shared/"}]}
EOF
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" evidence 2>&1); status=$?
expect_code 2 "$status" "two pools naming one store must make the profile file invalid"
assert_contains "$out" 'profiles claude-max-a and claude-max-b name the same Claude store' "the diagnostic should name both offending pools"
assert_not_contains "$out" 'auth=authenticated' "aliased pools must never both be cleared for launch"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-b 2>&1); status=$?
expect_code 2 "$status" "checking an aliased pool must fail as a configuration error"

cat > "$case_dir/home/config/claude-profiles.json" <<EOF
{"profiles":[{"id":"claude-max-a","config_dir":"$case_dir/ambient"}]}
EOF
mkdir -p "$case_dir/ambient"
out=$(PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="$case_dir/ambient" FM_HOME="$case_dir/home" "$AUTH" evidence 2>&1); status=$?
expect_code 2 "$status" "a named pool naming the ambient default store must be rejected"
assert_contains "$out" 'name the same Claude store' "aliasing the synthesized default should be named the same way"
assert_contains "$out" 'default' "the diagnostic should name the default profile it collides with"
pass "fm-claude-auth: two profiles may not name one Claude store, so a pool can never spend another account"

case_dir="$TMP_ROOT/help"
out=$(PATH="$FAKEBIN:$PATH" "$AUTH" check --help 2>&1); status=$?
expect_code 0 "$status" "check --help should succeed"
assert_contains "$out" 'attest --profile <id> --confirm-setup-complete' "help should advertise the attest command"
assert_contains "$out" 'unattested' "help should explain the verdict the command it advertises clears"
assert_contains "$out" 'POOL_ATTESTATION_CONTRACT' "help should reach the attestation staleness rules"
assert_not_contains "$out" 'set -u' "help should stop at the end of the header, not spill into the script"
pass "fm-claude-auth: --help documents every subcommand it advertises"

case_dir="$TMP_ROOT/malformed"
make_home "$case_dir/home"
printf '%s\n' '{"profiles":[{"id":"claude-max-a",}]}' > "$case_dir/home/config/claude-profiles.json"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" evidence 2>&1); status=$?
[ "$status" -ne 0 ] || fail "malformed profile config should make evidence fail, got exit 0: $out"
assert_contains "$out" 'config/claude-profiles.json is malformed' "malformed config should name its cause"
assert_not_contains "$out" 'profile= ' "malformed config must not emit an invented profile row"
assert_not_contains "$out" 'auth=' "malformed config must not invent an auth verdict"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$case_dir/home" "$AUTH" check --profile claude-max-a 2>&1); status=$?
expect_code 2 "$status" "malformed profile config should make check fail closed"
assert_contains "$out" 'config/claude-profiles.json is malformed' "malformed config should name its cause to check too"
pass "fm-claude-auth: a malformed profile config fails both commands instead of inventing verdicts"

echo '# all Claude auth preflight tests passed'
