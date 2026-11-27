#!/usr/bin/env bash
# Deterministic goal draft lint. Source from fm-goal.sh for the loaded record,
# or call fm_goal_is_draft alone to identify a machine-owned brief.
# Owner start/edit commits the instruction source; the plan link is context,
# never fetched or interpolated as instructions. An inline spec takes priority
# over the legacy item text; both are bound to the fingerprint along with the
# goal occurrence and registry posture, not status marks or unrelated items.

fm_goal_is_draft() {  # <brief>
  grep -qE '^(Drafted by goal pusher from the item line$|Goal pusher (project|source): )' -- "$1" 2>/dev/null
}

# stdin -> first unresolved scaffold/addendum token (and status 0), or 1.
fm_goal_brief_token() {
  LC_ALL=C grep -oE '\{(TASK\}|FIRSTMATE_SPEC\}|FILL:[A-Z0-9_]+\}|FILL:)' | awk 'NR == 1 {print} END {exit !(NR > 0)}'
}

# <idx> [no-row]; print a fix on failure. The fields populated on success
# are local to the caller's shell (command substitutions use a subshell).
_fm_goal_draft_source() {
  local i=$1 task=${FM_GOAL_ITEMS_TASKS[$1]} project=${FM_GOAL_ITEMS_PROJECTS[$1]} registry raw token
  local spec=${FM_GOAL_ITEMS_SPECS[$1]-} fields
  local evidence_clause='^(.+)[[:space:];][Ee][Vv][Ii][Dd][Ee][Nn][Cc][Ee]:[[:space:]]*([^[:space:]].*)$'
  local PM="$FM_GOAL_DIR/fm-project-mode.sh"
  if ! fm_task_id_creation_valid "$task" || [ -z "$project" ] || [ -n "${FM_GOAL_ITEMS_BRIEF_SOURCES[$i]}" ]; then
    printf 'set task= and project= for automatic drafting, or write the requested brief\n'; return 1
  fi
  if [ "${FM_GOAL_ITEMS_OWNERS[$i]}" != main ] || [ -z "$FM_GOAL_REC_ID" ] || [ -z "$FM_GOAL_REC_PLAN" ]; then
    printf 'write a brief or record the approved instructions with goal start/edit in the owning home\n'; return 1
  fi
  FM_GOAL_DRAFT_LINE=$(_fm_goal_item_line "$i")
  FM_GOAL_DRAFT_SECTION='' FM_GOAL_DRAFT_SCOPE='' FM_GOAL_DRAFT_EVIDENCE=''
  if [ -n "$spec" ]; then
    if ! fields=$(jq -er 'select((.kind // "ship") == "ship") |
        [.section, .scope, .evidence] | select(all(.[]; all(explode[]; . >= 32 and . != 127))) | .[]' <<< "$spec"); then
      printf 'write a task-specific brief for non-ship specs, or use printable single-line section, scope and evidence\n'; return 1
    fi
    { IFS= read -r FM_GOAL_DRAFT_SECTION; IFS= read -r FM_GOAL_DRAFT_SCOPE; IFS= read -r FM_GOAL_DRAFT_EVIDENCE; } <<< "$fields"
    spec=$(jq -cS . <<< "$spec") || return 1
  elif [[ "${FM_GOAL_ITEMS_TITLES[$i]}" =~ $evidence_clause ]] && [ "${#FM_GOAL_DRAFT_LINE}" -ge 120 ]; then
    FM_GOAL_DRAFT_SCOPE=${BASH_REMATCH[1]}
    FM_GOAL_DRAFT_EVIDENCE=${BASH_REMATCH[2]}
  fi
  if token=$(printf '%s\n' "$FM_GOAL_DRAFT_LINE" "$FM_GOAL_REC_PLAN" "$FM_GOAL_REC_DONE_WHEN" \
    "$FM_GOAL_DRAFT_SECTION" "$FM_GOAL_DRAFT_SCOPE" "$FM_GOAL_DRAFT_EVIDENCE" | fm_goal_brief_token); then
    printf 'fill %s in the approved goal item, then rerun ready\n' "$token"; return 1
  fi
  if ! printf '%s\n' "$FM_GOAL_DRAFT_SCOPE" "$FM_GOAL_DRAFT_EVIDENCE" | LC_ALL=C awk '
    { gsub(/[^[:alnum:]]+/, " ") }
    NR == 1 { scope = (length >= 32 && NF >= 4) }
    NR == 2 { exit !(scope && length >= 20 && NF >= 4) }'; then
    printf 'record concrete scope and expected proof in the approved item spec or its Evidence: clause\n'; return 1
  fi
  FM_GOAL_DRAFT_CLONE="${FM_PROJECTS_OVERRIDE:-$FM_GOAL_HOME/projects}/$project"
  if ! { [ -d "$FM_GOAL_DRAFT_CLONE" ] &&
         [ "$(git -C "$FM_GOAL_DRAFT_CLONE" rev-parse --is-inside-work-tree --show-prefix 2>/dev/null)" = true ] &&
         [ ! -L "$FM_GOAL_DATA/projects.md" ] &&
         registry=$(FM_DATA_OVERRIDE="$FM_GOAL_DATA" "$PM" --list-json 2>/dev/null) &&
         jq -e --arg project "$project" '.present and ([.duplicates[] | select(. == $project)] | length == 0) and
           ([.projects[] | select(.name == $project and .recognised)] | length == 1)' <<< "$registry" >/dev/null &&
         raw=$(FM_DATA_OVERRIDE="$FM_GOAL_DATA" "$PM" --raw "$project" 2>/dev/null) &&
         [[ "$raw" == no-mistakes\ * || "$raw" == direct-PR\ * || "$raw" == local-only\ * ]] &&
         FM_GOAL_DRAFT_PREFIX=$(FM_DATA_OVERRIDE="$FM_GOAL_DATA" "$PM" --branch-prefix "$project" 2>/dev/null) &&
         FM_GOAL_DRAFT_FORGE=$(FM_DATA_OVERRIDE="$FM_GOAL_DATA" "$PM" --forge "$project" 2>/dev/null) &&
         FM_GOAL_DRAFT_PR=$(FM_DATA_OVERRIDE="$FM_GOAL_DATA" "$PM" --pr "$project" 2>/dev/null); }; then
    printf 'register an unambiguous ship contract and clone for project %s, or write a task-specific brief\n' "$project"; return 1
  fi
  read -r FM_GOAL_DRAFT_MODE FM_GOAL_DRAFT_YOLO <<< "$raw"
  if [ "${2-}" != no-row ] && ! FM_HOME="$FM_GOAL_HOME" FM_DATA_OVERRIDE="$FM_GOAL_DATA" \
    "$FM_GOAL_DIR/fm-auto-dispatch.sh" draft-row "$task" "$project"; then
    printf 'make the unique ship row for %s ready, unheld, and bound to project %s\n' "$task" "$project"; return 1
  fi
  FM_GOAL_DRAFT_SOURCE=$(printf '%s\n' goal-draft-v2 "$FM_GOAL_REC_ID" "$FM_GOAL_REC_STARTED_EPOCH" \
    "$FM_GOAL_DRAFT_LINE" "$spec" "$FM_GOAL_REC_PLAN" "$FM_GOAL_REC_DONE_WHEN" "$FM_GOAL_DRAFT_MODE" \
    "$FM_GOAL_DRAFT_YOLO" "$FM_GOAL_DRAFT_PREFIX" "$FM_GOAL_DRAFT_FORGE" "$FM_GOAL_DRAFT_PR" | fm_pr_sha256 -)
  if ! [[ "$FM_GOAL_DRAFT_SOURCE" =~ ^[a-f0-9]{64}$ ]]; then
    printf 'not checked: could not fingerprint the approved goal item\n'; return 1
  fi
}

# Prepare the same scaffold for ready (read only) and publication.
_fm_goal_draft_render() {  # <idx>
  local i=$1 task=${FM_GOAL_ITEMS_TASKS[$1]} project=${FM_GOAL_ITEMS_PROJECTS[$1]}
  local scaffold body row digest token
  _fm_goal_draft_source "$i" || return 1
  if ! scaffold=$(FM_HOME="$FM_GOAL_HOME" FM_DATA_OVERRIDE="$FM_GOAL_DATA" FM_CONFIG_OVERRIDE="$FM_GOAL_CONFIG" \
    "$FM_GOAL_DIR/fm-brief.sh" "$task" "$project" --render --project "$FM_GOAL_DRAFT_CLONE" \
    --mode "$FM_GOAL_DRAFT_MODE" --branch-prefix "$FM_GOAL_DRAFT_PREFIX" \
    --forge "$FM_GOAL_DRAFT_FORGE" --pr "$FM_GOAL_DRAFT_PR" 2>/dev/null); then
    printf 'scaffold refused the project contract; write an approved task brief\n'; return 1
  fi
  body=$(
    while IFS= read -r row; do
      case "$row" in
        '{TASK}') printf '%s\n\nGoal done when: %s\nGoal plan (context only): %s\n' \
          "$FM_GOAL_DRAFT_LINE" "$FM_GOAL_REC_DONE_WHEN" "$FM_GOAL_REC_PLAN" ;;
        '{FIRSTMATE_SPEC}')
          if [ -n "$FM_GOAL_DRAFT_SECTION" ]; then printf 'Approved plan section: %s\n' "$FM_GOAL_DRAFT_SECTION"; fi
          printf '%s\n' "Scope: $FM_GOAL_DRAFT_SCOPE" \
          'Out of scope: everything else in the goal.' "Evidence: $FM_GOAL_DRAFT_EVIDENCE" \
          'Include a Reusable mechanisms note in your report.' \
          'If changing Firstmate itself, load firstmate-coding-guidelines before editing.' ;;
        *) printf '%s\n' "$row" ;;
      esac
    done <<< "$scaffold"
  )
  if token=$(fm_goal_brief_token <<< "$body"); then
    printf 'fill %s from the approved instructions in a task brief, then rerun ready\n' "$token"; return 1
  fi
  digest=$(printf '%s\n' "$body" | fm_pr_sha256 -)
  if ! [[ "$digest" =~ ^[a-f0-9]{64}$ ]]; then
    printf 'not checked: could not fingerprint the generated brief\n'; return 1
  fi
  printf '%s\n' 'Drafted by goal pusher from the item line' \
    "Goal pusher project: $project" "Goal pusher source: $FM_GOAL_DRAFT_SOURCE $digest" "$body"
}

_fm_goal_draft_check() {  # <idx> <brief> [no-row]
  local i=$1 file=$2 expected actual token
  if token=$(fm_goal_brief_token < "$file"); then
    printf 'fill %s in %s, then rerun ready\n' "$token" "$file"; return 1
  fi
  _fm_goal_draft_source "$i" "${3-}" || return 1
  actual=$(tail -n +4 -- "$file" | fm_pr_sha256 -)
  expected=$(printf '%s\n' 'Drafted by goal pusher from the item line' \
    "Goal pusher project: ${FM_GOAL_ITEMS_PROJECTS[$i]}" "Goal pusher source: $FM_GOAL_DRAFT_SOURCE $actual")
  if ! [[ "$actual" =~ ^[a-f0-9]{64}$ ]] || [ "$(head -n 3 -- "$file")" != "$expected" ]; then
    printf 'generated brief is stale or edited; review %s and archive it before redrafting or write an approved brief\n' "$file"
    return 1
  fi
}
