#!/usr/bin/env bash
# Portable coverage for Firstmate's default Pi bash timeout resolver.
# This file deliberately stays free of Node and TypeScript so the stock macOS
# Bash 3.2 CI lane can run it; the Pi extension runtime behavior that needs a
# Node-capable runner lives in tests/fm-pi-bash-timeout.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVER="$ROOT/bin/fm-pi-bash-timeout.sh"
TMP_ROOT=$(fm_test_tmproot fm-pi-bash-timeout-resolver)

resolve_for_home() {
  local home=$1
  env -u FM_PI_BASH_TIMEOUT_SECS FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$RESOLVER"
}

test_resolver_precedence_disable_and_invalid_fallback() {
  local home out
  home="$TMP_ROOT/resolver-home"
  mkdir -p "$home/config"

  out=$(resolve_for_home "$home")
  [ "$out" = 900 ] || fail "missing Pi timeout config should resolve to 900, got '$out'"

  printf '1200\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ "$out" = 1200 ] || fail "Pi timeout config should resolve to 1200, got '$out'"

  printf '2147483\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ "$out" = 2147483 ] || fail "Pi's maximum integer timeout should be accepted, got '$out'"

  printf '2147484\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ "$out" = 900 ] || fail "timeout above Pi's maximum should fall back to 900, got '$out'"

  printf '999999999999999999999999999999999999999\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ "$out" = 900 ] || fail "oversized timeout should safely fall back to 900, got '$out'"

  printf '0\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ -z "$out" ] || fail "config/pi-bash-timeout=0 should disable injection, got '$out'"

  printf 'not-a-timeout\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ "$out" = 900 ] || fail "invalid Pi timeout config should safely fall back to 900, got '$out'"

  printf '1200\n' > "$home/config/pi-bash-timeout"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_PI_BASH_TIMEOUT_SECS=NoNe "$RESOLVER")
  [ -z "$out" ] || fail "FM_PI_BASH_TIMEOUT_SECS=NoNe should override and disable file config, got '$out'"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_PI_BASH_TIMEOUT_SECS=OFF "$RESOLVER")
  [ -z "$out" ] || fail "FM_PI_BASH_TIMEOUT_SECS=OFF should override and disable file config, got '$out'"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_PI_BASH_TIMEOUT_SECS=2400 "$RESOLVER")
  [ "$out" = 2400 ] || fail "FM_PI_BASH_TIMEOUT_SECS should override file config, got '$out'"

  pass "Pi bash timeout resolver: default, file, env precedence, disable, and invalid fallback"
}

test_gitignore_and_shellcheck() {
  git -C "$ROOT" check-ignore -q config/pi-bash-timeout \
    || fail "config/pi-bash-timeout is not gitignored"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$RESOLVER" >/dev/null 2>&1 || fail "fm-pi-bash-timeout.sh is not shellcheck-clean"
  fi
  pass "Pi timeout config is local and the resolver is shellcheck-clean"
}

test_resolver_precedence_disable_and_invalid_fallback
test_gitignore_and_shellcheck

echo "# all fm-pi-bash-timeout-resolver tests passed"
