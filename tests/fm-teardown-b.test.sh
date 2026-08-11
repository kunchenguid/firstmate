#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/fm-teardown-suite.sh disable=SC1091
FM_TEST_PART_INDEX=2 FM_TEST_PART_TOTAL=2 . "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-suite.sh"
