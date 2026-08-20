#!/usr/bin/env bash
# fm-route-decision.sh - validate or inspect an advisory model route decision.
#
# Usage:
#   fm-route-decision.sh validate [FILE|-]
#   fm-route-decision.sh profile ROUTE
#   fm-route-decision.sh schema
#
# The validator is deliberately advisory: it never classifies prompts, checks
# credentials or quota, launches or replaces workers, replans failures, or
# changes merge authority. The versioned JSON schema is the allowlist owner;
# this script adds the deterministic cross-field checks that jq can enforce.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SELF_DIR/.." && pwd)
SCHEMA_FILE="$ROOT/schemas/fm-route-decision.v1.json"

fm_route_decision_usage() {
  sed -n '2,12{s/^# \{0,1\}//;p;}' "$SELF"
}

fm_route_decision_die() {
  printf 'fm-route-decision: %s\n' "$1" >&2
  exit 1
}

[ -r "$SCHEMA_FILE" ] || fm_route_decision_die "missing route-decision schema"
command -v jq >/dev/null 2>&1 || fm_route_decision_die "jq is required"

fm_route_decision_validate() {
  local input=${1:--} file rc
  file=$(mktemp "${TMPDIR:-/tmp}/fm-route-decision.XXXXXX") ||
    fm_route_decision_die "could not create an input buffer"
  trap 'rm -f "$file"' EXIT HUP INT TERM
  if [ "$input" = - ]; then
    cat > "$file" || fm_route_decision_die "could not read JSON from stdin"
  else
    [ -f "$input" ] || fm_route_decision_die "input file does not exist: $input"
    cat -- "$input" > "$file" || fm_route_decision_die "could not read input file: $input"
  fi

  if ! jq -e -s 'length == 1' "$file" >/dev/null 2>&1; then
    fm_route_decision_die "malformed JSON"
  fi

  if ! jq -e -s --slurpfile contract "$SCHEMA_FILE" '
    .[0] as $d
    | $contract[0] as $contract
    | if ($d | type) != "object" then false
      elif (($d | keys_unsorted | sort) != ([
        "confidence", "model", "override", "privacy", "provider", "reason",
        "route", "schema", "source"
      ] | sort)) then false
      elif $d.schema != "fm-route-decision.v1" then false
      elif ($d.route | type) != "string" then false
      elif (($contract["x-route-profiles"] | has($d.route)) | not) then false
      elif ($d.provider | type) != "string" then false
      elif ($d.model | type) != "string" then false
      elif ($d.confidence | type) != "number" or $d.confidence < 0 or $d.confidence > 1 then false
      elif ($d.privacy | type) != "string" or
        ($d.privacy != "local-only" and $d.privacy != "cloud-allowed") then false
      elif ($d.source | type) != "string" or
        ($d.source != "advisory" and $d.source != "explicit") then false
      elif ($d.reason | type) != "string" or ($d.reason | length) == 0 or
        ($d.reason | length) > 1000 then false
      else
        ($contract["x-route-profiles"][$d.route]) as $profile
        | if $d.provider != $profile.provider or $d.model != $profile.model then false
          elif (($profile.privacy | index($d.privacy)) == null) then false
          elif ($d.route | startswith("cloud-")) and $d.privacy != "cloud-allowed" then false
          elif $d.source == "advisory" and $d.override != null then false
          elif $d.source == "advisory" and $d.route != "escalate" and $d.confidence < 0.5 then false
          elif $d.source == "explicit" and ($d.override | type) != "object" then false
          elif $d.source == "explicit" and (($d.override | keys_unsorted | sort) != ["reason", "route"]) then false
          elif $d.source == "explicit" and ($d.override.route != $d.route) then false
          elif $d.source == "explicit" and ($d.override.route | type) != "string" then false
          elif $d.source == "explicit" and (($contract["x-route-profiles"] | has($d.override.route)) | not) then false
          elif $d.source == "explicit" and (($d.override.reason | type) != "string" or
            ($d.override.reason | length) == 0 or ($d.override.reason | length) > 1000) then false
          else true
          end
      end' "$file" >/dev/null 2>&1; then
    fm_route_decision_die "route decision violates fm-route-decision.v1"
  fi

  jq -cS . "$file"
  rc=$?
  trap - EXIT HUP INT TERM
  rm -f "$file"
  return "$rc"
}

fm_route_decision_profile() {
  local route=${1:-}
  [ "$#" -eq 1 ] || fm_route_decision_die "profile requires a route"
  jq -e -cS --arg route "$route" \
    '."x-route-profiles"[$route] // empty | . + {route: $route}' \
    "$SCHEMA_FILE" 2>/dev/null || fm_route_decision_die "unknown route: $route"
}

case "${1:-}" in
  validate)
    [ "$#" -le 2 ] || fm_route_decision_die "validate accepts one file or stdin"
    fm_route_decision_validate "${2:--}"
    ;;
  profile)
    shift
    fm_route_decision_profile "$@"
    ;;
  schema)
    [ "$#" -eq 1 ] || fm_route_decision_die "schema accepts no arguments"
    cat -- "$SCHEMA_FILE"
    ;;
  --help|-h)
    fm_route_decision_usage
    ;;
  *)
    fm_route_decision_usage >&2
    exit 2
    ;;
esac
