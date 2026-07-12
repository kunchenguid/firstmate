#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|opencode|pi|grok|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate [<id>]   print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: config/secondmate-harness ->
#                                        config/crew-harness -> own. "default" or absent
#                                        defers to the crew resolution, so an unset
#                                        secondmate-harness behaves exactly as the crew
#                                        harness did before this knob existed.
#        fm-harness.sh secondmate-model [<id>]   print the optional MODEL token, or empty.
#        fm-harness.sh secondmate-effort [<id>]  print the optional EFFORT token, or empty.
#        fm-harness.sh secondmate-fast [<id>]    print "fast" when Codex fast-mode intent
#                                        is set, else empty.
# config/secondmate-harness format: a single line "<harness> [<model>] [<effort>] [fast]",
# whitespace-separated. A bare "<harness>" (today's format) behaves exactly as before:
# harness only, no model/effort/fast. Only the first non-empty, non-comment line is parsed.
# A standalone "fast" keyword may appear after the harness token in any position; it marks
# Codex fast-mode intent (applied by fm-spawn as `-c service_tier="fast"`) and is removed
# before the remaining tokens are assigned positionally to harness/model/effort.
# Model/effort/fast come ONLY from these files - config/crew-harness stays a bare adapter
# name and is never parsed for a model.
#
# Per-secondmate override: an optional file config/secondmate-harness.d/<id> holds the SAME
# one-line format for a single secondmate id, overriding the global config/secondmate-harness
# for that id only. When the <id> argument is passed and a SAFE per-id override file exists,
# it is parsed instead of the global file; otherwise resolution falls back to the global file
# exactly as before, so homes with no per-id override are fully backward-compatible. The id
# must be a plain slug ([A-Za-z0-9] then [A-Za-z0-9._-]*), the .d directory must be a real
# directory (not a symlink), and the per-id file must be a regular file (not a symlink), so a
# malformed id or an unsafe/symlinked path fails safe by falling back to the global file
# rather than launching an unintended harness.
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

detect_own() {
  # Layer 1: environment markers for verified harnesses.
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  [ "${PI_CODING_AGENT:-}" = "true" ] && { echo pi; return; }
  # grok sets GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
  # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so this marker
  # is unambiguous when firstmate runs natively on grok.
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # Layer 2: walk the parent chain and match the command name.
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    case "$(basename "$comm")" in
      *claude*) echo claude; return ;;
      *codex*) echo codex; return ;;
      *opencode*) echo opencode; return ;;
      *grok*) echo grok; return ;;
      pi) echo pi; return ;;
      node*|python*)
        # Bare interpreter: match the harness name in its script path.
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$args" in
          *claude*) echo claude; return ;;
          *codex*) echo codex; return ;;
          *opencode*) echo opencode; return ;;
          *grok*) echo grok; return ;;
          *" pi "*|*/pi) echo pi; return ;;
        esac ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  echo unknown
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# A safe per-secondmate id: a plain slug that cannot escape the .d directory.
# Rejects empty, leading dot, and any path metacharacter (so "..", "/", etc. fail).
valid_secondmate_id() {
  case "$1" in
    '' | .*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# A per-id profile must contain exactly one non-empty, non-comment line with one
# to three positional fields and at most one standalone fast keyword.
valid_secondmate_profile() {
  local f=$1 line tok fields=0 fast_count=0 found=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    [ "$found" -eq 0 ] || return 1
    found=1
    # shellcheck disable=SC2086  # deliberate word-splitting: validating profile fields
    set -- $line
    for tok in "$@"; do
      if [ "$tok" = fast ]; then
        fast_count=$((fast_count + 1))
        [ "$fast_count" -le 1 ] || return 1
      else
        fields=$((fields + 1))
        [ "$fields" -le 3 ] || return 1
      fi
    done
  done < "$f"
  [ "$found" -eq 1 ] && [ "$fields" -ge 1 ]
}

# Resolve the config file to parse for a secondmate line. With no id, or when the
# id has no SAFE per-id override, this is the global config/secondmate-harness.
# With an id whose override file exists and passes the safety checks (valid id, a
# real .d directory, a regular non-symlink file), it is config/secondmate-harness.d/<id>.
# Prints the chosen path, or nothing when no readable source exists.
secondmate_source() {
  local id=${1:-} d f
  if [ -n "$id" ] && valid_secondmate_id "$id"; then
    d="$CONFIG/secondmate-harness.d"
    f="$d/$id"
    # Reject a symlinked .d directory or a symlinked/non-regular per-id file, so an
    # unsafe path falls back to the global file rather than being followed.
    if [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$f" ] && [ ! -L "$f" ] \
      && valid_secondmate_profile "$f"; then
      printf '%s\n' "$f"
      return 0
    fi
  fi
  [ -f "$CONFIG/secondmate-harness" ] && printf '%s\n' "$CONFIG/secondmate-harness"
}

# Print the first non-empty, non-comment line of the resolved secondmate source
# (leading/trailing whitespace trimmed), or nothing when the source is absent or
# holds only blank/comment lines. An optional id selects a per-id override.
secondmate_line() {
  local id=${1:-} src line
  src=$(secondmate_source "$id")
  [ -n "$src" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$src"
}

# Print a field of the resolved secondmate_line for an optional id. The standalone
# "fast" keyword is pulled out first (idx "fast" returns it, or empty); the
# remaining tokens are assigned positionally (1=harness, 2=model, 3=effort). A
# missing line or field prints nothing.
secondmate_field() {
  local idx=$1 id=${2:-} line tok n=0
  local fast='' rest_h='' rest_m='' rest_e=''
  line=$(secondmate_line "$id")
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  for tok in "$@"; do
    if [ "$tok" = fast ]; then
      fast=fast
      continue
    fi
    n=$((n + 1))
    case "$n" in
      1) rest_h=$tok ;;
      2) rest_m=$tok ;;
      3) rest_e=$tok ;;
    esac
  done
  case "$idx" in
    1) printf '%s\n' "$rest_h" ;;
    2) printf '%s\n' "$rest_m" ;;
    3) printf '%s\n' "$rest_e" ;;
    fast) printf '%s\n' "$fast" ;;
  esac
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain config/secondmate-harness -> config/crew-harness -> own. An absent or
# "default" secondmate-harness token defers to the crew resolution, so an unset
# secondmate-harness behaves exactly as before this knob existed (a secondmate
# launched on the crew harness). config/secondmate-harness is the PRIMARY's own
# setting and is never inherited downstream - secondmates do not spawn secondmates.
resolve_secondmate() {
  local id=${1:-} sm
  sm=$(secondmate_field 1 "$id")
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then resolve_crew; else echo "$sm"; fi
}

# Print the optional model token (2nd field) from the resolved secondmate source,
# or empty when the harness token is absent/"default" (harness-only file, same as
# today) or when no model token is present. An optional id selects a per-id override.
resolve_secondmate_model() {
  local id=${1:-} sm
  sm=$(secondmate_field 1 "$id")
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2 "$id"
}

# Print the optional effort token (3rd field), the same way.
resolve_secondmate_effort() {
  local id=${1:-} sm
  sm=$(secondmate_field 1 "$id")
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3 "$id"
}

# Print "fast" when the resolved secondmate source carries the fast keyword and a
# concrete harness (not absent/"default"), else empty - so the flag is read only
# when the file actually supplies the launch harness, exactly like model/effort.
resolve_secondmate_fast() {
  local id=${1:-} sm
  sm=$(secondmate_field 1 "$id")
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field fast "$id"
}

case "${1:-}" in
  crew) resolve_crew ;;
  secondmate) resolve_secondmate "${2:-}" ;;
  secondmate-model) resolve_secondmate_model "${2:-}" ;;
  secondmate-effort) resolve_secondmate_effort "${2:-}" ;;
  secondmate-fast) resolve_secondmate_fast "${2:-}" ;;
  *) detect_own ;;
esac
