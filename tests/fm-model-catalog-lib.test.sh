#!/usr/bin/env bash
# Characterization coverage for model-catalog file validation primitives.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-model-catalog-lib-tests)
CONFIG="$TMP_ROOT/config"
mkdir -p "$CONFIG"

# shellcheck source=bin/fm-model-catalog-lib.sh disable=SC1091
. "$ROOT/bin/fm-model-catalog-lib.sh"

valid_catalog() {
  cat <<'EOF'
{
  "pools": [
    {
      "pool": "codex-cli",
      "provider": "openai",
      "plan": "pro",
      "harness": "codex",
      "account": "primary",
      "models": ["gpt-5.6-sol"],
      "quota_readable": true
    }
  ],
  "excluded": [
    {
      "what": "legacy pool",
      "why": "retired"
    }
  ]
}
EOF
}

printf '%s' "$(valid_catalog)" > "$CONFIG/model-catalog.json"
fm_model_catalog_file_valid "$CONFIG/model-catalog.json" \
  || fail "valid catalog should pass schema validation"

printf '{"pools":[]}' > "$CONFIG/model-catalog.json"
if fm_model_catalog_file_valid "$CONFIG/model-catalog.json"; then
  fail "empty pools array should be rejected"
fi
assert_contains "$FM_MODEL_CATALOG_ERROR" "pools must be non-empty" \
  "empty pools should name the schema failure"

printf '%s' "$(valid_catalog)" | jq '.pools[0].gap = 42' > "$CONFIG/model-catalog.json"
if fm_model_catalog_file_valid "$CONFIG/model-catalog.json"; then
  fail "non-string optional pool fields should be rejected"
fi
assert_contains "$FM_MODEL_CATALOG_ERROR" "valid pool" \
  "invalid optional pool field types should name the schema failure"

printf 'not json' > "$CONFIG/model-catalog.json"
if fm_model_catalog_file_valid "$CONFIG/model-catalog.json"; then
  fail "malformed JSON should be rejected"
fi
assert_contains "$FM_MODEL_CATALOG_ERROR" "malformed JSON" \
  "malformed JSON should name the parse failure"

pass "model-catalog-lib validates schema, JSON, and unsafe artifacts"
echo "# fm-model-catalog-lib.test.sh: all assertions passed"
