#!/usr/bin/env bash
# fm-work-item.sh - the durable per-task work-item reference store.
#
# A task usually traces back to an issue in the MANAGED PROJECT's tracker, not
# in this repository, so the store is forge- and host-agnostic: it keeps the
# full URL plus the parsed forge, host, project path, owner, repository, number,
# and item kind. A task may carry several references or none.
#
# This script owns STORAGE and TRANSPORT only. Deciding which work item a task
# references, resolving it against a project's registry, and refreshing per-forge
# enrichment belong to the project-issue-linkage owner, which calls `add` and
# `enrich` here rather than inventing a second schema.
#
# The store lives at data/<task-id>/work-items.json (schema fm-work-items.v1),
# beside the scout report and the outcome manifest, so it survives teardown into
# durable history. bin/fm-outcome-manifest.sh embeds a copy in the manifest, and
# bin/fm-fleet-snapshot.sh exposes it for live tasks.
#
# Usage:
#   fm-work-item.sh add <task-id> <url> [--origin intake|pr-linked]
#                                       [--forge <token>] [--title <text>]
#                                       [--state open|closed|merged|unknown]
#                                       [--observed-at <iso>] [--source <token>]
#   fm-work-item.sh remove <task-id> <url>
#   fm-work-item.sh clear <task-id>
#   fm-work-item.sh list <task-id>
#   fm-work-item.sh parse <url> [--forge <token>]
#
# add is upsert-by-URL: re-adding a known reference updates its origin and
# enrichment in place and never duplicates it, so a resolver may run repeatedly.
# Insertion order is preserved. --origin defaults to intake, marking a reference
# the captain or brief declared; pr-linked marks one derived later from a PR's
# linked-issue metadata.
#
# Enrichment (title and open/closed state) is optional and nullable by contract.
# Every consumer must render a reference that has never been enriched, so a
# forge that cannot be reached is never a rendering failure.
#
# docs/fleet-data-contracts.md owns field ownership and consumer guarantees.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-outcome-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-outcome-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-work-item.sh add <task-id> <url> [--origin intake|pr-linked]
                                           [--forge <token>] [--title <text>]
                                           [--state open|closed|merged|unknown]
                                           [--observed-at <iso>] [--source <token>]
       fm-work-item.sh remove <task-id> <url>
       fm-work-item.sh clear <task-id>
       fm-work-item.sh list <task-id>
       fm-work-item.sh parse <url> [--forge <token>]

Maintain data/<task-id>/work-items.json (schema fm-work-items.v1), the durable
forge- and host-agnostic work-item references for one task.

add upserts by canonical URL and preserves insertion order. --forge overrides
the host-derived forge for a self-hosted instance; without it github.com and
gitlab hosts or paths are recognized and every other host stores forge=unknown
rather than guessing. Enrichment fields stay nullable: consumers must render a
reference that has never been enriched.

list always prints a valid document, including for a task with no store.
parse prints the normalized reference for one URL without touching any store.
EOF
}

command -v jq >/dev/null 2>&1 || { echo "fm-work-item: jq not found" >&2; exit 1; }

ORIGIN=intake
FORGE=
TITLE=
STATE=
OBSERVED=
SOURCE=

parse_enrichment_opts() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --origin) [ "$#" -ge 2 ] || return 2; ORIGIN=$2; shift 2 ;;
      --forge) [ "$#" -ge 2 ] || return 2; FORGE=$2; shift 2 ;;
      --title) [ "$#" -ge 2 ] || return 2; TITLE=$2; shift 2 ;;
      --state) [ "$#" -ge 2 ] || return 2; STATE=$2; shift 2 ;;
      --observed-at) [ "$#" -ge 2 ] || return 2; OBSERVED=$2; shift 2 ;;
      --source) [ "$#" -ge 2 ] || return 2; SOURCE=$2; shift 2 ;;
      *) return 2 ;;
    esac
  done
  fm_outcome_work_item_origin_valid "$ORIGIN" || {
    echo "fm-work-item: --origin must be intake or pr-linked" >&2
    return 2
  }
  fm_outcome_work_item_state_valid "$STATE" || {
    echo "fm-work-item: --state must be open, closed, merged, or unknown" >&2
    return 2
  }
  if [ -n "$OBSERVED" ] && ! fm_outcome_iso_valid "$OBSERVED"; then
    echo "fm-work-item: --observed-at must be an ISO-8601 UTC stamp" >&2
    return 2
  fi
  if [ -n "$FORGE" ] && ! fm_outcome_forge_token_valid "$FORGE"; then
    echo "fm-work-item: --forge must be a short lowercase token" >&2
    return 2
  fi
}

cmd_add() {  # <id> <url> [opts...]
  local id=$1 url=$2 ref refs
  shift 2
  parse_enrichment_opts "$@" || return $?
  ref=$(fm_outcome_work_item_json "$url" "$ORIGIN" "$FORGE" "$TITLE" "$STATE" "$OBSERVED" "$SOURCE") || {
    echo "fm-work-item: could not parse work-item URL: $url" >&2
    return 2
  }
  refs=$(fm_outcome_work_items_read "$DATA" "$id" \
    | jq -c --argjson ref "$ref" '
        .references as $existing
        | if ($existing | map(.url) | index($ref.url)) == null
          then $existing + [$ref]
          else ($existing | map(if .url == $ref.url then $ref else . end))
          end') || return 1
  fm_outcome_work_items_write "$DATA" "$id" "$refs" || {
    echo "fm-work-item: could not write the work-item store for $id" >&2
    return 1
  }
  printf '%s\n' "$(fm_outcome_work_items_path "$DATA" "$id")"
}

cmd_remove() {  # <id> <url>
  local id=$1 url=$2 refs
  fm_outcome_work_item_parse "$url" || {
    echo "fm-work-item: could not parse work-item URL: $url" >&2
    return 2
  }
  refs=$(fm_outcome_work_items_read "$DATA" "$id" \
    | jq -c --arg url "$FM_WI_URL" '[.references[] | select(.url != $url)]') || return 1
  fm_outcome_work_items_write "$DATA" "$id" "$refs" || return 1
}

cmd_clear() {  # <id>
  fm_outcome_work_items_write "$DATA" "$1" '[]'
}

cmd_list() {  # <id>
  fm_outcome_work_items_read "$DATA" "$1"
}

cmd_parse() {  # <url> [opts...]
  local url=$1
  shift
  parse_enrichment_opts "$@" || return $?
  fm_outcome_work_item_json "$url" "$ORIGIN" "$FORGE" "$TITLE" "$STATE" "$OBSERVED" "$SOURCE" || {
    echo "fm-work-item: could not parse work-item URL: $url" >&2
    return 2
  }
}

require_id() {  # <id>
  fm_task_id_path_safe "$1" || { echo "fm-work-item: invalid task id" >&2; exit 2; }
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  add)
    shift
    [ "$#" -ge 2 ] || { usage >&2; exit 2; }
    require_id "$1"
    cmd_add "$@"
    ;;
  remove)
    shift
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    require_id "$1"
    cmd_remove "$1" "$2"
    ;;
  clear)
    shift
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    require_id "$1"
    cmd_clear "$1"
    ;;
  list)
    shift
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    require_id "$1"
    cmd_list "$1"
    ;;
  parse)
    shift
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    cmd_parse "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
