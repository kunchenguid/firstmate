#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -eu

[ "${FM_TEST_RUNNER_ACTIVE:-}" = firstmate-test-runner-v1 ]
[ "${FM_TEST_HERDR_CAPABILITY:-}" = hermetic ]
printf 'ok - direct hermetic execution crossed the authoritative runner\n'
