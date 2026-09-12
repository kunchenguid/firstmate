#!/usr/bin/env bash
# Behavior guard for the always-loaded startup-surface budget.
#
# AGENTS.md and the one rendered supervision block are paid for by every fleet
# session on every turn, and both grew silently before (585 -> 958 lines
# between two AGENTS.md restructures) because nothing enforced their size.
# bin/fm-startup-surface-budget.sh is that enforcement; these tests prove it
# actually refuses growth, actually accepts a surface within budget, and points
# the reader at the placement decision that avoids the growth.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUDGET="$ROOT/bin/fm-startup-surface-budget.sh"
TMPROOT=$(fm_test_tmproot fm-startup-surface) || fail "fixture root could not be created"

# The guard reports its own ceiling, so a test can bracket it without pinning a
# number that a reviewed ceiling change would have to update in two places.
agents_ceiling() {
  "$BUDGET" 2>/dev/null \
    | sed -n 's/^STARTUP SURFACE  AGENTS\.md .*(ceiling \([0-9][0-9]*\) .*/\1/p'
}

# A fixture checkout whose AGENTS.md is ours while bin/ and docs/ stay the real
# ones, so the supervision blocks measured are the real tracked prose.
fixture_root() { # <agents-md-bytes>
  local bytes=$1 fixture
  fixture=$(mktemp -d "$TMPROOT/surface.XXXXXX") || return 1
  ln -s "$ROOT/bin" "$fixture/bin" || return 1
  ln -s "$ROOT/docs" "$fixture/docs" || return 1
  LC_ALL=C dd if=/dev/zero bs=1 count="$bytes" 2>/dev/null | LC_ALL=C tr '\0' 'x' \
    > "$fixture/AGENTS.md" || return 1
  [ "$(LC_ALL=C command wc -c < "$fixture/AGENTS.md" | tr -d '[:space:]')" = "$bytes" ] || return 1
  printf '%s\n' "$fixture"
}

test_reports_the_current_surface_and_passes() {
  local out
  out=$("$BUDGET" 2>&1) || fail "the repo's own startup surface must be within its budget: $out"
  assert_contains "$out" "STARTUP SURFACE  AGENTS.md" "the report names the AGENTS.md measurement"
  assert_contains "$out" "STARTUP SURFACE  supervision block" "the report names the supervision-block measurement"
  assert_contains "$out" "STARTUP SURFACE  composed" "the report names the composed measurement"
  assert_contains "$out" "STARTUP SURFACE: within budget." "a surface within budget says so"
  pass "reports every component and passes on the tracked surface"
}

test_refuses_a_grown_always_loaded_surface() {
  local ceiling grown fixture out status
  ceiling=$(agents_ceiling)
  case "$ceiling" in ''|*[!0-9]*) fail "the guard must report its AGENTS.md ceiling" ;; esac
  grown=$(( ceiling + 1 ))
  fixture=$(fixture_root "$grown") || fail "fixture root could not be built"
  out=$("$BUDGET" --root "$fixture" 2>&1) && status=0 || status=$?
  assert_equals "$status" 1 "one byte past the ceiling must fail"
  assert_contains "$out" "STARTUP SURFACE BUDGET EXCEEDED" "the refusal is named, not implied"
  assert_contains "$out" "AGENTS.md is $grown bytes" "the refusal names the measured size"
  assert_contains "$out" "over its $ceiling-byte" "the refusal names the ceiling it broke"
  assert_contains "$out" "firstmate-coding-guidelines" "the refusal routes the reader to the placement decision"
  assert_contains "$out" "agent-only skill" "the refusal names where conditional detail belongs instead"
  pass "an over-budget always-loaded surface is refused with actionable guidance"
}

test_accepts_a_surface_within_budget() {
  local ceiling fixture out
  ceiling=$(agents_ceiling)
  case "$ceiling" in ''|*[!0-9]*) fail "the guard must report its AGENTS.md ceiling" ;; esac
  fixture=$(fixture_root "$ceiling") || fail "fixture root could not be built"
  out=$("$BUDGET" --root "$fixture" 2>&1) || fail "a surface exactly at the ceiling must pass: $out"
  assert_contains "$out" "STARTUP SURFACE: within budget." "a surface at the ceiling passes"
  pass "a surface within budget is accepted"
}

test_report_mode_measures_without_enforcing() {
  local ceiling fixture out
  ceiling=$(agents_ceiling)
  fixture=$(fixture_root $(( ceiling + 1 ))) || fail "fixture root could not be built"
  out=$("$BUDGET" --report --root "$fixture" 2>&1) \
    || fail "--report must not enforce the budget: $out"
  assert_contains "$out" "STARTUP SURFACE  AGENTS.md" "the report still measures the surface"
  assert_not_contains "$out" "BUDGET EXCEEDED" "--report enforces nothing"
  pass "--report measures without enforcing"
}

test_rejects_unknown_arguments() {
  local out status
  out=$("$BUDGET" --nope 2>&1) && status=0 || status=$?
  assert_equals "$status" 2 "an unknown argument is a usage error"
  assert_contains "$out" "usage:" "the usage error prints usage"
  pass "unknown arguments are refused"
}

test_reports_the_current_surface_and_passes
test_refuses_a_grown_always_loaded_surface
test_accepts_a_surface_within_budget
test_report_mode_measures_without_enforcing
test_rejects_unknown_arguments
