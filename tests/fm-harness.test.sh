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

test_verified_marker_precedes_other_markers
test_crew_config_overrides_detected_harness
test_secondmate_fields_ignore_comments_and_resolve_tokens
