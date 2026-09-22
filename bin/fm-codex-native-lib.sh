#!/usr/bin/env bash
# fm-codex-native-lib.sh - shared validation for a recorded native ChatGPT Codex binding.

_FM_CODEX_NATIVE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F fm_run_timed >/dev/null 2>&1; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$_FM_CODEX_NATIVE_LIB_DIR/fm-timeout-lib.sh"
fi
unset _FM_CODEX_NATIVE_LIB_DIR

fm_codex_native_preflight() {  # <absolute-codex-bin> <canonical-codex-home>
  local codex_bin=$1 codex_home=$2 codex_home_real timeout status status_rc=0
  case "$codex_bin" in
    /*) ;;
    *) echo "error: recorded Codex native-provider executable is not an absolute path" >&2; return 1 ;;
  esac
  [ -x "$codex_bin" ] || {
    echo "error: recorded Codex native-provider executable is not executable at '$codex_bin'" >&2
    return 1
  }
  [ -n "$codex_home" ] && [ -d "$codex_home" ] && [ -r "$codex_home" ] || {
    echo "error: recorded Codex native-provider home is not a readable directory at '${codex_home:-none}'" >&2
    return 1
  }
  codex_home_real=$(CDPATH='' cd -- "$codex_home" 2>/dev/null && pwd -P) || {
    echo "error: recorded Codex native-provider home cannot be resolved" >&2
    return 1
  }
  [ "$codex_home_real" = "$codex_home" ] || {
    echo "error: recorded Codex native-provider home no longer resolves to its pinned path" >&2
    return 1
  }
  timeout=${FM_CODEX_NATIVE_STATUS_TIMEOUT:-10}
  case "$timeout" in
    ''|*[!0-9]*|0*) timeout=10 ;;
  esac
  status=$(fm_run_timed "$timeout" env \
    -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u CODEX_API_KEY \
    -u CODEX_ACCESS_TOKEN -u OPENAI_BASE_URL \
    CODEX_HOME="$codex_home" "$codex_bin" login status 2>&1) \
    || status_rc=$?
  if [ "$status_rc" -ne 0 ] || [ "$status" != "Logged in using ChatGPT" ]; then
    echo "error: Codex native-provider guard requires 'codex login status' to report exactly 'Logged in using ChatGPT'; native launch refused" >&2
    return 1
  fi
}
