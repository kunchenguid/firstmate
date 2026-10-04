#!/usr/bin/env bash
# Behavioral regressions for the removed Twitter/X Relay integration.
set -u

# shellcheck source=tests/fixtures.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-relay-removal)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

test_legacy_config_does_not_activate_bootstrap() {
  local home fakebin out before_shim before_cadence
  home="$TMP_ROOT/bootstrap-home"
  fakebin="$TMP_ROOT/fakebin"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects" "$fakebin"
  printf '%s\n' 'FMX_PAIRING_TOKEN=retained-token' 'FMX_RELAY_URL=https://relay.invalid' > "$home/.env"
  printf '%s\n' '#!/usr/bin/env bash' 'printf invoked > "$FM_HOME/state/legacy-shim-ran"' > "$home/state/x-watch.check.sh"
  printf '%s\n' 'export FM_CHECK_INTERVAL=30' > "$home/config/x-mode.env"
  before_shim=$(cksum "$home/state/x-watch.check.sh")
  before_cadence=$(cksum "$home/config/x-mode.env")

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    FM_BOOTSTRAP_LOCKED=1 PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-bootstrap.sh" 2>&1)

  [ ! -e "$home/state/legacy-shim-ran" ] || fail "bootstrap executed the retained Relay shim"
  [ "$(cksum "$home/state/x-watch.check.sh")" = "$before_shim" ] || fail "bootstrap rewrote retained Relay evidence"
  [ "$(cksum "$home/config/x-mode.env")" = "$before_cadence" ] || fail "bootstrap rewrote retained Relay cadence evidence"
  case "$out" in *FMX*|*Relay*|*x-mode*) fail "bootstrap still surfaced Relay activation: $out" ;; esac
  pass "bootstrap ignores retained FMX configuration and preserves historical artifacts"
}

test_legacy_artifacts_do_not_arm_supervision() {
  local home primary out
  home="$TMP_ROOT/supervision-home"
  primary="$TMP_ROOT/supervision-primary"
  mkdir -p "$home/state" "$home/config"
  git init -q -b main "$primary"
  printf '%s\n' '#!/usr/bin/env bash' 'printf invoked > "$FM_HOME/state/legacy-shim-ran"' > "$home/state/x-watch.check.sh"
  printf '%s\n' 'export FM_CHECK_INTERVAL=30' > "$home/config/x-mode.env"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$primary" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-guard.sh" 2>&1)
  [ -z "$out" ] || fail "retained Relay artifacts still armed the supervision guard: $out"
  [ ! -e "$home/state/legacy-shim-ran" ] || fail "the supervision guard executed the retained Relay shim"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness codex)
  case "$out" in *x-mode.env*|*Relay*|*"X mode"*) fail "supervision instructions still activated retained Relay state: $out" ;; esac
  pass "retained Relay artifacts neither arm supervision nor alter its instructions"
}

test_removed_command_family_has_no_passthrough() {
  local home out rc
  home="$TMP_ROOT/tasks-home"
  mkdir -p "$home/data"
  set +e
  out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" public-followup list 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "removed public-followup command family remained callable"
  case "$out" in *'tasks-axi is required for the public-followup compatibility family'*)
    fail "removed public-followup passthrough remained active"
  esac
  pass "task CLI no longer exposes the Relay public-followup command family"
}

test_legacy_config_does_not_activate_bootstrap
test_legacy_artifacts_do_not_arm_supervision
test_removed_command_family_has_no_passthrough
