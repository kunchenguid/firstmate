#!/usr/bin/env bash

fm_profile_normalize_model() {
  case "${1:-}" in
    ''|-|default) printf 'default\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

fm_profile_normalize_harness() {
  case "${1:-}" in
    pi) printf 'pi\n' ;;
    pi-signed) printf 'pi-signed\n' ;;
    claude*) printf 'claude\n' ;;
    codex*) printf 'codex\n' ;;
    opencode*) printf 'opencode\n' ;;
    grok*) printf 'grok\n' ;;
    kimi*) printf 'kimi\n' ;;
    muse*) printf 'muse\n' ;;
    *) return 1 ;;
  esac
}

fm_profile_normalize_effort() {
  case "${1:-}" in
    ''|-|default) printf 'default\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

fm_profile_effective_effort() {
  local harness=$1 effort=$2
  harness=$(fm_profile_normalize_harness "$harness") || return 1
  effort=$(fm_profile_normalize_effort "$effort")
  case "$effort" in
    default)
      printf 'default\n'
      ;;
    low|medium|high|xhigh|max)
      case "$harness" in
        claude|codex|pi|pi-signed) printf '%s\n' "$effort" ;;
        grok)
          case "$effort" in
            low|medium|high) printf '%s\n' "$effort" ;;
            xhigh|max) printf 'high\n' ;;
          esac
          ;;
        opencode|kimi) printf 'default\n' ;;
        muse)
          case "$effort" in
            max) printf 'ultra\n' ;;
            low|medium|high|xhigh) printf '%s\n' "$effort" ;;
          esac
          ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

fm_profile_codex_max_effort_capability() {
  case "${1:-}" in
    gpt-5.6-sol|gpt-5.6-sol-wm|gpt-5.6-terra|gpt-5.6-luna|codex-auto-review)
      return 0 ;;
    gpt-5.3-codex-spark)
      return 1 ;;
    *)
      return 2 ;;
  esac
}

fm_profile_validate_effort_capability() {
  local harness=$1 model=${2:-default} effort=${3:-} capability
  harness=$(fm_profile_normalize_harness "$harness") || return 0
  model=$(fm_profile_normalize_model "$model")
  effort=$(fm_profile_normalize_effort "$effort")
  [ "$harness" = codex ] && [ "$effort" = max ] || return 0
  fm_profile_codex_max_effort_capability "$model"
  capability=$?
  case "$capability" in
    0) return 0 ;;
    1)
      echo "error: codex model '$model' does not advertise max reasoning effort (catalog ceiling: xhigh); refusing before metadata or launch" >&2
      return 1 ;;
    2)
      echo "error: codex model '$model' has unknown max reasoning capability; select a model whose installed catalog advertises max (for example gpt-5.6-luna or gpt-5.6-sol); refusing before metadata or launch" >&2
      return 1 ;;
  esac
}
