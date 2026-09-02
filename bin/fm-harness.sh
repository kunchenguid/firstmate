#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|opencode|pi|pi-signed|prime-agent|grok|kimi|cursor|muse|unknown
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
    base=$(basename -- "$comm")
    base=${base#-}
    case "$base" in
      claude) echo claude; return ;;
      codex) echo codex; return ;;
      opencode) echo opencode; return ;;
      prime-agent) echo prime-agent; return ;;
      grok) echo grok; return ;;
      kimi) echo kimi; return ;;
      # muse's installed launcher ~/.local/bin/muse execs ~/.local/bin/muse-bin-<version>
      # (verified in the published launcher, muse 0.1.0-R708.1), so the live process
      # name carries the version and CHANGES on every auto-update. Match the stable
      # prefix rather than any exact name. Deliberately anchored, never *muse*, so
      # unrelated commands (musescore, amuse) cannot be misread as this harness.
      muse|muse-bin-*) echo muse; return ;;
      pi-signed) echo pi; return ;;
      pi) echo pi; return ;;
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
    case "$base" in
      node*|python*)
        if [ "${base#node}" != "$base" ] && fm_prime_node_pid_matches "$pid"; then
          echo prime-agent
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
  # Layer 1: unambiguous environment markers for verified harnesses, followed
  # by narrow ancestry disambiguation before any shared marker fallback.
  # Claude, Pi, Grok, and Cursor set verified markers of their own; codex,
  # opencode, Kimi, and Muse are markerless, so a foreign marker retained in a terminal
  # multiplexer's stored environment can silently misidentify one of them before
  # ancestry is consulted. This is a precedence hazard, not evidence that
  # CLAUDECODE inheritance into a kimi child was observed; it was not observed.
  # Cursor is checked BEFORE claude, deliberately. cursor-agent does NOT clear
  # an inherited CLAUDECODE, so a cursor worker launched from a claude primary
  # carries BOTH markers and whichever is tested first wins. Cursor's own
  # markers are unambiguous when present, so ordering them first is what makes
  # the verdict correct; bin/fm-spawn.sh additionally clears the foreign markers
  # at the launch boundary. Both are kept: the launch sanitization only covers
  # sessions fm-spawn started, while this ordering also covers a cursor session
  # a human started by hand. Verified live on cursor-agent 2026.08.11-e8db854:
  # CURSOR_INVOKED_AS=cursor-agent is set on the agent process itself, and
  # CURSOR_AGENT=1 is set for the child/tool processes this script runs as.
  local ancestry
  [ "${CURSOR_AGENT:-}" = "1" ] && { echo cursor; return; }
  [ "${CURSOR_INVOKED_AS:-}" = "cursor-agent" ] && { echo cursor; return; }
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
    [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
    [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
    if [ "${FM_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
    return
  fi
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
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
