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

# An admission policy whose authority rule bands to the requested band, which is
# what an unheld session lock produces. The test never holds the lock, so this is
# deterministic with no timing dependence.
write_admission_policy() {  # <home> [hard|soft]
  local file="$1/config/crew-dispatch.json" tmp="$1/config/crew-dispatch.json.tmp" band=${2:-hard}
  jq --arg band "$band" '. + {"_scheduling": {"admission_control": {
        "schema_version": 1, "enabled": true, "enforcement_mode": "safety-only",
        "fleet_id": "test-fleet", "combine": "most_restrictive",
        "severity_order": ["preferred","soft","hard"], "unknown_band": "hard",
        "authority": {"mode": "single-primary", "authority_id": "test-fleet",
                      "unreachable_band": $band, "config_mismatch_band": $band},
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

test_a_floor_axis_outside_its_vocabulary_refuses_rather_than_skipping() {
  local rec out home rc
  rec=$(make_refusal_home floor-vocabulary); read_home_record "$rec"
  home=$HOME_DIR
  # The likeliest way a floor ever reaches this code wrong: the right word with
  # the wrong separator. The tool-loop axis used to be skipped outright for it,
  # so every candidate passed a floor nothing measured and the check said ok.
  jq '._floors["F-MED"].tool_loop = "verified_agentic"' \
    "$home/config/crew-dispatch.json" > "$home/config/tmp.json"
  mv "$home/config/tmp.json" "$home/config/crew-dispatch.json"
  out=$(run_route "$home" check --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a tool_loop floor outside the closed vocabulary must refuse, never skip the axis"
  assert_contains "$out" "tool_loop_malformed" "the violated rule is not named"
  assert_contains "$out" "/_floors/F-MED/tool_loop" "the exact config path is not named"
  assert_contains "$out" "verified_agentic" "the value that could not be interpreted is not named"
  # And the chokepoint refuses it too, so an uninterpretable floor cannot admit
  # a dispatch by the other door.
  write_brief "$home" vocabtask no-mistakes
  out=$(run_spawn "$home" "$FAKEBIN" vocabtask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "the spawn chokepoint must refuse an uninterpretable tool_loop floor"
  assert_contains "$out" "tool_loop_malformed" "the chokepoint does not name the violated rule"
  assert_absent "$home/state/vocabtask.meta" "a dispatch checked against an uninterpretable floor must record nothing"
  # A non-numeric context_ceiling failed closed but blamed the candidate,
  # reporting a smart_zone below a string it could never be compared against.
  jq '._floors["F-MED"].tool_loop = "verified-agentic"
      | ._floors["F-MED"].context_ceiling = "140k"' \
    "$home/config/crew-dispatch.json" > "$home/config/tmp.json"
  mv "$home/config/tmp.json" "$home/config/crew-dispatch.json"
  out=$(run_route "$home" check --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a non-numeric context_ceiling must refuse naming the ceiling"
  assert_contains "$out" "context_ceiling_malformed" "the violated rule is not named"
  assert_contains "$out" "/_floors/F-MED/context_ceiling" "the exact config path is not named"
  assert_contains "$out" "140k" "the value that could not be interpreted is not named"
  assert_not_contains "$out" "context_below_floor" \
    "an uninterpretable ceiling must not be reported as a candidate falling below it"
  pass "a floor axis value outside its closed vocabulary refuses by name instead of skipping the axis"
}

# --- a missing input is a refusal, never a skipped check ---------------------
#
# Every case below was silently ADMITTED before this section existed: the check
# ran, found nothing it could measure, and reported compliance. Enforcement that
# quietly does nothing when an input is absent is indistinguishable from no
# enforcement, and an absent input is exactly the case nobody tries by hand.

test_unstated_model_is_refused_rather_than_recorded_as_checked() {
  local rec out
  rec=$(make_refusal_home unstated-model); read_home_record "$rec"
  write_brief "$HOME_DIR" nomodel no-mistakes
  # No --model at all. Nothing can show an unstated model is in the route's pool
  # or meets any floor axis, so it is unverifiable rather than compliant.
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" nomodel "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --effort medium); rc=$?
  expect_code 1 "$rc" "a routed dispatch that names no model must be refused"
  assert_contains "$out" "model_unstated" "the violated rule is not named"
  assert_contains "$out" "/rules/1/pool" "the pool config path the claim cannot be checked against is not named"
  assert_contains "$out" "vendor/large, other/small" "the configured pool is not named"
  assert_absent "$HOME_DIR/state/nomodel.meta" "an unverifiable dispatch must not be recorded as route-checked"
  pass "a dispatch that omits --model is refused instead of recorded as checked"
}

test_absent_models_block_refuses_as_unverifiable() {
  local rec out
  rec=$(make_refusal_home no-models); read_home_record "$rec"
  # A routed config with floors that declare evidence axes, and no evidence at
  # all. Unmeasured is not the same as met, whether one model lacks an entry or
  # the whole block is missing.
  jq 'del(._models)' "$HOME_DIR/config/crew-dispatch.json" > "$HOME_DIR/config/tmp.json"
  mv "$HOME_DIR/config/tmp.json" "$HOME_DIR/config/crew-dispatch.json"
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a candidate with no recorded evidence must be refused as unverifiable"
  assert_contains "$out" "context_unverifiable" "the context axis is silently skipped without a _models block"
  assert_contains "$out" "/_models/vendor/large/smart_zone" "the config path the missing evidence belongs at is not named"
  assert_contains "$out" "effort_unverifiable" "the effort-expressibility axis is silently skipped"
  assert_contains "$out" "tool_loop_unverifiable" "the tool-loop axis is silently skipped"
  pass "a floor axis with no recorded evidence refuses as unverifiable, including with no _models block at all"
}

test_undefined_floor_id_refuses_and_records_no_capability_floor() {
  local rec out
  rec=$(make_refusal_home floor-undefined); read_home_record "$rec"
  jq '.rules[1].floor = "F-MISSING"' "$HOME_DIR/config/crew-dispatch.json" > "$HOME_DIR/config/tmp.json"
  mv "$HOME_DIR/config/tmp.json" "$HOME_DIR/config/crew-dispatch.json"
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a rule whose floor id is undefined must refuse rather than enforce nothing"
  assert_contains "$out" "floor_undefined" "the violated rule is not named"
  assert_contains "$out" "/rules/1/floor" "the config path that names the undefined floor is not named"
  assert_contains "$out" "/_floors/F-MISSING" "the missing floor definition is not named"
  # And the record: a capability floor nothing was checked against is worse than
  # no record, so the dispatch must not reach metadata at all.
  write_brief "$HOME_DIR" nofloor no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" nofloor "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "the spawn chokepoint must refuse an undefined floor id"
  assert_absent "$HOME_DIR/state/nofloor.meta" "a floor that was never checked against a definition must not be recorded"
  pass "an undefined floor id refuses with the rule named and records no capability floor"
}

test_held_model_is_refused_at_the_chokepoint_and_check_agrees_with_eligible() {
  local rec out
  rec=$(make_refusal_home held-model); read_home_record "$rec"
  run_route "$HOME_DIR" availability hold vendor/large --state provider_unavailable \
    --for-seconds 300 --evidence '503 from the provider' >/dev/null
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a held model must be refused by check, not only dropped by eligible"
  assert_contains "$out" "FM_SPAWN_ROUTE_MODEL_HELD" "the stable refusal token is missing"
  assert_contains "$out" "provider_unavailable" "the held state is not named"
  assert_contains "$out" "model vendor/large" "the held scope and subject are not named"
  assert_contains "$out" "until epoch" "the recorded expiry is not named"
  # The substitute offered has to be one an operator can actually dispatch. The
  # refused model is never its own replacement, so the list is the ELIGIBLE
  # candidates and not the whole pool.
  assert_contains "$out" "in pool order (other/small)" "the failover advice does not name the eligible substitute"
  assert_not_contains "$out" "(vendor/large, other/small)" "the refused model is offered as its own substitute"
  # The two commands must never give opposite answers about the same model.
  out=$(run_route "$HOME_DIR" eligible --route R-MED)
  assert_not_contains "$out" "vendor/large" "eligible must agree with check that a held model is out"
  # And the chokepoint honours it, so failover is triggered rather than skipped.
  write_brief "$HOME_DIR" heldtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" heldtask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a held model must not be dispatched at the spawn chokepoint"
  assert_contains "$out" "FM_SPAWN_ROUTE_MODEL_HELD" "the stable refusal token is missing at the chokepoint"
  assert_contains "$out" "already checked against the model registry" \
    "the chokepoint holds the registry decisions, so its substitutes must be checked ones"
  assert_absent "$HOME_DIR/state/heldtask.meta" "a held model must leave no task metadata"
  # With every candidate held there is nothing to fail over TO, and saying so is
  # the honest answer: an empty substitute list would read as "substitute
  # something" with no name attached.
  run_route "$HOME_DIR" availability hold other/small --state auth_failure >/dev/null
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a held model must stay refused when the whole pool is held"
  assert_contains "$out" "no other candidate in this route pool is eligible" \
    "an exhausted pool must be stated plainly rather than printing an empty substitute list"
  assert_contains "$out" "fm-route.sh eligible --route R-MED" "the terminal report is not pointed at"
  assert_contains "$out" "do not lower the floor" "the refusal must forbid degrading"
  run_route "$HOME_DIR" availability release other/small >/dev/null
  # A hold on the substitute is not a hold on the primary: releasing restores it.
  run_route "$HOME_DIR" availability release vendor/large >/dev/null
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 0 "$rc" "a released model must be dispatchable again"
  pass "an unavailable model is refused at the chokepoint and check agrees with eligible"
}

test_a_substitute_list_says_whether_it_was_registry_checked() {
  local rec out rc
  rec=$(make_refusal_home substitute-checked); read_home_record "$rec"
  run_route "$HOME_DIR" availability hold vendor/large --state rate_limited --for-seconds 300 >/dev/null
  # fm-route.sh supplies the registry verdicts it already computes, so the
  # substitute it names is one the operator can actually dispatch.
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a held model must be refused"
  assert_contains "$out" "in pool order (other/small)" "the substitute is not named"
  assert_contains "$out" "already checked against the model registry" \
    "a caller-supplied registry verdict must be reported as a checked substitute list"
  # A caller that supplies no verdicts must be TOLD the list is unchecked. The
  # routing library owns routing eligibility and asks the registry nothing, so
  # presenting its answer as registry-checked would send an operator into a
  # second refusal from an owner the message never mentioned.
  out=$(bash -c '
      . "$1/bin/fm-route-lib.sh"
      d=$(fm_route_decision "$2" R-MED vendor/large medium "$3") || exit 9
      fm_route_refusal_from_decision "$2" R-MED vendor/large "$d" "$3"' \
    _ "$ROOT" "$HOME_DIR/config" "$HOME_DIR/state" 2>&1); rc=$?
  expect_code 1 "$rc" "a raw decision must still refuse a held model"
  assert_contains "$out" "in pool order (other/small)" "the substitute is not named"
  assert_contains "$out" "were NOT checked against the model registry" \
    "an unchecked substitute list must say so rather than reading as a checked one"
  assert_contains "$out" "fm-route.sh eligible --route R-MED" \
    "an unchecked list must point at the registry-checked one"
  pass "a substitute list states whether it was checked against the model registry"
}

test_check_asks_the_registry_only_about_the_model_it_answers_for() {
  local rec out rc
  rec=$(make_refusal_home check-enrich); read_home_record "$rec"
  # A compliant dispatch consumes exactly one registry verdict: the subject's.
  # Every other candidate's was computed for nothing, and the subject's was
  # computed twice, which is how one invocation can report two answers.
  out=$(run_route "$HOME_DIR" check --json --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 0 "$rc" "a compliant dispatch must still pass"
  [ "$(printf '%s' "$out" | jq -r '[ .candidates[] | select(.model == "vendor/large") ] | .[0].registry_checked')" = true ] \
    || fail "the dispatched model's registry verdict must be recorded on the decision it was read from: $out"
  [ "$(printf '%s' "$out" | jq -r '[ .candidates[] | select(.model == "other/small") ] | .[0].registry_checked')" != true ] \
    || fail "a compliant dispatch must not ask the registry about candidates nothing consumes: $out"
  # And the verdict read off that record is the real one: a model the registry
  # refuses is still refused, so laziness bought nothing at the answer's expense.
  cat > "$HOME_DIR/config/models.json" <<'JSON'
{
  "schema": "fm-model-registry.v1",
  "providers": { "vendor": { "status": "active", "cost_posture": "subscription-flat" } },
  "models": { "vendor/large": { "status": "rejected", "status_reason": "withdrawn by the provider" } }
}
JSON
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a routing-compliant model the registry rejects must still be refused"
  assert_contains "$out" "records vendor/large as rejected" "the registry's own refusal is not reported"
  # A held subject is the case that DOES need every candidate's verdict, because
  # it is about to print a substitute list an operator will dispatch from.
  rm -f "$HOME_DIR/config/models.json"
  run_route "$HOME_DIR" availability hold vendor/large --state rate_limited --for-seconds 300 >/dev/null
  out=$(run_route "$HOME_DIR" check --json --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a held model must still be refused"
  [ "$(printf '%s' "$out" | jq -r '[ .candidates[] | select(.model == "other/small") ] | .[0].registry_checked')" = true ] \
    || fail "a substitute an operator is about to be handed must carry a registry verdict: $out"
  pass "check asks the registry about the model it answers for, and about the whole pool only when it names substitutes"
}

test_default_only_route_is_listed_and_enforced() {
  local rec out
  rec=$(make_refusal_home default-only none); read_home_record "$rec"
  cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{
  "_floors": { "F-MED": { "effort_floor": "medium" } },
  "_models": { "vendor/large": { "effort_expressible": ["low","medium","high"] } },
  "rules": [ { "when": "anything", "use": { "harness": "codex", "model": "vendor/large", "effort": "medium" } } ],
  "default": { "harness": "codex", "model": "vendor/large", "effort": "medium",
               "route": "R-DEF", "floor": "F-MED", "pool": ["vendor/large"] }
}
JSON
  out=$(run_route "$HOME_DIR" routes)
  assert_contains "$out" "R-DEF" "a route defined only under default must be listed by routes"
  assert_contains "$out" "defined_at=/default" "the listing must say where a route is defined"
  # A default entry IS the profile, so its columns must carry the real profile
  # rather than the blanks a `use`-only reader produces.
  assert_contains "$out" "harness=codex" "the listed route must show its real harness"
  assert_contains "$out" "primary=vendor/large" "the listed route must show its real primary model"
  assert_contains "$out" "effort=medium" "the listed route must show its real effort"
  out=$(run_route "$HOME_DIR" check --route R-DEF --model vendor/large --effort medium); rc=$?
  expect_code 0 "$rc" "check must accept a route defined only under default"
  # And the chokepoint must agree that this home is enforcing, rather than
  # staying inert while fm-route.sh enforces the same file.
  write_brief "$HOME_DIR" deftask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" deftask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a pool that lives only under default must still turn enforcement on"
  assert_contains "$out" "FM_SPAWN_ROUTE_REQUIRED" "the stable refusal token is missing"
  assert_contains "$out" "R-DEF" "the route the dispatch could claim is not named"
  pass "a route defined only under default is listed, checked and enforced by every reader"
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

test_an_ambiguous_failover_anchor_is_refused_rather_than_resolved() {
  local rec out rc
  rec=$(make_refusal_home failover-ambiguous); read_home_record "$rec"
  # Two pool entries sharing the bare half of their qualified names is exactly
  # the shape the mixed-key rule exists for. Anchoring on the first match hands
  # back the second - which here is the model the operator just said failed.
  jq '.rules[1].pool += ["vendor/small"]' \
    "$HOME_DIR/config/crew-dispatch.json" > "$HOME_DIR/config/tmp.json"
  mv "$HOME_DIR/config/tmp.json" "$HOME_DIR/config/crew-dispatch.json"
  out=$(run_route "$HOME_DIR" next --route R-MED --after small); rc=$?
  expect_code 2 "$rc" "an ambiguous failover anchor must be refused"
  assert_contains "$out" "FM_SPAWN_ROUTE_POOL_VIOLATION" "the stable refusal token is missing"
  assert_contains "$out" "more than one entry" "the ambiguity is not explained"
  assert_contains "$out" "other/small" "the refusal must name every entry the bare name matched"
  assert_contains "$out" "vendor/small" "the refusal must name every entry the bare name matched"
  # Named in full the same anchor resolves, and the substitute still comes
  # strictly after it in pool order.
  out=$(run_route "$HOME_DIR" next --route R-MED --after other/small); rc=$?
  expect_code 0 "$rc" "a fully qualified anchor must still resolve"
  assert_contains "$out" "vendor/small" "the in-pool substitute after the named anchor is missing"
  out=$(run_route "$HOME_DIR" next --route R-MED --after vendor/small); rc=$?
  expect_code 3 "$rc" "the last entry in a pool has nothing after it to fail over to"
  # A bare name matching exactly one entry stays usable: the rule refuses
  # guessing, not abbreviating.
  out=$(run_route "$HOME_DIR" next --route R-MED --after large); rc=$?
  expect_code 0 "$rc" "a bare name matching exactly one pool entry must still anchor a substitution"
  assert_contains "$out" "other/small" "the substitute after an unambiguous bare anchor is missing"
  pass "an ambiguous failover anchor is refused naming every entry it matched, never resolved to the first"
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

test_a_hold_that_cannot_match_a_candidate_is_refused_rather_than_recorded() {
  local rec out
  rec=$(make_refusal_home hold-scope); read_home_record "$rec"
  # A bare pool entry used to become a PROVIDER hold, recorded under a key no
  # candidate can ever match, and the command reported success for it.
  out=$(run_route "$HOME_DIR" availability hold small --state model_unavailable); rc=$?
  expect_code 2 "$rc" "a bare name matching two pool entries must be refused"
  assert_contains "$out" "FM_ROUTE_HOLD_SUBJECT_UNRESOLVED" "the stable refusal token is missing"
  assert_contains "$out" "more than one pool entry" "the ambiguity is not explained"
  assert_absent "$HOME_DIR/state/model-health.json" "a refused hold must record nothing"
  out=$(run_route "$HOME_DIR" availability hold gpt-5 --state model_unavailable); rc=$?
  expect_code 2 "$rc" "a name no pool lists must be refused rather than recorded"
  assert_contains "$out" "matches no pool entry" "the reason the hold could not match is not explained"
  assert_absent "$HOME_DIR/state/model-health.json" "a hold that cannot match a candidate must record nothing"
  # A bare name that resolves to exactly one pool entry is held as that MODEL.
  out=$(run_route "$HOME_DIR" availability hold large --state rate_limited); rc=$?
  expect_code 0 "$rc" "a bare name matching exactly one pool entry must resolve"
  assert_contains "$out" "held model vendor/large" "an unqualified name must resolve to the model, not a provider"
  out=$(run_route "$HOME_DIR" eligible --route R-MED)
  assert_not_contains "$out" "vendor/large" "a hold reported as recorded must actually remove the candidate"
  run_route "$HOME_DIR" availability release large >/dev/null
  # A provider hold is asked for outright, and its subject must be one a pool names.
  out=$(run_route "$HOME_DIR" availability hold nosuch --scope provider --state provider_unavailable); rc=$?
  expect_code 2 "$rc" "a provider no pool entry names must be refused"
  out=$(run_route "$HOME_DIR" availability hold vendor --scope provider --state provider_unavailable); rc=$?
  expect_code 0 "$rc" "an explicit provider hold on a configured provider must be recorded"
  assert_contains "$out" "held provider vendor" "an explicit provider hold is not recorded as one"
  out=$(run_route "$HOME_DIR" eligible --route R-MED)
  assert_not_contains "$out" "vendor/large" "a provider hold must remove that provider's candidates"
  assert_contains "$out" "other/small" "a provider hold must not reach another provider's candidates"
  pass "an availability hold resolves against the configured pools and never reports success for a hold that cannot match"
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
  assert_contains "$out" "model-health.json" "the refusal must name the record that could not be read"
  pass "an unreadable availability record refuses rather than treating every model as available"
}

test_an_unreadable_input_names_the_file_that_could_not_be_read() {
  local rec out rc
  rec=$(make_refusal_home unreadable-health); read_home_record "$rec"
  # An availability record truncated by an interrupted write. The routing config
  # parses perfectly, so a refusal naming IT sends the operator to repair a file
  # that is not broken - the same misdirection as naming an unchecked substitute.
  printf '{"models":{"vendor/large":{"state":"rate_li\n' > "$HOME_DIR/state/model-health.json"
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 2 "$rc" "an unreadable availability record must never read as an empty one"
  assert_contains "$out" "FM_ROUTE_HEALTH_UNREADABLE" "the stable refusal token is missing"
  assert_contains "$out" "model-health.json" "the refusal must name the record that could not be read"
  assert_contains "$out" "could not be determined" "the refusal must say which determination it could not make"
  assert_not_contains "$out" "crew-dispatch.json" \
    "a routing config that parses perfectly must not be blamed for an unreadable availability record"
  # The chokepoint is where a ship or scout dispatch meets this, so it has to
  # name the same file.
  write_brief "$HOME_DIR" healthtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" healthtask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "an unreadable availability record must stop the spawn"
  assert_contains "$out" "FM_ROUTE_HEALTH_UNREADABLE" "the chokepoint names the wrong unreadable input"
  assert_contains "$out" "model-health.json" "the chokepoint must name the record that could not be read"
  assert_absent "$HOME_DIR/state/healthtask.meta" "an undetermined dispatch must leave no task metadata"
  # The other cause keeps naming the other file.
  rec=$(make_refusal_home unreadable-config); read_home_record "$rec"
  printf 'not json at all\n' > "$HOME_DIR/config/crew-dispatch.json"
  out=$(run_route "$HOME_DIR" check --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 2 "$rc" "an unreadable routing config must refuse"
  assert_contains "$out" "FM_SPAWN_ROUTE_UNREADABLE" "the stable refusal token is missing"
  assert_contains "$out" "crew-dispatch.json" "the refusal must name the config that could not be read"
  pass "each unreadable input refuses naming the file that actually could not be read"
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
  local rec out meta fakebin launchlog
  rec=$(make_refusal_home spawn-record); read_home_record "$rec"
  # This case must reach metadata, so it needs a tmux that succeeds and a real
  # worktree for the isolation assertion. The same fake captures the literal
  # launch command, which is where the worker's environment is constructed.
  fakebin="$TMP_ROOT/spawn-record/okbin"
  launchlog="$TMP_ROOT/spawn-record/launch.log"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      printf 'inherited_admission_snapshot=[%s]\n' "${FM_SPAWN_ADMISSION_SNAPSHOT-unset}" \
        >> "$FM_FAKE_LAUNCH_LOG"
      prev=
      for a in "$@"; do
        [ "$prev" != -l ] || printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  fm_fake_exit0 "$fakebin" codex
  fm_git_worktree "$TMP_ROOT/spawn-record/repo" "$TMP_ROOT/spawn-record/wt" wt-record
  write_brief "$HOME_DIR" recordtask no-mistakes
  touch "$HOME_DIR/state/.last-watcher-beat"
  : > "$launchlog"
  # A ship spawn started WITH a shared census in its environment, which is
  # exactly what a batch parent hands each pair.
  out=$(FM_FAKE_PANE_PATH="$TMP_ROOT/spawn-record/wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_SPAWN_ADMISSION_SNAPSHOT="$TMP_ROOT/spawn-record/absent-census.json" \
    run_spawn "$HOME_DIR" "$fakebin" recordtask "$TMP_ROOT/spawn-record/repo" \
      --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
      --harness codex --route R-MED --model vendor/large --effort medium); rc=$?
  meta="$HOME_DIR/state/recordtask.meta"
  [ -f "$meta" ] || fail "a compliant dispatch must reach task metadata"$'\n'"--- output ---"$'\n'"$out"
  assert_grep "route=R-MED" "$meta" "meta must record the route the dispatch was checked against"
  assert_grep "capability_floor=F-MED" "$meta" "meta must record the route's own floor"
  assert_grep "route_policy_digest=sha256:" "$meta" "meta must record a digest of the policy that checked it"
  # The shared census is the spawn's input, not the worker's: anything that
  # inherited it would admit against a census taken before it existed. Ship and
  # scout are the kinds that receive it, and the backend that opens the pane is
  # the process that would carry it onward, so its environment is where the
  # clearing has to show.
  assert_grep 'inherited_admission_snapshot=[unset]' "$launchlog" \
    "the shared admission census reached the process that creates the worker"
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

test_soft_admission_band_defers_distinguishably_from_a_refusal() {
  local rec out
  rec=$(make_refusal_home spawn-admission-soft); read_home_record "$rec"
  write_admission_policy "$HOME_DIR" soft
  write_brief "$HOME_DIR" defertask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" defertask "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a soft admission band must still stop the spawn"
  # The record's own action splits the bands; a caller matching tokens has to be
  # able to tell a deferral from a refusal.
  assert_contains "$out" "FM_SPAWN_ADMISSION_DEFERRED" "a queued band must carry its own stable token"
  assert_not_contains "$out" "FM_SPAWN_ADMISSION_REFUSED" "a deferral must not read as a refusal"
  assert_contains "$out" "deferred" "the deferral prose is missing"
  assert_contains "$out" "authority.single_primary" "a deferral must name the controlling condition too"
  assert_absent "$HOME_DIR/state/defertask.meta" "a deferred dispatch must leave no task metadata"
  pass "a soft admission band defers with its own token and prose, distinct from a hard refusal"
}

# A tasks-axi the queue substrate accepts, so the load hold is actually placed
# and the prose the spawn prints about it can be asserted.
write_fake_tasks_axi() {  # <fakebin>
  cat > "$1/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.4' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$1/tasks-axi"
}

test_a_queued_hold_promises_reconsideration_only_when_the_band_records_it() {
  local rec out
  rec=$(make_refusal_home auto-reconsider); read_home_record "$rec"
  write_admission_policy "$HOME_DIR" soft
  write_fake_tasks_axi "$FAKEBIN"
  write_brief "$HOME_DIR" recon1 no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" recon1 "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --model vendor/large --effort medium)
  assert_contains "$out" "queued recon1" "the deferred request must be queued as a load hold"
  assert_contains "$out" "at the next successful cleanup or session start" \
    "a band that records auto_reconsider must promise the automatic retake"
  # The same band with auto_reconsider off promises nothing automatic: a retake
  # that will not happen is how a queued request is quietly lost.
  jq '._scheduling.admission_control.bands.soft.auto_reconsider = false' \
    "$HOME_DIR/config/crew-dispatch.json" > "$HOME_DIR/config/tmp.json"
  mv "$HOME_DIR/config/tmp.json" "$HOME_DIR/config/crew-dispatch.json"
  write_brief "$HOME_DIR" recon2 no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" recon2 "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --harness codex --route R-MED --model vendor/large --effort medium)
  assert_contains "$out" "queued recon2" "the request must still be queued as a load hold"
  assert_contains "$out" "waits for an explicit release" \
    "a band with no automatic reconsideration must say the hold waits for a release"
  assert_not_contains "$out" "at the next successful cleanup or session start" \
    "a band with auto_reconsider false must not promise an automatic retake"
  pass "a queued hold promises automatic reconsideration only where the band records it"
}

test_an_interrupted_batch_leaves_no_fleet_state_snapshot_behind() {
  local rec tmpdir marker pid leftover
  rec=$(make_refusal_home batch-census); read_home_record "$rec"
  write_admission_policy "$HOME_DIR"
  write_brief "$HOME_DIR" bt1 no-mistakes
  tmpdir="$TMP_ROOT/batch-census/tmp"
  marker="$TMP_ROOT/batch-census/child-reached-the-queue"
  mkdir -p "$tmpdir"
  # The child stalls inside the refusal's queue probe, so the parent is reliably
  # still mid-batch - holding the shared census - when the signal arrives.
  cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  : > "$FM_FAKE_TASKS_AXI_MARKER"
  sleep 5
  printf '%s\n' '0.2.4'
fi
exit 0
SH
  chmod +x "$FAKEBIN/tasks-axi"
  TMPDIR="$tmpdir" FM_FAKE_TASKS_AXI_MARKER="$marker" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "bt1=$PROJ_DIR" --mode no-mistakes --yolo off \
      --reason-code NL_RULE_CLASSIFICATION --harness codex \
      --route R-MED --model vendor/large --effort medium >/dev/null 2>&1 &
  pid=$!
  fm_test_reap "$pid"
  fm_test_wait_file "$marker" 60 "$pid" \
    "the batch parent exited before any pair reached the queue substrate" \
    "the batch parent never dispatched a pair, so this case proves nothing"
  ls "$tmpdir"/fm-spawn-admission-snapshot.* >/dev/null 2>&1 \
    || fail "the batch parent never took the shared census, so this case proves nothing"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  leftover=$(find "$tmpdir" -maxdepth 1 -name 'fm-spawn-admission-snapshot.*' | wc -l | tr -d ' ')
  [ "$leftover" = 0 ] \
    || fail "an interrupted batch left $leftover fleet-state snapshot(s) behind in TMPDIR"
  pass "a batch interrupted by a signal leaves no fleet-state snapshot behind"
}

test_shipped_example_ships_admission_switched_off() {
  local rec out enabled
  # Downstream homes copy this file verbatim. An enabled admission policy bands
  # every invocation that does not hold the home's session lock, so a shipped
  # `enabled: true` would arm admission for every home that copied the example
  # without anyone choosing it. The whole block stays present and documented;
  # only activation is deliberate.
  enabled=$(jq -r '._scheduling.admission_control.enabled' "$ROOT/docs/examples/crew-dispatch.json")
  [ "$enabled" = false ] \
    || fail "docs/examples/crew-dispatch.json must ship admission control switched off, got enabled=$enabled"
  [ "$(jq -r '._scheduling.admission_control | has("bands")' "$ROOT/docs/examples/crew-dispatch.json")" = true ] \
    || fail "the shipped example must keep the full admission schema so a reader can switch it on deliberately"
  rec=$(make_refusal_home shipped-example none); read_home_record "$rec"
  cp "$ROOT/docs/examples/crew-dispatch.json" "$HOME_DIR/config/crew-dispatch.json"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-admission.sh" --json 2>&1); rc=$?
  expect_code 0 "$rc" "the shipped example must leave admission inert"
  [ "$(printf '%s' "$out" | jq -r '.active')" = false ] \
    || fail "the shipped example must evaluate as inert admission, got: $out"
  pass "the shipped example ships admission control switched off, so copying it arms nothing"
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
test_a_floor_axis_outside_its_vocabulary_refuses_rather_than_skipping
test_unstated_model_is_refused_rather_than_recorded_as_checked
test_absent_models_block_refuses_as_unverifiable
test_undefined_floor_id_refuses_and_records_no_capability_floor
test_held_model_is_refused_at_the_chokepoint_and_check_agrees_with_eligible
test_a_substitute_list_says_whether_it_was_registry_checked
test_check_asks_the_registry_only_about_the_model_it_answers_for
test_default_only_route_is_listed_and_enforced
test_failover_stays_inside_the_pool_in_order
test_an_ambiguous_failover_anchor_is_refused_rather_than_resolved
test_availability_hold_removes_a_candidate_and_release_restores_it
test_a_hold_that_cannot_match_a_candidate_is_refused_rather_than_recorded
test_unknown_availability_state_is_refused
test_exhausted_pool_stops_and_reports_rather_than_degrading
test_expired_hold_stops_binding_without_a_sweep
test_malformed_availability_record_is_not_an_empty_one
test_an_unreadable_input_names_the_file_that_could_not_be_read
test_spawn_refuses_a_pool_violation_and_creates_nothing
test_spawn_refuses_a_floor_violation_and_creates_nothing
test_spawn_requires_the_route_claim_or_derives_it_from_an_explicit_floor
test_spawn_refuses_a_route_and_floor_that_contradict_each_other
test_spawn_refuses_route_on_a_secondmate_spawn
test_unrouted_home_is_untouched_by_activation
test_route_claim_is_refused_where_nothing_can_check_it
test_spawn_records_the_route_and_the_policy_that_checked_it
test_admission_hard_band_refuses_the_spawn_naming_the_condition
test_soft_admission_band_defers_distinguishably_from_a_refusal
test_a_queued_hold_promises_reconsideration_only_when_the_band_records_it
test_an_interrupted_batch_leaves_no_fleet_state_snapshot_behind
test_shipped_example_ships_admission_switched_off
test_activation_does_not_recheck_work_already_dispatched
