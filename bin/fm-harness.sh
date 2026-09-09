#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|opencode|pi|pi-signed|prime-agent|grok|kimi|cursor|gemini|muse|rovo|omp|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate       print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: config/secondmate-harness ->
#                                        config/crew-harness -> own. "default" or absent
#                                        defers to the crew resolution, so an unset
#                                        secondmate-harness behaves exactly as the crew
#                                        harness did before this knob existed.
#        fm-harness.sh secondmate-model    print the optional MODEL token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh secondmate-effort   print the optional EFFORT token from
#                                        config/secondmate-harness, or empty when absent.
# config/secondmate-harness format: a single line "<harness> [<model>] [<effort>]",
# whitespace-separated. A bare "<harness>" (today's format) behaves exactly as before:
# harness only, no model/effort. Only the first non-empty, non-comment line is parsed.
# Model/effort come ONLY from this file - config/crew-harness stays a bare adapter
# name and is never parsed for a model.
# Detection layers: unambiguous environment markers first, narrow ancestry
# disambiguation for shared markers, then the remaining markers and ancestry.
# Record each newly verified identity signal here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"
# shellcheck source=bin/fm-gemini-lib.sh
. "$SCRIPT_DIR/fm-gemini-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-prime-lib.sh
. "$SCRIPT_DIR/fm-prime-lib.sh"

detect_ancestry() {
  local strength=${1:-loose} pid=$$ comm args argv0 base name
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    argv0=$(fm_cursor_argv0_for_pid "$pid" "$comm" 2>/dev/null || true)
    if fm_cursor_process_matches "$comm" '' "$argv0"; then
      echo cursor
      return
    fi
    if fm_gemini_path_is_gemini "$comm"; then
      echo gemini
      return
    fi
    base=$(basename -- "$comm")
    base=${base#-}
    case "$base" in
      *claude*) echo claude; return ;;
      *codex*) echo codex; return ;;
      *opencode*) echo opencode; return ;;
      prime-agent) echo prime-agent; return ;;
      *grok*) echo grok; return ;;
      kimi) echo kimi; return ;;
      rovo) echo rovo; return ;;
      muse|muse-bin-*) echo muse; return ;;
      pi-signed) echo pi; return ;;
      pi) echo pi; return ;;
      omp) echo omp; return ;;
    esac
    if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
      case "$name" in
        pi-signed) echo pi ;;
        *) echo "$name" ;;
      esac
      return
    fi
    if [ "$strength" != strong ]; then
      case "$base" in
        *claude*) echo claude; return ;;
        *codex*) echo codex; return ;;
        *opencode*) echo opencode; return ;;
        *grok*) echo grok; return ;;
      esac
    fi
    if fm_prime_node_pid_matches "$pid"; then
      echo prime-agent
      return
    fi
    case "$base" in
      node*|python*)
        if fm_gemini_args_are_gemini "$(ps -o args= -p "$pid" 2>/dev/null)"; then
          echo gemini
          return
        fi
        if [ "$strength" != strong ]; then
          args=$(ps -o args= -p "$pid" 2>/dev/null)
          case "$args" in
            *claude*) echo claude; return ;;
            *codex*) echo codex; return ;;
            *opencode*) echo opencode; return ;;
            *grok*) echo grok; return ;;
            *" pi "*|*/pi) echo pi; return ;;
          esac
        fi
        ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  echo unknown
}

detect_own() {
  local ancestry
  [ "${CURSOR_AGENT:-}" = "1" ] && { echo cursor; return; }
  [ "${CURSOR_INVOKED_AS:-}" = "cursor-agent" ] && { echo cursor; return; }
  [ "${GEMINI_CLI:-}" = "1" ] && { echo gemini; return; }
  [ "${ATLASSIAN_AGENT_TYPE:-}" = "rovo" ] && { echo rovo; return; }
  [ "${ROVODEV_CLI:-}" = "1" ] && { echo rovo; return; }
  if [ "${FM_OMP_HARNESS:-}" = omp ] && [ "$(detect_ancestry strong)" = omp ]; then
    echo omp
    return
  fi
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  if [ "${PI_CODING_AGENT:-}" = "true" ]; then
    ancestry=$(detect_ancestry strong)
    if [ "$ancestry" != unknown ]; then
      if [ "$ancestry" = pi ] && [ "${FM_PI_HARNESS:-}" = pi-signed ]; then
        echo pi-signed
      else
        echo "$ancestry"
      fi
      return
    fi
    [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
    if [ "${FM_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
    return
  fi
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  detect_ancestry
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# Print the first non-empty, non-comment line of config/secondmate-harness
# (leading/trailing whitespace trimmed), or nothing when the file is absent or
# holds only blank/comment lines.
secondmate_line() {
  local line
  [ -f "$CONFIG/secondmate-harness" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$CONFIG/secondmate-harness"
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved secondmate_line, or nothing if the line or that field is absent.
secondmate_field() {
  local idx=$1 line
  line=$(secondmate_line)
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain config/secondmate-harness -> config/crew-harness -> own. An absent or
# "default" secondmate-harness token defers to the crew resolution, so an unset
# secondmate-harness behaves exactly as before this knob existed (a secondmate
# launched on the crew harness). config/secondmate-harness is the PRIMARY's own
# setting and is never inherited downstream - secondmates do not spawn secondmates.
resolve_secondmate() {
  local sm
  sm=$(secondmate_field 1)
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then resolve_crew; else echo "$sm"; fi
}

# Print the optional model token (2nd field) from config/secondmate-harness, or
# empty when the harness token is absent/"default" (harness-only file, same as
# today) or when no model token is present.
resolve_secondmate_model() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2
}

# Print the optional effort token (3rd field) from config/secondmate-harness,
# the same way.
resolve_secondmate_effort() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3
}

case "${1:-}" in
  crew) resolve_crew ;;
  secondmate) resolve_secondmate ;;
  secondmate-model) resolve_secondmate_model ;;
  secondmate-effort) resolve_secondmate_effort ;;
  *) detect_own ;;
esac