#!/usr/bin/env bash
# Resolve Firstmate's optional presentation-only crew identities.
#
# Local schema owner: docs/configuration.md "Crew identities".
# Built-in roster data lives under rosters/<roster>.json.
# Mechanical task ids, kind values, endpoint selectors, and recovery bindings
# never depend on this layer.
#
# Usage:
#   fm-crew-identity.sh validate [<config-file>]
#   fm-crew-identity.sh assignment <captain|primary|agent> [<task-id>]
#   fm-crew-identity.sh render <roster> <identity>
#   fm-crew-identity.sh space-label <roster> <identity>
#   fm-crew-identity.sh check-active <task-id> <roster> <identity> [<state-dir>]
set -u

FM_CREW_IDENTITY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_CREW_IDENTITY_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$FM_CREW_IDENTITY_SCRIPT_DIR/.." && pwd)}}"
FM_CREW_IDENTITY_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_CREW_IDENTITY_ROOT}}"
FM_CREW_IDENTITY_CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_CREW_IDENTITY_HOME/config}"
FM_CREW_IDENTITY_STATE_DIR="${FM_STATE_OVERRIDE:-$FM_CREW_IDENTITY_HOME/state}"
FM_CREW_IDENTITY_CONFIG="${FM_CREW_IDENTITY_CONFIG:-$FM_CREW_IDENTITY_CONFIG_DIR/crew-identities.json}"

fm_crew_identity_config_present() {
  [ -f "$FM_CREW_IDENTITY_CONFIG" ] && [ ! -L "$FM_CREW_IDENTITY_CONFIG" ]
}

fm_crew_identity_roster_path() { # <roster-id>
  local roster=$1
  case "$roster" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s/rosters/%s.json' "$FM_CREW_IDENTITY_ROOT" "$roster"
}

fm_crew_identity_validate_roster() { # <roster-id>
  local roster=$1 path
  command -v jq >/dev/null 2>&1 || {
    echo "error: crew identities require jq" >&2
    return 1
  }
  path=$(fm_crew_identity_roster_path "$roster") || {
    echo "error: invalid crew roster id '$roster'" >&2
    return 1
  }
  [ -f "$path" ] && [ ! -L "$path" ] || {
    echo "error: crew roster '$roster' is missing or unsafe: $path" >&2
    return 1
  }
  if ! jq -e --arg roster "$roster" '
    . as $doc
    | .schema == "firstmate-crew-roster.v1"
    and .id == $roster
    and (.title | type == "string" and length > 0)
    and (.sources | type == "object" and length > 0)
    and all(.sources[];
      type == "object"
      and (.title | type == "string" and length > 0)
      and (.url | type == "string" and test("^https://")))
    and (.identities | type == "array" and length > 0)
    and all(.identities[];
      type == "object"
      and ((keys_unsorted - ["id","full_name","space_label","shipboard_role","affinities","source_refs"]) | length == 0)
      and (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
      and (.full_name | type == "string" and length > 0)
      and (.space_label | type == "string" and test("^[^[:cntrl:]/]+$") and length <= 80)
      and (.shipboard_role | type == "string" and length > 0)
      and (.affinities | type == "array" and length > 0)
      and all(.affinities[]; type == "string" and test("^[a-z][a-z-]*$"))
      and (.source_refs | type == "array" and length > 0)
      and all(.source_refs[]; type == "string" and (. as $ref | $doc.sources | has($ref))))
    and ([$doc.identities[].id] | length) == ([$doc.identities[].id] | unique | length)
    and ([$doc.identities[].space_label] | length) == ([$doc.identities[].space_label] | unique | length)
  ' "$path" >/dev/null 2>&1; then
    echo "error: invalid crew roster '$roster': schema validation failed" >&2
    return 1
  fi
}

fm_crew_identity_validate_config() { # [<config-file>]
  local config=${1:-$FM_CREW_IDENTITY_CONFIG} roster path
  [ -e "$config" ] || return 0
  [ -f "$config" ] && [ ! -L "$config" ] || {
    echo "error: crew identity config is not a regular file: $config" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: crew identities require jq" >&2
    return 1
  }
  if ! jq -e '
    type == "object"
    and ((keys_unsorted - ["version","roster","captain","primary","agents"]) | length == 0)
    and .version == 1
    and (.roster | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and ((has("captain") | not) or (.captain | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")))
    and (.primary | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and ((.agents // {}) | type == "object")
    and all((.agents // {}) | to_entries[];
      (.key | length <= 64 and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
      and (.value | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")))
    and (([.captain?, .primary?] + [(.agents // {})[]]
      | map(select(type == "string"))) as $assigned
      | ($assigned | length) == ($assigned | unique | length))
  ' "$config" >/dev/null 2>&1; then
    echo "error: invalid crew identity config: $config" >&2
    return 1
  fi
  roster=$(jq -r '.roster' "$config")
  fm_crew_identity_validate_roster "$roster" || return 1
  path=$(fm_crew_identity_roster_path "$roster") || return 1
  if ! jq -e --slurpfile roster "$path" '
    ([.captain?, .primary?] + [(.agents // {})[]]
      | map(select(type == "string" and length > 0))) as $assigned
    | all($assigned[]; . as $id | any($roster[0].identities[]; .id == $id))
  ' "$config" >/dev/null 2>&1; then
    echo "error: crew identity config names an identity absent from roster '$roster'" >&2
    return 1
  fi
}

fm_crew_identity_config_roster() {
  fm_crew_identity_config_present || return 1
  fm_crew_identity_validate_config || return 1
  jq -r '.roster' "$FM_CREW_IDENTITY_CONFIG"
}

fm_crew_identity_assignment() { # <captain|primary|agent> [<task-id>]
  local target=$1 id=${2:-} filter
  fm_crew_identity_config_present || return 1
  fm_crew_identity_validate_config || return 1
  case "$target" in
    captain) filter='.captain // "unassigned"' ;;
    primary) filter='.primary // "unassigned"' ;;
    agent)
      case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
      # shellcheck disable=SC2016 # $id is a jq --arg, not a shell expansion
      filter='(.agents[$id] // "unassigned")'
      ;;
    *) return 1 ;;
  esac
  jq -r --arg id "$id" "$filter" "$FM_CREW_IDENTITY_CONFIG"
}

fm_crew_identity_record_json() { # <roster> <identity>
  local roster=$1 identity=$2 path
  [ "$identity" != unassigned ] || {
    jq -n '{id:"unassigned",full_name:"Unassigned crew identity",space_label:"Unassigned crew",shipboard_role:"Unassigned",affinities:[],source_refs:[]}'
    return 0
  }
  fm_crew_identity_validate_roster "$roster" || return 1
  path=$(fm_crew_identity_roster_path "$roster") || return 1
  jq -ce --arg identity "$identity" '.identities[] | select(.id == $identity)' "$path"
}

# fm_crew_identity_id_for_space_label: the single roster identity carrying this
# exact canonical Space label. Roster schema validation already enforces unique
# space_labels, so a match is unambiguous; anything else fails.
fm_crew_identity_id_for_space_label() { # <roster> <space-label>
  local roster=$1 label=$2 path
  fm_crew_identity_validate_roster "$roster" || return 1
  path=$(fm_crew_identity_roster_path "$roster") || return 1
  jq -er --arg label "$label" '
    [.identities[] | select(.space_label == $label) | .id] as $ids
    | if ($ids | length) == 1 then $ids[0] else error("ambiguous") end
  ' "$path" 2>/dev/null
}

# Is this identity currently reserved by ANY entry of the live config?
fm_crew_identity_config_assigns() { # <identity>
  fm_crew_identity_config_present || return 1
  fm_crew_identity_validate_config || return 1
  jq -e --arg identity "$1" '
    ([.captain?, .primary?] + [(.agents // {})[]] | map(select(type == "string")))
    | any(. == $identity)
  ' "$FM_CREW_IDENTITY_CONFIG" >/dev/null 2>&1
}

fm_crew_identity_space_label() { # <roster> <identity>
  fm_crew_identity_record_json "$1" "$2" | jq -er '.space_label'
}

fm_crew_identity_detail() { # <roster> <identity>
  fm_crew_identity_record_json "$1" "$2" | jq -er '"\(.full_name) - \(.shipboard_role)"'
}

fm_crew_identity_brief_value() { # <brief> <key>
  local brief=$1 key=$2 count
  [ -f "$brief" ] && [ ! -L "$brief" ] || return 1
  count=$(grep -c "^${key}:" "$brief" 2>/dev/null || true)
  [ "$count" -le 1 ] || {
    echo "error: $brief records duplicate '$key:' lines" >&2
    return 2
  }
  [ "$count" -eq 1 ] || return 1
  sed -n "s/^${key}:[[:space:]]*//p" "$brief"
}

fm_crew_identity_resolve_task() { # <task-id> <brief> [<explicit-identity>]
  local id=$1 brief=$2 explicit=${3:-} brief_identity brief_roster configured_identity config_roster status
  FM_CREW_IDENTITY_RESOLVED_ID=""
  FM_CREW_IDENTITY_RESOLVED_ROSTER=""
  if brief_identity=$(fm_crew_identity_brief_value "$brief" "Crew identity"); then
    :
  else
    status=$?
    [ "$status" -ne 2 ] || return 1
    brief_identity=""
  fi
  if brief_roster=$(fm_crew_identity_brief_value "$brief" "Crew roster"); then
    :
  else
    status=$?
    [ "$status" -ne 2 ] || return 1
    brief_roster=""
  fi
  if [ -n "$explicit" ]; then
    fm_crew_identity_config_present || {
      echo "error: --identity requires local config/crew-identities.json to select a roster" >&2
      return 1
    }
    config_roster=$(fm_crew_identity_config_roster) || return 1
    configured_identity=$(fm_crew_identity_assignment agent "$id") || return 1
    [ "$configured_identity" = "$explicit" ] || {
      echo "error: --identity '$explicit' is not the unique config reservation for task '$id' (agents.$id is '$configured_identity')" >&2
      return 1
    }
    if [ -n "$brief_identity" ] \
       && { [ "$brief_identity" != "$explicit" ] || [ "$brief_roster" != "$config_roster" ]; }; then
      echo "error: crew identity mismatch for $id: the brief records '$brief_roster/$brief_identity' but --identity selected '$config_roster/$explicit'" >&2
      return 1
    fi
    FM_CREW_IDENTITY_RESOLVED_ID=$explicit
    FM_CREW_IDENTITY_RESOLVED_ROSTER=$config_roster
  else
    if [ -n "$brief_identity" ] || [ -n "$brief_roster" ]; then
      [ -n "$brief_identity" ] && [ -n "$brief_roster" ] || {
        echo "error: $brief must record both Crew roster and Crew identity" >&2
        return 1
      }
      fm_crew_identity_config_present || {
        echo "error: $brief records a crew identity but config/crew-identities.json is absent; refusing an unreserved assignment" >&2
        return 1
      }
      config_roster=$(fm_crew_identity_config_roster) || return 1
      configured_identity=$(fm_crew_identity_assignment agent "$id") || return 1
      [ "$brief_roster" = "$config_roster" ] && [ "$brief_identity" = "$configured_identity" ] || {
        echo "error: $brief records '$brief_roster/$brief_identity' but the unique config reservation for '$id' is '$config_roster/$configured_identity'" >&2
        return 1
      }
      FM_CREW_IDENTITY_RESOLVED_ID=$brief_identity
      FM_CREW_IDENTITY_RESOLVED_ROSTER=$brief_roster
    elif fm_crew_identity_config_present; then
      config_roster=$(fm_crew_identity_config_roster) || return 1
      FM_CREW_IDENTITY_RESOLVED_ID=$(fm_crew_identity_assignment agent "$id") || return 1
      FM_CREW_IDENTITY_RESOLVED_ROSTER=$config_roster
    else
      return 0
    fi
  fi
  [ "$FM_CREW_IDENTITY_RESOLVED_ID" = unassigned ] \
    || fm_crew_identity_record_json "$FM_CREW_IDENTITY_RESOLVED_ROSTER" "$FM_CREW_IDENTITY_RESOLVED_ID" >/dev/null
}

fm_crew_identity_meta_value() { # <meta> <key>
  local meta=$1 key=$2 count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(awk -F= -v key="$key" '$1 == key { n++ } END { print n+0 }' "$meta")
  [ "$count" -eq 1 ] || return 1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$meta"
}

# fm_crew_identity_check_active_tasks: duplicate detection against the durable
# state metadata of OTHER active tasks only. Relaunch uses this alone, because
# the identity it re-asserts is the one already recorded for this task; a later
# edit to the live config must never block an agent that is already sailing.
fm_crew_identity_check_active_tasks() { # <task-id> <roster> <identity> [<state-dir>]
  local id=$1 roster=$2 identity=$3 state=${4:-$FM_CREW_IDENTITY_STATE_DIR}
  local meta other other_identity other_roster
  [ "$identity" != unassigned ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    other=$(basename "$meta" .meta)
    [ "$other" != "$id" ] || continue
    if grep -qE '^(crew_identity|crew_roster)=' "$meta" 2>/dev/null; then
      other_identity=$(fm_crew_identity_meta_value "$meta" crew_identity 2>/dev/null) || {
        echo "error: active task '$other' has an incomplete or duplicate crew identity record" >&2
        return 1
      }
      other_roster=$(fm_crew_identity_meta_value "$meta" crew_roster 2>/dev/null) || {
        echo "error: active task '$other' has an incomplete or duplicate crew identity record" >&2
        return 1
      }
    else
      continue
    fi
    [ "$other_identity" != unassigned ] || continue
    if [ "$other_identity" = "$identity" ] && [ "$other_roster" = "$roster" ]; then
      echo "error: crew identity '$roster/$identity' is already assigned to active task '$other'; refusing duplicate active assignment for '$id'" >&2
      return 1
    fi
  done
}

fm_crew_identity_check_active() { # <task-id> <roster> <identity> [<state-dir>]
  local id=$1 roster=$2 identity=$3 state=${4:-$FM_CREW_IDENTITY_STATE_DIR}
  local captain primary configured_owner config_roster
  [ "$identity" != unassigned ] || return 0
  if fm_crew_identity_config_present; then
    captain=$(fm_crew_identity_assignment captain) || return 1
    primary=$(fm_crew_identity_assignment primary) || return 1
    config_roster=$(fm_crew_identity_config_roster) || return 1
    if [ "$captain" = "$identity" ] && [ "$config_roster" = "$roster" ]; then
      echo "error: crew identity '$roster/$identity' is already assigned to the active captain" >&2
      return 1
    fi
    if [ "$primary" = "$identity" ] && [ "$config_roster" = "$roster" ]; then
      echo "error: crew identity '$roster/$identity' is already assigned to the active primary first mate" >&2
      return 1
    fi
    configured_owner=$(jq -r --arg identity "$identity" --arg id "$id" '
      [(.agents // {}) | to_entries[] | select(.value == $identity and .key != $id) | .key][0] // ""
    ' "$FM_CREW_IDENTITY_CONFIG") || return 1
    if [ -n "$configured_owner" ] && [ "$config_roster" = "$roster" ]; then
      echo "error: crew identity '$roster/$identity' is reserved for configured task '$configured_owner'; refusing assignment to '$id'" >&2
      return 1
    fi
  fi
  fm_crew_identity_check_active_tasks "$id" "$roster" "$identity" "$state"
}

fm_crew_identity_cli() {
  local command=${1:-}
  shift || true
  case "$command" in
    validate)
      fm_crew_identity_validate_config "${1:-$FM_CREW_IDENTITY_CONFIG}"
      ;;
    assignment)
      [ "$#" -ge 1 ] && [ "$#" -le 2 ] || return 2
      fm_crew_identity_assignment "$@"
      ;;
    render)
      [ "$#" -eq 2 ] || return 2
      fm_crew_identity_detail "$1" "$2"
      ;;
    space-label)
      [ "$#" -eq 2 ] || return 2
      fm_crew_identity_space_label "$1" "$2"
      ;;
    check-active)
      [ "$#" -ge 3 ] && [ "$#" -le 4 ] || return 2
      fm_crew_identity_check_active "$@"
      ;;
    *)
      sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_crew_identity_cli "$@"
fi
