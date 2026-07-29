#!/usr/bin/env bash
# fm-model-registry-lib.sh - single owner of config/models.json parsing, schema
# validation, and the zero-budget routing decision.
#
# WHY THIS EXISTS. The fleet's zero-budget rule ("the budget for every API-key
# provider is ZERO ... this is a safety rule, not a preference") lived only as
# prose inside a JSON comment blob in config/crew-dispatch.json. Nothing read it.
# One API key can reach both free and metered models on the same provider, so a
# single mistyped or well-meant model name was a charge, and the fleet had already
# demonstrated once that it will route from a plausible name without checking.
# This library is the enforced copy of that rule; the prose is descriptive.
#
# It is sourced by bin/fm-spawn.sh (the last gate before a dispatch spends money,
# and the only one that sees an explicit --model that bypassed the dispatch config)
# and by bin/fm-bootstrap.sh (which catches a bad model at config-edit time,
# before any dispatch at all).
#
# docs/configuration.md "Model registry (config/models.json)" owns the schema.
# .agents/skills/model-onboarding/SKILL.md owns the admission policy this
# enforces. This header owns the mechanics.
#
# ENFORCEMENT SCOPE - the deliberate asymmetry, ruled 2026-07-28:
#
#   Registry ABSENT  -> enforcement inert, and bootstrap says so out loud whenever
#                       the dispatch config names a provider-prefixed model. This
#                       keeps the change purely additive: a home with no registry
#                       behaves byte-identically to one built before this existed.
#                       Unenforced is never SILENT, but it is not a refusal.
#   Registry PRESENT -> fail closed everywhere. Malformed JSON, an unknown schema
#                       version, an unclassified provider, a missing jq, or a
#                       stale-evidence allowlist entry all REFUSE. A broken safety
#                       file must never read as an absent one.
#
# The unit of authorization is the MODEL, never the provider and never the
# credential: one key reaching both free and paid models means "this provider is
# fine" is not a safe answer to any question.

# Idempotent guard: fm-spawn.sh and fm-bootstrap.sh may both be in one process
# tree, and a re-source must not redefine constants under set -u.
if [ -n "${FM_MODEL_REGISTRY_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_MODEL_REGISTRY_LIB_SOURCED=1

# The only schema this build understands. A registry carrying anything else is
# refused rather than best-effort parsed: a future format change must fail loudly
# instead of being silently misread by an old binary.
FM_MODEL_SCHEMA_VERSION='fm-model-registry.v1'

# Evidence source kinds, in the descending authority order the policy defines.
# The freshness rule turns on this ordering: harness-fetched-cache is a cache the
# provider rewrites underneath you, so it may never be the SOLE evidence for a
# cost class or an entitlement. Anything weaker than it (third-party, inference)
# is likewise insufficient alone.
# Listed in descending authority; that ordering is the policy's, and the two
# weakest kinds are anecdote rather than evidence.
FM_MODEL_SOURCE_KINDS='probe provider-entitlement provider-doc harness-static-catalogue harness-fetched-cache third-party inference'

# Price evidence is a NARROWER set than entitlement evidence, and conflating them
# is a real hole rather than a nicety: a successful probe proves the account gets
# an answer, and says nothing whatsoever about what that answer costs. Only a
# source that actually carries a price can establish one. This is what excludes an
# allowlist entry whose price is known solely from a cache the provider rewrites -
# the case where a repricing would land silently and the allowlist would not notice.
FM_MODEL_SOURCE_PRICE_AUTHORITATIVE='provider-doc harness-static-catalogue'

# ---------------------------------------------------------------------------
# Location and presence
# ---------------------------------------------------------------------------

# Echo the registry path for the active home. CONFIG is exported by the callers;
# fall back to the standard layout so the library is usable standalone in tests.
fm_model_registry_path() {
  local cfg
  cfg="${CONFIG:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-.}/config}}"
  printf '%s\n' "$cfg/models.json"
}

fm_model_registry_present() {
  [ -f "$(fm_model_registry_path)" ]
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

# Echo the provider half of a "provider/model" name, or nothing for a bare name.
# A bare name (opus, haiku) is a harness-native model selector: no provider
# credential is involved, so the zero-budget rule has nothing to say about it.
fm_model_provider_of() {
  case "${1:-}" in
    */*) printf '%s\n' "${1%%/*}" ;;
    *)   printf '%s\n' '' ;;
  esac
}

# ---------------------------------------------------------------------------
# Schema validation
# ---------------------------------------------------------------------------

# fm_model_registry_validate <file>
# Echo one human-readable reason and return 1 when the registry is invalid;
# print nothing and return 0 when it is well formed.
#
# The promotion-authority checks encode the captain-delegated ruling of
# 2026-07-28 as a CEILING in each direction: a registry may be equally or more
# conservative than the ruling, never more permissive. The Tier 1 / Tier 0 rows
# are the hard ceiling - no accumulation of evidence may enter those tiers, because
# Tier 1 is triggered by risk rather than capability rank, and a model with a
# spotless record at Tier 2 has demonstrated nothing whatsoever about credential
# handling or destructive-operation judgment.
fm_model_registry_validate() {
  local file=$1 err
  [ -f "$file" ] || { echo "registry file not found: $file"; return 1; }
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to validate the model registry"
    return 1
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "malformed JSON"
    return 1
  fi
  err=$(jq -r \
    --arg schema "$FM_MODEL_SCHEMA_VERSION" \
    --arg kinds "$FM_MODEL_SOURCE_KINDS" \
    --arg pricestrong "$FM_MODEL_SOURCE_PRICE_AUTHORITATIVE" \
    '
    def kinds: ($kinds | split(" "));
    def pricestrong: ($pricestrong | split(" "));
    # The freshness rule, applied to PRICE: at least one source that actually
    # carries a price. A probe is deliberately NOT enough - it proves the account
    # gets an answer, not what that answer costs. A cache-only price is exactly how
    # allowlist names once came to exist that no shipped catalogue could confirm.
    def fresh($s): (($s // []) | any(. as $k | pricestrong | index($k)));
    def bad_kinds($s): (($s // []) | map(select(. as $k | kinds | index($k) | not)));
    def accessclasses: ["A","B","C","D"];
    def postures: ["subscription-flat","api-key","self-hosted"];
    def provstatuses: ["active","blocked","dropped"];
    def costclasses: ["subscription-flat","verified-free","metered","unknown"];
    def modelstatuses: ["rejected","blocked","experimental","approved-fallback","approved-specialist","approved-primary"];
    def obslevels: ["O1","O2","O3","O4"];
    def entries($o): (($o // {}) | to_entries);

    if type != "object" then "top-level value must be an object"
    elif (.schema? // null) == null then "missing schema; expected \"" + $schema + "\""
    elif .schema != $schema then "unsupported schema \"" + (.schema | tostring) + "\"; this build understands \"" + $schema + "\""

    # --- providers ---------------------------------------------------------
    elif has("providers") and (.providers | type) != "object" then "providers must be an object"
    elif (entries(.providers) | map(select((.value | type) != "object")) | length) > 0 then
      "provider entries must be objects: " + (entries(.providers) | map(select((.value | type) != "object")) | map(.key) | join(", "))
    elif (entries(.providers) | map(select((.value.access_class? // null) as $a | ($a == null) or (accessclasses | index($a) | not))) | length) > 0 then
      "provider needs access_class one of A, B, C, D: " + (entries(.providers) | map(select((.value.access_class? // null) as $a | ($a == null) or (accessclasses | index($a) | not))) | map(.key) | join(", "))
    elif (entries(.providers) | map(select((.value.cost_posture? // null) as $p | ($p == null) or (postures | index($p) | not))) | length) > 0 then
      "provider needs cost_posture one of subscription-flat, api-key, self-hosted: " + (entries(.providers) | map(select((.value.cost_posture? // null) as $p | ($p == null) or (postures | index($p) | not))) | map(.key) | join(", "))
    elif (entries(.providers) | map(select(has("status") and ((.value.status) as $s | provstatuses | index($s) | not))) | length) > 0 then
      "provider status must be one of active, blocked, dropped: " + (entries(.providers) | map(select(has("status") and ((.value.status) as $s | provstatuses | index($s) | not))) | map(.key) | join(", "))
    elif (entries(.providers) | map(select((.value.status? // "active") != "active" and (((.value.status_reason? // "") | length) == 0))) | length) > 0 then
      "a blocked or dropped provider needs status_reason: " + (entries(.providers) | map(select((.value.status? // "active") != "active" and (((.value.status_reason? // "") | length) == 0))) | map(.key) | join(", "))

    # --- models ------------------------------------------------------------
    elif has("models") and (.models | type) != "object" then "models must be an object"
    elif (entries(.models) | map(select((.value | type) != "object")) | length) > 0 then
      "model entries must be objects: " + (entries(.models) | map(select((.value | type) != "object")) | map(.key) | join(", "))
    elif (entries(.models) | map(select((.value.cost_class? // null) as $c | ($c == null) or (costclasses | index($c) | not))) | length) > 0 then
      "model needs cost_class one of subscription-flat, verified-free, metered, unknown: " + (entries(.models) | map(select((.value.cost_class? // null) as $c | ($c == null) or (costclasses | index($c) | not))) | map(.key) | join(", "))
    elif (entries(.models) | map(select((.value.status? // null) as $s | ($s == null) or (modelstatuses | index($s) | not))) | length) > 0 then
      "model needs a known status: " + (entries(.models) | map(select((.value.status? // null) as $s | ($s == null) or (modelstatuses | index($s) | not))) | map(.key) | join(", "))
    elif (entries(.models) | map(select((.value.status? // "") as $s | (($s == "rejected") or ($s == "blocked")) and (((.value.status_reason? // "") | length) == 0))) | length) > 0 then
      "a rejected or blocked model needs status_reason so the refusal is not rediscovered: " + (entries(.models) | map(select((.value.status? // "") as $s | (($s == "rejected") or ($s == "blocked")) and (((.value.status_reason? // "") | length) == 0))) | map(.key) | join(", "))
    elif (entries(.models) | map(select(has("observation_level") and ((.value.observation_level) as $o | obslevels | index($o) | not))) | length) > 0 then
      "observation_level must be one of O1, O2, O3, O4: " + (entries(.models) | map(select(has("observation_level") and ((.value.observation_level) as $o | obslevels | index($o) | not))) | map(.key) | join(", "))
    elif (entries(.models) | map(select((.value.evidence?.price?.sources? // null) != null and ((bad_kinds(.value.evidence.price.sources) | length) > 0))) | length) > 0 then
      "unknown evidence source kind in: " + (entries(.models) | map(select((.value.evidence?.price?.sources? // null) != null and ((bad_kinds(.value.evidence.price.sources) | length) > 0))) | map(.key) | join(", "))

    # --- zero_budget allowlist --------------------------------------------
    elif has("zero_budget") and (.zero_budget | type) != "object" then "zero_budget must be an object"
    elif (.zero_budget?.allowlist? // null) != null and (.zero_budget.allowlist | type) != "object" then "zero_budget.allowlist must be an object"
    elif (entries(.zero_budget?.allowlist) | map(select((.value | type) != "object")) | length) > 0 then
      "allowlist entries must be objects: " + (entries(.zero_budget?.allowlist) | map(select((.value | type) != "object")) | map(.key) | join(", "))
    elif (entries(.zero_budget?.allowlist) | map(select((.value.sources? | type) != "array")) | length) > 0 then
      "allowlist entry needs a sources array: " + (entries(.zero_budget?.allowlist) | map(select((.value.sources? | type) != "array")) | map(.key) | join(", "))
    elif (entries(.zero_budget?.allowlist) | map(select((bad_kinds(.value.sources) | length) > 0)) | length) > 0 then
      "unknown evidence source kind in allowlist: " + (entries(.zero_budget?.allowlist) | map(select((bad_kinds(.value.sources) | length) > 0)) | map(.key) | join(", "))
    elif (entries(.zero_budget?.allowlist) | map(select(fresh(.value.sources) | not)) | length) > 0 then
      "allowlist entry has no price evidence beyond a provider-rewritten cache (a probe proves entitlement, not price): " + (entries(.zero_budget?.allowlist) | map(select(fresh(.value.sources) | not)) | map(.key) | join(", "))
    elif (entries(.zero_budget?.allowlist) | map(select(((.value.verified_at? // "") | length) == 0)) | length) > 0 then
      "allowlist entry needs verified_at: " + (entries(.zero_budget?.allowlist) | map(select(((.value.verified_at? // "") | length) == 0)) | map(.key) | join(", "))
    elif (entries(.zero_budget?.allowlist) | map(select((.value.price_at_verification? | type) != "object")) | length) > 0 then
      "allowlist entry needs price_at_verification: " + (entries(.zero_budget?.allowlist) | map(select((.value.price_at_verification? | type) != "object")) | map(.key) | join(", "))
    elif (entries(.zero_budget?.allowlist) | map(select([.value.price_at_verification[]?] | any(. != 0))) | length) > 0 then
      "allowlist entry is not priced at zero: " + (entries(.zero_budget?.allowlist) | map(select([.value.price_at_verification[]?] | any(. != 0))) | map(.key) | join(", "))

    # --- promotion authority ceiling --------------------------------------
    elif has("promotion") and (.promotion | type) != "object" then "promotion must be an object"
    elif (.promotion?.authority? // null) != null and (.promotion.authority | type) != "object" then "promotion.authority must be an object"
    elif ((.promotion?.authority?.t1_to_t0? // "never-by-evidence") != "never-by-evidence") then
      "promotion.authority.t1_to_t0 must be never-by-evidence: Tier 0 is never entered by accumulated evidence"
    elif ((.promotion?.authority?.t2_to_t1? // "never-by-evidence") != "never-by-evidence") then
      "promotion.authority.t2_to_t1 must be never-by-evidence: Tier 1 is triggered by risk, not capability rank"
    elif ((.promotion?.authority?.t3_to_t2? // "captain-confirm") as $a | ["captain-confirm","never-by-evidence"] | index($a) | not) then
      "promotion.authority.t3_to_t2 must be captain-confirm or never-by-evidence"
    elif ((.promotion?.authority?.t4_to_t3? // "automatic-notify-immediate") as $a | ["automatic-notify-immediate","captain-confirm","never-by-evidence"] | index($a) | not) then
      "promotion.authority.t4_to_t3 must be automatic-notify-immediate, captain-confirm, or never-by-evidence"
    elif (.promotion?.enabled? // false) == true and (((.promotion?.requires_instrument? // "") | length) == 0) then
      "promotion.enabled needs requires_instrument naming the evidence instrument"
    else empty
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    printf '%s\n' "$err"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The zero-budget decision
# ---------------------------------------------------------------------------

# fm_model_zero_budget_decision <model>
# Return 0 to allow the dispatch; return 1 and echo one actionable reason to
# refuse it. The reason names the exact model, why it was refused, and where the
# allowlist lives - a refusal a supervisor cannot act on is worse than none.
fm_model_zero_budget_decision() {
  local model=${1:-} reg provider verdict
  # No model selected: the harness picks its own default on a subscription
  # credential. Nothing here to authorize.
  [ -n "$model" ] && [ "$model" != default ] || return 0

  provider=$(fm_model_provider_of "$model")
  # A bare model name is a harness-native selector (claude's "opus"), not a
  # provider-credentialed route.
  [ -n "$provider" ] || return 0

  reg=$(fm_model_registry_path)
  # Ruled 2026-07-28: an absent registry leaves enforcement inert so the change
  # stays purely additive for homes that never opted in. Bootstrap is what makes
  # that state loud rather than silent.
  [ -f "$reg" ] || return 0

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to check $model against the zero-budget allowlist in $reg, and is not installed; refusing rather than dispatching an unchecked model"
    return 1
  fi

  verdict=$(jq -r \
    --arg model "$model" \
    --arg provider "$provider" \
    --arg schema "$FM_MODEL_SCHEMA_VERSION" \
    --arg pricestrong "$FM_MODEL_SOURCE_PRICE_AUTHORITATIVE" \
    '
    def pricestrong: ($pricestrong | split(" "));
    def fresh($s): (($s // []) | any(. as $k | pricestrong | index($k)));
    if type != "object" or (.schema? // "") != $schema then
      "refuse\tregistry schema is missing or unsupported"
    else
      (.providers[$provider]? // null) as $p
      | if $p == null then
          "refuse\tprovider \"" + $provider + "\" is not classified in the registry, so its cost posture is unknown"
        elif ($p.status? // "active") != "active" then
          "refuse\tprovider \"" + $provider + "\" is " + ($p.status | tostring) + ": " + ($p.status_reason? // "no reason recorded")
        elif ($p.cost_posture? // "") == "subscription-flat" then "allow"
        elif ($p.cost_posture? // "") == "self-hosted" then "allow"
        else
          (.zero_budget?.allowlist[$model]? // null) as $a
          | if $a == null then
              "refuse\t" + $provider + " is an API-key provider and \"" + $model + "\" is not on the verified-free allowlist"
            elif (fresh($a.sources) | not) then
              "refuse\tallowlist entry for \"" + $model + "\" has a price known only from a provider-rewritten cache, which cannot establish one"
            elif ([$a.price_at_verification[]?] | any(. != 0)) then
              "refuse\tallowlist entry for \"" + $model + "\" records a non-zero price"
            else "allow"
            end
        end
    end
  ' "$reg" 2>/dev/null || true)

  # A malformed registry yields no verdict. A broken safety file must not read as
  # an absent one, so an unparseable answer refuses.
  if [ -z "$verdict" ]; then
    echo "the model registry $reg could not be read; refusing $model rather than dispatching an unchecked model"
    return 1
  fi
  case "$verdict" in
    allow) return 0 ;;
    refuse*)
      printf 'zero-budget rule refuses %s: %s (allowlist: %s -> zero_budget.allowlist)\n' \
        "$model" "${verdict#refuse$'\t'}" "$reg"
      return 1
      ;;
    *)
      printf 'zero-budget check for %s produced no usable verdict from %s; refusing\n' "$model" "$reg"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Routability
# ---------------------------------------------------------------------------

# fm_model_routable_decision <model>
# Refuse a model the registry records as rejected or blocked. Return 0 otherwise.
#
# This is a SEPARATE axis from the zero-budget decision and must not be folded
# into it. A model can be perfectly free of cost risk and still be unroutable: the
# model that broke an entire tier was on a flat subscription, so the cost rule had
# nothing to say about it, and only its recorded entitlement refusal makes it
# refusable. Bootstrap catches such a model when a dispatch RULE names it, but the
# explicit --model path bypasses the dispatch config entirely - which is the whole
# reason enforcement lives at spawn too.
#
# Availability is deliberately NOT consulted here. A rate-limited or cooling-down
# model is unavailable, not rejected, and that lives in state/model-health.json on
# its own axis; conflating them would let a transient outage read as a permanent
# routing refusal.
fm_model_routable_decision() {
  local model=${1:-} reg verdict
  [ -n "$model" ] && [ "$model" != default ] || return 0
  [ -n "$(fm_model_provider_of "$model")" ] || return 0
  reg=$(fm_model_registry_path)
  [ -f "$reg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  verdict=$(jq -r --arg m "$model" --arg schema "$FM_MODEL_SCHEMA_VERSION" '
    if type != "object" or (.schema? // "") != $schema then empty
    else
      (.models[$m]? // null) as $e
      | if $e == null then "allow"
        elif (($e.status? // "") == "rejected") or (($e.status? // "") == "blocked") then
          "refuse\t" + ($e.status | tostring) + ": " + ($e.status_reason? // "no reason recorded")
        else "allow"
        end
    end
  ' "$reg" 2>/dev/null || true)

  case "$verdict" in
    allow|'') return 0 ;;
    refuse*)
      printf 'the model registry records %s as %s (registry: %s)\n' \
        "$model" "${verdict#refuse$'\t'}" "$reg"
      return 1
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Concurrency / shared quota pool guard
# ---------------------------------------------------------------------------

# fm_model_concurrency_decision <model> [state-dir]
# Refuse when launching one more worker on this model would exceed the cap the
# registry records for it, or for the quota pool it shares with siblings.
#
# Counts tasks by their recorded state/<id>.meta, which is exactly the set
# teardown has not yet cleaned. That over-counts a dead-but-not-torn-down task,
# which errs toward refusing - the correct direction for a guard whose whole job
# is keeping several workers from collectively breaching one free-tier pool.
fm_model_concurrency_decision() {
  local model=${1:-} statedir=${2:-} reg cap pool live meta m pool_of
  [ -n "$model" ] && [ "$model" != default ] || return 0
  reg=$(fm_model_registry_path)
  [ -f "$reg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  statedir=${statedir:-${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}}}

  cap=$(jq -r --arg m "$model" '.models[$m]?.limits?.concurrency? // empty' "$reg" 2>/dev/null || true)
  case "$cap" in
    ''|null) return 0 ;;
    *[!0-9]*) return 0 ;;
  esac
  [ "$cap" -gt 0 ] 2>/dev/null || return 0

  pool=$(jq -r --arg m "$model" '.models[$m]?.limits?.shared_quota_pool? // empty' "$reg" 2>/dev/null || true)

  live=0
  for meta in "$statedir"/*.meta; do
    [ -f "$meta" ] || continue
    m=$(sed -n 's/^model=//p' "$meta" | tail -1)
    [ -n "$m" ] && [ "$m" != default ] || continue
    if [ "$m" = "$model" ]; then
      live=$((live + 1))
      continue
    fi
    # A sibling on the same pool consumes the same free-tier budget, so it counts
    # against the same cap.
    [ -n "$pool" ] || continue
    pool_of=$(jq -r --arg m "$m" '.models[$m]?.limits?.shared_quota_pool? // empty' "$reg" 2>/dev/null || true)
    [ "$pool_of" = "$pool" ] && live=$((live + 1))
  done

  if [ "$live" -ge "$cap" ]; then
    printf 'concurrency guard refuses %s: %d active worker(s) already on %s, cap is %d (registry: %s -> models."%s".limits.concurrency)\n' \
      "$model" "$live" "${pool:-this model}" "$cap" "$reg" "$model"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Referential integrity: crew-dispatch.json x models.json
# ---------------------------------------------------------------------------

# fm_model_registry_integrity <dispatch-file> <registry-file> [now-epoch]
# Echo one line per problem; return 1 when any were found. This is the check that
# catches a bad model at CONFIG-EDIT time rather than at dispatch time: adding a
# rule that names a model with no probe record fails here, before a worker is ever
# launched against it.
fm_model_registry_integrity() {
  local dispatch=$1 reg=$2 now=${3:-} out
  [ -f "$dispatch" ] || return 0
  [ -f "$reg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  now=${now:-$(date -u +%s)}
  out=$(jq -r -n \
    --slurpfile d "$dispatch" \
    --slurpfile r "$reg" \
    --argjson now "$now" \
    '
    def profiles($v):
      if ($v | type) == "array" then $v
      elif ($v | type) == "object" then [$v]
      else [] end;
    def named:
      ($d[0] // {}) as $cfg
      | ([ (($cfg.rules // [])[]? | profiles(.use?)[]?)
           , (profiles($cfg.default // null)[]?) ]
         | map(.model? // empty)
         | map(select(type == "string" and (. != "default") and (test("/"))))
         | unique);
    def approved: ["approved-primary","approved-fallback","approved-specialist"];
    def secs($iso):
      ($iso // "") as $t
      | if ($t | length) == 0 then null
        else (try ($t | sub("Z$"; "+0000") | strptime("%Y-%m-%dT%H:%M:%S%z") | mktime)
              catch (try ($t | sub("Z$"; "") | sub("\\.[0-9]+$"; "") | strptime("%Y-%m-%dT%H:%M") | mktime) catch null))
        end;
    ($r[0] // {}) as $reg
    | named
    | map(. as $m
        | ($reg.models[$m]? // null) as $e
        | if $e == null then
            "MODEL_REGISTRY: " + $m + " is named in config/crew-dispatch.json but absent from config/models.json"
          elif (approved | index($e.status? // "") | not) then
            "MODEL_REGISTRY: " + $m + " is routed but its registry status is " + ($e.status? // "unset")
              + (if ($e.status_reason? // "") != "" then " (" + $e.status_reason + ")" else "" end)
          elif (($e.evidence?.probe?.at? // "") | length) == 0 then
            "MODEL_REGISTRY: " + $m + " is routed with no live-probe record; every routed model must be probe-verified"
          else
            (secs($e.evidence.probe.at)) as $at
            | (($reg.observation?.levels?[($e.observation_level? // "O4")]?.probe_max_age_days?) // null) as $maxd
            | if $at == null then
                "MODEL_REGISTRY: " + $m + " has an unparseable probe timestamp \"" + ($e.evidence.probe.at | tostring) + "\""
              elif $maxd != null and (($now - $at) > ($maxd * 86400)) then
                "MODEL_REGISTRY: " + $m + " probe evidence is " + ((($now - $at) / 86400) | floor | tostring)
                  + "d old, past the " + ($maxd | tostring) + "d limit for " + ($e.observation_level? // "O4")
              else empty
              end
          end)
    | .[]
  ' 2>/dev/null || true)
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Price drift
# ---------------------------------------------------------------------------

# fm_model_price_drift <registry-file>
# Echo one line per drifted model; return 1 when any drifted. Free, local file
# reads only - no network, no probe, no tokens.
#
# This is the only check that can catch a repricing, because a NAME-based
# allowlist is structurally blind to it: the thing that makes a name safe is its
# price, and the price lives in a catalogue the provider rewrites underneath you.
# Comparing two numbers is what makes drift detectable at all.
fm_model_price_drift() {
  local reg=$1 out
  [ -f "$reg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # jq cannot open the catalogue files itself, so the comparison is driven from
  # the shell: read each declared catalogue once, then diff it against the stored
  # prices for that provider's models.
  out=$(fm_model_price_drift_scan "$reg")
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 1
  fi
  return 0
}

# Internal: the actual drift scan. Split out so fm_model_price_drift keeps a
# single simple contract and this part stays testable on its own.
fm_model_price_drift_scan() {
  local reg=$1 prov src found
  command -v jq >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r prov src; do
    [ -n "$prov" ] && [ -n "$src" ] || continue
    # A declared catalogue that is not readable is reported, not silently skipped:
    # a drift check that quietly stops running is indistinguishable from one that
    # keeps passing.
    if [ ! -f "$src" ]; then
      printf 'MODEL_PRICE: %s catalogue source is unreadable: %s\n' "$prov" "$src"
      continue
    fi
    found=$(jq -r -n \
      --slurpfile reg "$reg" \
      --slurpfile cat "$src" \
      --arg prov "$prov" \
      '
      def costmap:
        (($cat[0] // {})) as $c
        | if ($c | type) != "object" then {}
          elif ($c[$prov]?.models? | type) == "array" then
            ($c[$prov].models | map(select(type == "object")) | map({key: (.id | tostring), value: (.cost // {})}) | from_entries)
          else
            ($c | to_entries | map(select((.value | type) == "object"))
              | map({key: ((.value.id // .key) | tostring), value: (.value.cost // {})}) | from_entries)
          end;
      costmap as $cm
      | ($reg[0] // {}) as $r
      | [ ($r.models // {}) | to_entries[]
          | select((.value.provider? // (.key | split("/")[0])) == $prov)
          | .key as $k | .value as $e
          | ($e.model_id? // ($k | split("/") | .[1:] | join("/"))) as $id
          | ($cm[$id]? // null) as $now
          | select($now != null)
          | ( # An allowlisted zero-priced model that is no longer free is the
              # repricing case, and it is critical: the route must suspend.
              if (($r.zero_budget?.allowlist[$k]? // null) != null) and ([$now[]?] | any(. != 0)) then
                "MODEL_PRICE: " + $k + " is on the zero-budget allowlist but its catalogue price is no longer zero (" + ($now | tostring) + "); suspend this route"
              elif ($e.price_at_verification? != null)
                   and (($e.price_at_verification.input? // 0) != ($now.input? // 0)
                        or ($e.price_at_verification.output? // 0) != ($now.output? // 0)) then
                "MODEL_PRICE: " + $k + " price drifted from " + ($e.price_at_verification | tostring) + " to " + ($now | tostring)
              else empty
              end )
        ]
      | .[]
      ' 2>/dev/null || true)
    [ -z "$found" ] || printf '%s\n' "$found"
  done <<EOF
$(jq -r '(.providers // {}) | to_entries[] | .key as $p | (.value.catalogue_sources // [])[] | "\($p)\t\(.)"' "$reg" 2>/dev/null || true)
EOF
  return 0
}

# ---------------------------------------------------------------------------
# Probe classification
# ---------------------------------------------------------------------------

# fm_model_probe_classify <rc> <combined-output>
# Echo one token for the four measured response shapes. The classifier matters
# because a local configuration typo and a server-side entitlement refusal are
# different facts with different handlers: one is a config error, the other means
# the account will never be served that model.
fm_model_probe_classify() {
  local rc=${1:-1} out=${2:-}
  if [ "$rc" = 0 ]; then
    printf 'ok\n'
    return 0
  fi
  case "$out" in
    *'is not supported when using'*)     printf 'entitlement-refused\n'; return 0 ;;
    *'not found for provider'*)          printf 'unknown-model\n'; return 0 ;;
    *'Using custom model id'*)           printf 'unknown-model\n'; return 0 ;;
    *'Unknown provider'*)                printf 'client-error\n'; return 0 ;;
  esac
  printf 'unclassified\n'
}

# ---------------------------------------------------------------------------
# Promotion dormancy
# ---------------------------------------------------------------------------

# fm_model_promotion_state [registry-file]
# Echo "active" or "dormant\t<the specific unmet condition>". Activation is a
# config and data condition, never a code change: write the instrument, flip the
# flag. Naming WHICH condition is unmet is the point - a dormant trigger nobody
# can check is indistinguishable from a rejected one.
fm_model_promotion_state() {
  local reg=${1:-} enabled instrument ledger
  reg=${reg:-$(fm_model_registry_path)}
  [ -f "$reg" ] || { printf 'dormant\tno model registry at %s\n' "$reg"; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'dormant\tjq is not installed\n'; return 0; }

  enabled=$(jq -r '.promotion?.enabled? // false' "$reg" 2>/dev/null || echo false)
  instrument=$(jq -r '.promotion?.requires_instrument? // empty' "$reg" 2>/dev/null || true)

  if [ "$enabled" != true ]; then
    printf 'dormant\tpromotion.enabled is false in %s\n' "$reg"
    return 0
  fi
  if [ -z "$instrument" ]; then
    printf 'dormant\tpromotion.requires_instrument is unset\n'
    return 0
  fi
  # The data half: the named evidence instrument must actually exist and be
  # producing terminal task lines. Until it does, P1/P2/P3 are not merely unmet -
  # they are not COMPUTABLE, and reporting them as unmet would be a false negative.
  ledger="${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}}/wake-outcome-ledger.jsonl"
  if [ ! -s "$ledger" ]; then
    printf 'dormant\tevidence instrument "%s" has produced no records yet (%s)\n' "$instrument" "$ledger"
    return 0
  fi
  if ! grep -q '"kind"[[:space:]]*:[[:space:]]*"task-terminal"' "$ledger" 2>/dev/null; then
    printf 'dormant\tevidence instrument "%s" exists but records no task-terminal lines yet\n' "$instrument"
    return 0
  fi
  printf 'active\n'
}
