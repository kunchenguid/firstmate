#!/usr/bin/env bash
# Regression for the committed routing-refusal candidate inventory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

"$ROOT/bin/fm-routing-guard-inventory.sh" --check \
  || fail "committed routing-refusal candidate inventory is stale"

pass "committed routing-refusal candidate inventory matches the dispatch sources"
