#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

out=$(env -u FM_TEST_RUNNER_ACTIVE "$ROOT/tests/fm-pi-direct-continuity.test.sh") || {
  printf '%s\n' "$out" >&2
  exit 1
}
printf '%s\n' "$out" | grep -Fqx 'PI_EXACT_DELIVERY_ASSOCIATION_PROOF_OK' || {
  printf '%s\n' "$out" >&2
  echo "not ok - installed Pi exact-delivery assertions did not complete" >&2
  exit 1
}
printf '%s\n' 'ok - installed Pi exact delivery association preserved'
