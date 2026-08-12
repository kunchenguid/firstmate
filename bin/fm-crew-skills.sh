#!/usr/bin/env bash
# Validate and resolve the local workflow-phase skill configuration.
#
# Usage:
#   fm-crew-skills.sh validate
#   fm-crew-skills.sh resolve <plan|review> <project-name> [--explicit <skill>]
#
# The canonical schema lives in docs/configuration.md "Crew workflow skills".
# This executable owns its mechanical validation and resolution:
#
#   explicit per-task skill > projects.<name>.<phase> > phases.<phase> > empty
#
# Empty means today's built-in behavior: no plan/review skill is added.
# Configured and explicit names must resolve to either a repo skill under
# <tracked-root>/.agents/skills/<name>/SKILL.md or a user skill under
# ~/.claude/skills/<name>/SKILL.md. Tests may override those roots with
# FM_REPO_SKILLS_DIR and FM_USER_SKILLS_DIR.
#
# Validation prints one reason to stderr and exits non-zero. Resolve validates
# the whole file first, so an explicit task override never masks a malformed or
# unknown configured skill. On success resolve prints only the chosen skill;
# no selection prints an empty line.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG_FILE="${FM_CREW_SKILLS_FILE:-$FM_HOME/config/crew-skills.json}"
REPO_SKILLS_DIR="${FM_REPO_SKILLS_DIR:-$CODE_ROOT/.agents/skills}"
USER_SKILLS_DIR="${FM_USER_SKILLS_DIR:-$HOME/.claude/skills}"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

skill_name_safe() {
  case "$1" in
    ''|*[!A-Za-z0-9._:-]*|[!A-Za-z0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

skill_exists() {
  local skill=$1
  [ -f "$REPO_SKILLS_DIR/$skill/SKILL.md" ] \
    || [ -f "$USER_SKILLS_DIR/$skill/SKILL.md" ]
}

validate_config() {
  local reason skill
  [ -e "$CONFIG_FILE" ] || return 0
  [ -f "$CONFIG_FILE" ] || {
    echo "path is not a regular file" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "jq is required" >&2
    return 1
  }
  jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || {
    echo "malformed JSON" >&2
    return 1
  }

  reason=$(jq -r '
    def known_phase: . == "plan" or . == "review";
    def phase_entries:
      [(.phases // {} | to_entries[]?)]
      + [(.projects // {} | to_entries[]?.value | to_entries[]?)];
    if type != "object" then "top-level value must be an object"
    elif ([keys[] | select(. != "phases" and . != "projects")] | length) > 0 then
      "unknown top-level key: " + ([keys[] | select(. != "phases" and . != "projects")] | sort | join(", "))
    elif has("phases") and (.phases | type) != "object" then "phases must be an object"
    elif has("projects") and (.projects | type) != "object" then "projects must be an object"
    elif ([.projects // {} | to_entries[] | select((.key | type) != "string" or (.key | length) == 0)] | length) > 0 then
      "project names must be non-empty strings"
    elif ([.projects // {} | to_entries[] | select((.value | type) != "object")] | length) > 0 then
      "each project override must be an object"
    elif ([phase_entries[] | select(.key | known_phase | not) | .key] | length) > 0 then
      "unknown phase: " + ([phase_entries[] | select(.key | known_phase | not) | .key] | unique | sort | join(", "))
    elif ([phase_entries[] | select((.value | type) != "object")] | length) > 0 then
      "each phase entry must be an object"
    elif ([phase_entries[] | select((.value | keys | sort) != ["skill"])] | length) > 0 then
      "each phase entry must contain only skill"
    elif ([phase_entries[] | select((.value.skill | type) != "string" or (.value.skill | length) == 0)] | length) > 0 then
      "each phase entry needs a non-empty skill"
    else empty
    end
  ' "$CONFIG_FILE" 2>/dev/null || true)
  if [ -n "$reason" ]; then
    echo "$reason" >&2
    return 1
  fi

  while IFS= read -r skill; do
    [ -n "$skill" ] || continue
    if ! skill_name_safe "$skill"; then
      echo "invalid skill name: $skill" >&2
      return 1
    fi
    if ! skill_exists "$skill"; then
      echo "unknown skill: $skill" >&2
      return 1
    fi
  done <<EOF
$(jq -r '
  ([.phases // {} | to_entries[]?.value.skill]
   + [.projects // {} | to_entries[]?.value | to_entries[]?.value.skill])
  | unique[]?
' "$CONFIG_FILE")
EOF
}

command_name=${1:-}
case "$command_name" in
  -h|--help) usage; exit 0 ;;
  validate)
    [ "$#" -eq 1 ] || { echo "error: validate accepts no arguments" >&2; exit 2; }
    validate_config
    ;;
  resolve)
    [ "$#" -ge 3 ] || { echo "error: resolve requires <plan|review> <project-name>" >&2; exit 2; }
    phase=$2
    project=$3
    shift 3
    explicit=
    case "$phase" in plan|review) ;; *) echo "error: phase must be plan or review" >&2; exit 2 ;; esac
    [ -n "$project" ] || { echo "error: project name must be non-empty" >&2; exit 2; }
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --explicit)
          [ "$#" -ge 2 ] || { echo "error: --explicit requires a value" >&2; exit 2; }
          explicit=$2
          shift 2
          ;;
        --explicit=*) explicit=${1#--explicit=}; shift ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
      esac
    done
    validate_config || {
      echo "error: invalid config/crew-skills.json" >&2
      exit 1
    }
    if [ -n "$explicit" ]; then
      skill_name_safe "$explicit" || { echo "error: invalid explicit skill name: $explicit" >&2; exit 1; }
      skill_exists "$explicit" || { echo "error: unknown explicit skill: $explicit" >&2; exit 1; }
      printf '%s\n' "$explicit"
      exit 0
    fi
    if [ -f "$CONFIG_FILE" ]; then
      jq -r --arg phase "$phase" --arg project "$project" '
        .projects[$project][$phase].skill // .phases[$phase].skill // empty
      ' "$CONFIG_FILE"
    else
      printf '\n'
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
