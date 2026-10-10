#!/usr/bin/env bash
# fm-model-tier.sh - resolve model tiers from harness discovery surfaces.
#
# Usage:
#   fm-model-tier.sh resolve <harness> <tier> [<effort>]
#   fm-model-tier.sh supports-effort <harness> <model> <effort>
#   fm-model-tier.sh max-models [<harness>]
#
# Supported tiers:
#   strong   - frontier / strongest reasoning model for demanding tasks
#   standard - everyday / workhorse coding model
#   fast     - quick, lightweight, or low-latency model
#
# Discovery surfaces:
#   claude - floating aliases: opus (strong), sonnet (standard), haiku (fast)
#   codex  - ${CODEX_HOME:-~/.codex}/models_cache.json (Codex-maintained cache;
#            read on each resolution, without a forced refresh)
#   agy    - agy models
#   kimi   - kimi provider list --json
#
# Codex, agy, and Kimi candidates are ordered by numeric generation parsed from
# their IDs, not catalog order or context size. Claude uses floating aliases.
# Codex excludes hidden models. No matching candidate is an error.
#
# Selects only candidates from the discovery surface. If discovery is unreachable,
# fails with the concrete missing requirement rather than a remembered model id.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

fm_model_tier_canonical() {
  local tier=${1:-}
  case "$tier" in
  strong | standard | fast) printf '%s\n' "$tier" ;;
  *)
    echo "error: invalid tier '$tier'; must be strong, standard, or fast" >&2
    return 1
    ;;
  esac
}

fm_model_tier_resolve_claude() {
  local tier=$1 effort=${2:-}
  local bin=${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    echo "error: claude model discovery is unreachable (claude binary not found on PATH)" >&2
    return 1
  fi
  case "$tier" in
  strong) printf '%s\n' "opus" ;;
  standard) printf '%s\n' "sonnet" ;;
  fast) printf '%s\n' "haiku" ;;
  esac
}

fm_model_tier_newest() {
  jq -Rsr '
    def generation:
      [capture("(?:^|[-/])k?(?<version>[0-9]+(?:\\.[0-9]+)*)(?:[-/]|$)"; "i").version
        | split(".") | map(tonumber)] | first // [];
    split("\n") | map(select(length > 0))
    | sort_by(generation, -length, .) | last // empty
  '
}

fm_model_tier_resolve_codex() {
  local tier=$1 effort=${2:-}
  local cache="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
  if [ ! -f "$cache" ] || [ ! -r "$cache" ]; then
    echo "error: codex model discovery is unreachable ($cache is missing or unreadable)" >&2
    return 1
  fi
  if ! jq -e . "$cache" >/dev/null 2>&1; then
    echo "error: codex model discovery is unreachable ($cache is malformed JSON)" >&2
    return 1
  fi

  local resolved
  case "$tier" in
  strong)
    resolved=$(jq -r '
      ([.models[]? | select(.visibility != "hide" and ((.slug | test("astra|strong|frontier"; "i")) or ((.description // "") | test("frontier"; "i"))))]
        | .[].slug)
    ' "$cache" 2>/dev/null | fm_model_tier_newest || true)
    ;;
  standard)
    resolved=$(jq -r '
      ([.models[]? | select(.visibility != "hide" and ((.slug | test("sol|standard|workhorse"; "i")) or ((.description // "") | test("workhorse"; "i"))))]
        | .[].slug)
    ' "$cache" 2>/dev/null | fm_model_tier_newest || true)
    ;;
  fast)
    resolved=$(jq -r '
      ([.models[]? | select(.visibility != "hide" and ((.slug | test("luna|fast|mini"; "i")) or ((.description // "") | test("fast"; "i"))))]
        | .[].slug)
    ' "$cache" 2>/dev/null | fm_model_tier_newest || true)
    ;;
  esac

  if [ -z "$resolved" ]; then
    echo "error: codex model catalog contains no candidate for tier '$tier'" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

fm_model_tier_resolve_agy() {
  local tier=$1 effort=${2:-}
  local bin=${AGY_BIN:-$(command -v agy 2>/dev/null || true)}
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    echo "error: agy model discovery is unreachable (agy binary not found on PATH)" >&2
    return 1
  fi

  local listing rc=0 bound=${FM_AGY_MODELS_TIMEOUT:-15}
  case "$bound" in '' | *[!0-9]* | 0*) bound=15 ;; esac
  listing=$(fm_run_timed "$bound" "$bin" models 2>/dev/null < /dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$listing" ]; then
    echo "error: agy model discovery is unreachable ('agy models' failed with exit $rc or returned empty listing)" >&2
    return 1
  fi

  local models resolved=""
  models=$(printf '%s\n' "$listing" | awk '{print $1}')
  local target_effort="${effort:-high}"

  case "$tier" in
  strong)
    resolved=$(printf '%s\n' "$models" | grep -Ei -- "-(pro|opus|strong)-${target_effort}$" | fm_model_tier_newest || true)
    [ -n "$resolved" ] || resolved=$(printf '%s\n' "$models" | grep -Ei -- "-(pro|opus|strong)" | fm_model_tier_newest || true)
    ;;
  standard)
    resolved=$(printf '%s\n' "$models" | grep -Ei -- "-(flash|sonnet|standard)-${target_effort}$" | fm_model_tier_newest || true)
    [ -n "$resolved" ] || resolved=$(printf '%s\n' "$models" | grep -Ei -- "-(flash|sonnet|standard)" | grep -Eiv -- "-(flash|sonnet|standard)-(lite|low)-" | fm_model_tier_newest || true)
    ;;
  fast)
    if [ -n "$effort" ]; then
      resolved=$(printf '%s\n' "$models" | grep -Ei -- "-(flash.*lite|flash.*low|fast|haiku)-${effort}$" | fm_model_tier_newest || true)
    fi
    [ -n "$resolved" ] || resolved=$(printf '%s\n' "$models" | grep -Ei -- "-(flash-low|flash.*lite|fast|haiku)" | fm_model_tier_newest || true)
    [ -n "$resolved" ] || resolved=$(printf '%s\n' "$models" | grep -Ei -- "-(flash|sonnet|standard)-low$" | fm_model_tier_newest || true)
    ;;
  esac

  if [ -z "$resolved" ]; then
    echo "error: agy model catalog contains no candidate for tier '$tier'" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

fm_model_tier_resolve_kimi() {
  local tier=$1 effort=${2:-}
  local bin=${KIMI_BIN:-$(command -v kimi 2>/dev/null || true)}
  if [ -z "$bin" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    bin="$HOME/.kimi-code/bin/kimi"
  fi
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    echo "error: kimi model discovery is unreachable (kimi binary not found on PATH or ~/.kimi-code/bin/kimi)" >&2
    return 1
  fi

  local listing rc=0
  listing=$(fm_run_timed 15 "$bin" provider list --json 2>/dev/null < /dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$listing" ] || ! jq -e .models <<<"$listing" >/dev/null 2>&1; then
    echo "error: kimi model discovery is unreachable ('kimi provider list --json' failed with exit $rc or returned invalid JSON)" >&2
    return 1
  fi

  local resolved
  case "$tier" in
  strong)
    resolved=$(jq -r '
      .models | keys[] | select(test("(?:^|/)k(?:[3-9]|[1-9][0-9]+)(?:[-.]|$)|strong|frontier"; "i"))
    ' <<<"$listing" 2>/dev/null | fm_model_tier_newest || true)
    ;;
  standard)
    resolved=$(jq -r '
      .models | keys[] | select((test("kimi-for-coding|standard|workhorse"; "i")) and (test("highspeed|fast"; "i") | not))
    ' <<<"$listing" 2>/dev/null | fm_model_tier_newest || true)
    ;;
  fast)
    resolved=$(jq -r '
      .models | keys[] | select(test("highspeed|fast|mini"; "i"))
    ' <<<"$listing" 2>/dev/null | fm_model_tier_newest || true)
    ;;
  esac

  if [ -z "$resolved" ]; then
    echo "error: kimi model catalog contains no candidate for tier '$tier'" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

fm_model_tier_resolve() {
  local harness=$1 tier=$2 effort=${3:-}
  local canonical resolved
  canonical=$(fm_model_tier_canonical "$tier") || return 1
  case "$harness" in
  claude) resolved=$(fm_model_tier_resolve_claude "$canonical" "$effort") || return 1 ;;
  codex) resolved=$(fm_model_tier_resolve_codex "$canonical" "$effort") || return 1 ;;
  agy) resolved=$(fm_model_tier_resolve_agy "$canonical" "$effort") || return 1 ;;
  kimi) resolved=$(fm_model_tier_resolve_kimi "$canonical" "$effort") || return 1 ;;
  *)
    echo "error: harness '$harness' does not support tier resolution" >&2
    return 1
    ;;
  esac
  if [ -n "$effort" ] && ! fm_model_catalog_supports_effort "$harness" "$resolved" "$effort"; then
    echo "error: $harness model '$resolved' does not support effort '$effort'" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

fm_model_catalog_supports_effort() {
  local harness=$1 model=$2 effort=$3
  case "$harness" in
  codex)
    local cache="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
    if [ ! -f "$cache" ] || [ ! -r "$cache" ]; then
      case "$effort" in
      low | medium | high | xhigh) return 0 ;;
      *) return 1 ;;
      esac
    fi
    local count
    count=$(jq -r --arg m "$model" --arg e "$effort" '
      [.models[]? | select(.slug == $m) | .supported_reasoning_levels[]?.effort | select(. == $e)] | length
    ' "$cache" 2>/dev/null || echo 0)
    [ "${count:-0}" -gt 0 ]
    ;;
  *)
    return 0
    ;;
  esac
}

fm_codex_max_models() {
  local cache="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
  if [ -f "$cache" ] && [ -r "$cache" ]; then
    jq -c '[.models[]? | select(.supported_reasoning_levels[]?.effort == "max") | .slug] | unique' "$cache" 2>/dev/null || echo '[]'
  else
    echo '[]'
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  action=${1:-}
  shift || true
  case "$action" in
  resolve)
    [ $# -ge 2 ] || { echo "Usage: $0 resolve <harness> <tier> [<effort>]" >&2; exit 2; }
    fm_model_tier_resolve "$1" "$2" "${3:-}"
    ;;
  supports-effort)
    [ $# -ge 3 ] || { echo "Usage: $0 supports-effort <harness> <model> <effort>" >&2; exit 2; }
    fm_model_catalog_supports_effort "$1" "$2" "$3"
    ;;
  max-models)
    harness=${1:-codex}
    case "$harness" in
    codex) fm_codex_max_models ;;
    *) echo '[]' ;;
    esac
    ;;
  -h | --help | help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  *)
    echo "Usage: $0 <resolve|supports-effort|max-models> ..." >&2
    exit 2
    ;;
  esac
fi
