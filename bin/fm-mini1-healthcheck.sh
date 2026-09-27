#!/usr/bin/env bash
# Health check for mini1 firstmate satellite home.
#
# Usage:
#   bin/fm-mini1-healthcheck.sh [--fix]
#
# Verifies that mini1's dev environment has all required tools, stores, and
# credentials. Reports one fact per line in a stable format; exit code 0 only
# when all gating checks pass.
#
# Line protocol:
#   tool <name>=<path>|MISSING
#   store <name>=ok|UNREACHABLE
#   credential <name>=present|MISSING
#   disk <mount>=<used>/<total>|<% used>
#   check <name>=ok|fixable|human|info
#   action: <check>: <step to take>
#   error: <message> (stderr only)
#   ok: all checks passed (success only)
set -eu

SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)}"

case "${1:-}" in
  '') ;;
  # --fix is accepted for compatibility; this check reports actionable `action:`
  # lines rather than mutating the machine, so the flag selects no behavior.
  --fix) shift ;;
  *) { printf 'Usage: %s [--fix]\n' "$0" >&2; exit 2; }
esac
[ "$#" -eq 0 ] || { printf 'Usage: %s [--fix]\n' "$0" >&2; exit 2; }

CHECKS=()
ACTIONS=()
GAPS=()
PLATFORM=$(uname -s)

record_check() { # <name> <status>
  CHECKS+=("$1=$2")
}

record_action() { # <check> <action>
  ACTIONS+=("$1: $2")
}

# --- tools -----------------------------------------------------------------

check_tool() { # <name>
  if resolved=$(command -v "$1" 2>/dev/null) && [ -x "$resolved" ]; then
    printf 'tool %s=%s\n' "$1" "$resolved"
    return 0
  else
    printf 'tool %s=MISSING\n' "$1"
    return 1
  fi
}

# --- stores and credentials ------------------------------------------------

check_beads_store() {
  local store="${HOME:-}/data/tasks/.beads"
  if [ ! -d "$store" ]; then
    printf 'store beads=UNREACHABLE (no .beads directory)\n'
    return 1
  fi
  if ! command -v task >/dev/null 2>&1 && ! command -v bd >/dev/null 2>&1; then
    printf 'store beads=UNREACHABLE (no task or bd CLI)\n'
    return 1
  fi
  if task list >/dev/null 2>&1; then
    printf 'store beads=ok\n'
    return 0
  else
    printf 'store beads=UNREACHABLE (task list failed)\n'
    return 1
  fi
}

check_claude_credential() {
  if [ -f "${HOME:-}/.claude/.credentials.json" ]; then
    printf 'credential claude=present\n'
    return 0
  else
    printf 'credential claude=MISSING\n'
    return 1
  fi
}

check_gh_auth() {
  if gh auth status >/dev/null 2>&1; then
    local status
    status=$(gh auth status 2>&1 || true)
    printf 'credential gh=present (%s)\n' "$(echo "$status" | head -1)"
    return 0
  else
    printf 'credential gh=MISSING\n'
    return 1
  fi
}

# --- disk space -----------------------------------------------------------

check_disk() {
  local home="${HOME:-~}" used total percent line
  if ! line=$(df -h "$home" 2>/dev/null | tail -1); then
    printf 'disk %s=UNKNOWN\n' "$home"
    return 1
  fi
  used=$(printf '%s' "$line" | awk '{print $3}')
  total=$(printf '%s' "$line" | awk '{print $2}')
  percent=$(printf '%s' "$line" | awk '{print $5}')
  printf 'disk %s=%s/%s (%s)\n' "$home" "$used" "$total" "$percent"
  # Warn if >85%
  percent_num=${percent%%%}
  [ "$percent_num" -lt 85 ] && return 0
  record_check disk-space "fixable: over 85% full"
  record_action disk-space "clean up or expand storage; current usage is $used/$total ($percent)"
  return 1
}

# --- required tools --------------------------------------------------------

check_required_tools() {
  local missing=() tool
  local required_tools=(git jq herdr tasks-axi)
  local harness_tools=(claude codex herdr pi opencode grok kimi)

  for tool in "${required_tools[@]}"; do
    check_tool "$tool" || missing+=("$tool")
  done

  # At least one harness required
  local found_harness=0
  for tool in "${harness_tools[@]}"; do
    if check_tool "$tool" >/dev/null 2>&1; then
      found_harness=1
      break
    fi
  done
  [ "$found_harness" -eq 1 ] || missing+=(harness)

  [ "${#missing[@]}" -eq 0 ] && return 0
  GAPS+=("missing-tools: ${missing[*]}")
  return 1
}

# --- optional tools and extras ------------------------------------------

check_optional_tools() {
  local optional=(tmux no-mistakes npm)
  for tool in "${optional[@]}"; do
    check_tool "$tool" || true
  done
}

check_juggle() {
  local juggle_repo="${HOME:-}/code/juggle" juggle_bin="${HOME:-}/.local/bin/juggle"
  if [ -d "$juggle_repo" ]; then
    printf 'repo juggle=%s\n' "$juggle_repo"
  else
    printf 'repo juggle=MISSING\n'
  fi
  if [ -x "$juggle_bin" ]; then
    printf 'tool juggle=%s\n' "$juggle_bin"
  elif command -v juggle >/dev/null 2>&1; then
    printf 'tool juggle=%s\n' "$(command -v juggle)"
  else
    printf 'tool juggle=MISSING\n'
  fi
}

# --- credential checks ------------------------------------------------

check_credentials() {
  local missing=()
  check_claude_credential || missing+=(claude)
  check_gh_auth || missing+=(gh)
  check_beads_store || missing+=(beads)
  [ "${#missing[@]}" -eq 0 ] && return 0
  record_check credentials "fixable: missing ${missing[*]}"
  record_action credentials "see Firstmate docs/remote-secondmates.md for setup guidance"
  GAPS+=("missing-credentials: ${missing[*]}")
  return 1
}

# --- aggregate results --------------------------------------------------

report_results() {
  printf '\n=== SUMMARY ===\n' >&2

  if [ "${#CHECKS[@]}" -gt 0 ]; then
    for check in "${CHECKS[@]}"; do
      printf 'check %s\n' "$check"
    done
  fi

  if [ "${#ACTIONS[@]}" -gt 0 ]; then
    printf '\n=== ACTIONS NEEDED ===\n' >&2
    for action in "${ACTIONS[@]}"; do
      printf 'action: %s\n' "$action" >&2
    done
  fi

  if [ "${#GAPS[@]}" -gt 0 ]; then
    printf '\nerror: health check found %d blocker(s)\n' "${#GAPS[@]}" >&2
    for gap in "${GAPS[@]}"; do
      printf 'error:   %s\n' "$gap" >&2
    done
    return 1
  fi

  printf '\nok: mini1 firstmate health check passed\n'
  return 0
}

# --- main ---------------------------------------------------------------

printf '=== Mini1 Firstmate Health Check ===\n' >&2
printf 'platform=%s\n' "$PLATFORM"
printf 'home=%s\n' "${FM_HOME:-${FM_ROOT}}"

# Required checks
check_required_tools || true
check_credentials || true
check_disk || true

# Optional and extras
check_optional_tools || true
check_juggle || true

# Report
report_results
