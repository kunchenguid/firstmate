#!/usr/bin/env bash
set -u
# shellcheck source=tests/fm-account-routing-suite.sh disable=SC1091
FM_TEST_PART_INDEX=1 FM_TEST_PART_TOTAL=2 . "$(dirname "${BASH_SOURCE[0]}")/fm-account-routing-suite.sh"
