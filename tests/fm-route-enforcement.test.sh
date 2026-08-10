#!/usr/bin/env bash
# Behavior tests for route, floor, pool, availability and admission enforcement
# at the spawn chokepoint (bin/fm-route-lib.sh, bin/fm-route.sh, bin/fm-spawn.sh).
#
# The routing policy states which models a route may use, the capability floor
# each route requires, and that a failed primary is replaced only from inside its
# own pool. These tests pin the four properties that make that enforcement worth
# having rather than worth working around:
#
#   1. It is RED BOTH WAYS. A dispatch that breaks a floor, a pool, or an
#      admission band is refused with the violated rule NAMED - the route, the
#      exact JSON config path, the configured value and the observed one - and a
#      compliant dispatch through the same code path is untouched. A refusal
#      nobody can trace to a line of policy is a refusal nobody can fix.
#   2. It is INERT WHERE NOTHING IS CONFIGURED. A home using the documented
#      profile schema, which has no pool, and a home with no dispatch config at
#      all, behave exactly as they did before. Activation must not reach them.
#   3. FAILOVER STAYS INSIDE THE POOL, IN ORDER, and the availability record is
#      the only thing that holds a candidate out. When every candidate is out,
#      the answer is a terminal stop that names each one - never a substitution
#      from another route and never a lowered floor.
#   4. NO LIVE LANE IS RE-CHECKED. Work already dispatched keeps the record it
#      was dispatched under; enforcement runs only on the next dispatch.
#
# Refusal cases stop before any endpoint exists, and a fake `tmux` that exits
# non-zero backstops them, so a case that wrongly proceeded would fail rather
# than quietly create a worker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
ROUTE="$ROOT/bin/fm-route.sh"
TMP_ROOT=$(fm_test_tmproot fm-route-enforcement)

# A routed policy with the shape the live home uses: ordered pools, structured
# floors carrying the three mechanically checkable axes, and per-model evidence.
# Deliberately small and self-contained, so a case asserts against a real file
# rather than against a constant baked into the test.
write_routed_config() {  # <home>
  cat > "$1/config/crew-dispatch.json" <<'JSON'
{
  "_floors": {
    "F-LOW":  { "effort_floor": "low",    "context_ceiling": 100000, "tool_loop": "verified-agentic" },
    "F-MED":  { "effort_floor": "medium", "context_ceiling": 140000, "tool_loop": "verified-agentic" },
    "F-WIDE": { "effort_floor": "WAIVED - bounded retrieval specialist", "context_ceiling": 400000, "tool_loop": "not-required" },
    "F-COORD": { "selectable_by_crew_rule": false }
  },
  "_models": {
    "vendor/small":  { "smart_zone": 140000, "effort_expressible": ["low","medium"], "tool_loop": "verified-agentic" },
    "vendor/large":  { "smart_zone": 140000, "effort_expressible": ["low","medium","high"], "tool_loop": "verified-agentic" },
    "other/small":   { "smart_zone": 140000, "effort_expressible": ["low","medium"], "tool_loop": "verified-agentic" },
    "wide/reader":   { "smart_zone": 400000, "effort_expressible": [], "tool_loop": "not-required" },
    "vendor/untooled": { "smart_zone": 140000, "effort_expressible": ["low","medium"], "tool_loop": "not-required" }
  },
  "rules": [
    { "when": "trivial mechanical edits", "route": "R-LOW", "floor": "F-LOW",
      "use": { "harness": "codex", "model": "vendor/small", "effort": "low" },
      "pool": ["vendor/small", "vendor/large"], "promotion_target": "R-MED" },
    { "when": "ordinary implementation", "route": "R-MED", "floor": "F-MED",
      "use": { "harness": "codex", "model": "vendor/large", "effort": "medium" },
      "pool": ["vendor/large", "other/small"], "promotion_target": "NONE - terminal rung" },
    { "when": "one very large read", "route": "R-WIDE", "floor": "F-WIDE",
      "use": { "harness": "codex", "model": "wide/reader" },
      "pool": ["wide/reader"], "promotion_target": "R-MED" }
  ],
  "default": { "harness": "codex", "model": "vendor/large", "effort": "medium", "route": "R-MED", "floor": "F-MED" }
}
JSON
}

# The schema every other home uses: profiles only, no pool, so there is nothing
# to enforce and this activation must not reach it.
write_unrouted_config() {  # <home>
  cat > "$1/config/crew-dispatch.json" <<'JSON'
{
  "_floors": { "F-GEN": "ordinary generalist work" },
  "rules": [ { "when": "anything", "use": { "harness": "codex", "model": "gpt-5", "effort": "medium" }, "floor": "F-GEN" } ],
  "default": { "harness": "codex", "model": "gpt-5", "effort": "medium", "floor": "F-GEN" }
}
JSON
}

# An admission policy whose authority rule bands to hard, which is what an
# unheld session lock produces. The test never holds the lock, so this is a
# deterministic hard band with no timing dependence.
write_admission_policy() {  # <home>
  local file="$1/config/crew-dispatch.json" tmp="$1/config/crew-dispatch.json.tmp"
  jq '. + {"_scheduling": {"admission_control": {
        "schema_version": 1, "enabled": true, "enforcement_mode": "safety-only",
        "fleet_id": "test-fleet", "combine": "most_restrictive",
        "severity_order": ["preferred","soft","hard"], "unknown_band": "hard",
        "authority": {"mode": "single-primary", "authority_id": "test-fleet",
                      "unreachable_band": "hard", "config_mismatch_band": "hard"},
        "bands": {"preferred": {"action": "admit"},
                  "soft": {"action": "queue", "hold_kind": "load", "auto_reconsider": true},
                  "hard": {"action": "refuse", "hold_kind": "load", "auto_reconsider": true}},
        "signals": {
          "census_integrity": {"enabled": true, "required": true, "source": "fresh-authority-census",
                               "max_snapshot_age_seconds": 600, "unknown_band": "hard"},
          "backlog_consistency": {"enabled": true, "enforce": false, "source": "main-inventory", "unknown_band": "hard"},
          "active_workers": {"enabled": true, "enforce": false, "source": "fresh-authority-census",
                             "soft_count": null, "hard_count": null},
          "admission_queue_pressure": {"enabled": true, "enforce": false,
                                       "source": "tasks-axi-load-holds-plus-ledger",
                                       "queued_soft_count": null, "queued_hard_count": null,
                                       "oldest_wait_soft_seconds": null, "oldest_wait_hard_seconds": null}},
        "queue": {"substrate": "tasks-axi hold --kind load",
                  "release_triggers": ["teardown","session-start"],
                  "already_empty_fleet_recheck": "session-start-only"},
        "reservations": {"enabled": false, "ttl_seconds": null, "heartbeat_seconds": null,
                         "clock_skew_tolerance_seconds": null, "reconcile_on": ["session-start"],
                         "release_on": ["spawn-failure","teardown"]},
        "notifications": {"episode_dedupe_seconds": 3600, "policy_ref": "/_scheduling/notification_bands"},
        "telemetry": {"sink": "wake-outcome-ledger", "record_every_decision": true,
                      "record_signal_values": true, "record_config_paths": true,
                      "record_config_digest": true, "credentials_forbidden": true}}}}' \
    "$file" > "$tmp" && mv "$tmp" "$file"
}

# A home whose fake tmux REFUSES, so any case that wrongly got past a gate
# fails loudly instead of leaving a worker behind.
make_refusal_home() {  # <name> [routed|unrouted|none]
  local name=$1 shape=${2:-routed} home projects fakebin
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/fakebin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  case "$shape" in
    routed) write_routed_config "$home" ;;
    unrouted) write_unrouted_config "$home" ;;
  esac
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

read_home_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR FAKEBIN <<EOF
$1
EOF
}

write_brief() {  # <home> <id> [<mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_route() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROUTE" "$@" 2>&1
}

# --- the reader: red before green -------------------------------------------

test_effort_below_floor_is_refused_naming_the_rule() {
  local rec out
  rec=$(make_refusal_home effort-floor); read_home_record "$rec"
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large --effort low); rc=$?
  expect_code 1 "$rc" "an effort below the route floor must be refused"
  assert_contains "$out" "effort_below_floor" "the violated rule is not named"
  assert_contains "$out" "/_floors/F-MED/effort_floor" "the exact config path is not named"
  assert_contains "$out" "configures medium" "the configured value is not named"
  assert_contains "$out" "observed low" "the observed value is not named"
  pass "an effort below the route's floor is refused, naming route, config path, configured and observed"
}

test_model_outside_the_pool_is_refused_naming_the_pool() {
  local rec out
  rec=$(make_refusal_home pool); read_home_record "$rec"
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/small --effort medium); rc=$?
  expect_code 1 "$rc" "a model outside the route's pool must be refused"
  assert_contains "$out" "model_not_in_pool" "the violated rule is not named"
  assert_contains "$out" "/rules/1/pool" "the exact config path is not named"
  assert_contains "$out" "vendor/large, other/small" "the configured pool is not named"
  pass "a model outside the claimed route's pool is refused, naming the configured pool"
}

test_compliant_dispatch_is_unaffected() {
  local rec out
  rec=$(make_refusal_home compliant); read_home_record "$rec"
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 0 "$rc" "a compliant dispatch must pass the same code path"
  assert_contains "$out" "ok:" "a compliant dispatch is not reported as allowed"
  # Exceeding a floor satisfies it; only falling below breaches it.
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large --effort high); rc=$?
  expect_code 0 "$rc" "an effort ABOVE the floor must satisfy it rather than breach it"
  pass "a compliant dispatch passes, and exceeding a floor satisfies it"
}

test_unknown_route_and_ambiguous_bare_name_are_refused() {
  local rec out
  rec=$(make_refusal_home unknown-route); read_home_record "$rec"
  out=$(run_route "$HOME_DIR" check --route R-NOPE --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "an undefined route must be refused"
  assert_contains "$out" "FM_SPAWN_ROUTE_UNKNOWN" "the stable refusal token is missing"
  assert_contains "$out" "R-LOW, R-MED, R-WIDE" "the defined routes are not named"
  # The mixed-key rule: a bare name that could be either sibling is refused,
  # never resolved to the closest-looking one. Two pool entries share the bare
  # half of their qualified names, which is exactly the near-miss case.
  jq '.rules[1].pool += ["vendor/small"]' "$HOME_DIR/config/crew-dispatch.json" > "$HOME_DIR/config/tmp.json"
  mv "$HOME_DIR/config/tmp.json" "$HOME_DIR/config/crew-dispatch.json"
  out=$(run_route "$HOME_DIR" check --route R-MED --model small --effort medium); rc=$?
  expect_code 1 "$rc" "an ambiguous bare model name must be refused"
  assert_contains "$out" "FM_SPAWN_ROUTE_POOL_VIOLATION" "the stable refusal token is missing"
  assert_contains "$out" "more than one pool entry" "the ambiguity is not explained"
  pass "an undefined route and an ambiguous bare model name are both refused"
}

test_waived_effort_floor_and_unselectable_floor() {
  local rec out
  rec=$(make_refusal_home waived); read_home_record "$rec"
  # F-WIDE waives effort explicitly, so a dispatch with no effort is compliant.
  out=$(run_route "$HOME_DIR" check --route R-WIDE --model wide/reader); rc=$?
  expect_code 0 "$rc" "an explicitly waived effort floor must accept a dispatch with no effort"
  # A concrete floor is the opposite: a provider default establishes no band.
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large); rc=$?
  expect_code 1 "$rc" "a concrete effort floor must refuse a provider-default dispatch"
  assert_contains "$out" "effort_unstated" "the violated rule is not named"
  pass "a waived effort floor accepts a provider default and a concrete one refuses it"
}

test_tool_loop_axis_is_enforced() {
  local rec out home
  rec=$(make_refusal_home tool-loop); read_home_record "$rec"
  home=$HOME_DIR
  # Put an untooled model in a pool whose floor requires a verified tool loop.
  jq '.rules[1].pool += ["vendor/untooled"]' "$home/config/crew-dispatch.json" > "$home/config/tmp.json"
  mv "$home/config/tmp.json" "$home/config/crew-dispatch.json"
  out=$(run_route "$home" check --route R-MED --model vendor/untooled --effort medium); rc=$?
  expect_code 1 "$rc" "a candidate that does not meet the tool-loop floor must be refused"
  assert_contains "$out" "tool_loop_below_floor" "the violated rule is not named"
  assert_contains "$out" "configures verified-agentic" "the configured axis value is not named"
  pass "the tool-loop axis refuses an in-pool candidate that does not meet it"
}

# --- eligibility, failover and the terminal stop ----------------------------

test_failover_stays_inside_the_pool_in_order() {
  local rec out
  rec=$(make_refusal_home failover); read_home_record "$rec"
  out=$(run_route "$HOME_DIR" eligible --route R-MED); rc=$?
  expect_code 0 "$rc" "a route with eligible candidates must return them"
  assert_contains "$out" "vendor/large" "the primary is missing from the eligible list"
  [ "$(printf '%s\n' "$out" | head -1)" = "vendor/large" ] || fail "eligibility must return pool order, primary first"
  out=$(run_route "$HOME_DIR" next --route R-MED --after vendor/large); rc=$?
  expect_code 0 "$rc" "a substitute inside the pool must be found"
  assert_contains "$out" "other/small" "the in-pool substitute is missing"
  assert_not_contains "$out" "vendor/large" "a substitute must come strictly after the failed model"
  # A model from another route's pool is not a substitute at all.
  out=$(run_route "$HOME_DIR" next --route R-MED --after wide/reader); rc=$?
  expect_code 2 "$rc" "a model outside the pool cannot anchor an in-pool substitution"
  assert_contains "$out" "FM_SPAWN_ROUTE_POOL_VIOLATION" "the stable refusal token is missing"
  pass "failover substitutes only inside the same pool, in pool order"
}

test_availability_hold_removes_a_candidate_and_release_restores_it() {
  local rec out
  rec=$(make_refusal_home availability); read_home_record "$rec"
  out=$(run_route "$HOME_DIR" availability hold vendor/large --state rate_limited --for-seconds 300 --evidence '429 in pane')
  expect_code 0 "$?" "recording an availability hold must succeed"
  out=$(run_route "$HOME_DIR" eligible --route R-MED)
  assert_not_contains "$out" "vendor/large" "a held model must not be eligible"
  assert_contains "$out" "other/small" "the next in-pool candidate must still be eligible"
  # The record is private: it names what the fleet is currently unable to reach.
  [ "$(stat -c '%a' "$HOME_DIR/state/model-health.json" 2>/dev/null || stat -f '%Lp' "$HOME_DIR/state/model-health.json")" = 600 ] \
    || fail "the availability record must be mode 0600"
  out=$(run_route "$HOME_DIR" availability release vendor/large)
  expect_code 0 "$?" "releasing an availability hold must succeed"
  out=$(run_route "$HOME_DIR" eligible --route R-MED)
  assert_contains "$out" "vendor/large" "a released model must be eligible again"
  pass "an availability hold removes a candidate, and releasing it restores the candidate"
}

test_unknown_availability_state_is_refused() {
  local rec out
  rec=$(make_refusal_home health-vocab); read_home_record "$rec"
  out=$(run_route "$HOME_DIR" availability hold vendor/large --state feeling_slow); rc=$?
  expect_code 2 "$rc" "an out-of-vocabulary availability state must be refused"
  assert_contains "$out" "FM_ROUTE_HEALTH_STATE_UNKNOWN" "the stable refusal token is missing"
  assert_absent "$HOME_DIR/state/model-health.json" "a refused state must not be recorded"
  pass "the availability vocabulary is closed and an unknown state records nothing"
}

test_exhausted_pool_stops_and_reports_rather_than_degrading() {
  local rec out
  rec=$(make_refusal_home terminal); read_home_record "$rec"
  run_route "$HOME_DIR" availability hold vendor/large --state provider_unavailable --for-seconds 300 >/dev/null
  run_route "$HOME_DIR" availability hold other/small --state auth_failure >/dev/null
  out=$(run_route "$HOME_DIR" eligible --route R-MED); rc=$?
  expect_code 3 "$rc" "an exhausted pool must return the terminal NO_CANDIDATE answer"
  assert_contains "$out" "FM_ROUTE_NO_CANDIDATE" "the stable terminal token is missing"
  assert_contains "$out" "R-MED" "the terminal report must name the route"
  assert_contains "$out" "F-MED" "the terminal report must name the floor"
  assert_contains "$out" "1. vendor/large" "the terminal report must list every candidate in order"
  assert_contains "$out" "2. other/small" "the terminal report must list every candidate in order"
  assert_contains "$out" "provider_unavailable" "the terminal report must name why each candidate was rejected"
  assert_contains "$out" "auth_failure" "the terminal report must name why each candidate was rejected"
  assert_contains "$out" "earliest known recovery" "the terminal report must state the earliest known recovery"
  assert_contains "$out" "do not lower the floor" "the terminal report must refuse degradation outright"
  pass "an exhausted pool stops and reports every candidate in order rather than degrading"
}

test_expired_hold_stops_binding_without_a_sweep() {
  local rec out
  rec=$(make_refusal_home expiry); read_home_record "$rec"
  run_route "$HOME_DIR" availability hold vendor/large --state rate_limited --for-seconds 1 >/dev/null
  # Rewrite the recorded expiry into the past rather than sleeping: the contract
  # is that a lapsed hold stops binding on READ, with nothing running to sweep it.
  jq '.models["vendor/large"].until = 1' "$HOME_DIR/state/model-health.json" > "$HOME_DIR/state/h.json"
  mv "$HOME_DIR/state/h.json" "$HOME_DIR/state/model-health.json"
  out=$(run_route "$HOME_DIR" eligible --route R-MED)
  assert_contains "$out" "vendor/large" "a lapsed hold must stop binding on read"
  pass "a lapsed availability hold stops binding on read, with nothing to sweep it"
}

test_malformed_availability_record_is_not_an_empty_one() {
  local rec out
  rec=$(make_refusal_home health-malformed); read_home_record "$rec"
  printf 'not json at all\n' > "$HOME_DIR/state/model-health.json"
  out=$(run_route "$HOME_DIR" eligible --route R-MED); rc=$?
  expect_code 2 "$rc" "an unreadable availability record must not read as an empty one"
  pass "an unreadable availability record refuses rather than treating every model as available"
}

# --- the spawn chokepoint ---------------------------------------------------

test_spawn_refuses_a_pool_violation_and_creates_nothing() {
  local rec out
  rec=$(make_refusal_home spawn-pool); read_home_record "$rec"
  write_brief "$HOME_DIR" pooltask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" pooltask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --model vendor/small --effort medium); rc=$?
  expect_code 1 "$rc" "a dispatch outside the claimed route's pool must be refused at the chokepoint"
  assert_contains "$out" "model_not_in_pool" "the violated rule is not named"
  assert_absent "$HOME_DIR/state/pooltask.meta" "a refused dispatch must leave no task metadata"
  pass "the spawn chokepoint refuses a pool violation and creates nothing"
}

test_spawn_refuses_a_floor_violation_and_creates_nothing() {
  local rec out
  rec=$(make_refusal_home spawn-floor); read_home_record "$rec"
  write_brief "$HOME_DIR" floortask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" floortask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --model vendor/large --effort low); rc=$?
  expect_code 1 "$rc" "a dispatch below the claimed route's floor must be refused at the chokepoint"
  assert_contains "$out" "effort_below_floor" "the violated rule is not named"
  assert_absent "$HOME_DIR/state/floortask.meta" "a refused dispatch must leave no task metadata"
  pass "the spawn chokepoint refuses a floor violation and creates nothing"
}

test_spawn_requires_the_route_claim_or_derives_it_from_an_explicit_floor() {
  local rec out
  rec=$(make_refusal_home spawn-claim); read_home_record "$rec"
  write_brief "$HOME_DIR" claimtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" claimtask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a routed home must refuse a dispatch that claims no route"
  assert_contains "$out" "FM_SPAWN_ROUTE_REQUIRED" "the stable refusal token is missing"
  assert_contains "$out" "R-LOW|R-MED|R-WIDE" "the refusal must name the configured routes"
  # An explicit floor that names exactly one route IS the claim; a violating
  # dispatch carrying it is still refused, on the derived route.
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" claimtask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --capability-floor F-MED --model vendor/small --effort medium); rc=$?
  expect_code 1 "$rc" "a route derived from an explicit floor must still be enforced"
  assert_contains "$out" "model_not_in_pool" "the derived route was not enforced"
  pass "a routed home requires the route claim, and an explicit floor naming one route supplies it"
}

test_spawn_refuses_a_route_and_floor_that_contradict_each_other() {
  local rec out
  rec=$(make_refusal_home spawn-contradiction); read_home_record "$rec"
  write_brief "$HOME_DIR" contradiction no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" contradiction "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --capability-floor F-LOW --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a recorded floor that disagrees with the claimed route must be refused"
  assert_contains "$out" "FM_SPAWN_ROUTE_FLOOR_MISMATCH" "the stable refusal token is missing"
  pass "a route and a recorded floor that describe different rungs are refused"
}

test_spawn_refuses_route_on_a_secondmate_spawn() {
  local rec out
  rec=$(make_refusal_home spawn-secondmate); read_home_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" smtask --secondmate --route R-MED); rc=$?
  expect_code 1 "$rc" "a secondmate spawn claims no route"
  assert_contains "$out" "--route applies to ship and scout dispatches" "the refusal does not explain the scope"
  pass "a secondmate spawn refuses a route claim"
}

test_unrouted_home_is_untouched_by_activation() {
  local rec out
  rec=$(make_refusal_home spawn-unrouted unrouted); read_home_record "$rec"
  write_brief "$HOME_DIR" plaintask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" plaintask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --model gpt-5 --effort medium); rc=$?
  # The fixture project has no default branch, so the spawn cannot complete -
  # but it must get all the way to the base-contract check, which runs well
  # after the chokepoint. That is the positive half: an absence assertion alone
  # would also pass if the spawn had died before reaching the gate at all.
  assert_not_contains "$out" "FM_SPAWN_ROUTE_REQUIRED" "an unrouted home must not be asked for a route claim"
  assert_not_contains "$out" "FM_SPAWN_ROUTE_POOL_VIOLATION" "an unrouted home has no pool to violate"
  assert_contains "$out" "base contract" "the unrouted spawn must reach a stage after the chokepoint"
  rec=$(make_refusal_home spawn-noconfig none); read_home_record "$rec"
  write_brief "$HOME_DIR" noconfigtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" noconfigtask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --model gpt-5 --effort medium)
  assert_not_contains "$out" "FM_SPAWN_ROUTE_REQUIRED" "a home with no dispatch config must not be asked for a route claim"
  assert_contains "$out" "base contract" "the unconfigured spawn must reach a stage after the chokepoint"
  pass "a home with no routed pool, and a home with no dispatch config at all, are unaffected"
}

test_route_claim_is_refused_where_nothing_can_check_it() {
  local rec out
  rec=$(make_refusal_home spawn-unverifiable-claim unrouted); read_home_record "$rec"
  write_brief "$HOME_DIR" claimless no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" claimless "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --model gpt-5 --effort medium); rc=$?
  expect_code 1 "$rc" "a route claim nothing can check must be refused rather than recorded"
  assert_contains "$out" "FM_SPAWN_ROUTE_UNKNOWN" "the stable refusal token is missing"
  assert_absent "$HOME_DIR/state/claimless.meta" "an unverifiable route claim must not reach task metadata"
  pass "a route claim in a home that configures no pool is refused rather than recorded unchecked"
}

test_spawn_records_the_route_and_the_policy_that_checked_it() {
  local rec out meta fakebin
  rec=$(make_refusal_home spawn-record); read_home_record "$rec"
  # This case must reach metadata, so it needs a tmux that succeeds and a real
  # worktree for the isolation assertion.
  fakebin="$TMP_ROOT/spawn-record/okbin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  fm_fake_exit0 "$fakebin" codex
  fm_git_worktree "$TMP_ROOT/spawn-record/repo" "$TMP_ROOT/spawn-record/wt" wt-record
  write_brief "$HOME_DIR" recordtask no-mistakes
  touch "$HOME_DIR/state/.last-watcher-beat"
  out=$(FM_FAKE_PANE_PATH="$TMP_ROOT/spawn-record/wt" TMUX="fake,1,0" \
    run_spawn "$HOME_DIR" "$fakebin" recordtask "$TMP_ROOT/spawn-record/repo" \
      --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
      --harness codex --route R-MED --model vendor/large --effort medium); rc=$?
  meta="$HOME_DIR/state/recordtask.meta"
  [ -f "$meta" ] || fail "a compliant dispatch must reach task metadata"$'\n'"--- output ---"$'\n'"$out"
  assert_grep "route=R-MED" "$meta" "meta must record the route the dispatch was checked against"
  assert_grep "capability_floor=F-MED" "$meta" "meta must record the route's own floor"
  assert_grep "route_policy_digest=sha256:" "$meta" "meta must record a digest of the policy that checked it"
  pass "a compliant dispatch records the route, its floor, and the policy surface that checked it"
}

test_admission_hard_band_refuses_the_spawn_naming_the_condition() {
  local rec out
  rec=$(make_refusal_home spawn-admission); read_home_record "$rec"
  write_admission_policy "$HOME_DIR"
  write_brief "$HOME_DIR" admittask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" admittask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a hard admission band must refuse the spawn"
  assert_contains "$out" "FM_SPAWN_ADMISSION_REFUSED" "the stable refusal token is missing"
  assert_contains "$out" "authority.single_primary" "the controlling admission condition is not named"
  assert_contains "$out" "/_scheduling/admission_control/authority/unreachable_band" "the exact config path is not named"
  assert_absent "$HOME_DIR/state/admittask.meta" "an admission refusal must leave no task metadata"
  pass "a hard admission band refuses the spawn, names the controlling condition, and creates nothing"
}

# --- activation safety ------------------------------------------------------

test_activation_does_not_recheck_work_already_dispatched() {
  local rec out before after
  rec=$(make_refusal_home no-recheck); read_home_record "$rec"
  # A lane dispatched before this enforcement existed: no route= line at all,
  # and a model that today's policy would refuse for its recorded floor.
  fm_write_meta "$HOME_DIR/state/livetask.meta" \
    "window=firstmate:fm-livetask" "endpoint_task_id=livetask" \
    "worktree=$PROJ_DIR" "project=$PROJ_DIR" "harness=codex" "kind=ship" \
    "mode=no-mistakes" "yolo=off" "capability_floor=F-MED" \
    "model=vendor/small" "effort=low"
  before=$(cat "$HOME_DIR/state/livetask.meta")
  write_brief "$HOME_DIR" newtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" newtask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --model vendor/small --effort medium)
  assert_contains "$out" "model_not_in_pool" "the NEW dispatch must still be refused"
  after=$(cat "$HOME_DIR/state/livetask.meta")
  [ "$before" = "$after" ] || fail "an already-dispatched lane's record must not be rewritten by activation"
  assert_not_contains "$out" "livetask" "activation must not re-check work already under way"
  pass "activation refuses only the next dispatch and leaves work already under way untouched"
}

test_effort_below_floor_is_refused_naming_the_rule
test_model_outside_the_pool_is_refused_naming_the_pool
test_compliant_dispatch_is_unaffected
test_unknown_route_and_ambiguous_bare_name_are_refused
test_waived_effort_floor_and_unselectable_floor
test_tool_loop_axis_is_enforced
test_failover_stays_inside_the_pool_in_order
test_availability_hold_removes_a_candidate_and_release_restores_it
test_unknown_availability_state_is_refused
test_exhausted_pool_stops_and_reports_rather_than_degrading
test_expired_hold_stops_binding_without_a_sweep
test_malformed_availability_record_is_not_an_empty_one
test_spawn_refuses_a_pool_violation_and_creates_nothing
test_spawn_refuses_a_floor_violation_and_creates_nothing
test_spawn_requires_the_route_claim_or_derives_it_from_an_explicit_floor
test_spawn_refuses_a_route_and_floor_that_contradict_each_other
test_spawn_refuses_route_on_a_secondmate_spawn
test_unrouted_home_is_untouched_by_activation
test_route_claim_is_refused_where_nothing_can_check_it
test_spawn_records_the_route_and_the_policy_that_checked_it
test_admission_hard_band_refuses_the_spawn_naming_the_condition
test_activation_does_not_recheck_work_already_dispatched
