#!/usr/bin/env bash
# tests/fm-focus.test.sh - the captain's opt-in project focus window
# (bin/fm-focus.sh): off by default and inert, urgent classes and unknown
# projects always delivered, non-urgent outcomes from other projects held in a
# durable ledger, held outcomes presented grouped by project by every wake drain
# once the window is cleared or expires, and cleared only by an explicit
# delivery acknowledgement.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

FOCUS="$ROOT/bin/fm-focus.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-focus-tests)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_focus_home() {  # <name>
  local home
  home=$(make_case "$1")
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] alpha-call - Pick the alpha route (repo: alpha) (kind: captain) (hold: choose) (hold-kind: captain)
- [ ] beta-call - Pick the beta route (repo: beta) (kind: captain) (hold: choose) (hold-kind: captain)
- [ ] loose-call - Pick a route (kind: captain) (hold: choose) (hold-kind: captain)
EOF
  printf 'project=%s/projects/gamma\n' "$home" > "$home/state/gamma-ship.meta"
  printf '%s\n' "$home"
}

focus() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_FOCUS_NOW_EPOCH="${NOW_EPOCH:-1790000000}" "$FOCUS" "$@"
}

drain() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_FOCUS_NOW_EPOCH="${NOW_EPOCH:-1790000000}" "$DRAIN" 2>/dev/null
}

test_no_window_is_inert() {
  local home out
  home=$(make_focus_home inert)
  assert_equals "$(focus "$home" route --task beta-call --class decision --summary "beta call")" \
    "deliver no-focus-window" "with no window a decision was not delivered"
  assert_equals "$(focus "$home" status)" "off; held undelivered: 0" "status did not report off"
  out=$(drain "$home") || fail "the drain failed with no focus window"
  assert_not_contains "$out" "FOCUS" "a drain with no focus window printed a focus section"
  assert_absent "$home/state/focus-held.jsonl" "routing with no window created a held ledger"
  pass "with no focus window every outcome is delivered and nothing prints"
}

test_urgent_and_unknown_project_outcomes_always_come_through() {
  local home class
  home=$(make_focus_home urgent)
  focus "$home" set alpha >/dev/null || fail "could not set the window"
  for class in failure security credential blocking; do
    assert_equals "$(focus "$home" route --task beta-call --class "$class" --summary "beta $class")" \
      "deliver urgent:$class" "an urgent $class outcome from another project was held"
  done
  assert_equals "$(focus "$home" route --task loose-call --class decision --summary "no project")" \
    "deliver unknown-project" "an outcome with no structured project was held"
  assert_equals "$(focus "$home" route --task alpha-call --class decision --summary "alpha")" \
    "deliver in-focus" "an outcome from the focused project was held"
  if focus "$home" route --task beta-call --class bogus --summary "?" >/dev/null 2>&1; then
    fail "an unknown class was accepted instead of refused"
  fi
  assert_equals "$(focus "$home" held)" "" "an urgent or in-focus outcome was recorded as held"
  pass "urgent classes, unknown projects, and focused projects bypass the window"
}

test_held_outcomes_are_listed_while_set_and_delivered_grouped_after_clear() {
  local home out
  home=$(make_focus_home held)
  focus "$home" set alpha >/dev/null || fail "could not set the window"
  assert_equals "$(focus "$home" route --task beta-call --class decision --summary "beta needs a call")" \
    "held 1 beta" "a non-urgent decision from another project was not held"
  assert_equals "$(focus "$home" route --task gamma-ship --class review-ready --summary "gamma PR ready")" \
    "held 2 gamma" "a review-ready outcome was not held by its task record's project"
  assert_equals "$(focus "$home" route --task beta-call --class completion --summary "beta work done")" \
    "held 3 beta" "a routine completion from another project was not held"
  out=$(drain "$home") || fail "the drain failed while a window was set"
  assert_contains "$out" "FOCUS WINDOW: on for alpha (3 outcome(s) held)" \
    "the drain did not remind main of the active window"
  assert_not_contains "$out" "FOCUS HELD" "held outcomes were delivered while the window was still set"
  out=$(focus "$home" clear) || fail "clear failed"
  assert_contains "$out" "focus: off" "clear did not end the window"
  printf '%s\n' "$out" | awk '/^  beta \(2\):/ { b = NR } /^    - \[completion\] beta-call/ { c = NR }
    /^  gamma \(1\):/ { g = NR } END { exit !(b && c > b && g > c) }' \
    || fail "held outcomes were not grouped by project in first-held order: $out"
  assert_contains "$out" "bin/fm-focus.sh delivered --through 3" "clear did not print the acknowledgement"
  out=$(drain "$home") || fail "the drain failed after clear"
  assert_contains "$out" "FOCUS HELD (the focus window ended" "an unacknowledged delivery was not presented again"
  assert_contains "$out" "gamma PR ready" "the drain dropped a held outcome"
  focus "$home" delivered --through 3 >/dev/null || fail "delivery acknowledgement failed"
  out=$(drain "$home") || fail "the drain failed after delivery"
  assert_not_contains "$out" "FOCUS" "a delivered obligation was presented again"
  pass "held outcomes stay listed while set, arrive grouped once cleared, and persist until acknowledged"
}

test_an_expired_window_holds_nothing_more_and_its_obligations_come_due() {
  local home out
  home=$(make_focus_home expiry)
  NOW_EPOCH=1790000000 focus "$home" set alpha --until 1h >/dev/null || fail "could not set a bounded window"
  assert_equals "$(NOW_EPOCH=1790000100 focus "$home" route --task beta-call --class decision --summary "beta")" \
    "held 1 beta" "a bounded window did not hold before it expired"
  assert_equals "$(NOW_EPOCH=1790003600 focus "$home" route --task beta-call --class decision --summary "beta again")" \
    "deliver focus-window-ended" "an expired window still held an outcome"
  out=$(NOW_EPOCH=1790003600 drain "$home") || fail "the drain failed after expiry"
  assert_contains "$out" "FOCUS HELD (the focus window ended" "an expired window's obligations did not come due"
  pass "an expired window stops holding and presents what it held"
}

test_a_damaged_record_delivers_everything() {
  local home
  home=$(make_focus_home damaged)
  printf 'garbage\n' > "$home/state/focus-window"
  assert_equals "$(focus "$home" route --task beta-call --class decision --summary "beta" 2>/dev/null)" \
    "deliver focus-record-unreadable" "a damaged record held an outcome"
  assert_contains "$(drain "$home")" "FOCUS WINDOW: the record is unreadable" \
    "the drain did not report the damaged record"
  pass "an unreadable focus record holds nothing and says so"
}

test_no_window_is_inert
test_urgent_and_unknown_project_outcomes_always_come_through
test_held_outcomes_are_listed_while_set_and_delivered_grouped_after_clear
test_an_expired_window_holds_nothing_more_and_its_obligations_come_due
test_a_damaged_record_delivers_everything
