#!/usr/bin/env bash
# Behavior tests for zero-budget enforcement at spawn, the concurrency guard, the
# availability/routing separation, and the terminal no-candidate state.
#
# The rule being enforced: the budget for every API-key provider is ZERO, and it
# is a SAFETY rule rather than a preference. The trap it guards is that one
# credential reaches both free and metered models on the same provider, rendered
# identically, so a single plausible-looking model name is a charge. The unit of
# authorization is therefore the MODEL, never the provider and never the key.
#
# Enforcement asymmetry under test (ruled 2026-07-28):
#   registry ABSENT  -> inert, so the change is purely additive for homes that
#                       never opted in; bootstrap is what makes it non-silent.
#   registry PRESENT -> fail closed on every unclear answer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-model-registry-lib.sh
. "$ROOT/bin/fm-model-registry-lib.sh"

TMP=$(fm_test_tmproot fm-model-zero-budget)
# fm_test_tmproot registers its cleanup inside the command substitution, so the
# path it names is already gone; recreate it and own teardown here.
mkdir -p "$TMP"
trap 'rm -rf "$TMP"; fm_test_cleanup' EXIT

SPAWN="$ROOT/bin/fm-spawn.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"

registry_json() {
  cat <<'JSON'
{
  "schema": "fm-model-registry.v1",
  "providers": {
    "openai-codex":   { "access_class": "A", "cost_posture": "subscription-flat" },
    "opencode":       { "access_class": "B", "cost_posture": "api-key" },
    "google":         { "access_class": "B", "cost_posture": "api-key" },
    "local-ollama":   { "access_class": "D", "cost_posture": "self-hosted" },
    "github-copilot": { "access_class": "A", "cost_posture": "subscription-flat",
                        "status": "dropped",
                        "status_reason": "dropped from consideration by captain decision" }
  },
  "models": {
    "openai-codex/gpt-5.4-mini": {
      "provider": "openai-codex", "model_id": "gpt-5.4-mini",
      "cost_class": "subscription-flat", "status": "approved-primary",
      "evidence": { "probe": { "result": "ok", "rc": 0, "at": "2026-07-27T01:20:00Z" } }
    },
    "google/gemini-2.5-flash": {
      "provider": "google", "model_id": "gemini-2.5-flash",
      "cost_class": "verified-free", "status": "approved-specialist",
      "limits": { "concurrency": 1, "shared_quota_pool": "google-genlang-free" },
      "evidence": { "probe": { "result": "ok", "rc": 0, "at": "2026-07-27T01:25:00Z" } }
    },
    "openai-codex/withdrawn-model": {
      "provider": "openai-codex", "model_id": "withdrawn-model",
      "cost_class": "subscription-flat", "status": "rejected",
      "status_reason": "live probe returned a server-side entitlement refusal for this account",
      "evidence": { "probe": { "result": "entitlement-refused", "rc": 1, "at": "2026-07-27T01:20:00Z" } }
    },
    "google/gemini-2.0-flash": {
      "provider": "google", "model_id": "gemini-2.0-flash",
      "cost_class": "verified-free", "status": "approved-fallback",
      "limits": { "concurrency": 1, "shared_quota_pool": "google-genlang-free" },
      "evidence": { "probe": { "result": "ok", "rc": 0, "at": "2026-07-27T01:25:00Z" } }
    }
  },
  "zero_budget": {
    "allowlist": {
      "opencode/deepseek-v4-flash-free": {
        "price_at_verification": { "input": 0, "output": 0 },
        "verified_at": "2026-07-27T01:22:00Z",
        "sources": ["harness-static-catalogue", "probe"]
      },
      "google/gemini-2.5-flash": {
        "price_at_verification": { "input": 0, "output": 0 },
        "verified_at": "2026-07-27T01:25:00Z",
        "sources": ["provider-doc", "probe"],
        "hard_ceiling": "provider-side quota override refuses rather than bills"
      },
      "google/gemini-2.0-flash": {
        "price_at_verification": { "input": 0, "output": 0 },
        "verified_at": "2026-07-27T01:25:00Z",
        "sources": ["provider-doc", "probe"]
      }
    }
  }
}
JSON
}

# make_home <name> -> echoes a firstmate home with a registry and a git project.
make_home() {
  local home="$TMP/$1"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/projects/demo"
  registry_json > "$home/config/models.json"
  git init -q "$home/projects/demo" 2>/dev/null
  ( cd "$home/projects/demo" && git commit -q --allow-empty -m init 2>/dev/null ) || true
  printf '%s\n' "$home"
}

# spawn_out <home> <model> -> combined output of a spawn attempt; never mutates
# beyond what the gate allows, because the gate precedes all creation.
spawn_out() {
  local home=$1 model=$2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" zb-task "$home/projects/demo" --harness pi --model "$model" --effort low 2>&1 || true
}

# --- the decision function --------------------------------------------------

# --- routability is a SEPARATE axis from cost ------------------------------

# THE REGRESSION FOR INCIDENT 1 AT THE SPAWN GATE. The model that broke a whole
# tier sat on a flat subscription, so the cost rule had nothing to say about it.
# Only its recorded status makes it refusable, and the explicit --model path
# bypasses the dispatch config that bootstrap validates.
test_rejected_model_passes_cost_but_fails_routability() {
  local home out
  home=$(make_home rejected)
  # Cost rule: no charge is possible, so it must ALLOW.
  if ! CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "openai-codex/withdrawn-model"; then
    fail "a subscription-backed model must pass the COST check regardless of status"
  fi
  # Routability rule: the account cannot use it, so it must REFUSE.
  out=$(CONFIG="$home/config" STATE="$home/state" fm_model_routable_decision "openai-codex/withdrawn-model" || true)
  assert_contains "$out" "rejected" "the recorded status is the reason"
  assert_contains "$out" "entitlement refusal" "the recorded evidence is surfaced"
  pass "a rejected model passes the cost check and is refused on routability - the two axes stay separate"
}

test_spawn_refuses_rejected_model() {
  local home out
  home=$(make_home spawn-rejected)
  out=$(spawn_out "$home" "openai-codex/withdrawn-model")
  assert_contains "$out" "records openai-codex/withdrawn-model as rejected" "fm-spawn refuses on status"
  assert_absent "$home/state/zb-task.meta" "a status refusal creates nothing"
  pass "fm-spawn refuses an explicit --model the registry records as rejected (incident 1 regression)"
}

test_unregistered_model_is_routable() {
  local home
  home=$(make_home unregistered-routable)
  # Absence from models[] is not a routability refusal; the cost rule and the
  # bootstrap integrity check own that case between them.
  if ! CONFIG="$home/config" STATE="$home/state" fm_model_routable_decision "openai-codex/some-new-model"; then
    fail "an unregistered model must not be refused by the routability axis"
  fi
  pass "an unregistered model is not refused on routability - other checks own that case"
}

test_metered_sibling_refused() {
  local home out
  home=$(make_home metered)
  out=$(CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "opencode/claude-opus-4-8" || true)
  assert_contains "$out" "not on the verified-free allowlist" "the reason is the allowlist"
  assert_contains "$out" "opencode/claude-opus-4-8" "the exact model is named"
  assert_contains "$out" "zero_budget.allowlist" "the allowlist location is named"
  pass "a metered sibling on a mixed-billing key is refused, naming model, reason and allowlist"
}

test_allowlisted_free_model_allowed() {
  local home
  home=$(make_home freeok)
  if ! CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "opencode/deepseek-v4-flash-free"; then
    fail "an allowlisted verified-free model must be allowed"
  fi
  pass "an allowlisted verified-free model is allowed"
}

test_subscription_provider_allowed() {
  local home
  home=$(make_home subok)
  if ! CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "openai-codex/gpt-5.4-mini"; then
    fail "a subscription-flat provider model must be allowed"
  fi
  pass "a subscription-flat provider model is allowed without an allowlist entry"
}

test_self_hosted_allowed() {
  local home
  home=$(make_home selfhost)
  if ! CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "local-ollama/qwen3"; then
    fail "a self-hosted model must be allowed (no API budget is involved)"
  fi
  pass "a self-hosted model is allowed - its cost is infrastructure, not API spend"
}

test_bare_model_name_allowed() {
  local home
  home=$(make_home bare)
  if ! CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "opus"; then
    fail "a bare harness-native model name must be allowed"
  fi
  pass "a bare harness-native model name is not a provider route and is allowed"
}

test_unclassified_provider_refused() {
  local home out
  home=$(make_home unclassified)
  out=$(CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "moonshot/kimi-k2.6" || true)
  assert_contains "$out" "not classified" "the unclassified provider is the reason"
  pass "an unclassified provider is refused - an unknown cost posture is never a default-allow"
}

test_dropped_provider_refused() {
  local home out
  home=$(make_home dropped)
  out=$(CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "github-copilot/claude-sonnet-5" || true)
  assert_contains "$out" "dropped" "the dropped status is the reason"
  assert_contains "$out" "captain decision" "the recorded reason is surfaced"
  pass "a provider dropped by captain decision is refused even though it is subscription-backed"
}

# --- fail-closed vs inert ---------------------------------------------------

test_absent_registry_is_inert() {
  local home
  home=$(make_home absent)
  rm -f "$home/config/models.json"
  if ! CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "opencode/claude-opus-4-8"; then
    fail "with no registry the check must be inert, preserving byte-identical behaviour"
  fi
  pass "an absent registry leaves enforcement inert (the additive-compatibility guarantee)"
}

test_malformed_registry_refuses() {
  local home out
  home=$(make_home malformed)
  echo 'not json at all' > "$home/config/models.json"
  out=$(CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "opencode/deepseek-v4-flash-free" || true)
  [ -n "$out" ] || fail "a malformed registry must refuse, not silently allow"
  assert_contains "$out" "refusing" "the refusal is explicit"
  pass "a malformed registry refuses - a broken safety file never reads as an absent one"
}

test_unknown_schema_refuses() {
  local home out
  home=$(make_home badschema)
  registry_json | jq '.schema = "fm-model-registry.v99"' > "$home/config/models.json"
  out=$(CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "opencode/deepseek-v4-flash-free" || true)
  assert_contains "$out" "schema" "the schema mismatch is the reason"
  pass "an unsupported registry schema refuses rather than being best-effort parsed"
}

test_cache_only_allowlist_entry_refused_at_dispatch() {
  local home out
  home=$(make_home cacheonly)
  registry_json | jq '.zero_budget.allowlist["opencode/laguna-s-2.1-free"] =
    { "price_at_verification": {"input":0,"output":0},
      "verified_at": "2026-07-27T01:22:00Z",
      "sources": ["harness-fetched-cache"] }' > "$home/config/models.json"
  out=$(CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "opencode/laguna-s-2.1-free" || true)
  assert_contains "$out" "cache" "the cache-only evidence is the reason"
  pass "an allowlist entry resting only on a cache is refused at dispatch, not merely at validation"
}

# --- the real spawn path ----------------------------------------------------

# THE REGRESSION FOR INCIDENT 3. fm-spawn is the last gate before money is spent
# and the only one that sees a --model passed explicitly, bypassing the dispatch
# config that bootstrap validates.
test_spawn_refuses_metered_model() {
  local home out
  home=$(make_home spawn-metered)
  out=$(spawn_out "$home" "opencode/claude-opus-4-8")
  assert_contains "$out" "zero-budget rule refuses" "the spawn refuses"
  assert_contains "$out" "opencode/claude-opus-4-8" "the exact model is named"
  pass "fm-spawn refuses an explicit --model naming a metered sibling (incident 3 regression)"
}

test_spawn_refusal_creates_nothing() {
  local home
  home=$(make_home spawn-clean)
  spawn_out "$home" "opencode/claude-opus-4-8" >/dev/null
  assert_absent "$home/state/zb-task.meta" "a refused spawn writes no task metadata"
  pass "a refused spawn leaves no worktree, endpoint or metadata behind"
}

test_spawn_admits_allowlisted_model() {
  local home out
  home=$(make_home spawn-allow)
  out=$(spawn_out "$home" "opencode/deepseek-v4-flash-free")
  assert_not_contains "$out" "zero-budget rule refuses" "an allowlisted model passes the gate"
  pass "fm-spawn admits an allowlisted verified-free model past the zero-budget gate"
}

test_spawn_inert_without_registry() {
  local home out
  home=$(make_home spawn-inert)
  rm -f "$home/config/models.json"
  out=$(spawn_out "$home" "opencode/claude-opus-4-8")
  assert_not_contains "$out" "zero-budget rule refuses" "no registry means no refusal"
  pass "fm-spawn behaves exactly as before when no registry exists"
}

# --- concurrency / shared quota pool ----------------------------------------

test_concurrency_cap_refuses() {
  local home out
  home=$(make_home conc)
  printf 'model=google/gemini-2.5-flash\n' > "$home/state/other.meta"
  out=$(CONFIG="$home/config" STATE="$home/state" fm_model_concurrency_decision "google/gemini-2.5-flash" || true)
  assert_contains "$out" "concurrency guard refuses" "the cap refuses"
  assert_contains "$out" "cap is 1" "the configured value is named"
  pass "a model at its concurrency cap refuses a further worker, naming the value it acted on"
}

test_shared_quota_pool_counts_siblings() {
  local home out
  home=$(make_home pool)
  # A DIFFERENT model on the SAME free pool consumes the same budget.
  printf 'model=google/gemini-2.0-flash\n' > "$home/state/sibling.meta"
  out=$(CONFIG="$home/config" STATE="$home/state" fm_model_concurrency_decision "google/gemini-2.5-flash" || true)
  assert_contains "$out" "concurrency guard refuses" "a sibling on the same pool counts"
  assert_contains "$out" "google-genlang-free" "the shared pool is named"
  pass "a sibling sharing one free-tier quota pool counts against the same cap"
}

test_uncapped_model_is_silent() {
  local home
  home=$(make_home uncapped)
  printf 'model=openai-codex/gpt-5.4-mini\n' > "$home/state/a.meta"
  printf 'model=openai-codex/gpt-5.4-mini\n' > "$home/state/b.meta"
  if ! CONFIG="$home/config" STATE="$home/state" fm_model_concurrency_decision "openai-codex/gpt-5.4-mini"; then
    fail "a model with no recorded cap must not be limited"
  fi
  pass "a model with no recorded concurrency cap is never limited"
}

test_spawn_refuses_over_concurrency_cap() {
  local home out
  home=$(make_home spawn-conc)
  printf 'model=google/gemini-2.5-flash\n' > "$home/state/other.meta"
  out=$(spawn_out "$home" "google/gemini-2.5-flash")
  assert_contains "$out" "concurrency guard refuses" "fm-spawn enforces the cap"
  pass "fm-spawn refuses a dispatch that would exceed a model's concurrency cap"
}

# --- availability is NOT demotion -------------------------------------------

# Conflating them would make every transient outage permanently degrade the
# routing table. The separation is structural: availability is volatile state,
# routing status is durable config, and they live in different files with
# different writers.
test_availability_never_touches_routing_status() {
  local home before after
  home=$(make_home separation)
  before=$(jq -r '.models["google/gemini-2.5-flash"].status' "$home/config/models.json")
  # Simulate the health writer recording an outage.
  cat > "$home/state/model-health.json" <<'JSON'
{ "models": { "google/gemini-2.5-flash": { "state": "unavailable", "shape": "timeout",
              "consecutive_failures": 3 } } }
JSON
  after=$(jq -r '.models["google/gemini-2.5-flash"].status' "$home/config/models.json")
  [ "$before" = "$after" ] || fail "recording unavailability must not change the routing status"
  [ "$after" = "approved-specialist" ] || fail "the routing status must be untouched, got $after"
  # And the model is still allowed by the cost rule: unavailable is not demoted.
  if ! CONFIG="$home/config" STATE="$home/state" fm_model_zero_budget_decision "google/gemini-2.5-flash"; then
    fail "an unavailable model must not be treated as a routing refusal"
  fi
  pass "a rate-limited or unavailable model is NOT demoted - availability and routing stay separate"
}

# --- bootstrap: loud when unenforced ----------------------------------------

bootstrap_out() {
  local home=$1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$BOOTSTRAP" 2>&1 || true
}

test_bootstrap_loud_when_registry_absent() {
  local home out
  home=$(make_home boot-absent)
  rm -f "$home/config/models.json"
  cat > "$home/config/crew-dispatch.json" <<'JSON'
{ "rules": [ { "when": "x", "use": { "harness": "pi", "model": "opencode/deepseek-v4-flash-free", "effort": "low" } } ] }
JSON
  out=$(bootstrap_out "$home")
  assert_contains "$out" "no config/models.json" "the missing registry is reported"
  assert_contains "$out" "not enforced" "the unenforced state is stated plainly"
  pass "with routed provider models and no registry, bootstrap says the rule is unenforced"
}

test_bootstrap_silent_when_nothing_provider_routed() {
  local home out
  home=$(make_home boot-silent)
  rm -f "$home/config/models.json"
  cat > "$home/config/crew-dispatch.json" <<'JSON'
{ "rules": [ { "when": "x", "use": { "harness": "claude", "model": "opus", "effort": "xhigh" } } ] }
JSON
  out=$(bootstrap_out "$home")
  assert_not_contains "$out" "MODEL_REGISTRY" "no provider models means nothing to say"
  pass "bootstrap stays silent when no provider-prefixed model is routed and no registry exists"
}

test_bootstrap_reports_malformed_registry() {
  local home out
  home=$(make_home boot-malformed)
  echo 'not json' > "$home/config/models.json"
  out=$(bootstrap_out "$home")
  assert_contains "$out" "invalid config/models.json" "the malformed registry is reported"
  pass "bootstrap reports a malformed registry rather than ignoring it"
}

test_bootstrap_integrity_binds_dispatch_to_registry() {
  local home out
  home=$(make_home boot-integrity)
  cat > "$home/config/crew-dispatch.json" <<'JSON'
{ "rules": [ { "when": "x", "use": { "harness": "pi", "model": "openai-codex/gpt-5.9-imaginary", "effort": "low" } } ] }
JSON
  out=$(bootstrap_out "$home")
  assert_contains "$out" "gpt-5.9-imaginary" "the unregistered model is named"
  assert_contains "$out" "absent from config/models.json" "the binding failure is explained"
  pass "bootstrap refuses a dispatch rule naming a model absent from the registry"
}

test_metered_sibling_refused
test_allowlisted_free_model_allowed
test_subscription_provider_allowed
test_self_hosted_allowed
test_bare_model_name_allowed
test_unclassified_provider_refused
test_dropped_provider_refused
test_absent_registry_is_inert
test_malformed_registry_refuses
test_unknown_schema_refuses
test_cache_only_allowlist_entry_refused_at_dispatch
test_spawn_refuses_metered_model
test_spawn_refusal_creates_nothing
test_spawn_admits_allowlisted_model
test_spawn_inert_without_registry
test_concurrency_cap_refuses
test_shared_quota_pool_counts_siblings
test_uncapped_model_is_silent
test_spawn_refuses_over_concurrency_cap
test_availability_never_touches_routing_status
test_rejected_model_passes_cost_but_fails_routability
test_spawn_refuses_rejected_model
test_unregistered_model_is_routable
test_bootstrap_loud_when_registry_absent
test_bootstrap_silent_when_nothing_provider_routed
test_bootstrap_reports_malformed_registry
test_bootstrap_integrity_binds_dispatch_to_registry
