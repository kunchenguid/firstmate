#!/usr/bin/env bash
# shellcheck shell=bash
# fm-provider-lib.sh - single owner of the model -> provider identity mapping and
# the per-provider live-lane concurrency cap.
#
# Usage:
#   . bin/fm-provider-lib.sh
#
# A provider is the billing pool a dispatch draws on, NOT the harness that
# launches it. The identity is taken from the resolved model string first - a
# provider-qualified `<provider>/<id>` prefix, else a model-id pattern - and the
# harness table is consulted only when the model carries no signal. That is what
# makes `opencode-go/deepseek-v4.1-flash` and `opencode-go/deepseek-v4-pro` ONE
# pool while `pi/deepseek-v4p1-flash`, billed through Fireworks, is a different
# one. The harness fallback reuses the existing quota tables
# (fm_quota_provider_for_harness / fm_quota_single_provider_for_harness in
# bin/fm-quota-axi-lib.sh) rather than restating them; those tables are frozen
# for no-key quota routing and are never edited here.
#
# Functions:
#   fm_provider_for_model <harness> <model>
#       Print the provider id the tuple bills against, or return 1 when the
#       model and harness together name no known pool.
#   fm_lane_provider <harness> <model>
#       Print fm_provider_for_model's answer, or the harness name as a
#       last-resort bucket, or return 1 when even that is empty.
#   fm_provider_cap_for <provider> [<config-dir>]
#       Print the operator-configured cap: `providerCaps.<provider>` from
#       config/crew-dispatch.json, else `providerCaps.default`, else
#       FM_PROVIDER_LANE_CAP_DEFAULT.
#   fm_provider_lane_counts <state-dir> [<config-dir>] [<exclude-id>]
#       Print `<provider> <used> <cap>` for every provider carrying a live lane,
#       sorted by provider. One line per provider, no header.
#   fm_provider_cap_refuse <state-dir> <config-dir> <harness> <model> [<exclude-id>]
#       Print an operator-facing refusal to stderr and return 1 when dispatching
#       this tuple would push its provider past the cap; return 0 otherwise.
#
# Seat accounting: a lane occupies a seat unless its recorded endpoint is
# PROVABLY dead or missing (fm_backend_agent_state). A lane whose endpoint cannot
# be proven gone - alive, ambiguous, unreadable, or unverified (every backend
# except tmux and herdr) - keeps its seat, and a record with no endpoint target
# keeps it too. The count can therefore under-admit, never over-admit; a
# stranded record on an unverifiable backend is released by the stranded-record
# detector that retires it, not by this counter.
#
# Scope: the cap is per home. A remote secondmate's own lanes live on another
# host and are invisible here, so this counter governs only the lanes this
# home's state directory records.
set -u

if [ -n "${FM_PROVIDER_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_PROVIDER_LIB_SOURCED=1

FM_PROVIDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$FM_PROVIDER_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$FM_PROVIDER_LIB_DIR/fm-quota-axi-lib.sh"

# Fallback cap when config/crew-dispatch.json is absent or declares no
# providerCaps entry. The operator overrides it per provider (or for every
# provider through providerCaps.default) in config/crew-dispatch.json.
FM_PROVIDER_LANE_CAP_DEFAULT=4

# fm_provider_for_model <harness> <model>
fm_provider_for_model() {  # <harness> <model>
  local harness=${1:-} model=${2:-} segment
  case "$model" in
    '' | default | -) ;;
    */*)
      segment=${model%%/*}
      case "$segment" in
        fireworks_ai | fireworks) printf 'fireworks\n'; return 0 ;;
        openai-codex | openai) printf 'codex\n'; return 0 ;;
        claude-bridge | anthropic) printf 'claude\n'; return 0 ;;
      esac
      # An unrecognized provider-qualified prefix is its own billing pool when
      # it is a well-formed provider id (the same shape docs/configuration.md
      # pins for the resolver's provider fields).
      case "$segment" in
        '' | -* | *- | *--* | *[!a-z0-9-]*) ;;
        *) printf '%s\n' "$segment"; return 0 ;;
      esac
      ;;
  esac
  case "$model" in
    '' | default | -) ;;
    deepseek-v4p1*) printf 'fireworks\n'; return 0 ;;
    deepseek*) printf 'deepseek\n'; return 0 ;;
    composer* | cursor-*) printf 'cursor\n'; return 0 ;;
    grok-*) printf 'grok\n'; return 0 ;;
    claude-* | sonnet | haiku | opus | fable) printf 'claude\n'; return 0 ;;
    kimi-*) printf 'kimi\n'; return 0 ;;
    gemini-*) printf 'gemini\n'; return 0 ;;
    muse*) printf 'meta\n'; return 0 ;;
    codex* | gpt-* | o[0-9]*) printf 'codex\n'; return 0 ;;
  esac
  if fm_quota_provider_for_harness "$harness" 2>/dev/null; then
    return 0
  fi
  if fm_quota_single_provider_for_harness "$harness" 2>/dev/null; then
    return 0
  fi
  return 1
}

# fm_lane_provider <harness> <model>
# The bucket a lane is counted against: the model-derived provider when one is
# known, else the harness name so unmapped lanes still count somewhere.
fm_lane_provider() {  # <harness> <model>
  local harness=${1:-}
  if fm_provider_for_model "$1" "${2:-}" 2>/dev/null; then
    return 0
  fi
  [ -n "$harness" ] || return 1
  printf '%s\n' "$harness"
}

# fm_provider_cap_for <provider> [<config-dir>]
fm_provider_cap_for() {  # <provider> [<config-dir>]
  local provider=${1:-} config=${2:-} cap=''
  if [ -n "$config" ] && [ -r "$config/crew-dispatch.json" ] && command -v jq >/dev/null 2>&1; then
    cap=$(jq -r --arg p "$provider" '
      (.providerCaps // {}) as $c
      | ($c[$p] // $c.default // empty)
      | select(type == "number" and . >= 1 and . == floor)
    ' "$config/crew-dispatch.json" 2>/dev/null || true)
  fi
  case "$cap" in
    '' | *[!0-9]*) cap=$FM_PROVIDER_LANE_CAP_DEFAULT ;;
  esac
  printf '%s\n' "$cap"
}

# fm_provider_lane_counts <state-dir> [<config-dir>] [<exclude-id>]
fm_provider_lane_counts() {  # <state-dir> [<config-dir>] [<exclude-id>]
  local state=${1:-} config=${2:-} exclude=${3:-}
  local meta id harness model provider backend target endpoint_state
  [ -n "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ -n "$exclude" ] && [ "$id" = "$exclude" ] && continue
    harness=$(fm_meta_get "$meta" harness)
    model=$(fm_meta_get "$meta" model)
    provider=$(fm_lane_provider "$harness" "$model" 2>/dev/null) || continue
    [ -n "$provider" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if [ -n "$target" ]; then
      endpoint_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')
      case "$endpoint_state" in
        dead | missing) continue ;;
      esac
    fi
    printf '%s\n' "$provider"
  done | LC_ALL=C sort | uniq -c | while read -r used provider; do
    printf '%s %s %s\n' "$provider" "$used" "$(fm_provider_cap_for "$provider" "$config")"
  done
}

# fm_provider_cap_refuse <state-dir> <config-dir> <harness> <model> [<exclude-id>]
fm_provider_cap_refuse() {  # <state-dir> <config-dir> <harness> <model> [<exclude-id>]
  local state=${1:-} config=${2:-} harness=${3:-} model=${4:-} exclude=${5:-}
  local provider used cap
  provider=$(fm_lane_provider "$harness" "$model" 2>/dev/null) || return 0
  [ -n "$provider" ] || return 0
  cap=$(fm_provider_cap_for "$provider" "$config")
  used=$(fm_provider_lane_counts "$state" "$config" "$exclude" | awk -v p="$provider" '$1 == p { print $2; exit }')
  case "$used" in
    '' | *[!0-9]*) used=0 ;;
  esac
  if [ "$used" -ge "$cap" ]; then
    printf 'error: provider lane cap: %s already carries %s live lanes (cap %s), so dispatching harness=%s model=%s would exceed it; reassign to a provider with headroom, or raise providerCaps.%s in %s/crew-dispatch.json (fallback cap %s).\n' \
      "$provider" "$used" "$cap" "${harness:-unknown}" "${model:-default}" \
      "$provider" "${config:-<config>}" "$FM_PROVIDER_LANE_CAP_DEFAULT" >&2
    return 1
  fi
  return 0
}
