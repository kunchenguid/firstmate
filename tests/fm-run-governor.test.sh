#!/usr/bin/env bash
# Behavioral regressions for the quota reserve governor: threshold boundaries,
# the hysteresis dead-band, the per-lane floor, per-local-day consumption budgets
# with baselines, rollover and override, projected runway, and the rule that
# unknown or stale quota is never treated as available.
#
# The governor is driven as an executable against synthetic quota-axi documents,
# so the policy is pinned without needing a live provider or any credential.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GOV="$ROOT/bin/fm-run-governor.sh"
TMP_ROOT=$(fm_test_tmproot fm-run-governor)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
export FM_HOME="$HOME_DIR"

# A minimal quota-axi schemaVersion 3 document for one provider and scope.
quota_doc() {  # <file> <provider> <percent> [state] [stale] [runway] [pace] [semantics] [availability]
  local file=$1 provider=$2 percent=$3 state=${4:-fresh} stale=${5:-false}
  local runway=${6:-through_reset} pace=${7:-behind} semantics=${8:-known} avail=${9:-known}
  cat > "$file" <<JSON
{
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "$provider",
      "state": { "status": "$state", "stale": $stale },
      "quotaSemantics": {
        "status": "$semantics",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "$avail",
            "effectivePercentRemaining": $percent,
            "runway": { "status": "$runway" },
            "pace": { "status": "$pace" }
          }
        ]
      }
    }
  ]
}
JSON
}

# An empty-window provider that could not authenticate, exactly the live shape a
# Claude lane returns when its quota needs an attended keychain authorization.
quota_auth_required() {  # <file>
  cat > "$1" <<'JSON'
{
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "claude",
      "windows": [],
      "state": {
        "status": "auth_required",
        "stale": false,
        "error": "keychain_prompt_required",
        "remedyCommand": "quota-axi --allow-keychain-prompt"
      },
      "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] }
    }
  ]
}
JSON
}

epoch_for() {  # <YYYY-MM-DDTHH:MM:SS>
  date -j -f '%Y-%m-%dT%H:%M:%S' "$1" +%s 2>/dev/null || date -d "$1" +%s
}

classify() {  # <lane> <quota-file> [extra args...]
  local lane=$1 file=$2
  shift 2
  "$GOV" classify --lane "$lane" --quota-json "$file" "$@"
}

field() {  # <output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

reset_state() {
  rm -rf "$HOME_DIR/state/run-governor"
}

test_threshold_boundaries() {
  local out percent expected
  # The boundary values themselves, not just the midpoints: 25, 15 and 10 are
  # inside the stricter class, one point above is outside it.
  for pair in '26 normal' '25 no-new-large' '16 no-new-large' '15 checkpoint-only' \
    '11 checkpoint-only' '10 emergency' '0 emergency'; do
    percent=${pair%% *}
    expected=${pair##* }
    reset_state
    quota_doc "$TMP_ROOT/q.json" codex "$percent"
    out=$(classify personal-codex "$TMP_ROOT/q.json")
    [ "$(field "$out" class)" = "$expected" ] \
      || fail "at ${percent}% remaining the governor said $(field "$out" class), expected $expected"
  done
  pass "the 25/15/10 reserve thresholds classify each boundary into the stricter class"
}

test_hysteresis_dead_band() {
  local out
  reset_state
  quota_doc "$TMP_ROOT/low.json" codex 24
  quota_doc "$TMP_ROOT/edge.json" codex 26
  quota_doc "$TMP_ROOT/clear.json" codex 29

  out=$(classify personal-codex "$TMP_ROOT/low.json")
  [ "$(field "$out" class)" = no-new-large ] || fail "24% did not enter no-new-large"

  # Back above the raw threshold but still inside the dead-band: the lane must
  # not flap back to normal on a single point of recovery.
  out=$(classify personal-codex "$TMP_ROOT/edge.json")
  [ "$(field "$out" class)" = no-new-large ] \
    || fail "26% flapped straight back to $(field "$out" class) inside the dead-band"
  assert_contains "$out" 'hysteresis:' "the held class was not attributed to the dead-band"

  out=$(classify personal-codex "$TMP_ROOT/clear.json")
  [ "$(field "$out" class)" = normal ] \
    || fail "29% did not recover past the dead-band"
  pass "a lane recovering through a threshold stays strict until it clears the dead-band"
}

test_unknown_and_stale_quota_are_never_available() {
  local out
  reset_state
  quota_auth_required "$TMP_ROOT/auth.json"
  out=$(classify company-claude "$TMP_ROOT/auth.json")
  [ "$(field "$out" class)" = unknown ] \
    || fail "a lane needing attended authorization classified as $(field "$out" class)"
  assert_contains "$out" 'state:auth_required' "the unknown class did not name the authorization blocker"
  [ "$(field "$out" percent)" = unknown ] || fail "an unreadable lane reported a percentage"

  # Stale evidence is not fresh evidence, however healthy the number looks.
  reset_state
  quota_doc "$TMP_ROOT/stale.json" codex 99 fresh true
  out=$(classify personal-codex "$TMP_ROOT/stale.json")
  [ "$(field "$out" class)" = unknown ] || fail "stale evidence at 99% was treated as available"

  reset_state
  quota_doc "$TMP_ROOT/nosem.json" codex 99 fresh false through_reset behind unknown
  out=$(classify personal-codex "$TMP_ROOT/nosem.json")
  [ "$(field "$out" class)" = unknown ] || fail "unknown quota semantics were treated as available"

  reset_state
  quota_doc "$TMP_ROOT/noavail.json" codex 99 fresh false through_reset behind known unknown
  out=$(classify personal-codex "$TMP_ROOT/noavail.json")
  [ "$(field "$out" class)" = unknown ] || fail "an unknown in-scope availability was treated as available"

  # A provider that is not in the document at all is unknown, never absent-equals-fine.
  reset_state
  quota_doc "$TMP_ROOT/other.json" cursor 99
  out=$(classify personal-codex "$TMP_ROOT/other.json")
  [ "$(field "$out" class)" = unknown ] || fail "a missing provider was treated as available"
  pass "unknown, stale, unreadable, and absent quota all classify as unknown rather than available"
}

test_projected_runway_bounds_a_healthy_percentage() {
  local out
  reset_state
  quota_doc "$TMP_ROOT/norunway.json" codex 99 fresh false unknown behind
  # With no declared duration there is nothing to cover, so the percentage stands.
  out=$(classify personal-codex "$TMP_ROOT/norunway.json" --no-record)
  [ "$(field "$out" class)" = normal ] || fail "a zero-duration query was tightened for runway"

  # With a real job to finish and verify, an unmeasurable runway is not a pass.
  out=$(classify personal-codex "$TMP_ROOT/norunway.json" --need-seconds 3600 --no-record)
  [ "$(field "$out" class)" = no-new-large ] \
    || fail "99% with an unmeasurable runway stayed at $(field "$out" class)"
  assert_contains "$out" 'runway:unknown' "the runway bound was not named"

  reset_state
  quota_doc "$TMP_ROOT/ahead.json" codex 99 fresh false through_reset ahead
  out=$(classify personal-codex "$TMP_ROOT/ahead.json" --no-record)
  [ "$(field "$out" class)" = no-new-large ] \
    || fail "a lane burning ahead of its reset stayed at $(field "$out" class)"
  pass "projected runway and pace tighten a lane whose raw percentage looks healthy"
}

test_company_codex_floor() {
  local out
  reset_state
  quota_doc "$TMP_ROOT/high.json" codex 99
  quota_doc "$TMP_ROOT/below.json" codex 64
  out=$(classify company-codex "$TMP_ROOT/high.json")
  [ "$(field "$out" class)" = normal ] || fail "company codex above its floor was not normal"

  reset_state
  out=$(classify company-codex "$TMP_ROOT/below.json")
  [ "$(field "$out" class)" = no-new-large ] \
    || fail "company codex below its 65% floor stayed at $(field "$out" class)"
  assert_contains "$out" 'lane-floor:65' "the stricter company floor was not named"

  # The floor is a lane policy, not a global one.
  reset_state
  out=$(classify personal-codex "$TMP_ROOT/below.json")
  [ "$(field "$out" class)" = normal ] || fail "the company floor leaked onto a personal lane"
  pass "the stricter Company Codex 65% floor applies to that lane only"
}

test_day_budget_baseline_rollover_and_override() {
  local out day1 day2 before
  before=$(epoch_for 2026-08-13T10:00:00)
  day1=$(epoch_for 2026-08-20T10:00:00)
  day2=$(epoch_for 2026-08-21T10:00:00)
  quota_doc "$TMP_ROOT/p99.json" codex 99
  quota_doc "$TMP_ROOT/p90.json" codex 90
  quota_doc "$TMP_ROOT/p82.json" codex 82

  # Before the effective date the budget does not apply at all.
  reset_state
  out=$(classify company-codex "$TMP_ROOT/p99.json" --now "$before")
  [ "$(field "$out" day_budget_state)" = not-yet-effective ] \
    || fail "the day budget applied before its effective date"

  # The first reading of a local day is that day's baseline.
  reset_state
  out=$(classify company-codex "$TMP_ROOT/p99.json" --now "$day1")
  [ "$(field "$out" day_consumed)" = 0 ] || fail "the first reading of a day was not the baseline"

  out=$(classify company-codex "$TMP_ROOT/p90.json" --now "$day1")
  [ "$(field "$out" day_consumed)" = 9 ] || fail "consumption was not measured against the day baseline"
  [ "$(field "$out" class)" = normal ] || fail "9pp of a 15pp budget already restricted the lane"

  out=$(classify company-codex "$TMP_ROOT/p82.json" --now "$day1")
  [ "$(field "$out" day_consumed)" = 17 ] || fail "consumption did not accumulate across the day"
  [ "$(field "$out" class)" = checkpoint-only ] \
    || fail "an exhausted day budget left the lane at $(field "$out" class)"
  assert_contains "$out" 'day-budget:' "the exhausted day budget was not named"

  # An explicit captain override releases exactly that lane and that day.
  "$GOV" override --lane company-codex --day 2026-08-20 --reason 'captain authorized the extra spend' >/dev/null
  out=$(classify company-codex "$TMP_ROOT/p82.json" --now "$day1")
  [ "$(field "$out" day_budget_state)" = overridden ] || fail "the override was not honored"
  [ "$(field "$out" class)" = normal ] || fail "an overridden day budget still restricted the lane"

  # The override expires with its day, and the new day starts a new baseline.
  out=$(classify company-codex "$TMP_ROOT/p82.json" --now "$day2")
  [ "$(field "$out" day)" = 2026-08-21 ] || fail "the local day did not roll over"
  [ "$(field "$out" day_consumed)" = 0 ] || fail "yesterday's consumption leaked into the new day"
  [ "$(field "$out" day_budget_state)" = within ] || fail "the previous day's override outlived its day"
  pass "the per-local-day budget baselines, accumulates, honors one day's override, and rolls over at midnight"
}

test_day_budget_applies_only_to_the_configured_lanes() {
  local out day1
  day1=$(epoch_for 2026-08-20T10:00:00)
  quota_doc "$TMP_ROOT/p99.json" codex 99
  quota_doc "$TMP_ROOT/p70.json" codex 70
  reset_state
  classify personal-codex "$TMP_ROOT/p99.json" --now "$day1" >/dev/null
  out=$(classify personal-codex "$TMP_ROOT/p70.json" --now "$day1")
  [ "$(field "$out" day_budget_state)" = not-applicable ] \
    || fail "a lane with no day budget reported $(field "$out" day_budget_state)"
  [ "$(field "$out" class)" = normal ] || fail "a 29pp day on an unbudgeted lane was restricted"
  pass "the per-day consumption budget binds only the lanes it was configured for"
}

test_unregistered_lane_is_refused_rather_than_guessed() {
  local rc=0 out
  reset_state
  quota_doc "$TMP_ROOT/p99.json" codex 99
  out=$(classify some-new-lane "$TMP_ROOT/p99.json" 2>&1) || rc=$?
  expect_code 1 "$rc" "classifying an unregistered lane"
  assert_contains "$out" 'no registered provider' "an unregistered lane's provider was guessed"

  # An explicit provider is the operator saying it, not the governor inferring it.
  rc=0
  out=$(classify some-new-lane "$TMP_ROOT/p99.json" --provider codex 2>&1) || rc=$?
  expect_code 0 "$rc" "classifying with an explicit provider"
  pass "a lane with no registered provider is refused instead of inferred from its name"
}

test_local_policy_file_overrides_the_built_in_lanes() {
  local out
  reset_state
  printf 'company-codex codex scope=all_models floor=80 day-budget=5\n' \
    > "$HOME_DIR/config/run-governor.conf"
  quota_doc "$TMP_ROOT/p75.json" codex 75
  out=$("$GOV" policy company-codex)
  assert_contains "$out" 'floor=80' "the local policy file did not override the built-in floor"
  out=$(classify company-codex "$TMP_ROOT/p75.json")
  [ "$(field "$out" class)" = no-new-large ] || fail "the retuned floor was not applied"
  rm -f "$HOME_DIR/config/run-governor.conf"
  pass "a home can retune a lane's floor and day budget without editing the governor"
}

# The day record is a read-modify-write: a classification reads the stored day and
# baseline, decides whether the day is still current, and writes the result.
# Concurrent classifications for one lane must leave exactly one baseline, and it
# must be the day's first reading rather than whichever contender wrote last.
#
# What this case can and cannot establish is worth stating plainly. It proves the
# converged outcome. It does NOT prove the absence of the torn-read window that
# the atomic rename closes: a classification takes ~70ms while that window is
# microseconds wide, so no CLI-level test provokes it at a useful rate, and one
# that pretended to would pass against the unlocked code and read as proof it
# never earned. The rename's correctness rests on `mv` being atomic, and the
# lock's on the run-engine suite, which drives contention on a much cheaper
# command; see tests/fm-run-engine.test.sh's concurrent-claim case.
test_concurrent_classifications_keep_one_day_baseline() {
  local out day baseline stored
  day=$(epoch_for 2026-08-20T10:00:00)
  quota_doc "$TMP_ROOT/race99.json" codex 99
  quota_doc "$TMP_ROOT/race80.json" codex 80
  reset_state

  # Establish the day's baseline with one settled reading, then contend with it.
  classify company-codex "$TMP_ROOT/race99.json" --now "$day" >/dev/null
  stored="$HOME_DIR/state/run-governor/company-codex.day"

  for _ in $(seq 1 8); do
    classify company-codex "$TMP_ROOT/race80.json" --now "$day" >/dev/null 2>&1 &
  done
  wait

  # The lane keeps ONE baseline, and it is the day's first reading rather than
  # whichever contender happened to write last.
  baseline=$(sed -n 's/^baseline=//p' "$stored" | head -1)
  [ "$baseline" = 99 ] \
    || fail "concurrent classifications rewrote the day baseline to $baseline, expected 99"
  [ "$(grep -c '^baseline=' "$stored")" = 1 ] || fail "the day record has a duplicated baseline"
  [ "$(grep -c '^day=' "$stored")" = 1 ] || fail "the day record has a duplicated day"

  # Consumption is still measured from that real baseline, which is the thing the
  # budget actually depends on.
  out=$(classify company-codex "$TMP_ROOT/race80.json" --now "$day")
  [ "$(field "$out" day_consumed)" = 19 ] \
    || fail "consumption after the race was $(field "$out" day_consumed), expected 19"
  pass "concurrent classifications preserve one day baseline per lane"
}

# What this test does NOT establish: that the class record is written atomically
# or that its read-decide-write is serialized. Neither is observable through this
# CLI. The record is three short lines emitted by one printf, so a direct
# truncating redirect is already effectively atomic on a local filesystem, and
# every contender in a race derives its class from the same settled previous
# value, so an unserialized version computes the same answer. Both properties
# were confirmed by mutation: reverting the lock, the atomic rename, or both
# leaves every assertion below green. Those two properties rest on `mv` being
# atomic and on the lock bracketing the read and the write - read the code, not
# this test, for them.
#
# What it does establish, and what a regression would break: contention leaves
# exactly one well-formed record that the NEXT classification can still read, and
# the dead-band that record carries survives it. A writer that appended instead
# of replacing, left the file empty or partial, or leaked its lock directory
# would fail here.
test_a_contended_class_record_stays_readable_for_the_next_classification() {
  local out stored dupes
  reset_state
  quota_doc "$TMP_ROOT/cls24.json" codex 24
  quota_doc "$TMP_ROOT/cls26.json" codex 26
  stored="$HOME_DIR/state/run-governor/personal-codex.class"

  classify personal-codex "$TMP_ROOT/cls24.json" >/dev/null
  for _ in $(seq 1 8); do
    classify personal-codex "$TMP_ROOT/cls26.json" >/dev/null 2>&1 &
  done
  wait

  dupes=$(grep -c '^class=' "$stored")
  [ "$dupes" = 1 ] || fail "the class record has $dupes class lines, expected 1"
  [ "$(grep -c '^percent=' "$stored")" = 1 ] || fail "the class record has a duplicated percent"
  [ -n "$(sed -n 's/^class=//p' "$stored")" ] || fail "the class record was left with an empty class"
  [ -z "$(find "$(dirname "$stored")" -name '*.class.lock' -print -quit)" ] \
    || fail "a class-state lock was left behind"
  [ -z "$(find "$(dirname "$stored")" -name '*.class.tmp.*' -print -quit)" ] \
    || fail "a class-state temp file was left behind"

  # The record is still usable: 26% holds inside the dead-band rather than
  # flapping back to normal, which only works if `previous` was readable.
  out=$(classify personal-codex "$TMP_ROOT/cls26.json")
  [ "$(field "$out" class)" = no-new-large ] \
    || fail "26% flapped to $(field "$out" class) after concurrent classification"
  assert_contains "$out" 'hysteresis:' "the dead-band was lost after concurrent classification"
  pass "a contended class record stays readable and keeps its dead-band for the next classification"
}

test_threshold_boundaries
test_hysteresis_dead_band
test_concurrent_classifications_keep_one_day_baseline
test_a_contended_class_record_stays_readable_for_the_next_classification
test_unknown_and_stale_quota_are_never_available
test_projected_runway_bounds_a_healthy_percentage
test_company_codex_floor
test_day_budget_baseline_rollover_and_override
test_day_budget_applies_only_to_the_configured_lanes
test_unregistered_lane_is_refused_rather_than_guessed
test_local_policy_file_overrides_the_built_in_lanes
