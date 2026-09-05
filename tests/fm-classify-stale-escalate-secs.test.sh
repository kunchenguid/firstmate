#!/usr/bin/env bash
# tests/fm-classify-stale-escalate-secs.test.sh - config/stale-escalate-secs
# (bin/fm-classify-lib.sh's fm_stale_escalate_secs), the LOCAL, gitignored
# per-home override for FM_STALE_ESCALATE_SECS documented in
# docs/configuration.md. ONE resolver backs both bin/fm-watch.sh and
# bin/fm-supervise-daemon.sh so the effective wedge-escalation threshold cannot
# drift between the two supervisors; these tests drive the real function over
# a crafted config directory rather than asserting its source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-stale-escalate-secs-tests)

case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

test_absent_config_falls_through_to_env_then_default() {
  local dir
  dir=$(case_dir absent)
  [ "$(fm_stale_escalate_secs "$dir" 240)" = 240 ] \
    || fail "an absent config file did not fall through to the caller's default"
  [ "$(FM_STALE_ESCALATE_SECS=999 fm_stale_escalate_secs "$dir" 240)" = 999 ] \
    || fail "an absent config file did not fall through to FM_STALE_ESCALATE_SECS"
  pass "an absent config/stale-escalate-secs falls through to the env var, then the default"
}

test_valid_config_overrides_the_env_var() {
  local dir
  dir=$(case_dir valid-overrides-env)
  printf '120\n' > "$dir/stale-escalate-secs"
  [ "$(FM_STALE_ESCALATE_SECS=999 fm_stale_escalate_secs "$dir" 240)" = 120 ] \
    || fail "a valid config file did not override FM_STALE_ESCALATE_SECS"
  [ "$(fm_stale_escalate_secs "$dir" 240)" = 120 ] \
    || fail "a valid config file was not read with no env var set"
  pass "a valid config/stale-escalate-secs overrides FM_STALE_ESCALATE_SECS for this home"
}

test_config_value_tolerates_surrounding_whitespace() {
  local dir
  dir=$(case_dir whitespace)
  printf '  60 \n' > "$dir/stale-escalate-secs"
  [ "$(fm_stale_escalate_secs "$dir" 240)" = 60 ] \
    || fail "surrounding whitespace in the config value was not tolerated"
  pass "config/stale-escalate-secs tolerates surrounding whitespace"
}

test_malformed_config_falls_through_rather_than_erroring() {
  local dir
  dir=$(case_dir malformed)
  printf 'not-a-number\n' > "$dir/stale-escalate-secs"
  [ "$(FM_STALE_ESCALATE_SECS=999 fm_stale_escalate_secs "$dir" 240)" = 999 ] \
    || fail "a non-numeric config value was not rejected in favor of the env var"

  printf '0\n' > "$dir/stale-escalate-secs"
  [ "$(fm_stale_escalate_secs "$dir" 240)" = 240 ] \
    || fail "a zero config value was not rejected in favor of the default"

  printf '' > "$dir/stale-escalate-secs"
  [ "$(fm_stale_escalate_secs "$dir" 240)" = 240 ] \
    || fail "an empty config file was not rejected in favor of the default"

  printf -- '-5\n' > "$dir/stale-escalate-secs"
  [ "$(fm_stale_escalate_secs "$dir" 240)" = 240 ] \
    || fail "a negative config value was not rejected in favor of the default"
  pass "a malformed config/stale-escalate-secs falls through to the env var, then the default, never erroring"
}

test_absent_config_falls_through_to_env_then_default
test_valid_config_overrides_the_env_var
test_config_value_tolerates_surrounding_whitespace
test_malformed_config_falls_through_rather_than_erroring
