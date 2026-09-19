#!/usr/bin/env bash
# Behavior tests for bin/fm-fork-target.sh and its local config/fork-url
# declaration contract. They use throwaway git repositories and a fake
# no-mistakes command to assert target output and initialization side effects.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FORK_TARGET="$ROOT/bin/fm-fork-target.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-target)

new_case() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/home/config" "$d/repo"
  git -C "$d/repo" init -q
  printf '%s\n' "$d"
}

set_origin() {
  git -C "$1/repo" remote remove origin 2>/dev/null || true
  git -C "$1/repo" remote add origin "$2"
}

make_fakebin() {
  local d=$1 fb
  fb=$(fm_fakebin "$d")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_TEST_NM_LOG"
if [ "${1:-}" = status ] && [ -n "${FM_TEST_NM_STATUS:-}" ]; then
  printf '%s\n' "$FM_TEST_NM_STATUS"
fi
SH
  chmod +x "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

resolve() {
  local d=$1; shift
  FM_TEST_NM_LOG="$d/nm.log" PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" resolve "$d/repo" "$@"
}

test_declared_url_is_used_verbatim() {
  local d out url; d=$(new_case declared-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" 'https://user:token@evil.example/acme/widget.git'
  while IFS= read -r url; do
    printf '%s\n' "$url" > "$d/home/config/fork-url"
    out=$(resolve "$d")
    assert_equals "$url" "$out" "declared URL was rewritten: $url"
  done <<EOF
https://github.example/contributor/widget.git
ssh://git@github.example/contributor/widget.git
git+ssh://git@github.example/contributor/widget.git
git@github.example:contributor/widget.git
file://$d/bare.git
EOF
  pass "config/fork-url returns accepted URLs byte-for-byte"
}

test_surrounding_whitespace_is_refused() {
  local d status out err safe; d=$(new_case whitespace-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  printf ' ssh://github.example/contributor/widget.git \n' > "$d/home/config/fork-url"
  status=0; out=$(resolve "$d" 2>"$d/err") || status=$?
  expect_code 1 "$status" "surrounding whitespace must be rejected"
  assert_equals "" "$out" "an invalid URL must produce no output"
  err=$(cat "$d/err")
  assert_contains "$err" "config/fork-url" "the setting must be named"
  safe=$(printf '%q' ' ssh://github.example/contributor/widget.git ')
  assert_contains "$err" "value $safe" "the rejected value must be rendered safely"
  assert_contains "$err" "contains whitespace" "the whitespace reason must be stated"
  pass "config/fork-url whitespace is rejected without normalization"
}

test_unusable_declarations_are_refused_without_init() {
  local d value reason status out err; d=$(new_case bad-urls)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  while IFS='|' read -r value reason; do
    printf '%s\n' "$value" > "$d/home/config/fork-url"
    : > "$d/nm.log"; status=0
    out=$(FM_TEST_NM_LOG="$d/nm.log" PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
      "$FORK_TARGET" init "$d/repo" 2>"$d/err") || status=$?
    expect_code 1 "$status" "unusable URL must stop init: $value"
    assert_equals "" "$out" "unusable URL must produce no stdout: $value"
    err=$(cat "$d/err")
    if [ -n "$value" ]; then
      assert_contains "$err" "$value" "unusable value must be named: $value"
    else
      assert_contains "$err" "value ''" "an empty unusable value must be visible"
    fi
    assert_contains "$err" "$reason" "unusable reason must be concrete: $value"
    assert_not_contains "$(cat "$d/nm.log")" "init" \
      "unusable URL must not invoke no-mistakes init: $value"
  done <<'EOF'
|it is empty
not-a-url|not an absolute remote URL or scp-like push URL
github.com/acme/widget|not an absolute remote URL or scp-like push URL
/tmp/upstream.git|not an absolute remote URL or scp-like push URL
ftp://github.example/contributor/widget.git|unsupported scheme
https://|host and path
https:///widget.git|host and path
https://github.example|host and path
file://|host and path
EOF
  pass "unusable config/fork-url declarations fail closed before init"
}

test_unreadable_declaration_is_refused_without_init() {
  local d status out err; d=$(new_case unreadable-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  mkdir "$d/home/config/fork-url"
  status=0
  out=$(FM_TEST_NM_LOG="$d/nm.log" PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" 2>"$d/err") || status=$?
  expect_code 1 "$status" "a non-regular declaration must stop init"
  assert_equals "" "$out" "an unreadable declaration must produce no stdout"
  err=$(cat "$d/err")
  assert_contains "$err" "config/fork-url" "the unreadable setting must be named"
  assert_contains "$err" "not a regular file" "the read failure reason must be concrete"
  assert_not_contains "$(cat "$d/nm.log")" "init" \
    "an unreadable declaration must not invoke no-mistakes init"
  pass "an unreadable config/fork-url fails closed without initialization"
}

test_control_bytes_are_refused_without_init() {
  local d status out err hex; d=$(new_case control-byte-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  printf 'ssh://github.example/contributor/widget.git' > "$d/home/config/fork-url"
  printf '\0evil\n' >> "$d/home/config/fork-url"
  status=0
  out=$(FM_TEST_NM_LOG="$d/nm.log" PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" 2>"$d/err") || status=$?
  expect_code 1 "$status" "a control-byte declaration must stop init"
  assert_equals "" "$out" "a control-byte declaration must produce no stdout"
  err=$(cat "$d/err")
  assert_contains "$err" "config/fork-url" "the control-byte setting must be named"
  assert_contains "$err" "NUL or control byte" "the control-byte reason must be stated"
  hex=$(od -An -tx1 -v "$d/home/config/fork-url" | tr -d '[:space:]')
  assert_contains "$err" "hex: $hex" "the control-byte diagnostic must identify the value safely"
  assert_not_contains "$(cat "$d/nm.log")" "init" \
    "a control-byte declaration must not invoke no-mistakes init"
  pass "config/fork-url control bytes fail before shell storage or init"
}

test_malformed_declaration_is_refused() {
  local d status out err hex; d=$(new_case malformed-url)
  make_fakebin "$d" >/dev/null
  printf 'ssh://github.example/contributor/widget.git\nsecond-line\n' > "$d/home/config/fork-url"
  status=0; out=$(resolve "$d" 2>"$d/err") || status=$?
  expect_code 1 "$status" "a multi-line declaration must be rejected"
  assert_equals "" "$out" "a multi-line declaration must produce no output"
  err=$(cat "$d/err")
  assert_contains "$err" "config/fork-url" "the malformed setting must be named"
  assert_contains "$err" "exactly one line" "the malformed shape must be stated"
  hex=$(od -An -tx1 -v "$d/home/config/fork-url" | tr -d '[:space:]')
  assert_contains "$err" "hex: $hex" "the malformed diagnostic must identify the complete value safely"
  pass "multi-line config/fork-url declarations fail closed"
}

# The unterminated variant is its own case because `read` reports 1 at EOF even
# when it captured bytes, so a second line WITHOUT a final newline is the shape
# a status-only check silently accepts.
test_unterminated_second_line_is_refused() {
  local d status out err hex; d=$(new_case unterminated-second-line)
  make_fakebin "$d" >/dev/null
  printf 'ssh://github.example/contributor/widget.git\nsecond-line' > "$d/home/config/fork-url"
  status=0; out=$(resolve "$d" 2>"$d/err") || status=$?
  expect_code 1 "$status" "an unterminated second line must be rejected"
  assert_equals "" "$out" "an unterminated second line must produce no output"
  err=$(cat "$d/err")
  assert_contains "$err" "config/fork-url" "the malformed setting must be named"
  assert_contains "$err" "exactly one line" "the malformed shape must be stated"
  hex=$(od -An -tx1 -v "$d/home/config/fork-url" | tr -d '[:space:]')
  assert_contains "$err" "hex: $hex" "the malformed diagnostic must identify the complete value safely"
  pass "a second line without a final newline fails closed"
}

# The accepting side of the same boundary: a lone line with no trailing newline
# is one line and must still resolve.
test_single_line_without_trailing_newline_is_accepted() {
  local d out status; d=$(new_case unterminated-single-line)
  make_fakebin "$d" >/dev/null
  printf 'ssh://github.example/contributor/widget.git' > "$d/home/config/fork-url"
  status=0; out=$(resolve "$d") || status=$?
  expect_code 0 "$status" "a single unterminated line must succeed"
  assert_equals 'ssh://github.example/contributor/widget.git' "$out" \
    "a single unterminated line must resolve verbatim"
  pass "a single line without a trailing newline is accepted"
}

test_absent_declaration_is_empty_success() {
  local d out status; d=$(new_case absent-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" 'https://user:token@evil.example/acme/widget.git'
  status=0; out=$(resolve "$d") || status=$?
  expect_code 0 "$status" "an absent declaration must succeed"
  assert_equals "" "$out" "an absent declaration must produce empty output"
  pass "an absent config/fork-url selects unchanged origin behavior"
}

test_resolution_does_not_read_git_or_network() {
  local d out status; d=$(new_case no-resolution-io)
  make_fakebin "$d" >/dev/null
  printf 'ssh://git@github.example/contributor/widget.git\n' > "$d/home/config/fork-url"
  cat > "$d/fakebin/git" <<'SH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$FM_TEST_NM_LOG"
exit 99
SH
  chmod +x "$d/fakebin/git"
  status=0; out=$(resolve "$d") || status=$?
  expect_code 0 "$status" "resolution should not invoke git"
  assert_equals 'ssh://git@github.example/contributor/widget.git' "$out" \
    "resolution should use only the local declaration"
  assert_equals '' "$(cat "$d/nm.log" 2>/dev/null || true)" \
    "resolve should not invoke no-mistakes or network helpers"
  pass "resolution uses no git remote or network lookup"
}

test_explicit_home_ignores_a_stale_config_override() {
  local d stale out status; d=$(new_case explicit-home-config)
  stale="$d/stale-config"
  mkdir -p "$stale"
  printf 'ssh://git@github.example/stale/wrong.git\n' > "$stale/fork-url"
  printf 'ssh://git@github.example/configured/right.git\n' > "$d/home/config/fork-url"
  status=0
  out=$(FM_CONFIG_OVERRIDE='' FM_HOME="$d/home" PATH="$d/fakebin:$PATH" \
    "$FORK_TARGET" resolve "$d/repo") || status=$?
  expect_code 0 "$status" "an explicit home should resolve successfully"
  assert_equals 'ssh://git@github.example/configured/right.git' "$out" \
    "the explicit home declaration must win over a stale override"
  pass "explicit home resolution does not inherit a stale config override"
}

test_init_passes_declared_url_verbatim() {
  local d status; d=$(new_case init-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" 'https://user:token@evil.example/acme/widget.git'
  printf 'ssh://git@github.example/contributor/widget.git\n' > "$d/home/config/fork-url"
  status=0
  FM_TEST_NM_LOG="$d/nm.log" PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >/dev/null || status=$?
  expect_code 0 "$status" "init with a declared URL"
  assert_contains "$(cat "$d/nm.log")" \
    "init --fork-url ssh://git@github.example/contributor/widget.git" \
    "init must pass the declared URL verbatim"
  pass "init initializes the gate against config/fork-url"
}

test_init_without_declaration_uses_origin() {
  local d status; d=$(new_case init-origin)
  make_fakebin "$d" >/dev/null; set_origin "$d" https://github.com/acme/widget.git
  status=0
  FM_TEST_NM_LOG="$d/nm.log" PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >/dev/null || status=$?
  expect_code 0 "$status" "init without a declaration"
  assert_contains "$(cat "$d/nm.log")" "init" "origin init must still run"
  assert_not_contains "$(cat "$d/nm.log")" "--fork-url" \
    "origin init must not invent a fork URL"
  pass "init preserves the maintainer origin path when unconfigured"
}

# A PATH with every other tool intact but no `no-mistakes` at all. The binary's
# absence is classified like any other initialization failure, so it needs the
# real tool genuinely missing rather than stubbed.
path_without_no_mistakes() {
  local nm nmdir
  nm=$(command -v no-mistakes 2>/dev/null) || { printf '%s' "$PATH"; return 0; }
  nmdir=$(dirname "$nm")
  printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$nmdir" | paste -sd: -
}

# The tool-presence check runs after resolution and is classified the same way
# as an init failure, so these are the two sides of that boundary.
test_missing_no_mistakes_is_advisory_without_a_declaration() {
  local d status clean_path err; d=$(new_case missing-nm-undeclared)
  set_origin "$d" https://github.com/acme/widget.git
  clean_path=$(path_without_no_mistakes)
  status=0
  PATH="$clean_path" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >/dev/null 2>"$d/err" || status=$?
  expect_code 4 "$status" "a missing binary with no declaration must be advisory"
  err=$(cat "$d/err")
  assert_contains "$err" "no-mistakes command not found" "the advisory must name what is missing"
  assert_contains "$err" "warning" "the advisory must not masquerade as an error"
  pass "a missing no-mistakes without a declaration is advisory, not fatal"
}

test_missing_no_mistakes_is_fatal_with_a_declaration() {
  local d status clean_path err; d=$(new_case missing-nm-declared)
  set_origin "$d" https://github.com/acme/widget.git
  printf 'ssh://git@github.example/contributor/widget.git\n' > "$d/home/config/fork-url"
  clean_path=$(path_without_no_mistakes)
  status=0
  PATH="$clean_path" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >/dev/null 2>"$d/err" || status=$?
  expect_code 1 "$status" "a missing binary with a declared url must be fatal"
  err=$(cat "$d/err")
  assert_contains "$err" "ssh://git@github.example/contributor/widget.git" \
    "the refusal must name the declared target it could not honor"
  pass "a missing no-mistakes with a declared url refuses"
}

test_existing_registration_is_preserved_on_failure() {
  local d status; d=$(new_case existing-registration)
  make_fakebin "$d" >/dev/null; set_origin "$d" https://github.com/acme/widget.git
  printf 'not-a-url\n' > "$d/home/config/fork-url"; status=0
  FM_TEST_NM_LOG="$d/nm.log" \
    FM_TEST_NM_STATUS='fork: ssh://git@github.example/contributor/widget.git' \
    PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >/dev/null 2>"$d/err" || status=$?
  expect_code 1 "$status" "failed resolution must stop init"
  assert_contains "$(cat "$d/nm.log")" "status" "existing registration should be inspected"
  assert_not_contains "$(cat "$d/nm.log")" "init" \
    "failed resolution must not replace the registration"
  pass "failed resolution preserves an existing gate registration"
}

test_usage_error_exits_2() {
  local status=0
  "$FORK_TARGET" >/dev/null 2>&1 || status=$?; expect_code 2 "$status" "no arguments"
  status=0; "$FORK_TARGET" bogus "$TMP_ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "unknown subcommand"
  pass "usage errors exit 2"
}

test_declared_url_is_used_verbatim
test_surrounding_whitespace_is_refused
test_unusable_declarations_are_refused_without_init
test_unreadable_declaration_is_refused_without_init
test_control_bytes_are_refused_without_init
test_malformed_declaration_is_refused
test_unterminated_second_line_is_refused
test_single_line_without_trailing_newline_is_accepted
test_absent_declaration_is_empty_success
test_resolution_does_not_read_git_or_network
test_explicit_home_ignores_a_stale_config_override
test_init_passes_declared_url_verbatim
test_init_without_declaration_uses_origin
test_missing_no_mistakes_is_advisory_without_a_declaration
test_missing_no_mistakes_is_fatal_with_a_declaration
test_existing_registration_is_preserved_on_failure
test_usage_error_exits_2
