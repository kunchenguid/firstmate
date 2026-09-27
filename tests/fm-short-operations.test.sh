#!/usr/bin/env bash
# Isolated real Git effects through the public short-agent API and guarded
# action owner. Only the Pi model is doubled; no live fleet or Herdr calls.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ "$(uname -s)" = Linux ] || { echo "skip: operation identity requires Linux /proc"; exit 0; }
TMP_ROOT=${FM_SHORT_OPERATION_EVIDENCE:-$(fm_test_tmproot fm-short-operations)}
mkdir -p "$TMP_ROOT"
node "$ROOT/tests/fm-short-operations-cases.mjs" "$ROOT" "$TMP_ROOT"
pass 'short operation grants, real sync/recovery effects, receipts and refusals'
