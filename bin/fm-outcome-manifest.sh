#!/usr/bin/env bash
# fm-outcome-manifest.sh - write and read the durable completion manifest.
#
# The manifest at data/<id>/outcome.json (schema fm-outcome-manifest.v1) is the
# ONE canonical completion artifact. bin/fm-teardown.sh publishes it atomically
# BEFORE it removes state/<id>.meta, so a task survives in durable history after
# its volatile records are gone and its Done backlog entry is pruned.
#
# Usage:
#   fm-outcome-manifest.sh write <task-id> [--forced] [--outcome <state>]
#                                          [--completed-at <iso>]
#   fm-outcome-manifest.sh show <task-id>
#   fm-outcome-manifest.sh list [--limit <n>]
#   fm-outcome-manifest.sh validate <task-id>
#
# write composes the manifest from records that still exist at completion time:
#   state/<id>.meta          kind, mode, yolo, project, harness, model, effort,
#                            backend/endpoint, worktree, task temp root, traceparent
#   data/backlog.md          the task title, from its structured row
#   state/<id>.status        the last terminal event, for outcome state and detail
#   data/<id>/report.md      the scout deliverable pointer
#   data/<id>/work-items.json  work-item references (bin/fm-work-item.sh owns the store)
#   state/<id>.pr-status     the normalized PR observation (bin/fm-pr-status.sh)
#   state/<id>.gbrain        the optional capture receipt, absent by default
# It never contacts a forge and never reads a brief, a prompt, a tool argument,
# or any credential-bearing artifact. Publication is refused outright when the
# composed document carries a key the fm-outcome-manifest.v1 allowlist in
# bin/fm-outcome-lib.sh does not name.
#
# write is idempotent for a given input state: rerunning it republishes the same
# document (modulo the completion timestamp), so a retried teardown is safe.
#
# Timestamps carry their provenance in timestamp_sources rather than pretending
# to a precision the records do not have: created comes from the brief's mtime
# and falls back to the backlog row's `since` date, started comes from the task
# metadata's mtime, and completed is the write time unless --completed-at names
# one. An explicit recorded value can supersede a source later without a schema
# change - only the timestamp_sources value moves.
#
# docs/fleet-data-contracts.md owns field ownership and consumer guarantees.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-outcome-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-outcome-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-outcome-manifest.sh write <task-id> [--forced] [--outcome <state>]
                                              [--completed-at <iso>]
       fm-outcome-manifest.sh show <task-id>
       fm-outcome-manifest.sh validate <task-id>
       fm-outcome-manifest.sh list [--limit <n>]

write composes data/<task-id>/outcome.json (schema fm-outcome-manifest.v1) from
the records that still exist at completion time and publishes it atomically.
Run it BEFORE removing state/<task-id>.meta; bin/fm-teardown.sh already does.
--forced records a discarding teardown, --outcome overrides the derived final
state (done|failed|discarded|retired|unknown), and --completed-at pins the
completion stamp instead of using the write time.

show prints one validated manifest, validate re-checks it against the field
allowlist, and list prints durable history as schema fm-outcome-history.v1,
newest completion first, disclosing unreadable records instead of dropping them.
FM_OUTCOME_HISTORY_LIMIT (default 40) sets the default list bound and
FM_OUTCOME_HISTORY_MAX_BYTES (default 65536) the per-manifest read bound.

Read-only apart from write. Never contacts a forge.
EOF
}

command -v jq >/dev/null 2>&1 || { echo "fm-outcome-manifest: jq not found" >&2; exit 1; }

# The title of the task's structured backlog row, from whichever section holds
# it. Free-text prose is capped and control characters stripped before it can
# reach a durable record.
backlog_title() {  # <id>
  local id=$1 line rest
  [ -f "$DATA/backlog.md" ] || return 0
  line=$(grep -E "^[-*][[:space:]]+(\[[ xX]\][[:space:]]+)?(\*\*)?$id(\*\*)?[[:space:]]+-[[:space:]]+" \
    "$DATA/backlog.md" 2>/dev/null | head -1) || true
  [ -n "$line" ] || return 0
  rest=${line#*"$id"}
  rest=${rest#*- }
  rest=$(printf '%s' "$rest" | sed -E \
    -e 's#<?https?://[^[:space:])">]+>?##g' \
    -e 's#[[:space:]]+data/[^[:space:])]+/report\.md##g' \
    -e 's#\([^)]*\)##g' \
    -e 's#blocked-by:[[:space:]]+[^[:space:])]+##g' \
    -e 's#[[:space:]]+-[[:space:]]*$##')
  fm_outcome_text "$rest"
}

# The `since <date>` metadata of the task's backlog row, normalized to UTC
# midnight. A date-only record is honest about its own precision.
backlog_since_iso() {  # <id>
  local id=$1 line since
  [ -f "$DATA/backlog.md" ] || return 0
  line=$(grep -E "^[-*][[:space:]]+(\[[ xX]\][[:space:]]+)?(\*\*)?$id(\*\*)?[[:space:]]+-[[:space:]]+" \
    "$DATA/backlog.md" 2>/dev/null | head -1) || true
  [ -n "$line" ] || return 0
  since=$(printf '%s' "$line" | sed -nE 's/.*\(since[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})[^)]*\).*/\1/p')
  [ -n "$since" ] || return 0
  printf '%sT00:00:00Z' "$since"
}

# The last terminal event in the append-only status log. The log is event
# history, never current state, so only a terminal verb is read here and the
# note is capped free text.
last_terminal_event() {  # <status-log> -> "<verb>\t<note>"
  local log=$1 line verb note
  [ -f "$log" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    verb=$(status_line_verb "$line")
    case "$verb" in
      done|failed) note=$(status_line_note "$line") ;;
      *) continue ;;
    esac
    printf '%s\t%s' "$verb" "$(fm_outcome_text "$note")"
    return 0
  done < <(grep -v '^[[:space:]]*$' "$log" 2>/dev/null \
    | awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }')
}

pr_identity_json() {  # <url> <head>
  local url=$1 head=$2
  if [ -z "$url" ] || ! fm_pr_url_parse "$url"; then
    jq -n '{url:null,provider:null,host:null,path:null,number:null,head:null}'
    return 0
  fi
  fm_outcome_sha_valid "$head" || head=
  jq -n --arg url "$FM_PR_URL" --arg provider "$FM_PR_PROVIDER" \
    --arg host "$FM_PR_HOST" --arg path "$FM_PR_PATH" --arg number "$FM_PR_NUMBER" \
    --arg head "$head" \
    'def blank($v): if $v == "" then null else $v end;
     {url:$url,provider:$provider,host:$host,path:$path,
      number:(if $number == "" then null else ($number | tonumber) end),
      head:blank($head)}'
}

cmd_write() {
  local id=$1; shift
  local forced=false outcome_override='' completed=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --forced) forced=true; shift ;;
      --outcome) [ "$#" -ge 2 ] || { usage >&2; return 2; }; outcome_override=$2; shift 2 ;;
      --completed-at) [ "$#" -ge 2 ] || { usage >&2; return 2; }; completed=$2; shift 2 ;;
      *) usage >&2; return 2 ;;
    esac
  done

  local meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "fm-outcome-manifest: no task metadata for $id" >&2
    return 1
  }

  local kind mode yolo project harness model effort worktree backend target
  local endpoint_task_id task_tmp traceparent secondmate_home pr_url pr_head
  kind=$(fm_outcome_kv_get "$meta" kind); [ -n "$kind" ] || kind=ship
  mode=$(fm_outcome_kv_get "$meta" mode)
  yolo=$(fm_outcome_kv_get "$meta" yolo)
  project=$(fm_outcome_kv_get "$meta" project)
  harness=$(fm_outcome_kv_get "$meta" harness)
  model=$(fm_outcome_kv_get "$meta" model)
  effort=$(fm_outcome_kv_get "$meta" effort)
  worktree=$(fm_outcome_kv_get "$meta" worktree)
  backend=$(fm_outcome_kv_get "$meta" backend); [ -n "$backend" ] || backend=tmux
  target=$(fm_outcome_kv_get "$meta" window)
  endpoint_task_id=$(fm_outcome_kv_get "$meta" endpoint_task_id)
  task_tmp=$(fm_outcome_kv_get "$meta" tasktmp)
  traceparent=$(fm_outcome_kv_get "$meta" traceparent)
  secondmate_home=$(fm_outcome_kv_get "$meta" home)
  pr_url=$(fm_outcome_kv_get "$meta" pr)
  pr_head=$(fm_outcome_kv_get "$meta" pr_head)

  local created created_source='' started started_source='' completed_source
  created=$(fm_outcome_path_iso "$DATA/$id/brief.md")
  if [ -n "$created" ]; then
    created_source=brief_mtime
  else
    created=$(backlog_since_iso "$id")
    [ -n "$created" ] && created_source=backlog_since
  fi
  started=$(fm_outcome_path_iso "$meta")
  [ -n "$started" ] && started_source=meta_mtime
  if [ -n "$completed" ]; then
    fm_outcome_iso_valid "$completed" || {
      echo "fm-outcome-manifest: --completed-at must be an ISO-8601 UTC stamp" >&2
      return 2
    }
    completed_source=explicit
  else
    completed=$(fm_outcome_now_iso)
    completed_source=manifest_write
  fi

  local event verb note outcome_state outcome_source
  event=$(last_terminal_event "$STATE/$id.status")
  verb=${event%%$'\t'*}
  note=${event#*$'\t'}
  [ "$event" = "$verb" ] && note=
  if [ -n "$outcome_override" ]; then
    case "$outcome_override" in
      done|failed|discarded|retired|unknown) ;;
      *) echo "fm-outcome-manifest: unsupported --outcome $outcome_override" >&2; return 2 ;;
    esac
    outcome_state=$outcome_override
    outcome_source=explicit
  elif [ "$verb" = "done" ] || [ "$verb" = "failed" ]; then
    outcome_state=$verb
    outcome_source=status_event
  elif [ "$kind" = secondmate ]; then
    outcome_state=retired
    outcome_source=task_kind
  elif [ "$forced" = true ]; then
    outcome_state=discarded
    outcome_source=forced_teardown
  else
    outcome_state=unknown
    outcome_source=none
  fi

  local report="$DATA/$id/report.md" report_present=false
  [ -f "$report" ] && report_present=true

  local pr_identity pr_status work_items gbrain title manifest
  pr_identity=$(pr_identity_json "$pr_url" "$pr_head")
  pr_status=$(fm_outcome_pr_status_read "$STATE" "$id")
  work_items=$(fm_outcome_work_items_read "$DATA" "$id")
  gbrain=$(fm_outcome_gbrain_json "$STATE" "$id")
  title=$(backlog_title "$id")

  manifest=$(jq -n \
    --arg schema "$FM_OUTCOME_MANIFEST_SCHEMA" \
    --arg id "$id" \
    --arg home "$FM_HOME" \
    --arg title "$title" \
    --arg project "$project" \
    --arg kind "$kind" \
    --arg mode "$mode" \
    --arg yolo "$yolo" \
    --arg harness "$harness" \
    --arg model "$model" \
    --arg effort "$effort" \
    --arg created "$created" \
    --arg created_source "$created_source" \
    --arg started "$started" \
    --arg started_source "$started_source" \
    --arg completed "$completed" \
    --arg completed_source "$completed_source" \
    --arg outcome_state "$outcome_state" \
    --arg outcome_detail "$note" \
    --arg outcome_source "$outcome_source" \
    --argjson forced "$forced" \
    --argjson pr_identity "$pr_identity" \
    --argjson pr_status "$pr_status" \
    --arg report_path "$report" \
    --argjson report_present "$report_present" \
    --arg backend "$backend" \
    --arg target "$target" \
    --arg endpoint_task_id "$endpoint_task_id" \
    --arg worktree "$worktree" \
    --arg task_tmp "$task_tmp" \
    --arg traceparent "$traceparent" \
    --arg secondmate_home "$secondmate_home" \
    --argjson work_items "$work_items" \
    --argjson gbrain "$gbrain" \
    --arg recorded_at "$completed" \
    'def blank($v): if $v == "" then null else $v end;
     {schema:$schema,
      task_id:$id,
      home:$home,
      title:blank($title),
      project:blank($project),
      kind:$kind,
      mode:blank($mode),
      yolo:blank($yolo),
      harness:blank($harness),
      model:blank($model),
      effort:blank($effort),
      timestamps:{created:blank($created),started:blank($started),completed:blank($completed)},
      timestamp_sources:{created:blank($created_source),
                         started:blank($started_source),
                         completed:blank($completed_source)},
      outcome:{state:$outcome_state,
               detail:blank($outcome_detail),
               source:$outcome_source,
               forced:$forced},
      pr:($pr_identity + {status:$pr_status}),
      report:{path:$report_path,present:$report_present},
      attribution:{backend:$backend,
                   endpoint:{target:blank($target),task_id:blank($endpoint_task_id)},
                   worktree:blank($worktree),
                   task_tmp:blank($task_tmp),
                   traceparent:blank($traceparent),
                   secondmate_home:blank($secondmate_home)},
      work_items:{schema:($work_items.schema),references:($work_items.references)},
      gbrain:$gbrain,
      recorded_at:$recorded_at}') || {
    echo "fm-outcome-manifest: could not compose the manifest for $id" >&2
    return 1
  }

  fm_outcome_manifest_write "$DATA" "$id" "$manifest" || {
    echo "fm-outcome-manifest: refused to publish the manifest for $id" >&2
    return 1
  }
  printf '%s\n' "$(fm_outcome_manifest_path "$DATA" "$id")"
}

cmd_show() {  # <id>
  fm_outcome_manifest_read "$DATA" "$1" || {
    echo "fm-outcome-manifest: no valid manifest for $1" >&2
    return 1
  }
}

cmd_validate() {  # <id>
  local doc
  doc=$(fm_outcome_manifest_read "$DATA" "$1") || {
    echo "fm-outcome-manifest: no valid manifest for $1" >&2
    return 1
  }
  fm_outcome_manifest_keys_valid "$doc" || {
    echo "fm-outcome-manifest: manifest for $1 carries unexpected fields" >&2
    return 1
  }
  echo "ok"
}

# Durable history, newest completion first. A manifest that no longer parses is
# disclosed by id and reason rather than silently dropped, so a renderer can
# tell "nothing completed" from "one record is unreadable".
cmd_list() {
  local limit=${FM_OUTCOME_HISTORY_LIMIT:-40}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit) [ "$#" -ge 2 ] || { usage >&2; return 2; }; limit=$2; shift 2 ;;
      *) usage >&2; return 2 ;;
    esac
  done
  case "$limit" in ''|*[!0-9]*) echo "fm-outcome-manifest: --limit must be an integer" >&2; return 2 ;; esac
  fm_outcome_history_json "$DATA" "$limit"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
  write)
    shift
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    fm_task_id_path_safe "$1" || { echo "fm-outcome-manifest: invalid task id" >&2; exit 2; }
    cmd_write "$@"
    ;;
  show)
    shift
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    fm_task_id_path_safe "$1" || { echo "fm-outcome-manifest: invalid task id" >&2; exit 2; }
    cmd_show "$1"
    ;;
  validate)
    shift
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    fm_task_id_path_safe "$1" || { echo "fm-outcome-manifest: invalid task id" >&2; exit 2; }
    cmd_validate "$1"
    ;;
  list)
    shift
    cmd_list "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
