#!/usr/bin/env bash
# tests/ak47-weekly-review.test.sh - the weekly review.
#
# The review reads its own logs and proposes threshold changes as a diff. The
# two things that must never happen: it writes the budget itself, and it widens
# its own authority by inventing an action class.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEW="$ROOT/ak47/weekly-review.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SANDBOX=
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ak47-review-tests.XXXXXX")

export AK47_STATE=$SANDBOX/state
export AK47_CACHE=$SANDBOX/cache
export AK47_CONFIG=$SANDBOX/config
export AK47_TMP_ROOT=$SANDBOX/tmp
export FM_HOME=$SANDBOX/fmhome
mkdir -p "$AK47_STATE" "$AK47_CACHE" "$AK47_CONFIG" "$AK47_TMP_ROOT" "$FM_HOME/state"

# A samples.log with `n` lines of one metric at a fixed value.
seed_samples() {
  local key=$1 value=$2 n=${3:-20} i now
  now=$(date +%s)
  : >"$AK47_STATE/samples.log"
  # Timestamps must fall inside the review's window, so they are relative to
  # now rather than a fixed epoch.
  for ((i = 0; i < n; i++)); do
    printf '%s %s=%s\n' "$((now - (n - i) * 300))" "$key" "$value" \
      >>"$AK47_STATE/samples.log"
  done
}

# --- the report -----------------------------------------------------------------

test_refuses_without_samples() {
  : >"$AK47_STATE/samples.log"
  if "$REVIEW" --print >/dev/null 2>&1; then
    fail "the review produced a report with no samples to read"
  fi
  pass "the review refuses when there are no samples"
}

test_reports_no_changes_when_every_metric_sits_mid_band() {
  # load15 ceiling is 32. 20 is 62% of it: past the 50% lower threshold and
  # short of the 80% raise threshold, so nothing should move.
  seed_samples load15 20
  local out
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  case "$out" in
    *"None. Every ceiling still describes the box."*) : ;;
    *) fail "the review proposed a change for a metric sitting mid-band: $out" ;;
  esac
  pass "the review reports NO_CHANGES when every metric sits mid-band"
}

test_proposes_a_raise_when_p95_sits_near_the_ceiling() {
  # load15 ceiling 32; 30 is 94% of it, well past the 80% raise threshold.
  seed_samples load15 30
  local out
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  case "$out" in
    *"- load15: 32 -> "*) : ;;
    *) fail "the review did not propose raising a ceiling its p95 nearly touches: $out" ;;
  esac
  pass "the review proposes a raise when p95 sits near the ceiling"
}

test_proposes_a_lower_when_p95_sits_far_below_the_ceiling() {
  # load15 ceiling 32; 2 is 6% of it, well under the 50% lower threshold.
  seed_samples load15 2
  local out
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  case "$out" in
    *"- load15: 32 -> "*) : ;;
    *) fail "the review did not propose lowering a ceiling its p95 never approaches: $out" ;;
  esac
  pass "the review proposes a lower when p95 sits far below the ceiling"
}

test_emits_a_unified_diff_against_the_budget() {
  seed_samples load15 30
  local out
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  case "$out" in
    *"--- "*"+++ "*) : ;;
    *) fail "the review printed no unified diff header: $out" ;;
  esac
  case "$out" in
    *"@@ "*) : ;;
    *) fail "the review printed no diff hunk: $out" ;;
  esac
  pass "the review emits a unified diff against the budget"
}

# --- what it must never do ------------------------------------------------------

test_never_writes_the_budget() {
  seed_samples load15 30
  local before after
  before=$(cksum <"$ROOT/ak47/budget.conf")
  "$REVIEW" --print --no-inbox >/dev/null 2>&1 || true
  after=$(cksum <"$ROOT/ak47/budget.conf")
  [ "$before" = "$after" ] \
    || fail "the review rewrote ak47/budget.conf; a review that edits its own thresholds is not a review"
  pass "the review never writes the budget"
}

test_never_proposes_a_new_action_class() {
  seed_samples load15 30
  local out
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  # The only permitted change lines are threshold moves on keys the budget
  # already carries. Anything else is the review widening its own authority.
  local line key
  while IFS= read -r line; do
    case "$line" in
      "- "*": "*" -> "*) : ;;
      *) continue ;;
    esac
    key=${line#- }
    key=${key%%:*}
    grep -q "^${key}|" "$ROOT/ak47/budget.conf" \
      || fail "the review proposed a change to '$key', which is not a budget row"
  done <<<"$out"
  pass "the review never proposes a new action class"
}

test_states_what_it_will_not_do() {
  seed_samples load15 30
  local out
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  case "$out" in
    *"will not"*) : ;;
    *) fail "the review does not state the limits of its own authority: $out" ;;
  esac
  pass "the review states what it will not do"
}

test_writes_a_dated_report() {
  seed_samples load15 30
  "$REVIEW" --no-inbox >/dev/null 2>&1 || fail "the review failed"
  local found
  found=$(find "$AK47_STATE" -maxdepth 1 -name 'review-*.md' -print -quit)
  [ -n "$found" ] || fail "the review wrote no dated report"
  [ -s "$found" ] || fail "the review wrote an empty report"
  pass "the review writes a dated report"
}

test_refuses_a_malformed_budget() {
  seed_samples load15 30
  local fake=$SANDBOX/fake
  mkdir -p "$fake/ak47"
  cp "$REVIEW" "$fake/ak47/weekly-review.sh"
  cp -r "$ROOT/ak47/lib" "$fake/ak47/lib"
  printf '%s\n' 'load15|notanumber|max|load|because' >"$fake/ak47/budget.conf"
  if "$fake/ak47/weekly-review.sh" --print --no-inbox >/dev/null 2>&1; then
    fail "the review accepted a budget row with a non-numeric ceiling"
  fi
  pass "the review refuses a malformed budget"
}

test_refuses_without_samples
test_reports_no_changes_when_every_metric_sits_mid_band
test_proposes_a_raise_when_p95_sits_near_the_ceiling
test_proposes_a_lower_when_p95_sits_far_below_the_ceiling
test_emits_a_unified_diff_against_the_budget
test_never_writes_the_budget
test_never_proposes_a_new_action_class
test_states_what_it_will_not_do
test_writes_a_dated_report
test_refuses_a_malformed_budget
