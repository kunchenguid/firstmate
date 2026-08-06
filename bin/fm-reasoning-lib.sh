# shellcheck shell=bash
# Single owner of the agent-justification record written at the spawn chokepoint.
# Usage: . bin/fm-reasoning-lib.sh
#
# Every dispatch has to answer one question: why was an agent turn necessary
# here? This library owns the closed vocabulary that answer is given in, the
# fields derived from it, and the refusal tokens callers and tests match on.
# bin/fm-spawn.sh records the answer; bin/fm-promote.sh recomputes the derived
# escalation policy when a promotion changes the delivery contract. Nothing
# enforces a policy on the value: the record exists so the question is
# answerable, not so a dispatch can be blocked for reasoning too little.
#
# THE CLOSED ENUM. Eight reasoning codes name recurring invocations measured in
# this fleet. TOOLING_GAP is deliberately NOT a reasoning code: it names an
# agent turn taken because a deterministic reader is broken or absent. It is
# counted separately, never as justified reasoning, and it always files repair
# work. Without it a broken reader is recorded as legitimate reasoning demand
# forever, which is the single failure mode that would make this record worse
# than no record at all.
#
# WHY CLOSED. A free-text reason is unmeasurable, so an unknown code is refused
# rather than recorded. Adding a code is a deliberate change here, not a
# spelling choice at a call site.
#
# DERIVED, NEVER DECLARED. reasoning_required follows from the code, and
# escalation_policy follows from kind plus the delivery contract. A caller
# supplies neither, so the two cannot disagree with the record they summarize.
#
# MIGRATION. The fields are additive. A meta written before this library
# existed carries none of them, and an absent field reads as unknown, never as
# justified reasoning.

# The closed reason_code enum. Order is presentation only.
FM_REASON_CODES='NL_RULE_CLASSIFICATION
CONTRACT_SCOPE_JUDGMENT
MULTIPLE_PLAUSIBLE_ROOT_CAUSES
NOVEL_DECOMPOSITION
UNFAMILIAR_CODE
SEMANTIC_REVIEW
SYNTHESIS
AMBIGUOUS_INTENT
TOOLING_GAP'

# The one code that is not a reasoning code.
# shellcheck disable=SC2034 # Contract constants are consumed by sourcing callers.
FM_REASON_CODE_TOOLING_GAP=TOOLING_GAP

# Stable refusal tokens. Tests and callers match these rather than prose, so
# the wording of a refusal can improve without breaking its detection.
# shellcheck disable=SC2034 # Contract constants are consumed by sourcing callers.
{
FM_REASON_TOKEN_REQUIRED=FM_SPAWN_REASON_CODE_REQUIRED
FM_REASON_TOKEN_UNKNOWN=FM_SPAWN_REASON_CODE_UNKNOWN
FM_REASON_TOKEN_REFUSED=FM_SPAWN_REASON_CODE_REFUSED
FM_REASON_TOKEN_GAP_ITEM_REQUIRED=FM_SPAWN_TOOLING_GAP_ITEM_REQUIRED
FM_REASON_TOKEN_GAP_ITEM_REFUSED=FM_SPAWN_TOOLING_GAP_ITEM_REFUSED
FM_REASON_TOKEN_GAP_ITEM_UNFILED=FM_SPAWN_TOOLING_GAP_ITEM_UNFILED
FM_REASON_TOKEN_FLOOR_UNKNOWN=FM_SPAWN_CAPABILITY_FLOOR_UNKNOWN
FM_REASON_TOKEN_FLOOR_UNVERIFIABLE=FM_SPAWN_CAPABILITY_FLOOR_UNVERIFIABLE

# Recorded when this home configures no dispatch profiles, so an unconfigured
# floor is never confused with a floor that was checked and matched.
FM_CAPABILITY_FLOOR_UNCONFIGURED=unconfigured
}

fm_reason_code_known() {  # <code>
  local code=$1 known
  while IFS= read -r known; do
    [ "$known" = "$code" ] && return 0
  done <<EOF
$FM_REASON_CODES
EOF
  return 1
}

fm_reason_codes_oneline() {
  printf '%s\n' "$FM_REASON_CODES" | tr '\n' ' ' | sed 's/ $//'
}

# TOOLING_GAP is an agent turn taken because a reader is broken, so the honest
# answer is that reasoning was NOT what the turn required. Every other code
# names reasoning the platform cannot do deterministically.
fm_reasoning_required_for() {  # <code>
  case "$1" in
    "$FM_REASON_CODE_TOOLING_GAP") printf 'no\n' ;;
    *) printf 'yes\n' ;;
  esac
}

# Derived from the delivery contract this spawn already validates
# (AGENTS.md section 7), so the record cannot claim an authority the task does
# not have. A scout produces a report and holds no merge authority at all.
fm_escalation_policy_for() {  # <kind> <mode> <yolo>
  local kind=$1 yolo=$3
  case "$kind" in
    scout) printf 'report-only\n' ;;
    secondmate) printf 'captain-approves-gates\n' ;;
    *)
      case "$yolo" in
        on) printf 'firstmate-routine-gates\n' ;;
        *) printf 'captain-approves-gates\n' ;;
      esac
      ;;
  esac
}

# The floor vocabulary comes verbatim from this home's own dispatch profiles,
# so a recorded floor is one the routing config actually defines rather than a
# label a caller invented. Prints every accepted floor, one per line.
# Exit 0 with output when the config defines floors, 1 when this home has no
# dispatch config, and 2 when the config exists but cannot be read (missing jq
# or malformed JSON), which is unverifiable rather than empty.
fm_capability_floor_vocabulary() {  # <config-dir>
  local config=$1 file
  file="$config/crew-dispatch.json"
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  jq -r '
    [ (._floors // {} | keys[]?),
      (.rules // [] | .[]?.floor // empty),
      (.default.floor // empty) ]
    | map(select(type == "string" and length > 0)) | unique | .[]
  ' "$file" 2>/dev/null || return 2
}

# The floor a dispatch inherits when the caller names none: the configured
# default route's floor. Empty when this home configures no default floor.
fm_capability_floor_default() {  # <config-dir>
  local config=$1 file
  file="$config/crew-dispatch.json"
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  jq -r '.default.floor // empty' "$file" 2>/dev/null || return 2
}

# TOOLING_GAP's certification: the repair has to exist as OPEN work in this
# home's backlog before the dispatch that the gap forced is recorded. A closed
# or absent item is not a filed repair, and without this check the code becomes
# a laundering label for turns nobody ever fixes.
fm_backlog_item_open() {  # <data-dir> <item-id>
  local data=$1 id=$2 file
  file="$data/backlog.md"
  [ -f "$file" ] || return 1
  grep -qE "^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]+$(
    printf '%s' "$id" | sed 's/[][\.*^$/&]/\\&/g'
  )([[:space:]]|$)" "$file"
}
