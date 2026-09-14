#!/usr/bin/env bash
# Generic candidate-availability layer shared by fm-quota-choose.sh (worker-side
# selection) and fm-spawn.sh (final pre-launch gate).
#
# Usage: . bin/fm-candidate-availability-lib.sh
#        fm_candidate_availability <quota-json-or-empty> <harness> <model>
#
# fm_candidate_availability prints one JSON object describing whether a single
# <harness>:<model> candidate currently has usable headroom, and returns 0.
# The object always has this shape:
#   {"harness":"...", "model":"...", "provider":"..."|null,
#    "source":"quota-axi"|"copilot"|"local"|"none",
#    "status":"known"|"unknown"|"not_applicable", "eligible":true|false}
#
# quota-axi is the authoritative source for every provider it models with
# known or partial semantics. A provider-specific adapter (currently only
# Copilot's bin/fm-copilot-quota-lib.sh) is consulted only as a fallback
# producer, for a provider quota-axi does not model with authoritative data
# (Copilot's quotaSemantics.status is always "unknown" from quota-axi; see
# docs/verification/dispatch-auth.md). A local model carries no paid-quota
# policy at all: it is always "not_applicable"/eligible, and quota-axi is
# never consulted for it. This is a data-only layer: it never selects a
# route, never ranks candidates, and never recommends one harness over
# another. AGENTS.md section 4 and the quota-array-dispatch skill remain the
# authoritative source of the reasoning-class and runway-feasibility gates
# this layer does not replace.
#
# Provider identity comes from the same authoritative harness mapping
# fm-quota-choose.sh has always used (fm_candidate_provider_for_harness,
# below), never from guessing a family out of an arbitrary model string.
# omp (Oh My Pi) is a harness whose candidate model carries an explicit,
# self-declared namespace prefix instead of a single primary family: an
# `ollama/<id>` model routes a locally-hosted model (for example
# `ollama/qwen3:8b`) through omp with no paid vendor quota to check, the same
# way `openai-codex/<id>` and `claude-bridge/<id>` already select the codex
# and claude families. Pi carries one analogous declared local lane of its
# own, `gx10-vllm/<id>` (currently `gx10-vllm/qwen3.8-27b-fp8`, the default
# local Qwen candidate), reported by Pi's own catalog exactly like its
# `openai-codex/<id>`-style provider-prefixed models (see
# docs/verification/dispatch-auth.md); every other Pi model keeps the
# existing single-family "pi" mapping. Only these exact declared prefixes are
# recognized; nothing here infers "local" from a bare model name.
#
# A harness with no provider mapping here (fm_candidate_provider_for_harness
# returns nonzero) is reported as source "none"/status "unknown" rather than
# failing the whole call, because a caller such as fm-spawn.sh dispatches
# harnesses (agy, gemini, rovo, ...) this optional layer does not map; only
# the Copilot check, which is keyed on the model string alone, still applies
# to those candidates.

_FM_CANDIDATE_AVAILABILITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CANDIDATE_AVAILABILITY_LIB_DIR="."

# shellcheck source=bin/fm-copilot-quota-lib.sh
. "$_FM_CANDIDATE_AVAILABILITY_LIB_DIR/fm-copilot-quota-lib.sh"

# fm_candidate_provider_for_harness <harness> [<model>]
# Map a firstmate harness to its primary quota-axi provider family, or (for
# omp, and for Pi's one declared local lane) to a family selected by the
# candidate's declared model prefix. Multi-provider harnesses otherwise map to
# their primary family only; see fm-quota-choose.sh's header for that accepted
# limitation.
#
# Pi's own catalog (`pi --list-models <query>`) reports a provider column
# ahead of the model, the same shape as openai-codex/gpt-5.6-terra in
# docs/verification/dispatch-auth.md. gx10-vllm/<id> is Pi's catalog name for
# its one locally-hosted (self-served, no paid vendor quota) lane - currently
# the default Qwen local model, gx10-vllm/qwen3.8-27b-fp8 - so it is
# recognized here the same way omp's openai-codex/, claude-bridge/, and
# ollama/ prefixes are: an explicit, self-declared provider name from the
# harness's own catalog, never a guessed prefix. Every other Pi model keeps
# the existing single-family "pi" mapping and its accepted limitation.
fm_candidate_provider_for_harness() {
  case "$1" in
    omp)
      case "${2:-}" in
        openai-codex/*)  printf 'codex\n' ;;
        claude-bridge/*) printf 'claude\n' ;;
        ollama/*)        printf 'local\n' ;;
        *)               return 1 ;;
      esac
      ;;
    pi|pi-signed)
      case "${2:-}" in
        gx10-vllm/*) printf 'local\n' ;;
        *)           printf 'pi\n' ;;
      esac
      ;;
    claude)       printf 'claude\n' ;;
    codex)        printf 'codex\n' ;;
    opencode)     printf 'codex\n' ;;
    grok)         printf 'grok\n' ;;
    kimi)         printf 'kimi\n' ;;
    cursor)       printf 'cursor\n' ;;
    muse)         printf 'meta\n' ;;
    *)            return 1 ;;
  esac
}

# fm_candidate_effective_for_provider_model <quota-json> <provider> <model>
# Print the most constraining applicable quota-axi evidence for the
# provider/model tuple, including provider-wide and exact model or product
# scopes. Empty output means no applicable evidence exists.
fm_candidate_effective_for_provider_model() {
  local quota_json=$1 provider=$2 model=${3:-default}
  printf '%s\n' "$quota_json" | jq -c --arg provider "$provider" --arg model "$model" '
    ($model | sub("^model:"; "")) as $model_token |
    ([.providers[]? | select(.provider == $provider)] | first) as $p |
    if ($p // null) == null then {status: "unknown"}
    else ($p.quotaSemantics.effectiveAvailability // []) |
    map(select(.scope as $scope |
      $scope == "all_models" or $scope == "all_products" or
      ($model_token != "" and $model_token != "default" and
       (($scope | startswith("model:")) or ($scope | startswith("product:"))) and
       ($model_token == ($scope | sub("^(model|product):"; ""))))
    )) as $applicable |
    ($applicable | map(select(.status == "known"))) as $known |
    if ($applicable | length) == 0 then {status: "unknown"}
    elif any($applicable[]; (.runway.status // "") == "exhausted_now") then
      ($applicable | map(select((.runway.status // "") == "exhausted_now")) | first)
    elif ($known | length) == 0 then {status: "unknown"}
    elif any($known[]; .effectivePercentRemaining == 0) then
      ($known | map(select(.effectivePercentRemaining == 0)) | first)
    else ($known | min_by(.effectivePercentRemaining))
    end
    end
  ' 2>/dev/null
}

# fm_candidate_availability <quota-json-or-empty> <harness> <model>
# See the file header for the returned JSON shape. Never fails: an
# unrecognized harness/model combination is reported as unknown rather than
# raising an error, so callers keep their own harness-validity checks.
fm_candidate_availability() {
  local quota_json=$1 harness=$2 model=$3
  local provider scope_model effective status eligible

  if fm_copilot_model_is_premium "$model"; then
    if fm_copilot_model_available "$model"; then
      eligible=true
    else
      eligible=false
    fi
    jq -n --arg harness "$harness" --arg model "$model" --argjson eligible "$eligible" \
      '{harness: $harness, model: $model, provider: "copilot", source: "copilot", status: "known", eligible: $eligible}'
    return 0
  fi

  if ! provider=$(fm_candidate_provider_for_harness "$harness" "$model"); then
    jq -n --arg harness "$harness" --arg model "$model" \
      '{harness: $harness, model: $model, provider: null, source: "none", status: "unknown", eligible: false}'
    return 0
  fi

  if [ "$provider" = local ]; then
    jq -n --arg harness "$harness" --arg model "$model" \
      '{harness: $harness, model: $model, provider: "local", source: "local", status: "not_applicable", eligible: true}'
    return 0
  fi

  scope_model=$model
  [ "$harness" != omp ] || scope_model=${model#*/}

  if [ -z "$quota_json" ]; then
    jq -n --arg harness "$harness" --arg model "$model" --arg provider "$provider" \
      '{harness: $harness, model: $model, provider: $provider, source: "quota-axi", status: "unknown", eligible: false}'
    return 0
  fi

  effective=$(fm_candidate_effective_for_provider_model "$quota_json" "$provider" "$scope_model")
  if [ -z "$effective" ] || [ "$effective" = null ]; then
    status=unknown
    eligible=false
  else
    status=$(printf '%s\n' "$effective" | jq -r '.status')
    if printf '%s\n' "$effective" | jq -e '
      if (.runway.status // "") == "exhausted_now" then false
      elif .status == "unknown" then false
      else
        .effectivePercentRemaining as $remaining |
        (($remaining | type) == "number") and
        ($remaining > 0) and
        ((.runway.status // "") != "exhausted_now")
      end
    ' >/dev/null 2>&1; then
      eligible=true
    else
      eligible=false
    fi
  fi
  jq -n --arg harness "$harness" --arg model "$model" --arg provider "$provider" \
    --arg status "$status" --argjson eligible "$eligible" \
    '{harness: $harness, model: $model, provider: $provider, source: "quota-axi", status: $status, eligible: $eligible}'
}
