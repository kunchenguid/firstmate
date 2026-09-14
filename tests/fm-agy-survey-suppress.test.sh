#!/usr/bin/env bash
# tests/fm-agy-survey-suppress.test.sh - regression for the agy feedback survey
# suppression that prevents the interactive "[1] Good [2] Fine [3] Bad [0] Skip"
# prompt from wedging autonomous workers.
#
# The contracts pinned here:
#   1. A settings file that already has showFeedbackSurvey=false is left
#      unchanged (fast path).
#   2. A settings file without the key gets it set to false.
#   3. A settings file that is a symlink (nix home-manager) is replaced with a
#      real file carrying the updated content.
#   4. An absent settings file is a no-op.
#   5. A missing jq is a no-op (fail-open).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-agy-lib.sh
. "$ROOT/bin/fm-agy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-survey-suppress)
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# 1. Fast path: already suppressed
# ---------------------------------------------------------------------------
test_already_suppressed() {
  local d="$TMP_ROOT/already"
  mkdir -p "$d"
  printf '{"enableTelemetry":false,"showFeedbackSurvey":false}\n' > "$d/settings.json"
  local before
  before=$(cat "$d/settings.json")
  FM_AGY_SETTINGS="$d/settings.json" fm_agy_suppress_feedback_survey
  local after
  after=$(cat "$d/settings.json")
  [ "$before" = "$after" ] || fail "already-suppressed settings were modified"
  pass "already-suppressed settings are unchanged"
}

# ---------------------------------------------------------------------------
# 2. Missing key: inserted as false
# ---------------------------------------------------------------------------
test_missing_key_inserted() {
  local d="$TMP_ROOT/missing-key"
  mkdir -p "$d"
  printf '{"enableTelemetry":false,"model":"test"}\n' > "$d/settings.json"
  FM_AGY_SETTINGS="$d/settings.json" fm_agy_suppress_feedback_survey
  if jq -e '.showFeedbackSurvey == false' "$d/settings.json" >/dev/null 2>&1; then
    pass "missing key inserted as false"
  else
    fail "showFeedbackSurvey was not set to false"
  fi
  # Verify other keys survived.
  if jq -e '.enableTelemetry == false and .model == "test"' "$d/settings.json" >/dev/null 2>&1; then
    pass "existing keys preserved"
  else
    fail "existing keys were lost"
  fi
}

# ---------------------------------------------------------------------------
# 3. Symlink replaced with real file
# ---------------------------------------------------------------------------
test_symlink_replaced() {
  local d="$TMP_ROOT/symlink"
  mkdir -p "$d/store"
  printf '{"enableTelemetry":false}\n' > "$d/store/settings.json"
  ln -sf "$d/store/settings.json" "$d/settings.json"
  [ -L "$d/settings.json" ] || fail "precondition: settings.json is not a symlink"
  FM_AGY_SETTINGS="$d/settings.json" fm_agy_suppress_feedback_survey
  if [ -L "$d/settings.json" ]; then
    fail "symlink was not replaced"
  fi
  if jq -e '.showFeedbackSurvey == false' "$d/settings.json" >/dev/null 2>&1; then
    pass "symlink replaced with real file containing showFeedbackSurvey=false"
  else
    fail "replaced file does not contain showFeedbackSurvey=false"
  fi
  # Original symlink target must be unchanged.
  if jq -e '.showFeedbackSurvey' "$d/store/settings.json" >/dev/null 2>&1; then
    fail "symlink target was modified"
  else
    pass "symlink target was not modified"
  fi
}

# ---------------------------------------------------------------------------
# 4. Absent settings file is a no-op
# ---------------------------------------------------------------------------
test_absent_noop() {
  FM_AGY_SETTINGS="$TMP_ROOT/nonexistent/settings.json" fm_agy_suppress_feedback_survey
  [ ! -e "$TMP_ROOT/nonexistent/settings.json" ] || fail "absent file was created"
  pass "absent settings file is a no-op"
}

# ---------------------------------------------------------------------------
# 5. Missing jq is a no-op (fail-open)
# ---------------------------------------------------------------------------
test_no_jq_noop() {
  local d="$TMP_ROOT/no-jq"
  mkdir -p "$d"
  printf '{"enableTelemetry":false}\n' > "$d/settings.json"
  local before
  before=$(cat "$d/settings.json")
  # Shadow jq with a nonexistent path.
  mkdir -p "$d/empty-bin"
  (
    export PATH="$d/empty-bin"
    FM_AGY_SETTINGS="$d/settings.json" fm_agy_suppress_feedback_survey
  )
  local after
  after=$(cat "$d/settings.json")
  [ "$before" = "$after" ] || fail "settings modified without jq"
  pass "missing jq is a no-op"
}

test_already_suppressed
test_missing_key_inserted
test_symlink_replaced
test_absent_noop
test_no_jq_noop

echo "all tests passed"
