#!/usr/bin/env bash
# Close completed tasks into the private history archive.
#
# Usage: fm-close.sh [--review] [--retained <destination>] [--follow-up <task-id>] <selector>...
#        fm-close.sh --accept-close --actor <actor> --evidence <text> [--limitations <text>] <selector>
#
# A selector is a canonical task id, an active t1-t99 reference, or an
# unambiguous active human name. Review mode is read-only and prints the exact
# proposed disposition, retained material, existing next work, and any blocker.
# Normal mode independently verifies and closes at most 25 selectors. It first
# requires the accepted lifecycle route owned by docs/task-lifecycle.md to be
# complete. --accept-close is the only combined acceptance/closure path and is
# limited to one explicit close-route task with no unresolved captain call. It
# calls fm-teardown.sh when a terminal task still has a live task record, so the
# existing landed-work, captain-hold, public-commitment, and guarded cleanup
# checks stay authoritative. It then archives the task's useful private material,
# removes the Done row only through the configured tasks-axi backend, retires the
# short reference through fm-callsigns-lib.sh, and publishes the closure record.
#
# Archive: data/closed-tasks/<canonical-id>/closure.json plus any regular
# brief.md, launch-brief.md, report.md, lifecycle.json, task.txt, notes.md, and
# status.log. The closure record embeds acceptance and selected-route evidence.
# The closure record preserves explicit created, started, completed, and closed dates when their authoritative source exists; missing dates remain null.
# Prepared archive records are hidden from fm-history.sh and make an interrupted
# close retryable by canonical id or human name. A second close of an already
# closed canonical id or unambiguous name is an idempotent success.
#
# --retained records an additional knowledge destination already chosen and
# written through the normal knowledge-routing rules. It never writes that
# destination itself. --follow-up records an existing authorized follow-up id;
# this command never invents or creates follow-up work. These flags require one
# selector so their ownership is unambiguous.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ARCHIVE_ROOT="$DATA/closed-tasks"
MAX_BATCH=25

# shellcheck source=bin/fm-callsigns-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-callsigns-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

fail() { printf 'fm-close: %s\n' "$*" >&2; return 1; }

REVIEW=0
ACCEPT_CLOSE=0
ACCEPT_ACTOR=
ACCEPT_EVIDENCE=
ACCEPT_LIMITATIONS='none declared'
SELECTORS=()
EXTRA_RETAINED=()
EXTRA_FOLLOWUPS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --review) REVIEW=1; shift ;;
    --accept-close) ACCEPT_CLOSE=1; shift ;;
    --actor)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      ACCEPT_ACTOR=$2; shift 2
      ;;
    --evidence)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      ACCEPT_EVIDENCE=$2; shift 2
      ;;
    --limitations)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      ACCEPT_LIMITATIONS=$2; shift 2
      ;;
    --retained)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      EXTRA_RETAINED+=("$2"); shift 2
      ;;
    --follow-up)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      EXTRA_FOLLOWUPS+=("$2"); shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    --*) printf 'fm-close: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) SELECTORS+=("$1"); shift ;;
  esac
done
[ "${#SELECTORS[@]}" -gt 0 ] || { usage >&2; exit 2; }
[ "${#SELECTORS[@]}" -le "$MAX_BATCH" ] || { fail "a batch may contain at most $MAX_BATCH tasks"; exit 2; }
if { [ "${#EXTRA_RETAINED[@]}" -gt 0 ] || [ "${#EXTRA_FOLLOWUPS[@]}" -gt 0 ] || [ "$ACCEPT_CLOSE" -eq 1 ]; } \
   && [ "${#SELECTORS[@]}" -ne 1 ]; then
  fail "--retained, --follow-up, and --accept-close require exactly one selector"
  exit 2
fi
if [ "$ACCEPT_CLOSE" -eq 1 ]; then
  [ "$REVIEW" -eq 0 ] || { fail "--accept-close cannot be combined with --review"; exit 2; }
  [ -n "$ACCEPT_ACTOR" ] && [ -n "$ACCEPT_EVIDENCE" ] \
    || { fail "--accept-close requires --actor and --evidence"; exit 2; }
elif [ -n "$ACCEPT_ACTOR" ] || [ -n "$ACCEPT_EVIDENCE" ] || [ "$ACCEPT_LIMITATIONS" != 'none declared' ]; then
  fail "--actor, --evidence, and --limitations require --accept-close"
  exit 2
fi
command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

snapshot() {
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json
}

archive_match() {  # <selector>; sets ARCHIVE_MATCH_FILE
  local selector=$1 file found=0 id name disposition
  ARCHIVE_MATCH_FILE=
  [ -d "$ARCHIVE_ROOT" ] && [ ! -L "$ARCHIVE_ROOT" ] || return 1
  for file in "$ARCHIVE_ROOT"/*/closure.json; do
    [ -d "${file%/*}" ] && [ ! -L "${file%/*}" ] || continue
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    id=$(jq -r '.id // empty' "$file" 2>/dev/null) || continue
    [ "${file%/*}" = "$ARCHIVE_ROOT/$id" ] || continue
    name=$(jq -r '.name // empty' "$file" 2>/dev/null) || continue
    disposition=$(jq -r '.disposition // empty' "$file" 2>/dev/null) || continue
    case "$disposition" in prepared|closed) ;; *) continue ;; esac
    if [ "$selector" = "$id" ] || [ "$selector" = "$name" ]; then
      found=$((found + 1))
      ARCHIVE_MATCH_FILE=$file
    fi
  done
  if [ "$found" -eq 1 ]; then return 0; fi
  if [ "$found" -gt 1 ]; then
    fail "ambiguous closed-task name '$selector'; use a canonical id"
  fi
  ARCHIVE_MATCH_FILE=
  return 1
}

preview_callsign_record() {  # <selector>; prints id<TAB>ref<TAB>name without durable writes
  local selector=$1 preview line rc=0
  preview=$(mktemp -d "${TMPDIR:-/tmp}/fm-close-callsigns.XXXXXX") || return 1
  if [ -f "$FM_CALLSIGNS_FILE" ] && [ ! -L "$FM_CALLSIGNS_FILE" ]; then
    cp "$FM_CALLSIGNS_FILE" "$preview/callsigns.tsv" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    FM_CALLSIGNS_FILE="$preview/callsigns.tsv" FM_CALLSIGNS_LOCK="$preview/lock" \
      fm_callsigns_sync >/dev/null 2>&1 || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    line=$(awk -F '\t' -v selector="$selector" '
      $6 == "" && ($1 == selector || $2 == selector || $3 == selector || "fm-" $1 == selector) {
        found++; value=$1 "\t" $2 "\t" $3
      }
      END {if (found == 1) print value; else exit 1}
    ' "$preview/callsigns.tsv") || rc=1
  fi
  rm -rf -- "$preview"
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$line"
}

has_lifecycle_record() {  # <canonical-id>
  fm_task_id_path_safe "$1" \
    && [ -f "$DATA/task-lifecycle/$1.json" ] && [ ! -L "$DATA/task-lifecycle/$1.json" ]
}

active_id_from_snapshot() {  # <snapshot-json> <selector> <allow-sync:0|1>
  local fleet=$1 selector=$2 allow_sync=$3 matches resolved preview
  matches=$(printf '%s\n' "$fleet" | jq --arg selector "$selector" \
    '[.backlog.records[]? | select(.structured == true and .id == $selector)] | length') || return 1
  if [ "$matches" -eq 1 ] || has_lifecycle_record "$selector"; then printf '%s\n' "$selector"; return 0; fi
  if [ -f "$FM_CALLSIGNS_FILE" ] && [ ! -L "$FM_CALLSIGNS_FILE" ]; then
    resolved=$(fm_callsigns_lookup_id "$selector" 2>/dev/null || true)
    if [ -n "$resolved" ]; then
      matches=$(printf '%s\n' "$fleet" | jq --arg id "$resolved" \
        '[.backlog.records[]? | select(.structured == true and .id == $id)] | length') || return 1
      if [ "$matches" -eq 1 ] || has_lifecycle_record "$resolved"; then printf '%s\n' "$resolved"; return 0; fi
    fi
  fi
  if [ "$allow_sync" = 0 ]; then
    preview=$(preview_callsign_record "$selector" 2>/dev/null || true)
    resolved=${preview%%$'\t'*}
    [ -n "$resolved" ] || return 1
    matches=$(printf '%s\n' "$fleet" | jq --arg id "$resolved" \
      '[.backlog.records[]? | select(.structured == true and .id == $id)] | length') || return 1
    [ "$matches" -eq 1 ] || has_lifecycle_record "$resolved" || return 1
    printf '%s\n' "$resolved"
    return 0
  fi
  resolved=$(fm_callsign_resolve "$selector" 2>/dev/null || true)
  [ -n "$resolved" ] || return 1
  matches=$(printf '%s\n' "$fleet" | jq --arg id "$resolved" \
    '[.backlog.records[]? | select(.structured == true and .id == $id)] | length') || return 1
  [ "$matches" -eq 1 ] || has_lifecycle_record "$resolved" || return 1
  printf '%s\n' "$resolved"
}

callsign_fields() {  # <id> <row-json> <allow-sync:0|1>; prints ref<TAB>name
  local id=$1 row=$2 allow_sync=$3 line title preview
  if [ "$allow_sync" = 1 ]; then fm_callsigns_sync >/dev/null 2>&1 || return 1; fi
  if [ -f "$FM_CALLSIGNS_FILE" ] && [ ! -L "$FM_CALLSIGNS_FILE" ]; then
    line=$(awk -F '\t' -v id="$id" '$1 == id && $6 == "" {print $2 "\t" $3; exit}' "$FM_CALLSIGNS_FILE")
    if [ -n "$line" ]; then printf '%s\n' "$line"; return 0; fi
  fi
  if [ "$allow_sync" = 0 ]; then
    preview=$(preview_callsign_record "$id" 2>/dev/null || true)
    line=${preview#*$'\t'}
    if [ -n "$preview" ] && [ "$line" != "$preview" ]; then printf '%s\n' "$line"; return 0; fi
  fi
  title=$(printf '%s\n' "$row" | jq -r '.title // empty') || return 1
  printf -- '-\t%s\n' "$(fm_callsign_shorthand_name "$title" "$id")"
}

row_for_id() {  # <snapshot-json> <id>
  printf '%s\n' "$1" | jq -c --arg id "$2" \
    '[.backlog.records[]? | select(.structured == true and .id == $id)] | if length == 1 then .[0] else empty end'
}

followups_for_id() {  # <snapshot-json> <id>
  printf '%s\n' "$1" | jq -r --arg id "$2" \
    '.backlog.records[]? | select(.structured == true and (.state == "queued" or .state == "in_flight"))
      | select((.blocked_by_ids // []) | index($id)) | .id'
}

check_captain_hold() {  # <id>
  local id=$1 out rc=0
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" 2>&1) || rc=$?
  case "$rc" in
    0) fail "task $id still has an unresolved captain decision" ;;
    1) return 0 ;;
    *) [ -z "$out" ] || printf '%s\n' "$out" >&2; fail "cannot verify captain decisions for task $id" ;;
  esac
}

check_public_commitments() {  # <id>
  local id=$1 out
  if ! out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-public-followup.sh" guard-work main "$id" 2>&1); then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    fail "task $id still has an unresolved public commitment"
    return 1
  fi
}

lifecycle_close_check() {  # <id>; prints accepted lifecycle JSON
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-task-lifecycle.sh" close-check "$1"
}

ensure_close_lifecycle() {  # <id>; sets CLOSE_LIFECYCLE
  local id=$1 out
  check_captain_hold "$id" || return 1
  check_public_commitments "$id" || return 1
  if out=$(lifecycle_close_check "$id" 2>/dev/null); then
    CLOSE_LIFECYCLE=$out
    return 0
  fi
  if [ "$ACCEPT_CLOSE" -eq 1 ]; then
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-task-lifecycle.sh" accept-close "$id" \
      --actor "$ACCEPT_ACTOR" --evidence "$ACCEPT_EVIDENCE" --limitations "$ACCEPT_LIMITATIONS" >/dev/null \
      || return 1
    out=$(lifecycle_close_check "$id") || return 1
    CLOSE_LIFECYCLE=$out
    return 0
  fi
  lifecycle_close_check "$id" >/dev/null
}

closure_lifecycle() {  # <closure-json>; prints lifecycle when the selected route is complete
  jq -ce '
    .lifecycle as $l
    | select($l != null and $l.acceptance != null)
    | select(
        ($l.stage == "accepted" and $l.acceptance.route == "close")
        or ($l.stage == "delivering" and $l.acceptance.route == "deliver" and (($l.delivery.completedAt // "") != ""))
        or ($l.stage == "monitoring" and $l.acceptance.route == "deliver-monitor" and (($l.monitoring.completedAt // "") != "")))
    | $l
  ' "$1" 2>/dev/null
}

retire_lifecycle_record() {  # <id>
  local file
  file="$DATA/task-lifecycle/$1.json"
  if [ -L "$file" ]; then fail "lifecycle record is unsafe at $file"; return 1; fi
  [ ! -e "$file" ] || rm -f -- "$file"
}

remaining_resource() {  # <id>; prints first live resource
  local id=$1 path
  for path in \
    "$STATE/$id.meta" "$STATE/$id.backlog-close" "$STATE/$id.check.sh" \
    "$STATE/$id.check-trust" "$STATE/$id.pr-poll" "$STATE/$id.pr-poll-registration" \
    "$STATE/$id.busy-state" "$STATE/$id.busy-gen" "$STATE/$id.turn-ended" \
    "$STATE/$id.progress" "$STATE/$id.inbox"; do
    if [ -e "$path" ] || [ -L "$path" ]; then printf '%s\n' "$path"; return 0; fi
  done
  return 1
}

row_artifacts() {  # <row-json>
  local row=$1 value
  for field in pr_url report_path; do
    value=$(printf '%s\n' "$row" | jq -r --arg field "$field" '.[$field] // empty') || return 1
    [ -z "$value" ] || printf '%s\n' "$value"
  done
  printf '%s\n' "$row" | jq -r '.links[]?'
}

row_result() {  # <row-json> [terminal-result]
  local row=$1 terminal=${2:-} value
  if [ -n "$terminal" ]; then printf '%s\n' "$terminal"; return 0; fi
  value=$(printf '%s\n' "$row" | jq -r '.pr_url // empty')
  if [ -n "$value" ]; then printf 'Delivered in %s\n' "$value"; return 0; fi
  value=$(printf '%s\n' "$row" | jq -r '.report_path // empty')
  if [ -n "$value" ]; then printf 'Report completed at %s\n' "$value"; return 0; fi
  value=$(printf '%s\n' "$row" | jq -r '.local_note // empty')
  if [ -n "$value" ]; then printf 'Delivered to %s\n' "$value"; return 0; fi
  value=$(printf '%s\n' "$row" | jq -r '.body_excerpt // empty')
  [ -z "$value" ] || { printf '%s\n' "$value"; return 0; }
  printf 'Completed\n'
}

planned_retained() {  # <id>; one destination per line
  local id=$1 source name data_label
  data_label=$(fm_backlog_data_relative "$DATA" 2>/dev/null || printf 'data')
  for name in brief.md launch-brief.md report.md; do
    source="$DATA/$id/$name"
    [ -f "$source" ] && [ ! -L "$source" ] || continue
    printf '%s/closed-tasks/%s/%s\n' "$data_label" "$id" "$name"
  done
  [ ! -f "$DATA/task-lifecycle/$id.json" ] || printf '%s/closed-tasks/%s/lifecycle.json\n' "$data_label" "$id"
  printf '%s/closed-tasks/%s/task.txt\n' "$data_label" "$id"
  printf '%s/closed-tasks/%s/notes.md\n' "$data_label" "$id"
  for source in ${EXTRA_RETAINED[@]+"${EXTRA_RETAINED[@]}"}; do printf '%s\n' "$source"; done
}

review_one() {  # <id> <row-json> <ref> <name> <snapshot-json> [terminal]
  local id=$1 row=$2 ref=$3 name=$4 fleet=$5 terminal=${6:-} project kind result artifacts retained followups resource lifecycle lifecycle_error route actor
  project=$(printf '%s\n' "$row" | jq -r '.repo // "-"')
  kind=$(printf '%s\n' "$row" | jq -r '.kind // "task"')
  result=$(row_result "$row" "$terminal")
  artifacts=$(row_artifacts "$row" || true)
  retained=$(planned_retained "$id")
  followups=$(followups_for_id "$fleet" "$id")
  for resource in ${EXTRA_FOLLOWUPS[@]+"${EXTRA_FOLLOWUPS[@]}"}; do
    followups=${followups:+$followups$'\n'}$resource
  done
  printf 'Proposed closure: %s (%s, %s)\n' "$name" "$id" "$ref"
  printf 'Project: %s\nKind: %s\nResult: %s\n' "$project" "$kind" "$result"
  if [ -n "$artifacts" ]; then printf 'Artifacts:\n%s\n' "$(printf '%s\n' "$artifacts" | sed 's/^/- /')"; else printf 'Artifacts: none recorded\n'; fi
  printf 'Retained knowledge and task material:\n%s\n' "$(printf '%s\n' "$retained" | sed 's/^/- /')"
  if [ -n "$followups" ]; then
    printf 'Next-work recommendations:\n%s\n' "$(printf '%s\n' "$followups" | awk '!seen[$0]++' | sed 's/^/- Continue existing task /')"
  else
    printf 'Next-work recommendations: none; no follow-up will be created automatically.\n'
  fi
  if [ -f "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ]; then
    printf 'Cleanup: guarded cleanup is still required before archival.\n'
  elif resource=$(remaining_resource "$id"); then
    printf 'Cleanup blocker: remaining resource %s cannot be retired without its task record.\n' "$resource"
  else
    printf 'Cleanup: already complete.\n'
  fi
  if lifecycle=$(lifecycle_close_check "$id" 2>/dev/null); then
    route=$(printf '%s\n' "$lifecycle" | jq -r '.acceptance.route')
    actor=$(printf '%s\n' "$lifecycle" | jq -r '.acceptance.actor')
    printf 'Lifecycle: accepted by %s; route %s is complete.\n' "$actor" "$route"
  else
    lifecycle_error=$(lifecycle_close_check "$id" 2>&1 || true)
    printf 'Lifecycle blocker: %s\n' "${lifecycle_error#fm-task-lifecycle: }"
  fi
  printf 'Review only: nothing changed.\n'
}

validate_extra_followups() {  # <snapshot-json>
  local fleet=$1 follow count
  for follow in ${EXTRA_FOLLOWUPS[@]+"${EXTRA_FOLLOWUPS[@]}"}; do
    count=$(printf '%s\n' "$fleet" | jq --arg id "$follow" \
      '[.backlog.records[]? | select(.structured == true and .id == $id and .state != "done")] | length') || return 1
    [ "$count" -eq 1 ] || { fail "follow-up $follow is not one current active task"; return 1; }
  done
}

prepare_archive() {  # <id> <row> <ref> <name> <result> <followups-newline> <started-at> <lifecycle-json>
  local id=$1 row=$2 ref=$3 name=$4 result=$5 followups=$6 started=$7 lifecycle=$8 target stage source file body
  local closed_at now data_label artifacts_file retained_file followups_file closure_tmp
  target="$ARCHIVE_ROOT/$id"
  [ ! -e "$target" ] && [ ! -L "$target" ] || { fail "archive target already exists for $id"; return 1; }
  if [ -e "$ARCHIVE_ROOT" ] || [ -L "$ARCHIVE_ROOT" ]; then
    [ -d "$ARCHIVE_ROOT" ] && [ ! -L "$ARCHIVE_ROOT" ] || { fail "closed-task archive is unsafe at $ARCHIVE_ROOT"; return 1; }
  else
    (umask 077; mkdir -p "$ARCHIVE_ROOT") || return 1
  fi
  stage="$ARCHIVE_ROOT/.$id.closing.$$"
  [ ! -e "$stage" ] && [ ! -L "$stage" ] || { fail "archive staging path already exists for $id"; return 1; }
  (umask 077; mkdir "$stage") || return 1
  for file in brief.md launch-brief.md report.md; do
    source="$DATA/$id/$file"
    [ -f "$source" ] && [ ! -L "$source" ] || continue
    cp "$source" "$stage/$file" || { rm -rf -- "$stage"; return 1; }
    chmod 0600 "$stage/$file"
  done
  if [ -f "$STATE/$id.status" ] && [ ! -L "$STATE/$id.status" ]; then
    cp "$STATE/$id.status" "$stage/status.log" || { rm -rf -- "$stage"; return 1; }
    chmod 0600 "$stage/status.log"
  fi
  printf '%s\n' "$lifecycle" | jq . > "$stage/lifecycle.json" || { rm -rf -- "$stage"; return 1; }
  chmod 0600 "$stage/lifecycle.json"
  if [ "$(printf '%s\n' "$row" | jq -r '._lifecycle_only // false')" = true ]; then
    {
      printf 'Task: %s\n' "$id"
      printf '  id: %s\n' "$id"
      printf '  title: %s\n' "$name"
      printf '  state: done\n'
      printf '  body: -\n'
      printf '  source: retained lifecycle record; backlog Done row already rotated\n'
    } > "$stage/task.txt" || { rm -rf -- "$stage"; return 1; }
  else
    fm_backlog_row_show "$DATA" "$id" --full > "$stage/task.txt" || { rm -rf -- "$stage"; return 1; }
  fi
  chmod 0600 "$stage/task.txt"
  body=$(printf '%s\n' "$row" | jq -r '.body_lines[]?' 2>/dev/null || true)
  printf '%s\n' "$body" > "$stage/notes.md" || { rm -rf -- "$stage"; return 1; }
  chmod 0600 "$stage/notes.md"
  artifacts_file="$stage/.artifacts"
  retained_file="$stage/.retained"
  followups_file="$stage/.followups"
  row_artifacts "$row" | awk 'NF && !seen[$0]++' > "$artifacts_file" || { rm -rf -- "$stage"; return 1; }
  planned_retained "$id" | awk 'NF && !seen[$0]++' > "$retained_file" || { rm -rf -- "$stage"; return 1; }
  printf '%s\n' "$followups" | awk 'NF && !seen[$0]++' > "$followups_file"
  closed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  now=$(date +%s)
  data_label=$(fm_backlog_data_relative "$DATA" 2>/dev/null || printf 'data')
  closure_tmp="$stage/closure.json"
  jq -n \
    --arg disposition prepared --arg id "$id" --arg ref "$ref" --arg name "$name" \
    --arg project "$(printf '%s\n' "$row" | jq -r '.repo // "-"')" \
    --arg kind "$(printf '%s\n' "$row" | jq -r '.kind // "task"')" \
    --arg created "$(printf '%s\n' "$row" | jq -r '.since // empty')" \
    --arg started "$started" \
    --arg completed "$(printf '%s\n' "$row" | jq -r '.done // .completion.date // empty')" \
    --arg closed "$closed_at" --argjson closedEpoch "$now" --arg result "$result" \
    --arg archive "$data_label/closed-tasks/$id" \
    --argjson artifacts "$(jq -Rn '[inputs]' < "$artifacts_file")" \
    --argjson retained "$(jq -Rn '[inputs]' < "$retained_file")" \
    --argjson followUps "$(jq -Rn '[inputs]' < "$followups_file")" \
    --argjson lifecycle "$lifecycle" \
    '{version:2, disposition:$disposition, id:$id, ref:$ref, name:$name,
      project:$project, kind:$kind,
      dates:{created:(if $created=="" then null else $created end),
             started:(if $started=="" then null else $started end),
             completed:(if $completed=="" then null else $completed end), closed:$closed},
      closedEpoch:$closedEpoch, result:$result, artifacts:$artifacts,
      retainedKnowledge:$retained, followUps:$followUps, lifecycle:$lifecycle, archive:$archive}' \
    > "$closure_tmp" || { rm -rf -- "$stage"; return 1; }
  chmod 0600 "$closure_tmp"
  rm -f -- "$artifacts_file" "$retained_file" "$followups_file"
  mv "$stage" "$target" || { rm -rf -- "$stage"; return 1; }
  PREPARED_CLOSURE="$target/closure.json"
}

finalize_archive() {  # <closure-json>
  local closure=$1 tmp="$1.tmp.$$"
  [ -f "$closure" ] && [ ! -L "$closure" ] || { fail "closure record is unsafe at $closure"; return 1; }
  jq '.disposition = "closed"' "$closure" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp"
  mv -f "$tmp" "$closure"
}

retire_reference() {  # <epoch>
  fm_callsigns_sync "$1" || { fail "the backlog changed but the short reference could not be retired; retry by canonical id"; return 1; }
}

remove_done_row() {  # <snapshot-json> <id> [remove-row:1|0]
  local fleet=$1 id=$2 remove_row=${3:-1} dep failed=0
  local detached=()
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    if fm_backlog_mutate "$DATA" unblock "$dep" --by "$id"; then
      detached+=("$dep")
    else
      failed=1
      fail "could not detach completed dependency $id from follow-up $dep: $FM_BACKLOG_TRANSITION_ERROR"
      break
    fi
  done <<< "$(followups_for_id "$fleet" "$id")"
  if [ "$failed" -eq 0 ] && [ "$remove_row" -eq 1 ] && ! fm_backlog_mutate "$DATA" rm "$id"; then
    failed=1
    fail "could not remove Done task $id: $FM_BACKLOG_TRANSITION_ERROR"
  fi
  if [ "$failed" -ne 0 ]; then
    for dep in ${detached[@]+"${detached[@]}"}; do fm_backlog_mutate "$DATA" block "$dep" --by "$id" >/dev/null 2>&1 || true; done
    return 1
  fi
}

close_prepared() {  # <closure-json> <snapshot-json>
  local closure=$1 fleet=$2 id disposition row resource now kind
  id=$(jq -r '.id // empty' "$closure") || return 1
  disposition=$(jq -r '.disposition // empty' "$closure") || return 1
  if [ -z "$id" ] || ! fm_task_id_path_safe "$id" || [ "${closure%/*}" != "$ARCHIVE_ROOT/$id" ]; then
    fail "invalid prepared closure record at $closure"
    return 1
  fi
  if [ "$disposition" = closed ]; then
    printf 'already closed: %s (%s)\n' "$id" "$(jq -r '.name // .id' "$closure")"
    return 0
  fi
  [ "$disposition" = prepared ] || { fail "invalid closure disposition for $id"; return 1; }
  closure_lifecycle "$closure" >/dev/null \
    || { fail "prepared task $id has no accepted, completed lifecycle route"; return 1; }
  if resource=$(remaining_resource "$id"); then
    fail "task $id still has a live resource at $resource"
    return 1
  fi
  check_captain_hold "$id" || return 1
  check_public_commitments "$id" || return 1
  row=$(row_for_id "$fleet" "$id")
  if [ -n "$row" ]; then
    [ "$(printf '%s\n' "$row" | jq -r '.state')" = "done" ] || { fail "prepared task $id is no longer Done"; return 1; }
    kind=$(jq -r '.kind // "task"' "$closure") || return 1
    if fm_backlog_transition_applies "$CONFIG" "$DATA" "$kind"; then :; else
      fail "automatic closure is unavailable: ${FM_BACKLOG_TRANSITION_SKIP:-$FM_BACKLOG_TRANSITION_ERROR}"
      return 1
    fi
    remove_done_row "$fleet" "$id" || return 1
  fi
  if resource=$(remaining_resource "$id"); then
    fail "task $id still has a live resource at $resource"
    return 1
  fi
  now=$(date +%s)
  retire_lifecycle_record "$id" || return 1
  retire_reference "$now" || return 1
  finalize_archive "$closure" || return 1
  printf 'closed: %s (%s) -> %s\n' "$id" "$(jq -r '.name // .id' "$closure")" "$(jq -r '.archive' "$closure")"
}

close_one() {  # <selector>
  local selector=$1 fleet id row fields ref name state kind current terminal='' out rc resource lifecycle_checked=0 backlog_present=1
  local followups follow result lock closure existing_archive now started=''
  CLOSE_LIFECYCLE=
  fleet=$(snapshot) || { fail "could not read current tasks"; return 1; }
  id=$(active_id_from_snapshot "$fleet" "$selector" "$((1 - REVIEW))" || true)
  if [ -z "$id" ]; then
    if archive_match "$selector"; then
      if [ "$REVIEW" = 1 ]; then
        if [ "$(jq -r '.disposition' "$ARCHIVE_MATCH_FILE")" = closed ]; then
          printf 'Already closed: %s (%s).\nReview only: nothing changed.\n' \
            "$(jq -r '.name' "$ARCHIVE_MATCH_FILE")" "$(jq -r '.id' "$ARCHIVE_MATCH_FILE")"
          return 0
        fi
        printf 'Prepared closure awaiting completion: %s (%s).\nReview only: nothing changed.\n' \
          "$(jq -r '.name' "$ARCHIVE_MATCH_FILE")" "$(jq -r '.id' "$ARCHIVE_MATCH_FILE")"
        return 0
      fi
      id=$(jq -r '.id // empty' "$ARCHIVE_MATCH_FILE") || return 1
      fm_task_id_path_safe "$id" || { fail "invalid archived task identity"; return 1; }
      lock="$STATE/.close-$id.lock"
      fm_lock_try_acquire "$lock" || { fail "another close is already running for task $id"; return 1; }
      if close_prepared "$ARCHIVE_MATCH_FILE" "$fleet"; then rc=0; else rc=$?; fi
      fm_lock_release "$lock"
      return "$rc"
    fi
    fail "unknown task selector '$selector'"
    return 1
  fi
  fm_task_id_path_safe "$id" || { fail "task $id has an invalid canonical identity"; return 1; }
  row=$(row_for_id "$fleet" "$id")
  if [ -z "$row" ]; then
    has_lifecycle_record "$id" || { fail "task $id is not current"; return 1; }
    backlog_present=0
    row=$(jq -n --arg id "$id" '{id:$id,title:$id,state:"done",kind:"task",structured:true,unresolved_blocker_ids:[],_lifecycle_only:true}')
  fi
  state=$(printf '%s\n' "$row" | jq -r '.state')
  kind=$(printf '%s\n' "$row" | jq -r '.kind // "task"')
  if [ "$REVIEW" = 0 ] && [ "$backlog_present" -eq 1 ]; then
    if fm_backlog_transition_applies "$CONFIG" "$DATA" "$kind"; then :; else
      rc=$?
      if [ "$rc" -eq 1 ]; then fail "automatic closure is unavailable: $FM_BACKLOG_TRANSITION_SKIP"; else fail "$FM_BACKLOG_TRANSITION_ERROR"; fi
      return 1
    fi
  fi
  fields=$(callsign_fields "$id" "$row" "$((1 - REVIEW))") || { fail "could not resolve task name for $id"; return 1; }
  IFS=$'\t' read -r ref name <<< "$fields"
  validate_extra_followups "$fleet" || return 1
  if [ -f "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ]; then
    started=$(awk -F= '$1 == "started_at" {sub(/^[^=]*=/, ""); print; exit}' "$STATE/$id.meta")
    if [ "$state" = "done" ]; then
      current="done"
    else
      out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
        FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>&1) || true
      current=$(printf '%s\n' "$out" | sed -n 's/^state: *//p' | awk 'NR == 1 {print $1}')
      case "$current" in
        done) terminal=$(printf '%s\n' "$out" | sed -n 's/^detail: *//p' | head -1) ;;
        failed) terminal=$(printf '%s\n' "$out" | sed -n 's/^detail: *//p' | head -1); terminal="Failed${terminal:+: $terminal}" ;;
        *)
          [ "$REVIEW" = 1 ] && review_one "$id" "$row" "$ref" "$name" "$fleet" "$terminal"
          fail "task $id is not terminal (current state: ${current:-unknown})"
          return 1
          ;;
      esac
    fi
    if [ "$REVIEW" = 0 ]; then
      ensure_close_lifecycle "$id" || return 1
      lifecycle_checked=1
      if ! out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
        FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-teardown.sh" "$id" 2>&1); then
        printf '%s\n' "$out" >&2
        return 1
      fi
      fleet=$(snapshot) || { fail "could not read tasks after guarded cleanup"; return 1; }
      row=$(row_for_id "$fleet" "$id")
      [ -n "$row" ] || { fail "task $id vanished without a Done record after cleanup"; return 1; }
      state=$(printf '%s\n' "$row" | jq -r '.state')
    fi
  fi
  if [ "$state" != "done" ] && ! { [ "$REVIEW" = 1 ] && { [ "$current" = "done" ] || [ "$current" = "failed" ]; }; }; then
    [ "$REVIEW" = 1 ] && review_one "$id" "$row" "$ref" "$name" "$fleet" "$terminal"
    fail "task $id is not Done (backlog state: $state)"
    return 1
  fi
  if [ "$REVIEW" = 1 ]; then
    check_captain_hold "$id" || return 1
    check_public_commitments "$id" || return 1
  elif [ "$lifecycle_checked" -eq 0 ]; then
    ensure_close_lifecycle "$id" || return 1
    lifecycle_checked=1
  fi
  if resource=$(remaining_resource "$id"); then
    if ! { [ "$REVIEW" = 1 ] && [ "$resource" = "$STATE/$id.meta" ] && { [ "$current" = "done" ] || [ "$current" = "failed" ]; }; }; then
      [ "$REVIEW" = 1 ] && review_one "$id" "$row" "$ref" "$name" "$fleet" "$terminal"
      fail "task $id still has a live resource at $resource; reconcile guarded cleanup before closing"
      return 1
    fi
  fi
  followups=$(followups_for_id "$fleet" "$id")
  for follow in ${EXTRA_FOLLOWUPS[@]+"${EXTRA_FOLLOWUPS[@]}"}; do
    followups=${followups:+$followups$'\n'}$follow
  done
  followups=$(printf '%s\n' "$followups" | awk 'NF && !seen[$0]++')
  result=$(row_result "$row" "$terminal")
  if [ "$REVIEW" = 1 ]; then
    review_one "$id" "$row" "$ref" "$name" "$fleet" "$terminal"
    return 0
  fi
  lock="$STATE/.close-$id.lock"
  fm_lock_try_acquire "$lock" || { fail "another close is already running for task $id"; return 1; }
  existing_archive="$ARCHIVE_ROOT/$id/closure.json"
  if [ -f "$existing_archive" ] && [ ! -L "$existing_archive" ]; then
    if close_prepared "$existing_archive" "$fleet"; then rc=0; else rc=$?; fi
    fm_lock_release "$lock"
    return "$rc"
  fi
  PREPARED_CLOSURE=
  if ! prepare_archive "$id" "$row" "$ref" "$name" "$result" "$followups" "$started" "$CLOSE_LIFECYCLE"; then
    fm_lock_release "$lock"
    fail "could not prepare the private archive for task $id"
    return 1
  fi
  if ! remove_done_row "$fleet" "$id" "$backlog_present"; then
    fm_lock_release "$lock"
    return 1
  fi
  now=$(date +%s)
  if ! retire_lifecycle_record "$id" || ! retire_reference "$now" || ! finalize_archive "$PREPARED_CLOSURE"; then
    fm_lock_release "$lock"
    return 1
  fi
  closure=$PREPARED_CLOSURE
  fm_lock_release "$lock"
  printf 'closed: %s (%s) -> %s\n' "$id" "$name" "$(jq -r '.archive' "$closure")"
}

overall=0
for selector in ${SELECTORS[@]+"${SELECTORS[@]}"}; do
  close_one "$selector" || overall=1
done
exit "$overall"
