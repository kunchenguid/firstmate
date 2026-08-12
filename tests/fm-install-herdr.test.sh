#!/usr/bin/env bash
# Behavior tests for the pinned Herdr CI installer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-install-herdr)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
REAL_PATH=$PATH

cat > "$FAKEBIN/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' Linux ;;
  -m) printf '%s\n' x86_64 ;;
  *) exit 1 ;;
esac
EOF

cat > "$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CURL_LOG"
case "${FM_FAKE_CURL_MODE:-certificate}" in
  certificate)
    case " $* " in
      *" -kfsSL "*) ;;
      *) exit 60 ;;
    esac
    ;;
  network) exit 7 ;;
  *) exit 90 ;;
esac
output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    output=$2
    break
  fi
  shift
done
[ -n "$output" ] || exit 91
cat > "$output" <<'HERDR'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "--version ") printf '%s\n' 'herdr 0.7.4' ;;
  "status --json") printf '%s\n' '{"client":{"protocol":16}}' ;;
  *) exit 1 ;;
esac
HERDR
EOF

cat > "$FAKEBIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
printf '%s  %s\n' bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059 "$1"
EOF
chmod +x "$FAKEBIN/uname" "$FAKEBIN/curl" "$FAKEBIN/sha256sum"

test_certificate_failure_retries_verified_pin() {
  local destination log out rc=0
  destination="$TMP_ROOT/certificate/bin"
  log="$TMP_ROOT/certificate/curl.log"
  mkdir -p "$(dirname "$log")"
  : > "$log"
  out=$(PATH="$FAKEBIN:$REAL_PATH" FM_FAKE_CURL_LOG="$log" FM_FAKE_CURL_MODE=certificate \
    "$ROOT/bin/fm-install-herdr.sh" "$destination" 2>&1) || rc=$?
  expect_code 0 "$rc" "certificate failure fallback"
  [ -x "$destination/herdr" ] || fail "certificate fallback did not install Herdr: $out"
  [ "$(wc -l < "$log" | tr -d ' ')" = 2 ] || fail "certificate failure should perform exactly one retry"
  sed -n '2p' "$log" | grep -q -- '-kfsSL' || fail "certificate retry did not disable CA verification"
  assert_contains "$out" "retrying pinned asset without CA verification" "certificate fallback diagnostic"
  pass "certificate verification failures retry once and retain the pinned installer gates"
}

test_non_certificate_failure_does_not_retry() {
  local destination log out rc=0
  destination="$TMP_ROOT/network/bin"
  log="$TMP_ROOT/network/curl.log"
  mkdir -p "$(dirname "$log")"
  : > "$log"
  out=$(PATH="$FAKEBIN:$REAL_PATH" FM_FAKE_CURL_LOG="$log" FM_FAKE_CURL_MODE=network \
    "$ROOT/bin/fm-install-herdr.sh" "$destination" 2>&1) || rc=$?
  expect_code 1 "$rc" "non-certificate download failure"
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] || fail "non-certificate failure must not retry"
  [ ! -e "$destination/herdr" ] || fail "failed download unexpectedly installed Herdr"
  assert_contains "$out" "download failed" "non-certificate download diagnostic"
  pass "non-certificate download failures remain fail-closed"
}

test_certificate_failure_retries_verified_pin
test_non_certificate_failure_does_not_retry

echo "all fm-install-herdr tests passed"
