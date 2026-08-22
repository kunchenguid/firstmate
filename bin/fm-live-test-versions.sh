#!/usr/bin/env bash
# fm-live-test-versions.sh - record and detect version changes of tools the
# nine fleet-relevant live-harness-optin tests depend on.
#
# The nine tests guard this fleet's ASSUMPTIONS about someone else's code:
# agy, claude, herdr, and other harnesses all update themselves with no commit
# in this repository. A test that passed yesterday can fail today with nothing
# in between, so the fleet needs to know when a tool changed.
#
# This script records each tool's installed version in a baseline file and
# prints a diagnostic when any version differs from the baseline. On first
# run (no baseline file), it records the current versions and is silent.
#
# Usage: fm-live-test-versions.sh check [--state-dir <dir>]
#          Compare installed versions against the recorded baseline.
#          Prints one LIVE_TEST_VERSIONS_CHANGED: line per changed tool,
#          a BOOTSTRAP_INFO: line when no versions changed, or records
#          the initial baseline silently.
#          Exit 0 always - this is a detector, not a gate.
#        fm-live-test-versions.sh show [--state-dir <dir>]
#          Print the current baseline file, or "no baseline" if absent.
#        fm-live-test-versions.sh record [--state-dir <dir>]
#          Force-record the current versions as the new baseline.
#
# The TOOLS list is derived from the nine test files (not guessed from names):
#   fm-agy-model-switch-live-e2e:           agy, herdr
#   fm-claude-stop-autoarm-live-e2e:        claude
#   fm-harness-liveness-drift-live-e2e:     claude, codex, opencode, pi, grok, kimi, cursor, muse, tmux
#   fm-submit-latency-live-e2e:             agy, claude, codex, opencode, pi, grok, kimi, muse, herdr
#   fm-quota-array-dispatch-live-e2e:       pi
#   fm-herdr-version-floor-live-e2e:        herdr
#   fm-composer-matrix-live-e2e:            claude, codex, opencode, pi, grok, kimi, muse, zellij, tmux
#   fm-sessionstart-hook-live-e2e:          claude, codex, pi, tmux
#   fm-sessionstart-instruction-refresh:    pi, tmux
#
# Tools like jq, git, curl, shasum, and python3 are stable system tools whose
# updates do not invalidate harness-behavior assumptions; they are excluded.
#
# STATE: state/.live-test-versions (gitignored with the rest of state/).
#   Format: one "tool=version" line per tool, sorted. "unknown" for tools
#   that are absent or whose --version output is unparseable.
#   An unknown version is NOT treated as changed from a previous unknown -
#   the tool is simply not installed, and that is stable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# The tools the nine fleet-relevant live tests depend on, sorted. Derived from
# reading each test file's command -v checks and direct invocations, then
# excluding stable system tools (jq, git, curl, shasum, python3, od, awk, tee).
LIVE_TEST_TOOLS="agy claude codex cursor grok herdr kimi muse opencode pi tmux zellij"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-live-test-versions.sh" | sed 's/^# \{0,1\}//; $d'
}

# Read the installed version of a tool. Prints the version string on stdout,
# or "unknown" if the tool is absent or its output is unparseable. Uses the
# same parse rules as fm-bootstrap.sh's tool_installed_version: extract the
# first major.minor.patch triple from --version output.
tool_version() {  # <tool>
  local tool=$1 output parts major minor patch extra
  command -v "$tool" >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  output=$("$tool" --version 2>/dev/null) || { printf 'unknown\n'; return 0; }
  parts=$(printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  if [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ]; then
    printf '%s\n' "$major.$minor.$patch"
  else
    # The tool responded but the output is not a parseable triple. Record the
    # raw first line so a version change is still detectable even when the
    # format does not match the semver pattern.
    local raw
    raw=$(printf '%s\n' "$output" | head -1 | tr -d '\r')
    if [ -n "$raw" ]; then
      printf '%s\n' "$raw"
    else
      printf 'unknown\n'
    fi
  fi
}

# Snapshot all tool versions into a sorted key=value block on stdout.
snapshot_versions() {
  local t ver
  for t in $LIVE_TEST_TOOLS; do
    ver=$(tool_version "$t")
    printf '%s=%s\n' "$t" "$ver"
  done
}

cmd_check() {
  local state_dir="${1:-$FM_HOME/state}"
  local baseline="$state_dir/.live-test-versions"
  local current changed_tools tool cur_ver base_ver

  current=$(snapshot_versions)

  if [ ! -f "$baseline" ]; then
    # First run: record the baseline. No diagnostic - the fleet has no prior
    # expectation to compare against.
    if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
      mkdir -p "$state_dir" 2>/dev/null || true
      printf '%s\n' "$current" > "$baseline"
    fi
    return 0
  fi

  # Compare each tool's current version against the baseline.
  changed_tools=""
  for tool in $LIVE_TEST_TOOLS; do
    cur_ver=$(printf '%s\n' "$current" | sed -n "s/^${tool}=//p")
    base_ver=$(sed -n "s/^${tool}=//p" "$baseline" 2>/dev/null)

    # An unknown version is stable: if both are unknown, nothing changed.
    # If the baseline has no entry for this tool (e.g. the tool list grew),
    # treat the current version as new baseline and skip it.
    if [ -z "$base_ver" ]; then
      continue
    fi
    if [ "$cur_ver" != "$base_ver" ]; then
      if [ -n "$changed_tools" ]; then
        changed_tools="$changed_tools, $tool ($base_ver -> $cur_ver)"
      else
        changed_tools="$tool ($base_ver -> $cur_ver)"
      fi
    fi
  done

  if [ -n "$changed_tools" ]; then
    echo "LIVE_TEST_VERSIONS_CHANGED: $changed_tools"
    # Update the baseline so the next session does not re-trigger for the
    # same versions. The agent sees this diagnostic once and runs the nine.
    if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
      printf '%s\n' "$current" > "$baseline"
    fi
  fi
}

cmd_show() {
  local state_dir="${1:-$FM_HOME/state}"
  local baseline="$state_dir/.live-test-versions"
  if [ -f "$baseline" ]; then
    cat "$baseline"
  else
    echo "no baseline"
  fi
}

cmd_record() {
  local state_dir="${1:-$FM_HOME/state}"
  local baseline="$state_dir/.live-test-versions"
  mkdir -p "$state_dir" 2>/dev/null || true
  snapshot_versions > "$baseline"
  echo "recorded"
}

# --- main -------------------------------------------------------------------

state_dir=""
case "${1:-}" in
  check|show|record) cmd=$1; shift ;;
  --help|-h) usage; exit 0 ;;
  '') cmd=check ;;
  *) echo "unknown command: $1" >&2; usage >&2; exit 1 ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state-dir) state_dir=$2; shift 2 ;;
    --state-dir=*) state_dir=${1#--state-dir=}; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

case "$cmd" in
  check) cmd_check "${state_dir:-}" ;;
  show) cmd_show "${state_dir:-}" ;;
  record) cmd_record "${state_dir:-}" ;;
esac
exit 0
