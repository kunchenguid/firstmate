#!/usr/bin/env bash
# Characterization tests for fm-doc-audience-check.sh's CLI contract.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-doc-audience-check.sh"
INVENTORY="$ROOT/docs/documentation-audiences.json"
TMP_ROOT=$(fm_test_tmproot fm-doc-audience-check)

test_repository_inventory_passes() {
  local output rc=0
  output=$("$CHECK" 2>&1) || rc=$?
  expect_code 0 "$rc" "the tracked documentation inventory must pass"
  assert_contains "$output" "fm-doc-audience-check: ok surfaces=" \
    "success output must report the surface count"
  assert_contains "$output" "local_links=" \
    "success output must report the local-link count"
  pass "fm-doc-audience-check accepts the repository inventory"
}

test_duplicate_surface_is_rejected() {
  local duplicate="$TMP_ROOT/duplicate.json" output rc=0
  python3 - "$INVENTORY" "$duplicate" <<'PY'
import json
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
data = json.loads(source.read_text(encoding="utf-8"))
data["surfaces"].append(dict(data["surfaces"][0]))
destination.write_text(json.dumps(data) + "\n", encoding="utf-8")
PY
  output=$("$CHECK" --inventory "$duplicate" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "duplicate surfaces must fail validation"
  assert_contains "$output" "surfaces classified more than once" \
    "duplicate-surface failure must explain the violated invariant"
  pass "fm-doc-audience-check rejects duplicate surface classifications"
}

test_repository_inventory_passes
test_duplicate_surface_is_rejected
