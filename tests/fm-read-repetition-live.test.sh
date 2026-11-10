#!/usr/bin/env bash
# Token-free installed Pi RPC guard. Uses a synthetic in-process provider,
# fake Bash execution, private home/session directories and no credentials.
# Linux only; enable FM_READ_REPETITION_LIVE=1 to require the installed tools.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_READ_REPETITION_LIVE pi node
if [ "$(uname -s)" != Linux ]; then
  printf 'skip: read guard supports Linux only\n'
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-read-live)
PI_VERSION=$(pi --version)
if node "$ROOT/tests/fixtures/fm-read-repetition-live.mjs" "$(command -v pi)" "$TMP_ROOT"; then
  pass "Pi $PI_VERSION installed RPC read guard: veto, abort, durable latch, operational denial and user reset"
else
  fail "Pi $PI_VERSION installed RPC read guard failed"
fi
