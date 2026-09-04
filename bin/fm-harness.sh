#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|copilot|opencode|pi|pi-signed|grok|kimi|cursor|gemini|muse|unknown
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
# Detection prefers the nearest verified process ancestry, then verified
# environment markers as fallbacks.
# Record each newly verified env marker and ancestry shape here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-gemini-lib.sh
. "$SCRIPT_DIR/fm-gemini-lib.sh"

detect_own() {
  local pid=$$ comm args ancestry=''
  # Prefer the nearest actual harness process in ancestry before consulting any
  # inherited marker. This keeps a real Claude session authoritative inside a
  # Copilot shell and a real Copilot process authoritative under inherited
  # Cursor or Claude markers, while preserving the verified marker fallbacks
  # when ancestry cannot prove the host.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null) || args=
    args=${args#"${args%%[![:space:]]*}"}
    if ancestry=$(fm_harness_process_name "$comm" "$args" 2>/dev/null); then
      break
    fi
    if fm_gemini_pid_is_gemini "$pid" 2>/dev/null; then
      ancestry=gemini
      break
    fi
    case "$(basename -- "$comm")" in
      muse|muse-bin-*) ancestry=muse; break ;;
      node*|python*|MainThread)
        if fm_gemini_args_are_gemini "$args"; then
          ancestry=gemini
          break
        fi
        ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|*[!0-9]*) break ;; esac
    if [ "$pid" -le 1 ]; then
      break
    fi
  done
  if [ -n "$ancestry" ]; then
    if [ "$ancestry" = pi ] && [ "${PI_CODING_AGENT:-}" = "true" ] \
       && [ "${FM_PI_HARNESS:-}" = pi-signed ]; then
      echo pi-signed
    else
      echo "$ancestry"
    fi
    return
  fi

  [ "${COPILOT_CLI:-}" = "1" ] && { echo copilot; return; }
  [ "${CURSOR_AGENT:-}" = "1" ] && { echo cursor; return; }
  [ "${CURSOR_INVOKED_AS:-}" = "cursor-agent" ] && { echo cursor; return; }
  # Gemini is checked BEFORE claude for exactly cursor's reason above: the
  # Gemini CLI does NOT clear an inherited CLAUDECODE, so a gemini worker
  # launched from a claude primary carries BOTH markers and whichever is
  # tested first wins. Verified live on gemini-cli 0.58.0: a tool process
  # spawned by a gemini worker under a claude primary reported GEMINI_CLI=1
  # AND CLAUDECODE=1 together. GEMINI_CLI is gemini's own and is unset in the
  # launching environment, so ordering it first is what makes the verdict
  # correct; bin/fm-spawn.sh additionally clears the foreign markers at the
  # launch boundary. Both are kept for the same reason cursor keeps both.
  # AI_AGENT is deliberately NOT used: it was present in that same process
  # carrying the claude primary's value (claude-code_2-1-260_agent), so it is
  # an inherited launcher marker, not a Gemini identity.
  [ "${GEMINI_CLI:-}" = "1" ] && { echo gemini; return; }
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  if [ "${PI_CODING_AGENT:-}" = "true" ]; then
    if [ "${FM_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
    return
  fi
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # muse (Muse Code) publishes no verified child-process identity marker, so it
  # is detected by ancestry alone above rather than by any inherited MUSE_* env.
  echo unknown
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
