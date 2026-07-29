#!/usr/bin/env bash

FM_LAUNCH_PROFILE_CANONICAL=canonical
FM_LAUNCH_PROFILE_RAW=raw

fm_launch_profile_is_child_replayable() {
  [ "$1" = "$FM_LAUNCH_PROFILE_CANONICAL" ]
}

fm_launch_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_launch_resolve_binary() {  # <harness>
  local harness=$1 candidate dir fallback
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
      /*) printf '%s\n' "$candidate"; return 0 ;;
      *)
        dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
        if [ -n "$dir" ]; then
          printf '%s/%s\n' "$dir" "$(basename "$candidate")"
          return 0
        fi
        ;;
    esac
  fi
  if [ "$harness" = kimi ]; then
    fallback="${HOME:-}/.kimi-code/bin/kimi"
    if [ -n "${HOME:-}" ] && [ -x "$fallback" ]; then
      printf '%s\n' "$fallback"
      return 0
    fi
    echo "error: kimi executable not found; searched PATH for 'kimi' and fallback '$fallback'" >&2
  else
    echo "error: $harness executable not found on PATH" >&2
  fi
  return 1
}

fm_launch_model_flag_for_harness() {  # <harness> <model>
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi)
      printf -- '--model %s ' "$(fm_launch_shell_quote "$model")"
      ;;
  esac
}

fm_launch_effort_flag_for_harness() {  # <harness> <effort>
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(fm_launch_shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
    pi|pi-signed)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
  esac
}

fm_launch_profile_args() {  # <harness> <model> <effort>
  local harness=$1 model=$2 effort=$3
  FM_LAUNCH_PROFILE_ARGS=()
  [ -z "$model" ] || [ "$model" = default ] || FM_LAUNCH_PROFILE_ARGS+=(--model "$model")
  case "$harness" in
    claude)
      case "$effort" in default|'') ;; *) FM_LAUNCH_PROFILE_ARGS+=(--effort "$effort") ;; esac
      ;;
    codex)
      case "$effort" in low|medium|high|xhigh) FM_LAUNCH_PROFILE_ARGS+=(-c "model_reasoning_effort=\"$effort\"") ;; esac
      ;;
    grok)
      case "$effort" in low|medium|high) FM_LAUNCH_PROFILE_ARGS+=(--reasoning-effort "$effort") ;; esac
      ;;
    pi|pi-signed)
      case "$effort" in default|'') ;; *) FM_LAUNCH_PROFILE_ARGS+=(--thinking "$effort") ;; esac
      ;;
  esac
}

fm_launch_environment_prefix() {  # <harness>
  local harness=$1
  case "$harness" in
    claude)
      [ -z "${CLAUDE_CONFIG_DIR:-}" ] \
        || printf 'CLAUDE_CONFIG_DIR=%s ' "$(fm_launch_shell_quote "$CLAUDE_CONFIG_DIR")"
      ;;
    pi|pi-signed)
      printf 'FM_PI_HARNESS=%s ' "$harness"
      ;;
  esac
}
