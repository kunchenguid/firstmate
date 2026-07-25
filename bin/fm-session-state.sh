#!/usr/bin/env bash
# Validate and atomically compile the fleet-wide phase-boundary session state.
#
# Session state is task execution state, not project memory. The schema emitted
# here is its sole versioned contract. A phase-boundary candidate is validated,
# copied to a temporary file beside the canonical state, validated again, and
# atomically renamed so readers see either the previous valid state or the new
# valid state. The next phase must not start unless compile succeeds.
#
# Usage:
#   fm-session-state.sh schema
#   fm-session-state.sh validate <state.json>
#   fm-session-state.sh compile <candidate.json> <canonical-state.json>
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'fm-session-state.sh: %s\n' "$*" >&2
  exit 1
}

emit_schema() {
  cat <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:firstmate:session-state:v1",
  "title": "Firstmate phase-boundary session state v1",
  "x-firstmate-invariants": [
    "budget.iterations_used must not exceed budget.iteration_cap",
    "budget.tokens_used must be null when unavailable or must not exceed budget.token_budget"
  ],
  "type": "object",
  "additionalProperties": false,
  "required": [
    "schema_version",
    "task_id",
    "compiled_at",
    "completed_phase",
    "deviations",
    "decisions",
    "evidence_pointers",
    "budget",
    "next_phase"
  ],
  "properties": {
    "schema_version": { "const": "firstmate.session-state/v1" },
    "task_id": { "type": "string", "minLength": 1 },
    "compiled_at": { "type": "string", "minLength": 1 },
    "completed_phase": {
      "type": "object",
      "additionalProperties": false,
      "required": ["name", "checklist"],
      "properties": {
        "name": { "type": "string", "minLength": 1 },
        "checklist": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["item", "status"],
            "properties": {
              "item": { "type": "string", "minLength": 1 },
              "status": { "enum": ["done", "skipped"] }
            }
          }
        }
      }
    },
    "deviations": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["summary", "disposition"],
        "properties": {
          "summary": { "type": "string", "minLength": 1 },
          "disposition": { "type": "string", "minLength": 1 }
        }
      }
    },
    "decisions": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["summary", "authority"],
        "properties": {
          "summary": { "type": "string", "minLength": 1 },
          "authority": { "type": "string", "minLength": 1 }
        }
      }
    },
    "evidence_pointers": {
      "type": "array",
      "minItems": 1,
      "items": { "type": "string", "minLength": 1 }
    },
    "budget": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "iteration_cap",
        "iterations_used",
        "wall_clock_deadline",
        "token_budget",
        "tokens_used"
      ],
      "properties": {
        "iteration_cap": { "type": "integer", "minimum": 1 },
        "iterations_used": { "type": "integer", "minimum": 0 },
        "wall_clock_deadline": { "type": "string", "minLength": 1 },
        "token_budget": { "type": "integer", "minimum": 1 },
        "tokens_used": {
          "oneOf": [
            { "type": "integer", "minimum": 0 },
            { "type": "null" }
          ]
        }
      }
    },
    "next_phase": {
      "type": "object",
      "additionalProperties": false,
      "required": ["name", "acceptance_criteria", "resume_action"],
      "properties": {
        "name": { "type": "string", "minLength": 1 },
        "acceptance_criteria": {
          "type": "array",
          "minItems": 1,
          "items": { "type": "string", "minLength": 1 }
        },
        "resume_action": { "type": "string", "minLength": 1 }
      }
    }
  }
}
EOF
}

validate_state() {
  local state=$1
  [ -f "$state" ] || die "state file not found: $state"
  command -v jq >/dev/null 2>&1 || die "jq is required"

  jq -e '
    def nonempty: type == "string" and length > 0;
    def exact_keys($allowed): ((keys_unsorted - $allowed) | length) == 0;
    def checklist_item:
      type == "object"
      and exact_keys(["item", "status"])
      and (.item | nonempty)
      and (.status == "done" or .status == "skipped");
    def deviation:
      type == "object"
      and exact_keys(["summary", "disposition"])
      and (.summary | nonempty)
      and (.disposition | nonempty);
    def decision:
      type == "object"
      and exact_keys(["summary", "authority"])
      and (.summary | nonempty)
      and (.authority | nonempty);

    type == "object"
    and exact_keys([
      "schema_version",
      "task_id",
      "compiled_at",
      "completed_phase",
      "deviations",
      "decisions",
      "evidence_pointers",
      "budget",
      "next_phase"
    ])
    and .schema_version == "firstmate.session-state/v1"
    and (.task_id | nonempty)
    and (.compiled_at | nonempty)
    and (.completed_phase | type == "object")
    and (.completed_phase | exact_keys(["name", "checklist"]))
    and (.completed_phase.name | nonempty)
    and (.completed_phase.checklist | type == "array" and length > 0)
    and (.completed_phase.checklist | all(.[]; checklist_item))
    and (.deviations | type == "array" and all(.[]; deviation))
    and (.decisions | type == "array" and all(.[]; decision))
    and (.evidence_pointers | type == "array" and length > 0)
    and (.evidence_pointers | all(.[]; nonempty))
    and (.budget | type == "object")
    and (.budget | exact_keys([
      "iteration_cap",
      "iterations_used",
      "wall_clock_deadline",
      "token_budget",
      "tokens_used"
    ]))
    and (.budget.iteration_cap | type == "number" and floor == . and . >= 1)
    and (.budget.iterations_used | type == "number" and floor == . and . >= 0)
    and (.budget.iterations_used <= .budget.iteration_cap)
    and (.budget.wall_clock_deadline | nonempty)
    and (.budget.token_budget | type == "number" and floor == . and . >= 1)
    and (
      .budget.tokens_used == null
      or (.budget.tokens_used | type == "number" and floor == . and . >= 0)
    )
    and (
      .budget.tokens_used == null
      or .budget.tokens_used <= .budget.token_budget
    )
    and (.next_phase | type == "object")
    and (.next_phase | exact_keys(["name", "acceptance_criteria", "resume_action"]))
    and (.next_phase.name | nonempty)
    and (.next_phase.acceptance_criteria | type == "array" and length > 0)
    and (.next_phase.acceptance_criteria | all(.[]; nonempty))
    and (.next_phase.resume_action | nonempty)
  ' "$state" >/dev/null || die "state does not match firstmate.session-state/v1: $state"
}

compile_state() {
  local candidate=$1 target=$2 target_dir tmp=""
  validate_state "$candidate"
  target_dir=$(dirname "$target")
  [ -d "$target_dir" ] || die "canonical state directory not found: $target_dir"
  tmp=$(mktemp "$target_dir/.session-state.compile.XXXXXX") \
    || die "could not create phase-boundary temporary file"
  trap 'rm -f "${tmp:-}"' EXIT HUP INT TERM
  cp "$candidate" "$tmp" || die "could not stage phase-boundary state"
  chmod 0600 "$tmp" || die "could not protect phase-boundary state"
  validate_state "$tmp"
  mv -f "$tmp" "$target" || die "could not atomically publish phase-boundary state"
  tmp=""
  trap - EXIT HUP INT TERM
  printf 'compiled: %s\n' "$target"
}

case "${1:-}" in
  -h|--help)
    usage
    ;;
  schema)
    [ "$#" -eq 1 ] || die "schema takes no arguments"
    emit_schema
    ;;
  validate)
    [ "$#" -eq 2 ] || die "validate requires <state.json>"
    validate_state "$2"
    printf 'valid: %s\n' "$2"
    ;;
  compile)
    [ "$#" -eq 3 ] || die "compile requires <candidate.json> <canonical-state.json>"
    compile_state "$2" "$3"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
