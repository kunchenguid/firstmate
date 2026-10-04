#!/usr/bin/env bash
# Read-only model evidence for one explicit harness/model tuple.
# Usage: fm-model-availability.sh <harness> <model>
# JSON output separates harness-catalog evidence from provider quota evidence.
# `unsupported` is emitted only when that harness supplied a reachable,
# account-specific listing that omits the exact model. A missing CLI, catalog,
# or quota row is uncertainty, never proof that a model is unavailable.
# Quota scopes identify providers, not harnesses; this tool never converts one
# to the other or edits model routing, global tools, or credentials.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
harness=${1:-}
model=${2:-}
if [ "$#" -ne 2 ] || [ -z "$harness" ] || [ -z "$model" ]; then
  printf 'Usage: fm-model-availability.sh <harness> <model>\n' >&2
  exit 2
fi
case "$harness" in
  claude|pi|codex|opencode|cursor|grok|kimi|gemini|rovo|muse|agy|devin|omp|pi-signed) ;;
  *) printf 'fm-model-availability: unsupported harness identity: %s\n' "$harness" >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { printf 'fm-model-availability: jq is required\n' >&2; exit 2; }

catalog_status=unverified
catalog_source=none
catalog_rows=''
if [ "$harness" = pi ] || [ "$harness" = pi-signed ]; then
  catalog_filter=$model
  catalog_model=$model
  catalog_provider=''
  case "$model" in
    */*) catalog_provider=${model%%/*}; catalog_model=${model#*/}; catalog_filter=$catalog_provider ;;
  esac
  if [ -n "$catalog_filter" ] && [ -n "$catalog_model" ] \
    && command -v "$harness" >/dev/null 2>&1 \
    && catalog_rows=$("$harness" --list-models "$catalog_filter" 2>/dev/null); then
    catalog_source="$harness --list-models"
    catalog_status=unsupported
    if printf '%s\n' "$catalog_rows" | awk -v provider="$catalog_provider" -v model="$catalog_model" \
      'NR > 1 && $2 == model && (provider == "" || $1 == provider) {found=1} END {exit !found}'; then
      catalog_status=available
    fi
  fi
elif [ "$harness" = opencode ]; then
  if command -v opencode >/dev/null 2>&1 && catalog_rows=$(opencode models 2>/dev/null); then
    catalog_source='opencode models'
    catalog_status=unsupported
    if printf '%s\n' "$catalog_rows" | grep -qxF "$model"; then catalog_status=available; fi
  fi
elif [ "$harness" = cursor ]; then
  # Reuse the spawn owner's verified launcher and exact catalog parser. A bare
  # executable named `agent` can be unrelated, so it is never queried directly.
  # shellcheck source=bin/fm-cursor-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-cursor-lib.sh"
  cursor_bin=$(fm_cursor_resolve_binary 2>/dev/null) || cursor_bin=''
  if [ -n "$cursor_bin" ] && catalog_rows=$(fm_cursor_list_models "$cursor_bin" 2>/dev/null); then
    catalog_source="$cursor_bin --list-models"
    catalog_status=unsupported
    if printf '%s\n' "$catalog_rows" | fm_cursor_catalog_has_model "$model"; then
      catalog_status=available
    fi
  fi
fi
# Claude's published CLI flag accepts aliases, but its account catalog is the
# interactive /model picker. A quota model:fable scope must therefore keep
# `claude:fable` unresolved rather than being misreported as unsupported.

quota='{}'
if command -v quota-axi >/dev/null 2>&1; then
  quota=$(quota-axi --json --no-credential-refresh 2>/dev/null) || quota='{}'
fi
if ! printf '%s' "$quota" | jq -e 'type == "object"' >/dev/null 2>&1; then quota='{}'; fi
quota_evidence=$(printf '%s' "$quota" | jq -c --arg model "$model" '
  [.providers[]? | select(.windows? | any(.[]?; .id == ("model:" + $model))) |
    {provider, scope:("model:" + $model), state:(.state.status // "unknown"),
     percentRemaining: ([.windows[]? | select(.id == ("model:" + $model)) | .percentRemaining] | first // null)}]
')
model_catalog='{}'
if command -v quota-axi >/dev/null 2>&1; then
  model_catalog=$(quota-axi models --json --no-credential-refresh 2>/dev/null) || model_catalog='{}'
fi
if ! printf '%s' "$model_catalog" | jq -e 'type == "object"' >/dev/null 2>&1; then model_catalog='{}'; fi
curated=$(printf '%s' "$model_catalog" | jq -c --arg model "$model" '[.models[]? | select(.id == $model) | {provider,id}]')
jq -nc --arg harness "$harness" --arg model "$model" --arg status "$catalog_status" \
  --arg source "$catalog_source" --argjson quota "$quota_evidence" --argjson curated "$curated" '
  {harness:$harness,model:$model,harnessCatalog:{status:$status,source:$source},
   quotaModelScopes:$quota,curatedModels:$curated,
   resolution:(if $status == "available" then "available" elif $status == "unsupported" then "unsupported-on-this-harness" else "uncertain" end)}'
