#!/usr/bin/env bash
# fm-bearings-snapshot.sh - compact, bounded bearings projection.
#
# This read-only wrapper projects bin/fm-fleet-snapshot.sh into the small set
# of fields needed to resume main-home work. It can optionally enrich recorded
# repositories with live GitHub PR state; the canonical fleet snapshot itself
# never performs network discovery.
#
# Output contract: fm-bearings.v1. JSON is available with --json; TOON is the
# default agent-facing representation of the same model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/fm-fleet-snapshot.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-landed-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-landed-lib.sh"  # FM_LANDED_JQ_DEFS: the shared landed selector

# Bounds (overridable for tests / large fleets).
FM_BEARINGS_LANDED=${FM_BEARINGS_LANDED:-6}
FM_BEARINGS_IN_FLIGHT=${FM_BEARINGS_IN_FLIGHT:-20}
FM_BEARINGS_DECISIONS=${FM_BEARINGS_DECISIONS:-20}
FM_BEARINGS_GATES=${FM_BEARINGS_GATES:-20}
FM_BEARINGS_REPORTS=${FM_BEARINGS_REPORTS:-20}
FM_BEARINGS_RECORDED_PRS=${FM_BEARINGS_RECORDED_PRS:-20}
FM_BEARINGS_UNHEALTHY=${FM_BEARINGS_UNHEALTHY:-20}
FM_BEARINGS_PR_REPOS=${FM_BEARINGS_PR_REPOS:-10}
FM_BEARINGS_PR_LIMIT=${FM_BEARINGS_PR_LIMIT:-20}
FM_BEARINGS_PR_TIMEOUT=${FM_BEARINGS_PR_TIMEOUT:-20}
case "$FM_BEARINGS_PR_TIMEOUT" in ''|*[!0-9]*|0) FM_BEARINGS_PR_TIMEOUT=20 ;; esac
validate_bound() {  # <name> <value>
  case "$2" in ''|*[!0-9]*|0) echo "fm-bearings-snapshot: $1 must be a positive integer" >&2; exit 2 ;; esac
}
validate_bound FM_BEARINGS_LANDED "$FM_BEARINGS_LANDED"
validate_bound FM_BEARINGS_IN_FLIGHT "$FM_BEARINGS_IN_FLIGHT"
validate_bound FM_BEARINGS_DECISIONS "$FM_BEARINGS_DECISIONS"
validate_bound FM_BEARINGS_GATES "$FM_BEARINGS_GATES"
validate_bound FM_BEARINGS_REPORTS "$FM_BEARINGS_REPORTS"
validate_bound FM_BEARINGS_RECORDED_PRS "$FM_BEARINGS_RECORDED_PRS"
validate_bound FM_BEARINGS_UNHEALTHY "$FM_BEARINGS_UNHEALTHY"
validate_bound FM_BEARINGS_PR_REPOS "$FM_BEARINGS_PR_REPOS"
validate_bound FM_BEARINGS_PR_LIMIT "$FM_BEARINGS_PR_LIMIT"

usage() {
  cat <<'EOF'
usage: fm-bearings-snapshot.sh [--json] [--include-prs] [--fields <list>]
                               [--task <task-id>]
                               [--all-in-flight] [--all-decisions]
                               [--all-retained]
                               [--all-landed]
                               [--all-reports] [--all-queued]
                               [--all-recorded-prs] [--all-unhealthy]
                               [--all-pr-repos]

Compact bearings projection over fm-fleet-snapshot.sh. TOON by default.
Closed non-working records are counted by default; rows with folded open decisions remain visible.
--all-retained reveals bounded purely historical detail.
--include-prs additionally performs live GitHub discovery and checks.

Default fields: schema, home, generated, prs, in_flight{id,kind,state,repo,name,doing},
  retained_record_count, retained_records{id,state,open_decisions,reason},
  decisions_open{id,key,verb,summary,owner}, landed{id,what,artifact,owner},
  gates{id,title,blocked_by,reason,owner,filed}, reports{id,path}, recorded_prs{id,url},
  unhealthy_endpoints{...} (only when non-empty), omitted{surface,reveal}.
Default gates are selected newest filed first before their bound; undated gates
  retain input order after dated gates.
landed shows this home's Done rows, bounded by FM_BEARINGS_LANDED.
  --all-landed reveals the complete newest-first set.
Targeted task read: --task <task-id> returns only that task's current target,
  effective delivery authority, remaining issue, exact backlog detail, and evidence paths.
Opt-in surfaces: --fields bodies|paths|actions|endpoints, --all-in-flight,
  --all-retained,
  --all-decisions (all open decisions and captain holds in the bounded snapshot),
  --all-landed, --all-reports, --all-queued, --all-recorded-prs,
  --all-unhealthy, --all-pr-repos, --include-prs (adds candidate_prs).
Raise FM_BEARINGS_PR_LIMIT to expand per-repository open-PR results.
EOF
}

FORMAT=toon
INCLUDE_PRS=0
ALL_REPORTS=0
ALL_QUEUED=0
ALL_IN_FLIGHT=0
ALL_RETAINED=0
ALL_DECISIONS=0
ALL_LANDED=0
ALL_RECORDED_PRS=0
ALL_UNHEALTHY=0
ALL_PR_REPOS=0
FIELDS=""
TASK_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --include-prs) INCLUDE_PRS=1 ;;
    --all-reports) ALL_REPORTS=1 ;;
    --all-queued) ALL_QUEUED=1 ;;
    --all-in-flight) ALL_IN_FLIGHT=1 ;;
    --all-retained) ALL_RETAINED=1 ;;
    --all-decisions) ALL_DECISIONS=1 ;;
    --all-landed) ALL_LANDED=1 ;;
    --all-recorded-prs) ALL_RECORDED_PRS=1 ;;
    --all-unhealthy) ALL_UNHEALTHY=1 ;;
    --all-pr-repos) ALL_PR_REPOS=1 ;;
    --fields) shift; FIELDS=${1:-} ;;
    --fields=*) FIELDS=${1#--fields=} ;;
    --task)
      [ $# -gt 1 ] || { echo "fm-bearings-snapshot: --task requires a task id" >&2; usage >&2; exit 2; }
      case "$2" in ''|-*) echo "fm-bearings-snapshot: --task requires a non-option task id" >&2; usage >&2; exit 2 ;; esac
      shift
      TASK_ID=$1
      ;;
    --task=*)
      TASK_ID=${1#--task=}
      case "$TASK_ID" in
        '') echo "fm-bearings-snapshot: --task requires a task id" >&2; usage >&2; exit 2 ;;
        -*) echo "fm-bearings-snapshot: --task requires a non-option task id" >&2; usage >&2; exit 2 ;;
      esac
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "$TASK_ID" in
  ''|*[!A-Za-z0-9._-]*)
    [ -z "$TASK_ID" ] || { echo "fm-bearings-snapshot: invalid task id" >&2; exit 2; }
    ;;
esac
if [ -n "$TASK_ID" ] && { [ "$INCLUDE_PRS" = 1 ] || [ -n "$FIELDS" ] || [ "$ALL_REPORTS" = 1 ] \
  || [ "$ALL_QUEUED" = 1 ] || [ "$ALL_IN_FLIGHT" = 1 ] || [ "$ALL_RETAINED" = 1 ] \
  || [ "$ALL_DECISIONS" = 1 ] || [ "$ALL_LANDED" = 1 ] || [ "$ALL_RECORDED_PRS" = 1 ] \
  || [ "$ALL_UNHEALTHY" = 1 ] || [ "$ALL_PR_REPOS" = 1 ]; }; then
  echo "fm-bearings-snapshot: --task cannot be combined with fleet expansion options" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "fm-bearings-snapshot: jq not found" >&2; exit 1; }

print_model() {  # <json-model>
  local model=$1 toon
  if [ "$FORMAT" = json ]; then
    printf '%s\n' "$model"
    return
  fi
  toon=$(printf '%s\n' "$model" | jq -r '
    def q:
      tostring
      | if (. == "")
          or test("^\\s|\\s$")
          or (. == "true" or . == "false" or . == "null")
          or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
          or test("[:\"\\\\\\[\\]{},]")
          or test("[[:cntrl:]]")
          or test("^-")
        then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
        else . end;
    def scal:
      if . == null then "null"
      elif type == "boolean" then (if . then "true" else "false" end)
      elif type == "number" then tostring
      else q end;
    def emit($k; $v):
      if ($v | type) == "array" then
        if ($v | length) == 0 then "\($k): []"
        else
          ($v[0] | keys_unsorted) as $ks
          | ( "\($k)[\($v | length)]{\($ks | map(q) | join(","))}:",
              ($v[] as $row | "  " + ([ $ks[] as $kk | ($row[$kk] | scal) ] | join(","))) )
        end
      else "\($k): " + ($v | scal)
      end;
    [ to_entries[] | emit(.key; .value) ] | join("\n")
  ') || { echo "fm-bearings-snapshot: TOON rendering failed" >&2; return 1; }
  printf '%s\n' "$toon"
}

# The shared read-only away-return owner is consulted, not obeyed. An active
# away window still refuses here: the correct answer to a bearings request then
# is to run the return first. Return CATCH-UP is different - the captain is
# back and asking for the picture, so the catch-up posture is reported as
# content (a Charted Next gate row) and collection continues. bin/fm-afk-return.sh
# owns both the gate format and the branch distinction; bearings reproduces
# neither. Acting on the fleet still waits for its `check`.
RETURN_CATCHUP=null
GUARD_RC=0
GUARD_ERR=$("$SCRIPT_DIR/fm-afk-return.sh" guard 2>&1 >/dev/null) || GUARD_RC=$?
if [ "$GUARD_RC" -ne 0 ] && [ "$GUARD_RC" -ne 4 ]; then
  [ -z "$GUARD_ERR" ] || printf '%s\n' "$GUARD_ERR" >&2
  exit "$GUARD_RC"
fi
if [ "$GUARD_RC" -eq 4 ]; then
  CATCHUP_LINE=$("$SCRIPT_DIR/fm-afk-return.sh" catchup-summary) || CATCHUP_LINE=""
  CATCHUP_BLOCKERS=${CATCHUP_LINE%%$'\t'*}
  case "$CATCHUP_BLOCKERS" in ''|*[!0-9]*) CATCHUP_BLOCKERS=0 ;; esac
  CATCHUP_REASON=""
  case "$CATCHUP_LINE" in *"$(printf '\t')"*) CATCHUP_REASON=${CATCHUP_LINE#*$'\t'} ;; esac
  RETURN_CATCHUP=$(jq -n --argjson blockers "$CATCHUP_BLOCKERS" --arg reason "$CATCHUP_REASON" \
    '{pending:true,blockers:$blockers,reason:$reason}')
fi

NOW=${FM_BEARINGS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
if [ -n "$TASK_ID" ]; then
  SNAP=$(FM_SNAPSHOT_NOW="$NOW" "$FLEET" --json --task "$TASK_ID") || exit $?
else
  SNAP=$(FM_SNAPSHOT_NOW="$NOW" "$FLEET" --json) || exit $?
fi
HOME_LABEL=$(printf '%s' "$SNAP" | jq -er '.fm_home | strings | split("/") | (.[-2:] | join("/"))') \
  || { echo "fm-bearings-snapshot: invalid canonical snapshot" >&2; exit 1; }

if [ -n "$TASK_ID" ]; then
  MODEL=$(printf '%s' "$SNAP" | jq -e --arg id "$TASK_ID" --arg home "$HOME_LABEL" --arg now "$NOW" '
    ([.backlog.records[] | select(.structured and .id == $id)] | if length == 1 then .[0] else null end) as $record
    | ([.tasks[] | select(.id == $id)] | if length == 1 then .[0] else null end) as $task
    | if $record == null and $task == null then error("task not found: " + $id) else
      {
        schema:"fm-task-context.v1", home:$home, generated:$now, id:$id,
        title:($record.title // $id), repo:($record.repo // $task.project // null),
        kind:($record.kind // $task.kind // null), backlog_state:($record.state // null),
        current_state:($task.current_state.state // null),
        authority_brief:(.roots.data + "/" + $id + "/brief.md"),
        delivery_mode:($task.mode // null), merge_posture:($task.yolo // null),
        remaining_request:($record.hold_reason // null),
        blocked_by:(($record.unresolved_blocker_ids // []) | join(",")),
        hold_kind:($record.hold_kind // null), hold_until:($record.hold_until // null),
        open_decisions:($task.hints.open_decisions // []),
        current_detail:($task.current_state.detail // null),
        backlog_path:.backlog.path, backlog_row:($record.raw // null),
        backlog_body:(($record.body_lines // []) | map({line:.})),
        status_path:($task.paths.status_log.path // null), report_path:($task.paths.report.path // null),
        progress_source:.backlog.path,
        omitted:[{surface:"other fleet tasks and history",reveal:"run the default snapshot"}]
      }
    end
  ') || { echo "fm-bearings-snapshot: targeted task read failed" >&2; exit 1; }
  print_model "$MODEL"
  exit $?
fi

# --- optional live GitHub PR enrichment -------------------------------------
PR_STATUS='not_requested (run: /bearings include PRs)'
CANDIDATE_PRS='[]'
PR_REPOS_TOTAL=0
PR_REPOS_SHOWN=0
PR_ROWS_CAPPED=0
PR_ROWS_MIN_TOTAL=0

# Parse owner/repo from an https or ssh GitHub remote/PR URL; empty if not GitHub.
repo_slug() {  # <url>
  printf '%s' "$1" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p' | sed 's#\.git$##; s#/pull/.*$##; s#/$##'
}

# Bounded gh call; prints stdout, non-zero on timeout/failure. gh only.
# bin/fm-timeout-lib.sh owns the bound itself.
gh_bounded() {  # <args...>
  fm_run_timed "$FM_BEARINGS_PR_TIMEOUT" \
    env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"
}

if [ "$INCLUDE_PRS" = 1 ]; then
  if ! command -v gh >/dev/null 2>&1; then
    PR_STATUS='unavailable (gh not found)'
  else
    # Candidate repos: recorded pr= URLs plus live worktree origins. Deduped.
    repos=""
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      s=$(repo_slug "$u"); [ -n "$s" ] || continue
      case " $repos " in *" $s "*) : ;; *) repos="$repos $s" ;; esac
    done <<EOF
$(printf '%s' "$SNAP" | jq -r '.tasks[].pr.url // empty')
EOF
    while IFS= read -r wt; do
      [ -n "$wt" ] || continue
      [ -d "$wt" ] || continue
      u=$(git -C "$wt" remote get-url origin 2>/dev/null) || continue
      s=$(repo_slug "$u"); [ -n "$s" ] || continue
      case " $repos " in *" $s "*) : ;; *) repos="$repos $s" ;; esac
    done <<EOF
$(printf '%s' "$SNAP" | jq -r '.tasks[] | .paths.worktree.path // empty')
EOF

    for repo in $repos; do PR_REPOS_TOTAL=$((PR_REPOS_TOTAL + 1)); done
    nrepos=0; npr=0; nwarn=0; ncapped=0; rows='[]'
    pr_fetch_limit=$((FM_BEARINGS_PR_LIMIT + 1))
    for repo in $repos; do
      if [ "$ALL_PR_REPOS" != 1 ] && [ "$nrepos" -ge "$FM_BEARINGS_PR_REPOS" ]; then break; fi
      nrepos=$((nrepos + 1))
      out=$(gh_bounded pr list --repo "$repo" --state open --limit "$pr_fetch_limit" \
        --json number,title,url,headRefName,reviewDecision,mergeable,statusCheckRollup 2>/dev/null) \
        || { nwarn=$((nwarn + 1)); continue; }
      [ -n "$out" ] || out='[]'
      repo_result=$(printf '%s' "$out" | jq --arg repo "$repo" --argjson limit "$FM_BEARINGS_PR_LIMIT" '
        [ .[] | {
          num:(.number|tostring),
          repo:$repo,
          task:(if (.headRefName // "" | startswith("fm/")) then (.headRefName | ltrimstr("fm/")) else "-" end),
          url:(.url // "-"),
          review:(.reviewDecision // "none"),
          mergeable:(.mergeable // "UNKNOWN"),
          checks:(
            (.statusCheckRollup // []) as $c
            | if ($c|length) == 0 then "none"
              elif any($c[]; (.conclusion // .state // "") as $s | ($s=="FAILURE" or $s=="ERROR" or $s=="TIMED_OUT" or $s=="CANCELLED" or $s=="ACTION_REQUIRED")) then "failing"
              elif any($c[]; ((.status // "") != "COMPLETED") and ((.state // "") != "SUCCESS")) then "pending"
              else "passing" end)
        } ] as $rows | {returned:($rows | length), rows:$rows[:$limit]}') || { nwarn=$((nwarn + 1)); continue; }
      returned=$(printf '%s' "$repo_result" | jq '.returned')
      repo_rows=$(printf '%s' "$repo_result" | jq '.rows')
      cnt=$(printf '%s' "$repo_rows" | jq 'length')
      [ "$returned" -gt "$FM_BEARINGS_PR_LIMIT" ] && ncapped=$((ncapped + 1))
      npr=$((npr + cnt))
      rows=$(jq -n --argjson a "$rows" --argjson b "$repo_rows" '$a + $b')
    done
    PR_REPOS_SHOWN=$nrepos
    PR_ROWS_CAPPED=$ncapped
    PR_ROWS_MIN_TOTAL=$((npr + ncapped))
    CANDIDATE_PRS=$rows
    warnnote=""
    [ "$nwarn" -gt 0 ] && warnnote="; ${nwarn} repo(s) unavailable"
    cappednote=""
    [ "$ncapped" -gt 0 ] && cappednote="; ${npr} shown, at least ${PR_ROWS_MIN_TOTAL} open; capped in ${ncapped} repo(s)"
    if [ "$ncapped" -gt 0 ]; then
      PR_STATUS="checked (${nrepos} repos${cappednote}${warnnote})"
    else
      PR_STATUS="checked (${nrepos} repos, ${npr} open${warnnote})"
    fi
  fi
fi

# --- projection: canonical snapshot -> fm-bearings.v1 model (JSON) ----------
BEARINGS_TODAY=${NOW%%T*}
case "$BEARINGS_TODAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) BEARINGS_TODAY=$(date -u +%Y-%m-%d) ;;
esac
MODEL=$(printf '%s' "$SNAP" | jq \
  --arg home "$HOME_LABEL" \
  --arg now "$NOW" \
  --arg today "$BEARINGS_TODAY" \
  --arg prs "$PR_STATUS" \
  --arg fields "$FIELDS" \
  --argjson landed_n "$FM_BEARINGS_LANDED" \
  --argjson in_flight_n "$FM_BEARINGS_IN_FLIGHT" \
  --argjson decisions_n "$FM_BEARINGS_DECISIONS" \
  --argjson gates_n "$FM_BEARINGS_GATES" \
  --argjson reports_n "$FM_BEARINGS_REPORTS" \
  --argjson recorded_prs_n "$FM_BEARINGS_RECORDED_PRS" \
  --argjson unhealthy_n "$FM_BEARINGS_UNHEALTHY" \
  --argjson include_prs "$INCLUDE_PRS" \
  --argjson all_in_flight "$ALL_IN_FLIGHT" \
  --argjson all_retained "$ALL_RETAINED" \
  --argjson all_decisions "$ALL_DECISIONS" \
  --argjson all_landed "$ALL_LANDED" \
  --argjson all_reports "$ALL_REPORTS" \
  --argjson all_queued "$ALL_QUEUED" \
  --argjson all_recorded_prs "$ALL_RECORDED_PRS" \
  --argjson all_unhealthy "$ALL_UNHEALTHY" \
  --argjson pr_repos_total "$PR_REPOS_TOTAL" \
  --argjson pr_repos_shown "$PR_REPOS_SHOWN" \
  --argjson pr_rows_capped "$PR_ROWS_CAPPED" \
  --argjson pr_rows_min_total "$PR_ROWS_MIN_TOTAL" \
  --argjson return_catchup "$RETURN_CATCHUP" \
  --argjson candidate_prs "$CANDIDATE_PRS" "$FM_LANDED_JQ_DEFS"'
  def trunc($n): if . == null then null else
    (tostring | gsub("\\s+"; " ") | if (length > $n) then (.[:$n] + "…") else . end) end;
  def fit($n):
    tostring | gsub("\\s+"; " ")
    | if $n <= 0 then ""
      elif length > $n then (if $n == 1 then "…" else (.[:($n - 1)] + "…") end)
      else . end;
  def live_captain_call: .hold_bucket == "live";
  def projected_deferred_hold:
    .hold_bucket != null and .hold_bucket != "live";
  def bounded_blocker_note($n):
    ((.unresolved_blocker_ids // []) | map(tostring)) as $ids
    | reduce range(0; $ids | length) as $i
        ({shown:[]};
         ($ids[0:($i + 1)]) as $candidate
         | (($ids | length) - ($i + 1)) as $remaining
         | ("blocked-by " + ($candidate | join(","))
            + (if $remaining > 0 then " +\($remaining) more" else "" end)) as $rendered
         | if ($rendered | length) <= $n then .shown = $candidate else . end)
    | .shown as $shown
    | (($ids | length) - ($shown | length)) as $remaining
    | if ($shown | length) == 0 then "blocked-by +\($remaining) more"
      else ("blocked-by " + ($shown | join(","))
            + (if $remaining > 0 then " +\($remaining) more" else "" end))
      end;
  def hold_note:
    if .hold_bucket == "blocked" then bounded_blocker_note(70)
    elif .hold_bucket == "dated" then ("until " + (.hold_until // "-"))
    elif .hold_bucket == "aged" and .hold_age_days != null then
      ("held " + (.hold_age_days | tostring) + "d")
    else null end;
  def hold_gate_reason:
    (.hold_reason // .blocked_reason // "-") as $base
    | (hold_note) as $note
    | if $note == null then $base else ($note + ": " + $base) end;
  def hold_summary($title; $base):
    (hold_note) as $note
    | if $note == null then (($title + ": " + $base) | trunc(90))
      else ($note | length) as $note_n
      | (86 - $note_n) as $context_n
      | if $context_n < 2 then ($note | fit(90))
        else ([46, ($context_n / 2 | floor)] | min) as $title_n
        | (($title | fit($title_n)) + ": " + $note + ": "
           + ($base | fit($context_n - $title_n)))
        end
      end;
  def as_gate($owner):
    {id, title:(.title | trunc(60)),
     blocked_by:((.unresolved_blocker_ids // []) | if length > 0 then join(",") else "-" end | trunc(120)),
     reason:(hold_gate_reason | trunc(40)), owner:$owner,
     filed:((.since // null) | trunc(40))};
  ($fields | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) as $fl
  | (($fl | index("bodies")) != null) as $f_bodies
  | (($fl | index("paths")) != null) as $f_paths
  | (($fl | index("actions")) != null) as $f_actions
  | (($fl | index("endpoints")) != null) as $f_endpoints
  | ([ .backlog.records[] | select(landed_record)
       | {id, title, kind, hold_kind, pr_url, report_path, local_note, completion,
          home:"(main)", home_id:"(main)"} ]) as $main_done
  | ($main_done | sort_by([(.completion.date // ""), .id]) | reverse) as $landed_sorted
  | (if $all_landed == 1 then $landed_sorted else $landed_sorted[:$landed_n] end) as $done
  | ($done | map(.id)) as $done_ids
  | ([.tasks[] | select(.kind != "secondmate") | .id]) as $live_ids
  | ([.tasks[] | select(.kind != "secondmate" and .current_state.state == "working") | .id]) as $working_ids
  | ($live_ids + $done_ids) as $rel_ids
  | ([ .tasks[]
       | select(.endpoint.exists == false or .endpoint.agent_alive == "dead")
       | {id, backend, target:(.endpoint.target // "-"), exists:.endpoint.exists, agent:.endpoint.agent_alive} ]) as $unhealthy_all
  | ([ .tasks[]
       | select(.kind != "secondmate")
       | select(.retained_record != true)
       | select((.record_disposition == "active"
                   and (.backlog.state == "in_flight" or .current_state.state == "working"))
           or (.record_disposition == "unknown" and (.hints.open_decisions | length) > 0))
       | select(.backlog.current_role != "program")
       | select(.backlog.current_role != "held" or .current_state.state == "working")
       | {id, kind,
        state: .current_state.state,
        repo:(.backlog.repo // .project // null),
        name:((.backlog.title // "") as $name
              | (if ($name | test("[^[:space:]]")) then $name else .id end) | trunc(70)),
        doing: ((.current_state.detail // "") as $d
                | (if $d != "" then $d else (.hints.last_event_text // "") end) | trunc(90))
      } ]) as $in_flight_all
  | ([ .backlog.records[]
         | . as $record
         | select(.structured and .hold_bucket != null)
         | select(($all_decisions == 1) or live_captain_call)
         | {id,key:.id,verb:"captain-hold",
            summary:hold_summary(.title; .hold_reason),owner:"(main)",
            retrieve:("--task " + .id)} ]) as $decisions_all
  | ([ .backlog.records[]
         | . as $record
         | select(.structured and projected_deferred_hold) ]
     | length) as $decisions_marked_deferred
  | (if ($return_catchup.pending // false) then
       [{id:"(return-catchup)",
         title:((if ($return_catchup.blockers // 0) > 0 then
                   "\($return_catchup.blockers) blocker(s) to clear before ordinary work"
                 elif (($return_catchup.reason // "") != "") then
                   ("catch-up retained: " +
                    ($return_catchup.reason | sub("[,;] *catch-up stays gated$"; "")))
                 else "away-return catch-up is still open" end) | trunc(60)),
         blocked_by:"-",
         reason:"away-return catch-up",
         owner:"(main)",
         filed:null}]
     else [] end) as $return_catchup_gate
  | ([ .tasks[]
       | select(.kind != "secondmate")
       | select(((.record_disposition == "unknown" or .record_disposition == "ambiguous")
                   and (.hints.open_decisions | length) == 0)
           or ((.record_disposition == "done" or .record_disposition == "archive_done")
               and .current_state.state == "working"))
       | {id,
          title:(if .record_disposition == "ambiguous"
                 then "execution record matches duplicate current task rows"
                 elif .record_disposition == "unknown" and .backlog == null
                 then "execution record has no current or archived task row"
                 elif .record_disposition == "unknown"
                 then "task row disposition could not be classified"
                 else "closed task still has current working evidence" end),
          blocked_by:"-", reason:"task record integrity", owner:"(main)", filed:null} ]) as $task_record_gates
  | ((if (.main_inventory.valid == false) then
        [{id:"(main-inventory)",
          title:((.main_inventory.reason // "main inventory invalid") | trunc(60)),
          blocked_by:"-",
          reason:"main inventory",
          owner:"(main)",
          filed:null}]
      else [] end)
     + $task_record_gates
     + [ .backlog.records[]
         | . as $record
         | select(.structured and
             (.hold_bucket != null or .state == "queued" or
              (.state == "in_flight" and .current_role == "held" and ($working_ids | index($record.id) | not))))
         | select(.captain_actionable != true)
         | select((.hold_bucket == null) or ($all_decisions == 0))
         | as_gate("(main)") ]) as $gates_all
  | ([ .scout_reports[]
       | . as $r
       | select(($all_reports == 1) or (($rel_ids | index($r.id)) != null))
       | {id, path} ]) as $reports_all
  | ([ .tasks[] | select(.kind != "secondmate" and .pr.url != null and .pr.source == "meta") | {id, url:.pr.url} ]) as $recorded_prs_all
  | ([.tasks[] | select(.retained_record == true)
       | {id,state:.current_state.state,open_decisions:.hints.open_decisions,
          reason:(if .record_disposition == "archive_done"
                  then "backlog completion archived; execution record retained, cleanup unverified"
                  else "backlog closed; execution record retained, cleanup unverified" end)}]) as $retained_all
  | ($retained_all | map(select((.open_decisions | length) > 0))) as $retained_open
  | def filed_epoch:
      (.filed // null) as $filed
      | if ($filed | type) != "string" then null
        elif ($filed | test("T")) then try ($filed | fromdateiso8601) catch null
        else try (($filed + "T00:00:00Z") | fromdateiso8601) catch null end;
    def newest_filed_first:
      to_entries
      | sort_by((.value | filed_epoch) as $epoch
          | if $epoch == null then [1, 0, .key] else [0, -$epoch, .key] end)
      | map(.value);
    . as $snap
  | {
      schema: "fm-bearings.v1",
      home: $home,
      generated: $now,
      prs: $prs,
      in_flight: (if $all_in_flight == 1 then $in_flight_all else $in_flight_all[:$in_flight_n] end),
      retained_record_count: ($retained_all | length),
      retained_records: (if $all_retained == 1 then $retained_all[:$in_flight_n] else $retained_open end),
      decisions_open: (if $all_decisions == 1 then $decisions_all else $decisions_all[:$decisions_n] end),
      landed: ($done | map({id, what:(.title | trunc(70)),
                            artifact:(landed_artifact // "-"),owner:.home_id})),
      gates: ($return_catchup_gate
              + ($gates_all | newest_filed_first
                 | if $all_queued == 1 then . else .[:$gates_n] end)),
      reports: (if $all_reports == 1 then $reports_all else $reports_all[:$reports_n] end),
      recorded_prs: (if $all_recorded_prs == 1 then $recorded_prs_all else $recorded_prs_all[:$recorded_prs_n] end)
    }
  | . + (if ($unhealthy_all | length) > 0 then
           {unhealthy_endpoints:(if $all_unhealthy == 1 then $unhealthy_all else $unhealthy_all[:$unhealthy_n] end)}
         else {} end)
  | . + (if $include_prs == 1 then {candidate_prs:$candidate_prs} else {} end)
  | . + (if $f_bodies then {bodies:[ $snap.backlog.records[] | select(.structured and (.state == "queued" or .state == "done")) | {id, body:((.body_excerpt // .raw // "-") | trunc(200))} ]} else {} end)
  | . + (if $f_paths then {paths:[ $snap.tasks[] | {id, worktree:(.paths.worktree.path // "-"), status:.paths.status_log.path, report:.paths.report.path} ]} else {} end)
  | . + (if $f_actions then {actions:[ $snap.tasks[] | {id, watch:(.actions.watch // .actions.send // "-"), steer:(.actions.steer // .actions.send // "-")} ]} else {} end)
  | . + (if $f_endpoints then {endpoints:[ $snap.tasks[] | {id, backend, target:(.endpoint.target // "-"), exists:.endpoint.exists, agent:.endpoint.agent_alive} ]} else {} end)
  | . + {omitted: (
      [ (if $f_bodies then empty else {surface:"backlog item bodies", reveal:"--fields bodies"} end),
        (if $f_paths then empty else {surface:"task paths", reveal:"--fields paths"} end),
        (if $f_actions then empty else {surface:"watch/steer actions", reveal:"--fields actions"} end),
        (if $f_endpoints then empty else {surface:"healthy endpoint detail", reveal:"--fields endpoints"} end),
        (if $all_reports == 1 then empty else {surface:"full scout-report inventory", reveal:"--all-reports"} end),
        (if $all_landed == 0 and ($landed_sorted | length) > ($done | length) then {surface:("landed showing \($done | length) of \($landed_sorted | length)"), reveal:"--all-landed"} else empty end),
        ((($snap.main_inventory.orphan_in_flight // []) | length) as $n
         | if $n > 0 then {surface:("main in-flight backlog item(s) have no child metadata: \($n)"), reveal:"inspect main data/backlog.md In flight vs state/*.meta"} else empty end),
        ((($snap.main_inventory.unstructured_current_count // 0)) as $n
         | if $n > 0 then {surface:("main unstructured current backlog row(s): \($n)"), reveal:"inspect main data/backlog.md In flight and Queued free-form rows"} else empty end),
        (if $all_in_flight == 0 and ($in_flight_all | length) > $in_flight_n then {surface:("in_flight showing \($in_flight_n) of \($in_flight_all | length)"), reveal:"--all-in-flight"} else empty end),
        (($retained_all | length) as $n
         | (($retained_all | length) - ($retained_open | length)) as $historical_n
         | if $all_retained == 0 and $historical_n > 0 then {surface:("retained records omitted: \($historical_n)"), reveal:"--all-retained"}
           elif $all_retained == 1 and $n > $in_flight_n then {surface:("retained records showing \($in_flight_n) of \($n)"), reveal:"raise FM_BEARINGS_IN_FLIGHT"}
           else empty end),
        (if $all_decisions == 0 and ($decisions_all | length) > $decisions_n then {surface:("decisions_open showing \($decisions_n) of \($decisions_all | length)"), reveal:"--all-decisions"} else empty end),
        (if $all_decisions == 0 and $decisions_marked_deferred > 0 then {surface:("captain holds bucketed blocked, dated, or aged: \($decisions_marked_deferred)"), reveal:"--all-decisions"} else empty end),
        (if $all_queued == 0 and ($gates_all | length) > $gates_n then {surface:("gates showing \($gates_n) of \($gates_all | length)"), reveal:"--all-queued"} else empty end),
        (if $all_reports == 0 and ($reports_all | length) > $reports_n then {surface:("reports showing \($reports_n) of \($reports_all | length)"), reveal:"--all-reports"} else empty end),
        (if $all_recorded_prs == 0 and ($recorded_prs_all | length) > $recorded_prs_n then {surface:("recorded_prs showing \($recorded_prs_n) of \($recorded_prs_all | length)"), reveal:"--all-recorded-prs"} else empty end),
        (if $all_unhealthy == 0 and ($unhealthy_all | length) > $unhealthy_n then {surface:("unhealthy_endpoints showing \($unhealthy_n) of \($unhealthy_all | length)"), reveal:"--all-unhealthy"} else empty end),
        (if $include_prs == 1 and $pr_repos_total > $pr_repos_shown then {surface:("PR repositories showing \($pr_repos_shown) of \($pr_repos_total)"), reveal:"--all-pr-repos"} else empty end),
        (if $include_prs == 1 and $pr_rows_capped > 0 then {surface:("candidate_prs showing \($candidate_prs | length) of at least \($pr_rows_min_total); capped in \($pr_rows_capped) repo(s)"), reveal:"raise FM_BEARINGS_PR_LIMIT"} else empty end),
        (if $include_prs == 1 then empty else {surface:"live PR discovery + checks", reveal:"--include-prs"} end) ]) }
') || { echo "fm-bearings-snapshot: projection failed" >&2; exit 1; }

print_model "$MODEL"
