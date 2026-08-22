#!/usr/bin/env bash
# Independent failure-direction and mutation battery for ROUTING_DECISION.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-routing-decision-lib.sh
. "$ROOT/bin/fm-routing-decision-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-routing-decision-negative-battery)
LAB="$TMP_ROOT/lab"
HOME_DIR="$LAB/home"
TASK_DIR="$HOME_DIR/data/t1"
RUN_HARNESS=claude
RUN_MODEL=opus
RUN_EFFORT=high
RUN_RAW=0
RUN_LAUNCH='claude verified template'
RUN_MODEL_FRAGMENT="--model 'opus' "
RUN_EFFORT_FRAGMENT="--effort 'high' "
negative_count=0
counterexample_count=0
PREEXISTING_FINAL=0

sha_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

sha_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

future_timestamp() {
  local epoch=$(( $(date -u +%s) + 120 ))
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}

write_fixture() {
  local brief_hash intent_hash config_hash home_hash host_hash now
  rm -rf "$LAB"
  mkdir -p "$TASK_DIR" "$HOME_DIR/config" "$HOME_DIR/state"
  printf 'exact brief bytes for t1\n' > "$TASK_DIR/brief.md"
  jq -n '{
    rules: [{when: "firstmate repo work", use: {harness: "claude", model: "opus", effort: "high"}}],
    default: [
      {harness: "codex", model: "gpt-5", effort: "high"},
      {harness: "claude", model: "opus", effort: "xhigh"}
    ]
  }' > "$HOME_DIR/config/crew-dispatch.json"
  brief_hash=$(sha_file "$TASK_DIR/brief.md")
  jq -n --arg brief_sha256 "$brief_hash" '{
    schema_version: 1,
    task_id: "t1",
    brief_sha256: $brief_sha256,
    hard_capability: "bash refactor",
    ambiguity: "LOW",
    risk: "LOCAL_FAIL_CLOSED",
    authority: "CONFIGURED_RULE",
    gate: "no-mistakes",
    forbidden_effects: ["push", "merge"]
  }' > "$TASK_DIR/routing-intent.json"
  intent_hash=$(sha_file "$TASK_DIR/routing-intent.json")
  config_hash=$(sha_file "$HOME_DIR/config/crew-dispatch.json")
  home_hash=$(printf '%s' "$HOME_DIR" | sha_text)
  host_hash=$(uname -n | sha_text)
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg intent_hash "$intent_hash" \
    --arg config_hash "$config_hash" \
    --arg home_hash "$home_hash" \
    --arg host_hash "$host_hash" \
    --arg now "$now" '{
      schema_version: 1,
      task_id: "t1",
      intent_sha256: $intent_hash,
      dispatch_config: {kind: "present", sha256: $config_hash},
      matched_profile: {source: "rule", index: 0},
      supervisor: {kind: "current-firstmate-home", home_sha256: $home_hash},
      host: {kind: "local", identity_sha256: $host_hash},
      launch_binding: {kind: "verified_template", harness: "claude", model: "opus", effort: "high"},
      harness: "claude",
      model: "opus",
      effort: "high",
      candidates_considered: [{harness: "claude", model: "opus", effort: "high"}],
      quota: {source: "NOT_APPLICABLE_SINGLETON", observed_at: null, snapshot_sha256: null},
      quota_basis: "NOT_APPLICABLE_SINGLETON",
      fallback: "NONE",
      rationale: "only capable candidate for the matched rule",
      required_gate: "no-mistakes",
      selection_order: ["hard_capability", "ambiguity_complexity", "fresh_quota_among_capable"],
      generated_at: $now
    }' > "$TASK_DIR/routing-decision.pending.json"
  RUN_HARNESS=claude
  RUN_MODEL=opus
  RUN_EFFORT=high
  RUN_RAW=0
  RUN_LAUNCH='claude verified template'
  RUN_MODEL_FRAGMENT="--model 'opus' "
  RUN_EFFORT_FRAGMENT="--effort 'high' "
  PREEXISTING_FINAL=0
}

update_receipt() {
  local filter=$1 file="$TASK_DIR/routing-decision.pending.json" tmp="$TASK_DIR/routing-decision.pending.json.tmp"
  jq "$filter" "$file" > "$tmp" || return 1
  mv "$tmp" "$file"
}

update_intent() {
  local filter=$1 file="$TASK_DIR/routing-intent.json" tmp="$TASK_DIR/routing-intent.json.tmp"
  jq "$filter" "$file" > "$tmp" || return 1
  mv "$tmp" "$file"
}

write_multi_fixture() {
  local now snapshot_hash config_hash
  write_fixture
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n '{rules: [{when: "firstmate repo work", use: [
    {harness: "claude", model: "opus", effort: "high"},
    {harness: "codex", model: "gpt-5", effort: "high"}
  ]}]}' > "$HOME_DIR/config/crew-dispatch.json"
  jq -n --arg now "$now" '{
    schemaVersion: 5,
    generatedAt: $now,
    providers: [{provider: "claude", state: {}, quotaSemantics: {}}]
  }' > "$TASK_DIR/quota-snapshot.json"
  snapshot_hash=$(sha_file "$TASK_DIR/quota-snapshot.json")
  config_hash=$(sha_file "$HOME_DIR/config/crew-dispatch.json")
  update_receipt ".dispatch_config.sha256 = \"$config_hash\"
    | .candidates_considered = [
        {harness: \"claude\", model: \"opus\", effort: \"high\"},
        {harness: \"codex\", model: \"gpt-5\", effort: \"high\"}
      ]
    | .quota_basis = \"FRESH_QUOTA_COMPARISON\"
    | .quota = {source: \"quota-axi --json\", observed_at: \"$now\", snapshot_sha256: \"$snapshot_hash\"}"
}

run_validator_then_effects() {
  fm_routing_decision_validate_and_persist \
    "$HOME_DIR/data" "$HOME_DIR/config" t1 \
    "$RUN_HARNESS" "$RUN_MODEL" "$RUN_EFFORT" "$HOME_DIR" "$RUN_RAW" "$RUN_LAUNCH" \
    "$RUN_MODEL_FRAGMENT" "$RUN_EFFORT_FRAGMENT" || return 1
  mkdir -p "$LAB/worktree.lease" "$LAB/endpoint"
  printf 'published\n' > "$HOME_DIR/state/t1.meta"
}

assert_no_effects() {
  assert_absent "$LAB/worktree.lease" "routing refusal leased a worktree"
  assert_absent "$LAB/endpoint" "routing refusal created an endpoint"
  assert_absent "$HOME_DIR/state/t1.meta" "routing refusal published task metadata"
  if [ "$PREEXISTING_FINAL" -eq 0 ]; then
    assert_absent "$TASK_DIR/routing-decision.json" "invalid receipt was persisted"
  else
    assert_present "$TASK_DIR/routing-decision.pending.json" "hostile final target consumed the pending receipt"
  fi
}

exercise_negative() { # <name> <predicate> <setup-function>
  local name=$1 predicate=$2 setup=$3 out status
  write_fixture
  "$setup"
  out=$(run_validator_then_effects 2>&1)
  status=$?
  expect_code 1 "$status" "$name should refuse"
  assert_contains "$out" "ROUTING_DECISION $predicate" "$name named the wrong predicate"
  assert_no_effects
  negative_count=$((negative_count + 1))
  pass "$name refuses before lease, endpoint, and metadata"

  write_fixture
  "$setup"
  if (
    fm_routing_decision_validate_and_persist() { return 0; }
    run_validator_then_effects >/dev/null 2>&1
  ); then
    assert_present "$LAB/worktree.lease" "$name counterexample did not reach a worktree lease"
    assert_present "$LAB/endpoint" "$name counterexample did not reach an endpoint"
    assert_present "$HOME_DIR/state/t1.meta" "$name counterexample did not publish metadata"
  else
    fail "$name counterexample did not fire after the routing validator was neutered"
  fi
  counterexample_count=$((counterexample_count + 1))
  pass "$name firing counterexample"
}

setup_missing_receipt() { rm "$TASK_DIR/routing-decision.pending.json"; }
setup_missing_intent() { rm "$TASK_DIR/routing-intent.json"; }
setup_empty_receipt() { : > "$TASK_DIR/routing-decision.pending.json"; }
setup_empty_intent() { : > "$TASK_DIR/routing-intent.json"; }
setup_wrong_task() { update_receipt '.task_id = "other"'; }
setup_stale() { update_receipt '.generated_at = "2000-01-01T00:00:00Z"'; }
setup_future() { update_receipt ".generated_at = \"$(future_timestamp)\""; }
setup_model_binding_mismatch() { update_receipt '.launch_binding.model = "sonnet"'; }
setup_effort_binding_mismatch() { update_receipt '.launch_binding.effort = "low"'; }
setup_config_absent_after_receipt() { rm "$HOME_DIR/config/crew-dispatch.json"; }
setup_dynamic_raw() {
  RUN_RAW=1
  # shellcheck disable=SC2016 # the command must retain the unresolved variable literally
  RUN_LAUNCH='claude --model "$ROUTE_MODEL" --effort high'
  update_receipt '.matched_profile = {source: "explicit_override", index: null}
    | .launch_binding.kind = "raw_launch"'
  update_intent '.authority = "EXPLICIT_RUNTIME_OVERRIDE"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\""
}
setup_env_raw() {
  RUN_RAW=1
  RUN_LAUNCH='MODEL=opus claude --model opus --effort high'
  update_receipt '.matched_profile = {source: "explicit_override", index: null}
    | .launch_binding.kind = "raw_launch"'
  update_intent '.authority = "EXPLICIT_RUNTIME_OVERRIDE"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\""
}
setup_nonstandard_raw() {
  RUN_RAW=1
  RUN_LAUNCH='claude -m opus --effort high'
  update_receipt '.matched_profile = {source: "explicit_override", index: null}
    | .launch_binding.kind = "raw_launch"'
  update_intent '.authority = "EXPLICIT_RUNTIME_OVERRIDE"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\""
}
setup_unresolved_raw() {
  RUN_RAW=1
  RUN_LAUNCH='claude --model opus'
  update_receipt '.matched_profile = {source: "explicit_override", index: null}
    | .launch_binding = {kind: "raw_launch", harness: "claude", model: "opus", effort: null}'
  update_intent '.authority = "EXPLICIT_RUNTIME_OVERRIDE"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\""
}
setup_intent_hash_mismatch() { update_receipt '.intent_sha256 = ("0" * 64)'; }
setup_brief_swap() { printf 'replacement brief bytes\n' > "$TASK_DIR/brief.md"; }
setup_gate_mismatch() { update_receipt '.required_gate = "direct-PR"'; }
setup_forbidden_fallback() { update_receipt '.fallback = "crew-harness"'; }
setup_supervisor_mismatch() { update_receipt '.supervisor.home_sha256 = ("0" * 64)'; }
setup_host_mismatch() { update_receipt '.host.identity_sha256 = ("0" * 64)'; }
setup_candidate_mismatch() { update_receipt '.candidates_considered[0].model = "sonnet"'; }
setup_unknown_key() { update_receipt '.bypass = true'; }
setup_missing_quota() { write_multi_fixture; rm "$TASK_DIR/quota-snapshot.json"; }
setup_stale_quota() {
  write_multi_fixture
  update_receipt '.quota.observed_at = "2000-01-01T00:00:00Z"'
  jq '.generatedAt = "2000-01-01T00:00:00Z"' "$TASK_DIR/quota-snapshot.json" > "$TASK_DIR/quota-old.json"
  mv "$TASK_DIR/quota-old.json" "$TASK_DIR/quota-snapshot.json"
  update_receipt ".quota.snapshot_sha256 = \"$(sha_file "$TASK_DIR/quota-snapshot.json")\""
}
setup_singleton_quota() {
  update_receipt '.quota_basis = "FRESH_QUOTA_COMPARISON"
    | .quota = {source: "quota-axi --json", observed_at: .generated_at, snapshot_sha256: ("0" * 64)}'
}
setup_final_directory() { PREEXISTING_FINAL=1; mkdir "$TASK_DIR/routing-decision.json"; }
setup_final_symlink() {
  PREEXISTING_FINAL=1
  printf '{}\n' > "$TASK_DIR/attacker-target.json"
  ln -s "$TASK_DIR/attacker-target.json" "$TASK_DIR/routing-decision.json"
}
setup_truncated_receipt() { printf '{"schema_version":1' > "$TASK_DIR/routing-decision.pending.json"; }
setup_config_byte_mutation() { printf '\n' >> "$HOME_DIR/config/crew-dispatch.json"; }
setup_pending_symlink() {
  mv "$TASK_DIR/routing-decision.pending.json" "$TASK_DIR/receipt-target.json"
  ln -s "$TASK_DIR/receipt-target.json" "$TASK_DIR/routing-decision.pending.json"
}
setup_selection_order_tamper() { update_receipt '.selection_order |= reverse'; }
setup_quota_byte_mutation() { write_multi_fixture; printf '\n' >> "$TASK_DIR/quota-snapshot.json"; }
setup_quota_symlink() {
  write_multi_fixture
  mv "$TASK_DIR/quota-snapshot.json" "$TASK_DIR/quota-target.json"
  ln -s "$TASK_DIR/quota-target.json" "$TASK_DIR/quota-snapshot.json"
}
setup_selected_tuple_outside_candidates() {
  write_multi_fixture
  RUN_MODEL=sonnet
  RUN_MODEL_FRAGMENT="--model 'sonnet' "
}
setup_rule_index_out_of_range() { update_receipt '.matched_profile.index = 7'; }
setup_wrong_quota_schema() {
  write_multi_fixture
  jq '.schemaVersion = 4' "$TASK_DIR/quota-snapshot.json" > "$TASK_DIR/quota-wrong-schema.json"
  mv "$TASK_DIR/quota-wrong-schema.json" "$TASK_DIR/quota-snapshot.json"
  update_receipt ".quota.snapshot_sha256 = \"$(sha_file "$TASK_DIR/quota-snapshot.json")\""
}

exercise_negative "01 missing receipt" missing setup_missing_receipt
exercise_negative "02 missing intent" missing setup_missing_intent
exercise_negative "03 empty receipt" MALFORMED_SCHEMA setup_empty_receipt
exercise_negative "04 empty intent" MALFORMED_INTENT setup_empty_intent
exercise_negative "05 task mismatch" TASK_MISMATCH setup_wrong_task
exercise_negative "06 stale receipt" STALE setup_stale
exercise_negative "07 future receipt" STALE setup_future
exercise_negative "08 emitted model mismatch" LAUNCH_BINDING_MISMATCH setup_model_binding_mismatch
exercise_negative "09 emitted effort mismatch" LAUNCH_BINDING_MISMATCH setup_effort_binding_mismatch
exercise_negative "10 canonical config removed" DISPATCH_CONFIG_MISMATCH setup_config_absent_after_receipt
exercise_negative "11 raw shell expansion" RAW_LAUNCH_NOT_VERIFIABLE setup_dynamic_raw
exercise_negative "12 raw environment prefix" RAW_LAUNCH_NOT_VERIFIABLE setup_env_raw
exercise_negative "13 raw non-standard model flag" RAW_LAUNCH_NOT_VERIFIABLE setup_nonstandard_raw
exercise_negative "14 raw missing effort" RAW_LAUNCH_UNRESOLVED setup_unresolved_raw
exercise_negative "15 intent hash mismatch" INTENT_HASH_MISMATCH setup_intent_hash_mismatch
exercise_negative "16 swapped brief" BRIEF_HASH_MISMATCH setup_brief_swap
exercise_negative "17 required gate mismatch" GATE_MISMATCH setup_gate_mismatch
exercise_negative "18 forbidden fallback" FORBIDDEN_FALLBACK setup_forbidden_fallback
exercise_negative "19 supervisor mismatch" SUPERVISOR_MISMATCH setup_supervisor_mismatch
exercise_negative "20 host mismatch" HOST_MISMATCH setup_host_mismatch
exercise_negative "21 candidate set mismatch" DISPATCH_CONFIG_MISMATCH setup_candidate_mismatch
exercise_negative "22 unknown receipt key" MALFORMED_SCHEMA setup_unknown_key
exercise_negative "23 missing multi-candidate quota" 'NOT_VERIFIABLE(QUOTA)' setup_missing_quota
exercise_negative "24 stale multi-candidate quota" 'NOT_VERIFIABLE(QUOTA)' setup_stale_quota
exercise_negative "25 singleton quota laundering" MALFORMED_QUOTA_BASIS setup_singleton_quota
exercise_negative "26 hostile final directory" PERSISTENCE_REFUSED setup_final_directory
exercise_negative "27 hostile final symlink" PERSISTENCE_REFUSED setup_final_symlink
exercise_negative "28 truncated receipt" MALFORMED_SCHEMA setup_truncated_receipt
exercise_negative "29 canonical config byte mutation" DISPATCH_CONFIG_MISMATCH setup_config_byte_mutation
exercise_negative "30 pending receipt symlink" missing setup_pending_symlink
exercise_negative "31 selection order tamper" MALFORMED_SCHEMA setup_selection_order_tamper
exercise_negative "32 quota snapshot byte mutation" 'NOT_VERIFIABLE(QUOTA)' setup_quota_byte_mutation
exercise_negative "33 quota snapshot symlink" 'NOT_VERIFIABLE(QUOTA)' setup_quota_symlink
exercise_negative "34 selected tuple outside candidates" INCAPABLE_CANDIDATE setup_selected_tuple_outside_candidates
exercise_negative "35 rule index out of range" DISPATCH_CONFIG_MISMATCH setup_rule_index_out_of_range
exercise_negative "36 wrong quota schema" 'NOT_VERIFIABLE(QUOTA)' setup_wrong_quota_schema

[ "$negative_count" -eq 36 ] || fail "negative battery counted $negative_count refusals instead of 36"
[ "$counterexample_count" -eq 36 ] || fail "negative battery counted $counterexample_count counterexamples instead of 36"
echo "# all 36 ROUTING_DECISION negatives refused before effects with 36 firing counterexamples"
