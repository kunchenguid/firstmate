#!/usr/bin/env bash
# Behavior tests for bin/fm-github-app-token.sh.
# No live GitHub App exists in this fleet yet: every network response is faked.
# Covers absent/partial config (inert exit 2), malformed config, bad keys, a
# correctly formed signed mint request against a mock API, and the invariant
# that neither the private key nor the installation token appear in curl argv.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-github-app-token.sh"
TMP_ROOT=$(fm_test_tmproot fm-github-app-token)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config"
  printf '%s\n' "$home"
}

write_config() {
  local home=$1 app_id=$2 installation_id=$3 key_path=$4
  [ -n "$app_id" ] && printf '%s\n' "$app_id" > "$home/config/github-app-id"
  [ -n "$installation_id" ] && printf '%s\n' "$installation_id" > "$home/config/github-app-installation-id"
  [ -n "$key_path" ] && printf '%s\n' "$key_path" > "$home/config/github-app-private-key-path"
}

# Fake curl that records argv and the Authorization header file contents for
# inspection, then returns a fixed installation-token JSON body.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_CURL_LOG:?}
auth_dump=${FM_FAKE_CURL_AUTH_DUMP:-}
body_out=
http_code_fmt=
args_file=${FM_FAKE_CURL_ARGV_FILE:?}
{
  printf 'argc=%s\n' "$#"
  i=0
  for a in "$@"; do
    i=$((i + 1))
    printf 'arg%d=%s\n' "$i" "$a"
  done
} > "$args_file"
printf '%s\n' "$*" >> "$log"

# Honor curl's -o / -w roughly enough for the helper.
prev=
for a in "$@"; do
  if [ "$prev" = "-o" ]; then
    body_out=$a
  fi
  case "$a" in
    -w) prev=-w; continue ;;
    -o) prev=-o; continue ;;
    "%{http_code}") http_code_fmt=1 ;;
    @*)
      # Header file form: -H @path. Capture file contents for JWT shape checks.
      if [ -n "$auth_dump" ] && [ -f "${a#@}" ]; then
        cat "${a#@}" > "$auth_dump"
      fi
      ;;
  esac
  prev=$a
done

# Walk argv again for -H @file when the @ form is a separate -H argument value.
prev=
for a in "$@"; do
  if [ "$prev" = "-H" ]; then
    case "$a" in
      @*)
        if [ -n "$auth_dump" ] && [ -f "${a#@}" ]; then
          cat "${a#@}" > "$auth_dump"
        fi
        ;;
    esac
  fi
  prev=$a
done

token=${FM_FAKE_INSTALL_TOKEN:-ghs_test_installation_token_not_real}
code=${FM_FAKE_HTTP_CODE:-201}
if [ -n "$body_out" ]; then
  printf '{"token":"%s","expires_at":"2099-01-01T00:00:00Z"}\n' "$token" > "$body_out"
fi
if [ -n "$http_code_fmt" ] || [ "${FM_FAKE_PRINT_CODE:-1}" = 1 ]; then
  printf '%s' "$code"
fi
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

make_rsa_key() {
  local path=$1
  openssl genrsa -out "$path" 2048 2>/dev/null \
    || fail "openssl genrsa failed for test key at $path"
  chmod 600 "$path"
}

run_helper() {
  local home=$1
  shift
  env FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$ROOT" \
    "$@" "$HELPER"
}

# --- absent / partial config: inert, not an error -----------------------------

test_absent_config_is_not_configured() {
  local home out rc
  home=$(make_home absent)
  out=$(run_helper "$home" 2>&1)
  rc=$?
  expect_code 2 "$rc" "absent config should exit 2 (not configured)"
  [ -z "$out" ] || fail "absent config should be silent, got: $out"
  pass "absent GitHub App config exits 2 silently"
}

test_partial_config_is_not_configured() {
  local home out rc key
  home=$(make_home partial-id-only)
  printf '12345\n' > "$home/config/github-app-id"
  out=$(run_helper "$home" 2>&1)
  rc=$?
  expect_code 2 "$rc" "app-id alone should still be not configured"
  [ -z "$out" ] || fail "partial config should be silent, got: $out"

  home=$(make_home partial-two)
  key="$home/key.pem"
  make_rsa_key "$key"
  write_config "$home" "12345" "" "$key"
  out=$(run_helper "$home" 2>&1)
  rc=$?
  expect_code 2 "$rc" "missing installation id should be not configured"

  home=$(make_home partial-no-keypath)
  write_config "$home" "12345" "67890" ""
  out=$(run_helper "$home" 2>&1)
  rc=$?
  expect_code 2 "$rc" "missing key path should be not configured"
  pass "partial GitHub App config exits 2 (not configured)"
}

# --- malformed present config fails closed ------------------------------------

test_non_digit_ids_fail() {
  local home out rc key
  home=$(make_home bad-ids)
  key="$home/key.pem"
  make_rsa_key "$key"
  write_config "$home" "not-digits" "67890" "$key"
  out=$(run_helper "$home" 2>&1)
  rc=$?
  expect_code 1 "$rc" "non-digit app id should fail"
  assert_contains "$out" "github-app-id" "error should name the app id file"
  assert_not_contains "$out" "BEGIN" "error must not dump key material"
  assert_not_contains "$out" "PRIVATE" "error must not dump key material"

  write_config "$home" "12345" "bad-id" "$key"
  out=$(run_helper "$home" 2>&1)
  rc=$?
  expect_code 1 "$rc" "non-digit installation id should fail"
  assert_contains "$out" "installation-id" "error should name the installation id file"
  pass "non-digit GitHub App ids fail closed without leaking the key"
}

test_relative_key_path_fails() {
  local home out rc
  home=$(make_home rel-key)
  write_config "$home" "12345" "67890" "relative/key.pem"
  out=$(run_helper "$home" 2>&1)
  rc=$?
  expect_code 1 "$rc" "relative key path should fail"
  assert_contains "$out" "absolute" "error should require an absolute path"
  pass "relative private key path is refused"
}

# A present-but-unreadable config file must be a hard error: reporting it as
# "not configured" would make fm-spawn.sh launch the worker under the captain's
# gh credentials with no diagnostic at all.
test_unreadable_config_fails_closed() {
  local home out rc key
  if [ "$(id -u)" = 0 ]; then
    pass "skipped unreadable-config check (root bypasses file permissions)"
    return 0
  fi
  home=$(make_home unreadable-id)
  key="$home/key.pem"
  make_rsa_key "$key"
  write_config "$home" "12345" "67890" "$key"
  chmod 000 "$home/config/github-app-id"
  out=$(run_helper "$home" 2>&1)
  rc=$?
  chmod 600 "$home/config/github-app-id"
  expect_code 1 "$rc" "unreadable app-id config should be a hard error, not exit 2"
  assert_contains "$out" "github-app-id" "error should name the unreadable file"
  assert_contains "$out" "not readable" "error should say the file is unreadable"
  pass "present-but-unreadable GitHub App config fails closed instead of reading as unconfigured"
}

test_symlinked_key_path_is_refused_with_a_clear_reason() {
  local home out rc key link
  home=$(make_home symlink-key)
  key="$home/key.pem"
  make_rsa_key "$key"
  link="$home/key-link.pem"
  ln -s "$key" "$link"
  write_config "$home" "12345" "67890" "$link"
  out=$(run_helper "$home" 2>&1)
  rc=$?
  expect_code 1 "$rc" "symlinked key path should fail"
  assert_contains "$out" "symlink" "error should name the symlink restriction"
  assert_contains "$out" "regular file" "error should say a regular file is required"
  assert_not_contains "$out" "BEGIN" "error must not dump key material"
  pass "symlinked private key path is refused with a reason the operator can act on"
}

test_bad_key_fails_without_leak() {
  local home out rc key
  home=$(make_home bad-key)
  key="$home/not-a-key.pem"
  printf 'this is not a PEM private key\n' > "$key"
  chmod 600 "$key"
  write_config "$home" "12345" "67890" "$key"
  out=$(run_helper "$home" 2>&1)
  rc=$?
  expect_code 1 "$rc" "bad key should fail mint"
  assert_contains "$out" "sign" "error should mention signing failure"
  assert_not_contains "$out" "this is not a PEM" "error must not echo key file bytes"
  assert_not_contains "$out" "ghs_" "error must not invent or echo a token"
  pass "bad private key fails safely without leaking key bytes"
}

# --- successful mint against mock API -----------------------------------------

test_mint_succeeds_with_signed_request_and_no_token_in_argv() {
  local home key fakebin out rc args auth jwt_header jwt_payload payload_json iss
  local token="ghs_mock_token_abc123_not_real"
  home=$(make_home mint-ok)
  key="$home/app.pem"
  make_rsa_key "$key"
  write_config "$home" "424242" "999001" "$key"
  fakebin=$(make_fake_curl "$home/fake")
  : > "$home/curl.log"
  : > "$home/curl.argv"
  : > "$home/auth.header"

  out=$(
    env FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$ROOT" \
      FM_GITHUB_APP_API_BASE="https://example.test" \
      FM_FAKE_CURL_LOG="$home/curl.log" \
      FM_FAKE_CURL_ARGV_FILE="$home/curl.argv" \
      FM_FAKE_CURL_AUTH_DUMP="$home/auth.header" \
      FM_FAKE_INSTALL_TOKEN="$token" \
      PATH="$fakebin:$PATH" \
      "$HELPER" 2>"$home/stderr.txt"
  )
  rc=$?
  expect_code 0 "$rc" "configured mint against mock API should succeed"
  # Token alone on stdout (optional trailing newline is fine).
  case "$out" in
    "$token"|"$token"$'\n') ;;
    *) fail "stdout should be exactly the installation token, got: [$out]" ;;
  esac
  [ ! -s "$home/stderr.txt" ] || fail "successful mint should be quiet on stderr: $(cat "$home/stderr.txt")"

  args=$(cat "$home/curl.argv")
  assert_contains "$args" "app/installations/999001/access_tokens" \
    "curl should hit the installation access_tokens path"
  assert_not_contains "$args" "$token" "installation token must never appear in curl argv"
  assert_not_contains "$args" "BEGIN" "private key must never appear in curl argv"
  assert_not_contains "$args" "PRIVATE KEY" "private key must never appear in curl argv"
  # JWT must ride -H @file, not -H "Authorization: Bearer <jwt>" with the JWT inline.
  if grep -E 'arg[0-9]+=Authorization: Bearer ' "$home/curl.argv" >/dev/null; then
    fail "JWT/Authorization must not be passed as a literal -H value on argv"
  fi
  if ! grep -E 'arg[0-9]+=@' "$home/curl.argv" >/dev/null; then
    fail "curl argv should include an @header-file form for Authorization"
  fi

  auth=$(cat "$home/auth.header")
  case "$auth" in
    "Authorization: Bearer "*.*.*) ;;
    *) fail "auth header file should hold a three-part JWT, got: [$auth]" ;;
  esac
  jwt_header=${auth#Authorization: Bearer }
  jwt_header=${jwt_header%%.*}
  jwt_payload=${auth#Authorization: Bearer }
  jwt_payload=${jwt_payload#*.}
  jwt_payload=${jwt_payload%%.*}

  # Decode payload (add base64 padding) and confirm iss is the App id.
  payload_json=$(
    pad=$jwt_payload
    case $(( ${#pad} % 4 )) in
      2) pad="${pad}==" ;;
      3) pad="${pad}=" ;;
    esac
    printf '%s' "$pad" | tr -- '-_' '+/' | base64 -d 2>/dev/null \
      || printf '%s' "$pad" | tr -- '-_' '+/' | base64 -D 2>/dev/null
  ) || fail "could not base64-decode JWT payload"
  iss=$(printf '%s' "$payload_json" | jq -r '.iss')
  [ "$iss" = "424242" ] || fail "JWT iss should be the App id, got: $iss"

  # Worktree / tracked-path leak checks: no token files under the home config tree.
  if grep -R -- "$token" "$home/config" >/dev/null 2>&1; then
    fail "installation token must not be written under config/"
  fi
  pass "mint succeeds with a correctly formed signed request; token stays off argv and disk config"
}

test_http_failure_is_error_without_token_leak() {
  local home key fakebin out rc
  home=$(make_home mint-http-fail)
  key="$home/app.pem"
  make_rsa_key "$key"
  write_config "$home" "1" "2" "$key"
  fakebin=$(make_fake_curl "$home/fake")
  out=$(
    env FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$ROOT" \
      FM_GITHUB_APP_API_BASE="https://example.test" \
      FM_FAKE_CURL_LOG="$home/curl.log" \
      FM_FAKE_CURL_ARGV_FILE="$home/curl.argv" \
      FM_FAKE_HTTP_CODE=401 \
      FM_FAKE_INSTALL_TOKEN="ghs_should_not_surface" \
      PATH="$fakebin:$PATH" \
      "$HELPER" 2>&1
  )
  rc=$?
  expect_code 1 "$rc" "HTTP 401 should fail the mint"
  assert_contains "$out" "401" "error should report the HTTP status"
  assert_not_contains "$out" "ghs_should_not_surface" "failed mint must not print the token body"
  pass "HTTP failure fails closed without printing a token"
}

test_absent_config_is_not_configured
test_partial_config_is_not_configured
test_non_digit_ids_fail
test_relative_key_path_fails
test_unreadable_config_fails_closed
test_symlinked_key_path_is_refused_with_a_clear_reason
test_bad_key_fails_without_leak
test_mint_succeeds_with_signed_request_and_no_token_in_argv
test_http_failure_is_error_without_token_leak

printf 'All fm-github-app-token tests passed.\n'
