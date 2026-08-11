#!/bin/sh
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -eu

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
