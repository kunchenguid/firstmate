#!/usr/bin/env bash
# Behavior tests for the model registry: schema validation, the freshness rule,
# referential integrity against config/crew-dispatch.json, price drift, the probe
# classifier, and promotion dormancy.
#
# Each test names the incident it is a regression for. The three incidents that
# motivated this machinery:
#   1. A routed model this account cannot use (configured from a plausible name,
#      never probed) broke an entire tier until an investigation found it.
#   2. `pi --list-models` proves nothing - it reads a local cache and is
#      byte-identical offline - yet it was used as the evidence for admission.
#   3. One API key exposes both free and metered models, rendered identically,
#      so a single plausible model name is a charge.
#
# Every single-quoted $name below is a jq variable bound by --arg, never a shell
# variable, so SC2016 is disabled for the whole file rather than per call site.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-model-registry-lib.sh
. "$ROOT/bin/fm-model-registry-lib.sh"

TMP=$(fm_test_tmproot fm-model-registry)
# fm_test_tmproot registers its cleanup inside the command substitution, so the
# directory it names is already gone by the time we get the path. Recreate it and
# own the teardown here, which is the extension point tests/lib.sh documents.
mkdir -p "$TMP"
trap 'rm -rf "$TMP"; fm_test_cleanup' EXIT

# A minimal registry that validates clean; tests mutate copies of it with jq.
base_registry() {
  cat <<'JSON'
{
  "schema": "fm-model-registry.v1",
  "providers": {
    "openai-codex": { "access_class": "A", "cost_posture": "subscription-flat" },
    "opencode":     { "access_class": "B", "cost_posture": "api-key" },
    "google":       { "access_class": "B", "cost_posture": "api-key" }
  },
  "models": {
    "openai-codex/gpt-5.4-mini": {
      "provider": "openai-codex", "model_id": "gpt-5.4-mini",
      "cost_class": "subscription-flat", "status": "approved-primary",
      "observation_level": "O4",
      "evidence": { "probe": { "result": "ok", "rc": 0, "at": "2026-07-27T01:20:00Z" } }
    },
    "opencode/deepseek-v4-flash-free": {
      "provider": "opencode", "model_id": "deepseek-v4-flash-free",
      "cost_class": "verified-free", "status": "approved-fallback",
      "observation_level": "O4",
      "price_at_verification": { "input": 0, "output": 0 },
      "evidence": { "probe": { "result": "ok", "rc": 0, "at": "2026-07-27T01:22:00Z" } }
    }
  },
  "zero_budget": {
    "allowlist": {
      "opencode/deepseek-v4-flash-free": {
        "price_at_verification": { "input": 0, "output": 0 },
        "verified_at": "2026-07-27T01:22:00Z",
        "sources": ["harness-static-catalogue", "probe"]
      }
    }
  },
  "observation": { "levels": { "O1": { "probe_max_age_days": 1 },
                               "O4": { "probe_max_age_days": 90 } } }
}
JSON
}

# write_registry <file> [jq-args... filter] - base registry, optionally
# transformed. Everything after <file> is passed to jq verbatim, so a test can
# supply --arg bindings alongside its filter.
write_registry() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || set -- '.'
  base_registry | jq "$@" > "$out"
}

# --- schema validation ------------------------------------------------------

# --- fm-model-verify due-selection (interval gating) ------------------------

# Regression: an earlier form of this query indexed the approved-status ARRAY
# instead of the entry, which failed the whole jq program. The failure was
# swallowed, so the sweep silently probed NOTHING while looking perfectly
# healthy - an observation floor that never runs is worse than none, because it
# reads as a passing check.
verify_dry_run() {
  local home=$1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-model-verify.sh" --dry-run 2>&1
}

# make_verify_home <name> <probe-iso> -> home whose one O1 model was probed then.
make_verify_home() {
  local home="$TMP/$1" at=$2
  mkdir -p "$home/config" "$home/state"
  write_registry "$home/config/models.json" --arg at "$at" '
    .models["openai-codex/gpt-5.4-mini"].observation_level = "O1"
    | .models["openai-codex/gpt-5.4-mini"].evidence.probe.at = $at
    | del(.models["opencode/deepseek-v4-flash-free"])
    | del(.zero_budget.allowlist["opencode/deepseek-v4-flash-free"])'
  printf '%s\n' "$home"
}

test_stale_model_is_due_for_probe() {
  local home out
  home=$(make_verify_home verify-stale "2020-01-01T00:00:00Z")
  out=$(verify_dry_run "$home")
  assert_contains "$out" "would probe openai-codex/gpt-5.4-mini" "a long-stale O1 model is due"
  pass "a model past its observation interval is selected for a probe"
}

test_fresh_model_is_not_due() {
  local home out now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  home=$(make_verify_home verify-fresh "$now")
  out=$(verify_dry_run "$home")
  assert_not_contains "$out" "would probe" "a just-probed model is not due"
  pass "a model inside its observation interval is skipped, keeping the steady-state sweep free"
}

test_unprobed_model_is_due() {
  local home out
  home=$(make_verify_home verify-unprobed "2020-01-01T00:00:00Z")
  jq 'del(.models["openai-codex/gpt-5.4-mini"].evidence)' "$home/config/models.json" > "$home/c.json"
  mv "$home/c.json" "$home/config/models.json"
  out=$(verify_dry_run "$home")
  assert_contains "$out" "would probe" "a never-probed model is always due"
  pass "a model with no probe record at all is due for a probe"
}

test_valid_registry_passes() {
  local reg="$TMP/valid.json" err
  write_registry "$reg"
  if ! err=$(fm_model_registry_validate "$reg"); then
    fail "a well-formed registry must validate, got: $err"
  fi
  pass "a well-formed registry validates clean"
}

test_malformed_json_refused() {
  local reg="$TMP/malformed.json" err
  echo '{ not json' > "$reg"
  err=$(fm_model_registry_validate "$reg") && fail "malformed JSON must not validate"
  assert_contains "$err" "malformed JSON" "malformed JSON is named as such"
  pass "malformed registry JSON is refused"
}

test_unknown_schema_version_refused() {
  local reg="$TMP/badschema.json" err
  write_registry "$reg" '.schema = "fm-model-registry.v99"'
  err=$(fm_model_registry_validate "$reg") && fail "an unknown schema version must not validate"
  assert_contains "$err" "unsupported schema" "the unsupported version is named"
  pass "an unknown schema version is refused rather than best-effort parsed"
}

test_missing_schema_refused() {
  local reg="$TMP/noschema.json" err
  write_registry "$reg" 'del(.schema)'
  err=$(fm_model_registry_validate "$reg") && fail "a registry with no schema must not validate"
  assert_contains "$err" "missing schema" "the absent schema is named"
  pass "a registry with no schema field is refused"
}

# THE FRESHNESS RULE. Regression for incident 2 and for the finding that two
# allowlisted names existed only in a provider-refreshed cache: the thing that
# makes a name safe is its PRICE, and a cache the provider rewrites cannot
# establish one.
test_cache_only_allowlist_entry_refused() {
  local reg="$TMP/cacheonly.json" err
  write_registry "$reg" '.zero_budget.allowlist["opencode/laguna-s-2.1-free"] =
    { "price_at_verification": {"input":0,"output":0},
      "verified_at": "2026-07-27T01:22:00Z",
      "sources": ["harness-fetched-cache"] }'
  err=$(fm_model_registry_validate "$reg") && fail "a cache-only allowlist entry must not validate"
  assert_contains "$err" "opencode/laguna-s-2.1-free" "the offending entry is named"
  assert_contains "$err" "cache" "the reason names the cache"
  pass "an allowlist entry resting only on a provider-rewritten cache is refused (freshness rule)"
}

# A probe proves ENTITLEMENT, never price. An entry whose price is known only
# from a provider-rewritten cache is refused even when the model demonstrably
# answers, because "it responds" and "it is free" are different claims.
test_probe_does_not_establish_price() {
  local reg="$TMP/probeonly.json" err
  write_registry "$reg" '.zero_budget.allowlist["opencode/laguna-s-2.1-free"] =
    { "price_at_verification": {"input":0,"output":0},
      "verified_at": "2026-07-27T01:22:00Z",
      "sources": ["harness-fetched-cache", "probe"] }'
  err=$(fm_model_registry_validate "$reg") && fail "a probe must not stand in for price evidence"
  assert_contains "$err" "price evidence" "the reason distinguishes price from entitlement"
  pass "a successful probe does not establish a price - cache-plus-probe is still refused"
}

test_price_bearing_source_accepted() {
  local reg="$TMP/cacheplus.json" err
  write_registry "$reg" '.zero_budget.allowlist["opencode/laguna-s-2.1-free"] =
    { "price_at_verification": {"input":0,"output":0},
      "verified_at": "2026-07-27T01:22:00Z",
      "sources": ["harness-fetched-cache", "harness-static-catalogue", "probe"] }'
  if ! err=$(fm_model_registry_validate "$reg"); then
    fail "a cache alongside a price-bearing catalogue must validate, got: $err"
  fi
  pass "a cache alongside a genuinely price-bearing source is acceptable"
}

test_nonzero_priced_allowlist_entry_refused() {
  local reg="$TMP/priced.json" err
  write_registry "$reg" '.zero_budget.allowlist["opencode/deepseek-v4-flash-free"].price_at_verification.input = 0.15'
  err=$(fm_model_registry_validate "$reg") && fail "a non-zero-priced allowlist entry must not validate"
  assert_contains "$err" "not priced at zero" "the reason names the price"
  pass "an allowlist entry recording a non-zero price is refused"
}

test_unknown_source_kind_refused() {
  local reg="$TMP/badsource.json" err
  write_registry "$reg" '.zero_budget.allowlist["opencode/deepseek-v4-flash-free"].sources = ["vibes"]'
  err=$(fm_model_registry_validate "$reg") && fail "an unknown source kind must not validate"
  assert_contains "$err" "unknown evidence source kind" "the bad kind is reported"
  pass "an unrecognised evidence source kind is refused"
}

test_rejected_model_needs_reason() {
  local reg="$TMP/noreason.json" err
  write_registry "$reg" '.models["openai-codex/gpt-5.3-codex-spark"] =
    { "provider": "openai-codex", "model_id": "gpt-5.3-codex-spark",
      "cost_class": "subscription-flat", "status": "rejected" }'
  err=$(fm_model_registry_validate "$reg") && fail "a rejected model with no reason must not validate"
  assert_contains "$err" "status_reason" "the missing reason is named"
  pass "a rejected model must record WHY, so the refusal is not rediscovered"
}

# THE HARD CEILING. No accumulation of evidence may enter Tier 1 or Tier 0:
# Tier 1 is triggered by risk, not capability rank, and a spotless Tier 2 record
# demonstrates nothing about credential or destructive-operation judgment.
test_promotion_ceiling_enforced() {
  local reg="$TMP/ceiling.json" err
  write_registry "$reg" '.promotion = { "authority": { "t2_to_t1": "automatic-notify-immediate" } }'
  err=$(fm_model_registry_validate "$reg") && fail "an automatic T2->T1 promotion must not validate"
  assert_contains "$err" "t2_to_t1" "the offending transition is named"
  pass "the registry cannot authorize automatic promotion into Tier 1"
}

test_promotion_ceiling_t0_enforced() {
  local reg="$TMP/ceiling0.json" err
  write_registry "$reg" '.promotion = { "authority": { "t1_to_t0": "captain-confirm" } }'
  err=$(fm_model_registry_validate "$reg") && fail "any evidence-driven T1->T0 promotion must not validate"
  assert_contains "$err" "t1_to_t0" "the offending transition is named"
  pass "the registry cannot authorize evidence-driven promotion into Tier 0"
}

test_promotion_t3_to_t2_cannot_be_automatic() {
  local reg="$TMP/t3t2.json" err
  write_registry "$reg" '.promotion = { "authority": { "t3_to_t2": "automatic-notify-immediate" } }'
  err=$(fm_model_registry_validate "$reg") && fail "an automatic T3->T2 promotion must not validate"
  assert_contains "$err" "t3_to_t2" "the offending transition is named"
  pass "T3->T2 promotion cannot be made automatic (captain confirmation is required)"
}

test_ruled_authority_validates() {
  local reg="$TMP/ruled.json" err
  write_registry "$reg" '.promotion = { "enabled": false,
    "requires_instrument": "wake-outcome-ledger:terminal-task-line",
    "authority": { "t4_to_t3": "automatic-notify-immediate",
                   "t3_to_t2": "captain-confirm",
                   "t2_to_t1": "never-by-evidence",
                   "t1_to_t0": "never-by-evidence" } }'
  if ! err=$(fm_model_registry_validate "$reg"); then
    fail "the ruled authority model must validate, got: $err"
  fi
  pass "the ruled promotion authority (auto T4->T3, confirmed T3->T2, never T1/T0) validates"
}

# --- referential integrity --------------------------------------------------

dispatch_with_model() {
  local out=$1 model=$2
  cat > "$out" <<JSON
{ "rules": [ { "when": "x", "use": { "harness": "pi", "model": "$model", "effort": "low" } } ] }
JSON
}

# THE REGRESSION FOR INCIDENT 1: naming a model with a rejected status in a
# dispatch rule must fail at CONFIG-EDIT time, before any worker is launched.
test_rejected_model_in_dispatch_fails() {
  local reg="$TMP/int-rejected.json" disp="$TMP/int-rejected-dispatch.json" out
  write_registry "$reg" '.models["openai-codex/gpt-5.3-codex-spark"] =
    { "provider": "openai-codex", "model_id": "gpt-5.3-codex-spark",
      "cost_class": "subscription-flat", "status": "rejected",
      "status_reason": "server-side entitlement refusal for this account" }'
  dispatch_with_model "$disp" "openai-codex/gpt-5.3-codex-spark"
  out=$(fm_model_registry_integrity "$disp" "$reg") && fail "routing a rejected model must fail integrity"
  assert_contains "$out" "gpt-5.3-codex-spark" "the rejected model is named"
  assert_contains "$out" "rejected" "the status is reported"
  pass "a dispatch rule naming a REJECTED model fails integrity (incident 1 regression)"
}

test_unregistered_model_in_dispatch_fails() {
  local reg="$TMP/int-unreg.json" disp="$TMP/int-unreg-dispatch.json" out
  write_registry "$reg"
  dispatch_with_model "$disp" "openai-codex/gpt-5.9-imaginary"
  out=$(fm_model_registry_integrity "$disp" "$reg") && fail "routing an unregistered model must fail integrity"
  assert_contains "$out" "absent from config/models.json" "the absence is reported"
  pass "a dispatch rule naming an unregistered model fails integrity"
}

test_unprobed_model_in_dispatch_fails() {
  local reg="$TMP/int-unprobed.json" disp="$TMP/int-unprobed-dispatch.json" out
  write_registry "$reg" '.models["openai-codex/gpt-5.5"] =
    { "provider": "openai-codex", "model_id": "gpt-5.5",
      "cost_class": "subscription-flat", "status": "approved-fallback" }'
  dispatch_with_model "$disp" "openai-codex/gpt-5.5"
  out=$(fm_model_registry_integrity "$disp" "$reg") && fail "routing an unprobed model must fail integrity"
  assert_contains "$out" "no live-probe record" "the missing probe is reported"
  pass "a dispatch rule naming a model with NO probe record fails integrity"
}

test_registered_probed_model_passes() {
  local reg="$TMP/int-ok.json" disp="$TMP/int-ok-dispatch.json" out
  write_registry "$reg"
  dispatch_with_model "$disp" "openai-codex/gpt-5.4-mini"
  if ! out=$(fm_model_registry_integrity "$disp" "$reg" "$(date -u -d '2026-07-28' +%s 2>/dev/null || date -u +%s)"); then
    fail "an approved, probed, in-interval model must pass integrity, got: $out"
  fi
  pass "an approved and recently probed model passes integrity"
}

test_bare_model_name_ignored_by_integrity() {
  local reg="$TMP/int-bare.json" disp="$TMP/int-bare-dispatch.json" out
  write_registry "$reg"
  dispatch_with_model "$disp" "opus"
  if ! out=$(fm_model_registry_integrity "$disp" "$reg"); then
    fail "a bare harness-native model name must not be checked against the registry, got: $out"
  fi
  pass "a bare harness-native model name is not subject to registry integrity"
}

test_stale_probe_evidence_reported() {
  local reg="$TMP/int-stale.json" disp="$TMP/int-stale-dispatch.json" out future
  write_registry "$reg"
  dispatch_with_model "$disp" "openai-codex/gpt-5.4-mini"
  # 2026-07-27 probe, O4 allows 90 days; evaluate far past that.
  future=$(date -u -d '2027-06-01' +%s 2>/dev/null || echo 1780000000)
  out=$(fm_model_registry_integrity "$disp" "$reg" "$future") && fail "stale probe evidence must fail integrity"
  assert_contains "$out" "past the 90d limit" "the interval is named"
  pass "probe evidence older than the observation interval is reported"
}

# --- price drift ------------------------------------------------------------

# The ONLY check that can catch a repricing: a name-based allowlist is
# structurally blind to it, because the thing that makes a name safe is a number
# stored in a catalogue the provider rewrites.
test_allowlisted_model_repriced_is_critical() {
  local reg="$TMP/drift.json" catalogue="$TMP/drift-cat.json" out
  cat > "$catalogue" <<'JSON'
{ "opencode": { "models": [ { "id": "deepseek-v4-flash-free", "cost": { "input": 0.15, "output": 0.6 } } ] } }
JSON
  write_registry "$reg" --arg c "$catalogue" '.providers.opencode.catalogue_sources = [$c]'
  out=$(fm_model_price_drift "$reg") && fail "a repriced allowlist model must be reported"
  assert_contains "$out" "no longer zero" "the repricing is named"
  assert_contains "$out" "suspend this route" "the required action is stated"
  pass "an allowlisted model that is no longer free is reported as critical"
}

test_price_drift_on_stored_price() {
  local reg="$TMP/drift2.json" catalogue="$TMP/drift2-cat.json" out
  cat > "$catalogue" <<'JSON'
{ "deepseek-v4-flash-free": { "id": "deepseek-v4-flash-free", "cost": { "input": 0, "output": 0 } },
  "claude-opus-4-8": { "id": "claude-opus-4-8", "cost": { "input": 5, "output": 25 } } }
JSON
  write_registry "$reg" --arg c "$catalogue" '.providers.opencode.catalogue_sources = [$c]
    | .models["opencode/claude-opus-4-8"] =
      { "provider": "opencode", "model_id": "claude-opus-4-8",
        "cost_class": "metered", "status": "blocked",
        "status_reason": "metered, rejected by cost policy",
        "price_at_verification": { "input": 3, "output": 15 } }'
  out=$(fm_model_price_drift "$reg") && fail "a drifted stored price must be reported"
  assert_contains "$out" "price drifted" "the drift is named"
  pass "a stored price differing from the current catalogue is reported"
}

test_no_drift_is_silent() {
  local reg="$TMP/nodrift.json" catalogue="$TMP/nodrift-cat.json" out
  cat > "$catalogue" <<'JSON'
{ "deepseek-v4-flash-free": { "id": "deepseek-v4-flash-free", "cost": { "input": 0, "output": 0 } } }
JSON
  write_registry "$reg" --arg c "$catalogue" '.providers.opencode.catalogue_sources = [$c]'
  if ! out=$(fm_model_price_drift "$reg"); then
    fail "an unchanged price must be silent, got: $out"
  fi
  [ -z "$out" ] || fail "an unchanged price must print nothing, got: $out"
  pass "an unchanged price prints nothing"
}

# A drift check that quietly stops running is indistinguishable from one that
# keeps passing, so an unreadable declared catalogue is reported.
test_unreadable_catalogue_reported() {
  local reg="$TMP/nocat.json" out
  write_registry "$reg" '.providers.opencode.catalogue_sources = ["/nonexistent/catalogue.json"]'
  out=$(fm_model_price_drift "$reg") && fail "an unreadable catalogue must be reported"
  assert_contains "$out" "unreadable" "the unreadable source is named"
  pass "a declared but unreadable catalogue source is reported, never silently skipped"
}

# --- probe classifier -------------------------------------------------------

# The four measured response shapes. The fixtures are the exact strings recorded
# by the investigation, not paraphrases. Separating a client-side failure from a
# server-side refusal matters: one is a local typo, the other is a fact about the
# account that must never be routed to again.
test_probe_classifier_shapes() {
  local got
  got=$(fm_model_probe_classify 0 "ok")
  [ "$got" = ok ] || fail "rc=0 must classify as ok, got $got"

  got=$(fm_model_probe_classify 1 "Codex error: The 'gpt-5.3-codex-spark' model is not supported when using Codex with a ChatGPT account.")
  [ "$got" = entitlement-refused ] || fail "server-side refusal must classify as entitlement-refused, got $got"

  got=$(fm_model_probe_classify 1 'Warning: Model "gpt-5.9-nonexistent" not found for provider "openai-codex". Using custom model id.')
  [ "$got" = unknown-model ] || fail "unknown model id must classify as unknown-model, got $got"

  got=$(fm_model_probe_classify 1 'Error: Unknown provider "not-a-provider". Use --list-models to see available providers.')
  [ "$got" = client-error ] || fail "unknown provider must classify as client-error, got $got"

  got=$(fm_model_probe_classify 1 "some novel failure nobody has recorded")
  [ "$got" = unclassified ] || fail "an unrecognised shape must classify as unclassified, got $got"

  pass "the four measured probe shapes each map to their own handler, and novelty is not guessed"
}

# --- promotion dormancy -----------------------------------------------------

# Activation must be a config and data condition, never a code change. The
# dormant state must name WHICH condition is unmet: a trigger nobody can check is
# indistinguishable from a rejected one.
test_promotion_dormant_by_default() {
  local reg="$TMP/dormant.json" out
  write_registry "$reg"
  out=$(fm_model_promotion_state "$reg")
  assert_contains "$out" "dormant" "an unconfigured promotion block is dormant"
  pass "promotion is dormant when nothing enables it"
}

test_promotion_dormant_without_instrument_data() {
  local reg="$TMP/dormant2.json" out state
  state=$(mktemp -d "$TMP/state.XXXXXX")
  write_registry "$reg" '.promotion = { "enabled": true,
    "requires_instrument": "wake-outcome-ledger:terminal-task-line" }'
  out=$(STATE="$state" fm_model_promotion_state "$reg")
  assert_contains "$out" "dormant" "enabled but instrument-less promotion stays dormant"
  assert_contains "$out" "wake-outcome-ledger" "the missing instrument is named"
  pass "promotion stays dormant while its evidence instrument produces nothing"
}

test_promotion_dormant_until_terminal_lines_exist() {
  local reg="$TMP/dormant3.json" out state
  state=$(mktemp -d "$TMP/state2.XXXXXX")
  printf '{"kind":"wake","seq":1}\n' > "$state/wake-outcome-ledger.jsonl"
  write_registry "$reg" '.promotion = { "enabled": true,
    "requires_instrument": "wake-outcome-ledger:terminal-task-line" }'
  out=$(STATE="$state" fm_model_promotion_state "$reg")
  assert_contains "$out" "dormant" "a ledger with no terminal lines keeps promotion dormant"
  assert_contains "$out" "task-terminal" "the missing line kind is named"
  pass "a ledger without terminal task lines keeps promotion dormant"
}

test_promotion_activates_on_config_and_data_only() {
  local reg="$TMP/active.json" out state
  state=$(mktemp -d "$TMP/state3.XXXXXX")
  printf '{"kind":"task-terminal","task":"x","outcome":"landed"}\n' > "$state/wake-outcome-ledger.jsonl"
  write_registry "$reg" '.promotion = { "enabled": true,
    "requires_instrument": "wake-outcome-ledger:terminal-task-line" }'
  out=$(STATE="$state" fm_model_promotion_state "$reg")
  [ "$out" = active ] || fail "config plus data must activate promotion with no code change, got: $out"
  pass "promotion activates on a config flag plus real instrument data, with no code change"
}

test_valid_registry_passes
test_malformed_json_refused
test_unknown_schema_version_refused
test_missing_schema_refused
test_cache_only_allowlist_entry_refused
test_probe_does_not_establish_price
test_price_bearing_source_accepted
test_nonzero_priced_allowlist_entry_refused
test_unknown_source_kind_refused
test_rejected_model_needs_reason
test_promotion_ceiling_enforced
test_promotion_ceiling_t0_enforced
test_promotion_t3_to_t2_cannot_be_automatic
test_ruled_authority_validates
test_rejected_model_in_dispatch_fails
test_unregistered_model_in_dispatch_fails
test_unprobed_model_in_dispatch_fails
test_registered_probed_model_passes
test_bare_model_name_ignored_by_integrity
test_stale_probe_evidence_reported
test_allowlisted_model_repriced_is_critical
test_price_drift_on_stored_price
test_no_drift_is_silent
test_unreadable_catalogue_reported
test_probe_classifier_shapes
test_promotion_dormant_by_default
test_promotion_dormant_without_instrument_data
test_promotion_dormant_until_terminal_lines_exist
test_promotion_activates_on_config_and_data_only
test_stale_model_is_due_for_probe
test_fresh_model_is_not_due
test_unprobed_model_is_due
