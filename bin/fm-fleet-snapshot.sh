#!/usr/bin/env bash
# fm-fleet-snapshot.sh - structured fleet snapshot.
#
# Output contract: `--json` prints one object with schema
# `fm-fleet-snapshot.v1`.
# `--task <task-id>` keeps that schema but limits task observations and output
# records to one exact identity; fleet-level inventory validity is then marked
# not evaluated rather than inferred from the partial view.
# The command does not acquire the session lock, drain wakes, arm watchers,
# mutate backlog state, or write reports.
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
#     unresolved_blocker_ids, captain_actionable, hold_set, hold_age_days,
#     and hold_bucket fields.
#     Repeated blocker tokens remain ordered; a blocker resolves only when its
#     structured record is Done, and missing ids stay open.
#     There is no separate decision type: any captain-held task is the same
#     primitive, whatever kind its row carries.
#     hold_bucket is the single classification for every captain hold, decided
#     only from structured fields - state, hold_kind, hold_until,
#     unresolved_blocker_ids, and the machine-written hold-set timestamp. No
#     hold reason or body prose is ever matched. The buckets are total and
#     mutually exclusive, so every captain hold lands in exactly one and none
#     can fall through: "blocked" when any blocker is unresolved, else "dated"
#     when hold_until is still in the future, else "aged" when an undated hold
#     is at least FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS old (default 14; legacy
#     unstamped holds fall back to `since`), else "live". A non-captain or Done
#     row carries null.
#     captain_actionable means "waiting on the captain now" and is exactly
#     hold_bucket == "live".
#     hold_age_days is the hold's age when computable, else null.
#     Aging is a projection safety net only: the durable deferral remains
#     re-holding with --until.
#     Renderers keep every non-live bucket out of the default Captain's Call,
#     project it as a Charted Next gate stating why, and disclose it in
#     omitted[]; --all-decisions reveals every captain hold available within the
#     bounded snapshot.
#   tasks[]: one row per task metadata record captured at snapshot start, sorted
#     by id. A record removed before capture is omitted. If a captured task's
#     generation changes while observations run, its selected metadata remains
#     but mutable current-state, status, report, and endpoint evidence is discarded
#     rather than attributed to the replacement generation.
#     deferred_marker is a presentation hint only: the row's hold reason or
#     body carries an explicit SUPERSEDED / NOT REQUIRED / DEFERRED marker.
#     It never changes captain_actionable; renderers may use it to keep
#     prose-deferred rows out of default views.
#     executor discriminates local-agent from legacy cloud-worker and native
#     remote-agent task records.
#     current_state is parsed from bin/fm-task-state.sh <id> and preserves
#     state, source, detail, and raw line separately; that provider-aware wrapper
#     delegates local agents to bin/fm-crew-state.sh.
#     paths.status_log.last_event is historical wake-event data only, never
#     current state.
#     record_disposition separates current backlog state from the configured
#     tasks-axi Done archive. retained_record is true for a closed current row or
#     archive record with no current working evidence. It is not proof of endpoint
#     cleanup or successful acceptance; endpoint evidence stays visible.
#     hints.open_decisions is the keyed open-decision set returned by
#     fm-classify-lib.sh's authoritative status_open_decisions fold and reconciled
#     against current_state; hints.pending_decision and hints.blocked_event are
#     booleans derived from that set.
#     endpoint.exists is the cheap local backend endpoint-presence read and is
#     null for cloud-worker and remote-agent tasks.
#     endpoint.agent_alive is not probed by this snapshot; cloud-worker and
#     remote-agent tasks use "not_applicable" and local tasks use "not_checked".
#   scout_reports[]: present data/<id>/report.md pointers.
#   main_inventory: {valid,reason,orphan_in_flight[],unstructured_current_count} -
#     main-home current-inventory checks (orphan structured in-flight ids with no
#     state/<id>.meta, and unstructured current backlog rows). Does not invent live
#     tasks; meta remains truth for workers. Bearings maps failures into omitted[]
#     disclosure rather than silently showing an empty Underway section.
#
# Compatibility: JSON is the primary machine-readable surface.
# Human views must render this output instead of parsing state files again.
set -u

JSON_TRANSPORT_DIR=
cleanup_json_files() {
  [ -n "$JSON_TRANSPORT_DIR" ] || return 0
  rm -rf -- "$JSON_TRANSPORT_DIR"
}

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

FM_SNAPSHOT_CREW_STATE_TIMEOUT=${FM_SNAPSHOT_CREW_STATE_TIMEOUT:-10}
FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=${FM_SNAPSHOT_LOCAL_READ_CONCURRENCY:-8}
validate_positive_bound() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0)
      printf 'fm-fleet-snapshot: %s must be a positive integer\n' "$1" >&2
      exit 2
      ;;
  esac
}
validate_positive_bound FM_SNAPSHOT_CREW_STATE_TIMEOUT "$FM_SNAPSHOT_CREW_STATE_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_LOCAL_READ_CONCURRENCY "$FM_SNAPSHOT_LOCAL_READ_CONCURRENCY"
FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=${FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS:-14}
case "$FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS" in
  ''|*[!0-9]*)
    echo "fm-fleet-snapshot: FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS must be a non-negative integer" >&2
    exit 2
    ;;
esac

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-task-disposition-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-task-disposition-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"  # fm_run_timed: the shared hard bound

usage() {
  cat <<'EOF'
usage: fm-fleet-snapshot.sh --json [--task <task-id>]

Print a structured snapshot of the firstmate fleet.
JSON is the stable machine-readable output contract.
Each local per-task current-state read is bounded by FM_SNAPSHOT_CREW_STATE_TIMEOUT
(default 10 seconds); a read that hits the bound reports state unknown. Local task
observations run concurrently, up to FM_SNAPSHOT_LOCAL_READ_CONCURRENCY (default 8).
Every captain hold carries hold_bucket, decided only from structured fields and
never from hold reason or body prose: "blocked", "dated", "aged", or "live".
An undated hold ages once its hold-set timestamp is at least
FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS old (default 14; 0 ages every hold with a
non-negative computed age); legacy holds without a stamp fall back to their
since date, and re-holding with --until remains the durable deferral.
EOF
}

TARGET_TASK_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) ;;
    --task)
      [ $# -gt 1 ] || { echo "fm-fleet-snapshot: --task requires a task id" >&2; usage >&2; exit 2; }
      case "$2" in ''|-*) echo "fm-fleet-snapshot: --task requires a non-option task id" >&2; usage >&2; exit 2 ;; esac
      shift
      TARGET_TASK_ID=$1
      ;;
    --task=*)
      TARGET_TASK_ID=${1#--task=}
      case "$TARGET_TASK_ID" in
        '') echo "fm-fleet-snapshot: --task requires a task id" >&2; usage >&2; exit 2 ;;
        -*) echo "fm-fleet-snapshot: --task requires a non-option task id" >&2; usage >&2; exit 2 ;;
      esac
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
case "$TARGET_TASK_ID" in
  ''|*[!A-Za-z0-9._-]*)
    [ -z "$TARGET_TASK_ID" ] || { echo "fm-fleet-snapshot: invalid task id" >&2; exit 2; }
    ;;
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
# snapshot without limit. A read that hits the bound folds to state unknown.
crew_state_json() {  # <id> [<captured-meta>] [<captured-status>]
  local id=$1 captured_meta=${2:-} captured_status=${3:-} raw rest state source detail sep
  raw=$(
    fm_run_timed "$FM_SNAPSHOT_CREW_STATE_TIMEOUT" \
      env FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_CREW_STATE_META_OVERRIDE="$captured_meta" \
      FM_CREW_STATE_STATUS_OVERRIDE="$captured_status" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-task-state.sh" "$id" 2>/dev/null || true
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
  jq -Rn --arg path "$backlog" --arg today "$SNAPSHOT_TODAY" --arg now "$SNAPSHOT_NOW" \
    --argjson age_days "$FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def timestamp_epoch($d):
      if ($d | type) != "string" then null
      elif ($d | test("T")) then try ($d | fromdateiso8601) catch null
      else try (($d + "T00:00:00Z") | fromdateiso8601) catch null end;
    def days_between($from; $to):
      (timestamp_epoch($from)) as $a
      | (timestamp_epoch($to)) as $b
      | if $a == null or $b == null then null
        else (($b - $a) / 86400 | floor) end;
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
    # LOAD-BEARING, do not remove as a duplicate definition of the kind field.
    # tasks-axi 0.2.5 omits the (kind: ...) metadata when a title starts with
    # uppercase SCOUT or SHIP at a JavaScript word boundary (ASCII letters,
    # digits, and underscore are word characters), so those rows carry no
    # explicit kind to read. Without this fallback a scout whose title starts
    # with SCOUT reports kind null, its
    # recorded report stops counting as a delivery, and it drops out of Recently
    # Landed - the defect this selector exists to fix. Pinned by
    # the producer word-boundary regression in tests/fm-bearings-snapshot.test.sh.
    def kind_of($rest):
      metadata($rest; "kind") as $kind
      | if $kind != null then $kind
        elif ($rest | test("^SCOUT(?![A-Za-z0-9_])")) then "scout"
        elif ($rest | test("^SHIP(?![A-Za-z0-9_])")) then "ship"
        else null end;
    def hold_metadata($rest):
      cap($rest; ".*\\(hold:[[:space:]]*(?<v>[^)]*)");
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
    def compact_progress($lines):
      ([$lines | join("\n") | capture(
        "(?:^|\\n)<!-- firstmate-progress:v1(?: context=[a-f0-9]{64}(?: identity=[a-f0-9]{64})?)? -->\\n" +
        "acceptance: (?<acceptance>[^\\n]*)\\ncurrent_state: (?<current_state>[^\\n]*)\\n" +
        "remaining_gap: (?<remaining_gap>[^\\n]*)\\nnext_step: (?<next_step>[^\\n]*)\\n" +
        "<!-- /firstmate-progress -->")] | .[0] // null) as $match
      | if $match == null then null
        else try ($match | with_entries(.value |= fromjson)) catch {invalid:true}
        end;
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
             kind:kind_of($rest),
             priority:metadata($rest; "priority"),
             hold_reason:hold_metadata($rest),
             hold_kind:metadata($rest; "hold-kind"),
             hold_until:metadata($rest; "hold-until"),
             hold_set:null,
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
          .hold_set = cap(.body_lines[0]; "^Captain hold set:[[:space:]]*(?<v>[0-9]{4}-[0-9]{2}-[0-9]{2}(?:T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?)$")
          | .local_note = (.local_note
              // (if any(.body_lines[];
                    test("^Resolution recorded by fm-(captain|decision)-hold\\.$"))
                  then null
                  else cap(.body_lines[-1]; "^(?<v>local main)$")
                  end))
          | .body_excerpt = ((.body_lines | join(" "))[:240])
        else . end)
    | .records |= map(.compact_progress = compact_progress(.body_lines))
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
          | .hold_age_days = days_between((.hold_set // .since); $now)
          | .hold_bucket =
              (if .hold_kind != "captain" or .hold_reason == null or .state == "done" then null
               elif (.unresolved_blocker_ids | length) > 0 then "blocked"
               elif .hold_until != null and .hold_until > $today then "dated"
               elif .hold_until == null and .hold_age_days != null
                    and .hold_age_days >= $age_days then "aged"
               else "live" end)
          | .captain_actionable = (.hold_bucket == "live")
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
  local meta=$1 id=$2 current_file endpoint_file current_pid='' current_rc=0
  local status_log status_capture report_path report_capture
  local kind backend target endpoint_exists=null generation_current=1
  kind=$(meta_value "$meta" kind)
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

  if [ "$kind" = secondmate ]; then
    jq -n '{state:"unsupported",source:"metadata",detail:"historical persistent-home records are preserved but unsupported",raw:""}' \
      > "$current_file" || current_rc=1
  elif [ "$generation_current" = 1 ]; then
    crew_state_json "$id" "$meta" "$status_capture" > "$current_file" &
    current_pid=$!
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if [ -n "$target" ]; then
      if fm_backend_target_exists "$backend" "$target" "fm-$id" >/dev/null 2>&1; then
        endpoint_exists=true
      else
        endpoint_exists=false
      fi
    fi
  else
    jq -n '{state:"unknown",source:"none",detail:"task generation changed during snapshot",raw:""}' \
      > "$current_file" || current_rc=1
  fi

  [ -z "$current_pid" ] || wait "$current_pid" || current_rc=1
  # All mutable observations must belong to the metadata generation captured in
  # the manifest. If teardown/relaunch raced any read, discard the whole sample.
  if ! snapshot_task_generation_is_current "$meta" "$id"; then
    rm -f -- "$status_capture" "$report_capture"
    jq -n '{state:"unknown",source:"none",detail:"task generation changed during snapshot",raw:""}' \
      > "$current_file" || current_rc=1
    endpoint_exists=null
  fi
  printf 'endpoint_exists=%s\n' "$endpoint_exists" > "$endpoint_file" || current_rc=1
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
    [ -z "$TARGET_TASK_ID" ] || [ "$id" = "$TARGET_TASK_ID" ] || continue
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
  local cleanup_json
  local meta original_meta id kind executor provider task_type cloud_state remote_task_state harness mode yolo project worktree spawn_gen backend target status_log report_path
  local current_file endpoint_file observation_line index=0
  local pr pr_source event_json current_json endpoint_exists agent_alive meta_json status_json report_json worktree_json cloud_state_json remote_state_json
  local last_event_raw current_state current_source pending_decision blocked_event report_present=0 pr_from_status
  local open_decisions_tsv open_decisions_json

  while [ "$index" -lt "$SNAPSHOT_TASK_META_COUNT" ]; do
    meta=${SNAPSHOT_TASK_METAS[index]}
    index=$((index + 1))
    id=$(basename "$meta" .meta)
    original_meta="$STATE/$id.meta"
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    executor=$(meta_value "$meta" executor)
    [ -n "$executor" ] || executor=local-agent
    provider=$(meta_value "$meta" provider)
    task_type=$(meta_value "$meta" task_type)
    cloud_state=$(meta_value "$meta" cloud_state)
    remote_task_state=$(meta_value "$meta" remote_state)
    harness=$(meta_value "$meta" harness)
    mode=$(meta_value "$meta" mode)
    yolo=$(meta_value "$meta" yolo)
    project=$(meta_value "$meta" project)
    worktree=$(meta_value "$meta" worktree)
    spawn_gen=$(meta_value "$meta" spawn_gen)
    if [ "$executor" = cloud-worker ]; then
      backend=cloud
      target=
    elif [ "$executor" = remote-agent ]; then
      backend=remote
      target=
    elif [ "$kind" = secondmate ]; then
      backend=unsupported
      target=
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
    # reconciled against current executor state, which only clears a stale decision the
    # crew has provably moved past. Two execution signals clear it, neither of which
    # reads any report content:
    #   - a live activity read (run-step or busy pane) that is working/done, so a
    #     crew that resumed past a gate is not still reported as parked; and
    #   - a TERMINAL done/failed state on a single-owner task (scout or ship), whose
    #     deliverable is its report or PR, so a COMPLETED scout surfaces only as a
    #     report POINTER, never as a reopened pending decision.
    # A parked/blocked state, or a non-authoritative status-log/none read on a
    # still-live task, keeps the fold's open decision surfacing.
    open_decisions_tsv=$(status_open_decisions "$status_log")
    cleanup_json=null
    if [ -f "$STATE/$id.cleanup.json" ] && [ ! -L "$STATE/$id.cleanup.json" ]; then
      cleanup_json=$(jq -c . "$STATE/$id.cleanup.json" 2>/dev/null) || cleanup_json='{"state":"unknown","reason_code":"invalid-cleanup-receipt"}'
    fi
    if { [ "$current_source" = run-step ] || [ "$current_source" = pane ] \
         || [ "$current_source" = cloud-state ] || [ "$current_source" = cloud-readback ] \
         || [ "$current_source" = remote-state ] || [ "$current_source" = remote-readback ]; } \
       && [ "$current_state" != parked ] && [ "$current_state" != blocked ] \
       || { [ "$current_state" = "done" ] || [ "$current_state" = "failed" ]; }; then
      open_decisions_tsv=""
    fi
    open_decisions_json=$(printf '%s' "$open_decisions_tsv" | jq -R -s '
      [ splits("\n") | select(length > 0)
        | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
        | select(. != null) ]')
    pending_decision=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "needs-decision") then 1 else 0 end')
    blocked_event=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "blocked") then 1 else 0 end')

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
    if [ -n "$cloud_state" ]; then cloud_state_json=$(path_present_json "$cloud_state"); else cloud_state_json=$(jq -n '{path:null,present:false}'); fi
    if [ -n "$remote_task_state" ]; then remote_state_json=$(path_present_json "$remote_task_state"); else remote_state_json=$(jq -n '{path:null,present:false}'); fi
    jq -n \
      --arg id "$id" \
      --arg kind "$kind" \
      --arg executor "$executor" \
      --arg provider "$provider" \
      --arg task_type "$task_type" \
      --arg harness "$harness" \
      --arg mode "$mode" \
      --arg yolo "$yolo" \
      --arg project "$project" \
      --arg worktree "$worktree" \
      --arg spawn_gen "$spawn_gen" \
      --arg backend "$backend" \
      --arg target "$target" \
      --arg pr "$pr" \
      --arg pr_source "$pr_source" \
      --arg agent_alive "$agent_alive" \
      --arg observed_at "$SNAPSHOT_NOW" \
      --arg last_event_raw "$last_event_raw" \
      --argjson current_state "$current_json" \
      --argjson cleanup "$cleanup_json" \
      --argjson meta_path "$meta_json" \
      --argjson status_log "$status_json" \
      --argjson report "$report_json" \
      --argjson worktree_path "$worktree_json" \
      --argjson cloud_state_path "$cloud_state_json" \
      --argjson remote_state_path "$remote_state_json" \
      --argjson endpoint_exists "$endpoint_exists" \
      --argjson open_decisions "$open_decisions_json" \
      --argjson pending_decision "$(bool_json "$pending_decision")" \
      --argjson blocked_event "$(bool_json "$blocked_event")" \
      --argjson report_present "$(bool_json "$report_present")" \
      '{
        id:$id,
        kind:$kind,
        executor:$executor,
        provider:($provider | if . == "" then null else . end),
        task_type:($task_type | if . == "" then null else . end),
        harness:($harness // ""),
        mode:($mode // ""),
        yolo:($yolo // ""),
        project:($project // ""),
        spawn_gen:($spawn_gen | if . == "" then null else . end),
        backend:$backend,
        paths:{
          meta:$meta_path,
          status_log:$status_log,
          worktree:$worktree_path,
          cloud_state:$cloud_state_path,
          remote_state:$remote_state_path,
          report:$report
        },
        current_state:($current_state + {observed_at:$observed_at,freshness:"fresh"}),
        cleanup:$cleanup,
        endpoint:{target:($target | if . == "" then null else . end),exists:$endpoint_exists,agent_alive:$agent_alive,
          status:(if ($executor == "cloud-worker" or $executor == "remote-agent") then "not_applicable"
                  elif $endpoint_exists == false then "absent"
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
          if $executor == "cloud-worker" and $provider == "aime" then
            {watch:"bin/fm-task-state.sh \($id)",
             adopt:"bin/fm-cloud-research-aime.sh adopt \($id)",
             cancel:"bin/fm-cloud-research-aime.sh cancel \($id)",
             retire:"bin/fm-task-retire.sh \($id)",
             return_channel_note:"AIME results return through deterministic process-event readback and data/<id>/report.md."}
          elif $executor == "remote-agent" and $provider == "aime" then
            {watch:"bin/fm-task-state.sh \($id)",
             adopt:"bin/fm-cloud-research-aime.sh adopt \($id)",
             cancel:"bin/fm-cloud-research-aime.sh cancel \($id)",
             retire:"bin/fm-task-retire.sh \($id)",
             return_channel_note:"AIME results return through deterministic process-event readback and data/<id>/report.md."}
          elif $executor == "remote-agent" and $provider == "ida" then
            {watch:"bin/fm-task-state.sh \($id)",
             adopt:"bin/fm-remote-agent-ida.sh adopt \($id)",
             cancel:"bin/fm-remote-agent-ida.sh cancel \($id) --authorize-provider-cancel",
             retire:"bin/fm-task-retire.sh \($id)",
             return_channel_note:"iDA results return through normalized process-event readback and data/<id>/report.md."}
          elif $kind == "secondmate" then
            null
          else
            {watch:"bin/fm-peek.sh fm-\($id)",
             steer:"bin/fm-send.sh fm-\($id) \u0027<instruction>\u0027",
             return_channel_note:null}
          end)
      }'
  done | jq -s 'sort_by(.id)'
}

# Main-home current-inventory validity checks orphan / unstructured-current rows
# without inventing live task rows.
# Meta inventory remains the sole source of live workers; this object only
# discloses backlog↔task inconsistency for renderers (Bearings omitted/gates).
main_inventory_json() {  # <backlog-json-file> <tasks-json-file>
  jq -n \
    --slurpfile backlog "$1" \
    --slurpfile tasks "$2" '
    ($backlog[0]) as $backlog
    | ($tasks[0]) as $tasks
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

scout_reports_json() {
  if [ ! -d "$DATA" ]; then
    jq -n '[]'
    return 0
  fi
  # Feed every discovered path to one jq process. Large operational homes may
  # retain hundreds of reports, so starting one jq per report makes unrelated
  # task-overview reads scale with historical report count.
  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md -print \
    | LC_ALL=C sort \
    | jq -Rn '[inputs | {id:(split("/") | .[-2]),path:.}] | sort_by(.id)'
}

BACKLOG_JSON=$(backlog_json) || { echo "fm-fleet-snapshot: backlog read failed" >&2; exit 1; }
TASK_DISPOSITIONS=$(fm_task_disposition_snapshot "$DATA" 2>/dev/null || true)
prefetch_task_current_states || { echo "fm-fleet-snapshot: task observation failed" >&2; exit 1; }
TASKS_JSON=$(task_json_lines) || { echo "fm-fleet-snapshot: task snapshot failed" >&2; exit 1; }

JSON_TRANSPORT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-snapshot.XXXXXX") \
  || { echo "fm-fleet-snapshot: temporary transport directory creation failed" >&2; exit 1; }
BACKLOG_JSON_FILE="$JSON_TRANSPORT_DIR/backlog.json"
TASKS_JSON_FILE="$JSON_TRANSPORT_DIR/tasks.json"
MAIN_INVENTORY_JSON_FILE="$JSON_TRANSPORT_DIR/main-inventory.json"
SCOUT_REPORTS_JSON_FILE="$JSON_TRANSPORT_DIR/scout-reports.json"
printf '%s\n' "$BACKLOG_JSON" > "$BACKLOG_JSON_FILE" \
  || { echo "fm-fleet-snapshot: temporary backlog file write failed" >&2; exit 1; }
printf '%s\n' "$TASKS_JSON" > "$TASKS_JSON_FILE" \
  || { echo "fm-fleet-snapshot: temporary task file write failed" >&2; exit 1; }

scout_reports_json > "$SCOUT_REPORTS_JSON_FILE" \
  || { echo "fm-fleet-snapshot: scout report snapshot failed" >&2; exit 1; }
main_inventory_json "$BACKLOG_JSON_FILE" "$TASKS_JSON_FILE" > "$MAIN_INVENTORY_JSON_FILE" \
  || { echo "fm-fleet-snapshot: main inventory summary failed" >&2; exit 1; }
jq -n \
  --arg generated "$SNAPSHOT_NOW" \
  --arg fm_home "$FM_HOME" \
  --arg fm_root "$FM_ROOT" \
  --arg state "$STATE" \
  --arg data "$DATA" \
  --arg config "$CONFIG" \
  --arg projects "$PROJECTS" \
  --arg task_dispositions "$TASK_DISPOSITIONS" \
  --arg task_filter "$TARGET_TASK_ID" \
  --slurpfile backlog "$BACKLOG_JSON_FILE" \
  --slurpfile tasks "$TASKS_JSON_FILE" \
  --slurpfile main_inventory "$MAIN_INVENTORY_JSON_FILE" \
  --slurpfile scout_reports "$SCOUT_REPORTS_JSON_FILE" \
  '($backlog[0]) as $backlog
   | ($tasks[0]) as $tasks
   | ($main_inventory[0]) as $main_inventory
   | ($scout_reports[0]) as $scout_reports
   | (reduce ($task_dispositions | split("\n")[] | select(length > 0) | split("\t")) as $row
       ({}; if ($row | length) == 2 then .[$row[0]] = $row[1] else . end)) as $dispositions
   | def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
   def task_by_id($id): ($tasks[]? | select(.id == $id) | .) // null;
   def report_kind($id): (task_by_id($id).kind // backlog_by_id($id).kind // "scout");
   {
     schema:"fm-fleet-snapshot.v1",
     generated:$generated,
     fm_home:$fm_home,
     roots:{fm_root:$fm_root,state:$state,data:$data,config:$config,projects:$projects},
     backlog:($backlog | if $task_filter == "" then . else .records |= map(select(.id == $task_filter)) end),
     tasks:($tasks | map(.id as $id
       | . + {backlog:backlog_by_id($id)}
       | . + {record_disposition:($dispositions[$id] // "unknown")}
       | . + {retained_record:((.record_disposition == "done" or .record_disposition == "archive_done")
           and .current_state.state != "working")})),
     main_inventory:(if $task_filter == "" then $main_inventory
       else {valid:null,reason:"not evaluated in targeted task projection",orphan_in_flight:[],unstructured_current_count:0} end),
     scout_reports:($scout_reports | map(select($task_filter == "" or .id == $task_filter) | . + {kind:report_kind(.id)}))
   }'
