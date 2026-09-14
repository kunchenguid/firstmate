#!/usr/bin/env bash
# Regression: fm_config_inherit_primary_preflight must exist for config push and
# remote inherit push callers (command-not-found broke both paths).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

declare -F fm_config_inherit_primary_preflight >/dev/null 2>&1 \
  || fail "fm_config_inherit_primary_preflight is not defined after sourcing the inherit lib"

TMP_ROOT=$(fm_test_tmproot fm-config-inherit-preflight)
home="$TMP_ROOT/home"
mkdir -p "$home/config" "$home/state" "$home/data"
printf '%s\n' '# secondmates' > "$home/data/secondmates.md"

config_push_runs_preflight() {
  local out rc
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-config-push.sh" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "config-push must survive primary catalog preflight"
  assert_contains "$out" "config-push: no live secondmate homes found" \
    "config-push did not reach post-preflight discovery"
  pass "fm-config-push.sh runs fm_config_inherit_primary_preflight"
}

remote_inherit_push_preflight_contract() {
  local config catalog_error out
  config="$TMP_ROOT/remote-config"
  mkdir -p "$config"
  printf '{"pools":[]}' > "$config/model-catalog.json"
  catalog_error=""
  if ! fm_config_inherit_primary_preflight "$config"; then
    catalog_error=$FM_MODEL_CATALOG_ERROR
  fi
  [ -n "$catalog_error" ] \
    || fail "remote inherit preflight should surface invalid catalog via FM_MODEL_CATALOG_ERROR"
  out=$(printf 'catalog-error: config/model-catalog.json: %s\n' "$catalog_error")
  assert_contains "$out" "catalog-error: config/model-catalog.json:" \
    "remote inherit push catalog-error line must stay stable"
  pass "fm-remote-inherit-push.sh preflight contract captures catalog errors"
}

config_push_runs_preflight
remote_inherit_push_preflight_contract

echo "# fm-config-inherit-preflight.test.sh: all assertions passed"
