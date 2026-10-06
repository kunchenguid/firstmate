#!/usr/bin/env bash
# fm-heavy-guard.sh - decide whether heavy suites may run on this host.
#
# Heavy suites (acceptance, end-to-end, and full-CI walks) are the ones that
# leak tens of gigabytes and thrash a workstation. When a home routes them to a
# remote campaign VM, this guard refuses them locally and names where to run
# them, so a worker cannot start one by accident.
#
# Usage:
#   fm-heavy-guard.sh status
#   fm-heavy-guard.sh check [--lane <lane>] [--family <family>] [--selection <mode>] [--token <name>] [--path <value>]...
#
# `status`   prints the posture and the rules that classify heavy work.
# `check`    exits 0 when the described work may run here, 3 when it is heavy and
#            the posture routes it away, and 2 on a usage error. The refusal
#            names the configured campaign runner.
#
# Configuration (optional, in this home's gitignored config/):
#   config/heavy-suites          `remote-only` routes heavy work to the campaign
#                                VM and refuses it here; `local` (the default)
#                                allows it. Any other value is an error.
#   config/campaign-runner       path or command for the campaign VM runner. When
#                                absent, a runner directory that exists on this
#                                host is named if one is found, otherwise the
#                                refusal points at the campaign VM generally.
#
# A lane named `heavy` and the families `live-harness-optin` and
# `real-herdr-gated` are always heavy. Selection `all` is always heavy. A free
# token is heavy when it names acceptance, end-to-end, full CI, playwright, or
# cypress work.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_HEAVY_POSTURE_FILE="heavy-suites"
FM_HEAVY_RUNNER_FILE="campaign-runner"
FM_HEAVY_DEFAULT_RUNNER=/sloth/gcp-runner

usage() {
  sed -n '2,/^set -u/{ /^set -u/d;s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'fm-heavy-guard: %s\n' "$*" >&2
  exit 2
}

# read_setting <file> - first non-comment, non-blank line, or empty.
fm_heavy_read_setting() {
  local path="$CONFIG/$1" line
  [ -r "$path" ] && [ ! -L "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    printf '%s' "$line"
    return 0
  done < "$path"
}

# fm_heavy_lower <value> - portable lowercase (stock macOS bash 3.2 has no ${v,,}).
fm_heavy_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# fm_heavy_posture - prints `local` or `remote-only`; an unknown value is an error.
fm_heavy_posture() {
  local value
  value=$(fm_heavy_lower "$(fm_heavy_read_setting "$FM_HEAVY_POSTURE_FILE")")
  case "$value" in
    ''|local) printf 'local\n' ;;
    remote-only) printf 'remote-only\n' ;;
    *)
      printf 'fm-heavy-guard: config/%s has an unknown posture: %s\n' \
        "$FM_HEAVY_POSTURE_FILE" "$value" >&2
      return 2
      ;;
  esac
}

fm_heavy_runner() {
  local value
  value=$(fm_heavy_read_setting "$FM_HEAVY_RUNNER_FILE")
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  if [ -d "$FM_HEAVY_DEFAULT_RUNNER" ]; then
    printf '%s' "$FM_HEAVY_DEFAULT_RUNNER"
  fi
}

# fm_heavy_lane_is_heavy <lane>
fm_heavy_lane_is_heavy() {
  case "$(fm_heavy_lower "$1")" in
    heavy|acceptance|e2e|end-to-end|full-ci|fullci) return 0 ;;
  esac
  return 1
}

# fm_heavy_family_is_heavy <family>
fm_heavy_family_is_heavy() {
  case "$(fm_heavy_lower "$1")" in
    live-harness-optin|real-herdr-gated) return 0 ;;
  esac
  return 1
}

# fm_heavy_selection_is_heavy <selection>
fm_heavy_selection_is_heavy() {
  case "$(fm_heavy_lower "$1")" in
    all|full|full-ci) return 0 ;;
  esac
  return 1
}

# fm_heavy_token_is_heavy <token>
fm_heavy_token_is_heavy() {
  local token
  token=$(fm_heavy_lower "$1")
  [ -n "$token" ] || return 1
  case "$token" in
    acceptance|acceptance.cjs|acceptance.js|e2e|end-to-end|endtoend|full-ci|fullci|playwright|cypress) return 0 ;;
  esac
  return 1
}

# fm_heavy_path_is_heavy <value>
# A file name is heavy when it carries a delimited acceptance/e2e/full-CI token,
# so `foo-e2e.test.sh`, `acceptance.cjs`, and `run-full-ci.sh` classify heavy
# while an unrelated name containing those letters does not.
fm_heavy_path_is_heavy() {
  local value base
  value=$(fm_heavy_lower "$1")
  base=${value##*/}
  [ -n "$base" ] || return 1
  case "$base" in
    *acceptance*) return 0 ;;
    *e2e*) return 0 ;;
    *end-to-end*|*end_to_end*) return 0 ;;
    *full-ci*|*full_ci*|*fullci*) return 0 ;;
    *playwright*|*cypress*) return 0 ;;
  esac
  return 1
}

# fm_heavy_refuse <detail> - print the refusal and exit 3.
fm_heavy_refuse() {
  local detail=$1 runner
  runner=$(fm_heavy_runner)
  if [ -n "$runner" ]; then
    printf 'refused: heavy work (%s) runs on the GCP campaign VM, not this host (config/%s=remote-only); use the campaign runner: %s\n' \
      "$detail" "$FM_HEAVY_POSTURE_FILE" "$runner" >&2
  else
    printf 'refused: heavy work (%s) runs on the GCP campaign VM, not this host (config/%s=remote-only); configure config/%s to name that runner\n' \
      "$detail" "$FM_HEAVY_POSTURE_FILE" "$FM_HEAVY_RUNNER_FILE" >&2
  fi
  exit 3
}

cmd_status() {
  local posture
  posture=$(fm_heavy_posture) || exit $?
  printf 'posture=%s\n' "$posture"
  printf 'runner=%s\n' "$(fm_heavy_runner)"
  printf 'heavy-lanes=heavy,acceptance,e2e,end-to-end,full-ci\n'
  printf 'heavy-families=live-harness-optin,real-herdr-gated\n'
  printf 'heavy-selections=all,full,full-ci\n'
}

cmd_check() {
  local posture lane='' family='' selection='' token='' path='' detail='' heavy=0
  posture=$(fm_heavy_posture) || exit $?
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lane) [ "$#" -gt 1 ] || die "--lane requires a value"; lane=$2; shift 2 ;;
      --lane=*) lane=${1#--lane=}; shift ;;
      --family) [ "$#" -gt 1 ] || die "--family requires a value"; family=$2; shift 2 ;;
      --family=*) family=${1#--family=}; shift ;;
      --selection) [ "$#" -gt 1 ] || die "--selection requires a value"; selection=$2; shift 2 ;;
      --selection=*) selection=${1#--selection=}; shift ;;
      --token) [ "$#" -gt 1 ] || die "--token requires a value"; token=$2; shift 2 ;;
      --token=*) token=${1#--token=}; shift ;;
      --path) [ "$#" -gt 1 ] || die "--path requires a value"; path=$2; shift 2 ;;
      --path=*) path=${1#--path=}; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown check argument: $1" ;;
    esac
    if [ -n "$lane" ] && fm_heavy_lane_is_heavy "$lane"; then
      heavy=1; detail="lane $lane"
    fi
    if [ -n "$family" ] && fm_heavy_family_is_heavy "$family"; then
      heavy=1; detail="family $family"
    fi
    if [ -n "$selection" ] && fm_heavy_selection_is_heavy "$selection"; then
      heavy=1; detail="selection $selection"
    fi
    if [ -n "$token" ] && fm_heavy_token_is_heavy "$token"; then
      heavy=1; detail="token $token"
    fi
    if [ -n "$path" ] && fm_heavy_path_is_heavy "$path"; then
      heavy=1; detail="suite ${path##*/}"
    fi
  done

  if [ "$heavy" = 1 ] && [ "$posture" = remote-only ]; then
    fm_heavy_refuse "$detail"
  fi
  printf 'allowed: %s\n' "${detail:-no heavy classification}"
  return 0
}

main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  local sub=$1
  shift
  case "$sub" in
    status) cmd_status "$@" ;;
    check) cmd_check "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
