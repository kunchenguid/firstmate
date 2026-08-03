# shellcheck shell=bash
# Shared reader for a persistent secondmate's COMMAND STATE - the durable answer
# to "who commands this lane right now, the main firstmate or the captain".
# Usage: . bin/fm-secondmate-command-lib.sh   (no side effects on source)
#
# Ownership: the AUTHORITY is the optional trailing `command:` field on the
# lane's `data/secondmates.md` registry line in the PRIMARY home. That file is
# the durable private record of the primary's direct reports, it is the same
# read that already resolves `home:`, `scope:`, and `label:`, and it lives in a
# home the lane itself cannot write - so a lane can never take itself out of
# firstmate command. state/ is deliberately NOT the owner: it is the volatile
# runtime tier, state/<id>.meta is rewritten by every fm-spawn relaunch, and a
# recovery respawn silently resetting command state is exactly the ambiguity the
# transfer procedure exists to remove.
#
# The seeded home's data/command.md is a DERIVED, primary-authoritative copy that
# tells the lane itself which state it is in (the same main-authoritative pattern
# data/captain-shared.md uses). The registry always wins; a divergence is a
# stop-and-report result, never something a reader resolves on its own.
#
# The complete two-way transfer procedure is owned by the
# secondmate-command-transfer skill, and its mechanics by
# bin/fm-secondmate-command.sh. This library only READS, so the watcher, the
# away-mode daemon, session start, and the steering/retirement guards can all ask
# the same question without duplicating the parser.

# The value a registry line with no `command:` field carries. Absence is the
# normal state for every lane seeded before command transfer existed, so it must
# mean ordinary firstmate command rather than "unknown".
FM_SECONDMATE_COMMAND_DEFAULT=firstmate

# Path of the derived per-home marker, relative to the secondmate home root.
FM_SECONDMATE_COMMAND_MARKER_REL=data/command.md

# Resolve the primary home's registry path. FM_SECONDMATE_COMMAND_REGISTRY wins
# (tests and callers that already hold the path), then FM_DATA_OVERRIDE, then
# FM_HOME. Prints nothing and returns 1 when none of those resolve, so a caller
# with no home context reads as "nothing is captain-commanded" instead of
# guessing a path.
fm_secondmate_command_registry_path() {
  if [ -n "${FM_SECONDMATE_COMMAND_REGISTRY:-}" ]; then
    printf '%s' "$FM_SECONDMATE_COMMAND_REGISTRY"
    return 0
  fi
  if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
    printf '%s' "$FM_DATA_OVERRIDE/secondmates.md"
    return 0
  fi
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s' "$FM_HOME/data/secondmates.md"
    return 0
  fi
  return 1
}

# Normalize one raw field value to a known token. Prints firstmate, captain, or
# invalid. An empty value is invalid, never silently defaulted: a `command:`
# field that is present but blank is a damaged record, not an absent field.
_fm_secondmate_command_token() {  # <raw-value>
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  case "$v" in
    firstmate) printf 'firstmate' ;;
    captain) printf 'captain' ;;
    *) printf 'invalid' ;;
  esac
}

# Command state of registered secondmate <id>. Prints one token and returns:
#   0 + firstmate|captain  - a registered lane whose state is known
#   1 + nothing            - no registry, or <id> is not a registered secondmate
#                            (an ordinary crewmate or scout id lands here)
#   2 + invalid            - the line carries an unrecognized `command:` value
# Returning 2 rather than defaulting is the fail-closed half of the contract: a
# damaged record must reach a human, not be read as ordinary firstmate command.
fm_secondmate_command_state() {  # <id> [registry]
  local id=$1 reg=${2:-} line value
  [ -n "$id" ] || return 1
  if [ -z "$reg" ]; then
    reg=$(fm_secondmate_command_registry_path) || return 1
  fi
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" 2>/dev/null | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$line" in
    *'; command:'*) ;;
    *) printf '%s' "$FM_SECONDMATE_COMMAND_DEFAULT"; return 0 ;;
  esac
  value=$(printf '%s\n' "$line" | sed -n 's/.*; command:[[:space:]]*\([^;)]*\).*/\1/p' | tail -1)
  value=$(_fm_secondmate_command_token "$value")
  printf '%s' "$value"
  [ "$value" = invalid ] && return 2
  return 0
}

# 0 only when <id> is a registered secondmate under CAPTAIN command. This is the
# escalation-absorb predicate: the captain is reading that lane's pane himself,
# so its status events are addressed to him and must not wake firstmate. An
# invalid record deliberately does NOT absorb - a damaged record must stay
# loud.
fm_secondmate_command_is_captain() {  # <id> [registry]
  [ "$(fm_secondmate_command_state "$@" 2>/dev/null || true)" = captain ]
}

# 0 when firstmate must NOT act on <id> (steer it, route work into it, retire
# it), printing the blocking token; 1 when firstmate may act normally. Both
# `captain` (deliberately transferred) and `invalid` (damaged record) block,
# because the dangerous direction is acting on a lane firstmate does not
# command.
fm_secondmate_command_blocks_firstmate_action() {  # <id> [registry]
  local state rc
  state=$(fm_secondmate_command_state "$@") && rc=0 || rc=$?
  case "${rc:-0}:$state" in
    0:captain) printf 'captain'; return 0 ;;
    2:*) printf 'invalid'; return 0 ;;
  esac
  return 1
}

# Path of the derived marker inside a secondmate home.
fm_secondmate_command_marker_path() {  # <home>
  printf '%s/%s' "${1%/}" "$FM_SECONDMATE_COMMAND_MARKER_REL"
}

# Command state recorded in the secondmate home's own derived marker. Prints one
# token and returns 0 (firstmate|captain), 1 + nothing (marker absent, which for
# a home seeded before this existed means ordinary firstmate command), or 2 +
# invalid. Never authoritative on its own: compare it against the registry.
fm_secondmate_command_marker_state() {  # <home>
  local home=$1 marker raw value
  [ -n "$home" ] || return 1
  marker=$(fm_secondmate_command_marker_path "$home")
  [ -f "$marker" ] || return 1
  raw=$(grep -E '^command:' "$marker" 2>/dev/null | tail -1 || true)
  [ -n "$raw" ] || { printf 'invalid'; return 2; }
  value=$(_fm_secondmate_command_token "${raw#command:}")
  printf '%s' "$value"
  [ "$value" = invalid ] && return 2
  return 0
}
