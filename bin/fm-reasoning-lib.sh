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
FM_REASON_TOKEN_VALUE_MALFORMED=FM_SPAWN_JUSTIFICATION_VALUE_MALFORMED

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
# The delivery mode is the other half of that contract: a local-only task never
# reaches a PR merge gate, it lands through the guarded fast-forward path, so
# with yolo off it records the local merge approval the captain actually owns
# rather than a gate it never arrives at. With yolo on, firstmate decides
# routine gates on either path, which is one posture rather than two.
fm_escalation_policy_for() {  # <kind> <mode> <yolo>
  local kind=$1 mode=$2 yolo=$3
  case "$kind" in
    scout) printf 'report-only\n' ;;
    secondmate) printf 'captain-approves-gates\n' ;;
    *)
      case "$yolo" in
        on) printf 'firstmate-routine-gates\n' ;;
        *)
          case "$mode" in
            local-only) printf 'captain-approves-local-merge\n' ;;
            *) printf 'captain-approves-gates\n' ;;
          esac
          ;;
      esac
      ;;
  esac
}

# A route's `use` and the top-level `default` each carry either one profile
# object or a non-empty array of them (docs/configuration.md "Crew dispatch
# profiles"). bin/fm-bootstrap.sh validates that file against exactly this
# normalization, so reading it any other way would make a config the validator
# calls good unreadable here.
# shellcheck disable=SC2016 # $value is a jq parameter, deliberately unexpanded.
FM_JQ_DISPATCH_PROFILES='
  def profiles($value):
    if ($value | type) == "array" then $value
    elif ($value | type) == "object" then [$value]
    else []
    end;
'

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
  jq -r "$FM_JQ_DISPATCH_PROFILES"'
    [ (._floors // {} | keys[]?),
      (.rules // [] | .[]? | (.floor // empty), (profiles(.use?)[]? | .floor // empty)),
      (profiles(.default)[]? | .floor // empty) ]
    | map(select(type == "string" and length > 0)) | unique | .[]
  ' "$file" 2>/dev/null || return 2
}

# The floor a dispatch inherits when the caller names none: the configured
# default route's floor. A default written as a profile array names one route
# with several interchangeable profiles, so its floor is the first one those
# profiles define. Empty when this home configures no default floor.
fm_capability_floor_default() {  # <config-dir>
  local config=$1 file
  file="$config/crew-dispatch.json"
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  jq -r "$FM_JQ_DISPATCH_PROFILES"'
    [ profiles(.default)[]? | .floor? | select(type == "string" and length > 0) ]
    | first // empty
  ' "$file" 2>/dev/null || return 2
}

# Every recorded field is one line of state/<id>.meta, a file teardown,
# supervision and backend resolution all read as authority. A value carrying a
# newline would append forged key lines to it, so a value that cannot be
# recorded as exactly one line is not recordable at all.
fm_justification_value_recordable() {  # <value>
  case "$1" in
    *[[:cntrl:]]*) return 1 ;;
    *) return 0 ;;
  esac
}

# TOOLING_GAP's certification: the repair has to exist as OPEN work in this
# home's backlog before the dispatch that the gap forced is recorded. A closed
# or absent item is not a filed repair, and without this check the code becomes
# a laundering label for turns nobody ever fixes.
#
# The wanted id is compared as a literal string against the id field parsed out
# of each open checkbox line, never spliced into a pattern. A caller's value is
# the thing being checked, so letting it carry match syntax would let `|` alone
# certify against any backlog at all.
fm_backlog_item_open() {  # <data-dir> <item-id>
  local data=$1 id=$2 file
  file="$data/backlog.md"
  [ -n "$id" ] || return 1
  [ -f "$file" ] || return 1
  awk -v want="$id" '
    /^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]+/ {
      item = $0
      sub(/^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]+/, "", item)
      sub(/[[:space:]].*$/, "", item)
      if (item == want) { open_item = 1; exit }
    }
    END { exit open_item ? 0 : 1 }
  ' "$file"
}
