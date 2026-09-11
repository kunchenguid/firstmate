#!/usr/bin/env bash
# Characterization tests for fm-harness's marker and configuration resolution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness)
CONFIG="$TMP_ROOT/config"
mkdir -p "$CONFIG"

# A suite run from inside Cursor (or another verified harness) inherits ambient
# markers that outrank the markers each case sets. Scrub them so detection
# assertions depend only on the case's explicit environment.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

run_harness() {
  env -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    FM_CONFIG_OVERRIDE="$CONFIG" "$HARNESS" "$@"
}

test_verified_marker_precedes_other_markers() {
  local out
  out=$(CLAUDECODE=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed run_harness)
  [ "$out" = claude ] || fail "Claude marker did not take precedence: $out"
  pass "fm-harness: verified Claude marker precedes other harness markers"
}

test_crew_config_overrides_detected_harness() {
  local out
  printf 'codex\n' > "$CONFIG/crew-harness"
  out=$(CLAUDECODE=1 run_harness crew)
  [ "$out" = codex ] || fail "crew config did not override detected harness: $out"
  pass "fm-harness: concrete crew configuration overrides detected harness"
}

test_secondmate_fields_ignore_comments_and_resolve_tokens() {
  local harness model effort
  cat > "$CONFIG/secondmate-harness" <<'EOF'
# ignored comment

pi openai/gpt-5 high
EOF
  harness=$(run_harness secondmate)
  model=$(run_harness secondmate-model)
  effort=$(run_harness secondmate-effort)
  [ "$harness" = pi ] || fail "secondmate harness token was not resolved: $harness"
  [ "$model" = openai/gpt-5 ] || fail "secondmate model token was not resolved: $model"
  [ "$effort" = high ] || fail "secondmate effort token was not resolved: $effort"
  pass "fm-harness: secondmate configuration skips comments and exposes all tokens"
}

test_disabled_harness_refuses_detected_and_alias_values() {
  local out status
  printf 'grok\ncursor\n' > "$CONFIG/disabled-adapters"
  set +e
  out=$(GROK_AGENT=1 run_harness 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a disabled detected harness should refuse"
  assert_contains "$out" "harness 'grok' is disabled by config/disabled-adapters" \
    "disabled detected harness did not name the policy"
  set +e
  out=$(run_harness validate cursor-agent 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "the cursor-agent alias should refuse when cursor is disabled"
  assert_contains "$out" "harness 'cursor-agent' is disabled by config/disabled-adapters" \
    "disabled cursor alias did not name the policy"
  out=$(CLAUDECODE=1 run_harness)
  [ "$out" = claude ] || fail "an enabled harness should read the complete policy file, got '$out'"
  rm -f "$CONFIG/disabled-adapters"
  pass "fm-harness: disabled-adapters policy blocks detected and alias harnesses"
}

test_unlisted_adapter_is_enabled_after_nonmatching_entry() {
  local out status
  printf 'cursor\n# trailing comment\n' > "$CONFIG/disabled-adapters"
  set +e
  out=$(FM_DISABLED_ADAPTERS_CONFIG="$CONFIG/disabled-adapters" bash -c \
    '. "$1/bin/fm-disabled-adapters-lib.sh"; fm_disabled_adapter pi' _ "$ROOT" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "an unlisted adapter returned status $status: $out"
  [ -z "$out" ] || fail "an unlisted adapter wrote diagnostics: $out"

  chmod 000 "$CONFIG/disabled-adapters"
  set +e
  out=$(FM_DISABLED_ADAPTERS_CONFIG="$CONFIG/disabled-adapters" bash -c \
    '. "$1/bin/fm-disabled-adapters-lib.sh"; fm_disabled_adapter pi' _ "$ROOT" 2>&1)
  status=$?
  set -e
  chmod 600 "$CONFIG/disabled-adapters"
  [ "$status" -eq 2 ] || fail "an unreadable adapter config returned status $status: $out"
  assert_contains "$out" "error: cannot read disabled adapters config:" \
    "an unreadable adapter config did not report a read error"
  rm -f "$CONFIG/disabled-adapters"
  pass "disabled-adapters: nonmatching and trailing-comment configs return 1; unreadable returns 2"
}

adapter_test_paths() {  # <adapter>
  case "$1" in
    opencode) printf '%s\n' tests/fm-opencode-primary-live-e2e.test.sh ;;
    grok) printf '%s\n' tests/fm-grok-continuity-live-e2e.test.sh tests/fm-grok-harness.test.sh tests/fm-grok-stop-live-e2e.test.sh ;;
    kimi) printf '%s\n' tests/fm-kimi-harness.test.sh tests/fm-kimi-trust-check.test.sh tests/fm-kimi-turnend-hook.test.sh ;;
    gemini) printf '%s\n' tests/fm-gemini-harness.test.sh ;;
    muse) printf '%s\n' tests/fm-muse-harness.test.sh tests/fm-muse-signals-live-e2e.test.sh ;;
    rovo) printf '%s\n' tests/fm-rovo-harness.test.sh tests/fm-rovo-signals-live-e2e.test.sh ;;
    omp) printf '%s\n' tests/fm-omp-harness.test.sh tests/fm-omp-primary-live-e2e.test.sh ;;
    cursor) printf '%s\n' tests/fm-cursor-harness.test.sh tests/fm-cursor-primary.test.sh tests/fm-cursor-primary-live-e2e.test.sh tests/fm-wake-drain-open-decisions-cursor.test.sh ;;
    *) return 1 ;;
  esac
}

test_tracked_policy_blocks_every_listed_harness_and_test_lane() {
  local fakebin adapter path paths out policy_out listed coverage
  [ -f "$ROOT/config/disabled-adapters" ] || fail "tracked disabled-adapters policy is missing"
  fakebin=$(fm_fakebin "$TMP_ROOT/disabled-adapters")
  listed=$(FM_CONFIG_OVERRIDE="$ROOT/config" "$ROOT/bin/fm-test-run.sh" --list --all)

  while IFS= read -r adapter; do
    case "$adapter" in
      ''|\#*|zellij|orca|cmux|windows|gitlab|water7) continue ;;
    esac
    if policy_out=$(FM_CONFIG_OVERRIDE="$ROOT/config" "$HARNESS" validate "$adapter" 2>&1); then
      fail "disabled adapter '$adapter' passed the policy gate"
    else
      :
    fi
    assert_contains "$policy_out" "harness '$adapter' is disabled by config/disabled-adapters" \
      "disabled adapter '$adapter' did not fail through the policy gate"
    if out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE="$ROOT/config" FM_SPAWN_NO_GUARD=1 \
      "$ROOT/bin/fm-spawn.sh" "disabled-$adapter" projects/none "$adapter" --mode no-mistakes --yolo off 2>&1); then
      fail "disabled adapter '$adapter' was spawnable"
    else
      :
    fi
    paths=$(adapter_test_paths "$adapter") || fail "disabled adapter '$adapter' lacks a test-lane guard"
    while IFS= read -r path; do
      printf '%s\n' "$listed" | grep -Fqx "$path" \
        && fail "disabled adapter '$adapter' still selects $path"
    done <<<"$paths"
  done < "$ROOT/config/disabled-adapters"

  coverage=$(FM_CONFIG_OVERRIDE="$ROOT/config" "$ROOT/bin/fm-test-run.sh" --check-coverage)
  assert_contains "$coverage" "FM_TEST_COVERAGE ok" \
    "disabled adapter policy broke test coverage accounting"
  pass "tracked disabled harnesses cannot spawn or select their dedicated test lanes"
}

test_verified_marker_precedes_other_markers
test_crew_config_overrides_detected_harness
test_secondmate_fields_ignore_comments_and_resolve_tokens
test_disabled_harness_refuses_detected_and_alias_values
test_unlisted_adapter_is_enabled_after_nonmatching_entry
test_tracked_policy_blocks_every_listed_harness_and_test_lane
