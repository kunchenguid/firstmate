#!/usr/bin/env bash
# Add all currently supervised worktrees to Agenttrail Kitchen, on demand.
# Usage: bin/fm-agenttrail-kitchen.sh [--dry-run|--run]
# Default is --dry-run; --run launches or re-attaches the dashboard with the list.
# At most 12 projects are passed. Working/validating tasks rank first; other states
# follow in snapshot order. Overflow and missing worktrees are reported with reasons.
# The helper reads `fm-bearings-snapshot.sh --json --all-in-flight --fields paths`.
set -euo pipefail

fm_agenttrail_select_json() {
  local snapshot=$1 limit=${2:-12}
  jq --argjson limit "$limit" '
    [.in_flight as $tasks | .paths as $paths
     | $tasks | to_entries[]
     | .key as $index
     | .value as $task
     | (($paths | map(select(.id == $task.id)) | first) // {}) as $path
     | {id:$task.id,
        state:($task.state // "unknown"),
        worktree:($path.worktree // null),
        index:($index | tonumber),
        rank:(if ($task.state == "working" or $task.state == "validating") then 0
              elif ($task.state == "unknown" or $task.state == "failed" or $task.state == "done") then 2
              else 1 end)}
     | select(.worktree != null and .worktree != "" and .worktree != "-")]
    | sort_by(.rank, .index)
    | reduce .[] as $row ([]; if any(.[]; .worktree == $row.worktree) then . else . + [$row] end)
    | {selected:.[0:$limit],
       omitted:.[ $limit: ] | map({id,state,worktree,
         reason:(if .rank == 2 then "12-project cap; current state is " + .state
                 else "12-project cap; lower priority or later in snapshot order" end)})}
  ' <<<"$snapshot"
}

fm_agenttrail_main() {
  local mode=dry-run snapshot eligible selection command_string path state id reason row
  local -a project_args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) mode=dry-run ;;
      --run) mode=run ;;
      -h|--help)
        sed -n '1,9p' "${BASH_SOURCE[0]}"
        exit 0
        ;;
      *) printf 'usage: %s [--dry-run|--run]\n' "$0" >&2; return 2 ;;
    esac
    shift
  done

  snapshot=$(FM_SNAPSHOT_SECONDMATES=0 FM_SNAPSHOT_SECONDMATE_CHILDREN=0 \
    FM_SNAPSHOT_REGISTRY_LINES=0 FM_SNAPSHOT_REGISTRY_BYTES=0 FM_SNAPSHOT_REGISTRY_RECORDS=0 \
    "$(dirname "${BASH_SOURCE[0]}")/fm-bearings-snapshot.sh" --json --all-in-flight --all-secondmates --fields paths)
  if jq -e '.omitted[]? | select(
      .surface == "registered secondmates omitted by snapshot bound"
      or .surface == "secondmate registry input truncated by bounded read"
      or .surface == "secondmate registry records omitted by bounded read"
      or (.surface | test("^secondmate home\\(s\\) with unreadable structured state:"))
      or (.surface | test("^secondmate .* active children omitted by snapshot bound:"))
      or (.surface | startswith("secondmate registry unavailable:"))
    )' <<<"$snapshot" >/dev/null; then
    printf 'fm-agenttrail-kitchen: snapshot omits secondmate worktrees; refusing incomplete list\n' >&2
    return 1
  fi
  eligible=$(jq -c '{in_flight:[],paths:[]}' <<<"$snapshot")
  while IFS= read -r row; do
    id=$(jq -r '.id' <<<"$row")
    state=$(jq -r '.state // "unknown"' <<<"$row")
    path=$(jq -r '.worktree // empty' <<<"$row")
    if [ -z "$path" ] || [ "$path" = "-" ] || [ ! -d "$path" ]; then
      printf 'omitted %s (%s): worktree path is missing or not an existing directory: %s\n' \
        "$id" "$state" "${path:-(none)}" >&2
      continue
    fi
    eligible=$(jq -c --argjson task "$(jq -c --arg id "$id" '.in_flight[] | select(.id == $id)' <<<"$snapshot")" \
      --arg id "$id" --arg worktree "$path" \
      '.in_flight += [$task] | .paths += [{id:$id,worktree:$worktree}]' <<<"$eligible")
  done < <(jq -c '[.paths as $paths | .in_flight[] as $task | (($paths | map(select(.id == $task.id)) | first) // {}) as $path | $task + {worktree:($path.worktree // null)}][]' <<<"$snapshot")

  selection=$(fm_agenttrail_select_json "$eligible" 12)

  while IFS= read -r row; do
    path=$(jq -r '.worktree // empty' <<<"$row")
    project_args+=(--project "$path")
  done < <(jq -c '.selected[]' <<<"$selection")

  if [ "${#project_args[@]}" -eq 0 ]; then
    printf 'fm-agenttrail-kitchen: no existing in-flight worktrees to add\n' >&2
    return 1
  fi

  while IFS=$'\t' read -r id state path reason; do
    [ -n "$id" ] || continue
    printf 'omitted %s (%s): %s\n' "$id" "$state" "$reason" >&2
  done < <(jq -r '.omitted[] | [.id,.state,(.worktree // "(none)"),.reason] | @tsv' <<<"$selection")

  local -a kitchen_args=(/Users/irene/.local/bin/agenttrail-kitchen "${project_args[@]}")
  printf -v command_string '%q ' "${kitchen_args[@]}"
  command_string=${command_string% }
  printf '%s\n' "$command_string"
  if [ "$mode" = run ]; then
    /Users/irene/.local/bin/agenttrail-kitchen "${project_args[@]}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  fm_agenttrail_main "$@"
fi
