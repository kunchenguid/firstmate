#!/usr/bin/env bash
# Characterization tests for fm-install-shellcheck.sh's hermetic installer path.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"

test_retries_and_installs_pinned_shellcheck() {
  local tmp fakebin destination output
  tmp=$(fm_test_tmproot fm-install-shellcheck)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$CURL_COUNT" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$CURL_COUNT"
[ "$count" -gt 1 ] || exit 35
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    : > "$2"
    exit 0
  fi
  shift
done
exit 2
SH
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
printf '8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198  %s\n' "$1"
SH
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    mkdir -p "$2/shellcheck-v0.11.0"
    cat > "$2/shellcheck-v0.11.0/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
EOF
    chmod +x "$2/shellcheck-v0.11.0/shellcheck"
    exit 0
  fi
  shift
done
exit 2
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/curl" "$fakebin/sha256sum" "$fakebin/tar" "$fakebin/sleep"

  output=$(CURL_COUNT="$tmp/curl-count" PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure\n$output"
  [ "$(cat "$tmp/curl-count")" -eq 2 ] \
    || fail "installer did not retry exactly once after recovery"
  assert_contains "$output" "download attempt 1 failed; retrying" \
    "installer did not disclose its retry"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck"
  assert_contains "$("$destination/shellcheck" --version)" "version: 0.11.0" \
    "installed executable did not report the pinned version"
  pass "fm-install-shellcheck retries and installs the pinned executable"
}

test_retries_and_installs_pinned_shellcheck
