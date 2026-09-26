#!/usr/bin/env bash
# Token-free Pi Calm terminal geometry, interaction and session persistence.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CALM_PI_E2E pi herdr node
FM_CALM_PI_LIVE_ONLY=1 exec bash "$ROOT/tests/fm-calm-pi-extension.test.sh"
