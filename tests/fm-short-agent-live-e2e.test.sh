#!/usr/bin/env bash
# Opt-in supported Pi SDK test: independent real model, parent responsiveness,
# actual extension registration, parent-only sentinel exclusion and evidence.
# No Herdr calls or running fleet records. FM_SHORT_LIVE_EVIDENCE retains output.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_SHORT_AGENT_LIVE_E2E pi node
TMP_ROOT=${FM_SHORT_LIVE_EVIDENCE:-$(fm_test_tmproot fm-short-agent-live)}
mkdir -p "$TMP_ROOT"
node "$ROOT/tests/fm-short-plugin-sdk.mjs" "$ROOT" "$TMP_ROOT"
node "$ROOT/tests/fm-short-agent-live.mjs" "$ROOT" "$TMP_ROOT"
pass 'real Pi short task stays independent while the parent accepts another prompt'
