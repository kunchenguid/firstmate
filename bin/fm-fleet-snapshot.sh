#!/usr/bin/env bash
# fm-fleet-snapshot.sh - structured fleet snapshot with observational caching.
#
# Output contract: `--json` prints one object with schema
# `fm-fleet-snapshot.v1`.
# The command does not acquire the session lock, drain wakes, arm watchers,
# mutate backlog state, or write reports. Its default ledger collector may
# atomically refresh parent-side cached copies of remote home summaries under
# state/secondmate-summary-cache; those observational cache writes are its only
# fleet-state mutation.
#
# Top-level fields:
#   schema: stable schema id.
#   generated: UTC observation time for this fresh command execution.
#   fm_home: resolved operational home.
#   roots: resolved root/config/data/state/projects directories.
#   backlog: {path,present,records[]} where records are ordered as written in
#     data/backlog.md and cover In flight, Queued, and Done.
#     Canonical tasks-axi rows are structured; free-form non-empty lines in
#     those sections are preserved as unstructured records.
#     Structured rows preserve captain-hold metadata such as hold_kind,
#     hold_reason, and hold_until when tasks-axi emits it. They also carry
#     normalized current_role, requires_child_metadata, blocked_by_ids,
#     unresolved_blocker_ids, captain_actionable, and deferred_marker fields.
#     Repeated blocker tokens remain ordered; a blocker resolves only when its
#     structured record is Done, and missing ids stay open.
#     captain_actionable means "waiting on the captain now": queued, held for
#     the captain, unblocked, and due (no hold_until, or hold_until at or
#     before the observation date, matching tasks-axi's own date-gate rule).
#     There is no separate decision type: any captain-held task is the same
#     primitive, whatever kind its row carries.
#     deferred_marker is a presentation hint only: the row's hold reason or
#     body carries an explicit SUPERSEDED / NOT REQUIRED / DEFERRED marker.
#     It never changes captain_actionable; renderers may use it to keep
#     prose-deferred rows out of default views.
#   tasks[]: one row per state/<id>.meta, sorted by id.
#     Local current_state is parsed from bin/fm-crew-state.sh <id> and preserves
#     state, source, detail, and raw line separately. Remote secondmate rows use
#     an explicit unknown value because their endpoint liveness belongs to
#     supervision rather than this snapshot path.
#     paths.status_log.last_event is historical wake-event data only, never
#     current state.
#     hints.open_decisions is the keyed open-decision set returned by
#     fm-classify-lib.sh's authoritative status_open_decisions fold and reconciled
#     against current_state; hints.pending_decision and hints.blocked_event are
#     booleans derived from that set.
#     endpoint.exists is the cheap local backend endpoint-presence read.
#     endpoint.agent_alive is populated for local secondmates only, where it is
#     useful return-channel supervision data; remote secondmates use "unknown"
#     without a probe, and other tasks use "not_checked".
#   scout_reports[]: present data/<id>/report.md pointers.
#   main_inventory: {valid,reason,orphan_in_flight[],unstructured_current_count} -
#     main-home current-inventory checks shared with secondmate_home_summary_json
#     (orphan structured in-flight ids with no state/<id>.meta, and unstructured
#     current backlog rows). Does not invent live tasks; meta remains truth for
#     workers. Bearings maps failures into omitted[] disclosure (and a Charted
#     Next gate line) rather than silent empty Underway.
#   secondmate_current: {records[],total,shown,truncated} - bounded current summaries
#     for registered secondmates, selected from validated structured state inside
#     each home with explicit provenance, freshness, endpoint evidence, and unknown
#     failure reasons. Parent status and bounded terminal evidence are historical,
#     untrusted supplements only and never override readable structured-home facts.
#     Each structured-home record carries active_children, decisions_open, holds,
#     queued, landed, endpoints, counts, and omitted. provenance.summary_source
#     distinguishes "local-ledger", "remote-ledger", and "remote-ledger-cache";
#     freshness is "cached" only for the cache source, and observed_at/age_seconds
#     come from the selected summary's generation. Every successfully sampled home also carries
#     reconcile_inventory independently of projection trust.
#     Actionable captain holds
#     appear in decisions_open; blocked captain holds remain queued with metadata.
#   secondmate_landed: {records[],truncated[],unreadable[],partial[]} - the
#     compatibility landed-work roll-up derived from secondmate_current. Readable
#     structured homes are partial, not unreadable, when an unavailable child state
#     or a backlog-vs-metadata inventory mismatch makes their summary incomplete;
#     they retain independently trustworthy structured surfaces. An inventory
#     mismatch also keeps the home's own current classification, which only an
#     unavailable child state or an untrustworthy backlog collapses to unknown.
#   secondmate_guidance: return-channel action note for renderers and bearings.
#
# Compatibility: JSON is the primary machine-readable surface.
# Human views must render this output instead of parsing state files again.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BACKLOG="$DATA/backlog.md"
SNAPSHOT_NOW=${FM_SNAPSHOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
if [ -n "${FM_SNAPSHOT_NOW_EPOCH:-}" ]; then
  SNAPSHOT_EPOCH=$FM_SNAPSHOT_NOW_EPOCH
else
  SNAPSHOT_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$SNAPSHOT_NOW" +%s 2>/dev/null \
    || date -u -d "$SNAPSHOT_NOW" +%s 2>/dev/null \
    || date +%s)
fi
case "$SNAPSHOT_EPOCH" in ''|*[!0-9]*) SNAPSHOT_EPOCH=$(date +%s) ;; esac
# The observation date gates captain-hold deferral: a `hold-until` date still in
# the future keeps a captain hold out of captain_actionable until it is due
# (tasks-axi's own contract: the hold is inactive on and after that date).
SNAPSHOT_TODAY=${SNAPSHOT_NOW%%T*}
case "$SNAPSHOT_TODAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) SNAPSHOT_TODAY=$(date -u +%Y-%m-%d) ;;
esac

# Cross-home bounds are explicit so one broken or unexpectedly large home cannot
# hang or explode the parent snapshot.
FM_SNAPSHOT_SECONDMATES=${FM_SNAPSHOT_SECONDMATES:-20}
FM_SNAPSHOT_CREW_STATE_TIMEOUT=${FM_SNAPSHOT_CREW_STATE_TIMEOUT:-10}
FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=${FM_SNAPSHOT_LOCAL_READ_CONCURRENCY:-8}
FM_SNAPSHOT_BUDGET=${FM_SNAPSHOT_BUDGET:-5}
FM_SNAPSHOT_CACHE_DIR=${FM_SNAPSHOT_CACHE_DIR:-$STATE/secondmate-summary-cache}
FM_SNAPSHOT_SECONDMATE_MAX_BYTES=${FM_SNAPSHOT_SECONDMATE_MAX_BYTES:-262144}
FM_SNAPSHOT_SECONDMATE_CHILDREN=${FM_SNAPSHOT_SECONDMATE_CHILDREN:-20}
FM_SNAPSHOT_SECONDMATE_QUEUED=${FM_SNAPSHOT_SECONDMATE_QUEUED:-20}
FM_SNAPSHOT_SECONDMATE_DECISIONS=${FM_SNAPSHOT_SECONDMATE_DECISIONS:-20}
FM_SNAPSHOT_TERMINAL_LINES=${FM_SNAPSHOT_TERMINAL_LINES:-8}
FM_SNAPSHOT_TERMINAL_BYTES=${FM_SNAPSHOT_TERMINAL_BYTES:-4096}
FM_SNAPSHOT_TERMINAL_TIMEOUT=${FM_SNAPSHOT_TERMINAL_TIMEOUT:-2}
FM_SNAPSHOT_PARENT_ACTIVITY_LINES=${FM_SNAPSHOT_PARENT_ACTIVITY_LINES:-256}
FM_SNAPSHOT_PARENT_ACTIVITY_BYTES=${FM_SNAPSHOT_PARENT_ACTIVITY_BYTES:-65536}
FM_SNAPSHOT_PARENT_ACTIVITIES=${FM_SNAPSHOT_PARENT_ACTIVITIES:-20}
FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT=${FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT:-2}
FM_SNAPSHOT_REGISTRY_LINES=${FM_SNAPSHOT_REGISTRY_LINES:-256}
FM_SNAPSHOT_REGISTRY_BYTES=${FM_SNAPSHOT_REGISTRY_BYTES:-65536}
FM_SNAPSHOT_REGISTRY_RECORDS=${FM_SNAPSHOT_REGISTRY_RECORDS:-40}
FM_SNAPSHOT_REGISTRY_TIMEOUT=${FM_SNAPSHOT_REGISTRY_TIMEOUT:-2}
validate_positive_bound() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0)
      printf 'fm-fleet-snapshot: %s must be a positive integer\n' "$1" >&2
      exit 2
      ;;
  esac
}
case "$FM_SNAPSHOT_SECONDMATES" in
  ''|*[!0-9]*)
    echo "fm-fleet-snapshot: FM_SNAPSHOT_SECONDMATES must be a non-negative integer" >&2
    exit 2
    ;;
esac
validate_positive_bound FM_SNAPSHOT_CREW_STATE_TIMEOUT "$FM_SNAPSHOT_CREW_STATE_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_LOCAL_READ_CONCURRENCY "$FM_SNAPSHOT_LOCAL_READ_CONCURRENCY"
validate_positive_bound FM_SNAPSHOT_BUDGET "$FM_SNAPSHOT_BUDGET"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_MAX_BYTES "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_CHILDREN "$FM_SNAPSHOT_SECONDMATE_CHILDREN"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_QUEUED "$FM_SNAPSHOT_SECONDMATE_QUEUED"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_DECISIONS "$FM_SNAPSHOT_SECONDMATE_DECISIONS"
validate_positive_bound FM_SNAPSHOT_TERMINAL_LINES "$FM_SNAPSHOT_TERMINAL_LINES"
validate_positive_bound FM_SNAPSHOT_TERMINAL_BYTES "$FM_SNAPSHOT_TERMINAL_BYTES"
validate_positive_bound FM_SNAPSHOT_TERMINAL_TIMEOUT "$FM_SNAPSHOT_TERMINAL_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_LINES "$FM_SNAPSHOT_PARENT_ACTIVITY_LINES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_BYTES "$FM_SNAPSHOT_PARENT_ACTIVITY_BYTES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITIES "$FM_SNAPSHOT_PARENT_ACTIVITIES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT "$FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_REGISTRY_LINES "$FM_SNAPSHOT_REGISTRY_LINES"
validate_positive_bound FM_SNAPSHOT_REGISTRY_BYTES "$FM_SNAPSHOT_REGISTRY_BYTES"
validate_positive_bound FM_SNAPSHOT_REGISTRY_RECORDS "$FM_SNAPSHOT_REGISTRY_RECORDS"
validate_positive_bound FM_SNAPSHOT_REGISTRY_TIMEOUT "$FM_SNAPSHOT_REGISTRY_TIMEOUT"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"  # validate_secondmate_home: shared seeded-home boundary checks
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"  # fm_run_timed: the shared hard bound

usage() {
  cat <<'EOF'
usage: fm-fleet-snapshot.sh --json
       fm-fleet-snapshot.sh --secondmate-home-summary

Print a structured snapshot of the firstmate fleet.
JSON is the stable machine-readable output contract. The default snapshot
refreshes only its parent-side remote-summary cache as an observational side effect.

--secondmate-home-summary emits the bounded structured summary used after a
validated registered-home handoff. It is local-only, skips nested secondmate
aggregation, includes generated_epoch for freshness arithmetic, and marks
inventory contradictions or unavailable child state invalid.
kind=secondmate meta records are not child inventory for unowned_current or
terminal_in_flight; they never have backlog rows.
Its invalidity object names the normalized failure kind and affected ids.
Actionable tasks-axi captain holds appear as decisions_open and stay visible in
queued with hold_reason, hold_kind, hold_until, deferred_marker, and plural
blocker fields for downstream projections. A captain hold is actionable only
when every blocker is Done and any hold-until date has arrived.
Cross-home collection uses FM_SNAPSHOT_SECONDMATES (default 20, 0 lifts the
count bound) and FM_SNAPSHOT_SECONDMATE_MAX_BYTES.
Every sampled remote home's state/home-summary.json is fetched concurrently
under one FM_SNAPSHOT_BUDGET (default 5 seconds), with a valid prior copy under
FM_SNAPSHOT_CACHE_DIR used when the live read fails, is invalid, or consumes the
budget. A home with neither a valid ledger nor a valid cached copy is reported
unreadable with the reason; collection never computes a summary in that home.
Each local per-task current-state read is bounded by FM_SNAPSHOT_CREW_STATE_TIMEOUT
(default 10 seconds); a read that hits the bound reports state unknown. Local task
observations run concurrently, up to FM_SNAPSHOT_LOCAL_READ_CONCURRENCY (default 8).
Remote secondmate endpoint liveness is not probed by this command.
Terminal contradiction evidence uses
FM_SNAPSHOT_TERMINAL_LINES, FM_SNAPSHOT_TERMINAL_BYTES, and
FM_SNAPSHOT_TERMINAL_TIMEOUT and never becomes canonical current state.
Parent activity evidence uses FM_SNAPSHOT_PARENT_ACTIVITY_LINES,
FM_SNAPSHOT_PARENT_ACTIVITY_BYTES, FM_SNAPSHOT_PARENT_ACTIVITIES, and
FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT, with truncation disclosed in the result.
The registered secondmate table uses FM_SNAPSHOT_REGISTRY_LINES,
FM_SNAPSHOT_REGISTRY_BYTES, FM_SNAPSHOT_REGISTRY_RECORDS, and
FM_SNAPSHOT_REGISTRY_TIMEOUT, with unavailability and truncation disclosed.
EOF
}

OUTPUT_MODE=json
case "${1:---json}" in
  --json) ;;
  --secondmate-home-summary) OUTPUT_MODE=secondmate-home-summary ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-snapshot: jq not found" >&2; exit 1; }

bool_json() {
  if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi
}

path_present_json() {  # <contract-path> [<observed-path>]
  local path=$1 observed=${2:-$1} present=0
  [ -e "$observed" ] && present=1
  jq -n --arg path "$path" --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present}'
}

meta_value() {  # <meta-file> <key>
  fm_meta_get "$1" "$2"
}

last_nonempty_line() {  # <file>
  [ -f "$1" ] || return 1
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

# A local crew-state read is bounded so one slow child cannot extend this
# snapshot without limit. Remote secondmate endpoint liveness is never read here.
# A local read that hits the bound folds to state unknown.
crew_state_json() {  # <id> [<captured-meta>]
  local id=$1 captured_meta=${2:-} raw rest state source detail sep
  raw=$(
    fm_run_timed "$FM_SNAPSHOT_CREW_STATE_TIMEOUT" \
      env FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_CREW_STATE_META_OVERRIDE="$captured_meta" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true
  )
  raw=$(printf '%s\n' "$raw" | head -1)
  sep=' · '
  state=unknown
  source=none
  detail=
  case "$raw" in
    state:\ *"$sep"source:\ *)
      rest=${raw#state: }
      state=${rest%%"$sep"source: *}
      rest=${rest#*"$sep"source: }
      case "$rest" in
        *"$sep"*) source=${rest%%"$sep"*}; detail=${rest#*"$sep"} ;;
        *) source=$rest ;;
      esac
      ;;
  esac
  jq -n --arg raw "$raw" --arg state "$state" --arg source "$source" --arg detail "$detail" \
    '{state:$state,source:$source,detail:$detail,raw:$raw}'
}

status_event_json() {  # <observed-status-log> [<contract-path>]
  local log=$1 path=${2:-$1} present=0 raw='' verb='' note=''
  if [ -f "$log" ]; then
    present=1
    raw=$(last_nonempty_line "$log" || true)
    verb=$(status_line_verb "$raw")
    note=$(status_line_note "$raw")
  fi
  jq -n \
    --arg path "$path" \
    --arg raw "$raw" \
    --arg verb "$verb" \
    --arg note "$note" \
    --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present,kind:"event_history",last_event:{state:$verb,note:$note,raw:$raw}}'
}

first_pr_url_in_file() {  # <file>
  [ -f "$1" ] || return 1
  grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$1" 2>/dev/null | head -1
}

backlog_json() {  # [<backlog-path>] - defaults to this home's $BACKLOG
  local backlog=${1:-$BACKLOG}
  if [ ! -f "$backlog" ]; then
    jq -n --arg path "$backlog" '{path:$path,present:false,records:[]}'
    return 0
  fi

  # shellcheck disable=SC2094
  jq -Rn --arg path "$backlog" --arg today "$SNAPSHOT_TODAY" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def section_state:
      if . == "In flight" then "in_flight"
      elif . == "Queued" then "queued"
      elif . == "Done" then "done"
      else null end;
    def cap($rest; $re):
      (((($rest | capture($re)?) // {}) | .v) // null) as $v
      | if $v == null then null else ($v | trim) end;
    def metadata($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
    def metadata_word($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + "[[:space:]]+(?<v>[^,)]*)");
    def url_pattern: "https?://[^[:space:])\"<>]+";
    def wrapped_url_pattern: "<?" + url_pattern + ">?";
    def links($rest): [$rest | scan(url_pattern)];
    def strip_trailing_metadata:
      reduce range(0; 20) as $_ (.;
        sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority|hold|hold-kind|hold-until):[[:space:]]*[^)]*|(?:since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""));
    def strip_title_artifacts:
      sub("[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+-[[:space:]]+local main$"; "")
      | sub("[[:space:]]+local main$"; "")
      | sub("[[:space:]]+-[[:space:]]*$"; "");
    def clean_title:
      strip_trailing_metadata
      | strip_title_artifacts
      | gsub("[[:space:]]+"; " ")
      | trim;
    def title_of($rest):
      $rest
      | gsub(wrapped_url_pattern; "")
      | sub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$"; "")
      | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
      | clean_title;
    def blocked_by_ids($rest):
      [ $rest | scan("blocked-by:[[:space:]]+(?<id>[^[:space:])]+)") | .[0] ]
      | reduce .[] as $id ([]; if index($id) == null then . + [$id] else . end);
    def blocked_reason($rest):
      cap($rest; ".*blocked-by:[[:space:]]*[^[:space:])]+[[:space:]]+-[[:space:]]*(?<v>.*)$") as $reason
      | if $reason == null then null
        else ($reason | clean_title | if . == "" then null else . end)
        end;
    def local_note($rest):
      cap(($rest | strip_trailing_metadata); ".*(?:^|[[:space:]]+-[[:space:]]+|[[:space:]])(?<v>local main)$");
    def completion($rest):
      (metadata_word($rest; "merged")) as $merged
      | (metadata_word($rest; "reported")) as $reported
      | (metadata_word($rest; "done")) as $done
      | if $merged != null then {verb:"merged",date:$merged}
        elif $reported != null then {verb:"reported",date:$reported}
        elif $done != null then {verb:"done",date:$done}
        else {verb:null,date:null} end;
    def row_match($line):
      (($line | capture("^[-*][[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?) //
       (($line | capture("^[-*][[:space:]]+\\*\\*(?<id>[^*]+)\\*\\*[[:space:]]+-[[:space:]]+(?<rest>.*)$")?)
        | if . == null then null else . + {check:" "} end));
    def structured_row($line):
      ($line | test("^[-*][[:space:]]+\\[[ xX]\\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+"))
      or ($line | test("^[-*][[:space:]]+\\*\\*[^*]+\\*\\*[[:space:]]+-[[:space:]]+"));
    def parse_row($line; $section; $order):
      row_match($line) as $m
      | if $m == null then
          {order:$order,state:$section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}
        else
          ($m.rest) as $rest
          | {order:$order,
             state:$section,
             structured:true,
             id:($m.id | trim),
             checked:($m.check | test("[xX]")),
             title:title_of($rest),
             repo:metadata($rest; "repo"),
             kind:metadata($rest; "kind"),
             priority:metadata($rest; "priority"),
             hold_reason:metadata($rest; "hold"),
             hold_kind:metadata($rest; "hold-kind"),
             hold_until:metadata($rest; "hold-until"),
             blocked_by:cap($rest; ".*blocked-by:[[:space:]]*(?<v>[^[:space:])]+).*"),
             blocked_by_ids:blocked_by_ids($rest),
             blocked_reason:blocked_reason($rest),
             since:metadata_word($rest; "since"),
             merged:metadata_word($rest; "merged"),
             reported:metadata_word($rest; "reported"),
             done:metadata_word($rest; "done"),
             completion:completion($rest),
             links:links($rest),
             pr_url:((links($rest) | map(select(test("/pull/[0-9]+"))) | .[0]) // null),
             report_path:cap($rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
             local_note:local_note($rest),
             raw:$line,
             body_lines:[],
             body_excerpt:null}
        end;
    reduce inputs as $line
      ({path:$path,present:true,records:[],section:null,order:0};
       if ($line | test("^##[[:space:]]+")) then
         .section = (($line | sub("^##[[:space:]]+";"") | trim) | section_state)
       elif .section == null or ($line | trim) == "" then
         .
       elif structured_row($line) then
         .order += 1
         | .records += [parse_row($line; .section; .order)]
       elif ((.records | length) > 0 and (.records[-1].structured == true) and ($line | test("^[[:space:]]+"))) then
         ($line | trim) as $body
         | if $body == "" then .
           else .records[-1].body_lines += [$body] end
       else
         .order += 1
         | .records += [{order:.order,state:.section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}]
       end)
    | .records |= map(
        if (.body_lines | length) > 0 then
          .body_excerpt = ((.body_lines | join(" "))[:240])
        else . end)
    | .records as $records
    | (reduce ($records[] | select(.structured)) as $record ({};
         .[$record.id] = ((.[$record.id] // true) and ($record.state == "done")))) as $resolved_ids
    | .records |= map(
        if .structured then
          . as $record
          | .unresolved_blocker_ids = [
              $record.blocked_by_ids[] as $blocker
              | select($resolved_ids[$blocker] != true)
              | $blocker
            ]
          | .current_role =
              (if .state == "in_flight" and .hold_reason != null and .hold_kind != null then "held"
               elif .state == "in_flight" and .kind == "program" then "program"
               elif .state == "in_flight" then "worker"
               elif .state == "queued" then "queued"
               else "done" end)
          | .requires_child_metadata = (.current_role == "worker")
          | .captain_actionable =
              (.state == "queued" and .hold_kind == "captain"
               and .hold_reason != null and (.unresolved_blocker_ids | length) == 0
               and (.hold_until == null or .hold_until <= $today))
          | .deferred_marker =
              ((((.hold_reason // "") + " " + (.body_excerpt // ""))
                | test("SUPERSEDED|NOT REQUIRED|NOT-REQUIRED|DEFERRED"; "i")))
        else . end)
    | del(.section,.order)
  ' < "$backlog"
}

SNAPSHOT_TASK_DIR=
SNAPSHOT_TASK_METAS=()
SNAPSHOT_TASK_META_COUNT=0

snapshot_task_cleanup() {
  [ -z "$SNAPSHOT_TASK_DIR" ] || rm -rf -- "$SNAPSHOT_TASK_DIR"
  SNAPSHOT_TASK_DIR=
  SNAPSHOT_TASK_METAS=()
  SNAPSHOT_TASK_META_COUNT=0
}

snapshot_wait_current_reads() {  # <pid>...
  local pid rc=0
  for pid in "$@"; do
    wait "$pid" || rc=1
  done
  return "$rc"
}

snapshot_capture_optional() {  # <source> <destination>
  local source=$1 destination=$2
  [ -f "$source" ] || return 0
  cp -p -- "$source" "$destination" && return 0
  # Teardown may remove an optional observation after the existence check.
  if [ ! -e "$source" ]; then
    rm -f -- "$destination"
    return 0
  fi
  return 1
}

snapshot_mark_optional_present() {  # <source> <destination>
  local source=$1 destination=$2
  [ -f "$source" ] || return 0
  : > "$destination"
}

snapshot_task_generation_is_current() {  # <captured-meta> <id>
  local captured_meta=$1 id=$2 current_meta captured_gen current_gen captured_contents current_contents
  current_meta="$STATE/$id.meta"
  [ -f "$current_meta" ] || return 1
  captured_gen=$(meta_value "$captured_meta" spawn_gen)
  if [ -n "$captured_gen" ]; then
    current_gen=$(meta_value "$current_meta" spawn_gen)
    [ "$current_gen" = "$captured_gen" ]
  else
    # Legacy metadata has no generation token. Exact equality is the strongest
    # available identity check and still detects ordinary teardown/relaunches.
    captured_contents=$(<"$captured_meta") || return 1
    current_contents=$(<"$current_meta") || return 1
    [ "$current_contents" = "$captured_contents" ]
  fi
}

prefetch_task_observations() {  # <meta> <id>
  local meta=$1 id=$2 remote_host current_file endpoint_file current_pid='' current_rc=0
  local status_log status_capture report_path report_capture
  local kind backend target endpoint_exists=null agent_alive=not_checked generation_current=1
  remote_host=$(meta_value "$meta" remote_host)
  current_file="$SNAPSHOT_TASK_DIR/$id.json"
  endpoint_file="$SNAPSHOT_TASK_DIR/$id.endpoint"
  status_log="$STATE/$id.status"
  status_capture="$SNAPSHOT_TASK_DIR/$id.status"
  report_path="$DATA/$id/report.md"
  report_capture="$SNAPSHOT_TASK_DIR/$id.report"

  snapshot_task_generation_is_current "$meta" "$id" || generation_current=0
  if [ "$generation_current" = 1 ]; then
    snapshot_capture_optional "$status_log" "$status_capture" || current_rc=1
    snapshot_mark_optional_present "$report_path" "$report_capture" || current_rc=1
  fi

  if [ -n "$remote_host" ]; then
    jq -n '{state:"unknown",source:"none",detail:"remote endpoint liveness not collected by fleet snapshot",raw:""}' \
      > "$current_file" || current_rc=1
    agent_alive=unknown
  elif [ "$generation_current" = 1 ]; then
    crew_state_json "$id" "$meta" > "$current_file" &
    current_pid=$!
    kind=$(meta_value "$meta" kind)
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if [ -n "$target" ]; then
      if fm_backend_target_exists "$backend" "$target" "fm-$id" >/dev/null 2>&1; then
        endpoint_exists=true
      else
        endpoint_exists=false
      fi
      if [ "$kind" = secondmate ]; then
        agent_alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf unknown)
      fi
    fi
  else
    jq -n '{state:"unknown",source:"none",detail:"task generation changed during snapshot",raw:""}' \
      > "$current_file" || current_rc=1
    agent_alive=unknown
  fi

  [ -z "$current_pid" ] || wait "$current_pid" || current_rc=1
  # All mutable observations must belong to the metadata generation captured in
  # the manifest. If teardown/relaunch raced any read, discard the whole sample.
  if ! snapshot_task_generation_is_current "$meta" "$id"; then
    rm -f -- "$status_capture" "$report_capture"
    jq -n '{state:"unknown",source:"none",detail:"task generation changed during snapshot",raw:""}' \
      > "$current_file" || current_rc=1
    endpoint_exists=null
    agent_alive=unknown
  fi
  printf 'endpoint_exists=%s\nagent_alive=%s\n' "$endpoint_exists" "$agent_alive" > "$endpoint_file" || current_rc=1
  return "$current_rc"
}

# Current-state and endpoint reads are independent observations. Start each
# task's pair together so five local workers pay one slow no-mistakes response
# window rather than five in series, while every command bound remains owned by
# fm-timeout-lib.sh.
prefetch_task_current_states() {
  local meta captured_meta id active=0 index=0 rc=0
  local -a pids=()
  snapshot_task_cleanup
  SNAPSHOT_TASK_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-fleet-tasks.XXXXXX") || return 1
  # Keep the metadata generation that selected each task beside its observations.
  # Publishers replace metadata atomically, so copying before workers start gives
  # composition one coherent task manifest even if publication or teardown races it.
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    captured_meta="$SNAPSHOT_TASK_DIR/$id.meta"
    if ! cp -- "$meta" "$captured_meta" 2>"$captured_meta.copy-error"; then
      # Teardown may unlink a task after the glob selected it but before cp opens
      # it. That task is no longer in the inventory; other copy failures remain
      # fatal rather than silently producing a partial snapshot.
      if [ ! -e "$meta" ]; then
        rm -f -- "$captured_meta" "$captured_meta.copy-error"
        continue
      fi
      cat "$captured_meta.copy-error" >&2
      snapshot_task_cleanup
      return 1
    fi
    rm -f -- "$captured_meta.copy-error"
    SNAPSHOT_TASK_METAS[SNAPSHOT_TASK_META_COUNT]=$captured_meta
    SNAPSHOT_TASK_META_COUNT=$((SNAPSHOT_TASK_META_COUNT + 1))
  done
  while [ "$index" -lt "$SNAPSHOT_TASK_META_COUNT" ]; do
    meta=${SNAPSHOT_TASK_METAS[index]}
    id=$(basename "$meta" .meta)
    prefetch_task_observations "$meta" "$id" &
    pids[active]=$!
    active=$((active + 1))
    index=$((index + 1))
    if [ "$active" -ge "$FM_SNAPSHOT_LOCAL_READ_CONCURRENCY" ]; then
      snapshot_wait_current_reads "${pids[@]}" || rc=1
      pids=()
      active=0
    fi
  done
  if [ "$active" -gt 0 ]; then
    snapshot_wait_current_reads "${pids[@]}" || rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    snapshot_task_cleanup
    return 1
  fi
}

task_json_lines() {
  local meta original_meta id kind harness mode yolo project worktree home projects spawn_gen backend target status_log report_path
  local remote_host remote_root current_file endpoint_file observation_line index=0
  local pr pr_source event_json current_json endpoint_exists agent_alive meta_json status_json report_json worktree_json home_json
  local decision_line decision_verb
  local last_event_raw current_state current_source pending_decision blocked_event report_present=0 pr_from_status
  local open_decisions_tsv open_decisions_json

  while [ "$index" -lt "$SNAPSHOT_TASK_META_COUNT" ]; do
    meta=${SNAPSHOT_TASK_METAS[index]}
    index=$((index + 1))
    id=$(basename "$meta" .meta)
    original_meta="$STATE/$id.meta"
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    harness=$(meta_value "$meta" harness)
    mode=$(meta_value "$meta" mode)
    yolo=$(meta_value "$meta" yolo)
    project=$(meta_value "$meta" project)
    worktree=$(meta_value "$meta" worktree)
    home=$(meta_value "$meta" home)
    projects=$(meta_value "$meta" projects)
    spawn_gen=$(meta_value "$meta" spawn_gen)
    remote_host=$(meta_value "$meta" remote_host)
    remote_root=$(meta_value "$meta" remote_root)
    if [ -n "$remote_host" ]; then
      backend=$(meta_value "$meta" remote_backend)
      [ -n "$backend" ] || backend=unknown
      target=$(meta_value "$meta" remote_target)
    else
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta")
    fi
    status_log="$SNAPSHOT_TASK_DIR/$id.status"
    report_path="$SNAPSHOT_TASK_DIR/$id.report"
    pr=$(meta_value "$meta" pr)
    pr_source=meta
    if [ -z "$pr" ]; then
      pr_from_status=$(first_pr_url_in_file "$status_log" || true)
      pr=$pr_from_status
      pr_source=status_event
    fi
    if [ -z "$pr" ]; then
      pr_source=absent
    fi

    current_file="$SNAPSHOT_TASK_DIR/$id.json"
    current_json=$(<"$current_file") || {
      snapshot_task_cleanup
      return 1
    }
    event_json=$(status_event_json "$status_log" "$STATE/$id.status")
    last_event_raw=$(printf '%s' "$event_json" | jq -r '.last_event.raw // ""')
    read -r current_state current_source < <(
      printf '%s' "$current_json" | jq -r '[.state // "", .source // ""] | @tsv'
    )

    # Durable keyed open-decision set: fold the WHOLE status stream
    # (fm-classify-lib.sh's status_open_decisions) so a later unrelated event can
    # never mask a still-open captain decision. The set is derived purely from the
    # keyed fold - never from report bodies or decision-like prose - and then
    # reconciled against the crew LIFECYCLE, which only clears a stale decision the
    # crew has provably moved past. Two lifecycle signals clear it, neither of which
    # reads any report content:
    #   - a live activity read (run-step or busy pane) that is working/done, so a
    #     crew that resumed past a gate is not still reported as parked; and
    #   - a TERMINAL done/failed state on a single-owner task (scout or ship), whose
    #     deliverable is its report or PR, so a COMPLETED scout surfaces only as a
    #     report POINTER, never as a reopened pending decision.
    # Secondmates are excluded from lifecycle clearing: they are persistent and
    # multiplex many concerns onto one stream, so activity on one concern must
    # never clear another concern's keyed decision. A parked/blocked state, or a
    # non-authoritative status-log/none read on a still-live task, keeps the fold's
    # open decision surfacing.
    open_decisions_tsv=$(status_open_decisions "$status_log")
    if [ "$kind" != secondmate ] && \
       { { { [ "$current_source" = run-step ] || [ "$current_source" = pane ]; } \
           && [ "$current_state" != parked ] && [ "$current_state" != blocked ]; } \
         || { [ "$current_state" = "done" ] || [ "$current_state" = "failed" ]; }; }; then
      open_decisions_tsv=""
    fi
    open_decisions_json=$(printf '%s' "$open_decisions_tsv" | jq -R -s '
      [ splits("\n") | select(length > 0)
        | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
        | select(. != null) ]')
    pending_decision=0
    blocked_event=0
    while IFS= read -r decision_line || [ -n "$decision_line" ]; do
      decision_verb=${decision_line#*$'\t'}
      decision_verb=${decision_verb%%$'\t'*}
      case "$decision_verb" in
        needs-decision) pending_decision=1 ;;
        blocked) blocked_event=1 ;;
      esac
    done <<< "$open_decisions_tsv"

    endpoint_exists=null
    agent_alive=not_checked
    endpoint_file="$SNAPSHOT_TASK_DIR/$id.endpoint"
    while IFS= read -r observation_line || [ -n "$observation_line" ]; do
      case "$observation_line" in
        endpoint_exists=*) endpoint_exists=${observation_line#*=} ;;
        agent_alive=*) agent_alive=${observation_line#*=} ;;
      esac
    done < "$endpoint_file" || {
      snapshot_task_cleanup
      return 1
    }
    [ -f "$report_path" ] && report_present=1 || report_present=0
    meta_json=$(path_present_json "$original_meta" "$meta")
    status_json=$event_json
    report_json=$(path_present_json "$DATA/$id/report.md" "$report_path")
    if [ -n "$worktree" ]; then worktree_json=$(path_present_json "$worktree"); else worktree_json=$(jq -n '{path:null,present:false}'); fi
    if [ -n "$home" ] && [ -n "$remote_host" ]; then
      home_json=$(jq -n --arg path "$home" '{path:$path,present:null}')
    elif [ -n "$home" ]; then
      home_json=$(path_present_json "$home")
    else
      home_json=$(jq -n '{path:null,present:false}')
    fi

    jq -n \
      --arg id "$id" \
      --arg kind "$kind" \
      --arg harness "$harness" \
      --arg mode "$mode" \
      --arg yolo "$yolo" \
      --arg project "$project" \
      --arg worktree "$worktree" \
      --arg home "$home" \
      --arg projects "$projects" \
      --arg spawn_gen "$spawn_gen" \
      --arg backend "$backend" \
      --arg target "$target" \
      --arg remote_host "$remote_host" \
      --arg remote_root "$remote_root" \
      --arg pr "$pr" \
      --arg pr_source "$pr_source" \
      --arg agent_alive "$agent_alive" \
      --arg observed_at "$SNAPSHOT_NOW" \
      --arg last_event_raw "$last_event_raw" \
      --argjson current_state "$current_json" \
      --argjson meta_path "$meta_json" \
      --argjson status_log "$status_json" \
      --argjson report "$report_json" \
      --argjson worktree_path "$worktree_json" \
      --argjson home_path "$home_json" \
      --argjson endpoint_exists "$endpoint_exists" \
      --argjson open_decisions "$open_decisions_json" \
      --argjson pending_decision "$(bool_json "$pending_decision")" \
      --argjson blocked_event "$(bool_json "$blocked_event")" \
      --argjson report_present "$(bool_json "$report_present")" \
      '{
        id:$id,
        kind:$kind,
        harness:($harness // ""),
        mode:($mode // ""),
        yolo:($yolo // ""),
        project:($project // ""),
        spawn_gen:($spawn_gen | if . == "" then null else . end),
        backend:$backend,
        remote:(if $remote_host == "" then null else {host:$remote_host,root:$remote_root} end),
        paths:{
          meta:$meta_path,
          status_log:$status_log,
          worktree:$worktree_path,
          home:$home_path,
          report:$report
        },
        secondmate_projects:($projects | if . == "" then [] else split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != "")) end),
        current_state:($current_state + {observed_at:$observed_at,freshness:"fresh"}),
        endpoint:{target:($target | if . == "" then null else . end),exists:$endpoint_exists,agent_alive:$agent_alive,
          status:(if $endpoint_exists == false then "absent"
                  elif $agent_alive == "alive" or $agent_alive == "dead" then $agent_alive
                  else "unknown" end),
          observed_at:$observed_at,freshness:"fresh"},
        pr:{url:($pr | if . == "" then null else . end),source:$pr_source},
        hints:{
          pending_decision:$pending_decision,
          blocked_event:$blocked_event,
          open_decisions:$open_decisions,
          scout_report_present:$report_present,
          last_event_text:$last_event_raw
        },
        actions:(
          if $kind == "secondmate" then
            {send:"bin/fm-send.sh fm-\($id) \u0027<request>\u0027",
             watch:"read status/doc return channel; do not routinely fm-peek a secondmate for answers",
             return_channel_note:"Secondmate answers come back through status/doc paths after a marked fm-send request."}
          else
            {watch:"bin/fm-peek.sh fm-\($id)",
             steer:"bin/fm-send.sh fm-\($id) \u0027<instruction>\u0027",
             return_channel_note:null}
          end)
      }'
  done | jq -s 'sort_by(.id)'
}

# Main-home current-inventory validity: same orphan / unstructured-current checks
# used by secondmate_home_summary_json, without inventing live task rows.
# Meta inventory remains the sole source of live workers; this object only
# discloses backlog↔task inconsistency for renderers (Bearings omitted/gates).
main_inventory_json() {  # <backlog-json> <tasks-json>
  # Feed potentially large inventories through stdin. Linux limits each exec
  # argument to 128 KiB even when ARG_MAX is larger, so --argjson can reject a
  # valid large backlog before jq starts.
  printf '%s\n%s\n' "$1" "$2" | jq -s '
    .[0] as $backlog
    | .[1] as $tasks
    | ([ $backlog.records[]?
       | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured_current
    | ([ $backlog.records[]?
         | select(.state == "in_flight" and .structured and .requires_child_metadata) ]) as $owned_in_flight
    | ([ $owned_in_flight[]
         | select(.id as $id | [$tasks[].id] | index($id) | not)
         | .id ]) as $orphan_in_flight
    | (($unstructured_current | length) == 0
       and ($orphan_in_flight | length) == 0) as $valid
    | (if ($unstructured_current | length) > 0 then "unstructured current backlog row"
       elif ($orphan_in_flight | length) > 0 then "in-flight backlog item has no child metadata"
       else null end) as $reason
    | {
        valid:$valid,
        reason:$reason,
        orphan_in_flight:$orphan_in_flight,
        unstructured_current_count:($unstructured_current | length)
      }'
}

# Project one home's canonical structured inventory into the bounded shape a
# validated parent read needs.
# This mode never reads parent events or terminal text and never aggregates
# nested secondmates.
secondmate_home_summary_json() {  # <backlog-json> <tasks-json>
  printf '%s\n%s\n' "$1" "$2" | jq -s \
    --arg generated "$SNAPSHOT_NOW" \
    --argjson generated_epoch "$SNAPSHOT_EPOCH" \
    --arg home "$FM_HOME" \
    --argjson child_n "$FM_SNAPSHOT_SECONDMATE_CHILDREN" \
    --argjson queued_n "$FM_SNAPSHOT_SECONDMATE_QUEUED" \
    --argjson decisions_n "$FM_SNAPSHOT_SECONDMATE_DECISIONS" \
    --argjson landed_n "$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" '
    .[0] as $backlog
    | .[1] as $tasks
    | def trunc($n):
      tostring | gsub("\\s+"; " ")
      | if length > $n then .[:$n] + "…" else . end;
    ([ $backlog.records[]?
       | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured_current
    | ([ $backlog.records[]? | select(.state == "in_flight" and .structured) ]) as $owned_in_flight
    | ([ $backlog.records[]?
         | select(.structured and
             (.state == "queued" or
              (.state == "in_flight" and .current_role == "held"
               and (.id as $id
                    | any($tasks[]; .id == $id and .current_state.state == "working") | not)))) ]) as $queued_all
    | ([ $queued_all[]
         | select(.captain_actionable == true)
         | {id,key:.id,verb:"captain-hold",summary:(.title | trunc(160)),
            reason:(.hold_reason | trunc(160)),
            hold_until:(.hold_until // null),
            deferred_marker:(.deferred_marker // false),source:"backlog"} ]) as $captain_holds_all
    | ([ $backlog.records[]? | select(.state == "done" and .structured and .hold_kind != "captain")
         | {id:(.id | trunc(120)),title:(.title | trunc(120)),
            pr_url:((.pr_url // null) | if . == null then null else trunc(500) end),
            report_path:((.report_path // null) | if . == null then null else trunc(500) end),
            local_note:((.local_note // null) | if . == null then null else trunc(120) end),completion} ]
       | sort_by([(.completion.date // ""), .id]) | reverse) as $landed_all
    | ([ $tasks[] | select(.current_state.state == "unknown") ]) as $unknown_children
    | ([ $owned_in_flight[]
         | select(.requires_child_metadata)
         | select(.id as $id | [$tasks[].id] | index($id) | not) ]) as $orphan_in_flight
    | ([ $tasks[]
         | select(.kind != "secondmate")
         | select(.id as $id | [$owned_in_flight[].id] | index($id) | not)
         | {id,state:.current_state.state} ]) as $unowned_children
    | ([ $owned_in_flight[] as $work
         | $tasks[]
         | select(.kind != "secondmate")
         | select(.id == $work.id and (.current_state.state == "done" or .current_state.state == "failed"))
         | {id,state:.current_state.state} ]) as $terminal_in_flight
    | ([if $backlog.present != true then
          {kind:"missing_backlog",ids:[],reason:"missing structured backlog"}
        else empty end,
        if ($unstructured_current | length) > 0 then
          {kind:"unstructured_current",ids:[],reason:"unstructured current backlog row"}
        else empty end,
        if ($orphan_in_flight | length) > 0 then
          {kind:"orphan_in_flight",ids:($orphan_in_flight | map(.id)),
           reason:("in-flight backlog item has no child metadata: " + ($orphan_in_flight | map(.id) | join(", ")))}
        else empty end,
        if ($unowned_children | length) > 0 then
          {kind:"unowned_current",ids:($unowned_children | map(.id)),
           reason:("live child state has no in-flight backlog item: " +
                   ($unowned_children | map(.id + "=" + .state) | join(", ")))}
        else empty end,
        if ($terminal_in_flight | length) > 0 then
          {kind:"terminal_in_flight",ids:($terminal_in_flight | map(.id)),
           reason:("in-flight backlog item has terminal child state: " +
                   ($terminal_in_flight | map(.id + "=" + .state) | join(", ")))}
        else empty end]) as $strict_invalidities
    | ([ $owned_in_flight[] as $work
         | select($work.current_role != "program")
         | $tasks[]
         | select(.id == $work.id and .current_state.state == "working")
         | {id,kind,state:.current_state.state,
            repo:(($work.repo // .project // null) | if . == null then null else trunc(120) end),
            source:.current_state.source,
            doing:((.current_state.detail // "") | trunc(120))} ]) as $active_all
    | ($captain_holds_all
       + ([ $tasks[] as $t | ($t.hints.open_decisions // [])[]
            | {id:$t.id,key,verb,summary:(.summary | trunc(160)),reason:null,source:"status"} ])) as $decisions_all
    | ([ $queued_all[]
         | select((.unresolved_blocker_ids | length) > 0 or (.hold_reason != null and .hold_kind != null))
         | {id:(.id | trunc(120)),title:(.title | trunc(90)),
            blocked_by:((.unresolved_blocker_ids | join(",")) | if . == "" then null else trunc(120) end),
            blocked_by_ids:(.blocked_by_ids | map(trunc(120))),
            unresolved_blocker_ids:(.unresolved_blocker_ids | map(trunc(120))),
            reason:((.hold_reason // .blocked_reason // "blocked") | trunc(120)),source:"backlog"} ]
       + [ $owned_in_flight[] as $work
           | $tasks[]
           | select(.id == $work.id and (.current_state.state == "parked" or .current_state.state == "paused" or .current_state.state == "blocked"))
           | select(($work.hold_reason != null and $work.hold_kind != null) | not)
           | {id,title:((.backlog.title // .id) | trunc(90)),blocked_by:null,
              blocked_by_ids:[],unresolved_blocker_ids:[],
              reason:((.current_state.detail // .current_state.state) | trunc(120)),source:"child-state"} ]) as $holds_all
    | ($backlog.present == true
       and ($unstructured_current | length) == 0
       and ($unknown_children | length) == 0
       and ($orphan_in_flight | length) == 0
       and ($unowned_children | length) == 0
       and ($terminal_in_flight | length) == 0) as $valid
    | (if ($strict_invalidities | length) > 0 then $strict_invalidities[0].reason
       elif ($unknown_children | length) > 0 then
         "child current state unavailable: " + ($unknown_children | map(.id) | join(", "))
       else null end) as $reason
    | (if ($strict_invalidities | length) > 0 then $strict_invalidities[0] | del(.reason)
       elif ($unknown_children | length) > 0 then {kind:"child_current_unavailable",ids:($unknown_children | map(.id))}
       else {kind:null,ids:[]} end) as $invalidity
    | (if ($valid | not)
          and (($unknown_children | length) > 0
               or (["orphan_in_flight","unowned_current","terminal_in_flight"]
                   | index($invalidity.kind) | not))
       then "unknown"
       elif any($decisions_all[]; .verb == "needs-decision" or .verb == "captain-hold") then "captain_decision"
       elif ($active_all | length) > 0 then "active_child_work"
       elif ($holds_all | length) > 0 then "externally_held"
       else "no_active_work" end) as $state
    | {
        schema:"fm-secondmate-home-summary.v1",
        generated:$generated,
        generated_epoch:$generated_epoch,
        home:$home,
        valid:$valid,
        reason:$reason,
        invalidity:$invalidity,
        state:$state,
        active_children:$active_all[:$child_n],
        decisions_open:$decisions_all[:$decisions_n],
        holds:$holds_all[:$queued_n],
        queued:([$queued_all[] | {id:(.id | trunc(120)),title:(.title | trunc(120)),
          blocked_by:((.blocked_by // null) | if . == null then null else trunc(120) end),
          blocked_by_ids:((.blocked_by_ids // []) | map(trunc(120))),
          unresolved_blocker_ids:((.unresolved_blocker_ids // []) | map(trunc(120))),
          blocked_reason:((.blocked_reason // null) | if . == null then null else trunc(160) end),
          hold_reason:((.hold_reason // null) | if . == null then null else trunc(160) end),
          hold_kind:((.hold_kind // null) | if . == null then null else trunc(40) end),
          hold_until:((.hold_until // null) | if . == null then null else trunc(40) end),
          deferred_marker:(.deferred_marker // false),
          captain_actionable:(.captain_actionable // false),
          repo:((.repo // null) | if . == null then null else trunc(120) end),
          kind:((.kind // null) | if . == null then null else trunc(40) end)}][:$queued_n]),
        landed:(if $landed_n == 0 then $landed_all else $landed_all[:$landed_n] end),
        endpoints:([$tasks[] | {id,state:.current_state.state,source:.current_state.source,
          endpoint:(.endpoint + {target:((.endpoint.target // null) | if . == null then null else trunc(240) end)})}][:$child_n]),
        counts:{
          active_children:($active_all | length),
          decisions_open:($decisions_all | length),
          holds:($holds_all | length),
          queued:($queued_all | length),
          landed:($landed_all | length),
          endpoints:($tasks | length)
        },
        omitted:[
          (if ($active_all | length) > $child_n then {surface:"active_children",count:(($active_all | length) - $child_n)} else empty end),
          (if ($decisions_all | length) > $decisions_n then {surface:"decisions_open",count:(($decisions_all | length) - $decisions_n)} else empty end),
          (if ($queued_all | length) > $queued_n then {surface:"queued",count:(($queued_all | length) - $queued_n)} else empty end),
          (if ($tasks | length) > $child_n then {surface:"endpoints",count:(($tasks | length) - $child_n)} else empty end),
          (if $landed_n > 0 and ($landed_all | length) > $landed_n then {surface:"landed",count:(($landed_all | length) - $landed_n)} else empty end)
        ]
      }'
}

# Current registered-secondmate aggregation.
# The validated home summary is canonical.
# Parent status and bounded terminal capture remain untrusted supplemental evidence
# with explicit provenance, and can only produce a contradiction or unknown fallback.
FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=${FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME:-10}
case "$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" in ''|*[!0-9]*) FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=10 ;; esac

# GNU stat treats -f as a filesystem-report command, so a BSD-first fallback can
# pollute arithmetic input before failing. Select the platform syntax once.
if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
  SNAPSHOT_STAT_STYLE=bsd
  file_mtime_epoch() { stat -f '%m' "$1" 2>/dev/null || true; }
  file_mode_octal() { stat -f '%Lp' "$1" 2>/dev/null || true; }
else
  SNAPSHOT_STAT_STYLE=gnu
  file_mtime_epoch() { stat -c '%Y' "$1" 2>/dev/null || true; }
  file_mode_octal() { stat -c '%a' "$1" 2>/dev/null || true; }
fi

registry_secondmates_json() {
  local reg="$DATA/secondmates.md" out rc reason mode script parse_filter output_filter
  if [ ! -f "$reg" ]; then
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      '{present:false,available:true,complete:true,reason:null,provenance:"registered-table",path:$path,freshness:{status:"fresh",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  mode=$(file_mode_octal "$reg")
  if [ -z "$mode" ] || [ $((8#$mode & 0444)) -eq 0 ]; then
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      --arg reason "registered secondmate table is unreadable" \
      '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  script=$(cat <<'BASH'
    f=$1
    max_lines=$2
    max_bytes=$3
    max_records=$4
    path=$5
    observed=$6
    parse_filter=$7
    output_filter=$8
    content=$(LC_ALL=C head -c "$((max_bytes + 1))" "$f" || exit 3; printf "\036") || exit 3
    content=${content%$'\036'}
    bytes=$(printf "%s" "$content" | LC_ALL=C wc -c | tr -d " ")
    byte_truncated=false
    if [ "$bytes" -gt "$max_bytes" ]; then
      byte_truncated=true
      content=$(printf "%s" "$content" | LC_ALL=C head -c "$max_bytes")
      complete=${content%$'\n'*}
      if [ "$complete" != "$content" ]; then
        content=$complete
      else
        content=
      fi
    fi
    if [ -n "$content" ]; then
      lines=$(printf "%s\n" "$content" | awk "END {print NR}")
    else
      lines=0
    fi
    line_truncated=false
    if [ "$lines" -gt "$max_lines" ]; then line_truncated=true; fi
    window=$(printf "%s\n" "$content" | LC_ALL=C head -n "$max_lines") || exit 3
    if [ -n "$window" ]; then
      lines_in_window=$(printf "%s\n" "$window" | awk "END {print NR}")
    else
      lines_in_window=0
    fi
    records=$(printf "%s\n" "$window" | jq -Rn "$parse_filter") || exit 3
    records_in_window=$(printf "%s" "$records" | jq "length") || exit 3
    records_truncated=false
    if [ "$records_in_window" -gt "$max_records" ]; then records_truncated=true; fi
    printf "%s" "$records" | jq \
      --arg path "$path" --arg observed "$observed" \
      --argjson byte_truncated "$byte_truncated" \
      --argjson line_truncated "$line_truncated" \
      --argjson records_truncated "$records_truncated" \
      --argjson lines_in_window "$lines_in_window" \
      --argjson records_in_window "$records_in_window" \
      --argjson max_records "$max_records" "$output_filter"
BASH
  )
  parse_filter=$(cat <<'JQ'
      [ inputs
        | select(startswith("- "))
        | (capture("^- (?<id>[^[:space:]]+)")?) as $id
        | select($id != null)
        | ([capture("^.*\\(host:[[:space:]]*(?<host>[^;)]*);[[:space:]]*root:[[:space:]]*(?<root>[^;)]*);[[:space:]]*home:[[:space:]]*(?<home>[^;)]*);[[:space:]]*scope:[[:space:]]*.*;[[:space:]]*projects:[[:space:]]*[^;)]*;[[:space:]]*added[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}\\)[[:space:]]*$")?][0] // null) as $remote
        | ([capture("^.*\\(home:[[:space:]]*(?<home>[^;)]*);[[:space:]]*scope:[[:space:]]*.*;[[:space:]]*projects:[[:space:]]*[^;)]*;[[:space:]]*added[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}\\)[[:space:]]*$")?][0] // null) as $local
        | ($local // $remote) as $route
        | (($local == null) and ($remote != null)) as $is_remote
        | {id:$id.id,home:($route.home // null),host:(if $is_remote then $remote.host else null end),root:(if $is_remote then $remote.root else null end),
           remote:$is_remote,registered:true,
           registry_error:(if $route == null or ($route.home | length) == 0 then "registry entry has no home" else null end)} ]
      | group_by(.id)
      | map(if length > 1 then .[0] + {registry_error:"duplicate secondmate id in registry"} else .[0] end)
JQ
  )
  output_filter=$(cat <<'JQ'
      {present:true,available:true,reason:null,provenance:"registered-table",path:$path,
       freshness:{status:"fresh",observed_at:$observed},
       records:(if length > $max_records then .[:$max_records] else . end),
       input_truncated:($byte_truncated or $line_truncated),records_truncated:$records_truncated,
       complete:(($byte_truncated or $line_truncated or $records_truncated) | not),
       reasons:[
         (if $byte_truncated then "byte_limit" else empty end),
         (if $line_truncated then "line_limit" else empty end),
         (if $records_truncated then "record_limit" else empty end)
       ],lines_in_window:$lines_in_window,records_in_window:$records_in_window}
JQ
  )
  out=$(fm_run_timed "$FM_SNAPSHOT_REGISTRY_TIMEOUT" bash -c "$script" \
    fm-secondmate-registry "$reg" "$FM_SNAPSHOT_REGISTRY_LINES" \
    "$FM_SNAPSHOT_REGISTRY_BYTES" "$FM_SNAPSHOT_REGISTRY_RECORDS" "$reg" "$SNAPSHOT_NOW" \
    "$parse_filter" "$output_filter" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
    .available == true and (.records | type) == "array"
  ' >/dev/null 2>&1; then
    printf '%s' "$out"
    return 0
  fi
  [ "$rc" -eq 124 ] && reason="registered secondmate table read timed out" \
    || reason="registered secondmate table is unreadable"
  jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
    '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
}

# The remote ledger collector is the one cross-home read path used by the
# default snapshot. It writes every remote result to a private file, launches
# all sampled homes together, and places the whole collector process group under
# fm-timeout-lib's single fleet-wide deadline. A timed-out child therefore cannot
# survive the snapshot and convoy a later read.
SNAPSHOT_COLLECT_DIR=
SNAPSHOT_SUMMARY_FILTER=
SNAPSHOT_CACHE_AVAILABLE=0
SNAPSHOT_COLLECTION_TIMED_OUT=0

summary_file_read() {  # <file> <expected-home>
  local file=$1 home=$2 captured bytes
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  captured=$(umask 077; mktemp "$SNAPSHOT_COLLECT_DIR/.selected-summary.XXXXXX") || return 1
  if ! LC_ALL=C head -c "$((FM_SNAPSHOT_SECONDMATE_MAX_BYTES + 1))" "$file" > "$captured"; then
    rm -f -- "$captured"
    return 1
  fi
  bytes=$(LC_ALL=C wc -c < "$captured" | tr -d ' ')
  case "$bytes" in
    ''|*[!0-9]*) rm -f -- "$captured"; return 1 ;;
  esac
  if [ "$bytes" -gt "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES" ] \
    || ! jq -e -s --arg home "$home" -f "$SNAPSHOT_SUMMARY_FILTER" "$captured" >/dev/null 2>&1; then
    rm -f -- "$captured"
    return 1
  fi
  jq -c -s '.[0]' "$captured"
  bytes=$?
  rm -f -- "$captured"
  return "$bytes"
}

summary_file_oversized() {  # <file>
  local bytes
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  bytes=$(LC_ALL=C wc -c < "$1" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -gt "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES" ]
}

snapshot_cache_prepare() {
  local mode
  SNAPSHOT_CACHE_AVAILABLE=0
  if [ -e "$FM_SNAPSHOT_CACHE_DIR" ] || [ -L "$FM_SNAPSHOT_CACHE_DIR" ]; then
    [ -d "$FM_SNAPSHOT_CACHE_DIR" ] && [ ! -L "$FM_SNAPSHOT_CACHE_DIR" ] || return 1
    mode=$(file_mode_octal "$FM_SNAPSHOT_CACHE_DIR")
    case "$mode" in ''|*[!0-7]*) return 1 ;; esac
    [ $((8#$mode & 077)) -eq 0 ] || return 1
  else
    [ -d "$(dirname "$FM_SNAPSHOT_CACHE_DIR")" ] || return 1
    (umask 077; mkdir "$FM_SNAPSHOT_CACHE_DIR") 2>/dev/null || return 1
  fi
  SNAPSHOT_CACHE_AVAILABLE=1
}

snapshot_route_cache_path() {  # <id> <host> <home>
  local id=$1 host=$2 home=$3 key
  [ "$SNAPSHOT_CACHE_AVAILABLE" -eq 1 ] || return 1
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  if command -v shasum >/dev/null 2>&1; then
    key=$(printf '%s\n%s\n%s\n' "$id" "$host" "$home" | shasum -a 256 | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    key=$(printf '%s\n%s\n%s\n' "$id" "$host" "$home" | sha256sum | awk '{print $1}') || return 1
  else
    return 1
  fi
  case "$key" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  [ "${#key}" -eq 64 ] || return 1
  printf '%s/%s.json\n' "$FM_SNAPSHOT_CACHE_DIR" "$key"
}

snapshot_cache_store() {  # <summary-json> <destination>
  local summary=$1 destination=$2 tmp
  [ "$SNAPSHOT_CACHE_AVAILABLE" -eq 1 ] || return 1
  case "$destination" in "$FM_SNAPSHOT_CACHE_DIR"/*) ;; *) return 1 ;; esac
  [ ! -L "$destination" ] || return 1
  tmp=$(umask 077; mktemp "$FM_SNAPSHOT_CACHE_DIR/.summary.XXXXXX") || return 1
  if printf '%s\n' "$summary" > "$tmp" && chmod 600 "$tmp" && mv -f -- "$tmp" "$destination"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

prepare_remote_summary_collection() {  # <sampled-row-json-lines>
  local rows=$1 manifest collector row id home host cache_path remote_rows rc slot=0
  SNAPSHOT_COLLECT_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-fleet-ledgers.XXXXXX") || return 1
  SNAPSHOT_SUMMARY_FILTER="$SNAPSHOT_COLLECT_DIR/summary-filter.jq"
  cat > "$SNAPSHOT_SUMMARY_FILTER" <<'JQ'
length == 1 and (.[0] |
  .schema == "fm-secondmate-home-summary.v1" and .home == $home
  and (.generated | type) == "string"
  and (.generated_epoch | type) == "number" and .generated_epoch >= 0 and (.generated_epoch | floor) == .generated_epoch
  and (.valid | type) == "boolean" and (.state | type) == "string"
  and (.invalidity | type) == "object" and (.invalidity.ids | type) == "array"
  and (.active_children | type) == "array" and (.decisions_open | type) == "array"
  and (.holds | type) == "array" and (.queued | type) == "array"
  and (.landed | type) == "array" and (.endpoints | type) == "array"
  and (.counts | type) == "object" and (.omitted | type) == "array"
)
JQ
  snapshot_cache_prepare || true
  manifest="$SNAPSHOT_COLLECT_DIR/manifest.jsonl"
  : > "$manifest"
  remote_rows=$(printf '%s\n' "$rows" | jq -c '
    select(.registered == true and .remote == true and (.registry_error // "") == "")
    | select((.id | type) == "string" and (.id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")))
    | select((.host | type) == "string" and (.host | length) > 0 and (.host | test("[[:cntrl:]]") | not))
    | select((.home | type) == "string" and (.home | startswith("/")) and (.home | test("[[:cntrl:]]") | not))') || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id')
    home=$(printf '%s' "$row" | jq -r '.home')
    host=$(printf '%s' "$row" | jq -r '.host')
    cache_path=$(snapshot_route_cache_path "$id" "$host" "$home" 2>/dev/null || true)
    slot=$((slot + 1))
    jq -cn --arg id "$id" --arg home "$home" --arg cache "$cache_path" --argjson slot "$slot" \
      '{id:$id,home:$home,cache:$cache,slot:$slot}' >> "$manifest" || return 1
  done <<EOF
$remote_rows
EOF
  [ -s "$manifest" ] || return 0

  collector="$SNAPSHOT_COLLECT_DIR/collect.sh"
  cat > "$collector" <<'BASH'
#!/usr/bin/env bash
set -u
script_dir=$1
manifest=$2
out_dir=$3
filter=$4
max_bytes=$5

valid_summary() {  # <file> <home>
  local file=$1 home=$2 bytes
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  bytes=$(LC_ALL=C wc -c < "$file" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le "$max_bytes" ] || return 1
  jq -e -s --arg home "$home" -f "$filter" "$file" >/dev/null 2>&1
}

bounded_collect() {  # <output> <error> <command...>
  local output=$1 error=$2 producer_rc bytes
  shift 2
  "$@" 2> "$error" | LC_ALL=C head -c "$((max_bytes + 1))" > "$output"
  producer_rc=${PIPESTATUS[0]}
  bytes=$(LC_ALL=C wc -c < "$output" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le "$max_bytes" ] || return 75
  return "$producer_rc"
}

collect_one() {  # <manifest-row>
  local row=$1 id home cache slot fetch status
  id=$(printf '%s' "$row" | jq -r '.id') || return
  home=$(printf '%s' "$row" | jq -r '.home') || return
  cache=$(printf '%s' "$row" | jq -r '.cache') || return
  slot=$(printf '%s' "$row" | jq -r '.slot') || return
  fetch="$out_dir/$slot.fetch"
  status="$out_dir/$slot.status"
  if bounded_collect "$fetch" "$out_dir/$slot.fetch.err" \
      "$script_dir/fm-on.sh" "$id" fm-remote-file.sh get state/home-summary.json "$max_bytes" \
      && valid_summary "$fetch" "$home"; then
    printf 'fresh\n' > "$status"
    return
  fi
  if [ -n "$cache" ] && valid_summary "$cache" "$home"; then
    printf 'cached\n' > "$status"
    return
  fi
  printf 'failed\n' > "$status"
}

while IFS= read -r row; do
  [ -n "$row" ] || continue
  collect_one "$row" &
done < "$manifest"
wait
BASH
  chmod 700 "$collector"
  SNAPSHOT_COLLECTION_TIMED_OUT=0
  if fm_run_timed "$FM_SNAPSHOT_BUDGET" bash "$collector" \
      "$SCRIPT_DIR" "$manifest" "$SNAPSHOT_COLLECT_DIR" "$SNAPSHOT_SUMMARY_FILTER" \
      "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES"; then
    :
  else
    rc=$?
    [ "$rc" -eq 124 ] && SNAPSHOT_COLLECTION_TIMED_OUT=1
  fi
  return 0
}

snapshot_summary_age() {  # <summary-json>
  local generated age
  generated=$(printf '%s' "$1" | jq -r '.generated_epoch' 2>/dev/null || true)
  case "$generated" in ''|*[!0-9]*) printf 'null\n'; return ;; esac
  age=$((SNAPSHOT_EPOCH - generated))
  [ "$age" -lt 0 ] && age=0
  printf '%s\n' "$age"
}

snapshot_collection_cleanup() {
  [ -z "$SNAPSHOT_COLLECT_DIR" ] || rm -rf -- "$SNAPSHOT_COLLECT_DIR"
  SNAPSHOT_COLLECT_DIR=
  SNAPSHOT_SUMMARY_FILTER=
}
snapshot_cleanup() {
  snapshot_task_cleanup
  snapshot_collection_cleanup
}
trap snapshot_cleanup EXIT

bounded_parent_activities_json() {  # <status-file>
  local f=$1 out rc reason script
  if [ ! -f "$f" ]; then
    jq -n '{records:[],available:true,input_truncated:false,retained_truncated:false,reasons:[],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  script=$(cat <<'BASH'
    classify=$1
    f=$2
    max_lines=$3
    max_bytes=$4
    max_records=$5
    stat_style=$6
    . "$classify"
    if [ "$stat_style" = bsd ]; then
      size=$(stat -f "%z" "$f" 2>/dev/null) || exit 3
    else
      size=$(stat -c "%s" "$f" 2>/dev/null) || exit 3
    fi
    content=$(LC_ALL=C tail -c "$max_bytes" "$f") || exit 3
    byte_truncated=false
    if [ "$size" -gt "$max_bytes" ]; then
      byte_truncated=true
      complete=${content#*$'\n'}
      if [ "$complete" != "$content" ]; then
        content=$complete
      else
        content=
      fi
    fi
    if [ -n "$content" ]; then
      lines_in_chunk=$(printf "%s\n" "$content" | awk "END {print NR}")
    else
      lines_in_chunk=0
    fi
    line_truncated=false
    if [ "$lines_in_chunk" -gt "$max_lines" ]; then line_truncated=true; fi
    window=$(printf "%s\n" "$content" | LC_ALL=C tail -n "$max_lines") || exit 3
    if [ -n "$window" ]; then
      lines_in_window=$(printf "%s\n" "$window" | awk "END {print NR}")
    else
      lines_in_window=0
    fi
    records=$(printf "%s\n" "$window" | status_open_activities - \
      | jq -R -s '[splits("\n") | select(length > 0)
          | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
          | select(. != null)]') || exit 3
    records_in_window=$(printf "%s" "$records" | jq "length") || exit 3
    retained_truncated=false
    if [ "$records_in_window" -gt "$max_records" ]; then retained_truncated=true; fi
    printf "%s" "$records" | jq \
      --argjson byte_truncated "$byte_truncated" \
      --argjson line_truncated "$line_truncated" \
      --argjson retained_truncated "$retained_truncated" \
      --argjson lines_in_window "$lines_in_window" \
      --argjson records_in_window "$records_in_window" \
      --argjson max_records "$max_records" '
        {records:(if length > $max_records then .[-$max_records:] else . end),
         available:true,
         input_truncated:($byte_truncated or $line_truncated),
         retained_truncated:$retained_truncated,
         reasons:[
           (if $byte_truncated then "byte_limit" else empty end),
           (if $line_truncated then "line_limit" else empty end),
           (if $retained_truncated then "activity_limit" else empty end)
         ],
         lines_in_window:$lines_in_window,
         records_in_window:$records_in_window}'
BASH
  )
  out=$(fm_run_timed "$FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT" bash -c "$script" \
    fm-parent-activities "$SCRIPT_DIR/fm-classify-lib.sh" "$f" \
    "$FM_SNAPSHOT_PARENT_ACTIVITY_LINES" "$FM_SNAPSHOT_PARENT_ACTIVITY_BYTES" \
    "$FM_SNAPSHOT_PARENT_ACTIVITIES" "$SNAPSHOT_STAT_STYLE" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
    (.records | type) == "array" and (.available | type) == "boolean"
  ' >/dev/null 2>&1; then
    printf '%s' "$out"
    return 0
  fi
  [ "$rc" -eq 124 ] && reason="timeout" || reason="read_failed"
  jq -n --arg reason "$reason" \
    '{records:[],available:false,input_truncated:false,retained_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
}

terminal_evidence_json() {  # <parent-task-json> <event-note> <evidence-contradicts>
  local task=$1 note=$2 evidence_contradicts=$3 backend target exists expected out rc clean bytes lines seen=false contradiction=false reason='' remote_host id captured_meta
  backend=$(printf '%s' "$task" | jq -r '.backend // ""')
  target=$(printf '%s' "$task" | jq -r '.endpoint.target // ""')
  exists=$(printf '%s' "$task" | jq -r '.endpoint.exists // "unknown"')
  remote_host=$(printf '%s' "$task" | jq -r '.remote.host // ""')
  id=$(printf '%s' "$task" | jq -r '.id // ""')
  if [ -n "$remote_host" ]; then
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "remote terminal evidence is not collected by the primary" \
      '{provenance:"remote-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  expected="fm-$id"
  if [ -z "$target" ] || [ "$exists" = false ]; then
    [ "$exists" = false ] && reason="recorded endpoint is absent" || reason="no recorded endpoint"
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
      '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"unknown",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  captured_meta="$SNAPSHOT_TASK_DIR/$id.meta"
  if [ ! -f "$captured_meta" ] || ! snapshot_task_generation_is_current "$captured_meta" "$id"; then
    jq -n --arg observed "$SNAPSHOT_NOW" \
      '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"unknown",reason:"task generation changed during snapshot",lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  # shellcheck disable=SC2016 # Positional parameters expand inside the child bash, not here.
  out=$(fm_run_timed "$FM_SNAPSHOT_TERMINAL_TIMEOUT" bash -c \
    '. "$1"; fm_backend_capture "$2" "$3" "$4" "$5" | LC_ALL=C head -c "$6"; rc=${PIPESTATUS[0]}; [ "$rc" -eq 141 ] && rc=0; exit "$rc"' \
    fm-terminal-capture "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" "$FM_SNAPSHOT_TERMINAL_LINES" "$expected" "$FM_SNAPSHOT_TERMINAL_BYTES" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 124 ] && reason="terminal capture timed out" || reason="terminal capture unavailable"
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
      '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"unknown",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  if ! snapshot_task_generation_is_current "$captured_meta" "$id"; then
    jq -n --arg observed "$SNAPSHOT_NOW" \
      '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"unknown",reason:"task generation changed during snapshot",lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  clean=$(printf '%s' "$out" | tail -n "$FM_SNAPSHOT_TERMINAL_LINES" | LC_ALL=C head -c "$FM_SNAPSHOT_TERMINAL_BYTES")
  if command -v perl >/dev/null 2>&1; then
    clean=$(printf '%s' "$clean" | perl -pe 's/\e\[[0-?]*[ -\/]*[@-~]//g; s/[^\x09\x0A\x0D\x20-\x7E]//g')
  else
    clean=$(printf '%s' "$clean" | LC_ALL=C tr -cd '\11\12\15\40-\176')
  fi
  bytes=$(printf '%s' "$clean" | LC_ALL=C wc -c | tr -d ' ')
  if [ -n "$clean" ]; then
    lines=$(printf '%s\n' "$clean" | wc -l | tr -d ' ')
  else
    lines=0
  fi
  if [ -n "$note" ]; then
    case "$clean" in *"$note"*) seen=true ;; esac
  fi
  if [ "$seen" = true ] && [ "$evidence_contradicts" = true ]; then contradiction=true; fi
  jq -n \
    --arg observed "$SNAPSHOT_NOW" \
    --argjson lines "$lines" \
    --argjson bytes "$bytes" \
    --argjson seen "$seen" \
    --argjson contradiction "$contradiction" \
    '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:true,observed_at:$observed,freshness:"fresh",reason:null,lines:$lines,bytes:$bytes,event_note_seen:$seen,contradiction:$contradiction}'
}

parent_evidence_reconciliation_json() {  # <summary-json> <activities-json> <decisions-json>
  jq -n --argjson summary "$1" --argjson activities "$2" --argjson decisions "$3" '
    def keyed: . != null and . != "" and . != "default";
    def result($e; $matches; $complete; $surface):
      $e + {
        verdict:(if ($e.key | keyed | not) then "inconclusive"
                 elif ($matches | length) > 0 then "corroborates"
                 elif $complete then "contradicts"
                 else "inconclusive" end),
        compared_to:$surface,
        matched:(if ($e.key | keyed) then ($matches[0] // null) else null end)
      };
    ([ $activities[] as $e
       | if $e.verb == "working" then
           ([ $summary.active_children[]
              | select(if ($e.key | keyed) then .id == $e.key else true end)
              | {surface:"active_children",id,key:null,verb:"working"}]) as $matches
           | result($e; $matches;
               $summary.counts.active_children == ($summary.active_children | length);
               "active_children")
         elif $e.verb == "paused" then
           ([ $summary.holds[]
              | select(if ($e.key | keyed) then .id == $e.key or .blocked_by == $e.key else true end)
              | {surface:"holds",id,key:(.blocked_by // null),verb:"paused"}]) as $matches
           | result($e; $matches;
               $summary.counts.holds == ($summary.holds | length);
               "holds")
         else
           $e + {verdict:"inconclusive",compared_to:null,matched:null}
         end ]) as $activity_results
    | ([ $decisions[] as $e
         | if $e.verb == "needs-decision" then
             ([ $summary.decisions_open[]
                | select(.verb == "needs-decision")
                | select(if ($e.key | keyed) then .key == $e.key else true end)
                | {surface:"decisions_open",id,key,verb}]) as $matches
             | result($e; $matches;
                 $summary.counts.decisions_open == ($summary.decisions_open | length);
                 "decisions_open")
           elif $e.verb == "blocked" then
             ([ $summary.decisions_open[]
                | select(.verb == "blocked")
                | select(if ($e.key | keyed) then .key == $e.key or .id == $e.key else true end)
                | {surface:"decisions_open",id,key,verb}]
              + [ $summary.holds[]
                  | select(if ($e.key | keyed) then .id == $e.key or .blocked_by == $e.key else true end)
                  | {surface:"holds",id,key:(.blocked_by // null),verb:"blocked"}]) as $matches
             | result($e; $matches;
                 ($summary.counts.decisions_open == ($summary.decisions_open | length)
                  and $summary.counts.holds == ($summary.holds | length));
                 "decisions_open_or_holds")
           else
             $e + {verdict:"inconclusive",compared_to:null,matched:null}
           end ]) as $decision_results
    | {provenance:"parent-status-keyed-fold",trust:"untrusted-supplement",
       activities:$activity_results,decisions:$decision_results,
       contradiction:any(($activity_results + $decision_results)[]; .verdict == "contradicts"),
       inconclusive:any(($activity_results + $decision_results)[]; .verdict == "inconclusive")}'
}

secondmate_current_json() {  # <parent-tasks-json>
  local tasks=$1 registry union rows total_registered total shown truncated
  local row id home host remote registered registry_error task sampled_spawn_gen status_file status_observation_file event_raw event_note event_epoch event_age
  local activity_scan activities decisions reconciliation provenance freshness reason summary summary_sampled summary_valid summary_reason summary_invalidity state current_reason terminal terminal_contradiction contradiction
  local summary_source summary_age summary_observed summary_freshness cache_path collection_status collection_slot
  local records='[]' seen_homes=''
  registry=$(registry_secondmates_json) || return 1
  union=$(printf '%s\n%s\n' "$registry" "$tasks" | jq -s '
    .[0] as $registry
    | .[1] as $tasks
    | ($registry.records // []) as $registered
    | (($registered | map(.id)) // []) as $registered_ids
    | ([ $registered[] as $r
         | $r + {parent_task:([$tasks[] | select(.id == $r.id)][0] // null)} ]
       + [ $tasks[] | select(.kind == "secondmate") as $t
           | select(($registered_ids | index($t.id)) == null)
           | {id:$t.id,home:($t.paths.home.path // null),
              registered:(if $registry.complete == true then false else null end),
              registry_error:(if $registry.complete == true
                              then "secondmate metadata is not registered"
                              else "secondmate registration is unknown because the registry read is incomplete or unavailable" end),
              parent_task:$t} ])
    | sort_by(.id)
    | {registry:$registry,records:.}') || return 1
  total_registered=$(printf '%s' "$union" | jq '[.records[] | select(.registered)] | length')
  total=$(printf '%s' "$union" | jq '.records | length')
  rows=$(printf '%s' "$union" | jq -c --argjson cap "$FM_SNAPSHOT_SECONDMATES" '(if $cap == 0 then .records else .records[:$cap] end)[]')
  shown=$(printf '%s\n' "$rows" | grep -c . || true)
  truncated=$((total - shown))
  if [ -n "$rows" ]; then
    prepare_remote_summary_collection "$rows" || return 1
  fi

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id')
    home=$(printf '%s' "$row" | jq -r '.home // ""')
    host=$(printf '%s' "$row" | jq -r '.host // ""')
    remote=$(printf '%s' "$row" | jq -r '.remote // false')
    registered=$(printf '%s' "$row" | jq -r '.registered')
    registry_error=$(printf '%s' "$row" | jq -r '.registry_error // ""')
    task=$(printf '%s' "$row" | jq -c '.parent_task // {}')
    sampled_spawn_gen=$(printf '%s' "$task" | jq -r '.spawn_gen // ""')
    status_file=$(printf '%s' "$task" | jq -r '.paths.status_log.path // ""')
    status_observation_file=
    if [ -n "$status_file" ]; then status_observation_file="$SNAPSHOT_TASK_DIR/$id.status"; fi
    event_raw=$(printf '%s' "$task" | jq -r '.paths.status_log.last_event.raw // ""')
    event_note=$(printf '%s' "$task" | jq -r '.paths.status_log.last_event.note // ""')
    activity_scan=$(bounded_parent_activities_json "$status_observation_file")
    activities=$(printf '%s' "$activity_scan" | jq -c '.records')
    decisions=$(printf '%s' "$task" | jq -c '.hints.open_decisions // []')
    event_epoch=$(file_mtime_epoch "$status_observation_file")
    event_age=null
    if [ -n "$event_epoch" ]; then
      event_age=$((SNAPSHOT_EPOCH - event_epoch))
      [ "$event_age" -lt 0 ] && event_age=0
    fi

    reason=$registry_error
    summary='{}'
    summary_sampled=false
    summary_valid=false
    if [ -z "$reason" ] && [ -z "$home" ]; then reason="no recorded secondmate home"; fi
    if [ -z "$reason" ]; then
      case "$home" in
        /*) : ;;
        *) reason="invalid home: registered path is not absolute" ;;
      esac
    fi
    if [ -z "$reason" ]; then
      if [ "$remote" = true ]; then
        [ -n "$host" ] || reason="invalid remote route: missing SSH host"
        case " $seen_homes " in
          *" $host:$home "*) reason="invalid home: duplicate resolved remote route" ;;
          *) seen_homes="$seen_homes $host:$home" ;;
        esac
      elif ! validate_secondmate_home "$id" "$home" 2>/dev/null; then
        reason="invalid home: $VALIDATION_ERROR"
      else
        home=$VALIDATED_HOME
        case " $seen_homes " in
          *" local:$home "*) reason="invalid home: duplicate resolved home route" ;;
          *) seen_homes="$seen_homes local:$home" ;;
        esac
      fi
    fi
    summary_source=
    summary_age=0
    summary_observed=$SNAPSHOT_NOW
    summary_freshness=fresh
    if [ -z "$reason" ]; then
      if [ "$remote" = true ]; then
        cache_path=$(snapshot_route_cache_path "$id" "$host" "$home" 2>/dev/null || true)
        collection_slot=$(jq -r --arg id "$id" 'select(.id == $id) | .slot' "$SNAPSHOT_COLLECT_DIR/manifest.jsonl" 2>/dev/null | head -1)
        collection_status=$(cat "$SNAPSHOT_COLLECT_DIR/$collection_slot.status" 2>/dev/null || true)
        if summary=$(summary_file_read "$SNAPSHOT_COLLECT_DIR/$collection_slot.fetch" "$home"); then
          summary_source='remote-ledger'
          [ -z "$cache_path" ] || snapshot_cache_store "$summary" "$cache_path" || true
        elif [ -n "$cache_path" ] && summary=$(summary_file_read "$cache_path" "$home"); then
          summary_source='remote-ledger-cache'
          summary_freshness=cached
        elif summary_file_oversized "$SNAPSHOT_COLLECT_DIR/$collection_slot.fetch"; then
          reason="structured home ledger exceeded byte limit and no valid cached copy is available"
        elif [ "$SNAPSHOT_COLLECTION_TIMED_OUT" -eq 1 ] && [ -z "$collection_status" ]; then
          reason="structured home ledger collection timed out and no valid cached copy is available"
        else
          reason="structured home ledger is missing, unreadable, or invalid and no valid cached copy is available"
        fi
      elif summary=$(summary_file_read "$home/state/home-summary.json" "$home"); then
        summary_source='local-ledger'
      elif summary_file_oversized "$home/state/home-summary.json"; then
        reason="structured home ledger exceeded byte limit"
      else
        reason="structured home ledger is missing, unreadable, or invalid"
      fi
      if [ -z "$reason" ]; then
        summary_age=$(snapshot_summary_age "$summary")
        summary_observed=$(printf '%s' "$summary" | jq -r '.generated')
      fi
    fi
    # Failed command substitutions clear their assignment target. Keep the
    # unsampled record's --argjson input valid without retaining any rejected
    # or oversized summary fragment.
    if [ -n "$reason" ]; then summary='{}'; fi
    if [ -z "$reason" ]; then
      summary_sampled=true
      summary_valid=$(printf '%s' "$summary" | jq -r '.valid')
      if [ "$summary_valid" != true ]; then
        summary_reason=$(printf '%s' "$summary" | jq -r '.reason // "unknown reason"')
        summary_invalidity=$(printf '%s' "$summary" | jq -r '.invalidity.kind // "unknown"')
        case "$summary_invalidity" in
          child_current_unavailable|orphan_in_flight|unowned_current|terminal_in_flight) : ;;
          *) reason="structured home state invalid: $summary_reason" ;;
        esac
      fi
    fi

    if [ -z "$reason" ]; then
      state=$(printf '%s' "$summary" | jq -r '.state')
      current_reason=
      if [ "$summary_valid" != true ]; then
        current_reason="structured home state invalid: $(printf '%s' "$summary" | jq -r '.reason // "unknown reason"')"
      fi
      reconciliation=$(parent_evidence_reconciliation_json "$summary" "$activities" "$decisions")
      contradiction=$(printf '%s' "$reconciliation" | jq -r '.contradiction')
      terminal_contradiction=$(printf '%s' "$reconciliation" | jq -r --arg note "$event_note" '
        any(.activities[]; .verdict == "contradicts" and .summary == $note)')
      if [ "$terminal_contradiction" = true ]; then
        terminal=$(terminal_evidence_json "$task" "$event_note" true)
      else
        terminal=$(jq -n --arg observed "$SNAPSHOT_NOW" \
          '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:"no useful contradiction check",lines:0,bytes:0,event_note_seen:false,contradiction:false}')
      fi
      if printf '%s' "$terminal" | jq -e '.contradiction == true' >/dev/null; then contradiction=true; fi
      record=$(jq -n \
        --arg id "$id" --arg home "$home" --arg host "$host" --argjson remote "$remote" --arg state "$state" --arg current_reason "$current_reason" --arg observed "$summary_observed" \
        --arg summary_source "$summary_source" --arg summary_freshness "$summary_freshness" --argjson summary_age "$summary_age" \
        --arg spawn_gen "$sampled_spawn_gen" \
        --argjson registered "$registered" --argjson summary "$summary" --argjson summary_valid "$summary_valid" --argjson decisions "$decisions" \
        --argjson activities "$activities" --argjson activity_scan "$activity_scan" \
        --argjson reconciliation "$reconciliation" --argjson terminal "$terminal" --argjson contradiction "$contradiction" \
        --arg event_raw "$event_raw" --arg event_note "$event_note" --argjson event_age "$event_age" '
        {id:$id,home:$home,host:($host | if . == "" then null else . end),remote:$remote,registered:$registered,
         spawn_gen:($spawn_gen | if . == "" then null else . end),
         current:{state:$state,reason:($current_reason | if . == "" then null else . end)},invalidity:$summary.invalidity,
         reconcile_inventory:$summary.invalidity,
         provenance:{selected:"structured-home",structured_home:$home,summary_source:$summary_source,summary_valid:$summary_valid,
           trust:(if $summary_valid then "complete" else "partial-structured" end),parent_event_role:"historical-only"},
         freshness:{status:$summary_freshness,observed_at:$observed,age_seconds:$summary_age},
         active_children:$summary.active_children,
         decisions_open:$summary.decisions_open,holds:$summary.holds,queued:$summary.queued,
         landed:$summary.landed,endpoints:$summary.endpoints,counts:$summary.counts,omitted:$summary.omitted,
         parent_event:{raw:$event_raw,note:$event_note,age_seconds:$event_age,open_activities:$activities,open_decisions:$decisions,activity_scan:$activity_scan,reconciliation:$reconciliation},
         terminal_evidence:$terminal,contradiction:$contradiction}')
    else
      if [ -n "$event_raw" ]; then
        provenance='parent-event-fallback'
        freshness=historical-event
      else
        provenance=unknown
        freshness=unknown
      fi
      if [ -n "$event_raw" ]; then
        terminal=$(terminal_evidence_json "$task" "$event_note" false)
      else
        terminal=$(jq -n --arg observed "$SNAPSHOT_NOW" \
          '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:"no parent event to compare",lines:0,bytes:0,event_note_seen:false,contradiction:false}')
      fi
      record=$(jq -n \
        --arg id "$id" --arg home "$home" --arg host "$host" --argjson remote "$remote" --arg reason "$reason" --arg observed "$SNAPSHOT_NOW" \
        --arg spawn_gen "$sampled_spawn_gen" \
        --arg provenance "$provenance" --arg freshness "$freshness" --arg event_raw "$event_raw" --arg event_note "$event_note" \
        --argjson registered "$registered" --argjson event_age "$event_age" --argjson activities "$activities" --argjson activity_scan "$activity_scan" \
        --argjson decisions "$decisions" --argjson terminal "$terminal" --argjson summary "$summary" --argjson summary_sampled "$summary_sampled" '
        {id:$id,home:($home | if . == "" then null else . end),host:($host | if . == "" then null else . end),remote:$remote,registered:$registered,
         spawn_gen:($spawn_gen | if . == "" then null else . end),
         current:{state:"unknown",reason:$reason},invalidity:null,
         reconcile_inventory:(if $summary_sampled then $summary.invalidity else null end),
         provenance:{selected:$provenance,structured_home:($home | if . == "" then null else . end),parent_event_role:"fallback-only-not-current"},
         freshness:{status:$freshness,observed_at:$observed,age_seconds:$event_age},
         active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},omitted:[],
         parent_event:{raw:$event_raw,note:$event_note,age_seconds:$event_age,open_activities:$activities,open_decisions:$decisions,activity_scan:$activity_scan},
         terminal_evidence:$terminal,contradiction:false}')
    fi
    records=$(jq -n --argjson records "$records" --argjson record "$record" '$records + [$record]')
  done <<EOF
$rows
EOF
  snapshot_collection_cleanup
  jq -n \
    --argjson registry "$(printf '%s' "$union" | jq '.registry')" \
    --argjson records "$records" \
    --argjson total_registered "$total_registered" \
    --argjson total "$total" \
    --argjson shown "$shown" \
    --argjson truncated "$truncated" \
    '{registry:$registry,records:$records,total_registered:$total_registered,total:$total,shown:$shown,truncated:$truncated}'
}

secondmate_landed_from_current_json() {  # <secondmate-current-json>
  jq -n --argjson current "$1" '
    {records:[ $current.records[]
      | select(.provenance.selected == "structured-home") as $mate
      | $mate.landed[]
      | . + {home:$mate.home,home_id:$mate.id}],
     truncated:[ $current.records[]
       | select(.provenance.selected == "structured-home" and (.counts.landed > (.landed | length)))
       | .home],
     unreadable:[ $current.records[]
       | select(.current.state == "unknown" and .provenance.selected != "structured-home")
       | .home // ("<" + .id + ": unavailable>")],
     partial:[ $current.records[]
       | select(.provenance.selected == "structured-home" and .provenance.trust == "partial-structured")
       | .home // ("<" + .id + ": partial>")]}
    | .records |= sort_by([(.completion.date // ""), .id]) | .records |= reverse'
}

scout_report_lines() {
  local report id
  if [ ! -d "$DATA" ]; then
    jq -n '[]'
    return 0
  fi
  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md -print \
    | sort \
    | while IFS= read -r report; do
      id=$(basename "$(dirname "$report")")
      jq -n --arg id "$id" --arg path "$report" '{id:$id,path:$path}'
    done \
    | jq -s 'sort_by(.id)'
}

BACKLOG_JSON=$(backlog_json) || { echo "fm-fleet-snapshot: backlog read failed" >&2; exit 1; }
prefetch_task_current_states || { echo "fm-fleet-snapshot: task observation failed" >&2; exit 1; }
TASKS_JSON=$(task_json_lines) || { echo "fm-fleet-snapshot: task snapshot failed" >&2; exit 1; }

if [ "$OUTPUT_MODE" = secondmate-home-summary ]; then
  secondmate_home_summary_json "$BACKLOG_JSON" "$TASKS_JSON" \
    || { echo "fm-fleet-snapshot: secondmate home summary failed" >&2; exit 1; }
  exit 0
fi

SCOUT_REPORTS_JSON=$(scout_report_lines)
MAIN_INVENTORY_JSON=$(main_inventory_json "$BACKLOG_JSON" "$TASKS_JSON") \
  || { echo "fm-fleet-snapshot: main inventory summary failed" >&2; exit 1; }
SECONDMATE_CURRENT_JSON=$(secondmate_current_json "$TASKS_JSON") \
  || { echo "fm-fleet-snapshot: registered secondmate aggregation failed" >&2; exit 1; }
SECONDMATE_LANDED_JSON=$(secondmate_landed_from_current_json "$SECONDMATE_CURRENT_JSON") \
  || { echo "fm-fleet-snapshot: secondmate landed projection failed" >&2; exit 1; }

# Stream fleet-sized JSON values through stdin rather than argv: Linux applies
# a much smaller per-argument limit than ARG_MAX, including to --argjson.
printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
  "$BACKLOG_JSON" "$TASKS_JSON" "$MAIN_INVENTORY_JSON" "$SCOUT_REPORTS_JSON" \
  "$SECONDMATE_CURRENT_JSON" "$SECONDMATE_LANDED_JSON" \
| jq -s \
  --arg generated "$SNAPSHOT_NOW" \
  --arg fm_home "$FM_HOME" \
  --arg fm_root "$FM_ROOT" \
  --arg state "$STATE" \
  --arg data "$DATA" \
  --arg config "$CONFIG" \
  --arg projects "$PROJECTS" \
  '.[0] as $backlog
   | .[1] as $tasks
   | .[2] as $main_inventory
   | .[3] as $scout_reports
   | .[4] as $secondmate_current
   | .[5] as $secondmate_landed
   | def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
   def task_by_id($id): ($tasks[]? | select(.id == $id) | .) // null;
   def report_kind($id): (task_by_id($id).kind // backlog_by_id($id).kind // "scout");
   {
     schema:"fm-fleet-snapshot.v1",
     generated:$generated,
     fm_home:$fm_home,
     roots:{fm_root:$fm_root,state:$state,data:$data,config:$config,projects:$projects},
     backlog:$backlog,
     tasks:($tasks | map(. + {backlog:backlog_by_id(.id)})),
     main_inventory:$main_inventory,
     scout_reports:($scout_reports | map(. + {kind:report_kind(.id)})),
     secondmate_current:$secondmate_current,
     secondmate_landed:$secondmate_landed,
     secondmate_guidance:{
       note:"For kind=secondmate, bearings selects validated structured state from that registered home; parent events and bounded terminal evidence are fallback-only supplements and never current-state authority."
     }
   }'
