#!/usr/bin/env bash
# fm-bearings-snapshot.sh - compact, bounded, TOON-by-default bearings projection.
#
# A thin wrapper OVER the canonical bin/fm-fleet-snapshot.sh. It does not parse
# fleet state itself: it shells out to `fm-fleet-snapshot.sh --json`, projects that
# complete structured contract down to the small set of fields a "pick up where I
# left off" read needs, and renders TOON at the output boundary. The internal data
# model stays JSON (`--json` prints it verbatim); TOON is the default agent-facing
# format per the AXI standard, and TOON/JSON are parity representations of the same
# projected model. The projection is view-specific: it DROPS fields from the bearings
# output, it never removes them from - or otherwise weakens - the canonical snapshot,
# which stays complete.
#
# LOCAL-ONLY by default: a normal invocation makes ZERO GitHub/network/auth calls.
# It MAY surface PR URLs already recorded locally in task meta (recorded_prs), but it
# performs no live discovery or checks. Live PR discovery/checks happen ONLY under
# --include-prs, which is the sole path that touches the network; all gh coupling
# lives in that branch and never in the canonical snapshot. The default output states
# explicitly (the prs: line and the omitted[] surfaces) what was not requested, so an
# absence is never ambiguous.
#
# This wrapper consumes canonical status decisions plus structured captain-held
# backlog items. It never infers decisions from report or visual-review prose.
#
# The landed section merges this home's Done with the canonical snapshot's
# secondmate_landed roll-up (fm-fleet-snapshot.sh), so merges a secondmate managed -
# recorded in ITS OWN backlog, never the main one - are visible. It stays bounded by
# a per-home cap and an overall cap, with omitted[] disclosure of both and of any
# secondmate home whose backlog was unreadable; no GitHub/network call is involved.
# The default landed baseline is balanced across homes: each home keeps its internal
# newest-first ordering, homes iterate in deterministic id order, sparse homes do not
# waste capacity, and --all-landed switches back to the complete global newest-first
# order.
#
# Flags:
#   (default)        compact projection, TOON, local-only
#   --json           the same projected model as JSON (machine/debug; parity form)
#   --include-prs    ALSO do live open-PR discovery + checks (the only network path)
#   --fields <list>  opt in to dropped surfaces: bodies,paths,actions,endpoints
#   --all-in-flight  include every in-flight task
#   --all-decisions  include every open decision
#   --all-secondmates include every aggregated secondmate record
#   --all-landed     include every landed record from every home (default: bounded)
#   --all-reports    include the full scout-report inventory (default: relevant only)
#   --all-queued     include superseded queued items (default: dropped)
#   --all-recorded-prs include every locally recorded PR
#   --all-unhealthy  include every unhealthy endpoint
#   --all-pr-repos   query every discovered repository under --include-prs
#   -h,--help        usage
#
# Output contract: `fm-bearings.v1`. Read-only; no locks, no mutation, no reports.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/fm-fleet-snapshot.sh"

# Bounds (overridable for tests / large fleets).
FM_BEARINGS_LANDED=${FM_BEARINGS_LANDED:-6}
FM_BEARINGS_LANDED_PER_HOME=${FM_BEARINGS_LANDED_PER_HOME:-$FM_BEARINGS_LANDED}
FM_BEARINGS_IN_FLIGHT=${FM_BEARINGS_IN_FLIGHT:-20}
FM_BEARINGS_DECISIONS=${FM_BEARINGS_DECISIONS:-20}
FM_BEARINGS_SECONDMATES=${FM_BEARINGS_SECONDMATES:-20}
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
validate_bound FM_BEARINGS_LANDED_PER_HOME "$FM_BEARINGS_LANDED_PER_HOME"
validate_bound FM_BEARINGS_IN_FLIGHT "$FM_BEARINGS_IN_FLIGHT"
validate_bound FM_BEARINGS_DECISIONS "$FM_BEARINGS_DECISIONS"
validate_bound FM_BEARINGS_SECONDMATES "$FM_BEARINGS_SECONDMATES"
validate_bound FM_BEARINGS_GATES "$FM_BEARINGS_GATES"
validate_bound FM_BEARINGS_REPORTS "$FM_BEARINGS_REPORTS"
validate_bound FM_BEARINGS_RECORDED_PRS "$FM_BEARINGS_RECORDED_PRS"
validate_bound FM_BEARINGS_UNHEALTHY "$FM_BEARINGS_UNHEALTHY"
validate_bound FM_BEARINGS_PR_REPOS "$FM_BEARINGS_PR_REPOS"
validate_bound FM_BEARINGS_PR_LIMIT "$FM_BEARINGS_PR_LIMIT"

usage() {
  cat <<'EOF'
usage: fm-bearings-snapshot.sh [--json] [--include-prs] [--fields <list>]
                               [--all-in-flight] [--all-decisions]
                               [--all-secondmates] [--all-landed]
                               [--all-reports] [--all-queued]
                               [--all-recorded-prs] [--all-unhealthy]
                               [--all-pr-repos]

Compact bearings projection over fm-fleet-snapshot.sh. TOON by default.
Default is LOCAL-ONLY (no network); --include-prs is the only path that fetches.

Default fields: schema, home, generated, prs, in_flight{id,kind,state,doing},
  secondmates{id,state,doing,provenance,freshness,age_seconds,contradiction,reason},
  decisions_open{id,key,verb,summary,owner}, landed{id,what,artifact,owner},
  gates{id,title,blocked_by,reason,owner}, reports{id,path}, recorded_prs{id,url},
  unhealthy_endpoints{...} (only when non-empty), omitted{surface,reveal}.
landed merges this home's Done with registered secondmate homes' Done, bounded by
  a per-home cap (FM_BEARINGS_LANDED_PER_HOME) and an overall cap (FM_BEARINGS_LANDED),
  with omitted[] disclosure. Default selection is balanced across deterministic home
  order while preserving each home's internal newest-first order; sparse homes do
  not waste capacity. --all-landed reveals the full global newest-first set.
For every registered secondmate, validated structured state from its own home is
  authoritative. Parent events and bounded terminal reads are labeled fallback or
  contradiction evidence and never become current work.
Opt-in surfaces: --fields bodies|paths|actions|endpoints, --all-in-flight,
  --all-decisions, --all-secondmates, --all-landed, --all-reports, --all-queued, --all-recorded-prs,
  --all-unhealthy, --all-pr-repos, --include-prs (adds candidate_prs).
Raise FM_BEARINGS_PR_LIMIT to expand per-repository open-PR results.
EOF
}

FORMAT=toon
INCLUDE_PRS=0
ALL_REPORTS=0
ALL_QUEUED=0
ALL_IN_FLIGHT=0
ALL_DECISIONS=0
ALL_SECONDMATES=0
ALL_LANDED=0
ALL_RECORDED_PRS=0
ALL_UNHEALTHY=0
ALL_PR_REPOS=0
FIELDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --include-prs) INCLUDE_PRS=1 ;;
    --all-reports) ALL_REPORTS=1 ;;
    --all-queued) ALL_QUEUED=1 ;;
    --all-in-flight) ALL_IN_FLIGHT=1 ;;
    --all-decisions) ALL_DECISIONS=1 ;;
    --all-secondmates) ALL_SECONDMATES=1 ;;
    --all-landed) ALL_LANDED=1 ;;
    --all-recorded-prs) ALL_RECORDED_PRS=1 ;;
    --all-unhealthy) ALL_UNHEALTHY=1 ;;
    --all-pr-repos) ALL_PR_REPOS=1 ;;
    --fields) shift; FIELDS=${1:-} ;;
    --fields=*) FIELDS=${1#--fields=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-bearings-snapshot: jq not found" >&2; exit 1; }

# The deterministic return-catch-up owner must clear before this or any other
# ordinary captain request proceeds. Bearings does not reproduce that policy;
# it only consults the shared read-only gate.
"$SCRIPT_DIR/fm-afk-return.sh" guard || exit $?

NOW=${FM_BEARINGS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
if [ "$ALL_LANDED" = 1 ] || [ "$ALL_SECONDMATES" = 1 ]; then
  if [ "$ALL_LANDED" = 1 ]; then
    SNAP=$(FM_SNAPSHOT_NOW="$NOW" FM_SNAPSHOT_SECONDMATES=0 FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=0 "$FLEET" --json) || exit $?
  else
    SNAP=$(FM_SNAPSHOT_NOW="$NOW" FM_SNAPSHOT_SECONDMATES=0 "$FLEET" --json) || exit $?
  fi
else
  SNAP=$(FM_SNAPSHOT_NOW="$NOW" "$FLEET" --json) || exit $?
fi
HOME_LABEL=$(printf '%s' "$SNAP" | jq -er '.fm_home | strings | split("/") | (.[-2:] | join("/"))') \
  || { echo "fm-bearings-snapshot: invalid canonical snapshot" >&2; exit 1; }

# --- optional live PR enrichment (the ONLY network path) --------------------
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
gh_bounded() {  # <args...>
  if command -v timeout >/dev/null 2>&1; then
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 timeout "$FM_BEARINGS_PR_TIMEOUT" gh "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gtimeout "$FM_BEARINGS_PR_TIMEOUT" gh "$@"
  elif command -v perl >/dev/null 2>&1; then
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$FM_BEARINGS_PR_TIMEOUT" gh "$@"
  else
    return 124
  fi
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
$(printf '%s' "$SNAP" | jq -r '.tasks[] | select(.kind != "secondmate") | .paths.worktree.path // empty')
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
MODEL=$(printf '%s' "$SNAP" | jq \
  --arg home "$HOME_LABEL" \
  --arg now "$NOW" \
  --arg prs "$PR_STATUS" \
  --arg fields "$FIELDS" \
  --argjson landed_n "$FM_BEARINGS_LANDED" \
  --argjson landed_per_home_n "$FM_BEARINGS_LANDED_PER_HOME" \
  --argjson in_flight_n "$FM_BEARINGS_IN_FLIGHT" \
  --argjson decisions_n "$FM_BEARINGS_DECISIONS" \
  --argjson secondmates_n "$FM_BEARINGS_SECONDMATES" \
  --argjson gates_n "$FM_BEARINGS_GATES" \
  --argjson reports_n "$FM_BEARINGS_REPORTS" \
  --argjson recorded_prs_n "$FM_BEARINGS_RECORDED_PRS" \
  --argjson unhealthy_n "$FM_BEARINGS_UNHEALTHY" \
  --argjson include_prs "$INCLUDE_PRS" \
  --argjson all_in_flight "$ALL_IN_FLIGHT" \
  --argjson all_decisions "$ALL_DECISIONS" \
  --argjson all_secondmates "$ALL_SECONDMATES" \
  --argjson all_landed "$ALL_LANDED" \
  --argjson all_reports "$ALL_REPORTS" \
  --argjson all_queued "$ALL_QUEUED" \
  --argjson all_recorded_prs "$ALL_RECORDED_PRS" \
  --argjson all_unhealthy "$ALL_UNHEALTHY" \
  --argjson pr_repos_total "$PR_REPOS_TOTAL" \
  --argjson pr_repos_shown "$PR_REPOS_SHOWN" \
  --argjson pr_rows_capped "$PR_ROWS_CAPPED" \
  --argjson pr_rows_min_total "$PR_ROWS_MIN_TOTAL" \
  --argjson candidate_prs "$CANDIDATE_PRS" '
  def trunc($n): if . == null then null else
    (tostring | gsub("\\s+"; " ") | if (length > $n) then (.[:$n] + "…") else . end) end;
  def round_robin_landed($n):
    . as $groups
    | [range(0; (($groups | map(length) | max) // 0)) as $i
       | $groups[]
       | select(length > $i)
       | .[$i]][:$n];
  ($fields | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) as $fl
  | (($fl | index("bodies")) != null) as $f_bodies
  | (($fl | index("paths")) != null) as $f_paths
  | (($fl | index("actions")) != null) as $f_actions
  | (($fl | index("endpoints")) != null) as $f_endpoints
  | ([ .backlog.records[] | select(.state == "done" and .structured and .kind != "captain")
       | {id, title, pr_url, report_path, local_note, completion, home:"(main)", home_id:"(main)"} ]) as $main_done
  | ((.secondmate_landed.records) // []) as $mate_done
  | ($main_done + $mate_done) as $all_landed_rows
  | ([ $all_landed_rows | group_by(.home_id)[]
       | sort_by([(.completion.date // ""), .id]) | reverse
       | (if $all_landed == 1 then . else .[:$landed_per_home_n] end) ]) as $per_home_groups
  | ($per_home_groups | add // []) as $per_home_capped
  | ([ $all_landed_rows | group_by(.home_id)[] | select(length > $landed_per_home_n) ] | length) as $home_cap_dropped
  | ($per_home_capped | sort_by([(.completion.date // ""), .id]) | reverse) as $landed_sorted
  | (if $all_landed == 1 then $landed_sorted else ($per_home_groups | round_robin_landed($landed_n)) end) as $done
  | ($done | map(.id)) as $done_ids
  | ([.tasks[] | select(.kind != "secondmate") | .id]) as $live_ids
  | ($live_ids + $done_ids) as $rel_ids
  | ([ .tasks[]
       | select(.endpoint.exists == false or .endpoint.agent_alive == "dead")
       | {id, backend, target:(.endpoint.target // "-"), exists:.endpoint.exists, agent:.endpoint.agent_alive} ]
     + [ (.secondmate_current.records // [])[] as $m | $m.endpoints[]?
         | select(.endpoint.exists == false or .endpoint.agent_alive == "dead")
         | {id:($m.id + "/" + .id),backend:"secondmate-home",target:(.endpoint.target // "-"),exists:.endpoint.exists,agent:.endpoint.agent_alive} ]) as $unhealthy_all
  | ([ (.secondmate_current.records // [])[]
       | ([.decisions_open[]? | select(.source == "backlog" and .verb == "captain-hold")]) as $captain_holds
       | ([.holds[]? | select(.source == "backlog")]) as $backlog_holds
       | . + {
           bearings_captain_holds:$captain_holds,
           bearings_holds:(if .current.state == "captain_decision" then $backlog_holds else .holds end),
           bearings_state:(
             if .current.state == "captain_decision" then
               if ($captain_holds | length) > 0 then "captain_decision"
               elif (.active_children | length) > 0 then "active_child_work"
               elif ($backlog_holds | length) > 0 then "externally_held"
               else "unknown" end
             else .current.state end)
         } ]) as $secondmate_views
  | ([ if .secondmate_current.registry.available == false then
         {id:"(registry)",state:"unknown",doing:(.secondmate_current.registry.reason // "Registered secondmate table unavailable"),
          provenance:(.secondmate_current.registry.provenance // "registered-table"),
          freshness:(.secondmate_current.registry.freshness.status // "unavailable"),
          age_seconds:null,contradiction:false,reason:(.secondmate_current.registry.reason // "Registered secondmate table unavailable")}
       else empty end ]
     + [ $secondmate_views[]
       | {id,state:.bearings_state,
          doing:((if .bearings_state == "active_child_work" then
                    ([.active_children[] | .id + ": " + (.doing // .state)] | join("; "))
                  elif .bearings_state == "captain_decision" then
                    ([.bearings_captain_holds[] | .summary] | join("; "))
                  elif .bearings_state == "externally_held" then
                    ([.bearings_holds[] | .id + ": " + (.reason // "held")] | join("; "))
                  elif .bearings_state == "no_active_work" then "No active child work"
                  else (.current.reason // "Current home state unavailable") end) | trunc(120)),
          provenance:.provenance.selected,freshness:.freshness.status,
          age_seconds:.freshness.age_seconds,contradiction:(.contradiction // false),
          reason:(.current.reason // "-")} ]) as $secondmates_all
  | ([ .tasks[] | select(.kind != "secondmate") | {
        id, kind,
        state: .current_state.state,
        doing: ((.current_state.detail // "") as $d
                | (if $d != "" then $d else (.hints.last_event_text // "") end) | trunc(90))
      } ]
     + [ $secondmate_views[]
         | select(.bearings_state == "active_child_work")
         | {id,kind:"secondmate",state:.bearings_state,
            doing:([.active_children[] | .id + ": " + (.doing // .state)] | join("; ") | trunc(90))} ]) as $in_flight_all
  | ([ .backlog.records[]
         | select(.state == "queued" and .structured and .kind == "captain"
                  and .hold_kind == "captain" and .hold_reason != null)
         | {id,key:.id,verb:"captain-hold",
            summary:((.title + ": " + .hold_reason) | trunc(90)),owner:"(main)"} ]
     + [ (.secondmate_current.records // [])[] as $m | $m.decisions_open[]?
         | select(.source == "backlog" and .verb == "captain-hold")
         | {id:($m.id + "/" + .id),key,verb,
            summary:(((.summary // .id) + ": " + (.reason // "captain decision pending")) | trunc(90)),owner:$m.id} ]) as $decisions_all
  | ([ .backlog.records[]
       | select(.state == "queued" and .structured)
       | select((.kind == "captain" and .hold_kind == "captain" and .hold_reason != null) | not)
       | select(($all_queued == 1)
                or (((.body_excerpt // "") | test("SUPERSEDED|NOT REQUIRED|NOT-REQUIRED|DEFERRED"; "i")) | not))
       | {id, title:(.title | trunc(60)), blocked_by:(.blocked_by // "-"),
          reason:((.blocked_reason // "-") | trunc(40)),owner:"(main)"} ]
     + [ (.secondmate_current.records // [])[] as $m
         | select($m.provenance.selected == "structured-home")
         | $m.queued[]?
         | select((.kind == "captain" and .hold_kind == "captain" and .hold_reason != null) | not)
         | {id,title:(.title | trunc(60)),blocked_by:(.blocked_by // "-"),
            reason:((.blocked_reason // "-") | trunc(40)),owner:$m.id} ]) as $gates_all
  | ([ .scout_reports[]
       | . as $r
       | select(($all_reports == 1) or (($rel_ids | index($r.id)) != null))
       | {id, path} ]) as $reports_all
  | ([ .tasks[] | select(.kind != "secondmate" and .pr.url != null and .pr.source == "meta") | {id, url:.pr.url} ]) as $recorded_prs_all
  | . as $snap
  | {
      schema: "fm-bearings.v1",
      home: $home,
      generated: $now,
      prs: $prs,
      in_flight: (if $all_in_flight == 1 then $in_flight_all else $in_flight_all[:$in_flight_n] end),
      secondmates: (if $all_secondmates == 1 then $secondmates_all else $secondmates_all[:$secondmates_n] end),
      decisions_open: (if $all_decisions == 1 then $decisions_all else $decisions_all[:$decisions_n] end),
      landed: ($done | map({id, what:(.title | trunc(70)),
                            artifact:(.pr_url // .report_path // .local_note // "-"),owner:.home_id})),
      gates: (if $all_queued == 1 then $gates_all else $gates_all[:$gates_n] end),
      reports: (if $all_reports == 1 then $reports_all else $reports_all[:$reports_n] end),
      recorded_prs: (if $all_recorded_prs == 1 then $recorded_prs_all else $recorded_prs_all[:$recorded_prs_n] end)
    }
  | . + (if ($unhealthy_all | length) > 0 then
           {unhealthy_endpoints:(if $all_unhealthy == 1 then $unhealthy_all else $unhealthy_all[:$unhealthy_n] end)}
         else {} end)
  | . + (if $include_prs == 1 then {candidate_prs:$candidate_prs} else {} end)
  | . + (if $f_bodies then {bodies:[ $snap.backlog.records[] | select(.structured and (.state == "queued" or .state == "done")) | {id, body:((.body_excerpt // .raw // "-") | trunc(200))} ]} else {} end)
  | . + (if $f_paths then {paths:[ $snap.tasks[] | {id, worktree:(.paths.worktree.path // "-"), home:(.paths.home.path // "-"), status:.paths.status_log.path, report:.paths.report.path} ]} else {} end)
  | . + (if $f_actions then {actions:[ $snap.tasks[] | {id, watch:(.actions.watch // .actions.send // "-"), steer:(.actions.steer // .actions.send // "-")} ]} else {} end)
  | . + (if $f_endpoints then {endpoints:[ $snap.tasks[] | {id, backend, target:(.endpoint.target // "-"), exists:.endpoint.exists, agent:.endpoint.agent_alive} ]} else {} end)
  | . + {omitted: (
      [ (if $f_bodies then empty else {surface:"backlog item bodies", reveal:"--fields bodies"} end),
        (if $f_paths then empty else {surface:"task paths", reveal:"--fields paths"} end),
        (if $f_actions then empty else {surface:"watch/steer actions", reveal:"--fields actions"} end),
        (if $f_endpoints then empty else {surface:"healthy endpoint detail", reveal:"--fields endpoints"} end),
        (if $all_reports == 1 then empty else {surface:"full scout-report inventory", reveal:"--all-reports"} end),
        (if $all_queued == 1 then empty else {surface:"superseded queued items", reveal:"--all-queued"} end),
        (if $all_landed == 0 and ($per_home_capped | length) > ($done | length) then {surface:("landed showing \($done | length) of \($per_home_capped | length)" + (($done | map(.home_id) | unique | map(select(. != "(main)")) | length) as $k | if $k > 0 then " (incl. \($k) secondmate home(s))" else "" end)), reveal:"--all-landed"} else empty end),
        (if $all_landed == 0 and $home_cap_dropped > 0 then {surface:("landed per-home capped at \($landed_per_home_n) for \($home_cap_dropped) home(s)"), reveal:"--all-landed"} else empty end),
        (if (($snap.secondmate_landed.unreadable // []) | length) > 0 then {surface:("secondmate home(s) with unreadable backlog: \(($snap.secondmate_landed.unreadable // []) | length)"), reveal:"inspect the listed secondmate home backlogs"} else empty end),
        (if $all_landed == 0 and (($snap.secondmate_landed.truncated // []) | length) > 0 then {surface:("secondmate home Done capped at the snapshot layer for \(($snap.secondmate_landed.truncated // []) | length) home(s)"), reveal:"--all-landed"} else empty end),
        (if $all_in_flight == 0 and ($in_flight_all | length) > $in_flight_n then {surface:("in_flight showing \($in_flight_n) of \($in_flight_all | length)"), reveal:"--all-in-flight"} else empty end),
        (if $all_secondmates == 0 and ($secondmates_all | length) > $secondmates_n then {surface:("secondmates showing \($secondmates_n) of \($secondmates_all | length)"), reveal:"--all-secondmates"} else empty end),
        (if (($snap.secondmate_current.truncated // 0) > 0) then {surface:("registered secondmates omitted by snapshot bound: \($snap.secondmate_current.truncated)"), reveal:"raise FM_SNAPSHOT_SECONDMATES"} else empty end),
        (if $snap.secondmate_current.registry.input_truncated == true then {surface:"secondmate registry input truncated by bounded read", reveal:"raise FM_SNAPSHOT_REGISTRY_LINES or FM_SNAPSHOT_REGISTRY_BYTES"} else empty end),
        (if $snap.secondmate_current.registry.records_truncated == true then {surface:"secondmate registry records omitted by bounded read", reveal:"raise FM_SNAPSHOT_REGISTRY_RECORDS"} else empty end),
        (if $snap.secondmate_current.registry.available == false then {surface:("secondmate registry unavailable: " + ($snap.secondmate_current.registry.reason // "read failed")), reveal:"inspect data/secondmates.md"} else empty end),
        (([($snap.secondmate_current.records // [])[] | select(.parent_event.activity_scan.input_truncated == true or .parent_event.activity_scan.retained_truncated == true)] | length) as $n | if $n > 0 then {surface:("secondmate parent activity evidence truncated for \($n) record(s)"), reveal:"raise FM_SNAPSHOT_PARENT_ACTIVITY_LINES, FM_SNAPSHOT_PARENT_ACTIVITY_BYTES, or FM_SNAPSHOT_PARENT_ACTIVITIES"} else empty end),
        (([($snap.secondmate_current.records // [])[] | select(.parent_event.activity_scan.available == false)] | length) as $n | if $n > 0 then {surface:("secondmate parent activity evidence unavailable for \($n) record(s)"), reveal:"inspect the parent status logs"} else empty end),
        (if $all_decisions == 0 and ($decisions_all | length) > $decisions_n then {surface:("decisions_open showing \($decisions_n) of \($decisions_all | length)"), reveal:"--all-decisions"} else empty end),
        (if $all_queued == 0 and ($gates_all | length) > $gates_n then {surface:("gates showing \($gates_n) of \($gates_all | length)"), reveal:"--all-queued"} else empty end),
        (if $all_reports == 0 and ($reports_all | length) > $reports_n then {surface:("reports showing \($reports_n) of \($reports_all | length)"), reveal:"--all-reports"} else empty end),
        (if $all_recorded_prs == 0 and ($recorded_prs_all | length) > $recorded_prs_n then {surface:("recorded_prs showing \($recorded_prs_n) of \($recorded_prs_all | length)"), reveal:"--all-recorded-prs"} else empty end),
        (if $all_unhealthy == 0 and ($unhealthy_all | length) > $unhealthy_n then {surface:("unhealthy_endpoints showing \($unhealthy_n) of \($unhealthy_all | length)"), reveal:"--all-unhealthy"} else empty end),
        (if $include_prs == 1 and $pr_repos_total > $pr_repos_shown then {surface:("PR repositories showing \($pr_repos_shown) of \($pr_repos_total)"), reveal:"--all-pr-repos"} else empty end),
        (if $include_prs == 1 and $pr_rows_capped > 0 then {surface:("candidate_prs showing \($candidate_prs | length) of at least \($pr_rows_min_total); capped in \($pr_rows_capped) repo(s)"), reveal:"raise FM_BEARINGS_PR_LIMIT"} else empty end),
        (if $include_prs == 1 then empty else {surface:"live PR discovery + checks", reveal:"--include-prs"} end) ]) }
') || { echo "fm-bearings-snapshot: projection failed" >&2; exit 1; }

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

# --- TOON renderer (output boundary; parity with the JSON model) ------------
# The model is a flat object of scalar fields plus arrays of uniform scalar
# objects, so the encoder only needs object scalars, the tabular array form
# (key[N]{fields}: + comma rows at +2 indent), and the empty-array form (key: []),
# per the TOON spec. Quoting follows the spec exactly.
TOON=$(printf '%s\n' "$MODEL" | jq -r '
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
') || { echo "fm-bearings-snapshot: TOON rendering failed" >&2; exit 1; }
printf '%s\n' "$TOON"
