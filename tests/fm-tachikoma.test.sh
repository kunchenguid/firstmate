#!/usr/bin/env bash
# Repository bridge; module-local tests own routing and adapter behavior.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
node --test "$ROOT"/modules/tachikoma/tests/*.test.mjs
