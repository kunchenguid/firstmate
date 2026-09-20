#!/usr/bin/env bash
# Token-free native Windows receipt persistence and file-boundary tests.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_LIVE_NATIVE_RECEIPTS powershell.exe git node
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    if [ "${FM_LIVE_NATIVE_RECEIPTS:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
      printf 'not ok - FM_LIVE_NATIVE_RECEIPTS was requested but native receipt tests require Windows\n' >&2
      exit 1
    fi
    printf 'skip: live: Windows required for native receipt tests\n'
    exit 0
    ;;
esac
powershell.exe -NoProfile -NonInteractive -File "$(cygpath -w "$ROOT/tests/fixtures/native-owner/Build.ps1")"
node "$ROOT/tests/fixtures/native-owner/Lifecycle.mjs"
