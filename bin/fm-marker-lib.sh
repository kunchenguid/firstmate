#!/usr/bin/env bash
# fm-marker-lib.sh - compatibility entry point for from-firstmate routing.
#
# bin/fm-operational-input.sh owns current operational-input construction,
# parsing, marker bytes, and the established from-firstmate compatibility
# carrier. Existing callers source this path so they do not need a flag-day
# migration. No side effects on source. set -u / set -e safe.
# Removal milestone: delete this file in the first tagged firstmate release
# after every tracked caller sources bin/fm-operational-input.sh directly
# (`git grep -l fm-marker-lib` outside this file and tests is empty).

_FM_MARKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-operational-input.sh
. "$_FM_MARKER_LIB_DIR/fm-operational-input.sh"
unset _FM_MARKER_LIB_DIR
