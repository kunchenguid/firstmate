#!/bin/sh
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -eu

# A sealed validation cell without python3.11 skips explicitly; a cell
# booted from the golden image carries python3.11 and runs the suite in
# full. Public CI remains authoritative either way.
if [ "${FM_TEST_SEALED_CELL:-0}" = 1 ] && ! command -v python3.11 >/dev/null 2>&1; then
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
  tests.test_bridge_worker_state_transaction \
  tests.test_fm_crosscheck_ledger
