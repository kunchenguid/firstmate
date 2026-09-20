#!/usr/bin/env bash
# Token-free real app-server effective-catalog guard for the native host policy.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_LIVE_NATIVE_APP_POLICY node codex
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    if [ "${FM_LIVE_NATIVE_APP_POLICY:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
      printf 'not ok - FM_LIVE_NATIVE_APP_POLICY was requested but native app-server policy tests require Windows\n' >&2
      exit 1
    fi
    printf 'skip: live: Windows required for native app-server policy tests\n'
    exit 0
    ;;
esac
node "$ROOT/tests/fixtures/native-owner/AppServerPolicy.mjs"
