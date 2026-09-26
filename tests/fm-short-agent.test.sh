#!/usr/bin/env bash
# Behavioral headless lifecycle, read boundary, budgets and outcome replay.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-short-agent)
node "$ROOT/tests/fm-short-agent-cases.mjs" "$ROOT" "$TMP_ROOT"
pass 'short-agent read boundary, asynchronous lifecycle and durable notification'
