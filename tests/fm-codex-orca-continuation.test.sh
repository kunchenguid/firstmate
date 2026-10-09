#!/usr/bin/env bash
# Public-interface continuation tests: real watcher/queue/ACK, controlled Orca
# transport, isolated primary homes. The Codex-shaped parent is not vendor proof.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-orca-continuation)
bash -c 'exec -a codex bash -c '\''python3 "$1" "$2" "$3"; rc=$?; exit "$rc"'\'' fixture "$@"' fixture \
  "$ROOT/tests/fm-orca-continuation.test.py" "$ROOT" "$TMP_ROOT"
