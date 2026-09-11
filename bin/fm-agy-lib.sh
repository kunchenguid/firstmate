#!/usr/bin/env bash
# AGY adapter preflight. Source-only; no fleet or account mutations.
# fm_agy_backend_check <backend>: refuse placement without live control proof.
# fm_agy_preflight <executable> <model> <effort>: require the tested CLI surface
# and an exact Gemini catalog id before interactive launch, rather than relying
# on vendor defaults or display-name aliases for dispatch. This performs no
# inference: agy models establishes availability, NOT account eligibility.
# Effort low/medium/high is native. A conflicting model suffix is refused;
# unsupported efforts retain the common record-and-omit contract.
fm_agy_backend_check() {
  case "$1" in
    tmux|herdr) return 0 ;;
    *) echo "error: agy worker control/composer is verified only on tmux and herdr; backend '$1' is unsupported for agy" >&2; return 1 ;;
  esac
}

fm_agy_preflight() {
  local bin=$1 model=$2 effort=$3 help catalog flag
  [ -x "$bin" ] || { echo 'error: agy executable is absent' >&2; return 1; }
  help=$(AGY_CLI_DISABLE_AUTO_UPDATE=true "$bin" --help 2>&1) || return 1
  for flag in --new-project --add-dir --prompt-interactive --model --effort --dangerously-skip-permissions; do
    printf '%s\n' "$help" | grep -Eq -- "^[[:space:]]*$flag[[:space:]]" || {
      echo "error: agy lacks required CLI capability $flag; adapter launch refused" >&2
      return 1
    }
  done
  case "$model" in
    gemini-*) ;;
    *) echo 'error: agy workers require an explicit Gemini model id from agy models' >&2; return 1 ;;
  esac
  catalog=$(AGY_CLI_DISABLE_AUTO_UPDATE=true "$bin" models) || {
    echo 'error: agy model catalog unavailable; verify AGY authentication and connectivity' >&2
    return 1
  }
  printf '%s\n' "$catalog" | awk -F '\t' -v model="$model" '$1 == model {found=1} END {exit !found}' || {
    echo "error: agy model '$model' is not listed by agy models; no fallback was selected" >&2
    return 1
  }
  case "$effort" in
    low|medium|high)
      case "$model" in
        *-low|*-medium|*-high)
          [ "${model##*-}" = "$effort" ] || {
            echo "error: agy effort '$effort' would replace model variant '$model'; select matching model and effort" >&2
            return 1
          }
          ;;
      esac
      ;;
  esac
}
