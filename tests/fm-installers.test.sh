#!/usr/bin/env bash
# Behavior tests for the pinned CI tool installers.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot fm-installers >/dev/null

make_retry_fakes() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -eu
count=0
[ -f "$FM_TEST_CURL_COUNT" ] && count=$(cat "$FM_TEST_CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_TEST_CURL_COUNT"

output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    output=$2
    shift 2
  else
    shift
  fi
done
[ -n "$output" ] || exit 2
[ "$count" -le "${FM_TEST_CURL_FAILURES:-3}" ] && exit 22
cp "$FM_TEST_CURL_ARTIFACT" "$output"
SH
  chmod +x "$fakebin/curl"

  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
printf '%s  %s\n' "$FM_TEST_SHA256" "$1"
SH
  chmod +x "$fakebin/sha256sum"

  # Keep the retry regression test fast while preserving the installer's delay
  # and attempt ordering.
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

make_shellcheck_artifact() {
  local dir=$1
  mkdir -p "$dir/shellcheck-v0.11.0"
  cat > "$dir/shellcheck-v0.11.0/shellcheck" <<'SH'
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
SH
  chmod +x "$dir/shellcheck-v0.11.0/shellcheck"
  tar -cJf "$dir/shellcheck.tar.xz" -C "$dir" shellcheck-v0.11.0
}

make_herdr_artifact() {
  local dir=$1
  cat > "$dir/herdr-linux-x86_64" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:) printf 'herdr 0.7.4\n' ;;
  status:--json) printf '{"client":{"protocol":16}}\n' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$dir/herdr-linux-x86_64"
}

test_shellcheck_retries_transient_release_failure() {
  local dir fakebin count output
  dir=$(fm_test_tmproot fm-installer-shellcheck)
  fakebin=$(fm_fakebin "$dir")
  make_retry_fakes "$fakebin"
  make_shellcheck_artifact "$dir"
  count="$dir/curl.count"
  mkdir -p "$dir/runner"

  output=$(PATH="$fakebin:$PATH" \
    RUNNER_TEMP="$dir/runner" \
    FM_TEST_CURL_COUNT="$count" \
    FM_TEST_CURL_ARTIFACT="$dir/shellcheck.tar.xz" \
    FM_TEST_CURL_FAILURES=3 \
    FM_TEST_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 \
    "$ROOT/bin/fm-install-shellcheck.sh" "$dir/bin" 2>&1) \
    || fail "ShellCheck installer did not recover from transient release failure\n$output"
  [ "$(cat "$count")" -ge 4 ] || fail "ShellCheck installer did not retry the release download"
  assert_contains "$output" 'version: 0.11.0' \
    "ShellCheck installer did not report the installed pinned version"
  pass "ShellCheck installer retries transient release failures"
}

test_herdr_retries_transient_release_failure() {
  local dir fakebin count output
  dir=$(fm_test_tmproot fm-installer-herdr)
  fakebin=$(fm_fakebin "$dir")
  make_retry_fakes "$fakebin"
  make_herdr_artifact "$dir"
  count="$dir/curl.count"
  mkdir -p "$dir/runner"

  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf 'Linux\n' ;;
  -m) printf 'x86_64\n' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/uname"
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
printf '16\n'
SH
  chmod +x "$fakebin/jq"

  output=$(PATH="$fakebin:$PATH" \
    RUNNER_TEMP="$dir/runner" \
    FM_TEST_CURL_COUNT="$count" \
    FM_TEST_CURL_ARTIFACT="$dir/herdr-linux-x86_64" \
    FM_TEST_CURL_FAILURES=3 \
    FM_TEST_SHA256=bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059 \
    "$ROOT/bin/fm-install-herdr.sh" "$dir/bin" 2>&1) \
    || fail "Herdr installer did not recover from transient release failure\n$output"
  [ "$(cat "$count")" -ge 4 ] || fail "Herdr installer did not retry the release download"
  assert_contains "$output" 'herdr 0.7.4' \
    "Herdr installer did not report the installed pinned version"
  pass "Herdr installer retries transient release failures"
}

test_shellcheck_retries_transient_release_failure
test_herdr_retries_transient_release_failure
