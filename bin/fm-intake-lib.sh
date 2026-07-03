#!/usr/bin/env bash
# fm-intake-lib.sh - the Wardroom's append-only intake channel.
# Spec: docs/specs/2026-07-03-wardroom-intake.md.
#
# state/<id>.intake holds one line per event: `<kind>: <text>` with kind in
# proceed|revise|escalate|panel. proceed/revise/escalate are DECISIONS
# (fm-intake's outcome); panel lines are evidence (lens + thinker traces).
# The gate consumed by fm-spawn is fm_intake_require_proceed: the LAST decision
# line must be proceed. FM_INTAKE_OVERRIDE=1 is the captain's explicit bypass
# and prints a loud banner so it never happens silently.
#
# Deliberately mirrors fm-verdict-lib.sh (spec: Deliberate decisions) - two
# small channels with different grammars beat a premature generic abstraction.
# Source this; do not execute it.

fm_intake_file() {  # <state-dir> <id>
  printf '%s/%s.intake\n' "$1" "$2"
}

fm_intake_append() {  # <state-dir> <id> <kind> <text>
  local kind=$3
  case "$kind" in
    proceed|revise|escalate|panel) : ;;
    *) echo "error: invalid intake kind '$kind' (proceed|revise|escalate|panel)" >&2; return 1 ;;
  esac
  printf '%s: %s\n' "$kind" "$4" >> "$(fm_intake_file "$1" "$2")"
}

fm_intake_last() {  # <state-dir> <id> -> kind of last decision line
  local f line
  f=$(fm_intake_file "$1" "$2")
  [ -f "$f" ] || return 1
  line=$(grep -E '^(proceed|revise|escalate):' "$f" | tail -1)
  [ -n "$line" ] || return 1
  printf '%s\n' "${line%%:*}"
}

fm_intake_revise_count() {  # <state-dir> <id>
  local f
  f=$(fm_intake_file "$1" "$2")
  [ -f "$f" ] || { echo 0; return 0; }
  grep -c '^revise:' "$f" || true
}

fm_intake_require_proceed() {  # <state-dir> <id> <label>
  local last
  if [ "${FM_INTAKE_OVERRIDE:-}" = 1 ]; then
    {
      echo "==================== WARDROOM OVERRIDE ===================="
      echo "WARNING: $3 spawning task $2 WITHOUT an intake proceed"
      echo "(FM_INTAKE_OVERRIDE=1 - captain authority; logged, not silent)"
      echo "==========================================================="
    } >&2
    return 0
  fi
  last=$(fm_intake_last "$1" "$2" 2>/dev/null) || last=none
  if [ "$last" != proceed ]; then
    {
      echo "======================== WARDROOM ========================="
      echo "REFUSED: $3 for task $2 - no intake proceed (last intake: $last)"
      echo "Run: bin/fm-intake.sh $2 <project-dir>"
      echo "Captain bypass (loud, logged): FM_INTAKE_OVERRIDE=1"
      echo "==========================================================="
    } >&2
    return 1
  fi
  return 0
}
