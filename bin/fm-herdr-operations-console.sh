#!/usr/bin/env bash
# fm-herdr-operations-console.sh - fixture-first, display-only Herdr operations view.
#
# Usage:
#   fm-herdr-operations-console.sh --fixture PATH [--format all|json|panel|activity|network]
#       [--now RFC3339] [--max-events N] [--width N] [--color|--no-color]
#       [--publish-metadata WORKSPACE_ID]
#
# The fixture envelope is an opt-in display adapter around one
# fm-fleet-snapshot.v1 object. The snapshot remains the only source for current
# task state; the envelope's task map supplies only display labels, explicit
# profile lanes, and read-only Obsidian navigation hints.
#
# This command never reads agent chat, pane text, process names, raw report
# content, or absolute paths. It never starts, stops, deletes, approves, or
# mutates a worker or a Firstmate task. Metadata publication is allowed only
# when HERDR_LAB_HELPER and a non-default HERDR_LAB_SESSION are explicitly set,
# and every Herdr call is routed through that helper.
#
# Input contract:
#   {
#     "schema":"fm-herdr-operations-console.fixture.v1",
#     "now":"2026-08-13T12:00:00Z",
#     "ttl_seconds":300,
#     "max_events":80,
#     "snapshot":{ "schema":"fm-fleet-snapshot.v1", "tasks":[] },
#     "tasks":{ "task-id":{ "phase":"QA", "profile_lane":"Personal Codex" } },
#     "events":[{ "id":"event-id", "at":"...", "source":"Firstmate",
#       "kind":"worker-state", "summary":"safe operational text" }],
#     "edges":[{ "from":"Firstmate", "to":"task-id", "relation":"observes" }]
#   }
#
# Exact fixture fields, limits, and output schemas are owned by this header and
# the executable's --help output; docs/herdr-backend.md owns operator context.
set -u

CONSOLE_SOURCE='firstmate-operations-console'
MAX_EVENTS_HARD_LIMIT=200

usage() {
  cat <<'EOF'
usage: bin/fm-herdr-operations-console.sh --fixture PATH [OPTIONS]

Render the fixture-only Herdr Firstmate operations console.

Options:
  --fixture PATH              Required JSON fixture path, or - for stdin.
  --format FORMAT             all (default), json, panel, activity, or network.
  --now RFC3339               Observation time override for deterministic tests.
  --max-events N              Activity retention bound; default is fixture value or 80, max 200.
  --width N                    Maximum rendered line width; default is 120.
  --color                      Emit ANSI status/lane colors.
  --no-color                   Disable ANSI colors.
  --publish-metadata WORKSPACE_ID
                              Publish display-only tokens to one lab workspace.

Metadata publication requires HERDR_LAB_HELPER and HERDR_LAB_SESSION. The
session must begin with fm-lab-, and the helper owns every Herdr call.
EOF
}

die() {
  echo "fm-herdr-operations-console: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die 'jq is required'

FIXTURE=''
FORMAT=all
NOW_ARG=''
MAX_EVENTS_ARG=''
WIDTH=120
COLOR=auto
PUBLISH_WORKSPACE=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fixture)
      [ "$#" -ge 2 ] || die '--fixture requires a path'
      FIXTURE=$2
      shift 2
      ;;
    --fixture=*) FIXTURE=${1#*=}; shift ;;
    --format)
      [ "$#" -ge 2 ] || die '--format requires a value'
      FORMAT=$2
      shift 2
      ;;
    --format=*) FORMAT=${1#*=}; shift ;;
    --now)
      [ "$#" -ge 2 ] || die '--now requires an RFC3339 value'
      NOW_ARG=$2
      shift 2
      ;;
    --now=*) NOW_ARG=${1#*=}; shift ;;
    --max-events)
      [ "$#" -ge 2 ] || die '--max-events requires a positive integer'
      MAX_EVENTS_ARG=$2
      shift 2
      ;;
    --max-events=*) MAX_EVENTS_ARG=${1#*=}; shift ;;
    --width)
      [ "$#" -ge 2 ] || die '--width requires a positive integer'
      WIDTH=$2
      shift 2
      ;;
    --width=*) WIDTH=${1#*=}; shift ;;
    --color) COLOR=on; shift ;;
    --no-color) COLOR=off; shift ;;
    --publish-metadata)
      [ "$#" -ge 2 ] || die '--publish-metadata requires a workspace id'
      PUBLISH_WORKSPACE=$2
      shift 2
      ;;
    --publish-metadata=*) PUBLISH_WORKSPACE=${1#*=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

[ -n "$FIXTURE" ] || { usage >&2; die '--fixture is required'; }
case "$FORMAT" in
  all|json|panel|activity|network) ;;
  *) die "unsupported format: $FORMAT" ;;
esac
case "$WIDTH" in
  ''|*[!0-9]*|0) die '--width must be a positive integer' ;;
esac
if [ -n "$MAX_EVENTS_ARG" ]; then
  case "$MAX_EVENTS_ARG" in
    ''|*[!0-9]*|0) die '--max-events must be a positive integer' ;;
  esac
fi

if [ "$FIXTURE" = '-' ]; then
  INPUT=$(cat) || die 'could not read fixture from stdin'
else
  [ -f "$FIXTURE" ] || die "fixture not found: $FIXTURE"
  INPUT=$(cat "$FIXTURE") || die "could not read fixture: $FIXTURE"
fi

if [ -n "$NOW_ARG" ]; then
  NOW=$NOW_ARG
else
  NOW=$(printf '%s' "$INPUT" | jq -r '.now // .snapshot.generated // empty' 2>/dev/null || true)
  [ -n "$NOW" ] || NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
fi
NOW_EPOCH=$(jq -nr --arg now "$NOW" 'try ($now | fromdateiso8601) catch empty' 2>/dev/null) || NOW_EPOCH=''
case "$NOW_EPOCH" in
  ''|*[!0-9]*) die '--now and fixture timestamps must be RFC3339 UTC values' ;;
esac

MAX_EVENTS_EFFECTIVE=$(
  if [ -n "$MAX_EVENTS_ARG" ]; then
    printf '%s' "$MAX_EVENTS_ARG"
  else
    printf '%s' "$INPUT" | jq -r '.max_events // 80' 2>/dev/null
  fi
)
case "$MAX_EVENTS_EFFECTIVE" in
  ''|*[!0-9]*|0) die 'max_events must be a positive integer' ;;
esac
[ "$MAX_EVENTS_EFFECTIVE" -le "$MAX_EVENTS_HARD_LIMIT" ] \
  || die "max_events exceeds the hard bound of $MAX_EVENTS_HARD_LIMIT"

NORMALIZED=$(
  printf '%s' "$INPUT" | jq -e -c \
    --arg now "$NOW" \
    --argjson now_epoch "$NOW_EPOCH" \
    --argjson max_events "$MAX_EVENTS_EFFECTIVE" \
    --argjson width "$WIDTH" \
    '
    def clean($value; $fallback; $limit):
      if ($value | type) != "string" then $fallback
      else ($value
        | gsub("[\u0000-\u001f\u007f]"; " ")
        | gsub("[[:space:]]+"; " ")
        | sub("^ +"; "")
        | sub(" +$"; "")
        | if length > $limit then .[:($limit - 3)] + "..." else . end)
      end;
    def private_text($value):
      ($value | type) == "string"
      and ($value | test("(^/|^~|/Users/|/private/|file://|BEGIN [A-Z ]+ KEY|password|secret|credential|api[_ -]?key|access[_ -]?token)"; "i"));
    def unsafe_id($value):
      ($value | type) != "string"
      or ($value | test("[\u0000-\u001f\u007f]"))
      or private_text($value);
    def unsafe_optional_id($value):
      ($value | type) == "string"
      and (($value | test("[\u0000-\u001f\u007f]")) or private_text($value));
    def safe($value; $fallback; $limit):
      if private_text($value) then $fallback else clean($value; $fallback; $limit) end;
    def ts_epoch($value):
      if ($value | type) == "string" then (try ($value | fromdateiso8601) catch null) else null end;
    def freshness($timestamp; $observed; $ttl):
      (ts_epoch($timestamp)) as $epoch
      | if $epoch == null then "unknown"
        elif $epoch > ($observed + 60) then "unknown"
        elif ($observed - $epoch) <= $ttl then "fresh"
        else "stale"
        end;
    def canonical_state($value):
      ($value | tostring | ascii_downcase) as $state
      | if $state == "parked" then "pending-review"
        elif ($state == "working" or $state == "qa" or $state == "waiting"
              or $state == "blocked" or $state == "paused" or $state == "done") then $state
        else "unknown"
        end;
    def state_label($state):
      if $state == "working" then "Working"
      elif $state == "qa" then "QA"
      elif $state == "pending-review" then "Pending review"
      elif $state == "waiting" then "Waiting"
      elif $state == "blocked" then "Blocked"
      elif $state == "paused" then "Paused"
      elif $state == "done" then "Done"
      elif $state == "stale" then "Stale"
      else "Unknown"
      end;
    def lane($value):
      if ($value | type) == "string"
         and (["Personal Codex", "Company Codex", "Personal Claude", "Company Claude"] | index($value)) != null
      then $value
      else "Unknown lane"
      end;
    def obsidian_link($link):
      if ($link | type) != "object" or ($link.supported // false) != true then
        {state:"unsupported", label:"Obsidian navigation unsupported", uri:null}
      else
        ($link.vault // "AI Project Manager") as $vault
        | ($link.file // "") as $file
        | if $vault == "AI Project Manager"
             and ($file | type) == "string"
             and ($file | test("^Items/[A-Za-z0-9][A-Za-z0-9 _./-]*\\.md$"))
             and (($file | contains("..")) | not)
             and (($file | contains("//")) | not)
          then {state:"supported", label:"Open Obsidian", uri:("obsidian://open?vault=" + ($vault | @uri) + "&file=" + ($file | @uri))}
          else {state:"unsupported", label:"Obsidian navigation unsupported", uri:null}
          end
      end;
    def allowed_source($value):
      ["Firstmate", "AI Project Manager", "Git/PR/QA", "Obsidian", "Herdr"] | index($value) != null;
    def allowed_kind($value):
      ["task-updated", "worker-state", "phase", "qa", "review", "decision", "blocker", "docs"] | index($value) != null;
    def fit($value; $limit):
      if ($value | length) <= $limit then $value
      elif $limit <= 3 then $value[:$limit]
      else $value[:($limit - 3)] + "..."
      end;
    def node_for($id; $tasks):
      if $id == "Captain" then {id:"Captain", label:"Captain", state:null}
      elif $id == "Firstmate" then {id:"Firstmate", label:"Firstmate", state:null}
      elif $id == "Review" then {id:"Review", label:"Review", state:null}
      elif $id == "Approval" then {id:"Approval", label:"Approval", state:null}
      else ([$tasks[] | select(.id == $id) | {id, label:.task, state}] | .[0] // null)
      end;

    if .schema != "fm-herdr-operations-console.fixture.v1" then error("fixture schema") else . end
    | (.snapshot // null) as $snapshot
    | if ($snapshot | type) != "object" or $snapshot.schema != "fm-fleet-snapshot.v1" then error("snapshot schema") else . end
    | if (($snapshot.tasks // null) | type) != "array" then error("snapshot tasks") else . end
    | if any($snapshot.tasks[]?; unsafe_id(.id) or .id == "") then error("task id") else . end
    | ((.ttl_seconds // 300) as $ttl
       | if ($ttl | type) != "number" or ($ttl < 1) or ($ttl > 86400) or (($ttl % 1) != 0) then error("ttl_seconds") else $ttl end) as $ttl_seconds
    | ((.tasks // {}) as $task_display
       | if ($task_display | type) != "object" then error("task display") else $task_display end) as $task_display
    | ($snapshot.tasks | map(
        . as $task
        | ($task_display[$task.id] // {}) as $display
        | ($task.current_state // {}) as $current
        | (canonical_state($current.state // "unknown")) as $reported_state
        | (freshness(($current.observed_at // $snapshot.generated); $now_epoch; $ttl_seconds)) as $task_freshness
        | (if $task_freshness == "stale" then "stale"
           elif $task_freshness == "unknown" or $reported_state == "unknown" then "unknown"
           else $reported_state end) as $effective_state
        | (((($display.needs_review // false) == true)
            or (($task.hints.pending_decision // false) == true)
            or (($task.hints.blocked_event // false) == true)
            or ($reported_state == "pending-review")
            or ($reported_state == "blocked"))) as $needs_review
        | (if ($display.review | type) == "string" and ($display.review | length) > 0 then $display.review
           elif $reported_state == "pending-review" then "Captain decision"
           elif $reported_state == "blocked" then "Blocked"
           else "None" end) as $review
        | {
            id:$task.id,
            project:safe(($display.project // $task.backlog.repo // $task.project); "Unknown project"; 80),
            task:safe(($display.task // $task.backlog.title // $task.id); "Unknown task"; 100),
            phase:safe(($display.phase // "Unknown phase"); "Unknown phase"; 64),
            state:$effective_state,
            state_label:(state_label($effective_state)),
            reported_state:$reported_state,
            reported_state_label:(state_label($reported_state)),
            freshness:$task_freshness,
            profile_lane:lane($display.profile_lane),
            model:safe(($display.model // $task.model); "Unknown"; 64),
            effort:safe(($display.effort // $task.effort); "Unknown"; 32),
            review:safe($review; "Unknown"; 80),
            needs_review:$needs_review,
            link:obsidian_link($display.link),
            source:{state:safe($current.source; "unknown"; 24)}
          }
      ) | sort_by(.id)) as $tasks
    | ((.events // []) as $raw_events
       | if ($raw_events | type) != "array" then error("events") else $raw_events end
       | reduce .[] as $event
           ({valid:[], malformed:0, redacted:0};
            if ($event | type) != "object"
               or ($event.id | type) != "string" or ($event.id | length) == 0
               or ($event.at // $event.timestamp | type) != "string"
               or (ts_epoch($event.at // $event.timestamp)) == null
               or unsafe_optional_id($event.id)
               or unsafe_optional_id($event.dedupe_key)
               or ($event.source | type) != "string" or (allowed_source($event.source) | not)
               or ($event.kind | type) != "string" or (allowed_kind($event.kind) | not)
               or ($event.summary | type) != "string" or ($event.summary | length) == 0 then
              .malformed += 1
            elif private_text($event.summary) then
              .redacted += 1
            else
              (ts_epoch($event.at // $event.timestamp)) as $event_epoch
              | (safe($event.summary; ""; 240)) as $summary
              | if $summary == "" then .redacted += 1
                else .valid += [{
                  id:$event.id,
                  dedupe_key:(safe(($event.dedupe_key // $event.id); $event.id; 120)),
                  at:($event.at // $event.timestamp),
                  epoch:$event_epoch,
                  source:$event.source,
                  kind:$event.kind,
                  task_id:(if ($event.task_id | type) == "string"
                             and ($event.task_id | test("[\u0000-\u001f\u007f]") | not)
                             and (private_text($event.task_id) | not)
                           then $event.task_id else null end),
                  summary:$summary,
                  freshness:(freshness(($event.at // $event.timestamp); $now_epoch; $ttl_seconds))
                }]
                end
            end)) as $activity_acc
    | ($activity_acc.valid
       | group_by(.dedupe_key)
       | map(max_by([.epoch, .id]))
       | sort_by([.epoch, .id])) as $deduped_events
    | ($deduped_events | if length > $max_events then .[-$max_events:] else . end) as $retained_events
    | ((.edges // []) as $raw_edges
       | if ($raw_edges | type) != "array" then error("edges") else $raw_edges end
       | reduce .[] as $edge
           ({valid:[], malformed:0};
            if ($edge | type) != "object"
               or ($edge.from | type) != "string" or ($edge.to | type) != "string"
               or ($edge.relation | type) != "string" then .malformed += 1
            else
              (node_for($edge.from; $tasks)) as $from_node
              | (node_for($edge.to; $tasks)) as $to_node
              | if $from_node == null or $to_node == null then .malformed += 1
                else .valid += [{
                  from:$from_node.id,
                  from_label:$from_node.label,
                  to:$to_node.id,
                  to_label:$to_node.label,
                  relation:(safe($edge.relation; "observes"; 48))
                }]
                end
            end)) as $edge_acc
    | ($edge_acc.valid | unique_by([.from, .to, .relation])) as $edges
    | (freshness($snapshot.generated; $now_epoch; $ttl_seconds)) as $source_freshness
    | {
        schema:"fm-herdr-operations-console.v1",
        mode:"fixture",
        theme:"tokyo-night",
        observed_at:$now,
        source:{
          schema:"fm-fleet-snapshot.v1",
          generated_at:(if ($snapshot.generated | type) == "string" and (ts_epoch($snapshot.generated) != null) then $snapshot.generated else null end),
          freshness:$source_freshness,
          inventory:(if $snapshot.main_inventory.valid == false then "invalid" else "valid-or-unknown" end)
        },
        tasks:$tasks,
        activity:{
          events:($retained_events | map(del(.epoch, .dedupe_key))),
          max_events:$max_events,
          available:(($activity_acc.valid | length) > 0),
          scrollable:true,
          deduplicated:(($activity_acc.valid | length) - ($deduped_events | length)),
          malformed:($activity_acc.malformed),
          redacted:($activity_acc.redacted),
          truncated:(($deduped_events | length) > $max_events)
        },
        network:{
          task_ids:($tasks | map(.id)),
          nodes:((
            [{id:"Captain",label:"Captain",state:null}, {id:"Firstmate",label:"Firstmate",state:null}]
            + ($tasks | map({id,label:.task,state:.state}))
            + ($edges | map({id:.from,label:.from_label,state:null}) + map({id:.to,label:.to_label,state:null}))
          ) | unique_by(.id)),
          edges:$edges,
          malformed:($edge_acc.malformed),
          ascii:(
            (["Captain -> Firstmate"]
             + (if ($tasks | length) == 0 then ["Tasks -> Unknown (no task records)"]
                else ($tasks | map(("Task: " + .task + " [" + .state_label + "]"))) end)
             + ["Dependencies:"]
             + (if ($edges | length) == 0 then ["  (none recorded; no dependency inferred)"]
                else ($edges | map(("  " + .from_label + " -> " + .to_label + " [" + .relation + "]"))) end)
            ) | map(fit(.; $width)) | join("\n")
          )
        },
        herdr:{
          mode:"fixture",
          source:"display-only metadata",
          focus_policy:"no-focus",
          lifecycle:"helper-only",
          ttl_seconds:$ttl_seconds,
          tokens:{
            surface:"fixture",
            theme:"tokyo-night",
            freshness:$source_freshness,
            tasks:(($tasks | length) | tostring),
            activity:(($retained_events | length) | tostring),
            review:(if any($tasks[]?; .needs_review) then "needed" else "clear" end),
            network:(if ($edges | length) > 0 then "ready" else "empty" end)
          },
          publish:null
        },
        safety:{
          display_only:true,
          control_actions:false,
          chat_read:false,
          private_paths_redacted:true,
          default_session_untouched:true,
          focus_preserved:null
        }
      }
    '
) || die 'malformed fixture input or unsupported fixture contract'

focus_signature() {
  printf '%s' "$1" | jq -ce '
    .result.snapshot
    | {
        workspaces:[.workspaces[]? | {id:(.workspace_id // .id),focused:(.focused // false)}],
        tabs:[.tabs[]? | {id:(.tab_id // .id),workspace_id,focused:(.focused // false)}],
        panes:[.panes[]? | {id:(.pane_id // .id),workspace_id,tab_id,focused:(.focused // false)}]
      }
  ' 2>/dev/null
}

herdr_call() {
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

publish_metadata() {
  local workspace=$1 before after before_focus after_focus metadata_json ttl_ms
  local -a command_args
  [ -n "${HERDR_LAB_HELPER:-}" ] || die '--publish-metadata requires HERDR_LAB_HELPER'
  [ -x "$HERDR_LAB_HELPER" ] || die 'HERDR_LAB_HELPER is not executable'
  [ -n "${HERDR_LAB_SESSION:-}" ] || die '--publish-metadata requires HERDR_LAB_SESSION'
  case "$HERDR_LAB_SESSION" in
    fm-lab-*) ;;
    *) die '--publish-metadata refuses a non-lab Herdr session' ;;
  esac
  case "$workspace" in
    ''|*[!A-Za-z0-9:_-]*) die 'workspace id is malformed' ;;
  esac
  before=$(herdr_call api snapshot 2>/dev/null) || die 'could not read the lab focus snapshot'
  before_focus=$(focus_signature "$before") || die 'lab focus snapshot was malformed'
  printf '%s' "$before" | jq -e --arg workspace "$workspace" \
    'any(.result.snapshot.workspaces[]?; (.workspace_id // .id) == $workspace)' >/dev/null 2>&1 \
    || die "workspace is not present in the named lab session: $workspace"
  ttl_ms=$(printf '%s' "$NORMALIZED" | jq -r '.herdr.ttl_seconds * 1000')
  if [ "$ttl_ms" -lt 1 ] || [ "$ttl_ms" -gt 86400000 ]; then
    ttl_ms=300000
  fi
  command_args=(workspace report-metadata "$workspace" --source "$CONSOLE_SOURCE" --ttl-ms "$ttl_ms")
  while IFS=$'\t' read -r name value; do
    [ -n "$name" ] || continue
    command_args+=(--token "$name=$value")
  done < <(printf '%s' "$NORMALIZED" | jq -r '.herdr.tokens | to_entries[] | [.key, (.value | tostring)] | @tsv')
  herdr_call "${command_args[@]}" >/dev/null 2>&1 || die 'lab metadata publication failed'
  metadata_json=$(herdr_call workspace get "$workspace" 2>/dev/null) || die 'could not verify lab metadata publication'
  printf '%s' "$metadata_json" | jq -e '.result.workspace.tokens.surface == "fixture"' >/dev/null 2>&1 \
    || die 'lab metadata publication did not return the fixture marker'
  after=$(herdr_call api snapshot 2>/dev/null) || die 'could not read the post-publication lab focus snapshot'
  after_focus=$(focus_signature "$after") || die 'post-publication lab focus snapshot was malformed'
  [ "$before_focus" = "$after_focus" ] || die 'metadata publication changed Herdr focus'
  jq -n --arg session "$HERDR_LAB_SESSION" --arg workspace "$workspace" \
    '{attempted:true,session:$session,workspace_id:$workspace,focus_preserved:true,control_actions:false}'
}

if [ -n "$PUBLISH_WORKSPACE" ]; then
  PUBLISH_RESULT=$(publish_metadata "$PUBLISH_WORKSPACE")
  NORMALIZED=$(printf '%s' "$NORMALIZED" | jq -c --argjson result "$PUBLISH_RESULT" \
    '.herdr.mode = "fixture-lab" | .herdr.publish = $result | .safety.focus_preserved = $result.focus_preserved') \
    || die 'could not attach lab publication result'
fi

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$NORMALIZED"
  exit 0
fi

if [ "$FORMAT" = panel ] || [ "$FORMAT" = all ]; then
  printf '%s\n' "$NORMALIZED" | jq -r --argjson width "$WIDTH" --arg color "$COLOR" '
    def fit($value):
      if ($value | length) <= $width then $value
      elif $width <= 3 then $value[:$width]
      else $value[:($width - 3)] + "..."
      end;
    def icon($state):
      if $state == "working" then "[W]"
      elif $state == "qa" then "[Q]"
      elif $state == "pending-review" then "[R]"
      elif $state == "blocked" then "[B]"
      elif $state == "paused" then "[P]"
      elif $state == "done" then "[D]"
      elif $state == "stale" then "[S]"
      else "[?]"
      end;
    def ansi($code; $value):
      if $color == "on" then ("\u001b[" + $code + "m" + $value + "\u001b[0m") else $value end;
    (("╔ FIRSTMATE // HERDR OPS // TOKYO NIGHT // " + (.mode | ascii_upcase) + " ╗") | fit(.)),
    (("Source: " + .source.schema + " | snapshot: " + .source.freshness + " | display-only: yes") | fit(.)),
    "",
    ("PROJECT / TASK | PHASE | STATUS | PROFILE | MODEL / EFFORT | FRESHNESS | REVIEW | OBSIDIAN" | fit(.)),
    ("----------------------------------------------------------------------------------------" | fit(.)),
    ((if (.tasks | length) == 0 then "[?] No task records - Unknown (no source)"
     else (.tasks[] |
       . as $task
       | (icon($task.state) + " " + $task.project + " / " + $task.task + " | " + $task.phase + " | " + $task.state_label + " | " + $task.profile_lane + " | " + $task.model + " · " + $task.effort + " | " + $task.freshness + " | " + $task.review + " | " + $task.link.label)
       | (if $task.state == "blocked" then "31" elif $task.state == "stale" or $task.state == "unknown" then "90" elif $task.state == "done" then "32" else "36" end) as $code
       | fit(.)
       | ansi($code; .))
     end)),
    "",
    (("Activity: " + ((.activity.events | length) | tostring) + "/" + (.activity.max_events | tostring) + " retained | scrollable: " + (.activity.scrollable | tostring) + " | deduped: " + (.activity.deduplicated | tostring)) | fit(.))
  ' || die 'panel rendering failed'
fi

if [ "$FORMAT" = activity ] || [ "$FORMAT" = all ]; then
  printf '%s\n' "$NORMALIZED" | jq -r --argjson width "$WIDTH" '
    def fit($value):
      if ($value | length) <= $width then $value
      elif $width <= 3 then $value[:$width]
      else $value[:($width - 3)] + "..."
      end;
    "ACTIVITY // BOUNDED OPERATIONAL HISTORY",
    (if (.activity.events | length) == 0 then "(none recorded)"
     else (.activity.events[] | fit((.at + " | " + .source + " | " + .kind + " | " + (.freshness | ascii_upcase) + " | " + .summary)))
     end),
    (("retained=" + ((.activity.events | length) | tostring) + " max=" + (.activity.max_events | tostring) + " deduplicated=" + (.activity.deduplicated | tostring) + " redacted=" + (.activity.redacted | tostring) + " malformed=" + (.activity.malformed | tostring)) | fit(.))
  ' || die 'activity rendering failed'
fi

if [ "$FORMAT" = network ] || [ "$FORMAT" = all ]; then
  printf '%s\n' "$NORMALIZED" | jq -r '.network.ascii' || die 'network rendering failed'
fi
