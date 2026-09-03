#!/usr/bin/env bash
# Behavior tests for the pure cswap account-selection decision function
# (bin/fm-cswap-select.jq, invoked through bin/fm-cswap-lib.sh's
# fm_cswap_decide). Hermetic - feeds literal fixture JSON, no real cswap call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-cswap-lib.sh"

decide() {  # <candidates-json> <active>
  fm_cswap_decide "$1" "$2"
}

field() {  # <json> <jq-filter>
  printf '%s' "$1" | jq -r "$2"
}

# --- the captain's exact scenario -------------------------------------------
#
# A 5x-plan account at 36% weekly usage, resetting in 4d20h, projected by
# cswap's own pace math to exhaust in 3d19h (BEFORE its reset - it will run
# dry with about a day of margin to spare), against a 20x-plan account at 6%
# weekly usage, resetting in 4d4h, running 34 points under its expected pace
# (cswap's own reservePct, i.e. expectedPct - actualPct). A new task must
# pick the 20x account.
test_captain_scenario_5x_at_risk_vs_20x_safe_picks_20x() {
  local now=1735689600 r5x e5x r20x e20x cands out
  r5x=$((now + 417600))    # +4d20h
  e5x=$((now + 327600))    # +3d19h - BEFORE r5x: will exhaust before reset
  r20x=$((now + 360000))   # +4d4h
  e20x=$((now + 3840000))  # ~+44.4d - far past r20x: comfortably safe
  cands=$(cat <<JSON
[
  {"number":1,"email":"5x@example.com","alias":"","disabled":false,"usageStatus":"ok","usageAgeSeconds":60,
   "pct5h":10,"resets5hEpoch":$((now + 3600)),
   "pct7d":36,"resets7dEpoch":$r5x,"expectedPct7d":30.95,"aheadOfPace7d":false,
   "willLastToReset7d":false,"projectedExhaustionAt7dEpoch":$e5x},
  {"number":2,"email":"20x@example.com","alias":"","disabled":false,"usageStatus":"ok","usageAgeSeconds":60,
   "pct5h":5,"resets5hEpoch":$((now + 3600)),
   "pct7d":6,"resets7dEpoch":$r20x,"expectedPct7d":40.4,"aheadOfPace7d":false,
   "willLastToReset7d":true,"projectedExhaustionAt7dEpoch":$e20x}
]
JSON
  )
  out=$(printf '%s' "$cands" | jq -c --argjson now "$now" --argjson active 1 --argjson maxAgeS 1800 \
    -f "$ROOT/bin/fm-cswap-select.jq")
  [ "$(field "$out" .decision)" = switch ] || fail "expected a switch decision, got: $out"
  [ "$(field "$out" .chosen)" = 2 ] || fail "expected the 20x account (2) to be chosen, got: $out"
  [ "$(field "$out" '.candidates[0].margin7dSeconds')" -lt 0 ] || fail "5x account must show a negative (will-exhaust-early) margin"
  [ "$(field "$out" '.candidates[1].margin7dSeconds')" -gt 0 ] || fail "20x account must show a positive (safe) margin"
  [ "$(field "$out" '.candidates[1].reserve7dPct')" = "34.4" ] || fail "20x reserve7dPct should read 34.4 (expectedPct 40.4 - actual 6), got: $out"
  pass "5x at-risk of exhausting before reset vs 20x comfortably safe: the 20x account is chosen"
}

test_plan_size_breaks_a_tie_and_is_carried_in_evidence() {
  # Two accounts identical on every other ranking key (same tier, same
  # margin7d, same headroom) but different plan size: the larger plan must be
  # chosen, and each account's plan must appear verbatim in the candidates
  # evidence. Proves selection ranks BY plan size, not just headroom/runway.
  local now=1735689600 r7 e7 cands out
  r7=$((now + 400000))
  e7=$((now + 900000))
  cands=$(cat <<JSON
[
  {"number":1,"email":"5x@example.com","alias":"","disabled":false,"usageStatus":"ok","usageAgeSeconds":30,
   "plan":5,"pct5h":10,"resets5hEpoch":$((now + 3600)),
   "pct7d":20,"resets7dEpoch":$r7,"expectedPct7d":20,"aheadOfPace7d":false,
   "willLastToReset7d":true,"projectedExhaustionAt7dEpoch":$e7},
  {"number":2,"email":"20x@example.com","alias":"","disabled":false,"usageStatus":"ok","usageAgeSeconds":30,
   "plan":20,"pct5h":10,"resets5hEpoch":$((now + 3600)),
   "pct7d":20,"resets7dEpoch":$r7,"expectedPct7d":20,"aheadOfPace7d":false,
   "willLastToReset7d":true,"projectedExhaustionAt7dEpoch":$e7}
]
JSON
  )
  out=$(printf '%s' "$cands" | jq -c --argjson now "$now" --argjson active 1 --argjson maxAgeS 1800 \
    -f "$ROOT/bin/fm-cswap-select.jq")
  [ "$(field "$out" .decision)" = switch ] || fail "the larger-plan account must win an otherwise-exact tie, got: $out"
  [ "$(field "$out" .chosen)" = 2 ] || fail "expected the 20x-plan account (2) to be chosen over the tied 5x active one, got: $out"
  [ "$(field "$out" '.candidates[0].plan')" = 5 ] || fail "account 1's plan size must be carried into evidence, got: $out"
  [ "$(field "$out" '.candidates[1].plan')" = 20 ] || fail "account 2's plan size must be carried into evidence, got: $out"
  pass "plan size breaks an otherwise-exact tie (larger plan chosen) and is recorded per account in evidence"
}

test_tie_stays_on_active_account() {
  local now=1735689600 cands out
  cands=$(cat <<JSON
[
  {"number":1,"email":"a@example.com","alias":"","disabled":false,"usageStatus":"ok","usageAgeSeconds":30,
   "pct5h":10,"resets5hEpoch":$((now + 3600)),
   "pct7d":20,"resets7dEpoch":$((now + 400000)),"expectedPct7d":20,"aheadOfPace7d":false,
   "willLastToReset7d":true,"projectedExhaustionAt7dEpoch":$((now + 900000))},
  {"number":2,"email":"b@example.com","alias":"","disabled":false,"usageStatus":"ok","usageAgeSeconds":30,
   "pct5h":10,"resets5hEpoch":$((now + 3600)),
   "pct7d":20,"resets7dEpoch":$((now + 400000)),"expectedPct7d":20,"aheadOfPace7d":false,
   "willLastToReset7d":true,"projectedExhaustionAt7dEpoch":$((now + 900000))}
]
JSON
  )
  out=$(printf '%s' "$cands" | jq -c --argjson now "$now" --argjson active 2 --argjson maxAgeS 1800 \
    -f "$ROOT/bin/fm-cswap-select.jq")
  [ "$(field "$out" .decision)" = keep-current ] || fail "an exact tie must keep the currently active account, got: $out"
  [ "$(field "$out" .chosen)" = 2 ] || fail "keep-current must report the active account as chosen, got: $out"
  pass "an exact tie between two equally-good accounts stays on the currently active one"
}

test_stale_usage_fails_closed_to_keep_current() {
  local now=1735689600 cands out
  cands=$(cat <<JSON
[
  {"number":1,"email":"a@example.com","alias":"","disabled":false,"usageStatus":"ok","usageAgeSeconds":9000,
   "pct5h":10,"resets5hEpoch":$((now + 3600)),
   "pct7d":10,"resets7dEpoch":$((now + 400000)),"expectedPct7d":20,"aheadOfPace7d":false,
   "willLastToReset7d":true,"projectedExhaustionAt7dEpoch":$((now + 900000))}
]
JSON
  )
  out=$(printf '%s' "$cands" | jq -c --argjson now "$now" --argjson active 1 --argjson maxAgeS 1800 \
    -f "$ROOT/bin/fm-cswap-select.jq")
  [ "$(field "$out" .decision)" = keep-current ] || fail "a lone account with stale (9000s > 1800s max) usage must never be picked, got: $out"
  [ "$(field "$out" .chosen)" = null ] || fail "keep-current on stale-only evidence must not name a chosen account, got: $out"
  case "$(field "$out" .reason)" in
    *"no eligible"*) : ;;
    *) fail "reason should explain no eligible candidate, got: $out" ;;
  esac
  pass "the only candidate's usage being older than the freshness floor fails closed instead of guessing"
}

test_disabled_account_excluded_even_with_best_headroom() {
  local now=1735689600 cands out
  cands=$(cat <<JSON
[
  {"number":1,"email":"disabled@example.com","alias":"","disabled":true,"usageStatus":"ok","usageAgeSeconds":30,
   "pct5h":0,"resets5hEpoch":$((now + 3600)),
   "pct7d":0,"resets7dEpoch":$((now + 400000)),"expectedPct7d":20,"aheadOfPace7d":false,
   "willLastToReset7d":true,"projectedExhaustionAt7dEpoch":null},
  {"number":2,"email":"b@example.com","alias":"","disabled":false,"usageStatus":"ok","usageAgeSeconds":30,
   "pct5h":50,"resets5hEpoch":$((now + 3600)),
   "pct7d":50,"resets7dEpoch":$((now + 400000)),"expectedPct7d":50,"aheadOfPace7d":false,
   "willLastToReset7d":true,"projectedExhaustionAt7dEpoch":$((now + 900000))}
]
JSON
  )
  out=$(printf '%s' "$cands" | jq -c --argjson now "$now" --argjson active 2 --argjson maxAgeS 1800 \
    -f "$ROOT/bin/fm-cswap-select.jq")
  [ "$(field "$out" .decision)" = keep-current ] || fail "the only non-disabled account is already active, so this must keep-current, got: $out"
  [ "$(field "$out" .chosen)" = 2 ] || fail "expected account 2 (the non-disabled one), got: $out"
  pass "a disabled account (held out of rotation) is never a selection candidate even with perfect headroom"
}

test_null_disabled_fails_closed_and_is_never_selected() {
  # cswap's real `list --json` omits `disabled` for an in-rotation account and
  # emits it as `true` only when a slot is held out of rotation
  # (claude_swap/json_output.py); it never emits a bare `null`. A null disabled
  # therefore signals a partial/garbled read whose authorization is UNCONFIRMED,
  # and must fail CLOSED (excluded) rather than be silently treated as enabled
  # and reach `cswap switch`. Account 1 here has otherwise-perfect headroom and
  # a safe (null-projection) tier, so a fail-OPEN reading would wrongly switch
  # to it; the fix must instead keep the explicitly-enabled active account.
  local now=1735689600 cands out
  cands=$(cat <<JSON
[
  {"number":1,"email":"unconfirmed@example.com","alias":"","disabled":null,"usageStatus":"ok","usageAgeSeconds":30,
   "pct5h":0,"resets5hEpoch":$((now + 3600)),
   "pct7d":0,"resets7dEpoch":$((now + 400000)),"expectedPct7d":20,"aheadOfPace7d":false,
   "willLastToReset7d":true,"projectedExhaustionAt7dEpoch":null},
  {"number":2,"email":"b@example.com","alias":"","disabled":false,"usageStatus":"ok","usageAgeSeconds":30,
   "pct5h":50,"resets5hEpoch":$((now + 3600)),
   "pct7d":50,"resets7dEpoch":$((now + 400000)),"expectedPct7d":50,"aheadOfPace7d":false,
   "willLastToReset7d":true,"projectedExhaustionAt7dEpoch":$((now + 900000))}
]
JSON
  )
  out=$(printf '%s' "$cands" | jq -c --argjson now "$now" --argjson active 2 --argjson maxAgeS 1800 \
    -f "$ROOT/bin/fm-cswap-select.jq")
  [ "$(field "$out" '.candidates[0].eligible')" = false ] || fail "an account whose disabled state is null (unconfirmed) must be ineligible, got: $out"
  [ "$(field "$out" .decision)" = keep-current ] || fail "a null-disabled account with perfect headroom must not trigger a switch, got: $out"
  [ "$(field "$out" .chosen)" = 2 ] || fail "only the explicitly-enabled (disabled==false) account may be chosen, got: $out"
  pass "an unconfirmed (null) disabled state fails closed and can never reach a credential switch"
}

test_untouched_account_with_no_5h_reset_timestamp_is_eligible() {
  # Verified live against the captain's real cswap accounts: a window with
  # 0% usage carries no resetsAt at all (nothing has opened it yet), so
  # eligibility must not require a 5h reset timestamp to exist.
  local now=1735689600 cands out
  cands=$(cat <<JSON
[
  {"number":1,"email":"fresh@example.com","alias":"","disabled":false,"usageStatus":"ok","usageAgeSeconds":250,
   "pct5h":0,"resets5hEpoch":null,
   "pct7d":6,"resets7dEpoch":$((now + 400000)),"expectedPct7d":40.8,"aheadOfPace7d":null,
   "willLastToReset7d":true,"projectedExhaustionAt7dEpoch":$((now + 3500000))},
  {"number":2,"email":"active@example.com","alias":"","disabled":false,"usageStatus":"ok","usageAgeSeconds":20,
   "pct5h":96,"resets5hEpoch":$((now + 6600)),
   "pct7d":41,"resets7dEpoch":$((now + 406800)),"expectedPct7d":31.3,"aheadOfPace7d":null,
   "willLastToReset7d":null,"projectedExhaustionAt7dEpoch":$((now + 259200))}
]
JSON
  )
  out=$(printf '%s' "$cands" | jq -c --argjson now "$now" --argjson active 2 --argjson maxAgeS 1800 \
    -f "$ROOT/bin/fm-cswap-select.jq")
  [ "$(field "$out" '.candidates[0].eligible')" = true ] || fail "an untouched account with no 5h resetsAt must still be eligible, got: $out"
  [ "$(field "$out" .decision)" = switch ] || fail "expected a switch away from the near-limit active account, got: $out"
  [ "$(field "$out" .chosen)" = 1 ] || fail "expected the fresh account to be chosen, got: $out"
  pass "an account whose 5h window has never been opened (no resetsAt) is still a valid selection candidate"
}

test_captain_scenario_5x_at_risk_vs_20x_safe_picks_20x
test_null_disabled_fails_closed_and_is_never_selected
test_untouched_account_with_no_5h_reset_timestamp_is_eligible
test_plan_size_breaks_a_tie_and_is_carried_in_evidence
test_tie_stays_on_active_account
test_stale_usage_fails_closed_to_keep_current
test_disabled_account_excluded_even_with_best_headroom

echo "all fm-cswap-select tests passed"
