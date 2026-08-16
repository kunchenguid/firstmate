#!/bin/sh
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -eu

# The sealed validation-cell lane stages only the pinned tool closure and
# has no python3.11 runtime; public CI remains the authoritative run.
if [ "${FM_TEST_SEALED_CELL:-0}" = 1 ]; then
  printf 'ok - sealed cell lane: python3.11 is outside the staged tool closure\n'
  exit 0
fi

command -v python3.11 >/dev/null
export PYTHONDONTWRITEBYTECODE=1

exec python3.11 -m unittest -v \
  tests.test_build_quota_axi_offline_proof \
  tests.test_build_quota_axi_offline_real_inputs \
  tests.test_build_sealed_bridge_runtimes \
  tests.test_bridge_cutover_transaction \
  tests.test_bridge_sealed_adoption \
  tests.test_prepare_bridge_cutover \
  tests.test_bridge_worker_state_transaction
