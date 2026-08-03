#!/usr/bin/env bash
# fm-subagent-dispatch.sh - read, validate, and resolve the captain's live Pi
# subagent workload configuration without changing it or persisting model data.
#
# Usage:
#   fm-subagent-dispatch.sh path
#   fm-subagent-dispatch.sh list
#   fm-subagent-dispatch.sh resolve <cheap|balanced|strong> <workload-key>
#   fm-subagent-dispatch.sh --help
#
# Source precedence is evaluated on every command invocation:
#   1. $PI_CODING_AGENT_DIR/extensions/subagents/config.json when
#      PI_CODING_AGENT_DIR is nonempty and that candidate is a regular file.
#   2. $FM_SUBAGENTS_CONFIG when nonempty. This override must be absolute and a
#      regular file; an explicitly invalid override is an error, not a fallback.
#   3. $HOME/.pi/agent/extensions/subagents/config.json when it is regular.
# No source prints SOURCE_ABSENT and exits 4. Invalid JSON or schema exits 3.
# Usage errors exit 2, and an unknown tier or workload exits 5.
#
# Every selected source is snapshotted once into a private temporary file, then
# validated and rendered only from that snapshot. The exact schema is a root
# object containing only modelTiers and optional maxConcurrency. When present,
# maxConcurrency is a positive integer; list exposes the extension default 4
# when omitted. modelTiers contains exactly cheap, balanced, and strong. Each
# tier contains only workloads, a nonempty array of exact workload objects: key,
# description, model, and thinkingLevel. Keys are tier-local unique wN
# identifiers, descriptions are nonempty strings, and models match
# /^[^/\s]+\/.+\S$/: a provider with no slash or whitespace, then a model suffix
# that may contain further slashes or internal spaces but ends non-whitespace and
# contains no JavaScript line terminator. thinkingLevel is one of
# off|minimal|low|medium|high|xhigh|max. resolve renames thinkingLevel to effort
# without changing its value. list and resolve write JSON to stdout; path writes
# the selected path.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die_usage() {
  printf 'fm-subagent-dispatch: %s\n' "$*" >&2
  exit 2
}

select_source() {
  local candidate
  if [ -n "${PI_CODING_AGENT_DIR:-}" ]; then
    candidate=${PI_CODING_AGENT_DIR}/extensions/subagents/config.json
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if [ -n "${FM_SUBAGENTS_CONFIG:-}" ]; then
    case "$FM_SUBAGENTS_CONFIG" in
      /*) ;;
      *)
        printf 'SUBAGENTS_CONFIG: invalid %s - FM_SUBAGENTS_CONFIG must be an absolute path\n' \
          "$FM_SUBAGENTS_CONFIG" >&2
        exit 3
        ;;
    esac
    if [ ! -f "$FM_SUBAGENTS_CONFIG" ]; then
      printf 'SUBAGENTS_CONFIG: invalid %s - FM_SUBAGENTS_CONFIG is not a regular file\n' \
        "$FM_SUBAGENTS_CONFIG" >&2
      exit 3
    fi
    printf '%s\n' "$FM_SUBAGENTS_CONFIG"
    return 0
  fi

  if [ -n "${HOME:-}" ]; then
    candidate=${HOME}/.pi/agent/extensions/subagents/config.json
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  printf 'SOURCE_ABSENT: no Pi subagent config found in PI_CODING_AGENT_DIR, FM_SUBAGENTS_CONFIG, or HOME\n' >&2
  exit 4
}

validate_config() {
  jq -r '
    def exact_keys($expected): (keys | sort) == ($expected | sort);
    def valid_thinking:
      . == "off" or . == "minimal" or . == "low" or . == "medium" or
      . == "high" or . == "xhigh" or . == "max";
    def tier_reason($name):
      .modelTiers[$name] as $tier |
      if ($tier | type) != "object" then
        "modelTiers." + $name + " must be an object"
      elif ($tier | exact_keys(["workloads"])) | not then
        "modelTiers." + $name + " must contain exactly workloads"
      elif ($tier.workloads | type) != "array" then
        "modelTiers." + $name + ".workloads must be an array"
      elif ($tier.workloads | length) == 0 then
        "modelTiers." + $name + ".workloads must be nonempty"
      elif any($tier.workloads[]; type != "object") then
        "modelTiers." + $name + " has a workload that is not an object"
      elif any($tier.workloads[]; (exact_keys(["key", "description", "model", "thinkingLevel"]) | not)) then
        "modelTiers." + $name + " workload objects must contain exactly key, description, model, thinkingLevel"
      elif any($tier.workloads[]; (.key | type) != "string" or (.key | test("^w[1-9][0-9]*$") | not)) then
        "modelTiers." + $name + " workload key must match ^w[1-9][0-9]*$"
      elif ([$tier.workloads[].key] | unique | length) != ($tier.workloads | length) then
        "modelTiers." + $name + " workload keys must be unique within the tier"
      elif any($tier.workloads[]; (.description | type) != "string" or (.description | length) == 0) then
        "modelTiers." + $name + " workload description must be a nonempty string"
      elif any($tier.workloads[]; (.model | type) != "string" or (.model | test("[\\r\\n\u2028\u2029]")) or (.model | test("^[^/\\s]+/.+\\S$") | not)) then
        "modelTiers." + $name + " workload model must match ^[^/\\s]+/.+\\S$"
      elif any($tier.workloads[]; (.thinkingLevel | type) != "string" or (.thinkingLevel | valid_thinking | not)) then
        "modelTiers." + $name + " workload thinkingLevel is unsupported"
      else
        "OK"
      end;
    if type != "object" then
      "root must be an object"
    elif ((keys - ["maxConcurrency", "modelTiers"]) | length) != 0 or has("modelTiers") == false then
      "root may contain only maxConcurrency and modelTiers, and modelTiers is required"
    elif has("maxConcurrency") and ((.maxConcurrency | type) != "number" or .maxConcurrency <= 0 or (.maxConcurrency | floor) != .maxConcurrency) then
      "maxConcurrency must be a positive integer when present"
    elif (.modelTiers | type) != "object" then
      "modelTiers must be an object"
    elif (.modelTiers | exact_keys(["cheap", "balanced", "strong"]) | not) then
      "modelTiers must contain exactly cheap, balanced, strong"
    else
      tier_reason("cheap") as $cheap |
      if $cheap != "OK" then $cheap
      else tier_reason("balanced") as $balanced |
        if $balanced != "OK" then $balanced
        else tier_reason("strong")
        end
      end
    end
  '
}

case "${1:-}" in
  -h|--help)
    [ "$#" -eq 1 ] || die_usage "--help takes no arguments"
    usage
    exit 0
    ;;
  path|list)
    [ "$#" -eq 1 ] || die_usage "$1 takes no arguments"
    ;;
  resolve)
    [ "$#" -eq 3 ] || die_usage "resolve requires <cheap|balanced|strong> <workload-key>"
    ;;
  '')
    die_usage "command required (path, list, or resolve)"
    ;;
  *)
    die_usage "unknown command '$1' (expected path, list, or resolve)"
    ;;
esac

SOURCE=$(select_source)
if ! command -v jq >/dev/null 2>&1; then
  printf 'SUBAGENTS_CONFIG: unavailable - jq is required to validate %s\n' "$SOURCE" >&2
  exit 3
fi
umask 077
SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/fm-subagent-dispatch.XXXXXX") || {
  printf 'SUBAGENTS_CONFIG: unavailable - could not create private source snapshot\n' >&2
  exit 3
}
trap 'rm -f "$SNAPSHOT"' EXIT HUP INT TERM
if ! cat -- "$SOURCE" >"$SNAPSHOT"; then
  printf 'SUBAGENTS_CONFIG: invalid %s - could not snapshot selected source\n' "$SOURCE" >&2
  exit 3
fi
set +e
VALIDATION=$(validate_config <"$SNAPSHOT" 2>&1)
VALIDATION_RC=$?
set -e
if [ "$VALIDATION_RC" -ne 0 ]; then
  VALIDATION=$(printf '%s' "$VALIDATION" | tr '\n' ' ')
  printf 'SUBAGENTS_CONFIG: invalid %s - malformed JSON: %s\n' "$SOURCE" "$VALIDATION" >&2
  exit 3
fi
if [ "$VALIDATION" != "OK" ]; then
  printf 'SUBAGENTS_CONFIG: invalid %s - %s\n' "$SOURCE" "$VALIDATION" >&2
  exit 3
fi

if [ "$1" = resolve ]; then
  case "$2" in
    cheap|balanced|strong) ;;
    *)
      printf "SUBAGENTS_CONFIG: unknown tier '%s' (expected cheap, balanced, or strong)\n" "$2" >&2
      exit 5
      ;;
  esac
fi

case "$1" in
  path)
    printf '%s\n' "$SOURCE"
    ;;
  list)
    jq -c --arg source "$SOURCE" '
      {
        source: $source,
        maxConcurrency: (.maxConcurrency // 4),
        tiers: (.modelTiers | with_entries(
          .value = [.value.workloads[] | {
            workload: .key,
            description,
            model,
            effort: .thinkingLevel
          }]
        ))
      }
    ' "$SNAPSHOT"
    ;;
  resolve)
    if ! jq -e --arg tier "$2" --arg workload "$3" \
      '.modelTiers[$tier].workloads | any(.key == $workload)' "$SNAPSHOT" >/dev/null; then
      printf "SUBAGENTS_CONFIG: unknown workload '%s' in tier '%s'\n" "$3" "$2" >&2
      exit 5
    fi
    jq -c --arg source "$SOURCE" --arg tier "$2" --arg workload "$3" '
      .modelTiers[$tier].workloads[] |
      select(.key == $workload) |
      {
        source: $source,
        tier: $tier,
        workload: .key,
        model,
        effort: .thinkingLevel,
        description
      }
    ' "$SNAPSHOT"
    ;;
esac
